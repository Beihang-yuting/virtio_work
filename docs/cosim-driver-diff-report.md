# 真实驱动对比验证报告

## 1 概述

**目的。** 让两类驱动面对同一个独立设备模型（`virtio_net_vip/src/devmodel`）：一类是真实 Linux 驱动（QEMU guest 经 cosim 桥接到 VCS 中的设备模型），另一类是 VIP 驱动（同一模型，VIP 测试平台）。逐场景对比两侧的设备侧语义事件，凡有差异就判定归属：VIP 有误、设备模型有误，或两者都合规。前两类就地修复并补回归测试，第三类列入白名单，并写明依据（驱动源码或 virtio 规范）。

| 项 | 值 |
|---|---|
| 日期 | 2026-10-07 至 2026-10-08；优化分支最终复跑日期为 2026-10-08 |
| VIP 分支 | `review/virtio-sdd-optimized`，优化版本快照 `5fab403`，恢复闭环提交 `bf57262`，MQ 预建/设备提交状态闭环 `aee1c5f` |
| 设备模型 | `vdev_virtio_pci`（1af4:1041）与 `vdev_dpu_priv`（20f9:5013），D1 起建立（`d2cd0d9`），最后一次模型改动 `5e433e0` |
| QEMU | 9.2.0，TCG，`-M q35 -smp 1 -m 512M` |
| cosim-platform | 从 59 的 `6b99406` 工作树原样复制（含未提交改动，记于 `cosim-platform.SOURCE`），另加本地补丁（`cosim-pcie-rc`：多 BAR 64 位、MMIO 单 DW、MSI-X 消息经 BH 投递；53 `~/cosim_diff` 中的 `0dfb7d1`、`1c7c875`、`8d2a461`） |
| guest | 内核 6.8.0-107-generic，用户态 Alpine 3.20（busybox/openrc） |
| 私有驱动 | dpu_snd1：icpu-kernel-driver `lance_net_mailbox@f2c9cd6`，在本机用 noble 头文件 6.8.0-107 编译，无需兼容补丁 |
| 仿真器 | VCS W-2024.09-SP1，UVM 1.2 |
| dpu_common | `4d73996` |
| 临时环境 | 53 `~/cosim_diff/`（本地 git，不推送；终点 `f9eb490`），不进入本仓库 |

## 2 与设计的偏差

| 设计 | 实际 | 原因 |
|---|---|---|
| 单 PF 用 `cosim-pcie-pf` | 走路线 R：在 `cosim-pcie-rc` 上打约 80 行本地补丁（多 BAR 64 位注册、MMIO 最大访问 4 B、APIC 区 DMA 写转 BH 投递 MSI-X） | `cosim-pcie-pf` 把配置空间 0x34–0x37、0x40–0xFF 与 0x100 以上留在 QEMU 本地，又把自己的 MSI-X 表放在 BAR0 偏移 0。设备模型的 virtio cap 链、调试 marker cap 和 MSI-X 因此都不可见，virtio_pci 无法绑定。`cosim-pcie-rc` 转发全部配置空间。（裁决：E1 路线 R） |
| 标准模式 S1/S4 用 `modprobe`/`rmmod` | sysfs `bind`/`unbind` | guest 内核内建 virtio、virtio_pci、virtio_net，无法卸载。启动期的绑定事件落在段 0，不参与对比 |
| guest 默认网络栈 | 启动参数 `ipv6.disable=1` | 避免 IPv6 DAD/RS 报文混进场景收发，影响逐帧对比 |
| S3 第二对队列的流量 | `ethtool -L combined 2` 后设置 XPS：tx-0 设为 0，tx-1 设为 CPU 掩码 1 | guest 只有 1 个 CPU，不固定的话发送会全部落在第 1 对。F1 轨迹确认 S3 的流量在 TX q3/RX q2 |
| dpu_snd1 在 53 上编译，或回退到 Debian guest 内编译 | 在本机 Ubuntu 24.04（gcc 13.3）用 apt download 的 6.8.0-107 头文件编译 | 53 是 gcc 9 / glibc 2.31，跑不了 noble 的 fixdep/modpost，内核配置也要求 gcc ≥ 12。Debian 镜像既无工具链也无头文件 |
| 只有 strict/order 两类比较 | 增加 review（寄存器写多重集合、notify/irq 集合、描述符与完成）与 info（读访问，只记录），并引入白名单（每条必须带理由，未使用的条目要报告） | 两种驱动的寄存器访问不可能逐条相同，需要逐条判定，又不能让差异静默通过 |
| 私有模式对比使用规则文件的原文 | 第 3 条偏序的后项收紧为 `mb_af_host_id=0x8`（PRIV-02） | S4 rmmod 时写 0 会造成误报；驱动 probe 写入的值是 `(v&7)\|8` |
| 私有对比测试沿用父类示例的环大小 | `drv_cfg.queue_size=512`（PRIV-03） | 父类示例 `virtio_system_env_example_test.sv:704/719–722` 为 VF 注册了 `default_queue_size=256` 的显式 service 配置，按 `virtio_net_env_config.sv:366–373` 的优先级它覆盖私有 `default_queue_size`（512）；对比测试改为与驱动 `DPU_DEFAULT_*_DESC_NUM` 相同的 512，使 queue_cfg 能做 strict 比较 |
| 私有设备的 GREG 规格寄存器 | `vport_port_num=136`，其余读 0（E3 `bf69294`，M-13） | 驱动与 reg plan 都没有给出值，读 0 时 probe 会失败。136 取自驱动 `res_record` 的容量 |
| 私有 Linux 的发送 offload | `ethtool -K tso off gso off` | 设备模型按 R4 原样回环，丢弃大于 16383 B 的 GSO 帧 |

## 3 结论

| 模式 | 场景 | 结果 | 差异数（VIP 有误 / 模型有误 / 两者合规） | 涉及 ID |
|---|---|---|---|---|
| std | S1 初始化与 feature 协商 | PASS | 3 / 0 / 5 | VIP：STD-02、14、19；合规：STD-01、03、04、05、08；工具：STD-06、07 |
| std | S2 单队列收发 | PASS | 1 / 1 / 5 | VIP：STD-15；模型：STD-18；合规：STD-05、08、09、10、20 |
| std | S3 多队列与 ctrl VQ | PASS | 3 / 1 / 6 | VIP：STD-11、14、15；模型：STD-18；合规：STD-03、05、08、09、10、20 |
| std | S4 关闭与复位 | PASS | 0 / 0 / 4 | 合规：STD-08、12、13、21 |
| priv | S1 初始化 | PASS | 0 / 1 / 5 | 模型：PRIV-01；合规：PRIV-04、06、07、09、10；测试件：PRIV-03 |
| priv | S2 单队列收发 | PASS | 0 / 0 / 2 | 合规：PRIV-07、08 |
| priv | S4 关闭与复位 | PASS | 1 / 1 / 5 | VIP：PRIV-05；模型：PRIV-01；合规：PRIV-04、07、09、10、11；规则：PRIV-02 |

最终对比输出：
- `VDEV_DIFF PASS mode=std`：S1–S4 的 strict/order/review 都是 0，info 行数为 54/3/3/16，白名单 20 条全部用到。
- `VDEV_DIFF PASS mode=priv`：S1/S2/S4 的 strict/order/review 都是 0，info 行数为 86/3/558，白名单 17 条全部用到。

2026-10-08 在最终提交 `aee1c5f` 上从 build 开始复跑，build、std Linux、std VIP、std diff、priv Linux、priv VIP、priv diff 与 `vdev_diff.py selftest` 全部返回 0；CAPS 为 `100420020`。std/priv 差分报告 SHA256 分别为 `67138346cad1a8313debe7d6566e39c7f2cbc6aaff91eac2ab0854a567a7734e`、`b43f7b74b38609e91a4123fd3e82a31652c23c684703415932b1ec529fb22aa8`，selftest 输出 `vdev_diff selftest PASS`。归档同步的 175 个文件逐项一致，manifest SHA256 为 `66888b39914c46bbae7587bbf6f3dff3fdca97ba6d8ef72145c3afa33f8407a6`。

两类 Linux/VIP 的四次运行中，UVM WARNING/ERROR/FATAL 都是 0/0/0。数据面方面，两种模式的 strict.pkt（方向、队列、长度、sha1）与完成长度都逐帧一致；std 共 2×16 帧，priv 共 16 帧。

## 4 差异明细

判定栏的含义：VIP=VIP 有误；模型=设备模型有误；合规=两者合规（加白名单）；工具=vdev_diff.py 缺陷；规则/测试件=对比规则或对比测试的配置。完整 triage 见 53 `~/cosim_diff/triage_std.md` 与 `triage_priv.md`。

