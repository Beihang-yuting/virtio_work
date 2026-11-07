// integration/project/tests：真实 Intel 引脚/monitor/bridge 的项目合同模型回归。
// 应用侧 adapter 仅模拟 DUT 的 BAR MMIO 与主动 DMA；Host 仍由项目 RC 唯一响应。
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

	// 用户仅实现每类别单项访问；外围循环、校验和锁完全使用 project_env 产品方法。
	class project_external_model_env extends project_env;
		`uvm_component_utils(project_external_model_env)
		int unsigned	vtx_calls;
		int unsigned	vrx_calls;
		int unsigned	notify_calls;
		int unsigned	bar_calls;
		int unsigned	fail_vtx_call;
		bit	fail_verify;
		project_vtx_cfg_t	last_vtx;
		project_vrx_cfg_t	last_vrx;
		// 构造模型 hook 容器，不修改生产 build/connect。
		extern function new(string name, uvm_component parent);
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
	function project_external_model_env::new(string name, uvm_component parent); super.new(name,parent); endfunction
	// 没有猜测 BAR payload，模型仅确认完整声明组收到真实租约。
	task project_external_model_env::user_configure_bar_mapping_entry(input project_bar_mapping_cfg_t item, output bit ok, output string why);
		bar_calls++;
		ok = item.members.size() != 0;
		why = ok ? "" : "empty BAR group";
	endtask
	// 模型平台明确报告所选公共配置完成；产品仍检查上下文和依赖。
	task project_external_model_env::user_verify_dpu_configuration(input project_dpu_config_scope scope, output bit ok, output string why);
		ok = 1; why = "";
	endtask
	// 模型平台明确报告队列配置完成；后续核心 preflight 不能被此成功绕过。
	task project_external_model_env::user_verify_vio_configuration(input project_vio_selection_t selection, output bit ok, output string why);
		ok = !fail_verify; why = ok ? "" : "injected platform verification failure";
	endtask
	// 使能使用唯一 checked 路径，只允许 enable 位变化。
	task project_external_model_env::user_enable_queue(input project_queue_control_cfg_t item, output bit ok, output string why);
		write_enabled_queue(item, ok, why);
	endtask

	// 单项 bdf 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_bdf_entry(input project_bdf_cfg_t item, output bit ok, output string why);
		write_bdf(item, ok, why);
	endtask

	// 单项 pfvf 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_pf_vf_entry(input project_pfvf_cfg_t item, output bit ok, output string why);
		write_pfvf(item, ok, why);
	endtask

	// 单项 msix_linear 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_msix_linear_entry(input project_msix_linear_cfg_t item, output bit ok, output string why);
		write_msix_linear(item, ok, why);
	endtask

	// 单项 msix_info 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_msix_info_entry(input project_msix_info_cfg_t item, output bit ok, output string why);
		write_msix_info(item, ok, why);
	endtask

	// 单项 msix_interval 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_msix_interval_entry(input project_msix_interval_cfg_t item, output bit ok, output string why);
		write_msix_interval(item, ok, why);
	endtask

	// 单项 msix_table 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_msix_table_entry(input project_msix_table_cfg_t item, output bit ok, output string why);
		write_msix_table(item, ok, why);
	endtask

	// 单项 qsch_q2tc 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_qsch_q2tc(input project_qsch_q2tc_cfg_t item, output bit ok, output string why);
		write_qsch_q2tc(item, ok, why);
	endtask

	// 单项 qsch_n2g 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_qsch_n2g(input project_qsch_n2g_cfg_t item, output bit ok, output string why);
		write_qsch_n2g(item, ok, why);
	endtask

	// 单项 qsch_g2p 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_qsch_g2p(input project_qsch_g2p_cfg_t item, output bit ok, output string why);
		write_qsch_g2p(item, ok, why);
	endtask

	// 单项 vtx 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_vtx_queue(input project_vtx_cfg_t item, output bit ok, output string why);
		vtx_calls++;
		last_vtx = item;
		if (fail_vtx_call != 0 && vtx_calls == fail_vtx_call) begin ok = 0; why = "injected midway VTX hook failure"; return; end
		write_vtx(item, ok, why);
	endtask

	// 单项 vrx 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_vrx_queue(input project_vrx_cfg_t item, output bit ok, output string why);
		vrx_calls++;
		last_vrx = item;
		write_vrx(item, ok, why);
	endtask

	// 单项 vio_notify 返回真实 helper 结果；不在 hook 中增加外围循环。
	task project_external_model_env::user_configure_vio_notify_entry(input project_vio_notify_cfg_t item, output bit ok, output string why);
		notify_calls++;
		write_vio_notify(item, ok, why);
	endtask

	// 仅此测试模型的明确路由规则，不作为产品硬件默认；实际平台替换此一个纯函数。
	class project_external_model_cfg extends project_env_cfg;
		`uvm_object_utils(project_external_model_cfg)
		// 构造配置，保留生产参数生成器。
		extern function new(string name="project_external_model_cfg");
		// fixture 的 PF0 从 offset1 开始，Pfvf=vf_id+1；完整成员逐项检查，不要求VF连续。
		extern virtual function bit validate_pfvf_relationship(input project_pfvf_relationship_t family, output string why);
	endclass

	// fixture 配置仍使用产品解析和资源生成器。
	function project_external_model_cfg::new(string name="project_external_model_cfg");
		super.new(name);
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
		project_external_model_env	env;
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
		extern task app_receive(input int unsigned host);
		// 经真实应用侧引脚发 Memory，保持 wire requester 身份。
		extern task send_memory(input int unsigned host, input bit writing, input bit [15:0] requester,
			input bit [63:0] address, input bit [31:0] data, input bit [9:0] tag = 10'h155);
		// 非 identity 双向 DMA、权限/未知 requester、真实 MSI-X sink 与 Completion sideband。
		extern task check_receive_path();
		// 实际取消在发包间隔中的 AIP sequence；stop 不清取消，只有新代确认后才能复用。
		extern task check_cancel_recovery();
		extern task check_revoke();
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
		super.build_phase(phase);

		no_vio = $test$plusargs("PROJECT_NO_VIO");
		tx_only = $test$plusargs("PROJECT_TX_ONLY");
		msix_mode = $test$plusargs("PROJECT_MSIX");
		host_count = $test$plusargs("PROJECT_TWO_HOSTS") ? 2 : 1;
		vf_count = $test$plusargs("PROJECT_TWO_VFS") ? 2 : 1;
		pairs = vf_count == 2 ? 16 : 32;
		if ($test$plusargs("PROJECT_SMALL")) pairs = 2;
		if ($test$plusargs("PROJECT_ONE_PAIR")) pairs = 1;
		cfg = project_external_model_cfg::type_id::create("cfg");
		cfg.hosts = host_count;
		cfg.vfs_per_pf = vf_count;
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
		cfg.load_params();
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
			p.vport = key.kind == DPU_FUNCTION_VF ? key.vf_id + 1 : 0;
			p.pfvf = p.vport;
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
		add_layout(PROJECT_MSIX_INFO,4,1024,'h100000,'h50000);
		add_layout(PROJECT_MSIX_INTERVAL,4,1024,'h100000,'h40000);
		add_layout(PROJECT_MSIX_TABLE,16,1024,'h100000,'h20000);
		add_layout(PROJECT_NOTIFY,16,512,'h200000,'h20000);
		add_layout(PROJECT_VTX,16,2048,'h400000,'h10000,1);
		add_layout(PROJECT_VRX,16,2048,'h500000,'h10000,1);
		add_layout(PROJECT_Q2TC,4,1024,'h600000,'h10000);
		add_layout(PROJECT_N2G,4,2048,'h600000,'h12000);
		add_layout(PROJECT_G2P,4,1024,'h600000,'h14000);
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
		env = project_external_model_env::type_id::create("env",this);
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
		env.dpu_setup.list_functions(functions);
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

	// 完整模型流程：独立类别、失败保留、跨 Host 原子预检、旧代拒绝及真正 Intel 收发。
	task project_external_integration_test::run_phase(uvm_phase phase);
		project_dpu_config_scope	public_scope;
		dpu_function_key_t	keys[$];
		int unsigned	bars[$];
		bit	ok;
		string	why;
		int unsigned	posted_before;
		project_vtx_cfg_t	changed;
		logic [127:0]	readback;
		phase.raise_objection(this);
		foreach (apps[h]) begin
			automatic int unsigned	host = h;
			fork app_receive(host); join_none
		end
		#100ns;
		begin
			project_function_record_t functions[$];
			project_dpu_config_scope probe;
			project_dpu_setup foreign;
			dpu_function_key_t chosen[$];
			env.dpu_setup.list_functions(functions);
			chosen.push_back(functions[0].key);
			chosen[0].host_id = 32'hffff;
			probe = new("unknown_public", env.dpu_setup, chosen, bars);
			env.configure_bdf_table(probe, ok, why);
			require_true(!ok, "unknown Function scope accepted");
			chosen.delete();
			foreign = new("foreign_public", env.dpu_env.get_snapshot(), env.bar_registry, env.dpu_setup.get_generation());
			probe = new("foreign_scope", foreign, chosen, bars);
			require_true(!probe.validate(env.dpu_setup, why), "foreign public setup accepted");
			if (functions.size() > 2) begin
				chosen.push_back(functions[0].key);
				chosen.push_back(functions[functions.size()-1].key);
				probe = new("noncontiguous_public", env.dpu_setup, chosen, bars);
				require_true(probe.validate(env.dpu_setup, why) && !probe.selects(functions[1].key), "noncontiguous public selection expanded");
				env.configure_bdf_table(probe, ok, why);
				require_true(ok, why);
			end
		end
		public_scope = new("all_public",env.dpu_setup,keys,bars);
		env.configure_bar_table(public_scope,ok,why); require_true(ok,why);
		env.configure_bdf_table(public_scope,ok,why); require_true(ok,why);
		env.configure_pf_vf_map(public_scope,ok,why); require_true(ok,why);
		env.configure_msix(public_scope,ok,why); require_true(ok,why);
		env.verify_dpu_configuration(public_scope,ok,why); require_true(ok,why);
		env.pcie_bar_write_by_name("h0.pf0.bar0",'h40,16,128'hffeeddccbbaa99887766554433221100,32'h0a0a,ok,why);
		require_true(ok,why);
		env.pcie_bar_read_by_name("h0.pf0.bar0",'h40,16,32'h0a0a,readback,ok,why);
		require_true(ok && readback==128'hffeeddcc00aa00887766554400220000,"MMIO little endian sparse skip/read path");
		env.prepare_vio_configuration(selection,ok,why); require_true(ok,why);
		if (!no_vio) begin
			require_true(selection.setups.num()==host_count,"missing prepared Host");
			env.configure_vio_notify(selection,ok,why); require_true(ok,why);
			env.configure_qsch(selection,ok,why); require_true(ok,why);
			env.fail_vtx_call = (pairs*vf_count*host_count > 1) ? 2 : 1;
			env.configure_vio_queues(selection,ok,why); require_true(!ok,"midway hook failure not propagated");
			env.enable_vio_queues(selection,ok,why); require_true(!ok,"enable allowed after partial hook failure");
			env.commit_vio_configuration(selection,ok,why); require_true(!ok,"commit allowed after partial hook failure");
			env.fail_vtx_call = 0;
			env.vtx_calls = 0;
			env.vrx_calls = 0;
			env.configure_vio_queues(selection,ok,why); require_true(ok,why);
			require_true(env.vtx_calls==pairs*vf_count*host_count,"VTX hook count differs from actual queue count");
			require_true(env.vrx_calls==(tx_only?0:pairs*vf_count*host_count),"VRX hook direction/count");
			require_true(env.notify_calls==pairs*vf_count*host_count,"notify pair dedup count");
			changed = env.last_vtx;
			changed.entry.desc_addr ^= 64'h1000;
			posted_before = posted[0].size();
			env.write_vtx(changed,ok,why); require_true(!ok,"checked VTX accepted mutated ring IOVA");
			for (int mutation = 0; mutation < 7; mutation++) begin
				changed = env.last_vtx;
				case (mutation)
					0: changed.binding.qpair.global_qpair_id++;
					1: changed.entry.dma_msix++;
					2: changed.entry.q_depth++;
					3: changed.entry.virtio_mode ^= 1;
					4: changed.ctx.byte_offset += 4;
					5: changed.ctx.layout.module_offset = 'x;
					6: changed.entry.desc_addr = 'x;
				endcase
				env.write_vtx(changed, ok, why);
				require_true(!ok, "typed queue mutation accepted");
			end
			#20ns;
			require_true(posted[0].size()==posted_before,"invalid typed entry emitted TLP");
			env.enable_vio_queues(selection,ok,why); require_true(ok,why);
			env.verify_vio_configuration(selection,ok,why); require_true(ok,why);
			if (host_count==2) begin
				virtqueue_base	queue;
				bit [63:0]	saved;
				fsm_state_e	state;
				vio_queue_setup_t	rows[$];
				selection.setups[1].list_queues(rows);
				queue = env.vio_envs[1].function_instances[0].vq_mgr.get_queue(rows[0].notification.local_qid);
				saved = queue.desc_table_addr;
				state = env.vio_envs[0].function_instances[0].driver_agent.fsm.state;
				queue.desc_table_addr += 16;
				env.commit_vio_configuration(selection,ok,why);
				require_true(!ok && env.vio_envs[0].function_instances[0].driver_agent.fsm.state==state,"later Host mismatch partially confirmed earlier Host");
				queue.desc_table_addr = saved;
			end
			env.commit_vio_configuration(selection,ok,why); require_true(ok,why);
		end else require_true(selection.setups.num()==0,"no-VIO scenario prepared rings");
		check_receive_path();
		if ($test$plusargs("PROJECT_CANCEL")) begin
			fork : bounded_cancel_fixture
				check_cancel_recovery();
				begin
					#20us;
					`uvm_fatal("PROJECT_CANCEL_TIMEOUT", {"cancel fixture stalled at ", cancel_stage})
				end
			join_any
			disable bounded_cancel_fixture;
		end
		if ($test$plusargs("PROJECT_REVOKE")) check_revoke();
		if (!no_vio) begin
			if (host_count==2) begin
				virtqueue_base	queue;
				bit [63:0]	saved;
				vio_queue_setup_t	rows[$];
				selection.setups[1].list_queues(rows);
				queue = env.vio_envs[1].function_instances[0].vq_mgr.get_queue(rows[0].notification.local_qid);
				saved = queue.desc_table_addr;
				queue.desc_table_addr += 16;
				env.release_vio_resources(selection,1,ok,why);
				require_true(!ok && env.vio_envs[0].function_instances[0].driver_agent.fsm.state==FSM_READY &&
					env.vio_envs[0].function_instances[0].vq_mgr.get_queue_count()!=0,"later Host mismatch partially released earlier Host");
				queue.desc_table_addr = saved;
			end
			env.release_vio_resources(selection,0,ok,why); require_true(!ok,"release accepted no platform quiescence");
			env.release_vio_resources(selection,1,ok,why); require_true(ok,why);
			env.commit_vio_configuration(selection,ok,why); require_true(!ok,"stale generation recommitted");
		end
		foreach (env.vio_envs[h]) env.vio_envs[h].host_mem.leak_check();
		`uvm_info("PROJECT_EXTERNAL_FLOW",$sformatf("PROJECT_EXTERNAL_FLOW_PASS checks=%0d hosts=%0d vfs=%0d pairs=%0d",checks,host_count,vf_count,pairs),UVM_LOW)
		phase.drop_objection(this);
	endtask
	// 已确认停止状态和损坏几何均能撤销；外来 scope 不能影响有效资源。
	task project_external_integration_test::check_revoke();
		project_vio_selection_t subset;
		vio_queue_setup_t rows[$];
		dpu_service_key_t keys[$];
		virtio_function_instance instance;
		virtqueue_base queue;
		bit [63:0] saved;
		string why;
		bit ok;
		require_true(!no_vio, "revoke fixture requires VIO");
		selection.setups[0].list_queues(rows);
		keys.push_back(rows[0].service_key);
		subset.setups[0] = selection.setups[0];
		subset.scopes[0] = new("revoke_subset", subset.setups[0], keys);
		instance = env.vio_envs[0].function_instances[0];
		queue = instance.vq_mgr.get_queue(rows[0].notification.local_qid);
		ok = env.vio_envs[0].revoke_external_configuration(null, subset.scopes[0], why);
		require_true(!ok && instance.driver_agent.ops.external_queue_ready(queue.queue_id), "foreign revoke mutated READY");
		for (int invalid_case = 0; invalid_case < 3; invalid_case++) begin
			project_vio_selection_t invalid_selection;
			invalid_selection = subset;
			case (invalid_case)
				0: begin invalid_selection.scopes.delete(0); invalid_selection.scopes[99] = subset.scopes[0]; end
				1: invalid_selection.scopes[0] = null;
				2: begin
					invalid_selection.setups.delete(0); invalid_selection.scopes.delete(0);
					invalid_selection.setups[99] = subset.setups[0]; invalid_selection.scopes[99] = subset.scopes[0];
				end
			endcase
			env.verify_vio_configuration(invalid_selection, ok, why);
			require_true(!ok && instance.driver_agent.ops.external_queue_ready(queue.queue_id) &&
				env.vio_envs.num() == host_count, "invalid Host/scope changed live state or map");
		end
		env.fail_verify = 1;
		env.verify_vio_configuration(subset, ok, why);
		require_true(!ok && !instance.driver_agent.ops.external_queue_ready(queue.queue_id) &&
			instance.driver_agent.fsm.state == FSM_REINIT_REQUIRED && instance.vq_mgr.get_queue_count() != 0,
			"failed verify did not close business gate while retaining rings");
		if (host_count > 1) require_true(env.vio_envs[1].function_instances[0].driver_agent.fsm.state == FSM_READY,
			"scoped revoke invalidated another Host");
		env.fail_verify = 0;
		env.verify_vio_configuration(selection, ok, why); require_true(ok, why);
		env.commit_vio_configuration(selection, ok, why); require_true(ok, why);
		saved = queue.desc_table_addr;
		queue.desc_table_addr += 16;
		env.verify_vio_configuration(subset, ok, why);
		require_true(!ok && !instance.driver_agent.ops.external_queue_ready(queue.queue_id) &&
			instance.vq_mgr.get_queue_count() != 0, "corrupt geometry prevented safe revoke");
		queue.desc_table_addr = saved;
		env.verify_vio_configuration(selection, ok, why); require_true(ok, why);
		env.commit_vio_configuration(selection, ok, why); require_true(ok, why);
		`uvm_info("PROJECT_EXTERNAL_FLOW", "PROJECT_REVOKE_PASS", UVM_LOW)
	endtask

	// 使用真正 AIP sequence kill 路径，driver 已接受的第一个 TX 留待平台 quiescence 后释放。
	task project_external_integration_test::check_cancel_recovery();
		virtio_function_instance	instance;
		virtio_aip_sequence	start_seq;
		virtio_aip_sequence	tx_seq;
		virtio_aip_sequence	stop_seq;
		project_vio_selection_t	old_selection;
		string	name;
		string	why;
		bit	ok;
		require_true(!no_vio && host_count==1 && tx_only,"cancel fixture requires single Host TX-only");
		instance = env.vio_envs[0].function_instances[0];
		env.register_aip_commands();
		require_true(aip_cmd::get_handle("vio_init")==null && aip_cmd::get_handle("vio_reset")==null &&
			aip_cmd::get_handle("vio_start")!=null,"project registered removed legacy commands");
		name = virtio_aip_registry::target_name(instance.service_key);
		start_seq = new("start_before_cancel");
		start_seq.target = instance;
		start_seq.target_path = name;
		start_seq.operation = VIO_TXN_START_DP;
		require_true(instance.driver_agent.ops.wait_pol.default_poll_interval_ns != 0, "cancel fixture has zero worker poll interval");
		`uvm_info("PROJECT_CANCEL", $sformatf("effective worker poll_ns=%0d", instance.driver_agent.ops.wait_pol.default_poll_interval_ns), UVM_LOW)
		cancel_stage = "start dataplane";
		start_seq.start(instance.driver_agent.sequencer);
		require_true(start_seq.ok,start_seq.result_text);
		tx_seq = new("cancel_stream");
		tx_seq.target = instance;
		tx_seq.target_path = name;
		tx_seq.operation = VIO_TXN_SEND_PKTS;
		tx_seq.count = 2;
		tx_seq.pair = 0;
		tx_seq.len_min = 512;
		tx_seq.len_max = 512;
		tx_seq.gap_ns = 5000;
		cancel_stage = "kill TX sequence";
		fork
			tx_seq.start(instance.driver_agent.sequencer);
			begin
				#500ns;
				`uvm_info("PROJECT_CANCEL", "issuing sequence kill", UVM_LOW)
				tx_seq.kill();
				`uvm_info("PROJECT_CANCEL", "sequence kill returned", UVM_LOW)
			end
		join
		require_true(virtio_aip_registry::needs_reset[name],"AIP kill did not retain cancellation gate");
		stop_seq = new("stop_after_cancel");
		stop_seq.target = instance;
		stop_seq.target_path = name;
		stop_seq.operation = VIO_TXN_STOP_DP;
		cancel_stage = "stop dataplane";
		stop_seq.start(instance.driver_agent.sequencer);
		require_true(stop_seq.ok,stop_seq.result_text);
		require_true(!virtio_aip_registry::external_reuse_ready(name),"mere stop cleared cancellation");
		env.commit_vio_configuration(selection,ok,why); require_true(ok,why);
		require_true(!virtio_aip_registry::external_reuse_ready(name),"same generation confirmation cleared cancellation");
		old_selection = selection;
		cancel_stage = "release old generation";
		env.release_vio_resources(selection,1,ok,why); require_true(ok,why);
		cancel_stage = "prepare new generation";
		env.prepare_vio_configuration(selection,ok,why); require_true(ok,why);
		require_true(selection.setups[0].get_generation()>old_selection.setups[0].get_generation(),"new preparation did not advance generation");
		cancel_stage = "configure new generation";
		env.configure_vio_notify(selection,ok,why); require_true(ok,why);
		env.configure_qsch(selection,ok,why); require_true(ok,why);
		env.configure_vio_queues(selection,ok,why); require_true(ok,why);
		env.enable_vio_queues(selection,ok,why); require_true(ok,why);
		env.verify_vio_configuration(selection,ok,why); require_true(ok,why);
		require_true(!virtio_aip_registry::external_reuse_ready(name),"unconfirmed new generation cleared cancellation");
		env.commit_vio_configuration(selection,ok,why); require_true(ok,why);
		require_true(virtio_aip_registry::external_reuse_ready(name),"verified new generation did not clear cancellation");
		cancel_stage = "start dataplane";
		start_seq.start(instance.driver_agent.sequencer);
		require_true(start_seq.ok,start_seq.result_text);
		cancel_stage = "stop dataplane";
		stop_seq.start(instance.driver_agent.sequencer);
		require_true(stop_seq.ok,stop_seq.result_text);
		`uvm_info("PROJECT_EXTERNAL_FLOW","PROJECT_AIP_CANCEL_RECOVERY_PASS",UVM_LOW)
	endtask

endpackage
