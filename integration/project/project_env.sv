// integration/project：可拷入已有项目的组合式 env；只继承 uvm_env。
// 依赖 DPU、PCIe TL、Intel adapter、VIO 与 AIP，由 project_env_pkg 在 cfg 后包含。
// 类内集中声明成员和 extern 方法；全部实现在本文件类外展开，仍属于同一个 package。
// 本层直接创建 DPU/PCIe/VIO；VIO 的 parent 指向 DPU，使 UVM 自动保证快照先发布。
// 平台 pool 只借用并校验；本层不安装旧设备配置 executor/backend。
// 公共路由在 connect 冻结，用户显式调用独立配置入口后确认 VIO。
// 固定 Intel HARD_IP，在子组件 build 前取得或发布 cfg/VIF；EP 功能由真实 DUT 提供。
class project_env extends uvm_env;
	`uvm_component_utils(project_env)

	// 大 cfg 由 test 下发；DPU、PCIe 和各 Host VIO 由本层创建，VIO 的 parent 为 dpu_env。
	project_env_cfg	cfg;
	dpu_device_env	dpu_env;
	pcie_tl_env		pcie_env;
	virtio_net_env	vio_envs[int unsigned];

	// pool 借用平台对象，registry 与公共视图发布后不可替换；ring 准备可产生独立新代。
	host_mem_pool	shared_pool;
	project_bar_registry	bar_registry;
	project_dpu_setup	dpu_setup;
	vio_external_setup	vio_setups[int unsigned];
	local project_msix_message_t	frozen_messages[$];
	local project_config_record_t	records[string];
	local bit	configured[string];
	local bit	verified[string];
	local bit	enabled[string];
	local semaphore	port_locks[string];
	local semaphore	configuration_lock = new(1);


	local project_table_layout_t	frozen_layouts[project_table_kind_e];
	local project_function_policy_t	frozen_functions[string];
	local project_vio_policy_t	frozen_policies[string];
	local string	frozen_reg_target;
	local project_bar_mapping_cfg_t	frozen_bar_groups[$];
	local project_control_cfg_t	frozen_controls[$];
	local bit	tx_observation_bound[int unsigned];
	local int unsigned	checked_writes_active;
	local project_msix_policy_t	frozen_msix_policies[string];

	// 首次成功发布后才打印，重复同快照幂等，新拓扑要求 rebuild 而不留下新旧路由混合。
	extern function void publish_dpu_configuration(output bit ok, output string why);
	extern virtual function void end_of_elaboration_phase(uvm_phase phase);

	// 准备仅分配本地 ring；返回各 Host 的真实视图，硬件配置由后续独立入口完成。
	extern task prepare_vio_configuration(output project_vio_selection_t selection, output bit ok, output string why);
	extern function bit preflight_vio(input project_vio_selection_t selection, output string why);
	extern function void commit_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	extern function void release_vio_resources(input project_vio_selection_t selection, input logic dut_quiesced, output bit ok, output string why);

	// MMIO helper 校验四态输入和完整范围，posted success 仅表示发送完成。
	extern task pcie_bar_write(input dpu_function_key_t owner, input int unsigned bar_id,
		input logic [63:0] offset, input int unsigned length, input logic [127:0] data,
		input logic [31:0] byte_skip_mask, output bit ok, output string why);
	extern task pcie_bar_read(input dpu_function_key_t owner, input int unsigned bar_id,
		input logic [63:0] offset, input int unsigned length, input logic [31:0] byte_skip_mask,
		output logic [127:0] data, output bit ok, output string why);
	extern task pcie_bar_write_by_name(input string name, input logic [63:0] offset,
		input int unsigned length, input logic [127:0] data, input logic [31:0] byte_skip_mask,
		output bit ok, output string why);
	extern task pcie_bar_read_by_name(input string name, input logic [63:0] offset,
		input int unsigned length, input logic [31:0] byte_skip_mask,
		output logic [127:0] data, output bit ok, output string why);
	extern task pcie_poll_bar(input dpu_function_key_t owner, input int unsigned bar_id,
		input logic [63:0] offset, input int unsigned length, input logic [127:0] mask,
		input logic [127:0] expected, input int unsigned attempts, input time interval,
		output bit ok, output string why);

	// checked helper 是间接端口唯一锁持有层；整项预检后才允许首个 posted 写。
	extern protected task checked_write(input project_config_record_t record,
		input logic [127:0] value, input bit enabling, output bit ok, output string why);
	extern protected task mmio(input project_bar_target_t target, input bit writing,
		input logic [63:0] offset, input int unsigned length, input logic [127:0] data,
		input logic [31:0] byte_skip_mask, output logic [127:0] result, output bit ok, output string why);
	extern protected function bit make_context(input project_table_kind_e kind,
		input dpu_function_key_t owner, input int unsigned index, input longint unsigned generation,
		output project_table_context_t ctx, output string why);
	extern protected function bit public_records(input project_table_kind_e kind,
		input project_dpu_config_scope scope, output project_config_record_t selected[$], output string why);
	extern protected function bit queue_records(input project_vio_selection_t selection,
		input project_table_kind_e kinds[$],
		output project_config_record_t selected[$], output string why);
	extern protected function bit kind_selected(input project_table_kind_e kind, input project_table_kind_e kinds[$]);
	extern protected function bit revoke_public(input project_dpu_config_scope scope, input bit apply, output string why);
	extern protected function bit revoke_vio(input project_vio_selection_t selection, output string why);
	extern protected function bit remember_record(input project_config_record_t record, output string why);
	extern protected function logic [127:0] platform_control_mask(input project_config_record_t record);
	extern task write_control(input project_control_cfg_t item, output bit ok, output string why);
	extern task write_queue_aux(input project_queue_control_cfg_t item, output bit ok, output string why);
	extern protected task dispatch_record(input project_config_record_t record, output bit ok, output string why);
	extern protected task configure_public(input project_table_kind_e kinds[$],
		input project_dpu_config_scope scope, output bit ok, output string why);
	extern protected task configure_queues(input project_table_kind_e kinds[$],
		input project_vio_selection_t selection, output bit ok, output string why);

	// 独立 configure_bar_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bar_table(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_af 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_af(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_pf_vf_map 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_pf_vf_map(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bdf_table(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_completion_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_completion_bdf_table(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_tlp_prefix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_tlp_prefix(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_msix(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 enable_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task enable_msix(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_rdma_notify 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_rdma_notify(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_qsch_rnet 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_qsch_rnet(input project_dpu_config_scope scope, output bit ok, output string why);
	// 独立 configure_vio_notify 入口；不隐含调用其他类别。
	extern task configure_vio_notify(input project_vio_selection_t selection, output bit ok, output string why);
	// 独立 configure_qsch 入口；不隐含调用其他类别。
	extern task configure_qsch(input project_vio_selection_t selection, output bit ok, output string why);
	// 独立 configure_vio_queues 入口；不隐含调用其他类别。
	extern task configure_vio_queues(input project_vio_selection_t selection, output bit ok, output string why);
	// 使能和验证分别执行；任何必需类别失败均保留 DMA 并阻止提交。
	extern task enable_vio_queues(input project_vio_selection_t selection, output bit ok, output string why);
	extern task verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
	extern task verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	// 单项用户实现 bdf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_bdf_entry(input project_bdf_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_bdf(input project_bdf_cfg_t item, output bit ok, output string why);
	// 单项用户实现 completion_bdf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_completion_bdf_entry(input project_completion_bdf_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_completion_bdf(input project_completion_bdf_cfg_t item, output bit ok, output string why);
	// 单项用户实现 pfvf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_pf_vf_entry(input project_pfvf_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_pfvf(input project_pfvf_cfg_t item, output bit ok, output string why);
	// 单项用户实现 tlp_prefix，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_tlp_prefix_entry(input project_tlp_prefix_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_tlp_prefix(input project_tlp_prefix_cfg_t item, output bit ok, output string why);
	// 单项用户实现 msix_linear，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_linear_entry(input project_msix_linear_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_linear(input project_msix_linear_cfg_t item, output bit ok, output string why);
	// 单项用户实现 msix_info，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_info_entry(input project_msix_info_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_info(input project_msix_info_cfg_t item, output bit ok, output string why);
	// 单项用户实现 msix_interval，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_interval_entry(input project_msix_interval_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_interval(input project_msix_interval_cfg_t item, output bit ok, output string why);
	// 单项用户实现 msix_table，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_table_entry(input project_msix_table_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_table(input project_msix_table_cfg_t item, output bit ok, output string why);
	// 单项用户实现 qsch_q2tc，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
	// 单项用户实现 qsch_n2g，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
	// 单项用户实现 qsch_g2p，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
	// 单项用户实现 rdma_notify，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_rdma_notify_entry(input project_rdma_notify_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_rdma_notify(input project_rdma_notify_cfg_t item, output bit ok, output string why);
	// 单项用户实现 qsch_rnet，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_rnet_entry(input project_qsch_rnet_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_rnet(input project_qsch_rnet_cfg_t item, output bit ok, output string why);
	// 单项用户实现 vtx，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vtx_queue(input project_vtx_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vtx(input project_vtx_cfg_t item, output bit ok, output string why);
	// 单项用户实现 vrx，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vrx_queue(input project_vrx_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vrx(input project_vrx_cfg_t item, output bit ok, output string why);
	// 单项用户实现 vio_notify，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vio_notify_entry(input project_vio_notify_cfg_t item, output bit ok, output string why);
	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vio_notify(input project_vio_notify_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_prepare_device(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_af(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_control_entry(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_function(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_qsch_spwrr(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_qsch_tc_weight(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_queue_aux(input project_queue_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_enable_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_quiesce_device(input project_control_cfg_t item, output bit ok, output string why);
	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_reset_device(input project_control_cfg_t item, output bit ok, output string why);
	// BAR 映射必须接收完整原子组，不能推测连续 VF 窗口。
	extern virtual task user_configure_bar_mapping_entry(input project_bar_mapping_cfg_t item, output bit ok, output string why);
	// 验证平台已有配置允许独立于写入入口调用；成功只确认传入 scope。
	extern virtual task user_verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
	extern virtual task user_verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	// 检查单条队列的公共/队列依赖，已配置或独立验证均可作为本代依据。
	extern protected function bit dependencies_ready(input project_config_record_t queue, output string why);
	// 已交付 READY/RUNNING 的消费者禁止重写依赖；平台应先 stop/quiesce/release。
	extern protected function bit record_writable(input project_config_record_t record, output string why);

	// 使能专用 checked 入口，只允许冻结 enable 位变化并完整核对 ring 绑定。
	extern task write_enabled_queue(input project_queue_control_cfg_t item, output bit ok, output string why);

	// 只读状态查询与明确 W1C 清除保持独立，不参与配置成功账本。
	extern task read_msix_pba(input project_state_query_t item, output project_msix_pba_word_t value, output bit ok, output string why);
	extern task read_msix_stat(input project_state_query_t item, output project_msix_stat_t value, output bit ok, output string why);
	extern task read_pfvf_drop_status(input project_state_query_t item, output project_pfvf_drop_status_t value, output bit ok, output string why);
	extern task clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t item, output bit ok, output string why);
	extern virtual task user_read_msix_stat(input project_state_query_t item, output project_msix_stat_t value, output bit ok, output string why);
	extern virtual task user_read_pfvf_drop_status(input project_state_query_t item, output project_pfvf_drop_status_t value, output bit ok, output string why);
	extern virtual task user_clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t item, output bit ok, output string why);
	// 只读生成状态上下文，缺失 PBA 实际容量时拒绝，不猜截图内部冲突。
	extern function bit get_state_context(input project_table_kind_e kind, input dpu_function_key_t owner,
		input int unsigned index, output project_state_query_t item, output string why);

	// 组装完整冻结 PF 家族给平台纯规则；与写 hook 分离，任何访问前完成。
	extern protected function bit validate_pfvf_family(input dpu_function_key_t owner, output string why);

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

	// 平台就绪后执行 DPU 的 VIO 寄存器计划；执行失败报告 fatal，不能重复初始化。


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
	int unsigned			slot;
	string				why;

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
			virtio_function_instance		f;
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

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_bar_table(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_BAR};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_af(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_AF};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_pf_vf_map(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_PFVF};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_bdf_table(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_BDF};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_completion_bdf_table(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_COMPLETION_BDF};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_tlp_prefix(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_PREFIX};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_msix(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_CONTROL, PROJECT_MSIX_TABLE};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::enable_msix(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e kinds[$] = '{PROJECT_MSIX_FUNCTION};
	project_table_kind_e dependencies[$] = '{PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_TABLE, PROJECT_MSIX_CONTROL};
	project_config_record_t batch[$];
	ok = 0;
	foreach (dependencies[k]) begin
		if (!public_records(dependencies[k], scope, batch, why)) return;
		foreach (batch[i]) begin
			string key;
			key = batch[i].ctx.record_key;
			if (!records.exists(key) || !((configured.exists(key) && configured[key]) || (verified.exists(key) && verified[key]))) begin
				why = {"MSI-X enable dependency not configured/verified: ", key}; return;
			end
		end
	end
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_rdma_notify(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_RDMA_NOTIFY};
	configure_public(kinds, scope, ok, why);
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_env::configure_qsch_rnet(input project_dpu_config_scope scope, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_RNET};
	configure_public(kinds, scope, ok, why);
endtask

// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_env::configure_vio_notify(input project_vio_selection_t selection, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_NOTIFY};
	configure_queues(kinds, selection, ok, why);
endtask

// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_env::configure_qsch(input project_vio_selection_t selection, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT};
	configure_queues(kinds, selection, ok, why);
endtask

// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_env::configure_vio_queues(input project_vio_selection_t selection, output bit ok, output string why);
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX};
	configure_queues(kinds, selection, ok, why);
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_bdf_entry(input project_bdf_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_bdf_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_completion_bdf_entry(input project_completion_bdf_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_completion_bdf_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_pf_vf_entry(input project_pfvf_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_pf_vf_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_tlp_prefix_entry(input project_tlp_prefix_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_tlp_prefix_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_msix_linear_entry(input project_msix_linear_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_linear_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_msix_info_entry(input project_msix_info_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_info_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_msix_interval_entry(input project_msix_interval_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_interval_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_msix_table_entry(input project_msix_table_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_table_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_q2tc is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_n2g is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_g2p is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_rdma_notify_entry(input project_rdma_notify_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_rdma_notify_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_qsch_rnet_entry(input project_qsch_rnet_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_rnet_entry is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_vtx_queue(input project_vtx_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_vtx_queue is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_vrx_queue(input project_vrx_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_vrx_queue is not implemented";
endtask

// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_env::user_configure_vio_notify_entry(input project_vio_notify_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_vio_notify_entry is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_prepare_device(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_prepare_device is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_af(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_af is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_msix_control_entry(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_control_entry is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_msix_function(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_msix_function is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_qsch_spwrr(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_spwrr is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_qsch_tc_weight(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_qsch_tc_weight is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_configure_queue_aux(input project_queue_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_queue_aux is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_enable_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_enable_queue is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_quiesce_device(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_quiesce_device is not implemented";
endtask

// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_env::user_reset_device(input project_control_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_reset_device is not implemented";
endtask

// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_env::user_configure_bar_mapping_entry(input project_bar_mapping_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_configure_bar_mapping_entry is not implemented";
endtask

// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_env::user_verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
	ok = 0;
	why = "required user_verify_dpu_configuration is not implemented";
endtask

// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_env::user_verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	ok = 0;
	why = "required user_verify_vio_configuration is not implemented";
endtask

// 成功冻结并安装同一个 registry 后才发布视图。新 DPU snapshot 需要重建 env，禁止静默重绑。
function void project_env::publish_dpu_configuration(output bit ok, output string why);
	project_bar_registry	candidate;
	project_dpu_setup	view;
	dpu_host_info_t	hosts[$];
	project_pcie_rc_driver	driver;
	project_msix_message_t	host_messages[$];
	project_bar_mapping_cfg_t groups[$];
	groups = cfg.bar_groups;
	ok = 0;
	why = "DPU/PCIe components are not ready";
	if (dpu_env == null || pcie_env == null) return;
	if (dpu_env.get_snapshot() == null) return;
	if (bar_registry != null) begin
		if (dpu_setup == null) begin why = "published setup is missing"; return; end
		if (!dpu_setup.belongs_to(dpu_env.get_snapshot(), bar_registry)) begin
			why = "new DPU snapshot requires project env rebuild; live RC routing is immutable";
			return;
		end
		ok = !cfg.print_bar_map || bar_registry.print_bar_map(why, 1);
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
				project_bar_target_t	target;
				if (!candidate.resolve_function(functions[f].key, functions[f].bars[b].even_bar_id, target, why)) return;
				group.owners.push_back(functions[f]);
				group.members.push_back(target);
				group.ctx = project_empty_context(target);
				group.ctx.layout_id = "platform-bar-per-lease";
				groups.push_back(group);
			end
		end else foreach (cfg.bar_group_policies[g]) begin
			project_bar_mapping_cfg_t	group;
			project_bar_target_t	target;
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
	bar_registry = candidate;
	dpu_setup = view;
	frozen_messages = cfg.messages;
	frozen_layouts = cfg.table_layouts;
	frozen_functions = cfg.function_policies;
	frozen_policies = cfg.vio_policies;
	frozen_reg_target = cfg.reg_target;
	frozen_bar_groups = groups;
	frozen_controls = cfg.platform_controls;
	frozen_msix_policies = cfg.msix_policies;
	ok = !cfg.print_bar_map || bar_registry.print_bar_map(why, 1);
endfunction

// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
function void project_env::end_of_elaboration_phase(uvm_phase phase);
	bit	ok;
	string	why;
	super.end_of_elaboration_phase(phase);
	publish_dpu_configuration(ok, why);
	if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
endfunction

// 全部四态检查在两态 registry/sequence 转换前执行，保留小端 byte lane 和 skip-mask 语义。
task project_env::mmio(input project_bar_target_t target, input bit writing,
	input logic [63:0] offset, input int unsigned length, input logic [127:0] data,
	input logic [31:0] byte_skip_mask, output logic [127:0] result, output bit ok, output string why);
	pcie_tl_reg_seq	seq;
	bit [63:0]	address;
	ok = 0;
	result = '0;
	why = "MMIO contains X/Z, unsupported width/alignment or skip-mask";
	if ($isunknown({offset, data, byte_skip_mask}) || !(length inside {4,8,12,16}) ||
		offset[1:0] != 0 || (byte_skip_mask != '1 && (byte_skip_mask >> length) != 0) ||
		(writing && length < 16 && (data >> (8*length)) != 0)) return;
	if (bar_registry == null) return;
	if (!bar_registry.check_range(target, offset, length, address, why)) return;
	if (address[11:0] + length > 4096 || target.rc_slot >= pcie_env.rc_agents.size()) begin
		why = "MMIO crosses 4KB or has no RC sequencer";
		return;
	end
	seq = pcie_tl_reg_seq::type_id::create("project_mmio");
	seq.is_write = writing;
	seq.addr = address;
	seq.len = length;
	seq.mask = byte_skip_mask;
	seq.wdata = data;
	seq.start(pcie_env.rc_agents[target.rc_slot].sequencer);
	ok = seq.status == PCIE_RW_OK;
	why = seq.error_msg;
	result = seq.rdata;
endtask

// Function+真实 BAR 查找，offset 永远相对所选 BAR；失败不回退默认窗口。
task project_env::pcie_bar_write(input dpu_function_key_t owner, input int unsigned bar_id,
	input logic [63:0] offset, input int unsigned length, input logic [127:0] data,
	input logic [31:0] byte_skip_mask, output bit ok, output string why);
	project_bar_target_t	target;
	logic [127:0]	ignored;
	ok = 0;
	if (bar_registry == null) begin why = "public registry not published"; return; end
	if (!bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask

// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
task project_env::pcie_bar_read(input dpu_function_key_t owner, input int unsigned bar_id,
	input logic [63:0] offset, input int unsigned length, input logic [31:0] byte_skip_mask,
	output logic [127:0] data, output bit ok, output string why);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (bar_registry == null) begin why = "public registry not published"; return; end
	if (!bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask

// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
task project_env::pcie_bar_write_by_name(input string name, input logic [63:0] offset,
	input int unsigned length, input logic [127:0] data, input logic [31:0] byte_skip_mask,
	output bit ok, output string why);
	project_bar_target_t	target;
	logic [127:0]	ignored;
	ok = 0;
	if (bar_registry == null) begin why = "public registry not published"; return; end
	if (!bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask

// 名字解析与实际 Function API 复用同一个范围/格式检查。
task project_env::pcie_bar_read_by_name(input string name, input logic [63:0] offset,
	input int unsigned length, input logic [31:0] byte_skip_mask,
	output logic [127:0] data, output bit ok, output string why);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (bar_registry == null) begin why = "public registry not published"; return; end
	if (!bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask

// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
task project_env::pcie_poll_bar(input dpu_function_key_t owner, input int unsigned bar_id,
	input logic [63:0] offset, input int unsigned length, input logic [127:0] mask,
	input logic [127:0] expected, input int unsigned attempts, input time interval,
	output bit ok, output string why);
	logic [127:0]	data;
	ok = 0;
	why = "poll needs finite attempts and known comparison";
	if (attempts == 0 || $isunknown({mask, expected})) return;
	for (int unsigned i = 0; i < attempts; i++) begin
		pcie_bar_read(owner, bar_id, offset, length, 0, data, ok, why);
		if (!ok) return;
		if ((data & mask) === (expected & mask)) return;
		if (i + 1 < attempts) #(interval);
	end
	ok = 0;
	why = "BAR poll exhausted attempts";
endtask

// 从平台已冻结布局解析真实目标，图片相对偏移单独保留；整个操作范围先检查。
function bit project_env::make_context(input project_table_kind_e kind,
	input dpu_function_key_t owner, input int unsigned index, input longint unsigned generation,
	output project_table_context_t ctx, output string why);
	project_table_layout_t	layout;
	bit [64:0]	offset;
	bit [63:0]	address;
	bit [63:0]	expected_offset;
	string	name;
	why = {"missing platform layout: ", kind.name()};
	if (bar_registry == null) return 0;
	if (frozen_layouts.exists(kind)) layout = frozen_layouts[kind];
	else begin
		layout.provided = 0;
		layout.reg_target = "";
		layout.access_host_provided = 0;
		layout.access_host = 0;
		layout.access_uses_owner_host = 0;
		layout.module_offset = 0;
		layout.table_offset = 0;
		layout.capacity = 0;
		layout.entry_bytes = 0;
		layout.index_policy = PROJECT_INDEX_EXPLICIT;
		layout.indirect = 0;
		layout.data_port = 0;
		layout.control_port = 0;
		layout.index_mask = 0;
		layout.control_fixed = 0;
		layout.trigger_mask = 0;
		layout.index_shift = 0;
		layout.required = 0;
	end
	if (kind inside {PROJECT_MSIX_TABLE, PROJECT_MSIX_PBA} && frozen_msix_policies.exists(dpu_function_key_name(owner))) begin
		project_msix_policy_t	p;
		bit	provided;
		bit [63:0]	base;
		int unsigned	bar_id;
		p = frozen_msix_policies[dpu_function_key_name(owner)];
		if (p.table_present && p.pba_present && p.table_bar == p.pba_bar) begin
			bit [64:0] table_end;
			bit [64:0] pba_end;
			table_end = {1'b0, p.table_offset} + 65'(p.table_size)*16;
			pba_end = {1'b0, p.pba_offset} + 65'(p.pba_words)*8;
			if ($isunknown({p.table_offset,p.pba_offset}) || table_end[64] || pba_end[64] ||
				({1'b0,p.table_offset} < pba_end && {1'b0,p.pba_offset} < table_end)) begin
				why = "MSI-X table/PBA declarations overlap or overflow"; return 0;
			end
		end
		provided = kind == PROJECT_MSIX_TABLE ? p.table_present : p.pba_present;
		if (provided) begin
			base = kind == PROJECT_MSIX_TABLE ? p.table_offset : p.pba_offset;
			bar_id = kind == PROJECT_MSIX_TABLE ? p.table_bar : p.pba_bar;
			if (base < (kind == PROJECT_MSIX_TABLE ? 'h20000 : 'h10000) ||
				$isunknown(base) || (kind == PROJECT_MSIX_TABLE && (base[3:0] != 0 || p.table_size == 0 || p.table_size > 1024)) ||
				(kind == PROJECT_MSIX_PBA && (base[2:0] != 0 || p.pba_words == 0))) begin
				why = "explicit MSI-X/PBA layout has invalid offset/capacity"; return 0;
			end
			layout.provided = 1;
			layout.reg_target = $sformatf("h%0d.pf%0d", owner.host_id, owner.pf_id);
			if (owner.kind == DPU_FUNCTION_VF) layout.reg_target = {layout.reg_target,$sformatf(".vf%0d",owner.vf_id)};
			layout.reg_target = {layout.reg_target,$sformatf(".bar%0d",bar_id)};
			layout.table_offset = kind == PROJECT_MSIX_TABLE ? 'h20000 : 'h10000;
			layout.module_offset = base - layout.table_offset;
			layout.capacity = kind == PROJECT_MSIX_TABLE ? p.table_size : p.pba_words;
			layout.entry_bytes = kind == PROJECT_MSIX_TABLE ? 16 : 8;
			layout.index_policy = PROJECT_INDEX_LOCAL_VECTOR;
			layout.indirect = 0;
		end
	end
	if (!layout.provided) return 0;
	if ($isunknown({layout.module_offset, layout.table_offset, layout.data_port, layout.control_port,
		layout.index_mask, layout.control_fixed, layout.trigger_mask}) ||
		!(layout.entry_bytes inside {4,8,12,16}) || index >= layout.capacity) begin
		why = "layout/index has unknown values or unsupported capacity/width";
		return 0;
	end
	if ((kind inside {PROJECT_VTX,PROJECT_VRX,PROJECT_NOTIFY,PROJECT_MSIX_TABLE} && layout.entry_bytes != 16) ||
		(kind inside {PROJECT_PREFIX,PROJECT_MSIX_LINEAR,PROJECT_RDMA_NOTIFY,PROJECT_MSIX_PBA} && layout.entry_bytes != 8) ||
		(kind inside {PROJECT_BDF,PROJECT_PFVF,PROJECT_COMPLETION_BDF,PROJECT_MSIX_INFO,PROJECT_MSIX_INTERVAL,
			PROJECT_Q2TC,PROJECT_N2G,PROJECT_G2P,PROJECT_RNET,PROJECT_MSIX_STAT,PROJECT_PFVF_DROP} && layout.entry_bytes != 4)) begin
		why = "declared table width contradicts screenshot"; return 0;
	end
	case (kind)
		PROJECT_BDF, PROJECT_PFVF: expected_offset = 'h8000;
		PROJECT_COMPLETION_BDF, PROJECT_PREFIX: expected_offset = 'h18000;
		PROJECT_MSIX_LINEAR, PROJECT_MSIX_INTERVAL: expected_offset = 'h40000;
		PROJECT_MSIX_INFO: expected_offset = 'h50000;
		PROJECT_MSIX_TABLE, PROJECT_NOTIFY: expected_offset = 'h20000;
		PROJECT_Q2TC, PROJECT_VTX, PROJECT_VRX: expected_offset = 'h10000;
		PROJECT_N2G: expected_offset = 'h12000;
		PROJECT_G2P: expected_offset = 'h14000;
		PROJECT_RNET: expected_offset = 'h15000;
		PROJECT_RDMA_NOTIFY: expected_offset = 'hc000;
		PROJECT_MSIX_PBA: expected_offset = 'h10000;
		PROJECT_MSIX_STAT: expected_offset = 'h48000;
		PROJECT_PFVF_DROP: expected_offset = 'ha000;
		default: expected_offset = layout.table_offset;
	endcase
	if (layout.table_offset != expected_offset ||
		(kind inside {PROJECT_VTX, PROJECT_VRX} && !layout.indirect)) begin
		why = "layout contradicts screenshot offset or required indirect access";
		return 0;
	end
	name = layout.reg_target == "" ? frozen_reg_target : layout.reg_target;
	if (!bar_registry.resolve_name(name, ctx.target, why,
		layout.access_host_provided || layout.access_uses_owner_host,
		layout.access_host_provided ? layout.access_host : owner.host_id)) return 0;
	if (kind inside {PROJECT_MSIX_TABLE, PROJECT_MSIX_PBA}) begin
		bit [64:0] span_offset;
		span_offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset};
		if (span_offset[64] || !bar_registry.check_range(ctx.target, span_offset[63:0],
			64'(layout.capacity) * layout.entry_bytes, address, why)) return 0;
	end
	offset = {1'b0, layout.module_offset} + {1'b0, layout.table_offset} + 65'(index) * layout.entry_bytes;
	if (offset[64] || !bar_registry.check_range(ctx.target, offset[63:0], layout.entry_bytes, address, why)) return 0;
	if (layout.indirect) begin
		bit [64:0]	data_offset;
		bit [64:0]	control_offset;
		data_offset = {1'b0, layout.module_offset} + {1'b0, layout.data_port};
		control_offset = {1'b0, layout.module_offset} + {1'b0, layout.control_port};
		if (data_offset[64] || control_offset[64] || layout.index_shift >= 32 ||
			((64'(index) << layout.index_shift) & ~64'(layout.index_mask)) != 0 ||
			(layout.index_mask & (layout.control_fixed | layout.trigger_mask)) != 0 ||
			layout.trigger_mask == 0 || (layout.control_fixed & layout.trigger_mask) != 0 ||
			!bar_registry.check_range(ctx.target, data_offset[63:0], layout.entry_bytes, address, why) ||
			!bar_registry.check_range(ctx.target, control_offset[63:0], 4, address, why) ||
			data_offset[1:0] != 0 || control_offset[1:0] != 0 ||
			data_offset[11:0] + layout.entry_bytes > 4096) begin
			why = "indirect ports/index do not fit declared BAR operation";
			return 0;
		end
	end
	ctx.snapshot = dpu_env.get_snapshot();
	ctx.snapshot_id = dpu_setup.get_generation();
	ctx.config_generation = generation;
	ctx.layout_id = "image-2026-11-07";
	ctx.kind = kind;
	ctx.layout = layout;
	ctx.table_index = index;
	ctx.byte_offset = offset[63:0];
	ctx.record_key = $sformatf("%0d:%s:%016h", kind, ctx.target.canonical_name, ctx.byte_offset);
	why = "";
	return 1;
endfunction

// 同物理项只允许相同本代值；共享消费者合并，不重复调用同一项 hook。
function bit project_env::remember_record(input project_config_record_t record, output string why);
	string	key;
	key = record.ctx.record_key;
	why = "";
	if (records.exists(key)) begin
		if (records[key].ctx !== record.ctx || records[key].entry !== record.entry ||
			records[key].enable_mask !== record.enable_mask || records[key].enable_value !== record.enable_value) begin
			why = {"conflicting/stale table record: ", key};
			return 0;
		end
		foreach (record.consumers[i]) begin
			bit	found;
			found = 0;
			foreach (records[key].consumers[j])
				if (dpu_service_key_name(record.consumers[i]) == dpu_service_key_name(records[key].consumers[j])) found = 1;
			if (!found) records[key].consumers.push_back(record.consumers[i]);
		end
		return 1;
	end
	records[key] = record;
	return 1;
endfunction

// 任意用户副本必须与账本原件匹配；仅 enabling 可改变冻结时声明的 enable/mask 位。
// 同端口锁在本层取得，外层调度和 hook 不持有它，避免嵌套获取造成自锁。
task project_env::checked_write(input project_config_record_t record,
	input logic [127:0] value, input bit enabling, output bit ok, output string why);
	project_config_record_t	original;
	project_table_layout_t	layout;
	logic [127:0]	ignored;
	logic [127:0]	expected;
	bit [63:0]	address;
	bit [63:0]	offset;
	logic [31:0]	control;
	string	lock_key;
	ok = 0;
	why = "checked table write has no matching frozen record";
	if (!records.exists(record.ctx.record_key)) return;
	original = records[record.ctx.record_key];
	if (!record_writable(original, why)) return;
	expected = enabling ? (original.entry & ~original.enable_mask) | original.enable_value : original.entry;
	if (record.ctx !== original.ctx || record.has_queue != original.has_queue ||
		!dpu_same_function_key(record.owner, original.owner) ||
		(record.has_queue && record.binding !== original.binding) || $isunknown(value) || value !== expected) begin
		why = "checked table context/binding/entry differs from immutable export";
		return;
	end
	if (record.has_queue) begin
		vio_config_scope	local_scope;
		dpu_service_key_t	keys[$];
		keys.push_back(record.binding.service_key);
		local_scope = new("write_scope", vio_setups[record.owner.host_id], keys);
		if (!vio_envs[record.owner.host_id].preflight_external_configuration(vio_setups[record.owner.host_id], local_scope, why)) return;
	end
	layout = original.ctx.layout;
	if (!bar_registry.check_range(original.ctx.target, original.ctx.byte_offset, layout.entry_bytes, address, why)) return;
	if (layout.indirect) begin
		offset = layout.module_offset + layout.data_port;
		if (!bar_registry.check_range(original.ctx.target, offset, layout.entry_bytes, address, why) ||
			!bar_registry.check_range(original.ctx.target, layout.module_offset + layout.control_port, 4, address, why)) return;
		lock_key = $sformatf("%s:%016h", original.ctx.target.canonical_name, layout.module_offset + layout.control_port);
		if (!port_locks.exists(lock_key)) port_locks[lock_key] = new(1);
		checked_writes_active++;
		port_locks[lock_key].get();
		mmio(original.ctx.target, 1, offset, layout.entry_bytes, value, 0, ignored, ok, why);
		control = layout.control_fixed | (original.ctx.table_index << layout.index_shift);
		if (ok) mmio(original.ctx.target, 1, layout.module_offset + layout.control_port, 4, 128'(control), 0, ignored, ok, why);
		if (ok) mmio(original.ctx.target, 1, layout.module_offset + layout.control_port, 4, 128'(control | layout.trigger_mask), 0, ignored, ok, why);
		port_locks[lock_key].put();
	end else if (original.ctx.kind inside {PROJECT_NOTIFY, PROJECT_MSIX_LINEAR, PROJECT_RDMA_NOTIFY}) begin
		checked_writes_active++;
		ok = 1;
		for (int d = int'(layout.entry_bytes/4)-1; d >= 0; d--) begin
			mmio(original.ctx.target, 1, original.ctx.byte_offset + 4*d, 4, 128'(value[d*32 +: 32]), 0, ignored, ok, why);
			if (!ok) break;
		end
	end else begin
		checked_writes_active++;
		mmio(original.ctx.target, 1, original.ctx.byte_offset, layout.entry_bytes, value, 0, ignored, ok, why);
	end
	checked_writes_active--;
endtask

// bdf typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_bdf(input project_bdf_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_BDF) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// completion_bdf typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_completion_bdf(input project_completion_bdf_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_COMPLETION_BDF) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// pfvf typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_pfvf(input project_pfvf_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PFVF) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// tlp_prefix typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_tlp_prefix(input project_tlp_prefix_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PREFIX) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// msix_linear typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_msix_linear(input project_msix_linear_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_LINEAR) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// msix_info typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_msix_info(input project_msix_info_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INFO) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// msix_interval typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_msix_interval(input project_msix_interval_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INTERVAL) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// msix_table typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_msix_table(input project_msix_table_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_TABLE) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// qsch_q2tc typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_Q2TC) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// qsch_n2g typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_N2G) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// qsch_g2p typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_G2P) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// rdma_notify typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_rdma_notify(input project_rdma_notify_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RDMA_NOTIFY) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// qsch_rnet typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_qsch_rnet(input project_qsch_rnet_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RNET) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// vtx typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_vtx(input project_vtx_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VTX) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// vrx typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_vrx(input project_vrx_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VRX) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// vio_notify typed 写入口检查全部关联，随后复用唯一序列化/锁实现。
task project_env::write_vio_notify(input project_vio_notify_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_NOTIFY) return;
	r = records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask

// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
task project_env::dispatch_record(input project_config_record_t record, output bit ok, output string why);
	ok = 0;
	why = "unsupported table category";
	case (record.ctx.kind)
		PROJECT_BDF: begin
			project_bdf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_bdf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_bdf_entry(item, ok, why);
		end
		PROJECT_COMPLETION_BDF: begin
			project_completion_bdf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_completion_bdf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_completion_bdf_entry(item, ok, why);
		end
		PROJECT_PFVF: begin
			project_pfvf_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_pfvf_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_pf_vf_entry(item, ok, why);
		end
		PROJECT_PREFIX: begin
			project_tlp_prefix_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_tlp_prefix_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_tlp_prefix_entry(item, ok, why);
		end
		PROJECT_MSIX_LINEAR: begin
			project_msix_linear_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_linear_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_linear_entry(item, ok, why);
		end
		PROJECT_MSIX_INFO: begin
			project_msix_info_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_info_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_info_entry(item, ok, why);
		end
		PROJECT_MSIX_INTERVAL: begin
			project_msix_interval_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_interval_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_interval_entry(item, ok, why);
		end
		PROJECT_MSIX_TABLE: begin
			project_msix_table_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_msix_table_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_msix_table_entry(item, ok, why);
		end
		PROJECT_Q2TC: begin
			project_qsch_q2tc_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_q2tc_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_q2tc(item, ok, why);
		end
		PROJECT_N2G: begin
			project_qsch_n2g_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_n2g_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_n2g(item, ok, why);
		end
		PROJECT_G2P: begin
			project_qsch_g2p_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_g2p_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_g2p(item, ok, why);
		end
		PROJECT_RDMA_NOTIFY: begin
			project_rdma_notify_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_rdma_notify_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_rdma_notify_entry(item, ok, why);
		end
		PROJECT_RNET: begin
			project_qsch_rnet_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_qsch_rnet_entry_t'(record.entry);
			item.owner = record.owner;
			item.consumers = record.consumers;
			user_configure_qsch_rnet_entry(item, ok, why);
		end
		PROJECT_VTX: begin
			project_vtx_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vtx_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vtx_queue(item, ok, why);
		end
		PROJECT_VRX: begin
			project_vrx_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vrx_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vrx_queue(item, ok, why);
		end
		PROJECT_NOTIFY: begin
			project_vio_notify_cfg_t	item;
			item.ctx = record.ctx;
			item.entry = project_vio_notify_entry_t'(record.entry);
			item.binding = record.binding;
			user_configure_vio_notify_entry(item, ok, why);
		end
		PROJECT_QUEUE_AUX: begin
			project_queue_control_cfg_t item;
			item.ctx = record.ctx;
			item.binding = record.binding;
			item.value = record.entry;
			item.writable_mask = platform_control_mask(record);
			user_configure_queue_aux(item, ok, why);
		end
		PROJECT_BAR: begin
			project_bar_mapping_cfg_t	item;
			item = frozen_bar_groups[record.ctx.table_index];
			item.ctx = record.ctx;
			user_configure_bar_mapping_entry(item, ok, why);
		end
		default: begin
			project_control_cfg_t	item;
			item.ctx = record.ctx;
			item.owner = record.owner;
			item.consumers = record.consumers;
			item.value = record.entry;
			item.writable_mask = platform_control_mask(record);
			case (record.ctx.kind)
				PROJECT_AF: user_configure_af(item, ok, why);
				PROJECT_MSIX_CONTROL: user_configure_msix_control_entry(item, ok, why);
				PROJECT_MSIX_FUNCTION: user_configure_msix_function(item, ok, why);
				PROJECT_SPWRR: user_configure_qsch_spwrr(item, ok, why);
				PROJECT_TC_WEIGHT: user_configure_qsch_tc_weight(item, ok, why);

				default: ;
			endcase
		end
	endcase
endtask

// 控制 payload/mask 只来自已冻结 catalog，不把未定义位扩展成全可写。
function logic [127:0] project_env::platform_control_mask(input project_config_record_t record);
	foreach (frozen_controls[c])
		if (frozen_controls[c].ctx.kind == record.ctx.kind && frozen_controls[c].ctx.table_index == record.ctx.table_index &&
			dpu_same_function_key(frozen_controls[c].owner, record.owner)) return frozen_controls[c].writable_mask;
	return 0;
endfunction

// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
task project_env::write_control(input project_control_cfg_t item, output bit ok, output string why);
	project_config_record_t r;
	ok = 0;
	why = "control has no matching frozen record";
	if (!records.exists(item.ctx.record_key)) return;
	r = records[item.ctx.record_key];
	if (!(r.ctx.kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) ||
		item.writable_mask !== platform_control_mask(r) || item.consumers != r.consumers) return;
	r.ctx = item.ctx;
	r.owner = item.owner;
	checked_write(r, item.value, 0, ok, why);
endtask

// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
task project_env::write_queue_aux(input project_queue_control_cfg_t item, output bit ok, output string why);
	project_config_record_t r;
	ok = 0;
	why = "queue auxiliary control has no matching frozen record";
	if (!records.exists(item.ctx.record_key)) return;
	r = records[item.ctx.record_key];
	if (r.ctx.kind != PROJECT_QUEUE_AUX || item.writable_mask !== platform_control_mask(r)) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 0, ok, why);
endtask

// 公共类别只消费冻结 Function/消息/布局；缺失映射只阻止当前类别，不依赖 VIO ring。
function bit project_env::public_records(input project_table_kind_e kind,
	input project_dpu_config_scope scope, output project_config_record_t selected[$], output string why);
	project_function_record_t	functions[$];
	project_function_policy_t	p;
	project_config_record_t	r;
	int unsigned	index;
	selected.delete();
	if (scope == null) return 0;
	if (!scope.validate(dpu_setup, why)) return 0;
	dpu_setup.list_functions(functions);
	if (kind == PROJECT_BAR) begin
		if (frozen_bar_groups.size() == 0) begin why = "BAR mapping atomic groups must be explicitly declared"; return 0; end
		foreach (frozen_bar_groups[g]) begin
			bit	any_selected;
			bit	all_selected;
			any_selected = 0;
			all_selected = 1;
			if (frozen_bar_groups[g].members.size() == 0) begin why = "empty BAR mapping group"; return 0; end
			foreach (frozen_bar_groups[g].members[m]) begin
				project_bar_target_t	target;
				bit	chosen;
				target = frozen_bar_groups[g].members[m];
				chosen = scope.selects(target.function_key) && scope.selects_bar(target.bar_lease.even_bar_id);
				any_selected |= chosen;
				all_selected &= chosen;
				begin
					bit [63:0]	address;
					if (!bar_registry.check_range(target, 0, target.bar_lease.size, address, why)) return 0;
				end
			end
			if (!any_selected) continue;
			if (!all_selected) begin why = "BAR scope splits a declared atomic group"; return 0; end
			r.ctx = frozen_bar_groups[g].ctx;
			r.ctx.snapshot = dpu_env.get_snapshot();
			r.ctx.snapshot_id = dpu_setup.get_generation();
			r.ctx.config_generation = 0;
			r.ctx.kind = PROJECT_BAR;
			r.ctx.table_index = g;
			r.ctx.record_key = $sformatf("BAR:%0d", g);
			r.owner = frozen_bar_groups[g].members[0].function_key;
			r.has_queue = 0;
			r.entry = '0;
			r.enable_mask = '0;
			r.enable_value = '0;
			r.consumers.delete();
			foreach (functions[f]) foreach (frozen_bar_groups[g].members[m]) begin
				if (!dpu_same_function_key(functions[f].key, frozen_bar_groups[g].members[m].function_key)) continue;
				foreach (functions[f].services[v]) r.consumers.push_back(functions[f].services[v]);
			end
			r.dependencies.delete();
			selected.push_back(r);
		end
		// 全部选中租约必须有且只有一个声明组，不能默默遗漏未编码的 BAR。
		foreach (functions[f]) begin
			if (!scope.selects(functions[f].key)) continue;
			foreach (functions[f].bars[b]) begin
				int unsigned	count;
				if (!scope.selects_bar(functions[f].bars[b].even_bar_id)) continue;
				count = 0;
				foreach (selected[s]) foreach (frozen_bar_groups[selected[s].ctx.table_index].members[m]) begin
					project_bar_target_t	t;
					t = frozen_bar_groups[selected[s].ctx.table_index].members[m];
					if (dpu_same_function_key(t.function_key, functions[f].key) && t.bar_lease.even_bar_id == functions[f].bars[b].even_bar_id) count++;
				end
				if (count != 1) begin why = "selected BAR has missing/duplicate mapping group membership"; return 0; end
			end
		end
		return 1;
	end
	// 图中没有定义的控制项仅按平台显式 catalog 遍历，不补默认寄存器或 payload。
	if (kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX, PROJECT_RDMA_NOTIFY, PROJECT_RNET}) begin
		foreach (frozen_controls[i]) begin
			if (frozen_controls[i].ctx.kind != kind || !scope.selects(frozen_controls[i].owner)) continue;
			r.ctx = frozen_controls[i].ctx;
			if (!make_context(kind, frozen_controls[i].owner, r.ctx.table_index, 0, r.ctx, why)) return 0;
			r.owner = frozen_controls[i].owner;
			r.consumers = frozen_controls[i].consumers;
			r.entry = frozen_controls[i].value;
			r.enable_mask = '0;
			r.enable_value = '0;
			r.has_queue = 0;
			if ($isunknown({r.entry, frozen_controls[i].writable_mask}) || (r.entry & ~frozen_controls[i].writable_mask) != 0) begin
				why = "platform control contains unknown/reserved bits"; return 0;
			end
			if (kind == PROJECT_RNET) begin
				project_qsch_rnet_entry_t e;
				e = project_qsch_rnet_entry_t'(r.entry);
				if (r.entry[127:32] != 0 || e.reserved_31_4 != 0 || e.host_id != r.owner.host_id || r.ctx.table_index >= 256) begin
					why = "RNET reserved/Host/index encoding invalid"; return 0;
				end
			end
			if (kind == PROJECT_RDMA_NOTIFY) begin
				project_rdma_notify_entry_t e;
				e = project_rdma_notify_entry_t'(r.entry);
				if (r.entry[127:64] != 0 || e.reserved_63_59 != 0 || e.host_id != r.owner.host_id ||
					r.owner.kind != DPU_FUNCTION_VF || r.ctx.table_index >= 256) begin
					why = "RDMA notify reserved/Host/VF/index encoding invalid"; return 0;
				end
			end
			selected.push_back(r);
		end
		if (kind inside {PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION}) begin
			foreach (frozen_messages[m]) begin
				bit covered;
				string owner_name;
				if (!scope.selects(frozen_messages[m].owner)) continue;
				owner_name = dpu_function_key_name(frozen_messages[m].owner);
				covered = frozen_msix_policies.exists(owner_name) && frozen_msix_policies[owner_name].table_only_enable;
				foreach (selected[c]) if (dpu_same_function_key(selected[c].owner, frozen_messages[m].owner)) covered = 1;
				if (!covered) begin why = "MSI-X requires explicit control or table-only enable declaration"; return 0; end
			end
		end
		if (selected.size() == 0 && (kind == PROJECT_AF ||
			(frozen_layouts.exists(kind) && frozen_layouts[kind].required))) begin
			why = {"required platform control catalog is empty: ", kind.name()}; return 0;
		end
		return 1;
	end
	foreach (functions[f]) begin
		string	name;
		if (!scope.selects(functions[f].key)) continue;
		name = dpu_function_key_name(functions[f].key);
		if (!frozen_functions.exists(name)) begin why = {"platform Function mapping missing: ", name}; return 0; end
		p = frozen_functions[name];
		if ((kind == PROJECT_PFVF || kind == PROJECT_MSIX_LINEAR) && !validate_pfvf_family(p.key, why)) return 0;
		r.owner = functions[f].key;
		r.consumers = functions[f].services;
		r.has_queue = 0;
		r.entry = '0;
		r.enable_mask = '0;
		r.enable_value = '0;
		r.dependencies.delete();
		if (kind inside {PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_TABLE}) begin
			foreach (frozen_messages[m]) begin
				project_msix_message_t	message;
				message = frozen_messages[m];
				if (!dpu_same_function_key(message.owner, r.owner)) continue;
				if (kind == PROJECT_MSIX_TABLE && frozen_msix_policies.exists(name) && frozen_msix_policies[name].table_present)
					index = message.local_vector;
				else begin
				if (!frozen_layouts.exists(kind) ||
					!(frozen_layouts[kind].index_policy inside {PROJECT_INDEX_GLOBAL_VECTOR, PROJECT_INDEX_LOCAL_VECTOR})) begin
					why = "MSI-X table requires explicit local/global vector index policy"; return 0;
				end
				index = frozen_layouts[kind].index_policy == PROJECT_INDEX_GLOBAL_VECTOR ? message.global_vector : message.local_vector;
				end
				if ((kind == PROJECT_MSIX_LINEAR && (index >= 2048 || p.pfvf >= 1024 || p.key.host_id >= 8)) ||
					(kind != PROJECT_MSIX_LINEAR && index >= 1024) ||
					(kind == PROJECT_MSIX_INFO && p.vport >= 128)) begin
					why = "MSI-X mapping exceeds screenshot capacity/reserved fields"; return 0;
				end
				case (kind)
					PROJECT_MSIX_LINEAR: begin
						project_msix_linear_entry_t	e;
						e = '0;
						e.global_msix_idx = message.global_vector;
						e.host_id = p.key.host_id;
						e.pfvf_id = p.pfvf;
						e.local_msix_idx = message.local_vector;
						r.entry = 128'(e);
					end
					PROJECT_MSIX_INFO: begin
						project_msix_info_entry_t	e;
						e = '0;
						if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].self_mask_present ||
							$isunknown(frozen_msix_policies[name].self_mask)) begin
							why = "MSI-X info requires explicit self-mask policy"; return 0;
						end
						e.self_mask = frozen_msix_policies[name].self_mask;
						e.valid = 1;
						e.host_id = p.key.host_id;
						e.function_id = p.vport;
						r.entry = 128'(e);
					end
					PROJECT_MSIX_INTERVAL: begin
							if (!frozen_msix_policies.exists(name) || !frozen_msix_policies[name].interval_present ||
								$isunknown(frozen_msix_policies[name].interval_entry)) begin
								why = "MSI-X interval requires explicit rate/packet policy"; return 0;
							end
							r.entry = 128'(frozen_msix_policies[name].interval_entry);
						end
					PROJECT_MSIX_TABLE: begin
						project_msix_table_entry_t	e;
						e = '0;
						e.msix_addr = message.address;
						e.msix_data = message.data;
						e.msix_mask = message.masked;
						r.entry = 128'(e);
					end
					default: ;
				endcase
				if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			continue;
		end
		case (kind)
			PROJECT_BDF: begin
				project_bdf_entry_t	e;
				project_ep_requester_id_t	ep;
				if (p.bdf_index >= 128 || $isunknown(p.requester)) begin why = "requester table index/encoding invalid"; return 0; end
				ep = project_ep_requester_id_t'(p.requester);
				if ((p.mode == PROJECT_HOST_SW && p.requester != functions[f].pcie_id.bdf) ||
					(p.mode == PROJECT_HOST_EP && ep.vf_valid != (p.key.kind == DPU_FUNCTION_VF))) begin why = "requester EP/SW encoding contradicts explicit route"; return 0; end
				e = '0;
				e.requester_id = p.requester;
				e.valid = 1;
				e.ecrc_en = p.ecrc;
				e.vdpa_en = p.vdpa;
				r.entry = 128'(e);
				index = p.bdf_index;
			end
			PROJECT_COMPLETION_BDF: begin
				project_completion_bdf_entry_t	e;
				if (p.mode == PROJECT_HOST_EP) continue;
				if (p.completion_index >= 4096) begin why = "Completion table index exceeds screenshot"; return 0; end
				e = '0;
				e.valid = 1;
				e.ecrc_en = p.ecrc;
				e.completion_id = functions[f].pcie_id.bdf;
				r.entry = 128'(e);
				index = p.completion_index;
			end
			PROJECT_PFVF: begin
				project_pfvf_entry_t	e;
				if (p.key.kind != DPU_FUNCTION_PF) continue;
				if (p.intel_pf >= 4 || p.first_vf_offset >= 1024) begin why = "PFVF mapping exceeds screenshot fields"; return 0; end
				e = '0;
				e.valid = 1;
				e.first_vf_offset = p.first_vf_offset;
				r.entry = 128'(e);
				index = p.intel_pf;
			end
			PROJECT_PREFIX: begin
				project_tlp_prefix_entry_t	e;
				if (!p.prefix_enabled) continue;
				if (p.prefix_index >= 256 || $isunknown(p.prefix)) begin why = "prefix invalid"; return 0; end
				e = '0;
				e.valid = 1;
				e.vdpa_en = p.vdpa;
				e.tlp_prefix = p.prefix;
				r.entry = 128'(e);
				index = p.prefix_index;
			end
			default: begin why = "category is not a public table"; return 0; end
		endcase
		if (!make_context(kind, r.owner, index, 0, r.ctx, why)) return 0;
		selected.push_back(r);
	end
	why = "";
	return 1;
endfunction

// 所有 Host 的绑定先解析，真实 ring 仅由核心 env 分配；准备失败保留已交付 Host 的视图。
task project_env::prepare_vio_configuration(output project_vio_selection_t selection, output bit ok, output string why);
	dpu_vio_qpair_binding_t	pairs[$];
	vio_external_queue_binding_t	bindings[int unsigned][$];
	vio_service_requirement_t	requirement;
	dpu_service_key_t	keys[$];
	ok = 0;
	selection.setups.delete();
	selection.scopes.delete();
	why = "public configuration must be published first";
	if (dpu_setup == null) return;
	foreach (vio_setups[h]) if (vio_setups[h] != null) begin why = "release existing VIO generation before reprepare"; return; end
	// 全部旧 ring 代释放后才冻结显式平台表策略；核心 service enabled/pairs/geometry/format 仍用 placement 前缓存合同。
	frozen_policies = cfg.vio_policies;
	dpu_env.get_resource_snapshot().list_vio_bindings(pairs);
	foreach (pairs[p]) begin
		int unsigned	h;
		h = pairs[p].service_key.function_key.host_id;
		if (!vio_envs.exists(h) || !cfg.vio_cfg_by_host.exists(h)) return;
		if (vio_envs[h] == null || cfg.vio_cfg_by_host[h] == null) return;
		if (!cfg.vio_cfg_by_host[h].resolve_final_service_requirement(pairs[p].service_key, requirement, why)) return;
		for (int direction = 0; direction < 2; direction++) begin
			vio_external_queue_binding_t	b;
			bit [64:0]	offset;
			bit	message_found;
			dpu_priv_driver_config private_cfg;
			dpu_priv_queue_config private_queue;
			if ((direction == 0 && !requirement.rx_enable) || (direction == 1 && !requirement.tx_enable)) continue;
			b.service_key = pairs[p].service_key;
			b.local_qid = direction == 0 ? pairs[p].rx_local_virtqueue_id : pairs[p].tx_local_virtqueue_id;
			private_cfg = cfg.vio_cfg_by_host[h].get_dpu_private_config(b.service_key);
			private_queue = null;
			if (requirement.behavior.vq_type == VQ_CUSTOM && private_cfg != null)
				private_queue = private_cfg.resolve_queue(b.local_qid);
			if (!requirement.notify_layout_valid && (private_queue == null || !private_queue.notify_offset_present)) begin
				why = "service/queue has no explicit doorbell binding"; return;
			end
			offset = {1'b0, requirement.notify_base} + 65'(b.local_qid) * {1'b0, requirement.notify_stride};
			if (offset[64]) begin why = "doorbell offset overflow"; return; end
			b.notify_bar = requirement.notify_bar;
			b.notify_offset = offset[63:0];
			if (private_queue != null) begin
				if (private_queue.notify_bar_present) b.notify_bar = private_queue.notify_bar;
				if (private_queue.notify_offset_present) b.notify_offset = private_queue.notify_offset;
			end
			b.notify_encoding = requirement.notify_encoding;
			b.local_vector = pairs[p].local_msix_vector_id;
			b.global_vector = pairs[p].global_msix_vector_id;
			b.msix_valid = 0;
			b.message_address = 0;
			b.message_data = 0;
			b.masked = 0;
			message_found = 0;
			foreach (frozen_messages[m]) begin
				if (dpu_same_function_key(frozen_messages[m].owner, b.service_key.function_key) &&
					frozen_messages[m].local_vector == b.local_vector) begin
					if (frozen_messages[m].global_vector != b.global_vector) begin why = "public vector disagrees with qpair binding"; return; end
					message_found = 1;
					b.msix_valid = 1;
					b.message_address = frozen_messages[m].address;
					b.message_data = frozen_messages[m].data;
					b.masked = frozen_messages[m].masked;
				end
			end
			if (requirement.completion_mode == VIRTIO_COMPLETION_MSIX && !message_found) begin why = "MSI-X service has no frozen public message"; return; end
			bindings[h].push_back(b);
		end
	end
	foreach (bindings[h]) begin
		vio_config_scope	scope;
		vio_external_setup	setup;
		vio_envs[h].prepare_external_configuration(bindings[h], setup, ok, why);
		if (!ok) return;
		vio_setups[h] = setup;
		keys.delete();
		scope = new($sformatf("vio_scope_h%0d", h), setup, keys);
		selection.setups[h] = setup;
		selection.scopes[h] = scope;
	end
	ok = 1;
	why = "";
endtask

// 所选全部 Host 共用核心只读 validator；所有检查结束前绝不确认/释放第一个 Host。
function bit project_env::preflight_vio(input project_vio_selection_t selection, output string why);
	why = "VIO selection is empty or has incomplete Host setup/scope pairs";
	if (selection.setups.num() == 0 || selection.scopes.num() != selection.setups.num()) return 0;
	foreach (selection.setups[h]) begin
		if (!vio_envs.exists(h) || !vio_setups.exists(h) || !selection.scopes.exists(h)) return 0;
		if (vio_envs[h] == null || selection.setups[h] == null ||
			selection.setups[h] != vio_setups[h] || selection.scopes[h] == null) return 0;
		if (!vio_envs[h].preflight_external_configuration(selection.setups[h], selection.scopes[h], why)) return 0;
	end
	why = "";
	return 1;
endfunction

// 队列表按真实 service/qpair/IOVA 生成；任何平台策略越界都在窄字段赋值前拒绝。
function bit project_env::queue_records(input project_vio_selection_t selection,
		input project_table_kind_e kinds[$],
	output project_config_record_t selected[$], output string why);
	vio_queue_setup_t	queues[$];
	project_vio_policy_t	policy;
	project_function_policy_t	fp;
	project_config_record_t	r;
	int unsigned	depth;
	int unsigned	pre_count;
	int unsigned	pre_start;
	int unsigned	net_id;
	int unsigned	index;
	string	service;
	selected.delete();
	if (!preflight_vio(selection, why)) return 0;
	foreach (selection.setups[h]) begin
		selection.setups[h].list_queues(queues);
		foreach (queues[q]) begin
			if (!selection.scopes[h].selects(queues[q].service_key)) continue;
			service = dpu_service_key_name(queues[q].service_key);
			if (!frozen_policies.exists(service) || !frozen_functions.exists(dpu_function_key_name(queues[q].service_key.function_key))) begin
				why = {"queue platform policy missing: ", service}; return 0;
			end
			policy = frozen_policies[service];
			fp = frozen_functions[dpu_function_key_name(queues[q].service_key.function_key)];
			if (queues[q].queue_size < 32 || queues[q].queue_size > 32768 ||
				(queues[q].queue_type == VQ_CUSTOM && queues[q].queue_size > 4096) ||
				(queues[q].queue_size & (queues[q].queue_size-1)) != 0 || fp.vport >= 1024 ||
				queues[q].qpair.global_msix_vector_id >= 8192 || queues[q].qpair.global_qpair_id >= (policy.fpga ? 512 : 2048)) begin
				why = "queue geometry/vector/vport exceeds screenshot or VIP bounds"; return 0;
			end
			depth = $clog2(queues[q].queue_size);
			r.owner = queues[q].service_key.function_key;
			r.consumers.delete();
			r.consumers.push_back(queues[q].service_key);
			r.has_queue = 1;
			r.binding = queues[q];
			r.dependencies.delete();
			foreach (kinds[k]) begin
				bit found;
				if (!(kinds[k] inside {PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX})) continue;
				found = 0;
				foreach (frozen_controls[c]) begin
					if (frozen_controls[c].ctx.kind != kinds[k] ||
						!dpu_same_function_key(frozen_controls[c].owner, r.owner)) continue;
					if (kinds[k] == PROJECT_QUEUE_AUX && frozen_controls[c].ctx.table_index != queues[q].qpair.global_qpair_id) continue;
					if ($isunknown({frozen_controls[c].value, frozen_controls[c].writable_mask}) ||
						(frozen_controls[c].value & ~frozen_controls[c].writable_mask) != 0) begin
						why = "queue control contains unknown/reserved bits"; return 0;
					end
					r.has_queue = kinds[k] == PROJECT_QUEUE_AUX;
					r.entry = frozen_controls[c].value;
					r.enable_mask = 0;
					r.enable_value = 0;
					if (!make_context(kinds[k], r.owner, frozen_controls[c].ctx.table_index,
						kinds[k] == PROJECT_QUEUE_AUX ? selection.setups[h].get_generation() : 0, r.ctx, why)) return 0;
					selected.push_back(r);
					found = 1;
				end
				if (!found && frozen_layouts.exists(kinds[k]) && frozen_layouts[kinds[k]].required) begin
					why = {"required queue control missing: ", kinds[k].name()}; return 0;
				end
			end
			r.has_queue = 1;
			r.enable_mask = 128'h1 << 68;
			r.enable_value = r.enable_mask;
			if ((queues[q].tx_mode && kind_selected(PROJECT_VTX, kinds)) ||
				(!queues[q].tx_mode && kind_selected(PROJECT_VRX, kinds))) begin
			if (queues[q].tx_mode) begin
				project_vtx_entry_t	e;
				e = policy.vtx;
				if ($isunknown(e) || e.reserved_127_112 != 0 || e.reserved_111_106 != 0 ||
					e.queue_en != 0 || e.queue_stop != 0 || (e.high_speed_mode && depth < 7) || h > 6) begin
					why = "VTX template reserved/enable/Host/high-speed constraint violated"; return 0;
				end
				e.desc_addr = queues[q].desc_iova;
				e.q_depth = depth;
				e.virtio_mode = queues[q].queue_type == VQ_PACKED;
				e.sport = h;
				e.sport_id = fp.vport;
				e.dma_msix = queues[q].qpair.global_msix_vector_id;
				r.entry = e;
				if (!make_context(PROJECT_VTX, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
			end else begin
				project_vrx_entry_t	e;
				e = policy.vrx;
				pre_count = e.dsc_pre_max_num == 0 ? 256 : e.dsc_pre_max_num == 1 ? 128 : e.dsc_pre_max_num == 2 ? 64 : e.dsc_pre_max_num == 3 ? 32 : 16;
				pre_start = policy.prefetch_start + queues[q].qpair.virtio_pair_index * pre_count;
				if ($isunknown(e) || e.reserved_127 != 0 || e.reserved_108 != 0 || e.queue_en != 0 ||
					e.dsc_mode != 0 || e.payload_dsc_len != 0 || e.head_dsc_len != 0 || h > 3 ||
					policy.prefetch_ram == "" || pre_count >= queues[q].queue_size ||
					policy.prefetch_slots != pre_count || pre_start % pre_count != 0 ||
					64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs) * pre_count > (policy.fpga ? 16384 : 32768)) begin
					why = "VRX reserved/head-split/Host/prefetch policy invalid"; return 0;
				end
				// 以全部冻结 service 的 RAM 预留检查重叠，局部 scope 不会重新从零分配。
				foreach (frozen_policies[other]) begin
					if (other != service && frozen_policies[other].prefetch_ram == policy.prefetch_ram) begin
						vio_service_requirement_t	other_requirement;
						int unsigned	oh;
						oh = frozen_policies[other].service_key.function_key.host_id;
						if (!cfg.vio_cfg_by_host.exists(oh)) return 0;
						if (cfg.vio_cfg_by_host[oh] == null) return 0;
						if (!cfg.vio_cfg_by_host[oh].resolve_final_service_requirement(frozen_policies[other].service_key, other_requirement, why)) return 0;
						if (other_requirement.enabled && other_requirement.rx_enable &&
							64'(policy.prefetch_start) < 64'(frozen_policies[other].prefetch_start) + 64'(other_requirement.behavior.num_queue_pairs)*frozen_policies[other].prefetch_slots &&
							64'(frozen_policies[other].prefetch_start) < 64'(policy.prefetch_start) + 64'(queues[q].allocated_qpairs)*pre_count) begin
							why = "VRX descriptor RAM reservations overlap across services/Hosts"; return 0;
						end
					end
				end
				e.dsc_addr = queues[q].desc_iova;
				e.q_depth = depth;
				e.virtio_mode = queues[q].queue_type == VQ_PACKED;
				e.dport = h;
				e.dport_id = fp.vport;
				e.dma_msix = queues[q].qpair.global_msix_vector_id;
				e.dma_msix_en = queues[q].completion_mode == VIRTIO_COMPLETION_MSIX;
				e.dsc_pre_read_ram_addr = pre_start;
				r.entry = e;
				if (!make_context(PROJECT_VRX, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
			end
			selected.push_back(r);
			end
			// 非 ring 表不携带 ring enable 位，独立批次与合并 verify 必须生成相同记录。
			r.enable_mask = 0;
			r.enable_value = 0;
			// Notify 是每 pair 一个单 bank 项；实际 doorbell qid 仍留在 binding，不能混作 pair 编码。
			if (kind_selected(PROJECT_NOTIFY, kinds)) begin
				project_vio_notify_entry_t	e;
				bit [63:0]	base;
				project_bar_target_t	notify_target;
				if (!policy.notify_table_base_provided || $isunknown(policy.notify_table_offset) ||
					!bar_registry.resolve_function(r.owner, policy.notify_table_bar, notify_target, why) ||
					!bar_registry.check_range(notify_target, policy.notify_table_offset, 128, base, why)) begin
					why = "notify table lookup base requires explicit owner BAR/offset"; return 0;
				end
				if (!policy.notify_net_pair5 || queues[q].qpair.virtio_pair_index >= 32 ||
					queues[q].qpair.rx_local_virtqueue_id >= 64 || queues[q].qpair.tx_local_virtqueue_id >= 64 ||
					queues[q].qpair.global_qpair_id >= 512 || base[63:61] != 0 ||
					base[6:0] != 0) begin why = "notify single-bank pair5/base/index cannot represent binding"; return 0; end
				e = '0;
				e.global_qid = queues[q].qpair.global_qpair_id;
				e.host_id = h;
				e.base_addr_60_7 = base[60:7];
				e.local_qid_encoding = (queues[q].qpair.virtio_pair_index << 1) | 1;
				r.entry = e;
				r.enable_mask = 0;
				r.enable_value = 0;
				if (!make_context(PROJECT_NOTIFY, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
				selected.push_back(r);
			end
			if (kind_selected(PROJECT_Q2TC, kinds) || kind_selected(PROJECT_N2G, kinds) || kind_selected(PROJECT_G2P, kinds)) begin
			// Q2TC/N2G/G2P 编号由显式策略生成；net/group 十位先检查再赋值。
			if (64'(policy.net_base) + 64'(queues[q].qpair.virtio_pair_index)*policy.net_stride >= 1024 ||
				policy.group_id >= 1024 || policy.cos >= 8 || policy.eth_ports + h >= 16 ||
				policy.eth_ports == 0 || (policy.ets && policy.ets_priority >= 8) || (!policy.ets && h >= 5) ||
				queues[q].qpair.global_qpair_id >= 1024) begin why = "QSCH topology exceeds declared screenshot encoding"; return 0; end
			net_id = policy.net_base + queues[q].qpair.virtio_pair_index * policy.net_stride;
			if (kind_selected(PROJECT_Q2TC, kinds)) begin
				project_qsch_q2tc_entry_t	e;
				e = '0;
				e.valid = 1;
				e.net_id = net_id;
				e.cos = policy.cos;
				r.entry = e;
				if (!make_context(PROJECT_Q2TC, r.owner, queues[q].qpair.global_qpair_id, selection.setups[h].get_generation(), r.ctx, why)) return 0;
				selected.push_back(r);
			end
			r.has_queue = 0;
			if (kind_selected(PROJECT_N2G, kinds)) begin
				project_qsch_n2g_entry_t	e;
				e = '0;
				e.valid = 1;
				e.group_id = policy.group_id;
				r.entry = e;
				if (!make_context(PROJECT_N2G, r.owner, net_id, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			if (kind_selected(PROJECT_G2P, kinds)) begin
				project_qsch_g2p_entry_t	e;
				e = '0;
				e.valid = 1;
				e.dpt = policy.eth_ports + h;
				e.lvl2_id = policy.ets ? policy.ets_priority : h;
				r.entry = e;
				if (!make_context(PROJECT_G2P, r.owner, policy.group_id, 0, r.ctx, why)) return 0;
				selected.push_back(r);
			end
			end
		end
	end
	why = "";
	return 1;
endfunction

// 小型类别集合查询，只统一遍历条件，不建立第二个 callback 引擎。
function bit project_env::kind_selected(input project_table_kind_e kind, input project_table_kind_e kinds[$]);
	foreach (kinds[i]) if (kind == kinds[i]) return 1;
	return 0;
endfunction

// 已确认资源不能被外围配置重写；状态失败不自动 reset 或释放可能仍在 DMA 的内存。
function bit project_env::record_writable(input project_config_record_t record, output string why);
	if (records.exists(record.ctx.record_key)) begin
		foreach (records[record.ctx.record_key].consumers[i]) begin
			int unsigned h;
			h = records[record.ctx.record_key].consumers[i].function_key.host_id;
			if (!vio_setups.exists(h)) continue;
			if (!vio_envs.exists(h)) begin why = "table consumer Host is missing"; return 0; end
			if (vio_envs[h] == null) begin why = "table consumer Host is null"; return 0; end
			if (vio_envs[h].external_service_confirmed(vio_setups[h], records[record.ctx.record_key].consumers[i])) begin
				why = "shared table dependency belongs to confirmed resources";
				return 0;
			end
		end
	end
	foreach (record.consumers[i]) begin
		int unsigned	h;
		h = record.consumers[i].function_key.host_id;
		if (!vio_setups.exists(h)) continue;
		if (!vio_envs.exists(h)) begin why = "table consumer Host is missing"; return 0; end
		if (vio_envs[h] == null) begin why = "table consumer Host is null"; return 0; end
		if (vio_envs[h].external_service_confirmed(vio_setups[h], record.consumers[i])) begin
			why = "table dependency belongs to confirmed resources; stop/quiesce/release before rewriting";
			return 0;
		end
	end
	why = "";
	return 1;
endfunction

// 完整 scope/类别集合预检，随后统一登记再逐项执行；hook 失败立即停止且保留全部 DMA。
task project_env::configure_public(input project_table_kind_e kinds[$],
	input project_dpu_config_scope scope, output bit ok, output string why);
	project_config_record_t	selected[$];
	project_config_record_t	batch[$];
	bit	seen[string];
	ok = 0;
	configuration_lock.get();
	foreach (kinds[k]) begin
		if (!public_records(kinds[k], scope, selected, why)) begin configuration_lock.put(); return; end
		foreach (selected[i]) begin
			if (!record_writable(selected[i], why)) begin configuration_lock.put(); return; end
			batch.push_back(selected[i]);
		end
	end
	foreach (batch[i]) if (!remember_record(batch[i], why)) begin configuration_lock.put(); return; end
	foreach (batch[i]) begin
		string	key;
		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		configured[key] = 0;
		verified[key] = 0;
		dispatch_record(records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			configuration_lock.put();
			return;
		end
		configured[key] = 1;
	end
	configuration_lock.put();
	ok = 1;
	why = "";
endtask

// queue_records 仅生成所请求类别，共享表按实际 key 去重，TX-only 不调用 RX hook。
task project_env::configure_queues(input project_table_kind_e kinds[$],
	input project_vio_selection_t selection, output bit ok, output string why);
	project_config_record_t	batch[$];
	bit	seen[string];
	ok = 0;
	configuration_lock.get();
	if (!queue_records(selection, kinds, batch, why)) begin configuration_lock.put(); return; end
	foreach (batch[i]) begin
		if (!record_writable(batch[i], why) || !remember_record(batch[i], why)) begin configuration_lock.put(); return; end
	end
	foreach (batch[i]) begin
		string	key;
		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		configured[key] = 0;
		verified[key] = 0;
		dispatch_record(records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			configuration_lock.put();
			return;
		end
		configured[key] = 1;
	end
	configuration_lock.put();
	ok = 1;
	why = "";
endtask

// 依赖从实际账本查找；空集合不能代表成功，同类共享项按消费者和 frozen qpair 匹配。
function bit project_env::dependencies_ready(input project_config_record_t queue, output string why);
	project_table_kind_e	needed[$];
	project_function_policy_t	fp;
	bit	found;
	needed = '{PROJECT_BAR, PROJECT_BDF, PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P};
	needed.push_back(queue.ctx.kind);
	foreach (frozen_layouts[kind])
		if (frozen_layouts[kind].required && kind inside {PROJECT_AF, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION}) needed.push_back(kind);
	if (!frozen_functions.exists(dpu_function_key_name(queue.owner))) begin why = "missing Function policy"; return 0; end
	fp = frozen_functions[dpu_function_key_name(queue.owner)];
	if (fp.mode == PROJECT_HOST_SW) needed.push_back(PROJECT_COMPLETION_BDF);
	if (fp.prefix_enabled) needed.push_back(PROJECT_PREFIX);
	if (queue.owner.kind == DPU_FUNCTION_VF) needed.push_back(PROJECT_PFVF);
	if (queue.binding.completion_mode == VIRTIO_COMPLETION_MSIX) begin
		needed.push_back(PROJECT_MSIX_LINEAR);
		needed.push_back(PROJECT_MSIX_INFO);
		needed.push_back(PROJECT_MSIX_INTERVAL);
		needed.push_back(PROJECT_MSIX_TABLE);
	end
	// BAR 依赖覆盖该 Function 的每个实际声明组，不能由任意一个组冒充全部。
	foreach (frozen_bar_groups[g]) begin
		bit related;
		string key;
		related = 0;
		foreach (frozen_bar_groups[g].members[m])
			if (dpu_same_function_key(frozen_bar_groups[g].members[m].function_key, queue.owner)) related = 1;
		if (!related) continue;
		key = $sformatf("BAR:%0d", g);
		if (!records.exists(key) || !((configured.exists(key) && configured[key]) || (verified.exists(key) && verified[key]))) begin
			why = {"required BAR group absent/unconfirmed: ", key}; return 0;
		end
	end
	foreach (needed[k]) begin
		found = 0;
		foreach (records[name]) begin
			bit	related;
			if (records[name].ctx.kind != needed[k]) continue;
			related = dpu_same_function_key(records[name].owner, queue.owner);
			if (needed[k] inside {PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) begin
				related = 0;
				foreach (records[name].consumers[c])
					if (dpu_service_key_name(records[name].consumers[c]) == dpu_service_key_name(queue.binding.service_key)) related = 1;
			end
			if (needed[k] == PROJECT_PFVF)
				related = records[name].owner.host_id == queue.owner.host_id && records[name].owner.pf_id == queue.owner.pf_id && records[name].owner.kind == DPU_FUNCTION_PF;
			if (needed[k] == PROJECT_BAR) begin
				related = 0;
				foreach (frozen_bar_groups[records[name].ctx.table_index].members[m])
					if (dpu_same_function_key(frozen_bar_groups[records[name].ctx.table_index].members[m].function_key, queue.owner)) related = 1;
			end
			if (records[name].has_queue && needed[k] inside {PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX})
				related &= dpu_service_key_name(records[name].binding.service_key) == dpu_service_key_name(queue.binding.service_key) &&
					records[name].binding.qpair.global_qpair_id == queue.binding.qpair.global_qpair_id;
			if (!related) continue;
			if (!((configured.exists(name) && configured[name]) || (verified.exists(name) && verified[name]))) begin
				why = {"dependency not configured/verified: ", name}; return 0;
			end
			found = 1;
		end
		if (!found) begin why = {"required category absent: ", needed[k].name()}; return 0; end
	end
	why = "";
	return 1;
endfunction

// 使能前所有队列依赖一起检查；单项 hook 成功不自动确认 READY。
task project_env::enable_vio_queues(input project_vio_selection_t selection, output bit ok, output string why);
	project_config_record_t	batch[$];
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX};
	project_queue_control_cfg_t	item;
	ok = 0;
	configuration_lock.get();
	if (!queue_records(selection, kinds, batch, why)) begin configuration_lock.put(); return; end
	foreach (batch[i]) begin
		if (!remember_record(batch[i], why) || !dependencies_ready(batch[i], why) || !record_writable(batch[i], why)) begin configuration_lock.put(); return; end
	end
	foreach (batch[i]) begin
		item.ctx = batch[i].ctx;
		item.binding = batch[i].binding;
		item.value = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		item.writable_mask = batch[i].enable_mask;
		enabled[batch[i].ctx.record_key] = 0;
		verified[batch[i].ctx.record_key] = 0;
		user_enable_queue(item, ok, why);
		if (!ok) begin configuration_lock.put(); return; end
		enabled[batch[i].ctx.record_key] = 1;
	end
	configuration_lock.put();
	ok = 1;
	why = "";
endtask

// 平台已配置公共表可独立验证；仅标记当前 scope 的完整记录，不清除其他类别结果。
task project_env::verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
	project_config_record_t	batch[$];
	project_config_record_t	part[$];
	project_table_kind_e	kinds[$] = '{PROJECT_BAR, PROJECT_BDF, PROJECT_PFVF, PROJECT_COMPLETION_BDF, PROJECT_PREFIX};
	string revoke_why;
	bit revoked;
	ok = 0;
	configuration_lock.get();
	if (!revoke_public(scope, 0, why)) begin configuration_lock.put(); return; end
	if (frozen_messages.size() != 0) begin
		kinds.push_back(PROJECT_MSIX_LINEAR);
		kinds.push_back(PROJECT_MSIX_INFO);
		kinds.push_back(PROJECT_MSIX_INTERVAL);
		kinds.push_back(PROJECT_MSIX_TABLE);
	end
	foreach (frozen_layouts[kind])
		if (frozen_layouts[kind].required && kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION}) kinds.push_back(kind);
	foreach (kinds[k]) begin
		if (!scope.selects_kind(kinds[k])) continue;
		if (!public_records(kinds[k], scope, part, why)) begin configuration_lock.put(); return; end
		foreach (part[i]) batch.push_back(part[i]);
	end
	if (batch.size() == 0) begin why = "verification scope has no selected public records"; configuration_lock.put(); return; end
	foreach (batch[i]) if (!remember_record(batch[i], why)) begin configuration_lock.put(); return; end
	user_verify_dpu_configuration(scope, ok, why);
	foreach (batch[i]) verified[batch[i].ctx.record_key] = ok;
	if (!ok) revoked = revoke_public(scope, 1, revoke_why);
	configuration_lock.put();
endtask

// 公共验证失败沿实际消费者反查 VIO，只撤销当前有效 scope 相关的已发放会话。
function bit project_env::revoke_public(input project_dpu_config_scope scope, input bit apply, output string why);
	project_vio_selection_t selection;
	vio_queue_setup_t rows[$];
	if (scope == null) return 0;
	if (!scope.validate(dpu_setup, why)) return 0;
	foreach (vio_setups[h]) begin
		dpu_service_key_t keys[$];
		bit seen[string];
		if (vio_setups[h] == null) return 0;
		if (!vio_envs.exists(h)) return 0;
		if (vio_envs[h] == null) return 0;
		vio_setups[h].list_queues(rows);
		foreach (rows[q]) begin
			bit affected;
			string service;
			service = dpu_service_key_name(rows[q].service_key);
			affected = scope.selects(rows[q].service_key.function_key);
			foreach (records[r]) begin
				if (!scope.selects_kind(records[r].ctx.kind) || !scope.selects(records[r].owner)) continue;
				foreach (records[r].consumers[c]) if (dpu_service_key_name(records[r].consumers[c]) == service) affected = 1;
				if (records[r].ctx.kind == PROJECT_PFVF && records[r].owner.host_id == h &&
					records[r].owner.pf_id == rows[q].service_key.function_key.pf_id) affected = 1;
			end
			if (affected && !seen.exists(service)) begin keys.push_back(rows[q].service_key); seen[service] = 1; end
		end
		if (keys.size() != 0) begin
			selection.setups[h] = vio_setups[h];
			selection.scopes[h] = new("public_failure_scope", vio_setups[h], keys);
		end
	end
	if (selection.setups.num() == 0) return 1;
	foreach (selection.setups[h])
		if (!vio_envs[h].preflight_external_revocation(selection.setups[h], selection.scopes[h], why)) return 0;
	if (!apply) return 1;
	return revoke_vio(selection, why);
endfunction

// 所有 Host 认证并确认停止后再撤销；损坏几何不妨碍关闭原参与者门禁。
function bit project_env::revoke_vio(input project_vio_selection_t selection, output string why);
	if (selection.setups.num() == 0 || selection.setups.num() != selection.scopes.num()) return 0;
	foreach (selection.setups[h]) begin
		if (!vio_envs.exists(h) || !selection.scopes.exists(h)) return 0;
		if (vio_envs[h] == null || selection.setups[h] == null || selection.scopes[h] == null) return 0;
		if (!vio_envs[h].preflight_external_revocation(selection.setups[h], selection.scopes[h], why)) return 0;
	end
	foreach (selection.setups[h])
		if (!vio_envs[h].revoke_external_configuration(selection.setups[h], selection.scopes[h], why)) return 0;
	foreach (records[key]) foreach (records[key].consumers[c]) begin
		int unsigned h;
		h = records[key].consumers[c].function_key.host_id;
		if (!selection.scopes.exists(h)) continue;
		if (selection.scopes[h] == null) continue;
		if (selection.scopes[h].selects(records[key].consumers[c])) begin
			verified[key] = 0;
			enabled[key] = 0;
		end
	end
	return 1;
endfunction

// 独立 VIO verify 可确认平台已配置的完整队列范围；核心完整性检查发生在 hook 前后。
task project_env::verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	project_config_record_t	batch[$];
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX, PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX};
	string revoke_why;
	bit revoked;
	ok = 0;
	configuration_lock.get();
	if (!queue_records(selection, kinds, batch, why)) begin
		revoked = revoke_vio(selection, revoke_why);
		configuration_lock.put(); return;
	end
	foreach (batch[i]) if (!remember_record(batch[i], why)) begin
		revoked = revoke_vio(selection, revoke_why);
		configuration_lock.put(); return;
	end
	user_verify_vio_configuration(selection, ok, why);
	if (ok) ok = preflight_vio(selection, why);
	foreach (batch[i]) begin
		verified[batch[i].ctx.record_key] = ok;
		if (batch[i].ctx.kind inside {PROJECT_VTX, PROJECT_VRX}) enabled[batch[i].ctx.record_key] = ok;
	end
	if (!ok) revoked = revoke_vio(selection, revoke_why);
	configuration_lock.put();
endtask

// 所有 Host/队列依赖与 verify 先完整检查，再在不推进时间的函数内逐 Host 提交。
function void project_env::commit_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
	project_config_record_t	batch[$];
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX};
	ok = 0;
	if (checked_writes_active != 0) begin why = "checked table writes still in flight"; return; end
	if (!queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) begin
		string	key;
		key = batch[i].ctx.record_key;
		if (!dependencies_ready(batch[i], why)) return;
		if (!enabled.exists(key) || !enabled[key] || !verified.exists(key) || !verified[key]) begin
			why = {"queue not enabled and verified: ", key}; return;
		end
	end
	foreach (selection.setups[h]) begin
		if (!vio_envs[h].confirm_external_configuration(selection.setups[h], selection.scopes[h], 1, why)) return;
	end
	ok = 1;
	why = "";
endfunction

// 核心 release 为整 Host 代；拒绝局部 service scope，全部 Host 预检后才释放任何资源。
function void project_env::release_vio_resources(input project_vio_selection_t selection, input logic dut_quiesced, output bit ok, output string why);
	vio_queue_setup_t	queues[$];
	string	remove_keys[$];
	ok = 0;
	why = "release needs explicit platform quiescence";
	if (dut_quiesced !== 1'b1 || !preflight_vio(selection, why)) return;
	foreach (selection.setups[h]) begin
		selection.setups[h].list_queues(queues);
		foreach (queues[q]) if (!selection.scopes[h].selects(queues[q].service_key)) begin why = "release must select complete Host generation"; return; end
		if (!vio_envs[h].preflight_external_configuration(selection.setups[h], null, why)) return;
	end
	foreach (selection.setups[h]) begin
		if (!vio_envs[h].release_external_resources(selection.setups[h], dut_quiesced, why)) return;
		vio_setups.delete(h);
	end
	foreach (records[name]) begin
		if (records[name].ctx.kind inside {PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) begin
			for (int c = records[name].consumers.size()-1; c >= 0; c--)
				if (selection.setups.exists(records[name].consumers[c].function_key.host_id)) records[name].consumers.delete(c);
			if (records[name].consumers.size() == 0) remove_keys.push_back(name);
		end else if (records[name].has_queue && selection.setups.exists(records[name].owner.host_id)) remove_keys.push_back(name);
	end
	foreach (remove_keys[i]) begin
		records.delete(remove_keys[i]);
		configured.delete(remove_keys[i]);
		verified.delete(remove_keys[i]);
		enabled.delete(remove_keys[i]);
	end
	ok = 1;
	why = "";
endfunction

// queue enable 只能更新已声明的 enable 位，依赖未完成或副本变化在发包前拒绝。
task project_env::write_enabled_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
	project_config_record_t	r;
	ok = 0;
	why = "queue enable has no frozen typed record";
	if (!records.exists(item.ctx.record_key)) return;
	r = records[item.ctx.record_key];
	if (!r.has_queue || !(r.ctx.kind inside {PROJECT_VTX, PROJECT_VRX}) ||
		item.writable_mask !== r.enable_mask || !dependencies_ready(r, why)) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 1, ok, why);
endtask

// 只允许状态类别，调用者必须显式提供实测 PBA 容量和各自模块偏移。
function bit project_env::get_state_context(input project_table_kind_e kind, input dpu_function_key_t owner,
	input int unsigned index, output project_state_query_t item, output string why);
	why = "not a readable state category";
	if (!(kind inside {PROJECT_MSIX_PBA, PROJECT_MSIX_STAT, PROJECT_PFVF_DROP})) return 0;
	item.owner = owner;
	return make_context(kind, owner, index, 0, item.ctx, why);
endfunction

// PBA 是只读字；读取整个64位值，不把总容量从结构体宽度推断出来。
task project_env::read_msix_pba(input project_state_query_t item, output project_msix_pba_word_t value, output bit ok, output string why);
	project_state_query_t	canonical;
	logic [127:0]	data;
	ok = 0;
	value = '0;
	if (!get_state_context(PROJECT_MSIX_PBA, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "PBA context differs from frozen layout"; return; end
	mmio(item.ctx.target, 0, item.ctx.byte_offset, 8, 0, 0, data, ok, why);
	if (ok) value.pending = data[63:0];
endtask

// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_env::read_msix_stat(input project_state_query_t item, output project_msix_stat_t value, output bit ok, output string why);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!get_state_context(PROJECT_MSIX_STAT, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_msix_stat(item, value, ok, why);
endtask

// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_env::user_read_msix_stat(input project_state_query_t item, output project_msix_stat_t value, output bit ok, output string why);
	value = '0;
	ok = 0;
	why = "required user_read_msix_stat is not implemented";
endtask

// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_env::read_pfvf_drop_status(input project_state_query_t item, output project_pfvf_drop_status_t value, output bit ok, output string why);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_pfvf_drop_status(item, value, ok, why);
endtask

// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_env::user_read_pfvf_drop_status(input project_state_query_t item, output project_pfvf_drop_status_t value, output bit ok, output string why);
	value = '0;
	ok = 0;
	why = "required user_read_pfvf_drop_status is not implemented";
endtask

// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
task project_env::clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t item, output bit ok, output string why);
	project_state_query_t	canonical;
	ok = 0;
	if (!get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx || $isunknown(item.entry)) begin why = "invalid W1C context/mask"; return; end
	user_clear_pfvf_drop_status(item, ok, why);
endtask

// 清除由用户显式执行；不把读出的 status 自动回写。
task project_env::user_clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t item, output bit ok, output string why);
	ok = 0;
	why = "required user_clear_pfvf_drop_status is not implemented";
endtask

// 同 PF 完整成员和实际 BDF/路由交付平台；缺映射/角色错误在调用纯规则前拒绝。
function bit project_env::validate_pfvf_family(input dpu_function_key_t owner, output string why);
	project_function_record_t	functions[$];
	project_pfvf_relationship_t	family;
	dpu_setup.list_functions(functions);
	foreach (functions[i]) begin
		string	name;
		if (functions[i].key.host_id != owner.host_id || functions[i].key.pf_id != owner.pf_id) continue;
		name = dpu_function_key_name(functions[i].key);
		if (!frozen_functions.exists(name)) begin why = "PFVF family lacks explicit routing policy"; return 0; end
		if (frozen_functions[name].pfvf >= 1024 || frozen_functions[name].first_vf_offset >= 1024) begin
			why = "PFVF family field exceeds screenshot width"; return 0;
		end
		family.functions.push_back(functions[i]);
		family.policies.push_back(frozen_functions[name]);
	end
	if (family.functions.size() == 0) begin why = "PFVF family is empty"; return 0; end
	return cfg.validate_pfvf_relationship(family, why);
endfunction
