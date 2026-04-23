`ifndef VIRTIO_BASE_SEQ_SV
`define VIRTIO_BASE_SEQ_SV

// Base class for all virtio sequences
class virtio_base_seq extends uvm_sequence #(virtio_transaction);
    `uvm_object_utils(virtio_base_seq)

    // Common configuration
    virtio_driver_config_t  drv_cfg;
    bit [63:0]              negotiated_features;

    function new(string name = "virtio_base_seq");
        super.new(name);
    endfunction

    // Helper: create and send a transaction by type
    protected virtual task send_txn(virtio_txn_type_e txn_type);
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type = txn_type;
        start_item(req);
        finish_item(req);
    endtask

    // Helper: send a pre-built transaction
    protected virtual task send_configured_txn(virtio_transaction req);
        start_item(req);
        finish_item(req);
    endtask

    // Helper: standard init -> start dataplane
    protected virtual task do_init();
        virtio_init_seq init_s = virtio_init_seq::type_id::create("init_s");
        init_s.drv_cfg = drv_cfg;
        init_s.negotiated_features = negotiated_features;
        init_s.start(m_sequencer);
    endtask

    // Helper: standard reset
    protected virtual task do_reset();
        send_txn(VIO_TXN_RESET);
    endtask

endclass

`endif // VIRTIO_BASE_SEQ_SV
