# DPU 私有环的 src 使用流程

私有实现现在由 `virtio_net_vip/src/virtio_net_pkg.sv` 编译，使用者只需
`import virtio_net_pkg::*;`。本目录保留测试和顶层环境用法，不再复制私有实现。
驱动依据为 53 主机 `/home/ubuntu/wn/icpu-kernel-driver` 的
`lance_net_mailbox@f2c9cd6`，对应 `priv_ring=true`。

驱动的 `priv_ring=false` 另有一套 DPU Virtio ring 路径，与 VIP 标准模式存在
数据布局、控制面和通知差异；详细结果见 [标准模式对照审计](STANDARD_MODE_AUDIT.md)。

| 源码 | 职责 |
| --- | --- |
| `src/dpu_priv/dpu_priv_driver_config.sv` | Function/queue 分层配置 |
| `src/virtqueue/custom_virtqueue.sv` | 16B 描述符、CQ、wrap、64KiB TX 分片 |
| `src/dpu_priv/dpu_priv_config_backend.sv` | 队列参数表、doorbell、status/feature 语义 |
| `src/dpu_priv/dpu_priv_driver_protocol.sv` | 能力与复位语义 |
| `src/devmodel/vdev_dpu_priv.sv` | 私有设备模型（驱动寄存器序列、16B 描述符与 CQ、qid map 路由） |

## 1. 设备与配置后端

私有 Function 的全部设备访问由 `dpu_priv_config_backend` 完成：它按真实驱动 AF 路径（`pfvf_id=0`）
的寄存器序列访问 BAR0/BAR2——AF 声明（0x1010 魔数 0x5555AAAA、0x60040）、qinfo、MSI-X 映射表、qid map、
VTX/VRX 队列参数表、共享 doorbell（BAR0+0，`wrap<<31 | tail<<16 | local_qid`）与停队/复位轮询。序列表、
驱动与 reg plan 的疑点见 `src/devmodel/vdev_dpu_priv.sv` 文件头。PF/VF mailbox 路径未建模。

纯模型测试使用独立设备模型 `vdev_dpu_priv`：本目录的流程测试把它挂在回环端口上（寄存器访问直达设备，
设备 DMA 经该 Host 的 IOMMU），设备按 qid map 与参数表处理描述符、写 CQ，并把 TX 帧回环到同一队列对的
RX。测试旋钮 `stall_queue_stop` 让停队/复位永不完成，用来验证“DMA 未停则保留资源”。PCIe 枚举与 BAR 放置
属于平台，后端不写 BAR。

连接真实 DUT 时，在绑定 PCIe 前设置 `vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT`
和 `vio_cfg.completion_mode = VIRTIO_COMPLETION_POLLING`。

## 2. 按 service key 注册到 env_cfg

```systemverilog
virtio_net_env_config vio_cfg;       // 当前 Host 的配置
// service_key 来自顶层 DPU 声明，包含 Host/PF/VF/service 身份。
dpu_service_key_t service_key;
dpu_priv_driver_config private_cfg;
string why;

private_cfg = new("vf0_private_cfg");
private_cfg.default_queue_size = 512;
private_cfg.rx_buf_size = 2048;
private_cfg.local_qid_base = 0;      // RX0=0，TX0=1，RX1=2，TX1=3
private_cfg.defaults.notify_bar = 0;
private_cfg.defaults.notify_offset = 0;
private_cfg.defaults.dport_id = 10'h12;

if (!vio_cfg.add_dpu_private_config(service_key, private_cfg, why))
    `uvm_fatal("PRIVATE_CFG", why)
```

若某条队列需要单独设置路由/通知，可填写 `private_cfg.queues[queue_id]`：
该对象是完整的队列配置覆盖，必须明确填写 `local_qid`。它不继承 `defaults`
的字段；未覆盖的队列使用 `defaults` 并按 `local_qid_base+queue_id` 计算本地号。

同一 Host 下的其他 service 不注册私有配置即可继续使用标准 Virtio。已有
`add_service_config()` 控制队列对数和环大小；未提供显式 service 行为时，私有
service 使用 `default_queue_size`。注册私有模式会选择 `VQ_CUSTOM`、polling
和原始 Ethernet 数据路径，不再协商标准 Virtio offload。

顶层仍按 Host 绑定唯一的 `host_mem_manager`，该 Host 的 PF/VF 共用它；
不同 Function 的 ops、队列管理器和配置后端独立。设备本地 `local_qid` 不等同于
DPU 的全局队列资源编号。同一本地号可出现在不同 Host/Function 内。
驱动的 `local_qid` 为 8 位，因此每 Function 最多 128 对 RX/TX 队列，并继续受
冻结 snapshot 的实际配额限制；设备的 2048 条全局队列仍由顶层资源配置分配。

## 3. 使用现有 env/agent 接口

照常构建顶层环境，并使用现有 `bind_pcie_endpoints()`、`bind_pcie()` 或
Function 的 `preflight_bind_pcie()` + `commit_bind_pcie()` 绑定资源。环境把私有配置交给对应 Function，
Function 选择 `dpu_priv_driver_protocol`，创建通用 ops/FSM，提交时冻结私有配置进
`dpu_priv_config_backend`；`function.dataplane` 的标准 TX/RX 引擎委托同一个 ops。
不需要全局 factory override，也不需要逐队列配置私有格式。

```systemverilog
function_instance.driver_agent.fsm.full_init();
if (function_instance.driver_agent.fsm.state != FSM_READY)
    `uvm_fatal("PRIVATE_INIT", "私有初始化失败")
// 已创建全部 RX/TX 队列，启动时自动补充 RX buffer。
function_instance.driver_agent.fsm.start_dataplane();
function_instance.driver_agent.fsm.send_packets(packets, 0); // queue pair 0
// 通过 wait_packets() 等待并取得 RX 原始帧。
function_instance.shutdown(); // 停 worker，再确认停 DMA，成功后回收所有队列。
if (function_instance.get_state() != VF_DISABLED)
    `uvm_fatal("PRIVATE_STOP", "私有停机失败，资源已保留")
