`ifndef VIRTIO_PCIE_CROSS_ERROR_SEQ_SV
`define VIRTIO_PCIE_CROSS_ERROR_SEQ_SV

class virtio_pcie_cross_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_pcie_cross_error_seq)

    rand int unsigned inject_after_pkts;

    constraint c_defaults {
        inject_after_pkts inside {[1:8]};
    }

    function new(string name = "virtio_pcie_cross_error_seq");
        super.new(name);
        inject_after_pkts = 2;
    endfunction

    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Send some normal traffic
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_normal");
            tx_s.num_packets         = inject_after_pkts;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        // Inject PCIe error during virtio operation
        `uvm_info(get_type_name(),
            "Injecting PCIe error during virtio operation", UVM_MEDIUM)
        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = VQ_ERR_USE_AFTER_UNMAP;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Attempt continued operation
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_post");
            tx_s.num_packets         = 1;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), "PCIe cross error test complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_PCIE_CROSS_ERROR_SEQ_SV
