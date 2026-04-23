`ifndef VIRTIO_MIXED_VQ_TYPE_SEQ_SV
`define VIRTIO_MIXED_VQ_TYPE_SEQ_SV

class virtio_mixed_vq_type_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_mixed_vq_type_seq)

    rand int unsigned pkts_per_vf;

    constraint c_defaults {
        pkts_per_vf inside {[2:16]};
    }

    function new(string name = "virtio_mixed_vq_type_seq");
        super.new(name);
        pkts_per_vf = 4;
    endfunction

    virtual task body();
        virtqueue_type_e vf_types[3] = '{VQ_SPLIT, VQ_PACKED, VQ_CUSTOM};

        negotiated_features[VIRTIO_F_SR_IOV]      = 1'b1;
        negotiated_features[VIRTIO_F_RING_PACKED]  = 1'b1;

        // Setup each VF with a different virtqueue type
        for (int i = 0; i < 3; i++) begin
            virtio_queue_setup_seq qs = virtio_queue_setup_seq::type_id::create(
                $sformatf("qs_vf%0d", i));
            qs.queue_id            = i * 2;
            qs.queue_size          = 256;
            qs.vq_type             = vf_types[i];
            qs.drv_cfg             = drv_cfg;
            qs.negotiated_features = negotiated_features;
            qs.start(m_sequencer);
        end

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Parallel traffic on all VFs
        fork
            for (int i = 0; i < 3; i++) begin
                automatic int vf_id = i;
                fork
                    begin
                        virtio_tx_seq tx_s = virtio_tx_seq::type_id::create(
                            $sformatf("tx_vf%0d", vf_id));
                        tx_s.num_packets         = pkts_per_vf;
                        tx_s.queue_id            = vf_id * 2;
                        tx_s.drv_cfg             = drv_cfg;
                        tx_s.negotiated_features = negotiated_features;
                        tx_s.start(m_sequencer);
                    end
                join_none
            end
        join

        `uvm_info(get_type_name(), $sformatf(
            "Mixed VQ: split/packed/custom, %0d pkts each", pkts_per_vf), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_MIXED_VQ_TYPE_SEQ_SV
