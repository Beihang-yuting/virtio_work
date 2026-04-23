`ifndef VIRTIO_TSO_ENGINE_SV
`define VIRTIO_TSO_ENGINE_SV

// ============================================================================
// virtio_tso_engine
//
// TCP Segmentation Offload engine. Splits large TCP packets into MSS-sized
// segments. Each segment receives its own copy of ETH + IP + TCP headers
// with appropriate field updates (IP total_length, IP identification,
// TCP sequence number). IP header checksum is recalculated per segment.
// ============================================================================

class virtio_tso_engine extends uvm_object;
    `uvm_object_utils(virtio_tso_engine)

    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;

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
    // get_all_hdr_len — total header length (ETH + IP + TCP)
    // ------------------------------------------------------------------------
    function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len, l4_len;
        bit [15:0] etype;
        bit [3:0] ihl;
        int unsigned tcp_off;
        bit [3:0] data_offset;

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

        // TCP data offset (header length)
        tcp_off = l2_len + l3_len;
        if (pkt_data.size() <= tcp_off + 12)
            return 0;

        data_offset = pkt_data[tcp_off + 12][7:4];
        l4_len = data_offset * 4;
        if (l4_len < 20)
            l4_len = 20;

        return l2_len + l3_len + l4_len;
    endfunction

    // ------------------------------------------------------------------------
    // get_tcp_seq — extract 32-bit TCP sequence number
    // ------------------------------------------------------------------------
    function bit [31:0] get_tcp_seq(byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len, tcp_off;
        bit [15:0] etype;
        bit [3:0] ihl;

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

        tcp_off = l2_len + l3_len;
        // TCP seq at offset 4-7 within TCP header
        return {pkt_data[tcp_off + 4], pkt_data[tcp_off + 5],
                pkt_data[tcp_off + 6], pkt_data[tcp_off + 7]};
    endfunction

    // ------------------------------------------------------------------------
    // set_tcp_seq — write 32-bit TCP sequence number into packet
    // ------------------------------------------------------------------------
    function void set_tcp_seq(ref byte unsigned pkt_data[$], bit [31:0] seq);
        int unsigned l2_len, l3_len, tcp_off;
        bit [15:0] etype;
        bit [3:0] ihl;

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

        tcp_off = l2_len + l3_len;
        pkt_data[tcp_off + 4] = seq[31:24];
        pkt_data[tcp_off + 5] = seq[23:16];
        pkt_data[tcp_off + 6] = seq[15:8];
        pkt_data[tcp_off + 7] = seq[7:0];
    endfunction

    // ------------------------------------------------------------------------
    // set_ip_total_length — update IP total length field
    // IPv4: bytes 2-3 of IP header (big-endian)
    // IPv6: bytes 4-5 payload length (big-endian)
    // ------------------------------------------------------------------------
    function void set_ip_total_length(ref byte unsigned pkt_data[$], int unsigned total_len);
        int unsigned l2_len;
        bit [15:0] etype;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            pkt_data[l2_len + 2] = total_len[15:8];
            pkt_data[l2_len + 3] = total_len[7:0];
        end else if (etype == ETHERTYPE_IPV6) begin
            // IPv6 payload length = total_len - 40 (fixed IPv6 header)
            int unsigned payload_len;
            payload_len = total_len - 40;
            pkt_data[l2_len + 4] = payload_len[15:8];
            pkt_data[l2_len + 5] = payload_len[7:0];
        end
    endfunction

    // ------------------------------------------------------------------------
    // set_ip_identification — update IPv4 identification field (bytes 4-5)
    // No-op for IPv6 (no identification field)
    // ------------------------------------------------------------------------
    function void set_ip_identification(ref byte unsigned pkt_data[$], bit [15:0] id);
        int unsigned l2_len;
        bit [15:0] etype;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            pkt_data[l2_len + 4] = id[15:8];
            pkt_data[l2_len + 5] = id[7:0];
        end
    endfunction

    // ------------------------------------------------------------------------
    // recalc_ip_checksum — recalculate IPv4 header checksum
    // Zero the checksum field, compute ones-complement sum over IP header,
    // then write the complement. No-op for IPv6 (no header checksum).
    // ------------------------------------------------------------------------
    function void recalc_ip_checksum(ref byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;
        bit [31:0] sum;
        int unsigned i;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype != ETHERTYPE_IPV4)
            return;

        ihl = pkt_data[l2_len][7:4];
        l3_len = (ihl < 5) ? 20 : ihl * 4;

        // Zero checksum field (bytes 10-11 of IP header)
        pkt_data[l2_len + 10] = 8'h00;
        pkt_data[l2_len + 11] = 8'h00;

        // Compute ones-complement sum over IP header
        sum = 0;
        for (i = 0; i < l3_len; i += 2) begin
            sum += {pkt_data[l2_len + i], pkt_data[l2_len + i + 1]};
        end

        // Fold carries
        while (sum >> 16)
            sum = sum[15:0] + sum[31:16];

        // Write ones-complement
        pkt_data[l2_len + 10] = ~sum[15:8];
        pkt_data[l2_len + 11] = ~sum[7:0];
    endfunction

    // ------------------------------------------------------------------------
    // segment — split large TCP packet into MSS-sized segments
    //
    // Each segment receives a full copy of ETH + IP + TCP headers.
    // Per-segment updates:
    //   - IP total_length = hdr_len_ip + tcp_hdr_len + payload_chunk_size
    //   - IP identification incremented per segment
    //   - TCP sequence number += payload offset
    //   - IP checksum recalculated
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
        bit [31:0] base_seq;
        bit [15:0] base_ip_id;
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;
        int unsigned ip_total;

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

        // Calculate number of segments
        num_segments = (payload_len + mss - 1) / mss;
        segments = new[num_segments];

        base_seq = get_tcp_seq(pkt_data);

        // Get base IP identification and layer lengths
        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;
        if (etype == ETHERTYPE_VLAN)
            etype = {pkt_data[16], pkt_data[17]};

        if (etype == ETHERTYPE_IPV4) begin
            ihl = pkt_data[l2_len][7:4];
            l3_len = (ihl < 5) ? 20 : ihl * 4;
            base_ip_id = {pkt_data[l2_len + 4], pkt_data[l2_len + 5]};
        end else begin
            l3_len = 40;
            base_ip_id = 16'h0000;
        end

        payload_off = 0;
        for (seg_idx = 0; seg_idx < num_segments; seg_idx++) begin
            byte unsigned seg[$];

            // Determine chunk size
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
            ip_total = (l3_len + (all_hdr_len - l2_len - l3_len) + chunk_size);
            set_ip_total_length(seg, ip_total);

            // Update IP identification
            set_ip_identification(seg, base_ip_id + seg_idx[15:0]);

            // Update TCP sequence number
            set_tcp_seq(seg, base_seq + payload_off);

            // Recalculate IP header checksum
            recalc_ip_checksum(seg);

            segments[seg_idx] = seg;
            payload_off += chunk_size;
        end
    endfunction

endclass : virtio_tso_engine

`endif // VIRTIO_TSO_ENGINE_SV
