// integration/project：项目组件组装；仅继承 uvm_env，不承担寄存器写表。
// 依赖同包 cfg/registry/RC driver 与 DPU、PCIe TL、Intel adapter、VIO。
// env 拥有子组件，cfg 持有同一仿真期的借用句柄、冻结资源和配置状态。
// connect 发布到同一个 cfg；配置 seq 从 PCIe sequencer 的 config_db 取得它。
// 每 Host 一个 Intel RC，PF/VF 共用；VIO 挂在 DPU 子树保证快照先发布。
class project_env extends uvm_env;
	`uvm_component_utils(project_env)

	project_env_cfg	cfg;
	dpu_device_env	dpu_env;
	pcie_tl_env	pcie_env;
	virtio_net_env	vio_envs[int unsigned];
	host_mem_pool	shared_pool;

	local bit	tx_observation_bound[int unsigned];

	// 首次成功发布后才打印，重复同快照幂等，新拓扑要求 rebuild 而不留下新旧路由混合。
	extern function void publish_dpu_configuration(
		output bit	ok,
		output string	why
	);

	// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
	extern virtual function void end_of_elaboration_phase(
		uvm_phase	phase
	);

	// 构造组件壳；配置与共享资源延迟到 build，允许 test 先注入平台对象。
	extern function	new(
		string		name,
		uvm_component	parent
	);

	// 按 UVM 顺序建立 DPU、PCIe 和 VIO；缺 cfg 或绑定冲突立即报错。
	extern virtual function void	build_phase(
		uvm_phase	phase
	);

	// 子环境构建完毕后绑定快照、协议接口和 Function endpoint；拒绝跨 Host 错配。
	extern virtual function void	connect_phase(
		uvm_phase	phase
	);

	// 每次仿真登记一次各 Host 的 VIO 服务及 Tcl 命令；空服务或重复注册会报错。
	extern function void	register_aip_commands();

	// 准备或借用各 Host 的共享内存，校验已有 manager 的身份、范围与分配策略。
	extern protected function void	prepare_host_memory();

	// 根据 Host→slot 映射设置 RC 数量和内存绑定，校验 Intel 真实 DUT 接入约束。
	extern protected function void	prepare_pcie_config();

	// 在 PCIe build 前解析各端口的 cfg/VIF，借用 wrapper 对象并拒绝缺失或复用。
	extern protected function void	prepare_intel_bindings();

	// 连接阶段核对实际 adapter、cfg/VIF 句柄及 RC-only 组件树，不再补绑接口。
	extern protected function void	check_intel_bindings();

	// 按完整 Function 身份分配协议 VIF，拒绝空接口以及跨 Host/Function 复用。
	extern protected function void	bind_protocol_vifs();
endclass


// 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
function	project_env::new(
	string		name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction


// 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
// 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
function void	project_env::prepare_host_memory();
	host_mem_pool	dpu_pool;

	shared_pool = cfg.host_mem_pool_binding;

	if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
		if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref)) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"DPU memory owner is not a host_mem_pool"
			)
		end

		if (shared_pool != null && shared_pool != dpu_pool) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"project and DPU specify distinct Host pools"
			)
		end

		shared_pool = dpu_pool;
	end

	if (shared_pool == null) begin
		shared_pool = host_mem_pool::type_id::create("shared_pool");
	end

	foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg		host;
		virtio_net_env_config	vio;
		host_mem_manager	manager;

		host = cfg.dpu_cfg.device_cfg.hosts[i];

		if (
			host == null ||
			!host.has_gpa_aperture ||
			host.gpa_limit <= host.gpa_base
		) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"each Host requires a nonempty GPA aperture"
			)
		end

		if (!cfg.vio_cfg_by_host.exists(host.host_id)) begin
			`uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
		end

		vio = cfg.vio_cfg_by_host[host.host_id];

		if (!shared_pool.has_host(host.host_id)) begin
			if (!shared_pool.create_host(
				host.host_id,
				host.gpa_base,
				host.gpa_limit - 1,
				cfg.host_mem_mode,
				cfg.host_mem_granule,
				vio.host_mem_policy
			)) begin
				`uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
			end
		end

		manager = shared_pool.get_host(host.host_id);

		if (
			!manager.is_initialized() ||
			manager.get_host_id() != host.host_id ||
			!manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) ||
			manager.get_alloc_policy() != vio.host_mem_policy
		) begin
			`uvm_fatal(
				"PROJECT_ENV",
				"existing Host memory disagrees with configured aperture/policy"
			)
		end

		if (
			vio.host_mem_binding != null ||
			(vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool)
		) begin
			`uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
		end

		vio.host_mem_pool_binding = shared_pool;
		vio.mem_base              = host.gpa_base;
		vio.mem_end               = host.gpa_limit - 1;
	end

	cfg.host_mem_pool_binding     = shared_pool;
	cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
endfunction


// 按显式 Host→slot 准备 TL cfg；只借用同一 Host manager，不复制 BDF/BAR。
// 每 Host 只保留一个 RC，EP 和配置空间/MMIO 响应来自真实 DUT。
// 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
function void	project_env::prepare_pcie_config();
	string	why;

	if (!cfg.validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end

	if (cfg.pcie_cfg.switch_enable) begin
		`uvm_fatal("PROJECT_ENV", "Intel project reference does not create a Switch")
	end

	cfg.pcie_cfg.rc_agent_enable = 1;
	cfg.pcie_cfg.num_rc          = cfg.tl_slot_by_host.num();

	if (
		cfg.vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT ||
		cfg.pcie_cfg.if_mode != SV_IF_MODE ||
		!cfg.pcie_cfg.infinite_credit ||
		cfg.pcie_cfg.rc_is_active != UVM_ACTIVE ||
		cfg.pcie_cfg.ep_auto_response ||
		!cfg.pcie_cfg.use_unified_mem
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel requires REAL_DUT, SV_IF_MODE, active RC, unified memory and infinite public FC"
		)
	end

	cfg.pcie_cfg.ep_agent_enable = 0;
	cfg.pcie_cfg.num_ep          = 0;

	if (cfg.pcie_cfg.ep_root_by_index.num() != 0) begin
		`uvm_fatal("PROJECT_INTEL", "real EP DUT must not have VIP EP-to-Root bindings")
	end

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned		slot;
		host_mem_manager	manager;

		slot    = cfg.tl_slot_by_host[h];
		manager = shared_pool.get_host(h);

		if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
			if (
				cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
				!cfg.pcie_cfg.host_id_by_root.exists(slot) ||
				cfg.pcie_cfg.host_id_by_root[slot] != h
			) begin
				`uvm_fatal(
					"PROJECT_ENV",
					"PCIe Host memory binding disagrees with DPU owner"
				)
			end
		end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end
	end

	if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num()) begin
		`uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
	end
endfunction


// 在 pcie_env::create 前解析每个端口的配置和 VIF：cfg 显式句柄与 wrapper 发布值
// 必须相同；只缺配置时可创建 HARD_IP 默认对象，缺 HDL 接口则不能自动补造。
// 复用 wrapper 对象以保留端口压力/信用设置，拒绝跨端口共享可变 cfg 或物理 VIF。
function void	project_env::prepare_intel_bindings();
	intel_pcie_adapter_config	used_cfgs[$];
	intel_pcie_vif_t		used_vifs[$];

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned			slot;
		string				path;
		intel_pcie_adapter_config	port_cfg;
		intel_pcie_adapter_config	published_cfg;
		intel_pcie_vif_t		vif;
		intel_pcie_vif_t		published_vif;

		slot          = cfg.tl_slot_by_host[h];
		path          = $sformatf("pcie_env.rc_adapter_%0d", slot);
		port_cfg      = null;
		published_cfg = null;
		vif           = null;
		published_vif = null;

		if (cfg.intel_cfg_by_slot.exists(slot)) begin
			port_cfg = cfg.intel_cfg_by_slot[slot];

			if (port_cfg == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel cfg is null")
			end
		end

		if (uvm_config_db#(intel_pcie_adapter_config)::get(
			this,
			path,
			"intel_cfg",
			published_cfg
		)) begin
			if (
				published_cfg == null ||
				(port_cfg != null && port_cfg != published_cfg)
			) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"project and wrapper publish different Intel cfg handles"
				)
			end

			port_cfg = published_cfg;
		end

		if (port_cfg == null) begin
			port_cfg = intel_pcie_adapter_config::type_id::create(
				$sformatf("intel_cfg_%0d", slot)
			);

			port_cfg.side = INTEL_PCIE_HARD_IP;
		end

		if (port_cfg.side != INTEL_PCIE_HARD_IP) begin
			`uvm_fatal(
				"PROJECT_INTEL",
				"EP application DUT requires explicit INTEL_PCIE_HARD_IP side"
			)
		end

		port_cfg.validate();

		if (cfg.intel_rc_vifs.exists(slot)) begin
			vif = cfg.intel_rc_vifs[slot];

			if (vif == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel VIF is null")
			end
		end

		if (uvm_config_db#(intel_pcie_vif_t)::get(
			this,
			path,
			"vif",
			published_vif
		)) begin
			if (
				published_vif == null ||
				(vif != null && vif != published_vif)
			) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"project and wrapper publish different Intel VIFs"
				)
			end

			vif = published_vif;
		end

		if (vif == null) begin
			`uvm_fatal(
				"PROJECT_INTEL",
				$sformatf("missing Intel VIF at %s.%s", get_full_name(), path)
			)
		end

		foreach (used_cfgs[i]) begin
			if (used_cfgs[i] == port_cfg || used_vifs[i] == vif) begin
				`uvm_fatal(
					"PROJECT_INTEL",
					"Intel cfg or VIF reused by distinct TL slots"
				)
			end
		end

		used_cfgs.push_back(port_cfg);
		used_vifs.push_back(vif);

		cfg.intel_cfg_by_slot[slot] = port_cfg;
		cfg.intel_rc_vifs[slot]     = vif;

		uvm_config_db#(intel_pcie_adapter_config)::set(
			this,
			path,
			"intel_cfg",
			port_cfg
		);

		uvm_config_db#(intel_pcie_vif_t)::set(
			this,
			path,
			"vif",
			vif
		);
	end

	if (
		cfg.intel_cfg_by_slot.num() != cfg.tl_slot_by_host.num() ||
		cfg.intel_rc_vifs.num() != cfg.tl_slot_by_host.num()
	) begin
		`uvm_fatal("PROJECT_INTEL", "Intel bindings contain an unused TL slot")
	end
endfunction


// connect 时只校验实际创建的 adapter，不再补绑接口；否则 adapter build 早已失败。
// 确认 instance override 和 bridge 生效，防止接口配置看似存在却仍走公共 TLM 回环。
function void	project_env::check_intel_bindings();
	if (
		!pcie_env.bridge_required ||
		pcie_env.ep_agent != null ||
		pcie_env.ep_agents.size() != 0 ||
		pcie_env.ep_adapter != null ||
		pcie_env.ep_adapters.size() != 0
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel needs the external-pin bridge and RC-only component tree"
		)
	end

	foreach (cfg.intel_cfg_by_slot[slot]) begin
		intel_pcie_if_adapter	adapter;

		if (slot >= pcie_env.rc_adapters.size()) begin
			`uvm_fatal("PROJECT_INTEL", "Intel RC adapter slot is missing")
		end

		if (!$cast(adapter, pcie_env.rc_adapters[slot]) || adapter == null) begin
			`uvm_fatal("PROJECT_INTEL", "Intel instance factory override did not take effect")
		end

		if (
			adapter.cfg != cfg.intel_cfg_by_slot[slot] ||
			adapter.avst_vif != cfg.intel_rc_vifs[slot]
		) begin
			`uvm_fatal("PROJECT_INTEL", "Intel adapter consumed different cfg/VIF handles")
		end
	end
