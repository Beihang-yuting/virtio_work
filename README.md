# Virtio-Net 驱动 UVM 验证 IP

面向 DPU/SmartNIC virtio 硬件加速引擎验证的 UVM virtio-net 驱动模拟组件。

工作在 PCIe Transaction Layer，模拟完整的 Guest OS virtio-net 驱动行为，通过真实的 PCIe TLP 流量对 DUT 进行协议合规性和数据正确性验证。

---

## 项目概览

| 指标 | 数值 |
|------|------|
| 源文件数 | 90 个 `.sv` 文件 |
| 代码行数 | 约 20,000 行 SystemVerilog |
| 支持规范 | virtio 1.2 / 1.3 |
| Virtqueue 类型 | Split / Packed / 自定义 |
| 验证目标 | DPU/SmartNIC virtio-net 设备端 RTL |
| EDA 工具 | Synopsys VCS（通过 `$VCS_HOME` 配置；当前固定依赖阻断编译） |

---

## 系统架构

```
virtio_net_env（顶层环境）
│
├── vf_instances[N]                          ← 每个 VF 一个完整的 virtio-net 驱动
│   ├── virtio_driver_agent                  ← UVM Agent（驱动 + 监控 + 序列器）
│   │   ├── virtio_driver                    ← 双层模式：自动状态机 + 原子操作库
│   │   └── virtio_monitor                   ← 被动 TLP 观测与协议检查
│   ├── virtqueue_manager                    ← 队列管理（split/packed/自定义）
│   ├── virtio_net_dataplane                 ← 数据面
│   │   ├── tx_engine                        ← 发送引擎（集成 net_packet 报文产生器）
│   │   ├── rx_engine                        ← 接收引擎（三种 buffer 模式）
│   │   └── offload_engine                   ← 硬件卸载（校验和/TSO/USO/RSS）
│   └── virtio_pci_transport                 ← PCIe 传输层
│       ├── pci_cap_manager                  ← PCI Capability 链表发现
│       ├── bar_accessor                     ← BAR 寄存器读写 → PCIe TLP 翻译
│       └── notification_manager             ← 中断管理（MSI-X/INTx/轮询/自适应）
│
├── pf_manager                               ← SR-IOV PF/VF 管理（复用 pcie_tl_vip）
├── iommu_model                              ← IOMMU 地址翻译 + 权限检查 + 故障注入
├── wait_policy                              ← 统一的超时与轮询等待框架
├── perf_monitor                             ← 性能监控（带宽限制 + 延迟剖析）
├── scoreboard                               ← 记分板（8 类检查项）
├── coverage                                 ← 覆盖率（8 组 covergroup）
│
├── host_mem_manager（外部组件）               ← Buddy Allocator 内存后端
├── net_packet（外部组件）                     ← 协议报文产生器（L2-L4 + 隧道）
└── pcie_tl_env（外部组件，作为子环境）         ← PCIe TL 层 VIP
```

---

## 核心特性

### 一、双层驱动模型

VIP 提供两种驱动模式，可在运行时切换：

| 模式 | 说明 | 适用场景 |
|------|------|---------|
| **自动模式（AUTO）** | 全自动状态机驱动，从设备发现到数据面运行一键完成 | 功能回归、冒烟测试 |
| **手动模式（MANUAL）** | 原子操作库，逐步控制每一个驱动操作 | 异常注入、边界测试 |
| **混合模式（HYBRID）** | 初始化用自动模式，数据面用手动模式 | 灵活组合 |

### 二、完整的 virtio 初始化流程

整个初始化序列严格按照 virtio 规范执行，每一步都通过真实的 PCIe TLP 完成：

```
PCIe BAR 枚举 → Capability 发现 → 设备复位（写 status=0，轮询确认）
→ 设置 ACKNOWLEDGE → 设置 DRIVER → Feature 协商（64 位读写）
→ 设置 FEATURES_OK（回读确认设备未拒绝）→ 队列配置
→ MSI-X 中断配置 → 设置 DRIVER_OK → RX Buffer 预填充 → 数据面运行
```

### 三、三种 Virtqueue 实现

通过抽象基类（`virtqueue_base`）定义统一接口，三种实现通过策略模式切换：

