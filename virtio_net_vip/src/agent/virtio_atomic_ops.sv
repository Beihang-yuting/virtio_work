`ifndef VIRTIO_ATOMIC_OPS_SV
`define VIRTIO_ATOMIC_OPS_SV

// 驱动协议在本文件之后编译；ops 只查询其能力。
typedef class virtio_driver_protocol;

// ============================================================================
// virtio_atomic_ops
//
// 所属src/agent：统一生命周期与TX/RX操作；借用transport/队列管理器，持有
// 每包DMA直到完成或已确认的复位。TX空间等待不分配DMA，也不改变待发报文。
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

    // 完整报文采样器由 Function ops 持有；sidecar 只借用 packet_hub，不能
    // 通过它改变 DMA、ring 或通知状态。Function identity 是冻结 DPU 快照的值副本，
    // 用于把同号 local_qid 隔离到不同 Host/PF/VF。
    virtio_packet_hub          packet_hub;
    dpu_function_key_t         function_key;
    dpu_service_key_t          service_key;
    bit                         function_identity_valid;
    longint unsigned           packet_sequence;
    longint unsigned           packet_reset_epoch;

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

    // RX 统计归 ops 所有，覆盖 FSM 和 dataplane 两种入口；保留整个对象生命周期累计值。
    // polls 只计通过完成门禁后的非零预算调用，empty 计其中未交付帧的调用，不打印空轮询。
    protected longint unsigned	rx_polls          = 0;
    protected longint unsigned	rx_empty_polls    = 0;
    protected longint unsigned	rx_posted_buffers = 0;
    protected longint unsigned	rx_packets        = 0;
    protected longint unsigned	rx_bytes          = 0;

    // 由 agent 在 report_phase 汇总；未使用 RX 时保持安静，不清零计数或访问 DUT。
    extern function void print_rx_stats();

    // 绑定或替换本 Function 的报文 hub；只允许装配阶段调用，不改变队列资源。
    extern function void bind_packet_hub(virtio_packet_hub hub);

    // 发布 TX/RX 完整样本；输入来自实际 DMA 字节/合并后的 RX frame，失败时
    // 只跳过可选观察，不影响数据路径的 descriptor、notify 或 DMA 所有权。
    extern protected function void publish_tx_packet(
        int unsigned queue_id,
        byte unsigned frame_bytes[],
        virtio_net_hdr_t net_hdr,
        vio_private_tx_offload_t private_offload,
        int unsigned descriptor_id,
        string packet_key
    );
    extern protected function void publish_rx_frame(
        int unsigned queue_id,
        virtio_rx_frame_t frame
    );

    // 只登记尚未检查通知的TX发布；批末、等待空位前清除，队列释放时一并清除。
    protected bit	tx_notify_pending[int unsigned];
    // Migration payloads are recreated after reset rather than being tied to
    // a pre-freeze queue.  They still have normal DMA ownership and must be
    // retired by every later ordinary device reset.
    protected normal_dma_record_t migration_restore_dma[$];
    protected bit [63:0]         ring_iovas[int unsigned][$];  // queue_id -> 每个 ring 区一个 IOVA
    // 已本地准备队列的设备视角参数；外部会话另有确认闸门，记录存在不等于设备可用。
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

    // 外部会话的确认/回收权绑定来源对象与代号；未确认时 ops 自身拒绝提交和完成。
    local uvm_object	external_owner;
    local longint unsigned	external_generation;
    local bit	external_active;
    local vio_service_requirement_t	external_requirement;

    // 空位不足时通过原完成入口回收，保留轮询/MSI-X策略；超时只针对当前包。
    // 不可能容纳的请求立即报错；队列被释放或更换时返回失败，不操作旧ring。
    extern protected task wait_tx_space(virtqueue_base	vq, int unsigned	needed,
        int unsigned	timeout_ns, output bit	ready);

    // 将本队列尚未通知的TX一起发布；标准模式遵循event suppression，Custom必发尾指针。
    // 没有新提交时为空操作，调用方不提供或猜测tail/wrap。
    extern task flush_tx(int unsigned	queue_id);

    // 是否由用户配置设备；协议查询避免运行路径重复类型转换。
    function bit uses_external_configuration();
        return (protocol != null) && protocol.is_external_configuration();
    endfunction

    // 建立尚未交付的本地会话；活动资源不允许覆盖，新代只能在释放后开始。
    function bit begin_external_session(input uvm_object owner,
        input longint unsigned generation, input vio_service_requirement_t requirement,
        output string why);
        why = "";
        if (!uses_external_configuration() || owner == null || generation == 0 ||
            external_owner != null || has_active_queues()) begin
            why = "external session requires unused bound ops and a valid origin/generation";
            return 0;
        end
        external_owner = owner;
        external_generation = generation;
        external_requirement = requirement;
        external_active = 0;
        negotiated_features = requirement.behavior.driver_features;
        return 1;
    endfunction

    // 全量匹配本代实际队列与映射后才可确认；不接受只改 FSM_READY 的捷径。
    function bit validate_external_session(input uvm_object owner,
        input longint unsigned generation, input int unsigned qids[$], output string why);
        bit	seen[int unsigned];
        virtqueue_base	vq;
        bit [63:0]	gpas[$];
        int unsigned	sizes[$];
        bit [63:0]	iovas[$];
        iommu_mapping_t	mapping;

        why = "";
        if (owner == null || owner != external_owner || generation != external_generation ||
            qids.size() != queue_programs.num()) begin
            why = "external origin/generation or complete queue set mismatch";
            return 0;
        end
        foreach (qids[i]) begin
            if (seen.exists(qids[i]) || !queue_programs.exists(qids[i]) ||
                !ring_iovas.exists(qids[i])) begin
                why = "external queue mapping missing or duplicated";
                return 0;
            end
            seen[qids[i]] = 1;
            vq = vq_mgr.get_queue(qids[i]);
            if (vq == null || vq.mem != mem || vq.iommu != iommu ||
                vq.host_id != transport.iommu_host_id() || vq.bdf != transport.bdf ||
                vq.queue_size != queue_programs[qids[i]].queue_size) begin
                why = "external queue owner or geometry changed";
                return 0;
            end
            if (!get_local_ring_regions(qids[i], gpas, sizes, iovas) ||
                ring_iova_of(vq.desc_table_addr, gpas, sizes, iovas) != queue_programs[qids[i]].desc_iova ||
                ring_iova_of(vq.driver_ring_addr, gpas, sizes, iovas) != queue_programs[qids[i]].driver_iova ||
                ring_iova_of(vq.device_ring_addr, gpas, sizes, iovas) != queue_programs[qids[i]].device_iova) begin
                why = "external queue addresses changed";
                return 0;
            end
            foreach (iovas[r]) begin
                if (!iommu.get_live_mapping_for_host(transport.iommu_host_id(), transport.bdf, iovas[r], mapping) ||
                    mapping.gpa != gpas[r] || mapping.size != sizes[r] || mapping.dir != DMA_BIDIRECTIONAL) begin
                    why = "external queue mapping no longer live";
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 已验证完整会话的激活入口；来源和队列再次匹配，防止准备后对象被替换。
    function bit confirm_external_session(input uvm_object owner,
        input longint unsigned generation, input int unsigned qids[$], output string why);
        virtqueue_base	vq;

        if (!validate_external_session(owner, generation, qids, why)) return 0;
        foreach (qids[i]) begin
            vq = vq_mgr.get_queue(qids[i]);
            vq.state = VQ_ENABLED;
            vq.queue_enable = 1;
        end
        external_active = 1;
        return 1;
    endfunction

	// 只认证会话凭证，允许几何已损坏的所有者安全关闭业务门禁。
	function bit owns_external_session(input uvm_object owner, input longint unsigned generation);
		return owner != null && owner == external_owner && generation == external_generation;
	endfunction

	// 仅撤销业务凭证；失败配置保留所有 ring、映射和 pending DMA。
	function bit revoke_external_session(input uvm_object owner,
		input longint unsigned generation, output string why);
		why = "";
		if (!owns_external_session(owner, generation)) begin
			why = "external revoke origin/generation mismatch";
			return 0;
		end
		external_active = 0;
		return 1;
	endfunction

    // 环境已确认 workers 停止和 DUT quiesced 后回收；未交付失败也使用同一资源出口。
    function bit release_external_session(input uvm_object owner,
        input longint unsigned generation, output string why);
        int unsigned	qids[$];

        why = "";
        if (owner == null || owner != external_owner || generation != external_generation) begin
            why = "external release origin/generation mismatch";
            return 0;
        end
        external_active = 0;
        foreach (queue_programs[q]) qids.push_back(q);
        foreach (qids[i]) release_local_queue(qids[i]);
        external_owner = null;
        external_generation = 0;
        return 1;
    endfunction

    // FSM 和 MANUAL 共用就绪门禁；方向未启用或队列不属于本代则拒绝。
    function bit external_queue_ready(input int unsigned qid);
        return !uses_external_configuration() || (external_active &&
            queue_programs.exists(qid) &&
            (qid[0] ? external_requirement.tx_enable : external_requirement.rx_enable));
    endfunction

    // 外部完成机制固定；每队列独立消费 retained 中断许可，不存在 timeout 轮询兜底。
    function bit completion_permitted(input int unsigned qid);
        if (!external_queue_ready(qid)) return 0;
        if (!uses_external_configuration() ||
            external_requirement.completion_mode == VIRTIO_COMPLETION_POLLING) return 1;
        return transport.notify_mgr.consume_external_pending(qid);
    endfunction

    // 公共运行策略只读查询，不将可变配置句柄传给后台 worker。
    function bit external_direction_enabled(input bit tx);
        return !uses_external_configuration() ||
            (tx ? external_requirement.tx_enable : external_requirement.rx_enable);
    endfunction

    // 完成预算未耗尽时许可已消费；预算耗尽时保留下一轮 drain，直到 CQ 确认空。
    function void retain_external_completion(input int unsigned qid);
        if (uses_external_configuration() &&
            external_requirement.completion_mode == VIRTIO_COMPLETION_MSIX)
            transport.notify_mgr.retain_external_pending(qid);
    endfunction

    // 构造 atomic ops：输入 name 仅用于 UVM 对象命名；初始化协商结果、control VQ
    // 身份以及队列恢复闸门，不访问 transport、Host memory 或设备，因此没有外部副作用。
    function new(string name = "virtio_atomic_ops");
        super.new(name);
        negotiated_features = '0;
        packet_hub = virtio_packet_hub::type_id::create({name, "_packet_hub"});
        function_identity_valid = 0;
        packet_sequence = 0;
        packet_reset_epoch = 0;
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

    // 只读导出本地队列参数（诊断/测试）；准备后即可读取，但不能据此绕过确认。
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

        if (!external_queue_ready(qid)) return;
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

