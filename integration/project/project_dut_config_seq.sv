// integration/project：可直接 start 的 DUT 表配置 sequence，使用同一个 project_env_cfg。
// 依赖 cfg 中的真实 BAR/队列视图与 PCIe RC sequencer；不创建第二套 context 或 env。
// task/hook 属于本 sequence，cfg 保存参数、资源与表项数据；ring/BAR 不归 seq 所有。
// 所有硬件访问复用 pcie_tl_reg_seq，经实际目标 RC、Intel bind 发往 DUT。
// 默认 body 配置公共表和 VIO 后验证/提交；未知平台 hook 明确失败并保留 DMA 资源。
class project_dut_config_seq extends uvm_sequence #(pcie_tl_tlp);
	`uvm_object_utils(project_dut_config_seq)

	project_env_cfg		cfg;
	project_vio_selection_t	selection;
	bit			success;
	string			error_msg;

	// 对象只保存本次执行结果；运行期共享状态始终在 cfg，不随 sequence 销毁。
	extern function new(
		string	name = "project_dut_config_seq"
	);

	// start 时取得配置句柄；派生 body 自动获得 cfg，不需要调用 env 的配置 task。
	extern virtual task pre_start();

	// 默认完整配置流程；平台先等待复位就绪，成功只在最终验证/commit 后发布。
	extern virtual task body();


	// MMIO helper 校验四态输入和完整范围，posted success 仅表示发送完成。
	extern task pcie_bar_write(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		input logic [31:0]		byte_skip_mask,
		output bit			ok,
		output string			why
	);

	// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
	extern task pcie_bar_read(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]		data,
		output bit			ok,
		output string			why
	);

	// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
	extern task pcie_bar_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		input logic [31:0]	byte_skip_mask,
		output bit		ok,
		output string		why
	);

	// 名字解析与实际 Function API 复用同一个范围/格式检查。
	extern task pcie_bar_read_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [31:0]	byte_skip_mask,
		output logic [127:0]	data,
		output bit		ok,
		output string		why
	);

	// 用户自定义表按高 DWORD 到低 DWORD 写；完整预检后发送，失败立即停止。
	// 不隐含控制触发或读回；在配置 sequence 内按所需顺序调用。
	extern task pcie_table_write_by_name(
		input string		name,
		input logic [63:0]	offset,
		input int unsigned	length,
		input logic [127:0]	data,
		output bit		ok,
		output string		why
	);

	// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
	extern task pcie_poll_bar(
		input dpu_function_key_t	owner,
		input int unsigned		bar_id,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		mask,
		input logic [127:0]		expected,
		input int unsigned		attempts,
		input time			interval,
		output bit			ok,
		output string			why
	);

	// typed helper 在首笔发送前校验完整表项，随后顺序发送所有 DWORD。
	extern protected task checked_write(
		input project_config_record_t	record,
		input logic [127:0]		value,
		input bit			enabling,
		output bit			ok,
		output string			why
	);

	// 全部四态检查在两态 registry/sequence 转换前执行，保留小端 byte lane 和 skip-mask 语义。
	extern protected task mmio(
		input project_bar_target_t	target,
		input bit			writing,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		input logic [31:0]		byte_skip_mask,
		output logic [127:0]		result,
		output bit			ok,
		output string			why
	);

	// 统一表项写序；保留原始 mmio 的宽度/掩码语义，禁止先发送再发现越界。
	extern protected task write_table_dwords(
		input project_bar_target_t	target,
		input logic [63:0]		offset,
		input int unsigned		length,
		input logic [127:0]		data,
		output bit			ok,
		output string			why
	);

	// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
	extern task write_control(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
	extern task write_queue_aux(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
	extern protected task dispatch_record(
		input project_config_record_t	record,
		output bit			ok,
		output string			why
	);

	// 先生成所选公共表，再逐项调用用户 hook；同一硬件项只写一次，失败立即停止。
	extern protected task configure_public(
		input project_table_kind_e	kinds[$],
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 按实际 service/qpair 遍历；共享 QSCH 项去重，TX-only 不生成 VRX 写入。
	extern protected task configure_queues(
		input project_table_kind_e	kinds[$],
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 独立 configure_bar_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bar_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_af 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_af(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_pf_vf_map 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_pf_vf_map(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_bdf_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_completion_bdf_table 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_completion_bdf_table(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_tlp_prefix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_tlp_prefix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_msix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 enable_msix 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task enable_msix(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_rdma_notify 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_rdma_notify(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_qsch_rnet 入口；完整预检本 scope 后才调用对应单项 hook。
	extern task configure_qsch_rnet(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 独立 configure_vio_notify 入口；不隐含调用其他类别。
	extern task configure_vio_notify(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 独立 configure_qsch 入口；不隐含调用其他类别。
	extern task configure_qsch(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 独立 configure_vio_queues 入口；不隐含调用其他类别。
	extern task configure_vio_queues(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 使能和验证分别执行；任何必需类别失败均保留 DMA 并阻止提交。
	extern task enable_vio_queues(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 公共配置写完后交由平台读回或检查状态；不将 posted 发送完成当成硬件生效。
	extern task verify_dpu_configuration(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 队列配置写完后执行平台验证；成功后默认 body 才调用 cfg.commit_vio_configuration。
	extern task verify_vio_configuration(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 bdf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_bdf_entry(
		input project_bdf_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_bdf(
		input project_bdf_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 单项用户实现 completion_bdf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_completion_bdf_entry(
		input project_completion_bdf_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_completion_bdf(
		input project_completion_bdf_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 单项用户实现 pfvf，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_pf_vf_entry(
		input project_pfvf_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_pfvf(
		input project_pfvf_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 tlp_prefix，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_tlp_prefix_entry(
		input project_tlp_prefix_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_tlp_prefix(
		input project_tlp_prefix_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 msix_linear，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_linear_entry(
		input project_msix_linear_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_linear(
		input project_msix_linear_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 msix_info，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_info_entry(
		input project_msix_info_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_info(
		input project_msix_info_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 msix_interval，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_interval_entry(
		input project_msix_interval_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_interval(
		input project_msix_interval_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 单项用户实现 msix_table，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_msix_table_entry(
		input project_msix_table_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_msix_table(
		input project_msix_table_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 qsch_q2tc，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_q2tc(
		input project_qsch_q2tc_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_q2tc(
		input project_qsch_q2tc_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 qsch_n2g，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_n2g(
		input project_qsch_n2g_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_n2g(
		input project_qsch_n2g_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 qsch_g2p，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_g2p(
		input project_qsch_g2p_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_g2p(
		input project_qsch_g2p_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 rdma_notify，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_rdma_notify_entry(
		input project_rdma_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_rdma_notify(
		input project_rdma_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 qsch_rnet，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_qsch_rnet_entry(
		input project_qsch_rnet_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_qsch_rnet(
		input project_qsch_rnet_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 单项用户实现 vtx，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vtx_queue(
		input project_vtx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vtx(
		input project_vtx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 单项用户实现 vrx，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vrx_queue(
		input project_vrx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vrx(
		input project_vrx_cfg_t	item,
		output bit		ok,
		output string		why
	);

	// 单项用户实现 vio_notify，缺失实现明确失败；推荐调用 checked typed helper。
	extern virtual task user_configure_vio_notify_entry(
		input project_vio_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 在发送前核对 ctx/binding/entry 与本代原件；不会把任意 raw 认作合法表项。
	extern task write_vio_notify(
		input project_vio_notify_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_prepare_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_af(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_control_entry(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_msix_function(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_qsch_spwrr(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_qsch_tc_weight(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_configure_queue_aux(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_enable_queue(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_quiesce_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 平台专有控制由用户实现，未知地址/语义不能默认成功。
	extern virtual task user_reset_device(
		input project_control_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// BAR 映射必须接收完整原子组，不能推测连续 VF 窗口。
	extern virtual task user_configure_bar_mapping_entry(
		input project_bar_mapping_cfg_t	item,
		output bit			ok,
		output string			why
	);

	// 验证平台已有配置允许独立于写入入口调用；成功只确认传入 scope。
	extern virtual task user_verify_dpu_configuration(
		input project_dpu_config_scope	scope,
		output bit			ok,
		output string			why
	);

	// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
	extern virtual task user_verify_vio_configuration(
		input project_vio_selection_t	selection,
		output bit			ok,
		output string			why
	);

	// 使能专用 checked 入口，只允许冻结 enable 位变化并完整核对 ring 绑定。
	extern task write_enabled_queue(
		input project_queue_control_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 只读状态查询与明确 W1C 清除保持独立，不隐含写入配置表。
	extern task read_msix_pba(
		input project_state_query_t	item,
		output project_msix_pba_word_t	value,
		output bit			ok,
		output string			why
	);

	// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
	extern task read_msix_stat(
		input project_state_query_t	item,
		output project_msix_stat_t	value,
		output bit			ok,
		output string			why
	);

	// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
	extern task read_pfvf_drop_status(
		input project_state_query_t		item,
		output project_pfvf_drop_status_t	value,
		output bit				ok,
		output string				why
	);

	// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
	extern task clear_pfvf_drop_status(
		input project_pfvf_drop_clear_cfg_t	item,
		output bit				ok,
		output string				why
	);

	// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
	extern virtual task user_read_msix_stat(
		input project_state_query_t	item,
		output project_msix_stat_t	value,
		output bit			ok,
		output string			why
	);

	// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
	extern virtual task user_read_pfvf_drop_status(
		input project_state_query_t		item,
		output project_pfvf_drop_status_t	value,
		output bit				ok,
		output string				why
	);

	// 清除由用户显式执行；不把读出的 status 自动回写。
	extern virtual task user_clear_pfvf_drop_status(
		input project_pfvf_drop_clear_cfg_t	item,
		output bit				ok,
		output string				why
	);
endclass


// 构造 sequence 外壳，不读取参数，不访问 DUT。
function project_dut_config_seq::new(
	string	name
);
	super.new(name);
endfunction

// UVM 即使 start(..., call_pre_post=0) 也调用 pre_start，故派生 body 可直接使用 cfg。
task project_dut_config_seq::pre_start();
	success = 0;
	error_msg = "";
	if (m_sequencer == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "start configuration on the project's PCIe RC sequencer")
	end
	if (!uvm_config_db#(project_env_cfg)::get(m_sequencer, "", "env_cfg", cfg) || cfg == null) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "PCIe sequencer has no env_cfg")
	end
	if (!cfg.runtime_ready) begin
		`uvm_fatal("PROJECT_CONFIG_SEQ", "env connect must finish before configuration")
	end