| 类型 | 说明 | 特点 |
|------|------|------|
| **Split Virtqueue** | 标准分离式队列 | 描述符表 + Available Ring + Used Ring，三段独立内存 |
| **Packed Virtqueue** | 紧凑型单 Ring 队列 | AVAIL/USED 标志位嵌入描述符，wrap counter 机制 |
| **Custom Virtqueue** | 用户自定义格式 | 通过回调接口扩展，支持厂商私有描述符格式 |

### 四、全量 Feature 支持

所有 Feature 可通过配置按场景裁剪：

**数据面 Feature**：
- `MRG_RXBUF` — 多 buffer 合并接收
- `MQ` + `CTRL_MQ` — 多队列（RSS/队列对数配置）
- `CSUM` / `GUEST_CSUM` — 硬件校验和卸载
- `HOST_TSO4/6` / `GUEST_TSO4/6` — TCP 分段卸载
- `HOST_USO` / `GUEST_USO4/6` — UDP 分段卸载（1.2 新增）
- `RSS` / `HASH_REPORT` — RSS 分流与哈希上报
- `RING_PACKED` — Packed Virtqueue
- `INDIRECT_DESC` — 间接描述符表
- `EVENT_IDX` — 事件索引通知抑制
- `IN_ORDER` — 按序完成
- `NOTIFICATION_DATA` — 扩展通知数据（1.2 新增）

**控制面 Feature**：
- `CTRL_VQ` + `CTRL_RX` — 混杂/全组播/单播/组播 MAC 过滤
- `CTRL_VLAN` — VLAN 过滤
- `CTRL_ANNOUNCE` / `STATUS` — 链路状态通告 + ARP 公告
- `MTU` / `SPEED_DUPLEX` — MTU 和速率/双工上报
- `MAC_TABLE` — 单播/组播 MAC 表管理

**高级 Feature**：
- **SR-IOV** — 完整 PF/VF 生命周期（创建/配置/FLR/热迁移）
- `RING_RESET` — 单队列复位（1.2 新增）
- `STANDBY` — 主备切换（failover）
- **热迁移** — 队列状态冻结/恢复 + 脏页追踪
- **Admin VQ** — PF 级 VF 管理队列（1.2 新增）

### 五、全方位错误注入

| 层级 | 注入类型 |
|------|---------|
| **Virtqueue 层** | 循环描述符链、越界 index、零长度 buffer、内存屏障跳过、描述符 double-free、use-after-free、avail ring 溢出 |
| **PCIe 传输层** | 设备状态转换违规、Feature 协商异常、队列配置错误、通知错误（虚假中断/丢失中断） |
| **IOMMU 层** | 地址未映射、权限不足、use-after-unmap、可编程故障规则（按 BDF/地址范围/方向/触发次数） |
| **数据面** | 错误校验和、超 MTU 包、零长度包、截断包 |

### 六、性能监控

- **带宽限制**：同步令牌桶算法（无后台任务），支持运行时动态调整限速
- **延迟剖析**：7 阶段逐包时间戳（描述符填充→kick→设备处理→used 回写→中断→poll→完成）
- **统计报告**：TX/RX 包数、字节数、吞吐率，per-VF 和全局两个维度

---

## 目录结构