// 按真实格式求出总槽数与 data 分段。均分的余数放在前几段；随机每一步都为
// 剩余段保留合法空间，因此不产生零长度、截断或额外重抽。全部校验先于 DMA 分配。
function bit virtio_atomic_ops::plan_tx_segments(
    virtqueue_base	vq,
    int unsigned	packet_length,
    int unsigned	header_size,
    bit		tso,
    bit		indirect,
    virtio_tx_seg_t	request,
    output int unsigned	lengths[$],
    output int unsigned	needed,
    output string	why
);
    bit			private_format;
    virtqueue_type_e		format;
    int unsigned		fixed_slots;
    int unsigned		capacity;
    int unsigned		max_length;
    int unsigned		min_data;
    int unsigned		max_data;
    int unsigned		data_count;
    int unsigned		count;
    int unsigned		remaining;
    int unsigned		left;
    int unsigned		low;
    int unsigned		high;
    int unsigned		length;
    longint unsigned	reserve_limit;

    why = "";
    needed = 0;
    lengths.delete();
    format = vq.descriptor_format();
    private_format = format == VQ_CUSTOM;
    fixed_slots = private_format ? int'(tso) : int'(header_size != 0);
    capacity = private_format ? vq.queue_size - 1 : vq.queue_size;
    max_length = private_format ? 65536 : 32'hffff_ffff;
    min_data = int'((longint'(packet_length) + max_length - 1) / max_length);
    max_data = private_format ? 7 : packet_length;
    if (max_data > packet_length) max_data = packet_length;
    if (!indirect && max_data + fixed_slots > capacity)
        max_data = (capacity > fixed_slots) ? capacity - fixed_slots : 0;
    count = request.count_set ? request.desc_count : min_data + fixed_slots;

    if (!(request.mode inside {VIO_SEG_EQUAL, VIO_SEG_RANDOM})) begin
        why = $sformatf("queue=%0d invalid seg_mode=%0d", vq.queue_id, request.mode);
        return 0;
    end
    if (indirect && (private_format || request.count_set)) begin
        why = $sformatf("queue=%0d desc_count requires direct descriptors", vq.queue_id);
        return 0;
    end
    if (packet_length == 0 || max_data < min_data ||
        count < min_data + fixed_slots || count > max_data + fixed_slots) begin
        why = $sformatf(
            "queue=%0d format=%s packet_length=%0d desc_count=%0d allowed=[%0d:%0d]",
            vq.queue_id, format.name(), packet_length,
            count, min_data + fixed_slots, max_data + fixed_slots);
        return 0;
    end

    data_count = count - fixed_slots;
    needed = indirect ? 1 : count;
    remaining = packet_length;
    for (int unsigned i = 0; i < data_count; i++) begin
        left = data_count - i;
        if (request.mode == VIO_SEG_EQUAL) begin
            length = packet_length / data_count + int'(i < packet_length % data_count);
        end else begin
            reserve_limit = longint'(left - 1) * max_length;
            low = (remaining > reserve_limit) ? int'(remaining - reserve_limit) : 1;
            high = remaining - (left - 1);
            if (high > max_length) high = max_length;
            length = $urandom_range(high, low);
        end
        lengths.push_back(length);
        remaining -= length;
    end
    return 1;
