`ifndef VIRTIO_FUNCTION_INSTANCE_SV
`define VIRTIO_FUNCTION_INSTANCE_SV

// 目录层次：src/sriov；每个 PF/VF 拥有 driver、queue manager、transport 和运行态。
// 依赖冻结 DPU snapshot、共享 Host memory 和标准/私有 ops/FSM；组件生命周期由
// UVM 管理，private_cfg/control 借用自 env_cfg，DMA 由所选 ops 在停机确认后释放。
// One independently addressable virtio function.  A PF and every VF own the
// same driver, transport, queue-manager, dataplane, Fabric identity, and BAR
// leases; only their function key and transport VF bit differ.
// 中文说明：实例不保存一份可变的拓扑副本，而是绑定到全局冻结 snapshot；
// 这样 PF/VF 的 BDF、BAR 和资源映射在整个测试生命周期内保持一致。
class virtio_function_instance extends uvm_component;
    `uvm_component_utils(virtio_function_instance)

    // Identity and snapshot-owned placement.
    int unsigned            vf_index;
    bit [15:0]              bdf;
    dpu_pcie_function_id_t  pcie_id;
    bit                     pcie_id_valid;
    dpu_function_key_t      function_key;
    dpu_function_kind_e     function_kind;
    dpu_service_key_t       service_key;
    dpu_bar_pair_lease_t    bar_pairs[$];
    dpu_resource_manager    resource_manager;
    virtio_resource_client  resource_client;
    // 已校验的 snapshot 上下文；非空表示本实例已被某个 service 配置。
    protected vio_snapshot_ctx snapshot_ctx;

    // PCIe context is owned by the PCIe function manager, not this function.
    uvm_object              pcie_ctx_ref;

    // Owned virtio function components.
    virtio_driver_agent     driver_agent;
    virtqueue_manager       vq_mgr;
    virtio_net_dataplane    dataplane;
    virtio_pci_transport    transport;

    // Shared infrastructure references.
    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector    err_inj;
    virtio_wait_policy          wait_pol;

    vf_state_e             state = VF_CREATED;
    virtio_driver_config_t drv_cfg;
    // 非空时该 Function 使用 DPU 私有队列协议，其他 Function 仍可用标准 Virtio。
    dpu_priv_driver_config private_cfg;
    local virtio_auto_fsm  pending_pcie_fsm;
    local virtio_atomic_ops pending_pcie_ops;
    local bit              pcie_bind_prepared;

    // 创建一个尚未绑定拓扑的 Function 组件；资源、BDF、BAR 和 Host 所有权
    // 由后续 configure_from_service 从冻结 snapshot 注入。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_PF;
        pcie_id_valid = 0;
        pending_pcie_fsm = null;
        pending_pcie_ops = null;
        pcie_bind_prepared = 0;
    endfunction

    // 根据本 Function 的配置选择并创建匹配的 ops/FSM 候选；这是 driver 工厂
    // 选择的唯一位置，不访问设备。已提供对象与私有配置类型冲突时拒绝，防止标准
    // FSM 驱动私有 ring；factory 返回空对象时 UVM_FATAL。配置仅在提交时冻结。
    protected function bit prepare_driver_candidates(
        string label, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm
    );
        dpu_priv_atomic_ops private_ops;
        dpu_priv_auto_fsm private_fsm;
        string why;
        if (private_cfg != null) begin
            if (!private_cfg.validate(behavior.num_queue_pairs, why) ||
                behavior.vq_type != VQ_CUSTOM || behavior.irq_mode != IRQ_POLLING) begin
                `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
                return 0;
            end
            if (candidate_ops == null)
                candidate_ops = dpu_priv_atomic_ops::type_id::create({label, "_ops"});
            if (candidate_fsm == null)
                candidate_fsm = dpu_priv_auto_fsm::type_id::create({label, "_fsm"});
            if (!$cast(private_ops, candidate_ops) || !$cast(private_fsm, candidate_fsm)) begin
                `uvm_error("FUNCTION_BIND", "私有配置与已绑定 ops/FSM 类型冲突")
                return 0;
            end
            return 1;
        end
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create({label, "_fsm"}, this);
        if (candidate_fsm == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned a null PCIe FSM", label))
            return 0;
        end
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create({label, "_ops"}, this);
        if (candidate_ops == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned null PCIe atomic ops", label))
            return 0;
        end
        return 1;
    endfunction

    // 创建该 Function 独占的 driver/queue/dataplane/transport 对象，并应用当前
    // 已解析的身份；不在此阶段自行分配 BDF、BAR 或 Host memory。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        driver_agent = virtio_driver_agent::type_id::create("driver_agent", this);
        vq_mgr = virtqueue_manager::type_id::create("vq_mgr");
        dataplane = virtio_net_dataplane::type_id::create("dataplane");
        transport = virtio_pci_transport::type_id::create("transport");
        resource_client = virtio_resource_client::type_id::create("resource_client");
        apply_function_configuration();
    endfunction

    // 独立调用入口（测试与兼容路径）：先拒绝非冻结 device snapshot 和改绑到另一份
    // device snapshot，再由 vio_snapshot_ctx 一次性校验 resource snapshot/manager，
    // 最后委托 configure_from_ctx。调用方不能传入 raw BDF/BAR。
    virtual function bit configure_from_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        input dpu_resource_manager manager,
        input uvm_object pcie_ctx = null
    );
        vio_snapshot_ctx ctx;
        string why;

        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a frozen device snapshot")
            return 0;
        end
        if (!device_snapshot_assignable(device_snapshot))
            return 0;
        ctx = vio_snapshot_ctx::create_checked(
            device_snapshot, resource_snapshot, manager, why);
        if (ctx == null) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration requires its exact frozen resource ",
                 "snapshot and pair-seeded manager"})
            return 0;
        end
        return configure_from_ctx(ctx, service_key, pcie_ctx);
    endfunction

    // 生产入口：ctx 已由 env 校验。解析本 service 的 owner、PCIe 身份和三个 BAR，
    // 拒绝改绑（device snapshot / resource snapshot / service / manager / PCIe
    // context），在提交前导入资源视图；任何失败 UVM_FATAL 并保持原有绑定。
    virtual function bit configure_from_ctx(
        input vio_snapshot_ctx ctx,
        input dpu_service_key_t service_key,
        input uvm_object pcie_ctx = null
    );
        dpu_device_snapshot device_snapshot;
        dpu_function_key_t key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t bar;
        string why;

        if (ctx == null) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a validated snapshot context")
            return 0;
        end
        device_snapshot = ctx.device_snapshot();
        if (service_key.service_kind != DPU_SERVICE_VIO_NET) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a VIO-net service key")
            return 0;
        end
        if (!device_snapshot.get_service_owner(service_key, key, why) ||
            !device_snapshot.get_pcie_id(key, pcie_id, why) ||
            !device_snapshot.get_bar(key, DPU_BAR_DEVICE_MEMORY, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MAILBOX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MSIX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot_assignable(device_snapshot))
            return 0;
        if (!ctx.manager().contains_function(key)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration requires its exact frozen resource ",
                 "snapshot and pair-seeded manager"})
            return 0;
        end
        if ((snapshot_ctx != null) &&
            ((snapshot_ctx.resource_snapshot() != ctx.resource_snapshot()) ||
             (dpu_service_key_name(this.service_key) !=
              dpu_service_key_name(service_key)) ||
             ((resource_manager != null) && (resource_manager != ctx.manager())) ||
             (pcie_ctx_ref != pcie_ctx))) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different resource snapshot, service, manager, or PCIe context"})
            return 0;
        end
        if ((resource_client != null) &&
            !resource_client.bind_to_ctx(ctx, service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return 0;
        end
        snapshot_ctx = ctx;
        function_kind = key.kind;
        function_key = key;
        this.service_key = service_key;
        bdf = pcie_id.bdf;
        this.pcie_id = pcie_id;
        pcie_id_valid = 1;
        vf_index = key.vf_id;
        bar_pairs = bars;
        resource_manager = ctx.manager();
        pcie_ctx_ref = pcie_ctx;
        apply_function_configuration();
        return 1;
    endfunction

    // 已配置的 Function 不得迁移到另一份 device snapshot；违反时 UVM_FATAL 并返回 0。
    local function bit device_snapshot_assignable(
        input dpu_device_snapshot device_snapshot
    );
        if ((snapshot_ctx != null) &&
            (snapshot_ctx.device_snapshot() != device_snapshot)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different device snapshot"})
            return 0;
        end
        return 1;
    endfunction

    // 两阶段绑定的预检半段：检查 RC sequencer、driver agent、transport 子对象和
    // 本 Function 的 qpair 上限，只暂存 FSM/ops 候选，不修改任何已提交的连接；
    // 失败返回 0 并保留 UVM_FATAL 诊断。环境对全部 Function 预检后才逐个提交，
    // 后面的 Function 失败不会留下前面 Function 的部分绑定。
    function bit preflight_bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        string function_name;
        string why;
        virtio_auto_fsm candidate_fsm;
        virtio_atomic_ops candidate_ops;

        cancel_bind_pcie();
        function_name = $sformatf("function_%0d", vf_index);
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s received a null PCIe RC sequencer", function_name))
            return 0;
        end
        if (driver_agent == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing driver agent", function_name))
            return 0;
        end
        if ((transport == null) || (vq_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing transport or virtqueue manager", function_name))
            return 0;
        end
        if ((transport.bar == null) || (transport.notify_mgr == null) ||
            (transport.cap_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                {"%s is missing transport BAR, notify manager, or ",
                 "capability manager"}, function_name))
            return 0;
        end
        candidate_fsm = driver_agent.fsm;
        candidate_ops = driver_agent.ops;
        if (!prepare_driver_candidates(function_name, drv_cfg, candidate_ops, candidate_fsm))
            return 0;
        if (!candidate_fsm.mq_pair_limit_binding_supported(
            drv_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end
        pending_pcie_fsm = candidate_fsm;
        pending_pcie_ops = candidate_ops;
        pcie_bind_prepared = 1;
        return 1;
    endfunction

    // 返回预检阶段暂存的 FSM 候选，仅供环境在提交前检查；未预检时返回 null。
    function virtio_auto_fsm pending_pcie_fsm_candidate();
        return pending_pcie_fsm;
    endfunction

    // 返回预检阶段暂存的原子操作对象；调用者不得把它绑定到另一份 snapshot。
    function virtio_atomic_ops pending_pcie_ops_candidate();
        return pending_pcie_ops;
    endfunction

    // 两阶段绑定的取消入口：丢弃尚未提交的 FSM/ops 候选，供批量绑定回滚；
    // 不触碰已经提交的连接。
    function void cancel_bind_pcie();
        pending_pcie_fsm = null;
        pending_pcie_ops = null;
        pcie_bind_prepared = 0;
    endfunction

    // 两阶段绑定的提交半段：把预检成功的候选一次性接入共享 Host/IOMMU/PCIe
    // 资源；缺少预检状态时 UVM_FATAL 并返回 0，成功后清除暂存句柄。
    function bit commit_bind_pcie(
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;

        if (!pcie_bind_prepared || (pending_pcie_fsm == null) ||
            (pending_pcie_ops == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "function_%0d PCIe bind commit requires successful preflight",
                vf_index))
            return 0;
        end
        ops = pending_pcie_ops;
        fsm = pending_pcie_fsm;
        if (!commit_validated_pcie_components(
            $sformatf("function_%0d", vf_index), transport, vq_mgr,
            driver_agent, hmem, iommu_mdl, bar_mdl, einj, wpol, drv_cfg,
            pcie_rc_seqr, ops, fsm)) begin
            return 0;
        end
        mem = hmem;
        iommu = iommu_mdl;
        barrier = bar_mdl;
        err_inj = einj;
        wait_pol = wpol;
        cancel_bind_pcie();
        return 1;
    endfunction

    // 只由 commit_bind_pcie 调用：接线已通过 preflight_bind_pcie 空句柄、factory
    // 与 qpair 上限检查的组件；失败只返回 0，不接受半初始化的 driver/transport。
    local function bit commit_validated_pcie_components(
        input string function_name,
        input virtio_pci_transport transport_ref,
        input virtqueue_manager vq_mgr_ref,
        input virtio_driver_agent driver_agent_ref,
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input virtio_driver_config_t driver_cfg,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_atomic_ops ops,
        input virtio_auto_fsm fsm
    );
        string why;
        dpu_priv_atomic_ops private_ops;

        if (private_cfg != null) begin
            if (!$cast(private_ops, ops) ||
                !private_ops.configure_private(private_cfg, driver_cfg.num_queue_pairs, why)) begin
                `uvm_error("FUNCTION_BIND", {"无法冻结私有驱动配置: ", why})
                return 0;
            end
        end

        if (!fsm.bind_mq_pair_limit(
            driver_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end

        vq_mgr_ref.mem = hmem;
        vq_mgr_ref.iommu = iommu_mdl;
        vq_mgr_ref.barrier = bar_mdl;
        vq_mgr_ref.err_inj = einj;
        vq_mgr_ref.wait_pol = wpol;
        transport_ref.wait_pol = wpol;
        transport_ref.bar.pcie_rc_seqr = pcie_rc_seqr;
        transport_ref.notify_mgr.bar = transport_ref.bar;
        transport_ref.cap_mgr.bar_ref = transport_ref.bar;

        ops.transport = transport_ref;
        ops.vq_mgr = vq_mgr_ref;
        ops.mem = hmem;
        ops.iommu = iommu_mdl;
        ops.wait_pol = wpol;

        // Keep the optional standalone dataplane wrapper in the same
        // host-qualified DMA domain as the function-owned queue/atomic path.
        // 标准与私有 Function 使用同一引擎类，只是注入的 ops 不同；收发、DMA
        // 所有权与通知都在 ops 内，engine 与 FSM/sequence 共用同一张所有权表。
        if (dataplane != null) begin
            if (private_cfg != null) begin
                // 私有 buffer 容量不含 Virtio header；补充由调用方/FSM 控制。
                dataplane.rx_engine.buf_size = private_cfg.rx_buf_size;
                dataplane.rx_engine.refill_threshold = 0;
            end
            // Function 不调用 configure()：借用 dataplane 自带的 offload，特性为 0 时
            // build_tx_hdr 产出全零 header（私有 ops 要求如此）。
            dataplane.tx_engine.offload = dataplane.offload;
            dataplane.rx_engine.offload = dataplane.offload;
            dataplane.tx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.tx_engine.bdf = transport_ref.bdf;
            dataplane.rx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.rx_engine.bdf = transport_ref.bdf;
            dataplane.bind_ops(ops);
        end

        fsm.ops = ops;
        fsm.drv_cfg = driver_cfg;

        if (driver_agent_ref != null) begin
            driver_agent_ref.ops = ops;
            driver_agent_ref.fsm = fsm;
            if (driver_agent_ref.driver != null) begin
                driver_agent_ref.driver.ops = ops;
                driver_agent_ref.driver.fsm = fsm;
            end
            if (driver_agent_ref.monitor != null) begin
                driver_agent_ref.monitor.transport = transport_ref;
                driver_agent_ref.monitor.vq_mgr = vq_mgr_ref;
            end
        end
        return 1;
    endfunction

    // 单 Function 便捷入口：preflight + commit 的组合；任一半段失败都丢弃候选，
    // 不保留部分接线。环境批量绑定直接使用两阶段接口以保证多 Function 原子性。
    function bit wire_shared(
        host_mem_manager hmem,
        virtio_iommu_model iommu_mdl,
        virtio_memory_barrier_model bar_mdl,
        virtqueue_error_injector einj,
        virtio_wait_policy wpol,
        uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        if (preflight_bind_pcie(pcie_rc_seqr) &&
            commit_bind_pcie(hmem, iommu_mdl, bar_mdl, einj, wpol, pcie_rc_seqr))
            return 1;
        cancel_bind_pcie();
        return 0;
    endfunction

    // standalone 便捷入口：使用实例当前保存的共享对象绑定一个 RC sequencer。
    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        return wire_shared(
            mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr);
    endfunction

    // 保存驱动行为并将 Function 置为 CONFIGURED；真正启动由 driver FSM 负责。
    virtual task init(virtio_driver_config_t cfg);
        drv_cfg = cfg;
        state = VF_CONFIGURED;
    endtask

    // A full reset requested through the PF Admin VQ belongs to this normal
    // PF lifecycle owner, not to the separate Admin VQ.  Quiesce any running
    // FSM before the verified device reset; only confirmed completion permits
    // the function and FSM to become eligible for a fresh initialization.
    // 执行 PF 独有的完整设备复位生命周期；先停数据面，再验证 reset，失败时
    // 进入 RESET_FAILED，成功时进入 REINIT_REQUIRED 并通过引用返回结果。
    virtual task reset_pf_lifecycle(ref bit reset_complete);
        virtio_atomic_ops pf_ops;
        virtio_auto_fsm   pf_fsm;

        reset_complete = 0;
        if (function_kind != DPU_FUNCTION_PF) begin
            `uvm_error("FUNCTION_INSTANCE",
                "reset_pf_lifecycle: only a PF may own full-device recovery")
            return;
        end
        if ((driver_agent == null) || (driver_agent.ops == null) ||
            (driver_agent.fsm == null)) begin
            `uvm_error("FUNCTION_INSTANCE",
                "reset_pf_lifecycle: PF driver/FSM/ops lifecycle is not bound")
            return;
        end

        pf_ops = driver_agent.ops;
        pf_fsm = driver_agent.fsm;
        if (pf_fsm.state == FSM_RUNNING)
            pf_fsm.stop_dataplane();

        pf_ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            // device_reset_verified() retained normal PF queue/DMA ownership;
            // record the failed lifecycle instead of representing a usable or
            // successfully reinitialized function.
            state = VF_RESET_FAILED;
            pf_fsm.state = FSM_ERROR;
            return;
        end

        state = VF_REINIT_REQUIRED;
        pf_fsm.state = FSM_REINIT_REQUIRED;
    endtask

    // 停止活动数据面，复位成功后释放运行时资源并把 Function 标记为 DISABLED；
    // 不释放 snapshot 所有的静态 BDF/BAR lease。私有后端未确认停 DMA 时保留
    // 全部资源，进入 RESET_FAILED/FSM_ERROR，供调用方诊断或重试；成功时 FSM
    // 标记 REINIT_REQUIRED，禁止在已经释放的队列上直接重启数据面。
    virtual task shutdown();
        if (private_cfg != null) begin
            bit reset_ok;
            if ((driver_agent.fsm != null) && (driver_agent.fsm.state == FSM_RUNNING))
                driver_agent.fsm.stop_dataplane();
            reset_ok = 0;
            if (driver_agent.ops != null)
                driver_agent.ops.device_reset_verified(reset_ok);
            if (!reset_ok) begin
                state = VF_RESET_FAILED;
                if (driver_agent.fsm != null) driver_agent.fsm.state = FSM_ERROR;
                return;
            end
            if (resource_client != null) resource_client.reset_runtime_state();
            state = VF_DISABLED;
            if (driver_agent.fsm != null) driver_agent.fsm.state = FSM_REINIT_REQUIRED;
            return;
        end
        if ((state == VF_ACTIVE) && (driver_agent.fsm != null))
            driver_agent.fsm.stop_dataplane();
        if (driver_agent.ops != null)
            driver_agent.ops.device_reset();
        if (resource_client != null)
            resource_client.reset_runtime_state();
        state = VF_DISABLED;
    endtask

    // 响应 VF/PF FLR：分离队列、清理运行时 resource-client 状态，
    // 保留静态 Function 身份并进入 FLR 状态。
    virtual function void on_flr();
        vq_mgr.detach_all_queues();
        if (resource_client != null)
            resource_client.reset_runtime_state();
        state = VF_FLR;
    endfunction

    // 在 FLR 后重新装载驱动配置；调用者负责确保硬件侧 FLR 已完成。
    virtual task reinit_after_flr(virtio_driver_config_t cfg);
        state = VF_CREATED;
        init(cfg);
    endtask

    // 返回当前生命周期状态，供 PF manager、测试和并发控制器只读查询。
    virtual function vf_state_e get_state();
        return state;
    endfunction

    // 将已配置 Function 置为 ACTIVE；复位失败或要求重新初始化时拒绝激活。
    virtual function void set_active();
        if ((state == VF_REINIT_REQUIRED) || (state == VF_RESET_FAILED)) begin
            `uvm_error("FUNCTION_INSTANCE", $sformatf(
                "set_active: function %0d:%0d:%0d:%0d requires reinitialization before activation from state %s",
                function_key.host_id, function_key.pf_id, function_key.kind,
                function_key.vf_id, state.name()))
            return;
        end
        if (state != VF_CONFIGURED) begin
            `uvm_warning("FUNCTION_INSTANCE", $sformatf(
                "set_active: function %0d:%0d:%0d:%0d is in state %s",
                function_key.host_id, function_key.pf_id, function_key.kind,
                function_key.vf_id, state.name()))
        end
        state = VF_ACTIVE;
    endfunction

    // 把 snapshot 的 PCIe identity、BAR lease、Host-qualified DMA identity 和
    // service resources 同步到 transport/queue/dataplane；未绑定 snapshot 时仅
    // 保留 standalone 兼容路径，不创建新的资源所有权。
    protected function void apply_function_configuration();
        string why;

        if ((transport == null) || (vq_mgr == null) || (resource_client == null))
            return;
        if (pcie_id_valid)
            transport.configure_pcie_identity(pcie_id);
        else begin
            // Compatibility for standalone instances authored before a
            // frozen snapshot is attached.  Environment-owned functions
            // always take the full-identity branch above.
            transport.bdf = bdf;
            transport.notify_mgr.set_function_bdf(bdf);
            transport.bar.requester_id = bdf;
        end
        transport.is_vf = (function_kind == DPU_FUNCTION_VF);
        transport.vf_index = vf_index;
        vq_mgr.host_id = transport.iommu_host_id();
        vq_mgr.bdf = bdf;
        if (dataplane != null) begin
            dataplane.tx_engine.host_id = vq_mgr.host_id;
            dataplane.tx_engine.bdf = bdf;
            dataplane.rx_engine.host_id = vq_mgr.host_id;
            dataplane.rx_engine.bdf = bdf;
        end
        if (bar_pairs.size() != 0)
            transport.bar.configure_fabric_bar_pairs(bar_pairs);

        if (snapshot_ctx == null)
            return;
        // configure_from_ctx 在子对象已构建时已于提交前导入资源；只有子对象尚未
        // 构建（resource_client 在 build_phase 才创建）时由这里完成唯一一次导入。
        if (!resource_client.is_bound_to_service() &&
            !resource_client.bind_to_ctx(snapshot_ctx, service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return;
        end
        transport.configure_fabric_managed(resource_client);
    endfunction
endclass : virtio_function_instance

`endif // VIRTIO_FUNCTION_INSTANCE_SV
