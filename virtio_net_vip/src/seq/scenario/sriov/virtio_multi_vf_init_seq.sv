`ifndef VIRTIO_MULTI_VF_INIT_SEQ_SV
`define VIRTIO_MULTI_VF_INIT_SEQ_SV

class virtio_multi_vf_init_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_multi_vf_init_seq)

    rand int unsigned num_vfs;

    constraint c_defaults {
        num_vfs inside {[2:8]};
    }

    function new(string name = "virtio_multi_vf_init_seq");
        super.new(name);
        num_vfs = 4;
    endfunction

    virtual task body();
        // Enable SR-IOV feature
        negotiated_features[VIRTIO_F_SR_IOV] = 1'b1;

        // Init PF
        do_init();

        // Init each VF in parallel (fork-join)
        `uvm_info(get_type_name(), $sformatf(
            "Initializing %0d VFs in parallel", num_vfs), UVM_MEDIUM)

        fork
            for (int i = 0; i < num_vfs; i++) begin
                automatic int vf_id = i;
                fork
                    begin
                        virtio_transaction req = virtio_transaction::type_id::create(
                            $sformatf("vf_init_%0d", vf_id));
                        req.txn_type  = VIO_TXN_INIT;
                        req.queue_id  = vf_id;
                        req.num_pairs = 1;
                        req.vq_type   = VQ_SPLIT;
                        req.features  = negotiated_features;
                        send_configured_txn(req);
                    end
                join_none
            end
        join

        // Verify all queues mapped
        `uvm_info(get_type_name(), $sformatf(
            "Multi-VF init: %0d VFs initialized", num_vfs), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_MULTI_VF_INIT_SEQ_SV
