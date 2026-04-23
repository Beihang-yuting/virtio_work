`ifndef VIRTIO_KICK_SEQ_SV
`define VIRTIO_KICK_SEQ_SV

class virtio_kick_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_kick_seq)

    rand int unsigned queue_id;

    constraint c_defaults {
        queue_id inside {[0:15]};
    }

    function new(string name = "virtio_kick_seq");
        super.new(name);
        queue_id = 0;
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type  = VIO_TXN_ATOMIC_OP;
        req.atomic_op = ATOMIC_KICK;
        req.queue_id  = queue_id;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Kick: queue=%0d", queue_id), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_KICK_SEQ_SV
