`ifndef VIRTIO_MULTI_VF_VSEQ_SV
`define VIRTIO_MULTI_VF_VSEQ_SV

// ============================================================================
// virtio_multi_vf_vseq
//
// Parallel init + traffic across multiple VFs. All fork blocks are named
// per SystemVerilog best practice to aid debugging.
//
// The test sets vf_seqrs[] and num_vfs before calling start().
//
// Depends on:
//   - virtio_init_seq, virtio_tx_seq, virtio_rx_seq
//   - virtio_transaction
// ============================================================================

class virtio_multi_vf_vseq extends uvm_sequence;
    `uvm_object_utils(virtio_multi_vf_vseq)

    // Per-VF sequencer references (set by test before start)
    uvm_sequencer #(virtio_transaction) vf_seqrs[];
    int unsigned num_vfs;

    rand int unsigned pkts_per_vf;

    constraint c_default {
        pkts_per_vf inside {[10:100]};
    }

    function new(string name = "virtio_multi_vf_vseq");
        super.new(name);
    endfunction

    virtual task body();
        if (vf_seqrs.size() == 0)
            `uvm_fatal("MULTI_VF_VSEQ", "vf_seqrs[] not set -- test must assign before start()")

        if (num_vfs == 0)
            num_vfs = vf_seqrs.size();

        if (num_vfs > vf_seqrs.size())
            `uvm_fatal("MULTI_VF_VSEQ", $sformatf(
                "num_vfs=%0d exceeds vf_seqrs.size()=%0d", num_vfs, vf_seqrs.size()))

        `uvm_info("MULTI_VF_VSEQ", $sformatf(
            "Starting multi-VF: %0d VFs, %0d pkts/VF", num_vfs, pkts_per_vf), UVM_LOW)

        // 1. Parallel init all VFs
        fork : init_block
            begin
                foreach (vf_seqrs[i]) begin
                    automatic int vf_idx = i;
                    if (vf_idx >= num_vfs) continue;
                    fork : per_vf_init
                        begin
                            virtio_init_seq init_s;
                            init_s = virtio_init_seq::type_id::create(
                                $sformatf("init_vf%0d", vf_idx));
                            init_s.num_queue_pairs = 1;
                            init_s.vq_type = VQ_SPLIT;
                            init_s.start(vf_seqrs[vf_idx]);
                        end
                    join_none
                end
                wait fork;
            end
        join

        // 2. Parallel start dataplane on all VFs
        fork : start_dp_block
            begin
                foreach (vf_seqrs[i]) begin
                    automatic int vf_idx = i;
                    if (vf_idx >= num_vfs) continue;
                    fork : per_vf_start
                        begin
                            virtio_transaction req;
                            req = virtio_transaction::type_id::create(
                                $sformatf("start_vf%0d", vf_idx));
                            req.txn_type = VIO_TXN_START_DP;
                            start_item(req, -1, vf_seqrs[vf_idx]);
                            finish_item(req);
                        end
                    join_none
                end
                wait fork;
            end
        join

        // 3. Parallel traffic generation on all VFs
        fork : traffic_block
            begin
                foreach (vf_seqrs[i]) begin
                    automatic int vf_idx = i;
                    if (vf_idx >= num_vfs) continue;
                    fork : per_vf_traffic
                        begin
                            virtio_tx_seq tx_s;
                            virtio_rx_seq rx_s;

                            // TX
                            tx_s = virtio_tx_seq::type_id::create(
                                $sformatf("tx_vf%0d", vf_idx));
                            tx_s.num_packets = pkts_per_vf;
                            tx_s.queue_id = 1;  // transmitq_0
                            tx_s.start(vf_seqrs[vf_idx]);

                            // RX
                            rx_s = virtio_rx_seq::type_id::create(
                                $sformatf("rx_vf%0d", vf_idx));
                            rx_s.expected_count = pkts_per_vf;
                            rx_s.timeout_ns = pkts_per_vf * 500;
                            rx_s.start(vf_seqrs[vf_idx]);
                        end
                    join_none
                end
                wait fork;
            end
        join

        // 4. Parallel stop + reset on all VFs
        fork : shutdown_block
            begin
                foreach (vf_seqrs[i]) begin
                    automatic int vf_idx = i;
                    if (vf_idx >= num_vfs) continue;
                    fork : per_vf_shutdown
                        begin
                            virtio_transaction stop_req, reset_req;

                            // Stop dataplane
                            stop_req = virtio_transaction::type_id::create(
                                $sformatf("stop_vf%0d", vf_idx));
                            stop_req.txn_type = VIO_TXN_STOP_DP;
                            start_item(stop_req, -1, vf_seqrs[vf_idx]);
                            finish_item(stop_req);

                            // Reset
                            reset_req = virtio_transaction::type_id::create(
                                $sformatf("reset_vf%0d", vf_idx));
                            reset_req.txn_type = VIO_TXN_RESET;
                            start_item(reset_req, -1, vf_seqrs[vf_idx]);
                            finish_item(reset_req);
                        end
                    join_none
                end
                wait fork;
            end
        join

        `uvm_info("MULTI_VF_VSEQ", $sformatf(
            "Multi-VF complete: %0d VFs, %0d pkts/VF", num_vfs, pkts_per_vf), UVM_LOW)
    endtask

endclass : virtio_multi_vf_vseq

`endif // VIRTIO_MULTI_VF_VSEQ_SV
