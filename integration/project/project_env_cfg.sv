// integration/project：项目级配置组合与参数构建示例。
// 依赖 DPU、PCIe TL、Intel adapter、VIO 与 AIP；由 project_env_pkg 按顺序包含。
// 类内集中声明配置成员和 extern 方法；全部实现在本文件类外展开，无额外编译入口。
// cfg 拥有创建的配置对象，借用平台注入的 pool、IOMMU 与 VIF。
// load_params 只生成输入，不解析快照、不创建组件、不访问 DUT；每个对象只加载一次。
// 每 Host 一个 segment 0 和一组 TL 接口；PF/VF 共用接口，不配置 SVT 或链路训练。
// 固定使用真实 EP 应用 DUT 的 Intel HARD_IP 接口；每 Host 仅创建一个 RC。
class project_env_cfg extends uvm_object;
	`uvm_object_utils(project_env_cfg)

	// 平台布局/身份唯一输入；缺失项仅在对应类别导出/执行时失败，绝不补造硬件地址。
	string	reg_target = "pf0.bar0";
	bit	print_bar_map = 1;
	project_table_layout_t	table_layouts[project_table_kind_e];
	project_function_policy_t	function_policies[string];
	project_vio_policy_t	vio_policies[string];
	project_msix_message_t	messages[$];
	project_bar_mapping_cfg_t	bar_groups[$];
	bit	bar_mapping_per_lease = 0;
	project_bar_group_policy_t	bar_group_policies[$];
	project_control_cfg_t	platform_controls[$];

	project_msix_policy_t	msix_policies[string];
	project_msix_message_t	message_templates[string][int unsigned];

	// 参数只在 load_params 一次采样；消息模板无需 VIO service，公共向量在发布时关联。
	extern protected function void load_platform_params();
	extern function bit materialize_messages(input dpu_resource_snapshot resources, output string why);
	extern protected function bit add_message(input dpu_function_key_t owner, input int unsigned local_vector,
		input int unsigned global_vector, output string why);

	// 图片未提供完整 PFVF 公式；平台一次实现纯关系校验，默认缺规则只阻止依赖类别。
	extern virtual function bit validate_pfvf_relationship(input project_pfvf_relationship_t family, output string why);

	// 按完整 service 最终需求创建唯一固定 placement request，disabled 不删除 Function。
	extern protected function void add_service_request(input dpu_function_key_t key);

	// 三类子配置由本对象创建；每个 Host 的 VIO 配置在加载参数后独立生成。
	dpu_device_env_config	dpu_cfg;
	virtio_net_env_config	vio_cfg;
	virtio_net_env_config	vio_cfg_by_host[int unsigned];
	pcie_tl_env_config		pcie_cfg;

	// 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
	int unsigned	tl_slot_by_host[int unsigned];

	// 借用平台已有 pool；分配模式和粒度只作用于需要新建的 Host manager。
	host_mem_pool	host_mem_pool_binding;
	alloc_mode_e	host_mem_mode    = MODE_BUDDY;
	int unsigned	host_mem_granule = DEFAULT_MIN_GRANULE;

	// 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
	// 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
	// Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
	intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
	intel_pcie_vif_t		intel_rc_vifs[int unsigned];

	virtual virtio_protocol_event_if	protocol_vifs[$];

	// 这是配置生成规模，不是另一套已解析拓扑；最终身份以 DPU snapshot 为准。
	longint unsigned	hosts         = 1;
	longint unsigned	pfs_per_host  = 1;
	longint unsigned	vfs_per_pf    = 0;
	protected bit	params_loaded = 0;

	// 创建默认子 cfg，不读取参数；默认构造名字只在此声明，类外实现沿用该接口。
	extern function	new(
		string	name = "project_env_cfg"
	);

	// 仅首次调用加载参数并生成 Host/PF/VF 输入，拒绝覆盖已有拓扑或越过硬件容量。
	extern virtual function void	load_params();

	// 只读校验 Host→slot 的完整一一映射，失败通过 why 返回原因，不修补配置。
	extern function bit	validate_tl_mapping(
		output string	why
	);

	// 创建未解析的 Host 地址模板；调用者后续填写身份并加载 Host 级参数。
	extern protected function dpu_host_cfg	make_host_template();

	// 按完整身份和 DUT BAR 能力生成一个 Function；能力缺失时立即报告 fatal。
	extern protected function dpu_function_cfg	make_function(
		int unsigned		host_id,
		int unsigned		pf_id,
		dpu_function_kind_e	kind,
		int unsigned		vf_id
	);
endclass


// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
function	project_env_cfg::new(
	string	name
);
	super.new(name);

	dpu_cfg  = dpu_device_env_config::type_id::create("dpu_cfg");
	vio_cfg  = virtio_net_env_config::type_id::create("vio_cfg");
	pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");

	vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
	vio_cfg.external_configuration = 1;

	dpu_cfg.device_cfg.af_request.mode      = DPU_AF_SELECTED;
	dpu_cfg.device_cfg.af_request.requester = '{
		host_id: 0,
		pf_id:   0,
		kind:    DPU_FUNCTION_PF,
		vf_id:   0
	};
endfunction


// 构造全局 Host 模板；GPA 和 MMIO 分开，BDF 范围覆盖默认 PF/VF 规模。
// 每 Host 的 identity 和参数覆盖由 load_params 设置，不在这里解析实际地址。
function dpu_host_cfg	project_env_cfg::make_host_template();
	dpu_host_cfg	host;
	dpu_pcie_domain_cfg	domain;
	dpu_mmio_window_cfg	window;
	dpu_bdf_range_t	bdf_range;

	host = dpu_host_cfg::type_id::create("host_template");

	host.has_gpa_aperture = 1;
	host.gpa_base         = 64'h0000_1000_0000_0000;
	host.gpa_limit        = host.gpa_base + 64'h1000_0000;

	domain     = dpu_pcie_domain_cfg::type_id::create("domain_template");
	domain.key = '{
		host_id:    0,
		segment_id: 0
	};

	bdf_range = '{
		first_bdf: 16'h0010,
		last_bdf:  16'h0fff
	};

	domain.bdf_ranges.push_back(bdf_range);

	window = dpu_mmio_window_cfg::type_id::create("mmio_template");

	window.base          = 64'h0000_0020_0000_0000;
	window.limit         = window.base + 64'h0000_0001_0000_0000;
	window.allowed_roles = '{
		DPU_BAR_DEVICE_MEMORY,
		DPU_BAR_MAILBOX,
		DPU_BAR_MSIX
	};

	domain.mmio_windows.push_back(window);
	domain.bar_placement_policy = DPU_BAR_PLACEMENT_RANDOM;

	host.pcie_domains.push_back(domain);

	return host;
endfunction


// 按 Host/PF/VF 身份创建 Function，并从 DUT caps 取得 BAR 规格。
// 全部 BAR/BDF 均由 resolver 最终放置；未知规格立即 fatal，不能制造设备能力。
function dpu_function_cfg	project_env_cfg::make_function(
	int unsigned	host_id,
	int unsigned	pf_id,
	dpu_function_kind_e	kind,
	int unsigned	vf_id
);
	dpu_function_cfg	f;
	dpu_bar_role_e	roles[3] = '{
		DPU_BAR_DEVICE_MEMORY,
		DPU_BAR_MAILBOX,
		DPU_BAR_MSIX
	};
	string	why;

	f = dpu_function_cfg::type_id::create(
		$sformatf(
			"fn_h%0d_pf%0d_%0d_vf%0d",
			host_id,
			pf_id,
			kind,
			vf_id
		)
	);

	f.key = '{
		host_id: host_id,
		pf_id:   pf_id,
		kind:    kind,
		vf_id:   vf_id
	};

	f.domain_key = '{
		host_id:    host_id,
		segment_id: 0
	};

	f.bdf_mode = DPU_ALLOC_AUTO;
	f.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);

	foreach (roles[i]) begin
		dpu_bar_profile_t	profile;
		dpu_bar_request		bar;

		if (!dpu_cfg.device_cfg.dut_caps.lookup_bar_profile(
			kind,
			roles[i],
			profile,
			why
		)) begin
			`uvm_fatal("PROJECT_CFG", why)
		end

		bar = dpu_bar_request::type_id::create($sformatf("bar_%0d", i));

		bar.role        = profile.role;
		bar.even_bar_id = profile.even_bar_id;
		bar.size        = profile.size;
		bar.alignment   = profile.alignment;
		bar.placement   = DPU_ALLOC_AUTO;

		f.bars.push_back(bar);
	end

	return f;