endfunction


// 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
// create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
// PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
function void	project_env::build_phase(
	uvm_phase	phase
);

	super.build_phase(phase);

	if (
		!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) ||
		cfg == null
	) begin
		`uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
	end

	cfg.load_params();
	uvm_config_db#(project_env_cfg)::set(this, "pcie_env.*", "env_cfg", cfg);
	prepare_host_memory();
	prepare_pcie_config();

	uvm_config_db#(dpu_device_env_config)::set(
		this,
		"dpu_env",
		"cfg",
		cfg.dpu_cfg
	);

	dpu_env = dpu_device_env::type_id::create("dpu_env", this);

	prepare_intel_bindings();

	// bridge 的历史字段名含 svt，但这里只开启外部引脚传输，不创建 SVT/provider。
	intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
	foreach (cfg.tl_slot_by_host[h]) begin
		pcie_tl_rc_driver::type_id::set_inst_override(project_pcie_rc_driver::get_type(),
			$sformatf("pcie_env.rc_agent_%0d.driver", cfg.tl_slot_by_host[h]), this);
	end
	pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

	foreach (cfg.vio_cfg_by_host[h]) begin
		string	child_name;

		child_name = $sformatf("vio_h%0d", h);

		uvm_config_db#(virtio_net_env_config)::set(
			dpu_env,
			child_name,
			"cfg",
			cfg.vio_cfg_by_host[h]
		);

		vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
	end
endfunction


// 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
// 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
function void	project_env::bind_protocol_vifs();
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
					if (slot >= cfg.protocol_vifs.size()) begin
						`uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
					end

					vif = cfg.protocol_vifs[slot];
				end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
					null,
					"uvm_test_top",
					$sformatf("protocol_event_vif_%0d", slot),
					vif
				)) begin
					`uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
				end

				if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why)) begin
					`uvm_fatal("PROJECT_ENV", why)
				end
			end

			if (vif == null) begin
				`uvm_fatal("PROJECT_ENV", "protocol VIF is null")
			end

			foreach (used[j]) begin
				if (used[j] == vif) begin
					`uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
				end
			end

			used.push_back(vif);
			slot++;
		end
	end
