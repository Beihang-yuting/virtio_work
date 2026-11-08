// integration/project：单 Host/PF0、一对 Packed 队列的固定 VTX 联调配置入口。
// 依赖 project_dut_config_seq 的真实 PCIe 写表流程；本类写死表偏移与策略，不依赖平台布局输入。
// cfg/env 仍拥有 BDF/BAR、队列和 DMA ring；本 seq 借用这些资源，不重建冻结拓扑或伪造地址。
// build 前必须选择 Packed256/Polling/TX-only 和 BAR0 offset0 DPU32 Notify；不支持运行期改模式。
class project_single_queue_config_seq extends project_dut_config_seq;
	`uvm_object_utils(project_single_queue_config_seq)

	// 构造独立入口，不改变原 project_dut_config_seq 的行为。
	extern function new(string name = "project_single_queue_config_seq");
	// 校验已分配资源后安装固定表/策略，再复用真实配置、使能和失败传播流程。
	extern virtual task body();
	// 固定基线只接受实际的一 Host/PF0/一 pair；冻结合同不匹配时返回具体原因。
	extern protected function bit prepare_fixed_configuration(output string why);
	// 把明确的驱动偏移同时写到输入与冻结视图；仅本入口使用，目标固定 h0.pf0.bar0。
	extern protected function void fixed_layout(
		input project_table_kind_e	kind,
		input logic [63:0]		module_offset,
		input logic [63:0]		table_offset,
		input int unsigned		bytes,
		input int unsigned		capacity,
		input project_index_policy_e	index_policy
	);
endclass

// 对象只保存执行状态；共享资源由 cfg/env 管理。
function project_single_queue_config_seq::new(string name);
	super.new(name);
endfunction

// 先检查冻结的软件模式，避免 DUT 写成 Packed 而 driver 仍运行另一种格式。
task project_single_queue_config_seq::body();
	if (!prepare_fixed_configuration(error_msg)) begin
		error_msg = {"single_queue_baseline: ", error_msg};
		return;
	end
	super.body();
endtask

// 使用同一个固定管理窗口；VTX 间接端口在调用后单独补齐，其余都是线性 DWORD 表。
function void project_single_queue_config_seq::fixed_layout(
	input project_table_kind_e	kind,
	input logic [63:0]		module_offset,
	input logic [63:0]		table_offset,
	input int unsigned		bytes,
	input int unsigned		capacity,
	input project_index_policy_e	index_policy
);
	cfg.table_layouts[kind] = '{
		provided:1, reg_target:"h0.pf0.bar0", module_offset:module_offset, table_offset:table_offset,
		entry_bytes:bytes, capacity:capacity, index_policy:index_policy, required:1, default:0
	};
	cfg.frozen_layouts[kind] = cfg.table_layouts[kind];
endfunction

// 固定寄存器偏移和策略，BAR base/global qid/ring IOVA 保留实际分配值。
// 所有检查都在首笔 Memory Write 前完成；通信失败仍由父类原样报告，不跳过或伪造成功。
function bit project_single_queue_config_seq::prepare_fixed_configuration(output string why);
	dpu_host_info_t			hosts[$];
	dpu_function_key_t		functions[$];
	dpu_vio_qpair_binding_t		pairs[$];
	dpu_function_key_t		pf0;
	dpu_function_key_t		requester_owner;
	dpu_pcie_function_id_t		requester_pcie_id;
	vio_service_requirement_t	requirement;
	project_vio_policy_t		policy;
	project_function_policy_t	function_policy;
	project_bar_target_t		target;
	string				name;

	pf0 = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
	why = "expected published Host0/PF0/no-VF with exactly one VIO pair";
	if (cfg.device_snapshot == null || cfg.resource_snapshot == null || cfg.bar_registry == null) return 0;
	if (!cfg.vio_cfg_by_host.exists(0) || cfg.vio_cfg_by_host[0] == null) return 0;
	cfg.device_snapshot.list_hosts(hosts);
	cfg.device_snapshot.list_functions(functions);
	cfg.resource_snapshot.list_vio_bindings(pairs);
	if (hosts.size() != 1 || functions.size() != 1 || pairs.size() != 1) begin
		why = $sformatf("expected hosts/functions/pairs=1/1/1, actual=%0d/%0d/%0d",
			hosts.size(), functions.size(), pairs.size());
		return 0;
	end
	if (hosts[0].host_id != 0 || !dpu_same_function_key(functions[0], pf0) ||
		!dpu_same_function_key(pairs[0].service_key.function_key, pf0) || pairs[0].virtio_pair_index != 0) return 0;
	if (!cfg.vio_cfg_by_host[0].resolve_final_service_requirement(pairs[0].service_key, requirement, why)) return 0;
	if (!requirement.enabled || !requirement.tx_enable || requirement.rx_enable ||
		requirement.behavior.num_queue_pairs != 1 || requirement.behavior.vq_type != VQ_PACKED ||
		requirement.behavior.queue_size != 256 || requirement.completion_mode != VIRTIO_COMPLETION_POLLING ||
		!requirement.notify_layout_valid || requirement.notify_bar != 0 || requirement.notify_base != 0 ||
		requirement.notify_stride != 0 || requirement.notify_encoding != VIO_NOTIFY_DPU32) begin
		why = $sformatf({"expected enabled Packed256/Polling/TX-only/1pair, BAR0+0 DPU32 Notify; ",
			"actual enabled=%0b tx/rx=%0b/%0b pairs=%0d type=%s size=%0d completion=%s ",
			"notify_valid=%0b bar=%0d base=%h stride=%h encoding=%s"},
			requirement.enabled, requirement.tx_enable, requirement.rx_enable, requirement.behavior.num_queue_pairs,
			requirement.behavior.vq_type.name(), requirement.behavior.queue_size, requirement.completion_mode.name(),
			requirement.notify_layout_valid, requirement.notify_bar, requirement.notify_base, requirement.notify_stride,
			requirement.notify_encoding.name());
		return 0;
	end
	if (!cfg.bar_registry.resolve_name("h0.pf0.bar0", target, why)) return 0;
	name = dpu_function_key_name(pf0);
	why = "expected actual PF0 EP route requester=0/intel_pf=0/no-VF/vport=0";
	if (!cfg.frozen_functions.exists(name)) return 0;
	function_policy = cfg.frozen_functions[name];
	if (target.route.pf_index != 0 || target.route.is_vf ||
		function_policy.mode != PROJECT_HOST_EP || function_policy.requester != 0 ||
		function_policy.intel_pf != 0 || function_policy.intel_vf != -1 || function_policy.vport != 0) return 0;
	// EP requester 编码与资源分配的 PCI BDF 独立；允许 bdf_first=16 等真实分配起点。
	if (!cfg.bar_registry.resolve_requester(0, 0, requester_owner, requester_pcie_id, why)) return 0;
	if (!dpu_same_function_key(requester_owner, pf0)) begin
		why = "requester 0 does not resolve to the actual Host0/PF0 registry owner";
		return 0;
	end

	// 固定只下 AF、BDF、Notify、QSCH 和 VTX；Polling 不创建 MSI-X 表或 BAR/PFVF 公共表。
	cfg.configure_public        = 0;
	cfg.configure_bdf           = 1;
	cfg.verify_readback         = 0;
	cfg.reg_target              = "h0.pf0.bar0";
	cfg.frozen_reg_target       = "h0.pf0.bar0";
	cfg.qsch_configure_controls = 1;
	cfg.qsch_mode               = 0;
	cfg.qsch_mode_offset        = 'hb001c0;
	cfg.qsch_spwrr              = 'hff;
	cfg.qsch_tc_weight          = 'h11111111;
	cfg.platform_controls.delete();
	function_policy.bdf_index = 0;
	function_policy.ecrc      = 0;
	function_policy.vdpa      = 0;
	cfg.function_policies[name] = function_policy;
	cfg.frozen_functions[name] = function_policy;

	fixed_layout(PROJECT_BDF, 'h100000, 'h8000, 4, 128, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_NOTIFY, 'h080000, 'h20000, 16, 512, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_Q2TC, 'hb00000, 'h10000, 4, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
	fixed_layout(PROJECT_N2G, 'hb00000, 'h12000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_G2P, 'hb00000, 'h14000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_SPWRR, 'hb00000, 'h16000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_TC_WEIGHT, 'hb00000, 'h18000, 4, 1024, PROJECT_INDEX_EXPLICIT);
	fixed_layout(PROJECT_VTX, 'h880000, 'h10000, 16, 2048, PROJECT_INDEX_GLOBAL_QPAIR);
	cfg.table_layouts[PROJECT_VTX].indirect     = 1;
	cfg.table_layouts[PROJECT_VTX].data_port    = 'h134;
	cfg.table_layouts[PROJECT_VTX].control_port = 'h130;
	cfg.table_layouts[PROJECT_VTX].index_mask   = 'h7ff;
	cfg.table_layouts[PROJECT_VTX].trigger_mask = 'h2000;
	cfg.frozen_layouts[PROJECT_VTX] = cfg.table_layouts[PROJECT_VTX];

	policy = '{service_key:pairs[0].service_key, prefetch_ram:"", net_stride:1, eth_ports:8,
		notify_net_pair5:1, notify_table_base_provided:1, default:0};
	cfg.vio_policies[dpu_service_key_name(policy.service_key)] = policy;
	cfg.frozen_policies = cfg.vio_policies;
	why = "";
	return 1;
endfunction