endfunction


// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
function bit	project_env_cfg::validate_tl_mapping(
	output string	why
);
	bit			used_slots[int unsigned];
	int unsigned	count;

	why   = "";
	count = dpu_cfg.device_cfg.hosts.size();

	if (
		count == 0 ||
		tl_slot_by_host.num() != count ||
		vio_cfg_by_host.num() != count
	) begin
		why = "each DPU Host needs exactly one VIO config and TL slot";
		return 0;
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg	host;
		int unsigned	slot;

		host = dpu_cfg.device_cfg.hosts[i];

		if (host == null) begin
			why = "DPU Host config is null";
			return 0;
		end

		if (
			!tl_slot_by_host.exists(host.host_id) ||
			!vio_cfg_by_host.exists(host.host_id) ||
			vio_cfg_by_host[host.host_id] == null
		) begin
			why = $sformatf("Host%0d has no VIO config or TL slot", host.host_id);
			return 0;
		end

		slot = tl_slot_by_host[host.host_id];

		if (slot >= count || used_slots.exists(slot)) begin
			why = "TL slots must be unique and cover 0..Host_count-1";
			return 0;
		end

		if (host.pcie_domains.size() != 1) begin
			why = "Intel project requires one PCIe domain per Host";
			return 0;
		end

		if (host.pcie_domains[0] == null) begin
			why = "Host PCIe domain is null";
			return 0;
		end

		if (
			host.pcie_domains[0].key.host_id != host.host_id ||
			host.pcie_domains[0].key.segment_id != 0
		) begin
			why = "Intel project requires Host-owned segment 0";
			return 0;
		end

		used_slots[slot] = 1;
	end

	return 1;