### 4.1 标准模式（F2）

| ID | 场景 | 规则 | Linux 行为 | VIP 行为 | 判定 | 处理（提交 / 白名单理由） | 新增回归测试 |
|---|---|---|---|---|---|---|---|
| STD-01 | S1 | strict.status | 首个迁移为 `(1,0)`（段 0 解绑时 `virtio_dev_remove` 重新 ACK） | `(0,0)`（新设备） | 合规 | 白名单：两侧都先复位（§3.1.1），之后的迁移相同 | — |
| STD-02 | S1 | strict.queue_cfg | 队列使能时已带最终向量 1..4 | 以向量 0 使能，DRIVER_OK 前才改绑 | VIP | `63d001f`：full_init 先做 MSI-X 再建队（§4.1.4.3.2） | `virtio_ctrl_vq_test::test_full_init_binds_msix_before_enable` |
| STD-03 | S1、S3 | strict.queue_cfg、review.irq | ctrl VQ 用 NO_VECTOR | ctrl VQ 用独立向量 5 | 合规 | 白名单：§4.1.5.1.2 允许映射到任一有效向量或 NO_VECTOR | — |
| STD-04 | S1 | strict.ctrl | probe 时发冗余的 VQ_PAIRS_SET 1 | 不发 | 合规 | 白名单：MQ 缺省关闭（§5.1.6.5.5） | — |
| STD-05 | S1–S3 | review.notify | open 时为全部队列对投放 RX | 收发前投放 | 合规 | 白名单：投放时机不是规范约束 | — |
| STD-06 | S1 | review.reg_wr | 段 0 的 ring 地址占用了符号 #1 | — | 工具 | `vdev_diff.py` 段 0 单独编号（selftest 9） | 临时工具自测 |
| STD-07 | S1/S3/S4 | review.reg_wr | queue_size/enable/msix_vector 被重复报告 | — | 工具 | review 忽略建队过程中的这些写，`queue_msix_vector` 只在使能前忽略（selftest 10、11） | 临时工具自测 |
| STD-08 | S1–S4 | review.reg_wr | MSI-X 表项的地址/数据由平台决定 | VIP 自选 | 合规 | 白名单（只含 dw0–dw2） | — |
| STD-09 | S2、S3 | review.desc_chain | TX 用单描述符 140 B | 12 B + 128 B 两段 | 合规 | 白名单：§2.7.4 规定任意布局都可 | — |
| STD-10 | S2、S3 | review.desc_chain | RX 1530 B | RX 1526 B | 合规 | 白名单：§5.1.6.3.1 要求 ≥1526 B | — |
| STD-11 | S3 | review.reg_wr | — | configure_mq 整体重建 MSI-X，改写在用映射 | VIP | `ef5280f`：扩容的新队列在使能前写入自己的向量，在用队列不动 | `virtio_ctrl_vq_test::test_mq_expansion_binds_new_queue_vectors` |
| STD-12 | S4 | review.reg_wr | 复位后显式写 NO_VECTOR | 依赖复位解除映射 | 合规 | 白名单：§4.1.5.1.2.1 | — |
| STD-13 | S4 | strict.status | 复位后多出 `(0,1)` | — | 合规 | 白名单：Linux 核心约定，规范不要求 | — |
| STD-14 | S1、S3 | info.access | 映射后回读 vector | 不回读 | VIP | `3b32505`：§4.1.5.1.2.2 规定 MUST 回读核对 | `virtio_vdev_unit_test::test_vip_msix_mapping_readback` |
| STD-15 | S2、S3 | VIP UVM_ERROR | — | SVA 按 notify 计完成信用，批量 RX 时误报 | VIP | `678c4b2`：改为按可用 buffer 计（§2.7.13） | `virtio_protocol_test` 正反例；`virtio_monitor_test` |
| STD-16 | S2、S3 | VIP UVM_ERROR | — | pcie_tl scoreboard 在 GPA 复用时误报 | 测试平台检查器 | 只在临时对比测试中关闭 data integrity（裁决 F2-c3）；pcie_work 与回归不变 | — |
| STD-17 | S1 | — | 批量建队 | 每个队列单独配置并使能 | 无差异 | 偏序规则两侧都满足 | — |
| STD-18 | S2、S3 | VIP UVM_ERROR | — | `vdev_uvm_ep_port` 的 MSI-X 先于同一时刻的 notify/DMA 被观察到 | 模型（端口） | `52a5a14`：MSI-X 延后 2 ns 发布；fixture 复位前排空 SVA | `virtio_real_driver_{rx,flow,multiqueue}_test` |
| STD-19 | S1 | review.reg_wr | 先屏蔽，再写地址/数据，最后解屏蔽 | 先写地址/数据，再屏蔽 | VIP | `811219e`：先屏蔽（PCIe 规定未屏蔽时改写的结果未定义） | `virtio_vdev_unit_test::test_vip_msix_masks_before_programming` |
| STD-20 | S2、S3 | review.reg_wr | 中断亲和性调整时屏蔽、解屏蔽 | — | 合规 | 白名单：属 OS 行为 | — |
| STD-21 | S4 | review.reg_wr | free_irq/pci_disable_msix 两次屏蔽 | 只复位 | 合规 | 白名单：复位解除全部映射 | — |
| 修复轮 2 | — | — | — | 迁移恢复先恢复队列，使能后再改写向量 | VIP | `e00d9a9`（与 STD-02 同类） | `virtio_ctrl_vq_test` 迁移子测试断言使能后没有改写 |
| 修复轮 2 | — | — | — | 设备拒绝映射后，notify_mgr 仍绑定被拒的向量 | VIP | `7561d1a`：记为 NO_VECTOR | `test_vip_msix_mapping_readback` 扩展 |

### 4.2 私有模式（F3）

| ID | 场景 | 规则 | Linux 行为 | VIP 行为 | 判定 | 处理（提交 / 白名单理由） | 新增回归测试 |
|---|---|---|---|---|---|---|---|
| PRIV-01 | S1、S4 | 字段名 | 0x0C0000–0x4BFFFF 的寄存器都被记为 `msix_linear.N`，例如 0x4AA000 vport fwd 记为 `msix_linear.950272` | 同 | 模型 | `5e433e0`：`msix_linear` 只覆盖线性表（0xC0000–0x140000，register.h:37–38）和本设备 srcid 的 128 项解码窗口，其余保留原始偏移名 | `virtio_vdev_unit_test::test_priv_event_field_names` |
| PRIV-02 | S4 | order | rmmod 写 INTF_MB_AF_HOST_ID=0，段内没有 AF 声明 | — | 规则 | 第 3 条偏序的后项收紧为 `mb_af_host_id=0x8`（main.c:2052 `(v&7)\|8`） | — |
| PRIV-03 | S1 | strict.queue_cfg | 环大小 512（hw.h:28–29） | 256：父类示例为 VF 注册了 `default_queue_size=256` 的显式 service 配置（example_test.sv:704/719–722），按 env_config.sv:366–373 有意优先于私有 `default_queue_size=512`（无 service 配置时才用后者） | 测试件 | 不是 VIP 缺陷。对比测试设为 512，之后 q0/q1 strict 相等 | — |
| PRIV-04 | S1、S4 | strict.queue_cfg、review.reg_wr | 多出 AF 特殊队列：forward capture gq1（lqid 2/3、gv1）与 BPDU capture gq2（lqid 4/5、gv2），包括配置、中断 info 与停用 | 只建数据队列对 gq0 | 合规 | 白名单 4 条：main.c:2247/2255 激活，txrx.c:3852–3866/4082 建队，`dpu_remove` main.c:2520–2521 停用。这两个是 AF 管理队列，不属于 Function 的数据队列；正则按值限定为 gq1/gq2 | — |
| PRIV-05 | S4 | review.reg_wr | 停 RX 时间接读 VRX 参数 4 个 DW（i=0..3） | 读 3 个 DW | VIP | `ce48d92`：`sizeof(struct vrx_queue_para_table_entry)` 因 u64 对齐为 16 B（af_mng.c:1564），改为读 4 DW、写回 3 DW；同步更正模型文件头 #33。D4 修复轮按 12 B 推算有误 | `virtio_vdev_unit_test::test_priv_backend_sequence`（期望 4 DW） |
| PRIV-06 | S1 | review.notify | open 时补充 RX：q0 投放 511 个，特殊队列 q2/q4 同样预填 | full_init 不补充，在 S2 补充 | 合规 | 白名单：补充时机不影响语义（同 STD-05） | — |
| PRIV-07 | S1/S2/S4 | review.irq、review.reg_wr | 用 MSI-X 向量 0；写 0x1004 解除自屏蔽（#32）；建立并释放 MSI-X 表（#18） | 私有数据面轮询，MSI-X Enable 不置位；只写中断 info/ctrl（#27，两侧一致） | 合规 | 白名单 3 条 | — |
| PRIV-08 | S2 | review.desc_chain | RX 描述符 1664 B（D-6） | 2048 B（`rx_buf_size`） | 合规 | 白名单：两者都大于帧长，pkt 一致 | — |
| PRIV-09 | S1、S4 | review.reg_wr | 芯片初始化与转发表（PP、DSCH/QSCH、ETH 软复位、DPRX、外设；#9/#22/#23/#26/#30） | 刻意不做 | 合规 | 白名单 3 条（按地址块） | — |
| PRIV-10 | S1、S4 | review.reg_wr | mailbox 环、mailbox 中断 gv12 与 MBL 映射、MAC 老化 msgq gv13；guest 打印 VLAN slot 提示与 type 131 超时 | 不建 mailbox（AF 路径） | 合规 | 白名单 3 条：#11–15、#19，M-8/M-13 | — |
| PRIV-11 | S4 | review.reg_wr | rmmod 拆除：qid map 无效重写到 bank1、清线性表/BDF 映射/MB_AF_HOST_ID/AF 声明（#34–38） | S4 对应 `ip link down`，没有模块卸载 | 合规 | 白名单 | — |
| PRIV-12 | S1 | — | 批量建队 | 每个队列对依次 RX → 中断 → TX → 使能 | 无差异 | 只有一个数据队列对，review 按多重集合比较，不对建队顺序设偏序规则 | — |
| PRIV-13 | — | — | local_qid_base≠0 时的 qid map/gq/gv 编号差异（M-2/M-9） | — | 不适用 | 对比用 Host 0（base 0） | — |
| PRIV-14 | — | — | — | STD-16 的 scoreboard 关闭函数在私有环境中关闭了 0 个（回环端口不经 pcie_tl） | 测试件 | 保留调用 | — |
| PRIV-15 | — | — | qid map 整组符号化后，每项各自编号 | — | 工具限制 | 看不出 12 个有效项与 1 个有效项的值差异；路由正确性由 strict.pkt/complete 兜底（见 §7） | — |

