# Virtio-Net 驱动 UVM 验证 IP

面向 DPU/SmartNIC virtio 硬件加速引擎验证的 UVM virtio-net 驱动模拟组件。

工作在 PCIe Transaction Layer，模拟完整的 Guest OS virtio-net 驱动行为。MODEL
模式通过 TLM/本地 responder 完成可复现的协议与数据闭环；只有 REAL_DUT 模式才
通过真实的 PCIe TLP 对 RTL DUT 做协议合规性和数据正确性验证。

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
├── host_mem_manager（外部组件）               ← Buddy/Linear Host memory 后端
├── host_mem_pool                              ← 按 host-id 共享 manager 的所有权池
├── net_packet（项目外 checkout）              ← 协议报文产生器（跟随远程 master）
└── pcie_tl_env（外部组件，作为子环境）         ← PCIe TL 层 VIP
```

IOMMU requester identity 使用 `{host_id, BDF, IOVA}`，不是仅用
`{BDF, IOVA}`。因此不同 Host 可以合法复用同一数值 BDF 和 IOVA，映射、
unmap、fault rule、dirty tracking 与迁移快照仍彼此隔离。冻结的 PCIe function
identity 会把 `host_id` 传播到 virtqueue、atomic ops、Admin VQ 和独立 TX/RX
dataplane；未绑定全局 identity 的旧 standalone 用法默认属于 host0。

这里的 `iommu.map` 只管理 DMA IOVA 到 GPA 的地址空间，不分配 BAR，也不处理
notify、MSI-X、QSCH 或 global qpair。BAR/notify 属于 PCIe/DUT 配置平面，DMA
映射属于 function 发起内存访问时的数据面地址翻译，两者不能混为一张表。
Host-qualified IOMMU key 也不会自动复制 `host_mem_manager`；若两个 Host 需要相同
数值 GPA 对应不同物理内容，环境应为它们注入各自的 host-memory backend。

BAR 自动布局默认使用确定性的 first-fit；将
`dpu_pcie_domain_cfg.bar_placement_policy` 设为
`DPU_BAR_PLACEMENT_RANDOM` 后，会在声明的 MMIO window 内按 alignment 随机选择
候选地址，并排除 reserved MMIO 和同一 PCIe domain 已占用的 BAR。随机使用仿真器
现有状态，因此同一仿真 seed、配置和调用顺序可复现，找不到随机候选时会回退到
有界的 first-fit。

IOVA 是独立的 requester 地址空间。`virtio_iommu_model` 默认使用
`IOMMU_IOVA_RANDOM`，可通过 `configure_iova_aperture(base, limit, policy, why)`
配置 page-aligned、半开区间的 64-bit aperture，或选择 `IOMMU_IOVA_FIRST_FIT` 做
稳定调试。随机候选只在同一 `{host_id, BDF}` requester 域内检查重叠；不同 Host
可以合法复用相同数值 IOVA，不能把 IOVA 数值冲突误判成 Host GPA 冲突。IOVA 0 被
保留，因为 map 返回 0 表示失败；`map_fixed*` 使用同一 aperture 和冲突检查。

Host memory 由 `host_mem_pool` 按 `host_id` 管理：同一 Host 的 VIO、RDMA、VBLK
服务共享同一个 `host_mem_manager`，不同 Host 使用彼此独立的实例。VIO 可通过
`host_mem_pool_binding` 按 Host 查找共享对象，也可直接注入 `host_mem_binding`。
默认 `host_mem_alloc_policy_e::HOST_MEM_RANDOM` 从已初始化、具有 backing storage 的
区域中随机选择对齐地址；`HOST_MEM_FIRST_FIT` 可用于稳定调试。冻结 snapshot 中
完全落入 Host memory aperture 的 BAR 会在业务分配前自动导入 reservation（独立
MMIO 区间跳过，部分相交拒绝），同一 BAR 的重复导入是幂等的；手工 reservation
通过 `reserve_range(base, size, owner)` 导入，分配器会从空闲结构中扣除这些区间
（base/size 需满足该 manager 的最小 granule 对齐）。该随机化使用仿真器/UVM 的现有随机状态，不增加环境 seed 字段；
相同仿真 seed、配置和调用顺序即可复现布局。

PCIe DUT DMA 不再创建另一份 Host memory。顶层从同一个 pool 取得 manager，
将 VIO 绑定到 pool，并把 protocol-neutral `host_mem_api` handle 按 Root 显式交给
`pcie_tl_env_config`：

```systemverilog
host_mem_pool host_mem_owners;
host_mem_api  host0_mem;
string        why;

