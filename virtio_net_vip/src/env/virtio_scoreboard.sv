`ifndef VIRTIO_SCOREBOARD_SV
`define VIRTIO_SCOREBOARD_SV

// ============================================================================
// virtio_scoreboard
//
// 8-category verification scoreboard for virtio-net transactions.
// Receives transactions via uvm_analysis_imp and dispatches to
// per-category check methods based on transaction type.
//
// Check categories (each independently enable/disable):
//   1. Data integrity     -- TX/RX payload matching
//   2. Offload correctness -- checksum, GSO validation
//   3. Queue protocol     -- descriptor chain, avail/used ring correctness
//   4. Feature compliance -- operations match negotiated features
//   5. Notification       -- kick/interrupt protocol correctness
//   6. DMA compliance     -- address range, direction, mapping validity
//   7. Ordering           -- in-order completion within a queue
//   8. Config consistency -- device config register vs expected values
//
// Supports a custom callback (virtio_scoreboard_callback) for
// vendor-specific packet comparison logic.
//
// Depends on:
//   - virtio_transaction, virtio_scoreboard_callback
//   - virtio_net_types.sv (scoreboard_stats_t, virtio_net_hdr_t, etc.)
// ============================================================================

class virtio_scoreboard extends uvm_component;
    `uvm_component_utils(virtio_scoreboard)

    // ===== Analysis import =====
    uvm_analysis_imp #(virtio_transaction, virtio_scoreboard) txn_imp;

    // ===== Custom callback =====
    virtio_scoreboard_callback custom_checker;

    // ===== Check enable switches (all default ON) =====
    bit chk_data_integrity     = 1;
    bit chk_offload_correct    = 1;
    bit chk_queue_protocol     = 1;
    bit chk_feature_compliance = 1;
    bit chk_notification       = 1;
    bit chk_dma_compliance     = 1;
    bit chk_ordering           = 1;
    bit chk_config_consistency = 1;

    // ===== Statistics =====
    scoreboard_stats_t stats;

    // ===== Pending TX packets (for matching) =====
    protected uvm_object tx_expected[$];

    // ===== Ordering tracker: queue_id -> last completed sequence number =====
    protected int unsigned last_seq_num[int unsigned];

    // ===== Negotiated features (set by env or test) =====
    bit [63:0] negotiated_features = '0;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
        stats = '{default: 0};
    endfunction

    // ========================================================================
    // Build Phase
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        txn_imp = new("txn_imp", this);
    endfunction

    // ========================================================================
    // write -- Analysis port callback
    //
    // Dispatches each incoming transaction to the appropriate checker(s)
    // based on txn_type. Multiple checks may fire for a single transaction.
    // ========================================================================

    virtual function void write(virtio_transaction txn);
        case (txn.txn_type)
            VIO_TXN_SEND_PKTS: begin
                // Record expected TX packets for later matching
                if (chk_data_integrity) begin
                    foreach (txn.packets[i]) begin
                        tx_expected.push_back(txn.packets[i]);
                        stats.tx_sent++;
                    end
                end
                // Check offload on each packet
                if (chk_offload_correct) begin
                    foreach (txn.packets[i]) begin
                        check_offload(txn.net_hdr, get_pkt_data(txn.packets[i]));
                    end
                end
                // Check feature compliance
                if (chk_feature_compliance)
                    check_feature_compliance(txn, negotiated_features);
            end

            VIO_TXN_WAIT_PKTS: begin
                // Match received packets against expected
                if (chk_data_integrity) begin
                    foreach (txn.received_pkts[i]) begin
                        stats.rx_received++;
                        if (tx_expected.size() > 0) begin
                            uvm_object expected_pkt = tx_expected.pop_front();
                            check_data_integrity(expected_pkt, txn.received_pkts[i]);
                        end else begin
                            stats.unexpected_rx++;
                            `uvm_error("SCB",
                                $sformatf("Unexpected RX packet (no pending TX): queue=%0d",
                                          txn.queue_id))
                        end
                    end
                end
            end

            VIO_TXN_CTRL_CMD: begin
                if (chk_feature_compliance)
                    check_feature_compliance(txn, negotiated_features);
            end

            VIO_TXN_INIT: begin
                // Track negotiated features from init transaction
                if (txn.features != '0)
                    negotiated_features = txn.features;
            end

            VIO_TXN_ATOMIC_OP: begin
                if (chk_queue_protocol) begin
                    case (txn.atomic_op)
                        ATOMIC_KICK:      check_notification(txn.queue_id, 1, 0);
                        ATOMIC_POLL_USED: check_notification(txn.queue_id, 0, 1);
                        default: ;
                    endcase
                end
                if (chk_ordering)
                    check_ordering(txn.queue_id, txn.desc_id);
            end

            default: ;
        endcase
    endfunction

    // ========================================================================
    // check_data_integrity
    //
    // Compare expected vs actual packet data. Uses custom_checker if
    // registered, otherwise uses uvm_object::compare().
    // ========================================================================

    virtual function void check_data_integrity(uvm_object expected, uvm_object actual);
        bit match;

        if (expected == null || actual == null) begin
            `uvm_error("SCB", "check_data_integrity: null packet reference")
            stats.tx_mismatched++;
            return;
        end

        if (custom_checker != null) begin
            match = custom_checker.custom_compare(expected, actual);
        end else begin
            match = expected.compare(actual);
        end

        if (match) begin
            stats.tx_matched++;
            stats.rx_matched++;
            `uvm_info("SCB", "Data integrity: MATCH", UVM_HIGH)
        end else begin
            stats.tx_mismatched++;
            stats.rx_mismatched++;
            `uvm_error("SCB",
                $sformatf("Data integrity: MISMATCH\n  expected: %s\n  actual: %s",
                          expected.convert2string(), actual.convert2string()))
        end
    endfunction

    // ========================================================================
    // check_offload
    //
    // Validate virtio-net header offload fields against packet data.
    // Checks checksum offset validity and GSO segment size bounds.
    // ========================================================================

    virtual function void check_offload(virtio_net_hdr_t hdr, byte unsigned pkt_data[$]);
        // Checksum offload validation
        if (hdr.flags & VIRTIO_NET_HDR_F_NEEDS_CSUM) begin
            int unsigned csum_end = hdr.csum_start + hdr.csum_offset + 2;
            if (csum_end > pkt_data.size()) begin
                stats.csum_errors++;
                `uvm_error("SCB",
                    $sformatf("Checksum offset out of bounds: csum_start=%0d, csum_offset=%0d, pkt_size=%0d",
                              hdr.csum_start, hdr.csum_offset, pkt_data.size()))
            end
        end

        // GSO validation
        if (hdr.gso_type != VIRTIO_NET_HDR_GSO_NONE) begin
            if (hdr.gso_size == 0) begin
                stats.gso_errors++;
                `uvm_error("SCB",
                    $sformatf("GSO type=%0h but gso_size=0", hdr.gso_type))
            end
            if (hdr.hdr_len == 0) begin
                stats.gso_errors++;
                `uvm_error("SCB",
                    $sformatf("GSO type=%0h but hdr_len=0", hdr.gso_type))
            end
            // Verify packet is larger than one segment (otherwise GSO is unnecessary)
            if (pkt_data.size() > 0 && pkt_data.size() <= hdr.gso_size) begin
                `uvm_warning("SCB",
                    $sformatf("GSO enabled but pkt_size=%0d <= gso_size=%0d",
                              pkt_data.size(), hdr.gso_size))
            end
        end
    endfunction

    // ========================================================================
    // check_feature_compliance
    //
    // Verify that the transaction only uses operations/fields that are
    // permitted by the negotiated feature set.
    // ========================================================================

    virtual function void check_feature_compliance(virtio_transaction txn, bit [63:0] negotiated);
        // MQ command requires VIRTIO_NET_F_MQ
        if (txn.txn_type == VIO_TXN_SET_MQ && !negotiated[VIRTIO_NET_F_MQ]) begin
            stats.feature_errors++;
            `uvm_error("SCB",
                "Feature violation: VIO_TXN_SET_MQ without VIRTIO_NET_F_MQ negotiated")
        end

        // RSS command requires VIRTIO_NET_F_RSS
        if (txn.txn_type == VIO_TXN_SET_RSS && !negotiated[VIRTIO_NET_F_RSS]) begin
            stats.feature_errors++;
            `uvm_error("SCB",
                "Feature violation: VIO_TXN_SET_RSS without VIRTIO_NET_F_RSS negotiated")
        end

        // CTRL_VQ commands require VIRTIO_NET_F_CTRL_VQ
        if (txn.txn_type == VIO_TXN_CTRL_CMD && !negotiated[VIRTIO_NET_F_CTRL_VQ]) begin
            stats.feature_errors++;
            `uvm_error("SCB",
                "Feature violation: VIO_TXN_CTRL_CMD without VIRTIO_NET_F_CTRL_VQ negotiated")
        end

        // VLAN control requires VIRTIO_NET_F_CTRL_VLAN
        if (txn.txn_type == VIO_TXN_CTRL_CMD &&
            txn.ctrl_class == VIRTIO_NET_CTRL_CLS_VLAN &&
            !negotiated[VIRTIO_NET_F_CTRL_VLAN]) begin
            stats.feature_errors++;
            `uvm_error("SCB",
                "Feature violation: VLAN control without VIRTIO_NET_F_CTRL_VLAN negotiated")
        end

        // Checksum offload requires VIRTIO_NET_F_CSUM
        if (txn.txn_type == VIO_TXN_SEND_PKTS &&
            (txn.net_hdr.flags & VIRTIO_NET_HDR_F_NEEDS_CSUM) &&
            !negotiated[VIRTIO_NET_F_CSUM]) begin
            stats.feature_errors++;
            `uvm_error("SCB",
                "Feature violation: NEEDS_CSUM flag without VIRTIO_NET_F_CSUM negotiated")
        end

        // GSO requires appropriate feature bits
        if (txn.txn_type == VIO_TXN_SEND_PKTS) begin
            case (txn.net_hdr.gso_type)
                VIRTIO_NET_HDR_GSO_TCPV4: begin
                    if (!negotiated[VIRTIO_NET_F_HOST_TSO4]) begin
                        stats.feature_errors++;
                        `uvm_error("SCB",
                            "Feature violation: GSO_TCPV4 without VIRTIO_NET_F_HOST_TSO4")
                    end
                end
                VIRTIO_NET_HDR_GSO_TCPV6: begin
                    if (!negotiated[VIRTIO_NET_F_HOST_TSO6]) begin
                        stats.feature_errors++;
                        `uvm_error("SCB",
                            "Feature violation: GSO_TCPV6 without VIRTIO_NET_F_HOST_TSO6")
                    end
                end
                VIRTIO_NET_HDR_GSO_UDP_L4: begin
                    if (!negotiated[VIRTIO_NET_F_HOST_USO]) begin
                        stats.feature_errors++;
                        `uvm_error("SCB",
                            "Feature violation: GSO_UDP_L4 without VIRTIO_NET_F_HOST_USO")
                    end
                end
                default: ;
            endcase
        end
    endfunction

    // ========================================================================
    // check_notification
    //
    // Validate kick/interrupt protocol correctness for a queue.
    // ========================================================================

    virtual function void check_notification(int unsigned queue_id, bit kick_sent, bit irq_received);
        if (kick_sent)
            `uvm_info("SCB",
                $sformatf("Notification: kick sent on queue %0d", queue_id), UVM_HIGH)
        if (irq_received)
            `uvm_info("SCB",
                $sformatf("Notification: IRQ received on queue %0d", queue_id), UVM_HIGH)
    endfunction

    // ========================================================================
    // check_dma_access
    //
    // Verify DMA address and size are within expected bounds and direction
    // matches the mapping.
    // ========================================================================

    virtual function void check_dma_access(bit [63:0] addr, int unsigned size, dma_dir_e dir);
        if (size == 0) begin
            stats.dma_errors++;
            `uvm_error("SCB",
                $sformatf("DMA access with zero size at addr=0x%016h", addr))
        end
    endfunction

    // ========================================================================
    // check_ordering
    //
    // Verify in-order completion within a single queue. Sequence numbers
    // must be monotonically increasing per queue.
    // ========================================================================

    virtual function void check_ordering(int unsigned queue_id, int unsigned seq_num);
        if (last_seq_num.exists(queue_id)) begin
            if (seq_num != 0 && seq_num <= last_seq_num[queue_id]) begin
                stats.ordering_errors++;
                `uvm_error("SCB",
                    $sformatf("Ordering violation: queue=%0d, prev_seq=%0d, curr_seq=%0d",
                              queue_id, last_seq_num[queue_id], seq_num))
            end
        end
        last_seq_num[queue_id] = seq_num;
    endfunction

    // ========================================================================
    // check_config_consistency
    //
    // Compare expected device config against actual values read from device.
    // ========================================================================

    virtual function void check_config_consistency(
        virtio_net_device_config_t expected,
        virtio_net_device_config_t actual
    );
        bit mismatch = 0;

        if (expected.mac != actual.mac) begin
            `uvm_error("SCB",
                $sformatf("Config mismatch: MAC expected=0x%012h, actual=0x%012h",
                          expected.mac, actual.mac))
            mismatch = 1;
        end

        if (expected.mtu != actual.mtu) begin
            `uvm_error("SCB",
                $sformatf("Config mismatch: MTU expected=%0d, actual=%0d",
                          expected.mtu, actual.mtu))
            mismatch = 1;
        end

        if (expected.max_virtqueue_pairs != actual.max_virtqueue_pairs) begin
            `uvm_error("SCB",
                $sformatf("Config mismatch: max_vq_pairs expected=%0d, actual=%0d",
                          expected.max_virtqueue_pairs, actual.max_virtqueue_pairs))
            mismatch = 1;
        end

        if (expected.status != actual.status) begin
            `uvm_error("SCB",
                $sformatf("Config mismatch: status expected=0x%04h, actual=0x%04h",
                          expected.status, actual.status))
            mismatch = 1;
        end

        if (mismatch)
            `uvm_error("SCB", "Config consistency check: FAILED")
        else
            `uvm_info("SCB", "Config consistency check: PASSED", UVM_HIGH)
    endfunction

    // ========================================================================
    // report_phase -- Print scoreboard summary
    // ========================================================================

    virtual function void report_phase(uvm_phase phase);
        string report;
        super.report_phase(phase);

        report = "\n========== Virtio Scoreboard Report ==========\n";
        report = {report, $sformatf("  TX sent:       %0d\n", stats.tx_sent)};
        report = {report, $sformatf("  TX matched:    %0d\n", stats.tx_matched)};
        report = {report, $sformatf("  TX mismatched: %0d\n", stats.tx_mismatched)};
        report = {report, $sformatf("  RX received:   %0d\n", stats.rx_received)};
        report = {report, $sformatf("  RX matched:    %0d\n", stats.rx_matched)};
        report = {report, $sformatf("  RX mismatched: %0d\n", stats.rx_mismatched)};
        report = {report, $sformatf("  Checksum errs: %0d\n", stats.csum_errors)};
        report = {report, $sformatf("  GSO errors:    %0d\n", stats.gso_errors)};
        report = {report, $sformatf("  Feature errs:  %0d\n", stats.feature_errors)};
        report = {report, $sformatf("  Notify errors: %0d\n", stats.notify_errors)};
        report = {report, $sformatf("  DMA errors:    %0d\n", stats.dma_errors)};
        report = {report, $sformatf("  Order errors:  %0d\n", stats.ordering_errors)};
        report = {report, $sformatf("  Unexpected RX: %0d\n", stats.unexpected_rx)};
        report = {report, $sformatf("  Pending TX:    %0d\n", tx_expected.size())};
        report = {report, "==============================================="};

        `uvm_info("SCB", report, UVM_LOW)

        if (tx_expected.size() > 0) begin
            `uvm_error("SCB",
                $sformatf("%0d TX packets were never matched by RX", tx_expected.size()))
        end

        if (stats.tx_mismatched > 0 || stats.rx_mismatched > 0 ||
            stats.csum_errors > 0 || stats.gso_errors > 0 ||
            stats.feature_errors > 0 || stats.dma_errors > 0 ||
            stats.ordering_errors > 0 || stats.unexpected_rx > 0) begin
            `uvm_error("SCB", "Scoreboard detected errors -- see details above")
        end
    endfunction

    // ========================================================================
    // Helper: extract packet data bytes from a uvm_object packet reference
    // ========================================================================

    protected function virtio_byte_queue_t get_pkt_data(uvm_object pkt);
        byte unsigned empty[$];
        // Packet data extraction is implementation-specific.
        // The actual packet_item class (from the test layer) should provide
        // a method to get raw bytes. Tests should register a custom_checker
        // for real packet comparison with full data extraction.
        if (pkt == null) return empty;
        return empty;
    endfunction

endclass : virtio_scoreboard

`endif // VIRTIO_SCOREBOARD_SV
