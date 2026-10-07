# 真实驱动对比验证与私有模式收敛设计

## 目标

用真实 Linux 驱动与 VIP 驱动驱动同一个设备模型，对比设备侧行为，找出并修复 VIP 与真实驱动
不一致之处。标准 virtio-net 与 DPU 私有环两种模式都覆盖。为此先完成四项重构：已知缺陷修复、
私有模式收敛到通用接入点、配置后端成为唯一配置通道、设备与驱动分离。

原则：代码精简，功能完整。不保留兼容旧接口的空壳，不为单一用途引入抽象。

基线：分支 `refactor/arch-simplification` @ `6834ae6`，src 76 个文件 27,441 行，
tests 25,811 行，`strict_regression` 40/40 PASS（53 主机 VCS W-2024.09-SP1，dpu_common `4d73996`）。

## 范围与非目标

- 永久改动：`virtio_net_vip/src`、`virtio_net_vip/tests`、`examples/dpu_priv_ring`、`scripts/`、
  README 与手册相关段落。
- 临时验证环境：仅在 53 主机 `~/cosim_diff/`（本地 git，不推送，不进入 virtio_work）。
  cosim-platform 只是借用，后续不集成。
- 非目标：dpu_common、pcie_work、host_mem、net_packet、queue_work 不修改；cosim-platform 与
  icpu-kernel-driver 的仓库不提交任何改动；不做 spec-2（设备发现绑定与 AF 直配），它在本设计
  完成后基于 R2 进行。

## 执行规则

1. 阶段顺序：R3 → R1+R2 → R4 → cosim 冒烟 → 对比与修复。
2. 前三阶段每个条目独立提交，提交前 `strict_regression` 全部 PASS。
3. 缺陷与行为变更先写失败测试（RED），再修复。
4. 删除附 grep 证据（无剩余引用）。
5. 回归中若出现行为不等价，以测试意图为准修实现，不放宽断言。
6. 提交使用 Conventional Commits，中文描述。

## R3：已知缺陷

| 编号 | 缺陷 | 位置 | 复现测试 |
|---|---|---|---|
| R3.1 | `ctrl_send` 超时后释放设备仍可能持有的 DMA buffer；迟到的完成会被下一次 `ctrl_send` 消费 | `virtio_atomic_ops_ctrl_admin.svh` `ctrl_send`（对照同文件 Admin VQ 的 reset/quarantine 路径） | 设备在超时后才完成第一条命令：第二条命令得到的是自己的 ack；超时命令的 IOVA 不被复用 |
| R3.2 | MQ 扩容（`setup_queue_range`）不重新配置 MSI-X，新队列得到 NO_VECTOR | `virtio_auto_fsm.sv` `do_configure_mq`、`virtio_atomic_ops_lifecycle.svh` `setup_msix` | 1 对扩到 2 对后新队列的 `queue_msix_vector` 为有效向量，且与已有映射一致 |
| R3.3 | 标准协议下 MANUAL `ATOMIC_KICK` 不发 doorbell | `virtio_driver_protocol.sv` `kick` | MANUAL 模式发送 `ATOMIC_KICK`，transport 记录到 notify 写 |
| R3.4 | virtqueue 默认 `host_id=0`，直接创建队列会静默走 host0 DMA | `virtqueue_base.sv` 构造参数 `device_host_id = 0` | 去掉默认值，所有创建点显式传 host；编译期即覆盖 |

修复方式：
- R3.1 复用 Admin VQ 已有的模式：超时后 reset 该队列；reset 失败则把 DMA 隔离（quarantine），
  不释放。ctrl 与 admin 共用同一段实现，不复制。
- R3.2 扩容完成后按实际队列集合调用 `setup_msix`。

## R1：私有模式收敛

现状：私有模式在 ops、fsm、virtqueue 三层各有子类，并绕过已有接入点。
- `dpu_priv_atomic_ops` 覆盖约 25 个 ops 方法。
- `dpu_priv_auto_fsm` 覆盖初始化、MQ、迁移、单队列复位。
- `custom_virtqueue` 与 `dpu_priv_ring_callback` 形成两层间接。

目标：私有模式只通过三处表达差异，ops 与 fsm 只保留一套通用实现。

| 差异点 | 承担内容 |
|---|---|
| `dpu_priv_config_backend` | AF 声明、BAR2 qinfo、队列参数表、MSI-X 映射；features/status 在私有设备上的语义 |
| `dpu_priv_virtqueue`（直接继承 `virtqueue_base`，与 split/packed 平级） | 16B 描述符、CQ、kick 游标、状态保存与恢复 |
| `dpu_priv_driver_protocol` | kick、完成轮询、复位语义；能力声明（是否有 ctrl VQ、是否支持迁移、是否支持 MQ） |

