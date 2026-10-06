# Virtio VIP 架构简化设计

## 目标

在不改变已维护回归行为的前提下，修复审计发现的缺陷，删除无调用的代码，
合并重复实现，并为“设备发现绑定与 AF 直配”预留明确的接入点。
后续设计见 `2026-10-06-dut-discovery-binding-af-config-design.md`，它依赖本设计的 P3。

基线：`20f7630`，src 100 个文件 32,497 行，tests 34 个文件 27,147 行，
`strict_regression` 37/37 PASS（53 主机 VCS W-2024.09-SP1，dpu_common `4d73996`）。

## 范围与非目标

- 范围：`virtio_net_vip/src`、`virtio_net_vip/tests`、`examples/`、`scripts/`、README 与手册中
  与本次改动相关的段落。
- 非目标：dpu_common、pcie_work、host_mem、net_packet、queue_work 不在本设计内修改；
  不新增功能；不改变 MODEL/REAL_DUT 语义。
- 公共接口原则：被测试使用的公共接口要么保留签名，要么在同一阶段内迁移全部调用方。
  不保留“兼容旧接口”的空壳。

## 执行规则

1. 阶段顺序 P0 → P1 → P2 → P3 → P4。每阶段内部按条目独立提交。
2. 每次提交前在 53 运行 `strict_regression`（全部 PASS）和私有环两个测试
   （0 WARNING/ERROR/FATAL）。P0 之后私有环测试进入 manifest，统一由回归覆盖。
3. 缺陷修复遵循 TDD：先写能复现的失败测试，再修复。
4. 纯删除条目以“删除前后回归一致”为验收，并附 grep 证据（无剩余引用）。

## P0：缺陷修复

| 编号 | 缺陷 | 位置 | 复现测试 |
|---|---|---|---|
| P0.1 | dataplane 引擎路径不通知设备：`submit_packet` 无 kick；RX refill 调 `vq.kick()`，split/packed 的 `kick()` 只计数不发 TLP | `virtio_tx_engine.sv`、`virtio_rx_engine.sv:202`、`split_virtqueue.sv:385`、`packed_virtqueue.sv:410` | 经 `function.dataplane` 发送后 transport 桩记录到 kick（当前为 0） |
| P0.2 | MQ 扩容后数据队列与 control VQ 编号冲突：ctrl VQ 放在 `num_pairs*2`，`do_configure_mq` 扩容时在同一编号 `setup_queue` | `virtio_atomic_ops.sv:877`、`virtio_auto_fsm.sv:1132` | 1 对扩到 2 对后 ctrl VQ 与 RX1 不同号；按规范 ctrl VQ 位于 `2*max_virtqueue_pairs` |
| P0.3 | `ctrl_send` 不检查 `mem.alloc` / `map_for_host` 失败 | `virtio_atomic_ops.sv:1678-1705` | 注入分配失败：返回失败、无映射泄漏 |
| P0.4 | 私有环测试不在回归内 | `scripts/test_manifest.sh`、`filelists` | 两个测试进入 manifest 并通过 |

P0.1 的修复方式与 P2.1 一致（引擎委托 ops），因此 P0.1 直接按 P2.1 的委托方案实现，
P2.1 只负责删除被替代的旧代码。

## P1：纯删除（不改动已维护测试的行为）

