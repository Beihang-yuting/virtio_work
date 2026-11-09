# 项目 env / env_cfg 完整参考代码

本文件由 `python3 scripts/render_project_code.py` 从实际源码生成；使用 `--check` 检查一致性。
接入流程、参数和 Intel bind 见 [README](../integration/project/README.md)。

用户自己的 env_cfg 直接组合 `dpu_env_cfg`、`virtio_net_env_config`、`pcie_tl_env_config`，
不需要继承参考 cfg。env 直接创建三个组件，借用平台已有 VIF 和每 Host 的唯一 memory manager。
参考 `project_*` 只承担组装；公共实现通过 package 复用，不复制到用户 env。

| 编译入口 | 提供的能力 |
| --- | --- |
| `$DPU_COMMON_ROOT/filelists/dpu_common.f` | 资源、BAR、表类型与 `dpu_env_cfg` |
| `$DPU_COMMON_ROOT/filelists/dpu_pcie.f` | `dpu_cfg_seq`、`dpu_bar_reg_seq`、PCIe 路由 |
| `integration/dpu/virtio_dpu_pkg.sv` | `vio_dpu_cfg_seq`、`vio_pcie_rc_driver` |
| `integration/project/project_env_pkg.sv` | 本文的 env/cfg/base_test 与单队列示例 |

顺序为 AIP → DPU/host_mem/net_packet/PCIe TL → VIO/AIP → Intel → DPU PCIe 集成 → VIO DPU 集成 → 用户包。
同一个 package 只编译一次。参考 project 不加入生产核心 filelist/package。

配置 seq 从实际 PCIe sequencer 的 `dpu_cfg` 键获取公共配置；VIO env 以 `vio_env_hN` 发布。
`vio_dpu_cfg_seq` 先执行 AF 声明和状态读，再配置 BDF/所选 MSI-X、准备实际 ring、
写 Notify/QSCH/VTX/VRX，最后确认 VIO。每批 VIO/RDMA Notify 表成功后，
每个管理 BAR 写一次 `+0x80044 = 1`。空批次不写，失败停止；不增加 bank 切换或使能读回。
原有每100次完整 DWORD 写后的 AF 状态读保持不变。

Tcl 名称仍为 `dut_config`、`reg_acc`、`load_params`；其中 reg_acc 注册 `dpu_bar_reg_seq`，
addr 为 Host0/PF0 BAR0 内偏移。load_params 用 AIP 命令宏注册一次，顶层统一刷新允许字段。
完整快照恢复说明和边界见 README，源码变更后需重新编译并保存快照。

## `filelists/project_integration.f`

SHA-256: `2442dc727c076dd90a08f0dcbe2ebffbd6543b0330dd2742b38b4218575b066a`

```text
// Intel HARD_IP + 真实 EP 应用 DUT 的唯一项目参考入口；从 virtio_work 根运行。
// 依赖根由调用方提供；Intel interface、adapter 和 DUT 的接口几何必须一致。
// 已有统一工程 filelist 时，按此顺序增补缺失包，禁止把已有包再次编译。
-f filelists/aip_integration.f
+incdir+$INTEL_PCIE_ROOT/src
$INTEL_PCIE_ROOT/src/interface/intel_pcie_if.sv
$INTEL_PCIE_ROOT/src/adapter/intel_pcie_adapter_pkg.sv
-f $DPU_COMMON_ROOT/filelists/dpu_pcie.f
+incdir+integration/dpu
integration/dpu/virtio_dpu_pkg.sv
+incdir+integration/project
integration/project/project_env_pkg.sv
```

## `integration/project/project_env_pkg.sv`

SHA-256: `9c334e84b750c1acf6a10877d23eb18e2f1c70db4a98755d64d9691656b3d207`

```systemverilog
// integration/project：项目参考组装的唯一 package 编译入口。
// 顺序：AIP→DPU/Host memory/PCIe TL/VIO→AIP glue→本包。
// 固定 Intel 接入；Intel interface/adapter package 必须在本包之前编译。
// include 的普通 .sv 不可另行编译；本包只定义类型，不创建组件或取得外部资源。
package project_env_pkg;
	timeunit 1ns;
	timeprecision 1ps;

	import uvm_pkg::*;
	import aip_core_pkg::*;
	import host_mem_pkg::*;
	import dpu_resource_pkg::*;
	import dpu_pcie_pkg::*;
	import virtio_dpu_pkg::*;
	import pcie_tl_pkg::*;
	import virtio_net_pkg::*;
	import virtio_aip_pkg::*;
	import intel_pcie_adapter_pkg::*;
	`include "uvm_macros.svh"

	`include "project_env_cfg.sv"
	`include "project_single_queue_config_seq.sv"
	`include "project_env.sv"
	`include "project_base_test.sv"
