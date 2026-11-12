// =============================================================================
// virtio_packet_sample.sv
// 目录层次：virtio_net_vip/src/types；VIO 完整网络报文的只读采样值类型。
// 文件职责：统一保存 VTX/RX 的 Function、队列、Virtio header、Custom 控制和
// Ethernet payload，供 packet hub 与项目侧 RM/SCB 借用。它不拥有 DMA、ring 或
// UVM 组件；发布者在采样前填值，hub 通过 clone 取得独立副本。
// 主要依赖：virtio_net_types.sv、virtio_net_hdr.sv、DPU identity value types，
// 以及 net_packet 的 packet/packet_comparator（只生成差异，不直接打印）。
// 生命周期：每次发布创建样本，hub/sequence/sidecar 各自持有副本；trace registry
// 用 reset_epoch 隔离复位前后的流。比较仅针对 frame_bytes，不比较内部 Virtio 元数据。
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
    int unsigned		vf_id;
    int unsigned		local_qid;
    int unsigned		global_qid;
    int unsigned		descriptor_id;
    int unsigned		buffer_count;
    longint unsigned		packet_sequence;
    longint unsigned		reset_epoch;
    // trace registry 为整个仿真分配唯一编号；0 表示未加 trace tail。
    bit [15:0]			stream_id;
    bit				key_valid;
    string			packet_key;
    virtio_net_hdr_t		net_hdr;
    vio_private_tx_offload_t	private_offload;
    byte unsigned		frame_bytes[$];

    // 功能：创建空采样值，不分配外部资源。
    // 输入/输出：输入 UVM 名称；输出为新对象。
    // 边界/副作用：身份默认无效、descriptor_id='1；frame/key 由调用方在发布前补齐。
    extern function new(string	name="virtio_packet_sample");

    // 功能：深拷贝采样值，隔离 producer 的队列和 sidecar 的修改。
    // 输入/输出：输入源样本；无返回值。
    // 边界/副作用：源为空时保持当前对象不变；不复制任何 hub/mailbox 句柄。
    extern function void copy_from(virtio_packet_sample	source);

    // 功能：返回包含方向的稳定流描述。
    // 输入/输出：无输入；返回 reset epoch、Function 和队列身份组成的字符串。
    // 边界/副作用：只用于显式 stream registry 的关联，不产生哈希碰撞。
    extern function string flow_key();

    // 功能：返回供错误日志使用的 Function/队列摘要。
    // 输入/输出：无输入；返回可读字符串。
    // 边界/副作用：只读，不改变样本。
    extern function string identity_detail();

    // 功能：比较完整 Ethernet wire frame，并生成有限诊断信息。
    // 输入/输出：输入 actual 样本、输出差异字符串和比较 kind；返回是否一致。
    // 边界/副作用：packet_key/stream_id 已由 checker 选择匹配项；Virtio header、
    // descriptor 和队列元数据只用于定位，不作为 Ethernet wire 比较内容。
    extern virtual function bit self_define_do_compare(
        virtio_packet_sample	actual,
        output string		diff,
        input int		kind = -1
    );

    // 功能：生成首个字节差异、有限窗口和 net_packet 字段差异。
    // 输入/输出：输入 actual 样本；返回诊断字符串。
    // 边界/副作用：不调用 net_packet 的 compare_and_print，避免绕过 AIP 日志限流。
    extern function string wire_diff(virtio_packet_sample	actual);

    // 功能：为 hub 生成深拷贝对象。
    // 输入/输出：无输入；返回独立的 virtio_packet_sample。
    // 边界/副作用：复制 payload/header/身份值，不共享动态队列。
    extern virtual function uvm_object clone();
endclass

function virtio_packet_sample::new(string	name="virtio_packet_sample");
    super.new(name);
    direction        = VIO_PACKET_VTX;
    identity_valid   = 0;
    function_key     = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
    service_key      = '{function_key:function_key,
                         service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
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
    stream_id        = 0;
    key_valid        = 0;
    packet_key       = "";
    net_hdr          = '{default:0};
    private_offload  = '{default:0};
endfunction

