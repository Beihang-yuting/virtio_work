# virtio_net_vip 验证框架与端到端流程

> 整理日期 2026-09-09，基于 master 分支。目标读者：需要理解"配置怎么下发、
> 包怎么发出去、notify 怎么到设备、真实 DUT 怎么接入"的集成与验证人员。
> 关键跳均附 `类::方法 file:line` 实证，行号以整理当日代码为准。

## 1. 框架总览

```
                        测试 / real_driver_flow_fixture（模式分叉点）
                                        │
        ┌───────────────────────────────┼───────────────────────────────┐
        │                        virtio_net_env                          │
        │   （消费 dpu_common 冻结快照建拓扑；两段式原子 PCIe 绑定）        │
        │                                                                │
        │  每 Function（PF/VF 同构）─────────────┐   共享基础设施          │
        │  ┌──────────────────────────────────┐ │  ┌──────────────────┐  │
        │  │ driver_agent                     │ │  │ host_mem_manager │  │
        │  │  ├ atomic_ops(~30)/auto_fsm(12态) │ │  │ iommu_model      │  │
        │  │  ├ monitor ──────────┐           │ │  │ barrier/wait_pol │  │
        │  │  └ observer_adapter ─┤(被动解码)  │ │  │ err_inj/perf_mon │  │
        │  │ vq_mgr (Split/Packed/Custom)     │ │  └──────────────────┘  │
        │  │ dataplane (TX/RX + 4 offload)    │ │   scoreboard / cov     │
        │  │ transport (bar_accessor/cap_mgr/ │ │                        │
        │  │            notify_mgr)           │ │                        │
        │  └───────────┬──────────────────────┘ │                        │
        └──────────────┼────────────────────────┴────────────────────────┘
                       │ pcie_tl_tlp（唯一通货）
                ┌──────┴──────┐
                │ pcie_tl_env  │ ← pcie_work，由 test 创建后注入
                └──┬────────┬──┘
          MODEL 模式│        │REAL_DUT 模式
     ┌─────────────┴──┐  ┌──┴──────────────────────┐
     │ TLM 回环        │  │ SV 接口（pcie_tl_if ×2） │
     │ dut_responder + │  │ 真实 RTL DUT             │
     │ model_dma_adapt │  │ DUT DMA ← real_dut_host_ │
     │ （发真 EP TLP）  │  │ mem_responder+iova_proxy │
     └─────────────────┘  └─────────────────────────┘
```

两条设计主线：

1. **拓扑零字面量**：BDF/BAR/VF 数/qpair 全部来自 dpu_common 冻结快照
   （`dpu_device_snapshot` + `dpu_resource_snapshot`），env 越权即 FATAL。
2. **语义/执行解耦**：driver、virtqueue、transport、monitor、scoreboard 在两
   模式完全共用；模式切换是运行期枚举 `+VIRTIO_EXEC_MODE=`，无编译宏。
   MODEL 下设备侧也发真实 EP-originated TLP（走 TLM 传输），两模式下
   monitor 看到的事件序列同构。

## 2. 模块职责速查

| 模块 | 作用 |
|---|---|
| types/ | 模式/完成/故障枚举、host-qualified 身份（{host_id, BDF, IOVA}） |
| shared/ | 等待策略、内存屏障、BAR 区间预留 |
| iommu/ | 域隔离地址翻译 + 故障注入 + 脏页跟踪（迁移用） |
| virtqueue/ | 三种队列的字节级 ring 模型（全部经 host_mem，模式无关） |
| transport/ | virtio-pci 语义→TLP：BAR 访问、cap 解析、中断管理、初始化状态机 |
| agent/ | 驱动本体：原子操作库 + 自动 FSM + monitor/observer |
| dataplane/ | TX/RX 引擎 + csum/TSO/USO/RSS offload |
| sriov/ | PF/VF 编排（PCIe 机械层委托 pcie_work）、Admin VQ |
| pcie/ | 模式边界 5 文件（MODEL 设备模型 / REAL_DUT DMA 服务） |
| env/ | 快照消费、组件树组装、原子 PCIe 绑定、并发控制器 |

## 3. 阶段 A：配置下发（设备初始化）

全部配置访问最终经 `virtio_bar_accessor` 变成 TLP 从 `pcie_rc_seqr` 发出。

