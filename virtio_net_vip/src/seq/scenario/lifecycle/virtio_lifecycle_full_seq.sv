`ifndef VIRTIO_LIFECYCLE_FULL_SEQ_SV
`define VIRTIO_LIFECYCLE_FULL_SEQ_SV

class virtio_lifecycle_full_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_lifecycle_full_seq)

    rand int unsigned cycles;
    rand int unsigned pkts_per_cycle;

    constraint c_defaults {
        cycles        inside {[1:5]};
        pkts_per_cycle inside {[1:16]};
    }

    function new(string name = "virtio_lifecycle_full_seq");
        super.new(name);
        cycles         = 1;
        pkts_per_cycle = 4;
    endfunction

    virtual task body();
        repeat (cycles) begin
            // Init
            do_init();

            // Start dataplane
            send_txn(VIO_TXN_START_DP);

            // TX packets
            begin
                virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
                tx_s.num_packets = pkts_per_cycle;
                tx_s.drv_cfg = drv_cfg;
                tx_s.negotiated_features = negotiated_features;
                tx_s.start(m_sequencer);
            end

            // Stop dataplane
            send_txn(VIO_TXN_STOP_DP);

            // Reset
            do_reset();

            `uvm_info(get_type_name(), "Lifecycle cycle complete", UVM_MEDIUM)
        end

        `uvm_info(get_type_name(), $sformatf(
            "Lifecycle full: %0d cycles done", cycles), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_LIFECYCLE_FULL_SEQ_SV