function void virtio_packet_sample::copy_from(virtio_packet_sample	source);
    if (source == null) return;
    direction       = source.direction;
    identity_valid  = source.identity_valid;
    function_key    = source.function_key;
    service_key     = source.service_key;
    host_id         = source.host_id;
    bdf             = source.bdf;
    is_vf           = source.is_vf;
    vf_id           = source.vf_id;
    local_qid       = source.local_qid;
    global_qid      = source.global_qid;
    descriptor_id   = source.descriptor_id;
    buffer_count    = source.buffer_count;
    packet_sequence = source.packet_sequence;
    reset_epoch     = source.reset_epoch;
    stream_id       = source.stream_id;
    key_valid       = source.key_valid;
    packet_key      = source.packet_key;
    net_hdr         = source.net_hdr;
    private_offload = source.private_offload;
    frame_bytes     = source.frame_bytes;
endfunction

function string virtio_packet_sample::flow_key();
    return $sformatf(
        "dir=%0d.epoch=%0d.h%0d.bdf=%04h.pf=%0d.kind=%0d.vf=%0d.svc=%0d.%0d.lq=%0d.gq=%0d",
        direction,
        reset_epoch,
        host_id,
        bdf,
        function_key.pf_id,
        is_vf,
        (is_vf ? vf_id : 0),
        service_key.service_kind,
        service_key.service_instance_id,
        local_qid,
        global_qid
    );
endfunction

function string virtio_packet_sample::identity_detail();
    return $sformatf(
        "host=%0d bdf=%04h pf=%0d is_vf=%0b vf=%0d local_qid=%0d global_qid=%0d stream_id=0x%04h packet_sequence=%0d",
        host_id,
        bdf,
        function_key.pf_id,
        is_vf,
        (is_vf ? vf_id : 0),
        local_qid,
        global_qid,
        stream_id,
        packet_sequence
    );
endfunction

function bit virtio_packet_sample::self_define_do_compare(
    virtio_packet_sample	actual,
    output string		diff,
    input int			kind = -1
);
    diff = "";
    if (actual == null) begin
        diff = "actual packet sample is null";
        return 0;
    end
    if (frame_bytes.size() != actual.frame_bytes.size()) begin
        diff = $sformatf("expected_len=%0d actual_len=%0d",
                         frame_bytes.size(), actual.frame_bytes.size());
        return 0;
    end
    foreach (frame_bytes[i]) begin
        if (frame_bytes[i] !== actual.frame_bytes[i]) begin
            diff = $sformatf("first_diff=%0d expected_byte=%02x actual_byte=%02x",
                             i, frame_bytes[i], actual.frame_bytes[i]);
            return 0;
        end
    end
    return 1;
endfunction