host0_mem = host_mem_owners.get_host(0);
vio_cfg.host_mem_pool_binding = host_mem_owners;
if (!pcie_cfg.bind_host_memory(0, 0, host0_mem, why))
  `uvm_fatal("TOP_CFG", why)
```

`root_index` 选择 PCIe RC/Root，`host_id` 选择 Host 地址域；多 Root 模式要求每个
Root 都有一条绑定。MODEL responder 通过 IOMMU 模型把设备可见 IOVA 翻译为 Host
GPA，再访问这个 manager；REAL_DUT 启用本地
`virtio_pcie_real_dut_host_mem_responder` 时安装同一条
`virtio_pcie_iova_host_mem_proxy`，对 Endpoint→RC 的 Memory Read/Write TLP 执行
IOVA→GPA 翻译、权限检查和 dirty-page 记录。它与 VIO 的 ring/buffer 分配看到
完全相同的 backing storage，不会创建第二个 allocator。只有明确配置 legacy
direct-GPA 集成时才跳过 IOMMU；不能把普通 REAL_DUT 的 IOVA 误当成 GPA。不同 Host
必须绑定不同 manager，但可合法使用相同的数值 GPA。已初始化 manager 的 64-bit
aperture 不会被 PCIe 环境重置；旧的 `"host_mem"` config-db 注入只保留给单 Root
兼容测试。PREMAP 按唯一 manager handle 分配：多个 Root 绑定同一 Host manager
只占用一次 backing allocation。固定版 `pcie_work` 在 PREMAP 空间不足时会保留
`host_mem_manager.alloc()` 的 `HOST_MEM` 错误报告，但尚未把失败哨兵转换成
`PCIE_TL_HOST_MEM` fatal；测试必须把该情况视为配置失败，而不能依赖某一个报告级别。
后续
RDMA/VBLK 只需从 pool 取得本 Host 的同一 handle，无需修改 PCIe package。

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

整个初始化序列严格按照 virtio 规范执行；REAL_DUT 下每一步通过真实 PCIe TLP
完成，MODEL 下由同一 transport API 经过 TLM 回环和 endpoint image 完成：

```
BAR 配置/发现（Fabric: program frozen lease；legacy: enumerate）
→ Capability 发现 → 设备复位（写 status=0，轮询确认）
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
| **IOMMU 层** | 地址未映射、权限不足、use-after-unmap、可编程故障规则（按 Host/BDF/地址范围/方向/触发次数） |
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
│   ├── virtio_net_packet_multi_queue_test.sv ← net_packet 四队列 dataplane 语义
│   ├── virtio_real_driver_multiqueue_test.sv ← MODEL 闭环；REAL_DUT 被动多队列 TX
│   ├── virtio_real_driver_rx_test.sv       ← MODEL RX 闭环；REAL_DUT 需平台 ingress callback
│   ├── virtio_dual_test.sv                 ← 双 VIP 互打测试（2 万包 + 带宽控制）
│   └── host_mem_random_tb.sv               ← Host memory 随机布局/reservation 聚焦测试
└── ext/                                    ← 仅保留待清理的 PCIe 历史 gitlink，不参与主 filelist
    └── pcie_tl_vip   → 已由 PCIE_WORK_ROOT 替代
```

---

## 外部依赖

本 VIP 依赖 PCIe TL VIP、Host memory 和项目外的 `net_packet`。PCIe TL VIP 使用
项目外 `pcie_work` checkout，Host memory 使用项目外的 `host_mem` checkout；
`net_packet` 也使用独立 checkout，避免主项目内出现第二套协议报文源码。Host
memory 在本工程中增加了随机布局与 reservation/pool 适配层：