endfunction

// 功能：绑定 Function 级 packet hub。
// 输入/输出：输入新的 hub 句柄；无返回值。
// 边界/副作用：null 被忽略并保留已有 hub；不会重置 packet 序号或清空订阅。
function void virtio_atomic_ops::bind_packet_hub(virtio_packet_hub hub);
    if (hub != null)
        packet_hub = hub;
endfunction

// 功能：发布 TX 的完整 Ethernet payload 和 Virtio/Custom 元数据。
// 输入/输出：输入队列、实际 DMA payload、header、Custom offload、descriptor 和
// 可选用户 packet key；无返回值。
// 边界/副作用：未绑定 hub 时静默跳过；样本只复制值，不延长 DMA 资源生命周期。
function void virtio_atomic_ops::publish_tx_packet(
    int unsigned queue_id,
    byte unsigned frame_bytes[],
    virtio_net_hdr_t net_hdr,
    vio_private_tx_offload_t private_offload,
    int unsigned descriptor_id,
    string packet_key
);
    virtio_packet_sample sample;
    virtio_queue_program_t qprog;

    if (packet_hub == null) return;
    sample = virtio_packet_sample::type_id::create("vtx_packet");
    sample.direction       = VIO_PACKET_VTX;
    sample.host_id         = get_iommu_host_id(transport);
    sample.bdf             = transport.bdf;
    sample.is_vf           = transport.is_vf;
    sample.vf_id           = transport.vf_index;
    sample.local_qid       = queue_id;
    sample.global_qid      = queue_id;
    sample.descriptor_id   = descriptor_id;
    sample.buffer_count    = 1;
    sample.net_hdr         = net_hdr;
    sample.private_offload = private_offload;
    sample.packet_sequence = packet_sequence++;
    sample.reset_epoch     = packet_reset_epoch;
    sample.key_valid       = packet_key.len() != 0;
    sample.packet_key      = packet_key;
    if (function_identity_valid) begin
        sample.identity_valid = 1;
        sample.function_key   = function_key;
        sample.service_key    = service_key;
    end
    foreach (frame_bytes[i]) sample.frame_bytes.push_back(frame_bytes[i]);
    if (get_queue_program(queue_id, qprog))
        sample.global_qid = qprog.queue_id;
    void'(packet_hub.publish(sample));
