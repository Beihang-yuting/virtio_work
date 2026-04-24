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

在 DPU/SmartNIC 架构中，virtio-net 设备由硬件实现，替代传统的 QEMU 软件后端。这意味着硬件必须严格遵循 virtio 规范中定义的所有协议行为——从 PCI capability 发现、feature 协商、queue 配置，到数据面的描述符链处理、通知抑制、中断管理等。本 VIP 通过模拟一个完整的 virtio-net 驱动，在 PCIe Transaction Layer 产生真实的 TLP 流量，从而对 DUT 的协议合规性和数据正确性进行全面验证。

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
| `pcie_tl_vip` | `/ryan/pcie_work/pcie_tl_vip` | PCIe TL 子环境（RC/EP Agent, func_manager, SR-IOV） | 作为子环境，零修改 |
| `host_mem_manager` | `/ryan/shm_work/host_mem` | Buddy 分配器，用于描述符环和数据缓冲区 | 共享实例 |
| `net_packet` | `/ryan/shm_work/net_packet` | 协议报文生成器（L2-L4，隧道，RDMA） | `packet_item` UVM 封装 |

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
      |  (DUT reads descriptor table, writes used ring |
      |   via PCIe DMA, translated by IOMMU model)     |
      |                                                |
```

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
+-- ext/
    +-- host_mem -> /ryan/shm_work/host_mem
    +-- net_packet -> /ryan/shm_work/net_packet
    +-- pcie_tl_vip -> /ryan/pcie_work/pcie_tl_vip
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
| `ext/` | 外部组件的符号链接 |

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
| `virtqueue_error_e` | 26 种错误类型 | 描述符/ring/DMA/通知错误 |
| `virtio_txn_type_e` | 16 种事务类型 | 驱动事务分类 |
| `virtio_atomic_op_e` | 10 种原子操作 | MANUAL 模式操作 |
| `scb_error_e` | 12 种 scoreboard 错误 | 验证错误分类 |
| `race_point_e` | 7 种竞争点 | 并发竞争注入位置 |
| `status_error_e` | 5 种状态错误 | 状态转换错误注入 |
| `feature_error_e` | 5 种 feature 错误 | Feature 协商错误注入 |
| `queue_setup_error_e` | 6 种队列配置错误 | 队列配置错误注入 |

#### 4.1.3 结构体定义

| 结构体 | 主要字段 | 用途 |
|--------|----------|------|
| `virtio_sg_entry` | `addr[63:0]`, `len` | 单个 scatter-gather 条目 |
| `virtio_sg_list` | `entries[$]` | scatter-gather 列表 |
| `virtio_used_info` | `desc_id`, `len`, `submit_time`, `complete_time` | Used Ring 回收信息 |
| `virtqueue_snapshot_t` | `queue_id`, `queue_size`, 地址, 索引, `ring_data[]` | 队列迁移快照 |
| `iommu_mapping_t` | `bdf`, `gpa`, `iova`, `size`, `dir`, `desc_id` | DMA 映射记录 |
| `iommu_mapping_entry_t` | 同上 + `valid`, `map_time`, `caller_file`, `caller_line` | 带调试信息的映射 |
| `iommu_fault_rule_t` | `bdf_mask`, `iova_start/end`, `dir`, `fault_type`, `trigger_count` | Fault 注入规则 |
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

#### 4.4.1 核心接口

| 方法 | 签名 | 说明 |
|------|------|------|
| `map()` | `function bit[63:0] map(bdf, gpa, size, dir)` | 分配 IOVA, 创建映射，返回 IOVA |
| `unmap()` | `function void unmap(bdf, iova)` | 移除映射，保存到 unmap_history |
| `translate()` | `function bit translate(bdf, iova, size, dir, ref gpa, ref fault)` | 地址翻译，成功返回 1 |
| `add_fault_rule()` | `function void add_fault_rule(rule)` | 添加 fault 注入规则 |
| `clear_fault_rules()` | `function void clear_fault_rules()` | 清除所有规则 |
| `leak_check()` | `function void leak_check()` | 测试结束时检查未释放映射 |
| `reset()` | `function void reset()` | 重置所有状态 |

#### 4.4.2 IOVA 分配

使用 Bump 分配器，从 `IOVA_BASE = 0x8000_0000` 开始递增分配，每次分配对齐到 4KB 页面边界。

#### 4.4.3 翻译检查顺序

`translate()` 按以下顺序执行检查：

1. **Fault 注入规则检查** -- 首先检查是否有匹配的注入规则
2. **Use-after-unmap 检测** -- 检查 IOVA 是否已被 unmap
3. **映射查找** -- 查找覆盖该 IOVA 的有效映射
4. **范围检查** -- `(iova + size)` 不能超过映射范围
5. **权限检查** -- DMA 方向必须兼容
6. **GPA 计算** -- `gpa = entry.gpa + (iova - entry.iova)`
7. **脏页标记** -- 如果启用 dirty tracking

#### 4.4.4 Fault 注入规则

```systemverilog
iommu_fault_rule_t rule;
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

