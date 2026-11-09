`ifndef VIRTIO_NET_ENV_SV
`define VIRTIO_NET_ENV_SV

// ============================================================================
// virtio_net_env
//
// Top-level UVM environment for the virtio-net driver VIP.
// 所属层次：src/env；主要依赖 virtio_net_env_config、dpu_resource_pkg 的冻结
// 快照，以及 host_mem_pool/PCIe TL。test 持有配置与 PCIe 环境，当前 env 在
// UVM 生命周期中借用并装配业务组件，不接管控制面或外部资源的所有权。
//
// 中文说明：这是业务验证环境的装配根节点。DPU 控制面先解析出冻结的
// device/resource snapshot，本环境只消费 snapshot，不重新分配 BDF、BAR 或 qpair；
// 因而控制面、PCIe 传输层和 virtio 业务层的职责保持分离。
// 平台可通过 cfg 注入共享 IOMMU 和按完整身份分配的协议 VIF；外部 IOMMU
// 只校验不重配，协议 VIF 显式映射优先于旧的全局 slot 兼容入口。
//
// Creates and wires all components:
//   - PF manager (SR-IOV orchestration)
//   - VF instances (per-VF driver wrappers, dynamic array)
//   - Shared infrastructure: IOMMU, host memory, barriers, error injector,
//     wait policy, performance monitor
//   - Verification: scoreboard, coverage (conditionally created)
//   - Concurrency controller, dynamic reconfiguration
//
// Config is retrieved from uvm_config_db in build_phase. The test must set:
//   uvm_config_db#(virtio_net_env_config)::set(this, "env", "cfg", cfg)
//
// PCIe subenv connection (pcie_tl_env) is deferred to the test's
// connect_phase because the PCIe env is created by the test.  Tests bind it
// once through bind_pcie(), which wires every active function.
// 中文说明：PCIe 子环境由 test 创建，本 env 在 connect_phase 通过 bind_pcie()
// 接入 RC sequencer、RC/EP monitor 和 completion adapter。
//
// Depends on:
//   - 驱动栈全部层次：types/shared/iommu/virtqueue/transport/agent/
//     dataplane/sriov（见 virtio_net_pkg.sv 的编译分层）
//   - 同层 env 组件：virtio_net_env_config、scoreboard、coverage、
//     concurrency controller、dynamic reconfig
// ============================================================================

// 具体凭据类型只承载对象身份；环境不导出实例，避免用公开代号伪造 READY。
class vio_external_session_token extends uvm_object;
    // 不登记 factory，也不提供状态；每次 prepare 创建独立身份。
    extern function new(string name = "vio_external_session_token");
endclass

function vio_external_session_token::new(string name = "vio_external_session_token");
    super.new(name);
endfunction

