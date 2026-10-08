`ifndef VIRTIO_ATOMIC_OPS_SV
`define VIRTIO_ATOMIC_OPS_SV

// 驱动协议在本文件之后编译；ops 只查询其能力。
typedef class virtio_driver_protocol;

// ============================================================================
// virtio_atomic_ops
//
// Low-level atomic operations library for the virtio-net driver VIP.
// One method per real Linux virtio-net driver operation.
//
// Used by:
//   - virtio_auto_fsm (AUTO mode): full lifecycle orchestration
//   - Sequences directly (MANUAL mode): fine-grained control
//
// Depends on:
//   - virtio_pci_transport (PCI register access, kick, feature negotiation)
//   - virtqueue_manager (queue create/destroy/get)
//   - host_mem_manager (buffer allocation)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_wait_policy (timeout/polling)
//   - virtio_net_types.sv (all type/struct definitions)
//   - virtio_net_hdr.sv (header pack/unpack)
//
// 类体按职责拆分（类内 `include，对外仍是同一个类，子类覆写不受影响）：
//   atomic_ops/virtio_atomic_ops_migration_ownership.svh  迁移恢复与 DMA 所有权
//   atomic_ops/virtio_atomic_ops_lifecycle.svh            生命周期、特性协商、中断
//   atomic_ops/virtio_atomic_ops_queue.svh                队列建立与拆除
//   atomic_ops/virtio_atomic_ops_datapath.svh             TX/RX 数据路径
//   atomic_ops/virtio_atomic_ops_ctrl_admin.svh           Admin VQ 与 control VQ
// ============================================================================

