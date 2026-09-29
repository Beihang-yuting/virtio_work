# Virtio-Net Driver UVM VIP 项目手册

| 项目 | 说明 |
|------|------|
| **项目名称** | Virtio-Net Driver UVM Verification IP |
| **版本** | 1.0 |
| **日期** | 2026-04-24 |
| **概述** | 面向 DPU/SmartNIC virtio 硬件加速引擎验证的 UVM virtio-net 驱动模拟组件，工作在 PCIe Transaction Layer，支持 Split/Packed/Custom virtqueue、完整 SR-IOV、双层驱动模型和丰富的错误注入能力。 |

---

## 目录

- [1. 项目概述](#1-项目概述)
- [2. 系统架构](#2-系统架构)
- [3. 目录结构](#3-目录结构)
- [4. 核心组件详解](#4-核心组件详解)
  - [4.1 类型系统 (types/)](#41-类型系统-types)
  - [4.2 等待策略框架 (shared/virtio_wait_policy)](#42-等待策略框架-sharedvirtio_wait_policy)
  - [4.3 内存屏障模型 (shared/virtio_memory_barrier_model)](#43-内存屏障模型-sharedvirtio_memory_barrier_model)
  - [4.4 IOMMU 模型 (iommu/)](#44-iommu-模型-iommu)
  - [4.5 Virtqueue 层 (virtqueue/)](#45-virtqueue-层-virtqueue)
  - [4.6 PCI 传输层 (transport/)](#46-pci-传输层-transport)
  - [4.7 驱动 Agent (agent/)](#47-驱动-agent-agent)
  - [4.8 数据面 (dataplane/)](#48-数据面-dataplane)
  - [4.9 SR-IOV (sriov/)](#49-sr-iov-sriov)
  - [4.10 环境层 (env/)](#410-环境层-env)
  - [4.11 Sequence 库 (seq/)](#411-sequence-库-seq)
  - [4.12 回调扩展点 (callbacks/)](#412-回调扩展点-callbacks)
- [5. Feature 支持矩阵](#5-feature-支持矩阵)
- [6. 使用指南](#6-使用指南)
- [7. 测试方法论](#7-测试方法论)
- [8. 已知限制和未来工作](#8-已知限制和未来工作)
- [9. API 参考](#9-api-参考)
- [10. 附录](#10-附录)

---

## 1. 项目概述

### 1.1 项目背景和目标

本项目是一个 UVM（Universal Verification Methodology）验证 IP，用于模拟完整的 Guest OS virtio-net 网络驱动程序行为。其核心目标是验证 DPU（Data Processing Unit）和 SmartNIC 上的 virtio 硬件加速引擎（Device 侧）。

在 DPU/SmartNIC 架构中，virtio-net 设备由硬件实现，替代传统的 QEMU 软件后端。这意味着硬件必须严格遵循 virtio 规范中定义的所有协议行为——从 PCI capability 发现、feature 协商、queue 配置，到数据面的描述符链处理、通知抑制、中断管理等。本 VIP 通过模拟一个完整的 virtio-net 驱动，在 PCIe Transaction Layer 产生真实的 TLP 流量。MODEL 模式可执行 TX/RX 闭环；REAL_DUT 模式用于验证真实 RTL，但当前仍需平台提供双向 PCIe 链路和 RX ingress callback，不能把 MODEL 回归结果表述为 RTL 数据面已经通过。

**核心验证目标：**

1. **协议合规性**：验证 DUT 是否正确实现了 virtio 1.2/1.3 规范定义的所有初始化序列、状态转换和队列协议
2. **数据正确性**：端到端验证 TX/RX 数据路径的报文完整性
3. **offload 正确性**：验证 checksum、TSO、USO、RSS 等硬件卸载功能
4. **错误处理**：通过错误注入验证 DUT 对异常情况的处理能力
5. **性能特征**：带宽限制、延迟剖析、多队列并发性能

### 1.2 适用场景

| 场景 | 说明 |
|------|------|
| DPU virtio-net 引擎验证 | 验证硬件实现的 virtio-net 设备端行为 |
| SmartNIC virtio 加速验证 | 验证网卡上的 virtio offload 硬件 |
| SR-IOV VF 生命周期验证 | 验证 PF/VF 创建、配置、FLR、热迁移等 |
| 协议一致性测试 | 验证设备是否符合 virtio 1.2/1.3 规范 |
| 性能基准测试 | 测量延迟、带宽等性能指标 |
| 错误恢复测试 | 验证 DEVICE_NEEDS_RESET、FLR 等异常恢复流程 |

### 1.3 支持的 virtio 规范版本

- **virtio 1.2**（主要目标）
- **virtio 1.3**（部分特性支持）
- 覆盖 Section 4.1（PCI Transport）和 Section 5.1（Network Device）全部内容

### 1.4 核心设计理念

#### 双层驱动模型

VIP 提供两种驱动模式，可在运行时切换：

- **AUTO 模式**（`DRV_MODE_AUTO`）：自动状态机（`virtio_auto_fsm`）完成从设备发现到数据面运行的全生命周期管理，包含后台任务（RX 补充、TX 完成回收、中断处理、自适应 IRQ 等）
- **MANUAL 模式**（`DRV_MODE_MANUAL`）：通过原子操作库（`virtio_atomic_ops`）逐步控制每个驱动操作，适合精细化测试
- **HYBRID 模式**（`DRV_MODE_HYBRID`）：初始化使用 AUTO，数据面使用 MANUAL

#### 三种 Virtqueue 实现

通过抽象基类 `virtqueue_base` 定义 18 个纯虚方法，提供三种实现：
- **Split Virtqueue**：标准三区域布局（描述符表 + Available Ring + Used Ring）
- **Packed Virtqueue**：单环布局，AVAIL/USED 标志位嵌入描述符
- **Custom Virtqueue**：用户通过回调接口自定义描述符格式

#### wait_policy 统一等待框架

VIP 中**禁止使用裸 `#delay`**，所有等待操作必须通过 `virtio_wait_policy` 类完成，提供三种等待原语，每种都有双重保护（时间超时 + 迭代次数上限）。

#### Named Fork 规则

VIP 中**所有 fork 块必须命名**，**只使用 `disable <block_name>`**，**禁止使用 `disable fork`**（因为 `disable fork` 会杀死调用线程的所有子进程，在复杂 UVM 环境中极易导致难以调试的问题）。

```systemverilog
// 正确: 命名 fork 块
fork : my_wait_block
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable my_wait_block;

// 禁止: 裸 disable fork
fork
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable fork;  // 杀死调用线程中的所有子进程!
```

### 1.5 外部组件依赖

| 组件 | 路径 | 角色 | 集成方式 |
|------|------|------|----------|
| `pcie_tl_vip` | `$PCIE_WORK_ROOT/pcie_tl_vip` | PCIe TL 子环境（RC/EP Agent, func_manager, SR-IOV） | 外部 `main` checkout，作为子环境零修改 |
| `host_mem_manager` | `$HOST_MEM_ROOT`（项目外固定 checkout） | Buddy 分配器，用于描述符环和数据缓冲区 | 共享实例 |
| `net_packet` | `$NET_PACKET_ROOT`（项目外 checkout） | 跟随远程 `master`；协议报文生成器（L2-L4、隧道、RDMA、存储） | `packet_item` UVM 封装 |
| `dpu_common` | `$DPU_COMMON_ROOT`（项目外 checkout） | DPU 全局拓扑、资源快照和寄存器计划 | 固定 SHA 的独立仓库 |

本版本固定使用 `dpu_common@4d739965eb47d90b47cc048fc71fd8d7d76a77ca`、
`host_mem@35ec087014744ec85cf6c0fe17e1f7118ee7a7b7`；PCIe TL VIP 使用项目外
`pcie_work/main`（其 `pcie_tl_vip` 位于 `pcie_work/pcie_tl_vip`），并要求跟踪
`origin/main`。`make check-deps` 会在编译前验证固定依赖以及 PCIe 的远程/分支契约。
`dpu_common`、`host_mem` 和 `pcie_work` 不允许复制到本项目根目录，编译前必须分别设置
`DPU_COMMON_ROOT`、`HOST_MEM_ROOT` 和 `PCIE_WORK_ROOT`。

---

## 2. 系统架构

### 2.1 整体架构图

```
+===========================================================================+
|                           virtio_net_env (top-level)                       |
|                                                                           |
|  +-- pf_manager (simplified)                                              |
|  |   +-- ref: pcie_tl_env.func_manager    <-- 复用 PCIe PF/VF 管理        |
|  |   +-- virtio_vf_resource_pool          <-- virtio 专用队列映射          |
|  |   +-- admin_vq                         <-- PF 管理 virtqueue (1.2+)    |
|  |   +-- failover_manager                 <-- STANDBY/failover            |
|  |                                                                        |
|  +-- vf_instances[N]                      <-- 每个 VF 一个实例            |
|  |   +-- virtio_driver_agent              <-- 核心 UVM Agent              |
|  |   |   +-- virtio_driver                <-- 双层: auto_fsm + atomic_ops |
|  |   |   +-- virtio_monitor               <-- 被动 TLP 观察              |
|  |   |   +-- virtio_sequencer                                            |
|  |   +-- virtqueue_manager                <-- 本 VF 的队列集合            |
|  |   |   +-- split_virtqueue / packed_virtqueue / custom_virtqueue        |
|  |   +-- virtio_net_dataplane                                            |
|  |   |   +-- tx_engine                    <-- net_packet 集成             |
|  |   |   +-- rx_engine                    <-- buffer merge + parse        |
|  |   |   +-- offload_engine               <-- csum/TSO/USO/RSS           |
|  |   +-- virtio_pci_transport                                            |
|  |   |   +-- pci_cap_manager              <-- virtio capability 发现      |
|  |   |   +-- bar_accessor                 <-- BAR R/W -> PCIe TLP         |
|  |   |   +-- notification_manager         <-- MSI-X/INTx/polling/adaptive |
|  |   +-- virtio_net_config                <-- 每 VF 的 feature/config     |
|  |                                                                        |
|  +-- iommu_model                          <-- GPA->IOVA 映射 + 故障注入   |
|  +-- wait_policy                          <-- 统一超时/轮询框架           |
|  +-- perf_monitor                         <-- 延迟剖析 + 带宽限制         |
|  +-- error_injector                       <-- 统一错误注入控制器           |
|  +-- virtio_scoreboard                    <-- 数据/协议/offload/DMA 验证  |
|  +-- virtio_coverage                      <-- 8 个 covergroup, 惰性构造  |
|  +-- concurrency_controller              <-- 多 VF 并发操作 + 竞争注入    |
|  +-- dynamic_reconfig                     <-- 运行时 MQ/MTU/IRQ/MAC/VLAN  |
|  |                                                                        |
|  +-- host_mem_manager (external)          <-- 共享实例                     |
|  +-- net_packet (external)                <-- 共享实例                     |
|  +-- pcie_tl_env (subenv)                 <-- PCIe TL 子环境              |
|  |                                                                        |
|  +-- virtio_virtual_sequencer                                             |
|      +-- pf_seqr                                                          |
|      +-- vf_seqrs[N]                                                      |
|      +-- pcie_rc_seqr                                                     |
+===========================================================================+
```

### 2.2 组件层次关系

VIP 采用分层架构，从底层到顶层依次为：

1. **类型层**（Phase 1）：枚举、结构体、常量定义
2. **共享基础设施层**（Phase 1-2）：wait_policy、memory_barrier_model、IOMMU 模型
3. **Virtqueue 引擎层**（Phase 3）：抽象基类 + 三种实现 + 管理器
4. **PCI 传输层**（Phase 4）：寄存器定义、capability 发现、BAR 访问、通知管理
5. **驱动层**（Phase 5）：回调接口、事务类、原子操作库、自动 FSM、UVM Agent
6. **数据面层**（Phase 6）：TX/RX 引擎、offload 引擎、failover 管理
7. **SR-IOV 层**（Phase 7）：VF 资源池、VF 实例、PF 管理器
8. **环境层**（Phase 8）：配置、scoreboard、coverage、性能监控、并发控制
9. **序列层**（Phase 9）：基础序列、场景序列、虚拟序列

### 2.3 数据流图

#### TX 路径

```
 Test Sequence
      |
      v
 virtio_driver (process_transaction)
      |
      v
 virtio_auto_fsm.send_packets() / virtio_atomic_ops.tx_submit()
      |
      v
 +--build_net_hdr()                    -- 构建 virtio-net 头部
 |  +-- offload_engine.compute_csum()  -- 如果需要 checksum offload
 |  +-- tso_engine.segment()           -- 如果需要 TSO
 |  +-- uso_engine.segment()           -- 如果需要 USO
      |
      v
 host_mem.alloc() --> 分配 hdr+data buffer
      |
      v
 iommu.map() --> GPA -> IOVA 映射
      |
      v
 split/packed_virtqueue.add_buf() --> 填写描述符, 更新 avail ring
      |
      v
 barrier.wmb() --> 写内存屏障
      |
      v
 vq.needs_notification() --> 检查是否需要 kick
      |
      v
 transport.kick() --> BAR 写入 notify offset (PCIe Memory Write TLP)
      |
      v
 [DUT 处理报文, 写回 Used Ring]
      |
      v
 vq.poll_used() --> 读取 Used Ring, 回收描述符
      |
      v
 iommu.unmap() + host_mem.free() --> 释放资源
```

#### RX 路径

```
 virtio_auto_fsm.start_dataplane() --> rx_refill_loop()
      |
      v
 host_mem.alloc() --> 分配 RX buffer
      |
      v
 iommu.map() --> GPA -> IOVA 映射
      |
      v
 vq.add_buf() --> 填写描述符 (WRITE 标志), 更新 avail ring
      |
      v
 transport.kick() --> 通知设备有新的 RX buffer 可用
      |
      v
 [DUT 将接收到的报文写入 RX buffer, 更新 Used Ring]
      |
      v
 vq.poll_used() --> 读取 Used Ring, 获取已填充 buffer
      |
      v
 unpack_hdr() --> 解析 virtio-net 头部
      |
      v
 rx_engine.parse_buffer() --> 解析报文数据
      |
      +-- 如果 MRG_RXBUF: 合并多个 buffer
      |
      v
 iommu.unmap() + host_mem.free() --> 释放 buffer, 准备重新补充
```

### 2.4 PCIe TLP 交互流程

VIP 与 DUT 的所有交互都通过 PCIe TLP 完成：

```
 VIP (RC Agent)                                     DUT (EP)
      |                                                |
      |  Config Read TLP (BAR enumeration)             |
      |----------------------------------------------->|
      |                                                |
      |  Completion with Data                          |
      |<-----------------------------------------------|
      |                                                |
      |  Config Write TLP (BAR address assignment)     |
      |----------------------------------------------->|
      |                                                |
      |  Memory Write TLP (BAR: status/feature/queue)  |
      |----------------------------------------------->|
      |                                                |
      |  Memory Read TLP (BAR: status/feature readback)|
      |----------------------------------------------->|
      |                                                |
      |  Completion with Data                          |
      |<-----------------------------------------------|
      |                                                |
      |  Memory Write TLP (notify: kick)               |
      |----------------------------------------------->|
      |                                                |
      |  MSI-X Write TLP (interrupt)                   |
      |<-----------------------------------------------|
      |                                                |
      |  DMA Read/Write (descriptor/data via host_mem) |
      |  (MODEL responder or REAL_DUT Host-memory proxy |
      |   translates device IOVA to Host GPA)          |
      |                                                |
```

该图的 MSI-X Write 表示 REAL_DUT 下由 RTL 发出并被动观察的真实 PCIe TLP。
MODEL responder 当前通过 notification manager sideband 产生等价中断事件，不发送
真实 MSI-X Memory Write TLP。

---

## 3. 目录结构

### 3.1 完整文件树

```
virtio_net_vip/
+-- src/
|   +-- virtio_net_pkg.sv                    -- 顶层 package, 定义 include 顺序
|   +-- types/
|   |   +-- virtio_net_types.sv              -- 所有枚举、结构体、feature bit 定义
|   |   +-- virtio_net_hdr.sv                -- virtio-net 头部序列化/反序列化工具
|   |   +-- virtio_transaction.sv            -- UVM sequence item (事务类型)
|   +-- shared/
|   |   +-- virtio_wait_policy.sv            -- 统一等待/超时/轮询框架
|   |   +-- virtio_memory_barrier_model.sv   -- 内存屏障模型 (wmb/rmb/mb)
|   +-- iommu/
|   |   +-- virtio_iommu_model.sv            -- IOMMU 地址翻译、fault 注入、脏页追踪
|   +-- virtqueue/
|   |   +-- virtqueue_error_injector.sv      -- 错误注入控制器
|   |   +-- virtqueue_base.sv               -- 抽象基类 (18 个纯虚方法)
|   |   +-- split_virtqueue.sv              -- Split Virtqueue 完整实现
|   |   +-- packed_virtqueue.sv             -- Packed Virtqueue 完整实现
|   |   +-- custom_virtqueue.sv             -- Custom Virtqueue (回调委托)
|   |   +-- virtqueue_manager.sv            -- 工厂 + 生命周期管理器
|   +-- transport/
|   |   +-- virtio_pci_regs.sv              -- PCI Common Config 寄存器偏移常量
|   |   +-- virtio_bar_accessor.sv          -- BAR MMIO/Config -> PCIe TLP 翻译
|   |   +-- virtio_pci_cap_manager.sv       -- PCI Capability 链表遍历与解析
|   |   +-- virtio_notification_manager.sv  -- MSI-X/INTx/polling 中断管理
|   |   +-- virtio_pci_transport.sv         -- PCI 传输封装 (完整初始化序列)
|   +-- callbacks/
|   |   +-- virtio_dataplane_callback.sv    -- 数据面自定义回调 (TX chain/RX parse)
|   |   +-- virtio_scoreboard_callback.sv   -- Scoreboard 自定义比较回调
|   |   +-- virtio_coverage_callback.sv     -- Coverage 自定义采样回调
|   +-- agent/
|   |   +-- virtio_atomic_ops.sv            -- 原子操作库 (~30 个方法)
|   |   +-- virtio_auto_fsm.sv             -- 自动生命周期状态机 (12 状态)
|   |   +-- virtio_driver.sv               -- UVM Driver (事务分发)
|   |   +-- virtio_monitor.sv              -- 被动 TLP 观察 + 协议检查
|   |   +-- virtio_sequencer.sv            -- UVM Sequencer
|   |   +-- virtio_driver_agent.sv         -- UVM Agent 封装
|   +-- dataplane/
|   |   +-- virtio_csum_engine.sv           -- Checksum offload 引擎
|   |   +-- virtio_tso_engine.sv            -- TCP Segmentation Offload 引擎
|   |   +-- virtio_uso_engine.sv            -- UDP Segmentation Offload 引擎
|   |   +-- virtio_rss_engine.sv            -- RSS 分发引擎 (Toeplitz hash)
|   |   +-- virtio_offload_engine.sv        -- Offload 统一封装
|   |   +-- virtio_tx_engine.sv             -- TX 引擎 (报文组装 + SG 链)
|   |   +-- virtio_rx_engine.sv             -- RX 引擎 (buffer merge + parse)
|   |   +-- virtio_failover_manager.sv      -- STANDBY/failover 管理
|   |   +-- virtio_net_dataplane.sv         -- 数据面顶层封装
|   +-- sriov/
|   |   +-- virtio_vf_resource_pool.sv      -- VF 队列资源池 (local_qid <-> global_qid)
|   |   +-- virtio_vf_instance.sv           -- 单个 VF 实例封装
|   |   +-- virtio_pf_manager.sv            -- PF 管理器 (委托 pcie_tl_func_manager)
|   +-- env/
|   |   +-- virtio_net_env_config.sv        -- 环境配置对象
|   |   +-- virtio_virtual_sequencer.sv     -- 虚拟 Sequencer
|   |   +-- virtio_scoreboard.sv            -- 8 类检查的 Scoreboard
|   |   +-- virtio_coverage.sv              -- 8 个 Covergroup
|   |   +-- virtio_perf_monitor.sv          -- 性能监控 (带宽限制+延迟剖析)
|   |   +-- virtio_concurrency_controller.sv -- 多 VF 并发控制 + 竞争注入
|   |   +-- virtio_dynamic_reconfig.sv      -- 运行时动态重配置
|   |   +-- virtio_net_env.sv               -- 顶层环境
|   +-- seq/
|       +-- base/                            -- 7 个基础序列
|       |   +-- virtio_base_seq.sv
|       |   +-- virtio_init_seq.sv
|       |   +-- virtio_tx_seq.sv
|       |   +-- virtio_rx_seq.sv
|       |   +-- virtio_ctrl_seq.sv
|       |   +-- virtio_queue_setup_seq.sv
|       |   +-- virtio_kick_seq.sv
|       +-- scenario/                        -- 22 个场景序列 (9 个子目录)
|       |   +-- lifecycle/
|       |   |   +-- virtio_lifecycle_full_seq.sv
|       |   |   +-- virtio_status_error_seq.sv
|       |   |   +-- virtio_feature_error_seq.sv
|       |   +-- dataplane/
|       |   |   +-- virtio_tso_seq.sv
|       |   |   +-- virtio_mrg_rxbuf_seq.sv
|       |   |   +-- virtio_rss_distribution_seq.sv
|       |   |   +-- virtio_csum_offload_seq.sv
|       |   |   +-- virtio_tunnel_pkt_seq.sv
|       |   +-- interrupt/
|       |   |   +-- virtio_adaptive_irq_seq.sv
|       |   |   +-- virtio_event_idx_boundary_seq.sv
|       |   +-- migration/
|       |   |   +-- virtio_live_migration_seq.sv
|       |   |   +-- virtio_failover_seq.sv
|       |   +-- sriov/
|       |   |   +-- virtio_multi_vf_init_seq.sv
|       |   |   +-- virtio_vf_flr_isolation_seq.sv
|       |   |   +-- virtio_mixed_vq_type_seq.sv
|       |   +-- error/
|       |   |   +-- virtio_desc_error_seq.sv
|       |   |   +-- virtio_iommu_fault_seq.sv
|       |   |   +-- virtio_pcie_cross_error_seq.sv
|       |   |   +-- virtio_bad_packet_seq.sv
|       |   +-- concurrency/
|       |   |   +-- virtio_concurrent_vf_traffic_seq.sv
|       |   +-- dynamic/
|       |   |   +-- virtio_live_mq_resize_seq.sv
|       |   +-- boundary/
|       |       +-- virtio_boundary_seq.sv
|       +-- virtual/                         -- 4 个虚拟序列
|           +-- virtio_smoke_vseq.sv
|           +-- virtio_full_init_traffic_vseq.sv
|           +-- virtio_multi_vf_vseq.sv
|           +-- virtio_stress_vseq.sv
+-- tests/
|   +-- virtio_tb_top.sv                    -- 顶层 testbench module
|   +-- virtio_base_test.sv                 -- 基础 test 类
|   +-- virtio_smoke_test.sv                -- 冒烟测试
|   +-- virtio_unit_test.sv                 -- 单元测试 (无 PCIe 依赖)
|   +-- virtio_stress_unit_test.sv          -- 压力单元测试
|   +-- virtio_protocol_test.sv             -- 协议合规测试
|   +-- virtio_traffic_test.sv              -- 大流量 + 带宽控制测试
|   +-- virtio_e2e_test.sv                  -- 端到端集成测试 (PCIe TLM loopback)
|   +-- virtio_full_test.sv                 -- 完整集成测试 (Completion Bridge)
|   +-- virtio_dual_test.sv                 -- 双 VIP 互打测试
# 控制面、Host memory、PCIe VIP 和报文生成器均位于项目外独立 checkout，
# 分别由 $DPU_COMMON_ROOT、$HOST_MEM_ROOT、$PCIE_WORK_ROOT、$NET_PACKET_ROOT 指定。
```

**总计：约 75 个源文件（含测试）。**

### 3.2 目录职责说明

| 目录 | 职责 |
|------|------|
| `src/types/` | 类型定义层：所有枚举、结构体、常量、事务类 |
| `src/shared/` | 共享基础设施：等待策略、内存屏障 |
| `src/iommu/` | IOMMU 地址翻译模型 |
| `src/virtqueue/` | Virtqueue 引擎：抽象基类 + 三种实现 + 管理器 + 错误注入 |
| `src/transport/` | PCI 传输层：寄存器定义、BAR 访问、capability 发现、通知管理 |
| `src/callbacks/` | 用户扩展回调接口定义 |
| `src/agent/` | UVM Agent 组件：驱动、监控器、sequencer |
| `src/dataplane/` | 数据面引擎：TX/RX、offload、failover |
| `src/sriov/` | SR-IOV 支持：PF/VF 管理、资源池 |
| `src/env/` | 顶层环境：配置、scoreboard、coverage、性能监控 |
| `src/seq/` | 序列库：基础序列、场景序列、虚拟序列 |
| `tests/` | 测试用例和 testbench 顶层 |

---

## 4. 核心组件详解

### 4.1 类型系统 (types/)

#### 4.1.1 Feature Bit 定义

VIP 中所有 virtio feature bit 均以 `parameter int` 定义，与 virtio 规范中的 bit 编号一一对应。

**网络设备 Feature（bit 0-23, 54-63）：**

| 参数名 | Bit | 说明 |
|--------|-----|------|
| `VIRTIO_NET_F_CSUM` | 0 | 设备处理发送报文的 checksum |
| `VIRTIO_NET_F_GUEST_CSUM` | 1 | 驱动处理接收报文的 checksum |
| `VIRTIO_NET_F_CTRL_GUEST_OFFLOADS` | 2 | 控制 VQ 可动态开关 offload |
| `VIRTIO_NET_F_MTU` | 3 | 设备报告 MTU |
| `VIRTIO_NET_F_MAC` | 5 | 设备有默认 MAC 地址 |
| `VIRTIO_NET_F_GSO` | 6 | 通用 GSO（已废弃） |
| `VIRTIO_NET_F_GUEST_TSO4` | 7 | 驱动可接收 TSOv4 |
| `VIRTIO_NET_F_GUEST_TSO6` | 8 | 驱动可接收 TSOv6 |
| `VIRTIO_NET_F_GUEST_ECN` | 9 | 驱动可接收带 ECN 的 TSO |
| `VIRTIO_NET_F_GUEST_UFO` | 10 | 驱动可接收 UFO |
| `VIRTIO_NET_F_HOST_TSO4` | 11 | 设备可处理 TSOv4 |
| `VIRTIO_NET_F_HOST_TSO6` | 12 | 设备可处理 TSOv6 |
| `VIRTIO_NET_F_HOST_ECN` | 13 | 设备可处理带 ECN 的 TSO |
| `VIRTIO_NET_F_HOST_UFO` | 14 | 设备可处理 UFO |
| `VIRTIO_NET_F_MRG_RXBUF` | 15 | 合并 RX buffer |
| `VIRTIO_NET_F_STATUS` | 16 | 链路状态报告 |
| `VIRTIO_NET_F_CTRL_VQ` | 17 | 控制 VQ 存在 |
| `VIRTIO_NET_F_CTRL_RX` | 18 | 可配置混杂/全组播模式 |
| `VIRTIO_NET_F_CTRL_VLAN` | 19 | VLAN 过滤 |
| `VIRTIO_NET_F_GUEST_ANNOUNCE` | 21 | 免费 ARP 通告 |
| `VIRTIO_NET_F_MQ` | 22 | 多队列 |
| `VIRTIO_NET_F_CTRL_MAC_ADDR` | 23 | MAC 地址设置 |
| `VIRTIO_NET_F_GUEST_USO4` | 54 | 驱动可接收 USOv4（1.2+） |
| `VIRTIO_NET_F_GUEST_USO6` | 55 | 驱动可接收 USOv6（1.2+） |
| `VIRTIO_NET_F_HOST_USO` | 56 | 设备可处理 USO（1.2+） |
| `VIRTIO_NET_F_HASH_REPORT` | 57 | Hash 值报告 |
| `VIRTIO_NET_F_RSS` | 60 | RSS 分发 |
| `VIRTIO_NET_F_STANDBY` | 62 | failover 待机模式 |
| `VIRTIO_NET_F_SPEED_DUPLEX` | 63 | 速率/双工报告 |

**通用 Feature（bit 28-40）：**

| 参数名 | Bit | 说明 |
|--------|-----|------|
| `VIRTIO_F_RING_INDIRECT_DESC` | 28 | 间接描述符支持 |
| `VIRTIO_F_RING_EVENT_IDX` | 29 | EVENT_IDX 通知抑制 |
| `VIRTIO_F_VERSION_1` | 32 | virtio 1.0+ 合规 |
| `VIRTIO_F_ACCESS_PLATFORM` | 33 | IOMMU 平台支持 |
| `VIRTIO_F_RING_PACKED` | 34 | Packed Virtqueue |
| `VIRTIO_F_IN_ORDER` | 35 | 顺序完成 |
| `VIRTIO_F_SR_IOV` | 37 | SR-IOV |
| `VIRTIO_F_NOTIFICATION_DATA` | 38 | 扩展 kick 数据 |
| `VIRTIO_F_RING_RESET` | 40 | 单队列重置（1.2+） |

#### 4.1.2 枚举类型

VIP 定义了以下枚举类型：

| 枚举名 | 值 | 用途 |
|--------|------|------|
| `virtqueue_type_e` | `VQ_SPLIT`, `VQ_PACKED`, `VQ_CUSTOM` | 队列类型选择 |
| `virtqueue_state_e` | `VQ_RESET`, `VQ_CONFIGURE`, `VQ_ENABLED` | 队列生命周期状态 |
| `device_status_e` | `RESET(0x00)`, `ACKNOWLEDGE(0x01)`, `DRIVER(0x02)`, `FEATURES_OK(0x08)`, `DRIVER_OK(0x04)`, `DEVICE_NEEDS_RESET(0x40)`, `FAILED(0x80)` | 设备状态寄存器值 |
| `driver_mode_e` | `DRV_MODE_AUTO`, `DRV_MODE_MANUAL`, `DRV_MODE_HYBRID` | 驱动模式 |
| `rx_buf_mode_e` | `RX_MODE_MERGEABLE`, `RX_MODE_BIG`, `RX_MODE_SMALL` | RX 缓冲区模式 |
| `interrupt_mode_e` | `IRQ_MSIX_PER_QUEUE`, `IRQ_MSIX_SHARED`, `IRQ_INTX`, `IRQ_POLLING` | 中断模式 |
| `dma_dir_e` | `DMA_TO_DEVICE`, `DMA_FROM_DEVICE`, `DMA_BIDIRECTIONAL` | DMA 方向 |
| `fsm_state_e` | 12 个状态（IDLE 到 RECOVERING） | 自动 FSM 状态 |
| `vf_state_e` | `VF_CREATED` 到 `VF_DISABLED` | VF 生命周期 |
| `failover_state_e` | `FO_NORMAL` 到 `FO_FAILBACK` | Failover 状态 |
| `iommu_fault_e` | 6 种 fault 类型 | IOMMU 故障分类 |
| `virtqueue_error_e` | 27 种错误类型 | 描述符/ring/DMA/通知错误（语义枚举；不代表每一项都有通用自动变异） |
| `virtio_txn_type_e` | 16 种事务类型 | 驱动事务分类 |
| `virtio_atomic_op_e` | 10 种原子操作 | MANUAL 模式操作 |
| `scb_error_e` | 12 种 scoreboard 错误 | 验证错误分类 |
| `race_point_e` | 7 种竞争点 | 并发竞争注入位置 |
| `status_error_e` | 5 种状态错误 | 状态转换错误注入 |
| `feature_error_e` | 5 种 feature 错误 | Feature 协商错误注入 |
| `queue_setup_error_e` | 6 种队列配置错误 | 队列配置错误注入 |

`virtqueue_error_e` 的 27 个枚举值与源码保持一致：

```text
VQ_ERR_CIRCULAR_CHAIN          VQ_ERR_OOB_INDEX
VQ_ERR_ZERO_LEN_BUF            VQ_ERR_KICK_BEFORE_ENABLE
VQ_ERR_AVAIL_IDX_SKIP          VQ_ERR_WRONG_FLAGS
VQ_ERR_INDIRECT_IN_INDIRECT    VQ_ERR_DESC_UNALIGNED
VQ_ERR_SKIP_WMB_BEFORE_AVAIL   VQ_ERR_SKIP_RMB_BEFORE_USED
VQ_ERR_SKIP_MB_BEFORE_KICK     VQ_ERR_DOUBLE_FREE_DESC
VQ_ERR_USE_AFTER_FREE_DESC     VQ_ERR_STALE_DESC
VQ_ERR_DETACH_WHILE_ACTIVE     VQ_ERR_AVAIL_RING_OVERFLOW
VQ_ERR_USED_RING_CORRUPT       VQ_ERR_WRONG_USED_LEN
VQ_ERR_USE_AFTER_UNMAP          VQ_ERR_WRONG_DMA_DIR
VQ_ERR_IOMMU_FAULT_ON_DESC     VQ_ERR_IOMMU_FAULT_ON_DATA
VQ_ERR_WRONG_WRAP_COUNTER      VQ_ERR_AVAIL_USED_FLAG_CORRUPT
VQ_ERR_KICK_AFTER_DISABLE      VQ_ERR_SPURIOUS_INTERRUPT
VQ_ERR_EVENT_IDX_BACKWARD
```

这里的枚举值是待验证的语义分类，不是“调用 `configure()` 后所有错误都会被
同一个队列钩子自动改写”的承诺。实际能否落到线上的字节、ring 索引、状态、
IOMMU 或中断行为，取决于对应的专用注入钩子是否已接入。

#### 4.1.3 结构体定义

| 结构体 | 主要字段 | 用途 |
|--------|----------|------|
| `virtio_sg_entry` | `addr[63:0]`, `len` | 单个 scatter-gather 条目 |
| `virtio_sg_list` | `entries[$]` | scatter-gather 列表 |
| `virtio_used_info` | `desc_id`, `len`, `submit_time`, `complete_time` | Used Ring 回收信息 |
| `virtqueue_snapshot_t` | `queue_id`, `queue_size`, 地址, 索引, `ring_data[]` | 队列迁移快照 |
| `iommu_mapping_t` | `host_id`, `bdf`, `gpa`, `iova`, `size`, `dir`, `desc_id` | Host-qualified DMA 映射记录 |
| `iommu_mapping_entry_t` | 同上 + `valid`, `map_time`, `caller_file`, `caller_line` | 带调试信息的映射 |
| `iommu_fault_rule_t` | `host_id/host_id_valid`, `bdf_mask`, `iova_start/end`, `dir`, `fault_type`, `trigger_count` | 可按 Host 限定的 Fault 注入规则 |
| `virtio_net_hdr_t` | `flags`, `gso_type`, `hdr_len`, `gso_size`, `csum_start/offset`, `num_buffers`, `hash_value/report` | virtio-net 头部 |
| `virtio_net_device_config_t` | `mac`, `status`, `max_virtqueue_pairs`, `mtu`, `speed`, `duplex`, RSS 字段 | 设备配置空间 |
| `virtio_pci_cap_t` | `cap_id`, `cap_next`, `cfg_type`, `bar`, `offset`, `length` | PCI capability 信息 |
| `msix_entry_t` | `msg_addr`, `msg_data`, `masked` | MSI-X 表条目 |
| `virtio_rss_config_t` | `hash_key_size`, `hash_key[]`, `indirection_table[]`, `hash_types` | RSS 配置 |
| `virtio_driver_config_t` | `num_queue_pairs`, `queue_size`, `vq_type`, `driver_features`, RX/IRQ 配置, 带宽限制 | 每 VF 驱动配置 |
| `pkt_latency_t` | 7 个时间戳字段 | 报文延迟分段统计 |
| `perf_stats_t` | `tx/rx_packets/bytes`, `start/end_time` | 性能统计 |
| `scoreboard_stats_t` | 13 个计数器 | Scoreboard 汇总统计 |
| `virtio_device_snapshot_t` | `negotiated_features`, `device_status`, `net_config`, `queue_snapshots[]` | 设备完整快照 (热迁移) |

#### 4.1.4 virtio_net_hdr_util 工具类

`virtio_net_hdr_util` 提供静态方法处理 virtio-net 头部的序列化和反序列化：

```systemverilog
// 获取头部大小 (10/12/20 字节)
static function int unsigned get_hdr_size(bit [63:0] features);

// 序列化: 结构体 -> 小端字节流
static function void pack_hdr(virtio_net_hdr_t hdr, bit [63:0] features,
                               ref byte unsigned data[$]);

// 反序列化: 小端字节流 -> 结构体
static function void unpack_hdr(byte unsigned data[$], bit [63:0] features,
                                 ref virtio_net_hdr_t hdr);
```

头部大小取决于协商的 feature：
- **10 字节**：基本头部
- **12 字节**：+ `num_buffers`（`VIRTIO_NET_F_MRG_RXBUF`）
- **20 字节**：+ `hash_value`, `hash_report`（`VIRTIO_NET_F_HASH_REPORT`）

#### 4.1.5 virtio_transaction 事务类

`virtio_transaction` 是 VIP 的核心 UVM sequence item，通过 `txn_type` 字段区分 16 种事务类型：

| 类别 | txn_type | 说明 |
|------|----------|------|
| 生命周期 | `VIO_TXN_INIT` | 完整初始化序列 |
| | `VIO_TXN_RESET` | 设备重置 |
| | `VIO_TXN_SHUTDOWN` | 关闭数据面 |
| 数据面 | `VIO_TXN_SEND_PKTS` | 发送报文 |
| | `VIO_TXN_WAIT_PKTS` | 等待接收报文 |
| | `VIO_TXN_START_DP` | 启动数据面 |
| | `VIO_TXN_STOP_DP` | 停止数据面 |
| 控制面 | `VIO_TXN_CTRL_CMD` | 控制 VQ 命令 |
| | `VIO_TXN_SET_MQ` | 设置多队列对数 |
| | `VIO_TXN_SET_RSS` | 配置 RSS |
| 原子操作 | `VIO_TXN_ATOMIC_OP` | MANUAL 模式单步操作 |
| 热迁移 | `VIO_TXN_FREEZE` | 冻结设备状态 |
| | `VIO_TXN_RESTORE` | 恢复设备状态 |
| 队列管理 | `VIO_TXN_RESET_QUEUE` | 单队列重置 |
| | `VIO_TXN_SETUP_QUEUE` | 队列配置 |
| 错误注入 | `VIO_TXN_INJECT_ERROR` | 注入错误 |

### 4.2 等待策略框架 (shared/virtio_wait_policy)

`virtio_wait_policy` 是 VIP 的统一等待框架。所有等待操作必须通过此类完成。

#### 4.2.1 超时配置表

| 参数 | 默认值 | 说明 |
|------|--------|------|
| `default_poll_interval_ns` | 10 | 寄存器轮询间隔 |
| `default_timeout_ns` | 10000 (10us) | 默认超时 |
| `flr_timeout_ns` | 10000 (10us) | VF FLR 完成超时 |
| `reset_timeout_ns` | 5000 (5us) | 设备重置超时 |
| `queue_reset_timeout_ns` | 5000 (5us) | 单队列重置超时 |
| `vf_ready_timeout_ns` | 10000 (10us) | VF 就绪超时 |
| `cpl_timeout_ns` | 5000 (5us) | PCIe Completion 超时 |
| `status_change_timeout_ns` | 5000 (5us) | 状态变化超时 |
| `rx_wait_timeout_ns` | 50000 (50us) | RX 报文等待超时 |
| `timeout_multiplier` | 1 | 全局超时乘数（压力测试可调大） |
| `max_poll_attempts` | 10000 | 绝对迭代上限（死锁保护） |

#### 4.2.2 三种等待方法

**1. `poll_until_flag()`** -- 通用轮询循环

```systemverilog
task poll_until_flag(
    string       description,      // 用于日志的描述文字
    int unsigned timeout_ns,       // 基础超时 (ns)
    int unsigned poll_interval_ns, // 轮询间隔 (ns), 最小 1
    ref bit      success_flag,     // 外部设置为 1 时退出
    ref bit      timed_out         // 超时时设为 1
);
```

**2. `wait_event_or_timeout()`** -- UVM 事件等待

```systemverilog
task wait_event_or_timeout(
    string       description,
    uvm_event    evt,              // 要等待的 UVM 事件
    int unsigned timeout_ns,
    ref bit      triggered         // 事件触发返回 1, 超时返回 0
);
```

使用 named fork 实现：
```systemverilog
fork : wait_evt_blk
    begin : evt_arm
        evt.wait_trigger();
        triggered = 1;
    end
    begin : timeout_arm
        #(eff_timeout * 1ns);
    end
join_any
disable wait_evt_blk;  // 只禁用本 fork 块
```

**3. `wait_event_or_poll()`** -- 事件+轮询混合

在每次轮询迭代中短暂等待事件，同时检查全局超时。适用于事件可能在进入等待前已触发的场景。

#### 4.2.3 安全规则

1. `poll_interval_ns` 被 clamp 到最小值 1，防止无限循环
2. `max_poll_attempts` 限制最大迭代次数，即使超时计算溢出也能保护
3. 有效超时 = `base_ns * timeout_multiplier`，乘法溢出时饱和到 `32'hFFFF_FFFF`
4. 所有成功等待以 `UVM_HIGH` 记录日志，失败以 `uvm_error` 报告
5. 所有 `forever` 后台任务检查 `running` 标志并响应 `stop_event`

### 4.3 内存屏障模型 (shared/virtio_memory_barrier_model)

`virtio_memory_barrier_model` 模拟 Linux 内核中的 `smp_wmb()`, `smp_rmb()`, `smp_mb()` 内存屏障。

在仿真中，内存屏障不影响时序（不插入 `#delay`），但提供三个重要功能：

1. **文档化**：每次屏障调用记录其意图和顺序要求
2. **统计**：计数器允许测试检查屏障使用是否正确
3. **错误注入**：skip 标志允许故意省略屏障，验证 scoreboard 能否检测到顺序违规

| 方法 | 对应内核函数 | 使用时机 | 注入标志 |
|------|-------------|----------|----------|
| `wmb()` | `smp_wmb()` | 写描述符后、更新 avail ring 前 | `skip_wmb_before_avail` |
| `rmb()` | `smp_rmb()` | 读取 used ring 前 | `skip_rmb_before_used` |
| `mb()` | `smp_mb()` | 更新 avail ring 后、检查通知抑制前 | `skip_mb_before_kick` |

```systemverilog
// 注入屏障跳过
barrier.inject_barrier_skip(VQ_ERR_SKIP_WMB_BEFORE_AVAIL);

// 清除所有注入
barrier.clear_all_skips();

// 打印统计
barrier.print_stats();
// 输出: "Memory barrier statistics: wmb=42 rmb=38 mb=42 skipped=0"
```

### 4.4 IOMMU 模型 (iommu/)

`virtio_iommu_model` 模拟 IOMMU 地址翻译功能，为 `VIRTIO_F_ACCESS_PLATFORM` feature 提供支持。

映射唯一键是 `{host_id[31:0], BDF[15:0], IOVA[63:0]}`。Host 之间拥有独立
IOVA bump cursor，因此 `host0 + 00:08.2 + 0x80000000` 与
`host1 + 00:08.2 + 0x80000000` 可以同时存在。生产路径从冻结的
`dpu_pcie_function_id_t.domain.host_id` 取得 Host；旧 API 和未绑定 PCIe identity
的 standalone 对象兼容地落到 host0。

IOMMU 只管理 DMA 地址空间。BAR aperture、notify address、MSI-X table/PBA、
QSCH/DSCH 和 global qpair placement 都由各自配置平面管理，不通过 `iommu.map()`。
本模型中的 Host key 不隐式创建独立 host memory：若不同 Host 还要复用相同数值
GPA、但访问不同字节内容，应分别注入 `host_mem_manager`；共享 manager 表示共享
GPA backing。

#### 4.4.1 核心接口

| 方法 | 签名 | 说明 |
|------|------|------|
| `map()` | `function bit[63:0] map(bdf, gpa, size, dir)` | 分配 IOVA, 创建映射，返回 IOVA |
| `map_for_host()` | `function bit[63:0] map_for_host(host_id, bdf, gpa, size, dir)` | 在显式 Host requester domain 创建映射 |
| `unmap()` | `function void unmap(bdf, iova)` | 移除映射，保存到 unmap_history |
| `unmap_for_host()` | `function void unmap_for_host(host_id, bdf, iova)` | 只移除目标 Host 的映射 |
| `translate()` | `function bit translate(bdf, iova, size, dir, ref gpa, ref fault)` | 地址翻译，成功返回 1 |
| `translate_for_host()` | `function bit translate_for_host(host_id, bdf, iova, size, dir, ref gpa, ref fault)` | Host-qualified 地址翻译 |
| `map_fixed_for_host()` | `function bit[63:0] map_fixed_for_host(host_id, bdf, gpa, size, dir, iova)` | 在迁移恢复时重建稳定 IOVA |
| `write_from_device_for_host()` | `function bit write_from_device_for_host(host_id, mem, bdf, iova, data, ref fault)` | 完成 device-write 并产生 Host-scoped dirty record |
| `add_fault_rule()` | `function void add_fault_rule(rule)` | 添加 fault 注入规则 |
| `clear_fault_rules()` | `function void clear_fault_rules()` | 清除所有规则 |
| `leak_check()` | `function void leak_check()` | 测试结束时检查未释放映射 |
| `reset()` | `function void reset()` | 重置所有状态 |

#### 4.4.2 IOVA 分配

每个 Host 使用独立 allocator。默认策略是 `IOMMU_IOVA_RANDOM`：在可配置的
page-aligned `[iova_base, iova_limit)` 64-bit aperture 中随机选择 4KB slot，并在
同一 `{host_id, BDF}` requester 域内检查 live mapping 的区间冲突；随机候选耗尽
后使用确定性的 first-fit，保证接近满 aperture 时仍能完成分配。可调用
`configure_iova_aperture(base, limit, IOMMU_IOVA_FIRST_FIT, why)` 切换为稳定布局。
IOVA 0 保留为失败返回值；不同 Host 的数值 IOVA 可以相同，因为 requester identity
包含 host-id。随机使用仿真器/UVM 的现有随机状态，不新增环境 seed 字段。

#### 4.4.3 翻译检查顺序

`translate()` 按以下顺序执行检查：

1. **Fault 注入规则检查** -- 首先检查是否有匹配的注入规则
2. **映射查找** -- 在目标 `{host_id, BDF}` 中查找覆盖该 IOVA 的有效映射
3. **Use-after-unmap 检测** -- live mapping 不存在时，仅检查同 Host/BDF 的 retired history
4. **范围检查** -- `(iova + size)` 不能超过映射范围
5. **权限检查** -- DMA 方向必须兼容
6. **GPA 计算** -- `gpa = entry.gpa + (iova - entry.iova)`
7. **脏页标记** -- 如果启用 dirty tracking

#### 4.4.4 Fault 注入规则

```systemverilog
iommu_fault_rule_t rule;
rule.host_id       = 1;
rule.host_id_valid = 1;                  // 0 表示兼容 wildcard，作用于所有 Host
rule.bdf_mask    = 16'hFFFF;           // 匹配所有 BDF
rule.iova_start  = 64'h8000_0000;
rule.iova_end    = 64'h8000_FFFF;
rule.dir         = DMA_BIDIRECTIONAL;  // 匹配所有方向
rule.fault_type  = IOMMU_FAULT_PERMISSION;
rule.trigger_count = 3;                // 触发 3 次后耗尽
rule.triggered   = 0;

iommu.add_fault_rule(rule);
```

#### 4.4.5 脏页追踪

为热迁移提供支持，以 4KB 粒度、按 Host 独立追踪完成的 device write：

```systemverilog
void'(iommu.begin_dirty_generation_for_host(host_id));
// ... write_from_device_for_host(host_id, ...) ...
bit [63:0] dirty_pages[$];
iommu.capture_dirty_generation_for_host(host_id, dirty_pages);
```

`begin_dirty_generation()` / `capture_dirty_generation()` 和旧 dirty helper 仍表示
host0。Host-scoped bitmap、mapping snapshot 和 generation state 不会因相同 GPA
page number 而在不同 Host 之间合并。

### 4.5 Virtqueue 层 (virtqueue/)

#### 4.5.1 抽象基类接口 (`virtqueue_base`)

`virtqueue_base` 是一个虚类（`virtual class`），继承自 `uvm_object`。定义了 18 个纯虚方法：

| 类别 | 方法 | 返回类型 | 说明 |
|------|------|----------|------|
| 生命周期 | `alloc_rings()` | void | 分配并初始化 ring 内存 |
| | `free_rings()` | void | 释放 ring 内存 |
| | `reset_queue()` | void | 重置队列状态 |
| | `detach_all_unused(ref tokens[$])` | void | 回收所有未完成的 token |
| 驱动操作 | `add_buf(sgs[], n_out, n_in, token, indirect)` | int unsigned | 添加 buffer 到描述符环 |
| | `kick()` | task | 通知设备（PCIe TLP） |
| | `poll_used(ref token, ref len)` | bit | 轮询 Used Ring |
| 通知控制 | `disable_cb()` | void | 抑制设备中断 |
| | `enable_cb()` | void | 使能设备中断 |
| | `enable_cb_delayed()` | void | EVENT_IDX 延迟使能 |
| | `vq_poll(last_used)` | bit | 检查是否有新完成 |
| 查询 | `get_free_count()` | int unsigned | 空闲描述符数量 |
| | `get_pending_count()` | int unsigned | 待完成描述符数量 |
| | `needs_notification()` | bit | 是否需要 kick |
| DMA 辅助 | `dma_map_buf(gpa, size, dir)` | bit[63:0] | DMA 映射 |
| | `dma_unmap_buf(iova)` | void | DMA 解映射 |
| 错误注入 | `inject_desc_error(err_type)` | void | 注入描述符错误 |
| 热迁移 | `save_state(ref snap)` | void | 保存队列快照 |
| | `restore_state(snap)` | void | 恢复队列快照 |

基类还提供公共实现：
- `setup()` -- 初始化外部引用
- `detach()` -- 重置并禁用
- `dump_ring()` -- 日志输出队列状态
- `leak_check()` -- 检测未释放 token 和 DMA 映射

#### 4.5.2 Split Virtqueue 实现

Split Virtqueue 使用三个独立的内存区域：

```
+---+---+---+---+---+---+---+---+    每个 16 字节
| D | D | D | D | D | D | D | D |    Descriptor Table (4096 对齐)
+---+---+---+---+---+---+---+---+    addr[63:0], len[31:0], flags[15:0], next[15:0]
  0   1   2   3   4   5   6   7

+---+---+---+---+---+---+---+---+    Available Ring (2 字节对齐)
|flg|idx| 0 | 1 | 2 |...|evt|   |    flags, idx, ring[queue_size], used_event
+---+---+---+---+---+---+---+---+

+---+---+---+---+---+---+---+---+    Used Ring (4096 对齐)
|flg|idx|id0|ln0|id1|ln1|...|evt|    flags, idx, ring[queue_size]={id,len}, avail_event
+---+---+---+---+---+---+---+---+
```

**关键操作流程：**

1. **alloc_rings()**: 从 `host_mem` 分配三个区域，初始化空闲描述符链表
2. **add_buf()**: 从空闲链表取描述符 -> 写入描述符 -> wmb() -> 更新 avail ring -> mb() -> 存储 token
3. **poll_used()**: rmb() -> 读取 used idx -> 比较 -> 读取 used entry -> 回收描述符链到空闲链表
4. **needs_notification()**: EVENT_IDX 模式使用 `vring_need_event` 算法；否则检查 `VIRTQ_USED_F_NO_NOTIFY` 标志

#### 4.5.3 Packed Virtqueue 实现

Packed Virtqueue 使用单环布局，AVAIL 和 USED 标志位嵌入描述符的 flags 字段：

```
+---+---+---+---+---+---+---+---+    每个 16 字节
| P | P | P | P | P | P | P | P |    Packed Descriptor Ring (4096 对齐)
+---+---+---+---+---+---+---+---+    addr[63:0], len[31:0], id[15:0], flags[15:0]
  0   1   2   3   4   5   6   7

+---+---+                             Driver Event Suppression (4 字节)
|DES|FLG|
+---+---+

+---+---+                             Device Event Suppression (4 字节)
|DES|FLG|
+---+---+
```

**Wrap Counter 机制：**

- `avail_wrap_counter` 初始为 1，每当 `next_avail_idx` 回绕到 0 时翻转
- AVAIL 标志位 = `avail_wrap_counter`，USED 标志位 = `!avail_wrap_counter`
- 设备通过 USED 标志位 = `used_wrap_counter` 来标记完成

**Event Suppression（DESC 模式）：**

通知抑制使用 wrap counter 感知的比较：
```systemverilog
if (avail_wrap_counter == dev_wrap)
    return (next_avail_idx >= dev_desc_idx);
else
    return (next_avail_idx < dev_desc_idx);
```

#### 4.5.4 Custom Virtqueue

`custom_virtqueue` 通过 `virtqueue_custom_callback` 回调接口将所有 ring 操作委托给用户实现。

**使用步骤：**

1. 继承 `virtqueue_custom_callback`，实现所有纯虚方法
2. 创建 `custom_virtqueue` 实例
3. 设置 `custom_cb` 引用
4. 可选：配置 `desc_entry_size` 和 `desc_field_defs[]`

**字段定义机制：**

```systemverilog
custom_vq.desc_entry_size = 32;  // 每个描述符 32 字节
custom_vq.desc_field_defs = '{"addr:64:0", "len:32:8", "flags:16:12",
                               "next:16:14", "metadata:128:16"};
// 格式: "name:width_bits:offset_bytes"

// 在回调中使用:
custom_vq.write_desc_field(idx, "metadata", 128'hDEADBEEF);
bit [63:0] val = custom_vq.read_desc_field(idx, "addr");
```

#### 4.5.5 Virtqueue Manager

`virtqueue_manager` 是队列的工厂和生命周期管理器：

```systemverilog
// 创建队列
virtqueue_base vq = vq_mgr.create_queue(queue_id, queue_size, VQ_SPLIT);

// 获取队列
virtqueue_base vq = vq_mgr.get_queue(queue_id);

// 销毁单个队列
vq_mgr.destroy_queue(queue_id);

// 销毁所有队列
vq_mgr.destroy_all();

// 回收所有队列的未完成 token
vq_mgr.detach_all_queues();

// 泄漏检查
vq_mgr.leak_check();
```

#### 4.5.6 错误注入器

`virtqueue_error_injector` 保存错误的语义类型、目标队列、操作计数、概率和
消费边界。`virtqueue_error_e` 是 27 项语义分类；配置一个枚举值并不意味着
所有队列路径都会自动产生对应的线上故障。配置示例：

```systemverilog
err_inj.configure(
    .err(VQ_ERR_CIRCULAR_CHAIN),   // 错误类型
    .after_n_ops(5),                // 第 5 次操作后注入
    .queue_id('1),                  // 任意队列 ('1 = wildcard)
    .probability(50),               // 50% 概率
    .fault_phase(VQ_FAULT_POST_NOTIFY)
);

// 在操作点检查
if (err_inj.should_inject(current_queue_id, VQ_FAULT_POST_NOTIFY)) begin
    // 执行错误注入逻辑
end
```

`fault_phase` 的五个取值表示队列/响应路径的消费边界：

| 边界 | 触发位置 | 当前责任方 |
|------|----------|------------|
| `VQ_FAULT_PRE_NOTIFY` | 写 avail/提交后、发出 notify 前 | split/packed 队列的生产路径 |
| `VQ_FAULT_POST_NOTIFY` | notify 已发出、设备读取前 | split/packed 队列的生产路径 |
| `VQ_FAULT_PRE_DEVICE_READ` | 设备/响应器准备读取 descriptor 前 | MODEL responder；REAL_DUT 需用户/平台另接 fault provider（当前未实现） |
| `VQ_FAULT_BEFORE_USED` | 写回 used ring 前 | MODEL responder；REAL_DUT 需用户/平台另接 fault provider（当前未实现） |
| `VQ_FAULT_ANY` | 匹配任意上述边界 | 通配选择，不是额外的时序点 |

不同阶段只会在相应的生产者或响应器路径消费规则；阶段不匹配时不会递增计数，
也不会提前消耗一次性注入。`ANY` 适用于测试不关心具体边界的情况，但仍要求
实际调用方提供一个具体阶段。同一 queue/responder 操作即使依次经过 PRE/POST 两个
hook，也只在第一个满足条件的边界注入一次；下一次操作会按相同
countdown/probability 规则重新参与选择。

#### 描述符字节级辅助 API

发布 descriptor 后，可以显式修改共享 Host memory 中的一个标准描述符：

```systemverilog
string why;
bit ok = err_inj.corrupt_descriptor(
    mem, desc_base, VQ_SPLIT, queue_size, descriptor_index,
    VQ_DESC_FIELD_LEN, 64'd0, why);
```

标准队列还提供面向 fixture 的封装，自动带入队列自己的 Host-memory handle、
descriptor table 地址、队列大小和 ring 格式：

```systemverilog
bit ok = vq.corrupt_published_descriptor(
    descriptor_index, VQ_DESC_FIELD_FLAGS, 16'h0000, why);
```

`virtio_desc_corruption_field_e` 当前只允许以下五种 wire 字段：
`VQ_DESC_FIELD_ADDR`、`VQ_DESC_FIELD_LEN`、`VQ_DESC_FIELD_FLAGS`、
`VQ_DESC_FIELD_NEXT`（仅 Split）和 `VQ_DESC_FIELD_ID`（仅 Packed）。辅助 API
会检查 Host-memory handle、16 字节对齐、descriptor index/队列范围、地址算术
溢出、ring 格式和字段宽度；Custom virtqueue 因布局由用户定义而被拒绝，不能
猜测字段偏移。

队列的通用 `process_error_injection(fault_phase)` 目前只把以下语义错误转换成
真实的描述符字节变异：`VQ_ERR_ZERO_LEN_BUF`（LEN）、`VQ_ERR_DESC_UNALIGNED`
（ADDR）、`VQ_ERR_WRONG_FLAGS`（FLAGS）、`VQ_ERR_OOB_INDEX`/`VQ_ERR_STALE_DESC`
（Split 的 NEXT 或 Packed 的 ID）、`VQ_ERR_CIRCULAR_CHAIN`（Split 的 NEXT
或 Packed 的 FLAGS），以及 Packed ring 的 `VQ_ERR_AVAIL_USED_FLAG_CORRUPT`
（FLAGS）。因此“支持五种字段”不等于“27 种语义错误都能通过该 helper 自动
实现”。

其余错误必须接入与故障语义相匹配的专用 hook，不能由通用 descriptor helper
伪造：例如 avail/used ring 索引和 EVENT_IDX/WRAP 错误需要 ring hook；
`KICK_BEFORE_ENABLE`、`KICK_AFTER_DISABLE`、`DETACH_WHILE_ACTIVE` 等需要
状态机 hook；`USE_AFTER_UNMAP`、`WRONG_DMA_DIR`、`IOMMU_FAULT_ON_*` 需要
IOMMU/DMA hook；`SPURIOUS_INTERRUPT` 需要中断 hook；屏障省略错误需要对应
memory-order hook。若没有这些专用 hook，配置的语义枚举会保持未消费状态，不能
在报告中计为已注入。

### 4.6 PCI 传输层 (transport/)

#### 4.6.1 寄存器偏移常量

Common Config 寄存器按 virtio spec Section 4.1.4.3 定义：

| 偏移 | 宽度 | 名称 | 说明 |
|------|------|------|------|
| 0x00 | 32 | `DFSELECT` | Device Feature Select |
| 0x04 | 32 | `DF` | Device Feature (RO) |
| 0x08 | 32 | `GFSELECT` | Guest/Driver Feature Select |
| 0x0C | 32 | `GF` | Guest/Driver Feature |
| 0x10 | 16 | `MSIX` | Config MSI-X Vector |
| 0x12 | 16 | `NUMQ` | Num Queues (RO) |
| 0x14 | 8 | `STATUS` | Device Status |
| 0x15 | 8 | `CFGGENERATION` | Config Generation (RO) |
| 0x16 | 16 | `Q_SELECT` | Queue Select |
| 0x18 | 16 | `Q_SIZE` | Queue Size |
| 0x1A | 16 | `Q_MSIX` | Queue MSI-X Vector |
| 0x1C | 16 | `Q_ENABLE` | Queue Enable |
| 0x1E | 16 | `Q_NOFF` | Queue Notify Offset (RO) |
| 0x20 | 32 | `Q_DESCLO` | Queue Desc Addr Low |
| 0x24 | 32 | `Q_DESCHI` | Queue Desc Addr High |
| 0x28 | 32 | `Q_AVAILLO` | Queue Avail Addr Low |
| 0x2C | 32 | `Q_AVAILHI` | Queue Avail Addr High |
| 0x30 | 32 | `Q_USEDLO` | Queue Used Addr Low |
| 0x34 | 32 | `Q_USEDHI` | Queue Used Addr High |
| 0x38 | 16 | `Q_NDATA` | Queue Notify Data (1.2+) |
| 0x3A | 16 | `Q_RESET` | Queue Reset (1.2+) |

#### 4.6.2 BAR 访问器 (`virtio_bar_accessor`)

BAR 访问器将 MMIO 寄存器访问翻译为 PCIe TLP：

| 方法 | TLP 类型 | 说明 |
|------|----------|------|
| `read_reg(bar_id, offset, size, data)` | Memory Read | BAR MMIO 读 |
| `write_reg(bar_id, offset, size, data)` | Memory Write | BAR MMIO 写 |
| `config_read(addr, data)` | Config Read Type 0 | 配置空间读 |
| `config_write(addr, data, be)` | Config Write Type 0 | 配置空间写 |
| `enumerate_bars()` | Config Read/Write | PCI BAR 枚举 |
| `read_reg_with_error(...)` | Memory Read (BE=0) | 错误注入读 |
| `write_reg_with_error(...)` | Memory Write (BE=0) | 错误注入写 |

`enumerate_bars()` 的“保存原值 → 写全 1 → 读回 → 计算大小 → 分配地址 → 写入”
流程仅适用于 legacy/TLM 模型路径，支持 32/64 位 BAR。Fabric-owned REAL_DUT
禁止 sizing/enumeration；地址必须来自冻结 dpu_common lease，并由
`program_fabric_bar_pairs()` 编程 config-space BAR 后再发现 capability。

#### 4.6.3 Capability 发现 (`virtio_pci_cap_manager`)

遍历 PCI 配置空间的 capability 链表（从 `CAP_PTR` 0x34 开始），解析以下 capability：

| cfg_type | 名称 | 必需 |
|----------|------|------|
| 1 | Common Configuration | 必需 |
| 2 | Notification | 必需 |
| 3 | ISR Status | 必需 |
| 4 | Device-specific Configuration | 推荐 |
| 5 | PCI Configuration Access | 可选 |
| 0x11 | MSI-X | 推荐 |

对于 Notification capability，还会读取 `notify_off_multiplier`（偏移 +16）。

#### 4.6.4 通知管理器 (`virtio_notification_manager`)

支持四种中断模式和三级 IRQ 回退：

```
Per-queue MSI-X (N+1 vectors)
         |
         v (不够 vectors)
Shared MSI-X (3 vectors: config + rx_shared + tx_shared)
         |
         v (没有 MSI-X)
INTx fallback
```

**NAPI 模式支持：**
- `enter_polling_mode(queue_id)` -- 禁用该队列的中断回调
- `exit_polling_mode(queue_id)` -- 恢复中断回调

**错误注入：**
- `inject_spurious_interrupt(vector)` -- 注入虚假中断
- `inject_missed_interrupt(queue_id)` -- 注入丢失中断
- `inject_wrong_vector(queue_id)` -- 注入错误向量中断

#### 4.6.5 PCI Transport 封装 (`virtio_pci_transport`)

封装完整的 virtio PCI 传输协议，提供高层接口。

**完整初始化序列** (`full_init_sequence()`)：

```
Step 1: reset_device()                    -- 写 status=0, 轮询直到读回 0
Step 2: write_status(ACKNOWLEDGE)         -- 确认设备存在
Step 3: write_status(ACKNOWLEDGE|DRIVER)  -- 声明驱动身份
Step 4: negotiate_features()              -- 两阶段 feature 协商
Step 5: write_status(|FEATURES_OK)        -- 确认 feature, 轮询验证
Step 6: read_num_queues()                 -- 获取设备支持的队列数
Step 7: Per-queue discovery               -- 读取 max_size, notify_off
Step 8: setup_msix()                      -- MSI-X 表初始化 + 向量绑定
Step 9: write_status(|DRIVER_OK)          -- 驱动就绪
```

**Kick 机制：**

```systemverilog
// 标准 kick: 写 queue_id 到 notify offset
bar.write_reg(notify_bar, notify_offset, 2, queue_id);

// NOTIFICATION_DATA kick: 写 32-bit 扩展数据
// Split: {next_avail_idx[15:0], queue_id[15:0]}
// Packed: {wrap_counter, next_avail_idx[14:0], queue_id[15:0]}
bar.write_reg(notify_bar, notify_offset, 4, notify_data);
```

### 4.7 驱动 Agent (agent/)

#### 4.7.1 双层架构

```
                    virtio_driver_agent
                    /        |        \
         virtio_driver   virtio_monitor  virtio_sequencer
              |                |
     +--------+--------+     被动观察 TLP
     |                  |
virtio_auto_fsm   virtio_atomic_ops
(AUTO mode)       (MANUAL mode)
     |                  |
     +--------+---------+
              |
     virtio_pci_transport
     virtqueue_manager
     host_mem_manager
     virtio_iommu_model
```

#### 4.7.2 原子操作库 (`virtio_atomic_ops`)

每个方法对应一个真实的 Linux virtio-net 驱动操作：

| 类别 | 方法 | 说明 |
|------|------|------|
| 设备发现 | `device_reset()` | 写 status=0, 轮询 |
| | `set_acknowledge()` | 设置 ACKNOWLEDGE |
| | `set_driver()` | 设置 DRIVER |
| | `negotiate_features(supported, ref negotiated)` | Feature 协商 |
| | `set_features_ok(ref ok)` | 设置 FEATURES_OK 并验证 |
| | `set_driver_ok()` | 设置 DRIVER_OK |
| | `set_failed()` | 设置 FAILED |
| 队列管理 | `setup_queue(qid, size, type)` | 配置单个队列 |
| | `setup_all_queues(num_pairs, type, size)` | 配置所有队列 |
| | `teardown_queue(qid)` | 拆除队列 |
| | `reset_queue(qid)` | 重置单个队列 (1.2+) |
| MSI-X | `setup_msix(num_queues)` | MSI-X 初始化和向量绑定 |
| TX | `tx_submit(qid, hdr, pkt, indirect, ref desc_id)` | 提交发送报文 |
| | `tx_complete(qid, ref pkts, budget)` | 完成回收 |
| RX | `rx_refill(qid, count)` | 补充 RX buffer |
| | `rx_receive(qid, ref pkts, budget)` | 接收报文 |
| 控制 VQ | `ctrl_send(cls, cmd, data, ref ack)` | 发送控制命令 |
| | `ctrl_set_mq_pairs(num_pairs, ref ok)` | 设置多队列对数 |
| | `ctrl_set_rss(cfg, ref ok)` | 配置 RSS |
| | `ctrl_announce_ack(ref ok)` | GUEST_ANNOUNCE 确认 |

#### 4.7.3 自动状态机 (`virtio_auto_fsm`)

**FSM 状态转换图：**

```
FSM_IDLE ----full_init()----> FSM_DISCOVERING
                                    |
                                    v
                              FSM_NEGOTIATING
                                    |
                                    v
                              FSM_QUEUE_SETUP
                                    |
                                    v
                              FSM_MSIX_SETUP
                                    |
                                    v
               +------------  FSM_READY  <-----------+
               |                    |                 |
    start_dataplane()          stop_dataplane()       |
               |                    |                 |
               v                    |                 |
          FSM_RUNNING  --------+----+                 |
               |               |                      |
         (DEVICE_NEEDS_RESET)  |  freeze_for_migration()
               |               |         |
               v               |    FSM_SUSPENDING
          FSM_ERROR            |         |
               |               |         v
               v               |    FSM_FROZEN
          FSM_RECOVERING ------+         |
                                    restore_from_migration()
                                         |
                                    FSM_READY -> FSM_RUNNING
```

**后台任务：**

所有后台任务在 `fork : dataplane_tasks ... join_none` 中启动：

| 任务 | 功能 |
|------|------|
| `rx_refill_loop(queue_id)` | 定期检查 RX 队列空闲描述符，达到阈值时补充 |
| `tx_complete_loop(queue_id)` | 定期轮询 TX 队列 Used Ring，回收已完成描述符 |
| `interrupt_handler_loop()` | 等待中断事件，触发 used_ring_updated_event |
| `adaptive_irq_loop()` | 根据报文完成速率在 MSI-X 和 polling 间切换 |
| `config_change_handler()` | 监控设备配置变化（链路状态、DEVICE_NEEDS_RESET） |

停止数据面：`dataplane_running = 0; -> stop_event;`，所有后台任务在下次循环检查时退出。

#### 4.7.4 UVM Driver

`virtio_driver` 接收 `virtio_transaction` 并按 `txn_type` 分发：

```systemverilog
case (req.txn_type)
    VIO_TXN_INIT:       fsm.full_init();
    VIO_TXN_SEND_PKTS:  fsm.send_packets(req.packets, req.queue_id);
    VIO_TXN_ATOMIC_OP:  dispatch_atomic_op(req);
    VIO_TXN_FREEZE:     fsm.freeze_for_migration(req.snapshot);
    // ... 16 种事务类型
endcase
```

### 4.8 数据面 (dataplane/)

#### 4.8.1 TX Engine

TX 引擎负责将 `net_packet` 生成的报文组装成 virtio 描述符链：

1. **build_net_hdr()**: 根据 offload feature 构建 virtio-net 头部
2. **offload 检查**: 如果需要 TSO/USO，调用相应分段引擎
3. **standard_tx_build_chain()**: 构建 SG 链 `[net_hdr_sg] [pkt_data_sg]`
4. **vq.add_buf()**: 填写描述符
5. **kick()**: 如果 `needs_notification()` 返回 true

#### 4.8.2 RX Engine

RX 引擎支持三种 buffer 模式：

| 模式 | Feature | Buffer 大小 | 说明 |
|------|---------|-------------|------|
| `RX_MODE_MERGEABLE` | `MRG_RXBUF` | 小 buffer (如 1526) | 通过 `num_buffers` 合并多个 buffer |
| `RX_MODE_BIG` | - | 大 buffer (如 65535) | 单个 buffer 容纳完整报文 |
| `RX_MODE_SMALL` | - | 页大小 (4096) | 单页 buffer |

RX 自动补充：当空闲描述符数量低于阈值（默认 `queue_size / 4`）时自动补充。

#### 4.8.3 net_packet 多队列收发验证

`virtio_net_packet_multi_queue_test` 使用共享的 `host_mem_manager`、IOMMU 和
`virtqueue_manager` 创建四个 split virtqueue：q0/q2 为 RX，q1/q3 为 TX；每个
队列提交/接收 4 个由外部 `net_packet` master 生成的 `packet_item`。TX 侧从
descriptor 中取出 IOVA，经 IOMMU 翻译后校验真实报文字节；RX 侧通过
`write_from_device_for_host()` 写入 IOVA，再由 RX engine 恢复 `packet_item`。
测试同时检查 used ring 回收、跨队列隔离和 Host memory/IOMMU/virtqueue 无泄漏。

`packet_item.do_pack()` 是 UVM 序列化格式，包含长度字段；virtio 线速数据只使用
`packet_item.pkt.raw_data`，不会把 UVM framing 字节放进 descriptor。

上面的测试是 dataplane/内存语义专项，设备写入通过绑定的 IOMMU/Host-memory
接口完成；需要验证真实 PCIe transport 时使用
`virtio_real_driver_multiqueue_test`。MODEL 模式下该测试从 PCI capability
discovery 和两对 queue setup 开始，把外部 `net_packet` 的 `packet_item` 交给生产
`tx_submit()`，由 `virtio_pcie_dut_responder` 通过 EP-originated PCIe DMA
读取 descriptor/payload、写 used ring 并产生中断，最后由 driver `tx_complete()`
回收。测试覆盖冻结映射得到的两对 TX queue（默认 q1/q3），每队列 4 个报文，并
检查 Host/IOMMU/queue 无泄漏。REAL_DUT 模式不创建这个 responder，只被动观察真实
notify、DMA、interrupt 和 driver completion；它要求真实 PCIe 双向链路，以及外部
backend 或显式 Host-memory responder。

`virtio_real_driver_rx_test` 当前仅是 MODEL RX 闭环：driver 通过生产 `rx_refill()`
分配/映射可写 buffer，MODEL responder 从待注入的 `packet_item` 生成 virtio-net
header 和线速 payload，再通过 EP-originated PCIe DMA Write 写入 buffer，随后更新
used ring、产生中断，最后由生产 `rx_receive()` 解码并回收 GPA/IOVA。测试不直接写
Host memory、descriptor 或 used ring。REAL_DUT 下该测试会明确报告
`REAL_DUT_RX_SOURCE_UNAVAILABLE`，因为当前工程尚未提供平台物理/net_packet RX
ingress callback；不能把 MODEL 注入路径当作 RTL RX 覆盖。

#### 4.8.4 Offload Engine

| 引擎 | 功能 |
|------|------|
| `virtio_csum_engine` | TX: 计算伪头部 checksum; RX: 验证完整 checksum |
| `virtio_tso_engine` | TCP 分段，更新 IP/TCP 头部 |
| `virtio_uso_engine` | UDP 分段（1.2+） |
| `virtio_rss_engine` | Toeplitz hash 计算, 间接表查找, 队列选择 |

#### 4.8.5 Failover Manager

管理 `VIRTIO_NET_F_STANDBY` 的 failover 状态机：

```
FO_NORMAL -----(primary down)----> FO_PRIMARY_DOWN
                                        |
                                        v
                                   FO_SWITCHING
                                        |
                                        v
                                   FO_STANDBY_ACTIVE
                                        |
                              (primary recovered)
                                        |
                                        v
                                   FO_FAILBACK -> FO_NORMAL
```

### 4.9 SR-IOV (sriov/)

#### 4.9.1 PF Manager

`virtio_pf_manager` 不重新实现 SR-IOV 管理，而是**委托给 `pcie_tl_vip` 的 `func_manager`**：

- PF/VF 上下文管理、BDF 计算、VF 使能/禁用
- 每 VF 配置空间、SR-IOV Capability 寄存器

virtio 层只管理 virtio 专有状态：
- `virtio_vf_resource_pool`: local_qid <-> global_qid 映射
- `failover_manager`: STANDBY feature
- `admin_vq`: PF 管理队列（1.2+）
- VF 生命周期: 创建/配置/激活/FLR/禁用

#### 4.9.2 VF Resource Pool

`virtio_vf_resource_pool` 是冻结 placement binding 的只读、service-keyed queue
view，不根据 VF 位置创建或修改资源：

```systemverilog
typedef struct {
    dpu_service_key_t service_key;
    int unsigned local_qid;
    int unsigned global_qid;
    string       queue_name;
} virtio_local_queue_mapping_t;
```

#### 4.9.3 VF Instance

`virtio_vf_instance` 封装单个 VF 的所有组件：`virtio_driver_agent`、`virtqueue_manager`、`virtio_pci_transport`、`virtio_net_dataplane`。底层 nonvirtual `wire_shared()` 返回 `bit`，只有 MQ capability guard 和全部组件接线成功才返回 1；环境集成应统一调用 `virtio_net_env::bind_pcie()`，不直接逐 VF 接线。

#### 4.9.4 VF FLR 流程

```
1. Virtio: on_flr()          -- detach 所有队列, 清理 DMA
2. PCIe: Config Write FLR    -- 通过 pcie_tl_vip
3. poll_config_until()       -- 等待 VF 再次可访问
4. 可选: 重新初始化          -- full_init()
```

FLR 不会重新运行 placement 或重写 frozen binding：同一个 complete service key 的
local/global qpair identity 在 reset 前后保持不变；只有 VIO runtime transport state
会被清理和重建。

### 4.10 环境层 (env/)

#### 4.10.1 配置对象 (`virtio_net_env_config`)

`virtio_net_env_config` 只拥有 VIO driver/queue/traffic/verification behavior。
Global topology 由 `dpu_device_cfg` 显式声明 host、domain、PF/VF、可选 VF pool、
每个 function 的 BAR request、AF 和 VIO eligibility；
`dpu_resource_placement_cfg` 同时声明 `virtio.qpair` profile 与 VIO placement
requests。`dpu_device_env` 原子地解析这两个输入，发布精确关联且冻结的
`dpu_device_snapshot` / `dpu_resource_snapshot` pair，并以它 seed query-only
`dpu_resource_manager`。VIO 不包含 host/PF/VF topology、DUT capability、BDF、BAR
或 qpair authoring 字段，也不从 count matrix 或位置推导它们。

上述显式场景使用 real-DUT profile：PF0 与 VF0 各有
BAR0/1 `DPU_BAR_DEVICE_MEMORY`、BAR2/3 `DPU_BAR_MAILBOX` 和 BAR4/5
`DPU_BAR_MSIX`。PF0 通过 `DPU_AF_SELECTED` 被选为 AF，AF declaration 使用
BAR0 + `DPU_AF_DECLARATION_ADDR` (`0x1010`)。resolver 从 placement request 生成
完整 `dpu_service_key_t` (`{function_key, service_kind, service_instance_id}`)；
`virtio_net_env_config` 以这个完整 key 配置行为，例如：

```systemverilog
dpu_service_key_t vf0_vio;
virtio_driver_config_t behavior;
string why;

vf0_vio = builder.allow_vio_service(vf0);
behavior = vio_cfg.make_default_driver_config(32);
behavior.num_queue_pairs = 8;
if (!vio_cfg.add_service_config(vf0_vio, behavior, why))
  `uvm_fatal("CFG", why)
```

这个 override 由全 service key 索引，不使用 VF 队列位置。VIO build 只接受精确
frozen snapshot pair 和 pair-seeded manager；`virtio_resource_client` 按 service
导入不可变 qpair mapping，`virtio_vf_resource_pool` 提供同一 mapping 的 service-keyed
local/global queue lookup。Global config 与 VIO config 分别通过 `uvm_config_db`
传入 `dpu_device_env` 及其 VIO child；bootstrap plan 只读 device snapshot，
`dpu_reg_executor` 在 `dpu_device_env_config.executor` 中与 plan construction 分开
注入。仓库提供 `pcie_tl_dpu_reg_backend`/`pcie_tl_dpu_reg_executor` 作为 PCIe-TL
实现：backend 绑定 `pcie_tl_virtual_sequencer` 和 frozen `dpu_device_snapshot`，将
配置空间写入、BAR-relative MMIO 写入/回读转换为真实 PCIe TLP。MMIO 执行时按
`BDF + BAR id` 从 snapshot 解析绝对地址 `BAR base + operation.address`，posted
Memory Write 不等待不存在的 Completion，读回和显式 barrier 用于建立可观察顺序；
Completion status、读回值和 4KB TLP 边界都会检查。用户平台可继承同一 backend，或
直接替换 executor；未注入 executor 时仍报告 `NOT_EXECUTED`。

VIO behavior 可配置参数：

Host memory 的所有权与业务配置分离。顶层 DPU/Host 环境应为每个
`host_id` 创建一个 `host_mem_pool` entry，并把同一个 manager 注入该 Host
上的 VIO、RDMA、VBLK 子环境；不同 Host 创建不同 entry，即使数值 GPA 区间相同也
不会互相覆盖。若不注入 `host_mem_binding`，`virtio_net_env` 为兼容旧测试创建
单个 manager。也可以设置 `host_mem_pool_binding`，环境会按 `host_id` 查找
manager；它与 `host_mem_binding` 互斥，pool 中不存在该 Host 时在 build 阶段失败。
默认 `HOST_MEM_RANDOM` 使用仿真器随机状态在初始化 aperture 内选取对齐地址，
`HOST_MEM_FIRST_FIT` 用于稳定调试；随机地址始终有真实 backing storage。
冻结的 `dpu_device_snapshot` 会在 VIO 分配 ring/buffer 前自动导入当前 Host 的
BAR reservation：BAR 完全位于 host memory aperture 时会被排除，位于独立 MMIO
空间时跳过，部分相交则拒绝配置；同一 BAR 的重复导入是幂等的。手工使用
`reserve_range()` 时 base/size 需按 manager granule 对齐，之后 allocator 不会返回
保留区间。该阶段不改变 IOVA 模型；IOVA 仍与 GPA/BAR 保持独立地址空间。只有 DUT
明确使用统一地址译码时，才应在平台 backend 增加显式的 IOVA→GPA 处理，不能由
PCIe executor 默默替换 BAR 地址。

真实 DUT 的 PCIe DMA responder 复用这个 manager，不在 VIO 环境内复制 Host
memory 或 allocator；其 `virtio_pcie_iova_host_mem_proxy` 负责把设备 IOVA 翻译为
共享 Host GPA，并执行权限/dirty-page 检查。顶层先创建所有 Host entry，再把 VIO
和 PCIe 配置指向同一所有权源：

```systemverilog
host_mem_pool host_mem_owners;
host_mem_api  host0_mem;
host_mem_api  host1_mem;
string        why;

void'(host_mem_owners.create_host(0, host0_base, host0_end));
void'(host_mem_owners.create_host(1, host1_base, host1_end));
host0_mem = host_mem_owners.get_host(0);
host1_mem = host_mem_owners.get_host(1);

device_cfg.host_mem_pool_ref = host_mem_owners;
if (!pcie_cfg.bind_host_memory(0, 0, host0_mem, why) ||
    !pcie_cfg.bind_host_memory(1, 1, host1_mem, why))
  `uvm_fatal("TOP_CFG", why)
```

第一个参数是 `pcie_tl_env` 的 Root/RC 数组下标，第二个参数是 manager 的
`host_id`。配置层拒绝 null、Host-ID 不匹配、重复 Root、缺项和超范围绑定；显式
绑定模式要求 `0..num_roots-1` 全覆盖。`pcie_tl_env.host_mem_by_root[root]` 和相应
`rc_agents[root].rc_driver.mem` 保存同一个 handle，`pcie_tl_env.host_mem` 仅是
root0 兼容 alias。在普通 REAL_DUT IOVA 路径中，DUT/EP 发出的 MWr/MRd 先经过该
proxy，再更新或读取 Host backing storage；若外部 pcie_work backend 已自带
Host-memory responder，则由 backend 完成对应翻译/Completion，环境不能再重复安装
本地 responder。只有显式 legacy direct-GPA 模式才是 TLP 地址直接作为 GPA。两个
Host 即使使用相同 GPA 数值也不会串扰，因为 Root
持有不同 manager 对象。manager 已初始化时 PCIe 环境不再调用 `init_region()`；
未初始化的旧单 Root config-db manager 仍使用原有 0..4-GiB 默认 aperture。
`PCIE_TL_MEM_PREMAP` 针对唯一 manager handle 只分配一次；多个 Root 共享同一
Host manager 时不会重复消耗 aperture。当前 `pcie_work/main` 在空间不足时会先由
`host_mem_manager.alloc()` 报告 `HOST_MEM` allocator error，但该版本的
PREMAP 初始化没有检查失败哨兵，因此不保证额外产生 `PCIE_TL_HOST_MEM` fatal。
验证环境应把任一 allocator 失败视为配置失败，并在后续依赖升级后重新核对报告
级别；不能把某个 fatal ID 当作跨版本契约。

| 类别 | 参数 | 默认值 | 说明 |
|------|------|--------|------|
| 默认值 | `default_num_pairs` | 1 | 默认队列对数 |
| | `default_queue_size` | 256 | 默认队列大小 |
| | `default_vq_type` | `VQ_SPLIT` | 默认队列类型 |
| | `default_driver_features` | `'1` | 默认 feature（全开） |
| | `default_rx_mode` | `RX_MODE_MERGEABLE` | 默认 RX 模式 |
| | `default_irq_mode` | `IRQ_MSIX_PER_QUEUE` | 默认中断模式 |
| | `default_napi_budget` | 64 | NAPI 预算 |
| | `default_rx_buf_size` | 1526 | RX buffer 大小 |
| | `default_driver_mode` | `DRV_MODE_AUTO` | 默认驱动模式 |
| 内存 | `mem_base` | `64'h1_0000_0000` | host_mem 起始地址 |
| | `mem_end` | `64'h1_FFFF_FFFF` | host_mem 结束地址 |
| | `host_id` | 0 | 当前环境所属 Host 地址域 |
| | `host_mem_policy` | `HOST_MEM_RANDOM` | Host memory 放置策略；可选 `HOST_MEM_FIRST_FIT` |
| | `host_mem_binding` | `null` | 注入由顶层 `host_mem_pool` 持有的共享 manager |
| | `host_mem_pool_binding` | `null` | 注入按 `host_id` 管理多个 manager 的共享 pool；与 `host_mem_binding` 互斥 |
| IOMMU | `iommu_strict` | 1 | 严格权限检查 |
| 性能 | `bw_limit_enable` | 0 | 带宽限制开关 |
| | `bw_limit_mbps` | 0 | 带宽限制值 (Mbps) |
| 验证 | `scb_enable` | 1 | Scoreboard 开关 |
| | `cov_enable` | 0 | Coverage 开关 |
| Failover | `failover_enable` | 0 | Failover 开关 |
| | `primary_vf_id` | 0 | 主 VF ID |
| | `standby_vf_id` | 1 | 备 VF ID |

#### 4.10.2 Scoreboard（8 个检查类别）

| 类别 | 开关 | 检查内容 |
|------|------|----------|
| 数据完整性 | `chk_data_integrity` | TX/RX 报文数据匹配 |
| Offload 正确性 | `chk_offload_correct` | checksum/GSO 字段验证 |
| 队列协议 | `chk_queue_protocol` | 描述符链、ring 操作正确性 |
| Feature 合规 | `chk_feature_compliance` | 操作符合协商的 feature |
| 通知 | `chk_notification` | kick/中断协议正确性 |
| DMA 合规 | `chk_dma_compliance` | 地址范围、方向、映射有效性 |
| 顺序 | `chk_ordering` | 队列内完成顺序 |
| 配置一致性 | `chk_config_consistency` | 设备配置值匹配 |

#### 4.10.3 Coverage（8 个 Covergroup）

| Covergroup | 内容 | 默认状态 |
|------------|------|----------|
| `cg_features` | 队列类型、feature 组合、交叉覆盖 | OFF |
| `cg_queue_ops` | 队列大小、深度、操作类型 | OFF |
| `cg_dataplane` | 报文大小、burst 长度、队列利用率 | OFF |
| `cg_offload` | checksum 标志、GSO 类型、segment 大小 | OFF |
| `cg_notification` | 中断模式、coalescing、通知抑制 | OFF |
| `cg_errors` | 错误注入类型、fault 分类 | OFF |
| `cg_lifecycle` | 设备状态转换、reset 类型 | OFF |
| `cg_sriov` | VF 数量、FLR、并发 VF 操作 | OFF |

#### 4.10.4 Performance Monitor

**带宽限制：** 使用同步 token bucket（无后台任务）：
- bucket 大小 = `bw_limit_mbps * 125`（1ms 的字节量）
- `sync_refill()` 在每次调用时按仿真时间比例补充 token

**延迟剖析：** 7 阶段时间戳：
`desc_fill_time` -> `kick_time` -> `device_start_time` -> `device_done_time` -> `interrupt_time` -> `poll_time` -> `complete_time`

报告: min/max/avg/p50/p95/p99 延迟。

### 4.11 Sequence 库 (seq/)

#### 4.11.1 Base Sequences

| 序列 | 功能 |
|------|------|
| `virtio_base_seq` | 所有序列的基类 |
| `virtio_init_seq` | 完整初始化（INIT + START_DP） |
| `virtio_tx_seq` | 发送 N 个报文 |
| `virtio_rx_seq` | 等待接收 N 个报文 |
| `virtio_ctrl_seq` | 控制 VQ 命令 |
| `virtio_queue_setup_seq` | 单队列配置 |
| `virtio_kick_seq` | 显式 kick |

#### 4.11.2 Scenario Sequences

| 目录 | 序列 | 测试场景 |
|------|------|----------|
| `lifecycle/` | `virtio_lifecycle_full_seq` | 完整 init-traffic-shutdown 生命周期 |
| | `virtio_status_error_seq` | 状态转换错误（跳过 ACKNOWLEDGE 等） |
| | `virtio_feature_error_seq` | Feature 协商错误（部分写入等） |
| `dataplane/` | `virtio_tso_seq` | TCP/UDP 分段验证 |
| | `virtio_mrg_rxbuf_seq` | MRG_RXBUF 合并接收 |
| | `virtio_rss_distribution_seq` | RSS 队列分发验证 |
| | `virtio_csum_offload_seq` | Checksum offload 验证 |
| | `virtio_tunnel_pkt_seq` | 隧道报文处理 |
| `interrupt/` | `virtio_adaptive_irq_seq` | 自适应 IRQ 切换 |
| | `virtio_event_idx_boundary_seq` | EVENT_IDX 边界条件 |
| `migration/` | `virtio_live_migration_seq` | 热迁移 freeze/restore |
| | `virtio_failover_seq` | STANDBY failover |
| `sriov/` | `virtio_multi_vf_init_seq` | 多 VF 并行初始化 |
| | `virtio_vf_flr_isolation_seq` | VF FLR 隔离验证 |
| | `virtio_mixed_vq_type_seq` | 混合队列类型 |
| `error/` | `virtio_desc_error_seq` | 描述符错误注入 |
| | `virtio_iommu_fault_seq` | IOMMU fault 注入 |
| | `virtio_pcie_cross_error_seq` | PCIe 层错误 |
| | `virtio_bad_packet_seq` | 异常报文 |
| `concurrency/` | `virtio_concurrent_vf_traffic_seq` | 多 VF 并发流量 |
| `dynamic/` | `virtio_live_mq_resize_seq` | 运行时 MQ 调整 |
| `boundary/` | `virtio_boundary_seq` | 边界条件（min/max queue 等） |

#### 4.11.3 Virtual Sequences

| 序列 | 用途 |
|------|------|
| `virtio_smoke_vseq` | 冒烟测试：init -> 少量 traffic -> reset |
| `virtio_full_init_traffic_vseq` | 完整 init + 中等流量 |
| `virtio_multi_vf_vseq` | 多 VF 并行操作 |
| `virtio_stress_vseq` | 压力测试：大流量、极端参数 |

### 4.12 回调扩展点 (callbacks/)

#### 4.12.1 数据面回调 (`virtio_dataplane_callback`)

```systemverilog
virtual class virtio_dataplane_callback extends uvm_object;
    // TX: 自定义描述符链组装
    pure virtual function void custom_tx_build_chain(
        uvm_object pkt, virtio_net_hdr_t hdr, ref virtio_sg_list sgs[$]);
    // RX: 自定义 buffer 解析
    pure virtual function void custom_rx_parse_buf(
        byte unsigned raw_data[$], ref virtio_net_hdr_t hdr, ref uvm_object pkt);
    // 自定义头部大小/打包/解包
    pure virtual function int unsigned custom_hdr_size();
    pure virtual function void custom_hdr_pack(...);
    pure virtual function void custom_hdr_unpack(...);
endclass
```

#### 4.12.2 Scoreboard 回调 (`virtio_scoreboard_callback`)

```systemverilog
virtual class virtio_scoreboard_callback extends uvm_object;
    // 自定义报文比较（替代 uvm_object::compare()）
    pure virtual function bit custom_compare(uvm_object expected, uvm_object actual);
    // 自定义字段提取（用于调试 vendor-specific 描述符格式）
    pure virtual function void custom_extract_fields(
        byte unsigned raw_desc[], ref string field_values[string]);
endclass
```

#### 4.12.3 Coverage 回调 (`virtio_coverage_callback`)

用于注册用户自定义 covergroup 采样。

---

## 5. Feature 支持矩阵

| Feature | Bit | 支持状态 | 配置参数 |
|---------|-----|----------|----------|
| `VIRTIO_NET_F_CSUM` | 0 | 完整 | `default_driver_features[0]` |
| `VIRTIO_NET_F_GUEST_CSUM` | 1 | 完整 | `default_driver_features[1]` |
| `VIRTIO_NET_F_MTU` | 3 | 完整 | `default_driver_features[3]` |
| `VIRTIO_NET_F_MAC` | 5 | 完整（必需） | 始终开启 |
| `VIRTIO_NET_F_GUEST_TSO4/6` | 7/8 | 完整 | `default_driver_features[7:8]` |
| `VIRTIO_NET_F_HOST_TSO4/6` | 11/12 | 完整 | `default_driver_features[11:12]` |
| `VIRTIO_NET_F_MRG_RXBUF` | 15 | 完整 | `default_rx_mode = RX_MODE_MERGEABLE` |
| `VIRTIO_NET_F_STATUS` | 16 | 完整 | `default_driver_features[16]` |
| `VIRTIO_NET_F_CTRL_VQ` | 17 | 完整 | `default_driver_features[17]` |
| `VIRTIO_NET_F_CTRL_RX` | 18 | 完整 | `default_driver_features[18]` |
| `VIRTIO_NET_F_CTRL_VLAN` | 19 | 完整 | `default_driver_features[19]` |
| `VIRTIO_NET_F_GUEST_ANNOUNCE` | 21 | 完整 | `default_driver_features[21]` |
| `VIRTIO_NET_F_MQ` | 22 | 完整 | `default_num_pairs` |
| `VIRTIO_NET_F_GUEST_USO4/6` | 54/55 | 完整 | `default_driver_features[54:55]` |
| `VIRTIO_NET_F_HOST_USO` | 56 | 完整 | `default_driver_features[56]` |
| `VIRTIO_NET_F_RSS` | 60 | 完整 | `default_driver_features[60]` |
| `VIRTIO_NET_F_STANDBY` | 62 | 完整 | `failover_enable` |
| `VIRTIO_F_RING_INDIRECT_DESC` | 28 | 框架 | `default_driver_features[28]` |
| `VIRTIO_F_RING_EVENT_IDX` | 29 | 完整 | `default_driver_features[29]` |
| `VIRTIO_F_VERSION_1` | 32 | 完整（必需） | 始终开启 |
| `VIRTIO_F_ACCESS_PLATFORM` | 33 | 完整（必需） | 始终开启 |
| `VIRTIO_F_RING_PACKED` | 34 | 完整 | `default_vq_type = VQ_PACKED` |
| `VIRTIO_F_IN_ORDER` | 35 | 框架 | `default_driver_features[35]` |
| `VIRTIO_F_SR_IOV` | 37 | 完整 | snapshot 显式 VF VIO service |
| `VIRTIO_F_NOTIFICATION_DATA` | 38 | 完整 | `default_driver_features[38]` |
| `VIRTIO_F_RING_RESET` | 40 | 完整 | `default_driver_features[40]` |

### 5.1 VIO qpair placement contract

`total_qpairs` 是 `dpu_vio_placement_request` 的 declarative input。候选类型为
`DPU_VIO_CANDIDATE_PF_ONLY`、`DPU_VIO_CANDIDATE_VF_ONLY` 或
`DPU_VIO_CANDIDATE_PF_AND_VF`；候选项必须来自已经 author 的 explicit function
或 eligible VF-pool template。policy `DPU_VIO_DEVICE_AUTO_MINIMUM` 以最少可行
device 满足 demand，`DPU_VIO_DEVICE_FIXED` 仅使用 `fixed_devices`，
`DPU_VIO_DEVICE_ALL_ELIGIBLE` 使用全部 eligible candidates。`ordering` 可以是
稳定的 `DPU_PLACEMENT_CANONICAL` 或具有显式 seed 的
`DPU_PLACEMENT_SEEDED_RANDOM`。

`device_constraints` 的 `DPU_COUNT_EXACT` 固定某 device 的 pair count，
`DPU_COUNT_AT_LEAST` 则指定它至少拥有的数量；`qpair_overrides` 可分别对 owner、
local pair ID 与 global qpair ID 使用 `DPU_ASSIGN_AUTO`、`DPU_ASSIGN_PINNED` 或
`DPU_ASSIGN_PREFERRED`。normalizer 在 device resolution 前检查这些约束，将选择
展开为 explicit service-owned bindings；`DPU_ASSIGN_PINNED` conflict 必须失败，
`DPU_ASSIGN_PREFERRED` conflict 回退为 `DPU_ASSIGN_AUTO`，而 AUTO global qpair ID
总是选择最低的 unreserved free ID。任何 failure 都不会产生部分 published state。

三种 ID namespace 有不同所有者：`request_id` 只识别 placement request，
`service_instance_id` 结合 function key 识别 VIO service，`local_pair_id` 只在
一个 service 内唯一并作为 placement/resource 的本地 qpair label；
`virtio_pair_index` 是该 service 内
连续的软件 pair 序号；`global_qpair_id` 是 Fabric-wide snapshot identity，范围为
`0..2047`。一个 global qpair ID 描述一组 RX/TX queues，不为两个方向分别 author
global allocation。当前 real-DUT profile 要求 `service_instance_id == 0`，每个 PF/VF
至多一个 VIO-net service。软件 pair index `p` 的 RX virtqueue ID 是 `2*p`，TX
virtqueue ID 是 `2*p+1`；这两个协议队列号与 DUT local pair ID 相互独立。默认硬件限制为每个 device
32 pairs、全局 2048 pairs，所以
`total_qpairs=100` 至少需要四个 32-pair eligible devices。`virtio.qpair` profile
可低于 snapshot capability，不能提高它。

`dpu_vio_placement_request.lan_msix_vectors` 可以显式选择该 function 的 LAN
q-vector 数量：0 表示沿用一 qpair 一 vector 的默认 lowering；非零值必须不超过
qpair 数量，resolver 会复现驱动的 `DIV_ROUND_UP(remaining_rings,
remaining_vectors)` 分配，使多个 qpair 合法共享 local/global vector。共享 vector
不会重复写 MSI-X linear/info/interval，而每个 qpair 仍有独立 notify entry；mailbox
和 AF extra control vectors 仍按 capability 计数。

默认真实驱动 capability 会在选中 AF 的普通 LAN qpairs 后追加 11 个独立 queue
binding。其布局固定如下：

| extra offset | 类型 | 端口/队列 | `local_queue_index` |
|--------------|------|-----------|---------------------|
| 0 | forward | - | `ordinary_af_qpair_count + 0` |
| 1 | BPDU | - | `ordinary_af_qpair_count + 1` |
| 2..5 | ETH netdev | port0 / queue0..3 | `ordinary_af_qpair_count + offset` |
| 6..9 | ETH netdev | port1 / queue0..3 | `ordinary_af_qpair_count + offset` |
| 10 | PTP | - | `ordinary_af_qpair_count + 10` |

这些 binding 与普通 VIO qpair 从同一个 global qpair bitmap/pool 分配，不能重号；
AF 的普通与 extra qpair 总数不能超过 32，因此默认 11-extra profile 下 AF 最多拥有
21 个普通 VIO qpair。11 个 extra queue vector 追加在普通 AF LAN vectors 后；resolver
还按 capability 为 mailbox、MAC age 和 PTP stamp 等非 queue interrupt 保留资源，
但它们不是 `dpu_af_extra_queue_binding_t`。

resolver 冻结 device/resource snapshots 后，manager 只从 exact pair import profile、
reservation 和 bindings；VIO 以完整 service key 查询同一 mapping。它不在 runtime
选择 device、改变 local/global ID 或创建新的 qpair placement。FLR 仅清理/重建
runtime transport state，已解析的 service identity、local/global bindings 及其
snapshot pair 保持不变。notify、MSI-X、port/route 和 scheduler builders 应消费该
冻结结果；它们不是 placement feature。

---

## 6. 使用指南

### 6.1 快速开始

#### 6.1.1 环境准备

确保以下组件已就位。`host_mem` 使用项目外的固定 checkout，`net_packet` 跟踪远程
`master` 分支，PCIe TL VIP 跟踪 `pcie_work/main`；这些依赖都不复制到
`virtio_work` 内：

```bash
# 外部 host_mem
export HOST_MEM_ROOT=/path/to/host_mem
git -C "$HOST_MEM_ROOT" checkout --detach \
  35ec087014744ec85cf6c0fe17e1f7118ee7a7b7

# 外部 net_packet master
export NET_PACKET_ROOT=/path/to/net_packet
git clone --branch master https://github.com/Beihang-yuting/net_packet.git "$NET_PACKET_ROOT"  # 首次 clone 时执行
git -C "$NET_PACKET_ROOT" fetch origin master
git -C "$NET_PACKET_ROOT" switch master 2>/dev/null || \
  git -C "$NET_PACKET_ROOT" switch --track -c master origin/master
git -C "$NET_PACKET_ROOT" branch --set-upstream-to=origin/master master

# 外部 pcie_work main
export PCIE_WORK_ROOT=/path/to/pcie_work
git clone --branch main https://github.com/Beihang-yuting/pcie_work.git "$PCIE_WORK_ROOT"  # 首次 clone 时执行
git -C "$PCIE_WORK_ROOT" fetch origin main
git -C "$PCIE_WORK_ROOT" switch main 2>/dev/null || \
  git -C "$PCIE_WORK_ROOT" switch --track -c main origin/main
git -C "$PCIE_WORK_ROOT" branch --set-upstream-to=origin/main main

# dpu_common 位于项目外
export DPU_COMMON_ROOT=/path/to/dpu_common
scripts/check_deps.sh
```

#### 6.1.2 编译命令 (VCS)

```bash
TEST=virtio_smoke_test ./scripts/vcs.sh --compile-only
```

#### 6.1.3 运行测试

```bash
# 单元测试（无 PCIe 依赖）
./simv +UVM_TESTNAME=virtio_unit_test +UVM_VERBOSITY=UVM_MEDIUM

# 冒烟测试
./simv +UVM_TESTNAME=virtio_smoke_test

# 流量测试
./simv +UVM_TESTNAME=virtio_traffic_test

# 端到端集成测试
./simv +UVM_TESTNAME=virtio_e2e_test

# 完整集成测试（带 Completion Bridge）
./simv +UVM_TESTNAME=virtio_full_integration_test
```

#### 6.1.4 DPU Fabric 部署范围与回归入口

`dpu_dut_caps` 是 topology、resource manager、VIO client 和动态重配置共同使用的
real-DUT capability source。其默认 topology capability 为
`2 hosts × 4 PFs/host × 16 VFs/PF`。compile-time `DPU_MAX_*`（例如
`DPU_MAX_HOSTS`、`DPU_MAX_PFS_PER_HOST`、`DPU_MAX_VFS_PER_PF` 和
`DPU_MAX_FUNCTIONS`）是验证 model/encoding ceiling，不是 real-DUT default。
参数化测试可以在 `dut_caps` 中声明更小的非零合法 capability；校验会拒绝任何
超过相应 compile-time ceiling 的值。

VIO global qpair ID 域固定为 11 bits，即 `0..2047`，完整编码域提供 2048 个
global pair 资源。一个 frozen binding 同时记录 request、完整 service key、
local pair ID 和 global qpair ID；global ID 是一份 qpair identity，同时代表 RX/TX
pair，不为两个方向 author 两份 Fabric allocation。`virtio_resource_client` 和
`virtio_vf_resource_pool` 只把这个 binding 转换为其 service-keyed VIO queue view，
不会变更 placement。

每个 PF 或 VF VIO-net device 有自己的 real-DUT notify-address matching
domain/base 和独立的 local-qpair domain；一个 device 最多拥有 32 个 local
queue pairs，local pair ID 为 `0..31`。两个不同 device 可以使用相同的 local
pair ID，因为 Fabric 会结合各自 function/device context 解析排他的 global
qpair lease。这里的 matching domain/base 与标准 virtio PCI Notification
capability 不同：后者提供 notification region 与 `notify_off_multiplier`，每个
queue 的 `notify_off` 用来计算通用 VIP 的 kick address。

real-DUT AF notify table 的 logical match 是：

```text
{host_id, notify_addr[60:7], local_pair_id} -> global_qpair_id
```

`dpu_vio_register_plan_builder` 在 placement freeze 后读取该 matching domain 和
binding，生成 VIO service 范围内的 real-DUT BDF/MSI-X/notify lowering；placement 本身仍不执行 PCIe
访问。builder 先合并 BAR/AF bootstrap，再按 DAG 顺序写 BDF map、MSI-X linear/info/
interval 和选定 inactive notify bank，最后写 `BAR0 + 0x20044` 的 ready/select
commit。notify entry 是 16 字节（两个 64-bit write），匹配字段严格为
`{host_id, notify_addr[60:7], local_qid}`；其中 `local_qid` 使用驱动
`txrx_queues[]` 的连续 pair index，placement 的 sparse `local_pair_id` 仅用于
资源命名和约束。并把 snapshot 的 explicit `global_qpair_id` 放入 payload；不会用
稀疏 local ID 推导 global ID。PBA 是 DUT
运行时状态，不由配置 plan 伪写。notify entries 按驱动的 host/address key 排序；
`select_inactive_notify_bank` 默认开启并选择活动 bank 的另一份 shadow bank。冷启动
默认把 bank0 视为 active，因此第一次 setup 写 bank1；若 attach 到运行中的 DUT，必须
在 build 前通过 `dpu_device_env_config.vio_policy.active_notify_bank` 输入硬件的实际
active bank。`dpu_device_env` 仅在 plan 成功执行并完成 commit 后更新 tracked active
bank；仅 build、`NOT_EXECUTED`、preflight failure 或执行失败都不会推进 bank 状态。
`emit_full_notify_bank` 默认开启：有效项之后写入 driver-compatible invalid entries，
形成完整 128-entry shadow。每个 entry 的 low/high 写入完成后，builder 生成两次
`POLL_UNTIL` readback，默认最多 5 次、间隔 5 us；notify commit 直接依赖每项最终
verify。聚焦测试可以显式关闭完整 shadow 或 readback，但真实 DUT 默认路径不会依赖
上电残留状态恰好为空。

真实驱动的 `DPU_QID_MAP_TABLE_ENTRIES`/`DPU_MAX_TXRX_QUEUE` 是 128，因此默认
shadow bank 只生成或清理 128 项；1024 只是模型支持的编码上限。普通 VIO 和
AF extra queue 的 notify entries 使用同一排序和 commit。extra queue 从 frozen
snapshot 的显式 binding 生成自己的 BDF dependency、MSI-X linear/info/interval
以及 notify low/high operation，不在 builder 中重新分配 qid 或 vector。
resource manager 将 11 个 extra queue 导入为选中 AF 的 function-owned frozen
lease，防止其 global qpair ID 被动态资源再次使用；它们不进入 service lease，
因此 `virtio_resource_client` 看不到这些驱动控制队列。

环境层调用方式：

```systemverilog
dpu_reg_plan plan;
dpu_execution_report report;
string why;
if (!device_env.build_vio_register_plan(plan, why))
  `uvm_fatal("DPU_CFG", why)
device_env.apply_vio_register_plan(plan, report);
```

配置成功进入 `DPU_DEVICE_ACTIVE` 后，独立的 teardown API 使用同一对 frozen
snapshots，且不重新分配任何 ID：

```systemverilog
dpu_reg_plan teardown_plan;
if (!device_env.build_vio_teardown_plan(teardown_plan, why))
  `uvm_fatal("DPU_CFG", why)
device_env.apply_vio_teardown_plan(teardown_plan, report);
```

teardown 先把完整 invalid notify shadow 写入 inactive bank 并以 ready=0 commit，
随后只对普通 VIO/AF-extra binding 实际拥有的 global vector、function/local vector
和 function，依次清零 MSI-X info、MSI-X linear 与 BDF map。成功后状态回到
`RESOLVED`；`NOT_EXECUTED`、plan invalid 或 preflight failure 保持 `ACTIVE`，执行中
失败进入 `FAILED`。

setup 与 teardown 从相同的普通 VIO/AF-extra bindings 构造 VIO-owned function 集合。
没有这些 queue ownership 的 PF/VF 不由 VIO plan 写入或清理 BDF map；BAR bootstrap
属于公共 PCIe topology 配置，仍覆盖 snapshot 中的完整 function/BAR 集合，不随 VIO
BDF ownership 收窄。

`dpu_vio_register_plan_policy` 提供 notify bank/type、MSI-X interval 和 self-mask
策略；这些字段不会改变 frozen topology。`dpu_device_env_config.executor` 是唯一
真实下发扩展点，`apply_vio_register_plan` 会先 freeze 和调用 executor preflight，
preflight 失败不会产生 PCIe 写入。用户可继承 `dpu_reg_executor` 将每个
`dpu_reg_op` 翻译成平台 PCIe config/MMIO TLP；仓库不绑定某一具体 PCIe VIP transport。

当前仓库已提供与 53 号机真实驱动一致的
`dpu_vio_driver_dataplane_extension`。它从 frozen resource snapshot 派生
Host/function/MSI-X 字段，写入 QSCH init、Q2TC/N2G/G2P/SPWRR、可选的 TC0..TC7
WRR weight，以及 VTX/VRX queue-parameter RAM 的 content、RAM select 和
0→1 write-enable；AF BAR0 aperture
和所有字段宽度在 plan 阶段检查。驱动没有初始化的 VTX context、VRX tail、QSCH
链表/调度树节点仍不会被伪造。场景可直接填充 extension 的
`qsch_queues`、`qsch_functions`、`vtx_queues` 和 `vrx_queues`，也可以继承基类覆盖
以下 hook：

`qsch_functions` 中的 `weight_valid` 置 1 时，`tc_weight[0:7]` 会按驱动的
`qsch_tc_wgt_cfg_table_entry`（每个 TC 4 bit）生成
`DSCH_QSCH_BASE + 0x14000 + global_func_id*4` 写入；不置 1 则保持驱动默认权重，
不会增加额外写操作。
QSCH G2P 的 `src_port` 按 `dpu_snd1.ko` 的实际一位编码处理：驱动源码中的
`QSCH_PORT_HOST0 + host_id` 在写入结构体时被截断为低位，因此 plan 不会写入
超出该字段的逻辑端口值。

### QSCH 逻辑拓扑与随机 lowering

QSCH 不直接从寄存器字段反向随机，而是先在 `dpu-common` 生成逻辑图，再 lowering
到真实 DUT 配置。`dpu_qsch_topology_generator` 的输入是已经冻结的
`dpu_device_snapshot` 和 `dpu_resource_snapshot`，输出为
`dpu_qsch_topology_cfg`：

```text
Function/global_func_id ──> net ──> group ──> port
global_qpair_id ────────────────> TC/net
                                  │
                                  └── traffic_classes[0..7]
```

支持的模式为 `DPU_QSCH_TOPOLOGY_RANDOM_VALID` 和
`DPU_QSCH_TOPOLOGY_RANDOM_STRESS`。随机使用仿真全局 seed，因此同一仿真 seed 可以
复现同一张图，不需要环境额外维护 seed。net ID 不是独立随机数，而是对应 Function
的 `global_func_id`；随机的是 group/port 节点、qpair 的 TC、net 的 SP/WRR 与可选
TC weight。生成器保证 qpair owner、net、group、port 引用完整且字段范围合法，每个
生成的 group 至少有一个 net。需要覆盖多 Function 共享调度组时设置
`generator.require_shared_group = 1`；只要存在两个以上 Function，生成器就会约束
group 数量小于 net 数量，并让剩余 net 继续随机挂接，从而保证至少一个 group 被多个
net-device 共享。

```systemverilog
dpu_qsch_topology_generator generator;
dpu_qsch_topology_cfg topology;
generator = dpu_qsch_topology_generator::type_id::create("qsch_generator");
generator.mode = DPU_QSCH_TOPOLOGY_RANDOM_VALID;
if (!generator.build_random(device_snapshot, resource_snapshot, topology, why))
  `uvm_fatal("QSCH", why)

driver_extension.set_qsch_topology(topology);
```

`set_qsch_topology()` 在 lowering 前再次校验 snapshots 和关系，随后沿用已审计的
Q2TC/N2G/G2P/SPWRR/weight 地址和位域。由于 53 号真实驱动的 N2G/G2P 表项仍按
`global_func_id` 寻址，随机 group 写入 N2G 的 group 字段，group 的 port 写入该 net
的 G2P 字段；当前不会凭空增加未经驱动确认的独立 group-table 或硬件链表寄存器。
拓扑对象本身就是验证期望模型，可用于后续 DUT readback/数据面检查。

```systemverilog
class my_vio_dataplane_extension extends dpu_vio_dataplane_plan_extension;
  `uvm_object_utils(my_vio_dataplane_extension)

  virtual function bit contribute_qsch(
      dpu_device_snapshot devices,
      dpu_resource_snapshot resources,
      dpu_reg_plan plan,
      output string why);
    // 从 frozen resources 读取 qpair/MSI-X/AF-extra binding，向 plan 追加
    // 已由用户核实的 scheduler node/table operations 和 dependencies。
    why = "";
    return 1;
  endfunction
endclass

env_cfg.vio_dataplane_extension =
    my_vio_dataplane_extension::type_id::create("vio_dataplane_extension");
```

builder 固定按 `contribute_qsch()`、`contribute_vtx()`、`contribute_vrx()` 顺序，
在核心 BDF/MSI-X/notify commit operation 已存在后调用这些 hook。三者获得同一对
frozen snapshots 和仍可追加 operation/dependency 的 plan；任一 hook 返回 0，
plan build 整体失败且 executor 不会运行。QSCH 与 DSCH 调度树可先统一从
`contribute_qsch()` lowering，后续字段核实后再拆分专用 builder。

冻结 snapshot 中的 VIO qpair capabilities 是硬件上限，并在以下边界执行：

1. 初始 `virtio_net_env_config` 将默认行为和 service-keyed override 限制在
   `max_vio_net_qpairs_per_device` 内；
2. dynamic resize 拒绝超过 capability 的 pair 数（也拒绝 0）；
3. resource resolver 在冻结 binding 前拒绝越过 capability 的 local pair range；
4. `virtio.qpair` profile 的 global `capacity` 和 `max_per_function` 分别不得超过
   snapshot 的 `vio_global_qpair_count` 和 `max_vio_net_qpairs_per_device`；profile
   可以为具体场景声明更小的 quota，但不能扩大硬件能力。

默认 per-device capability 是 32，所以默认配置拒绝第 33 个 pair，local pair
ID 必须在 `0..31`。如果 snapshot capability 合法配置为 16，前三处设备边界和
profile 上限会降为 16，local pair ID 范围相应变为 `0..15`；场景 profile 还可
在这个上限内继续收窄。32 是每设备的默认 capability 和 device/model ceiling，
并非所有参数化场景中固定不变的 quota。

Fabric snapshot 拥有 `virtio.qpair` 的不透明 resource-class ID；它不是 core enum
常量。pair-seeded manager import snapshot profile 与 bindings 后封存 registry，
protocol children 只查询服务映射。

当前 real-DUT profile 的 BAR 布局是三组 64-bit pair。PF 的
BAR0/1、BAR2/3、BAR4/5 分别是 32 MiB device memory/AF registers、64 KiB
mailbox 和 64 KiB MSI-X table/PBA；VF 的对应大小为 16 KiB、16 KiB 和
32 KiB。`dpu_device_cfg` 为每个 function 声明这三个 BAR request，resolver
在 domain 的 MMIO windows 中检查 role、size、alignment、overflow 和 overlap，
并将完整解析结果发布到冻结的 `dpu_device_snapshot`。

当前边界已包含 resolved PCI BAR、AF declaration/bootstrap plan lowering 和 PCIe-TL
executor。当前 plan 已包含 11 个 AF extra queue
的 BDF dependency、MSI-X internal mapping 和 notify lowering，以及上述驱动证据充分
的 QSCH/VTX/VRX queue-parameter lowering；AF mailbox/MAC-age/PTP-stamp 等非 queue
control interrupt及标准 PCIe MSI-X table address/data 初始化仍由后续专用 builder
或平台集成处理。现有 teardown 已覆盖 snapshot-owned notify、MSI-X info/linear 和
BDF map；不会写 PBA、BAR4 MSI-X table、interval 或无 VIO queue 的其他 function。
PBA 是 DUT-maintained pending state，应通过读/检查验证而不是由配置层清零。只有测试或集成环境显式
注入 `dpu_reg_executor` 后才会访问硬件；未注入时报告
`NOT_EXECUTED`，不伪报硬件成功。

`cosim_control` 与 BAR2/3 mailbox command delivery 是
[real-DUT service configuration design](superpowers/specs/2026-08-25-real-dut-service-configuration-design.md)
明确列出的 out-of-scope 项。BAR2/3 的 mailbox role 和地址解析已定义，
但这不表示本仓库实现了 mailbox command transport/delivery。

完整回归使用：

```bash
make regression
```

`scripts/test_manifest.sh` 中的 `VIRTIO_MAINTAINED_TESTS` 是回归清单和顺序的
单一事实源。该入口按清单顺序运行 `dpu_resource_manager_test`、
`dpu_reg_plan_test`、`dpu_pcie_reg_executor_test`、`dpu_device_resolver_test`、`dpu_placement_test`、
`dpu_resource_resolver_test`、`dpu_device_bootstrap_plan_test`、`dpu_vio_reg_plan_test`、`virtio_dut_caps_test`、
`virtio_execution_mode_test`、`virtio_real_dut_iova_dma_test`、
`virtio_fabric_resource_test`、`virtio_unit_test`、
`virtio_host_mem_reclaim_test`、`virtio_queue_semantics_test`、
`virtio_stress_unit_test`、
`virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
`virtio_migration_dirty_test`、`virtio_monitor_test`、`virtio_coverage_test`、
`virtio_e2e_test`、`virtio_full_integration_test`、
`virtio_pf_lifecycle_reset_test`、`virtio_monitor_routing_test`、
`virtio_dual_test`、`virtio_smoke_test`、`virtio_traffic_test`、
`virtio_net_packet_multi_queue_test`、`virtio_real_driver_flow_test`、
`virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`、
`host_mem_random_test`、
`virtio_pcie_host_mem_test` 和 `dpu_pcie_tl_executor_integration_test`，
共 37 项。该入口
要求 `make check-deps` 先通过；无 VCS 环境时它应在编译前报告 VCS 依赖错误。

其中 `virtio_host_mem_reclaim_test`、`virtio_queue_semantics_test`、
`virtio_indirect_desc_test` 是资源生命周期和队列语义专项测试，不是简单的
报文 loopback。它们统一复用外部 `host_mem` 项目的 `host_mem_pool`；同一个
Host 的 queue ring、descriptor、packet buffer 共享一个 manager，reset、used
ring 消费和 teardown 后必须通过 `leak_check()`。大流量测试则通过
`+TRAFFIC_PACKETS=N` 调整报文数，并在每批释放 TX/RX buffer。

### 6.2 编写测试

#### 6.2.1 基本测试模板

```systemverilog
class my_test extends virtio_base_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 自定义配置
    virtual function void configure_default(virtio_net_env_config cfg);
        super.configure_default(cfg);
        cfg.default_num_pairs    = 2;
        cfg.default_queue_size   = 128;
        cfg.default_vq_type      = VQ_PACKED;
        cfg.scb_enable           = 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_full_init_traffic_vseq vseq;
        phase.raise_objection(this);

        vseq = virtio_full_init_traffic_vseq::type_id::create("vseq");
        vseq.start(env.v_seqr);

        phase.drop_objection(this);
    endtask
endclass
```

#### 6.2.2 使用 AUTO 模式

```systemverilog
// AUTO 模式下，test 只需发送高层事务
virtio_transaction txn;

// 初始化
txn = virtio_transaction::type_id::create("init_txn");
txn.txn_type = VIO_TXN_INIT;
// ... start_item/finish_item on sequencer ...

// 启动数据面
txn.txn_type = VIO_TXN_START_DP;
// ... start_item/finish_item ...

// 发送报文
txn.txn_type = VIO_TXN_SEND_PKTS;
txn.packets = my_packet_list;
// ... start_item/finish_item ...
```

#### 6.2.3 使用 MANUAL 模式

```systemverilog
// MANUAL 模式下，test 精确控制每个操作步骤
virtio_transaction txn;

// Step 1: Set Status
txn.txn_type = VIO_TXN_ATOMIC_OP;
txn.atomic_op = ATOMIC_SET_STATUS;
txn.status_val = DEV_STATUS_ACKNOWLEDGE;

// Step 2: Setup Queue
txn.atomic_op = ATOMIC_SETUP_QUEUE;
txn.queue_id = 0;
txn.queue_size = 256;
txn.vq_type = VQ_SPLIT;

// Step 3: TX Submit
txn.atomic_op = ATOMIC_TX_SUBMIT;
txn.queue_id = 1;  // transmitq_0
txn.pkt = my_packet;
txn.net_hdr = my_hdr;
```

### 6.3 与 DUT 对接

#### 6.3.1 PCIe 接口连接

VIP 通过 `pcie_tl_vip` 的 RC Agent 与 DUT 的 EP 端交互：

```systemverilog
class my_dut_test extends virtio_base_test;
    pcie_tl_env  pcie_env;

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // nonvirtual bind_pcie() 统一绑定所有 PF/VF，并逐层传播失败。
        if (!env.bind_pcie(pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("DUT_BIND", "virtio environment PCIe bind failed")
            return;
        end
    endfunction
endclass
```

`bind_pcie()` 返回 1 前会验证每个 function 的 driver/monitor/observer、独立 protocol-event VIF 和 MQ capability；任一项失败都会返回 0，并且不会提交环境级 RC sequencer 或 protocol-VIF 计数。调用方必须检查返回值。

#### 6.3.1a 执行模式与 REAL_DUT 前置条件

`virtio_net_env_config.execution_mode` 的默认值是 `VIRTIO_EXEC_MODEL`。两种模式
共享同一套生产 driver、队列映射和 Host-memory 所有权，但设备侧行为不同：

| 模式 | 设备侧实现 | 可验证范围 |
|------|------------|------------|
| `VIRTIO_EXEC_MODEL` | `virtio_pcie_dut_responder` 消费 notify，经过 IOMMU/Host-memory 完成 DMA/used ring，并由 notification manager sideband 模拟中断（非真实 MSI-X TLP） | 无 RTL 时的完整 TLM 闭环 |
| `VIRTIO_EXEC_REAL_DUT` | 不创建本地 device responder；被动观察真实 RTL 的 PCIe TLP | 真实配置、notify、DMA、used/interrupt 事件和 driver 回收 |

REAL_DUT 的 fixture 使用 `SV_IF_MODE`，必须发布独立的
`pcie_tl_rc_vif`（RC→EP）和 `pcie_tl_ep_vif`（EP→RC）。plain `pcie_work` 链路还
需要 `+VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1`，由
`virtio_pcie_real_dut_host_mem_responder` 代理 EP→RC Memory Read/Write；若外部
FULL-VIP/backend 已提供该 responder，则禁止同时打开 plusarg，以免重复
Completion 或重复写入。该 responder 通过
`virtio_pcie_iova_host_mem_proxy` 将 DUT IOVA 翻译为共享 Host GPA，不创建第二份
内存（仅在本地 responder 被 plusarg 或显式 API 启用时安装）。缺少双向 VIF 或
EP→RC responder 时，`build_flow()` 必须失败。
本地 responder 一次只绑定一个 `{host_id, BDF}`；多 PF/VF 平台需要为每个 Function
创建独立 responder，或由外部 backend 按 requester BDF 分派到对应 IOMMU/Host
memory 域。

REAL_DUT responder 只服务 Host-memory DMA，不生成 notify、used ring 或 RX 入包。
因此 `virtio_real_driver_rx_test` 目前仅支持 MODEL；REAL_DUT 会报告
`REAL_DUT_RX_SOURCE_UNAVAILABLE`，待平台提供物理/net_packet ingress callback 后再
纳入真实 RX 回归。MODEL 的 responder 计数不能作为 RTL 数据面通过的证据。
仓库默认 `virtio_tb_top.sv` 尚未实例化或发布这两条 VIF，因此默认顶层只能运行
MODEL；真实平台 wrapper 必须在 `run_test()` 前创建双向 `pcie_tl_if` 并通过
`uvm_config_db` 发布上述两个键。

#### 6.3.2 BAR 地址配置

Fabric-owned REAL_DUT 的 BAR 地址先由 dpu_common resolver/MMIO window 形成冻结
lease，RC 再按 lease 调用 `program_fabric_bar_pairs()` 编程 PCIe config-space BAR，
之后只做 capability discovery，不重新 sizing/分配，也不应在测试里写死地址。旧的
`bar_accessor.enumerate_bars()` 顺序分配（默认从 `0xC000_0000` 开始）只适用于
legacy/TLM 模型路径；Fabric-owned function 会明确报告 `BAR_FABRIC_OWNED`，不能
再用 `bar.next_bar_alloc_addr` 覆盖它。

---

## 7. 测试方法论

### 7.1 测试层次

| 层次 | 测试文件 | 依赖 | 说明 |
|------|----------|------|------|
| 单元测试 | `virtio_unit_test.sv` | 无 PCIe | host_mem, IOMMU, split_virtqueue, wait_policy |
| 压力单元 | `virtio_stress_unit_test.sv` | 无 PCIe | packed virtqueue, 大规模操作 |
| 协议测试 | `virtio_protocol_test.sv` | 无 PCIe | 类型系统、状态机验证 |
| 流量测试 | `virtio_traffic_test.sv` | 无 PCIe | 1000 报文 TX/RX, 带宽控制, 压力 |
| 端到端 | `virtio_e2e_test.sv` | PCIe TLM loopback | 完整 init + dataplane through TLP |
| 完整集成 | `virtio_full_test.sv` | PCIe + Completion Bridge | 解决 get_response 问题 |
| 双 VIP | `virtio_dual_test.sv` | 两个 VIP 实例 | 互打测试 |

### 7.2 测试结果汇总

以下是已通过的测试及其关键数据：

| 测试 | 报文数量 | 关键指标 | 结果 |
|------|----------|----------|------|
| `virtio_unit_test` | - | host_mem alloc/free, IOMMU map/translate, split_vq alloc/add_buf, wait_policy | PASS |
| `virtio_stress_unit_test` | - | packed_vq 压力, 大规模操作 | PASS |
| `virtio_protocol_test` | - | 类型枚举, 状态机, feature bit | PASS |
| `virtio_traffic_test` - 大流量 | 1000 pkts | TX/RX loopback, 全部匹配 | PASS |
| `virtio_traffic_test` - 带宽控制 | 100 pkts | 100 Mbps 限制, token bucket | PASS |
| `virtio_traffic_test` - 协议完整性 | 60+ pkts | checksum/TSO/RSS 验证 | PASS |
| `virtio_traffic_test` - 队列压力 | 2560 ops | 256-entry fill/drain x10 | PASS |
| `virtio_traffic_test` - 混合队列 | 200 pkts | split + packed 并行 | PASS |
| `virtio_e2e_test` | ~20 pkts | PCIe TLM loopback, 完整 init | PASS |
| `virtio_full_test` | ~50 pkts | Completion Bridge, 全 TLP 路径 | PASS |

### 7.3 测试建议

#### DUT 对接后的测试策略

1. **第一优先：冒烟测试** -- 验证基本初始化和单报文收发
2. **第二优先：协议合规** -- 状态转换、feature 协商、queue setup 错误检测
3. **第三优先：数据正确性** -- 中等流量 TX/RX 数据匹配
4. **第四优先：Offload 验证** -- checksum, TSO, USO, RSS
5. **第五优先：错误恢复** -- 描述符错误、IOMMU fault、DEVICE_NEEDS_RESET
6. **第六优先：性能基准** -- 延迟分段、带宽极限
7. **第七优先：高级场景** -- 热迁移、failover、多 VF 并发、动态重配置

#### 覆盖率目标

- Feature 交叉覆盖 > 80%
- 队列操作覆盖 > 90%
- 错误注入覆盖应按语义类型和专用 hook 分别统计；当前不能将 27 种枚举值统一
  宣称为已自动注入。描述符字节级路径只统计实际完成的 ADDR/LEN/FLAGS/NEXT/ID
  变异，ring、状态、IOMMU 和中断路径分别统计。
- 状态转换覆盖 100%

---

## 8. 已知限制和未来工作

### 8.1 已知限制

| 限制 | 说明 | 影响 |
|------|------|------|
| TLM loopback `get_response()` | 在 TLM loopback 模式下，PCIe RC driver 的 `get_response()` 可能死锁 | 使用 `virtio_cpl_bridge` 中间件解决（见 `virtio_full_test.sv`） |
| Indirect Descriptors | 框架已定义但未完整实现间接描述符表的分配和填写 | 不影响标准流量测试 |
| IN_ORDER Completion | Packed Queue 的 `VIRTIO_F_IN_ORDER` 快速路径为框架级实现 | 功能正确但未优化 |
| net_packet 集成 | TX/RX engine 使用 `uvm_object` 封装 `packet_item` | 需要 `virtio_dataplane_callback` |

### 8.2 Completion Bridge 中间件

为解决 TLM loopback 模式下的 `get_response()` 死锁问题，`virtio_full_test.sv` 引入了三层中间件架构：

1. **`virtio_cpl_bridge`** -- FIFO 化的 completion 存储（单 mailbox，因 virtio 寄存器访问是顺序的）
2. **`virtio_rc_driver_shim`** -- 继承 `pcie_tl_rc_driver`，将 completion 推入 bridge
3. **Bridged Sequences** -- 使用 bridge 的 `wait_completion()` 替代 `get_response()`

### 8.3 建议的后续改进

1. **间接描述符完整实现** -- 分配间接描述符表，支持超长 SG 链
2. **Admin VQ 完整实现** -- 目前为框架级，需实现 PF 管理队列的完整协议
3. **Live Migration 增强** -- 增加 dirty page bitmap 验证逻辑
4. **形式化协议检查** -- 将 monitor 的协议检查提取为 SVA assertions
5. **Performance Counters** -- 添加硬件性能计数器模拟和验证

---

## 9. API 参考

### 9.1 virtio_wait_policy

| 方法 | 签名 | 说明 |
|------|------|------|
| `effective_timeout` | `function int unsigned effective_timeout(int unsigned base_ns)` | 计算有效超时 |
| `poll_until_flag` | `task poll_until_flag(string, int unsigned, int unsigned, ref bit, ref bit)` | 通用轮询 |
| `wait_event_or_timeout` | `task wait_event_or_timeout(string, uvm_event, int unsigned, ref bit)` | 事件等待 |
| `wait_event_or_poll` | `task wait_event_or_poll(string, uvm_event, int unsigned, int unsigned, ref bit)` | 混合等待 |

### 9.2 virtio_iommu_model

| 方法 | 签名 | 说明 |
|------|------|------|
| `map` | `function bit[63:0] map(bit[15:0] bdf, bit[63:0] gpa, int unsigned size, dma_dir_e dir, string file="", int line=0)` | 创建映射 |
| `map_for_host` | `function bit[63:0] map_for_host(int unsigned host_id, bit[15:0] bdf, bit[63:0] gpa, int unsigned size, dma_dir_e dir, ...)` | 创建 Host-qualified 映射 |
| `unmap` | `function void unmap(bit[15:0] bdf, bit[63:0] iova, string file="", int line=0)` | 移除映射 |
| `unmap_for_host` | `function void unmap_for_host(int unsigned host_id, bit[15:0] bdf, bit[63:0] iova, ...)` | 移除指定 Host 映射 |
| `translate` | `function bit translate(bit[15:0] bdf, bit[63:0] iova, int unsigned size, dma_dir_e access_dir, ref bit[63:0] gpa, ref iommu_fault_e fault)` | 地址翻译 |
| `translate_for_host` | `function bit translate_for_host(int unsigned host_id, bit[15:0] bdf, bit[63:0] iova, int unsigned size, dma_dir_e access_dir, ref bit[63:0] gpa, ref iommu_fault_e fault)` | 指定 Host 地址翻译 |
| `map_fixed_for_host` | function | 指定 Host 重建固定 IOVA |
| `write_from_device_for_host` | function | 指定 Host 的完成 DMA write/dirty 边界 |
| `snapshot_live_mappings_for_host` | function | 快照指定 Host/BDF 的 live mappings |
| `add_fault_rule` | `function void add_fault_rule(iommu_fault_rule_t rule)` | 添加 fault 规则 |
| `clear_fault_rules` | `function void clear_fault_rules()` | 清除规则 |
| `get_and_clear_dirty` | `function void get_and_clear_dirty(ref bit[63:0] dirty_pages[$])` | 获取并清除脏页 |
| `begin_dirty_generation_for_host` / `capture_dirty_generation_for_host` | function | Host-scoped dirty generation |
| `leak_check` | `function void leak_check()` | 泄漏检查 |
| `reset` | `function void reset()` | 重置 |
| `print_stats` | `function void print_stats()` | 打印统计 |

### 9.3 virtqueue_base（及子类）

| 方法 | 类型 | 说明 |
|------|------|------|
| `setup` | function | 初始化外部引用 |
| `alloc_rings` | function | 分配 ring 内存 |
| `free_rings` | function | 释放 ring 内存 |
| `reset_queue` | function | 重置队列状态 |
| `add_buf` | function | 添加 buffer (返回 desc_id) |
| `kick` | task | 通知设备 |
| `poll_used` | function | 轮询 Used Ring (返回 1=found) |
| `disable_cb` | function | 抑制中断 |
| `enable_cb` | function | 使能中断 |
| `enable_cb_delayed` | function | EVENT_IDX 延迟使能 |
| `needs_notification` | function | 检查是否需要 kick |
| `get_free_count` | function | 空闲描述符数 |
| `get_pending_count` | function | 待完成描述符数 |
| `dma_map_buf` | function | DMA 映射 |
| `dma_unmap_buf` | function | DMA 解映射 |
| `inject_desc_error` | function | 注入错误 |
| `save_state` | function | 保存快照 |
| `restore_state` | function | 恢复快照 |
| `detach` | function | 重置并禁用 |
| `dump_ring` | function | 日志输出状态 |
| `leak_check` | function | 泄漏检查 |

### 9.4 virtio_pci_transport

| 方法 | 类型 | 说明 |
|------|------|------|
| `discover_and_init_bars` | task | BAR 枚举 + capability 发现 |
| `full_init_sequence` | task | 完整 9 步初始化 |
| `reset_device` | task | 写 status=0, 轮询 |
| `read_device_status` | task | 读取设备状态 |
| `write_device_status` | task | 写入设备状态 |
| `read_device_features` | task | 读取设备 feature (64-bit) |
| `write_driver_features` | task | 写入驱动 feature (64-bit) |
| `negotiate_features` | task | Feature 协商 |
| `select_queue` | task | 选择队列 |
| `read_queue_num_max` | task | 读取队列最大值 |
| `write_queue_size` | task | 设置队列大小 |
| `write_queue_desc_addr` | task | 设置描述符表地址 (64-bit) |
| `write_queue_driver_addr` | task | 设置 avail ring 地址 (64-bit) |
| `write_queue_device_addr` | task | 设置 used ring 地址 (64-bit) |
| `write_queue_enable` | task | 使能队列 |
| `write_queue_reset` | task | 队列重置 (1.2+) |
| `setup_single_queue` | task | 单队列完整配置 |
| `kick` | task | 通知 (标准或 NOTIFICATION_DATA) |
| `read_net_config_atomic` | task | 原子读取设备配置 (config generation check) |
| `inject_status_error` | task | 状态错误注入 |
| `inject_feature_error` | task | Feature 错误注入 |
| `inject_queue_setup_error` | task | 队列配置错误注入 |

### 9.5 virtio_auto_fsm

| 方法 | 类型 | 说明 |
|------|------|------|
| `full_init` | task | 完整初始化 (IDLE -> READY) |
| `start_dataplane` | task | 启动数据面 (READY -> RUNNING) |
| `stop_dataplane` | task | 停止数据面 (RUNNING -> READY) |
| `send_packets` | task | 发送报文 |
| `wait_packets` | task | 等待接收报文 |
| `configure_mq` | task | 动态调整 MQ 对数 |
| `configure_rss` | task | 配置 RSS |
| `freeze_for_migration` | task | 冻结设备 (迁移) |
| `restore_from_migration` | task | 恢复设备 (迁移) |
| `handle_device_needs_reset` | task | 错误恢复 |
| `reset_single_queue` | task | 单队列重置 + 重配置 |

### 9.6 virtio_net_env_config

| 方法 | 说明 |
|------|------|
| `make_default_driver_config(max_pairs)` | 从默认字段构建并按 snapshot 上限裁剪 `virtio_driver_config_t` |
| `add_service_config(service_key, cfg, why)` | 按 VIO service key 添加 function 行为 override |
| `get_service_config(service_key, max_pairs, cfg, why)` | 按 service key 取得 override；未配置时回退到裁剪后的默认行为 |
| `validate_local(why)` | 检查与 snapshot 无关的本地配置合法性 |
| `validate_against_snapshot(snapshot, why)` | 检查 service ownership 并按冻结 snapshot capability 校验/裁剪 |
| `convert2string()` | 格式化输出 |

`host_mem_pool` 提供 `create_host(host_id, base, end, mode, granule, policy)`、
`get_host(host_id)` 和 `has_host(host_id)`。`create_host()` 对每个 Host 只创建
一个 manager；重复获取返回同一 handle。业务环境通过 `host_mem_pool_binding`
按 Host 查找这个 handle（或直接通过 `host_mem_binding` 注入），从而让同 Host
的 VIO/RDMA/VBLK 分配在一个互斥地址域内。pool 会在发布 manager 前检查 64 位
aperture 是否可表示，拒绝完整 `2^64` 区间等无效配置。

---

## 10. 附录

### 10.1 VCS 编译命令参考

```bash
# 基础编译（单元测试）
TEST=virtio_unit_test ./scripts/vcs.sh --compile-only

# 完整编译/运行某一测试（脚本会从 PCIE_WORK_ROOT 引入远程 PCIe VIP）
TEST=virtio_traffic_test ./scripts/vcs.sh
```

### 10.2 仿真运行命令参考

```bash
# 运行指定测试
./simv +UVM_TESTNAME=<test_name> [options]

# 常用选项
+UVM_VERBOSITY=UVM_LOW|UVM_MEDIUM|UVM_HIGH|UVM_DEBUG
+UVM_MAX_QUIT_COUNT=10        # 最大 UVM_ERROR 数
+UVM_TIMEOUT=1000000           # UVM 超时 (ns)

# 示例
./simv +UVM_TESTNAME=virtio_unit_test +UVM_VERBOSITY=UVM_LOW
./simv +UVM_TESTNAME=virtio_traffic_test +UVM_VERBOSITY=UVM_MEDIUM
./simv +UVM_TESTNAME=virtio_e2e_test +UVM_VERBOSITY=UVM_HIGH
```

### 10.3 Git 提交历史

| Commit | 说明 |
|--------|------|
| `0e12770` | feat: 项目骨架，package 和外部符号链接 |
| `13ef967` | feat: 类型定义 - 枚举、结构体、feature bit、net_hdr 工具 |
| `148504a` | feat: wait_policy 框架和内存屏障模型 |
| `12fedf6` | feat: IOMMU 模型 - map/unmap/translate, fault 注入, 脏页追踪 |
| `b65dd88` | feat: virtqueue 错误注入器和抽象基类 |
| `d6c2563` | feat: split virtqueue - 完整描述符/avail/used ring 管理 |
| `f452fc7` | feat: packed/custom virtqueue 和队列管理器 |
| `6f4761f` | feat: PCI 寄存器偏移和 capability 发现管理器 |
| `f1baade` | feat: BAR 访问器 - MMIO/config 到 PCIe TLP 翻译 |
| `1cc36a1` | feat: 通知管理器和 PCI 传输完整初始化序列 |
| `74181e3` | feat: 回调接口和 virtio_transaction sequence item |
| `6f7179f` | feat: 原子操作库和自动 FSM (named-fork 后台任务) |
| `af708c6` | feat: driver, monitor, sequencer 和 agent 封装 |
| `9fc8366` | feat: offload 引擎 - checksum, TSO, USO, RSS, 统一封装 |
| `6a1ff5f` | feat: TX 和 RX 引擎 (net_packet 集成, buffer 追踪) |
| `aa2ef38` | feat: failover 管理器和数据面顶层封装 |
| `7470b3e` | feat: SR-IOV 支持 - VF 资源池, VF 实例, PF 管理器 |
| `d0ed789` | feat: 环境组装 - config, scoreboard, coverage, perf, concurrency, env |
| `a84a21e` | feat: 基础和场景序列 (29 个文件) |
| `689ff3f` | feat: 虚拟序列 (smoke, full traffic, multi-VF, stress) |
| `550dafc` | feat: base test, smoke test, 和顶层 testbench |
| `1e886af` | feat: 启用所有 package includes - VIP 实现完成 |
| `01175ec` | fix: 修复所有 VCS 编译错误 (20 个文件, include 顺序, 类型转换) |
| `f56d0a9` | test: 添加 unit/stress/protocol 测试 - 全部 PASS |
| `793ac48` | test: 端到端集成测试 (PCIe TLM loopback - 完整 virtio init + dataplane) |

### 10.4 相关规范参考

| 规范 | 版本 | 相关章节 |
|------|------|----------|
| OASIS virtio Specification | 1.2 / 1.3 | Section 4.1 (PCI Transport), Section 5.1 (Net Device) |
| PCI Local Bus Specification | 3.0 | BAR, Capability List |
| PCI Express Base Specification | 5.0 | TLP Format, Completion |
| MSI-X ECN | - | MSI-X Table, PBA |
| SR-IOV Specification | 1.1 | VF Enable, VF BAR, FLR |
| Linux kernel source | 6.x | `drivers/net/virtio_net.c`, `drivers/virtio/virtio_pci_common.c` |

---

*本文档由 Virtio-Net Driver UVM VIP 项目组编写，版本 1.0，2026-04-24。*
