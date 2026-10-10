# 13 把各层连成一次完整运行

## 13.1 从 run_test 到 flow ready

前面各章按对象和数据结构拆开阅读；这一章按时间重新串联。主线仍是 `virtio_real_driver_flow_test` 的 MODEL 运行，RX 放在独立小节，因为它由另一个 test 创建全新 fixture，不是 TX run 的下一段。

顶层 `virtio_tb_top.sv:71` 调用 `run_test()`，测试名由仿真参数 `+UVM_TESTNAME` 选择。顶层另有 250 MHz 时钟、100 ns 平台复位以及 30 s 仿真时间兜底。`run_test` 前的 `#0` 给生成的接口注册过程一次执行机会；它不等待业务初始化。测试 build phase 创建 fixture，此后 UVM 各 phase 才逐步产生可运行环境。

| 阶段 | 发生的业务动作 | 尚未完成的动作 |
|---|---|---|
| test.build | 工厂创建 `flow` | 未做 feature 协商 |
| fixture.build | 提交 DPU 配置请求，建立共享内存和各环境；MODEL 创建 device | 未分配业务 ring |
| DPU/环境解析 | 生成冻结的设备/资源视图，按 service 建 Function | 未写 DRIVER_OK |
| fixture.connect | 绑定 PCIe RC/EP 观察与事务路径，接 MODEL device port | 未提交包 |
| fixture.end_of_elaboration | 从 snapshot 解析 AF/BDF/BAR，配置并挂接模型，取共享 Host memory | 未产生 used completion |
| test.run / build_flow | 检查冻结对、路径、端点与共享句柄 ready | 尚需执行 driver flow |

这里有两个名字容易误读。`configure_devices` 创建的是设备模型的配置空间/寄存器初始状态，并赋予 frozen BDF；Host 驱动后面仍要经 PCIe 配置事务编程 BAR。`build_flow` 则是准备条件的验收函数：如果没有 endpoint ready、snapshot 对不匹配、PCIe 路径没接通、REAL_DUT 的双向链路/Host memory 服务缺失，返回 0 并填写 why。它本身不会偷偷完成 `start_driver_flow`。