```
virtio_net_vip/
├── src/                                    ← 源代码（90 个文件）
│   ├── virtio_net_pkg.sv                   ← 顶层 Package（包含所有源文件）
│   ├── types/                              ← 类型定义
│   │   ├── virtio_net_types.sv             ← 所有枚举、结构体、Feature 位定义
│   │   ├── virtio_net_hdr.sv              ← virtio_net_hdr 打包/解包工具类
│   │   └── virtio_transaction.sv           ← UVM Sequence Item
│   ├── shared/                             ← 共享工具
│   │   ├── virtio_wait_policy.sv           ← 等待策略框架（三种等待方法）
│   │   └── virtio_memory_barrier_model.sv  ← 内存屏障建模
│   ├── iommu/                              ← IOMMU 模型
│   │   └── virtio_iommu_model.sv           ← 地址翻译 + 权限 + 故障注入
│   ├── virtqueue/                          ← 虚拟队列
│   │   ├── virtqueue_base.sv               ← 抽象基类（18 个纯虚方法）
│   │   ├── split_virtqueue.sv              ← Split 实现（约 500 行）
│   │   ├── packed_virtqueue.sv             ← Packed 实现（约 750 行）
│   │   ├── custom_virtqueue.sv             ← 自定义扩展
│   │   ├── virtqueue_manager.sv            ← 队列工厂与生命周期管理
│   │   └── virtqueue_error_injector.sv     ← 队列错误注入器
│   ├── transport/                          ← PCI 传输层
│   │   ├── virtio_pci_regs.sv              ← Common Config 寄存器偏移常量
│   │   ├── virtio_bar_accessor.sv          ← BAR 读写 → PCIe TLP 翻译
│   │   ├── virtio_pci_cap_manager.sv       ← PCI Capability 链表发现
│   │   ├── virtio_notification_manager.sv  ← MSI-X/INTx/轮询/自适应中断管理
│   │   └── virtio_pci_transport.sv         ← 传输层顶层封装（完整初始化序列）
│   ├── agent/                              ← UVM 驱动代理
│   │   ├── virtio_atomic_ops.sv            ← 原子操作库（约 30 个方法）
│   │   ├── virtio_auto_fsm.sv             ← 自动状态机（12 状态 + 5 后台任务）
│   │   ├── virtio_driver.sv               ← UVM Driver（事务分发）
│   │   ├── virtio_monitor.sv              ← UVM Monitor（被动观测 + 协议检查）
│   │   ├── virtio_sequencer.sv            ← UVM Sequencer
│   │   └── virtio_driver_agent.sv          ← UVM Agent 顶层封装
│   ├── dataplane/                          ← 数据面
│   │   ├── virtio_tx_engine.sv             ← 发送引擎（net_packet 集成）
│   │   ├── virtio_rx_engine.sv             ← 接收引擎（三种 buffer 模式）
│   │   ├── virtio_offload_engine.sv        ← 统一 Offload 引擎入口
│   │   ├── virtio_csum_engine.sv           ← 校验和计算/验证
│   │   ├── virtio_tso_engine.sv            ← TCP 分段
│   │   ├── virtio_uso_engine.sv            ← UDP 分段
│   │   ├── virtio_rss_engine.sv            ← RSS Toeplitz 哈希 + 队列选择
│   │   ├── virtio_failover_manager.sv      ← 主备切换管理
│   │   └── virtio_net_dataplane.sv         ← 数据面顶层封装
│   ├── sriov/                              ← SR-IOV 支持
│   │   ├── virtio_pf_manager.sv            ← PF 管理（委托 pcie_tl_func_manager）
│   │   ├── virtio_vf_resource_pool.sv      ← VF 队列资源映射
│   │   └── virtio_vf_instance.sv           ← 单个 VF 实例封装
│   ├── env/                                ← 验证环境
│   │   ├── virtio_net_env_config.sv        ← 统一配置对象（25+ 可配参数）
│   │   ├── virtio_net_env.sv              ← 顶层环境（组件创建与连接）
│   │   ├── virtio_scoreboard.sv           ← 记分板（8 类检查）
│   │   ├── virtio_coverage.sv             ← 覆盖率收集器（8 组 covergroup）
│   │   ├── virtio_perf_monitor.sv         ← 性能监控（带宽 + 延迟）
│   │   ├── virtio_virtual_sequencer.sv    ← 虚拟序列器
│   │   ├── virtio_concurrency_controller.sv ← 并发控制器
│   │   └── virtio_dynamic_reconfig.sv     ← 动态重配置管理
│   ├── callbacks/                          ← 回调扩展点
│   │   ├── virtio_dataplane_callback.sv   ← 数据面自定义（TX 链/RX 解析/HDR 格式）
│   │   ├── virtio_scoreboard_callback.sv  ← 记分板自定义比对
│   │   └── virtio_coverage_callback.sv    ← 覆盖率自定义采样
│   └── seq/                                ← 序列库
│       ├── base/（7 个文件）                ← 基础序列（init/tx/rx/ctrl/kick/queue_setup）
│       ├── scenario/（22 个文件，9 个子目录） ← 场景序列
│       │   ├── lifecycle/                  ← 生命周期（完整循环/状态错误/Feature 错误）
│       │   ├── dataplane/                  ← 数据面（TSO/MRG_RXBUF/RSS/校验和/隧道）
│       │   ├── interrupt/                  ← 中断（自适应切换/EVENT_IDX 边界）
│       │   ├── migration/                  ← 热迁移/Failover
│       │   ├── sriov/                      ← SR-IOV（多 VF 初始化/FLR 隔离/混合队列）
│       │   ├── error/                      ← 错误注入（描述符/IOMMU/PCIe/坏包）
│       │   ├── concurrency/                ← 并发（多 VF 同时发包）
│       │   ├── dynamic/                    ← 动态变更（带流量 MQ 调整）
│       │   └── boundary/                   ← 边界（最小/最大队列/chain 满/背压/零包）
│       └── virtual/（4 个文件）             ← 虚拟序列（冒烟/全功能/多 VF/压力）
├── tests/                                  ← 测试文件
│   ├── virtio_tb_top.sv                    ← 顶层 Testbench 模块
│   ├── virtio_base_test.sv                 ← 基础测试类（默认配置）
│   ├── virtio_unit_test.sv                 ← 单元测试
│   ├── virtio_stress_unit_test.sv          ← 压力测试
│   ├── virtio_protocol_test.sv             ← 协议正确性测试
│   ├── virtio_e2e_test.sv                  ← 端到端集成测试
│   ├── virtio_full_test.sv                 ← 完整集成测试（含 Completion Bridge）
│   ├── virtio_traffic_test.sv              ← 大流量测试（1000 包）
│   └── virtio_dual_test.sv                 ← 双 VIP 互打测试（2 万包 + 带宽控制）
└── ext/                                    ← 固定版本的外部 Git submodule
    ├── host_mem       → 内存管理组件
    ├── net_packet     → 协议报文产生器
    └── pcie_tl_vip    → PCIe TL 层 VIP
```

