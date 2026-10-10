---
title: Virtio ENV 源码导读
subtitle: 从每个对象的创建、队列分配到 TX/RX 业务闭环
version: 1.0 · 代码基线 e2a0a46
date: 2026-10-10
toc_levels: 2
chapter_page_breaks: false
section_page_breaks: false
---

# 1. 阅读范围与方法

## 1.1 本文从哪里开始，到哪里结束

本文讲解 `review/virtio-sdd-optimized` 分支，代码基线为 `e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c`。正文不从几十个类的 API 列表开始，而是从 UVM 创建 `virtio_net_env` 的上层 fixture 开始，逐个追问：这个句柄何时变成对象？内部还创建什么？谁把配置、内存和 PCIe 引用交给它？哪个函数真正分配 ring？哪一步设备才知道队列地址？一次真实提交又如何走到完成和资源释放？

主要代码入口是 [virtio_real_driver_flow_test.run_phase():40](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_test.sv#L40) 和它持有的 `virtio_real_driver_flow_fixture`。这个正式测试会经生产驱动接口提交一个 16 字节 TX payload，由独立 MODEL 设备消费描述符并写回 used ring；它不由测试直接填写描述符或伪造完成。

RX 则单独选择 [virtio_real_driver_rx_test.run_phase():28](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_rx_test.sv#L28)，展开四个随机 IPv4/UDP 报文从设备网络侧入包，到驱动读回实际 Host 内存并做字节比较的过程。TX 和 RX 是两个独立测试运行，不把它们拼成源代码中并不存在的同一次测试。

所有本仓库源码链接都固定到上述完整提交，行号对应该版本。本文是源码教学和静态路径复核，不是新增的仿真通过报告；MODEL 中的“设备”也是 SystemVerilog 行为组件，不等于已经接入真实 RTL。

::: note
建议先读第 2～5 章把对象和 UVM 阶段弄清楚，再读第 6～9 章掌握地址、初始化和队列建立，第 10～12 章跟一次具体业务，最后用第 13 章的时间线复述完整过程。附录和各章的函数导航表用于回到源码。
:::

## 1.2 先区分六种动作

| 动作 | 真正发生的事 | 尚未保证的事 |
| --- | --- | --- |
| 声明 class 句柄 | 有一个保存引用的变量 | 不会自动创建对象 |
| `new / type_id::create` | 对象及其构造默认状态出现 | 不表示 PCIe 已绑定或设备已初始化 |
| 消费冻结 snapshot | 得到 Host、Function、BDF、BAR、qpair 的权威视图 | 不等于分配 ring 或启动流量 |
| 分配 Host backing | manager 产生可访问的 GPA 字节存储 | 不自动建立 IOVA 访问权限 |
| IOMMU 映射 | 为 `{host_id,BDF}` 建立 IOVA→GPA 和方向契约 | 不自动发布 descriptor 或通知设备 |
| 编程队列与发布 avail | 设备知道 ring 地址，随后知道新 buffer 可用 | 不表示设备已写 used 或驱动已回收 |

例如 `transport` 的对象创建、它保存 frozen PCIe identity、它读到 capability、驱动把 queue_enable 写成 1，是四个不同的时点。`vq_mgr` 的对象也不是一组已经分配完的 ring；队列对象通常由后续 `ops.setup_queue()` 创建。

本项目没有 RDMA 中的 PD、MR、RC QP 状态机。Virtio 的 Function 相当于一个独立设备驱动上下文；VIO qpair 是控制面绑定的一对 RX/TX 资源，不是 RDMA QP；payload 和 ring 的 DMA 访问由 Host memory backing 与 IOMMU 映射承担，而不是 STAG/lkey/rkey 注册。

## 1.3 两条路径不能混讲

| 维度 | 本文具体测试主线 | 另外存在的路径 |
| --- | --- | --- |
| 执行对象 | MODEL 独立 `vdev_virtio_pci` | REAL_DUT 外部 RTL，经双向 PCIe 链路 |
| 初始化入口 | fixture 手动调用生产 atomic ops | `fsm.full_init()` 批量初始化 |
| 业务入口 | `flow.submit_tx/refill_rx/receive_rx` | UVM transaction 或 `function.dataplane` |
| 队列格式 | Split | Packed、DPU 私有 custom |
| Function 数量 | Host0 的一个 VIO PF | snapshot 中多个 PF/VF/Host |

最容易误读的地方是配置里 `DRV_MODE_AUTO` 的名字。driver 的 run_phase 等待 sequencer 请求，并不会仅因为这个默认枚举就自己执行 full_init。golden fixture 也明确不调用 full_init：先逐步进行 discovery、reset、feature 和 MSI-X 等动作，再由测试显式 setup 它需要的单个队列。本文会说明自动 FSM 如何调用相同能力，但不把对照路径说成当前测试的实际调用。

另一个误区是 `default_num_pairs=2`。它说明配置和 snapshot 为两对 qpair 预留能力，不代表这个 TX 测试已经创建了 RX0、TX1、RX2、TX3 的全部 ring。实际只建立测试所需的 TX 队列；RX 测试另建自己的 RX 队列。协商 MQ 后，软件预建拓扑还必须与设备接受的 active_pairs 区分。

## 1.4 默认主线参数与地址记法

参数来自 [fixture.build_phase():99](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L99)，不是为了讲课另造的 fixture。

| 参数 | 主线实际值或来源 |
| --- | --- |
| VIO Function | Host0 / PF0；`vio_pf_count=1` |
| BDF、BAR 地址 | 从 frozen snapshot 解析，不硬编码 |
| qpair 资源 | 每 PF 预留两对；qid 从 resource client 查询 |
| queue_size / 格式 | 256 / `VQ_SPLIT` |
| device features | `0x0000000100000001`，CSUM 与 VERSION_1 |
| driver feature mask | 全 1，协商结果仍受 device features 限制 |
| Host memory 范围 | `0x0000000100000000`～`0x00000001FFFFFFFF` 配置区间 |
| Host 分配策略 | `HOST_MEM_RANDOM`；fixture 创建 Buddy manager |
| IOMMU | strict 开启，IOVA 默认随机策略 |
| IRQ / NAPI budget | `IRQ_MSIX_PER_QUEUE` / 64 |
| 检查组件 | scoreboard 开；coverage 关 |

随机分配意味着不能把一次运行的具体 GPA/IOVA 写成所有 seed 下的默认地址。后文用 `G_desc/G_avail/G_used` 表示三段 ring 的 GPA，用 `I_desc/I_avail/I_used` 表示设备可见的 IOVA；`G_hdr/G_pkt`、`I_hdr/I_pkt` 表示一次 TX 的 header/payload 地址。相同数值地址的合法复用也必须带上 Host 和 BDF 来讨论。

默认普通 Virtio-net 布局中 pair0 的 RX/TX qid 为 0/1，但测试仍调用 `rx_queue_id_for_pair/tx_queue_id_for_pair` 查询冻结的资源绑定。后文使用 qid=1 讲 TX 时，是该默认布局的结果，不是要求业务代码自行用 `2*pair+1` 重建权威 placement。

## 1.5 目录和层次分工

以下源码目录均位于 `virtio_net_vip/src/`，测试位于 `virtio_net_vip/tests/`。

| 目录 | 负责什么 | 不应让它代替谁 |
| --- | --- | --- |
| `env/` | env 装配、行为配置、执行模式、检查与附件 | 不重分配 DPU 权威身份 |
| `sriov/` | PF/Function/VF 包装与资源 client | 不私造 BDF/BAR/qpair |
| `agent/` | driver、ops、FSM、monitor、DMA 所有权 | 不代替设备完成 DMA |
| `transport/` | PCI 配置/BAR/capability/notify 与观察适配 | 不另建 Host allocator |
| `virtqueue/` | ring 格式、descriptor、avail/used、回收 | 不自行代表真实通知已发送 |
| `iommu/` | Host-qualified IOVA 翻译、方向权限和故障 | 不分配 BAR 或 payload |
| `dataplane/` | TX/RX/offload 高层业务适配 | 生产 buffer/notify 委托 ops |
| `devmodel/` | MODEL 独立设备解析、DMA 与完成 | 不在 REAL_DUT 下偷偷工作 |
| `pcie/` | 设备 DMA 和 REAL_DUT Host 服务适配 | 不接管外部 PCIe 生命周期 |

`dpu_common`、`host_mem`、`pcie_work`、`net_packet`、`queue_work` 是外部依赖。教学文档只消费本项目暴露的契约，不把它们复制进 Virtio 仓库，也不修改其实现。