| 组件 | 功能 | 主要接口 |
|------|------|---------|
| **pcie_work/pcie_tl_vip** | PCIe TL 层 VIP，提供 RC/EP Agent、TLM 回环、SR-IOV func_manager | `$PCIE_WORK_ROOT/pcie_tl_vip`；`pcie_tl_env`（子环境）、`uvm_sequencer #(pcie_tl_tlp)`（RC 序列器） |
| **host_mem_manager** | Buddy Allocator 内存管理，提供分配/释放/读写/泄漏检查 | `alloc()`、`free()`、`write_mem()`、`read_mem()`、`leak_check()` |
| **net_packet** | 项目外 `NET_PACKET_ROOT`，跟随远程 `master`；支持 L2-L4、隧道、RDMA、存储协议 | `packet_item`（UVM sequence item 封装） |
| **dpu_common** | 独立 DPU 控制面：拓扑、快照、资源解析和寄存器计划 | `$DPU_COMMON_ROOT` 外部 checkout，固定 SHA |

---

## 快速开始

### 环境要求

- Synopsys VCS（通过 `$VCS_HOME` 提供）和 UVM 1.2
- 可访问外部依赖 checkout 的 Git 远端
- 项目外 `host_mem` checkout（`HOST_MEM_ROOT`，固定提交
  `365b7553fc7dac6b4ad55886a8e4869153607c28`）
- 项目外 `net_packet` master checkout（`NET_PACKET_ROOT`，工作树跟踪
  `origin/master`）
- 独立的 `dpu_common` checkout（固定提交 `a595b5cb5ab0bf653975be68996b5d46deb5a63d`）
- 独立的 `pcie_work` checkout（`PCIE_WORK_ROOT`，固定提交
  `9aedf898f44ca260f3120a3fb162b7bb9fbafb5e`）

### 远程 UVM 验证环境

可用的远程验证机是 `ubuntu@10.11.10.53`，其 VCS 安装路径为
`/home/ubuntu/synopsys/vcs/W-2024.09-SP1`，并包含 UVM 1.2。登录后设置：

```bash
export VCS_HOME=/home/ubuntu/synopsys/vcs/W-2024.09-SP1
$VCS_HOME/bin/vcs -ID
```

`dpu_common` 是独立的控制面仓库，不再复制到本项目目录内。编译前必须将
`DPU_COMMON_ROOT` 指向项目外的 checkout；依赖检查会同时校验其远程地址和固定提交，
避免主项目和控制面出现两套源码：

```bash
export DPU_COMMON_ROOT=/home/ryan/workspace/ryan/dpu_common
git -C "$DPU_COMMON_ROOT" checkout --detach a595b5cb5ab0bf653975be68996b5d46deb5a63d
export HOST_MEM_ROOT=/home/ryan/workspace/ryan/host_mem
git -C "$HOST_MEM_ROOT" checkout --detach 365b7553fc7dac6b4ad55886a8e4869153607c28
export NET_PACKET_ROOT=/home/ryan/workspace/ryan/net_packet
git -C "$NET_PACKET_ROOT" fetch origin master
git -C "$NET_PACKET_ROOT" switch master 2>/dev/null || \
  git -C "$NET_PACKET_ROOT" switch --track -c master origin/master
git -C "$NET_PACKET_ROOT" branch --set-upstream-to=origin/master master
```

首次准备环境时，在项目外 clone 并固定版本：