```

细粒度场景继续使用 `ops.setup_queue/tx_submit/tx_complete/rx_refill/rx_receive`。
`tx_submit` 的 header 参数须全零，包用 `net_packet_pkg::packet_item`；
`function.dataplane.tx_engine` 和 `rx_engine` 的公共接口也委托同一个 ops，
因此它们共享 DMA 所有权。手工 `ATOMIC_KICK` 会发送私有 doorbell，
`ATOMIC_POLL_USED` 经 ops 回收资源后把结果放进事务的 completed/received 队列。
直接操作底层 `vq.add_buf/poll_used` 时则由调用方自行管理对应 SG/DMA 生命周期，
不能与 ops 管理的投递混用。

内部建队顺序为：创建 `VQ_CUSTOM` → 后端写方向/本地号 → 分配连续 desc+CQ →
一次映射 → 寄存器级后端写 VTX/VRX 队列参数表并启用（设备侧为 `vdev_dpu_priv`）。CQ IOVA 必须等于 ring IOVA 加
`queue_size*16`，不能把 CQ 单独随机映射。停队或复位失败会保留资源；上层必须
检查复位成功标志，并先停止后台数据面再做手工 teardown/reset。
通过 `Function.shutdown()` 停机成功后，FSM 进入 `FSM_REINIT_REQUIRED`，下次启动
须先 `full_init()`；停机失败则 Function/FSM 分别进入 `VF_RESET_FAILED/FSM_ERROR`。
数据面处于 `FSM_RUNNING` 时 `full_init()` 报 `UVM_ERROR` 并拒绝执行，须先停止数据面。

队列大小须为 2 的幂，2..4096（VTX/VRX `q_depth` 按 log2 编码，非 2 的幂由 `prepare_queue` 拒绝）；
显式请求大小超过 `default_queue_size` 时截到该值并给出 `UVM_WARNING`。
TX 遇到 ring 满（剩余槽不足以容纳本包描述符）时报 `UVM_ERROR`（`DPU_PRIV_RING`，
与 split 一致），不再静默返回；调用方应先回收完成再投递。

## 4. 运行验证

仿真在 `ubuntu@10.11.10.53` 上进行，先加载 `~/.bashrc` 的 VCS 环境，并设置
`DPU_COMMON_ROOT`、`NET_PACKET_ROOT`、`HOST_MEM_ROOT`、`PCIE_WORK_ROOT`、
`QUEUE_WORK_ROOT`。`scripts/check_deps.sh` 会核对这些外部依赖。

两个测试已列入 `scripts/test_manifest.sh`，与其他维护测试共用 `filelists/tests.f`
和 `virtio_tb_top` 编译，`make regression` 会运行它们。单独运行：

```bash
TEST=dpu_priv_driver_flow_test ./scripts/vcs.sh
TEST=dpu_priv_ring_contract_test ./scripts/vcs.sh
```

流程测试复用 `examples/virtio_system_env` 顶层：两个 Host 各有一个私有 VF 和一个标准 VF，私有 VF 面对
`vdev_dpu_priv`；验证 env_cfg 到 ops/FSM 的选择、寄存器级后端、TX/RX 原始帧（从设备事件核对描述符长度、
帧字节与通知字）、引擎委托、停 DMA 失败保护，以及后台启动/停止后的 DMA 回收。合同测试核对 GCC 生成的
TX/RX/CQ 黄金字节、默认 512 项布局、65537B TX 分片和环回绕，并让 `vdev_dpu_priv` 写出的 CQ 与同一组黄金值
对齐。

当前支持 polling、普通 TX（每段最多 65536B、拆分后最多 7 条 data desc）和
单 buffer RX。TSO 扩展描述符、多 buffer RX、动态 MQ、迁移及标准 control VQ
不在当前支持范围；TX 路由和 checksum 位通过私有队列配置明确指定。