endfunction


// connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
// 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
function void	project_env::connect_phase(
	uvm_phase	phase
);
	super.connect_phase(phase);

	if (
		pcie_env.global_cfg != null ||
		pcie_env.topology_adapter != null ||
		pcie_env.backend_provider_active ||
		pcie_env.cfg != cfg.pcie_cfg
	) begin
		`uvm_fatal("PROJECT_ENV", "Intel project requires the direct PCIe cfg-only path")
	end

	check_intel_bindings();
	bind_protocol_vifs();

	begin
		bit	ok;
		string	why;
		publish_dpu_configuration(ok, why);
		if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	end

	foreach (vio_envs[h]) begin
		virtio_pcie_function_endpoint	endpoints[$];
		int unsigned			slot;

		slot = cfg.tl_slot_by_host[h];

		if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null) begin
			`uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
		end

		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance	f;
			virtio_pcie_function_endpoint	endpoint;

			f = vio_envs[h].function_instances[i];

			if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0) begin
				`uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
			end

			endpoint = virtio_pcie_function_endpoint::type_id::create(
				$sformatf("endpoint_h%0d_f%0d", h, i)
			);

			// Completion 由 PCIe RC driver 接收；无模型 completion adapter 或 EP monitor。
			// 同 Host 的所有 Function 共用该 RC，完整身份仍由 endpoint 保留。
			endpoint.configure(
				f.pcie_id,
				pcie_env.rc_agents[slot].sequencer,
				pcie_env.rc_agents[slot].rc_driver,
				null,
				pcie_env.rc_agents[slot].monitor,
				null
			);

			endpoints.push_back(endpoint);
		end

		if (!vio_envs[h].bind_pcie_endpoints(endpoints)) begin
			`uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
		end
		// 真 DUT 无 EP 接收 monitor；RC monitor 仅收包，发出的真实 doorbell 从 driver TX 观察口补齐。
		// 仅补出站观察，不连接第二 responder，也不重复消费入站 MSI-X。
		if (!tx_observation_bound.exists(h)) begin
			foreach (vio_envs[h].function_instances[i])
				pcie_env.rc_agents[slot].rc_driver.tx_ap.connect(
					vio_envs[h].function_instances[i].driver_agent.observer.analysis_export);
			tx_observation_bound[h] = 1;
		end
	end
	// 发布真实组件句柄，所有配置 sequence 共享它们，不复制运行期状态。
	cfg.vio_envs = vio_envs;
	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned	slot;

		slot = cfg.tl_slot_by_host[h];
		cfg.rc_sequencers[slot] = pcie_env.rc_agents[slot].sequencer;
	end
	cfg.runtime_ready = 1;