---

## 外部依赖

本 VIP 依赖三个外部组件，通过 `ext/` 目录中的固定 Git submodule 集成，**不修改任何外部组件代码**：

| 组件 | 功能 | 主要接口 |
|------|------|---------|
| **pcie_tl_vip** | PCIe TL 层 VIP，提供 RC/EP Agent、TLM 回环、SR-IOV func_manager | `pcie_tl_env`（子环境）、`uvm_sequencer #(pcie_tl_tlp)`（RC 序列器） |
| **host_mem_manager** | Buddy Allocator 内存管理，提供分配/释放/读写/泄漏检查 | `alloc()`、`free()`、`write_mem()`、`read_mem()`、`leak_check()` |
| **net_packet** | 协议报文产生器，支持 L2-L4、隧道（VXLAN/GRE/Geneve）、RDMA、存储协议 | `packet_item`（UVM sequence item 封装） |

---

## 快速开始

### 环境要求

- Synopsys VCS（通过 `$VCS_HOME` 提供）和 UVM 1.2
- 可访问 Git submodule 远端

### 远程 UVM 验证环境

可用的远程验证机是 `ubuntu@10.11.10.53`，其 VCS 安装路径为
`/home/ubuntu/synopsys/vcs/W-2024.09-SP1`，并包含 UVM 1.2。登录后设置：

```bash
export VCS_HOME=/home/ubuntu/synopsys/vcs/W-2024.09-SP1
$VCS_HOME/bin/vcs -ID
```

访问凭据不写入仓库；使用已获授权的交互式 SSH 认证。

所有构建和测试均通过 Make 入口执行：

```bash
make bootstrap
make check-deps
make compile TEST=virtio_unit_test
make test TEST=virtio_unit_test
```

`make compile` 仅编译；`make test` 编译后运行指定测试。`scripts/test_manifest.sh`
中的 `VIRTIO_MAINTAINED_TESTS` 是回归清单和顺序的单一事实源；`make regression`
按该顺序运行 `dpu_resource_manager_test`、`dpu_reg_plan_test`、
`dpu_device_resolver_test`、`dpu_placement_test`、`dpu_resource_resolver_test`、`dpu_device_bootstrap_plan_test`、`virtio_dut_caps_test`、
`virtio_fabric_resource_test`、`virtio_unit_test`、`virtio_stress_unit_test`、
`virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_admin_vq_test`、
`virtio_migration_dirty_test`、`virtio_monitor_test`、`virtio_coverage_test`、
`virtio_e2e_test`、`virtio_full_integration_test`、`virtio_pf_lifecycle_reset_test`、
`virtio_monitor_routing_test`、`virtio_dual_test`、`virtio_smoke_test` 和
`virtio_traffic_test`，共 23 项。
`make check-deps` 会验证 submodule 固定 SHA、VCS 环境以及外部源码完整性。

