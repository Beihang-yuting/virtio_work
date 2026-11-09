# DPU 配置下沉与 Notify 使能 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:executing-plans` to implement this plan task-by-task. 当前侧会话采用串行执行，不创建 worktree，不启动子代理。步骤用复选框记录，未执行的编译或仿真不得标为通过。

**Goal:** 将已确认的 project 公共配置收敛到 `dpu_common`，精简参考 env/env_cfg，并在 VIO/RDMA Notify 表后增加 `BAR + 0x80044 = 1` 的 DWORD 写。

**Architecture:** DPU 核心持有资源和硬件表数据，PCIe 集成层通过原生 `pcie_tl_reg_seq` 发送，VIO 导出实际 ring 信息并管理其生命周期。用户 env_cfg 直接组合三个子 cfg，公共 seq 不依赖用户 env_cfg 的类型。

**Tech Stack:** SystemVerilog、UVM 1.2、VCS、AIP、原生 PCIe TL、Intel bind。

**Spec:** [已确认设计](../specs/2026-11-09-dpu-config-consolidation-design.md)。所有代码同时遵守 `/home/ryan/workspace/ryan/AGENTS.md`。

## Global Constraints

- 所有仿真在 `10.11.10.53` 执行，加载 `~/.bashrc` 中的工具和许可证环境。
- Notify 使能偏移为 `64'h0008_0044`，数据为 `32'h0000_0001`，完整写 4 字节；不再次叠加模块偏移，不添加 bank 位。
- 参数路径保留 `dpu.*`、`vio.*`、`pcie_cfg.*`；命令名称保留 `reg_acc`、`dut_config`、`load_params`。
- 类内 extern、类外实现；声明和主要语句逐行，类型与变量名使用 Tab，注释描述具体职责和边界。
- 一份资源结果、一份参数采样结果；DPU 核心不 import PCIe/VIO，公共 seq 不持有用户完整 env_cfg。
- 当前工作区已有发包、恢复参数和日志等未提交修改；实施以这些内容为基线，不 reset、覆盖或重新从 HEAD 生成整文件。
- 现有每 100 笔 DWORD 写后的 AF 状态读保留。posted write 发送完成不等于 DUT 状态已经生效。
- 不引入 SVT、PCIe 建链、global_cfg、配置空间枚举或第二套 Host memory 分配器。
- 本计划不授权推送远程；每阶段保留可审查差异，提交时只包含本任务文件及相关片段。

## 文件职责与接口约定

下文路径以 `/home/ryan/workspace/ryan` 为根。已有函数的搬迁以当前源码为准，字段位宽、地址和行为不重新推导；代码块给出新增接口、必要差异和关键断言。

| 文件 | 职责 |
| --- | --- |
| `dpu_common/src/dpu_env_cfg.sv` | 原 DPU cfg 加 project 的 DPU 输入构建、布局、表项生成和公共资源查询 |
| `dpu_common/src/dpu_table_types.sv` | 公共表 entry、layout、context、scope；不含 PCIe 类型 |
| `dpu_common/src/dpu_vio_table_types.sv` | VTX/VRX/Notify 硬件字段及 VIO 导出的中性队列值 |
| `dpu_common/src/dpu_bar_map.sv` | Function/BAR 名称、范围及快照查询 |
| `dpu_common/integration/pcie/dpu_pcie_pkg.sv` | 可选 PCIe 集成编译入口 |
| 同目录 `dpu_pcie_bar_map.sv` | RC sequencer 绑定、Intel 路由值与共享 BAR 查询的关联 |
| 同目录 `dpu_cfg_seq.sv`、`dpu_bar_reg_seq.sv` | 公共写表流程、独立 BAR 相对读写 |
| `virtio_work/integration/dpu/virtio_dpu_pkg.sv` | VIO 生命周期与 PCIe/DPU 集成入口 |
| 同目录 `vio_dpu_cfg_seq.sv`、`vio_pcie_rc_driver.sv` | VIO 薄配置 seq、带 VIO 接收路径的 RC driver |
| `virtio_work/integration/project/project_env*.sv` | 用户可以参考的组件组装和配置组合 |

