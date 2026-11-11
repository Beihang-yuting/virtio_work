// =============================================================================
// virtio_packet_seq.sv
// 目录层次：virtio_net_vip/src/agent；VIO 完整报文的用户侧采样 sequence。
// 文件职责：把 Function 的 packet hub 暴露成可复用的 sequence API。它不是 PCIe
// driver sequence，也不通过 start() 发 TLP；用户在 sidecar worker 中调用
// subscribe/mon_xaction 取出 VTX/RX 样本，再交给 RM/SCB。
// 主要依赖：virtio_packet_hub、virtio_atomic_ops、virtio_function_instance。
// 所有权与生命周期：sequence 借用 ops/hub；unsubscribe 后 hub 不再保留该 consumer
// 的数据，sequence 不释放 Function、ring、Host memory 或 PCIe 资源。
// =============================================================================

`ifndef VIRTIO_PACKET_SEQ_SV
`define VIRTIO_PACKET_SEQ_SV

class virtio_packet_seq extends uvm_sequence #(virtio_transaction);
    `uvm_object_utils(virtio_packet_seq)

    virtio_atomic_ops		ops;
    virtio_packet_hub		hub;

    // 功能：创建一个未绑定 Function 的采样 sequence。
    // 输入/输出：输入 UVM 名称；输出为新对象。
    // 边界/副作用：不启动 sequence，不访问 DUT。
    extern function new(string name="virtio_packet_seq");

    // 功能：绑定已有 atomic ops 的 packet hub。
    // 输入/输出：输入 Function-owned ops；无返回值。
    // 边界/副作用：只保存借用句柄，不创建或替换 hub。
    extern function void bind_ops(virtio_atomic_ops candidate_ops);

    // 功能：绑定一个已经完成 Function 配置的实例。
    // 输入/输出：输入 Function instance；无返回值。
    // 边界/副作用：不触发配置或 PCIe 访问；缺少 ops 时报告错误并保持未绑定。
    extern function void bind_function(virtio_function_instance instance);

    // 功能：建立一个方向/consumer 的 packet mailbox。
    // 输入/输出：输入方向、consumer_id、深度；无返回值。
    // 边界/副作用：重复订阅不覆盖旧 mailbox；hub 未绑定时报告错误。
    extern function void subscribe(
        vio_packet_dir_e direction,
        int unsigned consumer_id = 0,
        int unsigned depth = 1024
    );

    // 功能：取出一个完整 VTX/RX 样本，不调用 sequence start。
    // 输入/输出：输出 packet；输入方向、consumer_id 和 timeout。
    // 边界/副作用：timeout=0 永久等待；未绑定或超时返回 null。
    extern task mon_xaction(
        output virtio_packet_sample packet,
        input vio_packet_dir_e direction,
        input int unsigned consumer_id = 0,
        input time timeout = 0
    );

    // 功能：解除一个方向/consumer 的订阅。
    // 输入/输出：输入方向和 consumer_id；无返回值。
    // 边界/副作用：丢弃该 consumer 尚未取出的副本，不影响其他 consumer。
    extern function void unsubscribe(
        vio_packet_dir_e direction,
        int unsigned consumer_id = 0
    );

    // 功能：采样 sequence 的空 body，防止误 start 时意外驱动 Virtio transaction。
    // 输入/输出：输入 UVM phase；无输出。
    // 边界/副作用：只等待一个 delta cycle，所有报文获取必须显式调用 mon_xaction。
    extern virtual task body();
endclass

function virtio_packet_seq::new(string name="virtio_packet_seq");
    super.new(name);
    ops = null;
    hub = null;
endfunction

function void virtio_packet_seq::bind_ops(virtio_atomic_ops candidate_ops);
    ops = candidate_ops;
    hub = (candidate_ops == null) ? null : candidate_ops.packet_hub;
endfunction

function void virtio_packet_seq::bind_function(virtio_function_instance instance);
    if ((instance == null) || (instance.driver_agent == null) ||
        (instance.driver_agent.ops == null)) begin
        `uvm_error("VIO_PACKET_SEQ", "cannot bind packet sequence to an unconfigured Function")
        return;
    end
    bind_ops(instance.driver_agent.ops);
endfunction

function void virtio_packet_seq::subscribe(
    vio_packet_dir_e direction,
    int unsigned consumer_id,
    int unsigned depth
);
    if (hub == null) begin
        `uvm_error("VIO_PACKET_SEQ", "subscribe requires a bound packet hub")
        return;
    end
    if (!hub.subscribe(direction, consumer_id, depth)) begin
        `uvm_error("VIO_PACKET_SEQ",
            $sformatf("packet consumer already subscribed direction=%0d id=%0d",
                      direction, consumer_id))
    end
endfunction

task virtio_packet_seq::mon_xaction(
    output virtio_packet_sample packet,
    input vio_packet_dir_e direction,
    input int unsigned consumer_id,
    input time timeout
);
    packet = null;
    if (hub == null) return;
    hub.mon_xaction(packet, direction, consumer_id, timeout);
endtask

function void virtio_packet_seq::unsubscribe(
    vio_packet_dir_e direction,
    int unsigned consumer_id
);
    if (hub != null) void'(hub.unsubscribe(direction, consumer_id));
endfunction

task virtio_packet_seq::body();
    #0;
endtask

`endif
