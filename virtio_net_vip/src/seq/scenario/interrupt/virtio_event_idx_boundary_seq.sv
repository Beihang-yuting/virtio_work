`ifndef VIRTIO_EVENT_IDX_BOUNDARY_SEQ_SV
`define VIRTIO_EVENT_IDX_BOUNDARY_SEQ_SV

// ============================================================================
// virtio_event_idx_boundary_seq (seq/scenario/interrupt)
//
// EVENT_IDX 16 位回绕边界场景:置起 RING_EVENT_IDX feature 后,分"回绕前/
// 回绕后"两批发包,目标是覆盖 avail/used event index 在 0xFFFF -> 0x0000
// 处的比较逻辑(该处最容易因无符号比较写错而丢中断)。
// 说明(观察事实):本序列只控制两批包的数量,索引是否真正落在回绕点
// 取决于队列此前的累计计数——需配合环境把 index 预置到边界附近,或依赖
// 大计数自然到达;序列本身不做预置。
// ============================================================================

class virtio_event_idx_boundary_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_event_idx_boundary_seq)

    rand int unsigned pkts_before_wrap;
    rand int unsigned pkts_after_wrap;

    constraint c_defaults {
        pkts_before_wrap inside {[1:8]};
        pkts_after_wrap  inside {[1:8]};
    }

    // 构造函数:默认回绕前后各 4 包。
    function new(string name = "virtio_event_idx_boundary_seq");
        super.new(name);
        pkts_before_wrap = 4;
        pkts_after_wrap  = 4;
    endfunction

    // 置 EVENT_IDX -> init -> 两批 tx(边界前/后);中断丢失与否由
    // scoreboard 的 notify 检查项发现。
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
