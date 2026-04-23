`ifndef VIRTIO_USO_ENGINE_SV
`define VIRTIO_USO_ENGINE_SV

// ============================================================================
// virtio_uso_engine
//
// UDP Segmentation Offload engine (virtio 1.2+). Splits large UDP packets
// into MSS-sized segments. Each segment receives its own ETH + IP + UDP
// headers with appropriate field updates (IP total_length, UDP length).
// ============================================================================

class virtio_uso_engine extends uvm_object;
    `uvm_object_utils(virtio_uso_engine)

    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned UDP_HDR_LEN     = 8;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;

    function new(string name = "virtio_uso_engine");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------------
    // needs_uso — check if UDP payload exceeds MSS
    // ------------------------------------------------------------------------
    function bit needs_uso(byte unsigned pkt_data[$], int unsigned mss);
        int unsigned hdr_len;
        int unsigned payload_len;

        hdr_len = get_all_hdr_len(pkt_data);
        if (hdr_len == 0 || hdr_len >= pkt_data.size())
            return 0;

        payload_len = pkt_data.size() - hdr_len;
        return (payload_len > mss);
    endfunction

    // ------------------------------------------------------------------------
    // get_all_hdr_len — total header length (ETH + IP + UDP)
    // UDP header is always 8 bytes.
    // ------------------------------------------------------------------------
    function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;

        if (pkt_data.size() < ETH_HDR_LEN)
            return 0;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN && pkt_data.size() >= l2_len + 2)
            etype = {pkt_data[16], pkt_data[17]};

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

        return l2_len + l3_len + UDP_HDR_LEN;
    endfunction

    // ------------------------------------------------------------------------
    // segment — split large UDP packet into MSS-sized segments
    //
    // Each segment gets its own ETH + IP + UDP headers.
    // Per-segment updates:
    //   - IP total_length (IPv4) or payload_length (IPv6)
    //   - UDP length field = UDP_HDR_LEN + payload_chunk_size
    //   - IP checksum recalculated (IPv4 only)
    // Last segment may be smaller than MSS.
    // ------------------------------------------------------------------------
    function void segment(
        byte unsigned pkt_data[$],
        int unsigned  mss,
        ref byte unsigned segments[$][$]
    );
        int unsigned all_hdr_len;
        int unsigned payload_len;
        int unsigned num_segments;
        int unsigned seg_idx;
        int unsigned payload_off;
        int unsigned chunk_size;
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;
        int unsigned ip_total;
        int unsigned udp_len;

        all_hdr_len = get_all_hdr_len(pkt_data);
        if (all_hdr_len == 0 || all_hdr_len >= pkt_data.size()) begin
            segments = new[1];
            segments[0] = pkt_data;
            return;
        end

        payload_len = pkt_data.size() - all_hdr_len;
        if (payload_len <= mss) begin
            segments = new[1];
            segments[0] = pkt_data;
            return;
        end

        num_segments = (payload_len + mss - 1) / mss;
        segments = new[num_segments];

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;
        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            ihl = pkt_data[l2_len][7:4];
            l3_len = (ihl < 5) ? 20 : ihl * 4;
        end else begin
            l3_len = 40;
        end

        payload_off = 0;
        for (seg_idx = 0; seg_idx < num_segments; seg_idx++) begin
            byte unsigned seg[$];

            chunk_size = (payload_off + mss <= payload_len) ?
                         mss : (payload_len - payload_off);

            // Copy all headers
            seg = {};
            for (int unsigned i = 0; i < all_hdr_len; i++)
                seg.push_back(pkt_data[i]);

            // Append payload chunk
            for (int unsigned i = 0; i < chunk_size; i++)
                seg.push_back(pkt_data[all_hdr_len + payload_off + i]);

            // Update IP total length
            ip_total = l3_len + UDP_HDR_LEN + chunk_size;
            if (etype == ETHERTYPE_IPV4) begin
                seg[l2_len + 2] = ip_total[15:8];
                seg[l2_len + 3] = ip_total[7:0];
            end else if (etype == ETHERTYPE_IPV6) begin
                // IPv6 payload length
                int unsigned pld_len;
                pld_len = UDP_HDR_LEN + chunk_size;
                seg[l2_len + 4] = pld_len[15:8];
                seg[l2_len + 5] = pld_len[7:0];
            end

            // Update UDP length (at L4 offset + 4, 2 bytes big-endian)
            udp_len = UDP_HDR_LEN + chunk_size;
            seg[l2_len + l3_len + 4] = udp_len[15:8];
            seg[l2_len + l3_len + 5] = udp_len[7:0];

            // Recalculate IPv4 header checksum
            if (etype == ETHERTYPE_IPV4)
                recalc_ip_checksum(seg, l2_len, l3_len);

            segments[seg_idx] = seg;
            payload_off += chunk_size;
        end
    endfunction

    // ------------------------------------------------------------------------
    // recalc_ip_checksum — IPv4 header checksum recalculation
    // ------------------------------------------------------------------------
    protected function void recalc_ip_checksum(
        ref byte unsigned pkt_data[$],
        int unsigned l2_len,
        int unsigned l3_len
    );
        bit [31:0] sum;
        int unsigned i;

        // Zero checksum field
        pkt_data[l2_len + 10] = 8'h00;
        pkt_data[l2_len + 11] = 8'h00;

        sum = 0;
        for (i = 0; i < l3_len; i += 2) begin
            sum += {pkt_data[l2_len + i], pkt_data[l2_len + i + 1]};
        end

        while (sum >> 16)
            sum = sum[15:0] + sum[31:16];

        pkt_data[l2_len + 10] = ~sum[15:8];
        pkt_data[l2_len + 11] = ~sum[7:0];
    endfunction

endclass : virtio_uso_engine

`endif // VIRTIO_USO_ENGINE_SV
