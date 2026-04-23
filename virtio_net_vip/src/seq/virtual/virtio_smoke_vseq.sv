`ifndef VIRTIO_SMOKE_VSEQ_SV
`define VIRTIO_SMOKE_VSEQ_SV

// ============================================================================
// virtio_smoke_vseq
//
// Minimal end-to-end virtual sequence: init -> start dataplane -> TX 10
// packets -> RX wait -> stop dataplane -> reset.
//
// This is a coordinating sequence that runs on the virtual sequencer and
// directs sub-sequences to a specific VF sequencer. It extends uvm_sequence
// (not virtio_base_seq) because it orchestrates across sequencers rather
// than running on a single one.
//
// Depends on:
//   - virtio_init_seq, virtio_tx_seq, virtio_rx_seq (base sequences)
//   - virtio_transaction (transaction item)
// ============================================================================

class virtio_smoke_vseq extends uvm_sequence;
    `uvm_object_utils(virtio_smoke_vseq)

    // Sequencer reference (set by test before start)
    uvm_sequencer #(virtio_transaction) vf_seqr;

    function new(string name = "virtio_smoke_vseq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_init_seq  init_s;
        virtio_tx_seq    tx_s;
        virtio_rx_seq    rx_s;

        if (vf_seqr == null)
            `uvm_fatal("SMOKE_VSEQ", "vf_seqr not set -- test must assign before start()")

        // 1. Init (split queue, 1 pair, basic features)
        init_s = virtio_init_seq::type_id::create("init");
        init_s.num_queue_pairs = 1;
        init_s.vq_type = VQ_SPLIT;
        init_s.start(vf_seqr);

        // 2. Start dataplane
        begin
            virtio_transaction req = virtio_transaction::type_id::create("start");
            req.txn_type = VIO_TXN_START_DP;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        // 3. TX 10 packets
        tx_s = virtio_tx_seq::type_id::create("tx");
        tx_s.num_packets = 10;
        tx_s.queue_id = 1;  // transmitq_0
        tx_s.start(vf_seqr);

        // 4. RX wait
        rx_s = virtio_rx_seq::type_id::create("rx");
        rx_s.expected_count = 10;
        rx_s.timeout_ns = 50000;
        rx_s.start(vf_seqr);

        // 5. Stop dataplane
        begin
            virtio_transaction req = virtio_transaction::type_id::create("stop");
            req.txn_type = VIO_TXN_STOP_DP;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        // 6. Reset
        begin
            virtio_transaction req = virtio_transaction::type_id::create("reset");
            req.txn_type = VIO_TXN_RESET;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        `uvm_info("SMOKE_VSEQ", "Smoke test complete", UVM_LOW)
    endtask

endclass : virtio_smoke_vseq

`endif // VIRTIO_SMOKE_VSEQ_SV
