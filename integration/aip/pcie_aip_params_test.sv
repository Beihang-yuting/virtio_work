// integration/aip：PCIe原配置类参数和实际TL消费者的可选AIP契约测试。
// 依赖aip_core_pkg、pcie_tl_pkg、pcie_topology_pkg及系统示例类，测试在build前
// 写入AIP override并调用原load_params；真实pcie_tl_env创建manager/driver但不发送TLP。
// 测试持有配置与外部graph，UVM拥有组件；不新建平台global_cfg或Root映射的生产路径。
// +PCIE_PARAM_NEGATIVE=<mode>用于独立fatal负例，不能纳入正常零错误日志汇总。
`ifndef PCIE_AIP_PARAMS_TEST_SV
`define PCIE_AIP_PARAMS_TEST_SV
import uvm_pkg::*;
import aip_core_pkg::*;
import pcie_tl_pkg::*;
import pcie_topology_pkg::*;
`include "uvm_macros.svh"

// 原类加载与实际manager/driver联动验证，防止仅改配置对象却未接入真实消费点。
class pcie_aip_params_test extends uvm_test;
	`uvm_component_utils(pcie_aip_params_test)
	pcie_tl_env_config	cfg;
	pcie_tl_env		env;
	bit			prior_present[string];
	string			prior_values[string];
	int unsigned		checks;

	// 构造不读取参数；所有参数采样都在子组件build之前显式完成。
	function new(string	name = "pcie_aip_params_test", uvm_component	parent = null);
		super.new(name, parent);
		checks = 0;
	endfunction

	// 写入override前保存旧值，仅回收本测试使用的键，不清空其他用例的参数表。
	function void put(string	key, string	value);
		if (!prior_present.exists(key)) begin
			prior_present[key] = aip_cmdline_override::has(key);
			if (prior_present[key]) prior_values[key] = aip_cmdline_override::get_val(key);
		end
		aip_cmdline_override::set_val(key, value);
	endfunction

	// 正例结束恢复本测试的覆盖；不重载已建立的manager或driver。
	function void restore_overrides();
		foreach (prior_present[key]) begin
			if (prior_present[key]) aip_cmdline_override::set_val(key, prior_values[key]);
			else aip_cmdline_override::clear(key);
		end
		prior_present.delete();
		prior_values.delete();
	endfunction

	// 使用四态比较，不把未知值或空句柄造成的未检查状态当作通过。
	function void check_param(logic	condition, string	detail);
		checks++;
		if (condition !== 1'b1) `uvm_error("PCIE_AIP_TEST", detail)
	endfunction

	// 没有对应键时保留当前配置，包含未开放的结构、内存字段和外部Root映射。
	function void check_defaults();
		pcie_tl_env_config	original;

		original = new("defaults");
		original.cpl_timeout_ns = 12345;
		original.init_ph_credit = 19;
		original.max_outstanding = 17;
		original.response_delay_min = 3;
		original.response_delay_max = 7;
		original.no_snoop_enable = 1;
		original.num_rc = 3;
		original.num_ep = 4;
		original.mem_granule = 32;
		original.premap_base = 64'h1234_0000_0000;
		original.host_id_by_root[2] = 9;
		original.ep_root_by_index[3] = 2;
		original.load_params("pcie_params.absent");
		check_param(original.cpl_timeout_ns == 12345 && original.init_ph_credit == 19 &&
			original.max_outstanding == 17, "missing parameters must preserve caller policy defaults");
		check_param(original.num_rc == 3 && original.num_ep == 4 && original.mem_granule == 32 &&
			original.premap_base == 64'h1234_0000_0000 && original.host_id_by_root[2] == 9 &&
			original.ep_root_by_index[3] == 2, "load_params must preserve topology/memory/Root mapping");
		check_param(original.response_delay_min == 3 && original.response_delay_max == 7 &&
			original.no_snoop_enable == 1, "unconsumed response/no_snoop fields must remain unchanged");
	endfunction

	// 独立负例必须在原类解析点fatal；末尾MISSED不是成功证据，验证器必须排除它。
	function void run_negative(string	mode);
		pcie_tl_env_config	bad;

		bad = new("bad");
		case (mode)
			"unsigned_wrap": put("pcie_params.bad.cpl_timeout_ns", "-18446744073709551615");
			"enum": put("pcie_params.bad.max_payload_size", "MPS_NOT_A_VALUE");
			"bool": put("pcie_params.bad.scb_enable", "2");
			"outstanding": begin
				put("pcie_params.bad.extended_tag_enable", "0");
				put("pcie_params.bad.max_outstanding", "257");
			end
			"geometry": begin
				put("pcie_params.bad.rc2ep_latency_min_ns", "9");
				put("pcie_params.bad.rc2ep_latency_max_ns", "2");
			end
			"shaper_rate": begin
				put("pcie_params.bad.shaper_enable", "1");
				put("pcie_params.bad.avg_rate", "0");
			end
			default: `uvm_fatal("PCIE_PARAM_NEGATIVE_UNKNOWN", mode)
		endcase
		bad.load_params("pcie_params.bad");
		`uvm_fatal("PCIE_PARAM_NEGATIVE_MISSED", {"illegal value was accepted: ", mode})
	endfunction

	// 自定义路径覆盖后才创建原pcie_tl_env；不通过copy/mock旁路它的实际apply_config。
	virtual function void build_phase(uvm_phase	phase);
		string	negative_mode;

		super.build_phase(phase);
		if ($value$plusargs("PCIE_PARAM_NEGATIVE=%s", negative_mode)) run_negative(negative_mode);
		check_defaults();
		put("pcie_params.native.fc_enable", "1");
		put("pcie_params.native.init_ph_credit", "23");
		put("pcie_params.native.extended_tag_enable", "0");
		put("pcie_params.native.max_outstanding", "32");
		put("pcie_params.native.cpl_timeout_ns", "77777");
		put("pcie_params.native.max_payload_size", "MPS_128");
		put("pcie_params.native.max_read_request_size", "MRRS_256");
		put("pcie_params.native.read_completion_boundary", "RCB_128");
		put("pcie_params.native.shaper_enable", "1");
		put("pcie_params.native.avg_rate", "2.5");
		put("pcie_params.native.burst_size", "512");
		put("pcie_params.native.ordering_check_enable", "0");
		put("pcie_params.native.relaxed_ordering_enable", "0");
		put("pcie_params.native.ep_auto_response", "0");
		put("pcie_params.native.link_delay_enable", "1");
		put("pcie_params.native.rc2ep_latency_min_ns", "3");
		put("pcie_params.native.rc2ep_latency_max_ns", "5");
		put("pcie_params.native.link_delay_update_interval", "7");
		cfg = new("cfg");
		cfg.load_params("pcie_params.native");
		check_param(cfg.max_payload_size == MPS_128 && cfg.max_read_request_size == MRRS_256 &&
			cfg.read_completion_boundary == RCB_128, "typed capability enums must load by original field names");
		uvm_config_db#(pcie_tl_env_config)::set(this, "env", "cfg", cfg);
		env = pcie_tl_env::type_id::create("env", this);
	endfunction

	// 检查真实manager/driver拿到配置；运行期修改override不应自动改已采样对象。
	// TAG_BIT原有build阶段覆写保持更高优先级，并验证其最终值到达tag manager。
	virtual task run_phase(uvm_phase	phase);
		int	tag_bit;
		int	expected_outstanding;
		bit	expected_extended;

		phase.raise_objection(this);
		expected_outstanding = 32;
		expected_extended = 0;
		if ($value$plusargs("TAG_BIT=%d", tag_bit)) begin
			expected_outstanding = tag_bit == 10 ? 1024 : 256;
			expected_extended = tag_bit == 10;
		end
		check_param(env.cfg == cfg, "native env must retain the loaded config handle");
		check_param(env.tag_mgr.max_outstanding == expected_outstanding &&
			env.tag_mgr.extended_tag_enable == expected_extended, "tag manager must consume loaded policy/TAG_BIT precedence");
		check_param(env.fc_mgr.posted_header.limit == 23 && env.fc_mgr.fc_enable,
			"flow-control manager must consume initial credits");
		check_param(env.bw_shaper.shaper_enable && env.bw_shaper.avg_rate == 2.5 &&
			env.bw_shaper.burst_size == 512, "bandwidth shaper must consume real/integer policy");
		check_param(env.rc_agent.rc_driver.cpl_timeout_ns == 77777 &&
			env.rc_agent.rc_driver.mps_bytes == 128 && env.rc_agent.rc_driver.rcb_bytes == 128,
			"real RC driver must consume timeout/MPS/RCB");
		check_param(env.cfg_mgr.get_mrrs_bytes() == 256,
			"config-space manager must consume the MRRS capability encoding");
		check_param(!env.ord_eng.relaxed_ordering_enable && !env.scbs[0].ordering_check_enable,
			"ordering engine and scoreboard must consume their distinct switches");
		check_param(env.rc2ep_delay.enable && env.rc2ep_delay.latency_min_ns == 3 &&
			env.rc2ep_delay.latency_max_ns == 5 && env.rc2ep_delay.update_interval == 7,
			"link delay model must consume validated geometry");
		put("pcie_params.native.cpl_timeout_ns", "88888");
		check_param(cfg.cpl_timeout_ns == 77777 && env.rc_agent.rc_driver.cpl_timeout_ns == 77777,
			"set_param after build must not silently reconfigure the PCIe driver");
		restore_overrides();
		`uvm_info("PCIE_AIP_TEST", $sformatf("PASS %0d PCIe parameter/consumer checks", checks), UVM_LOW)
		phase.drop_objection(this);
	endtask
endclass

// 系统wrapper透传测试：平台显式提供graph，wrapper只加载行为并传同一policy对象。
// PCIe和DPU均建立真实层次，但本测试不连接二者端点、不发送TLP或声称DUT集成完成。
class pcie_aip_system_policy_test extends virtio_system_env_example_test;
	`uvm_component_utils(pcie_aip_system_policy_test)
	pcie_topology_cfg	external_graph;
	pcie_global_cfg		external_global;
	pcie_tl_env_config	original_policy;
	bit			old_timeout_present;
	string			old_timeout;

	// 构造保留示例的DPU authoring方法，PCIe输入由本测试显式创建。
	function new(string	name = "pcie_aip_system_policy_test", uvm_component	parent = null);
		super.new(name, parent);
	endfunction

	// 父build只create子env尚未遍历其build，因此在返回前注入可选PCIe配置与graph。
	// +PCIE_GRAPH_GLOBAL分别覆盖global_cfg.topology入口及直接topology_cfg入口。
	virtual function void build_phase(uvm_phase	phase);
		pcie_topology_builder	builder;

		super.build_phase(phase);
		system_cfg.create_pcie_env = 1;
		original_policy = new("caller_pcie_policy");
		original_policy.num_rc = 5;
		original_policy.num_ep = 6;
		original_policy.max_outstanding = 24;
		system_cfg.pcie_cfg = original_policy;
		old_timeout_present = aip_cmdline_override::has("pcie_cfg.cpl_timeout_ns");
		if (old_timeout_present) old_timeout = aip_cmdline_override::get_val("pcie_cfg.cpl_timeout_ns");
		aip_cmdline_override::set_val("pcie_cfg.cpl_timeout_ns", "88888");
		builder = new("external_builder");
		void'(builder.add_rc("CALLER_RC"));
		void'(builder.add_ep("CALLER_EP"));
		void'(builder.connect("CALLER_LINK", "CALLER_RC", PCIE_TOPO_PORT_RC, 0,
			"CALLER_EP", PCIE_TOPO_PORT_EP, 0, 8, 4));
		external_graph = builder.finish();
		if ($test$plusargs("PCIE_GRAPH_GLOBAL")) begin
			external_global = new("caller_global");
			external_global.topology = external_graph;
			uvm_config_db#(pcie_global_cfg)::set(this, "system_env.pcie_env", "global_cfg", external_global);
		end else
			uvm_config_db#(pcie_topology_cfg)::set(this, "system_env.pcie_env", "topology_cfg", external_graph);
	endfunction

	// 真实graph翻译应只替换结构字段，策略身份/timeout保持且到达真实driver。
	// 同时执行原DPU示例的资源检查，确保可选PCIe接入未破坏已有Host构建路径。
	virtual task run_phase(uvm_phase	phase);
		pcie_tl_env	pcie;
		pcie_tl_env_config	policy_slot;

		phase.raise_objection(this);
		pcie = system_env.get_pcie_env();
		if (pcie == null) `uvm_fatal("PCIE_AIP_SYSTEM", "optional PCIe env was not created")
		if (!uvm_config_db#(pcie_tl_env_config)::get(system_env, "pcie_env", "tl_policy_cfg", policy_slot) ||
			policy_slot != original_policy || pcie.cfg != original_policy || system_cfg.pcie_cfg != original_policy)
			`uvm_error("PCIE_AIP_SYSTEM", "cfg and tl_policy_cfg must carry the same caller-owned object")
		if (pcie.cfg.num_rc != 1 || pcie.cfg.num_ep != 1 || pcie.cfg.max_outstanding != 24 ||
			pcie.cfg.cpl_timeout_ns != 88888 || pcie.rc_agent.rc_driver.cpl_timeout_ns != 88888)
			`uvm_error("PCIE_AIP_SYSTEM", "graph structural override lost the loaded PCIe policy")
		if (pcie.topology_cfg != external_graph || external_graph.nodes.size() != 2 || external_graph.links.size() != 1)
			`uvm_error("PCIE_AIP_SYSTEM", "wrapper replaced or modified the caller graph")
		if (old_timeout_present) aip_cmdline_override::set_val("pcie_cfg.cpl_timeout_ns", old_timeout);
		else aip_cmdline_override::clear("pcie_cfg.cpl_timeout_ns");
		super.run_phase(phase);
		`uvm_info("PCIE_AIP_SYSTEM", "PASS caller graph and shared tl_policy_cfg reached the real PCIe driver", UVM_LOW)
		phase.drop_objection(this);
	endtask
endclass
`endif
