`ifndef VIRTIO_IOMMU_FAULT_SEQ_SV
`define VIRTIO_IOMMU_FAULT_SEQ_SV

// ============================================================================
// virtio_iommu_fault_seq (seq/scenario/error)
//
// IOMMU 故障场景:置起 ACCESS_PLATFORM(设备必须走 IOMMU 翻译)后,按
// fault_phase 把故障映射为描述符读(IOMMU_FAULT_ON_DESC)或数据访问
// (IOMMU_FAULT_ON_DATA)两类 vq_error 注入,再发 1 包 DMA 触发。
// 说明(观察事实):fault_type(具体 IOMMU 故障种类)参与随机化和日志,
// 但注入通道只用 fault_phase 二分——细粒度故障类型由 IOMMU 模型的
// fault rule 机制表达,不经过本事务。
// 依赖:virtio_iommu_model 的故障注入路径 + virtio_tx_seq。
// ============================================================================

class virtio_iommu_fault_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_iommu_fault_seq)

    rand iommu_fault_e       fault_type;
    rand iommu_fault_phase_e fault_phase;

    // 构造函数:故障类型/阶段不给默认值,由随机化或调用方指定。
    function new(string name = "virtio_iommu_fault_seq");
        super.new(name);
    endfunction

    // 置 ACCESS_PLATFORM -> init -> 注入按 phase 归类的 IOMMU 故障 ->
    // 发 1 包触发 DMA;故障命中与上报由 IOMMU 模型/driver 完成。
    virtual task body();
        virtio_transaction req;

        negotiated_features[VIRTIO_F_ACCESS_PLATFORM] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "IOMMU fault: type=%s phase=%s",
            fault_type.name(), fault_phase.name()), UVM_MEDIUM)

        // Inject IOMMU fault rule
        req = virtio_transaction::type_id::create("req");
        req.txn_type      = VIO_TXN_INJECT_ERROR;
        req.vq_error_type = (fault_phase == FAULT_PHASE_DESC_READ)
                            ? VQ_ERR_IOMMU_FAULT_ON_DESC
                            : VQ_ERR_IOMMU_FAULT_ON_DATA;
        req.queue_id      = 0;
        send_configured_txn(req);

        // Trigger DMA operation
        begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_fault");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), "IOMMU fault injection complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_IOMMU_FAULT_SEQ_SV