```bash
git clone https://github.com/Beihang-yuting/dpu_common.git "$DPU_COMMON_ROOT"
git -C "$DPU_COMMON_ROOT" checkout --detach a595b5cb5ab0bf653975be68996b5d46deb5a63d
git clone --branch master https://github.com/Beihang-yuting/net_packet.git "$NET_PACKET_ROOT"
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
`dpu_pcie_reg_executor_test`、`dpu_device_resolver_test`、`dpu_placement_test`、
`dpu_resource_resolver_test`、`dpu_device_bootstrap_plan_test`、`dpu_vio_reg_plan_test`、`virtio_dut_caps_test`、
`virtio_execution_mode_test`、`virtio_real_dut_iova_dma_test`、
`virtio_fabric_resource_test`、`virtio_unit_test`、
`virtio_host_mem_reclaim_test`、`virtio_queue_semantics_test`、
`virtio_stress_unit_test`、
`virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
`virtio_migration_dirty_test`、`virtio_monitor_test`、`virtio_coverage_test`、
`virtio_e2e_test`、`virtio_full_integration_test`、`virtio_pf_lifecycle_reset_test`、
`virtio_monitor_routing_test`、`virtio_dual_test`、`virtio_smoke_test`、
`virtio_traffic_test`、`virtio_net_packet_multi_queue_test`、
`virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、
`virtio_real_driver_rx_test`、
`host_mem_random_test`、`virtio_pcie_host_mem_test` 和
`dpu_pcie_tl_executor_integration_test`，共 37 项。
`make check-deps` 会验证 `host_mem` 外部 checkout 固定 SHA、VCS 环境以及
`dpu_common`、`pcie_work` 的固定版本；同时要求 `net_packet` 外部 checkout
来自指定远程并处于 `master`/`origin/master` 跟踪状态。

`virtio_host_mem_reclaim_test` 使用外部 `host_mem` 项目的 `host_mem_pool`，验证
同一 Host 的 manager 共享、随机 alloc/free、队列 reset/teardown 回收以及多 Host
隔离。`virtio_queue_semantics_test` 专门覆盖 split/packed queue 的满队列、消费、
回绕和 descriptor 复用；`virtio_indirect_desc_test` 覆盖 indirect table、非法
嵌套/长度、feature gate、queue-full cleanup，并在测试结束检查共享 Host memory
没有泄漏。`virtio_traffic_test` 和 `virtio_net_packet_multi_queue_test` 也从
同一个 Host manager 分配 ring 和 packet buffer。

`pcie_work/pcie_tl_vip@9aedf898f44ca260f3120a3fb162b7bb9fbafb5e` 和
`host_mem@365b7553fc7dac6b4ad55886a8e4869153607c28` 均为项目外固定依赖；其中
`host_mem` 提供 `host_mem_pkg.sv`、`host_mem_manager.sv` 和 `host_mem_pool.sv`，
PCIe package 由 `$PCIE_WORK_ROOT/pcie_tl_vip` 提供。固定 SHA 使依赖可复现；实际的 VCS
编译和动态 UVM 回归结果仍取决于运行环境。

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
只在显式 seed 下可复现。`PINNED` assignment 的冲突必须失败；`PREFERRED`
冲突会回退为 `AUTO`。自动 global qpair ID 总是选择最低的未预留 free ID。

四个 ID namespace 不可混用：`request_id` 识别 authoring request，
`service_instance_id` 与 function key 共同形成 service key，`local_pair_id`
只在该 service/device 内唯一并作为 placement/resource 的本地 qpair label；
`virtio_pair_index` 是
该 service 内连续的软件 pair 序号；`global_qpair_id` 是 snapshot 中跨 Fabric
的 `0..2047` ID。每个 qpair 同时表示 RX/TX pair，不为方向另取 Fabric global ID。
当前 real-DUT profile 要求 `service_instance_id == 0`，每个 PF/VF 至多拥有一个
VIO-net service。若软件 pair index 为 `p`，其 RX virtqueue ID 为 `2*p`，TX
virtqueue ID 为 `2*p+1`；这两个协议队列号与 DUT local pair ID 相互独立。
默认 real-DUT 上限为每个 device 32 pairs、全局 2048 pairs；profile 可以缩小，
不能扩大 snapshot capability，因此 100 pairs 至少需要四个 eligible 32-pair
devices。

`dpu_vio_placement_request.lan_msix_vectors` 可选地声明该 function 的 LAN
q-vector 数量。值为 0 时保留一 qpair 一 vector 的默认 lowering；设置为小于
qpair 数量的值时，resolver 按真实驱动的 `DIV_ROUND_UP(remaining_rings,
remaining_vectors)` 算法把多个 qpair 绑定到同一 local/global MSI-X vector。
共享 vector 只产生一份 linear/info/interval 表项，notify entries 仍按每个 qpair
生成；mailbox 和 AF 控制 vectors 继续从 capability 中单独计数。

默认真实驱动 profile 还会为选中的 AF 固定追加 11 个 queue binding：offset 0
为 forward，1 为 BPDU，2..5 为 ETH port0 netdev queue0..3，6..9 为 ETH port1
netdev queue0..3，10 为 PTP。它们的 `local_queue_index` 从 AF 普通 LAN qpair
数量之后连续追加，并和普通 VIO qpair 共用同一个 2048-entry global qpair pool；
因此 AF 的普通 LAN qpair 与 11 个 extra queue 合计不能超过 32，默认 profile 下
AF 最多配置 21 个普通 VIO qpair。extra queue 使用独立的 MSI-X binding，普通 AF
LAN vector 之后还会为 mailbox 及其他 AF control interrupt 预留 capability 空间。

解析成功后只查询 snapshots：`dpu_resource_snapshot` 提供按 request、
service/local 或 global ID 的 bindings 查询，`dpu_resource_manager` 仅以精确
snapshot pair seed 并维持只读 service lease mapping，`virtio_resource_client` 与
`virtio_vf_resource_pool` 将该 mapping 按 service key 导入且不可改绑。FLR 只复位
runtime state；已发布的 service、local/global qpair identity 和 snapshot pair
保持稳定。`dpu_vio_register_plan_builder` 现在可以把 frozen snapshot pair
降低为一份 VIO service 的 real-DUT register plan：它先合并 BAR/AF bootstrap，再写 BDF map、
MSI-X linear/info/interval 和选定 inactive notify bank，最后通过 commit 写提交 bank。
所有内部表写均以选中 AF 的 BAR0 为 target，notify 的匹配字段为
`{host_id, notify_addr[60:7], local_qid}`；其中 `local_qid` 使用驱动
`txrx_queues[]` 的连续 pair index，placement 的 sparse `local_pair_id` 仅用于
资源命名和约束。global qpair/vector 使用显式或稳定解析结果，不从稀疏 local ID 反推。
notify entries 按驱动的 host/address key 排序；
`select_inactive_notify_bank` 默认开启，自动选择当前活动 bank 的另一份 shadow bank。
冷启动默认把 bank0 视为 active，因此首次 setup 写 bank1；若环境 attach 到已经运行的
DUT，用户必须在 build 前通过 `dpu_device_env_config.vio_policy.active_notify_bank`
提供硬件当前实际的 active bank。环境只在 plan 成功执行并完成 commit 后更新 tracked
active bank；仅 build、`NOT_EXECUTED`、preflight failure 或执行失败均不会推进该状态。
`emit_full_notify_bank` 默认开启，按真实驱动写满 128 项 shadow，未使用项填入
driver-compatible invalid image。每个 16-byte entry 按 low/high 两次写入后，以
5 次、5 us 间隔做 readback polling；全部 entry 校验成功后才允许 commit。仅做
无残留状态的聚焦测试时可以显式关闭完整镜像或 readback。PBA 是 DUT 维护的 pending
状态，不在配置 plan 中伪写。

```systemverilog
dpu_reg_plan vio_plan;
dpu_execution_report report;
string why;
if (!device_env.build_vio_register_plan(vio_plan, why))
  `uvm_fatal("DPU_CFG", why)
device_env.apply_vio_register_plan(vio_plan, report);
```

