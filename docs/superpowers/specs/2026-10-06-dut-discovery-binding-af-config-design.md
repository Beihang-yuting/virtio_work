# 真实 DUT 设备发现绑定与 AF 直配设计

## 目标

1. 把真实 DUT 的硬件身份绑定到 VIP 的设备身份注册（frozen snapshot 中的 key）上：
   run 阶段读取 DUT 的身份与资源信息，与 snapshot 逐项核对并形成绑定记录。
2. 把 VIP 的抽象配置（virtio feature、队列、中断、环类型等）自动翻译为 DUT 的寄存器配置，
   由 VIP 扮演 AF 软件直接写入，测试不再手写寄存器序列。

依赖：`2026-10-06-architecture-simplification-design.md` 的 P3 接入点
（`virtio_discovery_strategy`、`virtio_config_backend`、`virtio_driver_protocol`、`virtio_execution_profile`）。

## 依据

真实驱动：53 主机 `/home/ubuntu/wn/icpu-kernel-driver`，分支 `lance_net_mailbox`，提交 `f2c9cd6`。
本设计中所有寄存器地址、结构体字段与时序均以该提交为准，代码中标注来源文件与行号。

驱动行为摘要：

- 身份由硬件给出：PCI device ID 区分 AF/PF/VF；BAR2 `qinfo.host_id` 读出
  `{host_id[2:0], pfvf_id[6:0]}`，`srcid = host_id<<10 | pfvf_id`（`mailbox.h:60,118`，`main.c:2021`）。
- AF 声明：BAR0 `0x1010` 写魔数 `0x5555AAAA`，读回校验硬件锁存的 host_id 与 valid 位，
  再写 `0x60040`；其他 Function 读 `0x1010` 得到 AF 所在 host（`main.c:2023-2121`）。
- 资源由 AF 分配：gfid（vport/dport）、全局 MSI-X 向量、`PREQ_BDF_MAP`、global qid 与 VIO notify 表
  （`af_mng.c:632-904,1088-1155`）。
- 队列：RX ring i 的 `local_qid=2i`，TX ring i 为 `2i+1`，一对 RX/TX 共用一个 global qid；
  VRX/VTX 队列参数表按 global qid 寻址（`register.h:1936,2113`，`af_mng.c:1327,1373`）。
- 队列数量由驱动参数决定，不从设备读取。

## 已确定的决策

| 决策 | 结论 |
|---|---|
| 绑定方案 | 声明加核对：snapshot 仍在 build 阶段生成，run 阶段读硬件核对并绑定 |
| 配置下发路径 | 仅 AF 直配：VIP 对所有 Function 直接写 DPU 表，不实现 mailbox |
| 寄存器定义来源 | 在 dpu_common 现有 reg plan 基础上扩展，缺失部分按驱动补齐 |
| 环类型 `virtio_mode` | 按 service 自由选择，逐队列写入，不告警 |

## 非目标

- 不实现 PF/VF mailbox 请求与 AF 侧 mailbox 服务。
- 不做“由 DUT 自动长出拓扑”：Function 数量与形状仍来自声明或默认拓扑。
- 不实现驱动 `priv_ring=false` 的 DPU Virtio ring 数据通路（见 `examples/dpu_priv_ring/STANDARD_MODE_AUDIT.md`）。
- 不覆盖 PFC/ECN/流控、VLAN、e-label MAC 池等与 VIO 队列无关的 AF 功能。

## 架构

```
build_phase（零时刻，不变）
  dpu_device_cfg ── 用户声明，或 dpu_default_topology 按 caps 自动生成
        └→ resolver → 冻结 snapshot（key ↔ BDF/BAR/qpair/MSI-X）

run_phase，每个 Host，在驱动初始化之前：
  ① 发现       virtio_discovery_strategy::verify_snapshot
  ② 核对与绑定  dpu_identity_binder
  ③ 平台初始化  dpu_common bootstrap plan（BAR、Command、AF 声明）
  ④ 资源配置    dpu_common VIO plan（MSI-X、BDF map、notify 表）
  ⑤ 队列与特性  virtio_af_direct_backend → dpu_vio_queue_plan_builder → 执行器
  ⑥ 数据面      标准 virtio 或私有环（virtio_driver_protocol）
```

## 组件

### dpu_common 侧（独立提交，virtio_work 的 `check_deps.sh` 同步更新固定版本）

