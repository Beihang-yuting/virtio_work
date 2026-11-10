// integration/project/tests：无 VIO 参数的项目构建及 PCIe→AIP idle 活动回归。
// 复用 Intel APP 模型和生产 RC responder，不直接调用 tick，不伪造 monitor 观察。
// 测试拥有一块临时 Host DMA 内存/IOVA；结束前回收，不启动 VIO worker 或分配 ring。
package project_pcie_idle_test_pkg;
	timeunit 1ns;
	timeprecision 1ps;

	import uvm_pkg::*;
	import aip_core_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	import virtio_dpu_pkg::*;
	import dpu_pcie_pkg::*;
	import intel_pcie_adapter_pkg::*;
	import project_env_pkg::*;
	import project_external_integration_test_pkg::*;
	`include "uvm_macros.svh"

	// 单 Host/PF0 使用默认 project cfg；父类只提供真实 APP 收发和断言工具。
	class project_pcie_idle_test extends project_external_integration_test;
		`uvm_component_utils(project_pcie_idle_test)

		// 不改变父类资源所有权，构建时不设置任何 vio.* 参数。
		extern function new(string	name, uvm_component	parent);

		// 仅注入真实 Intel VIF；无 VIO 队列也必须能够创建 PCIe/DPU 环境。
		extern virtual function void build_phase(uvm_phase	phase);

		// 由 APP 发 DMA 读并核对返回 DWORD；超时由测试 top 的统一限时捕获。
		extern task read_dma(bit [15:0]	requester, bit [63:0]	iova);

		// 分别证明 TX、RX、自动 Completion 触发 tick，再验证 end_test 的完整空闲窗口。
		extern virtual task run_phase(uvm_phase	phase);
	endclass

	function project_pcie_idle_test::new(string	name, uvm_component	parent);
		super.new(name, parent);
	endfunction

	function void project_pcie_idle_test::build_phase(uvm_phase	phase);
		intel_pcie_vif_t			vif;
		intel_pcie_adapter_config	app_cfg;

		cfg = project_env_cfg::type_id::create("cfg");
		cfg.load_params();
		require_true(cfg.dpu_cfg.hosts == 1, "idle fixture requires the default single Host");
		require_true(uvm_config_db#(intel_pcie_vif_t)::get(null, "uvm_test_top", "intel_vif_0", vif),
			"missing Intel VIF");
		cfg.intel_rc_vifs[0] = vif;
		app_cfg = intel_pcie_adapter_config::type_id::create("app_cfg");
		app_cfg.side = INTEL_PCIE_APPLICATION;
		uvm_config_db#(intel_pcie_vif_t)::set(this, "app_0", "vif", vif);
		uvm_config_db#(intel_pcie_adapter_config)::set(this, "app_0", "intel_cfg", app_cfg);
		apps[0] = intel_pcie_if_adapter::type_id::create("app_0", this);
		uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
		env = project_env::type_id::create("env", this);
	endfunction

	task project_pcie_idle_test::read_dma(bit [15:0]	requester, bit [63:0]	iova);
		pcie_tl_cpl_tlp	completion;

		send_memory(0, 0, requester, iova, 0, 10'h056);
		wait (completions[0].size() != 0);
		completion = completions[0].pop_front();
		require_true(completion.requester_id == requester && completion.tag == 10'h056 &&
			completion.cpl_status == CPL_STATUS_SC && completion.payload.size() == 4,
			"DMA Completion identity/status/size mismatch");
		require_true({completion.payload[3], completion.payload[2], completion.payload[1], completion.payload[0]}
			== 32'h12345678, "DMA data did not reach the real Intel APP");
	endtask

	task project_pcie_idle_test::run_phase(uvm_phase	phase);
		dpu_bar_target_t			target;
		dpu_function_policy_t	policy;
		dpu_vio_qpair_binding_t	pairs_in_use[$];
		vio_dpu_cfg_seq			setup;
		dpu_bar_reg_seq			access;
		bit [63:0]				gpa;
		bit [63:0]				iova;
		byte					bytes[];
		int unsigned			before_activity;
		int						command_status;
		bit						ok;
		bit						ended;
		string					why;
		string					result;
		time					started_at;
		time					last_dma_at;
		time					ended_at;

		phase.raise_objection(this);
		cfg.dpu_cfg.resource_snapshot.list_vio_bindings(pairs_in_use);
		require_true(pairs_in_use.size() == 0 && env.vio_envs[0].function_instances.size() == 0,
			"missing VIO parameters unexpectedly enabled a service");
		setup = vio_dpu_cfg_seq::type_id::create("empty_vio_setup");
		setup.cfg = cfg.dpu_cfg;
		setup.prepare_vio_configuration(selection, ok, why);
		require_true(ok && selection == null && cfg.dpu_cfg.queues_by_host.num() == 0,
			{"empty VIO setup did not skip queue preparation: ", why});
		fork
			app_receive(0);
		join_none
		#100ns;
		require_true(cfg.dpu_cfg.bar_map.resolve_name("h0.pf0.bar0", target, why), why);
		policy = cfg.dpu_cfg.function_policies[dpu_function_key_name(target.function_key)];

		// 仅一次 RC posted 发送：APP 没有 VIP monitor，计数只能来自生产 driver。
		before_activity = aip_activity::get_count();
		access = dpu_bar_reg_seq::type_id::create("bar_write");
		access.cfg      = cfg.dpu_cfg;
		access.addr     = 'h2000;
		access.is_write = 1;
		access.wdata    = 'haabbccdd;
		access.start(env.pcie_env.rc_agents[0].sequencer);
		#20ns;
		require_true(access.status == PCIE_RW_OK && posted[0].size() == 1 &&
			aip_activity::get_count() == before_activity + 1, "RC transmit did not tick exactly once");

		gpa  = env.vio_envs[0].host_mem.alloc(64, 64);
		iova = env.vio_envs[0].iommu.map_for_host(0, target.pcie_id.bdf, gpa, 64, DMA_BIDIRECTIONAL);
		require_true(iova != 0 && iova != gpa, "DMA fixture requires nonidentity IOVA");
		before_activity = aip_activity::get_count();
		send_memory(0, 1, policy.requester, iova, 32'h12345678);
		#20ns;
		env.vio_envs[0].host_mem.read_mem(gpa, 4, bytes);
		require_true(bytes.size() == 4 && {bytes[3], bytes[2], bytes[1], bytes[0]} == 32'h12345678 &&
			aip_activity::get_count() == before_activity + 1, "received DMA write did not tick exactly once");

		before_activity = aip_activity::get_count();
		read_dma(policy.requester, iova);
		#20ns;
		require_true(aip_activity::get_count() == before_activity + 2,
			"DMA read and automatic Completion must each tick once");

		// 业务持续跨越多个 idle 窗口；计数仅由生产 PCIe 更新，不能直接喂 tick 帮测试通过。
		started_at = $time;
		fork
			begin
				aip_cmd::exec_result("end_test idle=200ns timeout=3us", SRC_INTERNAL, command_status, result);
				ended_at = $time;
				ended = 1;
			end
			begin
				repeat (4) begin
					#120ns;
					require_true(!ended, "end_test exited while DMA traffic was still active");
					read_dma(policy.requester, iova);
					last_dma_at = $time;
				end
			end
		join
		require_true(command_status == 0 && ended_at >= last_dma_at + 200ns && ended_at < started_at + 3us,
			{"end_test did not wait a full idle window after DMA: ", result});
		aip_tcl_bridge::__tcl_exit = 0;
		before_activity = aip_activity::get_count();
		#250ns;
		require_true(aip_activity::get_count() == before_activity, "idle polling produced false activity");

		env.vio_envs[0].iommu.unmap_for_host(0, target.pcie_id.bdf, iova);
		env.vio_envs[0].host_mem.free(gpa);
		env.vio_envs[0].host_mem.leak_check();
		require_true(env.pcie_env.scbs[0].mismatched == 0 && env.pcie_env.scbs[0].pending_requests.num() == 0,
			"PCIe checks failed or a DMA request remained pending");
		`uvm_info("PROJECT_PCIE_IDLE_PASS", $sformatf("checks=%0d idle_after_dma=%0t no_vio=1",
			checks, ended_at - last_dma_at), UVM_LOW)
		phase.drop_objection(this);
	endtask
endpackage
