// integration/project/tests：真实 Intel 引脚/monitor/bridge 的项目合同模型回归。
// 应用侧 adapter 仅模拟 DUT 的 BAR MMIO、VTX/VRX 间接表和主动 DMA；Host 仍由项目 RC 唯一响应。
// 裸 seq 回归不覆写生产 hook，以真实 Memory Completion 验证默认配置、读回失败及缺布局拒绝。
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

	// 在指定分段拒绝发送，保留之前真正发出的间接数据端口写。
	task project_config_fault_seq::body();
		if (fail_on_call != 0) begin
			calls++;
			if (calls == fail_on_call) begin
				status = PCIE_RW_ERR;
				error_msg = "injected indirect DWORD send failure";
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

	// 用户仅实现每类别单项访问；外围循环和写序使用 project_dut_config_seq，配置数据来自 cfg。
	class project_external_model_seq extends project_dut_config_seq;
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
		project_pfvf_cfg_t	pfvf_items[string];
		project_vtx_cfg_t	last_vtx;
		project_vrx_cfg_t	last_vrx;
		// 旧分段发送故障由 run_phase 检查；仅该预期失败不交给生产 fatal。
		extern virtual task post_start();
		// 构造模型 hook 容器，不修改生产 build/connect。
		extern function new(string	name = "project_external_model_seq");
		// BAR 编码没有图片规格，测试只核对真实租约组后作为模型平台报告成功。
		extern virtual task user_configure_bar_mapping_entry(input project_bar_mapping_cfg_t item, output bit ok, output string why);
		// 显式平台模型 verify，实际 RTL 应覆写为读回/状态检查。
		extern virtual task user_verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
		extern virtual task user_verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
		extern virtual task user_enable_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
		// 单项 bdf 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_bdf_entry(input project_bdf_cfg_t item, output bit ok, output string why);
		// 单项 pfvf 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_pf_vf_entry(input project_pfvf_cfg_t item, output bit ok, output string why);
		// 单项 msix_linear 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_msix_linear_entry(input project_msix_linear_cfg_t item, output bit ok, output string why);
		// 单项 msix_info 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_msix_info_entry(input project_msix_info_cfg_t item, output bit ok, output string why);
		// 单项 msix_interval 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_msix_interval_entry(input project_msix_interval_cfg_t item, output bit ok, output string why);
		// 单项 msix_table 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_msix_table_entry(input project_msix_table_cfg_t item, output bit ok, output string why);
		// 单项 qsch_q2tc 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
		// 单项 qsch_n2g 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
		// 单项 qsch_g2p 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
		// 单项 vtx 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_vtx_queue(input project_vtx_cfg_t item, output bit ok, output string why);
		// 单项 vrx 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_vrx_queue(input project_vrx_cfg_t item, output bit ok, output string why);
		// 单项 vio_notify 使用产品 checked helper，实际经过 Intel 引脚。
		extern virtual task user_configure_vio_notify_entry(input project_vio_notify_cfg_t item, output bit ok, output string why);
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
	task project_external_model_seq::user_configure_bar_mapping_entry(input project_bar_mapping_cfg_t item, output bit ok, output string why);
		bar_calls++;
		ok = item.members.size() != 0;
		why = ok ? "" : "empty BAR group";
	endtask
	// 模型平台明确报告所选公共配置完成；产品仍检查上下文和依赖。
	task project_external_model_seq::user_verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
		ok = 1; why = "";
	endtask
	// 模型平台明确报告队列配置完成；后续核心 preflight 不能被此成功绕过。
	task project_external_model_seq::user_verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
		ok = !fail_verify; why = ok ? "" : "injected platform verification failure";
	endtask
	// 使能使用唯一 checked 路径，只允许 enable 位变化。
	task project_external_model_seq::user_enable_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
		write_enabled_queue(item, ok, why);
	endtask

	// 单项 bdf 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_bdf_entry(input project_bdf_cfg_t item, output bit ok, output string why);
		write_bdf(item, ok, why);
	endtask

	// 单项 pfvf 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_pf_vf_entry(input project_pfvf_cfg_t item, output bit ok, output string why);
		pfvf_calls++;
		pfvf_items[dpu_function_key_name(item.owner)] = item;
		write_pfvf(item, ok, why);
	endtask

	// 单项 msix_linear 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_msix_linear_entry(input project_msix_linear_cfg_t item, output bit ok, output string why);
		write_msix_linear(item, ok, why);
	endtask

	// 单项 msix_info 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_msix_info_entry(input project_msix_info_cfg_t item, output bit ok, output string why);
		write_msix_info(item, ok, why);
	endtask

	// 单项 msix_interval 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_msix_interval_entry(input project_msix_interval_cfg_t item, output bit ok, output string why);
		write_msix_interval(item, ok, why);
	endtask

	// 单项 msix_table 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_msix_table_entry(input project_msix_table_cfg_t item, output bit ok, output string why);
		write_msix_table(item, ok, why);
	endtask

	// 单项 qsch_q2tc 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
		write_qsch_q2tc(item, ok, why);
	endtask

	// 单项 qsch_n2g 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
		write_qsch_n2g(item, ok, why);
	endtask

	// 单项 qsch_g2p 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
		write_qsch_g2p(item, ok, why);
	endtask

	// 单项 vtx 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_vtx_queue(input project_vtx_cfg_t item, output bit ok, output string why);
		vtx_calls++;
		last_vtx = item;
		if (fail_vtx_call != 0 && vtx_calls == fail_vtx_call) begin ok = 0; why = "injected midway VTX hook failure"; return; end
		arm_send_failure("vtx");
		write_vtx(item, ok, why);
	endtask

	// 单项 vrx 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_vrx_queue(input project_vrx_cfg_t item, output bit ok, output string why);
		vrx_calls++;
		last_vrx = item;
		arm_send_failure("vrx");
		write_vrx(item, ok, why);
	endtask

	// 单项 vio_notify 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_seq::user_configure_vio_notify_entry(input project_vio_notify_cfg_t item, output bit ok, output string why);
		notify_calls++;
		write_vio_notify(item, ok, why);
	endtask

	// 仅此测试模型的明确路由规则，不作为产品硬件默认；实际平台替换此一个纯函数。
	class project_external_model_cfg extends project_env_cfg;
		`uvm_object_utils(project_external_model_cfg)
		// 构造配置，保留生产参数生成器。
		extern function new(string name="project_external_model_cfg");
		// fixture 的 PF0 从 offset1 开始，Pfvf=vf_id+1；完整成员逐项检查，不要求VF连续。
		// 在 placement 前通过同一生成/需求入口建立稀疏实际 VF。
		extern function void add_fixture_vf(input int unsigned vf_id);
		extern virtual function bit validate_pfvf_relationship(input project_pfvf_relationship_t family, output string why);
	endclass

	// fixture 配置仍使用产品解析和资源生成器。
	function project_external_model_cfg::new(string name="project_external_model_cfg");
		super.new(name);
	endfunction

	// 不改冻结快照；稀疏键和精确需求均在 env build 前加入。
	function void project_external_model_cfg::add_fixture_vf(input int unsigned vf_id);
		dpu_function_cfg function_cfg;
		function_cfg = make_function(0, 0, DPU_FUNCTION_VF, vf_id);
		dpu_cfg.device_cfg.functions.push_back(function_cfg);
		add_service_request(function_cfg.key);
	endfunction

	// 测试专用关系规则，绝不作为产品 PFVF 默认。
	function bit project_external_model_cfg::validate_pfvf_relationship(input project_pfvf_relationship_t family, output string why);
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
		project_vio_selection_t	selection;
		// 构造测试组件，不访问设备。
		extern function new(string name, uvm_component parent);
		// 精确失败断言，不能让过程 exit0 代替语义检查。
		extern function void require_true(input bit condition, input string detail);
		// 显式声明本测试模型布局；图片相对偏移与模块偏移分开。
		extern function void add_layout(input project_table_kind_e kind, input int unsigned bytes,
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
	function void project_external_integration_test::add_layout(input project_table_kind_e kind, input int unsigned bytes,
		input int unsigned capacity, input bit [63:0] module_offset, input bit [63:0] table_offset, input bit indirect);
		project_table_layout_t	l;
		l.provided = 1;
		l.reg_target = "pf0.bar0";
		l.access_host_provided = 0;
		l.access_host = 0;
		l.access_uses_owner_host = 1;
		l.module_offset = module_offset;
		l.table_offset = table_offset;
		l.capacity = capacity;
		l.entry_bytes = bytes;
		l.index_policy = PROJECT_INDEX_GLOBAL_VECTOR;
		l.indirect = indirect;
		l.data_port = 'h204;
		l.control_port = 'h200;
		l.index_mask = 'hffff;
		l.control_fixed = 0;
		l.trigger_mask = 'h10000;
		l.index_shift = 0;
		l.required = 1;
		cfg.table_layouts[kind] = l;
	endfunction

	// 配置基于真实 DPU 生成器，精确 enabled/pairs 在 placement 前解析。
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
		cfg = project_external_model_cfg::type_id::create("cfg");
		cfg.driver_layouts = 0;
		cfg.qsch_configure_controls = 0;
		cfg.configure_public = 1;
		cfg.verify_readback = 1;
		cfg.hosts = host_count;
		cfg.vfs_per_pf = vf_count;
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			require_true(host_count == 1 && !no_vio, "PFVF guard needs one Host with VIO");
			vf_count = $test$plusargs("PROJECT_PFVF_SINGLE") ? 1 : 2;
			cfg.vfs_per_pf = 0;
			cfg.pfs_per_host = 2;
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
		cfg.bar_mapping_per_lease = 1;
		for (int unsigned h = 0; h < host_count; h++) begin
			for (int unsigned v = 0; v < vf_count; v++)
				aip_cmdline_override::set_val($sformatf("vio.h%0d.pf0.vf%0d.i0.enabled",h,v), no_vio ? "0" : "1");
		end
		// 全局调度默认与精确 service 覆盖通过真实参数解析验证。
		aip_cmdline_override::set_val("dpu.qsch.cos", "3");
		aip_cmdline_override::set_val("vio.h0.pf0.vf0.i0.qsch.cos", "5");
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			aip_cmdline_override::set_val("vio.h0.pf0.vf3.i0.enabled", "1");
		end
		cfg.load_params();
		if ($test$plusargs("PROJECT_PFVF_GUARD")) begin
			require_true($cast(model_cfg, cfg), "fixture cfg cast");
			model_cfg.add_fixture_vf(0);
			if (!$test$plusargs("PROJECT_PFVF_SINGLE")) model_cfg.add_fixture_vf(3);
		end
		foreach (cfg.vio_policies[name]) begin
			dpu_function_key_t key;
			key = cfg.vio_policies[name].service_key.function_key;
			require_true(cfg.vio_policies[name].cos ==
				((key.host_id == 0 && key.pf_id == 0 && key.kind == DPU_FUNCTION_VF && key.vf_id == 0) ? 5 : 3),
				"dpu.qsch global/service parameter precedence");
		end
		foreach (cfg.dpu_cfg.device_cfg.functions[f]) begin
			project_function_policy_t	p;
			project_vio_policy_t	q;
			dpu_function_key_t	key;
			key = cfg.dpu_cfg.device_cfg.functions[f].key;
			p.key = key;
			p.mode = PROJECT_HOST_EP;
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
			cfg.function_policies[dpu_function_key_name(key)] = p;
			for (int unsigned v = 0; v < 64; v++) begin
				project_msix_message_t	m;
				m.owner = key;
				m.local_vector = v;
				m.global_vector = 0;
				m.address = 64'h0000900000000000 + p.vport * 'h10000 + v * 4;
				m.data = 32'h13572468 ^ (v << 8);
				m.masked = 0;
				cfg.msix_policies[dpu_function_key_name(key)].table_only_enable = 1;
				cfg.msix_policies[dpu_function_key_name(key)].interval_present = 1;
				cfg.msix_policies[dpu_function_key_name(key)].interval_entry = '0;
				cfg.msix_policies[dpu_function_key_name(key)].self_mask_present = 1;
				cfg.msix_policies[dpu_function_key_name(key)].self_mask = 0;
				cfg.message_templates[dpu_function_key_name(key)][v] = m;
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
			q.notify_table_offset = 0;
			cfg.vio_policies[dpu_service_key_name(q.service_key)] = q;
		end
		add_layout(PROJECT_BDF,4,128,'h100000,'h8000);
		add_layout(PROJECT_PFVF,4,4,'h200000,'h8000);
		add_layout(PROJECT_MSIX_LINEAR,8,2048,'h200000,'h40000);
		// MSI-X linear 与 Notify 同为所有 Host 共用的完整排序单 bank。
		cfg.table_layouts[PROJECT_MSIX_LINEAR].reg_target = "h0.pf0.bar0";
		cfg.table_layouts[PROJECT_MSIX_LINEAR].access_host_provided = 0;
		cfg.table_layouts[PROJECT_MSIX_LINEAR].access_uses_owner_host = 0;
		add_layout(PROJECT_MSIX_INFO,4,1024,'h100000,'h50000);
		add_layout(PROJECT_MSIX_INTERVAL,4,1024,'h100000,'h40000);
		add_layout(PROJECT_MSIX_TABLE,16,1024,'h100000,'h20000);
		add_layout(PROJECT_NOTIFY,16,512,'h200000,'h20000);
		// 所有 Host 共用一份排序 Notify 单 bank，其余表仍按所属 Host 选择管理端口。
		cfg.table_layouts[PROJECT_NOTIFY].reg_target = "h0.pf0.bar0";
		cfg.table_layouts[PROJECT_NOTIFY].access_host_provided = 0;
		cfg.table_layouts[PROJECT_NOTIFY].access_uses_owner_host = 0;
		add_layout(PROJECT_VTX,16,2048,'h400000,'h10000,1);
		add_layout(PROJECT_VRX,16,2048,'h500000,'h10000,1);
		add_layout(PROJECT_Q2TC,4,1024,'h600000,'h10000);
		add_layout(PROJECT_N2G,4,2048,'h600000,'h12000);
		add_layout(PROJECT_G2P,4,1024,'h600000,'h14000);

		// 仅显式参考场景采用上传驱动地址；模型不证明真实 RTL 的地址/位域兼容。
		// 生产 cfg 不隐含此选择，队列 data/control 的写序仍采用用户要求的高位先写。
		if ($test$plusargs("PROJECT_DRIVER_PORTS")) begin
			cfg.table_layouts[PROJECT_VTX].module_offset = 'h880000;
			cfg.table_layouts[PROJECT_VTX].data_port     = 'h134;
			cfg.table_layouts[PROJECT_VTX].control_port  = 'h130;
			cfg.table_layouts[PROJECT_VTX].index_mask    = 'h7ff;
			cfg.table_layouts[PROJECT_VTX].trigger_mask  = 'h2000;
			cfg.table_layouts[PROJECT_VTX].index_policy  = PROJECT_INDEX_GLOBAL_QPAIR;

			cfg.table_layouts[PROJECT_VRX].module_offset = 'h900000;
			cfg.table_layouts[PROJECT_VRX].index_policy  = PROJECT_INDEX_GLOBAL_QPAIR;
			cfg.table_layouts[PROJECT_Q2TC].module_offset = 'hb00000;
			cfg.table_layouts[PROJECT_N2G].module_offset  = 'hb00000;
			cfg.table_layouts[PROJECT_G2P].module_offset  = 'hb00000;
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
		config_seq.cfg = cfg;
	endfunction

	// 实际 Intel RX 返回 sideband 与 payload；模型只管理设备 BAR 存储，不响应 Host DMA。
	task project_external_integration_test::app_receive(input int unsigned host);
		forever begin
			pcie_tl_tlp	t;
			pcie_tl_mem_tlp	m;
			pcie_tl_cpl_tlp	c;
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
	task project_external_integration_test::check_receive_path();
		project_function_record_t	functions[$];
		project_dma_expected_error	catcher;
		string	why;
		catcher = new();
		cfg.dpu_setup.list_functions(functions);
		foreach (functions[f]) begin
			bit [63:0]	gpa;
			bit [63:0]	iova;
			bit [63:0]	readonly_iova;
			bit [63:0]	dirty[$];
			byte	bytes[];
			pcie_tl_cpl_tlp	cpl;
			project_function_policy_t	p;
			int unsigned	h;
			if (functions[f].key.kind != DPU_FUNCTION_VF) continue;
			h = functions[f].key.host_id;
			p = cfg.function_policies[dpu_function_key_name(functions[f].key)];
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
		foreach (cfg.messages[m]) begin
			project_msix_message_t message;
			vio_queue_setup_t rows[$];
			bit active;
			message = cfg.messages[m];
			active = 0;
			if (selection.setups.exists(message.owner.host_id)) begin
				selection.setups[message.owner.host_id].list_queues(rows);
				foreach (rows[q]) begin
					virtio_function_instance instance;
					packet_item packet;
					virtio_net_hdr_t hdr;
					uvm_object completed[$];
					byte bytes[];
					int unsigned desc_id;
					bit [31:0] word_value;
					project_function_policy_t policy;
					if (!rows[q].tx_mode || !dpu_same_function_key(rows[q].service_key.function_key, message.owner) ||
						rows[q].qpair.local_msix_vector_id != message.local_vector) continue;
					active = 1;
					if (!msix_mode) continue;
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
					policy = cfg.function_policies[dpu_function_key_name(message.owner)];
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

	// 正常使用方式：只启动一个配置 seq，自动 get 同一 cfg，成功后进入 READY。
	// 故障行每次仿真只注入一个 DWORD，检查整个 body 停止且不进入发包状态。
	task project_external_integration_test::run_phase(uvm_phase	phase);
		bit				ok;
		string			why;
		int unsigned	host;

		phase.raise_objection(this);
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
		config_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[host]]);
		selection = config_seq.selection;
		require_true(config_seq.cfg == cfg, "sequence did not retrieve the shared env_cfg");
		#100ns;

		if (config_seq.fail_dword != 0) begin
			require_true(!config_seq.success && config_seq.error_msg != "", "send failure was not propagated");
			require_true(config_seq.fault_armed && project_config_fault_seq::calls == config_seq.fail_dword,
				"configuration continued sending after failed DWORD");
			foreach (cfg.vio_envs[h]) foreach (cfg.vio_envs[h].function_instances[f]) begin
				require_true(cfg.vio_envs[h].function_instances[f].driver_agent.fsm.state != FSM_READY,
					"failed configuration entered packet-ready state");
			end
			`uvm_info("PROJECT_CONFIG_FAILURE_PASS", $sformatf("direction=%s failure=%0d stopped whole configuration sequence",
				config_seq.fail_direction, config_seq.fail_dword), UVM_LOW)
		end else begin
			require_true(config_seq.success, config_seq.error_msg);
			if (!no_vio) begin
				require_true(selection.setups.num() == host_count, "missing prepared Host");
				require_true(config_seq.vtx_calls == pairs*vf_count*host_count, "VTX hook count differs from actual queues");
				require_true(config_seq.vrx_calls == (tx_only ? 0 : pairs*vf_count*host_count), "VRX hook count differs from actual queues");
				foreach (cfg.vio_envs[h]) foreach (cfg.vio_envs[h].function_instances[f]) begin
					require_true(cfg.vio_envs[h].function_instances[f].driver_agent.fsm.state == FSM_READY,
						"successful configuration did not enable packet admission");
				end
			end
			check_receive_path();
			`uvm_info("PROJECT_CONFIG_SEQ_PASS", $sformatf("one sequence retrieved cfg, configured and verified %0d Hosts", host_count), UVM_LOW)
		end

		// APP fixture 此时没有在途 DMA；真实 DUT 项目应由平台确认停机后再释放。
		if (selection.setups.num() != 0) begin
			cfg.release_vio_resources(selection, 1, ok, why);
			require_true(ok, why);
		end
		foreach (cfg.vio_envs[h]) cfg.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_EXTERNAL_FLOW_PASS", $sformatf("checks=%0d", checks), UVM_LOW)
		phase.drop_objection(this);
	endtask

	// 只接收本用例显式安排的配置失败；其他 fatal/error 保留 UVM 默认行为。
	class project_bare_expected_failure extends uvm_report_catcher;
		int unsigned	count;
		string		message;
		string		expected_stage;
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
		if (get_id() == "PROJECT_CONFIG_SEQ" && get_severity() == UVM_FATAL &&
			uvm_is_match({expected_stage, ":*"}, get_message())) begin
			count++;
			message = get_message();
			return CAUGHT;
		end
		return THROW;
	endfunction

	// 排序夹具只隔离 cfg 的纯数据生成，不注册为生产 cfg，也不接管真实环境 ring。
	// 固定两 PF 的 BAR 顺序与 global_qid 相反，保证发现“用 global_qid 当行号”的回归。
	class project_notify_sort_fixture extends project_env_cfg;
		// 构造独立临时 cfg，不 load_params、不创建组件、不发硬件访问。
		extern function new();
		// 生成有 RX/TX 重复的两 Function × 两 pair，检查排序、去重及 global_qid 保真。
		extern function bit check_sort(output string why);
	endclass

	// 夹具生命周期仅覆盖一次排序检查，持有自身的快照和只读 setup。
	function project_notify_sort_fixture::new();
		super.new("notify_sort_fixture");
	endfunction

	// 所有输入和期望值均固定；两 Function 使用同一管理 PF0 BAR 写表。
	function bit project_notify_sort_fixture::check_sort(output string why);
		dpu_device_snapshot		snapshot;
		dpu_dut_caps			caps;
		dpu_host_info_t			host;
		vio_queue_setup_t		queues[$];
		vio_external_setup		setup;

		snapshot = new("sort_snapshot");
		caps = new("sort_caps");
		host = '{host_id:0, enabled:1, address_width:64, default:0};
		if (!snapshot.set_dut_caps(caps, why) || !snapshot.add_host(host, why)) return 0;
		for (int unsigned f = 0; f < 2; f++) begin
			dpu_function_key_t		key;
			dpu_pcie_function_id_t		identity;
			dpu_bar_pair_lease_t		bar;
			project_vio_policy_t		policy;

			key = '{host_id:0, pf_id:f, kind:DPU_FUNCTION_PF, vf_id:0};
			identity = '{domain:'{host_id:0, segment_id:0}, bdf:16'(f)};
			bar = '{DPU_BAR_DEVICE_MEMORY, 0, (f == 0 ? 64'h800000 : 64'h400000), 64'h200000};
			if (!snapshot.add_function(key, identity, why) || !snapshot.add_bar(key, bar, why)) return 0;
			if (f == 0 && !snapshot.set_expected_af(key, why)) return 0;
			policy.service_key = '{function_key:key, service_kind:DPU_SERVICE_VIO_NET, service_instance_id:0};
			policy.notify_net_pair5 = 1;
			policy.notify_table_base_provided = 1;
			policy.notify_table_bar = 0;
			policy.notify_table_offset = 0;
			frozen_policies[dpu_service_key_name(policy.service_key)] = policy;
			for (int p = 1; p >= 0; p--) begin
				vio_queue_setup_t	queue;

				queue.service_key = policy.service_key;
				queue.qpair.virtio_pair_index = p;
				queue.qpair.global_qpair_id = f*2+p;
				queue.qpair.rx_local_virtqueue_id = p*2;
				queue.qpair.tx_local_virtqueue_id = p*2+1;
				queues.push_back(queue);
				queues.push_back(queue);
			end
		end
		if (!snapshot.freeze(why)) return 0;
		bar_registry = new("sort_registry");
		if (!bar_registry.initialize(snapshot, 1, why) || !bar_registry.bind_host(0, 0, why)) return 0;
		for (int unsigned f = 0; f < 2; f++) begin
			dpu_function_key_t	key;

			key = '{host_id:0, pf_id:f, kind:DPU_FUNCTION_PF, vf_id:0};
			if (!bar_registry.bind_function(key, f, -1, 16'(f), why)) return 0;
		end
		if (!bar_registry.freeze(why)) return 0;
		device_snapshot = snapshot;
		dpu_setup = new("sort_dpu_setup", snapshot, bar_registry, 1);
		use_driver_reference_layouts();
		frozen_layouts = table_layouts;
		frozen_reg_target = "h0.pf0.bar0";
		setup = new("sort_setup", null, snapshot, null, 1, queues);
		vio_setups[0] = setup;
		if (!materialize_notify_records(why)) return 0;
		if (notify_records.size() != 4) begin
			why = "Notify pair deduplication did not produce four rows";
			return 0;
		end
		foreach (notify_records[i]) begin
			project_vio_notify_entry_t	entry;
			int unsigned			expected_pf;
			int unsigned			expected_global;

			entry = project_vio_notify_entry_t'(notify_records[i].entry);
			expected_pf = i < 2 ? 1 : 0;
			expected_global = i < 2 ? i+2 : i-2;
			if (notify_records[i].ctx.table_index != i || notify_records[i].owner.pf_id != expected_pf ||
				entry.global_qid != expected_global || entry.local_qid_encoding != ((i%2)*2+1) ||
				entry.base_addr_60_7 != ((expected_pf == 0 ? 64'h800000 : 64'h400000) >> 7)) begin
				why = $sformatf("Notify row %0d does not follow BAR/pair order independent of global_qid", i);
				return 0;
			end
		end
		why = "";
		return 1;
	endfunction

	// 裸配置测试只复用父类的 Intel adapter 容器和断言工具，不调用父类平台配置。
	// 默认 Host0/PF0、Packed、1 对只启 VTX；所有地址布局和软件身份来自生产 cfg。
	// 模型独立按驱动固定端口解释写序，不能因生产布局同时写错而自洽通过。
	class project_bare_config_test extends project_external_integration_test;
		`uvm_component_utils(project_bare_config_test)

		project_dut_config_seq	bare_seq;
		project_bar_target_t	management;
		bit [63:0]		write_offsets[$];
		bit [31:0]		write_values[$];
		int unsigned		indirect_transactions[2];
		int unsigned		read_requests;
		bit			corrupt_readback;
		bit			missing_layout;
		bit			missing_message;
		bit			corrupt_bdf;
		bit			corrupted;
		bit			business_notify_enabled;
		pcie_tl_mem_tlp		business_notifications[$];

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
		// 真正接收 Intel Memory 请求并发送 Completion；负例只篡改一次 Notify 读值。
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
	// 参数扩展由 PROJECT_BARE_PAIRS / PROJECT_CUSTOM / PROJECT_BARE_RX 选择。
	function void project_bare_config_test::build_phase(uvm_phase phase);
		intel_pcie_vif_t		vif;
		intel_pcie_adapter_config	app_cfg;

		pairs = 1;
		void'($value$plusargs("PROJECT_BARE_PAIRS=%d", pairs));
		tx_only = !$test$plusargs("PROJECT_BARE_RX");
		host_count = 1;
		vf_count = 0;
		corrupt_bdf = $test$plusargs("PROJECT_BARE_CORRUPT_BDF");
		corrupt_readback = $test$plusargs("PROJECT_BARE_CORRUPT") || corrupt_bdf;
		missing_message = $test$plusargs("PROJECT_BARE_MSIX_MISSING_MESSAGE");
		msix_mode = $test$plusargs("PROJECT_BARE_MSIX") || missing_message;
		missing_layout = $test$plusargs("PROJECT_BARE_MISSING_LAYOUT");
		require_true(int'(corrupt_readback)+int'(missing_layout)+int'(missing_message) <= 1, "select one bare failure per run");
		// 故障必须经可选的真实读回路径观察；普通正例保留产品默认零读请求。
		if (corrupt_readback) aip_cmdline_override::set_val("dpu.verify_readback", "1");

		aip_cmdline_override::set_val("dpu.hosts", "1");
		aip_cmdline_override::set_val("dpu.pfs_per_host", "1");
		aip_cmdline_override::set_val("dpu.vfs_per_pf", "0");
		aip_cmdline_override::set_val("dpu.reg_target", "h0.pf0.bar0");
		aip_cmdline_override::set_val("dpu.print_bar_map", "1");
		aip_cmdline_override::set_val("vio.enabled", "1");
		aip_cmdline_override::set_val("vio.pairs", $sformatf("%0d", pairs));
		aip_cmdline_override::set_val("vio.tx_enable", "1");
		aip_cmdline_override::set_val("vio.rx_enable", tx_only ? "0" : "1");
		aip_cmdline_override::set_val("vio.queue_type", $test$plusargs("PROJECT_CUSTOM") ? "VQ_CUSTOM" : "VQ_PACKED");
		aip_cmdline_override::set_val("vio.queue_size", "256");
		// RX 的预取 RAM 是平台输入；32 槽小于 256 深度，并按 pair 自动推进起始位置。
		if (!tx_only) begin
			aip_cmdline_override::set_val("vio.vrx.dsc_pre_max_num", "3");
			aip_cmdline_override::set_val("vio.prefetch_ram", "ram_h0");
			aip_cmdline_override::set_val("vio.prefetch_start", "0");
			aip_cmdline_override::set_val("vio.prefetch_slots", "32");
		end
		aip_cmdline_override::set_val("vio.features", $test$plusargs("PROJECT_CUSTOM") ? "0" : "0x0000000500000000");
		aip_cmdline_override::set_val("vio.completion_mode", msix_mode ? "VIRTIO_COMPLETION_MSIX" : "VIRTIO_COMPLETION_POLLING");
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
		aip_cmdline_override::set_val("dpu.qsch.net_base", "0");
		aip_cmdline_override::set_val("dpu.qsch.net_stride", "1");
		aip_cmdline_override::set_val("dpu.qsch.group_id", "0");
		aip_cmdline_override::set_val("dpu.qsch.cos", "0");
		aip_cmdline_override::set_val("dpu.qsch.eth_ports", "8");
		aip_cmdline_override::set_val("dpu.qsch.ets", "0");

		cfg = project_env_cfg::type_id::create("cfg");
		cfg.vio_cfg.scb_enable = 0;
		cfg.load_params();
		if (missing_layout) cfg.table_layouts.delete(PROJECT_NOTIFY);
		require_true(!cfg.configure_public, "bare default unexpectedly enables public tables");
		require_true(cfg.function_policies.exists(dpu_function_key_name(
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
		bare_seq = project_dut_config_seq::type_id::create("bare_seq");
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
		if (business_notify_enabled && offset == 0) begin
			business_notifications.push_back(request);
			return;
		end
		write_offsets.push_back(offset);
		write_values.push_back(value);
		for (int unsigned i = 0; i < 4; i++)
			mmio_bytes[0][management.bar_lease.base+offset+i] = request.payload[i];

		// 仅允许必要 BDF 和按场景选择的 MSI-X；BAR/PFVF/其他公共表不得被总开关带入。
		require_true(offset == 'h108000 ||
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
			end
		end
	endtask

	// 以冻结的唯一表项计算发送笔数：Notify 仅实际 pair、QSCH mode、普通 DWORD 表，
	// VTX/VRX 各有初始化和使能两组六笔写。按接收完成数等待，不用任意固定延迟假设。
	task project_bare_config_test::await_configuration_writes();
		int unsigned	expected_writes;

		expected_writes = pairs*4 + (msix_mode ? 2048*2 : 0) + (cfg.qsch_configure_controls ? 1 : 0);
		foreach (cfg.records[name]) begin
			case (cfg.records[name].ctx.kind)
				PROJECT_NOTIFY, PROJECT_MSIX_LINEAR: ;
				PROJECT_VTX, PROJECT_VRX: expected_writes += 12;
				default: expected_writes += cfg.records[name].ctx.layout.entry_bytes/4;
			endcase
		end
		for (int unsigned attempt = 0; attempt < 10000 && write_offsets.size() < expected_writes; attempt++) #10ns;
		require_true(write_offsets.size() == expected_writes,
			$sformatf("configuration posted writes incomplete/extra: received=%0d expected=%0d",
				write_offsets.size(), expected_writes));
		require_true(indirect_transactions[0] == pairs*2 &&
			indirect_transactions[1] == (tx_only ? 0 : pairs*2),
			"posted drain did not receive all queue enable triggers");
	endtask

	// 逐项检查最终 enabled 内容；Notify 额外核对所属 Function BAR 与四笔连续写序。
	function void project_bare_config_test::check_configuration();
		int unsigned	counts[project_table_kind_e];
		int unsigned	notify_writes;
		int unsigned	bdf_writes;
		int unsigned	bdf_position;
		int unsigned	first_queue_trigger;
		bit [127:0]	expected;
		bit [127:0]	actual;

		require_true(indirect_transactions[0] == pairs*2, "VTX needs initial write and enabled rewrite per pair");
		require_true(indirect_transactions[1] == (tx_only ? 0 : pairs*2), "VRX enabled rewrite count");
		if (cfg.verify_readback)
			require_true(read_requests > 0, "enabled readback performed no real MemRead verification");
		else
			require_true(read_requests == 0, "default configuration unexpectedly issued MemRead");
		require_true(table_value('hb001c0, 4) == 0, "QSCH mode is not VNET");

		foreach (cfg.records[name]) begin
			project_config_record_t	r;

			r = cfg.records[name];
			counts[r.ctx.kind]++;
			require_true(r.ctx.kind inside {PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P,
				PROJECT_SPWRR, PROJECT_TC_WEIGHT, PROJECT_VTX, PROJECT_VRX, PROJECT_BDF,
				PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL, PROJECT_MSIX_TABLE}, "unexpected public record");
			expected = (r.entry & ~r.enable_mask) | r.enable_value;
			actual = table_value(r.ctx.byte_offset, r.ctx.layout.entry_bytes);
			require_true(actual === expected, $sformatf("final table value differs: %s", name));
			if (r.ctx.kind == PROJECT_BDF) begin
				require_true(r.ctx.byte_offset == 'h108000 && actual == 'h10000,
					"PF0 BDF mapping differs from valid requester=0");
			end
			if (r.ctx.kind == PROJECT_NOTIFY) begin
				project_vio_notify_entry_t	entry;

				entry = project_vio_notify_entry_t'(actual);
				require_true(entry.base_addr_60_7 == management.bar_lease.base[60:7], "Notify table does not use assigned PF0 BAR");
				require_true(entry.local_qid_encoding == (r.binding.qpair.virtio_pair_index << 1 | 1), "Notify local pair encoding");
				require_true(r.binding.notify_address == management.bar_lease.base, "runtime doorbell differs from assigned BAR");
			end
			if (r.ctx.kind == PROJECT_SPWRR) require_true(actual == 'hff, "SPWRR default differs");
			if (r.ctx.kind == PROJECT_TC_WEIGHT) require_true(actual == 'h11111111, "TC weight default differs");
			if (r.ctx.kind == PROJECT_VTX) begin
				project_vtx_entry_t	entry;

				entry = project_vtx_entry_t'(actual);
				require_true(entry.q_depth == 8, "VTX depth does not match 256 descriptors");
				require_true(entry.virtio_mode == ($test$plusargs("PROJECT_CUSTOM") ? 0 : 1), "VTX Packed/Custom mode differs");
			end
		end
		require_true(counts[PROJECT_NOTIFY] == pairs && counts[PROJECT_VTX] == pairs &&
			counts[PROJECT_Q2TC] == pairs, "queue-derived table count differs");
		require_true(counts[PROJECT_N2G] != 0 && counts[PROJECT_G2P] != 0 &&
			counts[PROJECT_SPWRR] != 0 && counts[PROJECT_TC_WEIGHT] != 0, "scheduler tables incomplete");

		require_true(counts[PROJECT_BDF] == 1, "default configuration must contain PF0 BDF exactly once");
		first_queue_trigger = '1;
		foreach (write_offsets[i]) begin
			if (write_offsets[i] == 'h108000) begin
				bdf_writes++;
				bdf_position = i;
			end
			if (write_offsets[i] == 'h880130 && (write_values[i] & 'h2000) != 0 && first_queue_trigger == '1)
				first_queue_trigger = i;
		end
		require_true(bdf_writes == 1 && bdf_position < first_queue_trigger,
			"BDF was missing/duplicated or written after queue programming");
		if (msix_mode) begin
			require_true(counts[PROJECT_MSIX_LINEAR] == cfg.frozen_messages.size() &&
				counts[PROJECT_MSIX_INFO] == cfg.frozen_messages.size() &&
				counts[PROJECT_MSIX_INTERVAL] == cfg.frozen_messages.size() &&
				counts[PROJECT_MSIX_TABLE] == cfg.frozen_messages.size(), "MSI-X table/vector count differs");
			check_msix_tables();
		end else begin
			require_true(counts[PROJECT_MSIX_LINEAR]+counts[PROJECT_MSIX_INFO]+counts[PROJECT_MSIX_INTERVAL]+
				counts[PROJECT_MSIX_TABLE] == 0, "polling unexpectedly generated MSI-X records");
		end
		notify_writes = 0;
		foreach (write_offsets[i]) begin
			if (write_offsets[i] < 'ha0000 || write_offsets[i] >= 'ha2000) continue;
			require_true(write_offsets[i] == 'ha0000 + 64'(notify_writes/4)*16 + (3-(notify_writes%4))*4,
				"Notify rows are not sequential or DWORD writes are not high to low");
			notify_writes++;
		end
		require_true(notify_writes == pairs*4, "Notify must contain exactly one written row per queue pair");
		if (cfg.verify_readback && !msix_mode) begin
			// 每个唯一表项读一次，加 QSCH mode 一次；不存在未用 Notify 行的额外读回。
			require_true(read_requests == cfg.records.num() + (cfg.qsch_configure_controls ? 1 : 0),
				"configuration read count includes missing/extra table reads");
		end
	endfunction

	// 消息地址是 Host 写目标；按局部 vector 生成地址/data，再与队列导出及三张全局表交叉核对。
	// Linear 表独立按 local-vector 顺序检查有效行，并检查全部 2048 行尾部和高到低写序。
	function void project_bare_config_test::check_msix_tables();
		vio_queue_setup_t	queues[$];
		project_msix_message_t	messages[$];
		int unsigned		linear_writes;

		messages = cfg.frozen_messages;
		messages.sort() with (item.local_vector);
		require_true(messages.size() != 0, "MSI-X mode published no messages");
		foreach (messages[i]) begin
			project_msix_linear_entry_t	linear;
			project_msix_info_entry_t	info;
			project_msix_table_entry_t	message;
			bit [63:0]			expected_address;
			bit [31:0]			expected_data;

			expected_address = 64'h900000000000 + messages[i].local_vector*4;
			expected_data = 32'h13572468 + messages[i].local_vector*32'h100;
			linear = project_msix_linear_entry_t'(table_value('hc0000+i*8, 8));
			info = project_msix_info_entry_t'(table_value('h150000+messages[i].global_vector*4, 4));
			message = project_msix_table_entry_t'(table_value('h120000+messages[i].global_vector*16, 16));
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
		selection.setups[0].list_queues(queues);
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
			project_msix_linear_entry_t	entry;

			entry = project_msix_linear_entry_t'(table_value('hc0000+row*8, 8));
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
		project_vio_notify_entry_t	lookup;

		selection.setups[0].list_queues(queues);
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
		lookup = project_vio_notify_entry_t'(table_value('ha0000, 16));
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
		require_true(cfg.bar_registry.resolve_name("h0.pf0.bar0", management, why), why);
		fork app_receive(0); join_none
		#100ns;
		catcher = new();
		catcher.expected_stage = missing_message ? "select_msix_scope" :
			(corrupt_bdf ? "verify_function_configuration" :
			(corrupt_readback ? "verify_vio_configuration" : "prepare_vio_configuration"));
		if (corrupt_readback || missing_layout || missing_message) uvm_report_cb::add(null, catcher);
		started = $time;
		bare_seq.start(cfg.rc_sequencers[cfg.tl_slot_by_host[0]]);
		if (corrupt_readback || missing_layout || missing_message) uvm_report_cb::delete(null, catcher);
		selection = bare_seq.selection;
		require_true(bare_seq.cfg == cfg, "bare sequence did not retrieve the same env_cfg");

		if (corrupt_readback || missing_layout || missing_message) begin
			require_true(catcher.count == 1 && !bare_seq.success && bare_seq.error_msg != "",
				"configuration failure did not report exactly one fatal");
			if (corrupt_readback) begin
				require_true(corrupted && read_requests > 0 && $time > started, "negative readback never reached Intel completion");
			end else if (missing_message) begin
				require_true(write_offsets.size() == 0, "missing MSI-X message allowed configuration writes");
			end else begin
				// BDF 可先完成，但缺 Notify 布局不得下发任何队列/通知/调度配置。
				foreach (write_offsets[i]) require_true(write_offsets[i] == 'h108000,
					"missing Notify layout allowed dependent configuration writes");
			end
			foreach (cfg.vio_envs[h]) foreach (cfg.vio_envs[h].function_instances[f]) begin
				require_true(cfg.vio_envs[h].function_instances[f].driver_agent.fsm.state != FSM_READY,
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
			foreach (cfg.vio_envs[h]) foreach (cfg.vio_envs[h].function_instances[f]) begin
				require_true(cfg.vio_envs[h].function_instances[f].driver_agent.fsm.state == FSM_READY,
					"verified bare configuration did not enter READY");
			end
			check_tx_notify();
			`uvm_info("PROJECT_BARE_CONFIG_PASS", $sformatf("pairs=%0d rx=%0b writes=%0d reads=%0d elapsed=%0t checks=%0d",
				pairs, !tx_only, write_offsets.size(), read_requests, $time-started, checks), UVM_LOW)
		end

		#100ns;
		if (selection.setups.num() != 0) begin
			cfg.release_vio_resources(selection, 1, ok, why);
			require_true(ok, why);
		end
		foreach (cfg.vio_envs[h]) cfg.vio_envs[h].host_mem.leak_check();
		phase.drop_objection(this);
	endtask

endpackage
