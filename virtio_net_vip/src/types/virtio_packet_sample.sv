// =============================================================================
// virtio_packet_sample.sv
// 目录层次：virtio_net_vip/src/types；VIO 完整网络报文的只读采样值类型。
// 文件职责：统一保存 VTX/RX 的 Function、队列、Virtio header、Custom 控制和
// Ethernet payload，供 packet hub 与项目侧 RM/SCB 借用。它不拥有 DMA、ring 或
// UVM 组件；发布者在采样前填值，hub 通过 clone 取得独立副本。
// 主要依赖：virtio_net_types.sv、virtio_net_hdr.sv、DPU identity value types。
// 生命周期：每次发布创建一个样本，hub/sequence/sidecar 各自拥有副本；reset
// 不会复用旧样本，调用方应使用 reset_epoch 区分快照恢复前后的数据。
// =============================================================================

`ifndef VIRTIO_PACKET_SAMPLE_SV
`define VIRTIO_PACKET_SAMPLE_SV

typedef enum bit {
    VIO_PACKET_VTX,
    VIO_PACKET_VRX
} vio_packet_dir_e;

class virtio_packet_sample extends uvm_object;
    `uvm_object_utils(virtio_packet_sample)

    vio_packet_dir_e		direction;
    bit				identity_valid;
    dpu_function_key_t		function_key;
    dpu_service_key_t		service_key;
    int unsigned		host_id;
    bit [15:0]			bdf;
    bit				is_vf;
    int unsigned			vf_id;
    int unsigned			local_qid;
    int unsigned			global_qid;
    int unsigned			descriptor_id;
    int unsigned			buffer_count;
    longint unsigned		packet_sequence;
    longint unsigned		reset_epoch;
    bit				key_valid;
    string			packet_key;
    virtio_net_hdr_t		net_hdr;
    vio_private_tx_offload_t	private_offload;
    byte unsigned			frame_bytes[$];

    // 功能：创建空采样值，不分配外部资源。
    // 输入/输出：输入 UVM 名称；输出为新对象。
    // 边界/副作用：所有字段清零，空 frame/key 由调用方在发布前补齐。
    extern function new(string name="virtio_packet_sample");

    // 功能：深拷贝采样值，隔离 producer 的队列和 sidecar 的修改。
    // 输入/输出：输入源样本；无返回值。
    // 边界/副作用：源为空时保持当前对象不变；不复制任何 hub/mailbox 句柄。
    extern function void copy_from(virtio_packet_sample source);

    // 功能：返回 hub/SCB 可用于诊断和 stream 组合的稳定身份字符串。
    // 输入/输出：无输入；返回方向、Host、BDF、Function 和队列组成的字符串。
    // 边界/副作用：不包含 packet_key；同一 stream 内的 packet_key 单独匹配。
    extern function string stream_key();

    // 功能：生成不含方向的 flow stream ID，供同一 Function 的 VTX/RX 乱序比较。
    // 输入/输出：无输入；返回 64-bit FNV-1a 风格 hash。
    // 边界/副作用：Hash 只用于 stream 分桶，真正的报文身份仍由 packet_key 提供；
    // 极小概率碰撞由上层可通过自定义 stream_id 规避。
    extern function longint unsigned flow_stream_id();

    // 功能：判断样本是否可直接进入 keyed SCB。
    // 输入/输出：无输入；返回 key_valid 且 key 非空。
    // 边界/副作用：不根据 descriptor 或 payload hash 猜测报文身份。
    extern function bit has_packet_key();

    // 功能：比较完整 payload、Virtio header、Custom 控制和基本元数据。
    // 输入/输出：输入 actual 样本、输出差异字符串和比较 kind；返回是否一致。
    // 边界/副作用：packet_key 不在此重复比较，keyed SCB 已用它选择匹配项；
    // 长度或任一字节不同立即失败并给出首个差异位置。
    extern virtual function bit self_define_do_compare(
        virtio_packet_sample actual,
        output string diff,
        input int kind = -1
    );

    // 功能：为 hub 生成深拷贝对象。
    // 输入/输出：无输入；返回独立的 virtio_packet_sample。
    // 边界/副作用：复制 payload/header/身份值，不共享动态队列。
    extern virtual function uvm_object clone();
endclass

function virtio_packet_sample::new(string name="virtio_packet_sample");
    super.new(name);
    direction        = VIO_PACKET_VTX;
    identity_valid   = 0;
    host_id          = 0;
    bdf              = '0;
    is_vf            = 0;
    vf_id            = 0;
    local_qid        = 0;
    global_qid       = 0;
    descriptor_id    = '1;
    buffer_count     = 0;
    packet_sequence  = 0;
    reset_epoch      = 0;
    key_valid        = 0;
    packet_key       = "";
    net_hdr          = '{default:0};
    private_offload  = '{default:0};
endfunction

function void virtio_packet_sample::copy_from(virtio_packet_sample source);
    if (source == null) return;
    direction       = source.direction;
    identity_valid  = source.identity_valid;
    function_key    = source.function_key;
    service_key     = source.service_key;
    host_id         = source.host_id;
    bdf             = source.bdf;
    is_vf           = source.is_vf;
    vf_id           = source.vf_id;
    local_qid        = source.local_qid;
    global_qid      = source.global_qid;
    descriptor_id   = source.descriptor_id;
    buffer_count    = source.buffer_count;
    packet_sequence = source.packet_sequence;
    reset_epoch     = source.reset_epoch;
    key_valid       = source.key_valid;
    packet_key      = source.packet_key;
    net_hdr         = source.net_hdr;
    private_offload = source.private_offload;
    frame_bytes     = source.frame_bytes;
endfunction

function string virtio_packet_sample::stream_key();
    string dir_name;
    dir_name = (direction == VIO_PACKET_VTX) ? "vtx" : "vrx";
    return $sformatf(
        "%s.h%0d.bdf%04h.pf%0d.vf%0d.q%0d.gq%0d",
        dir_name,
        host_id,
        bdf,
        function_key.pf_id,
        (is_vf ? vf_id : 0),
        local_qid,
        global_qid
    );
endfunction

function longint unsigned virtio_packet_sample::flow_stream_id();
    string text;
    longint unsigned hash;

    text = $sformatf(
        "h%0d.bdf%04h.pf%0d.vf%0d.q%0d.gq%0d",
        host_id,
        bdf,
        function_key.pf_id,
        (is_vf ? vf_id : 0),
        local_qid,
        global_qid
    );
    hash = 64'hcbf29ce484222325;
    for (int i = 0; i < text.len(); i++) begin
        hash ^= byte'(text[i]);
        hash *= 64'h00000100000001b3;
    end
    return hash;
endfunction

function bit virtio_packet_sample::has_packet_key();
    return key_valid && (packet_key.len() != 0);
endfunction

function bit virtio_packet_sample::self_define_do_compare(
    virtio_packet_sample actual,
    output string diff,
    input int kind = -1
);
    diff = "";
    if (actual == null) begin
        diff = "actual packet sample is null";
        return 0;
    end
    if (direction != actual.direction) begin
        diff = $sformatf("direction expected=%0d actual=%0d",
                         direction, actual.direction);
        return 0;
    end
    if ((local_qid != actual.local_qid) ||
        (global_qid != actual.global_qid) ||
        (buffer_count != actual.buffer_count)) begin
        diff = $sformatf("queue/buffer metadata expected lq=%0d gq=%0d buffers=%0d actual lq=%0d gq=%0d buffers=%0d",
            local_qid, global_qid, buffer_count,
            actual.local_qid, actual.global_qid, actual.buffer_count
        );
        return 0;
    end
    if (net_hdr !== actual.net_hdr) begin
        diff = "virtio_net_hdr differs";
        return 0;
    end
    if (private_offload !== actual.private_offload) begin
        diff = "private offload control differs";
        return 0;
    end
    if (frame_bytes.size() != actual.frame_bytes.size()) begin
        diff = $sformatf("payload length expected=%0d actual=%0d",
                         frame_bytes.size(), actual.frame_bytes.size());
        return 0;
    end
    foreach (frame_bytes[i]) begin
        if (frame_bytes[i] !== actual.frame_bytes[i]) begin
            diff = $sformatf("payload byte[%0d] expected=0x%02x actual=0x%02x",
                             i, frame_bytes[i], actual.frame_bytes[i]);
            return 0;
        end
    end
    return 1;
endfunction

function uvm_object virtio_packet_sample::clone();
    virtio_packet_sample copy;
    copy = new(get_name());
    copy.copy_from(this);
    return copy;
endfunction

`endif
