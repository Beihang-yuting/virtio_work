# DPU Fabric Virtio 收敛设计

**日期：** 2026-08-07  
**基线：** `origin/feat/dpu-fabric-virtio-hardening` (`d939f08e273bb9ea63d6cf8699eb66a50d833f29`)  
**实施分支：** `feat/dpu-fabric-virtio-hardening`

## 目标

在不接入真实 DUT 的范围内，把 DPU Fabric virtio VIP 从“主体功能已实现但仍有告警、遗漏测试和超时”收敛为可重复、严格、零未处理告警的 VCS/TLM 验收版本。

本轮必须完成以下结果：

- 维护中的全部测试可由一个严格回归入口编译和运行。
- 每个测试在 180 秒墙钟内结束并生成 UVM Report Summary。
- 所有测试均为 `UVM_ERROR=0`、`UVM_FATAL=0`、未豁免 `UVM_WARNING=0`。
- 编译和运行日志没有已知 enum、fork/ref、`DT-MCEQ`、PCIe scoreboard 或资源泄漏告警。
- TLM completion adapter 对 TLM 回环可用，但 SV-interface/DUT 绑定路径不强制依赖它。
- 文档准确描述已支持能力，并明确真实 DUT 未在本轮验证。

## 范围

### 纳入范围

1. 严格回归入口和单一测试清单。
2. Monitor routing 事件与 SVA 的确定性采样。
3. E2E PCIe completion `byte_count` 正确性。
4. Host memory、IOMMU、virtqueue、Admin DMA 和普通 DMA 的资源回收。
5. TLM adapter 可选绑定。
6. Active/passive agent 绑定契约与相关 UVM 告警。
7. enum 赋值和 fork/ref 编译告警。
8. 空迁移 claim 队列的 `sort()` 告警。
9. `virtio_dual_test` 的 180 秒内完整运行。
10. smoke/traffic 测试的正式编译、运行和维护状态。
11. README、用户手册和回归说明更新。

### 不纳入范围

- 不新增或伪造 DUT RTL。
- 不把 TLM 回环结果表述为真实 DUT 合规性证明。
- 不重构与上述收敛问题无关的数据面、SR-IOV 或 Fabric 架构。
- 不自行永久豁免第三方工具告警；如确有不可修复告警，必须先提供证据并取得用户确认。

## 分支与隔离

所有变更在项目已有隔离工作树 `.worktrees/dpu-fabric-virtio-hardening` 中完成。该工作树基于远程 `d939f08`，并已包含一个领先提交：空队列调用 `sort()` 的保护修复。主工作树 `master` 不重置、不覆盖，也不接收本轮的中间修改。

实现按逻辑问题分批提交，使每一批都可独立审查和回退。

## 收敛架构

### 第一层：回归门禁

建立单一测试清单，供 Makefile、VCS 驱动脚本和 strict regression 共用，消除多处测试名单漂移。严格回归的数据流为：

```text
check-deps
  -> 编译一次全部维护测试
  -> 逐项复用 simv 运行
  -> 每项独立日志和 180 秒超时
  -> 解析退出码、UVM 统计、VCS 告警和泄漏
  -> 汇总并返回严格退出码
```

维护测试共 17 项：

1. `dpu_resource_manager_test`
2. `virtio_fabric_resource_test`
3. `virtio_unit_test`
4. `virtio_stress_unit_test`
5. `virtio_protocol_test`
6. `virtio_indirect_desc_test`
7. `virtio_admin_vq_test`
8. `virtio_migration_dirty_test`
9. `virtio_monitor_test`
10. `virtio_coverage_test`
11. `virtio_e2e_test`
12. `virtio_full_integration_test`
13. `virtio_pf_lifecycle_reset_test`
14. `virtio_monitor_routing_test`
15. `virtio_dual_test`
16. `virtio_smoke_test`
17. `virtio_traffic_test`

严格解析器将以下情况视为失败：非零进程退出码、超时、缺少日志、缺少 UVM summary、任何 UVM error/fatal、任何未捕获 UVM warning、任何未解决的 VCS `Warning-[...]`、scoreboard mismatch 或资源泄漏。

负向测试必须通过 report catcher 捕获并验证预期诊断，不允许把预期错误留在最终 UVM severity 统计中。

### 第二层：正确性

#### Monitor routing

Monitor callback 把语义事件放入 `virtio_protocol_event_if` 的 staged queue，接口在确定的时钟边界释放事件，SVA 再在后续采样边界检查。测试不得通过固定半周期延迟猜测 SVA 是否已经执行；它必须等待一个明确的“事件已释放且 SVA 已采样”边界后再读取 `protocol_error_count`。

修复应保持每个 PF/VF 使用独立 protocol event interface，不共享状态，也不通过放宽 assertion 来消除失败。

#### PCIe completion

Completion 生成端必须根据原始 request 的 length、first/last byte enable 和完成片段计算 `byte_count`、lower address 和 payload 长度。修复发生在可复用 completion/EP 响应边界，不在 scoreboard 中屏蔽 mismatch，也不在 E2E 测试里批量降级告警。

