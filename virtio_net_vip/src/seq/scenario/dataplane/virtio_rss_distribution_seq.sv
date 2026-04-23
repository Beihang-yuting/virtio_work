`ifndef VIRTIO_RSS_DISTRIBUTION_SEQ_SV
`define VIRTIO_RSS_DISTRIBUTION_SEQ_SV

class virtio_rss_distribution_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_rss_distribution_seq)

    rand int unsigned num_flows;
    rand int unsigned num_queues;

    constraint c_defaults {
        num_flows  inside {[4:64]};
        num_queues inside {[2:8]};
    }

    function new(string name = "virtio_rss_distribution_seq");
        super.new(name);
        num_flows  = 16;
        num_queues = 4;
    endfunction

    virtual task body();
        virtio_transaction req;

        do_init();

        // Configure RSS
        req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SET_RSS;
        req.rss_cfg.hash_types = 32'h0000_002B; // IPv4/TCP/UDP
        req.rss_cfg.hash_key_size = 40;
        req.rss_cfg.hash_key = new[40];
        foreach (req.rss_cfg.hash_key[i])
            req.rss_cfg.hash_key[i] = $urandom_range(0, 255);
        req.rss_cfg.indirection_table = new[128];
        foreach (req.rss_cfg.indirection_table[i])
            req.rss_cfg.indirection_table[i] = i % num_queues;
        send_configured_txn(req);

        send_txn(VIO_TXN_START_DP);

        // Send packets with different flow tuples
        for (int i = 0; i < num_flows; i++) begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), $sformatf(
            "RSS: sent %0d flows across %0d queues", num_flows, num_queues), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_RSS_DISTRIBUTION_SEQ_SV