`pcie_tl_vip@3e2d8c972f1baa78e073f98e8a38ad2f04db6e1a` 和
`host_mem@3b9e000d5df4d10efbb3029f43605e0362e0caca` 均为固定依赖；仅
`host_mem@3b9e000d5df4d10efbb3029f43605e0362e0caca` 提供
`host_mem_pkg.sv` 和 `host_mem_manager.sv`。filelist 在 PCIe package 前编译
`host_mem_pkg.sv`，而 `virtio_net_pkg` 在自身 package 内包含 manager。
固定 SHA 使依赖可复现；实际的 VCS 编译和动态 UVM 回归结果仍取决于运行环境。

---

## Global DPU 配置边界

`dpu_device_cfg` 与 `dpu_resource_placement_cfg` 是唯一可变的 authoring
输入：前者声明 host、PCIe domain、显式 PF/VF、可选 VF pool、BDF/BAR request、AF
和 VIO eligibility；后者声明 `virtio.qpair` profile、请求、选择策略、约束和
override。`dpu_device_env` 一次性将这两个输入解析为彼此精确关联、不可变的
`dpu_device_snapshot` 与 `dpu_resource_snapshot`，并以该 pair 创建 query-only
resource manager。VIO 只按完整 `dpu_service_key_t` 导入自己的 frozen bindings，
不 author topology、capability、BDF、BAR 或资源分配。

以下是 README 中唯一的端到端 authoring 示例。`virtio_test_device_builder` 只是
测试用 convenience；它只填充公开配置对象，不转换旧模型。为清晰起见示例写出
四个 eligible VF；生产配置也可以在显式 PF 下 author `vf_pools` template，resolver
只会从该已声明的 inventory 选择候选项。

```systemverilog
function void configure_devices(input dpu_reg_executor injected_executor);
virtio_test_device_builder b;
dpu_function_cfg pf0, vf0, vf1, vf2, vf3;
dpu_device_env_config env_cfg;
dpu_device_env_config global_cfg;
dpu_resource_placement_cfg placement_cfg;
dpu_resource_snapshot resource_snapshot;
dpu_resource_pool_config_t qpair_profile;
dpu_vio_placement_request vio_request;
dpu_service_key_t vf0_vio;
virtio_net_env_config vio_cfg;
virtio_driver_config_t vf0_behavior;
string why;

b = virtio_test_device_builder::type_id::create("b");
void'(b.add_host_domain(0, 0, 16'h0010, 16'h00ff,
                        64'h0000_0002_0000_0000,
                        64'h0000_0003_0000_0000));
pf0 = b.add_pf(0, 0, 0, DPU_ALLOC_PINNED, 16'h0010);
vf0 = b.add_vf(0, 0, 0, 0, DPU_ALLOC_PINNED, 16'h0011);
vf1 = b.add_vf(0, 0, 1, 0, DPU_ALLOC_PINNED, 16'h0012);
vf2 = b.add_vf(0, 0, 2, 0, DPU_ALLOC_PINNED, 16'h0013);
vf3 = b.add_vf(0, 0, 3, 0, DPU_ALLOC_PINNED, 16'h0014);
b.add_real_dut_bars(pf0);
b.add_real_dut_bars(vf0);
b.add_real_dut_bars(vf1);
b.add_real_dut_bars(vf2);
b.add_real_dut_bars(vf3);
b.select_af(pf0);

// Eligibility names candidate functions; it does not predeclare a service.
vf0_vio = b.allow_vio_service(vf0);
void'(b.allow_vio_service(vf1));
void'(b.allow_vio_service(vf2));
void'(b.allow_vio_service(vf3));

env_cfg = dpu_device_env_config::type_id::create("env_cfg");
env_cfg.device_cfg.copy_from(b.device_cfg);
placement_cfg = env_cfg.placement_cfg;
qpair_profile.name = "virtio.qpair";
qpair_profile.class_id = 0;
qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
qpair_profile.capacity = 2048;
qpair_profile.max_per_function = 32;
placement_cfg.profiles.push_back(qpair_profile);
vio_request = dpu_vio_placement_request::type_id::create("vio_request");
vio_request.request_id = 0;
vio_request.service_instance_id = 0;
vio_request.total_qpairs = 100;
vio_request.candidate_kind = DPU_VIO_CANDIDATE_VF_ONLY;
vio_request.device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
vio_request.ordering = DPU_PLACEMENT_CANONICAL;
placement_cfg.vio_requests.push_back(vio_request);

vio_cfg = virtio_net_env_config::type_id::create("vio_cfg");
vf0_behavior = vio_cfg.make_default_driver_config(32);
vf0_behavior.num_queue_pairs = 8;
if (!vio_cfg.add_service_config(vf0_vio, vf0_behavior, why))
  `uvm_fatal("CFG", why)

