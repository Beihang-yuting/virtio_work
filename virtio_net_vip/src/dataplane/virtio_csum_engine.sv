`ifndef VIRTIO_CSUM_ENGINE_SV
`define VIRTIO_CSUM_ENGINE_SV

// ============================================================================
// virtio_csum_engine
//
// Checksum offload engine for virtio-net. Provides TX csum_start/csum_offset
// derivation and RX full L4 checksum verification. Parses Ethernet/IP/TCP/UDP
// headers from raw packet bytes.
//
// Standard header layout assumed:
//   Ethernet: dst(6) + src(6) + ethertype(2) = 14 bytes (+4 if VLAN 0x8100)
//   IPv4: IHL*4 bytes, protocol at offset 9
//   IPv6: 40 bytes fixed, next_header at offset 6
//   TCP: checksum at offset 16, data_offset at byte 12 high nibble
//   UDP: checksum at offset 6, length at offset 4
// ============================================================================

class virtio_csum_engine extends uvm_object;
    `uvm_object_utils(virtio_csum_engine)

    // ETH header constants
    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;

    // L4 protocol numbers
    localparam int unsigned IPPROTO_TCP = 6;
    localparam int unsigned IPPROTO_UDP = 17;

    // L4 checksum field offsets within L4 header
    localparam int unsigned TCP_CSUM_OFFSET = 16;
    localparam int unsigned UDP_CSUM_OFFSET = 6;

    // 构造函数：无状态引擎，仅 UVM 注册。
    function new(string name = "virtio_csum_engine");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------------
    // get_ethertype — determine L3 protocol from Ethernet header
    // Returns 0x0800 (IPv4) or 0x86DD (IPv6) or raw ethertype
    // Handles VLAN-tagged frames (0x8100)
    // ------------------------------------------------------------------------
    function bit [15:0] get_ethertype(byte unsigned pkt_data[$]);
        bit [15:0] etype;
        if (pkt_data.size() < ETH_HDR_LEN)
            return 16'h0000;
        etype = {pkt_data[12], pkt_data[13]};
        if (etype == ETHERTYPE_VLAN && pkt_data.size() >= ETH_HDR_LEN + VLAN_TAG_LEN)
            etype = {pkt_data[16], pkt_data[17]};
        return etype;
    endfunction

    // ------------------------------------------------------------------------
    // get_l3_hdr_len — L3 header length in bytes
    // IPv4: IHL field * 4
    // IPv6: fixed 40 bytes (extension headers not parsed)
    // ------------------------------------------------------------------------
    function int unsigned get_l3_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_len;
        bit [15:0] etype;
        bit [3:0] ihl;

        etype = get_ethertype(pkt_data);
        l2_len = (({pkt_data[12], pkt_data[13]} == ETHERTYPE_VLAN) ?
                  ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN);

        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() <= l2_len)
                return 20;
            ihl = pkt_data[l2_len][7:4];
            return (ihl < 5) ? 20 : ihl * 4;
        end else if (etype == ETHERTYPE_IPV6) begin
            return 40;
        end
        return 0;
    endfunction

    // ------------------------------------------------------------------------
    // get_l4_proto — determine L4 protocol number from IP header
    // IPv4: protocol field at IP offset 9
    // IPv6: next_header at IP offset 6
    // ------------------------------------------------------------------------
    function bit [7:0] get_l4_proto(byte unsigned pkt_data[$]);
        int unsigned l2_len;
        bit [15:0] etype;

        etype = get_ethertype(pkt_data);
        l2_len = (({pkt_data[12], pkt_data[13]} == ETHERTYPE_VLAN) ?
                  ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN);

        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() > l2_len + 9)
                return pkt_data[l2_len + 9];
        end else if (etype == ETHERTYPE_IPV6) begin
            if (pkt_data.size() > l2_len + 6)
                return pkt_data[l2_len + 6];
        end
        return 8'h00;
    endfunction

    // ------------------------------------------------------------------------
    // get_l4_offset — byte offset of L4 header start within packet
    // ------------------------------------------------------------------------
    function int unsigned get_l4_offset(byte unsigned pkt_data[$]);
        int unsigned l2_len;
        l2_len = (({pkt_data[12], pkt_data[13]} == ETHERTYPE_VLAN) ?
                  ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN);
        return l2_len + get_l3_hdr_len(pkt_data);
    endfunction

    // ------------------------------------------------------------------------
    // calc_csum_start — TX: L4 header start offset relative to packet start
    // This is what goes into virtio_net_hdr.csum_start
    // ------------------------------------------------------------------------
    function int unsigned calc_csum_start(byte unsigned pkt_data[$]);
        return get_l4_offset(pkt_data);
    endfunction

    // ------------------------------------------------------------------------
    // calc_csum_offset — TX: checksum field offset within L4 header
    // TCP: 16, UDP: 6
    // This is what goes into virtio_net_hdr.csum_offset
    // ------------------------------------------------------------------------
    function int unsigned calc_csum_offset(byte unsigned pkt_data[$]);
        bit [7:0] proto;
        proto = get_l4_proto(pkt_data);
        if (proto == IPPROTO_TCP)
            return TCP_CSUM_OFFSET;
        else if (proto == IPPROTO_UDP)
            return UDP_CSUM_OFFSET;
        return 0;
    endfunction

    // ------------------------------------------------------------------------
    // ones_complement_sum — compute 16-bit ones-complement sum over a
    // byte range. Folds any carry bits back into the low 16 bits.
    // ------------------------------------------------------------------------
    function bit [15:0] ones_complement_sum(byte unsigned data[$], int unsigned start, int unsigned len);
        bit [31:0] sum;
        int unsigned i;
        int unsigned end_pos;

        sum = 0;
        end_pos = start + len;
        if (end_pos > data.size())
            end_pos = data.size();

        for (i = start; i + 1 < end_pos; i += 2) begin
            sum += {data[i], data[i + 1]};
        end

        // Handle odd byte
        if (i < end_pos)
            sum += {data[i], 8'h00};

        // Fold carries
        while (sum >> 16)
            sum = sum[15:0] + sum[31:16];

        return sum[15:0];
    endfunction

    // ------------------------------------------------------------------------
    // verify_rx_csum — RX: verify full L4 checksum
    // Computes ones-complement sum over pseudo-header + entire L4 segment.
    // Result should be 0xFFFF if checksum is correct.
    // Returns 1 if valid, 0 if mismatch.
    // ------------------------------------------------------------------------
    function bit verify_rx_csum(
        virtio_net_hdr_t hdr,
        byte unsigned pkt_data[$]
    );
        bit [15:0] etype;
        int unsigned l2_len, l3_hdr_len, l4_off;
        bit [7:0] proto;
        byte unsigned verify_data[$];
        bit [15:0] result;
        int unsigned l4_len;
        int unsigned ip_total_len;

        etype = get_ethertype(pkt_data);
        l2_len = (({pkt_data[12], pkt_data[13]} == ETHERTYPE_VLAN) ?
                  ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN);
        l3_hdr_len = get_l3_hdr_len(pkt_data);
        l4_off = l2_len + l3_hdr_len;
        proto = get_l4_proto(pkt_data);

        // Calculate L4 length
        if (etype == ETHERTYPE_IPV4) begin
            ip_total_len = {pkt_data[l2_len + 2], pkt_data[l2_len + 3]};
            l4_len = ip_total_len - l3_hdr_len;
        end else begin
            l4_len = {pkt_data[l2_len + 4], pkt_data[l2_len + 5]};
        end

        // Build pseudo-header + L4 data for verification
        verify_data = {};

        if (etype == ETHERTYPE_IPV4) begin
            for (int i = 0; i < 4; i++)
                verify_data.push_back(pkt_data[l2_len + 12 + i]);
            for (int i = 0; i < 4; i++)
                verify_data.push_back(pkt_data[l2_len + 16 + i]);
            verify_data.push_back(8'h00);
            verify_data.push_back(proto);
            verify_data.push_back(l4_len[15:8]);
            verify_data.push_back(l4_len[7:0]);
        end else if (etype == ETHERTYPE_IPV6) begin
            for (int i = 0; i < 16; i++)
                verify_data.push_back(pkt_data[l2_len + 8 + i]);
            for (int i = 0; i < 16; i++)
                verify_data.push_back(pkt_data[l2_len + 24 + i]);
            verify_data.push_back(8'h00);
            verify_data.push_back(8'h00);
            verify_data.push_back(l4_len[15:8]);
            verify_data.push_back(l4_len[7:0]);
            verify_data.push_back(8'h00);
            verify_data.push_back(8'h00);
            verify_data.push_back(8'h00);
            verify_data.push_back(proto);
        end

        // Append L4 data (including checksum field)
        for (int unsigned i = l4_off; i < l4_off + l4_len && i < pkt_data.size(); i++)
            verify_data.push_back(pkt_data[i]);

        // Pad to even length
        if (verify_data.size() % 2 != 0)
            verify_data.push_back(8'h00);

        result = ones_complement_sum(verify_data, 0, verify_data.size());

        // Valid checksum yields 0xFFFF
        return (result == 16'hFFFF);
    endfunction

endclass : virtio_csum_engine

`endif // VIRTIO_CSUM_ENGINE_SV
