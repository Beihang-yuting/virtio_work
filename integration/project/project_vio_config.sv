// integration/project：截图版硬件值类型；仅独立项目 package 包含，禁止进入生产 VIO。
// packed 只描述线格式；普通记录借用冻结快照，不拥有或释放设备/DMA 资源。
// 保留 X/Z 供发送前拒绝；所有未知模块基址和端口由平台明确声明。

typedef struct packed {
	logic [15:0]	reserved_127_112;
	logic [5:0]	reserved_111_106;
	logic [9:0]	sport_id;
	logic [3:0]	dma_info;
	logic [12:0]	dma_msix;
	logic [2:0]	sport;
	logic		queue_stop;
	logic		tail_buf_id_dis;
	logic		redraw_en;
	logic		high_speed_mode;
	logic		seg_en;
	logic		interl_seg_en;
	logic		virtio_mode;
	logic		queue_en;
	logic [3:0]	q_depth;
	logic [63:0]	desc_addr;
} project_vtx_entry_t;

typedef struct packed {
	logic [50:0]	reserved_127_77;
	logic [1:0]	notify_type;
	logic [10:0]	global_qid;
	logic [2:0]	host_id;
	logic [53:0]	base_addr_60_7;
	logic [6:0]	local_qid_encoding;
} project_vio_notify_entry_t;

typedef struct packed {
	logic		reserved_127;             // [127]
	logic [14:0]	dsc_pre_read_ram_addr;     // [126:112]，单位为 descriptor 槽
	logic [2:0]	dsc_pre_max_num;           // [111:109]，0 表示 256 槽
	logic		reserved_108;             // [108]
	logic [1:0]	dsc_pre_read_threshold;    // [107:106]
	logic [1:0]	dsc_dma_num;               // [105:104]
	logic [1:0]	dsc_mode;                  // [103:102]
	logic [2:0]	payload_dsc_len;           // [101:99]
	logic [1:0]	head_dsc_len;              // [98:97]
	logic		dma_msix_en;               // [96]
	logic [12:0]	dma_msix;                 // [95:83]
	logic [9:0]	dport_id;                 // [82:73]
	logic [2:0]	dport;                    // [72:70]
	logic		virtio_mode;              // [69]
	logic		queue_en;                 // [68]
	logic [3:0]	q_depth;                  // [67:64]，log2(descriptor 数)
	logic [63:0]	dsc_addr;                 // [63:0]，设备可见 ring IOVA
} project_vrx_entry_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vtx_entry_t	entry;
} project_vtx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vrx_entry_t	entry;
} project_vrx_cfg_t;

// 真实 ring 绑定是校验依据，entry 修改不能反向更改已分配资源。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	project_vio_notify_entry_t	entry;
} project_vio_notify_cfg_t;

// 队列平台策略按 service 给出；pair 映射可用显式基数/步长生成，冻结后不可重新采样。
// VRX RAM 是 descriptor 槽，域名表示实际共享 RAM；不同 Host 相同域仍检查非重叠。
typedef struct {
	dpu_service_key_t	service_key;
	project_vtx_entry_t	vtx;
	project_vrx_entry_t	vrx;
	bit	fpga;
	string	prefetch_ram;
	int unsigned	prefetch_start;
	int unsigned	prefetch_slots;
	int unsigned	net_base;
	int unsigned	net_stride;
	int unsigned	group_id;
	int unsigned	cos;
	int unsigned	eth_ports;
	bit	ets;
	bit	distinguish_business;
	int unsigned	ets_priority;
	bit	notify_net_pair5;
	bit	notify_table_base_provided;
	int unsigned	notify_table_bar;
	logic [63:0]	notify_table_offset;
} project_vio_policy_t;

// 内部统一账本复用预检/锁/结果；外部 hook 始终消费类别对应的 typed cfg。
typedef struct {
	project_table_context_t	ctx;
	dpu_function_key_t	owner;
	dpu_service_key_t	consumers[$];
	bit	has_queue;
	vio_queue_setup_t	binding;
	logic [127:0]	entry;
	logic [127:0]	enable_mask;
	logic [127:0]	enable_value;
	string	dependencies[$];
} project_config_record_t;

// 跨 Host 选择显式携带每个核心 setup/scope；调用方可选非连续 Host/service。
// 值只借用句柄，项目在提交/释放前先验证全部 Host，不能把循环误当原子保证。
typedef struct {
	vio_external_setup	setups[int unsigned];
	vio_config_scope	scopes[int unsigned];
} project_vio_selection_t;

// 使能和辅助上下文仍携带完整 ring 绑定，用户无需回查其他配置对象。
typedef struct {
	project_table_context_t	ctx;
	vio_queue_setup_t	binding;
	logic [127:0]	value;
	logic [127:0]	writable_mask;
} project_queue_control_cfg_t;