`project_*` 硬件值类型迁移为对应 `dpu_*` 名称，`PROJECT_*` 表类别迁移为 `DPU_TABLE_*`，不改变编码值。`project_table_context_t` 缩为 `dpu_table_ctx_t`，`project_config_record_t` 缩为 `dpu_table_item_t`。

`project_dpu_setup` 中的只读 Function 查询并入 `dpu_env_cfg`，查询现有快照；不为了更名再创建一个平行 setup 对象。`dpu_cfg_scope` 只保存 Function、BAR、service 选择条件和所属快照引用。公共表按 Function/BAR 筛选，队列表按 service 筛选，保留非连续 Host/service 的选择能力。

## Task 1：先独立完成 Notify 后置使能

**Files:**

- Modify: `virtio_work/integration/project/project_dut_config_seq.sv`
- Test: `virtio_work/integration/project/tests/project_external_contract_test.sv`
- Test: `virtio_work/integration/project/tests/project_external_integration_test.sv`
- Docs: `virtio_work/integration/project/README.md`

**Interfaces:** 复用现有 `configure_public()`、`configure_queues()`、`dispatch_record()`、`mmio()`。新增公共单项使能 task，之后随 seq 一起迁移：

```systemverilog
// 对已完成写表的管理 BAR 写使能；失败返回，不自行轮询或维护跨调用状态。
extern virtual task enable_notify(
	input project_bar_target_t	target,
	output bit			ok,
	output string			why
);
```

- [x] 在已有 `check_writes()` 的表项比对之后，按 Notify 记录的 `ctx.target.canonical_name` 去重，检查每个目标随后恰有一笔使能写。期望直接使用规格常量，不调用生产地址生成函数：

```systemverilog
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
```

这里 `m`、`target` 分别是捕获到的 `pcie_tl_mem_tlp` 与所选记录的 `project_bar_target_t`。现有逐 DWORD 比对继续验证表项在使能前，最后仍检查捕获游标等于实际笔数。

- [x] 在 VCS 主机运行 `project_external_contract_test +PROJECT_SMALL`，确认修改后的检查因缺少使能写而失败，保留日志。
- [x] 将 `configure_public()`、`configure_queues()` 中重复的记录执行循环提取为一个 `write_records(input project_config_record_t batch[$], output bit ok, output string why)`。在首笔写前执行现有记录检查，收集本批 Notify 管理目标并检查 `0x80044` 的 4 字节范围。只收集 `PROJECT_NOTIFY` 和 `PROJECT_RDMA_NOTIFY`。
- [x] 在全部记录成功发送后，按本批目标列表调用 `enable_notify()`；空列表不写，任一步失败立即返回。该列表是 task 局部变量，不保存到 cfg。
- [x] `enable_notify()` 只复用现有 MMIO helper：

```systemverilog
logic [127:0]	unused_readback;

mmio(
	target, 1, 64'h0008_0044,
	4, 128'h1, 0, unused_readback, ok, why
);
```

- [x] 更新 bare 配置测试，检查使能出现在最后一个 Notify DWORD 后、QSCH/队列配置前；新增写继续计入既有 AF 同步计数。
- [x] 执行本文“验证命令”中的 Notify 组。增加同 target 多 owner、不同 target、空选择及故障注入检查；表写失败时捕获记录中不得出现使能，使能失败时 seq 不得成功。复用现有 `project_config_fault_seq` 的指定请求拒绝能力，不新增生产错误开关。

当前 VIO 单 bank 目录要求一个管理窗口，此约束保持；多 target 的正例使用 RDMA 独立入口，VIO 的多个管理窗口仍在写入前拒绝。
- [x] 文档写明这是每批一次使能；本阶段保持旧类型名称，形成可单独审阅和回退的差异。

## Task 2：抽出公共表类型和唯一 BAR 查询

**Files:**

