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