私有白名单用变异检查验证过：从 VIP 轨迹中分别删去 gq0 的 TX 使能写、TX 环地址写、`msix_info.0`、RX 第 4 个 DW 读、`bar2.bdf` 写，每一种都会产生未豁免的 FAIL。这说明白名单没有遮住 gq0 数据队列的缺失。

### 4.3 对比之前的阶段（D3–E3）中由独立设备模型或 cosim 暴露的修复

| 阶段 | 提交 | 归属 | 内容 |
|---|---|---|---|
| D3 | `35b43f7` | VIP | `set_msix` 打开设备的 MSI-X Enable，并把屏蔽位写回设备表项 |
| D3 | `d97fa36` | VIP | Fabric 发现在编程 BAR 后置 Command 的 MSE/BME |
| D3 | `249b0c5` | VIP | packed 环的间接表按 `pvirtq_desc` 布局写入（virtio 1.1 §2.8.19） |
| D3 | `bc24260` | VIP | 未协商 MQ 时 control VQ 固定为队列 2（§5.1.2） |
| D3 | `1e22258`、`2c03af8` | VIP 测试平台 | 读 Completion 越过 posted 写；completion 认领丢失唤醒 |
| D3 | `e3dce2d`、`72ae024`、`8ed098a`、`f0ce4d1`、`0cd13d1` | VIP | 复位释放后才开始初始化；多队列流程先发 VQ_PAIRS_SET；MSI-X MsgCtl/VecCtl 改为读改写；clear_msix 只清 Enable；BAR 租约列表清空 |
| D4 | `a8a3b9e`、`f1d38c8`、`c00631f` | 模型 | 私有设备自屏蔽期间挂起中断并在解除时补发；按驱动修正命名与位宽；挂起状态作废的条件 |
| D5 | `93844cf`、`9914465` | VIP | 私有后端停用未配置的队列时不访问设备；中断 info 在全部队列停完后按向量升序清除（`dpu_down` 顺序） |
| E2 | `6578c53` | 模型 | 标准设备对超出活动队列对的 RX 通知不再告警（§5.1.6.5.5 只约束设备一侧） |
| E3 | `bf69294` | 模型 | 报告 GREG vport 规格 136，私有驱动 probe 才能分配全局 Function（M-13） |
| F2 | `3b32505` `63d001f` `678c4b2` `ef5280f` `52a5a14` `e00d9a9` `7561d1a` `811219e`（另有重构 `1c8ff9e`、`08b4fac`） | VIP/模型 | 见 §4.1 |
| F3 | `5e433e0` `ce48d92` | 模型/VIP | 见 §4.2 |
| 优化复审 | `bf57262` `aee1c5f` | VIP | 补全运行期 MQ、control VQ、批量回滚和私有 reset 恢复闭环；最终 cosim 发现并修正 Host 预建队列对数与设备已确认 MQ 状态混用，标准 S3 恢复逐帧一致 |

## 5 私有驱动与 reg plan 疑点清单

依据：驱动 icpu-kernel-driver f2c9cd6（53 `/home/ubuntu/wn/icpu-kernel-driver`，只读）；reg plan 指 dpu_common `4d73996` 的 `dpu_device_bootstrap_plan_builder.sv` 与 `dpu_vio_dataplane_plan_extension.sv`。凡不一致或语义不明，模型和 VIP 都按驱动实现。全文见 `vdev_dpu_priv.sv` 文件头。

| 寄存器/流程 | 驱动源码位置 | reg plan 定义 | 不一致或不明之处 | 模型采用的语义 |
|---|---|---|---|---|
| VTX ram_cfg（D-1） | `vtx_ram_cfg_reg` | selector 在 bit13、wr_enable 在 bit14，写 `q\|0x2000` 后写 `q\|0x6000` | 驱动是 selector@12、wr_enable@13 | 按驱动：先写 `q`，再写 `q\|0x2000` |
| 步骤缺失或多出（D-2） | main.c:1914/2124；af_mng.c:1406–1419/1310/1598；interrupt.c:386–389 | 缺软复位、第二次读 0x1010、VRX tail 检查、TX 读回、TX 先清 en、self_mask=1 与 0x48000+0xC；多出 0x60040 读回与 0x52000 写 | — | 按驱动序列 |
| qid map 写法（D-3） | af_mng.c:872–899 | 2×64 位写 | 驱动是 4×32 位写加读回，重写全部 128 项 | 按驱动 |
| srcid=`host<<10` 溢出（D-4） | interrupt.c:52 | 复制了同样的溢出 | host≥1 时线性表落到 0x140000 之后 | 按同一公式解码；PRIV-01 使命名只覆盖这个窗口 |
| G2P 截断（D-5） | — | 同样截断 | `src_port` 只有 1 位 | 按驱动 |
| RX buf_len（D-6） | txrx.c | 2048 | 描述符 len 约 1664（内核 ≥5.12） | 按描述符 len 填充（PRIV-08） |
| RSS srcid、host_id（D-7） | af_mng.c:1697 | — | AF 路径 RSS 不带 pfvf；控制用 ecpu_host_id，复位用 host_id | 存储 |
| `dpu_reset_rx_queue` 恒返回 0（D-8） | txrx.c:543–550 | — | — | — |
| TX 首描述符 len 被覆盖（D-9） | txrx.c | — | `skb->len` 后被 headlen 覆盖 | 按描述符 |
| ST 判断恒真（D-10） | — | — | `>=MIN \|\| <=MAX` | — |
| 无 SR-IOV 能力时的配置读（D-11） | sriov.c | — | pos=0 时读标准头 | 原样应答 |
| VRX 停队读回 DW 数（F3 新增，PRIV-05） | af_mng.c:1564 | reg plan 没有停队读回序列 | 结构按 u64 对齐为 16 B，读 4 DW 写回 3 DW；D4 修复轮误作 3 DW | 模型 i=0..3 照常应答；VIP 读 4 DW |
| 模型推断 M-1..M-13 | 见文件头 | — | 软复位语义、doorbell→gq 路由、VRX tail 值、CQ 中断与自屏蔽挂起、TX CQ head、QSCH 位、RX 多描述符、mailbox 未建模、gq/gv 分配、host 位不比、全局屏蔽复位值、virtio_mode、GREG 规格 136 | 见文件头 |
| AF 特殊队列（F3 观察，PRIV-04） | txrx.c:3852–3866/4082、main.c:2247/2255、`dpu_remove` main.c:2520–2521 | reg plan 没有 | forward/BPDU capture 两个 AF 管理队列占用 gq1/gq2、gv1/gv2 | 模型按普通队列处理；VIP 不建 |