- Create: `dpu_common/src/dpu_table_types.sv`、`src/dpu_vio_table_types.sv`、`src/dpu_bar_map.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Move/update consumers: `virtio_work/integration/project/project_dut_config.sv`、`project_vio_config.sv`、`project_bar_registry.sv`
- Test: `virtio_work/integration/project/tests/project_bar_registry_test.sv`
- Create test: `dpu_common/tests/dpu_table_types_test.sv`

**Interfaces:** `dpu_bar_target_t` 保留 Function/BDF/global Function、BAR 租约、规范名称和快照引用；移除 `rc_slot`、`pcie_tl_cq_route_t`，由 PCIe 子类查询。公共 BAR 查询接口为：

```systemverilog
extern function bit resolve_name(
	input string			name,
	output dpu_bar_target_t		target,
	output string			why,
	input bit			has_access_host = 0,
	input int unsigned		access_host = 0
);

extern function bit check_range(
	input dpu_bar_target_t		target,
	input bit [63:0]			byte_offset,
	input bit [63:0]			width_bytes,
	output bit [63:0]		address,
	output string			why
);
```

- [x] 将当前硬件 packed entry 原样搬迁并改名；不使用旧 plan 的 pack 函数重写字段。增加独立 DPU 测试 module，使用 UVM fatal 检查下列关系后 `$finish`：

```systemverilog
if ($bits(dpu_bdf_entry_t) != 32 ||
	$bits(dpu_msix_linear_entry_t) != 64 ||
	$bits(dpu_vtx_entry_t) != 128 ||
	$bits(dpu_vrx_entry_t) != 128 ||
	$bits(dpu_vio_notify_entry_t) != 128) begin
	`uvm_fatal("DPU_TABLE_TYPES", "hardware table widths changed")
end
```

- [x] 从 registry 搬迁名称解析、租约查询、完整范围及打印逻辑。基础 `freeze()` 不再要求 PCIe 路由；实际发送前的路由完整性仍由 PCIe 子类检查。
- [x] 把公共类型 include 放到既有身份、租约和快照类型可见的位置；`dpu_cfg_scope` 与 cfg 的类前向声明按依赖顺序安排，避免双向 include。
- [x] 运行不含 PCIe/VIO 的 DPU 类型编译和仿真；原 BAR 测试仍覆盖多 Host 重地址、VF 身份、BAR2、越界、64 位溢出和未知值拒绝。
- [x] 更新当前 project 的引用，删除已搬迁的重复定义；允许逐阶段编译入口调整，但最终不能在两个 package 定义同一套 entry。

## Task 3：公共 cfg 接管输入构建、布局和表生成

**Files:**

- Create: `dpu_common/src/dpu_env_cfg.sv`
- Modify: `dpu_common/src/dpu_device_env.sv`、`src/dpu_resource_pkg.sv`
- Modify: `virtio_work/integration/project/project_env_cfg.sv`
- Test: `dpu_common/tests/dpu_device_resolver_test.sv`、`tests/dpu_resource_resolver_test.sv`
- Test: `virtio_work/integration/project/tests/project_external_config_test.sv`

**Interfaces:** `dpu_env_cfg` 保留 `device_cfg`、`placement_cfg`，接管 `device_snapshot`、`resource_snapshot`、`bar_map`、公共策略和表记录。公共查询直接在此对象执行：

```systemverilog
extern function void load_params(input string path = "dpu");
extern function void list_functions(output dpu_function_record_t records[$]);
extern function bit get_function(
	input dpu_function_key_t	key,
	output dpu_function_record_t	record
);
extern function bit public_records(
	input dpu_table_kind_e		kind,
	input dpu_cfg_scope		scope,
	output dpu_table_item_t		selected[$],
	output string			why
);
extern function bit set_queues(
	input dpu_vio_queue_t		queues[$],
	output string			why
);
extern function bit queue_records(
	input dpu_cfg_scope		scope,
	input dpu_table_kind_e		kinds[$],
	output dpu_table_item_t		selected[$],
	output string			why
);
```

`dpu_vio_queue_t` 在 Task 2 的类型文件声明，字段见 Task 5。`set_queues()` 只接收实际导出值、检查其快照身份并更新表生成输入，不分配资源或再次读取参数。