function string virtio_packet_sample::wire_diff(
    virtio_packet_sample	actual
);
    packet		expected_packet;
    packet		actual_packet;
    packet		expected_layout;
    packet		actual_layout;
    packet_comparator	comparator;
    diff_entry_t	packet_diffs[$];
    byte unsigned	expected_data[$];
    byte unsigned	actual_data[$];
    string		expected_byte;
    string		actual_byte;
    string		result;
    string		expected_window;
    string		actual_window;
    int			first_diff;
    int			diff_count;
    int			min_length;
    int			window_start;
    int			window_end;
    int			expected_trace_base;
    int			actual_trace_base;
    byte unsigned	stripped[$];

    result = "";
    if (actual == null) return "actual packet sample is null";

    first_diff = -1;
    diff_count = 0;
    min_length = (frame_bytes.size() < actual.frame_bytes.size()) ?
                 frame_bytes.size() : actual.frame_bytes.size();
    for (int	i = 0; i < min_length; i++) begin
        if (frame_bytes[i] !== actual.frame_bytes[i]) begin
            if (first_diff < 0) first_diff = i;
            diff_count++;
        end
    end
    if (frame_bytes.size() != actual.frame_bytes.size()) begin
        if (first_diff < 0) first_diff = min_length;
        diff_count += (frame_bytes.size() > actual.frame_bytes.size()) ?
                      frame_bytes.size() - min_length :
                      actual.frame_bytes.size() - min_length;
    end

    result = $sformatf(
        "expected_len=%0d actual_len=%0d first_diff=%0d differing_bytes=%0d",
        frame_bytes.size(), actual.frame_bytes.size(), first_diff, diff_count
    );

    if (first_diff >= 0) begin
        expected_byte = first_diff < frame_bytes.size() ?
                        $sformatf("0x%02x", frame_bytes[first_diff]) : "<absent>";
        actual_byte   = first_diff < actual.frame_bytes.size() ?
                        $sformatf("0x%02x", actual.frame_bytes[first_diff]) : "<absent>";
        result = {result, $sformatf("\n  expected_byte=%s actual_byte=%s",
                                    expected_byte, actual_byte)};
        window_start = first_diff - 8;
        if (window_start < 0) window_start = 0;
        window_end = first_diff + 8;
        if (window_end >= frame_bytes.size() &&
            window_end >= actual.frame_bytes.size()) begin
            window_end = (frame_bytes.size() > actual.frame_bytes.size()) ?
                         frame_bytes.size() : actual.frame_bytes.size();
            window_end--;
        end
        expected_window = "";
        actual_window   = "";
        for (int	i = window_start; i <= window_end; i++) begin
            if (i < frame_bytes.size())
                expected_window = {expected_window,
                    $sformatf("%02x ", frame_bytes[i])};
            else
                expected_window = {expected_window, "-- "};
            if (i < actual.frame_bytes.size())
                actual_window = {actual_window,
                    $sformatf("%02x ", actual.frame_bytes[i])};
            else
                actual_window = {actual_window, "-- "};
        end
        result = {result,
            $sformatf("\n  window_offset=%0d\n  expected: %s\n  actual:   %s",
                      window_start, expected_window, actual_window)};
    end

    expected_data   = frame_bytes;
    actual_data     = actual.frame_bytes;
    // 协议解释不包含已验证的 payload 尾部 20B trace；原始字节扫描仍覆盖整个帧。
    // 每侧保留自己的长度，短包/损坏包不能通过解析或重打包变成正确报文。
    expected_layout = new();
    actual_layout   = new();
    expected_layout.unpack(expected_data);
    actual_layout.unpack(actual_data);
    if (stream_id != 0 && expected_data.size() >= 20) begin
        expected_trace_base = expected_data.size() - 20;
        if (expected_layout.layer_stack.size() != 0)
            expected_trace_base -= expected_layout.get_all_trailers_length();
        stripped.delete();
        for (int i = 0; i < expected_data.size(); i++)
            if (i < expected_trace_base || i >= expected_trace_base + 20)
                stripped.push_back(expected_data[i]);
        expected_data = stripped;
    end
    if (actual.stream_id != 0 && actual_data.size() >= 20) begin
        actual_trace_base = actual_data.size() - 20;
        if (actual_layout.layer_stack.size() != 0)
            actual_trace_base -= actual_layout.get_all_trailers_length();
        stripped.delete();
        for (int i = 0; i < actual_data.size(); i++)
            if (i < actual_trace_base || i >= actual_trace_base + 20)
                stripped.push_back(actual_data[i]);
        actual_data = stripped;
    end
    expected_packet = new();
    actual_packet   = new();
    expected_packet.unpack(expected_data);
    actual_packet.unpack(actual_data);
    comparator = new();
    comparator.compare(expected_packet, actual_packet, packet_diffs);
    if (packet_diffs.size() != 0) begin
        result = {result, "\n  net_packet:"};
        // 短值直接保留；VCS 对末端越界的 substr 会返回空串，不能无条件截取 96 字符。
        for (int	i = 0; i < packet_diffs.size() && i < 8; i++) begin
            result = {result, $sformatf("\n    %s.%s expect=%s actual=%s",
                packet_diffs[i].layer.name(),
                packet_diffs[i].field_name,
                (packet_diffs[i].val_a.len() > 96 ?
                 packet_diffs[i].val_a.substr(0, 95) : packet_diffs[i].val_a),
                (packet_diffs[i].val_b.len() > 96 ?
                 packet_diffs[i].val_b.substr(0, 95) : packet_diffs[i].val_b))};
        end
        if (packet_diffs.size() > 8)
            result = {result, $sformatf(";...(%0d more)",
                                      packet_diffs.size() - 8)};
    end
    return result;
endfunction

function uvm_object virtio_packet_sample::clone();
    virtio_packet_sample	copy;
    copy = new(get_name());
    copy.copy_from(this);
    return copy;
endfunction

`endif
