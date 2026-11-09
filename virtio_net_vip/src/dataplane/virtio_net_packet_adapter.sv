`ifndef VIRTIO_NET_PACKET_ADAPTER_SV
`define VIRTIO_NET_PACKET_ADAPTER_SV

// 中文说明：net_packet 适配层负责真实字节流转换及每包 TX offload 准备。
// packet_item.do_pack() 是 UVM 序列化格式，包含 32-bit 长度字段；virtio
// descriptor 中必须放 packet.pkt.raw_data，因此这里明确绕过 UVM framing。
// 主要依赖：UVM uvm_object 与项目外 net_packet 的 packet_item/packet payload。
// 所有权：不接管调用方 packet；prepare_tx 只修改发送字节副本，原始 packet 可用于比对。
// 协议层和头长度复用 net_packet parser；标准/Custom 编码由同一次解析结果派生。
// 生命周期：纯静态转换，无共享运行态；unpack 创建的 packet_item 由调用方持有。
class virtio_net_packet_adapter extends uvm_object;
    `uvm_object_utils(virtio_net_packet_adapter)

    // 按实际发送字节生成 header/Custom 控制，并写入 L4 partial-checksum seed。
    // 输入是本包参数和目标 Function 能力；失败不发布描述符，原因通过 why 返回。
    // 普通 IPv4/IPv6 TCP/UDP（含 VLAN/options）共用 parser；隧道和分片不隐式推断。
    extern static function bit prepare_tx(
        ref byte unsigned	data[$],
        input virtio_tx_offload_t	request,
        input bit	private_format,
        input bit [63:0]	features,
        output virtio_net_hdr_t	hdr,
        output vio_private_tx_offload_t	private_control,
        output string	why
    );

    // 创建无状态工具对象，不分配 packet 或 payload。
    function new(string name = "virtio_net_packet_adapter");
        super.new(name);
    endfunction

    // 接口契约：输入 pkt 必须可转换为 packet_item；输出 raw_data 先清空再写入
    // packet.pkt.raw_data。null/类型错误/空 payload 返回 0；空 raw_data 时可能调用
    // pkt.do_pack()，因此会有修改输入 packet 缓存的副作用，但不包含 UVM framing。
    // 将 net_packet packet_item 转换为真实 Ethernet 线速字节流。
    static function bit pack(
        input uvm_object pkt,
        ref byte unsigned raw_data[$]
    );
        packet_item item;

        raw_data.delete();
        if ((pkt == null) || !$cast(item, pkt) || (item.pkt == null))
            return 0;
        if (item.pkt.raw_data.size() == 0)
            item.pkt.do_pack();
        foreach (item.pkt.raw_data[i])
            raw_data.push_back(item.pkt.raw_data[i]);
        return raw_data.size() != 0;
    endfunction

    // 接口契约：输入 raw_data 为空时返回 0 且不保证 item 被初始化；成功时创建新的
    // packet_item/pkt 并复制线速 bytes，item 由调用方接管。unpack 尺寸不一致时返回 0。
    // 从设备写回的真实线速字节流解析出 net_packet packet_item。
    static function bit unpack(
        input byte unsigned raw_data[$],
        ref packet_item item
    );
        if (raw_data.size() == 0)
            return 0;
        item = packet_item::type_id::create("net_packet_rx_item");
        item.pkt = new();
        item.pkt.unpack(raw_data);
        return item.pkt.raw_data.size() == raw_data.size();
    endfunction

    // 接口契约：按 pack 后的 raw_data 长度和每字节内容比较；null、无法 pack 或尺寸
    // 不同返回 0。调用 pack 可能触发输入 packet 的 do_pack()，本函数不改变 payload
    // 所有权，也不使用 packet_item.do_compare()。
    // 比较线速字节流，避免 packet_item.do_compare() 丢失 payload/raw_data。
    static function bit compare(
        input uvm_object expected,
        input uvm_object actual
    );
        byte unsigned expected_data[$];
        byte unsigned actual_data[$];

        if (!pack(expected, expected_data) || !pack(actual, actual_data))
            return 0;
        if (expected_data.size() != actual_data.size())
            return 0;
        foreach (expected_data[i]) begin
            if (expected_data[i] != actual_data[i])
                return 0;
        end
        return 1;
    endfunction
endclass : virtio_net_packet_adapter

function bit virtio_net_packet_adapter::prepare_tx(
    ref byte unsigned	data[$],
    input virtio_tx_offload_t	request,
    input bit	private_format,
    input bit [63:0]	features,
    output virtio_net_hdr_t	hdr,
    output vio_private_tx_offload_t	private_control,
    output string	why
);
    protocol_parser	parser;
    packet		parsed;
    ipv4_header		ip4;
    ipv6_header		ip6;
    byte unsigned	pseudo[$];
    int unsigned	offset;
    int unsigned	ip_offset;
    int unsigned	l4_offset;
    int unsigned	l4_length;
    int unsigned	ip_count;
    int unsigned	packet_end;
    int unsigned	l4_bytes;
    int unsigned	payload_bytes;
    int unsigned	gso_feature;
    bit			is_tcp;
    bit			found_l4;
    bit [15:0]		seed;

    hdr             = '{default:0};
    private_control = '0;
    private_control.valid = request.valid;
    why             = "";

    if (!request.csum && !request.gso)
        return 1;

    parser = new();
    parsed = parser.parse(data);
    offset = 0;
    ip_count = 0;
    found_l4 = 0;

    // 从实际层顺序累计偏移，到目标 L4 截止；应用层头不计入 GSO hdr_len。
    foreach (parsed.layer_stack[i]) begin
        if (parsed.layer_stack[i].proto_type inside {PROTO_IPV4, PROTO_IPV6}) begin
            ip_count++;
            ip_offset = offset;
        end
        if (!found_l4 && parsed.layer_stack[i].proto_type inside {PROTO_TCP, PROTO_UDP}) begin
            found_l4 = 1;
            is_tcp = parsed.layer_stack[i].proto_type == PROTO_TCP;
            l4_offset = offset;
            l4_length = parsed.layer_stack[i].get_header_length();
        end
        offset += parsed.layer_stack[i].get_header_length();
    end

    ip4 = parsed.get_ipv4();
    ip6 = parsed.get_ipv6();
    if (ip_count != 1 || !found_l4 || l4_offset <= ip_offset) begin
        why = "TX offload requires one IPv4/IPv6 TCP/UDP datagram";
        return 0;
    end
    if (ip4 != null && (ip4.fragment_offset != 0 || ip4.flags[0])) begin
        why = "TX offload requires an unfragmented IPv4 datagram";
        return 0;
    end
    if (ip6 != null && !(ip6.next_header inside {8'd6, 8'd17})) begin
        why = "TX offload currently requires IPv6 without extension headers";
        return 0;
    end

    packet_end = ip_offset + ((ip4 != null) ? ip4.total_length : 40 + ip6.payload_length);
    if (packet_end > data.size() || l4_offset + l4_length > packet_end ||
        l4_length < (is_tcp ? 20 : 8)) begin
        why = "TX offload packet/header lengths are inconsistent";
        return 0;
    end
    if (!private_format && !features[VIRTIO_NET_F_CSUM]) begin
        why = "TX checksum requires VIRTIO_NET_F_CSUM on the selected Function";
        return 0;
    end

    l4_bytes = packet_end - l4_offset;
    payload_bytes = l4_bytes - l4_length;
    hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
    hdr.csum_start = l4_offset;
    hdr.csum_offset = is_tcp ? 16 : 6;
    // txrx.c 的 dpu_tx_csum/dpu_tx_tso 对 IPv4/IPv6 都置四个校验使能位；
    // 私有硬件再按协议解释，不在这里把 IPv6 的 l3/i_l3 位清掉。
    private_control.l3_cs = 1;
    private_control.l4_cs = 1;

    if (request.gso) begin
        if (request.mss == 0) begin
            why = "TX GSO requires a positive MSS";
            return 0;
        end
        gso_feature = is_tcp ? ((ip4 != null) ? VIRTIO_NET_F_HOST_TSO4 :
                       VIRTIO_NET_F_HOST_TSO6) : VIRTIO_NET_F_HOST_USO;
        if (!private_format && !features[gso_feature]) begin
            why = "TX GSO protocol is not enabled on the selected Function";
            return 0;
        end
        if (payload_bytes > request.mss) begin
            hdr.gso_type = is_tcp ? ((ip4 != null) ? VIRTIO_NET_HDR_GSO_TCPV4 :
                           VIRTIO_NET_HDR_GSO_TCPV6) : VIRTIO_NET_HDR_GSO_UDP_L4;
            hdr.gso_size = request.mss;
            hdr.hdr_len = l4_offset + l4_length;
            private_control.tso = 1;
        end
    end

    // 驱动扩展描述符的长度单位分别为2B/4B/4B，MSS仅14位；编码前检查。
    if (private_format && private_control.tso) begin
        if (request.mss > 16383 || ip_offset > 62 || (ip_offset % 2) != 0 ||
            l4_offset - ip_offset > 124 || ((l4_offset - ip_offset) % 4) != 0 ||
            l4_length > 60 || (l4_length % 4) != 0) begin
            why = "Custom TSO header lengths or MSS exceed descriptor fields";
            return 0;
        end
        private_control.extension[4:0]   = ip_offset / 2;
        private_control.extension[9:5]   = (l4_offset - ip_offset) / 4;
        private_control.extension[13:10] = l4_length / 4;
        private_control.extension[15:14] = is_tcp ? 1 : 2;
        private_control.extension[17:16] = (ip4 != null) ? 2 : 1;
        private_control.extension[31:18] = request.mss[13:0];
        // extend_type[35:32]=DPU_EXT_DESC_TSO(0)，其余隧道字段保持0。
    end

    // CHECKSUM_PARTIAL 的字段保存伪首部折叠和（不取反），设备补上L4头和payload。
    // 只改发送副本；之后禁止重新 do_pack，以免重算 checksum 或重新随机 payload。
    if (ip4 != null) begin
        packet_utils::pack_bytes_32(pseudo, ip4.src_addr);
        packet_utils::pack_bytes_32(pseudo, ip4.dst_addr);
        pseudo.push_back(0);
        pseudo.push_back(is_tcp ? 6 : 17);
        pseudo.push_back(l4_bytes[15:8]);
        pseudo.push_back(l4_bytes[7:0]);
    end else begin
        for (int i = 15; i >= 0; i--)
            pseudo.push_back(ip6.src_addr[i*8 +: 8]);
        for (int i = 15; i >= 0; i--)
            pseudo.push_back(ip6.dst_addr[i*8 +: 8]);
        packet_utils::pack_bytes_32(pseudo, l4_bytes);
        repeat (3) pseudo.push_back(0);
        pseudo.push_back(is_tcp ? 6 : 17);
    end
    seed = ~packet_utils::ones_complement_checksum(pseudo);
    data[l4_offset + hdr.csum_offset]     = seed[15:8];
    data[l4_offset + hdr.csum_offset + 1] = seed[7:0];
    return 1;
endfunction

`endif