- [x] 将原 DPU cfg 从 env 文件拆出；更新其 config_db 类型及现有测试构造点，不创建另一个包住旧 cfg 的对象。
- [x] 从 project 搬迁 `make_host_template()`、`make_function()` 和 Host/PF/VF 循环。`load_params()` 读取规模和输入但不抢先解析资源；VIO service 需求交付后才由已有 resolver 分配一次。
- [x] 搬迁 `load_platform_params()` 中的硬件字段、`use_driver_reference_layouts()`、`make_context()`、`public_records()`、消息表生成及 Function 查询。Intel 专属 slot/sideband 处理留给 Task 4。
- [x] 参数内部更名使用局部变量保持外部键，例如：

```systemverilog
longint unsigned	hosts;

`aip_int(path, longint unsigned, hosts, this.hosts)
this.hosts = hosts;
```

参数进入窄字段前保留现有范围检查；不得先 cast 截断后再检查。已有 AIP 无符号检查宏可以继续复用，不重复实现解析。

- [x] 比对相同固定输入下的 Function/BDF/BAR、qpair、vector 列表；检查子对象读取不再次消耗随机参数。
- [x] 更新缺失布局诊断：表名、owner、target、缺失字段、配置入口逐行输出。验证原 missing-layout 用例仍拒绝且不发后续写。

## Task 4：配置 seq 和 PCIe 路由脱离 project cfg

**Files:**

- Create: `dpu_common/integration/pcie/dpu_pcie_pkg.sv`、`dpu_pcie_bar_map.sv`、`dpu_cfg_seq.sv`、`dpu_bar_reg_seq.sv`
- Create: `dpu_common/filelists/dpu_pcie.f`
- Migrate: `virtio_work/integration/project/project_dut_config_seq.sv`、`project_pcie_reg_seq.sv`
- Test: `virtio_work/integration/project/tests/project_pcie_reg_test.sv`
- Compile consumer: `pcie_work/pcie_dpu_integration/src/pcie_dpu_reg_executor_base.sv`

**Interfaces:** `dpu_pcie_bar_map extends dpu_bar_map` 持有 Host→slot、RC sequencer 和 Intel/requester 路由；DPU cfg 与 RC driver 引用此同一对象。seq 从 sequencer 获取 `dpu_cfg` 并 cast BAR map，不引入第二份 transport cfg：

```systemverilog
if (!uvm_config_db#(dpu_env_cfg)::get(
	m_sequencer, "", "dpu_cfg", cfg
) || cfg == null) begin
	`uvm_fatal("DPU_CFG_SEQ", "PCIe sequencer has no dpu_cfg")
end
```

- [x] PCIe map 搬迁现有 `bind_host()`、`bind_function()`、`route_memory()`、`route_completion()`，增加 RC sequencer 句柄绑定；不分配 BAR 或 Host memory。
- [x] 保留公共 MMIO、DWORD 写、间接端口、AF 同步和 Task 1 使能逻辑，改为查询 PCIe map 中的实际 RC；移除对 `project_env_cfg` 的依赖。

`dpu_pcie_bar_map` 中的 sequencer 绑定使用 `uvm_sequencer #(pcie_tl_tlp)`，发送 helper 根据 target 的 Host/segment 查询实际 slot，不把这些字段重新加入核心 BAR 类型。VIO 接入的生命周期 hook 固定为以下两个接口，公共基类默认成功返回，具体 VIO 行为由 Task 5 实现：

```systemverilog
extern virtual task prepare_queues(
	output bit	ok,
	output string	why
);
extern virtual function void commit_queues(
	output bit	ok,
	output string	why
);
```