endpackage
```

## `integration/project/project_env_cfg.sv`

SHA-256: `1fa558fe238ff871ec3d9638d9d219ba31e9bc9fcee67459bab2568f72660556`

```systemverilog
// integration/project：用户 env_cfg 的组合参考，不要求用户继承本类。
// DPU 拥有资源与公共表，VIO 拥有行为/ring，PCIe 拥有传输参数；只在这里组装三个 cfg。
// 平台 VIF/pool 均借用，创建和连接组件由 project_env 完成。
class project_env_cfg extends uvm_object;
	`uvm_object_utils(project_env_cfg)
	// 三类子配置由本对象创建；每个 Host 的 VIO 配置在加载参数后独立生成。
	dpu_env_cfg				dpu_cfg;
	virtio_net_env_config	vio_cfg;
	virtio_net_env_config	vio_cfg_by_host[int unsigned];
	pcie_tl_env_config		pcie_cfg;

	// 值是 RC agent 下标；EP 由真实 DUT 提供。缺省 h→h，PF/VF 共用 Host 的 slot。
	int unsigned	tl_slot_by_host[int unsigned];

	// 借用平台已有 pool；分配模式和粒度只作用于需要新建的 Host manager。
	host_mem_pool	host_mem_pool_binding;
	alloc_mode_e	host_mem_mode = MODE_BUDDY;
	int unsigned	host_mem_granule = DEFAULT_MIN_GRANULE;

	// 按物理 RC slot 索引，不是按 PF/VF 索引；同一 Host 的 Function 共用端口。
	// 平台可注入句柄，或由 bind wrapper 向实际 adapter 路径发布；env 会复用并校验。
	// Intel cfg 没有 load_params；这里不宣称 pcie_cfg.intel.* 已自动注册。
	intel_pcie_adapter_config	intel_cfg_by_slot[int unsigned];
	intel_pcie_vif_t			intel_rc_vifs[int unsigned];

	virtual virtio_protocol_event_if protocol_vifs[$];

	protected bit	params_loaded;

	// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
	// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
	extern function new(string	name = "project_env_cfg");

	// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
	// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
	extern function bit validate_tl_mapping(output string	why);

	// 先构造 DPU 输入，再缓存各 Host VIO 需求并提交 placement，最后配置传输参数。
	// 幂等入口不重复采样随机值；实际资源解析仍由 dpu_device_env 的 build 执行一次。
	extern virtual function void load_params();

	// 只构造纯参数候选；保留三类 cfg 句柄的原有职责，不分配 BAR、ring 或发送配置。
	extern function bit make_runtime_candidate(
		output project_env_cfg	candidate,
		output string			why
	);

	// 全部预检后原地提交，不更换 DPU/Host cfg 或共享资源句柄。
	extern function void apply_runtime_candidate(input project_env_cfg	candidate);
endclass

// 创建配置容器；固定 REAL_DUT，实际 Intel 接口由 bind wrapper 或平台注入。
// new 不读取 plusargs，允许派生用例在 load_params 前修改场景默认值。
function project_env_cfg::new(string	name);
	super.new(name);

	dpu_cfg  = dpu_env_cfg::type_id::create("dpu_cfg");
	vio_cfg  = virtio_net_env_config::type_id::create("vio_cfg");
	pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");

	vio_cfg.execution_mode         = VIRTIO_EXEC_REAL_DUT;
	vio_cfg.external_configuration = 1;
endfunction

// 验证 Host→TL slot 是完整的一一映射；不补缺项，避免错配后静默使用 Root0。
// 仅支持每 Host 一个 segment 0；失败返回原因，不修改输入配置或访问 DUT。
function bit project_env_cfg::validate_tl_mapping(output string	why);
	bit				used_slots[int unsigned];
	int unsigned	count;

	why   = "";
	count = dpu_cfg.device_cfg.hosts.size();

	if (count == 0 || tl_slot_by_host.num() != count || vio_cfg_by_host.num() != count) begin
		why = "each DPU Host needs exactly one VIO config and TL slot";
		return 0;
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg	host;
		int unsigned	slot;

		host = dpu_cfg.device_cfg.hosts[i];

		if (host == null) begin
			why = "DPU Host config is null";
			return 0;
		end

		if (!tl_slot_by_host.exists(host.host_id) || !vio_cfg_by_host.exists(host.host_id) || vio_cfg_by_host[host.host_id] == null) begin
			why = $sformatf("Host%0d has no VIO config or TL slot", host.host_id);
			return 0;
		end

		slot = tl_slot_by_host[host.host_id];

		if (slot >= count || used_slots.exists(slot)) begin
			why = "TL slots must be unique and cover 0..Host_count-1";
			return 0;
		end

		if (host.pcie_domains.size() != 1) begin
			why = "Intel project requires one PCIe domain per Host";
			return 0;
		end

		if (host.pcie_domains[0] == null) begin
			why = "Host PCIe domain is null";
			return 0;
		end

		if (
			host.pcie_domains[0].key.host_id != host.host_id ||
			host.pcie_domains[0].key.segment_id != 0
		) begin
			why = "Intel project requires Host-owned segment 0";
			return 0;
		end

		used_slots[slot] = 1;
	end

	return 1;
endfunction

// 先构造 DPU 输入，再缓存各 Host VIO 需求并提交 placement，最后配置传输参数。
// 幂等入口不重复采样随机值；实际资源解析仍由 dpu_device_env 的 build 执行一次。
function void project_env_cfg::load_params();
	string	why;

	if (params_loaded) return;
	dpu_cfg.load_params();
`ifdef AIP_CMDLINE_SV
	begin
		alloc_mode_e			mem_mode;
		host_mem_alloc_policy_e	mem_policy;
		longint unsigned		mem_granule;

		`aip_enum("dpu", alloc_mode_e, mem_mode, host_mem_mode)
		`aip_enum("dpu", host_mem_alloc_policy_e, mem_policy, vio_cfg.host_mem_policy)
		`DPU_AIP_UINT("dpu", longint unsigned, mem_granule, host_mem_granule)

		if (
			(mem_granule == 0) ||
			(mem_granule > 64) ||
			((mem_granule & (mem_granule - 1)) != 0)
		) begin
			`uvm_fatal("PROJECT_CFG", "dpu.mem_granule must be a power of two in 1..64")
		end

		host_mem_mode           = mem_mode;
		host_mem_granule        = int'(mem_granule);
		vio_cfg.host_mem_policy = mem_policy;
	end
`endif
	vio_cfg.external_configuration = 1;
	vio_cfg.load_params("vio");

	if (vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT) begin
		`uvm_fatal("PROJECT_INTEL", "Intel reference requires REAL_DUT EP application logic")
	end

	foreach (dpu_cfg.device_cfg.hosts[i]) begin
		int unsigned			h;
		virtio_net_env_config	host_vio;

		h        = dpu_cfg.device_cfg.hosts[i].host_id;
		host_vio = virtio_net_env_config::type_id::create($sformatf("vio_cfg_h%0d", h));
		host_vio.copy_defaults_from(vio_cfg);

		host_vio.host_id           = h;
		host_vio.host_scope_enable = 1;
		host_vio.host_scope_id     = h;

		host_vio.load_params($sformatf("vio.h%0d", h));
		host_vio.enable_service_params("vio");

		if (host_vio.execution_mode != vio_cfg.execution_mode) begin
			`uvm_fatal("PROJECT_CFG",
					   "one PCIe environment requires consistent VIO execution modes")
		end

		vio_cfg_by_host[h] = host_vio;

		if (!host_vio.bind_dpu_services(dpu_cfg, why)) `uvm_fatal("PROJECT_CFG", why)
	end
	if (tl_slot_by_host.num() == 0) begin
		for (int	unsigned	h = 0; h < dpu_cfg.hosts; h++) begin
			tl_slot_by_host[h] = h;
		end
	end

	if (!validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_CFG", why)
	end

	// Intel 的接口选择由下面的固定模式和 env 的 instance override 完成，
	// 无需额外选择宏。标量参数仍加载，但不能绕过真实 DUT 的方向与信用约束。
	pcie_cfg.if_mode          = SV_IF_MODE;
	pcie_cfg.rc_is_active     = UVM_ACTIVE;
	pcie_cfg.ep_auto_response = 0;
	pcie_cfg.use_unified_mem  = 1;
	pcie_cfg.mem_access_mode  = PCIE_TL_MEM_PER_BUFFER;

	// 真实 EP 应用逻辑由 DUT 提供；Intel adapter 即使放在 passive agent 旁也会驱动
	// 引脚，因此必须关闭 EP 组件，而不是仅将 EP 标成 UVM_PASSIVE。
	pcie_cfg.rc_agent_enable = 1;
	pcie_cfg.ep_agent_enable = 0;
	pcie_cfg.num_rc          = tl_slot_by_host.num();
	pcie_cfg.num_ep          = 0;

	// 公共 FC 不门控；每端口有限 AVST credit 由 intel_cfg 独立管理。
	pcie_cfg.infinite_credit = 1;
	pcie_cfg.load_params("pcie_cfg");

	if (pcie_cfg.ep_auto_response) begin
		`uvm_fatal("PROJECT_CFG", "real EP DUT must provide its own responses")
	end

	if (!pcie_cfg.infinite_credit) begin
		`uvm_fatal("PROJECT_INTEL", "pcie_cfg.infinite_credit must be 1; Intel owns AVST credits")
	end

	params_loaded = 1;
endfunction

// 只构造纯参数候选；保留三类 cfg 句柄的原有职责，不分配 BAR、ring 或发送配置。
function bit project_env_cfg::make_runtime_candidate(
	output project_env_cfg	candidate,
	output string			why
);
	dpu_cfg_scope	msix_scope;

	candidate = new("runtime_candidate");
	if (!dpu_cfg.make_runtime_candidate(candidate.dpu_cfg, why)) return 0;
	if (!vio_cfg.make_runtime_candidate(null, "vio", candidate.vio_cfg, why)) return 0;
	foreach (vio_cfg_by_host[h]) begin
		if (!vio_cfg_by_host[h].make_runtime_candidate(
				candidate.vio_cfg, $sformatf("vio.h%0d", h), candidate.vio_cfg_by_host[h], why
			))
			return 0;
	end
	foreach (dpu_cfg.device_cfg.functions[f]) begin
		dpu_service_key_t	key;
		int unsigned		h;

		key = '{
			function_key: dpu_cfg.device_cfg.functions[f].key,
			service_kind: DPU_SERVICE_VIO_NET,
			service_instance_id: 0
		};
		h = key.function_key.host_id;
		if (!vio_cfg_by_host[h].validate_runtime_service(candidate.vio_cfg_by_host[h], key, why))
			return 0;
	end
	foreach (candidate.vio_cfg_by_host[h])
	if (!candidate.vio_cfg_by_host[h].bind_dpu_services(candidate.dpu_cfg, why, 0)) return 0;
	if (!candidate.dpu_cfg.select_msix_scope(msix_scope, why)) return 0;
	why = "";
	return 1;