endfunction


// 唯一参数构建入口：先采样规模/模板，再创建 Host/PF/VF/placement 和 Host 行为。
// 再调用幂等返回，不重新采样；已有输入的项目应把加载入口合入原构造点，省去生成循环。
// 默认生成器拒绝覆盖非空逻辑配置，避免重复追加 Host/PF/VF 和资源请求。
// base_test 无须逐项赋值；AIP-off 时保留默认值，但仍正常创建对象。
function void	project_env_cfg::load_params();
	dpu_dut_caps		caps;
	dpu_host_cfg		host_template;
	dpu_resource_pool_config_t	profile;

	string			why;

	if (params_loaded) begin
		return;
	end

	if (
		(dpu_cfg.device_cfg.hosts.size() != 0) ||
		(dpu_cfg.device_cfg.functions.size() != 0) ||
		(dpu_cfg.placement_cfg.vio_requests.size() != 0) ||
		(dpu_cfg.placement_cfg.profiles.size() != 0)
	) begin
		`uvm_fatal(
			"PROJECT_CFG",
			"default authoring cannot overwrite an existing DPU topology"
		)
	end

	dpu_cfg.device_cfg.load_params("dpu");
	caps = dpu_cfg.device_cfg.dut_caps;

	if (!caps.validate(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

`ifdef AIP_CMDLINE_SV
	`DPU_AIP_UINT("dpu", longint unsigned, hosts, this.hosts)
	`DPU_AIP_UINT("dpu", longint unsigned, pfs_per_host, this.pfs_per_host)
	`DPU_AIP_UINT("dpu", longint unsigned, vfs_per_pf, this.vfs_per_pf)

	begin
		alloc_mode_e		mem_mode;
		host_mem_alloc_policy_e	mem_policy;
		longint unsigned	mem_granule;

		`aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
		`aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
		`DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)

		if (
			(mem_granule == 0) ||
			(mem_granule > 64) ||
			((mem_granule & (mem_granule - 1)) != 0)
		) begin
			`uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
		end

		host_mem_mode           = mem_mode;
		host_mem_granule        = int'(mem_granule);
		vio_cfg.host_mem_policy = mem_policy;
	end
`endif

	if (
		(hosts == 0) ||
		(hosts > caps.max_hosts) ||
		(pfs_per_host == 0) ||
		(pfs_per_host > caps.max_pfs_per_host) ||
		(pfs_per_host > 4) ||
		(vfs_per_pf > caps.max_vfs_per_pf)
	) begin
		`uvm_fatal("PROJECT_CFG", "Host/PF/VF counts exceed DUT or VIO source-id capacity")
	end

	if ((hosts * pfs_per_host * (1 + vfs_per_pf)) > caps.max_functions) begin
		`uvm_fatal("PROJECT_CFG", "total Function count exceeds DUT capability")
	end

	vio_cfg.external_configuration = 1;
	vio_cfg.load_params("vio");
