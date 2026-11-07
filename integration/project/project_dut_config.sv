// integration/project：截图版硬件值类型；仅独立项目 package 包含，禁止进入生产 VIO。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

typedef struct packed {
	logic [12:0]	reserved_31_19;
	logic		vdpa_en;
	logic		ecrc_en;
	logic		valid;
	logic [15:0]	requester_id;
} project_bdf_entry_t;

typedef struct packed {
	logic		vf_valid;
	logic [10:0]	vf_num;
	logic [3:0]	pf_num;
} project_ep_requester_id_t;

typedef struct packed {
	logic [13:0]	reserved_31_18;
	logic		ecrc_en;
	logic		valid;
	logic [15:0]	completion_id;
} project_completion_bdf_entry_t;

typedef struct packed {
	logic [20:0]	reserved_31_11;
	logic [9:0]	first_vf_offset;
	logic		valid;
} project_pfvf_entry_t;

typedef struct packed {
	logic [29:0]	reserved_63_34;
	logic		vdpa_en;
	logic		valid;
	logic [31:0]	tlp_prefix;
} project_tlp_prefix_entry_t;

typedef struct packed {
	logic [28:0]	reserved_63_35;
	logic [12:0]	global_msix_idx;
	logic [2:0]	host_id;
	logic [9:0]	pfvf_id;
	logic [8:0]	local_msix_idx;
} project_msix_linear_entry_t;

typedef struct packed {
	logic [16:0]	reserved_31_15;
	logic		valid;
	logic		self_mask;
	logic [2:0]	host_id;
	logic [9:0]	function_id;
} project_msix_info_entry_t;

typedef struct packed {
	logic [15:0]	intrl_pnum;
	logic [15:0]	intrl_rate;
} project_msix_interval_entry_t;

typedef struct packed {
	logic [30:0]	reserved_127_97;
	logic		msix_mask;
	logic [31:0]	msix_data;
	logic [63:0]	msix_addr;
} project_msix_table_entry_t;

typedef struct packed {
	logic		valid;
	logic [17:0]	reserved_30_13;
	logic [9:0]	net_id;
	logic [2:0]	cos;
} project_qsch_q2tc_entry_t;

typedef struct packed {
	logic		valid;
	logic [20:0]	reserved_30_10;
	logic [9:0]	group_id;
} project_qsch_n2g_entry_t;

typedef struct packed {
	logic		valid;
	logic [10:0]	reserved_30_20;
	logic [3:0]	dpt;
	logic [11:0]	reserved_15_4;
	logic [3:0]	lvl2_id;
} project_qsch_g2p_entry_t;

typedef struct packed {
	logic [27:0]	reserved_31_4;
	logic [2:0]	host_id;
	logic		enable;
} project_qsch_rnet_entry_t;

typedef struct packed {
	logic [4:0]	reserved_63_59;
	logic [7:0]	vf_id;
	logic [2:0]	host_id;
	logic [47:0]	base_addr_60_13;
} project_rdma_notify_entry_t;

typedef struct packed {
	logic [63:0]	pending;
} project_msix_pba_word_t;

typedef struct packed {
	logic [15:0]	intrl_pnum_stat;
	logic [15:0]	intrl_rate_timer;
} project_msix_stat_t;

typedef struct packed {
	logic [31:0]	status;
} project_pfvf_drop_status_t;

typedef struct packed {
	logic [31:0]	clear_mask;
} project_pfvf_drop_clear_t;

// 同域消息必须唯一确定 owner/vector；接收 sink 不依赖是否存在 VIO service。
typedef struct {
	dpu_function_key_t	owner;
	int unsigned	local_vector;
	int unsigned	global_vector;
	logic [63:0]	address;
	logic [31:0]	data;
	logic	masked;
} project_msix_message_t;