global_cfg = env_cfg;
global_cfg.executor = injected_executor;
uvm_config_db#(dpu_device_env_config)::set(
    this, "device_env", "cfg", global_cfg);
uvm_config_db#(virtio_net_env_config)::set(
    this, "device_env.env", "cfg", vio_cfg);
endfunction
```

After `dpu_device_env` completes `build_phase`, its `get_resource_snapshot()`
query returns the exact frozen resource authority declared above; VIO children
receive that same object through `uvm_config_db`.

`add_real_dut_bars()` 为每个 function 显式添加三个 request：PF0 为
BAR0/1 `DPU_BAR_DEVICE_MEMORY` 32 MiB、BAR2/3 `DPU_BAR_MAILBOX` 64 KiB、
BAR4/5 `DPU_BAR_MSIX` 64 KiB；VF0 的三对分别是 16 KiB、16 KiB 和
32 KiB。BAR2/3 是 mailbox，不是保留 aperture。AF bootstrap 从冻结
snapshot 的 PF0 BAR0 生成，其 driver-aligned `DPU_AF_DECLARATION_ADDR`
为 `0x1010`；有 executor 时由独立注入的 `dpu_reg_executor` 执行，没有
executor 时报告 `NOT_EXECUTED`，不伪报硬件成功。

Placement policy is declarative and resolves before VIO construction:
`PF_ONLY`、`VF_ONLY` 和 `PF_AND_VF` 限定候选类型；auto-minimum 选择满足
demand 的最少 eligible devices，`FIXED` 只使用 `fixed_devices`，
`ALL_ELIGIBLE` 使用全部 eligible devices。每个 `device_constraint` 以
`EXACT` 固定该 device 的 qpair count，或以 `AT_LEAST` 设置最小 count；每个
pair override 可为 owner、local pair ID 或 global qpair ID 选择 `AUTO`、
`PINNED` 或 `PREFERRED`。canonical ordering 是稳定的键序，seeded-random ordering
只在显式 seed 下可复现。

三个 ID namespace 不可混用：`request_id` 识别 authoring request，
`service_instance_id` 与 function key 共同形成 service key，`local_pair_id`
只在该 service/device 内唯一；`global_qpair_id` 是 snapshot 中跨 Fabric 的
`0..2047` ID。每个 qpair 同时表示 RX/TX pair，不为方向另取 Fabric global ID。
默认 real-DUT 上限为每个 device 32 pairs、全局 2048 pairs；profile 可以缩小，
不能扩大 snapshot capability，因此 100 pairs 至少需要四个 eligible 32-pair
devices。

解析成功后只查询 snapshots：`dpu_resource_snapshot` 提供按 request、
service/local 或 global ID 的 bindings 查询，`dpu_resource_manager` 仅以精确
snapshot pair seed 并维持只读 service lease mapping，`virtio_resource_client` 与
`virtio_vf_resource_pool` 将该 mapping 按 service key 导入且不可改绑。FLR 只复位
runtime state；已发布的 service、local/global qpair identity 和 snapshot pair
保持稳定。notify、MSI-X、port/route 和 scheduler plan builders 是这些 frozen
snapshots 的后续消费者，不是 placement authoring 或执行功能。

---

## 编写自定义测试

### 自动模式（推荐用于功能测试）

```systemverilog
class my_test extends virtio_base_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 覆盖默认配置
    virtual function void configure_default(virtio_net_env_config cfg);
        super.configure_default(cfg);
        cfg.default_num_pairs    = 4;           // 4 个队列对
        cfg.default_vq_type      = VQ_PACKED;   // 使用 Packed 队列
        cfg.default_irq_mode     = IRQ_POLLING;  // 轮询模式
        cfg.default_driver_mode  = DRV_MODE_AUTO;
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_function_instance pf_vio;
        virtio_smoke_vseq vseq;
        phase.raise_objection(this);

        // virtio_base_test declares a VIO-net service on PF0.  Per-function
        // behavior is authored by that service key; the runtime owner is the
        // corresponding PF function, not an undeclared positional VF.
        pf_vio = env.pf_instances[0].pf_function;
        vseq = virtio_smoke_vseq::type_id::create("vseq");
        vseq.vf_seqr = pf_vio.driver_agent.sequencer;
        vseq.start(env.v_seqr);

        phase.drop_objection(this);
    endtask
