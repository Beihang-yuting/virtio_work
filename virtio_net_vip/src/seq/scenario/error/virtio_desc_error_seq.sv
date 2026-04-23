`ifndef VIRTIO_DESC_ERROR_SEQ_SV
`define VIRTIO_DESC_ERROR_SEQ_SV

class virtio_desc_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_desc_error_seq)

    rand virtqueue_error_e err_type;

    function new(string name = "virtio_desc_error_seq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "Injecting descriptor error: %s", err_type.name()), UVM_MEDIUM)

        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = err_type;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Try to send a packet after error injection
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_err");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), $sformatf(
            "Descriptor error test complete: %s", err_type.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_DESC_ERROR_SEQ_SV
