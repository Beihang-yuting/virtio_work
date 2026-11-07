// integration/project：可继承的 AIP base_test，由 project_env_pkg 最后包含。
// 依赖本目录 env/cfg 与 AIP bridge；基类拥有 objection 和统一配置/命令入口。
// 不知道平台的 reset/TL 接口/DMA/业务完成信号，故将这三处保留为强制实现的接口，
// 防止空 hook 假装平台已准备好。派生 test 用 factory 注册，本虚类不注册 factory。
virtual class project_base_test extends uvm_test;
	project_env_cfg	cfg;
	project_env		env;

	// 构造 test 壳；构建参数由 cfg.load_params 负责，无需在 new 重复逐项赋值。
	extern function new(string	name, uvm_component	parent);

	// 在 cfg 加载后、env 构建前注入平台 pool/IOMMU/VIF 等句柄。
	// cfg 若已由 top 完整注入，派生类可显式提供空实现；此 hook 不重新 load_params。
	pure virtual function void bind_platform_handles();

	// 等待真实复位/Intel 接口就绪，准备 requester-aware DMA 和平台网络检查器。
	// 必须有平台自己的超时及错误处理；返回后调用方才执行明确排列的独立配置操作。
	pure virtual task prepare_platform();

	// Tcl 退出后等待业务完成并检查数据、DMA、PCIe/协议监测与资源回收。
	// vio_tx 返回只表示提交，不能仅凭 AIP run_loop 退出认定业务测试通过。
	pure virtual task finish_platform();

	// 支持 top 提供预建 cfg 或使用 factory；单一参数入口后只下发同一 cfg 句柄。
	extern virtual function void build_phase(uvm_phase	phase);

	// 独立入口失败即停止参考流程，已导出资源留给平台 quiesce/release。
	extern function void require_success(input bit ok, input string why);

	// 唯一运行顺序：平台就绪→独立表配置/验证→VIO 确认→业务命令→Tcl→业务收尾。
	// 运行期 Tcl 只能改变下一条命令采样的参数，不能改写已冻结拓扑。
	extern virtual task run_phase(uvm_phase	phase);
endclass

// 构造 test 外壳，不读取设备。
function project_base_test::new(string	name, uvm_component	parent);
	super.new(name, parent);
endfunction

// 唯一参数加载后注入平台句柄，再构建同一个 env。
function void project_base_test::build_phase(uvm_phase	phase);
	super.build_phase(phase);
	if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg))
		cfg = project_env_cfg::type_id::create("cfg");
	if (cfg == null) `uvm_fatal("PROJECT_TEST", "project_cfg is null")
	cfg.load_params();
	bind_platform_handles();
	uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
	env = project_env::type_id::create("env", this);
endfunction

// 配置失败立即停止参考流程，资源仍由平台显式回收。
function void project_base_test::require_success(input bit ok, input string why);
	if (!ok) `uvm_fatal("PROJECT_TEST", why)
endfunction

// 调用方明确排列类别；成功确认后才进入业务 Tcl。
task project_base_test::run_phase(uvm_phase	phase);
	phase.raise_objection(this);
	prepare_platform();
	begin
		project_dpu_config_scope	public_scope;
		project_vio_selection_t	vio_selection;
		dpu_function_key_t	functions[$];
		int unsigned	bars[$];
		bit	ok;
		string	why;
		public_scope = new("public_scope", env.dpu_setup, functions, bars);
		env.configure_bar_table(public_scope, ok, why);
		require_success(ok, why);
		env.configure_af(public_scope, ok, why);
		require_success(ok, why);
		env.configure_pf_vf_map(public_scope, ok, why);
		require_success(ok, why);
		env.configure_bdf_table(public_scope, ok, why);
		require_success(ok, why);
		env.configure_completion_bdf_table(public_scope, ok, why);
		require_success(ok, why);
		env.configure_tlp_prefix(public_scope, ok, why);
		require_success(ok, why);
		env.configure_msix(public_scope, ok, why);
		require_success(ok, why);
		env.verify_dpu_configuration(public_scope, ok, why);
		require_success(ok, why);
		env.prepare_vio_configuration(vio_selection, ok, why);
		require_success(ok, why);
		if (vio_selection.setups.num() != 0) begin
			env.configure_vio_notify(vio_selection, ok, why);
			require_success(ok, why);
			env.configure_qsch(vio_selection, ok, why);
			require_success(ok, why);
			env.configure_vio_queues(vio_selection, ok, why);
			require_success(ok, why);
			env.enable_vio_queues(vio_selection, ok, why);
			require_success(ok, why);
			env.enable_msix(public_scope, ok, why);
			require_success(ok, why);
			env.verify_vio_configuration(vio_selection, ok, why);
			require_success(ok, why);
			env.commit_vio_configuration(vio_selection, ok, why);
			require_success(ok, why);
		end
	end
	if (env.vio_setups.num() != 0) begin
		env.register_aip_commands();
		aip_tcl_bridge::run_loop();
	end
	finish_platform();
	phase.drop_objection(this);
endtask