endclass
```

### 手动模式（用于精细化测试）

```systemverilog
// 逐步控制每个驱动操作
virtio_transaction req = virtio_transaction::type_id::create("req");

// 步骤 1: 设置 ACKNOWLEDGE
req.txn_type  = VIO_TXN_ATOMIC_OP;
req.atomic_op = ATOMIC_SET_STATUS;
req.status_val = DEV_STATUS_ACKNOWLEDGE;
start_item(req, , seqr); finish_item(req);

// 步骤 2: 设置 DRIVER
req.status_val = DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER;
start_item(req, , seqr); finish_item(req);

// 步骤 3: 配置队列
req.txn_type  = VIO_TXN_SETUP_QUEUE;
req.queue_id  = 0;
req.queue_size = 256;
req.vq_type   = VQ_SPLIT;
start_item(req, , seqr); finish_item(req);
```

### 自定义 Virtqueue 格式扩展

```systemverilog
// 继承回调基类，实现厂商私有描述符格式
class my_custom_cb extends virtqueue_custom_callback;
    virtual function void custom_alloc_rings(custom_virtqueue vq);
        // 自定义内存布局
    endfunction

    virtual function int unsigned custom_add_buf(custom_virtqueue vq, ...);
        // 自定义描述符填充逻辑
    endfunction
endclass
```

---

## 与 DUT 对接

### TLM 模式（回环测试，无需 RTL）

```
virtio 驱动 VIP → PCIe RC Agent → TLM 回环 → EP Agent（自动响应）
```

该模式面向 VIP 自身验证和功能开发。运行结果以当前环境的 VCS 回归日志为准。

### SV Interface 模式（连接真实 RTL）

```
virtio 驱动 VIP → PCIe RC Agent → SV Interface → DUT RTL（virtio 设备）
                                                      ↓
                                  Completion/DMA → SV Interface → RC Monitor
```

对接步骤：

1. 在 `virtio_tb_top.sv` 中实例化 `pcie_tl_if` 并连接到 DUT 的 PCIe 接口
2. 设置 `pcie_tl_env_config.if_mode = SV_IF_MODE`
3. 通过 `uvm_config_db` 将 interface 传递给 `pcie_tl_env`
4. 确保 DUT 的 virtio 设备端正确响应 Config/Memory Read/Write TLP
5. DUT 需要实现 virtio PCI Capability 结构、Common Config 寄存器、通知门铃等

---

## 设计约束与安全规则

### 等待策略

**项目中禁止使用裸 `#delay`。** 所有等待操作必须通过 `wait_policy` 的三种方法之一：

| 方法 | 用途 | 特点 |
|------|------|------|
| `poll_reg_until()` | 轮询 BAR 寄存器直到满足条件 | 双重保护：时间 + 次数 |
| `poll_config_until()` | 轮询 Config Space 寄存器 | 同上 |
| `wait_event_or_timeout()` | 等待 UVM Event 或超时 | 命名 fork 块 |

### Fork 块安全

```systemverilog
// 正确写法：命名 fork 块
fork : my_wait_block
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable my_wait_block;    // 只杀命名块内的进程

// 禁止写法：裸 disable fork
fork
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable fork;             // 会杀死调用线程下的所有子进程！
```

### 超时配置（仿真 ns 级）

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `reset_timeout_ns` | 5,000（5us） | 设备复位超时 |
| `queue_reset_timeout_ns` | 5,000 | 单队列复位超时 |
| `flr_timeout_ns` | 10,000（10us） | VF FLR 超时 |
| `cpl_timeout_ns` | 5,000 | PCIe Completion 超时 |
| `rx_wait_timeout_ns` | 50,000（50us） | RX 报文等待超时 |
| `timeout_multiplier` | 1 | 全局倍率（压力测试可调大） |