// 类别独立记账；可选平台项不冒充截图已有位域，状态读取不进入初始化类别。
typedef enum int unsigned {
	PROJECT_BAR, PROJECT_AF, PROJECT_PFVF, PROJECT_BDF, PROJECT_COMPLETION_BDF,
	PROJECT_PREFIX, PROJECT_MSIX_LINEAR, PROJECT_MSIX_INFO, PROJECT_MSIX_INTERVAL,
	PROJECT_MSIX_CONTROL, PROJECT_MSIX_TABLE, PROJECT_MSIX_FUNCTION,
	PROJECT_NOTIFY, PROJECT_Q2TC, PROJECT_N2G, PROJECT_G2P, PROJECT_SPWRR,
	PROJECT_TC_WEIGHT, PROJECT_VTX, PROJECT_VRX, PROJECT_QUEUE_AUX,
	PROJECT_RDMA_NOTIFY, PROJECT_RNET, PROJECT_MSIX_PBA, PROJECT_MSIX_STAT, PROJECT_PFVF_DROP
} project_table_kind_e;

// 平台必须声明索引来源；局部/全局编号不能因为数值恰巧相同就互换。
typedef enum int unsigned {
	PROJECT_INDEX_EXPLICIT, PROJECT_INDEX_GLOBAL_FUNCTION, PROJECT_INDEX_GLOBAL_QPAIR,
	PROJECT_INDEX_GLOBAL_VECTOR, PROJECT_INDEX_LOCAL_VECTOR
} project_index_policy_e;

typedef enum int unsigned {PROJECT_HOST_EP, PROJECT_HOST_SW} project_host_mode_e;

// 表目标独立于表项 owner；offset 是选定 BAR 内模块偏移，绝非物理地址。
// 间接端口数据宽度固定为该项宽度；control 写入先 clear 再 set trigger_mask。
typedef struct {
	bit	provided;
	string	reg_target;
	bit	access_host_provided;
	int unsigned	access_host;
	bit	access_uses_owner_host;
	logic [63:0]	module_offset;
	logic [63:0]	table_offset;
	int unsigned	capacity;
	int unsigned	entry_bytes;
	project_index_policy_e	index_policy;
	bit	indirect;
	logic [63:0]	data_port;
	logic [63:0]	control_port;
	logic [31:0]	index_mask;
	logic [31:0]	control_fixed;
	logic [31:0]	trigger_mask;
	int unsigned	index_shift;
	bit	required;
} project_table_layout_t;

// 每 Function 的平台编码输入。完整 VF Routing ID 由平台给出，绝不按数量推断。
typedef struct {
	dpu_function_key_t	key;
	project_host_mode_e	mode;
	int unsigned	intel_pf;
	int	intel_vf;
	logic [15:0]	requester;
	int unsigned	vport;
	int unsigned	pfvf;
	int unsigned	first_vf_offset;
	int unsigned	bdf_index;
	int unsigned	completion_index;
	int unsigned	prefix_index;
	logic [31:0]	prefix;
	bit	prefix_enabled;
	bit	ecrc;
	bit	vdpa;
} project_function_policy_t;

// ctx 保存真实访问目标和整个操作范围；仅冻结视图生成，checked helper 再核对原件。
typedef struct {
	dpu_device_snapshot	snapshot;
	longint unsigned	snapshot_id;
	longint unsigned	config_generation;
	string	layout_id;
	project_table_kind_e	kind;
	project_bar_target_t	target;
	project_table_layout_t	layout;
	int unsigned	table_index;
	bit [63:0]	byte_offset;
	string	record_key;
} project_table_context_t;

// 初始化非 packed 上下文时显式处理 class/string/enum，避免四态垃圾参与副本校验。
function automatic project_table_context_t project_empty_context(input project_bar_target_t target);
	project_table_context_t value;
	value.snapshot = null;
	value.snapshot_id = 0;
	value.config_generation = 0;
	value.layout_id = "";
	value.kind = PROJECT_BAR;
	value.target = target;
	value.layout = '{reg_target:"", index_policy:PROJECT_INDEX_EXPLICIT, default:0};
	value.table_index = 0;
	value.byte_offset = 0;
	value.record_key = "";
	return value;
