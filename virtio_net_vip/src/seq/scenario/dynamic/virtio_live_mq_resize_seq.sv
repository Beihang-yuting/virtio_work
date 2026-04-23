`ifndef VIRTIO_LIVE_MQ_RESIZE_SEQ_SV
`define VIRTIO_LIVE_MQ_RESIZE_SEQ_SV

class virtio_live_mq_resize_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_live_mq_resize_seq)

    rand int unsigned old_pairs;
    rand int unsigned new_pairs;
    rand int unsigned traffic_pkts;

    constraint c_defaults {
        old_pairs    inside {[1:4]};
        new_pairs    inside {[2:8]};
        old_pairs    != new_pairs;
        traffic_pkts inside {[4:16]};
    }

    function new(string name = "virtio_live_mq_resize_seq");
        super.new(name);
        old_pairs    = 2;
        new_pairs    = 4;
        traffic_pkts = 8;
    endfunction

    virtual task body();
        virtio_transaction req;
        virtio_tx_seq tx_s;

        negotiated_features[VIRTIO_NET_F_MQ]      = 1'b1;
        negotiated_features[VIRTIO_NET_F_CTRL_VQ]  = 1'b1;

        // Init with old_pairs
        begin
            virtio_init_seq init_s = virtio_init_seq::type_id::create("init_s");
            init_s.num_queue_pairs    = old_pairs;
            init_s.drv_cfg            = drv_cfg;
            init_s.negotiated_features = negotiated_features;
            init_s.start(m_sequencer);
        end

        send_txn(VIO_TXN_START_DP);

        // Send traffic with old configuration
        tx_s = virtio_tx_seq::type_id::create("tx_old");
        tx_s.num_packets         = traffic_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Resize while traffic active
        `uvm_info(get_type_name(), $sformatf(
            "Resizing MQ: %0d -> %0d pairs", old_pairs, new_pairs), UVM_MEDIUM)
        req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = new_pairs;
        send_configured_txn(req);

        // Send traffic with new configuration
        tx_s = virtio_tx_seq::type_id::create("tx_new");
        tx_s.num_packets         = traffic_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        `uvm_info(get_type_name(), $sformatf(
            "MQ resize complete: %0d -> %0d pairs", old_pairs, new_pairs), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_LIVE_MQ_RESIZE_SEQ_SV
