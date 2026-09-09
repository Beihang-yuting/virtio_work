`ifndef VIRTIO_MRG_RXBUF_SEQ_SV
`define VIRTIO_MRG_RXBUF_SEQ_SV

// ============================================================================
// virtio_mrg_rxbuf_seq (seq/scenario/dataplane)
//
// MRG_RXBUF(可合并接收缓冲)场景:等待一个需要跨多个 RX buffer 拼接的
// 大报文,验证 driver 按 num_buffers 合并的路径。说明(观察事实):
// large_pkt_size/rx_buf_size/expected_buffers 三个随机量只出现在约束和
// 日志里,body 并未把它们写进事务——大包的实际注入依赖设备侧/测试环境,
// 本序列只负责在驱动侧等待并回收。
// 约束意图:pkt > buf 保证必然发生多 buffer 合并,expected_buffers 按
// 向上取整推导,供日志/调用方对照。
// ============================================================================

class virtio_mrg_rxbuf_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_mrg_rxbuf_seq)

    rand int unsigned large_pkt_size;
    rand int unsigned rx_buf_size;
    rand int unsigned expected_buffers;

    constraint c_defaults {
        rx_buf_size    inside {[256:1024]};
        large_pkt_size inside {[2000:9000]};
        large_pkt_size > rx_buf_size;
        expected_buffers == (large_pkt_size + rx_buf_size - 1) / rx_buf_size;
    }

    // 构造函数:默认 4KB 大包 / 1KB buffer,即 4 个 buffer 合并。
    function new(string name = "virtio_mrg_rxbuf_seq");
        super.new(name);
        large_pkt_size   = 4096;
        rx_buf_size      = 1024;
        expected_buffers = 4;
    endfunction

    // init + 启动数据面后,用 virtio_rx_seq 等待 1 个(合并后的)大报文;
    // 100us 超时,收不到时只体现在日志计数上。
    virtual task body();
        virtio_rx_seq rx_s;

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Wait for large packets needing multi-buffer merge
        rx_s = virtio_rx_seq::type_id::create("rx_s");
        rx_s.expected_count      = 1;
        rx_s.timeout_ns          = 100000;
        rx_s.drv_cfg             = drv_cfg;
        rx_s.negotiated_features = negotiated_features;
        rx_s.start(m_sequencer);

        `uvm_info(get_type_name(), $sformatf(
            "MRG_RXBUF: pkt_size=%0d buf_size=%0d expected_bufs=%0d received=%0d",
            large_pkt_size, rx_buf_size, expected_buffers,
            rx_s.received.size()), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_MRG_RXBUF_SEQ_SV