endfunction

// 功能：发布 RX used entry 合并后的完整 payload。
// 输入/输出：输入队列和已完成的 RX frame；无返回值。
// 边界/副作用：header 已由 rx_receive_frames 分离；样本不重新读取或释放 DMA。
function void virtio_atomic_ops::publish_rx_frame(
    int unsigned queue_id,
    virtio_rx_frame_t frame
);
    virtio_packet_sample sample;
    virtio_queue_program_t qprog;

    if (packet_hub == null) return;
    sample = virtio_packet_sample::type_id::create("vrx_packet");
    sample.direction       = VIO_PACKET_VRX;
    sample.host_id         = get_iommu_host_id(transport);
    sample.bdf             = transport.bdf;
    sample.is_vf           = transport.is_vf;
    sample.vf_id           = transport.vf_index;
    sample.local_qid       = queue_id;
    sample.global_qid      = queue_id;
    sample.buffer_count    = frame.num_buffers;
    sample.net_hdr         = frame.net_hdr;
    sample.packet_sequence = packet_sequence++;
    sample.reset_epoch     = packet_reset_epoch;
    sample.key_valid       = 0;
    sample.packet_key      = "";
    if (function_identity_valid) begin
        sample.identity_valid = 1;
        sample.function_key   = function_key;
        sample.service_key    = service_key;
    end
    foreach (frame.payload[i]) sample.frame_bytes.push_back(frame.payload[i]);
    if (get_queue_program(queue_id, qprog))
        sample.global_qid = qprog.queue_id;
    void'(packet_hub.publish(sample));