`prepare_queues()` 位于公共表配置之后、Notify 之前；`commit_queues()` 仅在写表、使能及所选验证均成功后调用。基类已有 `success/error_msg` 负责本次执行结果，不增加跨 sequence 状态机。
- [x] `dpu_bar_reg_seq extends pcie_tl_reg_seq` 继续把用户 `addr` 当 PF0 BAR0 内偏移，保留 len/mask/wdata/check_read_data/rdata/status/error_msg；不原地累加 `addr`，不重复分配请求地址。
- [x] 将纯转发 `user_configure_*` 合并进对应的 virtual `write_*`。同步修改现有派生测试的 override 名称；保留独立类别批量入口及真正有平台行为的 hook。
- [x] 运行寄存器访问测试和 BAR 路由测试；通过 PCIe 集成包的独立编译证明它不需要 VIO。原生 `pcie_tl_pkg` 不添加 DPU import。

## Task 5：VIO 导出实际队列，保留薄生命周期连接

**Files:**

- Modify: `virtio_work/virtio_net_vip/src/env/virtio_net_env.sv`
- Modify: `dpu_common/src/dpu_vio_table_types.sv`、`src/dpu_env_cfg.sv`
- Create: `virtio_work/integration/dpu/virtio_dpu_pkg.sv`、`vio_dpu_cfg_seq.sv`、`vio_pcie_rc_driver.sv`
- Migrate: `virtio_work/integration/project/project_pcie_rc_driver.sv`
- Test: `virtio_work/virtio_net_vip/tests/virtio_external_configuration_test.sv`
- Test: `virtio_work/integration/project/tests/project_external_contract_test.sv`

**Interfaces:** `dpu_vio_queue_t` 是实际硬件配置值，包含现有 `dpu_service_key_t`、`dpu_vio_qpair_binding_t`、generation、TX/RX、packed/custom 对应的 `virtio_mode`、完成模式的 `msix_enable`、queue_size、allocated_qpairs、desc_iova、notify_address、notify_bar_base、notify_bar_size、local_qid。公共表不再借用 `vio_external_setup` 对象。

VIO 新增只读导出函数，setup/scope 的有效性继续由 VIO 检查：

```systemverilog
extern function bit export_dpu_queues(
	input vio_external_setup	setup,
	input vio_config_scope		scope,
	output dpu_vio_queue_t		queues[$],
	output string			why
);
```

- [x] 在导出测试中逐项断言 `desc_iova` 等于实际 setup 的值，`virtio_mode` 等于 `queue_type == VQ_PACKED`，qpair/vector 不变；重复导出前后 setup/队列数量不变，PCIe/VIO 共用同一 Host manager；BAR 由独立租约/事务检查覆盖，收尾 leak_check 通过。未为测试新增生产分配计数 API。
- [x] 将实际 ring 记录的字段逐一赋给中性类型，禁止用 `vio_cfg.queue_size` 或地址模板替代已分配结果。
- [x] 将 project 的 Notify 排序和 VTX/VRX/QSCH 生成迁入公共 cfg，输入改为上述值队列。预取 RAM 冲突检查基于所有已导出的活动 RX service 和已冻结策略，局部 scope 不重新分配 RAM。
- [x] `vio_dpu_cfg_seq extends dpu_cfg_seq` 只 override `prepare_queues()` 与 `commit_queues()`，连接准备、导出、确认与 VIO 选择。Host 的 VIO env 句柄以 `vio_env_h%0d` 为 config_db 字段名发布并借用；不新建 lifecycle manager 或额外 cfg。

`virtio_net_env` 已有 `local vio_external_setup live_external_setup`。继续由它持有当前 setup，增加只读 `function vio_external_setup get_external_setup()` 返回该借用句柄供收尾使用，不在 DPU cfg 保存第二份 VIO 生命周期对象。释放仍走原来的 `release_external_resources()`，成功后清除 cfg 中对应 Host 的导出队列值及派生记录。
- [x] 把包含 `virtio_iommu_model`、`virtio_pcie_iova_host_mem_proxy` 的 RC 接收代码移到 `vio_pcie_rc_driver`。其路由查询委托同一 `dpu_pcie_bar_map`，保留 MSI-X catalog 更新和实际 DMA 路径。
- [x] 运行 packed/custom × polling/MSI-X 的现有合同测试，以及双 Host、非连续 qpair、释放再准备测试。失败时不确认 ring，不把配置失败当成功发包入口。

