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
| EDA 工具 | Synopsys VCS（已验证通过） |

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
└── ext/                                    ← 外部组件符号链接
    ├── host_mem       → 内存管理组件
    ├── net_packet     → 协议报文产生器
    └── pcie_tl_vip    → PCIe TL 层 VIP
```

---

## 外部依赖

本 VIP 依赖三个外部组件，通过 `ext/` 目录的符号链接集成，**不修改任何外部组件代码**：

| 组件 | 功能 | 主要接口 |
|------|------|---------|
| **pcie_tl_vip** | PCIe TL 层 VIP，提供 RC/EP Agent、TLM 回环、SR-IOV func_manager | `pcie_tl_env`（子环境）、`uvm_sequencer #(pcie_tl_tlp)`（RC 序列器） |
| **host_mem_manager** | Buddy Allocator 内存管理，提供分配/释放/读写/泄漏检查 | `alloc()`、`free()`、`write_mem()`、`read_mem()`、`leak_check()` |
| **net_packet** | 协议报文产生器，支持 L2-L4、隧道（VXLAN/GRE/Geneve）、RDMA、存储协议 | `packet_item`（UVM sequence item 封装） |

---

## 快速开始

### 环境要求

- Synopsys VCS（已验证版本：Q-2020.03-SP2-7）
- UVM 1.2 或更高版本
- 上述三个外部组件已就位

### 编译命令

```bash
VCS_HOME=/opt/synopsys/vcs/Q-2020.03-SP2-7

$VCS_HOME/bin/vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps \
    +incdir+<host_mem>/src \
    +incdir+<pcie_tl_vip>/src \
    +incdir+<pcie_tl_vip>/src/types \
    +incdir+<pcie_tl_vip>/src/shared \
    +incdir+<pcie_tl_vip>/src/agent \
    +incdir+<pcie_tl_vip>/src/adapter \
    +incdir+<pcie_tl_vip>/src/env \
    +incdir+<pcie_tl_vip>/src/seq/base \
    +incdir+<pcie_tl_vip>/src/seq/constraints \
    +incdir+<pcie_tl_vip>/src/seq/scenario \
    +incdir+<pcie_tl_vip>/src/seq/virtual \
    +incdir+src +incdir+src/types +incdir+src/shared +incdir+src/iommu \
    +incdir+src/virtqueue +incdir+src/transport +incdir+src/callbacks \
    +incdir+src/agent +incdir+src/dataplane +incdir+src/sriov +incdir+src/env \
    +incdir+src/seq/base \
    +incdir+src/seq/scenario/lifecycle +incdir+src/seq/scenario/dataplane \
    +incdir+src/seq/scenario/interrupt +incdir+src/seq/scenario/migration \
    +incdir+src/seq/scenario/sriov +incdir+src/seq/scenario/error \
    +incdir+src/seq/scenario/concurrency +incdir+src/seq/scenario/dynamic \
    +incdir+src/seq/scenario/boundary +incdir+src/seq/virtual \
    <host_mem>/src/host_mem_pkg.sv \
    <pcie_tl_vip>/src/pcie_tl_if.sv \
    <pcie_tl_vip>/src/pcie_tl_pkg.sv \
    src/virtio_net_pkg.sv \
    tests/*.sv \
    -top virtio_tb_top -o simv
```

> 将 `<host_mem>`、`<pcie_tl_vip>` 替换为实际路径。

### 运行测试

```bash
# 单元测试（无需 PCIe 环境，验证基础组件）
./simv +UVM_TESTNAME=virtio_unit_test +UVM_VERBOSITY=UVM_LOW

# 压力测试（256 描述符填满/排空、带宽限制、故障注入、Packed 队列）
./simv +UVM_TESTNAME=virtio_stress_unit_test +UVM_VERBOSITY=UVM_LOW

# 协议测试（virtio_net_hdr 打包解包、校验和、TSO、RSS）
./simv +UVM_TESTNAME=virtio_protocol_test +UVM_VERBOSITY=UVM_LOW

# 端到端集成测试（完整 virtio 初始化流程通过 PCIe TLP）
./simv +UVM_TESTNAME=virtio_e2e_test +UVM_VERBOSITY=UVM_MEDIUM

# 完整集成测试（Completion Bridge + 完整初始化 + 1250 个 TLP）
./simv +UVM_TESTNAME=virtio_full_integration_test +UVM_VERBOSITY=UVM_LOW

# 大流量测试（1000 包回环 + 带宽控制 + 协议完整性 + 队列压力）
./simv +UVM_TESTNAME=virtio_traffic_test +UVM_VERBOSITY=UVM_LOW

# 双 VIP 互打测试（双向各 1 万包 + 带宽控制验证）
./simv +UVM_TESTNAME=virtio_dual_test +UVM_VERBOSITY=UVM_LOW
```

---

## 测试结果

### 单元测试和协议测试

| 测试名称 | 测试子项 | 结果 |
|---------|---------|------|
| 单元测试 | host_mem 分配读写 / IOMMU 映射翻译 / Split 队列操作 / 等待策略 | 4/4 通过 |
| 压力测试 | 256 描述符填满 / 带宽限制器 / 故障注入 / Packed 队列 / 队列管理器 | 5/5 通过 |
| 协议测试 | net_hdr 往返(10/12/20字节) / 校验和引擎 / TSO 引擎 / RSS 引擎 / Offload 检测 | 5/5 通过 |

### 集成测试（通过 PCIe TLP 通路）

| 测试名称 | 验证内容 | TLP 数量 | 结果 |
|---------|---------|---------|------|
| 端到端初始化 | BAR 枚举 → Cap 发现 → 完整 init → 队列配置 → kick | ~100 | 通过 |
| 完整集成 | 初始化 + 大流量读写 + 带宽控制 + 协议完整性 | 1,250 | 通过 |

### 双 VIP 互打测试

| 测试场景 | 报文数量 | 数据校验 | 结果 |
|---------|---------|---------|------|
| 双向对称大流量 | A→B 1000 + B→A 1000 = 2,000 | 2,000/2,000 通过 | 通过 |
| 非对称流量 | A→B 2000 + B→A 200 = 2,200 | 2,200/2,200 通过 | 通过 |
| 混合包长（64-1500B）| 双向各 480 = 960 | 960/960 通过 | 通过 |
| 队列 wrap 压力（qsize=32）| 双向各 500 = 1,000 | 0 描述符泄漏 | 通过 |
| **带宽控制（2 万包）** | **3 阶段 × 20,000 = 60,000** | **全部通过** | **通过** |

### 带宽控制精度

| 限速配置 | 实测吞吐 | 节流次数 | 精度误差 |
|---------|---------|---------|---------|
| 无限制 | 600 Gbps | 0 | — |
| 10 Gbps | 10.4 Gbps | 19,154 | 4% |
| 1 Gbps | 1.004 Gbps | 19,917 | 0.4% |

**累计测试报文数: 66,000+，全部通过，0 错误。**

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
        virtio_smoke_vseq vseq;
        phase.raise_objection(this);

        vseq = virtio_smoke_vseq::type_id::create("vseq");
        vseq.vf_seqr = env.vf_instances[0].driver_agent.sequencer;
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

适用于 VIP 自身验证和功能开发阶段。当前所有测试均在此模式下运行。

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