endfunction

// 每包从参数规划到 SG 发布始终使用同一份报文字节；等待只回收已有完成，不重采样。
task virtio_atomic_ops::tx_submit(
    int unsigned		queue_id,
    virtio_net_hdr_t		net_hdr,
    uvm_object		pkt,
    bit			use_indirect,
    ref int unsigned	desc_id,
    input virtio_tx_offload_t	tx_offload = '0,
    input int unsigned		timeout_ns = 0,
    input bit			notify = 1,
    input virtio_tx_seg_t	tx_seg = '0,
    input string			packet_key = ""
);
    virtqueue_base		vq;
    custom_virtqueue		private_vq;
    byte unsigned		hdr_bytes[$];
    byte unsigned		pkt_bytes[];
    byte unsigned		wire_bytes[$];
    byte			hdr_data[];
    byte			pkt_data[];
    int unsigned		hdr_size;
    int unsigned		hdr_dma_size;
    int unsigned		pkt_size;
    int unsigned		pkt_dma_size;
    int			hdr_idx;
    int			pkt_idx;
    virtio_sg_list		sgs[2];
    virtio_sg_entry		hdr_entry;
    virtio_sg_entry		pkt_entry;
    virtio_dma_buffer_set	dma_set;
    int unsigned		n_out;
    vio_private_tx_offload_t	private_control;
    string			why;
    bit			private_format;
    int unsigned		needed;
    bit			space_ready;
    int unsigned		segment_lengths[$];
    int unsigned		packet_offset;

    desc_id = '1;
    if (!external_queue_ready(queue_id)) return;
    if (use_indirect &&
        !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
        `uvm_error("ATOMIC_OPS", $sformatf(
            "tx_submit: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
            queue_id))
        return;
    end

    `uvm_info("ATOMIC_OPS",
        $sformatf("tx_submit: queue_id=%0d", queue_id), UVM_HIGH)

    vq = vq_mgr.get_queue(queue_id);
    if (vq == null) begin
        `uvm_error("ATOMIC_OPS",
            $sformatf("tx_submit: queue %0d not found", queue_id))
        return;
    end

    // 每包offload在取得最终字节后转换；无请求的原子调用保留显式net_hdr语义。
    hdr_size = vq.net_hdr_bytes(negotiated_features);
    private_format = $cast(private_vq, vq);
    private_control = '0;
    if (!tx_offload.valid && (hdr_size == 0) && ((net_hdr.flags != 0) ||
                            (net_hdr.gso_type != VIRTIO_NET_HDR_GSO_NONE))) begin
        `uvm_error("ATOMIC_OPS", $sformatf(
            "tx_submit: queue %0d carries no virtio-net header; offload request rejected",
            queue_id))
        return;
    end
    // PCIe Memory Read completions are DWORD based.  Keep the descriptor
    // length byte-accurate, but give the model/RC responder a DWORD-padded
    // backing allocation so a final partial DWORD never crosses an exact
    // host_mem block boundary.
    hdr_dma_size = (hdr_size + 3) & ~3;

    // 2. Get wire bytes.  packet_item.do_pack() 带 32-bit UVM 长度前缀，不是
    // 线速帧，先经 adapter 取 raw_data；其他对象保留原 do_pack 字节流。
    if (virtio_net_packet_adapter::pack(pkt, wire_bytes)) begin
        pkt_bytes = new[wire_bytes.size()];
        foreach (wire_bytes[i]) pkt_bytes[i] = wire_bytes[i];
    end else begin
        uvm_packer	packer;
        packer = new();
        pkt.do_pack(packer);
        packer.get_bytes(pkt_bytes);
    end
    if (tx_offload.valid) begin
        wire_bytes.delete();
        foreach (pkt_bytes[i]) wire_bytes.push_back(pkt_bytes[i]);
        if (!virtio_net_packet_adapter::prepare_tx(wire_bytes, tx_offload,
                private_format, negotiated_features, net_hdr, private_control, why)) begin
            `uvm_error("VIO_TX_OFFLOAD", why)
            return;
        end
        foreach (pkt_bytes[i]) pkt_bytes[i] = wire_bytes[i];
    end
    if (hdr_size != 0) begin
        virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
        hdr_size = hdr_bytes.size();
    end
    pkt_size = pkt_bytes.size();

    // If packet has no data from do_pack, use minimum Ethernet frame size
    if (pkt_size == 0) begin
        pkt_bytes = new[64];
        pkt_size  = pkt_bytes.size();
    end
    // Keep the backing allocation DWORD padded after the minimum-size
    // fallback as well; otherwise an empty packet would request a
    // zero-byte host_mem allocation even though the descriptor carries
    // the 64-byte minimum frame.
    pkt_dma_size = (pkt_size + 3) & ~3;

    // 空间不足是正常流控；本包字节和offload已固定，等待期间不占额外DMA。
    if (!plan_tx_segments(vq, pkt_size, hdr_size, private_control.tso,
                          use_indirect, tx_seg, segment_lengths, needed, why)) begin
        `uvm_fatal("VIO_TX_SEG", why)
        return;
    end
    wait_tx_space(vq, needed, timeout_ns, space_ready);
    if (!space_ready) return;

    // 3. Allocate host_mem for hdr + data buffers.  A failed second
    //    allocation rolls back the first; nothing is mapped yet.
    dma_set = new("tx_dma");
    dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);
    hdr_idx = (hdr_size == 0) ? -1 : dma_set.alloc(hdr_dma_size);
    pkt_idx = ((hdr_size != 0) && (hdr_idx < 0)) ? -1 : dma_set.alloc(pkt_dma_size);
    if (pkt_idx < 0) begin
        dma_set.release_all();
        `uvm_error("ATOMIC_OPS",
            $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
        return;
    end

    // 4. Write hdr and data to host_mem
    if (hdr_size != 0) begin
        hdr_data = new[hdr_size];
        foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
        dma_set.write(hdr_idx, hdr_data);
    end

    if (pkt_bytes.size() > 0) begin
        pkt_data = new[pkt_size];
        foreach (pkt_bytes[i]) pkt_data[i] = pkt_bytes[i];
        dma_set.write(pkt_idx, pkt_data);
    end

    // 5. Map through IOMMU (DMA_TO_DEVICE -- device reads these buffers)
    if ((hdr_size != 0) && !dma_set.map(hdr_idx, DMA_TO_DEVICE)) begin
        dma_set.release_all();
        `uvm_error("ATOMIC_OPS", $sformatf(
            "tx_submit: failed to map header for queue %0d", queue_id))
        return;
    end
    if (!dma_set.map(pkt_idx, DMA_TO_DEVICE)) begin
        dma_set.release_all();
        `uvm_error("ATOMIC_OPS", $sformatf(
            "tx_submit: failed to map payload for queue %0d", queue_id))
        return;
    end

    // 构建 header 和 data 两组 SG；data 组可包含多个分段，header 不拆分。
    n_out = 0;
    if (hdr_size != 0) begin
        hdr_entry.addr = dma_set.get_iova(hdr_idx);
        hdr_entry.len  = hdr_size;
        sgs[n_out].entries.push_back(hdr_entry);
        n_out++;
    end

    // 每个 data 段引用同一 DMA 的连续子区间；完成时仍只释放一次报文映射。
    packet_offset = 0;
    foreach (segment_lengths[i]) begin
        pkt_entry.addr = dma_set.get_iova(pkt_idx) + packet_offset;
        pkt_entry.len  = segment_lengths[i];
        sgs[n_out].entries.push_back(pkt_entry);
        packet_offset += segment_lengths[i];
    end
    n_out++;

    // 发布只有 OUT 数据的 SG 链；有标准 header 时为两组，否则只有 data 组。
    // DMA 仍归本次操作，add_buf 失败立即回滚，不登记完成记录或通知设备。
    if (private_format && private_control.valid)
        desc_id = private_vq.add_tx_buf(sgs, n_out, pkt, use_indirect, private_control);
    else
        desc_id = vq.add_buf(sgs, n_out, 0, pkt, use_indirect);
    if (desc_id == '1) begin
        dma_set.release_all();
        return;
    end

    // Hand the ownership records (hdr first, matching tx_complete's
    // per-packet retirement count) to completion/reset before notifying.
    if (!tx_dma_map.exists(queue_id))
        tx_dma_map[queue_id] = {};
    adopt_dma_set(dma_set, tx_dma_map[queue_id]);

    // 真实 descriptor 已成功接管 DMA 所有权；从此处采样能保证 hub 看到的
    // payload 与最终下到 Host memory 的字节一致，失败时不会发布伪报文。
    publish_tx_packet(
        queue_id,
        pkt_bytes,
        net_hdr,
        private_control,
        desc_id,
        packet_key
    );

    // 8. 批末发布当前真实游标；pending标志只属于本队列，不重复通知空批次。
    tx_notify_pending[queue_id] = 1;
    if (notify) flush_tx(queue_id);

    `uvm_info("ATOMIC_OPS",
        $sformatf("tx_submit: queue_id=%0d desc_id=%0d hdr_iova=0x%016h pkt_iova=0x%016h",
                  queue_id, desc_id, hdr_entry.addr, sgs[n_out-1].entries[0].addr), UVM_HIGH)