endfunction

// 全部预检后原地提交，不更换 DPU/Host cfg 或共享资源句柄。
function void project_env_cfg::apply_runtime_candidate(input project_env_cfg	candidate);
	dpu_cfg.apply_runtime_candidate(candidate.dpu_cfg);
	vio_cfg.apply_runtime_candidate(candidate.vio_cfg);
	foreach (vio_cfg_by_host[h])
	vio_cfg_by_host[h].apply_runtime_candidate(candidate.vio_cfg_by_host[h]);
endfunction
```

## `integration/project/project_env.sv`

SHA-256: `0e72c358c179e8302e31a1b685ba4d9eca8745143b15d9e124183ca53078645b`

```systemverilog
// integration/project：项目组件组装；仅继承 uvm_env，不承担寄存器写表。
// 依赖参考 cfg、dpu_pcie_pkg、virtio_dpu_pkg 与 DPU、PCIe TL、Intel adapter、VIO。
// env 拥有子组件；dpu_cfg 保存公共资源/表值，各 Host VIO env 拥有实际 ring。
// connect 将同一个 dpu_cfg 和各 Host VIO env 发布到 PCIe sequencer，seq 不依赖项目 cfg 类型。
// 每 Host 一个 Intel RC，PF/VF 共用；VIO 挂在 DPU 子树保证快照先发布。
typedef class project_env;

// 单个命令借用项目 env；由 AIP 宏生成适配，无独立命令类。
project_env	project_runtime_env;

class project_env extends uvm_env;
	`uvm_component_utils(project_env)

	project_env_cfg	cfg;
	dpu_device_env	dpu_env;
	pcie_tl_env		pcie_env;
	virtio_net_env	vio_envs[int unsigned];
	host_mem_pool	shared_pool;

	local bit	tx_observation_bound[int unsigned];

	// 首次成功发布后才打印，重复同快照幂等，新拓扑要求 rebuild 而不留下新旧路由混合。
	extern function void publish_dpu_configuration(
		output bit		ok,
		output string	why
	);

	// EOE 与晚首次发布共用同一检查；自动打印去重由 registry 维护。
	extern virtual function void end_of_elaboration_phase(uvm_phase	phase);

	// 构造组件壳；配置与共享资源延迟到 build，允许 test 先注入平台对象。
	extern function new(
		string			name,
		uvm_component	parent
	);

	// 按 UVM 顺序建立 DPU、PCIe 和 VIO；缺 cfg 或绑定冲突立即报错。
	extern virtual function void build_phase(uvm_phase	phase);

	// 子环境构建完毕后绑定快照、协议接口和 Function endpoint；拒绝跨 Host 错配。
	extern virtual function void connect_phase(uvm_phase	phase);

	// 运行期入口：重读当前AIP参数，只在首次prepare前或已release后更新同一个cfg。
	extern task load_params(
		output bit		ok,
		output string	why
	);

	// 每次仿真登记一次各 Host 的 VIO 服务及 Tcl 命令；空服务或重复注册会报错。
	extern function void register_aip_commands();

	// 准备或借用各 Host 的共享内存，校验已有 manager 的身份、范围与分配策略。
	extern protected function void prepare_host_memory();

	// 校验 cfg 已确定的 RC 拓扑并绑定 Host 内存，不在组件创建阶段重复覆盖参数。
	extern protected function void prepare_pcie_config();

	// 在 PCIe build 前解析各端口的 cfg/VIF，借用 wrapper 对象并拒绝缺失或复用。
	extern protected function void prepare_intel_bindings();

	// 连接阶段核对实际 adapter、cfg/VIF 句柄及 RC-only 组件树，不再补绑接口。
	extern protected function void check_intel_bindings();

	// 按完整 Function 身份分配协议 VIF，拒绝空接口以及跨 Host/Function 复用。
	extern protected function void bind_protocol_vifs();
endclass

// 构造项目组件壳；资源创建延迟到 build，以允许 test 注入已有平台对象。
function project_env::new(
	string			name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction

// 为每个 Host 准备唯一 manager；DPU 的 GPA limit 是开区间，pool end 是闭区间。
// 已有 manager 必须覆盖声明 aperture 且策略一致，不重置已有分配/数据。
function void project_env::prepare_host_memory();
	host_mem_pool	dpu_pool;

	shared_pool = cfg.host_mem_pool_binding;

	if (cfg.dpu_cfg.host_mem_pool_ref != null) begin
		if (!$cast(dpu_pool, cfg.dpu_cfg.host_mem_pool_ref)) begin
			`uvm_fatal("PROJECT_ENV", "DPU memory owner is not a host_mem_pool")
		end

		if (shared_pool != null && shared_pool != dpu_pool) begin
			`uvm_fatal("PROJECT_ENV", "project and DPU specify distinct Host pools")
		end

		shared_pool = dpu_pool;
	end

	if (shared_pool == null) begin
		shared_pool = host_mem_pool::type_id::create("shared_pool");
	end

	foreach (cfg.dpu_cfg.device_cfg.hosts[i]) begin
		dpu_host_cfg			host;
		virtio_net_env_config	vio;
		host_mem_manager		manager;

		host = cfg.dpu_cfg.device_cfg.hosts[i];

		if (host == null || !host.has_gpa_aperture || host.gpa_limit <= host.gpa_base) begin
			`uvm_fatal("PROJECT_ENV", "each Host requires a nonempty GPA aperture")
		end

		if (!cfg.vio_cfg_by_host.exists(host.host_id)) begin
			`uvm_fatal("PROJECT_ENV", "Host has no VIO behavior configuration")
		end

		vio = cfg.vio_cfg_by_host[host.host_id];

		if (!shared_pool.has_host(host.host_id)) begin
			if (!shared_pool.create_host(
					host.host_id,
					host.gpa_base,
					host.gpa_limit - 1,
					cfg.host_mem_mode,
					cfg.host_mem_granule,
					vio.host_mem_policy
				)) begin
				`uvm_fatal("PROJECT_ENV", "could not initialize Host memory")
			end
		end

		manager = shared_pool.get_host(host.host_id);

		if (
			!manager.is_initialized() ||
			manager.get_host_id() != host.host_id ||
			!manager.contains_range(host.gpa_base, host.gpa_limit - host.gpa_base) || manager.get_alloc_policy() != vio.host_mem_policy) begin
			`uvm_fatal("PROJECT_ENV",
					   "existing Host memory disagrees with configured aperture/policy")
		end

		if (
			vio.host_mem_binding != null ||
			(vio.host_mem_pool_binding != null && vio.host_mem_pool_binding != shared_pool)
		) begin
			`uvm_fatal("PROJECT_ENV", "Host VIO cfg must borrow the project-owned pool")
		end

		vio.host_mem_pool_binding = shared_pool;
		vio.mem_base              = host.gpa_base;
		vio.mem_end               = host.gpa_limit - 1;
	end

	cfg.host_mem_pool_binding     = shared_pool;
	cfg.dpu_cfg.host_mem_pool_ref = shared_pool;