endfunction

// 公共 Function 查询不依赖 VIO ring；service 集合与租约来自同一个冻结快照。
typedef struct {
	dpu_function_key_t	key;
	dpu_pcie_function_id_t	pcie_id;
	int unsigned	global_function_id;
	int unsigned	rc_slot;
	bit	is_af;
	dpu_service_key_t	services[$];
	dpu_bar_pair_lease_t	bars[$];
} project_function_record_t;

// BAR 编码未知，保持真实租约及平台声明的完整原子组，不制造可发送 payload。
typedef struct {
	project_table_context_t	ctx;
	project_function_record_t	owners[$];
	project_bar_target_t	members[$];
} project_bar_mapping_cfg_t;

// 平台控制项没有截图线格式，保留显式声明的 raw/mask；不同类别仍使用独立 hook。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	logic [127:0]	value;
	logic [127:0]	writable_mask;
} project_control_cfg_t;

// bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_bdf_entry_t	entry;
} project_bdf_cfg_t;

// completion_bdf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_completion_bdf_entry_t	entry;
} project_completion_bdf_cfg_t;

// pfvf 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_pfvf_entry_t	entry;
} project_pfvf_cfg_t;

// tlp_prefix 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_tlp_prefix_entry_t	entry;
} project_tlp_prefix_cfg_t;

// msix_linear 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_linear_entry_t	entry;
} project_msix_linear_cfg_t;

// msix_info 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_info_entry_t	entry;
} project_msix_info_cfg_t;

// msix_interval 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_interval_entry_t	entry;
} project_msix_interval_cfg_t;

// msix_table 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_msix_table_entry_t	entry;
} project_msix_table_cfg_t;

// qsch_q2tc 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_q2tc_entry_t	entry;
} project_qsch_q2tc_cfg_t;

// qsch_n2g 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_n2g_entry_t	entry;
} project_qsch_n2g_cfg_t;

// qsch_g2p 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_g2p_entry_t	entry;
} project_qsch_g2p_cfg_t;

// qsch_rnet 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_qsch_rnet_entry_t	entry;
} project_qsch_rnet_cfg_t;

// rdma_notify 单项值：ctx 与 owner/消费者独立保存；仅 entry 是硬件线格式。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	project_rdma_notify_entry_t	entry;
} project_rdma_notify_cfg_t;

// 公共只读导出拥有值副本、借用 snapshot/registry；不依赖 VIO ring 生命周期。
class project_dpu_setup extends uvm_object;
	local dpu_device_snapshot	m_snapshot;
	local project_bar_registry	m_registry;
	local longint unsigned	m_generation;
	local project_function_record_t	m_functions[$];
	local dpu_af_extra_queue_binding_t	m_extras[$];

	// 发布时一次构造，未知/失配的 Function 或 slot 使构造失败而不是发布半份视图。
	extern function new(string name, dpu_device_snapshot snapshot,
		project_bar_registry registry, longint unsigned generation);
	// 导出前校验真实租约和 RC 域；失败不改变旧值集合。
	extern function bit populate(input dpu_resource_snapshot resources, output string why);
	// 身份和代号只读，用于拒绝旧 scope；调用方无法更换内部 registry。
	extern function bit belongs_to(input dpu_device_snapshot snapshot, input project_bar_registry registry);
	// 查询函数只返回值副本，不允许通过副本改写冻结拓扑。
	extern function void list_functions(output project_function_record_t records[$]);
	extern function bit get_function(input dpu_function_key_t key, output project_function_record_t record);
	extern function void list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);
	extern function longint unsigned get_generation();
endclass