class virtio_atomic_ops extends uvm_object;
    `uvm_object_utils(virtio_atomic_ops)

    // ===== External component references (set by agent) =====
    virtio_pci_transport       transport;
    virtqueue_manager          vq_mgr;
    host_mem_manager           mem;
    virtio_iommu_model         iommu;
    virtio_wait_policy         wait_pol;

    // ===== Negotiated state =====
    bit [63:0]                 negotiated_features;

    // ===== Device configuration backend =====
    // 设备配置副作用的唯一出口；由 virtio_function_instance 在提交时按 Function 配置
    // 选择并经协议下发（不经 Function 的装配方须显式注入）。为空即接线错误。
    virtio_config_backend      config_backend;

    // ===== Driver protocol =====
    // 由协议 bind_ops 在 Function 提交时注入；ops 只查询能力（control VQ 等）。
    // 为空（直接构造 ops 的单元测试）时按标准 virtio 处理。
    virtio_driver_protocol     protocol;

    // ===== Internal tracking =====
    // Normal data DMA owns both sides of a mapping.  Retaining only the IOVA
    // made reset/teardown able to unmap (at best) while leaking the host
    // buffer that backs it.  Keep the ownership pair together until one
    // completion or a verified device reset retires it.
    typedef struct {
        int unsigned host_id;
        bit [15:0] bdf;
        bit [63:0] gpa;
        bit [63:0] iova;
    } normal_dma_record_t;
    protected normal_dma_record_t tx_dma_map[int unsigned][$];
    protected normal_dma_record_t rx_dma_map[int unsigned][$];
    // Migration payloads are recreated after reset rather than being tied to
    // a pre-freeze queue.  They still have normal DMA ownership and must be
    // retired by every later ordinary device reset.
    protected normal_dma_record_t migration_restore_dma[$];
    protected bit [63:0]         ring_iovas[int unsigned][$];  // queue_id -> 每个 ring 区一个 IOVA
    // 每个已编程队列的设备视角参数；拆除时原样交回后端，复位后清空。
    protected virtio_queue_program_t queue_programs[int unsigned];
    // control VQ 超时且设备未确认复位时隔离的缓冲（ctrl_send 的 dma_set 移入）。期间
    // ctrl_send 拒绝提交；只有 device_reset_verified 确认复位后才解除映射并释放。
    protected bit [63:0] ctrl_quarantined_iovas[$];
    protected bit [63:0] ctrl_quarantined_gpas[$];
    // control VQ 不是“当前最大队列号”：MQ 下它由设备上报的最大队列对数决定，动态
    // 扩缩容后也不移动。建队成功时显式保存身份，ctrl_send 只使用这份生命周期记录。
    // 任一已发布命令超时都会使设备结果不确定，pending 保持到 verified device reset
    // 成功；即使局部 Q_RESET/重建完成，普通建队或后续 control 命令也不能绕过边界。
    protected bit          ctrl_queue_id_valid;
    protected int unsigned ctrl_queue_id_value;
    protected bit          ctrl_recovery_pending;
    // 队列回滚时若后端无法确认单队列已停止，只有 verified Function reset 才能证明
    // 设备不再访问仍受 Host 管理的 ring。复位失败后保持该标志并拒绝继续建队或发布
    // control 命令，避免新生命周期与旧 DMA 所有权重叠；成功的整设备复位统一清零。
    protected bit          queue_recovery_pending;
    // 最近一次批量建队回滚是否升级为整 Function 复位。它与 recovery pending 组合
    // 给调用方完整结果：attempted=1/pending=0 表示复位成功且全部 Function 队列已清空；
    // attempted=1/pending=1 表示复位失败并保留 DMA；attempted=0 表示窄范围回滚。
    protected bit          queue_rollback_function_reset_attempted;

    // 构造 atomic ops：输入 name 仅用于 UVM 对象命名；初始化协商结果、control VQ
    // 身份以及队列恢复闸门，不访问 transport、Host memory 或设备，因此没有外部副作用。
    function new(string name = "virtio_atomic_ops");
        super.new(name);
        negotiated_features = '0;
        ctrl_queue_id_valid = 0;
        ctrl_queue_id_value = 0;
        ctrl_recovery_pending = 0;
        queue_recovery_pending = 0;
        queue_rollback_function_reset_attempted = 0;
    endfunction

    // 返回当前 Function 在本次设备生命周期中显式登记的 control VQ 编号。返回 1 时
    // queue_id 有效；尚未成功建立 control VQ 或 verified reset 已清除身份时返回 0，
    // 输出同时清零。该只读接口供诊断和测试使用，不授予队列所有权。
    function bit get_control_queue_id(output int unsigned queue_id);
        queue_id = ctrl_queue_id_valid ? ctrl_queue_id_value : 0;
        return ctrl_queue_id_valid;
    endfunction

    // 报告 control VQ 是否必须先做 verified device reset。命令发布后超时意味着设备
    // 副作用不确定，即使单队列停止和重建成功也会置位；停止失败或重建失败同样置位。
    // 只有确认完成的整设备复位清零。
    function bit control_vq_requires_recovery();
        return ctrl_recovery_pending;
    endfunction

    // 只读报告普通数据队列是否仍等待 verified Function reset。返回 1 表示此前的
    // 回滚未能确认停止全部 DMA，调用方只能重试 device_reset_verified，不能继续建队。
    function bit queues_require_recovery();
        return queue_recovery_pending;
    endfunction

    // 返回最近一次 setup_queue_range/setup_all_queues 失败回滚是否尝试过 verified
    // Function reset。调用方应同时读取 queues_require_recovery() 区分成功与失败；
    // 下一次批量建队开始时该标志清零。
    function bit queue_rollback_used_function_reset();
        return queue_rollback_function_reset_attempted;
    endfunction

    // A numeric BDF is scoped by the PCIe host domain taken from the bound
    // transport's frozen identity; there is no implicit host0 fallback.
    protected function int unsigned get_iommu_host_id(
        virtio_pci_transport t
    );
        if (t == null) begin
            `uvm_fatal("ATOMIC_OPS",
                "DMA host domain requested without a bound transport")
            return 0;
        end
        return t.iommu_host_id();
    endfunction

    // Retire one ordinary data-DMA ownership record.  This is deliberately
    // separate from ring/indirect-table ownership, which remains owned by
    // the virtqueue implementation.
    protected function void retire_normal_dma_record(
        normal_dma_record_t record
    );
        iommu.unmap_for_host(record.host_id, record.bdf, record.iova);
        mem.free(record.gpa);
    endfunction

    // 批量退休普通 DMA 所有权记录（逐条 unmap+free），并清空调用方队列。
    protected function void retire_normal_dma_records(
        ref normal_dma_record_t records[$]
    );
        foreach (records[i]) begin
            retire_normal_dma_record(records[i]);
        end
        records.delete();
    endfunction

    // 是否仍有未退休的普通 DMA 所有权（任一 TX/RX 队列的 map 非空，
    // 或迁移恢复暂存列表非空）；device_reset 用它判断是否需要 mem 上下文。
    protected function bit has_pending_normal_dma();
        foreach (tx_dma_map[qid]) begin
            if (tx_dma_map[qid].size() != 0)
                return 1;
        end
        foreach (rx_dma_map[qid]) begin
            if (rx_dma_map[qid].size() != 0)
                return 1;
        end
        return (migration_restore_dma.size() != 0) || (ctrl_quarantined_gpas.size() != 0);
    endfunction

    // 返回 Function 下发的配置后端；ops 不自建后端，未下发时 UVM_FATAL。每次调用都
    // 重新绑定当前 transport，测试或 Function 替换 transport 后不会访问旧对象。
    protected function virtio_config_backend cfg_backend();
        if (config_backend == null) begin
            `uvm_fatal("ATOMIC_OPS",
                "no config backend selected; virtio_function_instance hands one down at commit")
            return null;
        end
        config_backend.bind_transport(transport);
        return config_backend;
    endfunction

    // 只读导出已编程队列的设备视角参数（诊断/测试）；未建队返回 0 且输出空程序。
    function bit get_queue_program(int unsigned queue_id,
                                   output virtio_queue_program_t q);
        q = virtio_empty_queue_program();
        if (!queue_programs.exists(queue_id))
            return 0;
        q = queue_programs[queue_id];
        return 1;
    endfunction

    // 后端调用使用的队列编程参数：已建队返回记录值，否则返回只含 host/BDF/队列号的空程序
    // （后端据此判定该队列未配置）。
    protected function virtio_queue_program_t queue_program_of(int unsigned queue_id);
        virtio_queue_program_t qprog;

        if (queue_programs.exists(queue_id))
            return queue_programs[queue_id];
        qprog = virtio_empty_queue_program();
        qprog.host_id  = get_iommu_host_id(transport);
        qprog.bdf      = transport.bdf;
        qprog.queue_id = queue_id;
        return qprog;
    endfunction

    // 是否仍有已编程队列；驱动协议据此拒绝对活动 ops 重新冻结配置。
    function bit has_active_queues();
        return queue_programs.num() != 0;
    endfunction

    // ring 内地址 → 设备视角 IOVA：落在第 i 个已映射 ring 区内时按区内偏移换算；
    // 0（私有环无 driver 区）或不在任何区内返回 0。
    protected function bit [63:0] ring_iova_of(bit [63:0] gpa, bit [63:0] gpas[$],
                                               int unsigned sizes[$],
                                               bit [63:0] iovas[$]);
        if (gpa == 0)
            return 0;
        foreach (gpas[i])
            if ((gpa >= gpas[i]) && (gpa < gpas[i] + sizes[i]))
                return iovas[i] + (gpa - gpas[i]);
        return 0;
    endfunction

    // 生产路径的通知边界：PRE_NOTIFY 故障钩子 → 队列格式发布（prepare_notify）→
    // 通知（携带 ring 游标 next_idx/wrap）→ POST_NOTIFY 故障钩子。不调用
    // virtqueue::kick()，那只计数；调用方自己决定是否需要通知。via 为空时经配置
    // 后端通知（标准：notify capability；私有：私有 doorbell），Admin VQ 传入其上下文 transport。
    protected task kick_with_fault(virtqueue_base vq, int unsigned qid,
                                   virtio_pci_transport via = null);
        virtio_config_backend backend;

        void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
        if (vq.prepare_notify()) begin
            if (via != null)
                via.kick(qid, vq.get_notify_next_idx(), vq.get_notify_wrap());
            else begin
                backend = cfg_backend();
                backend.notify_queue(queue_program_of(qid), vq.get_notify_next_idx(),
                                     vq.get_notify_wrap());
            end
        end
        void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
    endtask

    // MANUAL ATOMIC_KICK 的生产入口：对已建队列无条件发 doorbell（经 PRE/POST_NOTIFY
    // 故障钩子，携带当前 ring 游标），不做事件抑制判断；队列不存在时报错且不通知。
    virtual task kick_queue(int unsigned queue_id);
        if ((vq_mgr == null) || !vq_mgr.has_queue(queue_id)) begin
            `uvm_error("ATOMIC_OPS", $sformatf("kick_queue: queue %0d not found", queue_id))
            return;
        end
        kick_with_fault(vq_mgr.get_queue(queue_id), queue_id);
    endtask

    // 把 buffer set 中的全部缓冲按添加顺序转成普通 DMA 所有权记录，追加到
    // records，然后让 set 放弃所有权。之后只由完成路径或已确认的设备复位退休。
    // 调用方保证每一项都已映射（只在 add_buf 成功后调用）。
    protected function void adopt_dma_set(
        virtio_dma_buffer_set   dma_set,
        ref normal_dma_record_t records[$]
    );
        normal_dma_record_t record;

        for (int unsigned i = 0; i < dma_set.count(); i++) begin
            record.host_id = dma_set.get_host_id();
            record.bdf     = dma_set.get_bdf();
            record.gpa     = dma_set.get_gpa(i);
            record.iova    = dma_set.get_iova(i);
            records.push_back(record);
        end
        dma_set.disown();
    endfunction

    `include "agent/atomic_ops/virtio_atomic_ops_migration_ownership.svh"
    `include "agent/atomic_ops/virtio_atomic_ops_lifecycle.svh"
    `include "agent/atomic_ops/virtio_atomic_ops_queue.svh"
    `include "agent/atomic_ops/virtio_atomic_ops_datapath.svh"
    `include "agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh"

endclass : virtio_atomic_ops

`endif // VIRTIO_ATOMIC_OPS_SV