endtask

// 用户 task 只处理单项；类别循环、真实路由和状态均复用现有 checked 路径。
// 第一个失败立即返回，保留现场；不自动 reset、回收 ring 或继续发包。
task project_dut_config_seq::body();
	project_dpu_config_scope	public_scope;
	dpu_function_key_t		functions[$];
	int unsigned			bars[$];
	bit				ok;

	public_scope = new("public_scope", cfg.dpu_setup, functions, bars);
	configure_bar_table(public_scope, ok, error_msg);
	if (!ok) return;
	if (cfg.frozen_layouts.exists(PROJECT_AF)) begin
		configure_af(public_scope, ok, error_msg);
		if (!ok) return;
	end
	configure_pf_vf_map(public_scope, ok, error_msg);
	if (!ok) return;
	configure_bdf_table(public_scope, ok, error_msg);
	if (!ok) return;
	configure_completion_bdf_table(public_scope, ok, error_msg);
	if (!ok) return;
	configure_tlp_prefix(public_scope, ok, error_msg);
	if (!ok) return;
	configure_msix(public_scope, ok, error_msg);
	if (!ok) return;
	verify_dpu_configuration(public_scope, ok, error_msg);
	if (!ok) return;

	cfg.prepare_vio_configuration(selection, ok, error_msg);
	if (!ok) return;
	if (selection.setups.num() != 0) begin
		configure_vio_notify(selection, ok, error_msg);
		if (!ok) return;
		configure_qsch(selection, ok, error_msg);
		if (!ok) return;
		configure_vio_queues(selection, ok, error_msg);
		if (!ok) return;
		enable_vio_queues(selection, ok, error_msg);
		if (!ok) return;
		enable_msix(public_scope, ok, error_msg);
		if (!ok) return;
		verify_vio_configuration(selection, ok, error_msg);
		if (!ok) return;
		cfg.commit_vio_configuration(selection, ok, error_msg);
		if (!ok) return;
	end
	success = 1;
	error_msg = "";