### 私有偏序规则的驱动源码依据（`rules_priv.json`）

| 先 | 后 | 驱动源码 | D4 表 |
|---|---|---|---|
| `reg_rd:bar2.host_id` | `reg_wr:bar0.soft_reset` | main.c:2020（读 BAR2 qinfo host_id）→ main.c:1914（`af_soft_reset_fe`） | #2 → #3 |
| `reg_wr:bar0.soft_reset` | `reg_wr:bar0.af_declaration` | main.c:1914 → main.c:2035（写 0x5555AAAA） | #3 → #5 |
| `reg_wr:bar0.af_declaration=0x5555aaaa` | `reg_wr:bar0.mb_af_host_id=0x8` | main.c:2035 → main.c:2052（`INTF_MB_AF_HOST_ID=(v&7)\|8`） | #5 → #7 |
| `reg_wr:bar0.mb_af_host_id` | `reg_wr:bar2.bdf` | main.c:2052 → mailbox.c:441（`dpu_mailbox_cfg_bdf`） | #7 → #10 |

驱动中看不出顺序要求的步骤，例如建队批量顺序（PRIV-12），没有写进规则。

## 6 回归

- **起点：** 40 个测试。
- **新增测试类：** 1 个，`virtio_vdev_unit_test`（D1，设备模型单元测试）。
- **在已有测试中新增的子测试**（不改变 N），按引入任务列出：
  - D2/D3：`virtio_vdev_unit_test` 的设备用例（split/packed、INDIRECT、ctrl 与 MQ、EVENT_IDX、故障复位、MSI-X 使能等）。
  - F2：`test_vip_msix_mapping_readback`、`test_vip_msix_masks_before_programming`；`virtio_ctrl_vq_test::test_full_init_binds_msix_before_enable`、`test_mq_expansion_binds_new_queue_vectors`，以及迁移子测试中的“使能后不改写”断言；`virtio_protocol_test` 的按 buffer 计信用正反例。
  - F3：`test_priv_event_field_names`；`test_priv_backend_sequence` 与 `test_priv_driver_sequence` 中 VRX 读回改为 4 DW。
  - 优化复审（`bf57262`、`aee1c5f`）：`virtio_ctrl_vq_test` 覆盖 control VQ 显式身份、命令超时后的全局恢复闸门、重建失败、运行期 MQ worker 更换、同值请求、设备拒绝、歧义超时 Function reset、扩容回滚、半个队列对缩容后的 reset 成功与失败，以及 Host 预建多队列与设备已确认 MQ 状态的区分；后者还覆盖同值首次提交、迁移恢复重新提交、迁移拒绝回滚、`DEVICE_NEEDS_RESET` 自动恢复成功与拒绝。`virtio_unit_test` 覆盖批量建队回滚、停队未确认后的 Function reset、reset 失败双门禁和重复 qid 零副作用；`virtio_vdev_unit_test` 覆盖私有队列深度边界，以及 Function reset 跨重试保存并最终清理 RX MSI-X info 所有权。
- **最终结果（2026-10-08，`aee1c5f`）：** `STRICT_REGRESSION PASS tests=41`，41/41 PASS、0 FAIL，没有非 PASS 的 STRICT_RESULT；compile-only、strict compile、独立 `virtio_ctrl_vq_test`、独立 `virtio_migration_dirty_test` 和全部 41 项测试的 UVM WARNING/ERROR/FATAL 均为 0/0/0。总日志为 53 `~/virtio_priv_run/virtio_work/logs/mq_recovery_validation/20261008T183346+0800/strict_regression.out`，SHA256 为 `ceffb323623741d29d6c71367269fbd78d94368658c5e5808a91ec652aca3abd`；41 项测试日志集合 SHA256 为 `a299f4f91eb637c7aa3926c33a8fe30f422977c1da80777b044da77e0f3bd84b`。
- **对比临时测试**（`vdev_diff_std_test`、`vdev_diff_priv_test`）只放在 53 `~/cosim_diff`，不进入 manifest，也不进入本仓库。

## 7 已知限制

- **临时环境：** cosim 环境只在 53 `~/cosim_diff`（本地 git），不随本仓库交付；`cosim-platform` 带本地补丁，未回提。
- **只覆盖 AF 路径：** 私有设备报告 `pfvf_id=0`，驱动走 AF 路径直接写芯片表。PF/VF 经 mailbox 请求 AF 的路径没有建模，也没有对比（M-8）。
- **mailbox 未建模：** 环寄存器只存储，不处理消息。type 131 消息因此超时，被驱动容忍（PRIV-10）。
- **TSO 关闭：** 私有 Linux 运行前执行 `ethtool -K tso off gso off`，因为模型原样回环，大于 16383 B 的帧会被丢弃。
- **没有检查 IOVA 是否落在已映射范围：** `vdev_diff.py` 只检查对齐，规范要求的“落在已映射范围内”没有实现，因为 Linux 轨迹不带映射信息。越界 DMA 会表现为设备 UVM_ERROR，使 `run_cosim.sh` 失败。
- **配置空间写只记 info：** marker 1 之后的配置空间读写只进入 info.access，不参与判定（plan 规定）。
- **私有 qid map 符号化（PRIV-15）：** 表项值差异在 review 中不可见，由 strict.pkt/complete 兜底。
- **私有中断路径未在 VIP 侧覆盖：** VIP 私有数据面轮询，CQ 中断、自屏蔽与 0x1004 补发只由 Linux 一侧和 `test_priv_driver_sequence` 覆盖。
- **单 CPU guest：** 标准模式靠 XPS 才让 S3 走第 2 对；私有模式只有 1 个数据队列对，多队列对的建队顺序（PRIV-12）没有在对比中实际出现。运行期多队列重配、停止、reset、迁移恢复和自动恢复顺序由 `bf57262`、`aee1c5f` 的聚焦单元测试覆盖。

## 8 裁决与遗留（progress.md）

### 主要裁决

| 裁决 | 内容 | 代价 |
|---|---|---|
| bind_ops 签名 | 按 B2，后端经 bind_ops 传入（4 参数） | C3 调用点 |
| cosim 路线 R | `cosim-pcie-rc` 加本地补丁，替代 `cosim-pcie-pf` | 仅临时环境 |
| guest 与驱动装卸 | 6.8 内核 + Alpine 用户态，标准模式用 sysfs bind/unbind | S1/S4 语义差异，已加白名单 |
| dpu_snd1 编译 | 在本机编译 | 无 |
| 标准设备 notify | 放在 BAR2（规范 c0661db 已更新） | cosim 暴露 BAR0/2/4 |
| D 任务顺序 | D4 私有设备先于 D5 后端 | 无 |
| 预检 S5–S30 | 全部按建议执行，例如 F2 VIP 测试用 `full_init + configure_mq(2)`，私有模式不做 status 偏序 | — |
| D1 | 修复 MSI-X 回放重复，设备遵守 Command BME/MSE | D3 暴露 VIP 缺陷（预期内） |
| D2 | 未协商 MQ 时 ctrl VQ=2N；packed 间接表布局作为 VIP 缺陷由 D3 修复 | — |
| D3 | 竞态从根上修复，保留 2 ns | — |
| D4 | 加挂起锁存（驱动 NAPI 不会重新轮询） | 可能多发一次 IRQ |
| E2 | 标准设备对超出 curr_pairs 的 RX notify 不告警，TX 仍告警 | — |
| E3/F1 | guest 脚本与 vdev_diff.py 由 F 阶段的实际对比验收 | — |
| F2-c1 | configure_mq 扩容的新队列在使能前写最终向量，不改写在用队列 | — |
| F2-c2 | SVA 信用按可用 buffer 计 | 检查器语义改变（按规范更正） |
| F2-c3 | 只在临时对比测试中关闭 pcie_tl data integrity | 对比运行失去 scoreboard 数据检查，由事件对比覆盖 |
| F2 修复轮 2 | 迁移恢复与 STD-02 同类，立即修复 | 小 |
| C1 命名（用户要求） | 私有队列类命名为 `custom_virtqueue`（`src/virtqueue/custom_virtqueue.sv` 原地重写），保留枚举 `VQ_CUSTOM`；plan C2 起与规范同步更新 | 名字不如 dpu_priv_* 具体 |
| C1 提交范围 | C1 提交同时加入 `virtio_unit_test.sv`、`virtio_dut_caps_test.sv`、`dpu_priv_ring/README.md` | 无 |
| A3/A4 → B1 | 删除 dataplane `configure()` 的 `device_host_id=0` 缺省（规范 R3.4“不静默落到 host0”），4 处 indirect_desc_test 调用显式传 host，作为 B1 的额外提交 | 多一个小提交 |
| C3 | 私有 Function RUNNING 时 full_init 的保护恢复（verified-reset 协议），加单元断言 | — |
| D1 → D3 | VIP/fixture 必须写配置 0x004=0x6（MSE\|BME），否则设备忽略 MMIO/DMA/MSI-X | — |
| D2 | 未用的 `std_log.select` 结果改为断言 | 无 |
| D3 | INTx 回退后 `set_msix` 不再写 MSI-X Enable | 无 |
| E1 | 临时基础设施无法在 E2 前运行验证，rc 补丁随 E2 冒烟一并审查 | 补丁缺陷晚一个任务发现 |
| 流程 | 实现者工作期间控制者不提交，提交时使用 `git commit -- <paths>`（C1 时 `91e1dd5` 误带暂存的删除，`fbdc036` 恢复，留下一个不可二分的提交） | — |