// 空键表示整份视图；BAR 选择仍保留完整 Function 身份，不重新编号。
class project_dpu_config_scope extends uvm_object;
	local project_dpu_setup	m_setup;
	local dpu_function_key_t	m_keys[$];
	local int unsigned	m_bars[$];
	local project_table_kind_e	m_kinds[$];
	// 保存选择；validate 在任何 hook 前一次检查全部未知/重复项。
	extern function new(string name, project_dpu_setup setup,
		dpu_function_key_t keys[$], int unsigned bars[$], project_table_kind_e kinds[$] = {});
	// 同一代且全部键存在才通过；空子集合不能意外扩大成其他 Host。
	extern function bit validate(input project_dpu_setup setup, output string why);
	// 只读选择查询，调用前必须 validate。
	extern function bit selects(input dpu_function_key_t key);
	extern function bit selects_bar(input int unsigned bar_id);
	extern function bit selects_kind(input project_table_kind_e kind);
endclass

// 借用冻结来源，populate 成功前无 Function 记录可访问。
function project_dpu_setup::new(string name, dpu_device_snapshot snapshot,
	project_bar_registry registry, longint unsigned generation);
	super.new(name);
	m_snapshot = snapshot;
	m_registry = registry;
	m_generation = generation;
endfunction

// 从实际快照枚举租约，保持无 VIO Host/Function 的公共导出能力。
function bit project_dpu_setup::populate(input dpu_resource_snapshot resources, output string why);
	dpu_function_key_t	keys[$];
	dpu_function_key_t	af;
	dpu_bar_pair_lease_t	af_bar;
	dpu_service_key_t	services[$];
	project_function_record_t	candidates[$];
	why = "public setup needs frozen registry and snapshots";
	if (m_snapshot == null || m_registry == null || resources == null) return 0;
	if (!m_registry.is_frozen() || m_functions.size() != 0 || m_generation == 0) return 0;
	if (!m_snapshot.get_expected_af(af, af_bar, why)) return 0;
	m_snapshot.list_functions(keys);
	m_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
	foreach (keys[i]) begin
		project_function_record_t	r;
		r.key = keys[i];
		r.is_af = dpu_same_function_key(keys[i], af);
		if (!m_snapshot.get_pcie_id(r.key, r.pcie_id, why) ||
			!m_snapshot.get_global_function_id(r.key, r.global_function_id, why) ||
			!m_snapshot.list_bars(r.key, r.bars, why) ||
			!m_registry.get_slot(r.key.host_id, r.pcie_id.domain.segment_id, r.rc_slot, why)) return 0;
		foreach (services[j])
			if (dpu_same_function_key(r.key, services[j].function_key)) r.services.push_back(services[j]);
		candidates.push_back(r);
	end
	m_functions = candidates;
	resources.list_af_extra_queue_bindings(m_extras);
	why = "";
	return 1;
endfunction

// 只比较借用身份，既不重新采样参数也不重新分配地址。
function bit project_dpu_setup::belongs_to(input dpu_device_snapshot snapshot, input project_bar_registry registry);
	return m_snapshot == snapshot && m_registry == registry && m_generation != 0;
endfunction

// 返回整份值副本，修改结果不影响公共拓扑。
function void project_dpu_setup::list_functions(output project_function_record_t records[$]);
	records = m_functions;
endfunction

// 完整 Function key 查询，失败不回退 PF0。
function bit project_dpu_setup::get_function(input dpu_function_key_t key, output project_function_record_t record);
	foreach (m_functions[i]) begin
		if (dpu_same_function_key(m_functions[i].key, key)) begin
			record = m_functions[i];
			return 1;
		end
	end
	return 0;
endfunction

// AF 额外项是真实容量消费者，单列而不虚构 ring。
function void project_dpu_setup::list_af_extra_queues(output dpu_af_extra_queue_binding_t records[$]);
	records = m_extras;
endfunction

// 公共发布代号不随 VIO ring 准备代号变化。
function longint unsigned project_dpu_setup::get_generation();
	return m_generation;
endfunction

// scope 借用精确 setup；不取得资源或管理权。
function project_dpu_config_scope::new(string name, project_dpu_setup setup,
	dpu_function_key_t keys[$], int unsigned bars[$], project_table_kind_e kinds[$]);
	super.new(name);
	m_setup = setup;
	m_keys = keys;
	m_bars = bars;
	m_kinds = kinds;