为热迁移提供支持，以 4KB 粒度追踪被写入的页面：

```systemverilog
iommu.dirty_tracking_enable = 1;
// ... DMA 操作 ...
bit [63:0] dirty_pages[$];
iommu.get_and_clear_dirty(dirty_pages);
```

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

`virtqueue_error_injector` 支持配置化的错误注入：

```systemverilog
err_inj.configure(
    .err(VQ_ERR_CIRCULAR_CHAIN),   // 错误类型
    .after_n_ops(5),                // 第 5 次操作后注入
    .queue_id('1),                  // 任意队列 ('1 = wildcard)
    .probability(50)                // 50% 概率
);

// 在操作点检查
if (err_inj.should_inject(current_queue_id)) begin
    // 执行错误注入逻辑
end
```

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

BAR 枚举流程：保存原值 -> 写全 1 -> 读回 -> 计算大小 -> 分配地址 -> 写入地址。支持 32/64 位 BAR。

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

#### 4.8.3 Offload Engine

| 引擎 | 功能 |
|------|------|
| `virtio_csum_engine` | TX: 计算伪头部 checksum; RX: 验证完整 checksum |
| `virtio_tso_engine` | TCP 分段，更新 IP/TCP 头部 |
| `virtio_uso_engine` | UDP 分段（1.2+） |
| `virtio_rss_engine` | Toeplitz hash 计算, 间接表查找, 队列选择 |

#### 4.8.4 Failover Manager

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

管理每个 VF 的队列资源映射：

```systemverilog
typedef struct {
    int unsigned vf_id;
    int unsigned local_qid;
    int unsigned global_qid;
    string       queue_name;
} queue_mapping_t;
```

#### 4.9.3 VF Instance

`virtio_vf_instance` 封装单个 VF 的所有组件：`virtio_driver_agent`、`virtqueue_manager`、`virtio_pci_transport`、`virtio_net_dataplane`。提供 `wire_shared()` 方法注入共享组件引用。

#### 4.9.4 VF FLR 流程

```
1. Virtio: on_flr()          -- detach 所有队列, 清理 DMA
2. PCIe: Config Write FLR    -- 通过 pcie_tl_vip
3. poll_config_until()       -- 等待 VF 再次可访问
4. 可选: 重新初始化          -- full_init()
```

### 4.10 环境层 (env/)

#### 4.10.1 配置对象 (`virtio_net_env_config`)

所有可配置参数：

| 类别 | 参数 | 默认值 | 说明 |
|------|------|--------|------|
| 拓扑 | `num_vfs` | 0 | VF 数量（0=纯 PF 模式） |
| | `max_vfs` | 256 | 最大 VF 数 |
| 默认值 | `default_num_pairs` | 1 | 默认队列对数 |
| | `default_queue_size` | 256 | 默认队列大小 |
| | `default_vq_type` | `VQ_SPLIT` | 默认队列类型 |
| | `default_driver_features` | `'1` | 默认 feature（全开） |
| | `default_rx_mode` | `RX_MODE_MERGEABLE` | 默认 RX 模式 |
| | `default_irq_mode` | `IRQ_MSIX_PER_QUEUE` | 默认中断模式 |
| | `default_napi_budget` | 64 | NAPI 预算 |
| | `default_rx_buf_size` | 1526 | RX buffer 大小 |
| | `default_driver_mode` | `DRV_MODE_AUTO` | 默认驱动模式 |
| PCIe | `pf_bdf` | `16'h0100` | PF 的 BDF |
| 内存 | `mem_base` | `64'h1_0000_0000` | host_mem 起始地址 |
| | `mem_end` | `64'h1_FFFF_FFFF` | host_mem 结束地址 |
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
| `VIRTIO_F_SR_IOV` | 37 | 完整 | `num_vfs > 0` |
| `VIRTIO_F_NOTIFICATION_DATA` | 38 | 完整 | `default_driver_features[38]` |
| `VIRTIO_F_RING_RESET` | 40 | 完整 | `default_driver_features[40]` |

---

## 6. 使用指南

### 6.1 快速开始

#### 6.1.1 环境准备

确保以下组件已就位：

```bash
# 外部依赖（通过符号链接）
virtio_net_vip/ext/host_mem      -> /path/to/host_mem
virtio_net_vip/ext/net_packet    -> /path/to/net_packet
virtio_net_vip/ext/pcie_tl_vip   -> /path/to/pcie_tl_vip
```