#### 可选 TLM adapter

`virtio_net_env::bind_pcie()` 继续要求有效 RC sequencer，但 TLM completion adapter 参数允许为空：

- 非空：安装并绑定 TLM 回环 completion 路径。
- 为空：跳过 TLM bridge，只完成 function、transport、driver、monitor 和 PCIe monitor 的公共接线。

新增无 adapter 的聚焦测试，证明调用不会 fatal，且所有 active PF/VF 仍获得正确的公共绑定。

### 第三层：资源和告警

#### 资源所有权

每次分配都由明确的生命周期所有者登记：queue ring、packet buffer、normal DMA、Admin DMA 和间接描述符表分别由创建它们的组件负责回收。Teardown 必须幂等：重复 shutdown/report 不得二次 free/unmap，也不得遗留有效记录。

E2E 在进入 report phase 前显式完成 function/queue teardown。最终 `host_mem.leak_check()`、`iommu.leak_check()` 和 `virtqueue_manager::leak_check()` 都必须报告零 outstanding resource。

#### Agent 模式

Agent 配置明确区分 active 和 passive：

- active agent 在开始产生事务前必须具备 ops、FSM 和 sequencer 绑定，缺失时是错误。
- passive observer/monitor 不要求 ops/FSM，不产生“driver will not function”类告警。

测试不得仅为安静日志而关闭实际需要运行的 active agent。

#### 编译告警

- enum 字段使用正确 enum 常量或显式目标类型 cast。
- fork 分支只写入对象拥有的内部结果，不直接访问调用者传入的 `ref` 数组或标量；join 后再复制给调用者。
- 迁移 claim 队列只有在元素数大于 1 时调用 `sort()`。

### 第四层：Dual 性能

先使用日志和仿真统计定位 10 Gbps 阶段的墙钟热点，优先消除不必要的逐包等待、重复拷贝和线性扫描，不改变带宽控制语义。

如果原始长压力规模仍不适合作为常规回归，则提供显式 plusarg 选择长压力规模；strict regression 使用有统计意义的有界规模，并继续覆盖：

- 双向等量流量；
- 非对称流量；
- 多 function 隔离；
- unlimited 与 10 Gbps 限速差异；
- throttle event 和公平性断言；
- 最终资源清理与 UVM summary。

strict 配置必须在 VCS 主机上 180 秒内完成。长压力模式作为可选扩展，不替代 strict 验收。

### 第五层：Smoke、Traffic 与文档

`virtio_smoke_test` 和 `virtio_traffic_test` 纳入正式 filelist、脚本接受名单和 strict suite。过期 API 按当前环境、queue 和资源生命周期接口迁移；traffic 默认工作量必须确定且有界。

README 和手册更新为实际状态：Indirect、Admin VQ、dirty-page migration 和 SVA 已实现；列出 17 项 strict suite、180 秒单测上限、TLM adapter 可选语义，以及真实 DUT 未验证的边界。

## TDD 与验证顺序

每个问题执行独立 RED-GREEN-REFACTOR 循环：

1. 保留或新增最小复现测试。
2. 在精确基线上运行，确认因目标问题失败，而不是编译或测试夹具错误。
3. 实施最小生产代码修复。
4. 运行聚焦测试确认 GREEN。
5. 运行受影响的相邻回归。
6. 仅在全部绿色后整理实现并提交。

已知 RED 证据如下：

| 问题 | RED 证据 |
|---|---|
| Monitor routing | `virtio_monitor_routing_test` 产生 1 个 UVM fatal |
| E2E completion | 27 次 completion `byte_count` mismatch |
| E2E teardown | 19 个 host-memory block、20,764 字节未释放 |
| Optional adapter | 当前 `bind_pcie()` 对空 adapter 直接 fatal |
| Dual | 180 秒超时且无 UVM summary |
| Smoke/traffic | 未进入 filelist，脚本拒绝测试名 |
| Compile | enum 与 fork/ref `Warning-[...]` |
| Migration | 空 claim queue 产生 `DT-MCEQ` |

## 最终验收

最终验证只在 `ubuntu@10.11.10.53` 上通过 bash login shell 执行，以使用指定 VCS 路径和 license 环境。验收必须同时满足：

- `make check-deps` 成功，子模块 SHA 与仓库固定值一致。
- 全量 VCS 编译成功，目标编译告警计数为零。
- 17 项 strict suite 全部在单项 180 秒内结束。
- 每项都有 UVM summary，且 error/fatal/未捕获 warning 均为零。
- migration 中 `DT-MCEQ=0`。
- PCIe scoreboard mismatch 为零。
- host memory、IOMMU、virtqueue 泄漏为零。
- dual 完成 10 Gbps 阶段和最终 summary。
- strict regression 总退出码为零。
- 工作树只包含本轮设计和实现相关变更。

上述结果证明 VIP 的 VCS/TLM 自测收敛，不证明任何真实 DUT 的 virtio 或 PCIe 合规性。