配置成功进入 `ACTIVE` 后，可从同一对 frozen snapshots 生成并执行独立 teardown：

```systemverilog
dpu_reg_plan teardown_plan;
if (!device_env.build_vio_teardown_plan(teardown_plan, why))
  `uvm_fatal("DPU_CFG", why)
device_env.apply_vio_teardown_plan(teardown_plan, report);
```

teardown 先向 inactive notify bank 提交完整 invalid shadow，再只对 snapshot 中实际
拥有普通 VIO 或 AF extra queue 的 function，依次失效 MSI-X info、MSI-X linear 和
BDF map。setup 与 teardown 使用同一个 VIO-owned function 集合；没有 VIO/AF-extra
queue 的 function 不由 VIO plan 写入或清理 BDF map。公共 BAR bootstrap 仍覆盖完整
PCIe topology，不随 VIO BDF ownership 收窄。成功后环境回到 `RESOLVED`；未执行或
preflight 失败保持 `ACTIVE`。

`dpu_vio_register_plan_policy` 可选择 notify bank、notify type、MSI-X interval 和
self-mask；它只改变寄存器 lowering，不改变 snapshot 拓扑。`apply_vio_register_plan`
复用 `dpu_device_env_config.executor` 注入的 `dpu_reg_executor`，先做完整 plan
freeze/preflight，preflight 失败时不会产生任何 PCIe 写入。用户可继承该 executor
把 `dpu_reg_op` 转换为真实 PCIe config/MMIO TLP；本仓库仍不提供特定平台的 production
transport。

真实驱动 profile 的 notify shadow 长度是 128 项；`emit_full_notify_bank` 只清理
到这 128 项，不把硬件编码上限 1024 误当成软件表长度。AF extra queue 以
`dpu_af_extra_queue_binding_t` 单独保存在 frozen resource snapshot 中。
resource manager 会把它们导入为 AF function-owned frozen lease，因而占用并保护
global qpair ID；它们不会成为 guest VIO service lease，也不会暴露给
`virtio_resource_client`。普通 VIO 与 extra queue 的 register operations 会按同一
notify match key 合并排序，并为 extra queue 生成 BDF dependency、MSI-X
linear/info/interval 和 notify low/high 写入。

已提供基于 53 号机真实驱动 `register.h` 的
`dpu_vio_driver_dataplane_extension`：它把 QSCH init、Q2TC/N2G/G2P/SPWRR 以及
可选的 QSCH TC0..TC7 WRR weight、VTX/VRX queue-parameter RAM 的 content 和
0→1 写使能顺序追加到同一个 register plan。QSCH/VTX/VRX 的地址、字段宽度、
Host/function/MSI-X 派生关系和 AF BAR0
aperture 都会校验；没有驱动证据的 context、tail、链表和调度树节点不会被伪造。
用户可直接向 `qsch_queues`、`qsch_functions`、`vtx_queues`、`vrx_queues` 添加
场景配置，或继承 `dpu_vio_dataplane_plan_extension` 自定义其他平台寄存器，再通过
`dpu_device_env_config.vio_dataplane_extension` 注入。三个 hook 按上述顺序在核心
BDF/MSI-X/notify plan 完整生成后调用，接收同一对 frozen snapshots 和仍可追加
operation/dependency 的 plan；任一 hook 返回失败，整个 plan build 失败且不会执行。
`qsch_functions.weight_valid` 为 1 时才写入八个 4-bit `tc_weight`；默认不改硬件
TC weight。
注意 QSCH G2P 的驱动结构体 `src_port` 实际只有 1 bit；虽然源码使用
`QSCH_PORT_HOST0 + host_id` 的逻辑值，编译后的 `dpu_snd1.ko` 最终只保留低位，
plan 也按该硬件可见编码生成。
QSCH 的随机拓扑与寄存器 lowering 已分层。`dpu_qsch_topology_generator` 先从
frozen device/resource snapshots 收集实际存在的 Function 和 global qpair，再按仿真
全局 seed 生成合法的 `port -> group -> net/function -> qpair` 关系；生成结果保存在
`dpu_qsch_topology_cfg` 中，支持 `DPU_QSCH_TOPOLOGY_RANDOM_VALID` 和
`DPU_QSCH_TOPOLOGY_RANDOM_STRESS` 两种模式。net ID 不独立随机，而是固定为对应
Function 的 `global_func_id`，以避免把不存在的硬件 vport 写入 Q2TC；group、port、TC、
SP/WRR 和 TC weight 才是受字段范围约束的随机部分。每个 qpair 只能属于其 owner
Function 的 net，group 必须挂到已声明 port，且每个生成的 group 至少被一个 net 使用。
如果场景需要覆盖多个 net-device 共享调度组，可将
`generator.require_shared_group = 1`；当存在两个以上 Function 时，生成器会把
group 数量限制为小于 net 数量，再随机选择剩余 net 的挂接关系，从而保证至少一个
group 被多个 net 共享，同时保留 group/port/TC 和策略字段的随机性。
拓扑还显式记录实际被 qpair 使用的 `traffic_classes[0..7]`，便于后续扩展 DSCH/QSCH
调度树模型。

拓扑生成后可通过 `dpu_vio_driver_dataplane_extension.set_qsch_topology()` 导入，
builder 会在生成 Q2TC/N2G/G2P/SPWRR operation 前再次校验同一对 frozen snapshots。
因此用户可以保存或打印拓扑作为期望模型，再把同一份图 lowering 到 DUT。当前真实
驱动证据中 N2G/G2P 表项仍按 `global_func_id` 寻址，随机 group 作为 N2G 字段、对应
group 的 port 作为该 net 的 G2P 字段；没有未经核实的独立 group-table 地址被伪造。
当前 builder 仍不负责 AF mailbox/MAC-age/PTP-stamp 等非 queue control interrupt、
标准 PCIe MSI-X table address/data 初始化或 PBA 写入。BAR4 MSI-X address/data 由 Host
PCIe MSI-X 配置流程产生；teardown 只清理本 snapshot 拥有的 DUT internal BDF、
MSI-X info/linear 和 notify 映射，不触碰 BAR4 table、PBA 或其他业务 function。

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

1. 在平台 wrapper 中实例化 RC→EP、EP→RC 两条 `pcie_tl_if` 并连接到 DUT
2. 设置 `pcie_tl_env_config.if_mode = SV_IF_MODE`
3. 通过 `uvm_config_db` 分别发布 `pcie_tl_rc_vif` 和 `pcie_tl_ep_vif`
4. 确保 DUT 的 virtio 设备端正确响应 Config/Memory Read/Write TLP
5. DUT 需要实现 virtio PCI Capability 结构、Common Config 寄存器、通知门铃等

#### MODEL 与 REAL_DUT 的边界

`virtio_net_env_config.execution_mode` 目前只保留两个可执行值：
`VIRTIO_EXEC_MODEL`（默认）和 `VIRTIO_EXEC_REAL_DUT`。两者都使用同一套生产
driver/queue/Host-memory API，但设备侧责任不同：

- MODEL 由 `virtio_pcie_dut_responder` 消费 notify、读取/写入共享 Host memory、
  更新 used ring，并通过 notification manager sideband 模拟 MSI-X/INTx 事件；该
  事件不是 RTL 发出的真实 PCIe MSI-X TLP，但可在没有 RTL 的 TLM 回环中完成闭环。
- REAL_DUT 不创建该 responder；PCIe EP agent 被动观察真实 RTL 的 TLP，RC 侧必须
  同时提供 `pcie_tl_rc_vif`（RC→EP）和 `pcie_tl_ep_vif`（EP→RC）。如果使用
  plain `pcie_work` 链路，还必须显式加
  `+VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1`，由
  `virtio_pcie_real_dut_host_mem_responder` 响应 EP-originated Host-memory DMA；
  已经提供完整 backend bridge 时不能再打开这个 plusarg，否则会产生重复
  Completion/写入。
- REAL_DUT 的 Host-memory responder 只负责 EP→RC DMA，不是 virtio 设备模型，
  不会生成 notify、used ring 或 RX ingress。当前 `virtio_real_driver_rx_test` 在
  REAL_DUT 下会明确报告 `REAL_DUT_RX_SOURCE_UNAVAILABLE`，直到平台通过
  `net_packet`/物理 ingress callback 提供真实入包路径。

本地 REAL_DUT Host-memory responder 一次只绑定一个 `{host_id, BDF}`。多 PF/VF
平台应为每个 Function 创建独立 responder，或由外部 backend 按 requester BDF
分派到对应 IOMMU/Host-memory 域；不能把一个绑定静默复用于其他 Function。

上述条件任一缺失时，fixture 会在 `build_flow()` 阶段失败；不能把 MODEL responder
计数当作真实 RTL 数据面已经通过的证据。
仓库自带的 `virtio_tb_top.sv` 目前只保留 REAL_DUT 接线说明，并未实例化或发布这两
条 VIF，因此默认顶层只能运行 MODEL。真实平台 wrapper 必须自行实例化双向
`pcie_tl_if`，并在 `run_test()` 前通过 `uvm_config_db` 发布上述两个键。

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
- 错误注入覆盖：定义 27 种语义错误类型；当前通用队列路径只自动实现可映射到
  描述符字节的错误变异（ADDR/LEN/FLAGS/NEXT/ID），其余 ring、状态、IOMMU
  和中断错误需要各自的专用 hook。`fault_phase` 提供
  `PRE_NOTIFY`、`POST_NOTIFY`、`PRE_DEVICE_READ`、`BEFORE_USED` 和
  `ANY` 五个队列/响应边界选择，不应将其理解为 27 种错误均已在所有阶段自动实现。

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