| 组件 | 职责 |
|---|---|
| `dpu_dut_caps` 扩展 | 新增 vendor ID 与按角色（AF/PF/VF）的 device ID 表，默认值取驱动 ID 表（`main.c:911-922`，vendor `0x20f9`） |
| `DPU_REG_OP_READ_CAPTURE` | 新的 reg op 类型：读取并把值写入执行报告（按 op 名索引）；现有 READ_VERIFY 不变 |
| `dpu_vio_regs.svh` | VIO 相关寄存器地址、结构体字段位置与默认值的唯一定义处，标注驱动来源 |
| `dpu_vio_queue_plan_builder` | 生成 VTX/VRX 队列参数表写入（经 staging 寄存器与 `WR_RAM_CFG`）、`CONTROL_QUEUE`、RSS group 表、`vport_fwd`、全局 RX MTU，以及对应的拆除计划 |

`dpu_vio_regs.svh` 的内容在实施计划第一步从驱动 `register.h/common.h` 提取，包括：
`VTX_QUEUE_PARA_TBL_BASE`、`DP_VRX_QUEUE_PARA_TBL_BASE`、`DP_VRX_TAIL_PNTR_ADDR`（默认 tail `0x8000`）、
VTX/VRX `wr_ram` staging 与 `WR_RAM_CFG`、TX/RX 队列复位寄存器、`vport_fwd`、RSS group 表、
`INTF_ETH*_CONFIGURATION_RX_MTU`，以及 BAR2 `qinfo.host_id` 偏移。不在 spec 中写入未经核实的数值。

### virtio_work 侧

| 组件 | 职责 |
|---|---|
| `dpu_observed_function` | 一次发现的结果：`{domain, bdf, vid, did, role, host_id, pfvf_id, bar_size[6], af_host_id}` |
| `virtio_discovery_strategy::verify_snapshot` | 对 snapshot 中每个 Function：读配置空间 VID/DID、BAR 尺寸（写全 1 读回后恢复）、BAR2 `qinfo.host_id`；对 AF 读 `0x1010`。只读不改设备状态 |
| `dpu_identity_binder` | 纯函数：输入 snapshot 与观测结果，输出 `dpu_identity_binding`（key ↔ `{bdf, srcid, gfid}`）或差异列表 |
| `virtio_dpu_cfg_map` | 配置项到寄存器的映射表，见下节 |
| `virtio_af_direct_backend` | `virtio_config_backend` 的实现：查映射表、调用 `dpu_vio_queue_plan_builder`、经 `dpu_pcie_reg_executor` 执行 |
| `dpu_default_topology` | 由 `tests/virtio_test_device_builder.sv` 移入 src：无用户配置时按 `dpu_dut_caps` 生成 AF/PF 与 N 个 VF 的默认拓扑 |

`dpu_priv_device_control` 的默认实现改为委托 `virtio_af_direct_backend`；用户仍可覆盖。

### 核对规则

| 观测项 | 期望值来源 | 不一致时 |
|---|---|---|
| VID/DID → 角色 | snapshot 中该 key 的 kind（AF/PF/VF）与 `dpu_dut_caps` 中的 ID 表 | fatal |
| BAR2 `host_id/pfvf_id` | key 的 `host_id`；`pfvf_id` 按驱动规则：VF 为 `4 + pf_id*16 + vf_idx`（`mailbox.c:2380`），PF 为 pf_id（实施计划第一步在驱动中核实后写入 `dpu_vio_regs.svh`） | fatal |
| BAR 尺寸 | `dpu_dut_caps.bar_profiles` 中对应角色的尺寸 | fatal |
| AF host | `0x1010` 锁存值等于 snapshot 中 AF 的 host | fatal |
| 多出或缺少 Function | snapshot 的 Function 集合 | fatal |

fatal 信息逐项列出 `{key: 字段 期望值 实际值}`，一次报告全部差异。

## 映射表

`virtio_dpu_cfg_map` 每条规则：`{配置项, 类别, 目标表.字段, 取值规则}`。

