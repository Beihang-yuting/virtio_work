`ifndef VIRTIO_LIFECYCLE_FULL_SEQ_SV
`define VIRTIO_LIFECYCLE_FULL_SEQ_SV

// ============================================================================
// virtio_lifecycle_full_seq (seq/scenario/lifecycle)
//
// 完整生命周期循环场景:init -> 启动数据面 -> TX -> 停数据面 -> reset,
// 重复 cycles 轮。目标是验证驱动栈可以被反复拉起/拆除而不泄漏状态
// (描述符、DMA 映射、队列内存)——泄漏由 env 的 leak_check/报告阶段
// 发现,序列只负责把生命周期完整走通。
// 约束意图:1..5 轮、每轮 1..16 包,重点在轮数而非流量强度。
// ============================================================================

class virtio_lifecycle_full_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_lifecycle_full_seq)

    rand int unsigned cycles;
    rand int unsigned pkts_per_cycle;

    constraint c_defaults {
        cycles        inside {[1:5]};
        pkts_per_cycle inside {[1:16]};
    }

    // 构造函数:默认 1 轮、每轮 4 包。
    function new(string name = "virtio_lifecycle_full_seq");
        super.new(name);
        cycles         = 1;
        pkts_per_cycle = 4;
    endfunction

    // 循环执行完整 init/traffic/stop/reset;每轮之间不保留任何状态,
    // 全部靠 do_init 重建。
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
