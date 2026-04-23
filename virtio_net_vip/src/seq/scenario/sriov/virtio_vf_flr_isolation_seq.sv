`ifndef VIRTIO_VF_FLR_ISOLATION_SEQ_SV
`define VIRTIO_VF_FLR_ISOLATION_SEQ_SV

class virtio_vf_flr_isolation_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_vf_flr_isolation_seq)

    rand int unsigned flr_vf;
    rand int unsigned num_vfs;

    constraint c_defaults {
        num_vfs inside {[2:8]};
        flr_vf  < num_vfs;
    }

    function new(string name = "virtio_vf_flr_isolation_seq");
        super.new(name);
        num_vfs = 4;
        flr_vf  = 1;
    endfunction

    virtual task body();
        virtio_transaction req;

        negotiated_features[VIRTIO_F_SR_IOV] = 1'b1;
        do_init();

        // Start traffic on all VFs
        `uvm_info(get_type_name(), $sformatf(
            "Starting traffic on %0d VFs", num_vfs), UVM_MEDIUM)
        for (int i = 0; i < num_vfs; i++) begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create(
                $sformatf("tx_vf_%0d", i));
            tx_s.num_packets         = 4;
            tx_s.queue_id            = i * 2; // TX queue for VF i
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        // FLR on target VF
        `uvm_info(get_type_name(), $sformatf(
            "Issuing FLR on VF %0d", flr_vf), UVM_MEDIUM)
        req = virtio_transaction::type_id::create("flr_req");
        req.txn_type = VIO_TXN_RESET;
        req.queue_id = flr_vf;
        send_configured_txn(req);

        // Verify other VFs still operational
        for (int i = 0; i < num_vfs; i++) begin
            if (i == flr_vf) continue;
            begin
                virtio_tx_seq tx_s = virtio_tx_seq::type_id::create(
                    $sformatf("tx_post_%0d", i));
                tx_s.num_packets         = 2;
                tx_s.queue_id            = i * 2;
                tx_s.drv_cfg             = drv_cfg;
                tx_s.negotiated_features = negotiated_features;
                tx_s.start(m_sequencer);
            end
        end

        `uvm_info(get_type_name(), $sformatf(
            "FLR isolation: VF %0d reset, others unaffected", flr_vf), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_VF_FLR_ISOLATION_SEQ_SV