| 编号 | 删除内容 | 约行数 | 证据 |
|---|---|---|---|
| P1.1 | `src/seq/**`（base/scenario/virtual 共 33 个文件）、`virtio_virtual_sequencer`、env 的 `v_seqr` 装配 | 2,850 | 无测试/示例引用；`virtio_dut_caps_test` 中对 virtual sequencer 的引用一并删除 |
| P1.2 | 无调用的错误注入：transport `inject_status_error/inject_feature_error/inject_queue_setup_error`，bar accessor `read_reg_with_error/write_reg_with_error`，notification manager `inject_spurious_interrupt/inject_missed_interrupt/inject_wrong_vector` | 330 | 定义以外 0 引用 |
| P1.3 | 回调钩子：`virtio_dataplane_callback`、`virtio_scoreboard_callback`、`virtio_coverage_callback`、`set_dataplane_callback`、`register_custom_coverage`、scoreboard `custom_checker`、引擎内 `custom_cb` 分支 | 150 | 从未赋值 |
| P1.4 | `virtio_failover_manager` 及 dataplane/pf_manager 中的持有与打印 | 250 | 仅 `get_status_string` 被打印引用 |
| P1.5 | 未调用的 offload：TSO/USO `segment()` 及其私有辅助、重复的 `recalc_ip_checksum`、csum `prepare_tx_csum` 与 offload 包装；`needs_uso/get_all_hdr_len` 并入 TSO 的 GSO 头长度辅助 | 450 | 维护测试只用 `needs_tso/get_gso_type/calc_csum_*/rss_*` |
| P1.6 | env 附件中未调用的方法：dynamic_reconfig 的 `live_mtu_change/live_irq_mode_switch/live_mac_change/live_vlan_update/live_rss_update`，concurrency 的 `inject_race_window/test_flr_isolation/test_queue_reset_isolation`，scoreboard `check_config_consistency` | 480 | 0 调用；保留 `live_mq_resize`、qpair 查询、`parallel_vf_op/parallel_traffic` |
| P1.7 | 零散死方法：monitor `broadcast_*` 与三个 `check_*`，reg backend `bind_host_root/calc_mem_transfer/wait_for_completion/payload_value`，cap manager `get_isr_bar/get_isr_bar_offset/all_mandatory_caps_found`，split `read_avail_16/write_used_16/read_desc_flags`，packed `read_packed_desc_flags`，atomic ops `claim_/validate_restored_indirect_ownership`，iova proxy `set_direct_gpa_mode`；IOMMU 五个无调用的 dirty/live 查询及仅被它们使用的 `_for_host` 变体 | 300 | 定义以外 0 引用 |
| P1.8 | `virtio_base_test`（无派生、不在 manifest）；RX `RX_MODE_BIG/RX_MODE_SMALL`（无人设置 `buf_mode`） | 160 | 0 引用 |
| P1.9 | 文档纠错：README/手册中的文件与行数、“依赖阻断编译”、split/packed 行数、不存在的 `virtio_cpl_bridge/virtio_rc_driver_shim`（实为 `virtio_tlm_completion_adapter/virtio_tlm_rc_driver_shim`）、已删除的 sequence 库描述 | — | — |

## P2：去重（测试改调用方式，行为不变）

### P2.1 dataplane 引擎委托 atomic ops

- 规范路径为 `virtio_atomic_ops.tx_submit/rx_refill/rx_receive`。
- `virtio_tx_engine.submit_packet` 与 `virtio_rx_engine.refill/receive` 改为薄适配：
  构造 header 后调用 ops；删除引擎内的 buffer tracker、chain builder、`receive_mergeable/receive_single_buf/custom_receive`。