1. **BAR 枚举**：`virtio_bar_accessor::enumerate_bars`（bar_accessor.sv:825）
   ——每 BAR：CfgRd 原值 → CfgWr 全 1 → CfgRd sizing → 回写分配基址；
   64-bit BAR 对做上半段 sizing。TLP 类型 CfgRd0/CfgWr0。
2. **Capability 链**：`virtio_pci_cap_manager::discover_capabilities`
   （cap_manager.sv:103）——从 cfg 0x34 起遍历，解析 5 种 virtio vendor
   cap（common/notify/ISR/device/pci）与 MSI-X cap；NOTIFY cap 额外读
   `notify_off_multiplier`（:253）。
3. **spec 7.2 状态机**：`virtio_pci_transport::full_init_sequence`
   （pci_transport.sv:605），全是 common cfg BAR 的 MemWr/MemRd：
   - reset：status(0x14)=0，轮询读回 0；
   - ACKNOWLEDGE(0x01) → DRIVER(0x03)；
   - **feature 64-bit 两段协商**：DFSELECT(0x00)/DF(0x04) 读两轮拼 64 位，
     GFSELECT(0x08)/GF(0x0C) 写两轮（:225-249）；
   - FEATURES_OK(0x0B) + 回读校验，失败写 FAILED；
   - 读 num_queues(0x12)。
4. **逐队列配置**：`virtio_atomic_ops::setup_queue`（atomic_ops.sv:627）：
   queue_select(0x16) → 读 size max(0x18) → `vq.alloc_rings()`（host_mem
   三块：desc 4K 对齐/avail/used）→ 三段 `iommu.map_for_host()`（失败
   回滚）→ **IOVA** 写入 desc/avail/used 地址寄存器（0x20–0x34）→
   MSI-X vector 绑 0x1A → 读 queue_notify_off(0x1E) 存表 →
   queue_enable(0x1C)=1。
5. **MSI-X 表**：`virtio_notification_manager::setup_msix`（:88）——每
   vector 写 msg_addr(0xFEE0_0000+…)/msg_data/mask 共 4 DW；vector 分配
   三级降级 per-queue → shared → INTx（:149）。
6. DRIVER_OK(0x0F)。配置面完成，设备可收 kick。

## 4. 阶段 B：发包（TX）

7. `virtio_atomic_ops::tx_submit`（atomic_ops.sv:895）：packet_item 经
   `virtio_net_packet_adapter::pack` 转字节流 → 填 `virtio_net_hdr`
   （csum/GSO 标志）→ host_mem 分配 hdr+payload（DWORD 对齐防
   Completion 跨块）并写入 → `iommu.map_for_host(DMA_TO_DEVICE)` 拿
   IOVA（失败逐级回滚）→ 组 SG（**地址是 IOVA**）。
8. `split_virtqueue::add_buf`（split_virtqueue.sv:251）：free list 取
   desc → `write_desc` 把 16 字节描述符 **LE 逐字节写进 host_mem**
   （:52-62）→ `wmb()` → 写 avail ring 槽 → avail.idx++ → `mb()`
   （:353-365）。此刻队列有活，设备未知。

## 5. 阶段 C：notify（kick）与完成回收

9. `needs_notification()` 判定（event_idx 抑制）→
   `virtio_pci_transport::kick`（pci_transport.sv:544）：
   - notify 地址 = notify BAR 基址 + `notify_cap.offset +
     queue_notify_off[qid] × notify_off_multiplier`（cap_manager.sv:387）；
   - notify 值 = `{queue_id}`（NOTIFICATION_DATA 开启时带 avail idx/wrap）；
   - 经 `bar.write_reg` 发出一条 **MemWr TLP**——门铃。
10. **设备侧收 kick（MODEL）**：`virtio_pcie_observer_adapter::write`
    （observer_adapter.sv:135）在 monitor 流量中认出落在 notify 窗口的
    MemWr → `virtio_monitor::observe_queue_notify`（monitor.sv:236，校验
    门铃地址与队列使能）→ ATOMIC_KICK 事务 → `virtio_pcie_dut_responder`
    订阅消费（dut_responder.sv:266→354）→ 经
    `virtio_pcie_model_dma_adapter` 发 **EP→RC MemRd TLP** 读 avail/desc
    链（IOVA 逐 4KiB 块经 iommu 翻译，dut_responder.sv:730）→ 读/写
    payload → MemWr 写 used ring（:675-698）→ 中断。
    注意：MODEL 的 MSI-X 走 sideband 直调
    `notify_mgr.on_interrupt_received`（:703-716，刻意不发 0xFEE0 TLP，
    原因见该处注释）；REAL_DUT 才有真实中断 TLP。