| 类别 | 含义 | 规则 |
|---|---|---|
| `REG_FIELD` | 写队列或 Function 级寄存器 | queue_size → `q_depth = log2(n)`；ring IOVA → `desc_addr`；队列向量 → `dma_msix`（全局向量号）；gfid → RX `dport_id` / TX `sport_id`；host → `dport_type/sport_type`；环类型 → `virtio_mode` |
| `HW_FIXED` | 硬件固定能力，没有寄存器，仅登记 | CSUM、TSO（TX `seg_en` 恒为 1，`af_mng.c:1397`）；MRG_RXBUF 不支持 |
| `GLOBAL_AF` | AF 级全局寄存器，每个 AF 写一次 | RX MTU（`RX_MAX_MTU`）、ETH 端口 RSS |
| `UNSUPPORTED` | DUT 未实现 | indirect（驱动位定义与标准不同）、动态 MQ、标准 control VQ |

规则：

- 驱动请求的 feature 与 DUT 能力取交集；请求 `UNSUPPORTED` 项时报错，不静默清除。
- 队列深度必须为 2 的幂且不超过 2^15。
- `virtio_mode` 按 service 的环类型逐队列写入，同一 AF 下允许混用。
- `local_qid` 与 global qid 的对应来自 resource snapshot 的 qpair 绑定，RX/TX 共用该 qpair。

## 下发与拆除顺序

下发（与驱动 `dpu_open` 一致）：

1. 每个 TX 队列写参数表，`queue_en=0`。
2. 每个 RX 队列写参数表，`queue_en=1`；写前读 VRX tail，必须等于默认值 `0x8000`，否则先复位该队列。
3. RSS group 表。
4. MSI-X 中断配置。
5. `CONTROL_QUEUE` 使能每个 TX 队列。
6. `vport_fwd=1`。

拆除（与驱动 `dpu_down` 一致）：`vport_fwd=0` → 每个 TX 停队、等待空闲、复位 →
每个 RX 复位脉冲 → 清 MSI-X 配置 → VIO plan 拆除（notify 表、MSI-X、BDF map）。

## MODEL 模式

- `virtio_pcie_dut_responder` 按 snapshot 生成身份：配置空间 VID/DID 与 BAR 尺寸、
  BAR2 `qinfo.host_id`、`0x1010` 的 AF 声明锁存行为。
- 新增寄存器表模型：记录 AF 直配写入的 VTX/VRX 参数表、`CONTROL_QUEUE` 与 `vport_fwd`，
  responder 的 DMA 以该表决定队列是否启用、ring 地址、深度与环类型。
  寄存器写错会直接导致数据面不通，而不是仅比对写入值。
- 同一套 ①–⑤ 流程在 MODEL 下运行，作为新组件的自测。

## 错误处理

- 核对失败：fatal，列出全部差异，不进入 ③。
- 寄存器读回校验失败：执行报告记为 FAIL，对应队列保持未启用，`configure_queue` 返回失败。
- VRX tail 非默认且复位后仍非默认：该队列配置失败。
- 拆除失败：保留该队列的内存与映射，Function 进入失败状态，与私有环现有约定一致。

## 测试

全部按 TDD：先写失败用例，再实现。新增测试全部进入 manifest。

| 层 | 用例 |
|---|---|
| 单元 | binder：完全匹配；角色不符；host/pfvf 不符；BAR 尺寸不符；多出/缺少 Function；多处差异一次报告 |
| 单元 | 映射表：每条规则的取值；请求 `UNSUPPORTED` 报错；q_depth 非 2 的幂与上限 |
| 单元 | `dpu_vio_queue_plan_builder`：写入顺序；字段位置与驱动结构体逐位比对（以 GCC 编译驱动结构体生成黄金值）；拆除计划 |
| 单元 | `READ_CAPTURE`：读值进入执行报告；READ_VERIFY 行为不变 |
| 集成 | MODEL：发现 → 核对 → AF 直配 → 标准 virtio 收发；私有环收发；同一 AF 下两种环混用 |
| 集成 | 故障：身份戳错误 → fatal 且差异完整；读回校验失败 → 队列不启用；VRX tail 非默认 → 复位后配置；拆除失败 → 资源保留 |
| 集成 | 无用户配置：`dpu_default_topology` 生成拓扑并完成上述流程 |

## 验收标准

- 上表全部测试通过，`strict_regression` 全 PASS（含新增测试）。
- 私有环测试不再需要用户实现 `dpu_priv_device_control` 即可运行。
- dpu_common 新版本固定到 `check_deps.sh`，dpu_common 自身测试通过。
- 寄存器定义只存在于 `dpu_vio_regs.svh` 一处。
