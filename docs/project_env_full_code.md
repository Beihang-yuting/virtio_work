# 项目 env / env_cfg 完整代码

以下代码逐文件完整展开，和 `integration/project/` 源文件一致，没有省略函数体。
具体接入顺序、参数和平台边界见 [集成说明](../integration/project/README.md)。
默认是 REAL_DUT；`project_base_test` 是虚基类，平台必须实现其句柄注入、准备和收尾接口。

## 大配置与参数构造：project_env_cfg.sv

[源文件](../integration/project/project_env_cfg.sv)

```systemverilog
// integration/project：项目级配置组合与参数构建示例。
// 依赖 DPU/PCIe topology/TL/VIO/AIP package；由 project_env_pkg 按顺序包含。
// cfg 拥有创建的配置对象，借用平台注入的 pool、IOMMU、VIF 和 backend factory。
// load_params 只生成输入，不解析快照、不创建组件、不访问 DUT；每个对象只加载一次。
// 默认场景为每 Host 一个 domain 和一条 RC→EP 直连；物理自定义须同时提供三张映射。
class project_env_cfg extends uvm_object;
    `uvm_object_utils(project_env_cfg)

    dpu_device_env_config	dpu_cfg;
    virtio_net_env_config	vio_cfg;
    virtio_net_env_config	vio_cfg_by_host[int unsigned];
    pcie_tl_env_config		pcie_cfg;
    pcie_global_cfg		pcie_hw_cfg;
    pcie_dpu_root_binding_cfg	root_bindings;
    pcie_dpu_attachment_cfg	attachments;
    pcie_tl_backend_factory	backend_factory;
    // MODEL 平台只安装一个 completion adapter；实际 Virtio 设备模型由平台创建。
    virtio_tlm_completion_adapter	completion_adapter;

    host_mem_pool			host_mem_pool_binding;
    alloc_mode_e			host_mem_mode = MODE_BUDDY;
    int unsigned			host_mem_granule = DEFAULT_MIN_GRANULE;
    virtual pcie_tl_if			rc_vifs[int unsigned];
    virtual pcie_tl_if			ep_vifs[string];
    virtual virtio_protocol_event_if	protocol_vifs[$];

    // 这是配置生成规模，不是另一套已解析拓扑；最终身份以 DPU snapshot 为准。
    longint unsigned	hosts = 1;
    longint unsigned	pfs_per_host = 1;
    longint unsigned	vfs_per_pf = 0;
    protected bit	params_loaded = 0;

    // 创建配置容器；默认 REAL_DUT，实际 HDL/后端由平台注入。
    // new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
    function new(string	name = "project_env_cfg");
        super.new(name);
        dpu_cfg = dpu_device_env_config::type_id::create("dpu_cfg");
        vio_cfg = virtio_net_env_config::type_id::create("vio_cfg");
        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_hw_cfg = pcie_global_cfg::type_id::create("pcie_hw_cfg");
        root_bindings = pcie_dpu_root_binding_cfg::type_id::create("root_bindings");
        attachments = pcie_dpu_attachment_cfg::type_id::create("attachments");
        vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
        dpu_cfg.device_cfg.af_request.mode = DPU_AF_SELECTED;
        dpu_cfg.device_cfg.af_request.requester =
            '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
    endfunction

    // 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
    // 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
    protected function dpu_host_cfg make_host_template();
        dpu_host_cfg		host;
        dpu_pcie_domain_cfg	domain;
        dpu_mmio_window_cfg	window;
        dpu_bdf_range_t		bdf_range;

        host = dpu_host_cfg::type_id::create("host_template");
        host.has_gpa_aperture = 1;
        host.gpa_base = 64'h0000_1000_0000_0000;
        host.gpa_limit = host.gpa_base + 64'h1000_0000;
        domain = dpu_pcie_domain_cfg::type_id::create("domain_template");
        domain.key = '{host_id:0, segment_id:0};
        bdf_range = '{first_bdf:16'h0010, last_bdf:16'h0fff};
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create("mmio_template");
        window.base = 64'h0000_0020_0000_0000;
        window.limit = window.base + 64'h0000_0001_0000_0000;
        window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};
        domain.mmio_windows.push_back(window);
        domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;
        host.pcie_domains.push_back(domain);
        return host;
    endfunction

    // 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
    // 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
    protected function dpu_function_cfg make_function(
        int unsigned	host_id,
        int unsigned	pf_id,
        dpu_function_kind_e	kind,
        int unsigned	vf_id
    );
        dpu_function_cfg	f;
        dpu_bar_role_e		roles[3] = '{DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX};
        string			why;

        f = dpu_function_cfg::type_id::create(
            $sformatf("fn_h%0d_pf%0d_%0d_vf%0d", host_id, pf_id, kind, vf_id));
        f.key = '{host_id:host_id, pf_id:pf_id, kind:kind, vf_id:vf_id};
        f.domain_key = '{host_id:host_id, segment_id:0};
        f.bdf_mode = DPU_ALLOC_AUTO;
        f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        foreach (roles[i]) begin
            dpu_bar_profile_t	profile;
            dpu_bar_request	bar;

            if (!dpu_cfg.device_cfg.dut_caps.lookup_bar_profile(kind, roles[i], profile, why))
                `uvm_fatal("PROJECT_CFG", why)
            bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", i));
            bar.role = profile.role;
            bar.even_bar_id = profile.even_bar_id;
            bar.size = profile.size;
            bar.alignment = profile.alignment;
            bar.placement = DPU_ALLOC_AUTO;
            f.bars.push_back(bar);
        end
        return f;
    endfunction

    // 生成示例的直连物理图及两类显式映射。已有完整物理配置保持借用，不改写。
    // 自定义 topology 缺 Root/attachment 时拒绝；默认映射只在本函数创建图时推导。
    protected function void build_physical_config();
        pcie_topology_builder	builder;
        string			why;

        if (pcie_hw_cfg.topology != null) begin
            if ((root_bindings.bindings.size() == 0) ||
                (attachments.attachments.size() == 0))
                `uvm_fatal("PROJECT_CFG", "custom topology requires explicit Root and Function mappings")
            return;
        end
        if ((root_bindings.bindings.size() != 0) || (attachments.attachments.size() != 0))
            `uvm_fatal("PROJECT_CFG", "physical mappings require a matching custom topology")
        builder = pcie_topology_builder::type_id::create("project_topology_builder");
        for (int unsigned	h = 0; h < hosts; h++) begin
            void'(builder.add_rc($sformatf("RC%0d", h)));
            void'(builder.add_ep($sformatf("EP%0d", h)));
            void'(builder.connect($sformatf("RC%0d_EP%0d", h, h),
                $sformatf("RC%0d", h), PCIE_TOPO_PORT_RC, 0,
                $sformatf("EP%0d", h), PCIE_TOPO_PORT_EP, 0, 16, 4));
            if (!root_bindings.bind_domain_to_root(h, 0, h, why))
                `uvm_fatal("PROJECT_CFG", why)
        end
        pcie_hw_cfg.build_default_for_topology(builder.finish());
        foreach (dpu_cfg.device_cfg.functions[i]) begin
            dpu_function_cfg	f;

            f = dpu_cfg.device_cfg.functions[i];
            if (!attachments.add(f.key, $sformatf("EP%0d", f.key.host_id),
                    $sformatf("RC%0d_EP%0d", f.key.host_id, f.key.host_id), 0, 0, why))
                `uvm_fatal("PROJECT_CFG", why)
        end
    endfunction

    // 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
    // 再调用幂等返回，不重新采样；拒绝覆盖已存在的逻辑拓扑，复杂预建拓扑应派生本类。
    // base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
    virtual function void load_params();
        dpu_dut_caps			caps;
        dpu_host_cfg			host_template;
        dpu_resource_pool_config_t	profile;
        dpu_vio_placement_request	request;
        virtio_execution_profile	execution;
        int unsigned			max_initial_pairs;
        string				why;

        if (params_loaded) return;
        if ((dpu_cfg.device_cfg.hosts.size() != 0) ||
            (dpu_cfg.device_cfg.functions.size() != 0) ||
            (dpu_cfg.placement_cfg.vio_requests.size() != 0) ||
            (dpu_cfg.placement_cfg.profiles.size() != 0))
            `uvm_fatal("PROJECT_CFG", "default authoring cannot overwrite an existing DPU topology")
        dpu_cfg.device_cfg.load_params("dpu");
        caps = dpu_cfg.device_cfg.dut_caps;
        if (!caps.validate(why)) `uvm_fatal("PROJECT_CFG", why)
`ifdef AIP_CMDLINE_SV
        `DPU_AIP_UINT("dpu", longint unsigned, hosts, this.hosts)
        `DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, this.pfs_per_host)
        `DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, this.vfs_per_pf)
        begin
            alloc_mode_e		mem_mode;
            host_mem_alloc_policy_e	mem_policy;
            longint unsigned		mem_granule;

            `aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
            `aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
            `DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)
            if ((mem_granule == 0) || (mem_granule > 64) ||
                ((mem_granule & (mem_granule - 1)) != 0))
                `uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
            host_mem_mode = mem_mode;
            host_mem_granule = int'(mem_granule);
            vio_cfg.host_mem_policy = mem_policy;
        end
`endif
        if ((hosts == 0) || (hosts > caps.max_hosts) ||
            (pfs_per_host == 0) || (pfs_per_host > caps.max_pfs_per_host) ||
            (pfs_per_host > 4) || (vfs_per_pf > caps.max_vfs_per_pf))
            `uvm_fatal("PROJECT_CFG", "Host/PF/VF counts exceed DUT or VIO source-id capacity")
        if ((hosts * pfs_per_host * (1 + vfs_per_pf)) > caps.max_functions)
            `uvm_fatal("PROJECT_CFG", "total Function count exceeds DUT capability")

        vio_cfg.load_params("vio");
        host_template = make_host_template();
        host_template.load_params("dpu");
        profile.name = "virtio.qpair";
        profile.class_id = '0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = caps.vio_global_qpair_count;
        profile.max_per_function = caps.max_vio_net_qpairs_per_device;
        dpu_cfg.placement_cfg.profiles.push_back(profile);
        request = dpu_vio_placement_request::type_id::create("vio_request");
        request.request_id = 0;
        request.candidate_kind = (vfs_per_pf == 0) ? DPU_VIO_CANDIDATE_PF_ONLY : DPU_VIO_CANDIDATE_VF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        max_initial_pairs = 0;

        for (int unsigned	h = 0; h < hosts; h++) begin
            dpu_host_cfg		host;
            virtio_net_env_config	host_vio;
            bit [64:0]			base;
            bit [64:0]			limit;

            host = dpu_host_cfg::type_id::create($sformatf("host_%0d", h));
            host.copy_from(host_template);
            host.host_id = h;
            host.pcie_domains[0].key.host_id = h;
            base = {1'b0, host.gpa_base} + h * 65'h0000_0100_0000_0000;
            limit = {1'b0, host.gpa_limit} + h * 65'h0000_0100_0000_0000;
            if (base[64] || limit[64]) `uvm_fatal("PROJECT_CFG", "Host GPA stride overflows")
            host.gpa_base = base[63:0];
            host.gpa_limit = limit[63:0];
            base = {1'b0, host.pcie_domains[0].mmio_windows[0].base} + h * 65'h0000_0010_0000_0000;
            limit = {1'b0, host.pcie_domains[0].mmio_windows[0].limit} + h * 65'h0000_0010_0000_0000;
            if (base[64] || limit[64]) `uvm_fatal("PROJECT_CFG", "Host MMIO stride overflows")
            host.pcie_domains[0].mmio_windows[0].base = base[63:0];
            host.pcie_domains[0].mmio_windows[0].limit = limit[63:0];
            host.load_params($sformatf("dpu.h%0d", h));
            dpu_cfg.device_cfg.hosts.push_back(host);

            host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
            host_vio.copy_defaults_from(vio_cfg);
            host_vio.host_id = h;
            host_vio.host_scope_enable = 1;
            host_vio.host_scope_id = h;
            host_vio.load_params($sformatf("vio.h%0d", h));
            host_vio.enable_service_params("vio");
            if (host_vio.execution_mode != vio_cfg.execution_mode)
                `uvm_fatal("PROJECT_CFG", "one PCIe environment requires consistent VIO execution modes")
            vio_cfg_by_host[h] = host_vio;
            if (host_vio.default_num_pairs > max_initial_pairs)
                max_initial_pairs = host_vio.default_num_pairs;

            for (int unsigned	pf = 0; pf < pfs_per_host; pf++) begin
                dpu_function_cfg	f;
                string			path;

                path = $sformatf("dpu.h%0d.pf%0d", h, pf);
                f = make_function(h, pf, DPU_FUNCTION_PF, 0);
                f.load_params(path);
                dpu_cfg.device_cfg.functions.push_back(f);
                if (vfs_per_pf == 0) begin
                    request.fixed_devices.push_back(f.key);
                end
                for (int unsigned	vf = 0; vf < vfs_per_pf; vf++) begin
                    f = make_function(h, pf, DPU_FUNCTION_VF, vf);
                    f.load_params($sformatf("%s.vf%0d", path, vf));
                    dpu_cfg.device_cfg.functions.push_back(f);
                    request.fixed_devices.push_back(f.key);
                end
            end
        end
        // 单个 placement request 在候选间分配资源；按最大初始 pairs 预留，
        // 保证 Host 行为覆盖不会因为全局平均分配而缺容量。用户仍可覆盖 qpairs。
        request.total_qpairs = request.fixed_devices.size() * max_initial_pairs;
        dpu_cfg.placement_cfg.vio_requests.push_back(request);
        dpu_cfg.placement_cfg.load_params("dpu");
        dpu_cfg.vio_policy.load_params("dpu");
        build_physical_config();

        execution = vio_cfg.execution_profile();
        if (execution == null) `uvm_fatal("PROJECT_CFG", "invalid execution profile")
        pcie_cfg.if_mode = execution.pcie_if_mode();
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = execution.ep_is_active();
        pcie_cfg.ep_auto_response = execution.ep_auto_response();
        pcie_cfg.use_unified_mem = 1;
        pcie_cfg.mem_access_mode = PCIE_TL_MEM_PER_BUFFER;
        pcie_cfg.load_params("pcie_cfg");
        if (pcie_cfg.ep_auto_response != execution.ep_auto_response())
            `uvm_fatal("PROJECT_CFG", "EP auto response conflicts with the execution profile")
        params_loaded = 1;
    endfunction
endclass
```

## DPU 解析后组装 PCIe 和 VIO：project_device_env.sv

[源文件](../integration/project/project_device_env.sv)

```systemverilog
// integration/project：DPU 解析完成后的 PCIe/VIO 组装层，由 project_env_pkg 包含。
// 依赖 dpu_device_env、pcie_dpu_cfg_adapter、pcie_tl_env 和 virtio_net_env。
// 本层继承 DPU 生命周期以保证 super.build_phase 先发布冻结快照，再创建消费者；
// VIO 本身不继承 DPU，也不再次分配 Host/PF/VF、BDF、BAR 或 qpair。
// 组件归 UVM 所有；project_cfg、共享内存、外部 VIF/backend 均为借用句柄。
class project_device_env extends dpu_device_env;
    `uvm_component_utils(project_device_env)

    project_env_cfg	cfg;
    pcie_global_cfg	projected_pcie_cfg;
    pcie_tl_env		pcie_env;
    virtio_net_env	vio_envs[int unsigned];
    // 仅默认 executor 使用该 backend；平台注入 executor 时由平台负责连接它。
    pcie_tl_dpu_reg_backend	reg_backend;

    // 构造组件壳；配置与快照在 build 中获取，不在 new 中访问父组件。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 对外汇总配置错误；保留全部适配器诊断，任一错误阻止创建 PCIe 子环境。
    protected function void require_no_errors(string	stage, string	errors[$]);
        string	message;

        message = stage;
        foreach (errors[i]) message = {message, "; ", errors[i]};
        if (errors.size() != 0) `uvm_fatal("PROJECT_DEVICE", message)
    endfunction

    // 将 DPU 的冻结身份/地址/资源投影到 PCIe；只从 hw cfg 复制物理链路策略。
    // 不使用 hw cfg 的 device images 覆盖快照；Root 内存绑定在 PCIe build 前完成。
    protected function void project_pcie_config();
        pcie_dpu_cfg_adapter	adapter;
        pcie_dpu_system_cfg	policy;
        host_mem_manager	manager;
        string			errors[$];
        string			why;

        adapter = pcie_dpu_cfg_adapter::type_id::create("dpu_to_pcie");
        if (!adapter.project_with_root_bindings(get_snapshot(), get_resource_snapshot(),
                cfg.pcie_hw_cfg.topology, cfg.attachments, cfg.root_bindings,
                projected_pcie_cfg, errors)) begin
            require_no_errors("DPU to PCIe projection failed", errors);
            `uvm_fatal("PROJECT_DEVICE", "DPU to PCIe projection returned no configuration")
        end
        policy = pcie_dpu_system_cfg::type_id::create("pcie_link_policy");
        policy.pcie_policy = cfg.pcie_hw_cfg;
        // 当前 helper 不复制此开关，必须在 helper 的 validate 之前显式传递。
        projected_pcie_cfg.svt_bridge_enable = cfg.pcie_hw_cfg.svt_bridge_enable;
        if (!policy.apply_pcie_policy(projected_pcie_cfg, errors))
            require_no_errors("PCIe physical policy failed", errors);

        foreach (cfg.root_bindings.bindings[i]) begin
            pcie_dpu_root_binding	binding;

            binding = cfg.root_bindings.bindings[i];
            if (!cfg.host_mem_pool_binding.has_host(binding.host_id))
                `uvm_fatal("PROJECT_DEVICE", "Root refers to a Host without shared memory")
            manager = cfg.host_mem_pool_binding.get_host(binding.host_id);
            if (cfg.pcie_cfg.host_mem_by_root.exists(binding.root_index)) begin
                if ((cfg.pcie_cfg.host_mem_by_root[binding.root_index] != manager) ||
                    !cfg.pcie_cfg.host_id_by_root.exists(binding.root_index) ||
                    (cfg.pcie_cfg.host_id_by_root[binding.root_index] != binding.host_id))
                    `uvm_fatal("PROJECT_DEVICE", "pre-bound PCIe memory disagrees with DPU Host owner")
            end else if (!cfg.pcie_cfg.bind_host_memory(
                    binding.root_index, binding.host_id, manager, why))
                `uvm_fatal("PROJECT_DEVICE", why)
        end
    endfunction

    // 必须先调用 DPU build：它唯一执行 resolver 并发布 device/resource/manager。
    // 子 VIO 继承 config_db 的快照发布范围；每 Host 只收到自己的行为 cfg。
    virtual function void build_phase(uvm_phase	phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg) || cfg == null)
            `uvm_fatal("PROJECT_DEVICE", "project_cfg is missing")
        super.build_phase(phase);
        project_pcie_config();

        uvm_config_db#(pcie_global_cfg)::set(this, "pcie_env", "global_cfg", projected_pcie_cfg);
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", cfg.pcie_cfg);
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "tl_policy_cfg", cfg.pcie_cfg);
        if (cfg.backend_factory != null)
            uvm_config_db#(pcie_tl_backend_factory)::set(
                this, "pcie_env", "pcie_tl_backend_factory", cfg.backend_factory);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        foreach (cfg.vio_cfg_by_host[h]) begin
            string	child_name;

            child_name = $sformatf("vio_h%0d", h);
            uvm_config_db#(virtio_net_env_config)::set(this, child_name, "cfg", cfg.vio_cfg_by_host[h]);
            vio_envs[h] = virtio_net_env::type_id::create(child_name, this);
        end
    endfunction

    // 根据规范物理节点顺序找到 EP 槽位；禁止把 Function 下标当成 EP 下标。
    // 无对应节点返回 -1，调用者据此拒绝错误 attachment。
    protected function int find_ep_slot(string	node_id);
        if (pcie_env.topology_adapter == null) return -1;
        if (pcie_env.cfg.switch_enable) begin
            foreach (pcie_env.topology_adapter.switch_ep_node_ids[i])
                if (pcie_env.topology_adapter.switch_ep_node_ids[i] == node_id) return i;
        end else begin
            foreach (pcie_env.topology_adapter.direct_ep_node_ids[i])
                if (pcie_env.topology_adapter.direct_ep_node_ids[i] == node_id) return i;
        end
        return -1;
    endfunction

    // 统一数组和单 EP 的历史接口。provider 可能刻意不创建 DUT 一侧的 agent，
    // 因而 null EP monitor 是合法的；Root driver/sequencer 则必须存在。
    protected function pcie_tl_base_monitor ep_monitor_at(int	slot);
        if (pcie_env.ep_agents.size() != 0) begin
            if (slot >= 0 && slot < pcie_env.ep_agents.size() && pcie_env.ep_agents[slot] != null)
                return pcie_env.ep_agents[slot].monitor;
            return null;
        end
        if (slot == 0 && pcie_env.ep_agent != null) return pcie_env.ep_agent.monitor;
        return null;
    endfunction

    // native SV_IF 每个方向显式注入接口；provider 自己管理 HDL/SVT 接口。
    // 该参考实现不替平台实例化 Serial/SVT VIP，也不重连 provider-owned adapter。
    protected function void bind_native_vifs();
        if (pcie_env.backend_provider_active || pcie_env.cfg.if_mode != SV_IF_MODE) return;
        foreach (pcie_env.rc_adapters[r]) begin
            if (pcie_env.rc_adapters[r] == null) continue;
            if (!cfg.rc_vifs.exists(r) || cfg.rc_vifs[r] == null)
                `uvm_fatal("PROJECT_DEVICE", $sformatf("missing native RC VIF for Root%0d", r))
            pcie_env.rc_adapters[r].vif = cfg.rc_vifs[r];
        end
        foreach (cfg.pcie_hw_cfg.topology.nodes[n]) begin
            string	node_id;
            int		slot;

            if (cfg.pcie_hw_cfg.topology.nodes[n].kind != PCIE_TOPO_NODE_EP) continue;
            node_id = cfg.pcie_hw_cfg.topology.nodes[n].node_id;
            slot = find_ep_slot(node_id);
            if (slot < 0) continue;
            if (!cfg.ep_vifs.exists(node_id) || cfg.ep_vifs[node_id] == null)
                `uvm_fatal("PROJECT_DEVICE", {"missing native EP VIF for ", node_id})
            if (pcie_env.ep_adapters.size() != 0) begin
                if (slot >= pcie_env.ep_adapters.size() || pcie_env.ep_adapters[slot] == null)
                    `uvm_fatal("PROJECT_DEVICE", "physical EP has no native adapter")
                pcie_env.ep_adapters[slot].vif = cfg.ep_vifs[node_id];
            end else begin
                if (slot != 0 || pcie_env.ep_adapter == null)
                    `uvm_fatal("PROJECT_DEVICE", "single EP has no native adapter")
                pcie_env.ep_adapter.vif = cfg.ep_vifs[node_id];
            end
        end
    endfunction

    // 全项目统一分配协议监测接口，并在任何 VIO bind 前检查跨 Host 句柄复用。
    // cfg 已登记的身份优先；否则使用显式池或兼容 top 的全局 slot 池。
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
                            `uvm_fatal("PROJECT_DEVICE", "protocol VIF pool is too small")
                        vif = cfg.protocol_vifs[slot];
                    end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                            null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif))
                        `uvm_fatal("PROJECT_DEVICE", "global protocol VIF slot is missing")
                    if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why))
                        `uvm_fatal("PROJECT_DEVICE", why)
                end
                foreach (used[j]) begin
                    if (used[j] == vif)
                        `uvm_fatal("PROJECT_DEVICE", "protocol VIF reused by distinct Functions/Hosts")
                end
                used.push_back(vif);
                slot++;
            end
        end
    endfunction

    // 用 Function 的完整身份找到 domain→Root 与 Function→物理 EP，统一连接 VIO。
    // child connect 已完成，故 sequencer/driver/monitor 均可使用；失败立即停止。
    virtual function void connect_phase(uvm_phase	phase);
        string	why;

        super.connect_phase(phase);
        bind_native_vifs();
        bind_protocol_vifs();
        if (reg_backend != null) begin
            reg_backend.bind_virtual_sequencer(pcie_env.v_seqr);
            foreach (cfg.root_bindings.bindings[i]) begin
                pcie_dpu_root_binding	b;

                b = cfg.root_bindings.bindings[i];
                reg_backend.bind_domain_root(b.host_id, b.segment_id, b.root_index);
            end
        end
        foreach (vio_envs[h]) begin
            virtio_pcie_function_endpoint	endpoints[$];

            foreach (vio_envs[h].function_instances[i]) begin
                virtio_function_instance	f;
                virtio_pcie_function_endpoint	endpoint;
                int unsigned			root;
                int				ep_slot;
                string				node_id;
                string				link_id;
                bit				has_fn_num;
                int unsigned			fn_num;

                f = vio_envs[h].function_instances[i];
                if (!cfg.root_bindings.find_root(f.pcie_id.domain.host_id,
                        f.pcie_id.domain.segment_id, root))
                    `uvm_fatal("PROJECT_DEVICE", "VIO domain has no Root binding")
                if (!cfg.attachments.find_by_function(f.service_key.function_key,
                        node_id, link_id, has_fn_num, fn_num))
                    `uvm_fatal("PROJECT_DEVICE", "VIO Function has no physical attachment")
                ep_slot = find_ep_slot(node_id);
                if (ep_slot < 0 || pcie_env.configured_ep_root_index(ep_slot, -1) != int'(root))
                    `uvm_fatal("PROJECT_DEVICE", "VIO physical EP/Root mapping disagrees")
                if (root >= pcie_env.rc_agents.size() || pcie_env.rc_agents[root] == null)
                    `uvm_fatal("PROJECT_DEVICE", "VIO requires a VIP-owned RC for its Root")
                endpoint = virtio_pcie_function_endpoint::type_id::create(
                    $sformatf("endpoint_h%0d_f%0d", h, i));
                endpoint.configure(f.pcie_id, pcie_env.rc_agents[root].sequencer,
                    pcie_env.rc_agents[root].rc_driver, cfg.completion_adapter,
                    pcie_env.rc_agents[root].monitor, ep_monitor_at(ep_slot));
                endpoints.push_back(endpoint);
            end
            if (!vio_envs[h].bind_pcie_endpoints(endpoints))
                `uvm_fatal("PROJECT_DEVICE", "VIO endpoint binding failed")
        end
    endfunction

    // 平台确认 reset/link/DMA 服务就绪后调用一次；计划已包含 bootstrap，不能
    // 先单独 apply_bootstrap 再重复执行。失败报告保留 DPU 状态与具体操作原因。
    task configure_device();
        dpu_reg_plan		plan;
        dpu_execution_report	report;
        string			why;

        if (!build_vio_register_plan(plan, why)) `uvm_fatal("PROJECT_DEVICE", why)
        apply_vio_register_plan(plan, report);
        if (report == null) `uvm_fatal("PROJECT_DEVICE", "DPU returned no execution report")
        if (report.status() != DPU_CFG_STATUS_SUCCEEDED)
            `uvm_fatal("PROJECT_DEVICE", report.reason())
    endtask

    // 所有 Host 先登记完整 service 身份，再统一注册命令；空 Host 合法，全局空拒绝。
    // 每个仿真只调用一次；TX 提交与业务完成的区别由平台 finish/check 负责收口。
    function void register_aip_commands();
        int unsigned	active_hosts;
        string		why;

        active_hosts = 0;
        foreach (vio_envs[h]) begin
            if (vio_envs[h].function_instances.size() == 0) continue;
            if (!virtio_aip_registry::bind_env(vio_envs[h], why))
                `uvm_fatal("PROJECT_DEVICE", why)
            active_hosts++;
        end
        if (active_hosts == 0) `uvm_fatal("PROJECT_DEVICE", "no VIO service available for AIP")
        if (!virtio_aip_registry::register_commands(why))
            `uvm_fatal("PROJECT_DEVICE", why)
    endfunction
endclass
```

## 项目 env 与公共资源：project_env.sv

[源文件](../integration/project/project_env.sv)

```systemverilog
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
```

## base test 的构建和运行顺序：project_base_test.sv

[源文件](../integration/project/project_base_test.sv)

```systemverilog
// integration/project：可继承的 AIP base_test，由 project_env_pkg 最后包含。
// 依赖本目录 env/cfg 与 AIP bridge；基类拥有 objection 和统一配置/命令入口。
// 不知道平台的 reset/link/DMA/业务完成信号，故将这三处保留为强制实现的接口，
// 防止空 hook 假装平台已准备好。派生 test 用 factory 注册，本虚类不注册 factory。
virtual class project_base_test extends uvm_test;
    project_env_cfg	cfg;
    project_env		env;

    // 构造 test 壳；构建参数由 cfg.load_params 负责，无需在 new 重复逐项赋值。
    function new(string	name, uvm_component	parent);
        super.new(name, parent);
    endfunction

    // 在 cfg 加载后、env 构建前注入平台 pool/IOMMU/VIF/backend 等句柄。
    // cfg 若已由 top 完整注入，派生类可显式提供空实现；此 hook 不重新 load_params。
    pure virtual function void bind_platform_handles();

    // 等待真实复位/链路就绪，准备 requester-aware DMA 和设备模型/网络检查器。
    // 必须有平台自己的超时及错误处理；返回即授权后续 DPU 寄存器计划访问设备。
    pure virtual task prepare_platform();

    // Tcl 退出后等待业务完成并检查数据、DMA、PCIe/协议监测与资源回收。
    // vio_tx 返回只表示提交，不能仅凭 AIP run_loop 退出认定业务测试通过。
    pure virtual task finish_platform();

    // 支持 top 提供预建 cfg 或使用 factory；单一参数入口后只下发同一 cfg 句柄。
    virtual function void build_phase(uvm_phase	phase);
        super.build_phase(phase);
        if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg))
            cfg = project_env_cfg::type_id::create("cfg");
        if (cfg == null) `uvm_fatal("PROJECT_TEST", "project_cfg is null")
        cfg.load_params();
        bind_platform_handles();
        uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
        env = project_env::type_id::create("env", this);
    endfunction

    // 唯一运行顺序：平台就绪→DPU 配置→注册 seq 命令→Tcl→业务收尾。
    // 运行期 Tcl 只能改变下一条命令采样的参数，不能改写已冻结拓扑。
    virtual task run_phase(uvm_phase	phase);
        phase.raise_objection(this);
        prepare_platform();
        env.device_env.configure_device();
        env.device_env.register_aip_commands();
        aip_tcl_bridge::run_loop();
        finish_platform();
        phase.drop_objection(this);
    endtask
endclass
```

## package 编译入口：project_env_pkg.sv

[源文件](../integration/project/project_env_pkg.sv)

```systemverilog
// integration/project：项目参考组装的唯一 package 编译入口。
// 顺序：AIP→DPU/Host memory/PCIe/VIO→PCIe-DPU/AIP glue→本包。
// include 的普通 .sv 不可另行编译；本包只定义类型，不创建组件或取得外部资源。
package project_env_pkg;
    timeunit 1ns;
    timeprecision 1ps;

    import uvm_pkg::*;
    import aip_core_pkg::*;
    import host_mem_pkg::*;
    import dpu_resource_pkg::*;
    import pcie_topology_pkg::*;
    import pcie_tl_pkg::*;
    import pcie_dpu_integration_pkg::*;
    import virtio_net_pkg::*;
    import virtio_aip_pkg::*;
    `include "uvm_macros.svh"

    `include "project_env_cfg.sv"
    `include "project_device_env.sv"
    `include "project_env.sv"
    `include "project_base_test.sv"
endpackage
```

## 完整编译 filelist

[project_integration.f](../filelists/project_integration.f)

```text
// 完整参考集成入口。从 virtio_work 根运行；五个依赖根由调用方提供。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+$PCIE_WORK_ROOT/pcie_dpu_integration/src
$PCIE_WORK_ROOT/pcie_dpu_integration/src/pcie_dpu_integration_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
```

## 配套的 VIO 原类接口

本次同时在原 [virtio_net_env_config.sv](../virtio_net_vip/src/env/virtio_net_env_config.sv)
增加 `iommu_binding` 与 `bind_protocol_event_vif/get_protocol_event_vif/has_protocol_event_bindings`。
原 [virtio_net_env.sv](../virtio_net_vip/src/env/virtio_net_env.sv) 消费这两个配置接口：
外部 IOMMU 只校验策略、不重配；显式协议 VIF 按完整 Function 身份查询。
复制本目录到使用旧版 VIO 的工程时，需要同步这两个原类改动。

可运行的结构回归见 [smoke test](../integration/project/tests/project_env_smoke_test.sv)
和 [HDL top](../integration/project/tests/project_env_tb.sv)，不包含 DUT 数据面。