### 遗留（parked / deferred minor）

- **A3/A4：** 手动 kick 测试未断言 PRE/POST_NOTIFY 钩子。
- **B1：** auto_fsm 的 config_change 与 admin_cmd 改道未经后端测试；pf_manager:667 的重复空检查。
- **B2：** 注释表述过度；共享的错误前缀；缺少 null 后端拒绝与私有提交后端类型的测试。
- **C1：** custom_virtqueue 的 130 字符长行。
- **C2：** `ring_iova_of` 假定区域不重叠。
- **C3：**
  - 私有 TX 满环改报 UVM_ERROR。
  - 缺少 DMA 记录时不再 fatal。
  - 从未编程的队列在 teardown 时以合成上下文 disable。
  - `queue_programs` 回退重复。
  - 拒绝时双重报错。
  - 标准 bind_ops 只接受 `virtio_common_cfg_backend`。
- **C4：** 手册:427 的位置描述有误；流程文档中的方法数（60 与 61）。
- **D1：**
  - 非连续 BE 被放宽。
  - 零长度 MemRd 的 byte_count；配置 Completion 的 byte_count=0。
  - Type1 配置被认领。
  - 跨 BAR 末端的 MemWr 未检查。
  - MSI-X 向量控制保留位被存储。
  - send_tlp 在流控下可能耗时。
  - 只有寄存器事件有 to_json。
  - 单元测试缺口（BAR2/4 sizing、只读字段）。
- **D2：**
  - 消费阻塞时重新使能（缺代计数）。
  - RX 溢出时 used len 为 0，MRG_RXBUF 只支持单 buffer。
  - packed used flags 缺 WRITE。
  - feature 依赖未检查。
  - event_idx 测试没有 RED，且在初始化后修改 device_features。
- **D3：**
  - BAR 尺寸魔数（plan 规定）。
  - 4 KiB DMA 拆分未覆盖；scoreboard RAM 语义。
  - 未协商 MQ 且无 ctrl 时，多于 1 对不被拒绝。
  - 每向量 RMW 的读开销；domain waiter 没有直接测试。
- **D4：** stop_ring 的共享检查不排除正在停的队列（依赖驱动先写 queue_en=0）；修复 2/3 没有直接单元断言。
- **D5：**
  - 多对建队顺序与驱动不同（F3 判为无差异，PRIV-12）。
  - local_qid_base≠0 时表项不同（PRIV-13）。
  - AF 声明之后 discover 失败，后续报错有误导性：F3 未触及，仍遗留。
  - 单队列在 reset() 之外的 teardown 不清 MSI-X info（与驱动一致）。
- **E3：** insmod 在 probe 失败时仍返回 0，需要等 120 s 才失败（临时脚本）。
- **F2 遗留：**
  - M2：notify 时刻信用（注释）。
  - M3：MSI-X 延迟魔数常量。
  - M7：full_init 中的冗余向量写。
  - F1：IOVA 已映射范围检查缺口。
  - marker 1 之后的配置写只记 info（plan 规定）。
- **F2 复审 2（低）：** STD-19 的测试只检查“先屏蔽后写地址”，未覆盖写数据与解屏蔽的顺序；迁移恢复回滚路径（MSI-X 早已使能时）未经追踪验证。
- **F3：**
  - qid map 整组符号化（PRIV-15），只在文档中记录。
  - 私有对比测试中的 STD-16 scoreboard 关闭调用实际不起作用（PRIV-14，临时代码）。

## 附录 A 复跑说明（53 `~/cosim_diff`）

目录结构：
```
~/cosim_diff/
  cosim-platform/   59 工作树副本 + 本地补丁（git 跟踪）
  qemu/             QEMU 9.2.0 源码与构建（git 忽略）
  images/           vmlinuz、rootfs.orig.ext4、rootfs.ext4（git 忽略）
  sv/               vdev_cosim_pkg.sv、cosim_vdev_top.sv、vdev_diff_pkg.sv、vdev_diff_tests.sv
  guest/            vdev-init、vdev_lib.sh、vdev_smoke.sh、run_scenarios.sh、vdev_pktgen.c、inject.sh（+ dpu_snd1.ko、vdev_pktgen 产物）
  drv/              src/（icpu-kernel-driver f2c9cd6 只读副本）、patches/（空）、SOURCE
  tools/            vdev_diff.py
  build_cosim.sh run_cosim.sh vip_diff.sh
  rules_priv.json whitelist_std.json whitelist_priv.json triage_std.md triage_priv.md
  build/ out/ run/ logs/   （git 忽略）
```

依赖：`/usr/local` 下的 glib 2.66.8（QEMU 需要 ≥2.66），以及 `~/virtio_priv_run/env.sh`（VCS 与 VIP 依赖根目录）。53 上同一时间只跑一个仿真，不要碰 `~/test_cosim`。

命令序列（在本仓库根目录 SYNC 后执行）：
```bash
# SYNC（本机 virtio_sdd 根目录）
sshpass -p ubuntu rsync -a --delete --exclude .git --exclude .superpowers --exclude build --exclude logs \
  --exclude csrc -e "ssh -o StrictHostKeyChecking=no" ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
# 53 上
cd ~/cosim_diff
./build_cosim.sh                                   # BUILD_COSIM OK
WALL_S=3600 ./run_cosim.sh std scen 16             # RUN_COSIM PASS，out/std/scen/linux.jsonl
CAPS=$(python3 -I tools/vdev_diff.py caps out/std/scen/linux.jsonl)
./vip_diff.sh vdev_diff_std_test out/std/scen/vip.jsonl +VDEV_N=16 +VDEV_DRV_FEATURES=$CAPS
python3 -I tools/vdev_diff.py diff out/std/scen/linux.jsonl out/std/scen/vip.jsonl --mode std \
  --whitelist whitelist_std.json --report out/std/scen/diff.md      # VDEV_DIFF PASS mode=std
WALL_S=3600 ./run_cosim.sh priv scen 16
./vip_diff.sh vdev_diff_priv_test out/priv/scen/vip.jsonl +VDEV_N=16
python3 -I tools/vdev_diff.py diff out/priv/scen/linux.jsonl out/priv/scen/vip.jsonl --mode priv \
  --rules rules_priv.json --whitelist whitelist_priv.json --report out/priv/scen/diff.md   # VDEV_DIFF PASS mode=priv
python3 -I tools/vdev_diff.py selftest             # vdev_diff selftest PASS
```

其他维护操作：
- **guest 脚本或产物改动后重新注入镜像：** `./guest/inject.sh images/rootfs.ext4`（先 e2fsck 重放日志，再用 debugfs 写入）。
- **QEMU 插件改动后：** 把 `cosim-platform/qemu-plugin/cosim_pcie_rc.c` 等文件复制到 `qemu/hw/net/`，然后 `ninja -C ~/cosim_diff/qemu/build qemu-system-x86_64`。
- **dpu_snd1.ko 重编：** 在本机 Ubuntu 24.04 上执行 `apt download linux-headers-6.8.0-107 linux-headers-6.8.0-107-generic`，用 `dpkg -x` 解到 `hdr/`，再 `make -C <drv/src 副本> KERNELDIR=hdr/usr/src/linux-headers-6.8.0-107-generic`（`drv/patches/` 为空），把产物复制到 53 的 `guest/dpu_snd1.ko` 并重新注入。

## 附录 B 白名单全文

每条的 `reason` 就是理由；ID 对应 §4。

