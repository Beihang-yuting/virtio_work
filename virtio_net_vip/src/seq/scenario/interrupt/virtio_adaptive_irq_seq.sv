`ifndef VIRTIO_ADAPTIVE_IRQ_SEQ_SV
`define VIRTIO_ADAPTIVE_IRQ_SEQ_SV

class virtio_adaptive_irq_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_adaptive_irq_seq)

    rand int unsigned low_rate_pkts;
    rand int unsigned high_rate_pkts;
    rand int unsigned ramp_down_pkts;

    constraint c_defaults {
        low_rate_pkts  inside {[1:4]};
        high_rate_pkts inside {[32:128]};
        ramp_down_pkts inside {[1:4]};
    }

    function new(string name = "virtio_adaptive_irq_seq");
        super.new(name);
        low_rate_pkts  = 2;
        high_rate_pkts = 64;
        ramp_down_pkts = 2;
    endfunction

    virtual task body();
        virtio_tx_seq tx_s;

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Phase 1: Low traffic (IRQ mode expected)
        `uvm_info(get_type_name(), "Phase 1: Low traffic - IRQ mode", UVM_MEDIUM)
        tx_s = virtio_tx_seq::type_id::create("tx_low");
        tx_s.num_packets         = low_rate_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Phase 2: High traffic (should switch to polling)
        `uvm_info(get_type_name(), "Phase 2: High traffic - polling mode", UVM_MEDIUM)
        tx_s = virtio_tx_seq::type_id::create("tx_high");
        tx_s.num_packets         = high_rate_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Phase 3: Ramp down (should switch back to IRQ)
        `uvm_info(get_type_name(), "Phase 3: Ramp down - IRQ mode", UVM_MEDIUM)
        tx_s = virtio_tx_seq::type_id::create("tx_down");
        tx_s.num_packets         = ramp_down_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        `uvm_info(get_type_name(), "Adaptive IRQ test complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_ADAPTIVE_IRQ_SEQ_SV