删除：`dpu_priv_atomic_ops`、`dpu_priv_auto_fsm`、`custom_virtqueue`、`dpu_priv_ring_callback`，
以及只为它们存在的通用代码分支（例如 `uses_private_ring()` 判断）。
通用 ops/fsm 中凡按“私有”分支的地方，改为询问 protocol 能力或交给 backend。

验收：
- `dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test` 断言不放宽并通过。
- 同一 Host 下私有 VF 与标准 VF 共存、各自收发、停机回收互不影响。
- src 净减少。

## R2：配置后端成为唯一配置通道

- auto_fsm、migration_engine、atomic ops 队列片段中直接读写 status/配置寄存器的地方，全部改走
  `config_backend`。
- `virtio_function_instance` 在 commit 阶段按冻结快照选择后端（common_cfg 或 dpu_priv），
  与 protocol 一起下发。ops 不再自行默认创建后端。
- 验收：grep 不到 backend 之外的 common_cfg status 访问；`virtio_dut_caps_test`、
  `virtio_unit_test` 覆盖后端选择。

## R4：设备与驱动分离

现状：`virtio_pcie_dut_responder` 订阅 VIP monitor 的 BAR 访问得知寄存器写入，直接读 VIP 的
`transport.driver_features` 与 `vq_mgr`，队列地址缺失时取 VIP virtqueue 的 `desc_table_addr`。
它不是独立设备，VIP 写错寄存器可能不被发现。私有环没有设备侧模型，
`dpu_priv_device_control` 只是测试钩子。

目标：新增独立设备模型，只依据收到的 PCIe 请求维护状态，不引用任何驱动侧对象。
它替换 responder 和 `dpu_priv_device_control`。

```
virtio_net_vip/src/devmodel/
  vdev_port.sv          端口接口：接收 MMIO/配置请求并返回完成；dma_read / dma_write；raise_msix
  vdev_uvm_ep_port.sv   基于 pcie_tl EP driver 的实现（VCS 回归使用）
  vdev_base.sv          配置空间（cap 链）、MSI-X 表、语义事件 analysis_port、回环
  vdev_virtio_pci.sv    标准设备：common_cfg / notify / ISR / device_cfg；split 与 packed 环处理
  vdev_dpu_priv.sv      私有设备：AF 0x1010（magic 0x5555AAAA）/ 0x60040、BAR2 qinfo、
                        队列参数表、16B 描述符 + CQ、MSI-X
```

- 报文：设备把 TX 帧原样回环到同队列对的 RX。
- 错误注入：现有 `virtqueue_error_injector` 的设备侧时序点改由设备模型调用。
- 私有设备的行为依据：真实驱动 icpu-kernel-driver `lance_net_mailbox@f2c9cd6` 的源码，寄存器定义取
  dpu_common reg plan。驱动与 reg plan 不一致或语义不明之处，模型按驱动预期实现，并在模型文件头
  列出疑点。
- 语义事件通过 `analysis_port` 输出，事件集合见“对比方法”。scoreboard/coverage 可订阅，
  不强制使用。

验收：
- 40 个回归测试在新模型下全部通过。
- 新模型暴露的 VIP 问题当场修复，并补测试。
- `virtio_pcie_dut_responder` 删除，grep 无引用。
- 私有环两个测试改为面对 `vdev_dpu_priv`。

## 对比验证（临时环境，位于 53 `~/cosim_diff/`）

### 环境

- QEMU：用 `~/qemu-9.2.0.tar.xz` 编译，打 cosim-platform `qemu-plugin` 补丁。只有 TCG，没有 KVM。
- cosim-platform：本地副本，给 `cosim-pcie-rc` 打本地补丁（多 BAR、4 字节 MMIO、MSI-X）。不用 `cosim-pcie-pf`：它在 QEMU 内部处理 0x40 以上配置空间并自带 MSI-X 表，guest 看不到设备模型的 cap 链。
- 传输：53 本机共享内存。
- VCS 侧 `cosim_vdev_top`：
  - `vdev_cosim_port` 通过 DPI 调用：`bridge_vcs_poll_tlp`、`send_completion`、
    `dma_read/write_sync`、`raise_msi`、`set_pf_topology`、`finalize_topology`。
  - 配置空间由设备模型提供（`+BYPASS_CONFIG`）。
  - 用 `+VDEV=std|priv` 选择模型。
- 设备标识：

  | 设备 | ID | BAR |
  |---|---|---|
  | 标准 | 1af4:1041 | BAR0 common_cfg/ISR/device_cfg，BAR2 notify（VIP fabric 发现要求 notify 位于 mailbox BAR），BAR4 MSI-X |
  | 私有 | 20f9:5013 | BAR0 内存，BAR2 mailbox/qinfo，BAR4 MSI-X |

