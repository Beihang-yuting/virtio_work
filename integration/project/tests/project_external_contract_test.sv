// integration/project/tests：补齐外部配置的可执行软件合同与真实 Intel 报文路径。
// 复用已有显式模型平台；地址/身份公式仅为 fixture，不能作为用户 RTL 默认值。
// 测试拥有 APP 侧 BAR 字节存储和捕获队列；Host DMA 仍仅由产品 RC 响应。
package project_external_contract_test_pkg;
	import uvm_pkg::*;
	import aip_core_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	import net_packet_pkg::*;
	import intel_pcie_adapter_pkg::*;
	import project_env_pkg::*;
	import project_external_integration_test_pkg::*;
	`include "uvm_macros.svh"

	// 单次UR注入的精确诊断窗口；其他severity/ID/状态照常报错，绝不全局降级。
	class project_ur_expected_report extends uvm_report_catcher;
		int unsigned	warnings;
		// 创建单次注入的计数器，初始未注册到report系统。
		extern function new();
		// 仅匹配业务接口的预期UR警告，计数必须恰好一次。
		extern virtual function action_e catch();
	endclass

	// 本对象仅在一次故意UR读期间注册。
	function project_ur_expected_report::new();
		super.new("expected_ur");
	endfunction

	// 保留status字段匹配，标签和租约地址由运行期分配，不能硬编码其数值。
	function uvm_report_catcher::action_e project_ur_expected_report::catch();
		if (get_severity() == UVM_WARNING && get_id() == "RW_SEQ" &&
			uvm_is_match("READ completed with status=CPL_STATUS_UR addr=*", get_message())) begin
			warnings++;
			return CAUGHT;
		end
		return THROW;
	endfunction

	// 模型hook与只读导出供独立断言；全部发送保留checked_write及生产资源校验。
	class project_contract_env extends project_external_model_env;
		`uvm_component_utils(project_contract_env)
		int unsigned	control_calls[project_table_kind_e];
		// 创建只读观察层，沿用父类构建路径。
		extern function new(string	name, uvm_component	parent);
		// 可选RDMA与W1C都必须由平台显式调用，不随队列初始化自动运行。
		extern virtual task user_configure_rdma_notify_entry(input project_rdma_notify_cfg_t	item, output bit	ok, output string	why);
		// W1C仅执行显式mask，不能偷偷读状态或清除其他位。
		extern virtual task user_clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_AF控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_af(input project_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_MSIX_CONTROL控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_msix_control_entry(input project_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_MSIX_FUNCTION控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_msix_function(input project_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_SPWRR控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_qsch_spwrr(input project_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_TC_WEIGHT控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_qsch_tc_weight(input project_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_QUEUE_AUX控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_queue_aux(input project_queue_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_COMPLETION_BDF控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_completion_bdf_entry(input project_completion_bdf_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_PREFIX控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_tlp_prefix_entry(input project_tlp_prefix_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_RNET控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_qsch_rnet_entry(input project_qsch_rnet_cfg_t	item, output bit	ok, output string	why);
		// 导出实际配置记录，调用者只检查冻结值和真实发送结果。
		extern function bit inspect_queues(input project_vio_selection_t	selected,
			input project_table_kind_e	kinds[$], output project_config_record_t	rows[$], output string	why);
		// 导出公共记录，不创建测试专属生产接口。
		extern function bit inspect_public(input project_table_kind_e	kind,
			input project_dpu_config_scope	scope, output project_config_record_t	rows[$], output string	why);
	endclass

	// 构造观察层，沿用原平台 hook。
	function project_contract_env::new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// 可选RDMA条目使用同一冻结检查和高低DWORD写序。
	task project_contract_env::user_configure_rdma_notify_entry(input project_rdma_notify_cfg_t	item, output bit	ok, output string	why);
		write_rdma_notify(item, ok, why);
	endtask

	// 此模型平台声明W1C寄存器的写法；只发送用户mask，绝不读状态再回写。
	task project_contract_env::user_clear_pfvf_drop_status(input project_pfvf_drop_clear_cfg_t	item, output bit	ok, output string	why);
		pcie_bar_write(item.ctx.target.function_key, item.ctx.target.bar_lease.even_bar_id,
			item.ctx.byte_offset, 4, 128'(item.entry.clear_mask), 0, ok, why);
	endtask

	// PROJECT_AF使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_af(input project_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_AF]++;
		write_control(item, ok, why);
	endtask

	// PROJECT_MSIX_CONTROL使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_msix_control_entry(input project_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_MSIX_CONTROL]++;
		write_control(item, ok, why);
	endtask

	// PROJECT_MSIX_FUNCTION使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_msix_function(input project_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_MSIX_FUNCTION]++;
		write_control(item, ok, why);
	endtask

	// PROJECT_SPWRR使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_qsch_spwrr(input project_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_SPWRR]++;
		write_control(item, ok, why);
	endtask

	// PROJECT_TC_WEIGHT使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_qsch_tc_weight(input project_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_TC_WEIGHT]++;
		write_control(item, ok, why);
	endtask

	// PROJECT_QUEUE_AUX使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_queue_aux(input project_queue_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_QUEUE_AUX]++;
		write_queue_aux(item, ok, why);
	endtask

	// PROJECT_COMPLETION_BDF使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_completion_bdf_entry(input project_completion_bdf_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_COMPLETION_BDF]++;
		write_completion_bdf(item, ok, why);
	endtask

	// PROJECT_PREFIX使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_tlp_prefix_entry(input project_tlp_prefix_cfg_t	item, output bit	ok, output string	why);
		if (!$test$plusargs("PROJECT_CONTROLS")) begin
			super.user_configure_tlp_prefix_entry(item, ok, why);
			return;
		end
		control_calls[PROJECT_PREFIX]++;
		write_tlp_prefix(item, ok, why);
	endtask

	// PROJECT_RNET使用平台声明布局和原typed校验，不伪造配置成功。
	task project_contract_env::user_configure_qsch_rnet_entry(input project_qsch_rnet_cfg_t	item, output bit	ok, output string	why);
		control_calls[PROJECT_RNET]++;
		write_qsch_rnet(item, ok, why);
	endtask

	// 复用真实导出，只读检查有完整失败说明。
	function bit project_contract_env::inspect_queues(input project_vio_selection_t	selected,
		input project_table_kind_e	kinds[$], output project_config_record_t	rows[$], output string	why);
		return queue_records(selected, kinds, rows, why);
	endfunction
	// 返回真实公共条目，缺布局仍由产品拒绝。
	function bit project_contract_env::inspect_public(input project_table_kind_e	kind,
		input project_dpu_config_scope	scope, output project_config_record_t	rows[$], output string	why);
		return public_records(kind, scope, rows, why);
	endfunction

	// 同一测试覆盖传输/顺序和实际 RX，plusarg 选择原 fixture 的协议与 Host 数。
	class project_external_contract_test extends project_external_integration_test;
		`uvm_component_utils(project_external_contract_test)
		project_contract_env	probe;
		pcie_tl_mem_tlp	requests[int unsigned][$];
		bit	read_error;
		string	policy_case;
		// 构造测试；所有模型 RAM 由本实例持有。
		extern function new(string	name, uvm_component	parent);
		// 在冻结前声明非连续 placement、完整 BAR 原子组和宽 QSCH 策略。
		extern virtual function void build_phase(uvm_phase	phase);
		// 可选成功控制仅在PROJECT_CONTROLS显式声明，未知地址全部为模型示例。
		extern function void declare_controls();
		// 按公开类别执行额外控制，检查真实Memory写与预期逐项调用数。
		extern task check_public_controls(input project_dpu_config_scope	scope);
		// 局部释放必须保留另一Host；全部释放后下一代才可复用预取RAM。
		extern task check_release_generation();
		// BAR 读可注入 UR Completion；仍经 Intel APP 引脚发送。
		extern task receive_contract(input int unsigned	host);
		// 检查实际全部 Memory 请求的路由、长度、逐字节数据及 skip mask。
		extern task check_mmio();
		// 与捕获的 Intel 写事务逐项比较，不通过 pack/unpack 自证顺序。
		extern task check_writes(input project_config_record_t	rows[$], input int unsigned	first);
		// 将完整 payload 分段为真实 Memory Write，DUT 不直接操作 Host GPA。
		extern task dma_bytes(input int unsigned	host, input bit [15:0]	requester,
			input bit [63:0]	address, input byte	data[]);
		// 真实 512B RX 的 descriptor、buffer、CQ/used 均走非 identity Function IOMMU。
		extern task check_rx();
		// 可选RDMA顺序、PBA只读容量和显式W1C独立于初始化类别。
		extern task check_optional_state(input project_dpu_config_scope	scope);
		// 两个真实checked写并发争用同一间接端口，捕获数据/clear/trigger不可交叉。
		extern task check_concurrent_port();
		// 当前Custom CQ格式的N-1、初值及RX wrap组件合同，不混用旧legacy黄金值。
		extern task check_current_custom_ring();
		// 新租约registry和同域消息歧义使用真实冻结API，保持组件与Intel证据分层。
		extern task check_registry_and_notifications();
		// 冻结前注入单一非法策略；检测分类错误、零发送和资源保留。
		extern task check_policy_rejection();
		// 按显式顺序执行配置；停机确认后释放，检查模型的无访问阶段。
		extern virtual task run_phase(uvm_phase	phase);
	endclass

	// 创建 test，不访问设备。
	function project_external_contract_test::new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	// 在既有参数入口前设置混合模式；不修改已解析快照或环描述符。
	function void project_external_contract_test::build_phase(uvm_phase	phase);
		project_bar_group_policy_t	group;
		bit	rdma_declared;
		void'($value$plusargs("PROJECT_POLICY_CASE=%s", policy_case));
		project_external_model_env::type_id::set_type_override(project_contract_env::get_type());
		if ($test$plusargs("PROJECT_MIXED")) begin
			aip_cmdline_override::set_val("vio.h0.pf0.vf1.i0.queue_type", "VQ_CUSTOM");
			aip_cmdline_override::set_val("vio.h1.pf0.vf1.i0.queue_type", "VQ_CUSTOM");
		end
		if ($test$plusargs("PROJECT_UNEQUAL")) begin
			aip_cmdline_override::set_val("dpu.pfs_per_host", "2");
			aip_cmdline_override::set_val("vio.h0.pf1.vf0.i0.enabled", "1");
		end
		super.build_phase(phase);
		if ($test$plusargs("PROJECT_LATE_BAR_PRINT")) cfg.print_bar_map = 0;
		if ($test$plusargs("PROJECT_UNEQUAL")) begin
			for (int	f = cfg.dpu_cfg.device_cfg.functions.size()-1; f >= 0; f--) begin
				dpu_function_key_t	key;
				string	name;
				key = cfg.dpu_cfg.device_cfg.functions[f].key;
				if (key.pf_id == 1 && key.kind == DPU_FUNCTION_VF && key.vf_id == 1) begin
					name = dpu_function_key_name(key);
					cfg.dpu_cfg.device_cfg.functions.delete(f);
					cfg.function_policies.delete(name);
					cfg.msix_policies.delete(name);
					cfg.message_templates.delete(name);
				end
			end
			foreach (cfg.vio_policies[name])
				if (cfg.vio_policies[name].service_key.function_key.pf_id == 1 &&
					cfg.vio_policies[name].service_key.function_key.vf_id == 1) cfg.vio_policies.delete(name);
		end
		require_true($cast(probe, env), "contract env factory override");
		foreach (cfg.dpu_cfg.placement_cfg.vio_requests[r]) begin
			for (int unsigned	q = 0; q < pairs; q++) begin
				dpu_vio_qpair_override	override_item;
				override_item = new("sparse_pair");
				override_item.request_pair_index = q;
				override_item.global_mode = DPU_ASSIGN_PINNED;
				override_item.requested_global_qpair_id = 100 + r*16 + q*3;
				cfg.dpu_cfg.placement_cfg.vio_requests[r].qpair_overrides.push_back(override_item);
			end
		end
		// 一个覆盖所有真实 BAR 成员的声明组，使部分 scope 必须明确失败。
		cfg.bar_mapping_per_lease = 0;
		group.name = "fixture_atomic_all_bars";
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			for (int unsigned	b = 0; b < 3; b++) begin
				group.functions.push_back(cfg.dpu_cfg.device_cfg.functions[f].key);
				group.bar_ids.push_back(b*2);
			end
		end
		cfg.bar_group_policies.push_back(group);
		foreach (cfg.vio_policies[name]) begin
			cfg.vio_policies[name].net_base = 128 + cfg.vio_policies[name].service_key.function_key.pf_id*64 + cfg.vio_policies[name].service_key.function_key.vf_id*16;
			cfg.vio_policies[name].group_id = 64 + cfg.vio_policies[name].service_key.function_key.pf_id*4 + cfg.vio_policies[name].service_key.function_key.vf_id;
			cfg.vio_policies[name].eth_ports = $test$plusargs("PROJECT_ETS") ? 4 : 2;
			cfg.vio_policies[name].ets = $test$plusargs("PROJECT_ETS");
			cfg.vio_policies[name].ets_priority = 3;
			// 双Host共享同一物理RAM时明确保留不重叠的descriptor槽区间。
			cfg.vio_policies[name].prefetch_ram = "fixture_shared_ram";
			cfg.vio_policies[name].prefetch_start += cfg.vio_policies[name].service_key.function_key.host_id*8192 + cfg.vio_policies[name].service_key.function_key.pf_id*1024;
			case (policy_case)
				"alignment": cfg.vio_policies[name].prefetch_start = 1;
				"capacity": cfg.vio_policies[name].prefetch_start = 32768;
				"fpga_high": begin
					cfg.vio_policies[name].fpga = 1;
					cfg.vio_policies[name].prefetch_start = 16384;
				end
				"prefetch_depth": begin
					cfg.vio_policies[name].vrx.dsc_pre_max_num = 0;
					cfg.vio_policies[name].prefetch_slots = 256;
				end
				"overlap": cfg.vio_policies[name].prefetch_start = 0;
				"headsplit": cfg.vio_policies[name].vrx.head_dsc_len = 1;
				"reserved": cfg.vio_policies[name].vtx.reserved_111_106 = 1;
				"unknown": cfg.vio_policies[name].vrx.dsc_dma_num = 'x;
				"qsch_overflow": cfg.vio_policies[name].net_base = 1024;
				"qsch_conflict": cfg.vio_policies[name].net_base = 128;
				default: ;
			endcase
		end
		add_layout(PROJECT_RDMA_NOTIFY, 8, 256, 'h200000, 'hc000);
		add_layout(PROJECT_PFVF_DROP, 4, 128, 'h200000, 'ha000);
		add_layout(PROJECT_MSIX_PBA, 8, 2, 'h100000, 'h10000);
		foreach (cfg.function_policies[name]) begin
			project_control_cfg_t	control;
			project_rdma_notify_entry_t	entry;
			if ($test$plusargs("PROJECT_SELF_MASK")) cfg.msix_policies[name].self_mask = 1;

			if (cfg.function_policies[name].key.kind != DPU_FUNCTION_VF || rdma_declared) continue;
			entry = '0;
			entry.host_id = cfg.function_policies[name].key.host_id;
			entry.vf_id = cfg.function_policies[name].key.vf_id;
			entry.base_addr_60_13 = 48'h12345678;
			control.ctx.kind = PROJECT_RDMA_NOTIFY;
			control.ctx.table_index = 0;
			control.owner = cfg.function_policies[name].key;
			control.value = 128'(entry);
			control.writable_mask = 128'h07ff_ffff_ffff_ffff;
			cfg.platform_controls.push_back(control);
			rdma_declared = 1;
		end

		if ($test$plusargs("PROJECT_CONTROLS")) declare_controls();

		if (policy_case == "pba_overlap") begin
			foreach (cfg.msix_policies[name]) if (cfg.function_policies[name].key.kind == DPU_FUNCTION_PF) begin
				cfg.msix_policies[name].table_present = 1;
				cfg.msix_policies[name].table_bar = 0;
				cfg.msix_policies[name].table_offset = 'h120000;
				cfg.msix_policies[name].table_size = 1024;
				cfg.msix_policies[name].pba_present = 1;
				cfg.msix_policies[name].pba_bar = 0;
				cfg.msix_policies[name].pba_offset = 'h120000;
				cfg.msix_policies[name].pba_words = 1;
			end
		end
		if (policy_case == "missing_layout") cfg.table_layouts.delete(PROJECT_VRX);
		if (policy_case == "missing_hook") begin
			add_layout(PROJECT_PREFIX, 8, 128, 'h100000, 'h18000);
			foreach (cfg.function_policies[name]) cfg.function_policies[name].prefix_enabled = 1;
		end
	endfunction

	// 可选控制使用明确的模型地址/值；SW Requester由固定BDF输入分配后再冻结。
	function void project_external_contract_test::declare_controls();
		project_table_kind_e	control_kinds[$] = '{PROJECT_AF, PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION,
			PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_QUEUE_AUX, PROJECT_RNET};
		require_true(host_count == 1, "control fixture is one explicit Host platform");
		foreach (control_kinds[k])
			add_layout(control_kinds[k], 4, 2048, 'h700000+k*'h10000, 0);
		// AF只配置真实PF0；不把该平台寄存器强制成每个VF的依赖。
		cfg.table_layouts[PROJECT_AF].required = 0;
		add_layout(PROJECT_COMPLETION_BDF, 4, 4096, 'h300000, 'h18000);
		cfg.table_layouts[PROJECT_RNET].table_offset = 'h15000;
		cfg.table_layouts[PROJECT_RNET].capacity = 256;
		add_layout(PROJECT_PREFIX, 8, 256, 'h100000, 'h18000);
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			dpu_function_key_t	key;
			string	name;
			project_control_cfg_t	control;
			project_table_kind_e	public_kinds[$] = '{PROJECT_MSIX_CONTROL, PROJECT_MSIX_FUNCTION, PROJECT_RNET};
			key = cfg.dpu_cfg.device_cfg.functions[f].key;
			name = dpu_function_key_name(key);
			cfg.dpu_cfg.device_cfg.functions[f].bdf_mode = DPU_ALLOC_PINNED;
			cfg.dpu_cfg.device_cfg.functions[f].pinned_bdf = 16'h20+f;
			cfg.function_policies[name].mode = PROJECT_HOST_SW;
			cfg.function_policies[name].requester = 16'h20+f;
			cfg.function_policies[name].prefix_enabled = 1;
			cfg.function_policies[name].prefix = 32'h12340000+f;
			cfg.msix_policies[name].table_only_enable = 0;
			control.owner = key;
			control.ctx.table_index = cfg.function_policies[name].vport;
			control.writable_mask = 32'hffff;
			foreach (public_kinds[k]) begin
				control.ctx.kind = public_kinds[k];
				control.value = public_kinds[k] == PROJECT_RNET ? (key.host_id << 1) | 1 : 32'h21+k;
				cfg.platform_controls.push_back(control);
			end
			if (key.kind == DPU_FUNCTION_PF && key.pf_id == 0) begin
				control.ctx.kind = PROJECT_AF;
				control.value = 32'h15;
				cfg.platform_controls.push_back(control);
			end
		end
		foreach (cfg.dpu_cfg.placement_cfg.vio_requests[r]) begin
			project_control_cfg_t	control;
			dpu_service_key_t	service;
			project_table_kind_e	shared_kinds[$] = '{PROJECT_SPWRR, PROJECT_TC_WEIGHT};
			require_true(cfg.dpu_cfg.placement_cfg.vio_requests[r].fixed_devices.size() == 1,
				"controls require the explicit one-owner placement request");
			control.owner = cfg.dpu_cfg.placement_cfg.vio_requests[r].fixed_devices[0];
			service = '{function_key:control.owner, service_kind:DPU_SERVICE_VIO_NET,
				service_instance_id:cfg.dpu_cfg.placement_cfg.vio_requests[r].service_instance_id};
			control.consumers.push_back(service);
			control.ctx.table_index = cfg.function_policies[dpu_function_key_name(control.owner)].vport;
			control.writable_mask = 32'hff;
			foreach (shared_kinds[k]) begin
				control.ctx.kind = shared_kinds[k];
				control.value = k == 0 ? 32'h31 : 32'h52;
				cfg.platform_controls.push_back(control);
			end
			for (int unsigned	q = 0; q < pairs; q++) begin
				control.ctx.kind = PROJECT_QUEUE_AUX;
				control.ctx.table_index = 100+r*16+q*3;
				control.value = 32'h73;
				cfg.platform_controls.push_back(control);
			end
		end
	endfunction

	// 公共额外类别逐项比对真实Intel发送，防止空catalog冒充成功。
	task project_external_contract_test::check_public_controls(input project_dpu_config_scope	scope);
		project_table_kind_e	kinds[$] = '{PROJECT_AF, PROJECT_COMPLETION_BDF, PROJECT_PREFIX, PROJECT_RNET, PROJECT_MSIX_FUNCTION};
		project_config_record_t	rows[$];
		bit	ok;
		string	why;
		int unsigned	before_count;
		foreach (kinds[k]) begin
			require_true(probe.inspect_public(kinds[k], scope, rows, why) && rows.size() != 0, why);
			if (kinds[k] == PROJECT_COMPLETION_BDF) foreach (rows[r]) begin
				project_function_record_t	owner;
				project_completion_bdf_entry_t	entry;
				require_true(env.dpu_setup.get_function(rows[r].owner, owner), "Completion owner absent");
				entry = project_completion_bdf_entry_t'(rows[r].entry);
				require_true(entry.completion_id == owner.pcie_id.bdf && entry.valid,
					"Completion BDF did not use actual frozen SW identity");
			end
			#20ns;
			before_count = posted[0].size();
			case (kinds[k])
				PROJECT_AF: env.configure_af(scope, ok, why);
				PROJECT_COMPLETION_BDF: env.configure_completion_bdf_table(scope, ok, why);
				PROJECT_PREFIX: env.configure_tlp_prefix(scope, ok, why);
				PROJECT_RNET: env.configure_qsch_rnet(scope, ok, why);
				PROJECT_MSIX_FUNCTION: env.enable_msix(scope, ok, why);
				default: require_true(0, "unknown optional public test category");
			endcase
			require_true(ok && probe.control_calls[kinds[k]] == rows.size(), why);
			check_writes(rows, before_count);
		end
		require_true(probe.inspect_public(PROJECT_MSIX_CONTROL, scope, rows, why) &&
			probe.control_calls[PROJECT_MSIX_CONTROL] == rows.size(), "MSI-X control traversal count");
	endtask

	// 一Host释放不改变另一Host的环/确认；旧代全部释放后允许明确的新预取分配。
	task project_external_contract_test::check_release_generation();
		project_vio_selection_t	released;
		project_vio_selection_t	retained;
		project_vio_selection_t	attempted;
		vio_queue_setup_t	before_rows[$];
		vio_queue_setup_t	after_rows[$];
		project_config_record_t	rows[$];
		project_table_kind_e	kinds[$] = '{PROJECT_VRX};
		longint unsigned	old_generation[int unsigned];
		int unsigned	before_count[int unsigned];
		bit	ok;
		string	why;
		foreach (selection.setups[h]) begin
			old_generation[h] = selection.setups[h].get_generation();
			before_count[h] = requests[h].size();
		end
		if (host_count == 2) begin
			released.setups[0] = selection.setups[0];
			released.scopes[0] = selection.scopes[0];
			retained.setups[1] = selection.setups[1];
			retained.scopes[1] = selection.scopes[1];
			retained.setups[1].list_queues(before_rows);
			env.release_vio_resources(released, 1, ok, why);
			require_true(ok, why);
			env.prepare_vio_configuration(attempted, ok, why);
			require_true(!ok && why == "release existing VIO generation before reprepare" && attempted.setups.num() == 0,
				"partial release allowed reprepare while another Host retained its generation");
			retained.setups[1].list_queues(after_rows);
			require_true(before_rows.size() == after_rows.size(), "partial release changed retained Host queue count");
			foreach (before_rows[q]) begin
				require_true(before_rows[q].desc_iova == after_rows[q].desc_iova &&
					before_rows[q].device_iova == after_rows[q].device_iova &&
					env.vio_envs[1].external_service_confirmed(retained.setups[1], before_rows[q].service_key),
					"partial release changed retained Host DMA or confirmation");
			end
			env.release_vio_resources(retained, 1, ok, why);
			require_true(ok, why);
			foreach (cfg.vio_policies[name])
				if (cfg.vio_policies[name].service_key.function_key.host_id == 0)
					cfg.vio_policies[name].prefetch_start += 4096;
		end else begin
			env.release_vio_resources(selection, 1, ok, why);
			require_true(ok, why);
		end
		// RX共享vector曾给TX保留许可；下一代的通知管理器必须清掉旧pending。
		env.prepare_vio_configuration(selection, ok, why);
		require_true(ok, why);
		foreach (selection.setups[h])
			require_true(selection.setups[h].get_generation() > old_generation[h], "reprepare reused old generation");
		foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
			virtio_function_instance	instance;
			instance = env.vio_envs[h].function_instances[f];
			require_true(!instance.transport.notify_mgr.consume_external_pending(0) &&
				!instance.transport.notify_mgr.consume_external_pending(1), "new generation consumed old interrupt permit");
		end
		if (host_count == 2) begin
			require_true(probe.inspect_queues(selection, kinds, rows, why), why);
			foreach (rows[r]) begin
				project_vrx_entry_t	entry;
				project_vio_policy_t	policy;
				entry = project_vrx_entry_t'(rows[r].entry);
				policy = cfg.vio_policies[dpu_service_key_name(rows[r].binding.service_key)];
				require_true(entry.dsc_pre_read_ram_addr == policy.prefetch_start +
					rows[r].binding.qpair.virtio_pair_index*policy.prefetch_slots, "new generation did not freeze changed prefetch allocation");
			end
		end
		env.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		foreach (before_count[h]) require_true(requests[h].size() == before_count[h], "release/reprepare accessed DUT");
		`uvm_info("PROJECT_GENERATION_REUSE_PASS", $sformatf("hosts=%0d, retained confirmation and generation-local prefetch/IRQ state", host_count), UVM_LOW)
	endtask

	// 捕获完整请求，并以实际 Completion 注入读失败；不拦截产品 receive 路径。
	task project_external_contract_test::receive_contract(input int unsigned	host);
		forever begin
			pcie_tl_tlp	t;
			pcie_tl_mem_tlp	m;
			pcie_tl_cpl_tlp	c;
			wait (apps[host].rx_queue.size() != 0);
			apps[host].receive(t);
			if (t == null) continue;
			if ($cast(c, t)) begin
				completions[host].push_back(c);
				continue;
			end
			require_true($cast(m, t), "non-Memory/Configuration TLP in project path");
			requests[host].push_back(m);
			if (m.kind == TLP_MEM_WR) begin
				posted[host].push_back(m);
				foreach (m.payload[i])
					if (pcie_tl_mem_lane_enabled(m, i)) mmio_bytes[host][pcie_tl_mem_wire_addr(m)+i] = m.payload[i];
			end else begin
				if (read_error) begin
					pcie_tl_scoreboard	scb;
					pcie_tl_scoreboard::request_key_t	key;
					// 仅声明这一笔请求的预期错误元数据；不改线包、统计或任何其他请求。
					scb = env.pcie_env.scbs[cfg.tl_slot_by_host[host]];
					key = scb.request_key(m);
					require_true(scb.pending_requests.exists(key) && !scb.cpl_trackers.exists(key),
						"UR expectation requires one pending uncompleted request");
					scb.pending_requests[key].expected_cpl_status = CPL_STATUS_UR;
				end
				c = new("contract_bar_completion");
				c.kind = read_error ? TLP_CPL : TLP_CPLD;
				c.type_f = TLP_TYPE_CPL;
				c.fmt = read_error ? FMT_3DW_NO_DATA : FMT_3DW_WITH_DATA;
				c.requester_id = m.requester_id;
				c.tag = m.tag;
				c.cpl_status = read_error ? CPL_STATUS_UR : CPL_STATUS_SC;
				c.length = read_error ? 0 : m.length;
				c.byte_count = read_error ? 0 : pcie_tl_mem_valid_bytes(m);
				c.lower_addr = m.addr[6:0] + pcie_tl_mem_first_valid_in_range(m, 0, pcie_tl_mem_dw_count(m)*4);
				c.payload = new[read_error ? 0 : pcie_tl_mem_dw_count(m)*4];
				foreach (c.payload[i]) c.payload[i] = mmio_bytes[host].exists(pcie_tl_mem_wire_addr(m)+i) ? mmio_bytes[host][pcie_tl_mem_wire_addr(m)+i] : 0;
				apps[host].send(c);
			end
		end
	endtask

	// 全宽和边缘稀疏 byte enables 经过 codec，非法输入在捕获计数增加前拒绝。
	task project_external_contract_test::check_mmio();
		project_function_record_t	functions[$];
		project_bar_target_t	target;
		logic [127:0]	value;
		logic [127:0]	actual;
		logic [127:0]	expected;
		logic [31:0]	skip;
		bit	ok;
		string	why;
		int unsigned	before_count;
		project_ur_expected_report	catcher;
		env.dpu_setup.list_functions(functions);
		foreach (functions[f]) begin
			int unsigned	h;
			h = functions[f].key.host_id;
			// BAR2 是真实偶数 BAR ID，不是角色或列表下标。
			require_true(env.bar_registry.resolve_function(functions[f].key, 2, target, why), why);
			for (int unsigned	length = 4; length <= 16; length += 4) begin
				for (int	masked = 0; masked < 2; masked++) begin
					value = 0;
					expected = 0;
					skip = masked ? 32'h9 : 0;
					for (int unsigned	i = 0; i < length; i++) begin
						value[i*8 +: 8] = 8'h31+i;
						if (!skip[i]) expected[i*8 +: 8] = 8'h31+i;
					end
					before_count = requests[h].size();
					env.pcie_bar_write(functions[f].key, 2, 'h300+length*32+masked*16, length, value, skip, ok, why);
					require_true(ok, why);
					#20ns;
					require_true(requests[h].size() == before_count + (masked && length > 4 ? 2 : 1), "posted mask segments/readback count");
					begin
						bit [15:0]	seen;
						seen = 0;
						for (int unsigned	n = before_count; n < requests[h].size(); n++) begin
							pcie_tl_mem_tlp	m;
							m = requests[h][n];
							require_true(m.kind == TLP_MEM_WR, "posted write issued a read");
							if (!masked) require_true(m.length*4 == length, "whole Memory TLP length");
							require_true(m.cq_route.bar_id == 2 && m.cq_route.pf_index == target.route.pf_index &&
								m.cq_route.is_vf == target.route.is_vf &&
								(!target.route.is_vf || m.cq_route.vf_index == target.route.vf_index), "actual Intel VF/PF/BAR sideband");
							foreach (m.payload[i]) if (pcie_tl_mem_lane_enabled(m, i)) begin
								int unsigned	lane;
								lane = pcie_tl_mem_wire_addr(m)+i-(target.bar_lease.base+'h300+length*32+masked*16);
								require_true(lane < length && !skip[lane] && !seen[lane] && m.payload[i] == byte'(8'h31+lane), "wire address/payload/enable mismatch");
								seen[lane] = 1;
							end
						end
						for (int unsigned	i = 0; i < length; i++) require_true(seen[i] == !skip[i], "missing enabled wire byte");
					end
					env.pcie_bar_read(functions[f].key, 2, 'h300+length*32+masked*16, length, 0, actual, ok, why);
					require_true(ok && actual == expected, "explicit MMIO readback differs");
				end
			end
			before_count = requests[h].size();
			env.pcie_bar_write(functions[f].key, 2, target.bar_lease.size-4, 8, 0, 0, ok, why);
			require_true(!ok, "out of BAR access accepted");
			env.pcie_bar_write(functions[f].key, 2, 'hfff, 4, 0, 0, ok, why);
			require_true(!ok, "unaligned access accepted");
			env.pcie_bar_write(functions[f].key, 2, 'h100, 4, 'z, 0, ok, why);
			require_true(!ok, "Z data narrowed into valid data");
			#20ns;
			require_true(requests[h].size() == before_count, "invalid MMIO emitted a TLP");
		end
		catcher = new();
		uvm_report_cb::add(null, catcher);
		read_error = 1;
		env.pcie_bar_read_by_name("h0.pf0.bar0", 'h40, 4, 0, actual, ok, why);
		require_true(!ok && why != "", "real UR Completion was reported as successful read");
		read_error = 0;
		#20ns;
		uvm_report_cb::delete(null, catcher);
		require_true(catcher.warnings == 1, "UR warning count differs from one injected read");
		require_true(env.pcie_env.scb.mismatched == 0 && env.pcie_env.scb.unexpected == 0,
			"declared UR was not matched by scoreboard");
		`uvm_info("PROJECT_MMIO_CONTRACT_PASS", "4/8/12/16B, masks, route, posted/readback and real UR Completion", UVM_LOW)
	endtask

	// 逐条重建规格要求的事务地址/值，精确计数排除旧 bank/ready 和隐含状态写。
	task project_external_contract_test::check_writes(input project_config_record_t	rows[$], input int unsigned	first);
		int unsigned	cursor;
		bit	seen[string];
		cursor = first;
		#20ns;
		foreach (rows[r]) begin
			int unsigned	h;
			int unsigned	count;
			if (seen.exists(rows[r].ctx.record_key)) continue;
			seen[rows[r].ctx.record_key] = 1;
			h = rows[r].ctx.target.function_key.host_id;
			// 本检查逐 Host 调用，first 属于该 Host 的独立捕获队列。
			count = rows[r].ctx.layout.indirect ? 3 :
				(rows[r].ctx.kind inside {PROJECT_NOTIFY,PROJECT_MSIX_LINEAR,PROJECT_RDMA_NOTIFY} ? rows[r].ctx.layout.entry_bytes/4 : 1);
			for (int unsigned	n = 0; n < count; n++) begin
				pcie_tl_mem_tlp	m;
				bit [63:0]	offset;
				logic [127:0]	expected;
				int unsigned	length;
				require_true(cursor < posted[h].size(), "missing expected table transaction");
				m = posted[h][cursor++];
				length = rows[r].ctx.layout.entry_bytes;
				expected = rows[r].entry;
				offset = rows[r].ctx.byte_offset;
				if (rows[r].ctx.layout.indirect) begin
					offset = rows[r].ctx.layout.module_offset + (n == 0 ? rows[r].ctx.layout.data_port : rows[r].ctx.layout.control_port);
					if (n != 0) begin
						length = 4;
						expected = rows[r].ctx.layout.control_fixed | (rows[r].ctx.table_index << rows[r].ctx.layout.index_shift);
						if (n == 2) expected |= rows[r].ctx.layout.trigger_mask;
					end
				end else if (count > 1) begin
					length = 4;
					offset += (count-1-n)*4;
					expected = 128'(rows[r].entry[(count-1-n)*32 +: 32]);
				end
				require_true(pcie_tl_mem_wire_addr(m) == rows[r].ctx.target.bar_lease.base+offset &&
					m.length*4 == length && m.cq_route.pf_index == 0 && !m.cq_route.is_vf,
					$sformatf("table %s record=%s segment=%0d actual_addr=%h expected_addr=%h actual_len=%0d expected_len=%0d PF=%0d VFactive=%0d",
						rows[r].ctx.kind.name(), rows[r].ctx.record_key, n, pcie_tl_mem_wire_addr(m),
						rows[r].ctx.target.bar_lease.base+offset, m.length*4, length, m.cq_route.pf_index, m.cq_route.is_vf));
				foreach (m.payload[i]) require_true(m.payload[i] == byte'(expected[i*8 +: 8]), "table payload differs");
			end
		end
		if (rows.size() != 0) require_true(cursor == posted[rows[0].ctx.target.function_key.host_id].size(), "extra bank/state/control write");
	endtask

	// 连续 buffer 按 4 DWORD 分段；每段保留原 Function wire requester。
	task project_external_contract_test::dma_bytes(input int unsigned	host, input bit [15:0]	requester,
		input bit [63:0]	address, input byte	data[]);
		for (int unsigned	offset = 0; offset < data.size(); offset += 16) begin
			pcie_tl_mem_tlp	m;
			int unsigned	length;
			length = data.size()-offset > 16 ? 16 : data.size()-offset;
			require_true(length%4 == 0 && address[1:0] == 0, "DMA fixture requires DWORD geometry");
			m = new("rx_dma");
			m.kind = TLP_MEM_WR;
			m.type_f = TLP_TYPE_MEM_RD;
			m.fmt = FMT_4DW_WITH_DATA;
			m.is_64bit = 1;
			m.addr = address+offset;
			m.requester_id = requester;
			m.length = length/4;
			m.first_be = 4'hf;
			m.last_be = length == 4 ? 0 : 4'hf;
			m.payload = new[length];
			foreach (m.payload[i]) m.payload[i] = data[offset+i];
			apps[host].send(m);
		end
	endtask

	// RX发布真实buffer，经Intel写payload/完成结构后比较交付；self-mask场景由用户显式rearm后发第二次消息。
	task project_external_contract_test::check_rx();
		foreach (selection.setups[h]) begin
			vio_queue_setup_t	rows[$];
			selection.setups[h].list_queues(rows);
			foreach (rows[q]) begin
				virtio_function_instance	instance;
				packet_item	packet;
				packet_item	received_packet;
				uvm_object	received[$];
				byte unsigned	wire_bytes[$];
				byte unsigned	actual_bytes[$];
				byte	bytes[];
				bit [63:0]	iova;
				project_function_policy_t	policy;
				bit	custom_mode;
				if (rows[q].tx_mode || rows[q].qpair.virtio_pair_index != 0) continue;
				foreach (env.vio_envs[h].function_instances[f])
					if (dpu_service_key_name(env.vio_envs[h].function_instances[f].service_key) == dpu_service_key_name(rows[q].service_key))
						instance = env.vio_envs[h].function_instances[f];
				require_true(instance != null, "RX instance missing");
				policy = cfg.function_policies[dpu_function_key_name(rows[q].service_key.function_key)];
				custom_mode = rows[q].queue_type == VQ_CUSTOM;
				for (int unsigned	frame = 0; frame < ($test$plusargs("PROJECT_SELF_MASK") ? 2 : 1); frame++) begin
					received.delete();
					packet = new("intel_rx_frame512");
					require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == 512;}, "RX packet randomization");
					packet.pkt.do_pack();
					require_true(virtio_net_packet_adapter::pack(packet, wire_bytes) && wire_bytes.size() == 512, "RX source bytes");
					instance.driver_agent.ops.rx_refill(rows[q].notification.local_qid, 1);
					env.vio_envs[h].host_mem.read_mem(rows[q].desc_gpa+frame*16, 8, bytes);
					iova = 0;
					foreach (bytes[i]) iova |= 64'(byte'(bytes[i]) & 8'hff) << (8*i);
					bytes = new[custom_mode ? 512 : 524];
					foreach (bytes[i]) bytes[i] = i < (custom_mode ? 0 : 12) ? 0 : byte'(wire_bytes[i-(custom_mode ? 0 : 12)]);
					dma_bytes(h, policy.requester, iova, bytes);
					if (custom_mode) begin
						bytes = new[16];
						foreach (bytes[i]) bytes[i] = 0;
						bytes[3] = 8'hd0;
						bytes[4] = 8'hc7;
						bytes[7] = 8'h82;
						dma_bytes(h, policy.requester, rows[q].device_iova+frame*16, bytes);
					end else begin
						bytes = new[4];
						bytes[0] = 8'h0c;
						bytes[1] = 2;
						bytes[2] = 0;
						bytes[3] = 0;
						dma_bytes(h, policy.requester, rows[q].desc_iova+frame*16+8, bytes);
						env.vio_envs[h].host_mem.read_mem(rows[q].desc_gpa+frame*16+12, 4, bytes);
						bytes[3] |= 8'h80;
						dma_bytes(h, policy.requester, rows[q].desc_iova+frame*16+12, bytes);
					end
					#100ns;
					if (msix_mode) begin
						instance.driver_agent.ops.rx_receive(rows[q].notification.local_qid, received, 8);
						require_true(received.size() == 0, "RX used DMA bypassed MSI-X requirement");
						if (frame != 0) begin
							bit	ok;
							string	why;
							int unsigned	before_count;
							// 模型平台明确声明的rearm端口；不是图片或用户RTL默认地址。
							before_count = requests[h].size();
							env.pcie_bar_write_by_name($sformatf("h%0d.pf0.bar0", h),
								'h2f0000+policy.vport*4, 4, 1, 0, ok, why);
							require_true(ok, why);
							#20ns;
							require_true(requests[h].size() == before_count+1 && requests[h][$].kind == TLP_MEM_WR &&
								requests[h][$].payload[0] == 1, "user self-mask rearm emitted RMW or failed");
						end
						foreach (cfg.messages[m])
							if (dpu_same_function_key(cfg.messages[m].owner, policy.key) && cfg.messages[m].local_vector == rows[q].qpair.local_msix_vector_id)
								send_memory(h, 1, 16'hffff, cfg.messages[m].address, cfg.messages[m].data);
						#100ns;
					end
					instance.driver_agent.ops.rx_receive(rows[q].notification.local_qid, received, 8);
					require_true(received.size() == 1 && $cast(received_packet, received[0]), "RX packet delivery missing");
					require_true(virtio_net_packet_adapter::pack(received_packet, actual_bytes) && actual_bytes.size() == 512, "RX length excludes Packed header");
					foreach (actual_bytes[i]) require_true(actual_bytes[i] == wire_bytes[i], "RX delivered byte mismatch");
				end
			end
		end
		`uvm_info("PROJECT_INTEL_RX_PASS", "512-byte RX delivered through Intel/Function IOVA and actual protocol completion", UVM_LOW)
	endtask

	// 仅测试平台策略失败，不伪造坏环；失败后仍可凭quiescence完整释放。
	task project_external_contract_test::check_policy_rejection();
		project_dpu_config_scope	scope;
		dpu_function_key_t	keys[$];
		int unsigned	bars[$];
		bit	ok;
		string	why;
		scope = new("policy", env.dpu_setup, keys, bars);
		env.prepare_vio_configuration(selection, ok, why);
		require_true(ok, why);
		if (policy_case == "missing_hook") env.configure_tlp_prefix(scope, ok, why);
		else if (policy_case == "pba_overlap") env.configure_msix(scope, ok, why);
		else if (policy_case inside {"qsch_overflow", "qsch_conflict"}) env.configure_qsch(selection, ok, why);
		else env.configure_vio_queues(selection, ok, why);
		require_true(!ok && why != "", {"bad platform policy accepted: ", policy_case});
		#20ns;
		foreach (apps[h]) begin
			require_true(requests[h].size() == 0, "failed category emitted a partial TLP");
			require_true(env.vio_envs[h].function_instances[0].vq_mgr.get_queue_count() != 0, "policy failure reclaimed exported DMA");
		end
		env.commit_vio_configuration(selection, ok, why);
		require_true(!ok, "bad policy reached commit");
		env.release_vio_resources(selection, 0, ok, why);
		require_true(!ok, "bad policy bypassed quiescence");
		env.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_POLICY_REJECTION_PASS", policy_case, UVM_LOW)
	endtask

	// 独立完整流程；空闲/prepare/commit 均以真实请求计数证明无访问。
	task project_external_contract_test::run_phase(uvm_phase	phase);
		project_dpu_config_scope	public_scope;
		project_dpu_config_scope	partial_scope;
		dpu_function_key_t	keys[$];
		int unsigned	bars[$];
		project_function_record_t	functions[$];
		project_config_record_t	rows[$];
		project_table_kind_e	kinds[$];
		bit	ok;
		string	why;
		int unsigned	before_count;
		phase.raise_objection(this);
		foreach (apps[h]) begin
			automatic int unsigned	host = h;
			fork
				receive_contract(host);
			join_none
		end
		#100ns;
		if ($test$plusargs("PROJECT_LATE_BAR_PRINT")) begin
			uvm_report_server	reports;
			project_bar_registry	saved_registry;
			project_dpu_setup	saved_setup;
			int unsigned	expected_reports;
			reports = uvm_report_server::get_server();
			saved_registry = env.bar_registry;
			saved_setup = env.dpu_setup;
			require_true(saved_registry != null && saved_setup != null && reports.get_id_count("DPU_BAR_MAP") == 0,
				"connect must install routes while disabled automatic BAR printing stays silent");
			saved_setup.list_functions(functions);
			expected_reports = 1;
			foreach (functions[f]) expected_reports += functions[f].bars.size();
			cfg.print_bar_map = 1;
			env.publish_dpu_configuration(ok, why);
			require_true(ok && env.bar_registry == saved_registry && env.dpu_setup == saved_setup &&
				reports.get_id_count("DPU_BAR_MAP") == expected_reports, "late first BAR map count/identity");
			env.publish_dpu_configuration(ok, why);
			require_true(ok && reports.get_id_count("DPU_BAR_MAP") == expected_reports,
				"same snapshot automatically printed more than once");
			`uvm_info("PROJECT_LATE_BAR_PRINT_PASS", "connect-installed routes retained; late first BAR map emitted once without TLP", UVM_LOW)
		end
		env.publish_dpu_configuration(ok, why);
		require_true(ok, "same snapshot republication failed");
		foreach (apps[h]) require_true(requests[h].size() == 0, "build/public export accessed DUT");
		if (policy_case != "") begin
			check_policy_rejection();
			phase.drop_objection(this);
			return;
		end
		check_mmio();
		check_registry_and_notifications();
		check_current_custom_ring();
		public_scope = new("all", env.dpu_setup, keys, bars);
		env.dpu_setup.list_functions(functions);
		keys.push_back(functions[0].key);
		partial_scope = new("split_atomic_group", env.dpu_setup, keys, bars);
		env.configure_bar_table(partial_scope, ok, why);
		require_true(!ok && env.bar_calls == 0, "partial BAR group reached hook");
		env.configure_bar_table(public_scope, ok, why);
		require_true(ok && env.bar_calls == 1, why);
		env.configure_bdf_table(public_scope, ok, why);
		require_true(ok, why);
		env.configure_pf_vf_map(public_scope, ok, why);
		require_true(ok, why);
		foreach (apps[h]) begin
			project_dpu_config_scope	host_scope;
			project_config_record_t	public_rows[$];
			project_config_record_t	part[$];
			project_table_kind_e	msix_kinds[$] = '{PROJECT_MSIX_LINEAR,PROJECT_MSIX_INFO,PROJECT_MSIX_INTERVAL,PROJECT_MSIX_CONTROL,PROJECT_MSIX_TABLE};
			keys.delete();
			foreach (functions[f]) if (functions[f].key.host_id == h) keys.push_back(functions[f].key);
			host_scope = new("msix_host", env.dpu_setup, keys, bars);
			foreach (msix_kinds[k]) begin
				require_true(probe.inspect_public(msix_kinds[k], host_scope, part, why), why);
				foreach (part[r]) public_rows.push_back(part[r]);
			end
			#20ns;
			before_count = posted[h].size();
			env.configure_msix(host_scope, ok, why);
			require_true(ok, why);
			check_writes(public_rows, before_count);
		end
		if ($test$plusargs("PROJECT_CONTROLS")) check_public_controls(public_scope);
		check_optional_state(public_scope);
		env.verify_dpu_configuration(public_scope, ok, why);
		require_true(ok, why);
		#20ns;
		before_count = requests[0].size();
		env.prepare_vio_configuration(selection, ok, why);
		require_true(ok, why);
		#20ns;
		require_true(requests[0].size() == before_count, "prepare emitted traffic");
		// 每 Host 独立 scope 使捕获计数和 shared 项去重的检查可直接对应。
		foreach (selection.setups[h]) begin
			project_vio_selection_t	subset;
			subset.setups[h] = selection.setups[h];
			subset.scopes[h] = selection.scopes[h];
			kinds = '{PROJECT_NOTIFY};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				project_vio_notify_entry_t	entry;
				entry = project_vio_notify_entry_t'(rows[r].entry);
				require_true(rows[r].binding.qpair.global_qpair_id >= 100 &&
					rows[r].binding.qpair.global_qpair_id != rows[r].binding.notification.local_qid/2,
					"noncontinuous global pair fixture lost");
				require_true(entry.global_qid == rows[r].binding.qpair.global_qpair_id,
					"notify used local pair as global ID");
			end
			before_count = posted[h].size();
			env.configure_vio_notify(subset, ok, why);
			require_true(ok, why);
			check_writes(rows, before_count);
			kinds = '{PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR, PROJECT_TC_WEIGHT};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				case (rows[r].ctx.kind)
					PROJECT_Q2TC: begin
						project_qsch_q2tc_entry_t	entry;
						entry = project_qsch_q2tc_entry_t'(rows[r].entry);
						require_true(entry.net_id == 128+rows[r].owner.pf_id*64+rows[r].owner.vf_id*16+rows[r].binding.qpair.virtio_pair_index &&
							rows[r].ctx.byte_offset == 'h610000+rows[r].ctx.table_index*4, "wide QSCH net/relative offset");
					end
					PROJECT_N2G: begin
						project_qsch_n2g_entry_t	entry;
						entry = project_qsch_n2g_entry_t'(rows[r].entry);
						require_true(entry.group_id == 64+rows[r].owner.pf_id*4+rows[r].owner.vf_id, "wide QSCH group truncated");
					end
					PROJECT_G2P: begin
						project_qsch_g2p_entry_t	entry;
						entry = project_qsch_g2p_entry_t'(rows[r].entry);
						require_true(entry.dpt == ($test$plusargs("PROJECT_ETS") ? 4 : 2)+h &&
							entry.lvl2_id == ($test$plusargs("PROJECT_ETS") ? 3 : h), "QSCH ETH/ETS destination");
					end
					PROJECT_SPWRR, PROJECT_TC_WEIGHT: require_true(rows[r].entry == (rows[r].ctx.kind == PROJECT_SPWRR ? 32'h31 : 32'h52), "scheduler control payload");
					default: require_true(0, "unexpected scheduler category");
				endcase
			end
			#20ns;
			before_count = posted[h].size();
			env.configure_qsch(subset, ok, why);
			require_true(ok, why);
			check_writes(rows, before_count);
			kinds = '{PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				if (rows[r].ctx.kind == PROJECT_VTX) begin
					project_vtx_entry_t	entry;
					entry = project_vtx_entry_t'(rows[r].entry);
					require_true(entry.virtio_mode == (rows[r].binding.queue_type == VQ_PACKED), "mixed service VTX mode crossed");
				end
			end
			#20ns;
			before_count = posted[h].size();
			env.configure_vio_queues(subset, ok, why);
			require_true(ok, why);
			check_writes(rows, before_count);
		end
		check_concurrent_port();
		env.enable_vio_queues(selection, ok, why);
		require_true(ok, why);
		env.verify_vio_configuration(selection, ok, why);
		require_true(ok, why);
		#20ns;
		before_count = requests[0].size();
		env.commit_vio_configuration(selection, ok, why);
		require_true(ok, why);
		#100ns;
		require_true(requests[0].size() == before_count, "commit/idle emitted implicit config/status traffic");
		check_rx();
		if ($test$plusargs("PROJECT_CONTROLS")) begin
			require_true(probe.control_calls[PROJECT_SPWRR] == cfg.dpu_cfg.placement_cfg.vio_requests.size() &&
				probe.control_calls[PROJECT_TC_WEIGHT] == cfg.dpu_cfg.placement_cfg.vio_requests.size() &&
				probe.control_calls[PROJECT_QUEUE_AUX] == cfg.dpu_cfg.placement_cfg.vio_requests.size()*pairs,
				"optional queue control traversal count");
			`uvm_info("PROJECT_CONTROLS_PASS", "all declared public and queue control hooks emitted checked Memory writes", UVM_LOW)
		end
		check_release_generation();
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_EXTERNAL_CONTRACT_PASS", $sformatf("checks=%0d mixed=%0d hosts=%0d", checks, $test$plusargs("PROJECT_MIXED"), host_count), UVM_LOW)
		phase.drop_objection(this);
	endtask
	// 可选入口逐项调用；初始化之后没有隐含PBA/stat读写，W1C只发显式mask。
	task project_external_contract_test::check_optional_state(input project_dpu_config_scope	scope);
		project_config_record_t	rows[$];
		project_function_record_t	functions[$];
		project_state_query_t	query_item;
		project_pfvf_drop_clear_cfg_t	clear_item;
		project_msix_pba_word_t	pba;
		bit	ok;
		string	why;
		int unsigned	before_count;
		require_true(probe.inspect_public(PROJECT_RDMA_NOTIFY, scope, rows, why), why);
		#20ns;
		before_count = posted[0].size();
		env.configure_rdma_notify(scope, ok, why);
		require_true(ok, why);
		check_writes(rows, before_count);
		env.dpu_setup.list_functions(functions);
		foreach (functions[f]) begin
			int unsigned	h;
			h = functions[f].key.host_id;
			require_true(env.get_state_context(PROJECT_MSIX_PBA, functions[f].key, 1, query_item, why), why);
			before_count = posted[h].size();
			env.read_msix_pba(query_item, pba, ok, why);
			require_true(ok && pba.pending == 0 && posted[h].size() == before_count, "PBA read emitted initialization write");
			require_true(!env.get_state_context(PROJECT_MSIX_PBA, functions[f].key, 2, query_item, why), "PBA capacity inferred or exceeded");
		end
		require_true(env.get_state_context(PROJECT_PFVF_DROP, functions[0].key, 0, query_item, why), why);
		clear_item.ctx = query_item.ctx;
		clear_item.owner = query_item.owner;
		clear_item.entry.clear_mask = 32'h00008005;
		before_count = requests[0].size();
		env.clear_pfvf_drop_status(clear_item, ok, why);
		require_true(ok, why);
		#20ns;
		require_true(requests[0].size() == before_count+1 && requests[0][$].kind == TLP_MEM_WR &&
			{requests[0][$].payload[3],requests[0][$].payload[2],requests[0][$].payload[1],requests[0][$].payload[0]} == 32'h8005,
			"explicit W1C changed mask or issued RMW");
		clear_item.entry.clear_mask = 'x;
		env.clear_pfvf_drop_status(clear_item, ok, why);
		require_true(!ok, "unknown W1C mask accepted");
		`uvm_info("PROJECT_OPTIONAL_STATE_PASS", "RDMA high/low, explicit PBA words and independent W1C", UVM_LOW)
	endtask

	// 并发线程只负责各一次真实typed写；同端口的三个TLP必须保持完整组。
	task project_external_contract_test::check_concurrent_port();
		project_vio_selection_t	subset;
		project_table_kind_e	kinds[$] = '{PROJECT_VTX};
		project_config_record_t	rows[$];
		project_config_record_t	ordered[$];
		project_vtx_cfg_t	first_item;
		project_vtx_cfg_t	second_item;
		bit	first_ok;
		bit	second_ok;
		string	first_why;
		string	second_why;
		int unsigned	before_count;
		subset.setups[0] = selection.setups[0];
		subset.scopes[0] = selection.scopes[0];
		require_true(probe.inspect_queues(subset, kinds, rows, first_why), first_why);
		require_true(rows.size() >= 2, "concurrent fixture needs two TX queues");
		first_item = '{ctx:rows[0].ctx, binding:rows[0].binding, entry:project_vtx_entry_t'(rows[0].entry)};
		second_item = '{ctx:rows[1].ctx, binding:rows[1].binding, entry:project_vtx_entry_t'(rows[1].entry)};
		#20ns;
		before_count = posted[0].size();
		fork
			env.write_vtx(first_item, first_ok, first_why);
			env.write_vtx(second_item, second_ok, second_why);
		join
		require_true(first_ok && second_ok, {first_why, second_why});
		#20ns;
		// 第二条事务必须是完整首组的clear；根据其index选择允许的两种串行顺序。
		if ({posted[0][before_count+1].payload[3],posted[0][before_count+1].payload[2],
			posted[0][before_count+1].payload[1],posted[0][before_count+1].payload[0]} == rows[0].ctx.table_index) begin
			ordered.push_back(rows[0]);
			ordered.push_back(rows[1]);
		end else begin
			ordered.push_back(rows[1]);
			ordered.push_back(rows[0]);
		end
		check_writes(ordered, before_count);
		`uvm_info("PROJECT_INDIRECT_SERIAL_PASS", "concurrent checked writes retain complete data/clear/trigger groups", UVM_LOW)
	endtask

	// 小环加速当前CQ的回绕证明；token/SG是假定组件输入，不作为Intel报文证据。
	task project_external_contract_test::check_current_custom_ring();
		custom_virtqueue	tx;
		custom_virtqueue	rx;
		virtio_sg_list	sgs[];
		virtio_sg_entry	entry;
		packet_item	tokens[6];
		uvm_object	returned;
		byte	bytes[];
		int unsigned	length;
		tx = new("current_tx_init");
		tx.setup(100, 4, env.vio_envs[0].host_mem, env.vio_envs[0].iommu, null, null, null, 16'h10, 0);
		tx.tx_mode = 1;
		tx.legacy_rx_cq = 0;
		tx.alloc_rings();
		env.vio_envs[0].host_mem.read_mem(tx.cq_addr, 2, bytes);
		require_true(bytes[0] == 0 && bytes[1] == 8'h80, "current TX CQ initial head/wrap");
		tx.free_rings();
		rx = new("current_rx_wrap");
		rx.setup(102, 4, env.vio_envs[0].host_mem, env.vio_envs[0].iommu, null, null, null, 16'h10, 0);
		rx.tx_mode = 0;
		rx.legacy_rx_cq = 0;
		rx.alloc_rings();
		sgs = new[1];
		entry.addr = 'h1000;
		entry.len = 1024;
		entry.is_indirect = 0;
		sgs[0].entries.push_back(entry);
		for (int unsigned	round = 0; round < 2; round++) begin
			for (int unsigned	i = round*3; i < round*3+3; i++) begin
				tokens[i] = new($sformatf("rx_token_%0d", i));
				require_true(rx.add_buf(sgs, 0, 1, tokens[i], 0) == i%4, "current RX producer slot/wrap");
			end
			require_true(rx.get_free_count() == 0, "current RX N-1 capacity");
			for (int unsigned	i = round*3; i < round*3+3; i++) begin
				bytes = new[16];
				foreach (bytes[b]) bytes[b] = 0;
				// 独立current CQ黄金：pkt_len=512，metadata不为0，head_split=0。
				bytes[3] = 8'hd0;
				bytes[4] = 8'hc7;
				bytes[7] = i < 4 ? 8'h82 : 8'h02;
				env.vio_envs[0].host_mem.write_mem(rx.cq_addr+(i%4)*16, bytes);
				returned = null;
				require_true(rx.poll_used(returned, length) && returned == tokens[i] && length == 512,
					"current CQ length/token/wrap did not consume");
			end
			require_true(rx.get_free_count() == 3, "current RX capacity not restored");
		end
		require_true(rx.consumer_wrap == 0 && rx.cq_consumer_wrap == 0, "current RX CQ wrap did not toggle");
		rx.free_rings();
		`uvm_info("PROJECT_CURRENT_CUSTOM_RING_PASS", "current TX CQ init and RX N-1/length/wrap", UVM_LOW)
	endtask

	// 独立冻结快照同路径跟随新租约；消息歧义使用新manager，绝不改活动Function状态。
	task project_external_contract_test::check_registry_and_notifications();
		project_bar_registry	registries[2];
		project_bar_target_t	targets[2];
		dpu_function_key_t	key;
		virtio_notification_manager	notifications;
		vio_external_queue_binding_t	binding;
		string	why;
		int unsigned	vector;
		key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
		for (int	n = 0; n < 2; n++) begin
			dpu_device_snapshot	snapshot;
			dpu_host_info_t	host;
			dpu_pcie_function_id_t	identity;
			dpu_bar_pair_lease_t	bar;
			dpu_dut_caps	caps;
			snapshot = new("changed_lease_snapshot");
			caps = new("caps");
			host = '{host_id:0, enabled:1, address_width:64, default:0};
			identity = '{domain:'{host_id:0, segment_id:0}, bdf:16'h10};
			bar = '{DPU_BAR_DEVICE_MEMORY, 0, 64'h100000+n*64'h200000, 64'h1000};
			require_true(snapshot.set_dut_caps(caps, why) && snapshot.add_host(host, why) &&
				snapshot.add_function(key, identity, why) && snapshot.add_bar(key, bar, why) &&
				snapshot.set_expected_af(key, why) && snapshot.freeze(why), why);
			registries[n] = new("changed_registry");
			require_true(registries[n].initialize(snapshot, n+1, why) && registries[n].bind_host(0, 0, why) &&
				registries[n].bind_function(key, 0, -1, 16'h10, why) && registries[n].freeze(why) &&
				registries[n].resolve_name("pf0.bar0", targets[n], why), why);
		end
		require_true(targets[0].bar_lease.base == 'h100000 && targets[1].bar_lease.base == 'h300000 &&
			dpu_same_function_key(targets[0].function_key, targets[1].function_key), "logical selector cached old lease");
		notifications = new("ambiguity_check");
		notifications.begin_external_notifications(0);
		binding = '{service_key:'{function_key:'{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0},
			service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0}, notify_encoding:VIO_NOTIFY_QID16, default:0};
		binding.local_qid = 0;
		binding.local_vector = 4;
		binding.msix_valid = 1;
		binding.message_address = 64'h900000000000;
		binding.message_data = 32'h13572468;
		require_true(notifications.register_external_queue(binding, why), why);
		require_true(notifications.match_external_message(0, binding.message_address, binding.message_data, vector) && vector == 4,
			"full message matcher failed");
		require_true(!notifications.match_external_message(1, binding.message_address, binding.message_data, vector), "message crossed Host");
		binding.local_qid = 2;
		binding.local_vector = 5;
		require_true(!notifications.register_external_queue(binding, why), "ambiguous same-domain message accepted");
		notifications.retain_external_pending(0);
		notifications.begin_external_notifications(0);
		binding.local_qid = 0;
		binding.local_vector = 4;
		require_true(notifications.register_external_queue(binding, why) && !notifications.consume_external_pending(0), "component generation retained old permit");
		`uvm_info("PROJECT_PUBLIC_IDENTITY_PASS", "changed lease path, exact message/Host and ambiguity rejection", UVM_LOW)
	endtask

endpackage
