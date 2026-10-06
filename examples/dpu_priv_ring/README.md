# DPU 私有环的 src 使用流程

私有实现现在由 `virtio_net_vip/src/virtio_net_pkg.sv` 编译，使用者只需
`import virtio_net_pkg::*;`。本目录保留测试和顶层环境用法，不再复制回调实现。
驱动依据为 53 主机 `/home/ubuntu/wn/icpu-kernel-driver` 的
`lance_net_mailbox@f2c9cd6`，对应 `priv_ring=true`。

驱动的 `priv_ring=false` 另有一套 DPU Virtio ring 路径，与 VIP 标准模式存在
数据布局、控制面和通知差异；详细结果见 [标准模式对照审计](STANDARD_MODE_AUDIT.md)。

| 源码 | 职责 |
| --- | --- |
| `src/dpu_priv/dpu_priv_driver_config.sv` | Function/queue 分层配置，AF/mailbox 控制接口 |
| `src/dpu_priv/dpu_priv_ring_callback.sv` | 16B TX/RX 描述符、CQ、wrap、64KiB TX 分片 |
| `src/dpu_priv/dpu_priv_atomic_ops.sv` | 自动建队、连续 ring DMA 映射、原始帧收发、资源回收 |
| `src/dpu_priv/dpu_priv_auto_fsm.sv` | 私有初始化与公共 FSM 收发/停止流程 |
| `src/dpu_priv/dpu_priv_dataplane.sv` | 让 `function.dataplane` 的引擎也共用同一套私有 ops |

## 1. 在顶层准备设备控制后端

继承 `dpu_priv_device_control`，实现三个有成功标志的 task：

- `reset_device(host_id, bdf, ok)`：复位指定 Function，确认停止 DMA 后返回成功。
- `configure_queue(ctx, ok)`：通过 AF 寄存器或 PF/VF mailbox 配置并启动队列。
  `ctx` 提供 Host、BDF、VIP queue_id、设备 local_qid、方向、容量、连续
  `ring_iova/cq_iova` 和 RX buffer 大小。失败时必须保证队列未启动 DMA。
- `disable_queue(ctx, ok)`：停队并确认 DMA 排空；失败时 src 保留全部内存和映射。

默认 `notify_queue()` 已通过 Function 的 BAR accessor 执行 32-bit MMIO 写，
数据为 `wrap<<31 | tail_ptr<<16 | local_qid`。默认目标 BAR0、offset 0，对应驱动
`writel(value, hw->hw_addr)`；可按队列覆盖地址，也可覆写通知 task 对接已有后端。

AF/mailbox 的平台实现仍由顶层接入，src 不会用空后端返回配置成功。本目录的
`dpu_priv_example_control` 是内存测试后端，演示这三个接口及严格 IOVA DMA；
它不代表真实硬件 AF/mailbox 已验证。PCIe 枚举、BAR 分配及平台初始化须先完成，
私有 FSM 不执行标准 Virtio capability/feature 握手。

连接真实 DUT 时，在绑定 PCIe 前设置 `vio_cfg.execution_mode = VIRTIO_EXEC_REAL_DUT`
和 `vio_cfg.completion_mode = VIRTIO_COMPLETION_POLLING`，由 DUT 产生描述符完成。
默认标准 Virtio 设备模型不解释这套私有格式；纯模型测试应像本目录示例一样提供
对应的私有设备控制/DMA 模型。

## 2. 按 service key 注册到 env_cfg

```systemverilog
virtio_net_env_config vio_cfg;       // 当前 Host 的配置
// service_key 来自顶层 DPU 声明，包含 Host/PF/VF/service 身份。
dpu_service_key_t service_key;
dpu_priv_driver_config private_cfg;
string why;

private_cfg = new("vf0_private_cfg");
private_cfg.control = my_device_control;
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
不同 Function 的 ops、队列管理器和回调独立。设备本地 `local_qid` 不等同于
DPU 的全局队列资源编号。同一本地号可出现在不同 Host/Function 内。
驱动的 `local_qid` 为 8 位，因此每 Function 最多 128 对 RX/TX 队列，并继续受
冻结 snapshot 的实际配额限制；设备的 2048 条全局队列仍由顶层资源配置分配。

## 3. 使用现有 env/agent 接口

照常构建顶层环境，并使用现有 `bind_pcie_endpoints()`、`bind_pcie()` 或
Function 的 `wire_shared()` 绑定资源。环境把私有配置交给对应 Function，
后者自动创建 `dpu_priv_atomic_ops`、`dpu_priv_auto_fsm` 和私有 TX/RX 引擎。
不需要全局 factory override，也不需要手动给每条队列设置 `custom_cb`。

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

内部建队顺序为：创建 `VQ_CUSTOM` → 注入每队列独立回调 → 分配连续 desc+CQ →
整块映射一次 IOVA → 配置设备 → 标记启用。CQ IOVA 必须等于 ring IOVA 加
`queue_size*16`，不能把 CQ 单独随机映射。停队或复位失败会保留资源；上层必须
检查复位成功标志，并先停止后台数据面再做手工 teardown/reset。
通过 `Function.shutdown()` 停机成功后，FSM 进入 `FSM_REINIT_REQUIRED`，下次启动
须先 `full_init()`；停机失败则 Function/FSM 分别进入 `VF_RESET_FAILED/FSM_ERROR`。

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

流程测试复用 `examples/virtio_system_env` 顶层：两个 Host 各有一个私有 VF 和
一个标准 VF，验证 env_cfg 到 ops/FSM 的选择、连续 IOVA、TX/RX 原始帧、引擎
委托、停 DMA 失败保护，以及后台启动/停止后的 DMA 回收。合同测试核对 GCC
生成的 TX/RX/CQ 黄金字节、默认 512 项布局、65537B TX 分片和环回绕。

当前支持 polling、普通 TX（每段最多 65536B、拆分后最多 7 条 data desc）和
单 buffer RX。TSO 扩展描述符、多 buffer RX、动态 MQ、迁移及标准 control VQ
不在当前支持范围；TX 路由和 checksum 位通过私有队列配置明确指定。
