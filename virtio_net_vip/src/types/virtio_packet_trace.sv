// src/types：VIO wire trace 的唯一编号分配与 payload 尾部 20B 标记编解码。
// 依赖 virtio_packet_sample；registry 仅保留身份副本和各流递增序号，不持有 DMA。
// 全仿真共用一份注册表，快照保存其状态；复位后的 epoch 形成新流，旧 ID 不回收，
// 因而迟到包不会误匹配新报文。开启 checker 的 Function 才会把 tail 写入 payload。
`ifndef VIRTIO_PACKET_TRACE_SV
`define VIRTIO_PACKET_TRACE_SV

// 显式双向映射代替截断 hash；序号在发包端产生，接收端只解析，支持实际包先到。
class virtio_packet_trace;
    local static int unsigned		m_next_id = 1;
    local static bit [15:0]		m_ids[string];
    local static virtio_packet_sample	m_streams[bit [15:0]];
    local static longint unsigned	m_sequences[bit [15:0]];

    // 为身份注册流并分配一个报文序号，把 tail 写入 payload 尾部，同时填充 sample。
    // 空身份、payload 不足、超长帧或 16bit ID 耗尽返回 why，不修改报文字节；
    // 同一身份重复注册幂等。重新组包保持最终 Ethernet 帧长度不变。
    extern static function bit stamp(
        input virtio_packet_sample	sample,
        ref byte unsigned		bytes[$],
        output string			why
    );

    // 校验 tail 后恢复身份/序号；失败 sample=null，不用损坏的 ID/序号猜匹配关系。
    // 输入为无 preamble/FCS 的完整 Ethernet 帧，返回的新样本由调用者持有。
    extern static function bit decode(
        input byte unsigned		bytes[$],
        input vio_packet_dir_e		direction,
        output virtio_packet_sample	sample,
        output string			why
    );

    // Locate the trace before any protocol trailer (for example RoCE ICRC).
    // The returned offset is the first byte of the 20B trace.
    extern static function bit locate(
        input byte unsigned		bytes[$],
        output int			base,
        output string			why
    );

    // CRC-16/CCITT-FALSE：poly=1021、init=ffff、不反射、xorout=0；仅覆盖给定字节。
    // tail 前 18B 使用此 CRC，原始 payload 的正确性由 SCB 逐字节判断。
    extern static function bit [15:0] crc16(input byte unsigned	bytes[$]);
endclass

// 注册时复制身份并清空 frame，避免 registry 随累计包数保留大报文。
function bit virtio_packet_trace::stamp(
    input virtio_packet_sample	sample,
    ref byte unsigned		bytes[$],
    output string		why
);
    string			key;
    bit [15:0]			id;
    bit [15:0]			crc;
    byte unsigned		tail[$];
    byte unsigned		payload[$];
    byte unsigned		original[$];
    packet			parsed;
    virtio_packet_sample	identity;
    int				header_length;
    int				trailer_length;
    int				payload_length;

    why = "";
    if (sample == null || !sample.identity_valid) begin
        why = "trace requires a configured Function/queue identity";
        return 0;
    end
    if (bytes.size() > 65535) begin
        why = "trace frame_length exceeds 16 bits";
        return 0;
    end

    // Trace bytes live in existing payload space. Parse first so a protocol
    // trailer such as RoCE ICRC is never overwritten.
    parsed = new();
    parsed.unpack(bytes);
    if (parsed.layer_stack.size() == 0) begin
        why = "trace requires a parseable Ethernet frame";
        return 0;
    end
    header_length  = parsed.get_all_headers_length();
    trailer_length = parsed.get_all_trailers_length();
    payload_length = bytes.size() - header_length - trailer_length;
    if (payload_length < 20) begin
        why = $sformatf(
            "trace requires at least 20B payload (frame=%0d headers=%0d trailers=%0d)",
            bytes.size(), header_length, trailer_length);
        return 0;
    end

    key = sample.flow_key();
    if (!m_ids.exists(key)) begin
        if (m_next_id > 65535) begin
            why = "trace stream_id space exhausted (65535 streams)";
            return 0;
        end
        id = m_next_id++;
        identity = new("trace_identity");
        identity.copy_from(sample);
        identity.stream_id = id;
        identity.frame_bytes.delete();
        m_ids[key]       = id;
        m_streams[id]    = identity;
        m_sequences[id]  = 0;
`ifdef AIP_CMDLINE_SV
        `aip_info(("[VIO_STREAM] %s epoch=%0d direction=%s",
            identity.identity_detail(), identity.reset_epoch, sample.direction.name()));
`else
        `uvm_info("VIO_STREAM", $sformatf("%s epoch=%0d direction=%s",
            identity.identity_detail(), identity.reset_epoch, sample.direction.name()), UVM_LOW)
