// integration/project：项目顶层 env；由 project_env_pkg 在 cfg、device_env 之后包含。
// 本层拥有公共资源的创建责任和一个 DPU 组装子环境；不启动复位或业务流量。
// 平台已有 pool/executor/completion adapter 时只借用并校验，不能偷偷替换。
// 默认 executor 在 DPU build 前安装 backend，确保 bind_topology 不会丢失。
class project_env extends uvm_env;
    `uvm_component_utils(project_env)

    project_env_cfg		cfg;
    project_device_env		device_env;
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

    // load_params 幂等，既支持 base_test 先加载再注入，也支持直接创建 env 的平台。
    // 默认寄存器 backend 先接 executor，再让 DPU super.build 注入冻结 snapshot。
    virtual function void build_phase(uvm_phase	phase);
        dpu_pcie_reg_executor		executor;
        virtio_execution_profile	execution;

        super.build_phase(phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) || cfg == null)
            `uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
        cfg.load_params();
        prepare_host_memory();
        execution = cfg.vio_cfg.execution_profile();
        if (execution.has_model_device()) begin
            if (cfg.completion_adapter == null)
                `uvm_fatal("PROJECT_ENV", "MODEL requires the platform's shared completion adapter and device model")
            cfg.completion_adapter.install_factory_overrides();
        end else if (cfg.completion_adapter != null)
            `uvm_fatal("PROJECT_ENV", "REAL_DUT must use native/provider Completion routing")

        if (cfg.dpu_cfg.executor == null) begin
            reg_backend = pcie_tl_dpu_reg_backend::type_id::create("reg_backend");
            executor = dpu_pcie_reg_executor::type_id::create("reg_executor");
            executor.set_backend(reg_backend);
            cfg.dpu_cfg.executor = executor;
        end
        uvm_config_db#(project_env_cfg)::set(this, "device_env", "project_cfg", cfg);
        uvm_config_db#(dpu_device_env_config)::set(this, "device_env", "cfg", cfg.dpu_cfg);
        device_env = project_device_env::type_id::create("device_env", this);
        device_env.reg_backend = reg_backend;
    endfunction
endclass