11. **驱动侧完成回收**：中断 → `virtio_monitor::observe_interrupt`
    （monitor.sv:190）→ auto_fsm 的 interrupt/tx_complete 循环唤醒
    （auto_fsm.sv:1955/1907）→ `virtio_atomic_ops::tx_complete`
    （atomic_ops.sv:1081）→ `split_virtqueue::poll_used`
    （split_virtqueue.sv:403：`rmb()` → 读 used.idx → 取 {id,len} →
    token 还原 → desc 链归还 free list）→ unmap IOVA + free host_mem。

## 6. REAL_DUT 模式差异点

同一链路在 REAL_DUT 下变化的跳（fixture 分叉见
tests/virtio_real_driver_flow_fixture.sv:196-237）：

| 环节 | 差异 |
|---|---|
| BAR/config 访问 | 不装 TLM override，走基类 seq 发真 TLP 等 `rb_done`；EP 不装寄存器镜像，config/BAR 响应全部来自 RTL |
| kick | 驱动侧完全不变；MemWr TLP 经 `rc_adapter.vif`（pcie_tl_if）串行化到线上被 DUT 采样 |
| 设备行为 | 不创建 dut_responder——设备行为全部是 RTL 自己的 |
| DUT DMA | `virtio_pcie_real_dut_host_mem_responder` 订阅 **RC monitor** 的 EP→RC 流量（real_dut_host_mem_responder.sv:159），按 requester BDF 过滤、串行交 RC driver 回 CplD；内存经 `virtio_pcie_iova_host_mem_proxy`：读走 `translate_for_host`，写走 `write_from_device_for_host`（权限+脏页一体，iova_proxy.sv:160-187） |
| 中断 | DUT 发真实 MSI-X MemWr（0xFEE0_xxxx），`observer_adapter::decode_msi_memory_write`（:234）比对 MSI-X 表解码 vector；INTx Message 亦有解码分支（:200-224） |
| used 回收 | 与 MODEL 完全一致——读的是 DUT 经 proxy 写进共享 host_mem 的同一批字节 |

内置护栏：REAL_DUT 要求双向 VIF（fixture:462-465）；要求
`+VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1`（:470-477）；与 pcie_work
backend bridge（cosim）互斥防重复 Completion（:375-379）。

## 7. 真实 DUT 集成步骤

1. **写平台 wrapper top**（当前 `virtio_tb_top.sv:59-69` 的 vif 实例化是
   注释态）：实例化 RC→EP / EP→RC 两条 `pcie_tl_if` 并 config_db set；
   DUT 为 PIPE/SerDes 口时中间接 pcie_work 的 SVT/PIPE 桥。
2. 启动参数：`+VIRTIO_EXEC_MODE=REAL_DUT
   +VIRTIO_REAL_DUT_HOST_MEM_RESPONDER=1`，fixture 自动完成模式切换。
3. DUT DMA 服务链自动就位（见第 6 节），无需额外代码。
4. 中断路径自动解码（MSI-X 表比对 / INTx Message）。
5. **建议先"伪 DUT 点亮"**：用 pcie_tl_vip 的 EP agent 当假 DUT 把
   REAL_DUT 分支全部跑活（这些代码当前回归零执行），并优先补两个洞：
   RX 入包源（`REAL_DUT_RX_SOURCE_UNAVAILABLE`）与 host-mem responder
   的多 {host,BDF} 分派（现单绑定，SR-IOV 会卡）。

## 8. 已知缺口（截至整理日）

1. REAL_DUT 通路未点亮：TB 顶层 vif 注释态、回归零执行、计划中的
   observer 组件与 mode test 未创建；
2. RX 无入包源；responder 单 {host,BDF} 绑定；寄存器执行器无生产 transport；
3. 回归单种子、覆盖率默认不收集、日志门禁纯否定式；
4. 手册部分章节滞后于实现（indirect/Admin VQ 成熟度描述与 README 矛盾）。
