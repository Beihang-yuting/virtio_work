`ifndef VIRTIO_TSO_ENGINE_SV
`define VIRTIO_TSO_ENGINE_SV

// ============================================================================
// virtio_tso_engine
//
// GSO header-length helpers for TX offload decisions.  Computes the total
// ETH + IP + L4 header length of a TCP or UDP packet and decides whether its
// payload exceeds the MSS.  The VIP never segments packets itself: when
// HOST_TSO4/6 or HOST_USO is negotiated the device performs segmentation.
// 中文说明：只提供 TCP/UDP 的 GSO 头长度和“payload 是否超过 MSS”判断，供
// offload 引擎填写 virtio_net_hdr 的 gso_type/hdr_len；分段由设备完成。
// ============================================================================

class virtio_tso_engine extends uvm_object;
    `uvm_object_utils(virtio_tso_engine)

    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned UDP_HDR_LEN     = 8;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;

    // 构造函数：无状态引擎，仅 UVM 注册。
    function new(string name = "virtio_tso_engine");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------------
    // needs_tso — check if TCP payload exceeds MSS
    // ------------------------------------------------------------------------
    function bit needs_tso(byte unsigned pkt_data[$], int unsigned mss);
        int unsigned hdr_len;
        int unsigned payload_len;

        hdr_len = get_all_hdr_len(pkt_data);
        if (hdr_len == 0 || hdr_len >= pkt_data.size())
            return 0;

        payload_len = pkt_data.size() - hdr_len;
        return (payload_len > mss);
    endfunction

    // ------------------------------------------------------------------------
    // needs_uso — check if UDP payload exceeds MSS
    // ------------------------------------------------------------------------
    function bit needs_uso(byte unsigned pkt_data[$], int unsigned mss);
        int unsigned hdr_len;
        int unsigned payload_len;

        hdr_len = get_udp_all_hdr_len(pkt_data);
        if (hdr_len == 0 || hdr_len >= pkt_data.size())
            return 0;

        payload_len = pkt_data.size() - hdr_len;
        return (payload_len > mss);
    endfunction

    // ------------------------------------------------------------------------
    // get_l2_l3_hdr_len — ETH (+ one VLAN tag) + IPv4/IPv6 header length.
    // 中文：非 IPv4/IPv6 或长度不足时返回 0。
    // ------------------------------------------------------------------------
    protected function int unsigned get_l2_l3_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;

        if (pkt_data.size() < ETH_HDR_LEN)
            return 0;

        // L2 length
        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN && pkt_data.size() >= l2_len + 2)
            etype = {pkt_data[16], pkt_data[17]};

        // L3 length
        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() <= l2_len)
                return 0;
            ihl = pkt_data[l2_len][7:4];
            l3_len = (ihl < 5) ? 20 : ihl * 4;
        end else if (etype == ETHERTYPE_IPV6) begin
            l3_len = 40;
        end else begin
            return 0;
        end

        return l2_len + l3_len;
    endfunction

    // ------------------------------------------------------------------------
    // get_all_hdr_len — total header length (ETH + IP + TCP)
    // ------------------------------------------------------------------------
    function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned tcp_off;
        int unsigned l4_len;
        bit [3:0] data_offset;

        tcp_off = get_l2_l3_hdr_len(pkt_data);
        if (tcp_off == 0)
            return 0;

        // TCP data offset (header length)
        if (pkt_data.size() <= tcp_off + 12)
            return 0;

        data_offset = pkt_data[tcp_off + 12][7:4];
        l4_len = data_offset * 4;
        if (l4_len < 20)
            l4_len = 20;

        return tcp_off + l4_len;
    endfunction

    // ------------------------------------------------------------------------
    // get_udp_all_hdr_len — total header length (ETH + IP + UDP)
    // UDP header is always 8 bytes.
    // ------------------------------------------------------------------------
    function int unsigned get_udp_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_l3_len;

        l2_l3_len = get_l2_l3_hdr_len(pkt_data);
        if (l2_l3_len == 0)
            return 0;
        return l2_l3_len + UDP_HDR_LEN;
    endfunction

endclass : virtio_tso_engine

`endif // VIRTIO_TSO_ENGINE_SV
