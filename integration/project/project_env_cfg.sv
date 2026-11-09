// integration/project：用户 env_cfg 的组合参考，不要求用户继承本类。
// DPU 拥有资源与公共表，VIO 拥有行为/ring，PCIe 拥有传输参数；只在这里组装三个 cfg。
// 平台 VIF/pool 均借用，创建和连接组件由 project_env 完成。
class project_env_cfg extends uvm_object;
	`uvm_object_utils(project_env_cfg)
	// 三类子配置由本对象创建；每个 Host 的 VIO 配置在加载参数后独立生成。
	dpu_env_cfg				dpu_cfg;
	virtio_net_env_config	vio_cfg;
	virtio_net_env_config	vio_cfg_by_host[int unsigned];
	pcie_tl_env_config		pcie_cfg;

	// 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
	int unsigned	tl_slot_by_host[int unsigned];

	// 借用平台已有 pool；分配模式和粒度只作用于需要新建的 Host manager。
	host_mem_pool	host_mem_pool_binding;
	alloc_mode_e	host_mem_mode = MODE_BUDDY;
	int unsigned	host_mem_granule = DEFAULT_MIN_GRANULE;

	// 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
	// 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
	// Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
	intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
	intel_pcie_vif_t			intel_rc_vifs[int unsigned];

	virtual virtio_protocol_event_if protocol_vifs[$];

	protected bit	params_loaded;

	// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
	// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
	extern function new(string	name = "project_env_cfg");

	// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
	// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
	extern function bit validate_tl_mapping(output string	why);

	// 先构造 DPU 输入，再缓存各 Host VIO 需求并提交 placement，最后配置传输参数。
	// 幂等入口不重复采样随机值；实际资源解析仍由 dpu_device_env 的 build 执行一次。
	extern virtual function void load_params();

	// 只构造纯参数候选；保留三类 cfg 句柄的原有职责，不分配 BAR、ring 或发送配置。
	extern function bit make_runtime_candidate(
		output project_env_cfg	candidate,
		output string			why
	);

	// 全部预检后原地提交，不更换 DPU/Host cfg 或共享资源句柄。
	extern function void apply_runtime_candidate(input project_env_cfg	candidate);
endclass

// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
function project_env_cfg::new(string	name);
	super.new(name);

	dpu_cfg  = dpu_env_cfg::type_id::create("dpu_cfg");
	vio_cfg  = virtio_net_env_config::type_id::create("vio_cfg");
	pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");

	vio_cfg.execution_mode         = VIRTIO_EXEC_REAL_DUT;
	vio_cfg.external_configuration = 1;
endfunction

// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
function bit project_env_cfg::validate_tl_mapping(output string	why);
	bit				used_slots[int unsigned];
	int unsigned	count;

	why   = "";
	count = dpu_cfg.device_cfg.hosts.size();

	if (count == 0 || tl_slot_by_host.num() != count || vio_cfg_by_host.num() != count) begin
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

		if (!tl_slot_by_host.exists(host.host_id) || !vio_cfg_by_host.exists(host.host_id) || vio_cfg_by_host[host.host_id] == null) begin
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

// 先构造 DPU 输入，再缓存各 Host VIO 需求并提交 placement，最后配置传输参数。
// 幂等入口不重复采样随机值；实际资源解析仍由 dpu_device_env 的 build 执行一次。
function void project_env_cfg::load_params();
	string	why;

	if (params_loaded) return;
	dpu_cfg.load_params();
`ifdef AIP_CMDLINE_SV
	begin
		alloc_mode_e			mem_mode;
		host_mem_alloc_policy_e	mem_policy;
		longint unsigned		mem_granule;

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
	vio_cfg.external_configuration = 1;
	vio_cfg.load_params("vio");

	if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT) begin
		`uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		int unsigned			h;
		virtio_net_env_config	host_vio;

		h        = dpu_cfg.device_cfg.hosts[i].host_id;
		host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
		host_vio.copy_defaults_from(vio_cfg);

		host_vio.host_id           = h;
		host_vio.host_scope_enable = 1;
		host_vio.host_scope_id     = h;

		host_vio.load_params($sformatf("vio.h%0d", h));
		host_vio.enable_service_params("vio");

		if (host_vio.execution_mode != vio_cfg.execution_mode) begin
			`uvm_fatal("PROJECT_CFG",
					   "one PCIe environment requires consistent VIO execution modes")
		end

		vio_cfg_by_host[h] = host_vio;

		if (!host_vio.bind_dpu_services(dpu_cfg, why)) `uvm_fatal("PROJECT_CFG", why)
	end
	if (tl_slot_by_host.num() == 0) begin
		for (int	unsigned	h = 0; h < dpu_cfg.hosts; h++) begin
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

	params_loaded = 1;
endfunction

// 只构造纯参数候选；保留三类 cfg 句柄的原有职责，不分配 BAR、ring 或发送配置。
function bit project_env_cfg::make_runtime_candidate(
	output project_env_cfg	candidate,
	output string			why
);
	dpu_cfg_scope	msix_scope;

	candidate = new("runtime_candidate");
	if (!dpu_cfg.make_runtime_candidate(candidate.dpu_cfg, why)) return 0;
	if (!vio_cfg.make_runtime_candidate(null, "vio", candidate.vio_cfg, why)) return 0;
	foreach (vio_cfg_by_host[h]) begin
		if (!vio_cfg_by_host[h].make_runtime_candidate(
				candidate.vio_cfg, $sformatf("vio.h%0d", h), candidate.vio_cfg_by_host[h], why
			))
			return 0;
	end
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		dpu_service_key_t	key;
		int unsigned		h;

		key = '{
			function_key: dpu_cfg.device_cfg.functions[f].key,
			service_kind: DPU_SERVICE_VIO_NET,
			service_instance_id: 0
		};
		h = key.function_key.host_id;
		if (!vio_cfg_by_host[h].validate_runtime_service(candidate.vio_cfg_by_host[h], key, why))
			return 0;
	end
	foreach (candidate.vio_cfg_by_host[h])
	if (!candidate.vio_cfg_by_host[h].bind_dpu_services(candidate.dpu_cfg, why, 0)) return 0;
	if (!candidate.dpu_cfg.select_msix_scope(msix_scope, why)) return 0;
	why = "";
	return 1;
endfunction

// 全部预检后原地提交，不更换 DPU/Host cfg 或共享资源句柄。
function void project_env_cfg::apply_runtime_candidate(input project_env_cfg	candidate);
	dpu_cfg.apply_runtime_candidate(candidate.dpu_cfg);
	vio_cfg.apply_runtime_candidate(candidate.vio_cfg);
	foreach (vio_cfg_by_host[h])
	vio_cfg_by_host[h].apply_runtime_candidate(candidate.vio_cfg_by_host[h]);
endfunction