## Task 6：参考 env/cfg 瘦身与宏注册

**Files:**

- Modify: `virtio_work/integration/project/project_env_cfg.sv`、`project_env.sv`、`project_env_pkg.sv`、`project_base_test.sv`、`project_single_queue_config_seq.sv`
- Modify: `virtio_work/filelists/project_integration.f`
- Test: `virtio_work/integration/project/tests/project_env_smoke_test.sv`
- Test: `virtio_work/integration/project/tests/project_external_integration_test.sv` 中的 `project_runtime_params_test`

**Interfaces:** 用户 cfg 保持三者组合。组件/VIF/Host memory 的平台绑定仍由用户 env 提供：

```systemverilog
dpu_env_cfg		dpu_cfg;
virtio_net_env_config	vio_cfg;
pcie_tl_env_config	pcie_cfg;

uvm_config_db#(dpu_env_cfg)::set(
	this, "pcie_env.*", "dpu_cfg", cfg.dpu_cfg
);
```

- [x] 从参考 cfg 删除已迁移的表字段、布局和生成方法；保留子 cfg 创建和按顺序调用，避免原样换名后保留大 cfg。
- [x] 参考 env 保留 Host memory、RC/Intel VIF、VIO 组件连接和句柄发布。既有 `dpu_device_env` 的快照发布能力继续使用，不要求用户 env 继承它。
- [x] 将 `project_load_params_command` 的无参校验及 status/result_out 处理移到参考包的单个命令 task；它只借用已登记的参考 env 实例。用 `aip_cmd_task` 注册，不手写命令适配类：

```systemverilog
`aip_cmd_task(load_params, project_load_params)
```

包级 `project_load_params()` 每次用 `aip_cmd::get_handle("load_params")` 取得命令句柄，重置输出；`args_in != ""` 返回 status=1。其余路径调用已有 `load_params(ok, why)`，写入 `status = ok ? 0 : 1` 及对应结果。多个子 cfg 不分别注册此命令。

- [x] 保留运行期候选全部校验再提交的现有行为；数据和参数加载归各自 cfg，顶层只控制顺序。无活动 ring 的限制不扩大，不增加自动停机/在线扩容。
- [x] 用已有运行期测试检查参数重读、失败保持原值、没有额外 MMIO，随后配置 seq 使用更新值；更新 save/restore Tcl 测试的类型引用，不改用户命令名称。
- [x] 更新 base_test 的创建和配置 seq 启动示例，以及 `reg_acc` 注册示例。filelist 明确添加公共集成包，参考文件不进入核心 package。

## Task 7：清除旧布局与重复入口，保留实际通用依赖

**Files:**

- Review/modify: `dpu_common/src/dpu_vio_reg_plan_types.sv`、`dpu_vio_dataplane_plan_extension.sv`、`dpu_vio_register_plan_builder.sv`、`dpu_device_bootstrap_plan_builder.sv`、`dpu_device_env.sv`
- Review retained consumers: `pcie_work/pcie_dpu_integration/src/pcie_dpu_reg_executor_base.sv`、`pcie_dpu_tl_reg_executor.sv`
- Update tests: `dpu_common/tests/dpu_device_bootstrap_plan_test.sv`、`tests/dpu_vio_reg_plan_test.sv`
- Update references: `virtio_work/scripts/test_manifest.sh`、`filelists/tests.f`、`filelists/dpu_red_tests.f`

- [x] 搜索旧 API 的代码引用，分别标记“仍使用的通用执行接口”“被新配置 seq 替代的 DUT builder”“旧驱动模型自己的协议常量”。执行：

```bash
rg -n 'dpu_device_bootstrap_plan_builder|dpu_vio_register_plan_builder|dpu_vio_dataplane_plan_extension|DPU_VIO_NOTIFY_BANK|DPU_VIO_NOTIFY_COMMIT' \
  ../dpu_common ../pcie_work/pcie_dpu_integration virtio_net_vip integration \
  -g '*.sv' -g '*.svh' -g '*.f'