endtask


// 按 Function 输出一次 RX 累计信息；停机回收不会抹掉计数，便于识别有投递但无收包。
function void virtio_atomic_ops::print_rx_stats();
    string	identity;

    if (rx_polls == 0 && rx_posted_buffers == 0) return;

    // 日志不引入新的运行期检查；异常清理中即使 transport 已解除绑定，也保留统计。
    identity = (transport == null) ? "transport=unbound" : $sformatf(
        "host=%0d bdf=%04h", get_iommu_host_id(transport), transport.bdf);
    `uvm_info("RX_STATS", $sformatf(
        "%s posted=%0d polls=%0d empty=%0d packets=%0d bytes=%0d", identity,
        rx_posted_buffers, rx_polls, rx_empty_polls, rx_packets, rx_bytes), UVM_LOW)
endfunction

// 每次受阻提交独立计时；回收复用tx_complete，不能直接poll_used绕过DMA释放和中断门禁。
task virtio_atomic_ops::wait_tx_space(virtqueue_base	vq, int unsigned	needed,
    int unsigned	timeout_ns, output bit	ready);
    custom_virtqueue	private_vq;
    int unsigned	capacity;
    int unsigned	limit_ns;
    realtime		deadline;
    uvm_object		completed[$];

    ready = 0;
    capacity = vq.queue_size;
    if ($cast(private_vq, vq)) capacity--;
    if (needed > capacity) begin
        `uvm_error("VIO_TX_SPACE", $sformatf(
            "queue %0d packet needs %0d descriptors but capacity is %0d",
            vq.queue_id, needed, capacity))
        return;
    end
    if (vq.get_free_count() >= needed) begin
        ready = 1;
        return;
    end

    // 未满一批也必须先通知已有描述符，否则Custom DUT尚未见到新的尾指针。
    flush_tx(vq.queue_id);
    limit_ns = wait_pol.effective_timeout(
        (timeout_ns == 0) ? wait_pol.default_timeout_ns : timeout_ns);
    deadline = $realtime + limit_ns * 1ns;
    while (1) begin
        if (!external_queue_ready(vq.queue_id) || vq_mgr.get_queue(vq.queue_id) != vq) begin
            `uvm_error("VIO_TX_SPACE", "queue became unavailable while waiting for TX space")
            return;
        end
        completed.delete();
        tx_complete(vq.queue_id, completed, vq.queue_size);
        if (vq.get_free_count() >= needed) begin
            ready = 1;
            return;
        end
        if ($realtime >= deadline) begin
            `uvm_error("VIO_TX_TIMEOUT", $sformatf(
                "queue %0d waited %0d ns for %0d descriptors; free=%0d",
                vq.queue_id, limit_ns, needed, vq.get_free_count()))
            return;
        end
        wait_pol.wait_poll_interval((deadline - $realtime) / 1ns);
    end
endtask

// 通知复用生产配置后端和故障钩子；清标志不影响DMA所有权或完成回收。
task virtio_atomic_ops::flush_tx(int unsigned	queue_id);
    virtqueue_base	vq;

    if (!tx_notify_pending.exists(queue_id) || !tx_notify_pending[queue_id]) return;
    vq = vq_mgr.get_queue(queue_id);
    if (vq == null || !external_queue_ready(queue_id)) return;
    if (vq.needs_notification()) kick_with_fault(vq, queue_id);
    tx_notify_pending.delete(queue_id);
endtask

`endif // VIRTIO_ATOMIC_OPS_SV
