`ifndef VIRTIO_BOUNDARY_SEQ_SV
`define VIRTIO_BOUNDARY_SEQ_SV

typedef enum {
    BOUND_MIN_QUEUE_SIZE, BOUND_MAX_QUEUE_SIZE, BOUND_MAX_CHAIN_LEN,
    BOUND_INDIRECT_TABLE_FULL, BOUND_ALL_QUEUES_BACKPRESSURE,
    BOUND_ZERO_LEN_PACKET, BOUND_CONSECUTIVE_RESETS, BOUND_FEATURES_REJECTED
} boundary_case_e;

class virtio_boundary_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_boundary_seq)

    rand boundary_case_e boundary;

    function new(string name = "virtio_boundary_seq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_transaction req;

        `uvm_info(get_type_name(), $sformatf(
            "Boundary test: %s", boundary.name()), UVM_MEDIUM)

        case (boundary)
            BOUND_MIN_QUEUE_SIZE: begin
                begin
                    virtio_queue_setup_seq qs = virtio_queue_setup_seq::type_id::create("qs");
                    qs.queue_id            = 0;
                    qs.queue_size          = 16; // minimum
                    qs.drv_cfg             = drv_cfg;
                    qs.negotiated_features = negotiated_features;
                    qs.start(m_sequencer);
                end
                do_init();
                send_txn(VIO_TXN_START_DP);
                begin
                    virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
                    tx_s.num_packets         = 16;
                    tx_s.drv_cfg             = drv_cfg;
                    tx_s.negotiated_features = negotiated_features;
                    tx_s.start(m_sequencer);
                end
            end

            BOUND_MAX_QUEUE_SIZE: begin
                begin
                    virtio_queue_setup_seq qs = virtio_queue_setup_seq::type_id::create("qs");
                    qs.queue_id            = 0;
                    qs.queue_size          = 1024; // maximum
                    qs.drv_cfg             = drv_cfg;
                    qs.negotiated_features = negotiated_features;
                    qs.start(m_sequencer);
                end
                do_init();
                send_txn(VIO_TXN_START_DP);
                begin
                    virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
                    tx_s.num_packets         = 64;
                    tx_s.drv_cfg             = drv_cfg;
                    tx_s.negotiated_features = negotiated_features;
                    tx_s.start(m_sequencer);
                end
            end

            BOUND_MAX_CHAIN_LEN: begin
                do_init();
                send_txn(VIO_TXN_START_DP);
                // Send packet requiring maximum descriptor chain
                req = virtio_transaction::type_id::create("req");
                req.txn_type = VIO_TXN_SEND_PKTS;
                req.queue_id = 0;
                send_configured_txn(req);
            end

            BOUND_INDIRECT_TABLE_FULL: begin
                negotiated_features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;
                do_init();
                send_txn(VIO_TXN_START_DP);
                begin
                    virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
                    tx_s.num_packets         = 64;
                    tx_s.use_indirect        = 1;
                    tx_s.drv_cfg             = drv_cfg;
                    tx_s.negotiated_features = negotiated_features;
                    tx_s.start(m_sequencer);
                end
            end

            BOUND_ALL_QUEUES_BACKPRESSURE: begin
                do_init();
                send_txn(VIO_TXN_START_DP);
                // Flood all queues to trigger backpressure
                for (int q = 0; q < 8; q++) begin
                    virtio_tx_seq tx_s = virtio_tx_seq::type_id::create(
                        $sformatf("tx_q%0d", q));
                    tx_s.num_packets         = 64;
                    tx_s.queue_id            = q * 2;
                    tx_s.drv_cfg             = drv_cfg;
                    tx_s.negotiated_features = negotiated_features;
                    tx_s.start(m_sequencer);
                end
            end

            BOUND_ZERO_LEN_PACKET: begin
                do_init();
                send_txn(VIO_TXN_START_DP);
                req = virtio_transaction::type_id::create("req");
                req.txn_type         = VIO_TXN_SEND_PKTS;
                req.queue_id         = 0;
                req.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_NONE;
                req.net_hdr.hdr_len  = 16'h0000;
                send_configured_txn(req);
            end

            BOUND_CONSECUTIVE_RESETS: begin
                repeat (8) begin
                    do_init();
                    do_reset();
                end
                `uvm_info(get_type_name(), "8 consecutive resets complete", UVM_MEDIUM)
            end

            BOUND_FEATURES_REJECTED: begin
                // Negotiate with all features, expect device to reject some
                req = virtio_transaction::type_id::create("req");
                req.txn_type  = VIO_TXN_INIT;
                req.features  = 64'hFFFF_FFFF_FFFF_FFFF;
                req.num_pairs = 1;
                req.vq_type   = VQ_SPLIT;
                send_configured_txn(req);
            end
        endcase

        `uvm_info(get_type_name(), $sformatf(
            "Boundary test complete: %s", boundary.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_BOUNDARY_SEQ_SV
