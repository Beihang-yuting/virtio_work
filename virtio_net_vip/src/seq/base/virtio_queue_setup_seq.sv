`ifndef VIRTIO_QUEUE_SETUP_SEQ_SV
`define VIRTIO_QUEUE_SETUP_SEQ_SV

class virtio_queue_setup_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_queue_setup_seq)

    rand int unsigned     queue_id;
    rand int unsigned     queue_size;
    rand virtqueue_type_e vq_type;

    constraint c_defaults {
        queue_id   inside {[0:15]};
        queue_size inside {16, 32, 64, 128, 256, 512, 1024};
        vq_type == VQ_SPLIT;
    }

    function new(string name = "virtio_queue_setup_seq");
        super.new(name);
        queue_id   = 0;
        queue_size = 256;
        vq_type    = VQ_SPLIT;
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_SETUP_QUEUE;
        req.queue_id   = queue_id;
        req.queue_size = queue_size;
        req.vq_type    = vq_type;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Queue setup: id=%0d size=%0d type=%s",
            queue_id, queue_size, vq_type.name()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_QUEUE_SETUP_SEQ_SV
