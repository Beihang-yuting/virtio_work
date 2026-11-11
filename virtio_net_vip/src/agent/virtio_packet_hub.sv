// =============================================================================
// virtio_packet_hub.sv
// 目录层次：virtio_net_vip/src/agent；单个 Virtio Function 的完整报文发布点。
// 文件职责：把 atomic ops 产生的 VTX/RX 完整样本复制到各个 sidecar consumer，
// 让 project_env 保持只负责装配。hub 不比较报文、不解析协议，也不拥有 DMA；
// mailbox 只保存 clone 后的样本，订阅者通过 sequence 主动取走并负责生命周期。
// 主要依赖：virtio_packet_sample.sv、UVM mailbox。
// 设计边界：每个 Function/ops 一个 hub；consumer_id 仅在该 Function 内唯一，
// VTX 与 VRX 仍按 direction 分开。队列满时丢弃该 consumer 的副本并报告一次，
// 不阻塞真实 TX/RX 发布路径。
// =============================================================================

`ifndef VIRTIO_PACKET_HUB_SV
`define VIRTIO_PACKET_HUB_SV

class virtio_packet_hub extends uvm_object;
    `uvm_object_utils(virtio_packet_hub)

    typedef mailbox #(virtio_packet_sample) sample_mailbox_t;
    protected sample_mailbox_t m_subscribers[string];
    protected longint unsigned m_published;
    protected longint unsigned m_dropped;
    protected bit m_drop_reported;

    // 功能：创建空 Function 级发布器。
    // 输入/输出：输入 UVM 名称；输出为新对象。
    // 边界/副作用：不建立订阅，不访问 PCIe、Host memory 或队列。
    extern function new(string name="virtio_packet_hub");

    // 功能：创建一个有界 consumer mailbox。
    // 输入/输出：输入方向、consumer_id、深度；返回是否新建成功。
    // 边界/副作用：重复订阅不覆盖旧 mailbox；depth=0 使用无界 mailbox。
    extern function bit subscribe(
        input vio_packet_dir_e direction,
        input int unsigned consumer_id = 0,
        input int unsigned depth = 1024
    );

    // 功能：移除一个 consumer 并丢弃其尚未读取的样本。
    // 输入/输出：输入方向和 consumer_id；返回是否存在该订阅。
    // 边界/副作用：不影响其他 consumer；已取出的样本由调用方自行管理。
    extern function bit unsubscribe(
        input vio_packet_dir_e direction,
        input int unsigned consumer_id = 0
    );

    // 功能：发布一个样本到所有同方向订阅者。
    // 输入/输出：输入源样本；返回成功入队的 consumer 数量。
    // 边界/副作用：每个 mailbox 收到独立 clone；满队列只丢该副本，不阻塞发布者。
    extern function int unsigned publish(virtio_packet_sample source);

    // 功能：从指定 consumer 取一个样本。
    // 输入/输出：输出 packet；输入方向、consumer_id 和 timeout。
    // 边界/副作用：timeout=0 永久等待；未订阅或超时返回 null，不改变其他 mailbox。
    extern task mon_xaction(
        output virtio_packet_sample packet,
        input vio_packet_dir_e direction,
        input int unsigned consumer_id = 0,
        input time timeout = 0
    );

    // 功能：查询 consumer 当前排队样本数。
    // 输入/输出：输入方向和 consumer_id；返回 0 表示未订阅或队列为空。
    // 边界/副作用：只读，不等待，不消费样本。
    extern function int unsigned pending(
        input vio_packet_dir_e direction,
        input int unsigned consumer_id = 0
    );

    // 功能：返回发布和丢弃统计，供 end checker/诊断使用。
    // 输入/输出：输出两个累计计数；不修改 hub 状态。
    extern function void get_stats(
        output longint unsigned published,
        output longint unsigned dropped
    );

    // 功能：生成 direction+consumer 的内部订阅键。
    // 输入/输出：输入方向和 consumer_id；返回稳定字符串。
    // 边界/副作用：只用于本 hub 内部，不与 packet_key 混用。
    extern protected function string subscription_key(
        input vio_packet_dir_e direction,
        input int unsigned consumer_id
    );

    // 功能：判断内部订阅键是否对应指定方向。
    // 输入/输出：输入内部键和方向；返回匹配结果。
    // 边界/副作用：只解析 subscribe 生成的固定格式。
    extern protected function bit subscription_matches(
        input string key,
        input vio_packet_dir_e direction
    );
endclass

function virtio_packet_hub::new(string name="virtio_packet_hub");
    super.new(name);
    m_published     = 0;
    m_dropped       = 0;
    m_drop_reported = 0;
endfunction

function bit virtio_packet_hub::subscribe(
    input vio_packet_dir_e direction,
    input int unsigned consumer_id,
    input int unsigned depth
);
    string key;

    key = subscription_key(direction, consumer_id);
    if (m_subscribers.exists(key)) return 0;
    m_subscribers[key] = new(depth);
    return 1;
endfunction

function bit virtio_packet_hub::unsubscribe(
    input vio_packet_dir_e direction,
    input int unsigned consumer_id
);
    string key;

    key = subscription_key(direction, consumer_id);
    if (!m_subscribers.exists(key)) return 0;
    m_subscribers.delete(key);
    return 1;
endfunction

function int unsigned virtio_packet_hub::publish(
    virtio_packet_sample source
);
    int unsigned delivered;
    virtio_packet_sample copy;
    string key;

    delivered = 0;
    if (source == null) return 0;
    m_published++;
    foreach (m_subscribers[key]) begin
        if (!subscription_matches(key, source.direction)) continue;
        copy = new("packet_sample");
        copy.copy_from(source);
        if (m_subscribers[key].try_put(copy)) begin
            delivered++;
        end else begin
            m_dropped++;
            if (!m_drop_reported) begin
                `uvm_warning("VIO_PACKET_HUB",
                    "packet consumer mailbox is full; samples are being dropped")
                m_drop_reported = 1;
            end
        end
    end
    return delivered;
endfunction

task virtio_packet_hub::mon_xaction(
    output virtio_packet_sample packet,
    input vio_packet_dir_e direction,
    input int unsigned consumer_id,
    input time timeout
);
    sample_mailbox_t mailbox_ref;
    virtio_packet_sample received;
    bit received_valid;
    string key;

    packet = null;
    key = subscription_key(direction, consumer_id);
    if (!m_subscribers.exists(key)) return;
    mailbox_ref = m_subscribers[key];

    if (timeout == 0) begin
        mailbox_ref.get(received);
        packet = received;
        return;
    end

    received_valid = 0;
    fork
        begin
            mailbox_ref.get(received);
            received_valid = 1;
        end
        begin
            #(timeout);
        end
    join_any
    disable fork;
    if (received_valid) packet = received;
endtask

function int unsigned virtio_packet_hub::pending(
    input vio_packet_dir_e direction,
    input int unsigned consumer_id
);
    string key;

    key = subscription_key(direction, consumer_id);
    if (!m_subscribers.exists(key)) return 0;
    return m_subscribers[key].num();
endfunction

function void virtio_packet_hub::get_stats(
    output longint unsigned published,
    output longint unsigned dropped
);
    published = m_published;
    dropped   = m_dropped;
endfunction

function string virtio_packet_hub::subscription_key(
    input vio_packet_dir_e direction,
    input int unsigned consumer_id
);
    return $sformatf("%0d.%0d", direction, consumer_id);
endfunction

function bit virtio_packet_hub::subscription_matches(
    input string key,
    input vio_packet_dir_e direction
);
    return key.substr(0, 0) == $sformatf("%0d", direction);
endfunction

`endif