`endif
    end
    id = m_ids[key];
    sample.stream_id       = id;
    sample.packet_sequence = m_sequences[id]++;
    sample.key_valid       = 1;
    sample.packet_key      = $sformatf("%016h", sample.packet_sequence);

    // 固定布局："VIO1"、version=1、flags[0]=方向、stream_id、sequence、帧长、CRC。
    // 所有多字节数值小端；方向分别有独立流号和序号，RX 不按到达顺序伪造 key。
    tail = '{8'h56, 8'h49, 8'h4f, 8'h31, 8'h01, byte'(sample.direction)};
    for (int	i = 0; i < 2; i++) tail.push_back(byte'(id >> (8*i)));
    for (int	i = 0; i < 8; i++)
        tail.push_back(byte'(sample.packet_sequence >> (8*i)));
    for (int	i = 0; i < 2; i++) tail.push_back(byte'(bytes.size() >> (8*i)));
    crc = crc16(tail);
    tail.push_back(crc[7:0]);
    tail.push_back(crc[15:8]);
    // Replace only the last 20B of payload, then let net_packet rebuild all
    // derived headers and checksums. The resulting frame remains same-sized.
    original = bytes;
    for (int i = 0; i < payload_length; i++)
        payload.push_back(original[header_length + i]);
    for (int i = 0; i < 20; i++)
        payload[payload_length - 20 + i] = tail[i];

    parsed.pkt_len         = original.size();
    parsed.payload_mode    = PAYLOAD_PATTERN;
    parsed.payload_pattern = payload;
    parsed.do_pack();
    if (parsed.raw_data.size() != original.size()) begin
        why = $sformatf(
            "trace reassembly changed frame length from %0d to %0d",
            original.size(), parsed.raw_data.size());
        return 0;
    end
    bytes = parsed.raw_data;
    sample.frame_bytes = bytes;
    return 1;
endfunction

function bit virtio_packet_trace::locate(
    input byte unsigned		bytes[$],
    output int			base,
    output string			why
);
    packet parsed;
    int header_length;
    int trailer_length;

    base = -1;
    why  = "";
    if (bytes.size() < 20) begin
        why = "frame shorter than 20B trace tail";
        return 0;
    end
    parsed = new();
    parsed.unpack(bytes);
    if (parsed.layer_stack.size() == 0) begin
        why = "trace requires a parseable Ethernet frame";
        return 0;
    end
    header_length  = parsed.get_all_headers_length();
    trailer_length = parsed.get_all_trailers_length();
    base = bytes.size() - trailer_length - 20;
    if (base < header_length) begin
        base = -1;
        why = $sformatf(
            "trace has no 20B payload region (frame=%0d headers=%0d trailers=%0d)",
            bytes.size(), header_length, trailer_length);
        return 0;
    end
    return 1;
endfunction

// 必须先完成长度、magic、版本、CRC、方向和 ID 校验，再借用 registry 身份。
function bit virtio_packet_trace::decode(
    input byte unsigned		bytes[$],
    input vio_packet_dir_e	direction,
    output virtio_packet_sample	sample,
    output string		why
);
    byte unsigned	tail[$];
    bit [15:0]		id;
    bit [15:0]		length;
    bit [15:0]		crc;
    int			base;

    sample = null;
    why    = "";
    if (!locate(bytes, base, why))
        return 0;
    for (int	i = 0; i < 18; i++) tail.push_back(bytes[base+i]);
    if ({tail[0], tail[1], tail[2], tail[3]} != 32'h56494f31)
        why = "bad trace magic (expected VIO1)";
    else if (tail[4] != 1)
        why = $sformatf("unsupported trace version=%0d", tail[4]);
    else if (tail[5] != byte'(direction))
        why = $sformatf("trace direction/flags=%02h expected=%02h", tail[5], direction);
    crc = {bytes[base+19], bytes[base+18]};
    if (why == "" && crc != crc16(tail))
        why = $sformatf("bad trace crc stored=%04h calculated=%04h", crc, crc16(tail));
    length = {tail[17], tail[16]};
    if (why == "" && length != bytes.size())
        why = $sformatf("trace frame_length=%0d frame_length_actual=%0d",
                        length, bytes.size());
    id = {tail[7], tail[6]};
    if (why == "" && !m_streams.exists(id))
        why = $sformatf("unknown trace stream_id=0x%04h", id);
    if (why != "") return 0;
    if (m_streams[id].direction != direction) begin
        why = $sformatf("trace stream_id=0x%04h belongs to another direction", id);
        return 0;
    end

    sample = new("wire_packet");
    sample.copy_from(m_streams[id]);
    sample.packet_sequence = 0;
    for (int	i = 0; i < 8; i++)
        sample.packet_sequence |= longint'(tail[8+i]) << (8*i);
    sample.key_valid   = 1;
    sample.packet_key  = $sformatf("%016h", sample.packet_sequence);
    sample.frame_bytes = bytes;
    return 1;
endfunction

// 左移 CRC；bit[15:0] 赋值自然截断多项式计算的第 17 位。
function bit [15:0] virtio_packet_trace::crc16(input byte unsigned	bytes[$]);
    bit [15:0]	crc;

    crc = 16'hffff;
    foreach (bytes[i]) begin
        crc ^= {bytes[i], 8'h00};
        repeat (8)
            crc = crc[15] ? (crc << 1) ^ 16'h1021 : crc << 1;
    end
    return crc;
endfunction

`endif
