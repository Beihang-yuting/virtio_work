`ifndef VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV
`define VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV

class virtio_concurrent_vf_traffic_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_concurrent_vf_traffic_seq)

    rand int unsigned num_vfs;
    rand int unsigned pkts_per_vf;

    constraint c_defaults {
        num_vfs    inside {[2:8]};
        pkts_per_vf inside {[4:32]};
    }

    function new(string name = "virtio_concurrent_vf_traffic_seq");
        super.new(name);
        num_vfs    = 4;
        pkts_per_vf = 8;
    endfunction

    virtual task body();
        negotiated_features[VIRTIO_F_SR_IOV] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "Starting concurrent traffic: %0d VFs, %0d pkts each",
            num_vfs, pkts_per_vf), UVM_MEDIUM)

        // All VFs send traffic simultaneously
        fork
            for (int i = 0; i < num_vfs; i++) begin
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
            "Concurrent VF traffic complete: %0d VFs", num_vfs), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV
