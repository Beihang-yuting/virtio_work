# VIP 标准模式与 DPU 驱动 Virtio ring 对照

审计日期：2026-09-30；真实驱动负向复跑日期：2026-10-09。

驱动依据为 `ubuntu@10.11.10.53:/home/ubuntu/wn/icpu-kernel-driver`，
分支 `lance_net_mailbox`、提交 `f2c9cd6`；检查时该驱动工作树无修改。
本次比较的是驱动 `priv_ring=false` / `DPU_RING_T_VIRTIO` 路径。
本目录原有私有测试验证的是 `priv_ring=true`，不能拿它的通过结果证明前者兼容。

## 结论

当前 VIP 标准模式不能直接替代这条 DPU 驱动的 Virtio ring 路径。
驱动使用 packed 形式的描述符，但 Ethernet 数据布局、控制面和通知方式仍属于
DPU 设备协议。单独设置 `VQ_PACKED` 不会消除这些差异。

此外，本次审计发现驱动的完成判断与自身发布状态矛盾，以及 VIP 标准路径中
modern header 长度和 packed 通知游标的独立问题。这些问题应分别修正或澄清，
不能通过修改标准 Virtio 定义去复制驱动中的可疑行为。

## 逐项比较

| 项目 | 当前 VIP 标准模式 | DPU 驱动 `priv_ring=false` | 影响 |
| --- | --- | --- | --- |
| 队列类型 | 支持 split/packed；env 默认 split | `xring_packed_desc`，没有对应的 split 数据路径 | 仅改 packed 是必要但不充分的步骤 |
| 基础描述符 | packed 为 `addr64/len32/id16/flags16`，16B | 基础大小及 addr/len/id 偏移相同 | 布局相似不等于整个协议相同 |
| TX 数据 | 默认普通发送为独立 net header SG + payload SG | DMA 直接映射 `skb->data` 及 frags，无 `virtio_net_hdr` | 同一包的首描述符、长度和实际 DMA 字节不同 |
| RX 数据 | 解析并剥离 net header，合包依据 `num_buffers` | 从 buffer 起始字节构造 Ethernet skb，包长来自 descriptor.len | 直接混用会误读/截断帧头；多 buffer 合包规则也不同 |
| 建队和启停 | Virtio PCI capability、status/features 和 common config | AF 直配或 PF/VF mailbox，写 DPU queue 参数表的 `virtio_mode` | 需要 DPU 控制后端，不能沿用标准 FSM 初始化 |
| 通知 | 由 notify capability + queue_notify_off 定位；未协商 NOTIFICATION_DATA 时写 16bit qid，协商后写 32bit | 固定 32bit `wrap<<31 \| tail<<16 \| local_qid` 到 `notify_addr` | 宽度、地址计算、特性前提不同；32bit 字格式本身可与标准 packed notification data 相同 |
| 环附属区域 | packed 分配并使用两份 4B event suppression 结构 | 标准分支仅分配 desc，CQ 大小为 0，未配置两份 event suppression | 通知抑制机制不相同；不是新增私有 CQ 的格式 |
| RX WRITE 标志 | 可写 RX 描述符设置 bit 1 | 首次零初始化后只设置 addr/len/avail/used，未设置 write | 驱动可能依赖 RX 队列方向；与标准描述符权限不同 |
| INDIRECT 标志 | bit 2，`0x0004` | C 位域先保留 bit 2，再把 indirect 放在 bit 3，`0x0008` | 间接描述符不兼容；当前驱动普通发送路径本身未使用 indirect |

驱动定位：`txrx.h:60`（描述符）、`txrx.h:479`（doorbell）、
`txrx.c:914`（RX 发布）、`txrx.c:1516`（TX 映射）、`txrx.c:2431`（RX 收包）、
`txrx.c:2659` / `txrx.c:2747`（环分配）、`txrx.c:2833`（控制后端分派）、
`af_mng.c:1350` / `af_mng.c:1390`（设备队列参数）。这些行号属于上述远端驱动。

VIP 定位：

- [标准 ops](../../virtio_net_vip/src/agent/virtio_atomic_ops.sv)：`setup_queue()`、`tx_submit()`、`rx_receive()`。
- [标准 FSM](../../virtio_net_vip/src/agent/virtio_auto_fsm.sv)：`do_full_init()`。
- [标准 PCI transport](../../virtio_net_vip/src/transport/virtio_pci_transport.sv)：`kick()`。
- [packed queue](../../virtio_net_vip/src/virtqueue/packed_virtqueue.sv)：`alloc_rings()`、`add_buf()`、`poll_used()`。

## 需要单独处理的问题

### 1. 驱动完成条件与发布状态矛盾

驱动 TX/RX 发布时均写入 `avail=wrap`、`used=!wrap`。
但 `txrx.c:1684` 的 RX 完成谓词返回 `used != avail`；
`txrx.c:1828` 的 TX 回收在 `used == avail` 时反而停止。

因此，仅代入驱动自己刚写入的状态，RX 谓词就返回“已完成”，TX 条件也允许回收；
标准设备把 used 更新成 avail 后，驱动反而判为不可回收。此处需要同驱动维护者及
RTL 完成写回约定核实。2026-09-30 的初次审计只复现 C 谓词；2026-10-09 已增加
真实 Linux 模块负向复跑（见下文），但仍未在真实 RTL/DUT 上验证完成写回约定。

### 2. VIP 的 modern net header 长度漏掉 VERSION_1 条件

[virtio_net_hdr.sv](../../virtio_net_vip/src/types/virtio_net_hdr.sv) 的
`get_hdr_size()` 仅检查 HASH_REPORT 和 MRG_RXBUF，均为零时返回 10。
对于已协商 `VIRTIO_F_VERSION_1=1` 的 modern 设备，基础 header 应为
12B（Linux UAPI `struct virtio_net_hdr_v1`）；10B 是 legacy 非 mergeable 格式。

触发条件：VERSION_1=1、MRG_RXBUF=0、HASH_REPORT=0。影响 TX header 描述符长度
以及 RX payload 起点。这是 VIP 标准路径问题，与 DPU 直接使用原始帧的差异分开处理。

**状态（2026-10-06）：已修复。** `get_hdr_size()` 在 VERSION_1 或 MRG_RXBUF 时返回 12；
`num_buffers` 仅在协商 MRG_RXBUF 时用于合包（atomic ops 与 RX engine 两条路径）。
回归：`virtio_protocol_test` 覆盖 10/12/20B 尺寸，`virtio_indirect_desc_test` 覆盖
VERSION_1 TX header 描述符 12B 及无 MRG_RXBUF 时 RX 不合包。

### 3. VIP 的 packed 通知传入包数和固定 wrap

[virtio_atomic_ops.sv](../../virtio_net_vip/src/agent/virtio_atomic_ops.sv) 的
TX/RX 通知调用为 `transport.kick(queue_id, vq.total_add_buf_ops, 0)`。
`total_add_buf_ops` 是成功投递的 buffer chain 数，不是 packed 描述符槽游标；
wrap 也不能固定为 0。

首圈一次普通 TX 使用 header+payload 两条描述符时，下一槽应为 2、wrap 应为 1，
当前生产调用传入 1/0。协商 NOTIFICATION_DATA 后会形成错误的 32bit 通知内容；
未协商该特性时只写 qid，此问题不会体现在通知数据中。

**状态（2026-10-06）：已修复。** virtqueue 新增 `get_notify_next_idx()/get_notify_wrap()`：
split 返回 `avail_idx`，packed 返回下一描述符槽及驱动 wrap counter，自定义队列保持原值。
atomic ops 的 TX、RX refill、Admin VQ、control VQ 通知均改用该游标。
回归：`virtio_indirect_desc_test` 校验 split 1/0、packed 首包 2/1、回绕后 0/0。

## 验证边界与后续接入

本次采用从驱动原样提取的 C 位域/完成谓词探针，以及调用生产 packed queue 和
atomic_ops 的临时 VCS 测试。探针不改动生产实现，抓取标准 TX 的 transport 参数，
用显式设备完成字节验证 RX 发布与完成边界。它们用于确认差异，不是端到端兼容性测试。

53 上的实际观察结果如下：

| 探针 | 观察结果 |
| --- | --- |
| GCC C ABI | 驱动 desc 大小 16B，addr/len/id 偏移 0/8/12；indirect 为 `0008`，Linux 为 `0004` |
| GCC 完成谓词 | wrap=0：posted `8000` 判完成，completed `0000` 判未完成；wrap=1：posted `0080` 判完成，completed `8080` 判未完成 |
| VCS 生产 RX | posted `0082` 判未完成；设备写回 `8082` 后判完成，WRITE=1 |
| Header | Linux legacy/modern 为 10/12B；VIP 在 VERSION_1=1、MRG=0、HASH=0 时为 10B |
| VCS 生产 TX | header=10B、payload=128B，两个 flags 分别为 `0081/0080`；kick 实参 next=1、wrap=0，应为 next=2、wrap=1 |

VCS 编译成功，审计测试 `virtio_standard_audit_test` 的 UVM 计数为
INFO=8、WARNING=0、ERROR=0、FATAL=0。测试明确输出上述差异；零 UVM 错误
只表示探针正常执行，不能解释为问题已修复或驱动已兼容。

临时探针及日志保存在 53 的 `/tmp/virtio_work_standard_audit.2rhnhg/audit/`：
`driver_abi_probe.log`、`standard_audit_vcs.log`、`standard_audit_run.log`。
本轮未修改生产 SV 或远端驱动的行为，只增加审计记录。

### 2026-10-09 真实驱动负向复跑

为确认上述静态矛盾是否会在真实 Linux 驱动流程中出现，本轮在 53 的
`~/cosim_diff` 临时复制 rootfs，仅把模块加载改为
`insmod /lib/modules/extra/dpu_snd1.ko priv_ring=0`，然后执行 AF probe、link up
和 4 个 128B 报文的回环场景。驱动、正式 guest 镜像和生产 SV 均未修改；使用的
模块仍是 `lance_net_mailbox@f2c9cd6` 编译产物。

运行结果为负向复现：

- 模块加载、AF probe、netdev 创建和 link up 成功，guest 写出 marker 2，说明失败点
  已进入 S2 数据面，而不是 PCI ID、BAR、AF 声明或建队阶段。
- 当前 `vdev_dpu_priv` 对 `virtio_mode=1` 只告警，仍按私有环解释描述符并写私有 CQ。
  在第一次中断前，模型能够从两种格式共有的 `addr/len/NEXT/AVAIL/USED` 位读取 4 个
  TX 帧，并把 4 个完全相同的 128B 帧写入 RX buffer；事件记录为 4 TX、4 RX、
  8 条 `desc_chain`、8 条 `complete` 和 1 条 IRQ。
- 第一次 IRQ 后，驱动把尚保持发布状态的 RX 描述符判成完成，持续成批回收、补充并
  再写 doorbell。终止前共产生 399645 条 notify，其中 q0 RX 为 399639 条；场景没有
  输出 `VDEV_PKTGEN` 或结束 marker，`RUN_COSIM` 以 `guest_rc uvm` 失败。

这个复现同时包含两个独立问题，不能把它解释为 DPU Virtio ring 已经可用：

1. 设备模型尚未实现 `virtio_mode=1` 的完成路径；它不应为该模式写私有 CQ，而应按
   packed 语义在 DMA 数据和长度写完后写回 `USED=AVAIL`。
2. 即使模型按 packed 语义写回，未修改驱动的 RX helper 会把 `USED=AVAIL` 判成未完成，
   TX cleaner 也会在同一条件下停止。因此不能通过让模型反向写 flags 来迎合驱动；
   这会掩盖驱动发布/完成谓词的自相矛盾。

归档位于 53 `~/cosim_diff/out/dpuvirt_baseline/scen/`。关键文件 SHA256 为：

- `guest.log`：`71ad9db6a5c25562785536c783af82dfdde70b1439f312b1f374d66a856506b5`
- `vcs.log`：`e41b6cc72f678ec2175e44c524ff49df20567bc519c2d678926484b3e7bd009b`
- `linux.jsonl`：`028c5cd2244b12605c6c92107a51be1ae7d0eae6c6728572fda8b3bbe3fde21c`

因此，`dpu_snd1.ko priv_ring=0` 当前裁决为 **FAIL / driver-blocked**。修复顺序应为：
先由驱动与 RTL owner 确认 packed 完成约定；若采用标准约定，则把 RX 完成条件改为
`used == avail`，把 TX 停止条件改为 `used != avail`；随后实现独立 DPU Virtio
设备路径并重新执行 S1/S2/S4。此前的标准 `virtio_net` PASS 和
`dpu_snd1.ko priv_ring=1` PASS 均不能替代这项验证。

如果需要覆盖驱动 `priv_ring=false`，应增加单独的 DPU Virtio ring 模式：
复用 Host/Function 隔离及 DPU 控制接口，实现原始帧数据路径和 DPU doorbell，
并在确认完成协议后适配 packed 描述符。已有 `custom_virtqueue` 对应私有 W1/W2+CQ
格式，也不能直接用于这个分支。

标准 Virtio 模式则应继续遵循标准定义，并分别修正上述 header 与通知游标问题。