- Guest：6.8.0-107 内核 + Alpine 用户空间（cosim 的 ubuntu 镜像）。
  - 标准模式用内核内建的 virtio_net；加载/卸载用 sysfs bind/unbind 代替 modprobe/rmmod。
  - 私有模式用 `dpu_snd1.ko`，在本机（Ubuntu 24.04）针对 6.8.0-107 头文件编译；兼容修改以 patch 文件保存在临时目录。
- 场景分段：设备提供一个调试 vendor cap，内含 marker 寄存器。guest 用 `setpci` 写入场景号，
  对应的 `marker` 事件不参与对比。VIP 侧对比测试在同一位置发出同号 marker。

### 场景

| 编号 | 场景 | guest 动作 | 模式 |
|---|---|---|---|
| S1 | 初始化与 feature 协商 | 驱动 bind（私有：insmod）、`ip link up` | 标准、私有 |
| S2 | 单队列收发 | `vdev_pktgen`（静态 C 程序，AF_PACKET）发 N 个固定帧，接收回环帧并校验 | 标准、私有 |
| S3 | 多队列与 ctrl VQ | `ethtool -L combined 2`，在第 2 对上收发 | 仅标准 |
| S4 | 关闭与复位 | `ip link down`、驱动 unbind（私有：rmmod） | 标准、私有 |

VIP 侧有两个临时对比测试（`vdev_diff_std_test` / `vdev_diff_priv_test`），场景、帧集合、marker 与
guest 一致。`driver_caps` 取自 Linux 轨迹的 `drv_accepted`。这两个测试只编进临时 filelist，
不进 manifest。

### 对比方法

由设备侧事件记录器写 JSONL，每条事件一行。

| 事件 | 字段 |
|---|---|
| `reg_wr` / `reg_rd` | fn、region、field、q、val（按字段解码，不记原始地址） |
| `status` | from、to |
| `features` | dev_offered、drv_accepted |
| `queue_cfg` | q、size、vector、enable、ring_fmt（队列 enable 时快照） |
| `notify` | q、next_idx、wrap |
| `desc_chain` | q、segs[len, flags]、hdr（解码后的 net_hdr） |
| `pkt` | dir、q、len、sha1 |
| `complete` | q、id、len |
| `irq` | vector |
| `ctrl` | class、cmd、data、ack |
| `marker` | scenario |

归一化（`vdev_diff.py`）：
- IOVA 替换为符号，只校验对齐和是否落在已映射范围内。
- 不记录时间。
- `irq` 与 `notify` 只比“是否发生”，不比次数。

规则：

| 类别 | 内容 | 不一致时 |
|---|---|---|
| 严格一致 | features、`queue_cfg` 集合、ctrl 命令序列、`pkt` 摘要集合、status 转换序列 | 判失败 |
| 偏序一致 | 队列配置在 FEATURES_OK 之后、DRIVER_OK 之前；enable 在地址写入之后；复位后读到 status 为 0 才重新初始化；私有模式按驱动源码确定的 AF/qinfo 顺序约束 | 判失败 |
| 信息项 | 冗余的寄存器读、额外的配置读取 | 只记录 |

差异处理：每条差异给出以下三种判定之一。
- VIP 有误：修 VIP，并在常规回归中补测试。
- 模型有误：修模型。
- 两者都合规：写入白名单并注明理由。

## 交付

1. VIP 分支：R1–R4 完成，回归全过（40 个加上新补的测试）。
2. 差异报告 `docs/cosim-driver-diff-report.md`，内容：
   - 每个模式、每个场景的结论
   - 每条差异的判定与修复提交
   - 私有驱动与 reg plan 的疑点清单
3. 53 上 `~/cosim_diff/` 的复跑说明（写在报告附录）。

## 风险

| 风险 | 应对 |
|---|---|
| `cosim-pcie-pf` 在单 PF 下未验证过 | cosim 冒烟作为独立阶段：先验证配置空间读写和 `lspci`，再接驱动 |
| `dpu_snd1.ko` 在 6.8 内核上编译失败 | 在本机用 6.8.0-107 头文件编译，patch 兼容问题 |
| 私有设备行为在驱动源码中不明确 | 模型按驱动预期实现，疑点写入报告，不猜测语义 |
| 独立设备模型让大量既有测试失败 | 逐个判定：属于 VIP 缺陷就修 VIP，属于测试依赖了 responder 的偷看行为就改测试的输入，不放宽断言 |
| TCG 运行慢 | 每个模式只跑一轮完整场景（预计 10–15 分钟）；回归不依赖 cosim |