endfunction


// 每个仿真调用一次：按完整 service 身份登记各 Host，再注册已有 Tcl 命令。
// 空 Host 可跳过；全局没有 VIO service 或重复注册属于接入错误。
function void	project_env::register_aip_commands();
	int unsigned	active_hosts;
	string		why;

	active_hosts = 0;

	foreach (vio_envs[h]) begin
		if (vio_envs[h].function_instances.size() == 0) begin
			continue;
		end

		if (!virtio_aip_registry::bind_env(vio_envs[h], why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end

		active_hosts++;
	end

	if (active_hosts == 0) return;

	if (!virtio_aip_registry::register_business_commands(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end
endfunction


// 成功冻结并安装同一个 registry 后才发布视图。新 DPU snapshot 需要重建 env，禁止静默重绑。
function void project_env::publish_dpu_configuration(
	output bit	ok,
	output string	why
);
	project_bar_registry		candidate;
	project_dpu_setup		view;
	dpu_host_info_t			hosts[$];
	project_pcie_rc_driver		driver;
	project_msix_message_t		host_messages[$];
	project_bar_mapping_cfg_t	groups[$];
	groups = cfg.bar_groups;
	ok = 0;
	why = "DPU/PCIe components are not ready";
	if (dpu_env == null || pcie_env == null) return;
	if (dpu_env.get_snapshot() == null) return;
	if (cfg.bar_registry != null) begin
		if (cfg.dpu_setup == null) begin why = "published setup is missing"; return; end
		if (!cfg.dpu_setup.belongs_to(dpu_env.get_snapshot(), cfg.bar_registry)) begin
			why = "new DPU snapshot requires project env rebuild; live RC routing is immutable";
			return;
		end
		ok = !cfg.print_bar_map || cfg.bar_registry.print_bar_map(why, 1);
		return;
	end
	if (!cfg.materialize_messages(dpu_env.get_resource_snapshot(), why)) return;
	candidate = project_bar_registry::type_id::create("bar_registry");
	if (!candidate.initialize(dpu_env.get_snapshot(), 1, why)) return;
	dpu_env.get_snapshot().list_hosts(hosts);
	foreach (hosts[i]) begin
		if (!cfg.tl_slot_by_host.exists(hosts[i].host_id) ||
			!candidate.bind_host(hosts[i].host_id, cfg.tl_slot_by_host[hosts[i].host_id], why)) return;
	end
	foreach (cfg.function_policies[name]) begin
		project_function_policy_t	p;
		p = cfg.function_policies[name];
		if (name != dpu_function_key_name(p.key) || $isunknown(p.requester) ||
			!candidate.bind_function(p.key, p.intel_pf, p.intel_vf, p.requester, why)) return;
	end
	if (!candidate.freeze(why)) return;
	view = new("dpu_setup", dpu_env.get_snapshot(), candidate, 1);
	if (!view.populate(dpu_env.get_resource_snapshot(), why)) return;
	begin
		project_function_record_t	functions[$];
		view.list_functions(functions);
		if (cfg.bar_mapping_per_lease && (cfg.bar_group_policies.size() != 0 || cfg.bar_groups.size() != 0)) begin
			why = "BAR per-lease and explicit group declarations are mutually exclusive"; return;
		end
		if (cfg.bar_mapping_per_lease) begin
			foreach (functions[f]) foreach (functions[f].bars[b]) begin
				project_bar_mapping_cfg_t	group;
				project_bar_target_t		target;
				if (!candidate.resolve_function(functions[f].key, functions[f].bars[b].even_bar_id, target, why)) return;
				group.owners.push_back(functions[f]);
				group.members.push_back(target);
				group.ctx = project_empty_context(target);
				group.ctx.layout_id = "platform-bar-per-lease";
				groups.push_back(group);
			end
		end else foreach (cfg.bar_group_policies[g]) begin
			project_bar_mapping_cfg_t	group;
			project_bar_target_t		target;
			project_function_record_t	owner;
			if (cfg.bar_group_policies[g].functions.size() == 0 ||
				cfg.bar_group_policies[g].functions.size() != cfg.bar_group_policies[g].bar_ids.size()) begin
				why = "BAR atomic group requires complete Function/BAR pairs"; return;
			end
			foreach (cfg.bar_group_policies[g].functions[m]) begin
				if (!view.get_function(cfg.bar_group_policies[g].functions[m], owner) ||
					!candidate.resolve_function(owner.key, cfg.bar_group_policies[g].bar_ids[m], target, why)) return;
				group.owners.push_back(owner);
				group.members.push_back(target);
			end
			group.ctx = project_empty_context(group.members[0]);
			group.ctx.layout_id = cfg.bar_group_policies[g].name;
			groups.push_back(group);
		end
	end
	// 全部 RC cast 和 catalog 检查先完成；install 不会在成功前更换任何外部可见 registry。
	foreach (hosts[i]) begin
		int unsigned	slot;
		slot = cfg.tl_slot_by_host[hosts[i].host_id];
		if (slot >= pcie_env.rc_agents.size() ||
			!$cast(driver, pcie_env.rc_agents[slot].rc_driver)) begin
			why = "project RC instance override was not installed";
			return;
		end
	end
	foreach (cfg.messages[i]) begin
		project_function_record_t	owner;
		if (!view.get_function(cfg.messages[i].owner, owner) ||
			$isunknown({cfg.messages[i].address, cfg.messages[i].data, cfg.messages[i].masked}) ||
			cfg.messages[i].address[1:0] != 0 || cfg.messages[i].local_vector >= 64 ||
			cfg.messages[i].global_vector >= 8192) begin
			why = "public MSI-X catalog contains invalid owner/address/vector";
			return;
		end
		foreach (cfg.messages[j]) if (j < i &&
			cfg.messages[i].owner.host_id == cfg.messages[j].owner.host_id &&
			((cfg.messages[i].address == cfg.messages[j].address && cfg.messages[i].data == cfg.messages[j].data) ||
			(dpu_same_function_key(cfg.messages[i].owner, cfg.messages[j].owner) && cfg.messages[i].local_vector == cfg.messages[j].local_vector))) begin
			why = "public MSI-X catalog has ambiguous message or duplicate vector";
			return;
		end
	end
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;
		h = hosts[i].host_id;
		slot = cfg.tl_slot_by_host[h];
		void'($cast(driver, pcie_env.rc_agents[slot].rc_driver));
		host_messages.delete();
		foreach (cfg.messages[m]) if (cfg.messages[m].owner.host_id == h) host_messages.push_back(cfg.messages[m]);
		if (!driver.install_registry(candidate, h, 0, slot, why) ||
			!driver.install_receive_path(vio_envs[h].host_mem, vio_envs[h].iommu, host_messages, why)) begin
			`uvm_fatal("PROJECT_PUBLICATION", why)
			return;
		end
	end
	cfg.device_snapshot = dpu_env.get_snapshot();
	cfg.resource_snapshot = dpu_env.get_resource_snapshot();
	cfg.bar_registry = candidate;
	cfg.dpu_setup = view;
	cfg.frozen_messages = cfg.messages;
	cfg.frozen_layouts = cfg.table_layouts;
	cfg.frozen_functions = cfg.function_policies;
	cfg.frozen_policies = cfg.vio_policies;
	cfg.frozen_reg_target = cfg.reg_target;
	cfg.frozen_bar_groups = groups;
	cfg.frozen_controls = cfg.platform_controls;
	cfg.frozen_msix_policies = cfg.msix_policies;
	ok = !cfg.print_bar_map || cfg.bar_registry.print_bar_map(why, 1);
endfunction


// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
function void project_env::end_of_elaboration_phase(
	uvm_phase	phase
);
	bit	ok;
	string	why;
	super.end_of_elaboration_phase(phase);
	publish_dpu_configuration(ok, why);
	if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
endfunction