### B.1 `whitelist_std.json`（20 条）

```json
[
 {
  "id": "STD-01",
  "rule": "strict.status",
  "scenario": 1,
  "key_re": "^#0 linux=\\(1, 0\\) vip=\\(0, 0\\)$",
  "reason": "S1 起始状态不同、语义相同：Linux 段 0 解绑 virtio-pci 时 virtio_dev_remove 重新写 ACKNOWLEDGE（status=1），S1 绑定时 register_virtio_device 先复位再 ACK，故首个迁移为 (1,0)；VIP 面对的设备是新设备（status=0），复位写 0 记为 (0,0)。两侧都按 virtio 1.2 §3.1.1 第 1 步先复位，其后迁移序列逐项相同。"
 },
 {
  "id": "STD-03",
  "rule": "strict.queue_cfg",
  "scenario": 1,
  "key_re": "^only_(linux x1 \\(4, 256, 65535, 1, 'split'\\)|vip x1 \\(4, 256, 5, 1, 'split'\\))$",
  "reason": "ctrl VQ（q4）的向量分配不同：Linux vp_find_vqs_msix 只给有回调的队列分配向量，无回调的 ctrl VQ 写 NO_VECTOR（轮询完成）；VIP 给 ctrl VQ 分配独立向量 5。virtio 1.2 §4.1.5.1.2 允许把任一事件映射到任一有效向量或 NO_VECTOR，两者均合规。数据队列 q0..q3 的向量两侧一致（1..4）。"
 },
 {
  "id": "STD-03",
  "rule": "review.irq",
  "scenario": 3,
  "key_re": "^linux=\\[3, 4\\] vip=\\[3, 4, 5\\]$",
  "reason": "同 STD-03：VIP 的 ctrl VQ 映射到向量 5，VQ_PAIRS_SET 完成时设备发向量 5 的 MSI-X；Linux 的 ctrl VQ 为 NO_VECTOR，不产生中断。virtio 1.2 §4.1.5.1.2 两种映射均合规。"
 },
 {
  "id": "STD-04",
  "rule": "strict.ctrl",
  "scenario": 1,
  "key_re": "^#0 linux=\\(4, 0, \\(1, 0\\), 0\\) vip=-$",
  "reason": "Linux virtnet_probe 在 DRIVER_OK 后无条件发 VQ_PAIRS_SET curr_queue_pairs（单 CPU 为 1）；virtio 1.2 §5.1.6.5.5 规定多队列缺省关闭、复位后设备只用第 1 对，因此 pairs=1 的命令是冗余的，VIP 初始化不发它合规。S3 的 VQ_PAIRS_SET 2 两侧一致。"
 },
 {
  "id": "STD-04",
  "rule": "review.complete",
  "scenario": 1,
  "key_re": "^only_linux x1 \\(4, 1\\)$",
  "reason": "同 STD-04：这是 Linux S1 冗余 VQ_PAIRS_SET 1 命令的 ctrl VQ 完成（1 字节 ack）。"
 },
 {
  "id": "STD-05",
  "rule": "review.notify",
  "scenario": 1,
  "key_re": "^linux=\\[0, 2, 4\\] vip=\\[\\]$",
  "reason": "RX buffer 投放时机不同：Linux 在 S1 ip link up（virtnet_open）为全部队列对填 RX（receiveq1/receiveq2，curr_pairs=1 时向 q2 notify 合法：virtio 1.2 §5.1.6.5.5 只约束设备不得使用未启用对的 receiveq），q4 是 STD-04 的 ctrl 命令；VIP 对比测试在 S2/S3 收发前由 refill_rx 投放。规范 §5.1.5 只把填 RX 列为初始化步骤、无 MUST/SHOULD 时机约束。"
 },
 {
  "id": "STD-05",
  "rule": "review.notify",
  "scenario": 2,
  "key_re": "^linux=\\[1\\] vip=\\[0, 1\\]$",
  "reason": "同 STD-05：VIP 在 S2 发包前投放 receiveq1 buffer 并 notify q0；Linux 已在 S1 投放。"
 },
 {
  "id": "STD-05",
  "rule": "review.notify",
  "scenario": 3,
  "key_re": "^linux=\\[0, 2, 3, 4\\] vip=\\[2, 3, 4\\]$",
  "reason": "同 STD-05：Linux 在 S3 对 receiveq1 补充 RX buffer（消费 S2 的 16 个 buffer 后的 refill，内核内部时机），VIP 只在 S3 投放 receiveq2；补 buffer 的时机由驱动决定，无规范约束。q2/q3/q4 两侧一致。"
 },
 {
  "id": "STD-08",
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_(linux|vip) x\\d+ \\(None, 'msix', 'vec\\d+\\.dw[0-2]', -1, \\d+\\)$",
  "reason": "MSI-X 表项的消息地址/数据（dw0–dw2）由平台中断子系统决定（PCI MSI-X：Linux x86 为 0xFEE00000 + APIC 向量 0x23..，S2 的 Linux 改写是中断亲和性调整；VIP 为合成值），表项个数随 STD-03 的向量分配而不同；不属 virtio 规范约束范围。Vector Control（dw3）不在此条内，逐条另判（STD-19）。"
 },
 {
  "id": "STD-09",
  "rule": "review.desc_chain",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\([13], \\(\\(140, 0\\),\\), \\(\\('csum_offset', 0\\), \\('csum_start', 0\\), \\('flags', 0\\), \\('gso_size', 0\\), \\('gso_type', 0\\), \\('hdr_len', 0\\), \\('num_buffers', 0\\)\\)\\)$",
  "reason": "TX 描述符布局不同：Linux 把 12B virtio-net header 放在帧头部空间、单描述符 140B；VIP 用 header+帧两个描述符（12B NEXT + 128B）。VERSION_1 蕴含任意布局，virtio 1.2 §2.7.4 规定设备不得假设描述符的具体划分，两者均合规；pkt 的 len/sha1 由 strict.pkt 比对且一致。"
 },
 {
  "id": "STD-09",
  "rule": "review.desc_chain",
  "scenario": "*",
  "key_re": "^only_vip x\\d+ \\([13], \\(\\(12, 1\\), \\(128, 0\\)\\), \\(\\('csum_offset', 0\\), \\('csum_start', 0\\), \\('flags', 0\\), \\('gso_size', 0\\), \\('gso_type', 0\\), \\('hdr_len', 0\\), \\('num_buffers', 0\\)\\)\\)$",
  "reason": "同 STD-09（VIP 一侧：header 与帧分两个描述符）。"
 },
 {
  "id": "STD-10",
  "rule": "review.desc_chain",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\([02], \\(\\(1530, 2\\),\\), \\(\\('csum_offset', 0\\), \\('csum_start', 0\\), \\('flags', 0\\), \\('gso_size', 0\\), \\('gso_type', 0\\), \\('hdr_len', 0\\), \\('num_buffers', 1\\)\\)\\)$",
  "reason": "RX buffer 大小不同：未协商 MRG_RXBUF/GUEST_TSO 时 virtio 1.2 §5.1.6.3.1 要求 buffer 至少 1526B（SHOULD）；Linux 用 GOOD_PACKET_LEN(1518，含 VLAN)+12=1530，VIP 用规范下限 1526，两者都满足。"
 },
 {
  "id": "STD-10",
  "rule": "review.desc_chain",
  "scenario": "*",
  "key_re": "^only_vip x\\d+ \\([02], \\(\\(1526, 2\\),\\), \\(\\('csum_offset', 0\\), \\('csum_start', 0\\), \\('flags', 0\\), \\('gso_size', 0\\), \\('gso_type', 0\\), \\('hdr_len', 0\\), \\('num_buffers', 1\\)\\)\\)$",
  "reason": "同 STD-10（VIP 一侧：1526B RX buffer）。"
 },
 {
  "id": "STD-12",
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x1 \\(None, 'common_cfg', 'config_msix_vector', -1, 65535\\)$",
  "reason": "Linux vp_del_vqs 在复位之后显式把 config 向量写成 NO_VECTOR；virtio 1.2 §4.1.5.1.2.1 规定设备复位时解除全部事件映射，VIP 依赖复位，不写冗余的解除映射。"
 },
 {
  "id": "STD-13",
  "rule": "strict.status",
  "scenario": 4,
  "key_re": "^#1 linux=\\(0, 1\\) vip=-$",
  "reason": "Linux 解绑时 virtio_dev_remove 在复位后重新写 ACKNOWLEDGE（“Acknowledge the device's existence again”），这是 Linux virtio 核心对已发现设备的约定，规范不要求；VIP 的 S4 只做复位。复位迁移 (15,0) 两侧一致。"
 },
 {
  "id": "STD-03",
  "rule": "review.reg_wr",
  "scenario": 1,
  "key_re": "^only_vip x1 \\(None, 'msix', 'vec5\\.dw3', -1, 0\\)$",
  "reason": "同 STD-03：VIP 给 ctrl VQ 分配了向量 5，因此会解屏蔽表项 5；Linux 的 ctrl VQ 为 NO_VECTOR，表项 5 保持屏蔽。virtio 1.2 §4.1.5.1.2 两种映射都合规。"
 },
 {
  "id": "STD-12",
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x1 \\(None, 'common_cfg', 'queue_msix_vector', [0-4], 65535\\)$",
  "reason": "Linux vp_del_vqs 在复位之后逐个把队列向量写成 NO_VECTOR（del_vq 解除映射）。这些写发生在队列使能之外，所以 review 照常报告。virtio 1.2 §4.1.5.1.2.1 规定设备复位时解除全部事件映射，VIP 依赖复位，不写冗余的解除映射。"
 },
 {
  "id": "STD-20",
  "rule": "review.reg_wr",
  "scenario": 2,
  "key_re": "^only_linux x1 \\(None, 'msix', 'vec[1-4]\\.dw3', -1, [01]\\)$",
  "reason": "Linux 调整中断亲和性时按 PCIe Base Spec 先屏蔽表项（dw3=1）、改写地址/数据（dw0–dw2，属 STD-08）、再解屏蔽（dw3=0）；VIP 不调整亲和性。这是 OS 中断子系统行为，不属 virtio 规范约束范围。VIP 自己的改写顺序已由 STD-19 修为先屏蔽。"
 },
 {
  "id": "STD-20",
  "rule": "review.reg_wr",
  "scenario": 3,
  "key_re": "^only_linux x1 \\(None, 'msix', 'vec[1-4]\\.dw3', -1, [01]\\)$",
  "reason": "同 STD-20（S3 第二对队列的中断亲和性调整）。"
 },
 {
  "id": "STD-21",
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x2 \\(None, 'msix', 'vec[0-4]\\.dw3', -1, 1\\)$",
  "reason": "Linux 解绑时释放中断：free_irq 关闭中断时屏蔽表项一次，pci_free_irq_vectors（pci_disable_msix）再屏蔽全部表项一次，所以每个向量写两次 dw3=1。VIP 的 S4 只做设备复位：virtio 1.2 §4.1.5.1.2.1 规定复位解除全部事件映射，复位后设备不会再发 MSI-X；MSI-X 表交给下一次初始化，而下一次初始化会先屏蔽再改写（STD-19）。释放 OS 中断资源不属 virtio 规范约束。"
 }
]
```