`ifdef AIP_CMDLINE_SV
	`aip_string("dpu", reg_target, this.reg_target)
	`aip_int("dpu", bit, print_bar_map, this.print_bar_map)
`endif

	if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT) begin
		`uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
	end

	host_template = make_host_template();
	host_template.load_params("dpu");

	profile.name             = "virtio.qpair";
	profile.class_id         = '0;
	profile.kind             = DPU_RESOURCE_KIND_QUEUE;
	profile.capacity         = caps.vio_global_qpair_count;
	profile.max_per_function = caps.max_vio_net_qpairs_per_device;

	dpu_cfg.placement_cfg.profiles.push_back(profile);

	for (int unsigned	h = 0; h < hosts; h++) begin
		dpu_host_cfg		host;
		virtio_net_env_config	host_vio;
		bit [64:0]		base;
		bit [64:0]		limit;

		host = dpu_host_cfg::type_id::create($sformatf("host_%0d", h));
		host.copy_from(host_template);

		host.host_id                     = h;
		host.pcie_domains[0].key.host_id = h;

		base  = {1'b0, host.gpa_base} + h * 65'h0000_0100_0000_0000;
		limit = {1'b0, host.gpa_limit} + h * 65'h0000_0100_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host GPA stride overflows")
		end

		host.gpa_base  = base[63:0];
		host.gpa_limit = limit[63:0];

		base  = {1'b0, host.pcie_domains[0].mmio_windows[0].base} + h * 65'h0000_0010_0000_0000;
		limit = {1'b0, host.pcie_domains[0].mmio_windows[0].limit} + h * 65'h0000_0010_0000_0000;

		if (base[64] || limit[64]) begin
			`uvm_fatal("PROJECT_CFG", "Host MMIO stride overflows")
		end

		host.pcie_domains[0].mmio_windows[0].base  = base[63:0];
		host.pcie_domains[0].mmio_windows[0].limit = limit[63:0];

		host.load_params($sformatf("dpu.h%0d", h));
		dpu_cfg.device_cfg.hosts.push_back(host);

		host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
		host_vio.copy_defaults_from(vio_cfg);

		host_vio.host_id           = h;
		host_vio.host_scope_enable = 1;
		host_vio.host_scope_id     = h;

		host_vio.load_params($sformatf("vio.h%0d", h));
		host_vio.enable_service_params("vio");

		if (host_vio.execution_mode != vio_cfg.execution_mode) begin
			`uvm_fatal(
				"PROJECT_CFG",
				"one PCIe environment requires consistent VIO execution modes"
			)
		end

		vio_cfg_by_host[h] = host_vio;

		for (int unsigned	pf = 0; pf < pfs_per_host; pf++) begin
			dpu_function_cfg	f;
			string		path;

			path = $sformatf("dpu.h%0d.pf%0d", h, pf);
			f    = make_function(h, pf, DPU_FUNCTION_PF, 0);

			f.load_params(path);
			dpu_cfg.device_cfg.functions.push_back(f);

			add_service_request(f.key);

			for (int unsigned	vf = 0; vf < vfs_per_pf; vf++) begin
				f = make_function(h, pf, DPU_FUNCTION_VF, vf);
				f.load_params($sformatf("%s.vf%0d", path, vf));

				dpu_cfg.device_cfg.functions.push_back(f);
				add_service_request(f.key);
			end
		end
	end

	// 精确需求已经冻结，禁止再让 placement 参数另行扩大或平均分配 service 容量。
	dpu_cfg.vio_policy.load_params("dpu");

	if (tl_slot_by_host.num() == 0) begin
		for (int unsigned	h = 0; h < hosts; h++) begin
			tl_slot_by_host[h] = h;
		end
	end

	if (!validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

	// Intel 的接口选择由下面的固定模式和 env 的 instance override 完成，
	// 无需额外选择宏。标量参数仍加载，但不能绕过真实 DUT 的方向与信用约束。
	pcie_cfg.if_mode          = SV_IF_MODE;
	pcie_cfg.rc_is_active     = UVM_ACTIVE;
	pcie_cfg.ep_auto_response = 0;
	pcie_cfg.use_unified_mem  = 1;
	pcie_cfg.mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;

	// 真实 EP 应用逻辑由 DUT 提供；Intel adapter 即使放在 passive agent 旁也会驱动
	// 引脚，因此必须关闭 EP 组件，而不是仅将 EP 标成 UVM_PASSIVE。
	pcie_cfg.rc_agent_enable = 1;
	pcie_cfg.ep_agent_enable = 0;
	pcie_cfg.num_rc          = tl_slot_by_host.num();
	pcie_cfg.num_ep          = 0;

	// 公共 FC 不门控；每端口有限 AVST credit 由 intel_cfg 独立管理。
	pcie_cfg.infinite_credit = 1;
	pcie_cfg.load_params("pcie_cfg");

	if (pcie_cfg.ep_auto_response) begin
		`uvm_fatal("PROJECT_CFG", "real EP DUT must provide its own responses")
	end

	if (!pcie_cfg.infinite_credit) begin
		`uvm_fatal("PROJECT_INTEL", "pcie_cfg.infinite_credit must be 1; Intel owns AVST credits")
	end

	load_platform_params();
	params_loaded = 1;
endfunction

// 在 DPU placement 前使用将来交给同 Host env 的同一个 cfg 缓存最终 service 需求。
function void project_env_cfg::add_service_request(input dpu_function_key_t key);
	dpu_service_key_t	service;
	vio_service_requirement_t	requirement;
	dpu_vio_placement_request	request;
	string	why;
	service.function_key = key;
	service.service_kind = DPU_SERVICE_VIO_NET;
	service.service_instance_id = 0;
	if (!vio_cfg_by_host[key.host_id].resolve_final_service_requirement(service, requirement, why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end
	if (!requirement.enabled) return;
	request = dpu_vio_placement_request::type_id::create(dpu_service_key_name(service));
	request.request_id = dpu_cfg.placement_cfg.vio_requests.size();
	request.service_instance_id = service.service_instance_id;
	request.total_qpairs = requirement.behavior.num_queue_pairs;
	request.candidate_kind = key.kind == DPU_FUNCTION_VF ? DPU_VIO_CANDIDATE_VF_ONLY : DPU_VIO_CANDIDATE_PF_ONLY;
	request.device_policy = DPU_VIO_DEVICE_FIXED;
	request.fixed_devices.push_back(key);
	dpu_cfg.placement_cfg.vio_requests.push_back(request);
endfunction

// 在原 cfg 的唯一加载点注册表目标与公共 MSI-X 模板；全局→Host→精确 Function 逐级覆盖。
function void project_env_cfg::load_platform_params();
	string	paths[$];
	string	path;
	string	name;
	string	raw;
	string	target;
	project_table_kind_e	kinds[$] = '{PROJECT_BAR,PROJECT_AF,PROJECT_PFVF,PROJECT_BDF,PROJECT_COMPLETION_BDF,PROJECT_PREFIX,
		PROJECT_MSIX_LINEAR,PROJECT_MSIX_INFO,PROJECT_MSIX_INTERVAL,PROJECT_MSIX_CONTROL,PROJECT_MSIX_TABLE,
		PROJECT_MSIX_FUNCTION,PROJECT_NOTIFY,PROJECT_Q2TC,PROJECT_N2G,PROJECT_G2P,PROJECT_SPWRR,PROJECT_TC_WEIGHT,
		PROJECT_VTX,PROJECT_VRX,PROJECT_QUEUE_AUX,PROJECT_RDMA_NOTIFY,PROJECT_RNET};
	string	labels[$] = '{"bar","af","pfvf","bdf","completion_bdf","tlp_prefix","msix_linear","msix_info",
		"msix_interval","msix_control","msix_table","msix_function","vio_notify","qsch_q2tc","qsch_n2g","qsch_g2p",
		"qsch_spwrr","qsch_tc_weight","vtx","vrx","queue_aux","rdma_notify","qsch_rnet"};
`ifdef AIP_CMDLINE_SV
	foreach (kinds[k]) begin
		paths.delete();
		case (kinds[k])
			PROJECT_BAR: paths.push_back("dpu.bar_map");
			PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_CONTROL,
			PROJECT_MSIX_TABLE, PROJECT_MSIX_FUNCTION: paths.push_back("dpu.msix");
			PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_RNET:
				paths.push_back("dpu.qsch");
			default: ;
		endcase
		paths.push_back({"dpu.", labels[k]});
		case (kinds[k])
			PROJECT_VTX: paths.push_back("vio.vtx");
			PROJECT_VRX: paths.push_back("vio.vrx");
			PROJECT_NOTIFY: paths.push_back("vio.notify_table");
			default: ;
		endcase
		foreach (paths[i]) begin
			raw = aip_cmdline#(string)::get_cmdline_string("reg_target", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("reg_target", paths[i], reg_target, target);
				table_layouts[kinds[k]].reg_target = target;
			end
		end
	end
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		project_msix_policy_t	p;
		dpu_function_key_t	owner;
		owner = dpu_cfg.device_cfg.functions[f].key;
		name = dpu_function_key_name(owner);
		if (msix_policies.exists(name)) p = msix_policies[name];
		else p = '{default:0};
		paths = '{"dpu.msix", $sformatf("dpu.h%0d.msix", owner.host_id)};
		path = $sformatf("dpu.h%0d.pf%0d", owner.host_id, owner.pf_id);
		if (owner.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", owner.vf_id)};
		paths.push_back({path, ".msix"});
		foreach (paths[i]) begin
			longint unsigned	value;
			string	fields[$] = '{"table_bar","table_offset","table_size","pba_bar","pba_offset","pba_words",
				"msg_addr_base","msg_addr_stride","msg_data_base","msg_data_stride","interval_rate","interval_packets","self_mask","table_only_enable"};
			foreach (fields[j]) begin
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "MSI-X unsigned field is negative")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				if ((j inside {0,2,3,5,8,9}) && value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "MSI-X field exceeds32 bits")
				case (j)
					0: p.table_bar = value;
					1: begin p.table_offset = value; p.table_present = 1; end
					2: p.table_size = value;
					3: p.pba_bar = value;
					4: begin p.pba_offset = value; p.pba_present = 1; end
					5: p.pba_words = value;
					6: begin p.address_base = value; p.address_present = 1; end
					7: p.address_stride = value;
					8: begin p.data_base = value; p.data_present = 1; end
					9: p.data_stride = value;
					10: begin
						if (value > 65535) `uvm_fatal("PROJECT_CFG", "MSI-X interval rate exceeds16 bits")
						p.interval_entry.intrl_rate = value; p.interval_present = 1;
					end
					11: begin
						if (value > 65535) `uvm_fatal("PROJECT_CFG", "MSI-X interval packet threshold exceeds16 bits")
						p.interval_entry.intrl_pnum = value; p.interval_present = 1;
					end
					12: begin
						if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X self_mask must be boolean")
						p.self_mask = value; p.self_mask_present = 1;
					end
					13: begin
						if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X table_only_enable must be boolean")
						p.table_only_enable = value;
					end
					default: ;
				endcase
			end
		end
		msix_policies[name] = p;
		for (int unsigned v = 0; v < 64; v++) begin
			project_msix_message_t	m;
			bit	address_valid;
			bit	data_valid;
			bit [64:0]	address;
			bit [64:0]	data;
			m.owner = owner;
			m.local_vector = v;
			m.global_vector = 0;
			m.masked = 0;
			address = {1'b0,p.address_base} + 65'(v)*p.address_stride;
			data = 65'(p.data_base) + 65'(v)*p.data_stride;
			address_valid = p.address_present;
			data_valid = p.data_present;
			m.address = address[63:0];
			m.data = data[31:0];
			foreach (paths[i]) begin
				longint unsigned	value;
				string	vector_path;
				string	fields[$] = '{"msg_addr","msg_data","masked"};
				vector_path = {paths[i],$sformatf(".v%0d", v)};
				foreach (fields[j]) begin
					raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], vector_path);
					if (raw == "") continue;
					if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "negative MSI-X vector value")
					aip_cmdline#(longint unsigned)::get_single_value(fields[j], vector_path, 0, value);
					case (j)
						0: begin m.address = value; address_valid = 1; address = value; end
						1: begin
							if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "MSI-X data exceeds32 bits")
							m.data = value; data_valid = 1; data = value;
						end
						2: begin
							if (value > 1) `uvm_fatal("PROJECT_CFG", "MSI-X masked must be0/1")
							m.masked = value;
						end
					endcase
				end
			end
			if ((address_valid && address[64]) || (data_valid && data > 32'hffffffff))
				`uvm_fatal("PROJECT_CFG", "MSI-X template overflow")
			if (address_valid && data_valid) message_templates[name][v] = m;
		end
	end
	// 平台表策略沿同一全局→Host→精确 service 路径加载；资源几何仍由核心冻结合同拥有。
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		project_vio_policy_t q;
		dpu_service_key_t service;
		bit provided;
		string fields[$] = '{"vtx.dma_info","vtx.tail_buf_id_dis","vtx.redraw_en","vtx.high_speed_mode","vtx.seg_en","vtx.interl_seg_en","vrx.dsc_pre_max_num","vrx.dsc_pre_read_threshold","vrx.dsc_dma_num","vrx.dsc_mode","vrx.payload_dsc_len","vrx.head_dsc_len","qsch.net_base","qsch.net_stride","qsch.group_id","qsch.cos","qsch.eth_ports","qsch.ets","qsch.distinguish_business","qsch.ets_priority","fpga","prefetch_start","prefetch_slots","notify_net_pair5","notify_table_bar","notify_table_offset"};
		service.function_key = dpu_cfg.device_cfg.functions[f].key;
		service.service_kind = DPU_SERVICE_VIO_NET;
		service.service_instance_id = 0;
		name = dpu_service_key_name(service);
		provided = vio_policies.exists(name);
		if (provided) q = vio_policies[name];
		else q = '{service_key:service, prefetch_ram:"", default:0};
		paths = '{"dpu", "vio", $sformatf("vio.h%0d", service.function_key.host_id)};
		path = $sformatf("vio.h%0d.pf%0d", service.function_key.host_id, service.function_key.pf_id);
		if (service.function_key.kind == DPU_FUNCTION_VF) path = {path, $sformatf(".vf%0d", service.function_key.vf_id)};
		paths.push_back({path, ".i0"});
		foreach (paths[i]) begin
			raw = (paths[i] == "dpu") ? "" : aip_cmdline#(string)::get_cmdline_string("prefetch_ram", paths[i]);
			if (raw != "") begin
				aip_cmdline#(string)::get_single_value("prefetch_ram", paths[i], "", q.prefetch_ram);
				provided = 1;
			end
			foreach (fields[j]) begin
				longint unsigned value;
				// dpu.qsch 提供全局调度策略，VIO 路径只覆盖相同字段。
				if (paths[i] == "dpu" && (j < 12 || j > 19)) continue;
				raw = aip_cmdline#(longint unsigned)::get_cmdline_string(fields[j], paths[i]);
				if (raw == "") continue;
				if (aip_str::str_find(raw, "-") >= 0) `uvm_fatal("PROJECT_CFG", "negative platform queue policy")
				aip_cmdline#(longint unsigned)::get_single_value(fields[j], paths[i], 0, value);
				provided = 1;
				case (j)
					0: begin
						if (value > 4'hf) `uvm_fatal("PROJECT_CFG", "vtx.dma_info exceeds declared width")
						q.vtx.dma_info = value;
					end
					1: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.tail_buf_id_dis exceeds declared width")
						q.vtx.tail_buf_id_dis = value;
					end
					2: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.redraw_en exceeds declared width")
						q.vtx.redraw_en = value;
					end
					3: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.high_speed_mode exceeds declared width")
						q.vtx.high_speed_mode = value;
					end
					4: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.seg_en exceeds declared width")
						q.vtx.seg_en = value;
					end
					5: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "vtx.interl_seg_en exceeds declared width")
						q.vtx.interl_seg_en = value;
					end
					6: begin
						if (value > 3'h7) `uvm_fatal("PROJECT_CFG", "vrx.dsc_pre_max_num exceeds declared width")
						q.vrx.dsc_pre_max_num = value;
					end
					7: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_pre_read_threshold exceeds declared width")
						q.vrx.dsc_pre_read_threshold = value;
					end
					8: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_dma_num exceeds declared width")
						q.vrx.dsc_dma_num = value;
					end
					9: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.dsc_mode exceeds declared width")
						q.vrx.dsc_mode = value;
					end
					10: begin
						if (value > 3'h7) `uvm_fatal("PROJECT_CFG", "vrx.payload_dsc_len exceeds declared width")
						q.vrx.payload_dsc_len = value;
					end
					11: begin
						if (value > 2'h3) `uvm_fatal("PROJECT_CFG", "vrx.head_dsc_len exceeds declared width")
						q.vrx.head_dsc_len = value;
					end
					12: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.net_base exceeds declared width")
						q.net_base = value;
					end
					13: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.net_stride exceeds declared width")
						q.net_stride = value;
					end
					14: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.group_id exceeds declared width")
						q.group_id = value;
					end
					15: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.cos exceeds declared width")
						q.cos = value;
					end
					16: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.eth_ports exceeds declared width")
						q.eth_ports = value;
					end
					17: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "qsch.ets exceeds declared width")
						q.ets = value;
					end
					18: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "qsch.distinguish_business exceeds declared width")
						q.distinguish_business = value;
					end
					19: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "qsch.ets_priority exceeds declared width")
						q.ets_priority = value;
					end
					20: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "fpga exceeds declared width")
						q.fpga = value;
					end
					21: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "prefetch_start exceeds declared width")
						q.prefetch_start = value;
					end
					22: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "prefetch_slots exceeds declared width")
						q.prefetch_slots = value;
					end
					23: begin
						if (value > 1'h1) `uvm_fatal("PROJECT_CFG", "notify_net_pair5 exceeds declared width")
						q.notify_net_pair5 = value;
					end
					24: begin
						if (value > 32'hffffffff) `uvm_fatal("PROJECT_CFG", "notify_table_bar exceeds declared width")
						q.notify_table_bar = value;
					end
					25: begin
						q.notify_table_offset = value;
						q.notify_table_base_provided = 1;
					end
					default: ;
				endcase
			end
		end
		if (provided) vio_policies[dpu_service_key_name(service)] = q;
	end
`endif
endfunction

// 公共向量来自资源快照，AF 额外资源也能在没有任何 VIO service 时产生消息项。
function bit project_env_cfg::materialize_messages(input dpu_resource_snapshot resources, output string why);
	dpu_vio_qpair_binding_t	pairs[$];
	dpu_af_extra_queue_binding_t	extras[$];
	why = "resource snapshot missing";
	if (resources == null) return 0;
	resources.list_vio_bindings(pairs);
	resources.list_af_extra_queue_bindings(extras);
	foreach (pairs[i]) if (!add_message(pairs[i].service_key.function_key, pairs[i].local_msix_vector_id,
		pairs[i].global_msix_vector_id, why)) return 0;
	foreach (extras[i]) if (!add_message(extras[i].af_function_key, extras[i].local_msix_vector_id,
		extras[i].global_msix_vector_id, why)) return 0;
	why = "";
	return 1;
endfunction

// 同一共享向量只登记一次；显式消息优先但必须与冻结向量身份一致。
function bit project_env_cfg::add_message(input dpu_function_key_t owner, input int unsigned local_vector,
	input int unsigned global_vector, output string why);
	string	name;
	project_msix_message_t	m;
	name = dpu_function_key_name(owner);
	why = "";
	foreach (messages[i]) begin
		if (dpu_same_function_key(messages[i].owner, owner) && messages[i].local_vector == local_vector) begin
			if (messages[i].global_vector != global_vector) begin why = "explicit shared MSI-X vector conflicts with DPU binding"; return 0; end
			return 1;
		end
	end
	if (!message_templates.exists(name) || !message_templates[name].exists(local_vector)) return 1;
	m = message_templates[name][local_vector];
	m.global_vector = global_vector;
	messages.push_back(m);
	return 1;
endfunction

// 平台关系不猜测；未提供规则时 PFVF/MSI-X linear 明确失败，但 BAR/BDF 可独立运行。
function bit project_env_cfg::validate_pfvf_relationship(input project_pfvf_relationship_t family, output string why);
	why = "platform PFVF relationship validator is not implemented";
	return 0;
endfunction