endfunction

// 全范围只读预检必须发生在第一个用户 hook 前；BAR 必须在每个选中 Function 存在。
function bit project_dpu_config_scope::validate(input project_dpu_setup setup, output string why);
	project_function_record_t	r;
	project_function_record_t	all[$];
	bit	seen[string];
	bit	found;
	why = "scope belongs to another public setup";
	if (setup == null || setup != m_setup) return 0;
	foreach (m_keys[i]) begin
		if (!setup.get_function(m_keys[i], r) || seen.exists(dpu_function_key_name(m_keys[i]))) begin
			why = "scope contains unknown/duplicate Function";
			return 0;
		end
		seen[dpu_function_key_name(m_keys[i])] = 1;
	end
	setup.list_functions(all);
	foreach (m_bars[b]) begin
		foreach (m_bars[j]) if (j < b && m_bars[b] == m_bars[j]) begin
			why = "scope contains duplicate BAR"; return 0;
		end
		foreach (all[f]) begin
			if (!selects(all[f].key)) continue;
			found = 0;
			foreach (all[f].bars[k]) if (all[f].bars[k].even_bar_id == m_bars[b]) found = 1;
			if (!found) begin why = "scope BAR is not a real lease on every selected Function"; return 0; end
		end
	end
	why = "";
	return 1;
endfunction

// 不按全局编号范围推测成员，非连续 Function 保持原身份。
function bit project_dpu_config_scope::selects(input dpu_function_key_t key);
	if (m_keys.size() == 0) return 1;
	foreach (m_keys[i]) if (dpu_same_function_key(m_keys[i], key)) return 1;
	return 0;
endfunction

// 空 BAR 列表表示选中 Function 的实际全部租约。
function bit project_dpu_config_scope::selects_bar(input int unsigned bar_id);
	if (m_bars.size() == 0) return 1;
	foreach (m_bars[i]) if (m_bars[i] == bar_id) return 1;
	return 0;
endfunction

// 只读/W1C 查询只接受独立上下文；禁止用状态值进入普通初始化 dispatch。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
} project_state_query_t;

typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	project_pfvf_drop_clear_t	entry;
} project_pfvf_drop_clear_cfg_t;

// MSI-X 地址/数据模板独立于 VIO；存在标志区分显式零与未提供，PBA 容量必须明确。
typedef struct {
	bit	table_only_enable;
	bit	interval_present;
	project_msix_interval_entry_t	interval_entry;
	bit	self_mask_present;
	logic	self_mask;
	bit	address_present;
	bit	data_present;
	logic [63:0]	address_base;
	logic [63:0]	address_stride;
	logic [31:0]	data_base;
	logic [31:0]	data_stride;
	bit	table_present;
	int unsigned	table_bar;
	logic [63:0]	table_offset;
	int unsigned	table_size;
	bit	pba_present;
	int unsigned	pba_bar;
	logic [63:0]	pba_offset;
	int unsigned	pba_words;
} project_msix_policy_t;

// BAR 原子组只声明逻辑成员，发布时解析真实租约；不要求用户在 build 前知道随机 BAR base。
typedef struct {
	string	name;
	dpu_function_key_t	functions[$];
	int unsigned	bar_ids[$];
} project_bar_group_policy_t;

// PFVF 关系校验输入包含同一 PF 的完整实际成员，不用数量/隐含 VF stride 推算路由。
typedef struct {
	project_function_record_t	functions[$];
	project_function_policy_t	policies[$];
} project_pfvf_relationship_t;

// 空类别列表保持全类别视图；明确类别只能确认其自己的账本项。
function bit project_dpu_config_scope::selects_kind(input project_table_kind_e kind);
	if (m_kinds.size() == 0) return 1;
	foreach (m_kinds[i]) if (m_kinds[i] == kind) return 1;
	return 0;
endfunction
