`ifndef VIRTIO_STATUS_ERROR_SEQ_SV
`define VIRTIO_STATUS_ERROR_SEQ_SV

class virtio_status_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_status_error_seq)

    rand status_error_e err_type;

    function new(string name = "virtio_status_error_seq");
        super.new(name);
    endfunction

    virtual task body();
        virtio_transaction req;

        `uvm_info(get_type_name(), $sformatf(
            "Injecting status error: %s", err_type.name()), UVM_MEDIUM)

        case (err_type)
            STATUS_ERR_SKIP_ACKNOWLEDGE: begin
                // Write DRIVER without ACKNOWLEDGE
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
            end

            STATUS_ERR_SKIP_DRIVER: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                // Skip DRIVER, go to FEATURES_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_FEATURES_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_SKIP_FEATURES_OK: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
                // Skip FEATURES_OK, go to DRIVER_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_DRIVER_OK_BEFORE_FEATURES_OK: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
                // DRIVER_OK before FEATURES_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_WRITE_AFTER_FAILED: begin
                // Set FAILED then try DRIVER_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_FAILED;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end
        endcase

        `uvm_info(get_type_name(), $sformatf(
            "Status error injection complete: %s", err_type.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_STATUS_ERROR_SEQ_SV
