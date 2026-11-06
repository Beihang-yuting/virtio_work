// integration/project：可拷入已有项目的组合式 env；只继承 uvm_env。
// 依赖 DPU、原生 PCIe TL、VIO 与 AIP，由 project_env_pkg 在 cfg 后包含。
// 本层直接创建 DPU/PCIe/VIO；VIO 的 parent 指向 DPU，使 UVM 自动保证快照先发布。
// 平台已有 pool/executor/completion adapter 时只借用并校验，不能偷偷替换。
// 默认 executor 在 DPU build 前安装 backend；接口连接与初始化由 connect/run 入口负责。
class project_env extends uvm_env;
    `uvm_component_utils(project_env)

    project_env_cfg		cfg;
    dpu_device_env		dpu_env;
    pcie_tl_env			pcie_env;
    virtio_net_env		vio_envs[int unsigned];
    host_mem_pool		shared_pool;
    pcie_tl_dpu_reg_backend	reg_backend;

    // 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
    // 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
    protected function void prepare_host_memory();
        host_mem_pool	dpu_pool;

        shared_pool = cfg.host_mem_pool_binding;
        if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
            if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref))
                `uvm_fatal("PROJECT_ENV", "DPU memory owner is not a host_mem_pool")
            if (shared_pool != null && shared_pool != dpu_pool)
                `uvm_fatal("PROJECT_ENV", "project and DPU specify distinct Host pools")
            shared_pool = dpu_pool;
        end
        if (shared_pool == null) shared_pool = host_mem_pool::type_id::create("shared_pool");
        foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
            dpu_host_cfg		host;
            virtio_net_env_config	vio;
            host_mem_manager		manager;

            host = cfg.dpu_cfg.device_cfg.hosts[i];
            if (host == null || !host.has_gpa_aperture || host.gpa_limit <= host.gpa_base)
                `uvm_fatal("PROJECT_ENV", "each Host requires a nonempty GPA aperture")
            if (!cfg.vio_cfg_by_host.exists(host.host_id))
                `uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
            vio = cfg.vio_cfg_by_host[host.host_id];
            if (!shared_pool.has_host(host.host_id)) begin
                if (!shared_pool.create_host(host.host_id, host.gpa_base, host.gpa_limit - 1,
                        cfg.host_mem_mode, cfg.host_mem_granule, vio.host_mem_policy))
                    `uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
            end
            manager = shared_pool.get_host(host.host_id);
            if (!manager.is_initialized() || manager.get_host_id() != host.host_id ||
                !manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) ||
                manager.get_alloc_policy() != vio.host_mem_policy)
                `uvm_fatal("PROJECT_ENV", "existing Host memory disagrees with configured aperture/policy")
            if (vio.host_mem_binding != null ||
                (vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool))
                `uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
            vio.host_mem_pool_binding = shared_pool;
            vio.mem_base = host.gpa_base;
            vio.mem_end = host.gpa_limit - 1;
        end
        cfg.host_mem_pool_binding = shared_pool;
        cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
    endfunction

    // 按显式 Host→slot 准备原生 TL cfg；只借用同一 Host manager，不复制 BDF/BAR。
    // 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
    protected function void prepare_pcie_config();
        string	why;

        if (!cfg.validate_tl_mapping(why)) `uvm_fatal("PROJECT_ENV", why)
        if (cfg.pcie_cfg.switch_enable)
            `uvm_fatal("PROJECT_ENV", "native project reference does not create a Switch")
        cfg.pcie_cfg.rc_agent_enable = 1;
        cfg.pcie_cfg.ep_agent_enable = 1;
        cfg.pcie_cfg.num_rc = cfg.tl_slot_by_host.num();
        cfg.pcie_cfg.num_ep = cfg.tl_slot_by_host.num();
        foreach (cfg.tl_slot_by_host[h]) begin
            int unsigned		slot;
            host_mem_manager	manager;

            slot = cfg.tl_slot_by_host[h];
            manager = shared_pool.get_host(h);
            if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
                if (cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
                    !cfg.pcie_cfg.host_id_by_root.exists(slot) ||
                    cfg.pcie_cfg.host_id_by_root[slot] != h)
                    `uvm_fatal("PROJECT_ENV", "PCIe Host memory binding disagrees with DPU owner")
            end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why))
                `uvm_fatal("PROJECT_ENV", why)
            if (cfg.pcie_cfg.ep_root_by_index.exists(slot)) begin
                if (cfg.pcie_cfg.ep_root_by_index[slot] != slot)
                    `uvm_fatal("PROJECT_ENV", "native EP/RC slots must be paired")
            end else if (!cfg.pcie_cfg.bind_ep_root(slot, slot, why))
                `uvm_fatal("PROJECT_ENV", why)
        end
        if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num() ||
            cfg.pcie_cfg.ep_root_by_index.num() != cfg.tl_slot_by_host.num())
            `uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
    endfunction

    // 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
    // create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
    // PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
    virtual function void build_phase(uvm_phase	phase);
        dpu_pcie_reg_executor		executor;
        virtio_execution_profile	execution;

        super.build_phase(phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) || cfg == null)
            `uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
        cfg.load_params();
        prepare_host_memory();
        prepare_pcie_config();
        execution = cfg.vio_cfg.execution_profile();
        if (execution.has_model_device()) begin
            if (cfg.completion_adapter == null)
                `uvm_fatal("PROJECT_ENV", "MODEL requires the platform's shared completion adapter and device model")
            cfg.completion_adapter.install_factory_overrides();
        end else if (cfg.completion_adapter != null)
            `uvm_fatal("PROJECT_ENV", "REAL_DUT must use native Completion routing")

        if (cfg.dpu_cfg.executor == null) begin
            reg_backend = pcie_tl_dpu_reg_backend::type_id::create("reg_backend");
            executor = dpu_pcie_reg_executor::type_id::create("reg_executor");
            executor.set_backend(reg_backend);
            cfg.dpu_cfg.executor = executor;
        end
        uvm_config_db#(dpu_device_env_config)::set(this, "dpu_env", "cfg", cfg.dpu_cfg);
        dpu_env = dpu_device_env::type_id::create("dpu_env", this);

        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", cfg.pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        foreach (cfg.vio_cfg_by_host[h]) begin
            string	child_name;

            child_name = $sformatf("vio_h%0d", h);
            uvm_config_db#(virtio_net_env_config)::set(
                dpu_env, child_name, "cfg", cfg.vio_cfg_by_host[h]);
            vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
        end
    endfunction

    // 单 EP 使用标量，多个 EP 使用数组；只返回已有 monitor，不创建替代观察者。
    protected function pcie_tl_base_monitor ep_monitor_at(int unsigned	slot);
        if (pcie_env.ep_agents.size() != 0) begin
            if (slot < pcie_env.ep_agents.size() && pcie_env.ep_agents[slot] != null)
                return pcie_env.ep_agents[slot].monitor;
            return null;
        end
        if (slot == 0 && pcie_env.ep_agent != null) return pcie_env.ep_agent.monitor;
        return null;
    endfunction

    // SV_IF_MODE 绑定平台实际接口；TLM 模式由模型路径接线。缺接口或跨槽位复用立即失败。
    // 两个方向分别使用一个 VIF，避免两套 adapter 驱动同一接口。
    protected function void bind_native_vifs();
        virtual pcie_tl_if	used[$];

        if (cfg.pcie_cfg.if_mode != SV_IF_MODE) return;
        foreach (cfg.tl_slot_by_host[h]) begin
            int unsigned	slot;

            slot = cfg.tl_slot_by_host[h];
            if (!cfg.rc_vifs.exists(slot) || cfg.rc_vifs[slot] == null ||
                !cfg.ep_vifs.exists(slot) || cfg.ep_vifs[slot] == null)
                `uvm_fatal("PROJECT_ENV", $sformatf("missing native VIF for TL slot %0d", slot))
            if (cfg.rc_vifs[slot] == cfg.ep_vifs[slot])
                `uvm_fatal("PROJECT_ENV", "RC and EP directions must use distinct VIFs")
            foreach (used[i]) begin
                if (used[i] == cfg.rc_vifs[slot] || used[i] == cfg.ep_vifs[slot])
                    `uvm_fatal("PROJECT_ENV", "native VIF reused by distinct TL slots")
            end
            used.push_back(cfg.rc_vifs[slot]);
            used.push_back(cfg.ep_vifs[slot]);
            if (slot >= pcie_env.rc_adapters.size() || pcie_env.rc_adapters[slot] == null)
                `uvm_fatal("PROJECT_ENV", "native RC adapter is missing")
            pcie_env.rc_adapters[slot].vif = cfg.rc_vifs[slot];
            if (pcie_env.ep_adapters.size() != 0) begin
                if (slot >= pcie_env.ep_adapters.size() || pcie_env.ep_adapters[slot] == null)
                    `uvm_fatal("PROJECT_ENV", "native EP adapter is missing")
                pcie_env.ep_adapters[slot].vif = cfg.ep_vifs[slot];
            end else begin
                if (slot != 0 || pcie_env.ep_adapter == null)
                    `uvm_fatal("PROJECT_ENV", "native scalar EP adapter is missing")
                pcie_env.ep_adapter.vif = cfg.ep_vifs[slot];
            end
        end
    endfunction

    // 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
    // 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
    protected function void bind_protocol_vifs();
        virtual virtio_protocol_event_if	used[$];
        virtual virtio_protocol_event_if	vif;
        int unsigned				slot;
        string					why;

        slot = 0;
        foreach (vio_envs[h]) begin
            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance	f;

                f = vio_envs[h].function_instances[i];
                if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
                    if (cfg.protocol_vifs.size() != 0) begin
                        if (slot >= cfg.protocol_vifs.size())
                            `uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
                        vif = cfg.protocol_vifs[slot];
                    end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                            null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif))
                        `uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
                    if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why))
                        `uvm_fatal("PROJECT_ENV", why)
                end
                if (vif == null) `uvm_fatal("PROJECT_ENV", "protocol VIF is null")
                foreach (used[j]) begin
                    if (used[j] == vif)
                        `uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
                end
                used.push_back(vif);
                slot++;
            end
        end
    endfunction

    // connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
    // 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
    virtual function void connect_phase(uvm_phase	phase);
        super.connect_phase(phase);
        if (pcie_env.global_cfg != null || pcie_env.topology_adapter != null ||
            pcie_env.backend_provider_active || pcie_env.cfg != cfg.pcie_cfg)
            `uvm_fatal("PROJECT_ENV", "native reference requires the direct PCIe cfg-only path")
        bind_native_vifs();
        bind_protocol_vifs();
        if (reg_backend != null) begin
            reg_backend.bind_virtual_sequencer(pcie_env.v_seqr);
            foreach (cfg.tl_slot_by_host[h])
                reg_backend.bind_domain_root(h, 0, cfg.tl_slot_by_host[h]);
        end
        foreach (vio_envs[h]) begin
            virtio_pcie_function_endpoint	endpoints[$];
            int unsigned				slot;

            slot = cfg.tl_slot_by_host[h];
            if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null)
                `uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance		f;
                virtio_pcie_function_endpoint	endpoint;

                f = vio_envs[h].function_instances[i];
                if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0)
                    `uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
                endpoint = virtio_pcie_function_endpoint::type_id::create(
                    $sformatf("endpoint_h%0d_f%0d", h, i));
                endpoint.configure(f.pcie_id, pcie_env.rc_agents[slot].sequencer,
                    pcie_env.rc_agents[slot].rc_driver, cfg.completion_adapter,
                    pcie_env.rc_agents[slot].monitor, ep_monitor_at(slot));
                endpoints.push_back(endpoint);
            end
            if (!vio_envs[h].bind_pcie_endpoints(endpoints))
                `uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
        end
    endfunction

    // 平台确认复位、TL 接口和 DMA 服务就绪后调用；计划包含 bootstrap，不能重复配置。
    // 状态管理和执行报告全部委托已创建的 dpu_env，不在项目层复制另一份执行状态。
    task configure_device();
        dpu_reg_plan		plan;
        dpu_execution_report	report;
        string			why;

        if (!dpu_env.build_vio_register_plan(plan, why)) `uvm_fatal("PROJECT_ENV", why)
        dpu_env.apply_vio_register_plan(plan, report);
        if (report == null) `uvm_fatal("PROJECT_ENV", "DPU returned no execution report")
        if (report.status() != DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("PROJECT_ENV", report.reason())
    endtask

    // 每个仿真调用一次：按完整 service 身份登记各 Host，再注册已有 Tcl 命令。
    // 空 Host 可跳过；全局没有 VIO service 或重复注册属于接入错误。
    function void register_aip_commands();
        int unsigned	active_hosts;
        string		why;

        active_hosts = 0;
        foreach (vio_envs[h]) begin
            if (vio_envs[h].function_instances.size() == 0) continue;
            if (!virtio_aip_registry::bind_env(vio_envs[h], why))
                `uvm_fatal("PROJECT_ENV", why)
            active_hosts++;
        end
        if (active_hosts == 0) `uvm_fatal("PROJECT_ENV", "no VIO service available for AIP")
        if (!virtio_aip_registry::register_commands(why)) `uvm_fatal("PROJECT_ENV", why)
    endfunction
endclass
