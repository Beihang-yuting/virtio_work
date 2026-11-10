// integration/project/tests：真实 Intel 引脚/monitor/bridge 的项目合同模型回归。
// 应用侧 adapter 仅模拟 DUT 的 BAR MMIO、VTX/VRX 间接表和主动 DMA；Host 仍由项目 RC 唯一响应。
// 裸 seq 回归不覆写生产 hook，核对 AF 首笔写和发送失败停止，再验证配置、读回及缺布局拒绝。
// 关闭/零队列和 RX-only 场景删除未使用的布局，并从真实 Intel MMIO 验证不会配置未启用模块。
// PROJECT_PREPARE_RETRY 复用双 Host 组件，验证后续 Host 准备失败仍能显式释放前序 Host 并重试。
// 测试拥有 app adapter 和期望值；不向 observer 直接注入，不声称覆盖真实 RTL。
package project_external_integration_test_pkg;
	import uvm_pkg::*;
	import aip_core_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	import net_packet_pkg::*;
	import virtio_aip_pkg::*;
	import intel_pcie_adapter_pkg::*;
	import project_env_pkg::*;
	import virtio_dpu_pkg::*;
	import dpu_pcie_pkg::*;
	`include "uvm_macros.svh"

	// 仅回归注入一次发送失败；其余访问调用真实 PCIe sequence。
	class project_config_fault_seq extends pcie_tl_reg_seq;
		`uvm_object_utils(project_config_fault_seq)
		static int unsigned	fail_on_call;
		static int unsigned	calls;
		extern function new(string name = "project_config_fault_seq");
		extern virtual task body();
	endclass

	// 构造发送失败观察器，不改变正常寄存器访问参数。

	function project_config_fault_seq::new(string name = "project_config_fault_seq");
		super.new(name);
	endfunction


	// 在指定调用拒绝发送，支持 AF 首笔或间接 DWORD 故障；之前真实发送的写仍保留。

	task project_config_fault_seq::body();
		if (fail_on_call != 0) begin
			calls++;
			if (calls == fail_on_call) begin
				status = PCIE_RW_ERR;
				error_msg = "injected configuration DWORD send failure";
				return;
			end
		end
		super.body();
	endtask


	// 只捕获明确负例的接收拒绝；其他日志保留原严重级别，不能掩盖 HOST_MEM 错误。
	class project_dma_expected_error extends uvm_report_catcher;
		int unsigned	count;
		// 构造精确 ID 捕获器。
		extern function new();
		// 计数生产预检拒绝，未匹配日志继续交 UVM。
		extern virtual function action_e catch();
	endclass

	// 构造精确错误捕获器。
	function project_dma_expected_error::new();
		super.new("dma_expected");
	endfunction

	// 负例只消费已知生产拒绝，其余错误保留原严重级别。
	function uvm_report_catcher::action_e project_dma_expected_error::catch();
		if (get_id() == "PROJECT_RC_DMA" && get_severity() == UVM_ERROR) begin
			count++;
			return CAUGHT;
		end
		return THROW;
	endfunction

	// 用户仅实现每类别单项访问；外围循环和写序使用 vio_dpu_cfg_seq，配置数据来自 cfg。
	class project_external_model_seq extends vio_dpu_cfg_seq;
		`uvm_object_utils(project_external_model_seq)
		int unsigned	vtx_calls;
		int unsigned	vrx_calls;
		int unsigned	notify_calls;
		int unsigned	bar_calls;
		int unsigned	fail_vtx_call;
		bit	fail_verify;
		int unsigned	fail_dword;
		string	fail_direction = "vtx";
		bit	fault_armed;
		// 故障仅在选定队列的实际 PCIe 发送段注入，整条配置 seq 必须停止。
		extern function void arm_send_failure(input string	direction);
		int unsigned	pfvf_calls;
		dpu_pfvf_cfg_t	pfvf_items[string];
		dpu_vtx_cfg_t	last_vtx;
		dpu_vrx_cfg_t	last_vrx;
		// 旧分段发送故障由 run_phase 检查；仅该预期失败不交给生产 fatal。
		extern virtual task post_start();
		// 构造模型 hook 容器，不修改生产 build/connect。
		extern function new(string	name = "project_external_model_seq");
		// BAR 编码没有图片规格，测试只核对真实租约组后作为模型平台报告成功。
		extern virtual task user_configure_bar_mapping_entry(input dpu_bar_mapping_cfg_t item, output bit ok, output string why);
		// 显式平台模型 verify，实际 RTL 应覆写为读回/状态检查。
		extern virtual task user_verify_dpu_configuration(input dpu_cfg_scope scope, output bit ok, output string why);
		extern virtual task user_verify_vio_configuration(input dpu_cfg_scope selection, output bit ok, output string why);
		extern virtual task write_enabled_queue(input dpu_queue_control_cfg_t item, output bit ok, output string why);
		// 单项 bdf 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_bdf(input dpu_bdf_cfg_t item, output bit ok, output string why);
		// 单项 pfvf 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_pfvf(input dpu_pfvf_cfg_t item, output bit ok, output string why);
		// 单项 msix_linear 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_msix_linear(input dpu_msix_linear_cfg_t item, output bit ok, output string why);
		// 单项 msix_info 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_msix_info(input dpu_msix_info_cfg_t item, output bit ok, output string why);
		// 单项 msix_interval 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_msix_interval(input dpu_msix_interval_cfg_t item, output bit ok, output string why);
		// 单项 msix_table 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_msix_table(input dpu_msix_table_cfg_t item, output bit ok, output string why);
		// 单项 qsch_q2tc 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_qsch_q2tc(input dpu_qsch_q2tc_cfg_t item, output bit ok, output string why);
		// 单项 qsch_n2g 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_qsch_n2g(input dpu_qsch_n2g_cfg_t item, output bit ok, output string why);
		// 单项 qsch_g2p 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_qsch_g2p(input dpu_qsch_g2p_cfg_t item, output bit ok, output string why);
		// 单项 vtx 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_vtx(input dpu_vtx_cfg_t item, output bit ok, output string why);
		// 单项 vrx 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_vrx(input dpu_vrx_cfg_t item, output bit ok, output string why);
		// 单项 vio_notify 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task write_vio_notify(input dpu_vio_notify_cfg_t item, output bit ok, output string why);
	endclass

	// UVM 构造，所有硬件访问都在 run 阶段用户入口进行。

	function project_external_model_seq::new(string	name = "project_external_model_seq");
		super.new(name);
	endfunction

	// 旧故障矩阵保持可检查失败状态；其他错误仍走生产 post_start 的 fatal。

	task project_external_model_seq::post_start();
		if (fail_dword != 0 && fault_armed && !success) return;
		super.post_start();
	endtask


	// 在首次指定方向 hook 前设置 PCIe fault；其余类别仍走正常真实发送。

	function void project_external_model_seq::arm_send_failure(input string	direction);
		if (fail_dword == 0 || fault_armed || direction != fail_direction) return;

		fault_armed = 1;
		project_config_fault_seq::calls = 0;
		project_config_fault_seq::fail_on_call = fail_dword;
	endfunction


	// 没有猜测 BAR payload，模型仅确认完整声明组收到真实租约。

	task project_external_model_seq::user_configure_bar_mapping_entry(input dpu_bar_mapping_cfg_t item, output bit ok, output string why);
		bar_calls++;
		ok = item.members.size() != 0;
		why = ok ? "" : "empty BAR group";
	endtask

	// 模型平台明确报告所选公共配置完成；产品仍检查上下文和依赖。

	task project_external_model_seq::user_verify_dpu_configuration(input dpu_cfg_scope scope, output bit ok, output string why);
		ok = 1; why = "";
	endtask

	// 模型平台明确报告队列配置完成；后续核心 preflight 不能被此成功绕过。

	task project_external_model_seq::user_verify_vio_configuration(input dpu_cfg_scope selection, output bit ok, output string why);
		ok = !fail_verify; why = ok ? "" : "injected platform verification failure";
	endtask

	// 使能使用唯一 checked 路径，只允许 enable 位变化。

	task project_external_model_seq::write_enabled_queue(input dpu_queue_control_cfg_t item, output bit ok, output string why);
		super.write_enabled_queue(item, ok, why);
	endtask


	// 单项 bdf 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_bdf(input dpu_bdf_cfg_t item, output bit ok, output string why);
		super.write_bdf(item, ok, why);
	endtask


	// 单项 pfvf 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_pfvf(input dpu_pfvf_cfg_t item, output bit ok, output string why);
		pfvf_calls++;
		pfvf_items[dpu_function_key_name(item.owner)] = item;
		super.write_pfvf(item, ok, why);
	endtask


	// 单项 msix_linear 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_msix_linear(input dpu_msix_linear_cfg_t item, output bit ok, output string why);
		super.write_msix_linear(item, ok, why);
	endtask


	// 单项 msix_info 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_msix_info(input dpu_msix_info_cfg_t item, output bit ok, output string why);
		super.write_msix_info(item, ok, why);
	endtask


	// 单项 msix_interval 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_msix_interval(input dpu_msix_interval_cfg_t item, output bit ok, output string why);
		super.write_msix_interval(item, ok, why);
	endtask


	// 单项 msix_table 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_msix_table(input dpu_msix_table_cfg_t item, output bit ok, output string why);
		super.write_msix_table(item, ok, why);
	endtask


	// 单项 qsch_q2tc 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_qsch_q2tc(input dpu_qsch_q2tc_cfg_t item, output bit ok, output string why);
		super.write_qsch_q2tc(item, ok, why);
	endtask


	// 单项 qsch_n2g 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_qsch_n2g(input dpu_qsch_n2g_cfg_t item, output bit ok, output string why);
		super.write_qsch_n2g(item, ok, why);
	endtask


	// 单项 qsch_g2p 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_qsch_g2p(input dpu_qsch_g2p_cfg_t item, output bit ok, output string why);
		super.write_qsch_g2p(item, ok, why);
	endtask


	// 单项 vtx 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_vtx(input dpu_vtx_cfg_t item, output bit ok, output string why);
		vtx_calls++;
		last_vtx = item;
		if (fail_vtx_call != 0 && vtx_calls == fail_vtx_call) begin ok = 0; why = "injected midway VTX hook failure"; return; end
		arm_send_failure("vtx");
		super.write_vtx(item, ok, why);
	endtask


	// 单项 vrx 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_vrx(input dpu_vrx_cfg_t item, output bit ok, output string why);
		vrx_calls++;
		last_vrx = item;
		arm_send_failure("vrx");
		super.write_vrx(item, ok, why);
	endtask


	// 单项 vio_notify 返回真实 helper 结果；不在 hook 中增加外围循环。

	task project_external_model_seq::write_vio_notify(input dpu_vio_notify_cfg_t item, output bit ok, output string why);
		notify_calls++;
		super.write_vio_notify(item, ok, why);
	endtask


	// 仅此测试模型的明确路由规则，不作为产品硬件默认；实际平台替换此一个纯函数。
	class project_external_model_cfg extends dpu_env_cfg;
		`uvm_object_utils(project_external_model_cfg)
		// 构造配置，保留生产参数生成器。
		extern function new(string name="project_external_model_cfg");
		// fixture 的 PF0 从 offset1 开始，Pfvf=vf_id+1；完整成员逐项检查，不要求VF连续。
		// 在 placement 前通过同一生成/需求入口建立稀疏实际 VF。
		extern function void add_fixture_vf(input int unsigned vf_id);
		extern virtual function bit validate_pfvf_relationship(input dpu_pfvf_relationship_t family, output string why);
	endclass

	// fixture 配置仍使用产品解析和资源生成器。

	function project_external_model_cfg::new(string name="project_external_model_cfg");
		super.new(name);
		// 本 fixture 专门验证原有逐 service 的显式布局；自动拓扑由独立测试覆盖。
		qsch_topology = DPU_QSCH_MANUAL;
	endfunction


	// 不改冻结快照；稀疏键和精确需求均在 env build 前加入。

	function void project_external_model_cfg::add_fixture_vf(input int unsigned vf_id);
		dpu_function_cfg function_cfg;
		function_cfg = make_function(0, 0, DPU_FUNCTION_VF, vf_id);
		device_cfg.functions.push_back(function_cfg);
	endfunction


	// 测试专用关系规则，绝不作为产品 PFVF 默认。

	function bit project_external_model_cfg::validate_pfvf_relationship(input dpu_pfvf_relationship_t family, output string why);
		int unsigned	pf_count;
		why = "fixture PFVF relationship mismatch";
		pf_count = 0;
		if (family.functions.size()!=family.policies.size()) return 0;
		foreach (family.functions[i]) begin
			if (!dpu_same_function_key(family.functions[i].key,family.policies[i].key)) return 0;
			if (family.functions[i].key.kind==DPU_FUNCTION_PF) begin
				pf_count++;
				if (family.policies[i].first_vf_offset!=1 || family.policies[i].pfvf!=0) return 0;
			end else if (family.policies[i].pfvf!=family.functions[i].key.vf_id+1) return 0;
		end
		if (pf_count!=1) return 0;
		why = "";
		return 1;
	endfunction


	// 单 VF32/双 VF16/双 Host/禁 RX/无 VIO 共用同一真实组装路径，plusarg 仅改变场景输入。
	class project_external_integration_test extends uvm_test;
		`uvm_component_utils(project_external_integration_test)
		project_env_cfg	cfg;
		project_env					env;
		project_external_model_seq	config_seq;
		intel_pcie_if_adapter	apps[int unsigned];
		pcie_tl_cpl_tlp	completions[int unsigned][$];
		byte	mmio_bytes[int unsigned][bit [63:0]];
		pcie_tl_mem_tlp	posted[int unsigned][$];
		int unsigned	checks;
		string	cancel_stage;
		int unsigned	pairs;
		int unsigned	vf_count;
		int unsigned	host_count;
		bit	no_vio;
		bit	tx_only;
		bit	msix_mode;
		dpu_cfg_scope	selection;
		// 构造测试组件，不访问设备。
		extern function new(string name, uvm_component parent);
		// 精确失败断言，不能让过程 exit0 代替语义检查。
		extern function void require_true(input bit condition, input string detail);
		// 显式声明本测试模型布局；图片相对偏移与模块偏移分开。
		extern function void add_layout(input dpu_table_kind_e kind, input int unsigned bytes,
			input int unsigned capacity, input bit [63:0] module_offset, input bit [63:0] table_offset,
			input bit indirect = 0);
		// 建立实际 project env 与每 Host 的应用侧物理 adapter。
		extern virtual function void build_phase(uvm_phase phase);
		// 应用侧仅响应 BAR 读、记录 posted 写；Host DMA 由 RC 处理。
		extern virtual task app_receive(input int unsigned host);
		// 经真实应用侧引脚发 Memory，保持 wire requester 身份。
		extern task send_memory(input int unsigned host, input bit writing, input bit [15:0] requester,
			input bit [63:0] address, input bit [31:0] data, input bit [9:0] tag = 10'h155);
		// 非 identity 双向 DMA、权限/未知 requester、真实 MSI-X sink 与 Completion sideband。
		extern task check_receive_path();

		// Host1 在实际准备入口失败，检查 Host0 清理范围及双 Host 重试；不发送 DUT 配置。
		extern task check_prepare_retry();

		// typed hook 中途失败、确认/释放全 Host 预检与 AIP 取消后重准备。
		extern virtual task run_phase(uvm_phase phase);
	endclass

	// 构造测试；全部输入在 build 冻结。
	function project_external_integration_test::new(string name, uvm_component parent);
		super.new(name,parent);
	endfunction

	// 保留完整错误说明；每条检查均计数。
	function void project_external_integration_test::require_true(input bit condition, input string detail);
		checks++;
		if (!condition) `uvm_fatal("PROJECT_EXTERNAL_FLOW", detail)
	endfunction

	// 测试模型端口控制布局明确声明，不能成为产品隐式默认。
	function void project_external_integration_test::add_layout(input dpu_table_kind_e kind, input int unsigned bytes,
		input int unsigned capacity, input bit [63:0] module_offset, input bit [63:0] table_offset, input bit indirect);
		dpu_table_layout_t	l;
		l.provided = 1;
		l.reg_target = "pf0.bar0";
		l.access_host_provided = 0;
		l.access_host = 0;
		l.access_uses_owner_host = 1;
		l.module_offset = module_offset;
		l.table_offset = table_offset;
		l.capacity = capacity;
		l.entry_bytes = bytes;
		l.index_policy = DPU_INDEX_GLOBAL_VECTOR;
		l.indirect = indirect;
		l.data_port = 'h204;
		l.control_port = 'h200;
		l.index_mask = 'hffff;
		l.control_fixed = 0;
		l.trigger_mask = 'h10000;
		l.index_shift = 0;
		l.required = 1;
		cfg.dpu_cfg.table_layouts[kind] = l;
	endfunction

	// 配置基于真实 DPU 生成器，精确 enabled/pairs 在 placement 前解析；混合方向固定 Host0 双向、Host1 RX-only。
	function void project_external_integration_test::build_phase(uvm_phase phase);
		string	why;
		project_external_model_cfg	model_cfg;
		super.build_phase(phase);
		if ($test$plusargs("PROJECT_FAIL_DWORD"))
			pcie_tl_reg_seq::type_id::set_type_override(project_config_fault_seq::get_type());

		no_vio = $test$plusargs("PROJECT_NO_VIO");
		tx_only = $test$plusargs("PROJECT_TX_ONLY");
		msix_mode = $test$plusargs("PROJECT_MSIX");
		host_count = $test$plusargs("PROJECT_TWO_HOSTS") ? 2 : 1;
		vf_count = $test$plusargs("PROJECT_TWO_VFS") ? 2 : 1;
		pairs = vf_count == 2 ? 16 : 32;
		if ($test$plusargs("PROJECT_SMALL")) pairs = 2;
		if ($test$plusargs("PROJECT_ONE_PAIR")) pairs = 1;
		if ($test$plusargs("PROJECT_MIXED_DIRECTIONS")) begin
			host_count = 2;
			vf_count   = 1;
			pairs      = 1;
			tx_only    = 0;
		end
		// 生命周期负例固定最小双 Host 拓扑，避免依赖额外场景参数才能覆盖部分成功。
		if ($test$plusargs("PROJECT_PREPARE_RETRY")) begin
			require_true(!no_vio, "prepare retry requires enabled VIO services");
			host_count = 2;
			vf_count   = 1;
			pairs      = 1;
		end
		cfg = project_env_cfg::type_id::create("cfg");
		cfg.dpu_cfg = project_external_model_cfg::type_id::create("dpu_cfg");
		cfg.dpu_cfg.driver_layouts = 0;
		cfg.dpu_cfg.qsch_configure_controls = 0;
		cfg.dpu_cfg.configure_public = 1;
		cfg.dpu_cfg.verify_readback = 1;
		cfg.dpu_cfg.hosts = host_count;
		cfg.dpu_cfg.vfs_per_pf = vf_count;
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			require_true(host_count == 1 && !no_vio, "PFVF guard needs one Host with VIO");
			vf_count = $test$plusargs("PROJECT_PFVF_SINGLE") ? 1 : 2;
			cfg.dpu_cfg.vfs_per_pf = 0;
			cfg.dpu_cfg.pfs_per_host = 2;
		end
		cfg.vio_cfg.enabled = 0;
		cfg.vio_cfg.default_num_pairs = pairs;
		cfg.vio_cfg.default_queue_size = 512;
		cfg.vio_cfg.rx_enable = !tx_only;
		cfg.vio_cfg.completion_mode = msix_mode ? VIRTIO_COMPLETION_MSIX : VIRTIO_COMPLETION_POLLING;
		cfg.vio_cfg.default_vq_type = $test$plusargs("PROJECT_CUSTOM") ? VQ_CUSTOM : VQ_PACKED;
		cfg.vio_cfg.notify_layout_valid = 1;
		cfg.vio_cfg.notify_bar = 0;
		cfg.vio_cfg.notify_base = 'h100;
		cfg.vio_cfg.notify_stride = 0;
		cfg.vio_cfg.notify_encoding = VIO_NOTIFY_DPU32;
		cfg.vio_cfg.iova_base = 'h80000000;
		cfg.vio_cfg.iova_limit = 'h90000000;
		cfg.vio_cfg.scb_enable = 0;
		cfg.dpu_cfg.bar_mapping_per_lease = 1;
		for (int unsigned h = 0; h < host_count; h++) begin
			for (int unsigned v = 0; v < vf_count; v++)
				aip_cmdline_override::set_val($sformatf("vio.h%0d.pf0.vf%0d.i0.enabled",h,v), no_vio ? "0" : "1");
		end
		if ($test$plusargs("PROJECT_MIXED_DIRECTIONS"))
			aip_cmdline_override::set_val("vio.h1.pf0.vf0.i0.tx_enable", "0");
		// 全局调度默认与精确 service 覆盖通过真实参数解析验证。
		aip_cmdline_override::set_val("dpu.qsch.cos", "3");
		aip_cmdline_override::set_val("vio.h0.pf0.vf0.i0.qsch.cos", "5");
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			aip_cmdline_override::set_val("vio.h0.pf0.vf3.i0.enabled", "1");
		end
		cfg.load_params();
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			require_true($cast(model_cfg, cfg.dpu_cfg), "fixture cfg cast");
			model_cfg.add_fixture_vf(0);
			if (!$test$plusargs("PROJECT_PFVF_SINGLE")) model_cfg.add_fixture_vf(3);
			foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
				dpu_vio_service_t	service;
				vio_service_requirement_t	requirement;
				dpu_service_key_t	key;
				key = '{function_key:cfg.dpu_cfg.device_cfg.functions[f].key,
					service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
				if (cfg.dpu_cfg.services.exists(dpu_service_key_name(key))) continue;
				require_true(cfg.vio_cfg_by_host[0].resolve_final_service_requirement(key, requirement, why), why);
				service = '{service_key:key, enabled:requirement.enabled, tx_enable:requirement.tx_enable,
					rx_enable:requirement.rx_enable, msix_enable:requirement.completion_mode == VIRTIO_COMPLETION_MSIX,
					qpairs:requirement.behavior.num_queue_pairs};
				cfg.dpu_cfg.add_vio_service(service);
			end
		end
		foreach (cfg.dpu_cfg.vio_policies[name]) begin
			dpu_function_key_t key;
			key = cfg.dpu_cfg.vio_policies[name].service_key.function_key;
			require_true(cfg.dpu_cfg.vio_policies[name].cos ==
				((key.host_id == 0 && key.pf_id == 0 && key.kind == DPU_FUNCTION_VF && key.vf_id == 0) ? 5 : 3),
				"dpu.qsch global/service parameter precedence");
		end
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			dpu_function_policy_t	p;
			dpu_vio_policy_t	q;
			dpu_function_key_t	key;
			key = cfg.dpu_cfg.device_cfg.functions[f].key;
			p.key = key;
			p.mode = DPU_HOST_EP;
			p.intel_pf = key.pf_id;
			p.intel_vf = key.kind == DPU_FUNCTION_VF ? int'(key.vf_id) : -1;
			p.requester = key.kind == DPU_FUNCTION_VF ? (16'h8000 | (key.vf_id << 4) | key.pf_id) : key.pf_id;
			p.vport = key.pf_id*32 + (key.kind == DPU_FUNCTION_VF ? key.vf_id + 1 : 0);
			p.pfvf = key.kind == DPU_FUNCTION_VF ? key.vf_id + 1 : 0;
			p.first_vf_offset = 1;
			p.bdf_index = p.vport;
			p.completion_index = p.vport;
			p.prefix_index = p.vport;
			p.prefix = 0;
			p.prefix_enabled = 0;
			p.ecrc = 0;
			p.vdpa = 0;
			cfg.dpu_cfg.function_policies[dpu_function_key_name(key)] = p;
			for (int unsigned v = 0; v < 64; v++) begin
				dpu_msix_message_t	m;
				m.owner = key;
				m.local_vector = v;
				m.global_vector = 0;
				m.address = 64'h0000900000000000 + p.vport * 'h10000 + v * 4;
				m.data = 32'h13572468 ^ (v << 8);
				m.masked = 0;
				cfg.dpu_cfg.msix_policies[dpu_function_key_name(key)].table_only_enable = 1;
				cfg.dpu_cfg.msix_policies[dpu_function_key_name(key)].interval_present = 1;
				cfg.dpu_cfg.msix_policies[dpu_function_key_name(key)].interval_entry = '0;
				cfg.dpu_cfg.msix_policies[dpu_function_key_name(key)].self_mask_present = 1;
				cfg.dpu_cfg.msix_policies[dpu_function_key_name(key)].self_mask = 0;
				cfg.dpu_cfg.message_templates[dpu_function_key_name(key)][v] = m;
			end
			if (key.kind != DPU_FUNCTION_VF) continue;
			q.service_key = '{function_key:key, service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
			q.vtx = '0;
			q.vrx = '0;
			q.vrx.dsc_pre_max_num = 3;
			q.fpga = 0;
			q.prefetch_ram = $sformatf("ram_h%0d",key.host_id);
			q.prefetch_start = key.vf_id * pairs * 32;
			q.prefetch_slots = 32;
			q.net_base = key.vf_id * pairs;
			q.net_stride = 1;
			q.group_id = key.vf_id;
			q.cos = 7;
			q.eth_ports = 2;
			q.ets = 0;
			q.distinguish_business = 1;
			q.ets_priority = 0;
			q.notify_net_pair5 = 1;
			q.notify_table_base_provided = 1;
			q.notify_table_bar = 0;
			// 本模型的真实 doorbell 位于 BAR+0x100，显式查找基址必须匹配其 [60:7]。
			q.notify_table_offset = 'h100;
			cfg.dpu_cfg.vio_policies[dpu_service_key_name(q.service_key)] = q;
		end
		add_layout(DPU_TABLE_BDF,4,128,'h100000,'h8000);
		add_layout(DPU_TABLE_PFVF,4,4,'h200000,'h8000);
		add_layout(DPU_TABLE_MSIX_LINEAR,8,2048,'h200000,'h40000);
		// MSI-X linear 与 Notify 同为所有 Host 共用的完整排序单 bank。
		cfg.dpu_cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].reg_target = "h0.pf0.bar0";
		cfg.dpu_cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].access_host_provided = 0;
		cfg.dpu_cfg.table_layouts[DPU_TABLE_MSIX_LINEAR].access_uses_owner_host = 0;
		add_layout(DPU_TABLE_MSIX_INFO,4,1024,'h100000,'h50000);
		add_layout(DPU_TABLE_MSIX_INTERVAL,4,1024,'h100000,'h40000);
		add_layout(DPU_TABLE_MSIX_TABLE,16,1024,'h100000,'h20000);
		add_layout(DPU_TABLE_NOTIFY,16,512,'h200000,'h20000);
		// 所有 Host 共用一份排序 Notify 单 bank，其余表仍按所属 Host 选择管理端口。
		cfg.dpu_cfg.table_layouts[DPU_TABLE_NOTIFY].reg_target = "h0.pf0.bar0";
		cfg.dpu_cfg.table_layouts[DPU_TABLE_NOTIFY].access_host_provided = 0;
		cfg.dpu_cfg.table_layouts[DPU_TABLE_NOTIFY].access_uses_owner_host = 0;
		add_layout(DPU_TABLE_VTX,16,2048,'h400000,'h10000,1);
		add_layout(DPU_TABLE_VRX,16,2048,'h500000,'h10000,1);
		add_layout(DPU_TABLE_Q2TC,4,1024,'h600000,'h10000);
		add_layout(DPU_TABLE_N2G,4,2048,'h600000,'h12000);
		add_layout(DPU_TABLE_G2P,4,1024,'h600000,'h14000);

		// 仅显式参考场景采用上传驱动地址；模型不证明真实 RTL 的地址/位域兼容。
		// 生产 cfg 不隐含此选择，队列 data/control 的写序仍采用用户要求的高位先写。
		if ($test$plusargs("PROJECT_DRIVER_PORTS")) begin
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].module_offset = 'h880000;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].data_port     = 'h134;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].control_port  = 'h130;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].index_mask    = 'h7ff;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].trigger_mask  = 'h2000;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VTX].index_policy  = DPU_INDEX_GLOBAL_QPAIR;

			cfg.dpu_cfg.table_layouts[DPU_TABLE_VRX].module_offset = 'h900000;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_VRX].index_policy  = DPU_INDEX_GLOBAL_QPAIR;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_Q2TC].module_offset = 'hb00000;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_N2G].module_offset  = 'hb00000;
			cfg.dpu_cfg.table_layouts[DPU_TABLE_G2P].module_offset  = 'hb00000;
		end

		for (int unsigned h = 0; h < host_count; h++) begin
			intel_pcie_vif_t	vif;
			intel_pcie_adapter_config	app_cfg;
			string	path;
			require_true(uvm_config_db#(intel_pcie_vif_t)::get(null,"uvm_test_top",$sformatf("intel_vif_%0d",h),vif),"missing Intel VIF");
			cfg.intel_rc_vifs[h] = vif;
			cfg.intel_cfg_by_slot[h] = intel_pcie_adapter_config::type_id::create("hip_cfg");
			cfg.intel_cfg_by_slot[h].side = INTEL_PCIE_HARD_IP;
			app_cfg = intel_pcie_adapter_config::type_id::create("app_cfg");
			app_cfg.side = INTEL_PCIE_APPLICATION;
			path = $sformatf("app_%0d",h);
			uvm_config_db#(intel_pcie_vif_t)::set(this,path,"vif",vif);
			uvm_config_db#(intel_pcie_adapter_config)::set(this,path,"intel_cfg",app_cfg);
			apps[h] = intel_pcie_if_adapter::type_id::create(path,this);
		end
		uvm_config_db#(project_env_cfg)::set(this,"env","cfg",cfg);
		env = project_env::type_id::create("env", this);
		config_seq = project_external_model_seq::type_id::create("config_seq");
		config_seq.cfg = cfg.dpu_cfg;
	endfunction

	// 实际 Intel RX 返回 sideband 与 payload；模型只管理设备 BAR 存储，不响应 Host DMA。
	task project_external_integration_test::app_receive(input int unsigned host);
		forever begin
			pcie_tl_tlp	t;
			pcie_tl_mem_tlp	m;
			pcie_tl_cpl_tlp	c;
			dpu_bar_target_t	af_target;
			string		why;
			wait (apps[host].rx_queue.size() != 0);
			apps[host].receive(t);
			if (t == null) continue;
			if ($cast(c,t)) begin completions[host].push_back(c); continue; end
			require_true($cast(m,t),"unexpected non-Memory/configuration request at Intel app");
			if (m.kind == TLP_MEM_WR) begin
				posted[host].push_back(m);
				for (int unsigned i = 0; i < m.payload.size(); i++)
					if (pcie_tl_mem_lane_enabled(m,i)) mmio_bytes[host][pcie_tl_mem_wire_addr(m)+i] = m.payload[i];
			end else begin
				c = new("dut_bar_completion");
				c.kind = TLP_CPLD;
				c.type_f = TLP_TYPE_CPL;
				c.fmt = FMT_3DW_WITH_DATA;
				c.requester_id = m.requester_id;
				c.tag = m.tag;
				c.completer_id = 0;
				c.cpl_status = CPL_STATUS_SC;
				c.length = m.length;
				c.byte_count = pcie_tl_mem_valid_bytes(m);
				c.lower_addr = m.addr[6:0] + pcie_tl_mem_first_valid_in_range(m,0,pcie_tl_mem_dw_count(m)*4);
				c.payload = new[pcie_tl_mem_dw_count(m)*4];
				foreach (c.payload[i]) c.payload[i] = mmio_bytes[host].exists(pcie_tl_mem_wire_addr(m)+i) ? mmio_bytes[host][pcie_tl_mem_wire_addr(m)+i] : 0;
				if (host == 0 && cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", af_target, why) &&
					pcie_tl_mem_wire_addr(m) == af_target.bar_lease.base + 'h1010)
					c.payload = '{8'h08, 8'h00, 8'h00, 8'h00};
				apps[host].send(c);
			end
		end
	endtask

	// 真实 APP TX→Intel HARD_IP adapter→monitor→bridge→project RC，没有 observer 旁路。
	task project_external_integration_test::send_memory(input int unsigned host, input bit writing, input bit [15:0] requester,
		input bit [63:0] address, input bit [31:0] data, input bit [9:0] tag);
		pcie_tl_mem_tlp	m;
		m = new("device_memory");
		m.kind = writing ? TLP_MEM_WR : TLP_MEM_RD;
		m.type_f = TLP_TYPE_MEM_RD;
		m.fmt = writing ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA;
		m.is_64bit = 1;
		m.addr = address;
		m.requester_id = requester;
		m.tag = tag;
		m.length = 1;
		m.first_be = 4'hf;
		m.last_be = 0;
		m.payload = new[writing ? 4 : 0];
		foreach (m.payload[i]) m.payload[i] = data[i*8 +: 8];
		apps[host].send(m);
	endtask

	// 独立分配 DMA backing，测试不会破坏真实 ring；权限失败检查 backing 与 dirty tracking。
	// 无消费者的消息才测试 RC sink；RX-only 向量仍有消费者，不能凭空注入未提交报文的完成。
	task project_external_integration_test::check_receive_path();
		dpu_function_record_t	functions[$];
		project_dma_expected_error	catcher;
		string	why;
		catcher = new();
		cfg.dpu_cfg.list_functions(functions);
		foreach (functions[f]) begin
			bit [63:0]	gpa;
			bit [63:0]	iova;
			bit [63:0]	readonly_iova;
			bit [63:0]	dirty[$];
			byte	bytes[];
			pcie_tl_cpl_tlp	cpl;
			dpu_function_policy_t	p;
			int unsigned	h;
			if (functions[f].key.kind != DPU_FUNCTION_VF) continue;
			h = functions[f].key.host_id;
			p = cfg.dpu_cfg.function_policies[dpu_function_key_name(functions[f].key)];
			gpa = env.vio_envs[h].host_mem.alloc(4096,4096);
			iova = env.vio_envs[h].iommu.map_for_host(h,functions[f].pcie_id.bdf,gpa,4096,DMA_BIDIRECTIONAL);
			require_true(iova != 0 && iova != gpa,"expected nonidentity DMA mapping");
			void'(env.vio_envs[h].iommu.begin_dirty_generation_for_host(h));
			send_memory(h,1,p.requester,iova,32'h12345678 ^ f);
			#100ns;
			env.vio_envs[h].host_mem.read_mem(gpa,4,bytes);
			require_true(bytes.size()==4 && {bytes[3],bytes[2],bytes[1],bytes[0]} == (32'h12345678 ^ f),"Intel DMA write did not reach translated GPA");
			env.vio_envs[h].iommu.capture_dirty_generation_for_host(h,dirty);
			require_true(dirty.size()!=0,"device write bypassed dirty tracking");
			send_memory(h,0,p.requester,iova,0,10'h056);
			wait(completions[h].size()!=0);
			cpl = completions[h].pop_front();
			require_true(cpl.requester_id==p.requester && cpl.tag==10'h056 && cpl.cpl_status==CPL_STATUS_SC,
				"DMA Completion changed wire requester/tag/status");
			require_true(cpl.cq_route.pf_index==p.intel_pf && cpl.cq_route.is_vf && cpl.cq_route.vf_index==p.intel_vf,
				"real Intel Completion sideband selected wrong Function");
			require_true(cpl.payload.size()==4 && {cpl.payload[3],cpl.payload[2],cpl.payload[1],cpl.payload[0]}==(32'h12345678 ^ f),"DMA read did not translate IOVA");
			readonly_iova = env.vio_envs[h].iommu.map_for_host(h,functions[f].pcie_id.bdf,gpa,4096,DMA_TO_DEVICE);
			uvm_report_cb::add(null,catcher);
			send_memory(h,1,p.requester,readonly_iova,32'hdeadbeef);
			send_memory(h,1,16'hffff,iova,32'hdeadbeef);
			#100ns;
			uvm_report_cb::delete(null,catcher);
			env.vio_envs[h].host_mem.read_mem(gpa,4,bytes);
			require_true({bytes[3],bytes[2],bytes[1],bytes[0]}==(32'h12345678 ^ f),"failed DMA mutated backing");
			env.vio_envs[h].iommu.unmap_for_host(h,functions[f].pcie_id.bdf,readonly_iova);
			env.vio_envs[h].iommu.unmap_for_host(h,functions[f].pcie_id.bdf,iova);
			env.vio_envs[h].host_mem.free(gpa);
		end
		require_true(catcher.count==2*host_count*vf_count,"DMA permission/requester rejection count");
		// 无消费者 catalog 验证 RC sink；活动向量以真实 TX 提交和 used DMA 验证，不伪造 SVA credit。
		foreach (cfg.dpu_cfg.messages[m]) begin
			dpu_msix_message_t message;
			vio_queue_setup_t rows[$];
			bit active;
			message = cfg.dpu_cfg.messages[m];
			active = 0;
			if (cfg.dpu_cfg.queues_by_host.exists(message.owner.host_id)) begin
				env.vio_envs[message.owner.host_id].get_external_setup().list_queues(rows);
				foreach (rows[q]) begin
					virtio_function_instance instance;
					packet_item packet;
					virtio_net_hdr_t hdr;
					uvm_object completed[$];
					byte bytes[];
					int unsigned desc_id;
					bit [31:0] word_value;
					dpu_function_policy_t policy;
					if (!dpu_same_function_key(rows[q].service_key.function_key, message.owner) ||
						rows[q].qpair.local_msix_vector_id != message.local_vector) continue;
					active = 1;
					if (!rows[q].tx_mode || !msix_mode) continue;
					foreach (env.vio_envs[message.owner.host_id].function_instances[f])
						if (dpu_service_key_name(env.vio_envs[message.owner.host_id].function_instances[f].service_key) == dpu_service_key_name(rows[q].service_key))
							instance = env.vio_envs[message.owner.host_id].function_instances[f];
					require_true(instance != null, "active MSI-X has no Function instance");
					packet = new("intel_frame512");
					require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == 512;}, "real TX packet");
					packet.pkt.do_pack();
					hdr = '{default:0};
					instance.driver_agent.ops.tx_submit(rows[q].notification.local_qid, hdr, packet, 0, desc_id);
					require_true(desc_id != '1, "real MSI-X submission failed");
					policy = cfg.dpu_cfg.function_policies[dpu_function_key_name(message.owner)];
					if (rows[q].queue_type == VQ_CUSTOM)
						send_memory(message.owner.host_id, 1, policy.requester, rows[q].device_iova, 32'h8001);
					else begin
						env.vio_envs[message.owner.host_id].host_mem.read_mem(rows[q].desc_gpa + 12, 4, bytes);
						word_value = {bytes[3],bytes[2],bytes[1],bytes[0]} | 32'h80000000;
						send_memory(message.owner.host_id, 1, policy.requester, rows[q].desc_iova + 12, word_value);
					end
					#100ns;
					instance.driver_agent.ops.tx_complete(rows[q].notification.local_qid, completed, 8);
					require_true(completed.size() == 0, "used DMA bypassed MSI-X message requirement");
					send_memory(message.owner.host_id, 1, 16'hffff, message.address, message.data);
					#100ns;
					instance.driver_agent.ops.tx_complete(rows[q].notification.local_qid, completed, 8);
					require_true(completed.size() == 1 && completed[0] == packet, "early Intel MSI-X did not complete submitted TX");
					if (!tx_only) require_true(instance.transport.notify_mgr.consume_external_pending(rows[q].qpair.rx_local_virtqueue_id),
						"shared vector did not preserve separate RX pending event");
				end
			end
			if (!active) send_memory(message.owner.host_id, 1, 16'hffff, message.address, message.data);
		end
		#100ns;
	endtask

	// 复用生产准备/释放入口，只暂时撤销 Host1 的外部配置许可来触发后序 Host 失败。
	// 此路径从未写 DUT 或确认队列，模型无 DMA；显式传入静止条件后才能回收前序 Host。
	task project_external_integration_test::check_prepare_retry();
		bit		ok;
		string	why;

		#100ns;
		config_seq.cfg = cfg.dpu_cfg;
		config_seq.set_sequencer(env.pcie_env.rc_agents[cfg.tl_slot_by_host[0]].sequencer);
		cfg.vio_cfg_by_host[1].external_configuration = 0;
		config_seq.prepare_vio_configuration(selection, ok, why);
		require_true(!ok && why == "external prepare requires bound nonempty environment without an exported generation",
			"Host1 did not fail at the actual VIO prepare entry");
		require_true(selection != null && env.vio_envs[0].get_external_setup() != null &&
			env.vio_envs[1].get_external_setup() == null,
			"partial prepare lost the release scope or created an unexpected Host1 generation");
		require_true(cfg.dpu_cfg.queues_by_host.num() == 0,
			"partial prepare published incomplete DPU queue exports");
		foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
			require_true(env.vio_envs[h].function_instances[f].driver_agent.fsm.state != FSM_READY,
				"partial prepare admitted packets before commit");
		end

		config_seq.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		require_true(env.vio_envs[0].get_external_setup() == null &&
			cfg.dpu_cfg.queues_by_host.num() == 0,
			"release retained the partially prepared Host generation");
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();

		cfg.vio_cfg_by_host[1].external_configuration = 1;
		config_seq.prepare_vio_configuration(selection, ok, why);
		require_true(ok && selection != null, why);
		require_true(env.vio_envs[0].get_external_setup() != null &&
			env.vio_envs[1].get_external_setup() != null && cfg.dpu_cfg.queues_by_host.num() == 2,
			"retry did not prepare and export both Host generations");
		config_seq.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		foreach (env.vio_envs[h]) begin
			require_true(env.vio_envs[h].get_external_setup() == null,
				"retry cleanup retained a live Host generation");
			env.vio_envs[h].host_mem.leak_check();
		end
		`uvm_info("PROJECT_PREPARE_RETRY_PASS",
			"Host0 survived Host1 prepare failure, released through returned scope, and both Hosts retried successfully",
			UVM_LOW)
	endtask

	// 正常使用方式：只启动一个配置 seq，自动 get 同一 cfg，成功后进入 READY。
	// 故障行每次仿真只注入一个 DWORD，检查整个 body 停止且不进入发包状态。
	// 准备重试分支仅执行本地生命周期检查，保留同一真实组件树但不启动 MMIO 模型。
	// 混合方向检查 QSCH 记录只来自 Host0，防止用全局 TX 开关误配 Host1 的纯 RX 队列。
	task project_external_integration_test::run_phase(uvm_phase	phase);
		bit				ok;
		string			why;
		int unsigned	host;

		phase.raise_objection(this);
		if ($test$plusargs("PROJECT_PREPARE_RETRY")) begin
			check_prepare_retry();
			phase.drop_objection(this);
			return;
		end
		foreach (apps[h]) begin
			automatic int unsigned	access_host = h;

			fork app_receive(access_host); join_none
		end
		#100ns;
		void'($value$plusargs("PROJECT_FAIL_DWORD=%d", config_seq.fail_dword));
		void'($value$plusargs("PROJECT_FAIL_DIRECTION=%s", config_seq.fail_direction));
		require_true(config_seq.fail_dword <= 6, "failure point must be within six queue writes");
		require_true(cfg.tl_slot_by_host.first(host), "Host mapping missing");

		config_seq.cfg = null;
		config_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[host]].sequencer);
		selection = config_seq.selection;
		require_true(config_seq.cfg == cfg.dpu_cfg, "sequence did not retrieve the shared env_cfg");
		#100ns;

		if (config_seq.fail_dword != 0) begin
			require_true(!config_seq.success && config_seq.error_msg != "", "send failure was not propagated");
			require_true(config_seq.fault_armed && project_config_fault_seq::calls == config_seq.fail_dword,
				"configuration continued sending after failed DWORD");
			foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
				require_true(env.vio_envs[h].function_instances[f].driver_agent.fsm.state != FSM_READY,
					"failed configuration entered packet-ready state");
			end
			`uvm_info("PROJECT_CONFIG_FAILURE_PASS", $sformatf("direction=%s failure=%0d stopped whole configuration sequence",
				config_seq.fail_direction, config_seq.fail_dword), UVM_LOW)
		end else begin
			require_true(config_seq.success, config_seq.error_msg);
			if (!no_vio) begin
				require_true(cfg.dpu_cfg.queues_by_host.num() == host_count, "missing prepared Host");
				require_true(config_seq.vtx_calls == pairs*vf_count*
					($test$plusargs("PROJECT_MIXED_DIRECTIONS") ? 1 : host_count), "VTX hook count differs from actual queues");
				require_true(config_seq.vrx_calls == (tx_only ? 0 : pairs*vf_count*host_count), "VRX hook count differs from actual queues");
				if ($test$plusargs("PROJECT_MIXED_DIRECTIONS")) begin
					int unsigned	q2tc_count;

					foreach (cfg.dpu_cfg.records[name]) begin
						if (cfg.dpu_cfg.records[name].ctx.kind inside
							{DPU_TABLE_Q2TC, DPU_TABLE_N2G, DPU_TABLE_G2P, DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT})
							require_true(cfg.dpu_cfg.records[name].owner.host_id == 0, "RX-only Host contributed QSCH table");
						if (cfg.dpu_cfg.records[name].ctx.kind == DPU_TABLE_Q2TC) q2tc_count++;
					end
					require_true(q2tc_count == 1, "mixed direction lost TX scheduler entry");
				end
				foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
					require_true(env.vio_envs[h].function_instances[f].driver_agent.fsm.state == FSM_READY,
						"successful configuration did not enable packet admission");
				end
			end
			check_receive_path();
			`uvm_info("PROJECT_CONFIG_SEQ_PASS", $sformatf("one sequence retrieved cfg, configured and verified %0d Hosts", host_count), UVM_LOW)
		end

		// APP fixture 此时没有在途 DMA；真实 DUT 项目应由平台确认停机后再释放。
		if (selection != null) begin
			config_seq.release_vio_resources(selection, 1, ok, why);
			require_true(ok, why);
		end
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_EXTERNAL_FLOW_PASS", $sformatf("checks=%0d", checks), UVM_LOW)
		phase.drop_objection(this);
	endtask

	// 只接收本用例显式安排的配置失败；其他 fatal/error 保留 UVM 默认行为。
	class project_bare_expected_failure extends uvm_report_catcher;
		int unsigned	count;
		string		message;
		string		expected_stage;
		bit		expect_completion_error;
		int unsigned	completion_errors;
		int unsigned	read_warnings;
		// 捕获器仅在负例 seq.start 周围注册，不吞整个仿真的错误。
		extern function new();
		// 精确匹配生产配置序列的 fatal，保存阶段用于 run_phase 二次断言。
		extern virtual function action_e catch();
	endclass

	// 构造局部配置失败捕获器。
	function project_bare_expected_failure::new();
		super.new("bare_expected_failure");
	endfunction

	// 返回 CAUGHT 允许负例继续检查 READY；错误 ID 或严重级别不同则继续上报。
	function uvm_report_catcher::action_e project_bare_expected_failure::catch();
		if (expect_completion_error) begin
			if (get_id() == "SCB_CPL_STATUS" && get_severity() == UVM_ERROR &&
				uvm_is_match("Completion status mismatch:*expected=CPL_STATUS_SC got=CPL_STATUS_UR*", get_message())) begin
				completion_errors++;
				return CAUGHT;
			end
			if (get_id() == "RW_SEQ" && get_severity() == UVM_WARNING &&
				uvm_is_match("READ completed with status=CPL_STATUS_UR *", get_message())) begin
				read_warnings++;
				return CAUGHT;
			end
			if (get_id() == "SCB" && get_severity() == UVM_ERROR && completion_errors == 1 &&
				get_message() == "FAIL: 1 mismatches, 0 unexpected completions") return CAUGHT;
		end
		if (get_id() == "PROJECT_CONFIG_SEQ" && get_severity() == UVM_FATAL &&
			uvm_is_match({expected_stage, ":*"}, get_message())) begin
			count++;
			message = get_message();
			return CAUGHT;
		end
		return THROW;
	endfunction

	// 排序夹具只隔离 cfg 的纯数据生成，不注册为生产 cfg，也不接管真实环境 ring。
	// 固定两 PF 的 BAR 顺序与 global_qid 相反，并用非零 doorbell 覆盖默认/显式查找基址合同。
	class project_notify_sort_fixture extends dpu_env_cfg;
		// 构造独立临时 cfg，不 load_params、不创建组件、不发硬件访问。
		extern function new();
		// 检查两 Function × 两 pair 的排序/去重，并验证非零默认基址和显式高位匹配。
		extern function bit check_sort(output string why);
	endclass

	// 夹具生命周期仅覆盖一次排序检查，持有自身的快照和只读 setup。

	function project_notify_sort_fixture::new();
		super.new("notify_sort_fixture");
	endfunction


	// 两 Function 使用同一管理 PF0 BAR 写表；RX/TX 实际地址低七位不同但匹配同一查找基址。
	// 先验证未显式指定基址的导出路径，再验证显式匹配和高位冲突拒绝，失败必须清空目录。

	function bit project_notify_sort_fixture::check_sort(output string why);
		dpu_device_snapshot		snapshot;
		dpu_dut_caps			caps;
		dpu_host_info_t			host;
		dpu_vio_queue_t		queues[$];

		snapshot = new("sort_snapshot");
		caps = new("sort_caps");
		host = '{host_id:0, enabled:1, address_width:64, default:0};
		if (!snapshot.set_dut_caps(caps, why) || !snapshot.add_host(host, why)) return 0;
		for (int unsigned f = 0; f < 2; f++) begin
			dpu_function_key_t		key;
			dpu_pcie_function_id_t		identity;
			dpu_bar_pair_lease_t		bar;
			dpu_vio_policy_t		policy;

			key = '{host_id:0, pf_id:f, kind:DPU_FUNCTION_PF, vf_id:0};
			identity = '{domain:'{host_id:0, segment_id:0}, bdf:16'(f)};
			bar = '{DPU_BAR_DEVICE_MEMORY, 0, (f == 0 ? 64'h800000 : 64'h400000), 64'h200000};
			if (!snapshot.add_function(key, identity, why) || !snapshot.add_bar(key, bar, why)) return 0;
			if (f == 0 && !snapshot.set_expected_af(key, why)) return 0;
			policy.service_key = '{function_key:key, service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
			policy.notify_net_pair5 = 1;
			policy.notify_table_base_provided = 0;
			policy.notify_table_bar = 0;
			policy.notify_table_offset = 0;
			frozen_policies[dpu_service_key_name(policy.service_key)] = policy;
			for (int p = 1; p >= 0; p--) begin
				dpu_vio_queue_t	queue;

				queue.service_key = policy.service_key;
				queue.snapshot = snapshot;
				queue.generation = 1;
				queue.qpair.virtio_pair_index = p;
				queue.qpair.global_qpair_id = f*2+p;
				queue.qpair.rx_local_virtqueue_id = p*2;
				queue.qpair.tx_local_virtqueue_id = p*2+1;
				queue.notify_address = bar.base + 'h104;
				queues.push_back(queue);
				queue.notify_address = bar.base + 'h108;
				queues.push_back(queue);
			end
		end
		if (!snapshot.freeze(why)) return 0;
		bar_map = new("sort_registry");
		if (!bar_map.initialize(snapshot, 1, why)) return 0;
		if (!bar_map.freeze(why)) return 0;
		device_snapshot = snapshot;
		use_driver_reference_layouts();
		frozen_layouts = table_layouts;
		frozen_reg_target = "h0.pf0.bar0";
		queues_by_host[0] = queues;
		if (!materialize_notify_records(why)) return 0;
		if (notify_records.size() != 4) begin
			why = "Notify pair deduplication did not produce four rows";
			return 0;
		end
		foreach (notify_records[i]) begin
			dpu_vio_notify_entry_t	entry;
			int unsigned			expected_pf;
			int unsigned			expected_global;

			entry = dpu_vio_notify_entry_t'(notify_records[i].entry);
			expected_pf = i < 2 ? 1 : 0;
			expected_global = i < 2 ? i+2 : i-2;
			if (notify_records[i].ctx.table_index != i || notify_records[i].owner.pf_id != expected_pf ||
				entry.global_qid != expected_global || entry.local_qid_encoding != ((i%2)*2+1) ||
				entry.base_addr_60_7 != ((expected_pf == 0 ? 64'h800100 : 64'h400100) >> 7)) begin
				why = $sformatf("Notify row %0d does not follow BAR/pair order independent of global_qid", i);
				return 0;
			end
		end
		// 显式 table offset 对齐到0x100；实际通知为0x104/0x108，硬件不比较低七位。
		foreach (frozen_policies[name]) begin
			frozen_policies[name].notify_table_base_provided = 1;
			frozen_policies[name].notify_table_offset = 'h100;
		end
		if (!materialize_notify_records(why)) return 0;
		if (notify_records.size() != 4) begin
			why = "explicit matching Notify base changed pair deduplication";
			return 0;
		end
		foreach (notify_records[i]) begin
			dpu_vio_notify_entry_t	entry;

			entry = dpu_vio_notify_entry_t'(notify_records[i].entry);
			if (entry.base_addr_60_7 != ((i < 2 ? 64'h400100 : 64'h800100) >> 7)) begin
				why = "explicit Notify base did not preserve exported doorbell high bits";
				return 0;
			end
		end
		// 只偏移一个128B查找区间，BAR与范围仍合法，必须由实际doorbell高位检查拒绝。
		foreach (frozen_policies[name]) frozen_policies[name].notify_table_offset = 'h180;
		if (materialize_notify_records(why) ||
			why != "notify table lookup base differs from exported doorbell [60:7]" ||
			notify_records.size() != 0) begin
			why = "mismatched explicit Notify base was accepted or retained a partial directory";
			return 0;
		end
		why = "";
		return 1;
	endfunction


	// 裸配置测试只复用父类的 Intel adapter 容器和断言工具，不调用父类平台配置。
	// 默认 Host0/PF0、Packed、1 对只启 VTX；所有地址布局和软件身份来自生产 cfg。
	// 模型独立按驱动固定端口解释写序，不能因生产布局同时写错而自洽通过。
	class project_bare_config_test extends project_external_integration_test;
		`uvm_component_utils(project_bare_config_test)

		vio_dpu_cfg_seq	bare_seq;
		dpu_bar_target_t	management;
		bit [63:0]		write_offsets[$];
		bit [31:0]		write_values[$];
		int unsigned		indirect_transactions[2];
		int unsigned		read_requests;
		bit			corrupt_readback;
		bit			missing_layout;
		bit			missing_message;
		bit			fail_af_write;
		bit			bad_af_status;
		bit			bad_af_completion;
		int unsigned		af_fail_read = 1;
		int unsigned		af_reads;
		int unsigned		completed_af_reads;
		bit			corrupt_bdf;
		bit			corrupted;
		bit			business_notify_enabled;
		bit [63:0]		business_notify_offset;
		pcie_tl_mem_tlp		business_notifications[$];
		bit				tx_active;
		bit				rx_active;
		int unsigned		active_pairs;

		// 构造测试组件，不提前创建或复制生产 cfg。
		extern function new(string name, uvm_component parent);
		// 参数入口与普通 base_test 相同，仅额外创建模型应用侧 adapter。
		extern virtual function void build_phase(uvm_phase phase);
		// DWORD 小端解码用于独立核对总线写值。
		extern function bit [31:0] payload_dword(input pcie_tl_mem_tlp request);
		// 将真实 BAR 存储组合成 128bit，供最终表内容核对。
		extern function bit [127:0] table_value(input bit [63:0] offset, input int unsigned bytes);
		// 模拟固定驱动端口：四次高到低 data、clear、trigger 后原子提交表项。
		extern function void capture_write(input pcie_tl_mem_tlp request);
		// 真正接收 Intel Memory 请求并发送 Completion；负例按指定位置篡改AF状态/Completion或表读值。
		extern virtual task app_receive(input int unsigned host);
		// 无读回时等待真实应用侧收到所有预期 posted 写；限时且不注入额外 MemRead。
		extern task await_configuration_writes();
		// 独立检查写入白名单、最终表值、Notify 匹配 BAR、QSCH 控制和使能位。
		extern function void check_configuration();
		// MSI-X 三层索引、消息 Host 地址和硬件偏移按实际冻结向量逐项核对。
		extern function void check_msix_tables();
		// 提交一个真实 512B TX descriptor，仅观察 Intel Notify，不模拟 DUT 消费或完成。
		extern task check_tx_notify();
		// 直接启动生产基类；正例到 READY，负例必须 fatal 且不 READY。
		extern virtual task run_phase(uvm_phase phase);
	endclass

	// 只初始化 UVM 组件名，具体场景在 build 解析。
	function project_bare_config_test::new(string name, uvm_component parent);
		super.new(name, parent);
	endfunction

	// 使用真实 load_params 构造资源；不手填布局、BAR 分组、Function 身份或配置 hook。
	// PROJECT_BARE_RX 保留双向场景；RX_ONLY、NO_DIRECTIONS、NO_VIO 及 pairs=0 验证使能边界。
	function void project_bare_config_test::build_phase(uvm_phase phase);
		intel_pcie_vif_t		vif;
		intel_pcie_adapter_config	app_cfg;

		pairs = 1;
		void'($value$plusargs("PROJECT_BARE_PAIRS=%d", pairs));
		tx_only = !$test$plusargs("PROJECT_BARE_RX") && !$test$plusargs("PROJECT_BARE_RX_ONLY");
		no_vio = $test$plusargs("PROJECT_NO_VIO");
		tx_active = !$test$plusargs("PROJECT_BARE_RX_ONLY") && !$test$plusargs("PROJECT_NO_DIRECTIONS");
		rx_active = !tx_only && !$test$plusargs("PROJECT_NO_DIRECTIONS");
		host_count = 1;
		vf_count = 0;
		corrupt_bdf = $test$plusargs("PROJECT_BARE_CORRUPT_BDF");
		corrupt_readback = $test$plusargs("PROJECT_BARE_CORRUPT") || corrupt_bdf;
		missing_message = $test$plusargs("PROJECT_BARE_MSIX_MISSING_MESSAGE");
		msix_mode = $test$plusargs("PROJECT_BARE_MSIX") || missing_message;
		missing_layout = $test$plusargs("PROJECT_BARE_MISSING_LAYOUT");
		fail_af_write = $test$plusargs("PROJECT_BARE_AF_WRITE_FAIL");
		bad_af_status = $test$plusargs("PROJECT_BARE_AF_BAD_STATUS");
		bad_af_completion = $test$plusargs("PROJECT_BARE_AF_CPL_ERROR");
		void'($value$plusargs("PROJECT_BARE_AF_FAIL_READ=%d", af_fail_read));
		require_true(af_fail_read >= 1, "AF failure read index must be positive");
		// 周期负例固定16对、TX-only/Polling；第100次写位于QSCH，避免阶段期望随场景漂移。
		if ((bad_af_status || bad_af_completion) && af_fail_read > 1)
			require_true(af_fail_read == 2 && pairs == 16 && tx_only && !msix_mode,
				"periodic AF failure fixture requires read2, 16 pairs, TX-only and polling");
		require_true(int'(corrupt_readback)+int'(missing_layout)+int'(missing_message)+int'(fail_af_write)+
			int'(bad_af_status)+int'(bad_af_completion) <= 1,
			"select one bare failure per run");
		if (fail_af_write) begin
			pcie_tl_reg_seq::type_id::set_type_override(project_config_fault_seq::get_type());
			project_config_fault_seq::calls = 0;
			project_config_fault_seq::fail_on_call = 1;
		end
		// 故障必须经可选的真实读回路径观察；普通正例仅执行首笔及每100次DWORD写后的AF状态读。
		if (corrupt_readback) aip_cmdline_override::set_val("dpu.verify_readback", "1");

		aip_cmdline_override::set_val("dpu.hosts", "1");
		aip_cmdline_override::set_val("dpu.pfs_per_host", "1");
		aip_cmdline_override::set_val("dpu.vfs_per_pf", "0");
		aip_cmdline_override::set_val("dpu.reg_target", "h0.pf0.bar0");
		aip_cmdline_override::set_val("dpu.print_bar_map", "1");
		aip_cmdline_override::set_val("vio.enabled", no_vio ? "0" : "1");
		aip_cmdline_override::set_val("vio.pairs", $sformatf("%0d", pairs));
		aip_cmdline_override::set_val("vio.tx_enable", tx_active ? "1" : "0");
		aip_cmdline_override::set_val("vio.rx_enable", rx_active ? "1" : "0");
		tx_active &= !no_vio && pairs != 0;
		rx_active &= !no_vio && pairs != 0;
		active_pairs = tx_active || rx_active ? pairs : 0;
		aip_cmdline_override::set_val("vio.queue_type", $test$plusargs("PROJECT_CUSTOM") ? "VQ_CUSTOM" : "VQ_PACKED");
		aip_cmdline_override::set_val("vio.queue_size", "256");
		// RX 的预取 RAM 是平台输入；32 槽小于 256 深度，并按 pair 自动推进起始位置。
		if (rx_active) begin
			aip_cmdline_override::set_val("vio.vrx.dsc_pre_max_num", "3");
			aip_cmdline_override::set_val("vio.prefetch_ram", "ram_h0");
			aip_cmdline_override::set_val("vio.prefetch_start", "0");
			aip_cmdline_override::set_val("vio.prefetch_slots", "32");
		end
		aip_cmdline_override::set_val("vio.features", $test$plusargs("PROJECT_CUSTOM") ? "0" : "0x0000000500000000");
		// 无 VIO 时故意保留 MSI-X 模式且不提供消息；关闭的 service 不得要求中断配置。
		aip_cmdline_override::set_val("vio.completion_mode",
			msix_mode || active_pairs == 0 ? "VIRTIO_COMPLETION_MSIX" : "VIRTIO_COMPLETION_POLLING");
		if (msix_mode && !missing_message) begin
			aip_cmdline_override::set_val("dpu.msix.msg_addr_base", "0x900000000000");
			aip_cmdline_override::set_val("dpu.msix.msg_addr_stride", "4");
			aip_cmdline_override::set_val("dpu.msix.msg_data_base", "0x13572468");
			aip_cmdline_override::set_val("dpu.msix.msg_data_stride", "0x100");
		end
		aip_cmdline_override::set_val("vio.notify_bar", "0");
		aip_cmdline_override::set_val("vio.notify_base", "0");
		aip_cmdline_override::set_val("vio.notify_stride", "0");
		aip_cmdline_override::set_val("vio.notify_encoding", "VIO_NOTIFY_DPU32");
		aip_cmdline_override::set_val("vio.notify_table_bar", "0");
		aip_cmdline_override::set_val("vio.notify_table_offset", "0");
		aip_cmdline_override::set_val("vio.notify_net_pair5", "1");
		// QSCH 使用生产默认值或本次 CLI 参数；fixture 不覆盖 net/group/COS，便于验证真实下发链。

		cfg = project_env_cfg::type_id::create("cfg");
		cfg.vio_cfg.scb_enable = 0;
		cfg.load_params();
		// 不提供未启用模块的布局，证明正常跳过而非仅写入零值；公共 BDF/AF 保持有效。
		if (!tx_active) begin
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_VTX);
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_Q2TC);
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_N2G);
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_G2P);
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_SPWRR);
			cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_TC_WEIGHT);
		end
		if (!rx_active) cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_VRX);
		if (active_pairs == 0) cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_NOTIFY);
		if (missing_layout) cfg.dpu_cfg.table_layouts.delete(DPU_TABLE_NOTIFY);
		require_true(!cfg.dpu_cfg.configure_public, "bare default unexpectedly enables public tables");
		require_true(cfg.dpu_cfg.function_policies.exists(dpu_function_key_name(
			'{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0})),
			"PF0 software route was not generated");

		require_true(uvm_config_db#(intel_pcie_vif_t)::get(null, "uvm_test_top", "intel_vif_0", vif),
			"missing Intel VIF");
		cfg.intel_rc_vifs[0] = vif;
		cfg.intel_cfg_by_slot[0] = intel_pcie_adapter_config::type_id::create("hip_cfg");
		cfg.intel_cfg_by_slot[0].side = INTEL_PCIE_HARD_IP;
		app_cfg = intel_pcie_adapter_config::type_id::create("app_cfg");
		app_cfg.side = INTEL_PCIE_APPLICATION;
		uvm_config_db#(intel_pcie_vif_t)::set(this, "app_0", "vif", vif);
		uvm_config_db#(intel_pcie_adapter_config)::set(this, "app_0", "intel_cfg", app_cfg);
		apps[0] = intel_pcie_if_adapter::type_id::create("app_0", this);
		uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
		env = project_env::type_id::create("env", this);
		bare_seq = vio_dpu_cfg_seq::type_id::create("bare_seq");
	endfunction

	// 这里只接受配置路径发出的完整 DWORD，不掩盖宽度或 byte-enable 错误。
	function bit [31:0] project_bare_config_test::payload_dword(input pcie_tl_mem_tlp request);
		bit [31:0]	value;

		require_true(request.payload.size() == 4 && pcie_tl_mem_valid_bytes(request) == 4,
			"configuration write was not one complete DWORD");
		foreach (request.payload[i]) value[i*8 +: 8] = request.payload[i];
		return value;
	endfunction

	// 表内容从模型真实接收的 posted 写组成；不使用 cfg 的期望值回填存储。
	function bit [127:0] project_bare_config_test::table_value(input bit [63:0] offset, input int unsigned bytes);
		bit [127:0]	value;
		bit [63:0]	address;

		address = management.bar_lease.base + offset;
		for (int unsigned i = 0; i < bytes; i++) begin
			require_true(mmio_bytes[0].exists(address+i), "table byte was never written");
			value[i*8 +: 8] = mmio_bytes[0][address+i];
		end
		return value;
	endfunction

	// 驱动 VTX 0x880134/0x880130，VRX 0x900204/0x900200；每批严格六笔。
	// 独立模型要求 clear 与 trigger 中间不能夹别的写，也不能先触发再补数据。
	function void project_bare_config_test::capture_write(input pcie_tl_mem_tlp request);
		bit [63:0]	offset;
		bit [31:0]	value;
		bit [63:0]	module_offset;
		bit [63:0]	data_offset;
		bit [31:0]	trigger;
		bit [31:0]	index_mask;
		int unsigned	direction;
		int unsigned	last;
		int unsigned	index;

		offset = pcie_tl_mem_wire_addr(request) - management.bar_lease.base;
		value = payload_dword(request);
		if (business_notify_enabled && offset == business_notify_offset) begin
			business_notifications.push_back(request);
			return;
		end
		write_offsets.push_back(offset);
		write_values.push_back(value);
		if (active_pairs == 0)
			require_true(offset inside {'h1010, 'h108000}, "disabled VIO emitted dependent MMIO");
		if (!tx_active) begin
			require_true(!(offset >= 'h880130 && offset <= 'h880140), "disabled VTX emitted MMIO");
			require_true(offset != 'hb001c0 && !(offset >= 'hb10000 && offset < 'hb19000),
				"RX-only/disabled VIO emitted QSCH MMIO");
		end
		if (!rx_active)
			require_true(!(offset >= 'h900200 && offset <= 'h900210), "disabled VRX emitted MMIO");
		if (write_offsets.size() > 1) begin
			require_true(completed_af_reads == 1 + (write_offsets.size()-2)/100,
				"configuration write crossed AF initial/100-DWORD status-read boundary");
		end
		for (int unsigned i = 0; i < 4; i++)
			mmio_bytes[0][management.bar_lease.base+offset+i] = request.payload[i];

		// AF 声明必须是第一笔完整 DWORD；真实地址由管理 BAR 租约加固定偏移得到。
		if (write_offsets.size() == 1 || offset == 'h1010) begin
			require_true(write_offsets.size() == 1 && offset == 'h1010 && value == 32'h5555_aaaa,
				"AF declaration must be the first and only 0x1010 write with data 0x5555aaaa");
			require_true(pcie_tl_mem_wire_addr(request) == management.bar_lease.base + 64'h1010,
				"AF declaration did not use allocated PF0 BAR0");
			require_true(!cfg.dpu_cfg.configure_public && read_requests == 0,
				"AF declaration depends on public tables or followed an unexpected read");
		end

		// 仅允许 AF、必要 BDF 和所选 MSI-X；BAR/PFVF/其他公共表不得被总开关带入。
		require_true(offset == 'h1010 || offset == 'h108000 || offset == 'h80044 ||
			(msix_mode && ((offset >= 'hc0000 && offset < 'hc4000) ||
				(offset >= 'h120000 && offset < 'h124000) ||
				(offset >= 'h140000 && offset < 'h141000) ||
				(offset >= 'h150000 && offset < 'h151000))) ||
			(offset >= 'ha0000 && offset < 'ha2000) ||
			(offset >= 'hb10000 && offset < 'hb19000) || offset == 'hb001c0 ||
			(offset >= 'h880130 && offset <= 'h880140) ||
			(offset >= 'h900200 && offset <= 'h900210),
			$sformatf("unexpected/public table write offset=0x%h", offset));

		if (!(offset inside {'h880130, 'h900200})) return;
		direction = offset == 'h880130 ? 0 : 1;
		module_offset = direction == 0 ? 'h880000 : 'h900000;
		data_offset = direction == 0 ? 'h880134 : 'h900204;
		trigger = direction == 0 ? 'h2000 : 'h10000;
		index_mask = direction == 0 ? 'h7ff : 'hffff;
		if ((value & trigger) == 0) return;

		last = write_offsets.size()-1;
		require_true(last >= 5, "queue triggered before four data DWORDs and clear");
		for (int unsigned d = 0; d < 4; d++) begin
			require_true(write_offsets[last-5+d] == data_offset+(3-d)*4,
				"queue data order is not high DWORD to low DWORD");
		end
		require_true(write_offsets[last-1] == offset && write_values[last-1] == (value & ~trigger),
			"queue clear/trigger ordering or index differs");
		index = value & index_mask;
		for (int unsigned b = 0; b < 16; b++) begin
			mmio_bytes[0][management.bar_lease.base+module_offset+'h10000+index*16+b] =
				mmio_bytes[0][management.bar_lease.base+data_offset+b];
		end
		indirect_transactions[direction]++;
	endfunction

	// 所有 readback 都通过 Intel Completion 往返，不能用共享 cfg 直接返回成功。
	task project_bare_config_test::app_receive(input int unsigned host);
		forever begin
			pcie_tl_tlp		t;
			pcie_tl_mem_tlp		m;
			pcie_tl_cpl_tlp		c;
			bit [63:0]		offset;

			wait (apps[host].rx_queue.size() != 0);
			apps[host].receive(t);
			if (t == null) continue;
			require_true($cast(m, t), "bare configuration issued non-Memory request");
			offset = pcie_tl_mem_wire_addr(m) - management.bar_lease.base;
			// 可选迁移审计只记录实际 Intel 请求；字段独立展开，保留原始事务顺序。
			if ($test$plusargs("PROJECT_MMIO_TRACE")) begin
				string	payload;

				payload = "";
				foreach (m.payload[i]) payload = {payload, $sformatf("%02h", m.payload[i])};
				$display("MMIO_TRACE host=%0d bar=%0d base=%016h offset=%016h kind=%s bytes=%0d first=%h last=%h payload=%s",
					host, m.cq_route.bar_id, management.bar_lease.base, offset,
					m.kind.name(), m.length * 4, m.first_be, m.last_be, payload);
			end

			if (!business_notify_enabled)
				require_true(m.tc == 0 && m.attr == 0, "configuration request allowed relaxed ordering or a different TC");
			if (offset == 'h1010) begin
				require_true(host == 0 && pcie_tl_mem_valid_bytes(m) == 4,
					"AF declaration/status must use Host0 RC complete DWORD access");
			end
			// DUT 未用 Notify 行由复位提供无效值；配置过程只可访问实际 pair，读写共用此边界检查。
			if (offset >= 'ha0000 && offset < 'ha2000) begin
				require_true(offset + pcie_tl_mem_dw_count(m)*4 <= 'ha0000 + 64'(pairs)*16,
					"configuration accessed an unused Notify row");
			end
			if (m.kind == TLP_MEM_WR) begin
				posted[host].push_back(m);
				capture_write(m);
			end else begin
				read_requests++;
				c = new("bare_readback");
				c.kind = TLP_CPLD;
				c.type_f = TLP_TYPE_CPL;
				c.fmt = FMT_3DW_WITH_DATA;
				c.requester_id = m.requester_id;
				c.tag = m.tag;
				c.completer_id = 0;
				c.cpl_status = CPL_STATUS_SC;
				c.length = m.length;
				c.byte_count = pcie_tl_mem_valid_bytes(m);
				c.lower_addr = m.addr[6:0] + pcie_tl_mem_first_valid_in_range(m, 0, pcie_tl_mem_dw_count(m)*4);
				c.payload = new[pcie_tl_mem_dw_count(m)*4];
				foreach (c.payload[i]) begin
					c.payload[i] = mmio_bytes[host].exists(pcie_tl_mem_wire_addr(m)+i) ?
						mmio_bytes[host][pcie_tl_mem_wire_addr(m)+i] : 0;
				end
				offset = pcie_tl_mem_wire_addr(m) - management.bar_lease.base;
				if (offset == 'h1010) begin
					af_reads++;
					require_true(write_offsets.size() == 1 + (af_reads-1)*100,
						"AF status read was missing/extra or not at the initial/100-write boundary");
					c.payload = '{8'h08, 8'h00, 8'h00, 8'h00};
					if (bad_af_status && af_reads == af_fail_read) c.payload[0] = 7;
					if (bad_af_completion && af_reads == af_fail_read) begin
						c.kind = TLP_CPL;
						c.fmt = FMT_3DW_NO_DATA;
						c.cpl_status = CPL_STATUS_UR;
						c.length = 0;
						c.byte_count = 0;
						c.payload = new[0];
					end
					// 设备模型故意延迟响应，期间不得已有后续配置写越过该同步读。
					#50ns;
					require_true(apps[host].rx_queue.size() == 0, "configuration continued before AF Completion");
				end
				if (corrupt_readback && !corrupted &&
					(corrupt_bdf ? offset == 'h108000 : (offset >= 'ha0000 && offset < 'ha2000))) begin
					int unsigned	slot;
					bit [63:0]	address;

					// 注入的是设备寄存器存储错误，而非 PCIe 传输损坏：模型存储和
					// SCB 的设备数据基准同步变化，生产 cfg 的期望值保持原样。
					// 因此 PCIe 字节完整性仍通过，配置 seq 必须从真实 Completion 检出不一致。
					c.payload[0] ^= 8'h1;
					address = pcie_tl_mem_wire_addr(m);
					slot = cfg.tl_slot_by_host[host];
					mmio_bytes[host][address] = c.payload[0];
					require_true(env.pcie_env.scbs.size() > slot && env.pcie_env.scbs[slot] != null,
						"readback fault requires active PCIe scoreboard");
					require_true(env.pcie_env.scbs[slot].written_data.exists(address),
						"readback fault byte has no observed PCIe write");
					env.pcie_env.scbs[slot].written_data[address] = c.payload[0];
					corrupted = 1;
				end
				apps[host].send(c);
				if (offset == 'h1010) completed_af_reads++;
			end
		end
	endtask

	// 以冻结的唯一表项计算发送笔数：AF 一笔、活动 Notify pair、仅 TX 的 QSCH mode、普通 DWORD 表，
	// VTX/VRX 各有初始化和使能两组六笔写。按接收完成数等待，不用任意固定延迟假设。
	task project_bare_config_test::await_configuration_writes();
		int unsigned	expected_writes;

		expected_writes = 1 + (active_pairs != 0 ? 1 : 0) + active_pairs*4 +
			(msix_mode ? 2048*2 : 0) + (tx_active && cfg.dpu_cfg.qsch_configure_controls ? 1 : 0);
		foreach (cfg.dpu_cfg.records[name]) begin
			case (cfg.dpu_cfg.records[name].ctx.kind)
				DPU_TABLE_NOTIFY, DPU_TABLE_MSIX_LINEAR: ;
				DPU_TABLE_VTX, DPU_TABLE_VRX: expected_writes += 12;
				default: expected_writes += cfg.dpu_cfg.records[name].ctx.layout.entry_bytes/4;
			endcase
		end
		for (int unsigned attempt = 0; attempt < 10000 && write_offsets.size() < expected_writes; attempt++) #10ns;
		require_true(write_offsets.size() == expected_writes,
			$sformatf("configuration posted writes incomplete/extra: received=%0d expected=%0d",
				write_offsets.size(), expected_writes));
		require_true(indirect_transactions[0] == (tx_active ? pairs*2 : 0) &&
			indirect_transactions[1] == (rx_active ? pairs*2 : 0),
			"posted drain did not receive all queue enable triggers");
	endtask

	// 逐项检查活动队列的 enabled 内容和关闭模块无写入；Notify 核对 Function BAR 与连续写序。
	function void project_bare_config_test::check_configuration();
		int unsigned	counts[dpu_table_kind_e];
		int unsigned	notify_writes;
		int unsigned	notify_enables;
		int unsigned	last_notify;
		int unsigned	first_qsch;
		int unsigned	bdf_writes;
		int unsigned	bdf_position;
		int unsigned	first_queue_trigger;
		bit [127:0]	expected;
		bit [127:0]	actual;

		require_true(write_offsets.size() != 0 && write_offsets[0] == 'h1010 &&
			write_values[0] == 32'h5555_aaaa && table_value('h1010, 4) == 128'h5555_aaaa,
			"default configuration did not declare AF before table writes");
		require_true(indirect_transactions[0] == (tx_active ? pairs*2 : 0), "VTX initial/enabled write count");
		require_true(indirect_transactions[1] == (rx_active ? pairs*2 : 0), "VRX initial/enabled write count");
		require_true(af_reads == 1 + (write_offsets.size()-1)/100 && completed_af_reads == af_reads,
			"AF initial/periodic read count differs from completed DWORD writes");
		if (cfg.dpu_cfg.verify_readback)
			require_true(read_requests > af_reads, "enabled table readback performed no extra MemRead");
		else
			require_true(read_requests == af_reads, "default configuration read beyond required AF status reads");
		if (tx_active) require_true(table_value('hb001c0, 4) == 0, "QSCH mode is not VNET");
		else require_true(!mmio_bytes[0].exists(management.bar_lease.base+'hb001c0), "inactive QSCH mode was written");

		foreach (cfg.dpu_cfg.records[name]) begin
			dpu_table_item_t	r;

			r = cfg.dpu_cfg.records[name];
			counts[r.ctx.kind]++;
			require_true(r.ctx.kind inside {DPU_TABLE_NOTIFY, DPU_TABLE_Q2TC, DPU_TABLE_N2G, DPU_TABLE_G2P,
				DPU_TABLE_SPWRR, DPU_TABLE_TC_WEIGHT, DPU_TABLE_VTX, DPU_TABLE_VRX, DPU_TABLE_BDF,
				DPU_TABLE_MSIX_LINEAR, DPU_TABLE_MSIX_INFO, DPU_TABLE_MSIX_INTERVAL, DPU_TABLE_MSIX_TABLE}, "unexpected public record");
			expected = (r.entry & ~r.enable_mask) | r.enable_value;
			actual = table_value(r.ctx.byte_offset, r.ctx.layout.entry_bytes);
			require_true(actual === expected, $sformatf("final table value differs: %s", name));
			if (r.ctx.kind == DPU_TABLE_BDF) begin
				require_true(r.ctx.byte_offset == 'h108000 && actual == 'h10000,
					"PF0 BDF mapping differs from valid requester=0");
			end
			if (r.ctx.kind == DPU_TABLE_NOTIFY) begin
				dpu_vio_notify_entry_t	entry;

				entry = dpu_vio_notify_entry_t'(actual);
				require_true(entry.base_addr_60_7 == management.bar_lease.base[60:7], "Notify table does not use assigned PF0 BAR");
				require_true(entry.local_qid_encoding == (r.binding.qpair.virtio_pair_index << 1 | 1), "Notify local pair encoding");
				require_true(r.binding.notify_address == management.bar_lease.base, "runtime doorbell differs from assigned BAR");
			end
			if (r.ctx.kind == DPU_TABLE_SPWRR)
				require_true(actual == cfg.dpu_cfg.qsch_spwrr, "SPWRR parameter did not reach DUT");
			if (r.ctx.kind == DPU_TABLE_TC_WEIGHT)
				require_true(actual == cfg.dpu_cfg.qsch_tc_weight, "TC weight parameter did not reach DUT");
			if (r.ctx.kind == DPU_TABLE_VTX) begin
				dpu_vtx_entry_t	entry;

				entry = dpu_vtx_entry_t'(actual);
				require_true(entry.q_depth == 8, "VTX depth does not match 256 descriptors");
				require_true(entry.virtio_mode == ($test$plusargs("PROJECT_CUSTOM") ? 0 : 1), "VTX Packed/Custom mode differs");
			end
		end
		// 独立核对 CLI→cfg→配置 seq→Intel 接口收到的地址/数值，不仅与 records 自己比较。
		// 固定例指定 net100/group20/HOST0；随机例限制 net100..103/group20..23/ETH0..1。
		if (tx_active && ($test$plusargs("PROJECT_QSCH_FIXED") || $test$plusargs("PROJECT_QSCH_RANDOM"))) begin
			dpu_qsch_q2tc_entry_t	q2tc;
			dpu_qsch_n2g_entry_t		n2g;
			dpu_qsch_g2p_entry_t		g2p;
			bit						fixed_ids;

			fixed_ids = $test$plusargs("PROJECT_QSCH_FIXED");
			q2tc = dpu_qsch_q2tc_entry_t'(table_value('hb10000, 4));
			n2g  = dpu_qsch_n2g_entry_t'(table_value('hb12000 + 4*q2tc.net_id, 4));
			g2p  = dpu_qsch_g2p_entry_t'(table_value('hb14000 + 4*n2g.group_id, 4));
			require_true(q2tc.valid && q2tc.cos == 3 && q2tc.net_id >= 100 &&
				q2tc.net_id <= (fixed_ids ? 100 : 103), "CLI net/COS absent from actual Q2TC write");
			require_true(n2g.valid && n2g.group_id >= 20 && n2g.group_id <= (fixed_ids ? 20 : 23),
				"CLI group absent from actual N2G write");
			require_true(g2p.valid && g2p.lvl2_id == 0 && (fixed_ids ? g2p.dpt == 8 : g2p.dpt <= 1),
				"CLI node absent from actual G2P write");
			require_true(table_value('hb16000 + 4*q2tc.net_id, 4) == 'h55 &&
				table_value('hb18000 + 4*q2tc.net_id, 4) == 'h87654321,
				"CLI scheduler controls were written at a different net index");
		end
		require_true(counts[DPU_TABLE_NOTIFY] == active_pairs &&
			counts[DPU_TABLE_VTX] == (tx_active ? pairs : 0) &&
			counts[DPU_TABLE_VRX] == (rx_active ? pairs : 0) &&
			counts[DPU_TABLE_Q2TC] == (tx_active ? pairs : 0), "queue-derived table count differs");
		if (tx_active) begin
			require_true(counts[DPU_TABLE_N2G] != 0 && counts[DPU_TABLE_G2P] != 0 &&
				counts[DPU_TABLE_SPWRR] != 0 && counts[DPU_TABLE_TC_WEIGHT] != 0, "scheduler tables incomplete");
		end else begin
			require_true(counts[DPU_TABLE_N2G]+counts[DPU_TABLE_G2P]+counts[DPU_TABLE_SPWRR]+
				counts[DPU_TABLE_TC_WEIGHT] == 0, "disabled TX generated scheduler records");
		end

		require_true(counts[DPU_TABLE_BDF] == 1, "default configuration must contain PF0 BDF exactly once");
		first_queue_trigger = '1;
		foreach (write_offsets[i]) begin
			if (write_offsets[i] == 'h108000) begin
				bdf_writes++;
				bdf_position = i;
			end
			if (((write_offsets[i] == 'h880130 && (write_values[i] & 'h2000) != 0) ||
				(write_offsets[i] == 'h900200 && (write_values[i] & 'h10000) != 0)) && first_queue_trigger == '1)
				first_queue_trigger = i;
		end
		require_true(bdf_writes == 1 && bdf_position < first_queue_trigger,
			"BDF was missing/duplicated or written after queue programming");
		if (msix_mode) begin
			require_true(counts[DPU_TABLE_MSIX_LINEAR] == cfg.dpu_cfg.frozen_messages.size() &&
				counts[DPU_TABLE_MSIX_INFO] == cfg.dpu_cfg.frozen_messages.size() &&
				counts[DPU_TABLE_MSIX_INTERVAL] == cfg.dpu_cfg.frozen_messages.size() &&
				counts[DPU_TABLE_MSIX_TABLE] == cfg.dpu_cfg.frozen_messages.size(), "MSI-X table/vector count differs");
			check_msix_tables();
		end else begin
			require_true(counts[DPU_TABLE_MSIX_LINEAR]+counts[DPU_TABLE_MSIX_INFO]+counts[DPU_TABLE_MSIX_INTERVAL]+
				counts[DPU_TABLE_MSIX_TABLE] == 0, "polling unexpectedly generated MSI-X records");
		end
		notify_writes = 0;
		first_qsch = '1;
		foreach (write_offsets[i]) begin
			if (write_offsets[i] == 'h80044) begin
				notify_enables++;
				require_true(notify_writes == active_pairs*4 && i > last_notify &&
					write_values[i] == 1 && first_qsch == '1,
					"Notify enable must follow all rows and precede scheduler configuration");
			end
			if (write_offsets[i] == 'hb001c0 ||
				(write_offsets[i] >= 'hb10000 && write_offsets[i] < 'hb19000)) first_qsch = i;
			if (write_offsets[i] < 'ha0000 || write_offsets[i] >= 'ha2000) continue;
			require_true(write_offsets[i] == 'ha0000 + 64'(notify_writes/4)*16 + (3-(notify_writes%4))*4,
				"Notify rows are not sequential or DWORD writes are not high to low");
			notify_writes++;
			last_notify = i;
		end
		require_true(notify_enables == (active_pairs != 0 ? 1 : 0), "Notify enable count differs from active queues");
		require_true(notify_writes == active_pairs*4, "Notify must contain exactly one written row per active queue pair");
		if (cfg.dpu_cfg.verify_readback && !msix_mode) begin
			// 每个唯一表项读一次，加 QSCH mode 一次；不存在未用 Notify 行的额外读回。
			require_true(read_requests == af_reads + cfg.dpu_cfg.records.num() +
				(tx_active && cfg.dpu_cfg.qsch_configure_controls ? 1 : 0),
				"configuration read count includes missing/extra table reads");
		end
	endfunction

	// 消息地址是 Host 写目标；按局部 vector 生成地址/data，再与队列导出及三张全局表交叉核对。
	// Linear 表独立按 local-vector 顺序检查有效行，并检查全部 2048 行尾部和高到低写序。
	function void project_bare_config_test::check_msix_tables();
		vio_queue_setup_t	queues[$];
		dpu_msix_message_t	messages[$];
		int unsigned		linear_writes;

		messages = cfg.dpu_cfg.frozen_messages;
		messages.sort() with (item.local_vector);
		require_true(messages.size() != 0, "MSI-X mode published no messages");
		foreach (messages[i]) begin
			dpu_msix_linear_entry_t	linear;
			dpu_msix_info_entry_t	info;
			dpu_msix_table_entry_t	message;
			bit [63:0]			expected_address;
			bit [31:0]			expected_data;

			expected_address = 64'h900000000000 + messages[i].local_vector*4;
			expected_data = 32'h13572468 + messages[i].local_vector*32'h100;
			linear = dpu_msix_linear_entry_t'(table_value('hc0000+i*8, 8));
			info = dpu_msix_info_entry_t'(table_value('h150000+messages[i].global_vector*4, 4));
			message = dpu_msix_table_entry_t'(table_value('h120000+messages[i].global_vector*16, 16));
			require_true(linear.global_msix_idx == messages[i].global_vector &&
				linear.local_msix_idx == messages[i].local_vector && linear.host_id == 0 && linear.pfvf_id == 0,
				"MSI-X linear row disagrees with actual Function/vector binding");
			require_true(info.valid && !info.self_mask && info.host_id == 0 && info.function_id == 0,
				"MSI-X info PF0/default policy mismatch");
			require_true(table_value('h140000+messages[i].global_vector*4, 4) == 0,
				"default MSI-X interval must be zero");
			require_true(messages[i].address == expected_address && messages[i].data == expected_data &&
				message.msix_addr == expected_address && message.msix_data == expected_data && !message.msix_mask,
				"MSI-X message address/data did not use explicit Host parameters");
			require_true(expected_address < management.bar_lease.base ||
				expected_address >= management.bar_lease.base+management.bar_lease.size,
				"MSI-X Host message address incorrectly aliases DUT BAR");
		end
		env.vio_envs[0].get_external_setup().list_queues(queues);
		foreach (queues[q]) begin
			bit	found;

			foreach (messages[i]) begin
				if (messages[i].local_vector != queues[q].qpair.local_msix_vector_id) continue;
				found = 1;
				require_true(queues[q].notification.msix_valid &&
					queues[q].notification.global_vector == messages[i].global_vector &&
					queues[q].qpair.global_msix_vector_id == messages[i].global_vector &&
					queues[q].notification.message_address == messages[i].address &&
					queues[q].notification.message_data == messages[i].data,
					"queue MSI-X export differs from configured message/vector");
			end
			require_true(found, "queue has no configured MSI-X message");
		end
		for (int unsigned row = messages.size(); row < 2048; row++) begin
			dpu_msix_linear_entry_t	entry;

			entry = dpu_msix_linear_entry_t'(table_value('hc0000+row*8, 8));
			require_true(entry.global_msix_idx == '1 && entry.host_id == '1 && entry.pfvf_id == '1 &&
				entry.local_msix_idx == '1 && entry.reserved_63_35 == 0,
				"MSI-X linear unused row was not invalid sentinel");
		end
		foreach (write_offsets[i]) begin
			if (write_offsets[i] < 'hc0000 || write_offsets[i] >= 'hc4000) continue;
			require_true(write_offsets[i][2:0] == (1-linear_writes%2)*4,
				"MSI-X linear writes must be high DWORD then low DWORD");
			linear_writes++;
		end
		require_true(linear_writes == 2048*2, "MSI-X linear bank was not written completely");
	endfunction

	// Host 写入真实 ring 和报文 backing 后由正常 ops 路径发 Notify；模型不返回完成。
	// 本检查仅证明配置结果可供首次 TX 通知使用；最后由已静止模型授权回收未完成资源。
	task project_bare_config_test::check_tx_notify();
		vio_queue_setup_t		queues[$];
		vio_queue_setup_t		tx_queue;
		virtio_function_instance		instance;
		packet_item			packet;
		virtio_net_hdr_t			header;
		byte unsigned			wire_bytes[$];
		int unsigned			descriptor;
		bit				found;
		bit [31:0]			notify_word;
		dpu_vio_notify_entry_t	lookup;

		env.vio_envs[0].get_external_setup().list_queues(queues);
		foreach (queues[q]) begin
			if (queues[q].tx_mode && queues[q].qpair.virtio_pair_index == 0) begin
				tx_queue = queues[q];
				found = 1;
				break;
			end
		end
		require_true(found, "first TX queue is absent after configuration");
		foreach (env.vio_envs[0].function_instances[f]) begin
			if (dpu_service_key_name(env.vio_envs[0].function_instances[f].service_key) ==
				dpu_service_key_name(tx_queue.service_key)) instance = env.vio_envs[0].function_instances[f];
		end
		require_true(instance != null, "TX Function instance is absent");
		packet = new("bare_tx_frame512");
		require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_UDP; pkt_len == 512;}, "TX packet randomization");
		packet.pkt.do_pack();
		require_true(virtio_net_packet_adapter::pack(packet, wire_bytes) && wire_bytes.size() == 512,
			"TX packet is not exactly 512 wire bytes");
		header = '{default:0};
		business_notify_enabled = 1;
		instance.driver_agent.ops.tx_submit(tx_queue.notification.local_qid, header, packet, 0, descriptor);
		require_true(descriptor != '1, "configured TX queue rejected submission");
		for (int unsigned attempt = 0; attempt < 100 && business_notifications.size() == 0; attempt++) #10ns;
		require_true(business_notifications.size() == 1, "first TX did not produce exactly one real Intel Notify");
		require_true(pcie_tl_mem_wire_addr(business_notifications[0]) == tx_queue.notify_address &&
			tx_queue.notify_address == management.bar_lease.base, "business Notify used wrong assigned BAR address");
		notify_word = payload_dword(business_notifications[0]);
		require_true(notify_word[15:0] == tx_queue.notification.local_qid && notify_word[30:16] != 0,
			"DPU32 business Notify lost local qid or producer position");
		lookup = dpu_vio_notify_entry_t'(table_value('ha0000, 16));
		require_true(lookup.host_id == 0 && lookup.base_addr_60_7 == tx_queue.notify_address[60:7] &&
			lookup.local_qid_encoding == notify_word[6:0] && lookup.global_qid == tx_queue.qpair.global_qpair_id,
			"business Notify does not resolve through the configured sorted table row");
		`uvm_info("PROJECT_BARE_TX_NOTIFY_PASS",
			"512-byte TX submitted and real Intel DPU32 Notify matched BAR/local-qid/global-qid; DUT packet completion is not modeled",
			UVM_LOW)
	endtask

	// 与 AIP 同样在 RC sequencer 上启动基类；cfg 由 pre_start 的 config_db 取得。
	// 失败即使被测试捕获，也不得提交 READY；清理前保证模型无在途请求。
	task project_bare_config_test::run_phase(uvm_phase phase);
		project_bare_expected_failure	catcher;
		project_notify_sort_fixture	sort_fixture;
		string				why;
		bit				ok;
		time				started;

		phase.raise_objection(this);
		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", management, why), why);
		fork app_receive(0); join_none
		#100ns;
		catcher = new();
		catcher.expected_stage = (bad_af_status || bad_af_completion) ?
			(af_fail_read == 1 ? "declare_af" : "configure_qsch") : fail_af_write ? "declare_af" : missing_message ? "select_msix_scope" :
			(corrupt_bdf ? "verify_function_configuration" :
			(corrupt_readback ? "verify_vio_configuration" : "prepare_vio_configuration"));
		catcher.expect_completion_error = bad_af_completion;
		if (corrupt_readback || missing_layout || missing_message || fail_af_write || bad_af_status || bad_af_completion)
			uvm_report_cb::add(null, catcher);
		started = $time;
		bare_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[0]].sequencer);
		if (corrupt_readback || missing_layout || missing_message || fail_af_write || bad_af_status)
			uvm_report_cb::delete(null, catcher);
		selection = bare_seq.selection;
		require_true(bare_seq.cfg == cfg.dpu_cfg, "bare sequence did not retrieve the same env_cfg");

		if (corrupt_readback || missing_layout || missing_message || fail_af_write || bad_af_status || bad_af_completion) begin
			require_true(catcher.count == 1 && !bare_seq.success && bare_seq.error_msg != "",
				"configuration failure did not report exactly one fatal");
			if (fail_af_write) begin
				require_true(project_config_fault_seq::calls == 1 && write_offsets.size() == 0 && read_requests == 0,
					"AF send failure did not stop all following Memory requests");
			end else if (bad_af_status || bad_af_completion) begin
				#100ns;
				require_true(write_offsets.size() == 1 + (af_fail_read-1)*100 && af_reads == af_fail_read &&
					read_requests == af_fail_read, "AF read failure allowed later requests or polling");
				if (bad_af_status) require_true(uvm_is_match("*AF status expected 0x00000008, got 0x00000007", bare_seq.error_msg),
					"wrong AF value did not stop configuration");
				if (bad_af_completion) require_true(catcher.completion_errors == 1 && catcher.read_warnings == 1 &&
					env.pcie_env.scbs[cfg.tl_slot_by_host[0]].mismatched == 1,
					"skipping data comparison suppressed Completion status checking");
			end else if (corrupt_readback) begin
				require_true(corrupted && read_requests > 0 && $time > started, "negative readback never reached Intel completion");
			end else if (missing_message) begin
				require_true(write_offsets.size() == 0, "missing MSI-X message allowed configuration writes");
			end else begin
				// AF/BDF 可先完成，但缺 Notify 布局不得下发任何队列/通知/调度配置。
				foreach (write_offsets[i]) require_true(write_offsets[i] inside {'h1010, 'h108000},
					"missing Notify layout allowed dependent configuration writes");
			end
			foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
				require_true(env.vio_envs[h].function_instances[f].driver_agent.fsm.state != FSM_READY,
					"failed configuration entered READY");
			end
			`uvm_info("PROJECT_BARE_FAILURE_PASS", catcher.message, UVM_LOW)
		end else begin
			require_true(bare_seq.success && $time > started, bare_seq.error_msg);
			require_true(catcher.count == 0, "unexpected configuration fatal");
			await_configuration_writes();
			check_configuration();
			sort_fixture = new();
			require_true(sort_fixture.check_sort(why), why);
			`uvm_info("PROJECT_NOTIFY_BASE_PASS",
				"nonzero exported Notify base, matching high bits with different low bits, mismatch rejection and pair sorting passed",
				UVM_LOW)
			foreach (env.vio_envs[h]) foreach (env.vio_envs[h].function_instances[f]) begin
				require_true(env.vio_envs[h].function_instances[f].driver_agent.fsm.state == FSM_READY,
					"verified bare configuration did not enter READY");
			end
			if (active_pairs == 0) begin
				require_true(selection == null && cfg.dpu_cfg.queues_by_host.num() == 0 &&
					cfg.dpu_cfg.notify_records.size() == 0, "disabled VIO allocated/exported queues");
				foreach (env.vio_envs[h])
					require_true(env.vio_envs[h].function_instances.size() == 0 &&
						env.vio_envs[h].get_external_setup() == null, "disabled VIO created live service/setup");
			end
			if (tx_active) check_tx_notify();
			`uvm_info("PROJECT_BARE_CONFIG_PASS", $sformatf("pairs=%0d active_pairs=%0d tx=%0b rx=%0b writes=%0d reads=%0d elapsed=%0t checks=%0d",
				pairs, active_pairs, tx_active, rx_active, write_offsets.size(), read_requests, $time-started, checks), UVM_LOW)
		end

		#100ns;
		if (selection != null) begin
			bare_seq.release_vio_resources(selection, 1, ok, why);
			require_true(ok, why);
		end
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		phase.drop_objection(this);
	endtask

	// 独立固定入口回归：env 发布前删掉全部布局，证明新 seq 不依赖已生成的参考表。
	// 继续复用真实 Intel 模型、24 笔配置检查和 512B TX Notify，不覆写产品配置 hook。
	class project_single_queue_config_test extends project_bare_config_test;
		`uvm_component_utils(project_single_queue_config_test)
		// 构造测试组件；不改变父类 Intel 模型的资源所有权。
		extern function new(string name, uvm_component parent);
		// 只替换启动的 seq 并删除布局；软件队列合同沿用 Packed256/Polling/TX-only。
		extern virtual function void build_phase(uvm_phase phase);
		// 正例与发送失败复用父类断言；旧 seq 缺 BDF 仍应准确失败，不能被新入口影响。
		extern virtual task run_phase(uvm_phase phase);
	endclass

	// 初始化父类测试名。
	function project_single_queue_config_test::new(string name, uvm_component parent);
		super.new(name, parent);
	endfunction

	// 构建后删除的是输入布局；真正 frozen 副本仍由产品 env 正常发布，测试不手动回填。
	function void project_single_queue_config_test::build_phase(uvm_phase phase);
		super.build_phase(phase);
		cfg.dpu_cfg.table_layouts.delete();
		if (!$test$plusargs("PROJECT_FIXED_ORIGINAL"))
			bare_seq = project_single_queue_config_seq::type_id::create("fixed_seq");
	endfunction

	// 旧入口负例只允许 AF 写及状态读，精确 BDF fatal 后不生成 ring；其余沿用正常/故障验证。
	task project_single_queue_config_test::run_phase(uvm_phase phase);
		project_bare_expected_failure	catcher;
		string				why;

		require_true(cfg.dpu_cfg.table_layouts.num() == 0 && cfg.dpu_cfg.frozen_layouts.num() == 0,
			"fixed sequence fixture must begin with no input or frozen layouts");
		if (!$test$plusargs("PROJECT_FIXED_ORIGINAL")) begin
			super.run_phase(phase);
			return;
		end

		phase.raise_objection(this);
		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", management, why), why);
		fork app_receive(0); join_none
		#100ns;
		catcher = new();
		catcher.expected_stage = "configure_bdf_table";
		uvm_report_cb::add(null, catcher);
		bare_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[0]].sequencer);
		uvm_report_cb::delete(null, catcher);
		require_true(catcher.count == 1 && !bare_seq.success &&
			uvm_is_match("configure_bdf_table: missing platform layout: DPU_TABLE_BDF\n*", bare_seq.error_msg),
			"original sequence no longer reports its missing BDF layout");
		for (int unsigned attempt = 0; attempt < 1000 && write_offsets.size() < 1; attempt++) #10ns;
		#100ns;
		require_true(write_offsets.size() == 1 && write_offsets[0] == 'h1010 && read_requests == 1,
			"original sequence sent configuration after the missing BDF failure");
		require_true(bare_seq.selection == null, "original failure allocated VIO rings");
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_FIXED_ORIGINAL_FAILURE_PASS", catcher.message, UVM_LOW)
		phase.drop_objection(this);
	endtask


	// 快照回归保留真实Intel模型，延迟首次DUT配置到Tcl命令；不绕过产品load_params注册。
	typedef class project_runtime_params_test;
	class project_reload_probe extends aip_cmd;
		project_runtime_params_test	test;
		// 测试命令只校验状态/执行配置，正式重载始终调用env注册的load_params。
		extern function new(input project_runtime_params_test	owner);
		// stage由Tcl指定，所有失败通过真实UVM断言终止。
		extern virtual task cmd_exec();
	endclass

	class project_runtime_params_test extends project_bare_config_test;
		`uvm_component_utils(project_runtime_params_test)
		project_env_cfg		saved_cfg;
		dpu_bar_map	saved_registry;
		dpu_device_snapshot	saved_device;
		dpu_resource_snapshot	saved_resources;
		virtio_net_env_config	saved_host_cfg;
		bit [63:0]		saved_bar;
		bit [15:0]		saved_bdf;
		bit			configured;

		// 父类提供真实Intel模型；此类仅改变测试运行顺序。
		extern function new(string	name, uvm_component	parent);
		// 初始消息用单向量模板，证明恢复未提供的新键不会丢掉旧模板。
		extern virtual function void build_phase(uvm_phase	phase);
		// 同一对象/地址身份、旧值保持、重载后真实配置和中断链路均在这里检查。
		extern task probe(input string	stage);
		// 无 Tcl 时也验证同一命令注册、失败不提交和真实写表；独立 restore 另走 Tcl 分支。
		extern task check_runtime_reload();
		// 进入真实Tcl桥并等待checkpoint/restore；结束后释放模型已停机的资源。
		extern virtual task run_phase(uvm_phase	phase);
	endclass

	function project_reload_probe::new(input project_runtime_params_test	owner);
		super.new("reload_probe");
		test = owner;
	endfunction

	task project_reload_probe::cmd_exec();
		test.probe(args_in);
		status = 0;
		result_out = "OK";
	endtask

	function project_runtime_params_test::new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	function void project_runtime_params_test::build_phase(uvm_phase	phase);
		aip_cmdline_override::set_val("dpu.msix.v0.msg_addr", "0x900000000000");
		aip_cmdline_override::set_val("dpu.msix.v0.msg_data", "0x13572468");
		aip_cmdline_override::set_val("dpu.msix.v1.msg_addr", "0x900000000004");
		aip_cmdline_override::set_val("dpu.msix.v1.msg_data", "0x13572469");
		super.build_phase(phase);
	endfunction

	// 独立常量检查新CLI预期，不能以cfg自身值构造总线期望而掩盖旧缓存。
	task project_runtime_params_test::probe(input string	stage);
		virtio_function_instance		instance;
		vio_service_requirement_t	requirement;
		dpu_bar_target_t		target;
		string				why;

		instance = env.vio_envs[0].function_instances[0];
		require_true(cfg == saved_cfg && cfg.dpu_cfg.bar_map == saved_registry &&
			cfg.dpu_cfg.device_snapshot == saved_device && cfg.dpu_cfg.resource_snapshot == saved_resources &&
			cfg.vio_cfg_by_host[0] == saved_host_cfg, "reload replaced cfg or frozen resource handles");
		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", target, why), why);
		require_true(target.bar_lease.base == saved_bar && instance.pcie_id.bdf == saved_bdf,
			"reload changed assigned BAR/BDF");
		require_true(cfg.vio_cfg_by_host[0].resolve_final_service_requirement(instance.service_key, requirement, why), why);
		if (stage == "before") begin
			require_true(requirement.behavior.queue_size == 256 &&
				requirement.completion_mode == VIRTIO_COMPLETION_POLLING && cfg.dpu_cfg.queues_by_host.num() == 0 &&
				write_offsets.size() == 0 && cfg.dpu_cfg.qsch_spwrr == 'hff &&
				cfg.dpu_cfg.frozen_messages[0].address == 'h900000000000,
				"restore/failed reload changed live values or sent DUT configuration");
			`uvm_info("PROJECT_RELOAD_BEFORE_PASS", "old cached values preserved before explicit load_params", UVM_LOW)
			return;
		end
		require_true(requirement.behavior.queue_size == 512 && requirement.notify_base == 'h80 &&
			requirement.completion_mode == VIRTIO_COMPLETION_MSIX && instance.drv_cfg.queue_size == 512 &&
			instance.driver_agent.fsm.drv_cfg.queue_size == 512, "runtime requirement/driver cache was not refreshed");
		require_true(cfg.dpu_cfg.frozen_messages.size() == 2 && cfg.dpu_cfg.frozen_messages[0].address == 'ha00000000000 &&
			cfg.dpu_cfg.frozen_messages[0].data == 'h24681357 && cfg.dpu_cfg.frozen_messages[1].address == 'h900000000004 &&
			cfg.dpu_cfg.frozen_messages[1].data == 'h13572469, "new v0 or omitted v1 message template was lost");
		require_true(cfg.dpu_cfg.qsch_spwrr == 'h55 && cfg.dpu_cfg.frozen_policies[dpu_service_key_name(instance.service_key)].vtx.dma_info == 5,
			"platform/frozen table policy did not update");
		if (stage == "reloaded") begin
			require_true(write_offsets.size() == 0 && cfg.dpu_cfg.queues_by_host.num() == 0,
				"load_params sent writes or allocated a ring");
			`uvm_info("PROJECT_RELOAD_VALUES_PASS", "same cfg contains refreshed service and frozen table values", UVM_LOW)
			return;
		end
		if (stage == "active") begin
			require_true(configured && cfg.dpu_cfg.queues_by_host.num() == 1 && instance.driver_agent.fsm.state == FSM_READY,
				"rejected active reload changed prepared state");
			return;
		end
		require_true(stage == "configure" && !configured, "unknown/duplicate reload probe stage");
		msix_mode = 1;
		bare_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[0]].sequencer);
		require_true(bare_seq.success, bare_seq.error_msg);
		selection = bare_seq.selection;
		await_configuration_writes();
		foreach (cfg.dpu_cfg.records[name]) begin
			dpu_table_item_t	record;
			bit [127:0]		actual;

			record = cfg.dpu_cfg.records[name];
			actual = table_value(record.ctx.byte_offset, record.ctx.layout.entry_bytes);
			require_true(actual == ((record.entry & ~record.enable_mask) | record.enable_value),
				{"actual reloaded table differs: ", name});
			if (record.ctx.kind == DPU_TABLE_VTX) begin
				dpu_vtx_entry_t	entry;

				entry = dpu_vtx_entry_t'(actual);
				require_true(entry.q_depth == 9 && entry.dma_info == 5, "actual VTX table retained old depth/policy");
			end
			if (record.ctx.kind == DPU_TABLE_SPWRR) require_true(actual == 'h55, "actual QSCH weight retained old value");
			if (record.ctx.kind == DPU_TABLE_NOTIFY) begin
				dpu_vio_notify_entry_t	entry;

				entry = dpu_vio_notify_entry_t'(actual);
				require_true(entry.base_addr_60_7 == ((saved_bar+'h80)>>7), "Notify lookup retained old base");
			end
		end
		begin
			vio_queue_setup_t	rows[$];
			packet_item		packet;
			virtio_net_hdr_t		header;
			uvm_object		completed[$];
			byte			bytes[];
			int unsigned		descriptor;
			bit [31:0]		word_value;
			dpu_function_policy_t	policy;

			env.vio_envs[0].get_external_setup().list_queues(rows);
			require_true(rows.size() == 1 && rows[0].queue_size == 512 &&
				rows[0].notify_address == saved_bar + 'h80, "prepared queue retained old geometry/Notify binding");
			if ($test$plusargs("PROJECT_CUSTOM"))
				require_true(rows[0].private_tx_control.dport_id == 'h23, "Custom private TX control cache was not refreshed");
			business_notify_enabled = 1;
			business_notify_offset = 'h80;
			packet = new("reload_frame512");
			require_true(packet.pkt.randomize() with {pkt_kind == ETH_IPV4_TCP; pkt_len == 512;}, "reload packet randomization");
			packet.pkt.do_pack();
			header = '{default:0};
			instance.driver_agent.ops.tx_submit(rows[0].notification.local_qid, header, packet, 0, descriptor);
			require_true(descriptor != '1, "reloaded queue rejected TX");
			policy = cfg.dpu_cfg.function_policies[dpu_function_key_name(instance.function_key)];
			if (rows[0].queue_type == VQ_CUSTOM) send_memory(0, 1, policy.requester, rows[0].device_iova, 32'h8001);
			else begin
				env.vio_envs[0].host_mem.read_mem(rows[0].desc_gpa + 12, 4, bytes);
				word_value = {bytes[3],bytes[2],bytes[1],bytes[0]} | 32'h80000000;
				send_memory(0, 1, policy.requester, rows[0].desc_iova + 12, word_value);
			end
			#100ns;
			instance.driver_agent.ops.tx_complete(rows[0].notification.local_qid, completed, 8);
			require_true(completed.size() == 0, "reloaded MSI-X queue completed before interrupt");
			send_memory(0, 1, 16'hffff, 64'ha00000000000, 32'h24681357);
			#100ns;
			instance.driver_agent.ops.tx_complete(rows[0].notification.local_qid, completed, 8);
			require_true(completed.size() == 1 && completed[0] == packet && business_notifications.size() == 1 &&
				pcie_tl_mem_wire_addr(business_notifications[0]) == saved_bar + 'h80,
				"new MSI-X message was treated as DMA or reloaded Notify failed");
		end
		configured = 1;
		`uvm_info("PROJECT_RELOAD_DUT_PASS", $sformatf("custom=%0b writes=%0d reads=%0d checks=%0d",
			$test$plusargs("PROJECT_CUSTOM"), write_offsets.size(), read_requests, checks), UVM_LOW)
	endtask

	// 参数只写 AIP 的现有 override 表，正式重载仍经宏注册的 load_params 命令执行。
	task project_runtime_params_test::check_runtime_reload();
		int	status;
		string	result;

		probe("before");
		aip_cmd::exec_result("load_params unexpected", SRC_INTERNAL, status, result);
		require_true(status != 0 && result == "ERROR: load_params takes no arguments",
			"macro command lost no-argument validation");
		aip_cmdline_override::set_val("vio.pairs", "2");
		aip_cmd::exec_result("load_params", SRC_INTERNAL, status, result);
		require_true(status != 0, "runtime reload changed allocated pair count");
		probe("before");
		aip_cmdline_override::clear("vio.pairs");

		aip_cmdline_override::set_val("vio.queue_size", "512");
		aip_cmdline_override::set_val("vio.completion_mode", "VIRTIO_COMPLETION_MSIX");
		aip_cmdline_override::set_val("vio.notify_base", "0x80");
		aip_cmdline_override::set_val("vio.notify_table_offset", "0x80");
		aip_cmdline_override::set_val("dpu.msix.v0.msg_addr", "0xa00000000000");
		aip_cmdline_override::set_val("dpu.msix.v0.msg_data", "0x24681357");
		aip_cmdline_override::set_val("dpu.qsch.spwrr", "0x55");
		aip_cmdline_override::set_val("vio.vtx.dma_info", "5");
		if ($test$plusargs("PROJECT_CUSTOM"))
			aip_cmdline_override::set_val("vio.private.dport_id", "0x23");

		repeat (2) begin
			aip_cmd::exec_result("load_params", SRC_INTERNAL, status, result);
			require_true(status == 0, result);
			probe("reloaded");
		end
		probe("configure");
		aip_cmd::exec_result("load_params", SRC_INTERNAL, status, result);
		require_true(status != 0, "runtime reload accepted an active VIO generation");
		probe("active");
	endtask

	// 初始参数已构建完毕，再清除测试夹具强制值；快照保留cfg，恢复进程用新CLI重新采样。
	task project_runtime_params_test::run_phase(uvm_phase	phase);
		project_reload_probe	command;
		string			why;
		bit			ok;
		string			keys[$] = '{"vio.queue_size", "vio.completion_mode", "vio.notify_base", "vio.notify_table_offset",
			"dpu.msix.v0.msg_addr", "dpu.msix.v0.msg_data", "dpu.msix.v1.msg_addr", "dpu.msix.v1.msg_data"};

		phase.raise_objection(this);
		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", management, why), why);
		saved_cfg = cfg;
		saved_registry = cfg.dpu_cfg.bar_map;
		saved_device = cfg.dpu_cfg.device_snapshot;
		saved_resources = cfg.dpu_cfg.resource_snapshot;
		saved_host_cfg = cfg.vio_cfg_by_host[0];
		saved_bar = management.bar_lease.base;
		saved_bdf = env.vio_envs[0].function_instances[0].pcie_id.bdf;
		foreach (keys[i]) aip_cmdline_override::clear(keys[i]);
		command = new(this);
		fork app_receive(0); join_none
		#100ns;
		if ($test$plusargs("AIP_TCL")) aip_tcl_bridge::run_loop();
		else check_runtime_reload();
		require_true(configured, "restore script never configured DUT");
		bare_seq.release_vio_resources(selection, 1, ok, why);
		require_true(ok, why);
		env.vio_envs[0].host_mem.leak_check();
		`uvm_info("PROJECT_RELOAD_TEST_PASS", "restore/reload/configure/new MSI-X completed", UVM_LOW)
		phase.drop_objection(this);
	endtask

endpackage