class virtio_net_env extends uvm_env;
    `uvm_component_utils(virtio_net_env)

    // 外部本代资源只由本环境持有；live_setup 一经交付，任何失败都保持到显式释放。
    local vio_external_setup	live_external_setup;
    // 未导出的会话凭据，阻止调用方用已知 env 句柄/公开代号直接伪造内部 READY。
    local vio_external_session_token	external_session_key;
    local longint unsigned	external_generation;
    local bit	external_confirmed[string];

    // 私有代次账本保存实际对象身份，不从可变公开数组重建所有权；队列引用与 setup 记录同序。
    typedef struct {
        virtio_function_instance	instance;
        virtio_driver_agent	agent;
        virtio_atomic_ops	ops;
        virtio_auto_fsm	fsm;
        virtqueue_manager	manager;
        virtio_pci_transport	transport;
        virtio_notification_manager	notifications;
        virtio_config_backend	backend;
        virtio_resource_client	client;
        virtio_monitor	monitor;
        dpu_resource_manager	resource_manager;
        dpu_service_key_t	service_key;
        dpu_pcie_function_id_t	pcie_id;
    } external_participant_t;
    local external_participant_t	external_participants[$];
    local virtqueue_base	external_queue_refs[$];
    local host_mem_manager	external_mem;
    local virtio_iommu_model	external_iommu;

    // 在本地分配前保存本代参与者；未交付失败也按该账本回滚，不依赖后来改写的公开集合。
    extern local function void capture_external_participants();

    // 确认与释放共用完整预检：先双向核对参与者，再校验选中 service 的全部 ring/DMA。
    // scope=null 表示释放整代；输出私有账本索引，失败不改 READY、账本、queue 或映射。
    extern local function bit validate_external_generation(input vio_external_setup setup,
        input vio_config_scope scope, output int unsigned selected[$], output string why);


    // 项目跨 Host 操作的薄只读预检；不泄露私有参与者下标，也不改变 READY/DMA。
    extern function bit preflight_external_configuration(input vio_external_setup setup,
        input vio_config_scope scope, output string why);

    // 撤销仅认证已签发视图和私有参与者，不以损坏 ring 阻止关闭业务门禁。
    extern function bit preflight_external_revocation(input vio_external_setup setup,
        input vio_config_scope scope, output string why);
    extern function bit revoke_external_configuration(input vio_external_setup setup,
        input vio_config_scope scope, output string why);

    // 取消恢复使用单调代号；confirmed_only 要求完整当前 service 确认，释放不回退代号。
    extern function longint unsigned external_service_generation(input dpu_service_key_t key,
        input bit confirmed_only = 0);

    // 平台在显式 prepare 时才提供 notify/MSI-X 最终绑定；不会在 connect 前抢读。
    extern task prepare_external_configuration(
        input vio_external_queue_binding_t bindings[$], output vio_external_setup setup,
        output bit ok, output string why);

    // 配置 task 成功由平台显式报告；本方法另外验证来源、代号、全部所选队列和 DMA。
    extern function bit confirm_external_configuration(
        input vio_external_setup setup, input vio_config_scope scope,
        input logic configured, output string why);

    // stop 只停止 VIP；只有平台报告 DUT quiesced 后才归还 ring/payload/DMA。
    extern function bit release_external_resources(
        input vio_external_setup setup, input logic dut_quiesced, output string why);

    // 准备失败且尚未交付时回滚；exported 资源绝不能经过这条路径。
    extern protected function void rollback_external_preparation();

    // 查询确认账本，供 AIP/项目状态同步；修改返回副本不影响内部结果。
    extern function bit external_service_confirmed(
        input vio_external_setup setup, input dpu_service_key_t key);

    // ===== Config =====
    virtio_net_env_config cfg;

    // ===== PF manager =====
    virtio_pf_manager pf_mgr;

    // ===== Snapshot-owned VIO function view =====
    virtio_pf_instance         pf_instances[];
    virtio_function_instance   function_instances[];
    protected dpu_device_snapshot device_snapshot;
    protected dpu_resource_snapshot resource_snapshot;
    protected dpu_resource_manager device_resource_manager;
    // 一次校验后的只读 snapshot 上下文；下游 PF/Function/resource client 只消费它。
    protected vio_snapshot_ctx snapshot_ctx;
    protected bit              configuration_valid;
    local dpu_dut_caps         effective_dut_caps;

    // ===== VF instances enumerated from declared VIO services =====
    virtio_vf_instance vf_instances[];

    // ===== Shared components =====
    virtio_iommu_model              iommu;
    host_mem_manager                host_mem;
    virtio_wait_policy              wait_pol;
    virtio_memory_barrier_model     barrier;
    virtqueue_error_injector        err_inj;
    virtio_perf_monitor             perf_mon;
    virtio_concurrency_controller   conc_ctrl;
    virtio_dynamic_reconfig         dyn_reconfig;

    // ===== Verification =====
    virtio_scoreboard               scb;
    virtio_coverage                 cov;

    // ===== PCIe subenv (stored as uvm_object, $cast at runtime) =====
    // The actual pcie_tl_env is created by the test and passed via config_db
    uvm_object                      pcie_env_ref;
    protected int unsigned           protocol_event_vif_index;

    // ========================================================================
    // Constructor
    // ========================================================================

    // 构造环境并初始化尚未发布的配置状态；不创建子组件，也不会访问 snapshot。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        configuration_valid = 0;
        effective_dut_caps = null;
        snapshot_ctx = null;
        protocol_event_vif_index = 0;
    endfunction

    // 根据冻结 snapshot 中声明的 VIO service 创建 PF/VF 实例；数组下标只是
    // 运行时容器索引，真实身份始终来自 service key。成功返回 1；失败返回 0
    // 并在 why 中说明缺失 service、资源 binding 或实例类型错误。
    protected function bit build_snapshot_topology(output string why);
        dpu_service_key_t service_keys[$];
        dpu_service_key_t grouped_services[$][$];
        dpu_function_key_t group_keys[$];
        dpu_function_key_t owner;
        dpu_function_key_t parent_key;
        int unsigned group_index;
        bit found;
        int unsigned vf_count;
        int unsigned function_count;
        dpu_vio_qpair_binding_t service_bindings[$];

        why = "";
        // build_phase 已建立 snapshot_ctx；测试探针跳过 build_phase、直接写入三个
        // snapshot 字段时在这里补建，校验规则仍只有 vio_snapshot_ctx 一处。
        if (snapshot_ctx == null) begin
            snapshot_ctx = vio_snapshot_ctx::create_checked(
                device_snapshot, resource_snapshot, device_resource_manager, why);
            if (snapshot_ctx == null)
                return 0;
        end
        // 空白名单保持原有的全量 service 语义；非空白名单按完整 key 筛选。
        // 多个 Host 子环境由此消费同一快照的不同部分，不重复解析资源。
        if (cfg.service_keys.size() == 0)
            device_snapshot.list_services(DPU_SERVICE_VIO_NET, service_keys);
        else
            foreach (cfg.service_keys[index])
                service_keys.push_back(cfg.service_keys[index]);
        if (cfg.host_scope_enable) begin
            dpu_service_key_t scoped_service_keys[$];

            // 仅依据快照确认的 owner 过滤 Host；找不到 owner 必须整体失败。
            foreach (service_keys[index]) begin
                dpu_function_key_t scoped_owner;
                string scope_why;

                if (!device_snapshot.get_service_owner(
                        service_keys[index], scoped_owner, scope_why)) begin
                    why = scope_why;
                    return 0;
                end
                if (scoped_owner.host_id == cfg.host_scope_id)
                    scoped_service_keys.push_back(service_keys[index]);
            end
            service_keys = scoped_service_keys;
        end
        if (cfg.external_configuration) begin
            dpu_service_key_t	enabled_services[$];
            vio_service_requirement_t	requirement;

            foreach (service_keys[i]) begin
                if (!cfg.resolve_final_service_requirement(service_keys[i], requirement, why)) return 0;
                if (requirement.enabled) enabled_services.push_back(service_keys[i]);
            end
            service_keys = enabled_services;
        end
        if (service_keys.size() == 0) begin
            // 作用域内可以合法地没有 VIO 参与者；保持共享基础设施但创建空函数
            // 数组。未设作用域时全局无 service 仍是配置错误，避免静默漏配置。
            if (cfg.external_configuration || (cfg.service_keys.size() != 0) || cfg.host_scope_enable) begin
                pf_instances = new[0];
                function_instances = new[0];
                vf_instances = new[0];
                return 1;
            end
            why = "frozen device snapshot declares no VIO services";
            return 0;
        end
        foreach (service_keys[index]) begin
            resource_snapshot.list_vio_bindings_for_service(
                service_keys[index], service_bindings);
            if (service_bindings.size() == 0) begin
                why = "published VIO service has no resource-snapshot bindings";
                return 0;
            end
        end
        foreach (service_keys[index]) begin
            if (!device_snapshot.get_service_owner(service_keys[index], owner, why))
                return 0;
            parent_key = owner;
            parent_key.kind = DPU_FUNCTION_PF;
            parent_key.vf_id = 0;
            found = 0;
            foreach (group_keys[candidate]) begin
                if (dpu_same_function_key(group_keys[candidate], parent_key)) begin
                    group_index = candidate;
                    found = 1;
                    break;
                end
            end
            if (!found) begin
                group_index = group_keys.size();
                group_keys.push_back(parent_key);
            end
            grouped_services[group_index].push_back(service_keys[index]);
        end

        pf_instances = new[group_keys.size()];
        foreach (group_keys[index]) begin
            pf_instances[index] = virtio_pf_instance::type_id::create(
                $sformatf("pf_%0d_%0d", group_keys[index].host_id,
                          group_keys[index].pf_id), this);
            if (!pf_instances[index].configure_services_ctx(
                    group_keys[index], snapshot_ctx,
                    grouped_services[index], why))
                return 0;
        end
        function_count = 0;
        foreach (pf_instances[index]) begin
            virtio_function_instance grouped_functions[$];

            pf_instances[index].collect_functions(grouped_functions);
            function_count += grouped_functions.size();
        end
        function_instances = new[function_count];
        function_count = 0;
        foreach (pf_instances[index]) begin
            virtio_function_instance grouped_functions[$];

            pf_instances[index].collect_functions(grouped_functions);
            foreach (grouped_functions[function_index]) begin
                function_instances[function_count] = grouped_functions[function_index];
                function_count++;
            end
        end

        vf_count = 0;
        foreach (function_instances[index]) begin
            if (function_instances[index].function_kind == DPU_FUNCTION_VF)
                vf_count++;
        end
        vf_instances = new[vf_count];
        vf_count = 0;
        foreach (function_instances[index]) begin
            if (function_instances[index].function_kind == DPU_FUNCTION_VF) begin
                if (!$cast(vf_instances[vf_count], function_instances[index])) begin
                    why = "snapshot VIO VF function did not construct a VF instance";
                    return 0;
                end
                vf_count++;
            end
        end
        return 1;
    endfunction

    // 返回当前生效 DUT capability 的防御性副本，避免调用者修改环境持有的权威对象；
    // build_phase 尚未成功取得 capability 时返回 null。
    function dpu_dut_caps snapshot_effective_dut_caps();
        dpu_dut_caps snapshot;

        if (effective_dut_caps == null)
            return null;
        snapshot = dpu_dut_caps::type_id::create(
            "virtio_env_effective_dut_caps_snapshot");
        snapshot.copy_from(effective_dut_caps);
        return snapshot;
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Retrieve behavior plus the mandatory frozen snapshot and create all
    // components from declared VIO services.
    // 中文说明：从 config_db 取得行为配置和严格匹配的一对冻结 snapshot，绑定
    // Host memory/IOMMU 后创建 PF/VF 拓扑；任何所有权或版本不一致均 UVM_FATAL。
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        string why;
        host_mem_bar_reservation_importer bar_importer;
        uvm_object dpu_pool_ref;
        host_mem_pool selected_pool;

        super.build_phase(phase);

        // 从 config_db 取得业务行为配置以及全局 DPU 发布的冻结 snapshot。
        // 这里拒绝缺失或不匹配的 snapshot，避免业务环境私自构造拓扑。
        if (!uvm_config_db #(virtio_net_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal("VIRTIO_ENV", "No virtio_net_env_config found in config_db")
            return;
        end
        if (!cfg.validate_execution_mode(why)) begin
            `uvm_fatal("VIRTIO_ENV", {"invalid execution/completion mode: ", why})
            return;
        end
        // 三者由全局 DPU 发布；这里一次性校验 frozen/引用/seeded 关系并封装为只读
        // 上下文，下游 PF/Function/resource client 不再重复校验。
        void'(uvm_config_db#(dpu_device_snapshot)::get(
            this, "", "dpu_device_snapshot", device_snapshot));
        void'(uvm_config_db#(dpu_resource_snapshot)::get(
            this, "", "dpu_resource_snapshot", resource_snapshot));
        void'(uvm_config_db#(dpu_resource_manager)::get(
            this, "", "dpu_resource_manager", device_resource_manager));
        snapshot_ctx = vio_snapshot_ctx::create_checked(
            device_snapshot, resource_snapshot, device_resource_manager, why);
        if (snapshot_ctx == null) begin
            `uvm_fatal("VIRTIO_ENV", {"published snapshot context is invalid: ", why})
            return;
        end
        if (!cfg.validate_against_snapshot(device_snapshot, why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "VIO behavior does not match the published device snapshot: %s", why))
            return;
        end
        effective_dut_caps = device_snapshot.snapshot_dut_caps();
        if (effective_dut_caps == null) begin
            `uvm_fatal("VIRTIO_ENV",
                "published device snapshot has no DUT capabilities")
            return;
        end
        configuration_valid = 1;

        `uvm_info("VIRTIO_ENV",
            $sformatf("build_phase: %s", cfg.convert2string()),
            UVM_LOW)

        // 创建 Host memory、IOMMU、等待策略等共享基础设施。相同 host-id 的
        // 多个业务环境应从同一个 host_mem_pool 取得 manager。
        selected_pool = cfg.host_mem_pool_binding;
        if (uvm_config_db#(uvm_object)::get(
                this, "", "dpu_host_mem_pool", dpu_pool_ref)) begin
            host_mem_pool dpu_pool;

            if (!$cast(dpu_pool, dpu_pool_ref) || (dpu_pool == null)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV",
                    "dpu_host_mem_pool is not a host_mem_pool object")
                return;
            end
            if ((selected_pool != null) && (selected_pool != dpu_pool)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV",
                    "direct host_mem_pool_binding disagrees with DPU owner")
                return;
            end
            selected_pool = dpu_pool;
        end
        if ((cfg.host_mem_binding != null) &&
            (selected_pool != null)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV",
                "host_mem_binding and host_mem_pool_binding are mutually exclusive")
            return;
        end
        if (cfg.host_mem_binding != null) begin
            host_mem = cfg.host_mem_binding;
            if (host_mem.get_host_id() != cfg.host_id) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "injected Host memory manager belongs to Host %0d, expected Host %0d",
                    host_mem.get_host_id(), cfg.host_id))
                return;
            end
        end else if (selected_pool != null) begin
            if (!selected_pool.has_host(cfg.host_id)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "Host memory pool has no manager for Host %0d",
                    cfg.host_id))
                return;
            end
            host_mem = selected_pool.get_host(cfg.host_id);
            if ((host_mem == null) ||
                (host_mem.get_host_id() != cfg.host_id)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "Host memory pool returned an invalid manager for Host %0d",
                    cfg.host_id))
                return;
            end
        end else begin
            host_mem = host_mem_manager::type_id::create("host_mem");
            host_mem.set_host_id(cfg.host_id);
            host_mem.set_alloc_policy(cfg.host_mem_policy);
            host_mem.init_region(cfg.mem_base, cfg.mem_end);
        end

        // Resolve all snapshot BARs for this Host before any VIO component
        // allocates rings or buffers.  BARs in a distinct MMIO aperture are
        // ignored by the importer; intersecting ranges are reserved and
        // repeated imports are idempotent for multi-service environments.
        bar_importer = host_mem_bar_reservation_importer::type_id::create(
            "bar_reservation_importer");
        if (!bar_importer.import_snapshot(device_snapshot, host_mem,
                                          cfg.host_id, why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", {"BAR reservation import failed: ", why})
            return;
        end

        if (cfg.iommu_binding != null) begin
            iommu = cfg.iommu_binding;
            // 外部 owner 可能已有 live mapping；只比较配置，不能调用 configure
            // 清空游标或改变映射语义。不同 Host 可以借用策略一致的同一模型。
            if ((iommu.iova_base != cfg.iova_base) ||
                (iommu.iova_limit != cfg.iova_limit) ||
                (iommu.iova_alloc_policy != cfg.iova_alloc_policy) ||
                (iommu.strict_permission_check != cfg.iommu_strict)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", "injected IOMMU policy disagrees with VIO configuration")
                return;
            end
        end else begin
            iommu = virtio_iommu_model::type_id::create("iommu");
            iommu.strict_permission_check = cfg.iommu_strict;
            if (!iommu.configure_iova_aperture(
                    cfg.iova_base, cfg.iova_limit, cfg.iova_alloc_policy, why)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", {"invalid configured IOVA aperture: ", why})
                return;
            end
        end

        wait_pol = virtio_wait_policy::type_id::create("wait_pol");
        // test 在 build 前加载的 vio.wait.* 进入实际被 Function/ops 使用的策略。
        // env 持有独立副本，后续修改配置模板不会悄悄改写已运行的等待过程。
        if (cfg.wait_policy_cfg != null)
            wait_pol.copy(cfg.wait_policy_cfg);
        barrier  = virtio_memory_barrier_model::type_id::create("barrier");
        err_inj  = virtqueue_error_injector::type_id::create("err_inj");

        perf_mon = virtio_perf_monitor::type_id::create("perf_mon", this);
        perf_mon.bw_limit_enable = cfg.bw_limit_enable;
        perf_mon.bw_limit_mbps   = cfg.bw_limit_mbps;

        if (!build_snapshot_topology(why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "could not construct VIO functions from device snapshot: %s", why))
            return;
        end

        // Create verification components (conditionally)
        if (cfg.scb_enable)
            scb = virtio_scoreboard::type_id::create("scb", this);
        if (cfg.cov_enable)
            cov = virtio_coverage::type_id::create("cov", this);

        // Create concurrency/dynamic reconfig
        conc_ctrl    = virtio_concurrency_controller::type_id::create("conc_ctrl");
        dyn_reconfig = virtio_dynamic_reconfig::type_id::create("dyn_reconfig");
        if (!dyn_reconfig.bind_device_snapshot(device_snapshot, why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Dynamic reconfiguration device snapshot bind failed: %s", why))
            return;
        end

    endfunction

    // ========================================================================
    // Connect Phase
    //
    // Wire shared components into VF instances and connect analysis ports to
    // scoreboard/coverage.
    //
    // Note: binding VF instances (preflight/commit_bind_pcie) requires
    // pcie_rc_seqr which comes from the PCIe TL env. That connection is
    // deferred to the test's connect_phase.
    // 中文说明：按 service key 装载每个 Function 的 driver 行为，连接监控与
    // scoreboard/coverage，并发布虚拟 sequencer 引用；配置无效时不产生副作用。
    // ========================================================================

    virtual function void connect_phase(uvm_phase phase);
        virtio_driver_config_t driver_cfg;
        dpu_vio_qpair_binding_t service_bindings[$];
        int unsigned allocated_qpairs;
        string why;

        super.connect_phase(phase);
        if (!configuration_valid)
            return;

        if (pf_instances.size() != 0) begin
            pf_mgr = pf_instances[0].pf_manager;
            pf_mgr.wait_pol = wait_pol;
        end
        foreach (function_instances[function_index]) begin
            service_bindings.delete();
            resource_snapshot.list_vio_bindings_for_service(
                function_instances[function_index].service_key,
                service_bindings);
            allocated_qpairs = service_bindings.size();
            if (allocated_qpairs == 0) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "published VIO service %s has no allocated qpair bindings",
                    dpu_service_key_name(
                        function_instances[function_index].service_key)))
                return;
            end
            if (!cfg.get_service_config(
                    function_instances[function_index].service_key,
                    allocated_qpairs,
                    driver_cfg, why)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "could not resolve VIO behavior for snapshot function: %s", why))
                return;
            end
            function_instances[function_index].drv_cfg = driver_cfg;
            function_instances[function_index].external_configuration = cfg.external_configuration;
            // 每个 Function 单独选择驱动协议；私有配置在 Function 提交时冻结进私有
            // 配置后端。这里仅传配置，不在 connect 阶段执行硬件访问或分配 ring。
            function_instances[function_index].private_cfg =
                cfg.get_dpu_private_config(function_instances[function_index].service_key);
            if (scb != null) begin
                function_instances[function_index].driver_agent.monitor.txn_ap.connect(
                    scb.txn_imp
                );
            end
            if (cov != null) begin
                function_instances[function_index].driver_agent.monitor.txn_ap.connect(
                    cov.analysis_imp
                );
            end
        end

        // Wire concurrency controller
        conc_ctrl.vf_instances = vf_instances;
        conc_ctrl.wait_pol     = wait_pol;

        // Wire the compatibility PF manager alias.
        if (pf_mgr != null)
            pf_mgr.vf_instances = vf_instances;

    endfunction

    // 一个 Function 的 PCIe 绑定计划：bind_pcie 为单 domain 内全部 Function 填入
    // 同一组 RC sequencer/monitor（endpoint 为空）；bind_pcie_endpoints 为每个
    // Function 填入按完整身份选中的 endpoint，提交时额外绑定 completion adapter
    // 与 transport 的 endpoint 通路。
    typedef struct {
        virtio_function_instance      function_instance;
        uvm_sequencer #(pcie_tl_tlp)  rc_seqr;
        pcie_tl_base_monitor          rc_monitor;
        pcie_tl_base_monitor          ep_monitor;
        virtio_pcie_function_endpoint endpoint;
    } pcie_bind_plan_t;

    // 将一个 RC sequencer 及可选 completion/monitor 绑定到全部 VIO Function。
    // 本函数只负责构造单 domain 计划与入口校验，预检、回滚与提交统一由 bind_all
    // 完成；任一 Function 失败则返回 0、标记环境无效且不保留部分绑定。
    // Bind one required RC sequencer and optional TLM completion adapter to
    // all snapshot-declared VIO functions.
    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
        pcie_bind_plan_t plan[$];
        pcie_bind_plan_t entry;
        dpu_pcie_domain_key_t legacy_domain;

        if (!configuration_valid)
            return 0;
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("VIRTIO_ENV", "bind_pcie() received a null PCIe RC sequencer")
            configuration_valid = 0;
            return 0;
        end

        // 标量兼容接口只能描述一条外部 PCIe 通路：同一 domain 内可服务多个
        // Function，但不得把它静默广播到多个独立 domain。
        foreach (function_instances[function_index]) begin
            if ((function_instances[function_index] == null) ||
                !function_instances[function_index].pcie_id_valid) begin
                `uvm_fatal("VIRTIO_ENV",
                    "bind_pcie() requires snapshot-resolved PCIe identities")
                configuration_valid = 0;
                return 0;
            end
            if (function_index == 0)
                legacy_domain = function_instances[0].pcie_id.domain;
            else if (!dpu_same_domain_key(
                    legacy_domain,
                    function_instances[function_index].pcie_id.domain)) begin
                `uvm_fatal("VIRTIO_ENV",
                    {"bind_pcie() cannot bind VIO functions from multiple ",
                     "PCIe domains; use bind_pcie_endpoints()"})
                configuration_valid = 0;
                return 0;
            end
            entry.function_instance = function_instances[function_index];
            entry.rc_seqr = pcie_rc_seqr;
            entry.rc_monitor = pcie_rc_monitor;
            entry.ep_monitor = pcie_ep_monitor;
            entry.endpoint = null;
            plan.push_back(entry);
        end

        // Analysis 连接属于原子提交的一部分：在任何 Function 预检分配候选之前
        // 校验调用方给出的 monitor。
        if ((pcie_rc_monitor != null) && (pcie_rc_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe RC monitor with a null tlp_ap")
            return abort_bind(plan);
        end
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe EP monitor with a null tlp_ap")
            return abort_bind(plan);
        end
        return bind_all(plan, tlm_adapter);
    endfunction

    // 按完整 {host, segment, BDF} 为每个 snapshot Function 选择独立 endpoint，
    // 构造计划后交给 bind_all；数量、身份或预检不匹配时返回 0，且全部校验
    // 通过前不提交任何连接。
    // Bind every snapshot function to one explicitly keyed external path.
    function bit bind_pcie_endpoints(
        input virtio_pcie_function_endpoint endpoints[$]
    );
        pcie_bind_plan_t plan[$];
        pcie_bind_plan_t entry;
        bit endpoint_used[];
        int selected_index;
        string why;

        if (!configuration_valid)
            return 0;
        if (endpoints.size() != function_instances.size()) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                {"bind_pcie_endpoints() requires exactly one endpoint per ",
                 "active function: endpoints=%0d functions=%0d"},
                endpoints.size(), function_instances.size()))
            configuration_valid = 0;
            return 0;
        end

        endpoint_used = new[endpoints.size()];
        foreach (endpoints[endpoint_index]) begin
            if (endpoints[endpoint_index] == null) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "PCIe endpoint index %0d is null", endpoint_index))
                configuration_valid = 0;
                return 0;
            end
            if (!endpoints[endpoint_index].validate(why)) begin
                `uvm_fatal("VIRTIO_ENV", why)
                configuration_valid = 0;
                return 0;
            end
            for (int unsigned prior_index = 0;
                 prior_index < endpoint_index; prior_index++) begin
                if (endpoints[prior_index].matches_id(
                    endpoints[endpoint_index].pcie_id)) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "Duplicate PCIe endpoint mapping for %s",
                        dpu_pcie_function_id_name(
                            endpoints[endpoint_index].pcie_id)))
                    configuration_valid = 0;
                    return 0;
                end
            end
        end

        foreach (function_instances[function_index]) begin
            if (!select_function_endpoint(
                    function_index, endpoints, selected_index)) begin
                configuration_valid = 0;
                return 0;
            end
            endpoint_used[selected_index] = 1;
            entry.function_instance = function_instances[function_index];
            entry.endpoint = endpoints[selected_index];
            entry.rc_seqr = entry.endpoint.rc_seqr;
            entry.rc_monitor = entry.endpoint.rc_monitor;
            entry.ep_monitor = entry.endpoint.ep_monitor;
            plan.push_back(entry);
        end
        foreach (endpoint_used[endpoint_index]) begin
            if (!endpoint_used[endpoint_index]) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "PCIe endpoint %s does not map to an active function",
                    dpu_pcie_function_id_name(
                        endpoints[endpoint_index].pcie_id)))
                configuration_valid = 0;
                return 0;
            end
        end
        return bind_all(plan, null);
    endfunction

    // 为第 function_index 个 Function 选出唯一身份匹配的 endpoint，并确认其
    // transport 身份一致；失败时 UVM_FATAL 并返回 0（由调用方置环境无效）。
    protected function bit select_function_endpoint(
        input int unsigned function_index,
        input virtio_pcie_function_endpoint endpoints[$],
        output int selected_index
    );
        virtio_function_instance function_instance;
        int match_count;

        selected_index = -1;
        match_count = 0;
        function_instance = function_instances[function_index];
        if ((function_instance == null) || !function_instance.pcie_id_valid) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Active function index %0d has no resolved PCIe identity",
                function_index))
            return 0;
        end
        foreach (endpoints[endpoint_index]) begin
            if (endpoints[endpoint_index].matches_id(function_instance.pcie_id)) begin
                match_count++;
                selected_index = endpoint_index;
            end
        end
        if (match_count != 1) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "PCIe endpoint mapping count for %s is %0d, expected 1",
                dpu_pcie_function_id_name(function_instance.pcie_id),
                match_count))
            return 0;
        end
        if ((function_instance.transport == null) ||
            !function_instance.transport.pcie_id_valid ||
            !endpoints[selected_index].matches_id(
                function_instance.transport.pcie_id)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Transport identity does not match function %s",
                dpu_pcie_function_id_name(function_instance.pcie_id)))
            return 0;
        end
        return 1;
    endfunction

    // 两个公共绑定入口共用的提交路径：
    //   1) 逐个 Function 无副作用预检，拒绝共享协议接口/FSM/ops 候选；
    //   2) 校验 endpoint 的 completion adapter 与 RC driver/domain 拓扑；
    //   3) 绑定 completion adapter（标量 adapter 或按 domain 的 adapter）；
    //   4) 逐个提交 Function 与 endpoint 通路，最后发布协议接口槽位计数。
    // 任一步失败都由 abort_bind 统一回滚预检候选并标记环境无效。
    protected function bit bind_all(
        input pcie_bind_plan_t plan[$],
        input virtio_tlm_completion_adapter legacy_adapter
    );
        int unsigned next_protocol_event_vif_index;
        virtual virtio_protocol_event_if staged_protocol_vifs[DPU_MAX_FUNCTIONS];

        if (!preflight_plan(plan, staged_protocol_vifs))
            return abort_bind(plan);
        if (!validate_plan_adapters(plan))
            return abort_bind(plan);
        if ((legacy_adapter != null) &&
            !legacy_adapter.bind_registered_rc_driver())
            return abort_bind(plan);
        if (!commit_plan_adapters(plan))
            return abort_bind(plan);

        next_protocol_event_vif_index = 0;
        foreach (plan[plan_index]) begin
            if (!bind_function_pcie(
                    plan[plan_index].function_instance,
                    plan[plan_index].rc_seqr,
                    plan[plan_index].rc_monitor,
                    plan[plan_index].ep_monitor,
                    next_protocol_event_vif_index,
                    staged_protocol_vifs[plan_index]))
                return abort_bind(plan);
            // 身份匹配已在构造计划时校验；这里只安装选中的 sequencer 与 adapter。
            if ((plan[plan_index].endpoint != null) &&
                !plan[plan_index].function_instance.transport.bind_pcie_endpoint(
                    plan[plan_index].endpoint))
                return abort_bind(plan);
        end
        protocol_event_vif_index = next_protocol_event_vif_index;
        return 1;
    endfunction

    // 统一回滚：丢弃计划内所有 Function 的预检候选并标记环境无效；恒返回 0，
    // 供调用方以 `return abort_bind(plan);` 一行退出。
    protected function bit abort_bind(input pcie_bind_plan_t plan[$]);
        foreach (plan[plan_index]) begin
            if (plan[plan_index].function_instance != null)
                plan[plan_index].function_instance.cancel_bind_pcie();
        end
        configuration_valid = 0;
        return 0;
    endfunction

    // 逐个 Function 预检并暂存其协议接口；若两个 Function 暂存了同一协议接口、
    // 同一 FSM 或同一 ops 候选（会共享运行态）则 UVM_FATAL 并返回 0。
    protected function bit preflight_plan(
        input pcie_bind_plan_t plan[$],
        output virtual virtio_protocol_event_if staged_protocol_vifs[DPU_MAX_FUNCTIONS]
    );
        int unsigned next_protocol_event_vif_index;
        virtio_auto_fsm staged_fsms[$];
        virtio_atomic_ops staged_ops[$];
        string alias_name;

        next_protocol_event_vif_index = 0;
        foreach (plan[plan_index]) begin
            if (!preflight_function_pcie(
                    plan[plan_index].function_instance,
                    plan[plan_index].rc_seqr,
                    next_protocol_event_vif_index,
                    staged_protocol_vifs[plan_index]))
                return 0;
            staged_fsms.push_back(
                plan[plan_index].function_instance.pending_pcie_fsm_candidate());
            staged_ops.push_back(
                plan[plan_index].function_instance.pending_pcie_ops_candidate());
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                alias_name = "";
                if (staged_protocol_vifs[plan_index] ==
                    staged_protocol_vifs[prior_index])
                    alias_name = "protocol event interface";
                else if (staged_fsms[plan_index] == staged_fsms[prior_index])
                    alias_name = "PCIe FSM candidate";
                else if (staged_ops[plan_index] == staged_ops[prior_index])
                    alias_name = "PCIe ops candidate";
                if (alias_name != "") begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "Active function indices %0d and %0d staged the same %s",
                        prior_index, plan_index, alias_name))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 只读校验 endpoint 计划中的 completion adapter 拓扑：一个 RC driver 只能
    // 喂一个 adapter；同一 adapter 内一个 domain 只能对应一个 RC driver，一个
    // RC driver 也不能代表多个 domain。标量计划（endpoint 为空）直接通过。
    protected function bit validate_plan_adapters(input pcie_bind_plan_t plan[$]);
        virtio_pcie_function_endpoint endpoint;
        virtio_pcie_function_endpoint prior_endpoint;
        bit same_domain;
        string why;

        foreach (plan[plan_index]) begin
            endpoint = plan[plan_index].endpoint;
            if ((endpoint == null) || (endpoint.completion_adapter == null))
                continue;
            if (!endpoint.completion_adapter.domain_rc_driver_binding_supported(
                    endpoint.pcie_id.domain, endpoint.rc_driver, why)) begin
                `uvm_fatal("VIRTIO_ENV", why)
                return 0;
            end
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                prior_endpoint = plan[prior_index].endpoint;
                if ((prior_endpoint == null) ||
                    (prior_endpoint.completion_adapter == null))
                    continue;
                if ((prior_endpoint.rc_driver == endpoint.rc_driver) &&
                    (prior_endpoint.completion_adapter !=
                     endpoint.completion_adapter)) begin
                    `uvm_fatal("VIRTIO_ENV",
                        "One RC driver cannot feed distinct completion adapters")
                    return 0;
                end
                if (prior_endpoint.completion_adapter != endpoint.completion_adapter)
                    continue;
                same_domain = dpu_same_domain_key(
                    prior_endpoint.pcie_id.domain, endpoint.pcie_id.domain);
                if (same_domain && (prior_endpoint.rc_driver != endpoint.rc_driver)) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "PCIe domain %s selects distinct RC drivers",
                        dpu_pcie_domain_key_name(endpoint.pcie_id.domain)))
                    return 0;
                end
                if (!same_domain && (prior_endpoint.rc_driver == endpoint.rc_driver)) begin
                    `uvm_fatal("VIRTIO_ENV",
                        "One RC driver cannot represent distinct PCIe domains")
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 每个 (adapter, domain) 组合只绑定一次 RC driver；必须在
    // validate_plan_adapters 通过之后调用，任一绑定失败返回 0。
    protected function bit commit_plan_adapters(input pcie_bind_plan_t plan[$]);
        virtio_pcie_function_endpoint endpoint;
        bit already_bound;

        foreach (plan[plan_index]) begin
            endpoint = plan[plan_index].endpoint;
            if ((endpoint == null) || (endpoint.completion_adapter == null))
                continue;
            already_bound = 0;
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                if ((plan[prior_index].endpoint != null) &&
                    (plan[prior_index].endpoint.completion_adapter ==
                     endpoint.completion_adapter) &&
                    dpu_same_domain_key(
                        plan[prior_index].endpoint.pcie_id.domain,
                        endpoint.pcie_id.domain))
                    already_bound = 1;
            end
            if (!already_bound &&
                !endpoint.completion_adapter.bind_domain_rc_driver(
                    endpoint.pcie_id.domain, endpoint.rc_driver))
                return 0;
        end
        return 1;
    endfunction

    // Function 绑定共用的空值检查：Function、driver agent、monitor 与 observer
    // 都必须存在；失败时 UVM_FATAL 并返回 0。
    protected function bit function_pcie_handles_valid(
        input virtio_function_instance function_instance
    );
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.monitor == null) ||
            (function_instance.driver_agent.observer == null)) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        return 1;
    endfunction

    // 解析第 slot_index 个协议接口槽位：先确认槽位池未耗尽；staged_protocol_vif
    // 非空时沿用预检结果；否则先查 cfg 的完整身份绑定。只有未启用显式绑定时，
    // 才从 config_db 读取旧 protocol_event_vif_<slot>；缺项不能静默跨域回退。
    // 失败时 UVM_FATAL 并返回 0，不改变接口所有权。
    protected function bit resolve_protocol_vif(
        input virtio_function_instance function_instance,
        input int unsigned slot_index,
        input virtual virtio_protocol_event_if staged_protocol_vif,
        output virtual virtio_protocol_event_if protocol_vif
    );
        protocol_vif = staged_protocol_vif;
        if (slot_index >= DPU_MAX_FUNCTIONS) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Protocol event interface pool exhausted at function BDF 0x%04h",
                function_instance.bdf))
            return 0;
        end
        if (protocol_vif != null)
            return 1;
        if (cfg.has_protocol_event_bindings()) begin
            if (!cfg.get_protocol_event_vif(function_instance.pcie_id, protocol_vif)) begin
                `uvm_fatal("VIRTIO_ENV", {"No explicit protocol event interface for ",
                    dpu_pcie_function_id_name(function_instance.pcie_id)})
                return 0;
            end
            return 1;
        end
        if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                null, "uvm_test_top",
                $sformatf("protocol_event_vif_%0d", slot_index), protocol_vif) ||
            (protocol_vif == null)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "No protocol event interface configured for active function %0d",
                slot_index))
            return 0;
        end
        return 1;
    endfunction

    // 预检单个 Function 所需的 observer、协议接口槽位和 FSM/ops；成功时返回 1、
    // 暂存 protocol_vif 并推进槽位索引，失败时 UVM_FATAL 且不提交任何连接。
    protected function bit preflight_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        inout int unsigned next_protocol_event_vif_index,
        output virtual virtio_protocol_event_if protocol_vif
    );
        string observer_why;

        protocol_vif = null;
        if (!function_pcie_handles_valid(function_instance))
            return 0;
        if (!function_instance.driver_agent.observer.
            preflight_mandatory_function_binding(
                function_instance.transport, observer_why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                {"Observer mandatory bind preflight failed for function ",
                 "BDF 0x%04h: %s"},
                function_instance.bdf, observer_why))
            return 0;
        end
        if (!resolve_protocol_vif(function_instance,
                next_protocol_event_vif_index, null, protocol_vif))
            return 0;
        if (!function_instance.preflight_bind_pcie(pcie_rc_seqr))
            return 0;
        next_protocol_event_vif_index++;
        return 1;
    endfunction

    // 提交一个已预检 Function 的共享内存、IOMMU、RC sequencer 和 monitor 连接；
    // 成功返回 1 并消费一个协议接口槽位，空句柄或提交失败返回 0。
    protected function bit bind_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input pcie_tl_base_monitor pcie_rc_monitor,
        input pcie_tl_base_monitor pcie_ep_monitor,
        inout int unsigned next_protocol_event_vif_index,
        input virtual virtio_protocol_event_if staged_protocol_vif = null
    );
        virtual virtio_protocol_event_if protocol_vif;

        if (!function_pcie_handles_valid(function_instance) ||
            !resolve_protocol_vif(function_instance,
                next_protocol_event_vif_index, staged_protocol_vif,
                protocol_vif))
            return 0;
        if (!function_instance.commit_bind_pcie(
            host_mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr)) begin
            return 0;
        end
        function_instance.driver_agent.observer.
            commit_mandatory_function_binding(
            function_instance.bdf, function_instance.transport);
        function_instance.driver_agent.monitor.protocol_vif = protocol_vif;
        next_protocol_event_vif_index++;
        if (pcie_rc_monitor != null)
            pcie_rc_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor != pcie_rc_monitor))
            pcie_ep_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        return 1;
    endfunction

    // ========================================================================
    // Report Phase
    //
    // Run leak checks and print barrier statistics.
    // Performance and verification reports are handled by their own
    // report_phase methods (called automatically by UVM).
    // 中文说明：配置成功时检查 Host memory、IOVA 和各 virtqueue 是否泄漏，
    // 并打印 barrier 统计；配置阶段已经失败时跳过，避免解引用未构造对象。
    // ========================================================================

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (!configuration_valid)
            return;

        `uvm_info("VIRTIO_ENV", "========== Environment Report ==========", UVM_LOW)

        // Leak checks
        host_mem.leak_check();
        iommu.leak_check();
        foreach (function_instances[index])
            function_instances[index].vq_mgr.leak_check();

        // Barrier stats
        barrier.print_stats();

        `uvm_info("VIRTIO_ENV", "========== End Environment Report ==========", UVM_LOW)
    endfunction

    // 导出真实已分配 ring 的 DPU 写表值；不分配资源，不改变 VIO 生命周期。
    extern function bit export_dpu_queues(
        input vio_external_setup	setup,
        input vio_config_scope		scope,
        output dpu_vio_queue_t		queues[$],
        output string				why
    );
    // 借用当前 setup；只读句柄不能绕过核心确认/释放校验。
    extern function vio_external_setup get_external_setup();
endclass : virtio_net_env

// 准备阶段不调用任何设备配置后端；先验证全部目标，再分配真实 ring 和本地接收规则。
task virtio_net_env::prepare_external_configuration(
    input vio_external_queue_binding_t bindings[$], output vio_external_setup setup,
    output bit ok, output string why);
    vio_queue_setup_t	records[$];
    vio_queue_setup_t	record;
    vio_service_requirement_t	requirement;
    dpu_vio_qpair_binding_t	pairs[$];
    vio_external_queue_binding_t	binding;
    virtio_function_instance	instance;
    virtio_external_config_backend	backend;
    virtio_queue_program_t	program_value;
    virtqueue_base	vq;
    bit	found;
    bit	step_ok;
    bit	consumed[int unsigned];
    int unsigned	qid;
    int unsigned	width;
    int unsigned	match_count;
    dpu_priv_queue_config	private_control;

    setup = null;
    ok = 0;
    why = "";
    if (cfg == null || !cfg.external_configuration || !configuration_valid ||
        live_external_setup != null || function_instances.size() == 0) begin
        why = "external prepare requires bound nonempty environment without an exported generation";
        return;
    end
    foreach (function_instances[f]) begin
        instance = function_instances[f];
        if (instance.driver_agent.ops == null || instance.driver_agent.fsm == null ||
            !instance.driver_agent.ops.uses_external_configuration() ||
            !instance.driver_agent.fsm.external_workers_stopped() ||
            instance.driver_agent.ops.has_active_queues() ||
            instance.driver_agent.ops.mem != host_mem || instance.driver_agent.ops.iommu != iommu) begin
            why = "external prepare requires idle Function with exact shared memory/IOMMU binding";
            return;
        end
        if (!cfg.resolve_final_service_requirement(instance.service_key, requirement, why)) return;
        resource_snapshot.list_vio_bindings_for_service(instance.service_key, pairs);
        if (!requirement.enabled || pairs.size() != requirement.behavior.num_queue_pairs) begin
            why = "allocated qpair count must exactly equal frozen service requirement";
            return;
        end
        foreach (pairs[p]) begin
            if (pairs[p].virtio_pair_index >= pairs.size() ||
                pairs[p].rx_local_virtqueue_id != 2*pairs[p].virtio_pair_index ||
                pairs[p].tx_local_virtqueue_id != 2*pairs[p].virtio_pair_index+1) begin
                why = "external service has invalid dense local queue mapping";
                return;
            end
            for (int unsigned direction = 0; direction < 2; direction++) begin
                if (direction ? !requirement.tx_enable : !requirement.rx_enable) continue;
                qid = direction ? pairs[p].tx_local_virtqueue_id : pairs[p].rx_local_virtqueue_id;
                found = 0;
                match_count = 0;
                foreach (bindings[b]) begin
                    if (dpu_service_key_name(bindings[b].service_key) ==
                        dpu_service_key_name(instance.service_key) && bindings[b].local_qid === qid) begin
                        binding = bindings[b];
                        consumed[b] = 1;
                        match_count++;
                        found = 1;
                    end
                end
                if (match_count > 1) begin
                    why = "external queue notification binding duplicated";
                    return;
                end
                if (!found) begin
                    if (!requirement.notify_layout_valid ||
                        requirement.completion_mode == VIRTIO_COMPLETION_MSIX ||
                        (requirement.notify_stride != 0 &&
                         qid > (64'hffff_ffff_ffff_ffff - requirement.notify_base) / requirement.notify_stride)) begin
                        why = "missing explicit notification/MSI-X binding or notify template overflow";
                        return;
                    end
                    binding.service_key = instance.service_key;
                    binding.local_qid = qid;
                    binding.notify_bar = requirement.notify_bar;
                    binding.notify_offset = requirement.notify_base + qid*requirement.notify_stride;
                    binding.notify_encoding = requirement.notify_encoding;
                    binding.local_vector = pairs[p].local_msix_vector_id;
                    binding.global_vector = pairs[p].global_msix_vector_id;
                    binding.msix_valid = 0;
                    binding.message_address = 0;
                    binding.message_data = 0;
                    binding.masked = 1;
                end
                width = (binding.notify_encoding == VIO_NOTIFY_QID16) ? 2 : 4;
                if ($isunknown({binding.local_qid, binding.notify_bar, binding.notify_offset,
                    binding.notify_encoding, binding.msix_valid, binding.local_vector,
                    binding.global_vector, binding.message_address, binding.message_data, binding.masked}) ||
                    binding.notify_bar > 5 || binding.notify_offset > 64'hffff_ffff ||
                    (binding.notify_offset % width) != 0 ||
                    !(binding.notify_encoding inside {VIO_NOTIFY_QID16, VIO_NOTIFY_DATA32, VIO_NOTIFY_DPU32}) ||
                    binding.local_vector != pairs[p].local_msix_vector_id ||
                    binding.global_vector != pairs[p].global_msix_vector_id) begin
                    why = "external notification contains unknown, out-of-range or mismatched identity";
                    return;
                end
                if (instance.transport.bar.bar_size[binding.notify_bar] < width ||
                    binding.notify_offset > instance.transport.bar.bar_size[binding.notify_bar] - width ||
                    (requirement.behavior.vq_type == VQ_CUSTOM && binding.notify_encoding != VIO_NOTIFY_DPU32) ||
                    (binding.notify_encoding == VIO_NOTIFY_DATA32 &&
                     !requirement.behavior.driver_features[VIRTIO_F_NOTIFICATION_DATA]) ||
                    (binding.notify_encoding == VIO_NOTIFY_QID16 &&
                     requirement.behavior.driver_features[VIRTIO_F_NOTIFICATION_DATA]) ||
                    (requirement.completion_mode == VIRTIO_COMPLETION_MSIX &&
                     (!binding.msix_valid || binding.masked || binding.message_address[1:0] != 0))) begin
                    why = "notification BAR/encoding or MSI-X message contract invalid";
                    return;
                end
                if (instance.private_cfg != null) begin
                    private_control = instance.private_cfg.resolve_queue(qid);
                    if (private_control == null || private_control.local_qid != qid ||
                        (private_control.notify_bar_present && private_control.notify_bar != binding.notify_bar) ||
                        (private_control.notify_offset_present && private_control.notify_offset != binding.notify_offset)) begin
                        why = "private local queue/explicit notification disagrees with external binding";
                        return;
                    end
                end
                foreach (records[r]) begin
                    if (records[r].pcie_id.domain.host_id == instance.pcie_id.domain.host_id &&
                        records[r].notification.msix_valid && binding.msix_valid &&
                        records[r].notification.message_address == binding.message_address &&
                        records[r].notification.message_data == binding.message_data &&
                        (dpu_function_key_name(records[r].service_key.function_key) !=
                         dpu_function_key_name(instance.function_key) ||
                         records[r].notification.local_vector != binding.local_vector)) begin
                        why = "ambiguous MSI-X address/data within Host";
                        return;
                    end
                    if (dpu_service_key_name(records[r].service_key) == dpu_service_key_name(instance.service_key) &&
                        records[r].notification.local_qid == qid) begin
                        why = "duplicate queue in resource snapshot";
                        return;
                    end
                end
                record.service_key = instance.service_key;
                record.pcie_id = instance.pcie_id;
                record.qpair = pairs[p];
                record.requirement = requirement;
                record.private_tx_control = '0;
                if (instance.private_cfg != null) begin
                    record.private_tx_control.dport_info = private_control.dport_info;
                    record.private_tx_control.dport_id = private_control.dport_id;
                    record.private_tx_control.dport_type = private_control.dport_type;
                    record.private_tx_control.cpu_tx_cos = private_control.cpu_tx_cos;
                    record.private_tx_control.rss_lag = private_control.rss_lag;
                    record.private_tx_control.l3_cs = private_control.l3_cs;
                    record.private_tx_control.l4_cs = private_control.l4_cs;
                    record.private_tx_control.i_l3_cs = private_control.i_l3_cs;
                    record.private_tx_control.i_l4_cs = private_control.i_l4_cs;
                    record.private_tx_control.fwd = private_control.fwd;
                end
                record.allocated_qpairs = pairs.size();
                record.notify_bar_base = instance.transport.bar.bar_base[binding.notify_bar];
                record.notify_bar_size = instance.transport.bar.bar_size[binding.notify_bar];
                record.notify_address = record.notify_bar_base + binding.notify_offset;
                record.notification = binding;
                record.queue_type = requirement.behavior.vq_type;
                record.completion_mode = requirement.completion_mode;
                record.tx_mode = direction;
                record.queue_size = requirement.behavior.queue_size;
                record.usable_descriptors = record.queue_size - (record.queue_type == VQ_CUSTOM);
                record.initial_index = 0;
                record.initial_wrap = 1;
                record.cq_bytes = (record.queue_type == VQ_CUSTOM) ? (direction ? 2 : 16*record.queue_size) : 0;
                record.desc_bytes = 16*record.queue_size;
                record.driver_bytes = (record.queue_type == VQ_CUSTOM) ? 0 : 4;
                record.device_bytes = (record.queue_type == VQ_CUSTOM) ? record.cq_bytes : 4;
                record.ring_valid_bytes = record.desc_bytes + record.driver_bytes + record.device_bytes;
                record.initial_tx_cq = (record.queue_type == VQ_CUSTOM && direction) ? 16'h8000 : 0;
                records.push_back(record);
            end
        end
    end
    if (consumed.num() != bindings.size()) begin
        why = "external bindings include unknown service/queue or disabled direction";
        return;
    end
    external_generation++;
    external_session_key = new("external_session_key");
    capture_external_participants();
    foreach (function_instances[f]) begin
        instance = function_instances[f];
        void'(cfg.resolve_final_service_requirement(instance.service_key, requirement, why));
        if (!instance.driver_agent.ops.begin_external_session(external_session_key, external_generation, requirement, why)) begin
            rollback_external_preparation();
            return;
        end
        instance.transport.notify_mgr.begin_external_notifications(instance.pcie_id.domain.host_id);
        instance.transport.notify_mgr.irq_mode = requirement.behavior.irq_mode;
    end
    foreach (records[r]) begin
        foreach (function_instances[f]) begin
            instance = function_instances[f];
            if (dpu_service_key_name(instance.service_key) != dpu_service_key_name(records[r].service_key)) continue;
            if (!$cast(backend, instance.driver_agent.ops.config_backend)) begin
                why = "external backend missing";
                rollback_external_preparation();
                return;
            end
            void'(cfg.resolve_final_service_requirement(instance.service_key, requirement, why));
            if (!backend.bind_queue(records[r].notification, instance.private_cfg,
                    requirement.behavior.rx_buf_size, why) ||
                !instance.transport.notify_mgr.register_external_queue(records[r].notification, why)) begin
                rollback_external_preparation();
                return;
            end
            program_value = virtio_empty_queue_program();
            program_value.queue_id = records[r].notification.local_qid;
            program_value.queue_size = records[r].queue_size;
            program_value.vq_type = records[r].queue_type;
            program_value.tx_mode = records[r].tx_mode;
            program_value.msix_vector = records[r].qpair.local_msix_vector_id;
            instance.driver_agent.ops.prepare_local_queue(program_value, step_ok);
            if (!step_ok) begin
                why = "local ring allocation/mapping failed before export";
                rollback_external_preparation();
                return;
            end
            vq = instance.vq_mgr.get_queue(program_value.queue_id);
            external_queue_refs.push_back(vq);
            records[r].desc_gpa = vq.desc_table_addr;
            records[r].driver_gpa = vq.driver_ring_addr;
            records[r].device_gpa = vq.device_ring_addr;
            records[r].desc_iova = program_value.desc_iova;
            records[r].driver_iova = program_value.driver_iova;
            records[r].device_iova = program_value.device_iova;
            records[r].ring_bytes = program_value.ring_bytes;
            void'(instance.driver_agent.ops.get_local_ring_regions(program_value.queue_id,
                records[r].region_gpas, records[r].region_bytes, records[r].region_iovas));
        end
    end
    live_external_setup = new("external_setup", this, device_snapshot, resource_snapshot,
                              external_generation, records);
    external_confirmed.delete();
    setup = live_external_setup;
    ok = 1;
endtask

// 保存实际参与者及共享内存身份；只有尚未交付的新代准备可以重建私有账本。
function void virtio_net_env::capture_external_participants();
    external_participant_t	p;

    external_participants.delete();
    external_queue_refs.delete();
    external_mem = host_mem;
    external_iommu = iommu;
    foreach (function_instances[f]) begin
        p.instance = function_instances[f];
        p.agent = p.instance.driver_agent;
        p.ops = p.agent.ops;
        p.fsm = p.agent.fsm;
        p.manager = p.instance.vq_mgr;
        p.transport = p.instance.transport;
        p.notifications = p.transport.notify_mgr;
        p.backend = p.ops.config_backend;
        p.client = p.instance.resource_client;
        p.monitor = p.agent.monitor;
        p.resource_manager = p.instance.resource_manager;
        p.service_key = p.instance.service_key;
        p.pcie_id = p.instance.pcie_id;
        external_participants.push_back(p);
    end
endfunction

// 未交付失败只释放本环境/本代拥有的资源；不要求尚未生成的 setup 或完整 ring 集合。
function void virtio_net_env::rollback_external_preparation();
    virtio_external_config_backend	backend;
    string	ignored;

    if (live_external_setup != null) return;
    foreach (external_participants[f]) begin
        if (external_participants[f].ops.release_external_session(external_session_key, external_generation, ignored)) begin
            external_participants[f].notifications.clear_external_notifications();
            if ($cast(backend, external_participants[f].backend)) backend.clear_bindings();
        end
    end
    external_participants.delete();
    external_queue_refs.delete();
    external_mem = null;
    external_iommu = null;
    external_session_key = null;
endfunction

// 私有参与者全集与公开集合一一对应；只有完成整项只读检查后，调用方才可提交状态变更。
function bit virtio_net_env::validate_external_generation(input vio_external_setup setup,
    input vio_config_scope scope, output int unsigned selected[$], output string why);
    external_participant_t	p;
    vio_queue_setup_t	records[$];
    bit	services[string];
    int unsigned	identity_count;
    int unsigned	qids[$];
    bit [63:0]	gpas[$];
    bit [63:0]	iovas[$];
    int unsigned	sizes[$];
    virtqueue_base	vq;
    iommu_mapping_t	mapping;
    int unsigned	bytes;
    string	service_name;

    why = "";
    selected.delete();
    if (setup == null || setup != live_external_setup ||
        !setup.belongs_to(this, device_snapshot, resource_snapshot, external_generation) ||
        external_participants.size() == 0 || function_instances.size() != external_participants.size() ||
        host_mem != external_mem || iommu != external_iommu) begin
        why = "external generation origin, participant count or shared memory identity changed";
        return 0;
    end
    if (scope != null && !scope.validate(setup, why)) return 0;
    setup.list_queues(records);
    if (records.size() != external_queue_refs.size()) begin
        why = "external exported queue identity set changed";
        return 0;
    end
    // 先核对全部拓扑，即使只确认第二个 service，也不能漏掉、重复或替换原参与者。
    foreach (external_participants[f]) begin
        p = external_participants[f];
        service_name = dpu_service_key_name(p.service_key);
        identity_count = 0;
        foreach (function_instances[current])
            if (function_instances[current] == p.instance) identity_count++;
        if (identity_count != 1 || services.exists(service_name)) begin
            why = "external participant missing, duplicated or replaced";
            return 0;
        end
        services[service_name] = 1;
        if (p.instance.driver_agent != p.agent || p.agent.ops != p.ops || p.agent.fsm != p.fsm ||
            p.instance.vq_mgr != p.manager || p.ops.vq_mgr != p.manager ||
            p.instance.transport != p.transport || p.ops.transport != p.transport ||
            p.transport.notify_mgr != p.notifications || p.ops.config_backend != p.backend ||
            p.instance.resource_client != p.client || p.agent.monitor != p.monitor ||
            p.monitor.transport != p.transport || p.monitor.vq_mgr != p.manager ||
            p.instance.resource_manager != p.resource_manager || p.fsm.ops != p.ops ||
            p.instance.mem != external_mem || p.ops.mem != external_mem || p.manager.mem != external_mem ||
            p.instance.iommu != external_iommu || p.ops.iommu != external_iommu || p.manager.iommu != external_iommu ||
            !p.ops.uses_external_configuration() ||
            dpu_service_key_name(p.instance.service_key) != service_name ||
            !dpu_same_function_key(p.instance.function_key, p.service_key.function_key) ||
            !p.instance.pcie_id_valid || !p.transport.pcie_id_valid ||
            !dpu_same_domain_key(p.instance.pcie_id.domain, p.pcie_id.domain) ||
            !dpu_same_domain_key(p.transport.pcie_id.domain, p.pcie_id.domain) ||
            p.instance.pcie_id.bdf != p.pcie_id.bdf || p.transport.pcie_id.bdf != p.pcie_id.bdf ||
            p.instance.bdf != p.pcie_id.bdf || p.transport.bdf != p.pcie_id.bdf ||
            p.manager.host_id != p.pcie_id.domain.host_id || p.manager.bdf != p.pcie_id.bdf ||
            !p.client.matches_service_binding(device_snapshot, resource_snapshot, p.service_key)) begin
            why = "external participant object, service owner or Host/BDF binding changed";
            return 0;
        end
        if (scope == null || scope.selects(p.service_key)) selected.push_back(f);
    end
    // 从不可变导出视图反向确认每个 service 均有私有参与者，防止只沿公开数组正向遍历漏项。
    foreach (records[r]) begin
        if (!services.exists(dpu_service_key_name(records[r].service_key))) begin
            why = "exported service has no exact generation participant";
            return 0;
        end
    end
    if (selected.size() == 0) begin
        why = "external scope has no generation participants";
        return 0;
    end
    foreach (selected[s]) begin
        p = external_participants[selected[s]];
        qids.delete();
        if (!p.fsm.external_workers_stopped()) begin
            why = "selected external workers must stop before confirmation or release";
            return 0;
        end
        foreach (records[r]) begin
            if (dpu_service_key_name(records[r].service_key) != dpu_service_key_name(p.service_key)) continue;
            qids.push_back(records[r].notification.local_qid);
            vq = p.manager.get_queue(records[r].notification.local_qid);
            if (vq == null || vq != external_queue_refs[r] || vq.mem != external_mem || vq.iommu != external_iommu ||
                vq.host_id != p.pcie_id.domain.host_id || vq.bdf != p.pcie_id.bdf ||
                vq.queue_id != records[r].notification.local_qid || vq.queue_size != records[r].queue_size ||
                vq.desc_table_addr != records[r].desc_gpa || vq.driver_ring_addr != records[r].driver_gpa ||
                vq.device_ring_addr != records[r].device_gpa ||
                !p.ops.get_local_ring_regions(vq.queue_id, gpas, sizes, iovas) ||
                gpas.size() != records[r].region_gpas.size() || sizes.size() != records[r].region_bytes.size() ||
                iovas.size() != records[r].region_iovas.size()) begin
                why = "external queue object, owner, geometry or exported region set changed";
                return 0;
            end
            bytes = 0;
            foreach (iovas[i]) begin
                if (gpas[i] != records[r].region_gpas[i] || sizes[i] != records[r].region_bytes[i] ||
                    iovas[i] != records[r].region_iovas[i] ||
                    !external_iommu.get_live_mapping_for_host(p.pcie_id.domain.host_id, p.pcie_id.bdf, iovas[i], mapping) ||
                    mapping.host_id != p.pcie_id.domain.host_id || mapping.bdf != p.pcie_id.bdf ||
                    mapping.iova != iovas[i] || mapping.gpa != gpas[i] || mapping.size != sizes[i] ||
                    mapping.dir != DMA_BIDIRECTIONAL) begin
                    why = "external ring live mapping differs from immutable export";
                    return 0;
                end
                bytes += sizes[i];
            end
            if (bytes != records[r].ring_bytes) begin
                why = "external ring allocation length changed";
                return 0;
            end
        end
        if (qids.size() == 0 || p.manager.get_queue_count() != qids.size()) begin
            why = "external participant complete queue set changed";
            return 0;
        end
        if (!p.ops.validate_external_session(external_session_key, external_generation, qids, why)) return 0;
    end
    return 1;
endfunction

// 所选 service 必须先全部预检再一起进入 READY；使用私有参与者和导出的冻结行为提交。
function bit virtio_net_env::confirm_external_configuration(
    input vio_external_setup setup, input vio_config_scope scope,
    input logic configured, output string why);
    vio_queue_setup_t	records[$];
    int unsigned	selected[$];
    int unsigned	qids[$];
    virtio_driver_config_t	behavior;
    external_participant_t	p;

    why = "";
    if (configured !== 1'b1 || scope == null) begin
        why = "external confirmation requires successful platform result and explicit scope";
        return 0;
    end
    if (!validate_external_generation(setup, scope, selected, why)) return 0;
    setup.list_queues(records);
    foreach (selected[s]) begin
        p = external_participants[selected[s]];
        qids.delete();
        foreach (records[r]) begin
            if (dpu_service_key_name(records[r].service_key) != dpu_service_key_name(p.service_key)) continue;
            qids.push_back(records[r].notification.local_qid);
            behavior = records[r].requirement.behavior;
        end
        if (!p.fsm.accept_external_configuration(external_session_key, external_generation, qids, behavior, why)) return 0;
        if (!p.client.mark_runtime_ready(why)) return 0;
        foreach (qids[q]) p.monitor.observe_queue_state(qids[q], 1, 1);
        p.instance.state = VF_CONFIGURED;
        external_confirmed[dpu_service_key_name(p.service_key)] = 1;
    end
    return 1;
endfunction

// 释放整代先完整预检，随后在无时间推进的函数内提交回收；任一失败保留所有 Function。
function bit virtio_net_env::release_external_resources(
    input vio_external_setup setup, input logic dut_quiesced, output string why);
    virtio_external_config_backend	backend;
    external_participant_t	p;
    int unsigned	selected[$];

    why = "";
    if (dut_quiesced !== 1'b1) begin
        why = "release requires explicit DUT quiescence";
        return 0;
    end
    if (!validate_external_generation(setup, null, selected, why)) return 0;
    foreach (selected[s]) begin
        p = external_participants[selected[s]];
        if (!p.ops.release_external_session(external_session_key, external_generation, why)) return 0;
        p.fsm.invalidate_external_configuration();
        p.monitor.reset_all_queue_state();
        p.client.reset_runtime_state();
        p.instance.state = VF_REINIT_REQUIRED;
        p.notifications.clear_external_notifications();
        if ($cast(backend, p.backend)) backend.clear_bindings();
    end
    live_external_setup = null;
    external_session_key = null;
    external_confirmed.delete();
    external_participants.delete();
    external_queue_refs.delete();
    external_mem = null;
    external_iommu = null;
    return 1;
endfunction

// 确认账本只承认当前环境交付的视图；释放后旧代查询立即为假。
// 复用唯一完整性 validator，使跨 Host 调用方在任何提交前完成全部 Host 预检。
function bit virtio_net_env::preflight_external_configuration(input vio_external_setup setup,
	input vio_config_scope scope, output string why);
	int unsigned	selected[$];
	return validate_external_generation(setup, scope, selected, why);
endfunction

// 只读恢复凭证：同一代重复确认不能解除取消，只有已确认的新准备代可重新开放业务。
function longint unsigned virtio_net_env::external_service_generation(input dpu_service_key_t key,
	input bit confirmed_only);
	if (confirmed_only && !external_service_confirmed(live_external_setup, key)) return 0;
	return external_generation;
endfunction

function bit virtio_net_env::external_service_confirmed(
	input vio_external_setup setup, input dpu_service_key_t key);
	return setup != null && setup == live_external_setup &&
		external_confirmed.exists(dpu_service_key_name(key)) &&
		external_confirmed[dpu_service_key_name(key)];
endfunction

// 失败撤销不能依赖完整几何校验；使用不可变视图和保存的私有参与者。
function bit virtio_net_env::preflight_external_revocation(input vio_external_setup setup,
	input vio_config_scope scope, output string why);
	int unsigned selected;
	why = "external revoke origin/generation/scope mismatch";
	if (setup == null || setup != live_external_setup || scope == null) return 0;
	if (!setup.belongs_to(this, device_snapshot, resource_snapshot, external_generation)) return 0;
	if (!scope.validate(setup, why)) return 0;
	selected = 0;
	foreach (external_participants[f]) begin
		if (!scope.selects(external_participants[f].service_key)) continue;
		selected++;
		if (external_participants[f].ops == null || external_participants[f].fsm == null) begin
			why = "external revoke saved participant is null"; return 0;
		end
		if (!external_participants[f].ops.owns_external_session(external_session_key, external_generation)) begin
			why = "external revoke saved participant credential mismatch";
			return 0;
		end
		if (!external_participants[f].fsm.external_workers_stopped()) begin
			why = "external revocation requires selected workers stopped";
			return 0;
		end
	end
	if (selected == 0) begin why = "external revoke has no owned participants"; return 0; end
	why = "";
	return 1;
endfunction

// 只关闭软件就绪，不改变设备、queue state、通知、映射或 DMA 分配。
function bit virtio_net_env::revoke_external_configuration(input vio_external_setup setup,
	input vio_config_scope scope, output string why);
	external_participant_t p;
	if (!preflight_external_revocation(setup, scope, why)) return 0;
	foreach (external_participants[f]) begin
		p = external_participants[f];
		if (!scope.selects(p.service_key)) continue;
		if (!p.ops.revoke_external_session(external_session_key, external_generation, why)) return 0;
		p.fsm.invalidate_external_configuration();
		p.client.reset_runtime_state();
		p.instance.state = VF_REINIT_REQUIRED;
		external_confirmed.delete(dpu_service_key_name(p.service_key));
	end
	return 1;
endfunction

// 当前代仅由本 env 管理；调用方不可替换或释放其内部对象。
function vio_external_setup virtio_net_env::get_external_setup();
    return live_external_setup;
endfunction

// 对照核心实际导出逐项投影；scope 与 ring 句柄先校验，失败不返回半份结果。
function bit virtio_net_env::export_dpu_queues(
    input vio_external_setup	setup,
    input vio_config_scope		scope,
    output dpu_vio_queue_t		queues[$],
    output string				why
);
    vio_queue_setup_t	records[$];
    dpu_vio_queue_t	queue;

    queues.delete();
    if (!preflight_external_configuration(setup, scope, why)) return 0;
    setup.list_queues(records);
    foreach (records[i]) begin
        if (scope != null && !scope.selects(records[i].service_key)) continue;
        queue.snapshot         = device_snapshot;
        queue.service_key      = records[i].service_key;
        queue.qpair            = records[i].qpair;
        queue.generation       = setup.get_generation();
        queue.virtio_mode      = records[i].queue_type == VQ_PACKED;
        queue.msix_enable      = records[i].completion_mode == VIRTIO_COMPLETION_MSIX;
        queue.tx_mode          = records[i].tx_mode;
        queue.local_qid        = records[i].notification.local_qid;
        queue.queue_size       = records[i].queue_size;
        queue.allocated_qpairs = records[i].allocated_qpairs;
        queue.desc_iova        = records[i].desc_iova;
        queue.notify_address   = records[i].notify_address;
        queue.notify_bar_base  = records[i].notify_bar_base;
        queue.notify_bar_size  = records[i].notify_bar_size;
        queues.push_back(queue);
    end
    return 1;
endfunction

`endif // VIRTIO_NET_ENV_SV
