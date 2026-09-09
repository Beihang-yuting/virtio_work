`ifndef VIRTIO_PCIE_CROSS_ERROR_SEQ_SV
`define VIRTIO_PCIE_CROSS_ERROR_SEQ_SV

// ============================================================================
// virtio_pcie_cross_error_seq (seq/scenario/error)
//
// PCIe/virtio 跨层错误场景:先跑 inject_after_pkts 个正常包建立在途状态,
// 再注入 VQ_ERR_USE_AFTER_UNMAP(用已解除 DMA 映射的地址继续访问——即
// 用 virtqueue 错误模拟 PCIe 侧访问失效映射的效果),随后再发 1 包验证
// 错误之后驱动栈还能继续工作/正确报错。
// 取舍:不直接操作 PCIe TLP 层,而是选一个语义等价的 vq_error,保持序列
// 只依赖 virtio 事务接口。
// 约束意图:先发 1..8 个正常包,保证注入点落在"有历史流量"的状态上。
// ============================================================================

class virtio_pcie_cross_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_pcie_cross_error_seq)

    rand int unsigned inject_after_pkts;

    constraint c_defaults {
        inject_after_pkts inside {[1:8]};
    }

    // 构造函数:默认先发 2 个正常包再注入。
    function new(string name = "virtio_pcie_cross_error_seq");
        super.new(name);
        inject_after_pkts = 2;
    endfunction

    // 正常流量 -> 注入 USE_AFTER_UNMAP -> 再发 1 包验证存活;错误检出由
    // scoreboard/IOMMU 模型完成。
    virtual task body();
        virtio_transaction req;

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Send some normal traffic
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_normal");
            tx_s.num_packets         = inject_after_pkts;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        // Inject PCIe error during virtio operation
        `uvm_info(get_type_name(),
            "Injecting PCIe error during virtio operation", UVM_MEDIUM)
        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = VQ_ERR_USE_AFTER_UNMAP;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Attempt continued operation
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_post");
            tx_s.num_packets         = 1;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), "PCIe cross error test complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_PCIE_CROSS_ERROR_SEQ_SV
