`ifndef VIRTIO_ADAPTIVE_IRQ_SEQ_SV
`define VIRTIO_ADAPTIVE_IRQ_SEQ_SV

// ============================================================================
// virtio_adaptive_irq_seq (seq/scenario/interrupt)
//
// 自适应中断(IRQ<->polling 切换)场景:用三段流量画出速率包络——低速
// (期望驱动走 IRQ 模式)-> 高速(期望切到 polling/NAPI)-> 降速(期望
// 切回 IRQ)。本序列只负责制造速率变化,模式切换发生在 driver 的中断
// 管理逻辑里,是否按预期切换由覆盖率/性能监控组件观察。
// 约束意图:低速段 1..4 包与高速段 32..128 包拉开量级差距,保证跨过
// 切换阈值。
// ============================================================================

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

    // 构造函数:默认 2/64/2 的三段流量包络。
    function new(string name = "virtio_adaptive_irq_seq");
        super.new(name);
        low_rate_pkts  = 2;
        high_rate_pkts = 64;
        ramp_down_pkts = 2;
    endfunction

    // 依次跑低速/高速/降速三段 tx 流量;不在序列内断言中断模式,只提供
    // 激励曲线。
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
