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
	import virtio_dpu_pkg::*;
	import dpu_pcie_pkg::*;
	import project_external_integration_test_pkg::*;
	`include "uvm_macros.svh"


	// 单次UR注入的精确诊断窗口；其他severity/ID/状态照常报错，绝不全局降级。
	class project_ur_expected_report extends uvm_report_catcher;
		int unsigned	warnings;

		// 创建仅用于一次预期 UR 读的计数器。
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
	class project_contract_seq extends project_external_model_seq;
		`uvm_object_utils(project_contract_seq)
		int unsigned	control_calls[dpu_table_kind_e];

		// 创建单项配置 hook 的模型实现，不拥有 env 或 DMA 资源。
		extern function new(string	name = "project_contract_seq");

		// 可选RDMA与W1C都必须由平台显式调用，不随队列初始化自动运行。
		extern virtual task write_rdma_notify(input dpu_rdma_notify_cfg_t	item, output bit	ok, output string	why);
		// W1C仅执行显式mask，不能偷偷读状态或清除其他位。
		extern virtual task user_clear_pfvf_drop_status(input dpu_pfvf_drop_clear_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_AF控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_af(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_MSIX_CONTROL控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_msix_control_entry(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_MSIX_FUNCTION控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task user_configure_msix_function(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_QUEUE_AUX控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task write_queue_aux(input dpu_queue_control_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_COMPLETION_BDF控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task write_completion_bdf(input dpu_completion_bdf_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_PREFIX控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task write_tlp_prefix(input dpu_tlp_prefix_cfg_t	item, output bit	ok, output string	why);
		// 显式模型PROJECT_RNET控制逐项走checked helper；调用数由完整遍历断言。
		extern virtual task write_qsch_rnet(input dpu_qsch_rnet_cfg_t	item, output bit	ok, output string	why);
		extern virtual task write_control(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		// 导出实际配置记录，调用者只检查冻结值和真实发送结果。
		extern function bit inspect_queues(input dpu_cfg_scope	selected,
			input dpu_table_kind_e	kinds[$], output dpu_table_item_t	rows[$], output string	why);
		// 导出公共记录，不创建测试专属生产接口。
		extern function bit inspect_public(input dpu_table_kind_e	kind,
			input dpu_cfg_scope	scope, output dpu_table_item_t	rows[$], output string	why);
		// 测试仅开放批次入口；写入、预检和后置使能仍执行生产实现。
		extern task send_batch(
			input dpu_table_item_t	rows[$],
			output bit		ok,
			output string		why
		);
	endclass

	// 空批次和故障测试直接检查返回值，不调用默认 body 的其他配置阶段。
	task project_contract_seq::send_batch(
		input dpu_table_item_t	rows[$],
		output bit		ok,
		output string		why
	);
		write_records(rows, ok, why);
	endtask

	// 共享控制写入口按明确 kind 计数，沿用生产的冻结记录校验。
	task project_contract_seq::write_control(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		if (item.ctx.kind inside {DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT}) control_calls[item.ctx.kind]++;
		super.write_control(item, ok, why);
	endtask

	// 构造观察层，沿用原平台 hook。

	function project_contract_seq::new(string	name = "project_contract_seq");
		super.new(name);
	endfunction


	// 可选RDMA条目使用同一冻结检查和高低DWORD写序。

	task project_contract_seq::write_rdma_notify(input dpu_rdma_notify_cfg_t	item, output bit	ok, output string	why);
		super.write_rdma_notify(item, ok, why);
	endtask


	// 此模型平台声明W1C寄存器的写法；只发送用户mask，绝不读状态再回写。

	task project_contract_seq::user_clear_pfvf_drop_status(input dpu_pfvf_drop_clear_cfg_t	item, output bit	ok, output string	why);
		pcie_bar_write(item.ctx.target.function_key, item.ctx.target.bar_lease.even_bar_id,
			item.ctx.byte_offset, 4, 128'(item.entry.clear_mask), 0, ok, why);
	endtask


	// PROJECT_AF使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::user_configure_af(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_AF]++;
		write_control(item, ok, why);
	endtask


	// PROJECT_MSIX_CONTROL使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::user_configure_msix_control_entry(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_MSIX_CONTROL]++;
		write_control(item, ok, why);
	endtask


	// PROJECT_MSIX_FUNCTION使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::user_configure_msix_function(input dpu_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_MSIX_FUNCTION]++;
		write_control(item, ok, why);
	endtask


	// PROJECT_SPWRR使用平台声明布局和原typed校验，不伪造配置成功。



	// PROJECT_TC_WEIGHT使用平台声明布局和原typed校验，不伪造配置成功。



	// PROJECT_QUEUE_AUX使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::write_queue_aux(input dpu_queue_control_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_QUEUE_AUX]++;
		super.write_queue_aux(item, ok, why);
	endtask


	// PROJECT_COMPLETION_BDF使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::write_completion_bdf(input dpu_completion_bdf_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_COMPLETION_BDF]++;
		super.write_completion_bdf(item, ok, why);
	endtask


	// PROJECT_PREFIX使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::write_tlp_prefix(input dpu_tlp_prefix_cfg_t	item, output bit	ok, output string	why);
		if (!$test$plusargs("PROJECT_CONTROLS")) begin
			super.write_tlp_prefix(item, ok, why);
			return;
		end
		control_calls[DPU_TABLE_PREFIX]++;
		super.write_tlp_prefix(item, ok, why);
	endtask


	// PROJECT_RNET使用平台声明布局和原typed校验，不伪造配置成功。

	task project_contract_seq::write_qsch_rnet(input dpu_qsch_rnet_cfg_t	item, output bit	ok, output string	why);
		control_calls[DPU_TABLE_RNET]++;
		super.write_qsch_rnet(item, ok, why);
	endtask


	// 复用真实导出，只读检查有完整失败说明。

	function bit project_contract_seq::inspect_queues(input dpu_cfg_scope	selected,
		input dpu_table_kind_e	kinds[$], output dpu_table_item_t	rows[$], output string	why);
		return cfg.queue_records(selected, kinds, rows, why);
	endfunction

	// 返回真实公共条目，缺布局仍由产品拒绝。

	function bit project_contract_seq::inspect_public(input dpu_table_kind_e	kind,
		input dpu_cfg_scope	scope, output dpu_table_item_t	rows[$], output string	why);
		return cfg.public_records(kind, scope, rows, why);
	endfunction


	// 同一测试覆盖传输/顺序和实际 RX，plusarg 选择原 fixture 的协议与 Host 数。
	class project_external_contract_test extends project_external_integration_test;
		`uvm_component_utils(project_external_contract_test)

		// 创建测试组件；真实资源仍由 project_env 构建。
		extern function new(string	name, uvm_component	parent);
		project_contract_seq	probe;
		pcie_tl_mem_tlp	requests[int unsigned][$];
		int unsigned	write_start[int unsigned];
		bit	read_error;
		string	policy_case;

		// 在冻结前声明非连续 placement、完整 BAR 原子组和宽 QSCH 策略。
		extern virtual function void build_phase(uvm_phase	phase);
		// 可选成功控制仅在PROJECT_CONTROLS显式声明，未知地址全部为模型示例。
		extern function void declare_controls();
		// 按公开类别执行额外控制，检查真实Memory写与预期逐项调用数。
		extern task check_public_controls(input dpu_cfg_scope	scope);
		// 平台正常停止 DMA 后释放实际 ring，并核对共享 cfg 的视图。
		extern task check_release_generation();
		// DPU 导出必须对应实际 ring；重复查询不更换 setup、内存管理器或创建队列。
		extern function void check_queue_export();


		// BAR 读可注入 UR Completion；仍经 Intel APP 引脚发送。
		extern task receive_contract(input int unsigned	host);
		// 检查实际全部 Memory 请求的路由、长度、逐字节数据及 skip mask。
		extern task check_mmio();
		// 表项 API 独立检查高到低的 DWORD 事务，以及非法整项在首笔前拒绝。
		extern task check_table_mmio();
		// 记录各目标Host的起点；共享MSI-X管理窗口可与表项owner不在同一Host。
		extern function void capture_write_start();
		// 与捕获的 Intel 写事务逐项比较，不通过 pack/unpack 自证顺序。
		extern task check_writes(input dpu_table_item_t	rows[$]);
		// 将完整 payload 分段为真实 Memory Write，DUT 不直接操作 Host GPA。
		extern task dma_bytes(input int unsigned	host, input bit [15:0]	requester,
			input bit [63:0]	address, input byte	data[]);
		// 真实 512B RX 的 descriptor、buffer、CQ/used 均走非 identity Function IOMMU。
		extern task check_rx();
		// 可选RDMA顺序、PBA只读容量和显式W1C独立于初始化类别。
		extern task check_optional_state(input dpu_cfg_scope	scope);
		// 独立 RDMA 批次验证空选择、重复目标和发送失败；错误后不得提前使能。
		extern task check_notify_batches(input dpu_cfg_scope	scope);

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
		dpu_bar_group_policy_t	group;
		bit	rdma_declared;
		void'($value$plusargs("PROJECT_POLICY_CASE=%s", policy_case));
		project_external_model_seq::type_id::set_type_override(project_contract_seq::get_type());
		if ($test$plusargs("PROJECT_CONTROL_GUARD")) aip_cmdline_override::set_val("dpu.pfs_per_host", "2");
		if ($test$plusargs("PROJECT_MIXED")) begin
			aip_cmdline_override::set_val("vio.h0.pf0.vf1.i0.queue_type", "VQ_CUSTOM");
			aip_cmdline_override::set_val("vio.h1.pf0.vf1.i0.queue_type", "VQ_CUSTOM");
		end
		if ($test$plusargs("PROJECT_UNEQUAL")) begin
			aip_cmdline_override::set_val("dpu.pfs_per_host", "2");
			aip_cmdline_override::set_val("vio.h0.pf1.vf0.i0.enabled", "1");
		end
		super.build_phase(phase);
		if ($test$plusargs("PROJECT_LATE_BAR_PRINT")) cfg.dpu_cfg.print_bar_map = 0;
		if ($test$plusargs("PROJECT_UNEQUAL")) begin
			for (int	f = cfg.dpu_cfg.device_cfg.functions.size()-1; f >= 0; f--) begin
				dpu_function_key_t	key;
				string	name;
				key = cfg.dpu_cfg.device_cfg.functions[f].key;
				if (key.pf_id == 1 && key.kind == DPU_FUNCTION_VF && key.vf_id == 1) begin
					name = dpu_function_key_name(key);
					cfg.dpu_cfg.device_cfg.functions.delete(f);
					cfg.dpu_cfg.function_policies.delete(name);
					cfg.dpu_cfg.msix_policies.delete(name);
					cfg.dpu_cfg.message_templates.delete(name);
				end
			end
			foreach (cfg.dpu_cfg.vio_policies[name])
				if (cfg.dpu_cfg.vio_policies[name].service_key.function_key.pf_id == 1 &&
					cfg.dpu_cfg.vio_policies[name].service_key.function_key.vf_id == 1) cfg.dpu_cfg.vio_policies.delete(name);
		end
		require_true($cast(probe, config_seq), "contract sequence factory override");
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
		cfg.dpu_cfg.bar_mapping_per_lease = 0;
		group.name = "fixture_atomic_all_bars";
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			for (int unsigned	b = 0; b < 3; b++) begin
				group.functions.push_back(cfg.dpu_cfg.device_cfg.functions[f].key);
				group.bar_ids.push_back(b*2);
			end
		end
		cfg.dpu_cfg.bar_group_policies.push_back(group);
		foreach (cfg.dpu_cfg.vio_policies[name]) begin
			cfg.dpu_cfg.vio_policies[name].net_base = 128 + cfg.dpu_cfg.vio_policies[name].service_key.function_key.pf_id*64 + cfg.dpu_cfg.vio_policies[name].service_key.function_key.vf_id*16;
			cfg.dpu_cfg.vio_policies[name].group_id = 64 + cfg.dpu_cfg.vio_policies[name].service_key.function_key.pf_id*4 + cfg.dpu_cfg.vio_policies[name].service_key.function_key.vf_id;
			cfg.dpu_cfg.vio_policies[name].eth_ports = $test$plusargs("PROJECT_ETS") ? 4 : 2;
			cfg.dpu_cfg.vio_policies[name].ets = $test$plusargs("PROJECT_ETS");
			cfg.dpu_cfg.vio_policies[name].ets_priority = 3;
			// 双Host共享同一物理RAM时明确保留不重叠的descriptor槽区间。
			cfg.dpu_cfg.vio_policies[name].prefetch_ram = "fixture_shared_ram";
			cfg.dpu_cfg.vio_policies[name].prefetch_start += cfg.dpu_cfg.vio_policies[name].service_key.function_key.host_id*8192 + cfg.dpu_cfg.vio_policies[name].service_key.function_key.pf_id*1024;
			case (policy_case)
				"alignment": cfg.dpu_cfg.vio_policies[name].prefetch_start = 1;
				"capacity": cfg.dpu_cfg.vio_policies[name].prefetch_start = 32768;
				"fpga_high": begin
					cfg.dpu_cfg.vio_policies[name].fpga = 1;
					cfg.dpu_cfg.vio_policies[name].prefetch_start = 16384;
				end
				"prefetch_depth": begin
					cfg.dpu_cfg.vio_policies[name].vrx.dsc_pre_max_num = 0;
					cfg.dpu_cfg.vio_policies[name].prefetch_slots = 256;
				end
				"overlap": cfg.dpu_cfg.vio_policies[name].prefetch_start = 0;
				"headsplit": cfg.dpu_cfg.vio_policies[name].vrx.head_dsc_len = 1;
				"reserved": cfg.dpu_cfg.vio_policies[name].vtx.reserved_111_106 = 1;
				"unknown": cfg.dpu_cfg.vio_policies[name].vrx.dsc_dma_num = 'x;
				"qsch_overflow": cfg.dpu_cfg.vio_policies[name].net_base = 1024;
				"qsch_conflict": cfg.dpu_cfg.vio_policies[name].net_base = 128;
				default: ;
			endcase
		end
		add_layout(DPU_TABLE_RDMA_NOTIFY, 8, 256, 'h200000, 'hc000);
		add_layout(DPU_TABLE_PFVF_DROP, 4, 128, 'h200000, 'ha000);
		add_layout(DPU_TABLE_MSIX_PBA, 8, 2, 'h100000, 'h10000);
		foreach (cfg.dpu_cfg.function_policies[name]) begin
			dpu_control_cfg_t	control;
			dpu_rdma_notify_entry_t	entry;
			if ($test$plusargs("PROJECT_SELF_MASK")) cfg.dpu_cfg.msix_policies[name].self_mask = 1;

			if (cfg.dpu_cfg.function_policies[name].key.kind != DPU_FUNCTION_VF) continue;
			if (rdma_declared && !$test$plusargs("PROJECT_NOTIFY_BATCH")) continue;
			entry = '0;
			entry.host_id = cfg.dpu_cfg.function_policies[name].key.host_id;
			entry.vf_id = cfg.dpu_cfg.function_policies[name].key.vf_id;
			entry.base_addr_60_13 = 48'h12345678;
			control.ctx.kind = DPU_TABLE_RDMA_NOTIFY;
			control.ctx.table_index = cfg.dpu_cfg.function_policies[name].key.vf_id;
			control.owner = cfg.dpu_cfg.function_policies[name].key;
			control.value = 128'(entry);
			control.writable_mask = 128'h07ff_ffff_ffff_ffff;
			cfg.dpu_cfg.platform_controls.push_back(control);
			rdma_declared = 1;
		end

		if ($test$plusargs("PROJECT_CONTROLS")) declare_controls();
		if (policy_case inside {"control_scope_missing", "control_consumer_unknown"}) begin
			foreach (cfg.dpu_cfg.platform_controls[c]) if (cfg.dpu_cfg.platform_controls[c].ctx.kind == DPU_TABLE_AF) begin
				if (policy_case == "control_scope_missing") cfg.dpu_cfg.platform_controls[c].consumers_complete = 0;
				else begin
					dpu_service_key_t	missing;
					missing = '{function_key:cfg.dpu_cfg.platform_controls[c].owner, service_kind:DPU_SERVICE_VIO_NET, service_instance_id:99};
					cfg.dpu_cfg.platform_controls[c].consumers.push_back(missing);
				end
			end
		end

		if (policy_case == "pba_overlap") begin
			foreach (cfg.dpu_cfg.msix_policies[name]) if (cfg.dpu_cfg.function_policies[name].key.kind == DPU_FUNCTION_PF) begin
				cfg.dpu_cfg.msix_policies[name].table_present = 1;
				cfg.dpu_cfg.msix_policies[name].table_bar = 0;
				cfg.dpu_cfg.msix_policies[name].table_offset = 'h120000;
				cfg.dpu_cfg.msix_policies[name].table_size = 1024;
				cfg.dpu_cfg.msix_policies[name].pba_present = 1;
				cfg.dpu_cfg.msix_policies[name].pba_bar = 0;
				cfg.dpu_cfg.msix_policies[name].pba_offset = 'h120000;
				cfg.dpu_cfg.msix_policies[name].pba_words = 1;
			end
		end
		if (policy_case == "missing_layout") cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_VRX);
		if (policy_case == "missing_hook") begin
			add_layout(DPU_TABLE_PREFIX, 8, 128, 'h100000, 'h18000);
			foreach (cfg.dpu_cfg.function_policies[name]) cfg.dpu_cfg.function_policies[name].prefix_enabled = 1;
		end
	endfunction

	// 可选控制使用明确的模型地址/值；SW Requester由固定BDF输入分配后再冻结。
	function void project_external_contract_test::declare_controls();
		dpu_table_kind_e	control_kinds[$] = '{DPU_TABLE_AF, DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION,
			DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_QUEUE_AUX, DPU_TABLE_RNET};
		require_true(host_count == 1, "control fixture is one explicit Host platform");
		foreach (control_kinds[k])
			add_layout(control_kinds[k], 4, 2048, 'h700000+k*'h10000, 0);
		// AF只配置真实PF0；不把该平台寄存器强制成每个VF的依赖。
		cfg.dpu_cfg.table_layouts[DPU_TABLE_AF].required = 0;
		add_layout(DPU_TABLE_COMPLETION_BDF, 4, 4096, 'h300000, 'h18000);
		cfg.dpu_cfg.table_layouts[DPU_TABLE_RNET].table_offset = 'h15000;
		cfg.dpu_cfg.table_layouts[DPU_TABLE_RNET].capacity = 256;
		add_layout(DPU_TABLE_PREFIX, 8, 256, 'h100000, 'h18000);
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			dpu_function_key_t	key;
			string	name;
			dpu_control_cfg_t	control;
			dpu_table_kind_e	public_kinds[$] = '{DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION, DPU_TABLE_RNET};
			key = cfg.dpu_cfg.device_cfg.functions[f].key;
			name = dpu_function_key_name(key);
			cfg.dpu_cfg.device_cfg.functions[f].bdf_mode = DPU_ALLOC_PINNED;
			cfg.dpu_cfg.device_cfg.functions[f].pinned_bdf = 16'h20+f;
			cfg.dpu_cfg.function_policies[name].mode = DPU_HOST_SW;
			cfg.dpu_cfg.function_policies[name].requester = 16'h20+f;
			cfg.dpu_cfg.function_policies[name].prefix_enabled = 1;
			cfg.dpu_cfg.function_policies[name].prefix = 32'h12340000+f;
			cfg.dpu_cfg.msix_policies[name].table_only_enable = 0;
			control.owner = key;
			control.consumers_complete = 1;
			control.ctx.table_index = cfg.dpu_cfg.function_policies[name].vport;
			control.writable_mask = 32'hffff;
			foreach (public_kinds[k]) begin
				control.ctx.kind = public_kinds[k];
				control.consumers.delete();
				if ($test$plusargs("PROJECT_CONTROL_GUARD") && key.kind == DPU_FUNCTION_PF && key.pf_id == 0 && public_kinds[k] inside {DPU_TABLE_MSIX_CONTROL, DPU_TABLE_MSIX_FUNCTION}) begin
					dpu_service_key_t	shared_service;
					require_true(cfg.dpu_cfg.placement_cfg.vio_requests[0].fixed_devices.size() == 1, "shared control needs explicit service owner");
					shared_service =
						'{function_key:cfg.dpu_cfg.placement_cfg.vio_requests[0].fixed_devices[0], service_kind:DPU_SERVICE_VIO_NET,
						service_instance_id:cfg.dpu_cfg.placement_cfg.vio_requests[0].service_instance_id};
					control.consumers.push_back(shared_service);
					control.consumers.push_back(shared_service); // canonical 输出必须去重。
				end
				control.value = public_kinds[k] == DPU_TABLE_RNET ? (key.host_id << 1) | 1 : 32'h21+k;
				cfg.dpu_cfg.platform_controls.push_back(control);
			end
			if (key.kind == DPU_FUNCTION_PF && key.pf_id == 0) begin
				control.consumers.delete();
				control.ctx.kind = DPU_TABLE_AF;
				control.value = 32'h15;
				cfg.dpu_cfg.platform_controls.push_back(control);
			end
		end
		foreach (cfg.dpu_cfg.placement_cfg.vio_requests[r]) begin
			dpu_control_cfg_t	control;
			dpu_service_key_t	service;
			dpu_table_kind_e	shared_kinds[$] = '{DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT};
			require_true(cfg.dpu_cfg.placement_cfg.vio_requests[r].fixed_devices.size() == 1,
				"controls require the explicit one-owner placement request");
			control.owner = cfg.dpu_cfg.placement_cfg.vio_requests[r].fixed_devices[0];
			service = '{function_key:control.owner, service_kind:DPU_SERVICE_VIO_NET,
				service_instance_id:cfg.dpu_cfg.placement_cfg.vio_requests[r].service_instance_id};
			control.consumers.push_back(service);
			control.consumers_complete = 1;
			control.ctx.table_index = cfg.dpu_cfg.function_policies[dpu_function_key_name(control.owner)].vport;
			control.writable_mask = 32'hff;
			foreach (shared_kinds[k]) begin
				control.ctx.kind = shared_kinds[k];
				control.value = k == 0 ? 32'h31 : 32'h52;
				cfg.dpu_cfg.platform_controls.push_back(control);
			end
			for (int unsigned	q = 0; q < pairs; q++) begin
				control.ctx.kind = DPU_TABLE_QUEUE_AUX;
				control.ctx.table_index = 100+r*16+q*3;
				control.value = 32'h73;
				cfg.dpu_cfg.platform_controls.push_back(control);
			end
		end
	endfunction

	// 公共额外类别逐项比对真实Intel发送，防止空catalog冒充成功。
	task project_external_contract_test::check_public_controls(input dpu_cfg_scope	scope);
		dpu_table_kind_e	kinds[$] = '{DPU_TABLE_AF, DPU_TABLE_COMPLETION_BDF, DPU_TABLE_PREFIX, DPU_TABLE_RNET, DPU_TABLE_MSIX_FUNCTION};
		dpu_table_item_t	rows[$];
		bit	ok;
		string	why;
		int unsigned	before_count;
		foreach (kinds[k]) begin
			require_true(probe.inspect_public(kinds[k], scope, rows, why) && rows.size() != 0, why);
			if (kinds[k] == DPU_TABLE_COMPLETION_BDF) foreach (rows[r]) begin
				dpu_function_record_t	owner;
				dpu_completion_bdf_entry_t	entry;
				require_true(cfg.dpu_cfg.get_function(rows[r].owner, owner), "Completion owner absent");
				entry = dpu_completion_bdf_entry_t'(rows[r].entry);
				require_true(entry.completion_id == owner.pcie_id.bdf && entry.valid,
					"Completion BDF did not use actual frozen SW identity");
			end
			#20ns;
			capture_write_start();
			case (kinds[k])
				DPU_TABLE_AF: config_seq.configure_af(scope, ok, why);
				DPU_TABLE_COMPLETION_BDF: config_seq.configure_completion_bdf_table(scope, ok, why);
				DPU_TABLE_PREFIX: config_seq.configure_tlp_prefix(scope, ok, why);
				DPU_TABLE_RNET: config_seq.configure_qsch_rnet(scope, ok, why);
				DPU_TABLE_MSIX_FUNCTION: config_seq.enable_msix(scope, ok, why);
				default: require_true(0, "unknown optional public test category");
			endcase
			require_true(ok && probe.control_calls[kinds[k]] == rows.size(), why);
			check_writes(rows);
		end
		require_true(probe.inspect_public(DPU_TABLE_MSIX_CONTROL, scope, rows, why) &&
			probe.control_calls[DPU_TABLE_MSIX_CONTROL] == rows.size(), "MSI-X control traversal count");
	endtask

	// 测试模型完成业务且无在途 DMA，按正常收尾路径释放导出的资源。
	task project_external_contract_test::check_release_generation();
		bit	ok;
		string	why;

		config_seq.release_vio_resources(selection, 1, ok, why);
		require_true(ok && cfg.dpu_cfg.queues_by_host.num() == 0, why);
	endtask

	// 期望直接取 VIO 的实际 setup 和队列管理器，不使用 DPU 写表结果反推 ring。
	// 同时确认 PCIe 与 VIO 使用同一 Host backing，重复导出仅复制配置值。
	function void project_external_contract_test::check_queue_export();
		foreach (env.vio_envs[h]) begin
			vio_external_setup	setup;
			vio_queue_setup_t	actual[$];
			dpu_vio_queue_t		exported[$];
			int unsigned		queue_count;
			int unsigned		after_count;
			string				why;

			setup = env.vio_envs[h].get_external_setup();
			require_true(setup != null, "prepared Host has no actual VIO setup");
			setup.list_queues(actual);
			require_true(
				cfg.pcie_cfg.host_mem_by_root[cfg.tl_slot_by_host[h]] == env.vio_envs[h].host_mem &&
				env.shared_pool.get_host(h) == env.vio_envs[h].host_mem,
				"PCIe and VIO do not share the Host memory manager"
			);

			queue_count = 0;
			foreach (env.vio_envs[h].function_instances[f])
				queue_count += env.vio_envs[h].function_instances[f].vq_mgr.get_queue_count();

			repeat (2) begin
				require_true(env.vio_envs[h].export_dpu_queues(setup, null, exported, why), why);
				require_true(
					exported.size() == actual.size() &&
					exported.size() == cfg.dpu_cfg.queues_by_host[h].size(),
					"DPU export changed the number of actual queues"
				);

				foreach (actual[q]) begin
					require_true(
						exported[q] === cfg.dpu_cfg.queues_by_host[h][q] &&
						exported[q].snapshot == cfg.dpu_cfg.device_snapshot &&
						exported[q].generation == setup.get_generation() &&
						exported[q].service_key == actual[q].service_key &&
						exported[q].qpair == actual[q].qpair &&
						exported[q].desc_iova == actual[q].desc_iova &&
						exported[q].local_qid == actual[q].notification.local_qid &&
						exported[q].queue_size == actual[q].queue_size &&
						exported[q].virtio_mode == (actual[q].queue_type == VQ_PACKED) &&
						exported[q].notify_address == actual[q].notify_address,
						"DPU export differs from the allocated VIO descriptor/identity"
					);
				end
			end

			after_count = 0;
			foreach (env.vio_envs[h].function_instances[f])
				after_count += env.vio_envs[h].function_instances[f].vq_mgr.get_queue_count();
			require_true(
				env.vio_envs[h].get_external_setup() == setup && after_count == queue_count,
				"export replaced the VIO generation or allocated extra queues"
			);
		end
		`uvm_info("PROJECT_QUEUE_EXPORT_PASS",
			"actual descriptors, repeated export and shared Host memory checked", UVM_LOW)
	endfunction

	// 捕获完整请求，并以实际 Completion 注入读失败；不拦截产品 receive 路径。
	// 此按表合同测试从已就绪 AF 开始，0x1010 返回状态8；声明/故障时序由 bare_config 测试覆盖。
	task project_external_contract_test::receive_contract(input int unsigned	host);
		dpu_bar_target_t	af_target;
		string			why;

		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", af_target, why), why);

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
				if (!read_error && host == 0 && m.addr == af_target.bar_lease.base + 'h1010) begin
					require_true(c.payload.size() == 4, "AF status read must be one DWORD");
					c.payload = '{8'h8, 8'h0, 8'h0, 8'h0};
				end
				apps[host].send(c);
			end
		end
	endtask

	// 全宽和边缘稀疏 byte enables 经过 codec，非法输入在捕获计数增加前拒绝。
	task project_external_contract_test::check_mmio();
		dpu_function_record_t	functions[$];
		dpu_bar_target_t	target;
		logic [127:0]	value;
		logic [127:0]	actual;
		logic [127:0]	expected;
		logic [31:0]	skip;
		bit	ok;
		string	why;
		int unsigned	before_count;
		project_ur_expected_report	catcher;
		cfg.dpu_cfg.list_functions(functions);
		foreach (functions[f]) begin
			int unsigned	h;
			h = functions[f].key.host_id;
			// BAR2 是真实偶数 BAR ID，不是角色或列表下标。
			require_true(cfg.dpu_cfg.bar_map.resolve_function(functions[f].key, 2, target, why), why);
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
					config_seq.pcie_bar_write(functions[f].key, 2, 'h300+length*32+masked*16, length, value, skip, ok, why);
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
							require_true(m.cq_route.bar_id == 2 && m.cq_route.pf_index == cfg.dpu_cfg.frozen_functions[dpu_function_key_name(target.function_key)].intel_pf &&
								m.cq_route.is_vf == (target.function_key.kind == DPU_FUNCTION_VF) &&
								(!(target.function_key.kind == DPU_FUNCTION_VF) || m.cq_route.vf_index == cfg.dpu_cfg.frozen_functions[dpu_function_key_name(target.function_key)].intel_vf), "actual Intel VF/PF/BAR sideband");
							foreach (m.payload[i]) if (pcie_tl_mem_lane_enabled(m, i)) begin
								int unsigned	lane;
								lane = pcie_tl_mem_wire_addr(m)+i-(target.bar_lease.base+'h300+length*32+masked*16);
								require_true(lane < length && !skip[lane] && !seen[lane] && m.payload[i] == byte'(8'h31+lane), "wire address/payload/enable mismatch");
								seen[lane] = 1;
							end
						end
						for (int unsigned	i = 0; i < length; i++) require_true(seen[i] == !skip[i], "missing enabled wire byte");
					end
					config_seq.pcie_bar_read(functions[f].key, 2, 'h300+length*32+masked*16, length, 0, actual, ok, why);
					require_true(ok && actual == expected, "explicit MMIO readback differs");
				end
			end
			before_count = requests[h].size();
			config_seq.pcie_bar_write(functions[f].key, 2, target.bar_lease.size-4, 8, 0, 0, ok, why);
			require_true(!ok, "out of BAR access accepted");
			config_seq.pcie_bar_write(functions[f].key, 2, 'hfff, 4, 0, 0, ok, why);
			require_true(!ok, "unaligned access accepted");
			config_seq.pcie_bar_write(functions[f].key, 2, 'h100, 4, 'z, 0, ok, why);
			require_true(!ok, "Z data narrowed into valid data");
			#20ns;
			require_true(requests[h].size() == before_count, "invalid MMIO emitted a TLP");
		end
		catcher = new();
		uvm_report_cb::add(null, catcher);
		read_error = 1;
		config_seq.pcie_bar_read_by_name("h0.pf0.bar0", 'h40, 4, 0, actual, ok, why);
		require_true(!ok && why != "", "real UR Completion was reported as successful read");
		read_error = 0;
		#20ns;
		uvm_report_cb::delete(null, catcher);
		require_true(catcher.warnings == 1, "UR warning count differs from one injected read");
		require_true(env.pcie_env.scb.mismatched == 0 && env.pcie_env.scb.unexpected == 0,
			"declared UR was not matched by scoreboard");
		`uvm_info("PROJECT_MMIO_CONTRACT_PASS", "4/8/12/16B, masks, route, posted/readback and real UR Completion", UVM_LOW)
	endtask

	// 使用非对称字节验证字序与字节序；每个真实 PF/VF 的 BAR2 由 registry 解析。
	// 无效跨度、宽度、X/Z 或超宽 payload 必须零发送，不能只检查每笔局部 DWORD。
	task project_external_contract_test::check_table_mmio();
		dpu_function_record_t	functions[$];
		dpu_bar_target_t			target;
		logic [127:0]				value;
		logic [63:0]				offset;
		int unsigned				length;
		int unsigned				before_count;
		int unsigned				h;
		bit							ok;
		string						why;

		cfg.dpu_cfg.list_functions(functions);

		foreach (functions[f]) begin
			h = functions[f].key.host_id;
			require_true(cfg.dpu_cfg.bar_map.resolve_function(functions[f].key, 2, target, why), why);

			for (length = 4; length <= 16; length += 4) begin
				value = '0;
				offset = 'h800 + length * 16;

				for (int unsigned	i = 0; i < length; i++) begin
					value[i * 8 +: 8] = 8'h51 + i;
				end

				before_count = requests[h].size();
				config_seq.pcie_table_write_by_name(target.canonical_name, offset, length, value, ok, why);
				require_true(ok, why);
				#20ns;
				require_true(requests[h].size() == before_count + length / 4, "table DWORD count/readback");

				for (int unsigned	n = 0; n < length / 4; n++) begin
					pcie_tl_mem_tlp	m;
					int unsigned	byte_index;

					m = requests[h][before_count + n];
					byte_index = length - 4 - 4 * n;

					require_true(m.kind == TLP_MEM_WR && m.length == 1 && m.payload.size() == 4 &&
						m.first_be == 4'hf && m.last_be == 0, "table API emitted non-DWORD write");
					require_true(pcie_tl_mem_wire_addr(m) == target.bar_lease.base + offset + byte_index,
						"table API address order must descend");
					require_true(m.cq_route.bar_id == 2 && m.cq_route.pf_index == cfg.dpu_cfg.frozen_functions[dpu_function_key_name(target.function_key)].intel_pf &&
						m.cq_route.is_vf == (target.function_key.kind == DPU_FUNCTION_VF) &&
						(!(target.function_key.kind == DPU_FUNCTION_VF) || m.cq_route.vf_index == cfg.dpu_cfg.frozen_functions[dpu_function_key_name(target.function_key)].intel_vf), "table API route");

					foreach (m.payload[i]) begin
						require_true(m.payload[i] == byte'(8'h51 + byte_index + i), "table API byte order");
					end
				end
			end

			before_count = requests[h].size();

			for (int unsigned	bad = 0; bad < 8; bad++) begin
				length = 16;
				offset = 'h900;
				value = '0;

				case (bad)
					0: offset = target.bar_lease.size - 4;
					1: offset = 'hff8;
					2: offset = 'h901;
					3: offset = 'x;
					4: value = 'x;
					5: length = 0;
					6: length = 20;
					7: begin
						length = 8;
						value[64] = 1;
					end
				endcase

				config_seq.pcie_table_write_by_name(target.canonical_name, offset, length, value, ok, why);
				require_true(!ok, "invalid table operation accepted");
			end

			#20ns;
			require_true(requests[h].size() == before_count, "invalid whole table sent a partial request");
		end

		`uvm_info("PROJECT_TABLE_DWORD_PASS", "4/8/12/16B high-to-low DWORDs, actual PF/VF BAR routing, whole-span preflight", UVM_LOW)
	endtask

	// 在配置入口前保存全部接收队列位置；按实际BAR目标域比对，不按owner重用其他Host的cursor。
	function void project_external_contract_test::capture_write_start();
		foreach (apps[h]) write_start[h] = posted[h].size();
	endfunction

	// 逐条重建规格要求的 DWORD 地址/值；间接项必须四笔数据后才出现 clear/trigger。
	// Notify 批次最后按实际管理 BAR 检查一次使能；期望值直接来自硬件规格。
	task project_external_contract_test::check_writes(input dpu_table_item_t	rows[$]);
		int unsigned	cursor[int unsigned];
		bit	seen[string];
		dpu_bar_target_t	notify_targets[string];
		cursor = write_start;
		#20ns;
		foreach (rows[r]) begin
			int unsigned	h;
			int unsigned	count;
			int unsigned	data_count;
			if (seen.exists(rows[r].ctx.record_key)) continue;
			seen[rows[r].ctx.record_key] = 1;
			if (rows[r].ctx.kind inside {DPU_TABLE_NOTIFY, DPU_TABLE_RDMA_NOTIFY}) begin
				notify_targets[rows[r].ctx.target.canonical_name] = rows[r].ctx.target;
			end
			h = rows[r].ctx.target.function_key.host_id;
			// MSI-X线性表可能统一经Host0写入，各目标域独立推进接收位置。
			data_count = rows[r].ctx.layout.entry_bytes / 4;
			count = data_count + (rows[r].ctx.layout.indirect ? 2 : 0);
			for (int unsigned	n = 0; n < count; n++) begin
				pcie_tl_mem_tlp	m;
				bit [63:0]	offset;
				logic [127:0]	expected;
				int unsigned	length;
				require_true(cursor.exists(h) && cursor[h] < posted[h].size(), "missing expected table transaction");
				m = posted[h][cursor[h]++];
				length = 4;
				if (n < data_count) begin
					offset = rows[r].ctx.layout.indirect ?
						rows[r].ctx.layout.module_offset + rows[r].ctx.layout.data_port : rows[r].ctx.byte_offset;
					offset += (data_count - 1 - n) * 4;
					expected = 128'(rows[r].entry[(data_count - 1 - n) * 32 +: 32]);
				end else begin
					offset = rows[r].ctx.layout.module_offset + rows[r].ctx.layout.control_port;
					expected = rows[r].ctx.layout.control_fixed | (rows[r].ctx.table_index << rows[r].ctx.layout.index_shift);
					if (n == data_count + 1) expected |= rows[r].ctx.layout.trigger_mask;
				end
				require_true(pcie_tl_mem_wire_addr(m) == rows[r].ctx.target.bar_lease.base+offset &&
					m.length*4 == length && m.cq_route.pf_index == 0 && !m.cq_route.is_vf,
					$sformatf("table %s record=%s segment=%0d actual_addr=%h expected_addr=%h actual_len=%0d expected_len=%0d PF=%0d VFactive=%0d",
						rows[r].ctx.kind.name(), rows[r].ctx.record_key, n, pcie_tl_mem_wire_addr(m),
						rows[r].ctx.target.bar_lease.base+offset, m.length*4, length, m.cq_route.pf_index, m.cq_route.is_vf));
				require_true(m.payload.size() == 4 && m.first_be == 4'hf && m.last_be == 0,
					"table write must be one fully enabled DWORD");
				foreach (m.payload[i]) require_true(m.payload[i] == byte'(expected[i*8 +: 8]), "table payload differs");
			end
		end
		foreach (notify_targets[name]) begin
			dpu_bar_target_t	target;
			pcie_tl_mem_tlp		m;
			int unsigned		h;

			target = notify_targets[name];
			h      = target.function_key.host_id;
			require_true(cursor.exists(h) && cursor[h] < posted[h].size(),
				"missing Notify enable after table writes");
			m = posted[h][cursor[h]++];
			require_true(
				pcie_tl_mem_wire_addr(m) == target.bar_lease.base + 64'h0008_0044 &&
				m.length == 1 && m.payload.size() == 4 &&
				m.first_be == 4'hf && m.last_be == 0,
				"Notify enable address/width/byte enables differ"
			);
			require_true(
				m.payload[0] == 8'h01 && m.payload[1] == 8'h00 &&
				m.payload[2] == 8'h00 && m.payload[3] == 8'h00,
				"Notify enable must write DWORD 1"
			);
		end
		foreach (cursor[h])
			require_true(cursor[h] == posted[h].size(), "extra bank/state/control write");
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
		foreach (cfg.dpu_cfg.queues_by_host[h]) begin
			vio_queue_setup_t	rows[$];
			env.vio_envs[h].get_external_setup().list_queues(rows);
			foreach (rows[q]) begin
				virtio_function_instance	instance;
				packet_item	packet;
				packet_item	received_packet;
				uvm_object	received[$];
				byte unsigned	wire_bytes[$];
				byte unsigned	actual_bytes[$];
				byte	bytes[];
				bit [63:0]	iova;
				dpu_function_policy_t	policy;
				bit	custom_mode;
				if (rows[q].tx_mode || rows[q].qpair.virtio_pair_index != 0) continue;
				foreach (env.vio_envs[h].function_instances[f])
					if (dpu_service_key_name(env.vio_envs[h].function_instances[f].service_key) == dpu_service_key_name(rows[q].service_key))
						instance = env.vio_envs[h].function_instances[f];
				require_true(instance != null, "RX instance missing");
				policy = cfg.dpu_cfg.function_policies[dpu_function_key_name(rows[q].service_key.function_key)];
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
							config_seq.pcie_bar_write_by_name($sformatf("h%0d.pf0.bar0", h),
								'h2f0000+policy.vport*4, 4, 1, 0, ok, why);
							require_true(ok, why);
							#20ns;
							require_true(requests[h].size() == before_count+1 && requests[h][$].kind == TLP_MEM_WR &&
								requests[h][$].payload[0] == 1, "user self-mask rearm emitted RMW or failed");
						end
						foreach (cfg.dpu_cfg.messages[m])
							if (dpu_same_function_key(cfg.dpu_cfg.messages[m].owner, policy.key) && cfg.dpu_cfg.messages[m].local_vector == rows[q].qpair.local_msix_vector_id)
								send_memory(h, 1, 16'hffff, cfg.dpu_cfg.messages[m].address, cfg.dpu_cfg.messages[m].data);
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
		dpu_cfg_scope	scope;
		dpu_function_key_t	keys[$];
		int unsigned	bars[$];
		bit	ok;
		string	why;
		scope = new("policy", cfg.dpu_cfg.device_snapshot, keys, bars);
		config_seq.prepare_vio_configuration(selection, ok, why);
		require_true(ok, why);
		check_queue_export();
		if (policy_case inside {"control_scope_missing", "control_consumer_unknown"}) config_seq.configure_af(scope, ok, why);
		else if (policy_case == "missing_hook") config_seq.configure_tlp_prefix(scope, ok, why);
		else if (policy_case == "pba_overlap") config_seq.configure_msix(scope, ok, why);
		else if (policy_case inside {"qsch_overflow", "qsch_conflict"}) config_seq.configure_qsch(selection, ok, why);
		else config_seq.configure_vio_queues(selection, ok, why);
		require_true(!ok && why != "", {"bad platform policy accepted: ", policy_case});
		if (policy_case == "control_scope_missing") require_true(why == "platform control requires complete explicit consumer scope" && probe.control_calls[DPU_TABLE_AF] == 0, "missing scope reached hook/wrong diagnostic");
		if (policy_case == "control_consumer_unknown") require_true(why == "control consumer absent from frozen topology" && probe.control_calls[DPU_TABLE_AF] == 0, "unknown consumer reached hook/wrong diagnostic");
		#20ns;
		foreach (apps[h]) begin
			require_true(requests[h].size() == 0, "failed category emitted a partial TLP");
			require_true(env.vio_envs[h].function_instances[0].vq_mgr.get_queue_count() != 0, "policy failure reclaimed exported DMA");
		end
		config_seq.release_vio_resources(selection, 0, ok, why);
		require_true(!ok, "bad policy bypassed quiescence");
		config_seq.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_POLICY_REJECTION_PASS", policy_case, UVM_LOW)
	endtask

	// 独立完整流程；空闲/prepare/commit 均以真实请求计数证明无访问。
	task project_external_contract_test::run_phase(uvm_phase	phase);
		dpu_cfg_scope	public_scope;
		dpu_cfg_scope	partial_scope;
		dpu_function_key_t	keys[$];
		int unsigned	bars[$];
		dpu_function_record_t	functions[$];
		dpu_table_item_t	rows[$];
		dpu_table_kind_e	kinds[$];
		bit	ok;
		string	why;
		int unsigned	before_count;
		phase.raise_objection(this);
		config_seq.set_sequencer(env.pcie_env.rc_agents[cfg.tl_slot_by_host[0]].sequencer);
		foreach (apps[h]) begin
			automatic int unsigned	host = h;
			fork
				receive_contract(host);
			join_none
		end
		#100ns;
		if ($test$plusargs("PROJECT_LATE_BAR_PRINT")) begin
			uvm_report_server	reports;
			dpu_bar_map	saved_registry;
			dpu_device_snapshot	saved_setup;
			int unsigned	expected_reports;
			reports = uvm_report_server::get_server();
			saved_registry = cfg.dpu_cfg.bar_map;
			saved_setup = cfg.dpu_cfg.device_snapshot;
			require_true(saved_registry != null && saved_setup != null && reports.get_id_count("DPU_BAR_MAP") == 0,
				"connect must install routes while disabled automatic BAR printing stays silent");
			// 每份快照现在以一条分组消息输出；再次发布不得重复打印。
			expected_reports = 1;
			cfg.dpu_cfg.print_bar_map = 1;
			env.publish_dpu_configuration(ok, why);
			require_true(ok && cfg.dpu_cfg.bar_map == saved_registry && cfg.dpu_cfg.device_snapshot == saved_setup &&
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
		check_table_mmio();
		check_registry_and_notifications();
		check_current_custom_ring();
		public_scope = new("all", cfg.dpu_cfg.device_snapshot, keys, bars);
		cfg.dpu_cfg.list_functions(functions);
		keys.push_back(functions[0].key);
		partial_scope = new("split_atomic_group", cfg.dpu_cfg.device_snapshot, keys, bars);
		config_seq.configure_bar_table(partial_scope, ok, why);
		require_true(!ok && config_seq.bar_calls == 0, "partial BAR group reached hook");
		config_seq.configure_bar_table(public_scope, ok, why);
		require_true(ok && config_seq.bar_calls == 1, why);
		config_seq.configure_bdf_table(public_scope, ok, why);
		require_true(ok, why);
		config_seq.configure_pf_vf_map(public_scope, ok, why);
		require_true(ok, why);
		foreach (apps[h]) begin
			dpu_cfg_scope	host_scope;
			dpu_table_item_t	public_rows[$];
			dpu_table_item_t	part[$];
			dpu_table_kind_e	msix_kinds[$] = '{DPU_TABLE_MSIX_LINEAR,DPU_TABLE_MSIX_INFO,DPU_TABLE_MSIX_INTERVAL,DPU_TABLE_MSIX_CONTROL,DPU_TABLE_MSIX_TABLE};
			keys.delete();
			foreach (functions[f]) if (functions[f].key.host_id == h) keys.push_back(functions[f].key);
			host_scope = new("msix_host", cfg.dpu_cfg.device_snapshot, keys, bars);
			foreach (msix_kinds[k]) begin
				require_true(probe.inspect_public(msix_kinds[k], host_scope, part, why), why);
				foreach (part[r]) public_rows.push_back(part[r]);
			end
			#20ns;
			capture_write_start();
			config_seq.configure_msix(host_scope, ok, why);
			require_true(ok, why);
			check_writes(public_rows);
		end
		if ($test$plusargs("PROJECT_CONTROLS")) check_public_controls(public_scope);
		check_optional_state(public_scope);
		config_seq.verify_dpu_configuration(public_scope, ok, why);
		require_true(ok, why);
		#20ns;
		before_count = requests[0].size();
		config_seq.prepare_vio_configuration(selection, ok, why);
		require_true(ok, why);
		check_queue_export();
		#20ns;
		require_true(requests[0].size() == before_count, "prepare emitted traffic");
		// 每 Host 独立 scope 使捕获计数和 shared 项去重的检查可直接对应。
		foreach (cfg.dpu_cfg.queues_by_host[h]) begin
			dpu_cfg_scope	subset;
			keys.delete();
			foreach (functions[f]) if (functions[f].key.host_id == h) keys.push_back(functions[f].key);
			subset = new("host_queues", cfg.dpu_cfg.device_snapshot, keys, bars);
			kinds = '{DPU_TABLE_NOTIFY};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				dpu_vio_notify_entry_t	entry;
				entry = dpu_vio_notify_entry_t'(rows[r].entry);
				require_true(rows[r].binding.qpair.global_qpair_id >= 100 &&
					rows[r].binding.qpair.global_qpair_id != rows[r].binding.local_qid/2,
					"noncontinuous global pair fixture lost");
				require_true(entry.global_qid == rows[r].binding.qpair.global_qpair_id,
					"notify used local pair as global ID");
			end
			capture_write_start();
			config_seq.configure_vio_notify(subset, ok, why);
			require_true(ok, why);
			check_writes(rows);
			kinds = '{DPU_TABLE_Q2TC, DPU_TABLE_N2G, DPU_TABLE_G2P, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				case (rows[r].ctx.kind)
					DPU_TABLE_Q2TC: begin
						dpu_qsch_q2tc_entry_t	entry;
						entry = dpu_qsch_q2tc_entry_t'(rows[r].entry);
						require_true(entry.net_id == 128+rows[r].owner.pf_id*64+rows[r].owner.vf_id*16+rows[r].binding.qpair.virtio_pair_index &&
							rows[r].ctx.byte_offset == ($test$plusargs("PROJECT_DRIVER_PORTS") ? 64'hb10000 : 64'h610000) +
							rows[r].ctx.table_index*4, "wide QSCH net/relative offset");
					end
					DPU_TABLE_N2G: begin
						dpu_qsch_n2g_entry_t	entry;
						entry = dpu_qsch_n2g_entry_t'(rows[r].entry);
						require_true(entry.group_id == 64+rows[r].owner.pf_id*4+rows[r].owner.vf_id, "wide QSCH group truncated");
					end
					DPU_TABLE_G2P: begin
						dpu_qsch_g2p_entry_t	entry;
						entry = dpu_qsch_g2p_entry_t'(rows[r].entry);
						require_true(entry.dpt == ($test$plusargs("PROJECT_ETS") ? 4 : 2)+h &&
							entry.lvl2_id == ($test$plusargs("PROJECT_ETS") ? 3 : h), "QSCH ETH/ETS destination");
					end
					DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT: require_true(rows[r].entry == (rows[r].ctx.kind == DPU_TABLE_SPWRR ? 32'h31 : 32'h52), "scheduler control payload");
					default: require_true(0, "unexpected scheduler category");
				endcase
			end
			#20ns;
			capture_write_start();
			config_seq.configure_qsch(subset, ok, why);
			require_true(ok, why);
			check_writes(rows);
			kinds = '{DPU_TABLE_VTX, DPU_TABLE_VRX, DPU_TABLE_QUEUE_AUX};
			require_true(probe.inspect_queues(subset, kinds, rows, why), why);
			foreach (rows[r]) begin
				if (rows[r].ctx.kind == DPU_TABLE_VTX) begin
					dpu_vtx_entry_t	entry;
					entry = dpu_vtx_entry_t'(rows[r].entry);
					require_true(entry.virtio_mode == rows[r].binding.virtio_mode, "mixed service VTX mode crossed");
				end
			end
			#20ns;
			capture_write_start();
			config_seq.configure_vio_queues(subset, ok, why);
			require_true(ok, why);
			check_writes(rows);
		end
		config_seq.enable_vio_queues(selection, ok, why);
		require_true(ok, why);
		config_seq.verify_vio_configuration(selection, ok, why);
		require_true(ok, why);
		#20ns;
		before_count = requests[0].size();
		config_seq.commit_vio_configuration(selection, ok, why);
		require_true(ok, why);
		#100ns;
		require_true(requests[0].size() == before_count, "commit/idle emitted implicit config/status traffic");
		check_rx();
		if ($test$plusargs("PROJECT_CONTROLS")) begin
			require_true(probe.control_calls[DPU_TABLE_SPWRR] == cfg.dpu_cfg.placement_cfg.vio_requests.size() &&
				probe.control_calls[DPU_TABLE_TC_WEIGHT] == cfg.dpu_cfg.placement_cfg.vio_requests.size() &&
				probe.control_calls[DPU_TABLE_QUEUE_AUX] == cfg.dpu_cfg.placement_cfg.vio_requests.size()*pairs,
				"optional queue control traversal count");
			`uvm_info("PROJECT_CONTROLS_PASS", "all declared public and queue control hooks emitted checked Memory writes", UVM_LOW)
		end
		if ($test$plusargs("PROJECT_NOTIFY_BATCH")) check_notify_batches(public_scope);
		check_release_generation();
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_EXTERNAL_CONTRACT_PASS", $sformatf("checks=%0d mixed=%0d hosts=%0d", checks, $test$plusargs("PROJECT_MIXED"), host_count), UVM_LOW)
		phase.drop_objection(this);
	endtask
	// 每次使用新 probe，使 AF 计数从零开始；故障由真实 PCIe sequence 在指定请求处拒绝。
	// 正例按原始表项检查字节和顺序，负例单独确认已发送数量以及没有任何使能写。
	task project_external_contract_test::check_notify_batches(input dpu_cfg_scope	scope);
		dpu_table_item_t	rows[$];
		dpu_table_item_t	batch[$];
		project_contract_seq	batch_seq;
		int unsigned		fail_at;
		int unsigned		sent;
		int unsigned		table_writes;
		bit			ok;
		string			why;

		require_true(probe.inspect_public(DPU_TABLE_RDMA_NOTIFY, scope, rows, why), why);
		require_true(rows.size() != 0, "Notify batch fixture needs RDMA records");
		table_writes = rows.size() * 2;
		pcie_tl_reg_seq::type_id::set_type_override(project_config_fault_seq::get_type());

		for (int unsigned scenario = 0; scenario < 5; scenario++) begin
			batch_seq = new($sformatf("notify_batch_%0d", scenario));
			batch_seq.cfg = cfg.dpu_cfg;
			batch_seq.set_sequencer(probe.get_sequencer());
			batch.delete();
			fail_at = 0;

			if (scenario != 0) begin
				batch = rows;
				// 重复同一记录不能多写表项或多使能同一个管理 BAR。
				batch.push_back(rows[0]);
			end
			case (scenario)
				2: fail_at = 1;
				3: fail_at = 2;
				4: fail_at = table_writes + 1;
				default: ;
			endcase
			project_config_fault_seq::calls = 0;
			project_config_fault_seq::fail_on_call = fail_at;
			capture_write_start();
			batch_seq.send_batch(batch, ok, why);
			project_config_fault_seq::fail_on_call = 0;

			if (fail_at == 0) begin
				require_true(ok, why);
				check_writes(batch);
				continue;
			end

			require_true(!ok && why != "", "failed Notify send reported success");
			#20ns;
			sent = 0;
			foreach (write_start[h]) begin
				sent += posted[h].size() - write_start[h];
				for (int unsigned i = write_start[h]; i < posted[h].size(); i++) begin
					foreach (rows[r]) begin
						require_true(
							pcie_tl_mem_wire_addr(posted[h][i]) !=
							rows[r].ctx.target.bar_lease.base + 64'h0008_0044,
							"failed Notify batch enabled a management target"
						);
					end
				end
			end
			require_true(sent == fail_at - 1,
				"Notify failure sent unexpected requests or continued after rejection");
		end
		`uvm_info("PROJECT_NOTIFY_BATCH_PASS",
			"empty/duplicate/multiple-target batches and table/enable send failures", UVM_LOW)
	endtask

	// 可选入口逐项调用；初始化之后没有隐含PBA/stat读写，W1C只发显式mask。
	task project_external_contract_test::check_optional_state(input dpu_cfg_scope	scope);
		dpu_table_item_t	rows[$];
		dpu_function_record_t	functions[$];
		dpu_state_query_t	query_item;
		dpu_pfvf_drop_clear_cfg_t	clear_item;
		dpu_msix_pba_word_t	pba;
		bit	ok;
		string	why;
		int unsigned	before_count;
		require_true(probe.inspect_public(DPU_TABLE_RDMA_NOTIFY, scope, rows, why), why);
		#20ns;
		capture_write_start();
		config_seq.configure_rdma_notify(scope, ok, why);
		require_true(ok, why);
		check_writes(rows);
		cfg.dpu_cfg.list_functions(functions);
		foreach (functions[f]) begin
			int unsigned	h;
			h = functions[f].key.host_id;
			require_true(cfg.dpu_cfg.get_state_context(DPU_TABLE_MSIX_PBA, functions[f].key, 1, query_item, why), why);
			before_count = posted[h].size();
			config_seq.read_msix_pba(query_item, pba, ok, why);
			require_true(ok && pba.pending == 0 && posted[h].size() == before_count, "PBA read emitted initialization write");
			require_true(!cfg.dpu_cfg.get_state_context(DPU_TABLE_MSIX_PBA, functions[f].key, 2, query_item, why), "PBA capacity inferred or exceeded");
		end
		require_true(cfg.dpu_cfg.get_state_context(DPU_TABLE_PFVF_DROP, functions[0].key, 0, query_item, why), why);
		clear_item.ctx = query_item.ctx;
		clear_item.owner = query_item.owner;
		clear_item.entry.clear_mask = 32'h00008005;
		before_count = requests[0].size();
		config_seq.clear_pfvf_drop_status(clear_item, ok, why);
		require_true(ok, why);
		#20ns;
		require_true(requests[0].size() == before_count+1 && requests[0][$].kind == TLP_MEM_WR &&
			{requests[0][$].payload[3],requests[0][$].payload[2],requests[0][$].payload[1],requests[0][$].payload[0]} == 32'h8005,
			"explicit W1C changed mask or issued RMW");
		clear_item.entry.clear_mask = 'x;
		config_seq.clear_pfvf_drop_status(clear_item, ok, why);
		require_true(!ok, "unknown W1C mask accepted");
		`uvm_info("PROJECT_OPTIONAL_STATE_PASS", "RDMA high/low, explicit PBA words and independent W1C", UVM_LOW)
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
		dpu_pcie_bar_map	registries[2];
		dpu_bar_target_t	targets[2];
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
