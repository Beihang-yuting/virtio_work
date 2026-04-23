`ifndef VIRTIO_LIVE_MIGRATION_SEQ_SV
`define VIRTIO_LIVE_MIGRATION_SEQ_SV

class virtio_live_migration_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_live_migration_seq)

    rand int unsigned pre_freeze_pkts;
    rand int unsigned post_restore_pkts;

    constraint c_defaults {
        pre_freeze_pkts   inside {[1:16]};
        post_restore_pkts inside {[1:16]};
    }

    function new(string name = "virtio_live_migration_seq");
        super.new(name);
        pre_freeze_pkts   = 4;
        post_restore_pkts = 4;
    endfunction

    virtual task body();
        virtio_transaction req;
        virtio_tx_seq tx_s;

        // Init and start dataplane
        do_init();
        send_txn(VIO_TXN_START_DP);

        // Inject traffic before migration
        tx_s = virtio_tx_seq::type_id::create("tx_pre");
        tx_s.num_packets         = pre_freeze_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Freeze device
        `uvm_info(get_type_name(), "Freezing device for migration", UVM_MEDIUM)
        send_txn(VIO_TXN_FREEZE);

        // Verify snapshot is captured
        req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_FREEZE;
        send_configured_txn(req);

        // Reset (simulate migration to new host)
        `uvm_info(get_type_name(), "Resetting for restore", UVM_MEDIUM)
        do_reset();

        // Restore
        `uvm_info(get_type_name(), "Restoring device state", UVM_MEDIUM)
        send_txn(VIO_TXN_RESTORE);

        // Verify continued operation
        tx_s = virtio_tx_seq::type_id::create("tx_post");
        tx_s.num_packets         = post_restore_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        `uvm_info(get_type_name(), $sformatf(
            "Live migration: pre=%0d post=%0d packets",
            pre_freeze_pkts, post_restore_pkts), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_LIVE_MIGRATION_SEQ_SV