```

- [x] 删除无剩余生产调用者的旧 DUT builder/双 bank policy 和对应 env 执行入口；更新 package include。对仍有通用调用者的 `dpu_reg_executor`、`dpu_reg_plan`、`dpu_pcie_reg_executor` 保留实现，不通过空方法伪装兼容。
- [x] 原 builder 测试中资源身份、地址越界及失败停止的有效检查迁入新 cfg/seq 测试；仅验证旧地址/双 bank 的测试删除，并更新清单及静态合同检查。
- [x] 旧驱动 devmodel 的本地协议常量保留，不因注释提到旧 builder 而改其线格式。运行 `dpu_priv_driver_flow_test` 检查模型能力未被删除。
- [x] 对实际受影响的 core、PCIe 独立 executor 和完整 project 做编译；不能仅编译新的可选包就声明迁移完成。

## Task 8：最终比对、文档和代码复审

**Files:**

- Modify: `dpu_common/README.md`
- Modify: `virtio_work/integration/project/README.md`、`docs/aip_parameters.md`、`docs/vio_external_configuration_validation.md`
- Modify: `virtio_work/scripts/render_project_code.py`，重新生成 `docs/project_env_full_code.md`

- [x] 相同固定输入和种子比对 Task 1 之后与迁移完成后的 MMIO；比较 Host、目标 BAR、offset、方向、宽度、byte enable 和数据，排除日志前缀/类名差异，不忽略事务顺序。
- [x] 运行 Notify 组及迁移组测试，保存 VCS 日志、源码 revision/文件哈希、测试参数与失败用例的预期原因。模型合同测试不能描述成真实 RTL 验证。
- [x] 文档给出完整 env/env_cfg/base_test 与 filelist，示例引用真实公共实现。渲染器改为读取新源路径，不在生成文档维护另一份实现；之后执行：

```bash
python3 scripts/render_project_code.py
python3 scripts/render_project_code.py --check
git diff --check
git -C ../dpu_common diff --check
```

- [x] 复审修改目录的文件头、中文说明、extern、Tab、命名、资源所有权和错误路径；检查是否仍有纯转发类、重复 BAR 分配或第二次同键随机采样。
- [x] 最终报告逐仓库文件、行为变化、实际执行的测试、仍存在的限制与远程状态；不把计划或未执行的检查当作验证结果。

## 验证命令与判据

下面命令只在指定 VCS 主机执行。使用本任务独立源码副本和输出目录，依赖根设置为该副本的实际 checkout；不得覆盖主线程正在调试的远程目录。`AIP_CORE_ROOT` 必须包含 filelist 要求的 `src/sv/aip_core_pkg.sv`，不能将不同布局的本地 AIP 源目录直接当作它。

```bash
source ~/.bashrc
: "${DPU_COMMON_ROOT:?}"
: "${PCIE_WORK_ROOT:?}"
: "${HOST_MEM_ROOT:?}"
: "${NET_PACKET_ROOT:?}"
: "${AIP_CORE_ROOT:?}"
: "${INTEL_PCIE_ROOT:?}"

cfg_test_out=build/dpu_cfg_consolidation
mkdir -p "$cfg_test_out"
vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
  -debug_access+all \
  -f filelists/project_integration.f -f filelists/project_tests.f \
  -top project_env_tb -Mdir="$cfg_test_out/csrc" \
  -o "$cfg_test_out/simv" -l "$cfg_test_out/compile.log"
scripts/strict_log_check.sh compile "$cfg_test_out/compile.log"

"$cfg_test_out/simv" -exitstatus \
  +UVM_TESTNAME=project_external_contract_test +PROJECT_SMALL \
  +UVM_VERBOSITY=UVM_LOW -l "$cfg_test_out/notify.log"