源码：[run_test():71](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_tb_top.sv#L71)、[build_phase():99](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L99)、[connect_phase():263](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L263)、[end_of_elaboration_phase():307](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L307)、[build_flow():412](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L412)。

## 13.2 golden TX 的顺序与证据

test.run 首先 raise objection，使业务 task 没有完成时 UVM 不提前结束。`build_flow` 成功后，测试检查 snapshot frozen、BDF 非零、三对 BAR、共享 Host memory 和 transport 环境句柄，再通过 resource client 映射取得 pair 0 的 TX local queue ID。默认是 TX1，调用链仍然使用查询结果。

接下来可按下列时间线定位断点。这里的箭头表示先后依赖，不代表同一仿真时刻完成；PCIe completion、device worker 和观察事件可能异步推进。

1. `start_driver_flow(ok)`：等待协议观察接口退出平台复位；发现/编程 BAR，开 MSE/BME；执行 verified reset；写 ACKNOWLEDGE、DRIVER；协商 CSUM|VERSION_1；写后读回 FEATURES_OK；检查四条队列容量；配置 MSI-X；写后读回 DRIVER_OK。完成后 fixture 标记 flow started，FSM 视图为 READY。
2. `setup_queue(tx_queue_id,256,VQ_SPLIT,ok)`：生产 ops 创建一条 split 队列，分配三个 Host 区域，映射为设备 IOVA，写地址/向量/notify offset 并 enable；fixture 额外读 queue_enable。golden 没有执行 `full_init`，因此不会再建一组重复 ring。
3. 构造 `virtio_real_driver_flow_packet`：payload 固定为 `de ad be ef 01 23 45 67 89 ab cd ef 10 20 30 40`，header 全零；记录模型 notify、DMA read、DMA write、completion、interrupt 五个计数基线。
4. `submit_tx(...,use_indirect=0,desc_id,ok)`：生产 TX 操作分配和映射 header/payload，经队列发布 descriptor 与 avail，按条件 kick。成功描述符 ID 不等于全 1；fixture 不直接改 ring 来模拟设备。
5. MODEL 经收到的通知处理队列，读取 descriptor 和数据，执行设备侧 TX 行为，再经设备 DMA 写 used 并产生中断。详情见第 10～12 章；测试此时没有“帮设备写完”的快捷操作。
6. `complete_tx(...,max_budget=1,completed_count,ok)`：反复调用生产 `tx_complete`，直到出现完成或等待界限耗尽。test 要求 ok、count=1、对象数组大小=1，并要求五项设备计数各自增加。
7. `reset_and_teardown(ok)`：等待观察事件可被检查，确认设备 reset，释放 ring/DMA，检查 manager 清空与泄漏报告，再 drop objection。

本测试的正向证据是“正式 TX 提交和回收、设备通知/DMA/used/中断计数发生”。它没有取出 wire-side frame 与 16 字节 payload 做逐字节比较；也没有把 returned token 的数据逐字节重读核验。不能把 completion count=1 宣传成任意 offload、分段、wire payload 内容都已验证。全零 header 也不意味着 CSUM feature 未协商，只表示本次报文不请求 checksum offload。

源码：[run_phase():40](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_test.sv#L40)、[start_driver_flow():736](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L736)、[setup_queue():830](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L830)、[complete_tx():918](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L918)。

## 13.3 独立 RX run：先到帧，后有可写 buffer

选择 `virtio_real_driver_rx_test` 会从 UVM build 重新开始。它同样通过 frozen placement 查询 pair 0 的 RX local queue ID，初始化 driver flow，再单独建立 split256 RX ring。该测试显式要求 MODEL；REAL_DUT 分支在缺少平台 RX ingress callback 时 fatal，不会自动拿模型代替 RTL。

RX test 记录 notify、DMA write、completion、interrupt 基线，然后生成四个 `packet_item`。每个对象约束 `pkt_kind==ETH_IPV4_UDP`、`pkt_len` 在 128..512，randomize 成功后执行 `pkt.pkt.do_pack()`，保存为 expected，并调用 `flow.inject_rx` 送入设备网络侧。四帧全部先入设备等待队列，此时还没有驱动发布的 RX writable buffer；这样特意验证设备会等资源，而不是测试预写 payload。

随后 `refill_rx(rx_queue_id,4,ok)` 调用生产 ops 分配四份空 buffer、做 FROM_DEVICE 映射、构造可写 descriptor、发布 avail 与通知。MODEL 自己消费已排队的帧并写入 header、payload、used。`receive_rx(...,budget=4,received,received_count,ok)` 反复调用生产接收接口。test 要求 received_count 与数组大小都精确等于 4；每项必须能 cast 为 `packet_item`，且 `virtio_net_packet_adapter::compare(expected[i],actual)` 成功。最后检查四项计数增加，再 reset/teardown。

因此 RX 的断言比 golden TX 多一个明确的 packet compare 边界：adapter 将 expected/actual 都 pack 成字节序列，先比长度，再逐字节比较。它覆盖本次随机生成帧在 adapter 契约下的内容一致性，不等于覆盖所有 IPv4/UDP checksum 错误、GSO、mergeable buffer、RSS 或 MQ；是否覆盖这些行为，要看各专项测试的 feature、报文和断言。

还要区分三个 helper 的 ok：`refill_rx` 的 ok=1 只表示找到有效 ops 并调用返回；`rx_refill` 内部可能因 ring 满、内存不足或映射失败提前结束。`complete_tx` 的 ok 表示至少收到一个完成，不保证 max_budget 项。`receive_rx` 的 ok 表示至少收到一个包，不保证 budget 项。请求数是否满足，必须看调用者对 count 和数组长度的断言，本 RX test 正是这样做的。

源码：[RX run_phase():28](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_rx_test.sv#L28)、[refill_rx():984](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L984)、[receive_rx():1007](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L1007)、[compare():57](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/dataplane/virtio_net_packet_adapter.sv#L57)。

# 14 生命周期、故障定位和运行入口

## 14.1 reset 的第一件事是证明设备停下

queue manager 的 `destroy_all()` 只会释放 Host ring 对象，不能证明设备已经停止使用这些地址。正式收尾调用 `device_reset_verified(ref reset_complete)`，先检查 transport、manager、IOMMU 以及待回收普通 DMA 所需 memory 上下文，再通过配置 backend 请求 reset 并等待确认。标准 backend 最终写 status=0 并轮询回读 0。

未确认时，它置 `queue_recovery_pending=1`、`ctrl_recovery_pending=1`，返回失败并保留旧 ring、IOVA 和 DMA backing。后续建队/control 提交会受恢复门禁阻止。保留资源是因为设备仍可能访问；这时不应为了让 leak check 好看而强行 free。上下文不完整也进入同一保守门禁，不能把缺少 handle 当成已经 reset。

只有设备 reset 确认后，才执行以下释放链：detach 未完成 buffer 的 descriptor 所有权；逐条撤销 ring IOVA 并清 `queue_programs`；retire 尚归 Host 持有的普通 TX/RX DMA 记录；回收迁移恢复 payload 与 control quarantine；最后 `vq_mgr.destroy_all()` 释放 ring 的 Host 分配并删除对象。成功路径清控制队列身份、negotiated features 与两个 recovery pending 标记。完成路径已经回收的 DMA 记录不应再由 reset 重复释放，所以 ownership 表是这段实现的核心。

fixture 的 `reset_and_teardown` 在此之前关闭可选 Host-memory responder，并在 FSM_RUNNING 时停止数据面 worker。它调用 `drain_protocol_events` 等待 MSI-X 发布延迟、staged protocol 事件消耗并再等两拍，避免立即复位使尚未检查的事件被清除。该 drain task 超时会报告 UVM_ERROR，但没有状态输出阻止后续 reset；不能把最终 helper ok 当成“整轮绝无观察错误”，还要检查 UVM summary。

verified reset 失败时 fixture 返回 ok=0；成功后检查队列数为零并调用 IOMMU/Host memory leak_check，最后将 FSM 视图设 IDLE、flow started 清零。leak_check 的报告也不都被折算为 helper 的 ok，所以严格日志检查仍是完成条件的一部分。

源码：[device_reset_verified():14](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh#L14)、[drain_protocol_events():1045](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L1045)、[reset_and_teardown():1075](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L1075)。

## 14.2 按最早断开的边界定位

看到“没有收到包”时，先找最早失去证据的位置，不要直接扩大轮询超时。下面每行只给第一组定位入口；修复必须遵守 snapshot、外部依赖和资源所有权边界。

| 现象 | 首先核对 | 可区分的问题 |
|---|---|---|
| build_flow 返回 0 | why、frozen snapshot 对、endpoint/path ready | 平台接线与业务初始化失败 |
| discovery fatal | BAR lease/role、capability walk、Command 位 | 身份/布局错误与队列错误 |
| FEATURES_OK 被清 | device mask、driver mask、设备 status | 配置愿望与实际协商 |
| setup_queue 返回 0 | 重复 ID、recovery pending、Q_SIZE、域、映射/向量 | 上一生命周期未结束与资源不足 |
| 有 avail，无 notify | suppression、notify offset、kick 日志 | 合法抑制与地址/队列错误 |
| 有 notify，无 DMA | DRIVER_OK、queue enable、设备 error、BME | 未激活队列与设备拒绝 descriptor |
| 有 DMA，无完成 | header/chain 解析、IOVA 权限、used 发布 | 数据访问失败与完成写失败 |
| 有 used，Host 没回收 | ring 格式、used index/wrap、预算与 token | 设备完成与驱动消费失败 |
| 有 completion，无中断 | MSI-X Enable/Mask、vector 映射、suppression | polling/抑制与真正丢中断 |
| reset 后资源残留 | reset_complete、pending 标记、ownership 表 | 安全保留与成功 reset 后漏回收 |

地址问题至少带上 host、BDF、queue ID、GPA、IOVA、长度与方向。仅记录一个十六进制地址通常不足以定位：同一 Host 的共享 backing、不同 BDF 的设备 DMA 域以及 BAR MMIO 窗口有不同意义。随机地址策略下也不应靠“这次地址没有连续”判错。

默认 flow 轮询界限是 1000 次，每次无完成时推进 1 ns，可由 `+VIRTIO_FLOW_TIMEOUT_NS` 调整，0 被归一为 1。它与 PCIe completion timeout、wait policy 的 reset 超时、顶层 30 s 仿真时间兜底、strict regression 的墙钟超时不是同一计时器。调整哪一个应取决于哪个等待先失败，不能用一个巨大上限掩盖没有接通的 EP→RC 路径。

## 14.3 MODEL 与 REAL_DUT 的替换边界

MODEL 的 execution profile 选择 TLM_MODE、active EP 和设备模型；fixture 安装 completion adapter/factory override，通过 `vdev_uvm_ep_port` 将设备配置/MMIO、DMA 与 MSI-X 接到 PCIe 环境。它仍然要求正式 driver 写寄存器与 ring；“MODEL”不等于测试直接造一个 used 条目。

REAL_DUT 的 profile 不创建 `vdev_virtio_pci`，选择 SV_IF_MODE、passive EP，关闭自动设备应答。配置/BAR/device 行为应来自 RTL。fixture 要求两条物理方向：RC→EP 与 EP→RC；单个 `pcie_tl_if` 只有一个有效方向，不能同一 bundle 同时充当双向链路。Virtio monitor 保留观察功能，却不会因此获得替 RTL 完成请求的权限。

EP 发起 Host memory DMA 还需要 RC 服务。可以由外部 FULL-VIP/backend bridge 提供，也可显式启用 fixture 的 Host-memory responder；两者同时启用会冲突，存在重复 Completion 风险，`build_flow` 会拒绝。该 responder 只服务共享 Host memory 的 MemRd/MemWr，不是 Virtio device model，不会构造网络 ingress，也不会替设备推进 used ring。

REAL_DUT TX 测试使用生产提交/回收接口，并检查被动 monitor 的 notify/DMA/interrupt 事件 FIFO 增长，不能去取 MODEL 的 device counters。REAL_DUT RX 在当前独立 RX test 中缺少平台 ingress callback，明确以 `REAL_DUT_RX_SOURCE_UNAVAILABLE` 终止。仅设置执行模式 plusarg 无法让默认顶层凭空出现 RTL、双向 VIF 或网络入口。

源码：[execution profile](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/env/virtio_execution_profile.sv)、[REAL_DUT readiness:432](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv#L432)。

## 14.4 如何复现，以及本文没有宣称什么

本文为源码阅读与文档交付，没有执行 VCS，没有新增某个测试 PASS 的结论。所有 VCS 验证必须在项目指定的 `10.11.10.53` 仿真主机进行，使用加载 `.bashrc` 中 VCS 路径及 license 环境的 bash 登录环境；认证信息不属于本文内容。应先在该主机核对 checkout 基线与外部依赖，不能在阅读机的任意环境直接宣称复现。

`scripts/check_deps.sh` 是编译前置门，检查外部依赖路径、remote 与版本契约。本文基线固定 `dpu_common=4d739965eb47d90b47cc048fc71fd8d7d76a77ca`、`host_mem=35ec087014744ec85cf6c0fe17e1f7118ee7a7b7`；其余依赖按脚本各自规则校验。本次阅读环境的 dpu_common HEAD 为 `311a9d…`，与 pin 不同，因此不能宣称依赖检查已通过。本文没有修改依赖仓库来消除差异；未来复现应准备符合项目契约的外部 checkout，再过门。

在仿真主机的正确仓库工作目录、依赖环境与 VCS 环境已配置后，两个主线入口是：

```bash
TEST=virtio_real_driver_flow_test bash scripts/vcs.sh
TEST=virtio_real_driver_rx_test bash scripts/vcs.sh
```

这是两次独立运行。`scripts/vcs.sh` 使用环境变量 TEST 选择 maintained test，唯一可选位置参数为 `--compile-only`；把测试名放在位置参数会被拒绝。脚本先检查 VCS 和 TEST，再调用依赖检查、编译固定 filelist，最后执行 `build/simv +UVM_TESTNAME=...`。它不把任意额外命令行参数透传给 simulator。

需要详细日志时可以设置 `UVM_VERBOSITY=UVM_HIGH`。需要自行给 simv 传递执行模式等 plusargs 时，应在同一受控环境先用合法 TEST 做 `--compile-only`，再直接运行已生成的 simv；REAL_DUT 还必须使用实际接好 RTL/VIF 的平台，不能把下面的 MODEL 编译入口误作 RTL 接入完整方案。

```bash
TEST=virtio_real_driver_flow_test bash scripts/vcs.sh --compile-only
build/simv +UVM_TESTNAME=virtio_real_driver_flow_test +UVM_VERBOSITY=UVM_HIGH
```

“进程退出为 0”不等于验证成功。`scripts/strict_log_check.sh` 分 compile/sim 模式，拒绝 VCS warning/error；sim 还要求恰好一份 UVM summary，WARNING/ERROR/FATAL 各一行且都为 0，并拒绝 Host memory leak、PCIe completion 字段 mismatch 和非零 scoreboard mismatch。`strict_regression.sh` 统一编译后逐个运行 maintained tests，另加默认 180 s 墙钟超时并对每份日志执行该检查。本次未运行这些脚本；这里解释可复现入口，不把脚本存在当成已有测试证据。

源码：[vcs.sh](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/scripts/vcs.sh)、[check_deps.sh](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/scripts/check_deps.sh)、[strict_log_check.sh](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/scripts/strict_log_check.sh)。

# 附录 A 按阅读目的查文件

本附录只提供索引；资源与初始化的逐函数参数表见第 9 章，TX/RX 数据动作见第 10～12 章。所有路径相对仓库根目录。

| 阅读目的 | 文件或目录 | 优先查找的入口 |
|---|---|---|
| UVM 从哪里启动 | `virtio_net_vip/tests/virtio_tb_top.sv` | `run_test` |
| 最短 TX 业务契约 | `virtio_net_vip/tests/virtio_real_driver_flow_test.sv` | `run_phase` |
| 随机网络帧 RX 对比 | `virtio_net_vip/tests/virtio_real_driver_rx_test.sv` | `run_phase` |
| 环境准备与业务包装 | `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv` | phase、submit/receive/reset helpers |
| Function 边界 | `virtio_net_vip/src/sriov/` | resource client、function instance |
| 驱动动作的真实实现 | `virtio_net_vip/src/agent/atomic_ops/` | lifecycle、queue、datapath 文件 |
| 自动状态机的另一入口 | `virtio_net_vip/src/agent/virtio_auto_fsm.sv` | full_init、start/stop_dataplane |
| 环格式与 Host ring 访问 | `virtio_net_vip/src/virtqueue/` | alloc_rings、add_buf、get_buf |
| 配置/MMIO 与 notify | `virtio_net_vip/src/transport/` | discovery、backend、transport |
| 真正设备侧处理 | `virtio_net_vip/src/devmodel/vdev_virtio_pci.sv` | service_queue、consume、push_used |
| 设备 PCIe 端口 | `virtio_net_vip/src/devmodel/vdev_uvm_ep_port.sv` | serve、dma_read/write、raise_msix |
| packet 对象转换 | `virtio_net_vip/src/dataplane/virtio_net_packet_adapter.sv` | pack、unpack、compare |
| 地址权限与域 | `virtio_net_vip/src/iommu/virtio_iommu_model.sv` | map_for_host、unmap_for_host |
| 私有协议独立实例 | `examples/dpu_priv_ring/` | driver flow 与 contract test |
| 可运行测试名单/判定 | `scripts/` | test_manifest、vcs、strict_log_check |

设备模型导航：[service_queue():491](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L491)、[push_used():948](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_virtio_pci.sv#L948)、[DMA 端口:192](https://github.com/Beihang-yuting/virtio_work/blob/e2a0a46cf968cb0cb0c3ad02a211ba65afc88d6c/virtio_net_vip/src/devmodel/vdev_uvm_ep_port.sv#L192)。

# 附录 B 术语与阅读自检

## B.1 本文术语

| 术语 | 本项目中应如何理解 |
|---|---|
| frozen snapshot | DPU 权威解析完成的设备/资源视图，Virtio 只消费 |
| Function / BDF | PCIe 功能及其 bus/device/function 身份；完整域还含 host/segment |
| service | 附属于 Function 的 VIO-net 服务，是资源绑定和行为配置的键 |
| qpair | 一对 RX/TX 资源；global qpair ID 不等于 local queue ID |
| GPA | Host memory backing 地址，Host 分配与读写使用 |
| IOVA | 设备可见 DMA 地址，受 host/BDF 映射和权限限制 |
| BAR | PCIe 寄存器/功能窗口，不能当作 ring backing |
| SG / descriptor | 一组缓冲段及其设备可读描述，方向以设备视角解释 |
| token | 随提交保留的 Host 软件对象身份；不等于设备 wire payload |
| avail / used | split 中的驱动发布与设备完成索引/条目 |
| packed wrap | packed 描述符归属随环回绕改变的判定状态 |
| notify / kick | Host 通知设备检查已发布队列 |
| MSI-X | 设备向 Host 发布的中断消息，受表项/向量/mask 控制 |
| verified reset | 确认设备停止旧生命周期后才能回收 DMA 的复位路径 |
| recovery pending | 未能确认安全回收时阻止新建队列及 control VQ 提交的状态门禁 |
| MODEL / REAL_DUT | 本地设备模型执行 / RTL 执行，不能混用完成来源 |

## B.2 能回答这些问题，再继续改业务

- pair 0 的 TX 队列号从哪一条资源映射取得？为什么不能从 global qpair ID 推导？答题定位：第 6 章的 resource client 与 fixture 查询。
- 全 1 driver feature mask 为什么没有让 golden 使用 packed、MQ 或 mergeable RX？定位：第 7 章的设备广告与交集。
- golden 哪个函数真正分配 ring？它为什么没有执行 full_init？定位：第 8 章的 setup_queue 和第 13 章时间线。
- 描述符中的地址、common config 中的 ring 地址、Host mem 读写地址分别属于哪个地址域？定位：第 8 章 GPA/IOVA。
- packed 一次 Host 分配为什么仍有三份 IOVA 区域？定位：get_ring_regions 与 ops 的映射粒度。
- 已有两对 Host ring 为什么还不能直接启动标准 MQ 数据面？定位：mq_pairs_committed 与 control VQ 命令。
- RX test 在没有可写 buffer 时把四帧放在哪里？谁在 refill 后写 payload 和 used？定位：第 13.3 节及设备 rx_frame。
- helper ok=1、count 达标、packet compare 成功和严格日志通过，各自排除了哪一类失败？定位：第 13 章及第 14.4 节。
- 如果 status=0 的回读一直未完成，应该释放 ring 还是保留？什么门禁阻止新队列混进旧生命周期？定位：device_reset_verified。
- REAL_DUT Host-memory responder 为什么不能解决 RX 网络入口缺失？定位：第 14.3 节的组件职责。
- golden TX 的计数都增加，是否证明线上 16 字节内容完全正确？定位：第 13.2 节测试断言边界。
- 新跑的一份日志出现 UVM_WARNING，但进程退出码为 0，能否登记 strict PASS？定位：strict_log_check 的 summary 规则。