endfunction

// 按显式 Host→slot 绑定 TL 内存；拓扑由 cfg 加载时确定，这里不再次赋固定值。
// 每 Host 只保留一个 RC，EP 和配置空间/MMIO 响应来自真实 DUT。
// 既有绑定只校验不重建；Switch、多余绑定或不同 manager 都拒绝。
function void project_env::prepare_pcie_config();
	string	why;

	if (!cfg.validate_tl_mapping(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end

	if (cfg.pcie_cfg.switch_enable) begin
		`uvm_fatal("PROJECT_ENV", "Intel project reference does not create a Switch")
	end

	if (
		cfg.vio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT ||
		!cfg.pcie_cfg.rc_agent_enable ||
		cfg.pcie_cfg.num_rc != cfg.tl_slot_by_host.num() ||
		cfg.pcie_cfg.ep_agent_enable ||
		cfg.pcie_cfg.num_ep != 0 ||
		cfg.pcie_cfg.if_mode != SV_IF_MODE ||
		!cfg.pcie_cfg.infinite_credit ||
		cfg.pcie_cfg.rc_is_active != UVM_ACTIVE ||
		cfg.pcie_cfg.ep_auto_response ||
		!cfg.pcie_cfg.use_unified_mem
	) begin
		`uvm_fatal(
			"PROJECT_INTEL",
			"Intel requires REAL_DUT, one active RC per Host, no VIP EP, SV_IF_MODE, unified memory and infinite public FC")
	end

	if (cfg.pcie_cfg.ep_root_by_index.num() != 0) begin
		`uvm_fatal("PROJECT_INTEL", "real EP DUT must not have VIP EP-to-Root bindings")
	end

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned		slot;
		host_mem_manager	manager;

		slot    = cfg.tl_slot_by_host[h];
		manager = shared_pool.get_host(h);

		if (cfg.pcie_cfg.host_mem_by_root.exists(slot)) begin
			if (
				cfg.pcie_cfg.host_mem_by_root[slot] != manager ||
				!cfg.pcie_cfg.host_id_by_root.exists(slot) || cfg.pcie_cfg.host_id_by_root[slot] != h) begin
				`uvm_fatal("PROJECT_ENV", "PCIe Host memory binding disagrees with DPU owner")
			end
		end else if (!cfg.pcie_cfg.bind_host_memory(slot, h, manager, why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end
	end

	if (cfg.pcie_cfg.host_mem_by_root.num() != cfg.tl_slot_by_host.num()) begin
		`uvm_fatal("PROJECT_ENV", "extra PCIe Root bindings are not part of this project")
	end
endfunction

// 在 pcie_env::create 前解析每个端口的配置和 VIF：cfg 显式句柄与 wrapper 发布值
// 必须相同；只缺配置时可创建 HARD_IP 默认对象，缺 HDL 接口则不能自动补造。
// 复用 wrapper 对象以保留端口压力/信用设置，拒绝跨端口共享可变 cfg 或物理 VIF。
function void project_env::prepare_intel_bindings();
	intel_pcie_adapter_config	used_cfgs[$];
	intel_pcie_vif_t			used_vifs[$];

	foreach (cfg.tl_slot_by_host[h]) begin
		int unsigned				slot;
		string						path;
		intel_pcie_adapter_config	port_cfg;
		intel_pcie_adapter_config	published_cfg;
		intel_pcie_vif_t			vif;
		intel_pcie_vif_t			published_vif;

		slot          = cfg.tl_slot_by_host[h];
		path          = $sformatf("pcie_env.rc_adapter_%0d", slot);
		port_cfg      = null;
		published_cfg = null;
		vif           = null;
		published_vif = null;

		if (cfg.intel_cfg_by_slot.exists(slot)) begin
			port_cfg = cfg.intel_cfg_by_slot[slot];

			if (port_cfg == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel cfg is null")
			end
		end

		if (uvm_config_db#(intel_pcie_adapter_config)::get(this, path, "intel_cfg", published_cfg)) begin
			if (published_cfg == null || (port_cfg != null && port_cfg != published_cfg)) begin
				`uvm_fatal("PROJECT_INTEL",
						   "project and wrapper publish different Intel cfg handles")
			end

			port_cfg = published_cfg;
		end

		if (port_cfg == null) begin
			port_cfg = intel_pcie_adapter_config::type_id::create($sformatf("intel_cfg_%0d", slot));

			port_cfg.side = INTEL_PCIE_HARD_IP;
		end

		if (port_cfg.side != INTEL_PCIE_HARD_IP) begin
			`uvm_fatal("PROJECT_INTEL",
					   "EP application DUT requires explicit INTEL_PCIE_HARD_IP side")
		end

		port_cfg.validate();

		if (cfg.intel_rc_vifs.exists(slot)) begin
			vif = cfg.intel_rc_vifs[slot];

			if (vif == null) begin
				`uvm_fatal("PROJECT_INTEL", "explicit Intel VIF is null")
			end
		end

		if (uvm_config_db#(intel_pcie_vif_t)::get(this, path, "vif", published_vif)) begin
			if (published_vif == null || (vif != null && vif != published_vif)) begin
				`uvm_fatal("PROJECT_INTEL", "project and wrapper publish different Intel VIFs")
			end

			vif = published_vif;
		end

		if (vif == null) begin
			`uvm_fatal("PROJECT_INTEL", $sformatf("missing Intel VIF at %s.%s", get_full_name(),
												  path))
		end

		foreach (used_cfgs[i]) begin
			if (used_cfgs[i] == port_cfg || used_vifs[i] == vif) begin
				`uvm_fatal("PROJECT_INTEL", "Intel cfg or VIF reused by distinct TL slots")
			end
		end

		used_cfgs.push_back(port_cfg);
		used_vifs.push_back(vif);

		cfg.intel_cfg_by_slot[slot] = port_cfg;
		cfg.intel_rc_vifs[slot]     = vif;

		uvm_config_db#(intel_pcie_adapter_config)::set(this, path, "intel_cfg", port_cfg);

		uvm_config_db#(intel_pcie_vif_t)::set(this, path, "vif", vif);
	end

	if (
		cfg.intel_cfg_by_slot.num() != cfg.tl_slot_by_host.num() ||
		cfg.intel_rc_vifs.num() != cfg.tl_slot_by_host.num()
	) begin
		`uvm_fatal("PROJECT_INTEL", "Intel bindings contain an unused TL slot")
	end
endfunction

// connect 时只校验实际创建的 adapter，不再补绑接口；否则 adapter build 早已失败。
// 确认 instance override 和 bridge 生效，防止接口配置看似存在却仍走公共 TLM 回环。
function void project_env::check_intel_bindings();
	if (
		!pcie_env.bridge_required ||
		pcie_env.ep_agent != null ||
		pcie_env.ep_agents.size() != 0 ||
		pcie_env.ep_adapter != null ||
		pcie_env.ep_adapters.size() != 0
	) begin
		`uvm_fatal("PROJECT_INTEL",
				   "Intel needs the external-pin bridge and RC-only component tree")
	end

	foreach (cfg.intel_cfg_by_slot[slot]) begin
		intel_pcie_if_adapter	adapter;

		if (slot >= pcie_env.rc_adapters.size()) begin
			`uvm_fatal("PROJECT_INTEL", "Intel RC adapter slot is missing")
		end

		if (!$cast(adapter, pcie_env.rc_adapters[slot]) || adapter == null) begin
			`uvm_fatal("PROJECT_INTEL", "Intel instance factory override did not take effect")
		end

		if (
			adapter.cfg != cfg.intel_cfg_by_slot[slot] ||
			adapter.avst_vif != cfg.intel_rc_vifs[slot]
		) begin
			`uvm_fatal("PROJECT_INTEL", "Intel adapter consumed different cfg/VIF handles")
		end
	end
endfunction

// 这里只创建组件和发布输入，不提前查询 DPU snapshot，也不手动调用子组件 build。
// create(..., dpu_env) 让 VIO 位于 DPU 子树；框架先 build DPU，再 build VIO。
// PCIe 只需要 Host 内存和 TL cfg，可以与 DPU 同级，不依赖二者遍历先后顺序。
function void project_env::build_phase(uvm_phase	phase);

	super.build_phase(phase);

	if (!uvm_config_db#(project_env_cfg)::get(this, "", "cfg", cfg) || cfg == null) begin
		`uvm_fatal("PROJECT_ENV", "project environment cfg is missing")
	end

	cfg.load_params();
	uvm_config_db#(dpu_env_cfg)::set(this, "pcie_env.*", "dpu_cfg", cfg.dpu_cfg);
	prepare_host_memory();
	prepare_pcie_config();

	uvm_config_db#(dpu_env_cfg)::set(this, "dpu_env", "cfg", cfg.dpu_cfg);

	dpu_env = dpu_device_env::type_id::create("dpu_env", this);

	prepare_intel_bindings();

	// bridge 的历史字段名含 svt，但这里只开启外部引脚传输，不创建 SVT/provider。
	intel_pcie_configure_env(this, cfg.pcie_cfg, "pcie_env");
	foreach (cfg.tl_slot_by_host[h]) begin
		pcie_tl_rc_driver::type_id::set_inst_override(
			vio_pcie_rc_driver::get_type(), $sformatf(
			"pcie_env.rc_agent_%0d.driver", cfg.tl_slot_by_host[h]), this);
	end
	pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

	foreach (cfg.vio_cfg_by_host[h]) begin
		string	child_name;

		child_name = $sformatf("vio_h%0d", h);

		uvm_config_db#(virtio_net_env_config)::set(dpu_env, child_name, "cfg",
												   cfg.vio_cfg_by_host[h]);

		vio_envs[h] = virtio_net_env::type_id::create(child_name, dpu_env);
	end
endfunction

// 全项目统一分配协议 VIF；显式身份映射优先，兼容 top 的全局 VIF slot 入口。
// 在 Function 绑定 PCIe 前拒绝空接口和跨 Host/Function 复用，不依赖各 Host 局部计数。
function void project_env::bind_protocol_vifs();
	virtual virtio_protocol_event_if used [$];
	virtual virtio_protocol_event_if vif;
	int unsigned	slot;
	string			why;

	slot = 0;

	foreach (vio_envs[h]) begin
		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance	f;

			f = vio_envs[h].function_instances[i];

			if (!cfg.vio_cfg_by_host[h].get_protocol_event_vif(f.pcie_id, vif)) begin
				if (cfg.protocol_vifs.size() != 0) begin
					if (slot >= cfg.protocol_vifs.size()) begin
						`uvm_fatal("PROJECT_ENV", "protocol VIF pool is too small")
					end

					vif = cfg.protocol_vifs[slot];
				end else if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(null, "uvm_test_top", $sformatf("protocol_event_vif_%0d", slot), vif)) begin
					`uvm_fatal("PROJECT_ENV", "global protocol VIF slot is missing")
				end

				if (!cfg.vio_cfg_by_host[h].bind_protocol_event_vif(f.pcie_id, vif, why)) begin
					`uvm_fatal("PROJECT_ENV", why)
				end
			end

			if (vif == null) begin
				`uvm_fatal("PROJECT_ENV", "protocol VIF is null")
			end

			foreach (used[j]) begin
				if (used[j] == vif) begin
					`uvm_fatal("PROJECT_ENV", "protocol VIF reused by distinct Functions/Hosts")
				end
			end

			used.push_back(vif);
			slot++;
		end
	end
endfunction

// connect 自底向上运行，此时 DPU 快照和 PCIe/VIO 子组件均已完成 build/connect。
// 从 Function 的完整身份选择 Host 对应的 TL slot；BDF/BAR 不在 PCIe 中重新分配。
function void project_env::connect_phase(uvm_phase	phase);
	super.connect_phase(phase);

	if (
		pcie_env.global_cfg != null ||
		pcie_env.topology_adapter != null ||
		pcie_env.backend_provider_active ||
		pcie_env.cfg != cfg.pcie_cfg
	) begin
		`uvm_fatal("PROJECT_ENV", "Intel project requires the direct PCIe cfg-only path")
	end

	check_intel_bindings();
	bind_protocol_vifs();

	begin
		bit		ok;
		string	why;

		publish_dpu_configuration(ok, why);
		if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	end

	foreach (vio_envs[h]) begin
		virtio_pcie_function_endpoint	endpoints[$];
		int unsigned					slot;

		slot = cfg.tl_slot_by_host[h];

		if (slot >= pcie_env.rc_agents.size() || pcie_env.rc_agents[slot] == null) begin
			`uvm_fatal("PROJECT_ENV", "Host has no native RC agent")
		end

		foreach (vio_envs[h].function_instances[i]) begin
			virtio_function_instance		f;
			virtio_pcie_function_endpoint	endpoint;

			f = vio_envs[h].function_instances[i];

			if (f.pcie_id.domain.host_id != h || f.pcie_id.domain.segment_id != 0) begin
				`uvm_fatal("PROJECT_ENV", "Function does not belong to its Host segment 0")
			end

			endpoint = virtio_pcie_function_endpoint::type_id::create(
				$sformatf("endpoint_h%0d_f%0d", h, i));

			// Completion 由 PCIe RC driver 接收；无模型 completion adapter 或 EP monitor。
			// 同 Host 的所有 Function 共用该 RC，完整身份仍由 endpoint 保留。
			endpoint.configure(f.pcie_id, pcie_env.rc_agents[slot].sequencer,
							   pcie_env.rc_agents[slot].rc_driver, null,
							   pcie_env.rc_agents[slot].monitor, null);

			endpoints.push_back(endpoint);
		end

		if (!vio_envs[h].bind_pcie_endpoints(endpoints)) begin
			`uvm_fatal("PROJECT_ENV", "VIO endpoint binding failed")
		end
		// 真 DUT 无 EP 接收 monitor；RC monitor 仅收包，发出的真实 doorbell 从 driver TX 观察口补齐。
		// 仅补出站观察，不连接第二 responder，也不重复消费入站 MSI-X。
		if (!tx_observation_bound.exists(h)) begin
			foreach (vio_envs[h].function_instances[i])
			pcie_env.rc_agents[slot].rc_driver.tx_ap.connect(
				vio_envs[h].function_instances[i].driver_agent.observer.analysis_export);
			tx_observation_bound[h] = 1;
		end
	end
	// 发布真实组件句柄，所有配置 sequence 共享它们，不复制运行期状态。
	foreach (vio_envs[h]) begin
		uvm_config_db#(virtio_net_env)::set(this, "pcie_env.*", $sformatf("vio_env_h%0d", h),
											vio_envs[h]);
	end
endfunction

// 每个仿真调用一次：按完整 service 身份登记各 Host，再注册已有 Tcl 命令。
// 空 Host 可跳过；全局没有 VIO service 或重复注册属于接入错误。
function void project_env::register_aip_commands();
	int unsigned	active_hosts;
	string			why;

	active_hosts = 0;

	foreach (vio_envs[h]) begin
		if (vio_envs[h].function_instances.size() == 0) begin
			continue;
		end

		if (!virtio_aip_registry::bind_env(vio_envs[h], why)) begin
			`uvm_fatal("PROJECT_ENV", why)
		end

		active_hosts++;
	end

	if (active_hosts == 0) return;

	if (!virtio_aip_registry::register_business_commands(why)) begin
		`uvm_fatal("PROJECT_ENV", why)
	end
endfunction

// 建立一份 PCIe BAR 扩展并交给公共 cfg；driver 与配置 seq 复用同一个对象。
function void project_env::publish_dpu_configuration(
	output bit		ok,
	output string	why
);
	dpu_pcie_bar_map	map;
	dpu_host_info_t		hosts[$];
	vio_pcie_rc_driver	driver;
	dpu_msix_message_t	host_messages[$];

	ok  = 0;
	why = "DPU/PCIe components are not ready";
	if (dpu_env == null || pcie_env == null || dpu_env.get_snapshot() == null) return;
	if (cfg.dpu_cfg.runtime_ready) begin
		if (cfg.dpu_cfg.device_snapshot != dpu_env.get_snapshot()) begin
			why = "new DPU snapshot requires environment rebuild";
			return;
		end
		ok = !cfg.dpu_cfg.print_bar_map || cfg.dpu_cfg.bar_map.print_bar_map(why, 1);
		return;
	end
	map = dpu_pcie_bar_map::type_id::create("bar_map");
	if (!map.initialize(dpu_env.get_snapshot(), 1, why)) return;
	dpu_env.get_snapshot().list_hosts(hosts);
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;

		h = hosts[i].host_id;
		if (!cfg.tl_slot_by_host.exists(h)) return;
		slot = cfg.tl_slot_by_host[h];
		if (!map.bind_host(h, slot, why)) return;
		if (slot >= pcie_env.rc_agents.size() || !$cast(driver, pcie_env.rc_agents[slot].rc_driver)) begin
			why = "VIO RC driver override was not installed";
			return;
		end
		map.rc_sequencers[slot] = pcie_env.rc_agents[slot].sequencer;
	end
	foreach (cfg.dpu_cfg.function_policies[name]) begin
		dpu_function_policy_t	p;

		p = cfg.dpu_cfg.function_policies[name];
		if (name != dpu_function_key_name(p.key) || $isunknown(p.requester) || !map.bind_function(p.key, p.intel_pf, p.intel_vf, p.requester, why))
			return;
	end
	if (!map.freeze(why) || !cfg.dpu_cfg.publish(dpu_env.get_snapshot(), dpu_env.get_resource_snapshot(), map, why))
		return;
	foreach (hosts[i]) begin
		int unsigned	h;
		int unsigned	slot;

		h    = hosts[i].host_id;
		slot = cfg.tl_slot_by_host[h];
		void'($cast(driver, pcie_env.rc_agents[slot].rc_driver));
		host_messages.delete();
		foreach (cfg.dpu_cfg.messages[m])
		if (cfg.dpu_cfg.messages[m].owner.host_id == h)
			host_messages.push_back(cfg.dpu_cfg.messages[m]);
		if (!driver.install_registry(map, h, 0, slot, why) || !driver.install_receive_path(
				vio_envs[h].host_mem, vio_envs[h].iommu, host_messages, why
			))
			return;
	end
	ok = !cfg.dpu_cfg.print_bar_map || map.print_bar_map(why, 1);
endfunction

// EOE 与晚首次发布共用同一检查；自动打印去重由 BAR map 维护。
function void project_env::end_of_elaboration_phase(uvm_phase	phase);
	bit		ok;
	string	why;

	super.end_of_elaboration_phase(phase);
	publish_dpu_configuration(ok, why);
	if (!ok) `uvm_fatal("PROJECT_PUBLICATION", why)
	if (project_runtime_env != null && project_runtime_env != this)
		`uvm_fatal("PROJECT_PARAM", "load_params command already registered")
	project_runtime_env = this;
endfunction

// 全部候选和RC消息先校验，成功后不推进时间地提交；不自动停DUT或释放现有ring。
// 资源和协议规模固定，字段更改由下一次配置seq写入DUT，命令自身不发送PCIe请求。
task project_env::load_params(
	output bit		ok,
	output string	why
);
	project_env_cfg		candidate;
	vio_pcie_rc_driver	drivers[int unsigned];
	dpu_msix_message_t	host_messages[int unsigned][$];

	ok = 0;
	why = "load_params requires published env without an active VIO generation; release before reload";
	if (cfg == null || !cfg.dpu_cfg.runtime_ready) return;
	foreach (vio_envs[h]) if (vio_envs[h].get_external_setup() != null) return;
	foreach (vio_envs[h])
		foreach (vio_envs[h].function_instances[f]) begin
			virtio_function_instance	vio_instance;

			vio_instance = vio_envs[h].function_instances[f];
			if (vio_instance.driver_agent.ops == null || vio_instance.driver_agent.fsm == null ||
			vio_instance.driver_agent.ops.has_active_queues() ||
			!vio_instance.driver_agent.fsm.external_workers_stopped())
				return;
		end
	if (!cfg.make_runtime_candidate(candidate, why)) return;
	foreach (vio_envs[h]) begin
		int unsigned	slot;

		slot = cfg.tl_slot_by_host[h];
		if (!$cast(drivers[h], pcie_env.rc_agents[slot].rc_driver)) begin
			why = "project RC driver is unavailable";
			return;
		end
		foreach (candidate.dpu_cfg.messages[m])
		if (candidate.dpu_cfg.messages[m].owner.host_id == h)
			host_messages[h].push_back(candidate.dpu_cfg.messages[m]);
		if (!drivers[h].validate_message_catalog(host_messages[h], why)) return;
	end

	cfg.apply_runtime_candidate(candidate);
	foreach (vio_envs[h]) begin
		// 相同候选已通过全Host预检，函数无时间推进；提交不更换BAR或DMA backing。
		if (!drivers[h].replace_message_catalog(host_messages[h], why))
			`uvm_fatal("PROJECT_PARAM", why)
		vio_envs[h].wait_pol.copy(cfg.vio_cfg_by_host[h].wait_policy_cfg);
		foreach (vio_envs[h].function_instances[f]) begin
			virtio_function_instance	vio_instance;
			vio_service_requirement_t	requirement;

			vio_instance = vio_envs[h].function_instances[f];
			void'(cfg.vio_cfg_by_host[h].resolve_final_service_requirement(vio_instance.service_key, requirement, why));
			requirement.behavior.max_vio_net_qpairs_per_device = vio_instance.drv_cfg.max_vio_net_qpairs_per_device;
			vio_instance.drv_cfg = requirement.behavior;
			vio_instance.driver_agent.fsm.drv_cfg = vio_instance.drv_cfg;
			vio_instance.private_cfg =
				cfg.vio_cfg_by_host[h].get_dpu_private_config(vio_instance.service_key);
		end
	end
	ok  = 1;
	why = "";
	`uvm_info("PROJECT_PARAM",
			  "reloaded runtime parameters into existing cfg; run dut_config to program DUT",
			  UVM_LOW)
endtask

// 顶层无参命令保持原 status/result_out；restore 后读取 AIP 当前来源，命令自身不写 DUT。
task project_load_params();
	aip_cmd	command;
	bit		ok;
	string	why;

	command = aip_cmd::get_handle("load_params");
	if (command.args_in != "") begin
		command.status     = 1;
		command.result_out = "ERROR: load_params takes no arguments";
		return;
	end
	if (project_runtime_env == null) begin
		command.status     = 1;
		command.result_out = "ERROR: load_params environment is not ready";
		return;
	end
	project_runtime_env.load_params(ok, why);
	command.status     = ok ? 0 : 1;
	command.result_out = ok ? "OK: runtime parameters reloaded" : {"ERROR: load_params: ", why};
endtask

`aip_cmd_task(load_params, project_load_params)
```

## `integration/project/project_base_test.sv`

SHA-256: `04ea43e97f302122313a8d6abfe04a1a73f7e729d07a140420345ab9999cdbd4`

```systemverilog
// integration/project：可继承的 AIP base_test，由 project_env_pkg 最后包含。
// 依赖本目录 env/cfg 与 AIP bridge；基类拥有 objection 和统一配置/命令入口。
// 不知道平台的 reset/TL 接口/DMA/业务完成信号，故将这三处保留为强制实现的接口，
// 防止空 hook 假装平台已准备好。派生 test 用 factory 注册，本虚类不注册 factory。
virtual class project_base_test extends uvm_test;
	project_env_cfg	cfg;
	project_env		env;

	// 构造 test 壳；构建参数由 cfg.load_params 负责，无需在 new 重复逐项赋值。
	extern function new(
		string			name,
		uvm_component	parent
	);

	// 在 cfg 加载后、env 构建前注入平台 pool/IOMMU/VIF 等句柄。
	// cfg 若已由 top 完整注入，派生类可显式提供空实现；此 hook 不重新 load_params。
	pure virtual function void bind_platform_handles();

	// 等待真实复位/Intel 接口就绪，准备 requester-aware DMA 和平台网络检查器。
	// 必须有平台自己的超时及错误处理；返回后才启动 DUT 配置 sequence。
	pure virtual task prepare_platform();

	// Tcl 退出后等待业务完成并检查数据、DMA、PCIe/协议监测与资源回收。
	// vio_tx 返回只表示提交，不能仅凭 AIP run_loop 退出认定业务测试通过。
	pure virtual task finish_platform();

	// 支持 top 提供预建 cfg 或使用 factory；单一参数入口后只下发同一 cfg 句柄。
	extern virtual function void build_phase(uvm_phase	phase);

	// 配置 sequence 失败即停止参考流程，已导出资源留给平台 quiesce/release。
	extern function void require_success(
		input bit		ok,
		input string	why
	);

	// 唯一运行顺序：平台就绪→独立表配置/可选读回→VIO 确认→业务命令→Tcl→业务收尾。
	// 运行期 Tcl 只能改变下一条命令采样的参数，不能改写已冻结拓扑。
	extern virtual task run_phase(uvm_phase	phase);
endclass

// 构造 test 外壳，不读取设备。
function project_base_test::new(
	string			name,
	uvm_component	parent
);
	super.new(name, parent);
endfunction

// 唯一参数加载后注入平台句柄，再构建同一个 env。
function void project_base_test::build_phase(uvm_phase	phase);
	super.build_phase(phase);
	if (!uvm_config_db#(project_env_cfg)::get(this, "", "project_cfg", cfg))
		cfg = project_env_cfg::type_id::create("cfg");
	if (cfg == null) `uvm_fatal("PROJECT_TEST", "project_cfg is null")
	cfg.load_params();
	bind_platform_handles();
	uvm_config_db#(project_env_cfg)::set(this, "env", "cfg", cfg);
	env = project_env::type_id::create("env", this);
endfunction

// 配置失败立即停止参考流程，资源仍由平台显式回收。
function void project_base_test::require_success(
	input bit		ok,
	input string	why
);
	if (!ok) `uvm_fatal("PROJECT_TEST", why)
endfunction

// 平台就绪后启动一个配置 sequence；失败不进入业务，成功才注册发包命令。
// 参考 VIO/QSCH 布局可直接使用基类；平台特殊访问才需 factory override 单项 hook。
task project_base_test::run_phase(uvm_phase	phase);
	vio_dpu_cfg_seq	config_seq;
	int unsigned	host;

	phase.raise_objection(this);
	prepare_platform();

	config_seq = vio_dpu_cfg_seq::type_id::create("config_seq");
	if (!cfg.tl_slot_by_host.first(host)) begin
		`uvm_fatal("PROJECT_TEST", "no PCIe Host configured")
	end
	config_seq.start(env.pcie_env.rc_agents[cfg.tl_slot_by_host[host]].sequencer);
	require_success(config_seq.success, config_seq.error_msg);

	if (cfg.dpu_cfg.queues_by_host.num() != 0) begin
		env.register_aip_commands();
		aip_tcl_bridge::run_loop();
	end
	finish_platform();
	phase.drop_objection(this);
endtask
```

## `integration/project/project_single_queue_config_seq.sv`

SHA-256: `f0c6d316a72100fa65862ad11e55689040c948340f14ae33e9211662ef8ed23d`

```systemverilog
// integration/project：单 Host/PF0、一对 Packed 队列的固定 VTX 联调配置入口。
// 依赖 vio_dpu_cfg_seq 的真实 PCIe 写表流程；本类写死表偏移与策略，不依赖平台布局输入。
// cfg/env 仍拥有 BDF/BAR、队列和 DMA ring；本 seq 借用这些资源，不重建冻结拓扑或伪造地址。
// build 前必须选择 Packed256/Polling/TX-only 和 BAR0 offset0 DPU32 Notify；不支持运行期改模式。
class project_single_queue_config_seq extends vio_dpu_cfg_seq;
	`uvm_object_utils(project_single_queue_config_seq)

	// 构造独立入口，不改变原 vio_dpu_cfg_seq 的行为。
	extern function new(string	name = "project_single_queue_config_seq");
	// 校验已分配资源后安装固定表/策略，再复用真实配置、使能和失败传播流程。
	extern virtual task body();
	// 固定基线只接受实际的一 Host/PF0/一 pair；冻结合同不匹配时返回具体原因。
	extern protected function bit prepare_fixed_configuration(output string	why);
	// 把明确的驱动偏移同时写到输入与冻结视图；仅本入口使用，目标固定 h0.pf0.bar0。
	extern protected function void fixed_layout(
		input dpu_table_kind_e		kind,
		input logic [63:0]			module_offset,
		input logic [63:0]			table_offset,
		input int unsigned			bytes,
		input int unsigned			capacity,
		input dpu_index_policy_e	index_policy
	);
endclass

// 对象只保存执行状态；共享资源由 cfg/env 管理。
function project_single_queue_config_seq::new(string	name);
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
	input dpu_table_kind_e		kind,
	input logic [63:0]			module_offset,
	input logic [63:0]			table_offset,
	input int unsigned			bytes,
	input int unsigned			capacity,
	input dpu_index_policy_e	index_policy
);
	cfg.table_layouts[kind] = '{
		provided: 1,
		reg_target: "h0.pf0.bar0",
		module_offset: module_offset,
		table_offset: table_offset,
		entry_bytes: bytes,
		capacity: capacity,
		index_policy: index_policy,
		required: 1,
		default: 0
	};
	cfg.frozen_layouts[kind] = cfg.table_layouts[kind];
endfunction

// 固定寄存器偏移和策略，BAR base/global qid/ring IOVA 保留实际分配值。
// 所有检查都在首笔 Memory Write 前完成；通信失败仍由父类原样报告，不跳过或伪造成功。
function bit project_single_queue_config_seq::prepare_fixed_configuration(output string	why);
	dpu_host_info_t				hosts[$];
	dpu_function_key_t			functions[$];
	dpu_vio_qpair_binding_t		pairs[$];
	dpu_function_key_t			pf0;
	dpu_function_key_t			requester_owner;
	dpu_pcie_function_id_t		requester_pcie_id;
	vio_service_requirement_t	requirement;
	dpu_vio_policy_t			policy;
	dpu_function_policy_t		function_policy;
	dpu_bar_target_t			target;
	string						name;
	virtio_net_env				vio_env;
	dpu_pcie_bar_map			map;
	pcie_tl_cq_route_t			route;

	pf0 = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
	why = "expected published Host0/PF0/no-VF with exactly one VIO pair";
	if (cfg.device_snapshot == null || cfg.resource_snapshot == null || cfg.bar_map == null)
		return 0;
	if (!get_env(0, vio_env, why) || !$cast(map, cfg.bar_map)) return 0;
	cfg.device_snapshot.list_hosts(hosts);
	cfg.device_snapshot.list_functions(functions);
	cfg.resource_snapshot.list_vio_bindings(pairs);
	if (hosts.size() != 1 || functions.size() != 1 || pairs.size() != 1) begin
		why = $sformatf(
			"expected hosts/functions/pairs=1/1/1, actual=%0d/%0d/%0d",
			hosts.size(),
			functions.size(),
			pairs.size()
		);
		return 0;
	end
	if (hosts[0].host_id != 0 || !dpu_same_function_key(functions[0], pf0) || !dpu_same_function_key(pairs[0].service_key.function_key, pf0) || pairs[0].virtio_pair_index != 0)
		return 0;
	if (!vio_env.cfg.resolve_final_service_requirement(pairs[0].service_key, requirement, why))
		return 0;
	if (!requirement.enabled || !requirement.tx_enable || requirement.rx_enable ||
		requirement.behavior.num_queue_pairs != 1 || requirement.behavior.vq_type != VQ_PACKED ||
		requirement.behavior.queue_size != 256 || requirement.completion_mode != VIRTIO_COMPLETION_POLLING ||
		!requirement.notify_layout_valid || requirement.notify_bar != 0 || requirement.notify_base != 0 ||
		requirement.notify_stride != 0 || requirement.notify_encoding != VIO_NOTIFY_DPU32) begin
		why = $sformatf(
			{
				"expected enabled Packed256/Polling/TX-only/1pair, BAR0+0 DPU32 Notify; ",
				"actual enabled=%0b tx/rx=%0b/%0b pairs=%0d type=%s size=%0d completion=%s ",
				"notify_valid=%0b bar=%0d base=%h stride=%h encoding=%s"
			},
			requirement.enabled,
			requirement.tx_enable,
			requirement.rx_enable,
			requirement.behavior.num_queue_pairs,
			requirement.behavior.vq_type.name(),
			requirement.behavior.queue_size,
			requirement.completion_mode.name(),
			requirement.notify_layout_valid,
			requirement.notify_bar,
			requirement.notify_base,
			requirement.notify_stride,
			requirement.notify_encoding.name()
		);
		return 0;
	end
	if (!cfg.bar_map.resolve_name("h0.pf0.bar0", target, why)) return 0;
	name = dpu_function_key_name(pf0);
	why  = "expected actual PF0 EP route requester=0/intel_pf=0/no-VF/vport=0";
	if (!cfg.frozen_functions.exists(name)) return 0;
	function_policy = cfg.frozen_functions[name];
	if (!map.get_route(target, route, why)) return 0;
	if (route.pf_index != 0 || route.is_vf ||
		function_policy.mode != DPU_HOST_EP || function_policy.requester != 0 ||
		function_policy.intel_pf != 0 || function_policy.intel_vf != -1 || function_policy.vport != 0)
		return 0;
	// EP requester 编码与资源分配的 PCI BDF 独立；允许 bdf_first=16 等真实分配起点。
	if (!map.resolve_requester(0, 0, requester_owner, requester_pcie_id, why)) return 0;
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
	function_policy.bdf_index   = 0;
	function_policy.ecrc        = 0;
	function_policy.vdpa        = 0;
	cfg.function_policies[name] = function_policy;
	cfg.frozen_functions[name]  = function_policy;

	fixed_layout(DPU_TABLE_BDF, 'h100000, 'h8000, 4, 128, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_NOTIFY, 'h080000, 'h20000, 16, 512, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_Q2TC, 'hb00000, 'h10000, 4, 2048, DPU_INDEX_GLOBAL_QPAIR);
	fixed_layout(DPU_TABLE_N2G, 'hb00000, 'h12000, 4, 1024, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_G2P, 'hb00000, 'h14000, 4, 1024, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_SPWRR, 'hb00000, 'h16000, 4, 1024, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_TC_WEIGHT, 'hb00000, 'h18000, 4, 1024, DPU_INDEX_EXPLICIT);
	fixed_layout(DPU_TABLE_VTX, 'h880000, 'h10000, 16, 2048, DPU_INDEX_GLOBAL_QPAIR);
	cfg.table_layouts[DPU_TABLE_VTX].indirect     = 1;
	cfg.table_layouts[DPU_TABLE_VTX].data_port    = 'h134;
	cfg.table_layouts[DPU_TABLE_VTX].control_port = 'h130;
	cfg.table_layouts[DPU_TABLE_VTX].index_mask   = 'h7ff;
	cfg.table_layouts[DPU_TABLE_VTX].trigger_mask = 'h2000;
	cfg.frozen_layouts[DPU_TABLE_VTX]             = cfg.table_layouts[DPU_TABLE_VTX];

	policy = '{
		service_key: pairs[0].service_key,
		prefetch_ram: "",
		net_stride: 1,
		eth_ports: 8,
		notify_net_pair5: 1,
		notify_table_base_provided: 1,
		default: 0
	};
	cfg.vio_policies[dpu_service_key_name(policy.service_key)] = policy;
	cfg.frozen_policies = cfg.vio_policies;
	why = "";
	return 1;
endfunction
```
