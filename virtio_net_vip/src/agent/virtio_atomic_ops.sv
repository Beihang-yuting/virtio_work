`ifndef VIRTIO_ATOMIC_OPS_SV
`define VIRTIO_ATOMIC_OPS_SV

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
    // 设备配置副作用的唯一出口；为空时使用绑定当前 transport 的 common-config
    // 后端。私有 ops 与后续 AF 直配在此注入其他实现。
    virtio_config_backend      config_backend;

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
    protected bit [63:0]         ring_iovas[int unsigned][$];  // queue_id -> ring IOVAs (desc, avail, used)
    // 每个已编程队列的设备视角参数；拆除时原样交回后端，复位后清空。
    protected virtio_queue_program_t queue_programs[int unsigned];

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_atomic_ops");
        super.new(name);
        negotiated_features = '0;
    endfunction

    // A numeric BDF is scoped by the PCIe host domain.  Standalone transports
    // without a frozen identity retain the legacy host0 behavior.
    protected function int unsigned get_iommu_host_id(
        virtio_pci_transport t
    );
        if (t != null)
            return t.iommu_host_id();
        return 0;
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
        return (migration_restore_dma.size() != 0);
    endfunction

    // 返回本 ops 的配置后端：未注入时创建 common-config 后端；每次调用都重新绑定
    // 当前 transport，测试或 Function 替换 transport 后不会访问旧对象。
    protected function virtio_config_backend cfg_backend();
        if (config_backend == null)
            config_backend = virtio_common_cfg_backend::type_id::create(
                {get_name(), "_cfg_backend"});
        config_backend.bind_transport(transport);
        return config_backend;
    endfunction

    // 是否为 DPU 私有环 ops；私有 FSM 用它确认 ops/FSM 配对，无需类型转换。
    virtual function bit uses_private_ring();
        return 0;
    endfunction

    // 生产路径的通知边界：PRE_NOTIFY 故障钩子 → transport 通知（携带 ring 游标
    // next_idx/wrap）→ POST_NOTIFY 故障钩子。不调用 virtqueue::kick()，那只计数；
    // 调用方自己决定是否需要通知（needs_notification 等）。via 为空时用本 ops 的
    // transport，Admin VQ 传入其上下文 transport。
    protected task kick_with_fault(virtqueue_base vq, int unsigned qid,
                                   virtio_pci_transport via = null);
        virtio_pci_transport notify_transport;

        notify_transport = (via != null) ? via : transport;
        void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
        notify_transport.kick(qid, vq.get_notify_next_idx(), vq.get_notify_wrap());
        void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
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