---

## 已知限制

### 1. TLM 回环模式下的 Completion 响应机制

**现象**：PCIe RC Driver 的 Completion 通过异步回调（`handle_completion()`）返回，不走 UVM 标准的 `put_response()` 机制，导致 `bar_accessor` 的读序列中 `get_response()` 永远阻塞。

**根因**：`pcie_tl_base_driver` 设计为 fire-and-forget 模式。Completion 匹配由 TLM 回环通路异步触发，与 UVM 的 response 队列是两条独立的路径。

**解决方案**：通过 Completion Bridge 中间层（`virtio_cpl_bridge` + `virtio_rc_driver_shim` + 桥接序列）弥合异步缺口。详见 `tests/virtio_full_test.sv`。

**影响范围**：仅影响 TLM 回环自测模式。**对接真实 DUT 后此问题不存在**——所有请求-响应匹配都通过 SV Interface 上的信号时序自然完成。

### 2. 写数据随机化冲突

**现象**：`pcie_tl_mem_wr_seq` 使用 `uvm_do_with` 随机化 payload，覆盖了 `bar_accessor` 设置的写入数据。

**解决方案**：桥接写序列（`virtio_bar_mem_wr_seq_bridged`）使用 `start_item/finish_item` 直接构造 TLP，绕过 `uvm_do_with`。

### 3. 性能监控运行时重配

**现象**：`perf_monitor` 的 `bucket_size` / `token_bucket` 在 `build_phase` 初始化，运行时修改 `bw_limit_mbps` 后内部状态不更新。

**解决方案**：使用 `virtio_perf_monitor_ext` 子类的 `configure_bw()` 方法进行运行时重配。

---

## 测试建议

### DUT 对接后的推荐测试优先级

| 优先级 | 测试类别 | 说明 |
|--------|---------|------|
| P0 | 完整初始化流程 | 验证设备能正确完成从复位到 DRIVER_OK 的所有步骤 |
| P0 | 基本 TX/RX 数据通路 | 发送/接收标准以太网帧，验证数据完整性 |
| P0 | 设备复位与恢复 | 验证设备复位后状态正确归零 |
| P1 | 多队列（MQ） | 验证多队列配置和 RSS 分发 |
| P1 | 校验和/TSO 卸载 | 验证硬件校验和计算和 TCP 分段 |
| P1 | 中断管理 | MSI-X 向量绑定、EVENT_IDX 通知抑制 |
| P2 | SR-IOV | VF 创建/FLR/独立 Feature 协商 |
| P2 | 错误注入 | 描述符异常、IOMMU 故障、状态转换违规 |
| P2 | 热迁移 | 队列状态冻结/恢复 |
| P3 | 性能基准 | 带宽/延迟/多队列并发 |
| P3 | Packed Virtqueue | Packed 模式全流程 |
| P3 | 动态重配 | 带流量 MQ 调整/MTU 变更/中断模式切换 |

### 覆盖率目标

- 功能覆盖率：Feature 组合交叉 > 80%
- 代码覆盖率：行覆盖 > 90%、分支覆盖 > 85%
- 错误注入覆盖：所有 27 种错误类型 × 4 个注入阶段（初始化/运行/迁移/复位）

---

## 文档列表

| 文档 | 路径 | 说明 |
|------|------|------|
| 项目手册（Markdown） | `docs/virtio_net_vip_manual.md` | 约 1900 行详细技术文档 |
| 项目手册（Word） | `docs/Virtio-Net_Driver_UVM_VIP_Manual_v1.0.docx` | Word 格式，适合打印 |
| 设计规格书 | `docs/superpowers/specs/2026-04-23-virtio-net-driver-vip-design.md` | 完整架构设计 |
| 实施计划 | `docs/superpowers/plans/2026-04-23-virtio-net-driver-vip-plan.md` | 37 个任务的实施计划 |

---

## 参考规范

- [OASIS virtio v1.2 规范](https://docs.oasis-open.org/virtio/virtio/v1.2/virtio-v1.2.html)
- [PCI Express Base Specification](https://pcisig.com/specifications)
- [PCI-SIG SR-IOV Specification](https://pcisig.com/specifications)

---

## 许可证

内部使用。