- `build_net_hdr`（csum/GSO/hash 字段推导）移到 `virtio_net_hdr_util` 静态函数，引擎与调用方共用。
- `dpu_priv_dataplane` 的覆盖随之简化为仅选择私有 ops。
- 受影响测试：`virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、私有环流程测试。

### P2.2 virtqueue 公共逻辑上移

- `dma_map_buf/dma_unmap_buf`、`inject_desc_error`、`kick()`、`free_rings/reset_queue/detach_all_unused`
  的公共前段移入 `virtqueue_base`；日志标签用 `protected string log_tag`。
- `save_state/restore_state` 保留在各格式中，只共享快照头赋值。
- custom 队列使用基类实现，不再复制。

### P2.3 atomic ops 内部去重

- 新增 `virtio_dma_buffer_set`：负责一次提交涉及的 alloc → write → map → 失败回滚 → retire，
  替换 `tx_submit`、`rx_refill`、`admin_vq_submit`、`ctrl_send` 中手写的清理代码。
- 新增 `kick_with_fault(vq, qid)`：封装 PRE_NOTIFY → `transport.kick(next_idx, wrap)` → POST_NOTIFY，替换 4 处复制。

### P2.4 env 绑定统一

- `bind_pcie` 与 `bind_pcie_endpoints` 共用受保护的 `bind_all(endpoint_plan[$])`，统一 preflight、
  重复检查、单点回滚和提交；`bind_pcie` 只负责构造单 domain 的计划。公共签名不变。
- `preflight_function_pcie/bind_function_pcie` 的空值检查与 config_db 查询合并。

### P2.5 function instance 绑定入口统一

- 保留 `preflight_bind_pcie`、`commit_bind_pcie`、`cancel_bind_pcie` 三个入口；
  `wire_shared`、`bind_pcie` 改为一行包装；删除 `bind_pcie_components`，调用方迁移。
- driver 工厂选择只在 `prepare_driver_candidates` 中出现一次。

### P2.6 snapshot 只校验一次

- env 构建不可变的 `vio_snapshot_ctx`（device snapshot、resource snapshot、resource manager），
  校验 frozen/引用/seeded 后向下传递；pf/function/resource_client/vf 删除各自的重复校验。
- `resource_client.bind_to_service` 每个 Function 只调用一次。

### P2.7 transport 去掉第二条 init 路径

- 删除 `virtio_pci_transport.full_init_sequence`；fixture 改走 `auto_fsm.full_init` 或 ops 的单步接口。
- 职责：FSM 负责时序，ops 负责单步与队列，transport 只提供寄存器访问。

### P2.8 测试公共件

- `tests/virtio_vq_test_kit.sv`：`make_split/make_packed/make_ops/complete_split_at/complete_packed`，
  替换约 45 处组件创建、108 处赋值和散落的完成写回。
- `tests/virtio_mock_transport.sv`：kick 计数与最后一次参数、可编程状态与复位完成，
  替换 4 个测试内的 transport 子类。
- `virtio_perf_monitor_ext` 的运行时重配并入 `virtio_perf_monitor.configure_bw()`。

## P3：接入点（策略对象，代码迁移为主）

| 策略 | 取代的分支 | 实现 |
|---|---|---|
| `virtio_execution_profile` | fixture 内 16 处 `execution_mode` 判断 | MODEL / REAL_DUT：选择 PCIe 接口模式、responder、DMA 适配 |
| `virtio_discovery_strategy` | `auto_fsm.sv:779`、`transport.sv:846` 及 bar accessor 中的 fabric 判断 | enumerate / fabric_preconfigured；后续设计新增 verify_snapshot |
| `virtio_config_backend` | atomic ops 直接调用 transport common-config；私有 ops 覆盖的 setup/teardown/reset | virtio_common_cfg（现行行为）；后续设计新增 af_direct |
| `virtio_driver_protocol` | `virtio_driver`、`function_instance`、私有 FSM 中的 `$cast` 与 `private_cfg != null` 判断 | standard / dpu_priv：`kick`、`poll`、`reset`、`allows_status_access()` |
| `fabric_bar_layout` | bar accessor 与 transport 两处写死的 BAR0/2/4 角色 | 由 snapshot 的 `dpu_bar_pair_lease_t` 构造 |

同时拆分大类（移动代码，不改行为）：

- `virtio_auto_fsm` 的迁移相关代码（checksum、校验、freeze/restore，约 1,150 行）移入
  `virtio_migration_engine`；`do_configure_mq` 复用 ops 的 `setup_queue_range()`。
- `virtio_atomic_ops` 按职责拆为 lifecycle、queue、datapath、ctrl_admin、migration_ownership 文件，
  对外仍是同一个类（`include` 拆分），子类 `dpu_priv_atomic_ops` 不受影响。

## P4：遗留路径迁移

| 编号 | 内容 | 迁移的测试 |
|---|---|---|
| P4.1 | IOMMU 旧版非 host 接口（`map/unmap/translate/map_fixed/write_from_device/begin_/capture_dirty_generation`）与 host0 标量双写 | unit、admin_vq、indirect_desc、migration_dirty、stress_unit 改用 `*_for_host(0, ...)` |
| P4.2 | 非 fabric BAR 枚举 `enumerate_bars` 与 transport 的非 fabric 分支 | full_integration、dual 改走 fabric 流程（snapshot 生成端点镜像），删除测试内 `setup_ep_virtio_config` |
| P4.3 | standalone/host0 兼容路径（function instance、transport、atomic ops、auto_fsm） | dut_caps、unit |

P4.2 完成后 `virtio_discovery_strategy` 只剩 fabric_preconfigured（及后续 verify_snapshot）。

## 验收标准

- 每个提交：`strict_regression` 全 PASS；私有环测试（P0.4 后在回归内）0 WARNING/ERROR/FATAL。
- P0 每项有在修复前失败、修复后通过的测试。
- P1 每项附删除后 grep 无残留引用的证据。
- 全部完成后统计 src/tests 行数变化，与估算（P1 约 5,000、P2 约 2,000、P4 约 600）对照记录。
- README 与手册描述与代码一致。

## 风险

- `virtio_real_driver_flow_fixture`（1,244 行）同时受 P2.7、P3 execution_profile 影响，改动集中在一个阶段完成，避免反复修改。
- P2.1 改变引擎内部实现；以 indirect_desc、net_packet_multi_queue 与私有环流程测试的字节级比对保证等价。
- P4.2 改变两个大测试的设备建模方式；如回归出现非等价差异，先停下来确认测试意图，不修改断言迁就实现。