### B.2 `whitelist_priv.json`（17 条）

```json
[
 {
  "rule": "strict.queue_cfg",
  "scenario": 1,
  "key_re": "^only_linux x1 \\((2|3|4|5), 512, (1|2), 1, 'priv'\\)$",
  "reason": "PRIV-04 AF 特殊队列：驱动 probe 在 AF 上激活 forward capture（gq1，lqid 2/3，gv1）与 BPDU capture（gq2，lqid 4/5，gv2）两个特殊队列（main.c:2247/2255 → dpu_af_activate_special_queue txrx.c:4082，表 txrx.c:3852–3866），rmmod 时停用（dpu_remove main.c:2520–2521）；它们是 AF 管理队列，不属于该 Function 的数据队列对，VIP 私有驱动只建数据队列对（gq0）。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 1,
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '(vtx_ram_cfg', -1, (1|2|8193|8194)|vrx_wr_cfg', -1, (1|2|65537|65538)|vtx_content\\.dw2', -1, (32905|32921|65673|65689)|vrx_content\\.dw2', -1, (524313|1048601)|msix_info\\.(1|2)', -1, 6144|msix_ctrl\\.(1|2)\\.dw3', -1, 0)\\)$",
  "reason": "PRIV-04 AF 特殊队列：驱动 probe 在 AF 上激活 forward capture（gq1，lqid 2/3，gv1）与 BPDU capture（gq2，lqid 4/5，gv2）两个特殊队列（main.c:2247/2255 → dpu_af_activate_special_queue txrx.c:4082，表 txrx.c:3852–3866），rmmod 时停用（dpu_remove main.c:2520–2521）；它们是 AF 管理队列，不属于该 Function 的数据队列对，VIP 私有驱动只建数据队列对（gq0）。 这些是 gq1/gq2 的 VTX/VRX 参数表写（ram_cfg/wr_cfg 低位=gq，DW2 的 dma_msix=gv1/gv2）与 gv1/gv2 中断 info/ctrl（#24/#25/#27/#28）。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 1,
  "key_re": "^only_linux x(1|2) \\(None, 'bar0', '(vtx|vrx)_content\\.dw0', -1, '@(vtx|vrx)_content\\.dw0\\.q-1#[23]'\\)$|^only_linux x4 \\(None, 'bar0', 'vtx_content\\.dw[13]', -1, ('@vtx_content\\.dw1\\.q-1#1'|0)\\)$|^only_linux x2 \\(None, 'bar0', 'vrx_content\\.dw1', -1, '@vrx_content\\.dw1\\.q-1#1'\\)$",
  "reason": "PRIV-04 AF 特殊队列：驱动 probe 在 AF 上激活 forward capture（gq1，lqid 2/3，gv1）与 BPDU capture（gq2，lqid 4/5，gv2）两个特殊队列（main.c:2247/2255 → dpu_af_activate_special_queue txrx.c:4082，表 txrx.c:3852–3866），rmmod 时停用（dpu_remove main.c:2520–2521）；它们是 AF 管理队列，不属于该 Function 的数据队列对，VIP 私有驱动只建数据队列对（gq0）。 环地址按出现顺序符号化：Linux 三个环（gq1、gq2、gq0）占 #1–#3、高 32 位均为 0（同一符号），VIP 只有 gq0 一个环（#1）；VIP 的 #1 与 Linux 先配置的 gq1 配对，多出的 #2/#3 两组、Linux 高 32 位为 0 的多余 dw1 写与 DW3 写都来自特殊队列。若 VIP 漏写 gq0 环地址，会多出未豁免的 #1。"
 },
 {
  "rule": "review.notify",
  "scenario": 1,
  "key_re": "^linux=\\[0, 2, 4\\] vip=\\[\\]$",
  "reason": "PRIV-06 RX 补充时机：Linux open 在 dpu_up_complete→dpu_alloc_all_rx_bufs（adapter_ops.c:315，txrx.c:964 doorbell 0x81FF0000 补 511 个）就填满 RX 环，特殊队列同样预填（txrx.c:4003）；VIP full_init 只建队，S2 由 rx_refill 补 RX（notify q0 出现在 S2，两侧 S2 notify 集合相同）。补充时机不影响设备语义，S2 的 strict.pkt/complete 两侧一致。与 STD-05 同类。"
 },
 {
  "rule": "review.irq",
  "scenario": 2,
  "key_re": "^linux=\\[0\\] vip=\\[\\]$",
  "reason": "PRIV-07 私有数据面轮询：VIP 私有驱动按 polling 收发（dpu_priv_driver_config.sv validate 注释“私有数据路径目前为 polling”），不做内核 MSI-X 建立（D4 表 #18）与 NAPI 重新使能（#32 写 0x1004），PCI MSI-X Enable 不置位，设备的 CQ 中断不投递；VIP 仍按驱动写中断 info/ctrl（#27，msix_info.0 两侧一致）。Linux 用 MSI-X 向量 0。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 2,
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', 'msix_rearm', -1, 0\\)$",
  "reason": "PRIV-07 私有数据面轮询：Linux dpu_napi_poll 完成后写 0x1004=gv<<1 解除 gv0 自屏蔽（interrupt.c:276，D4 表 #32）；VIP 轮询不依赖中断，不写。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'msix', 'vec\\d+\\.dw[0-3]', -1, \\d+\\)$",
  "reason": "PRIV-07 内核 MSI-X 表编程（D4 表 #18）：S1 pci_alloc_irq_vectors/request_irq 屏蔽 64 项后写地址/数据，S2 为中断亲和性重编程的屏蔽/解除（同 STD-20），S4 free_irq 与 pci_disable_msix 屏蔽各项（同 STD-21）。消息地址/数据由平台中断子系统决定；VIP 私有数据面轮询，不建立 MSI-X。"
 },
 {
  "rule": "review.desc_chain",
  "scenario": 2,
  "key_re": "^only_linux x16 \\(0, \\(\\(1664, 8388608\\),\\), None\\)$|^only_vip x16 \\(0, \\(\\(2048, 8388608\\),\\), None\\)$",
  "reason": "PRIV-08 RX buffer 长度由驱动选择：Linux ≥5.12 内核按 1664 B 建 RX buffer（D-6，告诉 AF 的 buf_len 仍为 2048），VIP 私有配置 rx_buf_size=2048。两者都大于 128 B 帧，设备按描述符 len 填充并在 CQ 报 pkt_len；S2 strict.pkt（len/sha1）与 complete 两侧一致。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '0x0(42|44|46|4a|4c)[0-9a-f]{4}', -1, \\d+\\)$",
  "reason": "PRIV-09 AF 芯片初始化与转发表（D4 表 #9、#22、#23、#26、#30）只出现在 Linux：PP 块（register.h:18,71–79）：PARSER 0x420000+ 的 PCMRT 表、IPRO 0x448000 VPORT_IPORT 表、PFLOW 0x460000 RSS hash、EPRO 0x4A0020/0x4A9000 RSS 组表（dpu_configure_rss_group_table adapter_ops.c:195）、0x4AA000 VPORT_EPORT（dpu_configure_vport_fwd af_mng.c:4959，open 置 1、dpu_down 清 0 adapter_ops.c:21/341）、MSE 0x4C01F0。均为报文转发/分类表，与数据队列 DMA 无关；VIP 私有后端刻意不做（D Notes），设备模型只存储。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '0x0(a[8-e]|b[01])[0-9a-f]{4}', -1, \\d+\\)$",
  "reason": "PRIV-09 AF 芯片初始化与转发表（D4 表 #9、#22、#23、#26、#30）只出现在 Linux：DSCH 块：shaping 0xA80000–0xAE0000 与 QSCH 0xB00000/0xB00100 初始化，以及 add_vnet/queue_2_qsch 的 QSCH 映射 0xB10000–0xB13000（main.c:1133/1185，#22），rmmod 时删除。调度器配置与队列 DMA 无关，VIP 私有后端不做；模型的 QSCH 在途状态（0xB22000，M-6）不依赖这些映射。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 1,
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '0x(0c40018|0cc0018|1110000|0164000|0174[0-9a-f]{3})', -1, \\d+\\)$",
  "reason": "PRIV-09 AF 芯片初始化与转发表（D4 表 #9、#22、#23、#26、#30）只出现在 Linux：ETH0/ETH1 软复位 INTF_ETH0_ETH_SOFT_RESET 0xC00018/0xCC0018、DPRX PRMUX 0x1110000（rx pause 门限）、INTF_PERIPHERAL 0x164000/0x174000（外设）。以太口与外设初始化，与 Function 数据队列无关。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'bar2', '(tx_cmd|rx_cmd|tx_base_lo|tx_base_hi|rx_base_lo|rx_base_hi|tx_size_bwid|rx_size_bwid|mb_doorbell)', -1, \\d+\\)$",
  "reason": "PRIV-10 mailbox 与 AF 附加中断未建模（D4 表 #11–15、#19，M-8）：BAR2 mailbox 环 reset/config/tail/enable（mailbox.c:158–372）与 S1/S4 的消息 doorbell（含发往 ECPU 的 type 131 DPU_MAILBOX_CFG_MC_ADDR，adapter_ops.c:119/124，因无 ECPU 应答而超时，guest 打印 \"Mailbox send message type: 131 ... timeout\"，M-13）。VIP 私有后端走 AF 路径，不建 mailbox 环。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '(0x0068[0-9a-f]{3}|msix_info\\.(12|13)|msix_ctrl\\.13\\.dw3)', -1, \\d+\\)$",
  "reason": "PRIV-10 mailbox 与 AF 附加中断未建模（D4 表 #11–15、#19，M-8）：af_enable_mailbox_irq（mailbox.c:708,717）写 gv12 的 info 与 MBL 映射表 0x68000+srcid*16，mailbox.c:430 为本 Host 的 VF srcid 逐项写 MBL 映射（0x68040–0x6813C）；gv13 为 AF 的 MAC 老化消息队列中断（dpu_af_setup_age_msgq_proc_work main.c:1667，MSE_AGE_QUE 0xA0080）。S4 rmmod 清除。VIP 不建 mailbox/消息队列。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": "*",
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '0x(00a00[89a][0-9a-f]|0001008)', -1, \\d+\\)$",
  "reason": "PRIV-10 mailbox 与 AF 附加中断未建模（D4 表 #11–15、#19，M-8）：AF 消息队列 MSE_AGE_QUE_CTRL 0xA0080–0xA00A0（register.h:373，main.c:1667 MAC 老化 msgq）与 INTF BREG 0x1008 的消息队列中断配置；S4 拆除。与数据队列无关。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '(vtx_reset', -1, (1|2|2147483649|2147483650)|vrx_reset', -1, (1|2|2147483649|2147483650)|vtx_stat_clr_cfg', -1, (65537|65538|2147549185|2147549186)|vrx_rd_cfg', -1, (1|2|16385|16386|32769|32770|49153|49154|65537|65538|81921|81922|98305|98306|114689|114690)|vtx_ram_cfg', -1, (1|2|8193|8194)|vrx_wr_cfg', -1, (1|2|65537|65538)|vtx_content\\.dw2', -1, (32905|65673)|vrx_content\\.dw2', -1, (524297|1048585)|msix_info\\.(1|2)', -1, 0)\\)$",
  "reason": "PRIV-04 AF 特殊队列：驱动 probe 在 AF 上激活 forward capture（gq1，lqid 2/3，gv1）与 BPDU capture（gq2，lqid 4/5，gv2）两个特殊队列（main.c:2247/2255 → dpu_af_activate_special_queue txrx.c:4082，表 txrx.c:3852–3866），rmmod 时停用（dpu_remove main.c:2520–2521）；它们是 AF 管理队列，不属于该 Function 的数据队列对，VIP 私有驱动只建数据队列对（gq0）。 S4 rmmod 停用特殊队列：gq1/gq2 的 TX 置 en=0、复位、清统计，RX 读回 4 DW、置 en=0、复位（与 gq0 相同的 #33 序列，低位=gq1/gq2），以及 gv1/gv2 的 info 清零。gq0 的同一序列两侧一致。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x1 \\(None, 'bar0', '(vtx|vrx)_content\\.dw0', -1, '@(vtx|vrx)_content\\.dw0\\.q-1#[23]'\\)$|^only_linux x2 \\(None, 'bar0', '((vtx|vrx)_content\\.dw1', -1, '@(vtx|vrx)_content\\.dw1\\.q-1#1'|(vtx_content\\.dw3|vrx_reset_done)', -1, 0)\\)$",
  "reason": "PRIV-04 AF 特殊队列：驱动 probe 在 AF 上激活 forward capture（gq1，lqid 2/3，gv1）与 BPDU capture（gq2，lqid 4/5，gv2）两个特殊队列（main.c:2247/2255 → dpu_af_activate_special_queue txrx.c:4082，表 txrx.c:3852–3866），rmmod 时停用（dpu_remove main.c:2520–2521）；它们是 AF 管理队列，不属于该 Function 的数据队列对，VIP 私有驱动只建数据队列对（gq0）。 S4 停用 gq1/gq2 时写回参数表的地址字（按出现顺序符号化，三个环占 #1–#3）、DW3 与复位完成位清零。"
 },
 {
  "rule": "review.reg_wr",
  "scenario": 4,
  "key_re": "^only_linux x\\d+ \\(None, 'bar0', '(qid_map\\.b1\\.e\\d+\\.dw[0-3]', -1, '@qid_map\\.b1\\.e\\d+\\.dw[0-3]\\.q-1#1'|qid_map_sel', -1, 2|msix_linear\\.([0-9]|1[0-4])', -1, 0|bdf_map\\.0', -1, '@bdf_map\\.0\\.q-1#2'|mb_af_host_id', -1, 0|pcmpl_af_host_id', -1, 0)\\)$",
  "reason": "PRIV-11 rmmod 拆除（D4 表 #34–38）：VIP 的 S4 对应 ip link down（停数据队列对、清 gv0 info），没有模块卸载的等价步骤；VIP 后端 probe 状态（AF 声明、qid map、线性表、BDF 映射）随设备复位或下一次 probe 重建。 驱动 remove 把 qid map 全部重写为无效项到另一 bank 并切换（fill_qid_map_table af_mng.c:872–899，0x20044=2）、清 0xC0000 线性表 15 项与 0x56000 BDF 映射、INTF_MB_AF_HOST_ID 0x60040=0、AF 声明 0x20040=0。"
 }
]
```