endtask

// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_bar_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_BAR};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_af(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_AF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_pf_vf_map(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_PFVF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_bdf_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_BDF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_completion_bdf_table(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_COMPLETION_BDF};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_tlp_prefix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_PREFIX};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_msix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_CONTROL, PROJECT_MSIX_TABLE};
	configure_public(kinds, scope, ok, why);
endtask


// 在配置顺序中执行 MSI-X Function 使能；真实控制项由平台声明。
task project_dut_config_seq::enable_msix(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_MSIX_FUNCTION};

	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_rdma_notify(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_RDMA_NOTIFY};
	configure_public(kinds, scope, ok, why);
endtask


// 只调用本类别的完整预检与执行，不串联其他配置入口。
task project_dut_config_seq::configure_qsch_rnet(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_RNET};
	configure_public(kinds, scope, ok, why);
endtask


// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_dut_config_seq::configure_vio_notify(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_NOTIFY};
	configure_queues(kinds, selection, ok, why);
endtask


// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_dut_config_seq::configure_qsch(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT};
	configure_queues(kinds, selection, ok, why);
endtask


// 本批次共享项按真实表地址去重，调用前完成全部 scope 预检。
task project_dut_config_seq::configure_vio_queues(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_table_kind_e	kinds[$] = '{PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX};
	configure_queues(kinds, selection, ok, why);
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_bdf_entry(
	input project_bdf_cfg_t	item,
	output bit		ok,
	output string		why
);
	ok = 0;
	why = "required user_configure_bdf_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_completion_bdf_entry(
	input project_completion_bdf_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_configure_completion_bdf_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_pf_vf_entry(
	input project_pfvf_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_pf_vf_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_tlp_prefix_entry(
	input project_tlp_prefix_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_tlp_prefix_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_msix_linear_entry(
	input project_msix_linear_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_linear_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_msix_info_entry(
	input project_msix_info_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_info_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_msix_interval_entry(
	input project_msix_interval_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_configure_msix_interval_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_msix_table_entry(
	input project_msix_table_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_table_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_qsch_q2tc(
	input project_qsch_q2tc_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_q2tc is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_qsch_n2g(
	input project_qsch_n2g_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_n2g is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_qsch_g2p(
	input project_qsch_g2p_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_g2p is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_rdma_notify_entry(
	input project_rdma_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_rdma_notify_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_qsch_rnet_entry(
	input project_qsch_rnet_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_rnet_entry is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_vtx_queue(
	input project_vtx_cfg_t	item,
	output bit		ok,
	output string		why
);
	ok = 0;
	why = "required user_configure_vtx_queue is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_vrx_queue(
	input project_vrx_cfg_t	item,
	output bit		ok,
	output string		why
);
	ok = 0;
	why = "required user_configure_vrx_queue is not implemented";
endtask


// 用户必须覆写本单项 hook；base 返回失败，不能把未实现配置记成成功。
task project_dut_config_seq::user_configure_vio_notify_entry(
	input project_vio_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_vio_notify_entry is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_prepare_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_prepare_device is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_af(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_af is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_msix_control_entry(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_control_entry is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_msix_function(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_msix_function is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_qsch_spwrr(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_spwrr is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_qsch_tc_weight(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_qsch_tc_weight is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_configure_queue_aux(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_configure_queue_aux is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_enable_queue(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_enable_queue is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_quiesce_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_quiesce_device is not implemented";
endtask


// 平台控制语义未定义；用户实现后才能报告成功，不自动调用旧 reset/init。
task project_dut_config_seq::user_reset_device(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_reset_device is not implemented";
endtask


// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_dut_config_seq::user_configure_bar_mapping_entry(
	input project_bar_mapping_cfg_t	item,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_configure_bar_mapping_entry is not implemented";
endtask


// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_dut_config_seq::user_verify_dpu_configuration(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_verify_dpu_configuration is not implemented";
endtask


// 用户显式验证平台行为；默认失败，不以 posted send 代替设备确认。
task project_dut_config_seq::user_verify_vio_configuration(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "required user_verify_vio_configuration is not implemented";
endtask


// 全部四态检查在两态 registry/sequence 转换前执行，保留小端 byte lane 和 skip-mask 语义。
task project_dut_config_seq::mmio(
	input project_bar_target_t	target,
	input bit			writing,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]		result,
	output bit			ok,
	output string			why
);
	pcie_tl_reg_seq	seq;
	bit [63:0]	address;
	ok = 0;
	result = '0;
	why = "MMIO contains X/Z, unsupported width/alignment or skip-mask";
	if ($isunknown({offset, data, byte_skip_mask}) || !(length inside {4,8,12,16}) ||
		offset[1:0] != 0 || (byte_skip_mask != '1 && (byte_skip_mask >> length) != 0) ||
		(writing && length < 16 && (data >> (8*length)) != 0)) return;
	if (cfg.bar_registry == null) return;
	if (!cfg.bar_registry.check_range(target, offset, length, address, why)) return;
	if (address[11:0] + length > 4096 || (!cfg.rc_sequencers.exists(target.rc_slot) || cfg.rc_sequencers[target.rc_slot] == null)) begin
		why = "MMIO crosses 4KB or has no RC sequencer";
		return;
	end
	seq = pcie_tl_reg_seq::type_id::create("project_mmio");
	seq.is_write = writing;
	seq.addr = address;
	seq.len = length;
	seq.mask = byte_skip_mask;
	seq.wdata = data;
	seq.start(cfg.rc_sequencers[target.rc_slot], this);
	ok = seq.status == PCIE_RW_OK;
	why = seq.error_msg;
	result = seq.rdata;
endtask


// Function+真实 BAR 查找，offset 永远相对所选 BAR；失败不回退默认窗口。
task project_dut_config_seq::pcie_bar_write(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	input logic [31:0]		byte_skip_mask,
	output bit			ok,
	output string			why
);
	project_bar_target_t	target;
	logic [127:0]		ignored;
	ok = 0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask


// 读 Completion 的失败和短数据由底层 sequence 明确上传，不把默认零当成功。
task project_dut_config_seq::pcie_bar_read(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [31:0]		byte_skip_mask,
	output logic [127:0]		data,
	output bit			ok,
	output string			why
);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_function(owner, bar_id, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask


// 手动路径无隐含 Host，多个 Host 时必须写完整 h 前缀。
task project_dut_config_seq::pcie_bar_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	input logic [31:0]	byte_skip_mask,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;
	logic [127:0]		ignored;
	ok = 0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 1, offset, length, data, byte_skip_mask, ignored, ok, why);
endtask


// 解析用户选择的真实 BAR 后逐 DWORD 写完整表项；不改变 cfg 中已生成的 typed 表项。
// 地址是 BAR 内偏移；不自动读回或触发间接控制，失败保留已发出的 posted 写。
task project_dut_config_seq::pcie_table_write_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [127:0]	data,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;

	ok  = 0;
	why = "public registry not published";

	if (cfg.bar_registry == null) begin
		return;
	end

	if (!cfg.bar_registry.resolve_name(name, target, why)) begin
		return;
	end

	write_table_dwords(target, offset, length, data, ok, why);
endtask


// 表项最多 128 bit，每次仅发 32 bit，高位放高地址；不反转 DWORD 内字节。
// 第一笔前检查整项宽度、已知值、BAR 和 4KB 范围；任何发送失败立即返回。
// 单个配置 sequence 顺序调用；本层返回后调用者才发送 clear/trigger。
task project_dut_config_seq::write_table_dwords(
	input project_bar_target_t	target,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		data,
	output bit			ok,
	output string			why
);
	logic [127:0]	ignored;
	bit [63:0]	address;

	ok  = 0;
	why = "table write contains X/Z, unsupported width/alignment or excess data";

	if (
		$isunknown({offset, data}) ||
		!(length inside {4, 8, 12, 16}) ||
		offset[1:0] != 0 ||
		(length < 16 && (data >> (8 * length)) != 0)
	) begin
		return;
	end

	if (cfg.bar_registry == null || !cfg.runtime_ready) begin
		why = "table write requires published registry and PCIe environment";
		return;
	end

	if (!cfg.bar_registry.check_range(target, offset, length, address, why)) begin
		return;
	end

	if (address[11:0] + length > 4096 || (!cfg.rc_sequencers.exists(target.rc_slot) || cfg.rc_sequencers[target.rc_slot] == null)) begin
		why = "table write crosses 4KB or has no RC sequencer";
		return;
	end

	for (int	dword = int'(length / 4) - 1; dword >= 0; dword--) begin
		mmio(
			target, 1, offset + 4 * dword, 4,
			128'(data[dword * 32 +: 32]), 0, ignored, ok, why
		);

		if (!ok) begin
			return;
		end
	end
endtask


// 名字解析与实际 Function API 复用同一个范围/格式检查。
task project_dut_config_seq::pcie_bar_read_by_name(
	input string		name,
	input logic [63:0]	offset,
	input int unsigned	length,
	input logic [31:0]	byte_skip_mask,
	output logic [127:0]	data,
	output bit		ok,
	output string		why
);
	project_bar_target_t	target;
	ok = 0;
	data = '0;
	if (cfg.bar_registry == null) begin why = "public registry not published"; return; end
	if (!cfg.bar_registry.resolve_name(name, target, why)) return;
	mmio(target, 0, offset, length, '0, byte_skip_mask, data, ok, why);
endtask


// 有界显式轮询；比较 mask 与 byte skip-mask 是不同概念，不在后台自动读状态。
task project_dut_config_seq::pcie_poll_bar(
	input dpu_function_key_t	owner,
	input int unsigned		bar_id,
	input logic [63:0]		offset,
	input int unsigned		length,
	input logic [127:0]		mask,
	input logic [127:0]		expected,
	input int unsigned		attempts,
	input time			interval,
	output bit			ok,
	output string			why
);
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


// 检查表项绑定与字段宽度；仅 enabling 改变声明的 enable/mask 位。
// 单个配置 sequence 按顺序调用，VTX/VRX 不插入其他表访问。
// 每项先高到低逐 DWORD 写；VTX/VRX 的四笔数据全部成功后才发 clear/trigger。
task project_dut_config_seq::checked_write(
	input project_config_record_t	record,
	input logic [127:0]		value,
	input bit			enabling,
	output bit			ok,
	output string			why
);
	project_config_record_t	original;
	project_table_layout_t	layout;
	logic [127:0]		ignored;
	logic [127:0]		expected;
	bit [63:0]		address;
	bit [63:0]		offset;
	logic [31:0]		control;
	ok = 0;
	why = "checked table write has no matching frozen record";
	if (!cfg.records.exists(record.ctx.record_key)) return;
	original = cfg.records[record.ctx.record_key];
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
		local_scope = new("write_scope", cfg.vio_setups[record.owner.host_id], keys);
		if (!cfg.vio_envs[record.owner.host_id].preflight_external_configuration(cfg.vio_setups[record.owner.host_id], local_scope, why)) return;
	end
	layout = original.ctx.layout;
	if (!cfg.bar_registry.check_range(original.ctx.target, original.ctx.byte_offset, layout.entry_bytes, address, why)) return;
	if (layout.indirect) begin
		offset = layout.module_offset + layout.data_port;
		if (!cfg.bar_registry.check_range(original.ctx.target, offset, layout.entry_bytes, address, why) ||
			!cfg.bar_registry.check_range(original.ctx.target, layout.module_offset + layout.control_port, 4, address, why)) return;
	end
	if (layout.indirect) begin

		write_table_dwords(original.ctx.target, offset, layout.entry_bytes, value, ok, why);
		control = layout.control_fixed | (original.ctx.table_index << layout.index_shift);

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port,
				4, 128'(control), 0, ignored, ok, why);
		end

		if (ok) begin
			mmio(original.ctx.target, 1, layout.module_offset + layout.control_port,
				4, 128'(control | layout.trigger_mask), 0, ignored, ok, why);
		end

	end else begin
		write_table_dwords(original.ctx.target, original.ctx.byte_offset,
			layout.entry_bytes, value, ok, why);
	end
endtask


// bdf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_bdf(
	input project_bdf_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_BDF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// completion_bdf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_completion_bdf(
	input project_completion_bdf_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_COMPLETION_BDF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// pfvf typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_pfvf(
	input project_pfvf_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PFVF) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// tlp_prefix typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_tlp_prefix(
	input project_tlp_prefix_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_PREFIX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_linear typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_linear(
	input project_msix_linear_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_LINEAR) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_info typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_info(
	input project_msix_info_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INFO) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_interval typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_interval(
	input project_msix_interval_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_INTERVAL) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// msix_table typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_msix_table(
	input project_msix_table_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_MSIX_TABLE) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_q2tc typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_q2tc(
	input project_qsch_q2tc_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_Q2TC) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_n2g typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_n2g(
	input project_qsch_n2g_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_N2G) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_g2p typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_g2p(
	input project_qsch_g2p_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_G2P) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// rdma_notify typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_rdma_notify(
	input project_rdma_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RDMA_NOTIFY) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// qsch_rnet typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_qsch_rnet(
	input project_qsch_rnet_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_RNET) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.owner = item.owner;
	if (r.consumers != item.consumers) begin why = "typed consumer set changed"; return; end
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vtx typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vtx(
	input project_vtx_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VTX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vrx typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vrx(
	input project_vrx_cfg_t	item,
	output bit		ok,
	output string		why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_VRX) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// vio_notify typed 写入口检查全部关联，随后复用唯一逐 DWORD 写入实现。
task project_dut_config_seq::write_vio_notify(
	input project_vio_notify_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "typed cfg has no frozen record or wrong category";
	if (!cfg.records.exists(item.ctx.record_key) || item.ctx.kind != PROJECT_NOTIFY) return;
	r = cfg.records[item.ctx.record_key];
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, 128'(item.entry), 0, ok, why);
endtask


// 唯一 typed dispatch；不在单项 hook 中复制外围循环，也不隐含执行其他类别。
task project_dut_config_seq::dispatch_record(
	input project_config_record_t	record,
	output bit			ok,
	output string			why
);
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
			project_queue_control_cfg_t	item;
			item.ctx = record.ctx;
			item.binding = record.binding;
			item.value = record.entry;
			item.writable_mask = cfg.platform_control_mask(record);
			user_configure_queue_aux(item, ok, why);
		end
		PROJECT_BAR: begin
			project_bar_mapping_cfg_t	item;
			item = cfg.frozen_bar_groups[record.ctx.table_index];
			item.ctx = record.ctx;
			user_configure_bar_mapping_entry(item, ok, why);
		end
		default: begin
			project_control_cfg_t	item;
			item.ctx = record.ctx;
			item.owner = record.owner;
			item.consumers = record.consumers;
			item.consumers_complete = 1;
			item.value = record.entry;
			item.writable_mask = cfg.platform_control_mask(record);
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


// 公共控制 hook 可复用同一 checked 路径；mask 和消费者也必须匹配原件。
task project_dut_config_seq::write_control(
	input project_control_cfg_t	item,
	output bit			ok,
	output string			why
);
	project_config_record_t	r;
	ok = 0;
	why = "control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!(r.ctx.kind inside {PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_SPWRR, PROJECT_TC_WEIGHT}) ||
		item.writable_mask !== cfg.platform_control_mask(r) || item.consumers != r.consumers) return;
	r.ctx = item.ctx;
	r.owner = item.owner;
	checked_write(r, item.value, 0, ok, why);
endtask


// 辅助项有实际 ring 绑定，不能借控制 payload 修改另一个 pair。
task project_dut_config_seq::write_queue_aux(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "queue auxiliary control has no matching frozen record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (r.ctx.kind != PROJECT_QUEUE_AUX || item.writable_mask !== cfg.platform_control_mask(r)) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 0, ok, why);
endtask


// 先生成所选公共表，再逐项调用用户 hook；同一硬件项只写一次，失败立即停止。
task project_dut_config_seq::configure_public(
	input project_table_kind_e	kinds[$],
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	project_config_record_t	selected[$];
	project_config_record_t	batch[$];
	bit			seen[string];

	ok = 0;
	foreach (kinds[k]) begin
		if (!cfg.public_records(kinds[k], scope, selected, why)) return;
		foreach (selected[i]) batch.push_back(selected[i]);
	end
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		string	key;

		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		dispatch_record(cfg.records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			return;
		end
	end
	ok = 1;
	why = "";
endtask


// 按实际 service/qpair 遍历；共享 QSCH 项去重，TX-only 不生成 VRX 写入。
task project_dut_config_seq::configure_queues(
	input project_table_kind_e	kinds[$],
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_config_record_t	batch[$];
	bit			seen[string];

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		string	key;

		key = batch[i].ctx.record_key;
		if (seen.exists(key)) continue;
		seen[key] = 1;
		dispatch_record(cfg.records[key], ok, why);
		if (!ok) begin
			why = {key, ": ", why};
			return;
		end
	end
	ok = 1;
	why = "";
endtask


// 写表完成后逐队列使能；平台 task 返回失败时不再处理下一条队列。
task project_dut_config_seq::enable_vio_queues(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	project_config_record_t		batch[$];
	project_table_kind_e		kinds[$] = '{PROJECT_VTX, PROJECT_VRX};
	project_queue_control_cfg_t	item;

	ok = 0;
	if (!cfg.queue_records(selection, kinds, batch, why)) return;
	foreach (batch[i]) if (!cfg.remember_record(batch[i], why)) return;

	foreach (batch[i]) begin
		item.ctx = batch[i].ctx;
		item.binding = batch[i].binding;
		item.value = (batch[i].entry & ~batch[i].enable_mask) | batch[i].enable_value;
		item.writable_mask = batch[i].enable_mask;
		user_enable_queue(item, ok, why);
		if (!ok) return;
	end
	ok = 1;
	why = "";
endtask


// 公共配置写完后交由平台读回或检查状态；不将 posted 发送完成当成硬件生效。
task project_dut_config_seq::verify_dpu_configuration(
	input project_dpu_config_scope	scope,
	output bit			ok,
	output string			why
);
	ok = 0;
	why = "public verification scope is missing";
	if (scope == null) return;
	if (!scope.validate(cfg.dpu_setup, why)) return;

	user_verify_dpu_configuration(scope, ok, why);
endtask


// 队列配置写完后执行平台验证；成功后默认 body 才调用 cfg.commit_vio_configuration。
task project_dut_config_seq::verify_vio_configuration(
	input project_vio_selection_t	selection,
	output bit			ok,
	output string			why
);
	ok = 0;
	if (!cfg.preflight_vio(selection, why)) return;

	user_verify_vio_configuration(selection, ok, why);
endtask


// queue enable 只能更新已声明的 enable 位，仅改变平台声明的 enable 位。
task project_dut_config_seq::write_enabled_queue(
	input project_queue_control_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_config_record_t	r;
	ok = 0;
	why = "queue enable has no frozen typed record";
	if (!cfg.records.exists(item.ctx.record_key)) return;
	r = cfg.records[item.ctx.record_key];
	if (!r.has_queue || !(r.ctx.kind inside {PROJECT_VTX, PROJECT_VRX}) ||
		item.writable_mask !== r.enable_mask) return;
	r.ctx = item.ctx;
	r.binding = item.binding;
	r.owner = item.binding.service_key.function_key;
	checked_write(r, item.value, 1, ok, why);
endtask


// PBA 是只读字；读取整个64位值，不把总容量从结构体宽度推断出来。
task project_dut_config_seq::read_msix_pba(
	input project_state_query_t	item,
	output project_msix_pba_word_t	value,
	output bit			ok,
	output string			why
);
	project_state_query_t	canonical;
	logic [127:0]		data;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_MSIX_PBA, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "PBA context differs from frozen layout"; return; end
	mmio(item.ctx.target, 0, item.ctx.byte_offset, 8, 0, 0, data, ok, why);
	if (ok) value.pending = data[63:0];
endtask


// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_dut_config_seq::read_msix_stat(
	input project_state_query_t	item,
	output project_msix_stat_t	value,
	output bit			ok,
	output string			why
);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_MSIX_STAT, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_msix_stat(item, value, ok, why);
endtask


// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_dut_config_seq::user_read_msix_stat(
	input project_state_query_t	item,
	output project_msix_stat_t	value,
	output bit			ok,
	output string			why
);
	value = '0;
	ok = 0;
	why = "required user_read_msix_stat is not implemented";
endtask


// 状态 hook 前核对冻结上下文，不允许 caller 将初始化表伪装成只读状态。
task project_dut_config_seq::read_pfvf_drop_status(
	input project_state_query_t		item,
	output project_pfvf_drop_status_t	value,
	output bit				ok,
	output string				why
);
	project_state_query_t	canonical;
	ok = 0;
	value = '0;
	if (!cfg.get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx) begin why = "state context differs from frozen layout"; return; end
	user_read_pfvf_drop_status(item, value, ok, why);
endtask


// 平台可按寄存器语义覆写；未实现不得返回伪造状态。
task project_dut_config_seq::user_read_pfvf_drop_status(
	input project_state_query_t		item,
	output project_pfvf_drop_status_t	value,
	output bit				ok,
	output string				why
);
	value = '0;
	ok = 0;
	why = "required user_read_pfvf_drop_status is not implemented";
endtask


// 显式 clear_mask 与状态值类型隔离；未知态、错误目标在用户 hook 前拒绝。
task project_dut_config_seq::clear_pfvf_drop_status(
	input project_pfvf_drop_clear_cfg_t	item,
	output bit				ok,
	output string				why
);
	project_state_query_t	canonical;
	ok = 0;
	if (!cfg.get_state_context(PROJECT_PFVF_DROP, item.owner, item.ctx.table_index, canonical, why)) return;
	if (canonical.ctx !== item.ctx || $isunknown(item.entry)) begin why = "invalid W1C context/mask"; return; end
	user_clear_pfvf_drop_status(item, ok, why);
endtask


// 清除由用户显式执行；不把读出的 status 自动回写。
task project_dut_config_seq::user_clear_pfvf_drop_status(
	input project_pfvf_drop_clear_cfg_t	item,
	output bit				ok,
	output string				why
);
	ok = 0;
	why = "required user_clear_pfvf_drop_status is not implemented";
endtask