scripts/strict_log_check.sh sim "$cfg_test_out/notify.log"
```

每条仿真异步启动并定期检查日志，保持向用户报告进展。正常场景要求进程退出成功、strict 通过、对应 PASS marker 齐全且无 UVM error/fatal；预期故障场景单列核对原因及后续无写入。

| 组 | 测试/参数 | 重点 |
| --- | --- | --- |
| Notify | `project_bare_config_test` | 默认 VIO 表后使能，AF 计数正确 |
| Notify | `project_external_contract_test +PROJECT_SMALL` | 独立 VIO 和 RDMA 入口 |
| Notify | 上项加 `+PROJECT_TWO_VFS +PROJECT_TWO_HOSTS +PROJECT_MIXED +PROJECT_ETS` | 管理 target 去重、Host/owner 区分 |
| Notify | Task 1 增加的空选择及指定请求故障检查 | 没有提前使能或假成功 |
| 迁移 | `project_bar_registry_test`、`project_pcie_reg_test`、`project_env_smoke_test` | 地址共享、reg_acc、组件绑定 |
| 迁移 | 合同测试的 `PROJECT_CUSTOM`、`PROJECT_MSIX` 四种组合 | 实际队列格式与中断配置 |
| 迁移 | `project_runtime_params_test`、已有 save/restore Tcl 场景 | 命令宏注册和现有重载能力 |
| 迁移 | DPU 解析/资源测试、PCIe 独立 executor 测试、`dpu_priv_driver_flow_test` | 公共依赖与已有模型能力 |

## 执行审阅点

设计已获用户确认。此计划把 Notify 功能、公共类型、cfg、PCIe seq、VIO 连接、参考环境、旧实现删除和最终验证分为八个可审阅阶段。计划确认后按上述顺序串行实施；不再对已确认的局部命名或常规代码组织反复请求许可。


## 2026-11-09 执行结果

八阶段已完成。当前源码以本轮工作区为准，未提交或推送。公共 DPU 配置已迁移，
参考 env_cfg 为269行，env 为707行；公共 seq 不再依赖项目 cfg 类型。
`AGENTS.md` 已补充 extern、可读布局、唯一资源所有者、AIP 复用及集成边界。

验证在 `ubuntu@10.11.10.53` 的 `/tmp/dpu_cfg_sr8q0qy7` 隔离目录执行：

- DPU 核心、字段位宽、无 VIO 的 PCIe 集成及完整项目编译通过。
- DPU 六项资源/计划/executor 测试、PCIe 独立 executor、实际 TLM executor、旧私有驱动、
  外部配置参数及 Packed/Custom × polling/MSI-X 生命周期通过。
- 单队列配置为25笔 DWORD 写、1笔 AF 读；双 Host/多 VF 混合合同有7125项检查，
  包含实际 ring 导出/共享内存、RDMA 多目标 Notify、去重/空批次及发送失败。
- 最终实现与“已加 Notify 使能、尚未迁移”的基线逐笔比对：Packed27、Custom27、
  32对队列653、MSI-X4236笔，Host/BAR/offset/方向/宽度/BE/payload及顺序一致。
- Packed 与 Custom 均用两个独立进程执行真实 Tcl save/restore；同一 simv，
  恢复后11项 Tcl 检查通过，分别21088/21089项 SV 检查；4133写/42读，SCB零错误。
- 缺布局、VTX第二笔/VRX第五笔发送失败停止；缺布局仍返回已分配 ring 的选择范围，
  经平台停机确认后可以显式释放，strict无泄漏告警。

验证过程中的修正也保留记录：旧 executor 测试需要显式 bind_topology；32对 AF 用例
必须提供 `+dpu.caps.af_extra_queue_count=0`，没有更改默认11项能力。
寄存器命令测试刻意产生两项 SCB 数据不匹配，用精确 catcher 核对读比较开关，
单独作为预期负例接受，不把它宣称为普通 strict 零不匹配结果。

证据：`build/dpu_cfg_sr8q0qy7/` 的运行脚本、结果 JSON、远端日志、源码快照与哈希。
最后的 Tab 排版与实际编译输入逐项验证 token 等价，差异仅为空白。
16个已有发包/报文/等待实现与本轮开始时逐字节相同，没有覆盖既有修改。
本轮为 Intel VIP 模型及驱动合同验证，不替代真实 RTL 验收。
