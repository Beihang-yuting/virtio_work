`ifndef VIRTIO_INIT_SEQ_SV
`define VIRTIO_INIT_SEQ_SV

class virtio_init_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_init_seq)

    rand int unsigned     num_queue_pairs;
    rand virtqueue_type_e vq_type;
    rand bit [63:0]       driver_features;

    constraint c_defaults {
        num_queue_pairs inside {[1:8]};
        vq_type == VQ_SPLIT;
    }

    function new(string name = "virtio_init_seq");
        super.new(name);
        num_queue_pairs = 1;
        driver_features = '0;
    endfunction

    virtual task body();
        virtio_transaction req = virtio_transaction::type_id::create("req");
        req.txn_type  = VIO_TXN_INIT;
        req.num_pairs = num_queue_pairs;
        req.vq_type   = vq_type;
        req.features  = (driver_features != '0) ? driver_features : negotiated_features;
        send_configured_txn(req);

        `uvm_info(get_type_name(), $sformatf(
            "Init complete: pairs=%0d vq_type=%s features=0x%016h",
            num_queue_pairs, vq_type.name(), req.features), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_INIT_SEQ_SV