#### 6.1.2 编译命令 (VCS)

```bash
vcs -full64 -sverilog -ntb_opts uvm \
    +incdir+virtio_net_vip/src \
    +incdir+ext/pcie_tl_vip/src \
    +incdir+ext/host_mem/src \
    ext/pcie_tl_vip/src/pcie_tl_pkg.sv \
    ext/host_mem/src/host_mem_pkg.sv \
    virtio_net_vip/src/virtio_net_pkg.sv \
    virtio_net_vip/tests/virtio_tb_top.sv \
    virtio_net_vip/tests/virtio_base_test.sv \
    virtio_net_vip/tests/virtio_smoke_test.sv \
    virtio_net_vip/tests/virtio_unit_test.sv \
    -o simv -timescale=1ns/1ps
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
        // 将 PCIe RC sequencer 注入每个 VF 实例
        foreach (env.vf_instances[i]) begin
            env.vf_instances[i].wire_shared(
                env.host_mem, env.iommu, env.barrier, env.err_inj,
                env.wait_pol, pcie_env.rc_agent.sequencer,
                cfg.pf_bdf
            );
        end
        env.v_seqr.pcie_rc_seqr = pcie_env.rc_agent.sequencer;
    endfunction
endclass
```

#### 6.3.2 BAR 地址配置

BAR 地址通过 `bar_accessor.enumerate_bars()` 自动枚举和分配。默认 MMIO 窗口从 `0xC000_0000` 开始。可通过设置 `bar.next_bar_alloc_addr` 自定义。

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
- 错误注入类型覆盖 100%
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
| `unmap` | `function void unmap(bit[15:0] bdf, bit[63:0] iova, string file="", int line=0)` | 移除映射 |
| `translate` | `function bit translate(bit[15:0] bdf, bit[63:0] iova, int unsigned size, dma_dir_e access_dir, ref bit[63:0] gpa, ref iommu_fault_e fault)` | 地址翻译 |
| `add_fault_rule` | `function void add_fault_rule(iommu_fault_rule_t rule)` | 添加 fault 规则 |
| `clear_fault_rules` | `function void clear_fault_rules()` | 清除规则 |
| `mark_dirty` | `function void mark_dirty(bit[63:0] gpa, int unsigned size)` | 标记脏页 |
| `get_and_clear_dirty` | `function void get_and_clear_dirty(ref bit[63:0] dirty_pages[$])` | 获取并清除脏页 |
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
| `get_default_driver_config()` | 从默认参数构建 `virtio_driver_config_t` |
| `get_vf_config(vf_idx)` | 获取指定 VF 的配置（有则用，无则回退默认） |
| `validate()` | 配置合法性检查 |
| `convert2string()` | 格式化输出 |

---

## 10. 附录

### 10.1 VCS 编译命令参考

```bash
# 基础编译（单元测试）
vcs -full64 -sverilog -ntb_opts uvm \
    +incdir+virtio_net_vip/src \
    +incdir+ext/pcie_tl_vip/src \
    +incdir+ext/host_mem/src \
    ext/pcie_tl_vip/src/pcie_tl_pkg.sv \
    ext/host_mem/src/host_mem_pkg.sv \
    virtio_net_vip/src/virtio_net_pkg.sv \
    virtio_net_vip/tests/virtio_tb_top.sv \
    virtio_net_vip/tests/virtio_unit_test.sv \
    -o simv -timescale=1ns/1ps

# 完整编译（所有测试）
vcs -full64 -sverilog -ntb_opts uvm \
    +incdir+virtio_net_vip/src \
    +incdir+ext/pcie_tl_vip/src \
    +incdir+ext/host_mem/src \
    ext/pcie_tl_vip/src/pcie_tl_pkg.sv \
    ext/host_mem/src/host_mem_pkg.sv \
    virtio_net_vip/src/virtio_net_pkg.sv \
    virtio_net_vip/tests/virtio_tb_top.sv \
    virtio_net_vip/tests/virtio_base_test.sv \
    virtio_net_vip/tests/virtio_smoke_test.sv \
    virtio_net_vip/tests/virtio_unit_test.sv \
    virtio_net_vip/tests/virtio_stress_unit_test.sv \
    virtio_net_vip/tests/virtio_protocol_test.sv \
    virtio_net_vip/tests/virtio_traffic_test.sv \
    virtio_net_vip/tests/virtio_e2e_test.sv \
    virtio_net_vip/tests/virtio_full_test.sv \
    virtio_net_vip/tests/virtio_dual_test.sv \
    -o simv -timescale=1ns/1ps
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
