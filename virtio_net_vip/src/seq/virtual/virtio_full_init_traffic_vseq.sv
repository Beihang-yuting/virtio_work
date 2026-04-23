`ifndef VIRTIO_FULL_INIT_TRAFFIC_VSEQ_SV
`define VIRTIO_FULL_INIT_TRAFFIC_VSEQ_SV

// ============================================================================
// virtio_full_init_traffic_vseq
//
// Full initialization with all features, sustained traffic across multiple
// queue pairs (round-robin), then graceful shutdown.
//
// Configurable via randomization:
//   - num_packets: total packets to send (100-1000)
//   - num_pairs:   number of queue pairs (1-4)
//
// Depends on:
//   - virtio_init_seq, virtio_tx_seq, virtio_rx_seq, virtio_ctrl_seq
//   - virtio_transaction
// ============================================================================

class virtio_full_init_traffic_vseq extends uvm_sequence;
    `uvm_object_utils(virtio_full_init_traffic_vseq)

    // Sequencer reference (set by test before start)
    uvm_sequencer #(virtio_transaction) vf_seqr;

    rand int unsigned  num_packets;
    rand int unsigned  num_pairs;

    constraint c_default {
        num_packets inside {[100:1000]};
        num_pairs   inside {[1:4]};
    }

    function new(string name = "virtio_full_init_traffic_vseq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_init_seq  init_s;
        virtio_tx_seq    tx_s;
        virtio_rx_seq    rx_s;
        virtio_ctrl_seq  ctrl_s;

        if (vf_seqr == null)
            `uvm_fatal("FULL_VSEQ", "vf_seqr not set -- test must assign before start()")

        `uvm_info("FULL_VSEQ", $sformatf(
            "Starting full init+traffic: packets=%0d pairs=%0d",
            num_packets, num_pairs), UVM_LOW)

        // 1. Init with full features and multi-queue
        init_s = virtio_init_seq::type_id::create("init");
        init_s.num_queue_pairs = num_pairs;
        init_s.vq_type = VQ_SPLIT;
        init_s.driver_features = '1;  // negotiate all features
        init_s.start(vf_seqr);

        // 2. Set MQ via ctrl virtqueue (if num_pairs > 1)
        if (num_pairs > 1) begin
            ctrl_s = virtio_ctrl_seq::type_id::create("ctrl_mq");
            ctrl_s.ctrl_class = VIRTIO_NET_CTRL_CLS_MQ;
            ctrl_s.ctrl_cmd   = VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET;
            ctrl_s.ctrl_data  = new[2];
            ctrl_s.ctrl_data[0] = num_pairs[7:0];
            ctrl_s.ctrl_data[1] = num_pairs[15:8];
            ctrl_s.start(vf_seqr);
        end

        // 3. Start dataplane
        begin
            virtio_transaction req = virtio_transaction::type_id::create("start");
            req.txn_type = VIO_TXN_START_DP;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        // 4. TX num_packets across multiple queues (round-robin)
        begin
            int unsigned remaining;
            int unsigned batch_size;

            remaining = num_packets;
            batch_size = 32;  // send in batches of 32

            while (remaining > 0) begin
                int unsigned this_batch;
                int unsigned target_queue;

                this_batch = (remaining < batch_size) ? remaining : batch_size;
                // Round-robin across TX queues (odd-numbered: 1, 3, 5, ...)
                target_queue = ((num_packets - remaining) % num_pairs) * 2 + 1;

                tx_s = virtio_tx_seq::type_id::create("tx");
                tx_s.num_packets = this_batch;
                tx_s.queue_id = target_queue;
                tx_s.start(vf_seqr);

                remaining -= this_batch;
            end
        end

        // 5. RX wait for all packets
        rx_s = virtio_rx_seq::type_id::create("rx");
        rx_s.expected_count = num_packets;
        rx_s.timeout_ns = num_packets * 500;  // scale timeout with packet count
        rx_s.start(vf_seqr);

        // 6. Stop dataplane
        begin
            virtio_transaction req = virtio_transaction::type_id::create("stop");
            req.txn_type = VIO_TXN_STOP_DP;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        // 7. Reset
        begin
            virtio_transaction req = virtio_transaction::type_id::create("reset");
            req.txn_type = VIO_TXN_RESET;
            start_item(req, -1, vf_seqr);
            finish_item(req);
        end

        `uvm_info("FULL_VSEQ", $sformatf(
            "Full init+traffic complete: %0d packets across %0d pairs",
            num_packets, num_pairs), UVM_LOW)
    endtask

endclass : virtio_full_init_traffic_vseq

`endif // VIRTIO_FULL_INIT_TRAFFIC_VSEQ_SV
