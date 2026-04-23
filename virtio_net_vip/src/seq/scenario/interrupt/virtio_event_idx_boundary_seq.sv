`ifndef VIRTIO_EVENT_IDX_BOUNDARY_SEQ_SV
`define VIRTIO_EVENT_IDX_BOUNDARY_SEQ_SV

class virtio_event_idx_boundary_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_event_idx_boundary_seq)

    rand int unsigned pkts_before_wrap;
    rand int unsigned pkts_after_wrap;

    constraint c_defaults {
        pkts_before_wrap inside {[1:8]};
        pkts_after_wrap  inside {[1:8]};
    }

    function new(string name = "virtio_event_idx_boundary_seq");
        super.new(name);
        pkts_before_wrap = 4;
        pkts_after_wrap  = 4;
    endfunction

    virtual task body();
        virtio_transaction req;

        // Ensure EVENT_IDX feature is negotiated
        negotiated_features[VIRTIO_F_RING_EVENT_IDX] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        // Drive avail_event_idx near 0xFFFF wrap boundary
        // Send packets to advance index to near wrap point
        `uvm_info(get_type_name(),
            "Driving avail index near 16-bit wrap boundary (0xFFFF)", UVM_MEDIUM)

        // Send packets before wrap
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_pre");
            tx_s.num_packets         = pkts_before_wrap;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        // Send packets that should cause 0xFFFF -> 0x0000 wrap
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_post");
            tx_s.num_packets         = pkts_after_wrap;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), $sformatf(
            "EVENT_IDX boundary: before=%0d after=%0d wrap",
            pkts_before_wrap, pkts_after_wrap), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_EVENT_IDX_BOUNDARY_SEQ_SV
