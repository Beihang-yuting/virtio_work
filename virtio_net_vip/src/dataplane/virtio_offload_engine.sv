`ifndef VIRTIO_OFFLOAD_ENGINE_SV
`define VIRTIO_OFFLOAD_ENGINE_SV

// ============================================================================
// virtio_offload_engine
//
// Unified offload engine wrapping all four sub-engines: checksum, TSO, USO,
// and RSS. Provides a single interface for TX/RX engines and the scoreboard.
//
// Sub-engines:
//   csum — checksum offload (TX partial csum, RX verification)
//   tso  — TCP Segmentation Offload
//   uso  — UDP Segmentation Offload (virtio 1.2+)
//   rss  — Receive Side Scaling (Toeplitz hash + queue selection)
// ============================================================================

class virtio_offload_engine extends uvm_object;
    `uvm_object_utils(virtio_offload_engine)

    // Sub-engines
    virtio_csum_engine    csum;
    virtio_tso_engine     tso;
    virtio_uso_engine     uso;
    virtio_rss_engine     rss;

    // Configuration
    bit [63:0]   negotiated_features;
    int unsigned mtu = 1500;
    int unsigned mss = 1460;   // TCP MSS default (MTU - IP(20) - TCP(20))

    function new(string name = "virtio_offload_engine");
        super.new(name);
        csum = virtio_csum_engine::type_id::create("csum");
        tso  = virtio_tso_engine::type_id::create("tso");
        uso  = virtio_uso_engine::type_id::create("uso");
        rss  = virtio_rss_engine::type_id::create("rss");
        negotiated_features = 64'h0;
    endfunction

    // ========================================================================
    // TX path helpers
    // ========================================================================

    // ------------------------------------------------------------------------
    // needs_gso — check if packet needs any segmentation (TSO or USO)
    // ------------------------------------------------------------------------
    function bit needs_gso(byte unsigned pkt_data[$]);
        return needs_tso(pkt_data) || needs_uso(pkt_data);
    endfunction

    // ------------------------------------------------------------------------
    // needs_tso — check if packet needs TCP segmentation offload
    // Only if HOST_TSO4 or HOST_TSO6 is negotiated.
    // ------------------------------------------------------------------------
    function bit needs_tso(byte unsigned pkt_data[$]);
        if (!(negotiated_features[VIRTIO_NET_F_HOST_TSO4] ||
              negotiated_features[VIRTIO_NET_F_HOST_TSO6]))
            return 0;
        return tso.needs_tso(pkt_data, mss);
    endfunction

    // ------------------------------------------------------------------------
    // needs_uso — check if packet needs UDP segmentation offload
    // Only if HOST_USO is negotiated.
    // ------------------------------------------------------------------------
    function bit needs_uso(byte unsigned pkt_data[$]);
        if (!negotiated_features[VIRTIO_NET_F_HOST_USO])
            return 0;
        return uso.needs_uso(pkt_data, mss);
    endfunction

    // ------------------------------------------------------------------------
    // get_gso_type — determine GSO type for virtio_net_hdr based on packet
    // Returns the appropriate VIRTIO_NET_HDR_GSO_* constant.
    // ------------------------------------------------------------------------
    function bit [7:0] get_gso_type(byte unsigned pkt_data[$]);
        bit [15:0] etype;
        bit [7:0] proto;
        int unsigned l2_len;

        if (pkt_data.size() < 14)
            return VIRTIO_NET_HDR_GSO_NONE;

        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == 16'h8100) ? 18 : 14;
        if (etype == 16'h8100 && pkt_data.size() >= 18)
            etype = {pkt_data[16], pkt_data[17]};

        // Get L4 protocol
        if (etype == 16'h0800 && pkt_data.size() > l2_len + 9)
            proto = pkt_data[l2_len + 9];
        else if (etype == 16'h86DD && pkt_data.size() > l2_len + 6)
            proto = pkt_data[l2_len + 6];
        else
            return VIRTIO_NET_HDR_GSO_NONE;

        if (proto == 8'd6) begin  // TCP
            if (etype == 16'h0800)
                return VIRTIO_NET_HDR_GSO_TCPV4;
            else
                return VIRTIO_NET_HDR_GSO_TCPV6;
        end else if (proto == 8'd17) begin  // UDP
            return VIRTIO_NET_HDR_GSO_UDP_L4;
        end

        return VIRTIO_NET_HDR_GSO_NONE;
    endfunction

    // ------------------------------------------------------------------------
    // get_mss_value — return configured MSS
    // ------------------------------------------------------------------------
    function int unsigned get_mss_value();
        return mss;
    endfunction

    // ------------------------------------------------------------------------
    // get_all_hdr_len — get total header length for segmentation
    // Delegates to TSO or USO engine depending on packet type.
    // ------------------------------------------------------------------------
    function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);
        if (needs_tso(pkt_data))
            return tso.get_all_hdr_len(pkt_data);
        if (needs_uso(pkt_data))
            return uso.get_all_hdr_len(pkt_data);
        return 0;
    endfunction

    // ------------------------------------------------------------------------
    // TX checksum helpers — delegate to csum engine
    // ------------------------------------------------------------------------
    function void prepare_tx_csum(virtio_net_hdr_t hdr, ref byte unsigned pkt_data[$]);
        csum.prepare_tx_csum(hdr, pkt_data);
    endfunction

    function int unsigned calc_csum_start(byte unsigned pkt_data[$]);
        return csum.calc_csum_start(pkt_data);
    endfunction

    function int unsigned calc_csum_offset(byte unsigned pkt_data[$]);
        return csum.calc_csum_offset(pkt_data);
    endfunction

    // ========================================================================
    // RX path helpers
    // ========================================================================

    // ------------------------------------------------------------------------
    // verify_rx_csum — verify L4 checksum on received packet
    // ------------------------------------------------------------------------
    function bit verify_rx_csum(virtio_net_hdr_t hdr, byte unsigned pkt_data[$]);
        return csum.verify_rx_csum(hdr, pkt_data);
    endfunction

    // ========================================================================
    // RSS helpers
    // ========================================================================

    // ------------------------------------------------------------------------
    // rss_select_queue — full RSS: hash + indirection table lookup
    // ------------------------------------------------------------------------
    function int unsigned rss_select_queue(byte unsigned pkt_data[$], int unsigned num_pairs);
        return rss.select_queue(pkt_data, num_pairs);
    endfunction

    // ------------------------------------------------------------------------
    // rss_calc_hash — compute RSS hash value for a packet
    // ------------------------------------------------------------------------
    function bit [31:0] rss_calc_hash(byte unsigned pkt_data[$]);
        return rss.calc_hash(pkt_data);
    endfunction

    // ------------------------------------------------------------------------
    // rss_get_hash_type — determine RSS hash type for a packet
    // ------------------------------------------------------------------------
    function int unsigned rss_get_hash_type(byte unsigned pkt_data[$]);
        return rss.get_hash_type(pkt_data);
    endfunction

endclass : virtio_offload_engine

`endif // VIRTIO_OFFLOAD_ENGINE_SV
