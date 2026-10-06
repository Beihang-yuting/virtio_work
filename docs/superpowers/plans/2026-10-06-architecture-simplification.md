# Virtio VIP 架构简化 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 修复审计发现的缺陷，删除无调用代码，合并重复实现，引入策略接入点，迁移遗留路径，全程保持维护回归通过。

**Architecture:** 按 P0（缺陷）→ P1（纯删除）→ P2（去重）→ P3（策略接入点与大类拆分）→ P4（遗留路径迁移）顺序执行。每个任务独立提交，提交前在 53 主机跑完整 `strict_regression`。缺陷与行为变更先写失败测试；删除附 grep 证据。

**Tech Stack:** SystemVerilog / UVM 1.2，Synopsys VCS W-2024.09-SP1（53 主机），外部依赖 dpu_common `4d73996`、host_mem `35ec087`、net_packet（master）、pcie_work（main）、queue_work。

**Spec:** `docs/superpowers/specs/2026-10-06-architecture-simplification-design.md`

## Global Constraints

- 起点：`62ae3e9`（master，工作树干净）。不修改 dpu_common、pcie_work、host_mem、net_packet、queue_work。
- 编辑在 59 `~/workspace/ryan/virtio_work`；仿真在 53 `~/virtio_priv_run/virtio_work`（依赖已对齐，env 脚本 `~/virtio_priv_run/env.sh`）。
- SYNC（59 仓库根目录执行）：`rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/`
- 单测：`ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && mkdir -p logs && TEST=<test_name> ./scripts/vcs.sh > logs/<test_name>.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/<test_name>.log | tail -20'`
- 回归：`ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'`，期望 `STRICT_REGRESSION PASS tests=<N>`。
- 回归测试数：起点 37；P0-1 后 39（私有环两个测试进入 manifest）；P0-2 后 40（新增 `virtio_ctrl_vq_test`）；此后各任务不再增加 manifest 条目。
- 私有环测试：P0-1 之前用 `~/virtio_priv_run/run_priv.sh <tag>`；P0-1 删除 `examples/dpu_priv_ring/run_vcs.sh` 后改用上面的单测命令（`TEST=dpu_priv_driver_flow_test` / `dpu_priv_ring_contract_test`），并由回归覆盖。
- VCS 约束：`ref` 形参之后的形参同为 ref，传变量而非字面量；块内声明须在语句之前。
- 提交：Conventional Commits，中文描述；不加 Co-Authored-By；不 push。
- 公共接口：被测试使用的接口要么保持签名，要么在同一任务内迁移全部调用方；不留兼容空壳。
- 行为非等价：若回归出现不等价差异，停下确认测试意图，不修改断言迁就实现。
- 文档：`scripts/test_manifest.sh` 在每个测试前校验 README/手册中的测试列表，修改测试列表或文档时同步更新。

## Review Focus

1. **REAL_DUT 执行模式**：回归全部运行在 MODEL 模式；P3-1 改变执行主体选择，P2-7 改变 fixture 初始化。期望 REAL_DUT 配置仍选择 SV 接口、被动 EP、无模型 responder。由 P3-1 Step 1 在 `virtio_execution_mode_test` 中断言 REAL_DUT 策略的各项能力。
2. **非连续队列号**：control VQ 位于 `2*max_virtqueue_pairs` 时数据队列与 ctrl VQ 不连续。期望迁移 freeze/restore 与 MSI-X 绑定覆盖实际队列集合。由 P0-2（编号）与 P3-9（迁移与 MSI-X）在 `virtio_ctrl_vq_test` 中覆盖。
3. **DMA 失败回滚**：`virtio_dma_buffer_set` 替换四条提交路径的手写清理。期望任一步分配/映射失败后无泄漏映射、无残留所有权记录。由 P0-3（ctrl_send）与 P2-3b（单元测试，单页 IOVA 窗口强制映射失败）覆盖，P2-3c/3d 跑 indirect_desc/admin_vq/unit/stress_unit/migration_dirty。
4. **packed 回绕下的通知**：`kick_with_fault` 收敛四处通知。期望 packed 回绕后通知参数为下一槽与翻转后的 wrap。由 `virtio_indirect_desc_test::test_atomic_notify_cursor`（已在 20f7630）在 P2-3a 回归中覆盖。
5. **私有环与标准 Function 共存**：P2-1 删除私有 dataplane、P3-3/P3-4 引入后端与协议对象。期望同一 Host 下私有 VF 与标准 VF 各自收发、停机回收互不影响。由 `dpu_priv_driver_flow_test`（P0-1 起在回归内）覆盖。

## 执行顺序

P0-1 → P0-2 → P0-3 → P0-4 → P0-5 →
P1-1 → … → P1-9 →
P2-1 → P2-2a → P2-2b → P2-3a → P2-3b → P2-3c → P2-3d → P2-4 → P2-5 → P2-6 → P2-7 → P2-8a → P2-8b → P2-8c →
P3-1 → P3-2 → P3-3 → P3-4 → P3-5 → P3-6 → P3-7 → P3-9 → P3-8 →
P4-1 → … → P4-9

依赖要点：P2-1 依赖 P0-4/P0-5 与 P1-3/P1-8；P2-5、P2-8 依赖 P2-1；P2-8b 依赖 P2-8a；P2-8c 在 P2-5 之后（同改 dual 测试）；P3-9 依赖 P0-2、P3-3、P3-6；P3-8 最后执行（纯移动代码）；P4-4/P4-5 依赖 P4-3；P4-6 依赖 P3-2 与 P4-4/P4-5；P4-9 有显式确认点。

各阶段末尾的 “Notes for integrator” 记录了该阶段产出的接口、偏离规范之处与风险，执行相关任务前先阅读。

---
## P0：缺陷修复

执行顺序：P0-1（规范 P0.4）→ P0-2（P0.2）→ P0-3（P0.3）→ P0-4、P0-5（P0.1，按 P2.1 的委托方案实现）。
所有行号均以 HEAD `62ae3e9` 为准；同一文件被前序任务修改后，以给出的 old 片段文本定位。

---

### Task P0-1: 私有环两个测试进入维护回归（规范 P0.4）

**Files:**
- Modify: `scripts/test_manifest.sh:22-60`（`VIRTIO_MAINTAINED_TESTS` 末尾追加两项）
- Modify: `filelists/tests.f:49-50`（在 `virtio_tb_top.sv` 前加入三个示例源文件）
- Modify: `examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv:1,407-414`（删除私有顶层 `dpu_priv_ring_tb_top`）
- Modify: `examples/dpu_priv_ring/README.md:121-125`（运行方式改为 `scripts/vcs.sh`）
- Modify: `examples/virtio_system_env/virtio_system_env_example_test.sv:1,11-13`（头注释）
- Modify: `examples/virtio_system_env/run_vcs.sh:2-4,44`（不再追加 `example.f`）
- Modify: `README.md:397-401,427-431`；`docs/virtio_net_vip_manual.md:2066-2068`；`docs/virtio_verification_flow.md:69-70`
- Delete: `examples/dpu_priv_ring/run_vcs.sh`、`examples/dpu_priv_ring/example.f`、`examples/virtio_system_env/example.f`
- Test: `dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`（经 `scripts/vcs.sh`/`strict_regression.sh`）

**Interfaces:**
- Consumes: `scripts/test_manifest.sh` 的 `VIRTIO_MAINTAINED_TESTS`、`_validate_documentation_contracts`（要求 README 与手册中的清单与 manifest 同序同数）。
- Produces: 回归 simv（top `virtio_tb_top`）包含 `virtio_system_env_example_test`、`dpu_priv_ring_contract_test`、`dpu_priv_driver_flow_test` 三个类；之后私有环测试一律用 `TEST=<name> ./scripts/vcs.sh` 或 `strict_regression.sh` 运行。

设计说明：`dpu_priv_driver_flow_test` 继承 `virtio_system_env_example_test`，因此示例文件必须一起编入 `tests.f`。
`dpu_priv_ring_tb_top`（`dpu_priv_ring_contract_test.sv:409-413`）只做 `run_test("dpu_priv_ring_contract_test")`；
`virtio_tb_top` 的 `run_test()` 由 `+UVM_TESTNAME` 选择测试，额外发布的协议事件接口只在 env 执行 PCIe 绑定时才取用
（`virtio_net_env.sv:1014`），这两个测试此前在没有这些接口的顶层下通过，说明不走该路径。所以统一用 `virtio_tb_top`，
删除私有顶层和冗余的 `examples/dpu_priv_ring/run_vcs.sh`、`example.f`。`virtio_system_env_example_test.sv` 进入 `tests.f`
后，`examples/virtio_system_env/example.f` 会造成重复编译（虽有 include guard），一并删除并让其 `run_vcs.sh` 只用 `tests.f`。

- [ ] **Step 1: 确认当前不可经维护入口运行（red）**

  SYNC：`rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/`
  ```bash
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=dpu_priv_driver_flow_test ./scripts/vcs.sh; echo rc=$?'
  ```
  期望输出：`unsupported TEST: dpu_priv_driver_flow_test` 与 `rc=2`。

- [ ] **Step 2: manifest 追加两项**

  `scripts/test_manifest.sh` old：
  ```bash
    virtio_pcie_host_mem_test
    dpu_pcie_tl_executor_integration_test
  )
  ```
  new：
  ```bash
    virtio_pcie_host_mem_test
    dpu_pcie_tl_executor_integration_test
    dpu_priv_driver_flow_test
    dpu_priv_ring_contract_test
  )
  ```

- [ ] **Step 3: `filelists/tests.f` 编入示例源文件**

  old（49-50 行）：
  ```
  virtio_net_vip/tests/dpu_pcie_tl_executor_integration_test.sv
  virtio_net_vip/tests/virtio_tb_top.sv
  ```
  new：
  ```
  virtio_net_vip/tests/dpu_pcie_tl_executor_integration_test.sv
  // 私有环流程测试继承多 Host 示例环境，示例文件须先于两个私有环测试编译；
  // 示例测试类本身不在维护清单中，仍由 examples/virtio_system_env/run_vcs.sh 运行。
  examples/virtio_system_env/virtio_system_env_example_test.sv
  examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv
  examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv
  virtio_net_vip/tests/virtio_tb_top.sv
  ```

- [ ] **Step 4: 删除合同测试的私有顶层**

  `examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv` 第 1 行 old：
  ```systemverilog
  // 目录层次：examples/dpu_priv_ring；显式 filelist 编译的 DPU 私有环合同测试。
  ```
  new：
  ```systemverilog
  // 目录层次：examples/dpu_priv_ring；由 filelists/tests.f 编入维护回归的 DPU 私有环合同测试。
  ```
  文件尾 old：
  ```systemverilog
  endclass

  // 最小仿真顶层只启动本示例测试；不依赖默认 tests.f 或 virtio_tb_top。
  module dpu_priv_ring_tb_top;
      import uvm_pkg::*;

      initial run_test("dpu_priv_ring_contract_test");
  endmodule

  `endif
  ```
  new：
  ```systemverilog
  endclass

  `endif
  ```

- [ ] **Step 5: 删除冗余脚本与 filelist，更新 virtio_system_env 示例脚本/注释**

  ```bash
  git rm examples/dpu_priv_ring/run_vcs.sh examples/dpu_priv_ring/example.f examples/virtio_system_env/example.f
  ```
  `examples/virtio_system_env/run_vcs.sh` 2-4 行 old：
  ```bash
  # 目录层次：examples/virtio_system_env。仅在显式调用时追加示例 filelist，
  # 不修改默认 VCS 入口和维护回归清单。依赖仓库脚本完成依赖校验，编译产物
  # 保存在 build/examples/virtio_system_env；脚本不持有外部依赖的生命周期。
  ```
  new：
  ```bash
  # 目录层次：examples/virtio_system_env。示例源文件已随 filelists/tests.f 编译
  # （私有环流程测试继承它），本脚本只负责运行不在维护清单中的示例测试。依赖仓库
  # 脚本完成依赖校验，编译产物保存在 build/examples/virtio_system_env。
  ```
  44 行删除：
  ```bash
    -f "$example_dir/example.f" \
  ```
  （删除后 `-f "$root_dir/filelists/tests.f" \` 直接接 `-top virtio_tb_top -o "$simv"`。）

  `examples/virtio_system_env/virtio_system_env_example_test.sv` 第 1 行 old：
  ```systemverilog
  // 目录层次：examples/virtio_system_env，仅由示例 filelist 显式编译，不进入默认 VIP 包。
  ```
  new：
  ```systemverilog
  // 目录层次：examples/virtio_system_env，经 filelists/tests.f 编译（私有环流程测试继承它），不进入默认 VIP 包。
  ```
  11-13 行 old：
  ```systemverilog
  // Example-local top-level configuration, environment, and executable test.
  // Compile this file explicitly after virtio_net_pkg; it is not part of the
  // default VIP package or maintained regression filelist.
  ```
  new：
  ```systemverilog
  // Example-local top-level configuration, environment, and executable test.
  // filelists/tests.f compiles it after virtio_net_pkg because the private-ring
  // flow test extends it; the example test itself is not a maintained test.
  ```

- [ ] **Step 6: 更新文档（清单与示例运行方式）**

  `README.md` 397-401 行 old：
  ```markdown
  `virtio_traffic_test`、`virtio_net_packet_multi_queue_test`、
  `virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、
  `virtio_real_driver_rx_test`、
  `host_mem_random_test`、`virtio_pcie_host_mem_test` 和
  `dpu_pcie_tl_executor_integration_test`，共 37 项。
  ```
  new：
  ```markdown
  `virtio_traffic_test`、`virtio_net_packet_multi_queue_test`、
  `virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、
  `virtio_real_driver_rx_test`、
  `host_mem_random_test`、`virtio_pcie_host_mem_test`、
  `dpu_pcie_tl_executor_integration_test`、`dpu_priv_driver_flow_test` 和
  `dpu_priv_ring_contract_test`，共 39 项。
  ```
  `README.md` 427-431 行 old：
  ```markdown
  [`virtio_system_env_example_test.sv`](examples/virtio_system_env/virtio_system_env_example_test.sv)
  把 `virtio_system_env_config`、`virtio_system_env` 和测试类放在同一个示例文件中，
  演示怎样自行装配多 Host 环境。这两个类仅用于示例，不属于默认 VIP API，也不进入
  默认 filelist。需要运行时，使用示例目录下的
  [`run_vcs.sh`](examples/virtio_system_env/run_vcs.sh) 显式编译。
  ```
  new：
  ```markdown
  [`virtio_system_env_example_test.sv`](examples/virtio_system_env/virtio_system_env_example_test.sv)
  把 `virtio_system_env_config`、`virtio_system_env` 和测试类放在同一个示例文件中，
  演示怎样自行装配多 Host 环境。这两个类仅用于示例，不属于默认 VIP API；因为
  `dpu_priv_driver_flow_test` 继承它，示例文件随 `filelists/tests.f` 编译，但示例测试
  不在维护清单中。需要运行时，使用示例目录下的
  [`run_vcs.sh`](examples/virtio_system_env/run_vcs.sh)。
  ```
  `docs/virtio_net_vip_manual.md` 2066-2068 行 old：
  ```markdown
  `host_mem_random_test`、
  `virtio_pcie_host_mem_test` 和 `dpu_pcie_tl_executor_integration_test`，
  共 37 项。该入口
  ```
  new：
  ```markdown
  `host_mem_random_test`、
  `virtio_pcie_host_mem_test`、`dpu_pcie_tl_executor_integration_test`、
  `dpu_priv_driver_flow_test` 和 `dpu_priv_ring_contract_test`，
  共 39 项。该入口
  ```
  `docs/virtio_verification_flow.md` 69-70 行 old：
  ```markdown
  演示多 Host 的一种装配方式。这两个类不属于默认 VIP API，也不进入默认 filelist；
  需要运行时使用 [`run_vcs.sh`](../examples/virtio_system_env/run_vcs.sh) 显式编译示例。
  ```
  new：
  ```markdown
  演示多 Host 的一种装配方式。这两个类不属于默认 VIP API；私有环流程测试继承它，
  因此示例文件随 `filelists/tests.f` 编译，但示例测试不在维护清单中，需要运行时使用
  [`run_vcs.sh`](../examples/virtio_system_env/run_vcs.sh)。
  ```
  `examples/dpu_priv_ring/README.md` 121-125 行 old：
  ````markdown
  ```bash
  ./examples/dpu_priv_ring/run_vcs.sh
  # 默认运行 dpu_priv_driver_flow_test；换成字节合同测试：
  TEST=dpu_priv_ring_contract_test ./examples/dpu_priv_ring/run_vcs.sh
  ```
  ````
  new：
  ````markdown
  两个测试已列入 `scripts/test_manifest.sh`，与其他维护测试共用 `filelists/tests.f`
  和 `virtio_tb_top` 编译，`make regression` 会运行它们。单独运行：

  ```bash
  TEST=dpu_priv_driver_flow_test ./scripts/vcs.sh
  TEST=dpu_priv_ring_contract_test ./scripts/vcs.sh
  ```
  ````

- [ ] **Step 7: grep 证据（无残留引用）**

  ```bash
  grep -rn "dpu_priv_ring_tb_top\|dpu_priv_ring/run_vcs\|dpu_priv_ring/example\.f\|virtio_system_env/example\.f" --exclude-dir=.git --exclude-dir=superpowers .
  ```
  期望：空输出。

- [ ] **Step 8: SYNC 并单测两个私有环测试**

  SYNC 后：
  ```bash
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=dpu_priv_driver_flow_test ./scripts/vcs.sh > logs/dpu_priv_driver_flow_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/dpu_priv_driver_flow_test.log | tail -20'
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=dpu_priv_ring_contract_test ./scripts/vcs.sh > logs/dpu_priv_ring_contract_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/dpu_priv_ring_contract_test.log | tail -20'
  ```
  期望：每个日志仅三行 `UVM_WARNING :    0`、`UVM_ERROR :    0`、`UVM_FATAL :    0`。
  再确认 `grep -c "Warning-\[" logs/dpu_priv_driver_flow_test.log` 输出 `0`（严格回归拒绝 VCS warning）。
  若编译报告 wildcard import 二义性（示例文件此前从未与 `tests.f`、`queue_work_integration.f` 同编译），在示例文件中把
  冲突标识符改成 `pkg::name` 限定引用，不改测试逻辑。

- [ ] **Step 9: 回归**

  ```bash
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
  ```
  期望：第一条 grep 无输出；末行 `STRICT_REGRESSION PASS tests=39`。
  另确认示例脚本仍可用：
  ```bash
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./examples/virtio_system_env/run_vcs.sh > logs/sysenv.log 2>&1; grep -E "UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/sysenv.log'
  ```
  期望三项均为 0。

- [ ] **Step 10: 提交**

  ```bash
  git add scripts/test_manifest.sh filelists/tests.f \
    examples/dpu_priv_ring/dpu_priv_ring_contract_test.sv examples/dpu_priv_ring/README.md \
    examples/virtio_system_env/virtio_system_env_example_test.sv examples/virtio_system_env/run_vcs.sh \
    README.md docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md
  git commit -m "test: 私有环流程与合同测试进入维护回归"
  ```
  （三个已删除文件已由 Step 5 的 `git rm` 暂存。）

---

### Task P0-2: control VQ 按 2*max_virtqueue_pairs 编号（规范 P0.2）

**缺陷确认：** `virtio_atomic_ops.sv:872-881` 在协商 `CTRL_VQ` 时把 control VQ 建在 `num_pairs*2`；
`virtio_auto_fsm.sv:1131-1149` 的 `do_configure_mq` 扩容时对 `i*2`（i 从旧 `active_num_pairs` 开始）调用
`setup_queue`，1→2 对时 `setup_queue(2)` 命中已存在的 control VQ：`virtqueue_manager.create_queue`
（`virtqueue_manager.sv:69-74`）报 `create_queue: queue_id=2 already exists` 并返回旧队列，随后重新分配环并覆盖
`ring_iovas[2]`。缺陷真实存在。virtio 1.2 §5.1.2：协商 `VIRTIO_NET_F_MQ` 时 controlq 编号为
`2*max_virtqueue_pairs`（设备 config 偏移 8，`virtio_pci_transport.sv:361-363`），否则为 2。

**Spec deviation:** 规范把 `virtio_auto_fsm.sv:1132` 列为位置之一；修复后 control VQ 不再与任何数据队列同号，
`do_configure_mq` 的按对建队逻辑本身正确，无需改 FSM。修复只在 `setup_all_queues`。

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:844-875`（`setup_all_queues`）
- Create: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`
- Modify: `filelists/tests.f:27`、`scripts/test_manifest.sh:40`、`README.md:393`（及 P0-1 改过的计数行）、`docs/virtio_net_vip_manual.md:2059`（及计数行）
- Test: `virtio_ctrl_vq_test`

**Interfaces:**
- Consumes: `virtio_pci_transport::read_net_config(ref virtio_net_device_config_t cfg)`（`virtio_pci_transport.sv:587`）、
  `virtio_auto_fsm::configure_mq/bind_mq_pair_limit`、`virtio_atomic_ops::setup_queue/setup_all_queues/teardown_queue/ctrl_set_mq_pairs`。
- Produces: 新维护测试 `virtio_ctrl_vq_test`（P0-3 继续在其中追加子测试）及其测试件类
  `virtio_ctrl_vq_test_transport`、`virtio_ctrl_vq_test_mq_ops`、`virtio_ctrl_vq_test_mem`、`virtio_ctrl_vq_test_iommu`、
  `virtio_ctrl_vq_test_catcher`。`setup_all_queues` 新行为：仅当 `CTRL_VQ` 与 `MQ` 都协商时读一次设备 net config。

- [ ] **Step 1: 写失败测试 `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`**

  ```systemverilog
  `ifndef VIRTIO_CTRL_VQ_TEST_SV
  `define VIRTIO_CTRL_VQ_TEST_SV

  import uvm_pkg::*;
  `include "uvm_macros.svh"
  import virtio_net_pkg::*;

  // 目录层次：tests/。control VQ 编号与 ctrl_send 资源回滚的聚焦回归。不建 PCIe 通路，
  // 寄存器桩 transport 只记录建队与通知；建队、DMA 映射与回滚全部走生产 atomic ops。
  // 测试拥有全部 Host memory/IOMMU/队列对象，每个子测试结束时拆除并检查泄漏。

  // 寄存器桩：common-config 访问只记录、不发 TLP；read_net_config 返回可编程的
  // max_virtqueue_pairs，用于验证 controlq 按 2*max_virtqueue_pairs 编号。
  class virtio_ctrl_vq_test_transport extends virtio_pci_transport;
      `uvm_object_utils(virtio_ctrl_vq_test_transport)

      int unsigned max_virtqueue_pairs;
      int unsigned net_config_reads;
      int unsigned kick_count;
      int unsigned programmed_qids[$];

      function new(string name = "virtio_ctrl_vq_test_transport");
          super.new(name);
          max_virtqueue_pairs = 1;
          net_config_reads = 0;
          kick_count = 0;
      endfunction

      virtual task read_net_config(ref virtio_net_device_config_t cfg);
          net_config_reads++;
          cfg = '{default: 0};
          cfg.max_virtqueue_pairs = max_virtqueue_pairs;
      endtask

      virtual task select_queue(int unsigned queue_id);
      endtask

      virtual task read_queue_num_max(ref int unsigned max_size);
          max_size = 8;
      endtask

      virtual task setup_single_queue(
          int unsigned queue_id,
          int unsigned queue_size,
          bit [63:0]   desc_addr,
          bit [63:0]   driver_addr,
          bit [63:0]   device_addr,
          int unsigned msix_vector
      );
          programmed_qids.push_back(queue_id);
      endtask

      virtual task write_queue_enable(bit enable);
      endtask

      virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                        bit wrap_counter);
          kick_count++;
      endtask
  endclass : virtio_ctrl_vq_test_transport

  // 设备接受 MQ 变更：只替换 control 命令往返，建队/拆队仍走生产实现。
  class virtio_ctrl_vq_test_mq_ops extends virtio_atomic_ops;
      `uvm_object_utils(virtio_ctrl_vq_test_mq_ops)

      int unsigned mq_requests[$];

      function new(string name = "virtio_ctrl_vq_test_mq_ops");
          super.new(name);
      endfunction

      virtual task ctrl_set_mq_pairs(int unsigned num_pairs, ref bit success);
          mq_requests.push_back(num_pairs);
          success = 1;
      endtask
  endclass : virtio_ctrl_vq_test_mq_ops

  // 只为断言暴露受保护的分配表，不改变分配行为。
  class virtio_ctrl_vq_test_mem extends host_mem_manager;
      `uvm_object_utils(virtio_ctrl_vq_test_mem)

      function new(string name = "virtio_ctrl_vq_test_mem");
          super.new(name);
      endfunction

      function int unsigned outstanding_allocations();
          return alloc_table.size();
      endfunction
  endclass : virtio_ctrl_vq_test_mem

  // fail_map_after=N（N>0）时第 N 次及之后的映射返回 '1，模拟 IOVA 耗尽；0 表示不注入。
  class virtio_ctrl_vq_test_iommu extends virtio_iommu_model;
      `uvm_object_utils(virtio_ctrl_vq_test_iommu)

      int unsigned fail_map_after;
      int unsigned map_calls;

      function new(string name = "virtio_ctrl_vq_test_iommu");
          super.new(name);
          fail_map_after = 0;
          map_calls = 0;
      endfunction

      virtual function bit [63:0] map_for_host(int unsigned host_id,
                                               bit [15:0] bdf,
                                               bit [63:0] gpa,
                                               int unsigned size,
                                               dma_dir_e dir,
                                               string file = "",
                                               int line = 0);
          map_calls++;
          if ((fail_map_after != 0) && (map_calls >= fail_map_after))
              return '1;
          return super.map_for_host(host_id, bdf, gpa, size, dir, file, line);
      endfunction

      function int unsigned active_mapping_count();
          return mapping_table.size();
      endfunction
  endclass : virtio_ctrl_vq_test_iommu

  // 只吞掉登记过的 (id, 消息模式) UVM_ERROR，其余错误照常失败。
  class virtio_ctrl_vq_test_catcher extends uvm_report_catcher;
      string       expected_ids[$];
      string       expected_msgs[$];
      int unsigned caught_count;

      function new(string name = "virtio_ctrl_vq_test_catcher");
          super.new(name);
          caught_count = 0;
      endfunction

      function void expect_error(string id, string msg_pattern);
          expected_ids.push_back(id);
          expected_msgs.push_back(msg_pattern);
      endfunction

      virtual function action_e catch();
          if (get_severity() != UVM_ERROR)
              return THROW;
          foreach (expected_ids[i]) begin
              if ((get_id() == expected_ids[i]) &&
                  uvm_is_match(expected_msgs[i], get_message())) begin
                  caught_count++;
                  return CAUGHT;
              end
          end
          return THROW;
      endfunction
  endclass : virtio_ctrl_vq_test_catcher

  class virtio_ctrl_vq_test extends uvm_test;
      `uvm_component_utils(virtio_ctrl_vq_test)

      function new(string name, uvm_component parent);
          super.new(name, parent);
      endfunction

      virtual task run_phase(uvm_phase phase);
          phase.raise_objection(this);
          test_ctrl_vq_at_twice_max_pairs();
          `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
          phase.drop_objection(this);
      endtask

      // 一个 Function 的最小装配：ring 内存给 vq_mgr，ops_mem 给 ops 的数据/控制缓冲。
      protected function void wire_ops(
          virtio_atomic_ops             ops,
          virtio_ctrl_vq_test_transport transport,
          virtqueue_manager             vq_mgr,
          host_mem_manager              ring_mem,
          host_mem_manager              ops_mem,
          virtio_iommu_model            iommu,
          bit [15:0]                    bdf
      );
          virtio_memory_barrier_model barrier =
              virtio_memory_barrier_model::type_id::create("ctrl_vq_barrier");
          virtqueue_error_injector err_inj =
              virtqueue_error_injector::type_id::create("ctrl_vq_err_inj");
          virtio_wait_policy wait_pol =
              virtio_wait_policy::type_id::create("ctrl_vq_wait_pol");

          vq_mgr.mem = ring_mem;
          vq_mgr.iommu = iommu;
          vq_mgr.barrier = barrier;
          vq_mgr.err_inj = err_inj;
          vq_mgr.wait_pol = wait_pol;
          vq_mgr.bdf = bdf;
          transport.bdf = bdf;
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = ops_mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
      endfunction

      // 设备 max_virtqueue_pairs=2、当前 1 对：control VQ 必须是 4，扩到 2 对时
      // 新建的 RX1/TX1（2/3）不得与 control VQ 冲突。
      task test_ctrl_vq_at_twice_max_pairs();
          virtio_ctrl_vq_test_transport transport =
              virtio_ctrl_vq_test_transport::type_id::create("mq_transport");
          virtio_ctrl_vq_test_mq_ops ops =
              virtio_ctrl_vq_test_mq_ops::type_id::create("mq_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("mq_vq_mgr");
          virtio_ctrl_vq_test_mem mem =
              virtio_ctrl_vq_test_mem::type_id::create("mq_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("mq_iommu");
          virtio_auto_fsm fsm = virtio_auto_fsm::type_id::create("mq_fsm");
          int unsigned expected_qids[$];
          bit ok;
          string why;

          mem.init_region(64'h7000_0000, 64'h7000_FFFF);
          wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0901);
          transport.max_virtqueue_pairs = 2;
          ops.negotiated_features = '0;
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
          ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

          ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
          assert(ok && (vq_mgr.get_queue(4) != null) &&
                 (vq_mgr.get_queue(2) == null) &&
                 (vq_mgr.get_queue_count() == 3))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "control VQ must be queue 2*max_virtqueue_pairs=4 (ok=%0b q2=%0b q4=%0b count=%0d)",
                  ok, vq_mgr.get_queue(2) != null, vq_mgr.get_queue(4) != null,
                  vq_mgr.get_queue_count()))

          fsm.ops = ops;
          fsm.drv_cfg.queue_size = 8;
          fsm.drv_cfg.vq_type = VQ_SPLIT;
          assert(fsm.bind_mq_pair_limit(2, why))
              else `uvm_fatal("CTRL_VQ_TEST", why)
          fsm.configure_mq(2);
          expected_qids = '{0, 1, 4, 2, 3};
          assert((fsm.state != FSM_ERROR) && (ops.mq_requests.size() == 1) &&
                 (ops.mq_requests[0] == 2) && (vq_mgr.get_queue_count() == 5) &&
                 (transport.programmed_qids == expected_qids))
              else `uvm_fatal("CTRL_VQ_TEST",
                  "MQ expansion 1->2 collided with the control VQ")

          foreach (expected_qids[i])
              ops.teardown_queue(expected_qids[i]);
          assert((vq_mgr.get_queue_count() == 0) &&
                 (iommu.active_mapping_count() == 0) &&
                 (mem.outstanding_allocations() == 0))
              else `uvm_fatal("CTRL_VQ_TEST", "control VQ layout test leaked queue resources")
          mem.leak_check();

          `uvm_info("CTRL_VQ_TEST", "control VQ at 2*max_virtqueue_pairs test PASSED", UVM_LOW)
      endtask
  endclass : virtio_ctrl_vq_test

  `endif // VIRTIO_CTRL_VQ_TEST_SV
  ```

- [ ] **Step 2: 加入编译与 manifest、同步文档清单**

  `filelists/tests.f` old：
  ```
  virtio_net_vip/tests/virtio_admin_vq_test.sv
  ```
  new：
  ```
  virtio_net_vip/tests/virtio_admin_vq_test.sv
  virtio_net_vip/tests/virtio_ctrl_vq_test.sv
  ```
  `scripts/test_manifest.sh` old：
  ```bash
    virtio_admin_vq_test
    virtio_migration_dirty_test
  ```
  new：
  ```bash
    virtio_admin_vq_test
    virtio_ctrl_vq_test
    virtio_migration_dirty_test
  ```
  `README.md` 393 行 old：
  ```markdown
  `virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
  ```
  new：
  ```markdown
  `virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
  `virtio_ctrl_vq_test`、
  ```
  `README.md`（P0-1 修改后的计数行）old：`` `dpu_priv_ring_contract_test`，共 39 项。`` → new：`` `dpu_priv_ring_contract_test`，共 40 项。``

  `docs/virtio_net_vip_manual.md` 2059 行 old：
  ```markdown
  `virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
  ```
  new：
  ```markdown
  `virtio_protocol_test`、`virtio_indirect_desc_test`、`virtio_desc_corruption_test`、`virtio_admin_vq_test`、
  `virtio_ctrl_vq_test`、
  ```
  手册（P0-1 修改后的计数行）old：`共 39 项。该入口` → new：`共 40 项。该入口`

- [ ] **Step 3: 运行，确认失败**

  SYNC 后：
  ```bash
  ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_ctrl_vq_test ./scripts/vcs.sh > logs/virtio_ctrl_vq_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_ctrl_vq_test.log | tail -20'
  ```
  期望：`UVM_FATAL ... [CTRL_VQ_TEST] control VQ must be queue 2*max_virtqueue_pairs=4 (ok=1 q2=1 q4=0 count=3)`，
  汇总 `UVM_FATAL :    1`。

- [ ] **Step 4: 修复 `setup_all_queues`**

  `virtio_atomic_ops.sv` 844-846 行 old：
  ```systemverilog
          int unsigned ctrl_qid;
          int unsigned created_qids[$];
          bit queue_ok;
  ```
  new：
  ```systemverilog
          int unsigned ctrl_qid;
          int unsigned created_qids[$];
          bit queue_ok;
          virtio_net_device_config_t net_cfg;
  ```
  872-875 行 old：
  ```systemverilog
          // Setup control queue if CTRL_VQ negotiated
          if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
              ctrl_qid = num_pairs * 2;
              setup_queue(ctrl_qid, queue_size, vq_type, queue_ok);
  ```
  new：
  ```systemverilog
          // Setup control queue if CTRL_VQ negotiated.  virtio 1.2 §5.1.2：
          // 协商 MQ 时 controlq 编号为 2*max_virtqueue_pairs（设备 config 上限），
          // 否则为 2（单对）。取 max(num_pairs, 设备上限)，设备上报值小于当前对数时
          // 也不与数据队列重号；之后 MQ 扩容新建的 RX/TX 不会落到 control VQ 上。
          if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
              ctrl_qid = num_pairs * 2;
              if (negotiated_features[VIRTIO_NET_F_MQ]) begin
                  transport.read_net_config(net_cfg);
                  if (net_cfg.max_virtqueue_pairs > num_pairs)
                      ctrl_qid = 2 * net_cfg.max_virtqueue_pairs;
              end
              setup_queue(ctrl_qid, queue_size, vq_type, queue_ok);
  ```
  （`ctrl_send` 以 `ring_iovas` 中最大队列号定位 control VQ，`virtio_atomic_ops.sv:1655-1663`；control VQ
  位于 2*max 时它仍是最大号，无需修改。`dpu_priv_atomic_ops.setup_all_queues` 调 `super`，私有路径不协商
  CTRL_VQ，不受影响。）

- [ ] **Step 5: 运行，确认通过**

  同 Step 3 命令。期望三行汇总均为 0，日志含 `control VQ at 2*max_virtqueue_pairs test PASSED`。

- [ ] **Step 6: 回归**

  REGRESSION 命令；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 7: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv \
    filelists/tests.f scripts/test_manifest.sh README.md docs/virtio_net_vip_manual.md
  git commit -m "fix: control VQ 按 2*max_virtqueue_pairs 编号，避免 MQ 扩容与数据队列冲突"
  ```

---

### Task P0-3: ctrl_send 检查分配与映射失败并回滚（规范 P0.3）

**缺陷确认：** `virtio_atomic_ops.sv:1675-1705` 中 `hdr_gpa/ack_gpa/data_gpa` 的 `mem.alloc` 返回 `'1` 与三次
`map_for_host` 返回 `'1`/0 均未检查：失败后仍写内存、入队、`transport.kick`，并对 `'1` 地址 unmap/free。缺陷真实存在。
（`add_buf` 失败同样未检查，但只导致轮询超时后正常清理，无泄漏，不在本任务范围，见 integrator notes。）
注入方式：`host_mem_manager.alloc` 不是 virtual，无法覆写；用独立的 16 字节 ops 内存（一个最小块）制造第二次分配失败；
`virtio_iommu_model.map_for_host` 是 virtual，用测试子类在第 N 次映射返回 `'1`。

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:1675-1705`（`ctrl_send` 分配/映射段）
- Modify: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`（新增两个子测试并在 `run_phase` 调用）
- Test: `virtio_ctrl_vq_test`

**Interfaces:**
- Consumes: P0-2 的 `virtio_ctrl_vq_test_*` 测试件；`virtio_atomic_ops::ctrl_send(virtio_ctrl_class_e ctrl_class, bit [7:0] cmd, byte unsigned data[], ref virtio_ctrl_ack_e ack)`。
- Produces: `ctrl_send` 失败契约——任一分配/映射失败：`ack = VIRTIO_NET_CTRL_ACK_ERR`，报 `ATOMIC_OPS` 错误
  `ctrl_send: host_mem alloc failed for control <header|ack|data>` 或 `ctrl_send: failed to map control buffers`，
  已分配/已映射资源全部释放，不入队、不通知。P2.3 的 `virtio_dma_buffer_set` 替换这段手写回滚时须保持该契约。

- [ ] **Step 1: 写失败测试**

  `virtio_ctrl_vq_test.sv` 的 `run_phase` old：
  ```systemverilog
          test_ctrl_vq_at_twice_max_pairs();
          `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
  ```
  new：
  ```systemverilog
          test_ctrl_vq_at_twice_max_pairs();
          test_ctrl_send_alloc_failure_rolls_back();
          test_ctrl_send_map_failure_rolls_back();
          `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE)
  ```
  在 `endclass : virtio_ctrl_vq_test` 之前加入：
  ```systemverilog
      // ops 内存只有一个 16B 最小块：header 占用后 ack 申请失败。ctrl_send 必须释放
      // header，不映射、不入队、不通知，并以 ACK_ERR 返回。
      task test_ctrl_send_alloc_failure_rolls_back();
          virtio_ctrl_vq_test_transport transport =
              virtio_ctrl_vq_test_transport::type_id::create("alloc_fail_transport");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("alloc_fail_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("alloc_fail_vq_mgr");
          virtio_ctrl_vq_test_mem ring_mem =
              virtio_ctrl_vq_test_mem::type_id::create("alloc_fail_ring_mem");
          virtio_ctrl_vq_test_mem ctrl_mem =
              virtio_ctrl_vq_test_mem::type_id::create("alloc_fail_ctrl_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("alloc_fail_iommu");
          virtio_ctrl_vq_test_catcher catcher;
          virtqueue_base ctrl_vq;
          virtio_ctrl_ack_e ack;
          byte unsigned data[];
          int unsigned maps_before;
          bit ok;

          ring_mem.init_region(64'h7100_0000, 64'h7100_FFFF);
          ctrl_mem.init_region(64'h7200_0000, 64'h7200_000F);
          wire_ops(ops, transport, vq_mgr, ring_mem, ctrl_mem, iommu, 16'h0902);
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.setup_queue(2, 8, VQ_SPLIT, ok);
          assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
          ctrl_vq = vq_mgr.get_queue(2);
          maps_before = iommu.active_mapping_count();

          data = new[2];
          data[0] = 8'h01;
          data[1] = 8'h00;
          ack = VIRTIO_NET_CTRL_ACK_OK;
          catcher = new("alloc_fail_catcher");
          catcher.expect_error("HOST_MEM", "*alloc: insufficient space*");
          catcher.expect_error("ATOMIC_OPS", "*ctrl_send: host_mem alloc failed*");
          uvm_report_cb::add(null, catcher);
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, ack);
          uvm_report_cb::delete(null, catcher);
          assert((ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 2) &&
                 (ctrl_mem.outstanding_allocations() == 0) &&
                 (iommu.active_mapping_count() == maps_before) &&
                 (transport.kick_count == 0) && (ctrl_vq.get_free_count() == 8))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "ctrl_send ack-allocation failure leaked resources or notified the device (ack=%s caught=%0d allocs=%0d maps=%0d/%0d kicks=%0d free=%0d)",
                  ack.name(), catcher.caught_count, ctrl_mem.outstanding_allocations(),
                  iommu.active_mapping_count(), maps_before, transport.kick_count,
                  ctrl_vq.get_free_count()))

          ops.teardown_queue(2);
          assert((iommu.active_mapping_count() == 0) &&
                 (ring_mem.outstanding_allocations() == 0))
              else `uvm_fatal("CTRL_VQ_TEST", "alloc-failure test leaked control queue resources")
          ring_mem.leak_check();
          ctrl_mem.leak_check();
          `uvm_info("CTRL_VQ_TEST", "ctrl_send allocation-failure rollback test PASSED", UVM_LOW)
      endtask

      // header 映射成功、data 映射失败：ctrl_send 必须撤销 header 映射并释放三块缓冲。
      task test_ctrl_send_map_failure_rolls_back();
          virtio_ctrl_vq_test_transport transport =
              virtio_ctrl_vq_test_transport::type_id::create("map_fail_transport");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("map_fail_ops");
          virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("map_fail_vq_mgr");
          virtio_ctrl_vq_test_mem mem =
              virtio_ctrl_vq_test_mem::type_id::create("map_fail_mem");
          virtio_ctrl_vq_test_iommu iommu =
              virtio_ctrl_vq_test_iommu::type_id::create("map_fail_iommu");
          virtio_ctrl_vq_test_catcher catcher;
          virtqueue_base ctrl_vq;
          virtio_ctrl_ack_e ack;
          byte unsigned data[];
          int unsigned maps_before;
          int unsigned allocs_before;
          bit ok;

          mem.init_region(64'h7300_0000, 64'h7300_FFFF);
          wire_ops(ops, transport, vq_mgr, mem, mem, iommu, 16'h0903);
          ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
          ops.setup_queue(2, 8, VQ_SPLIT, ok);
          assert(ok) else `uvm_fatal("CTRL_VQ_TEST", "control queue setup failed")
          ctrl_vq = vq_mgr.get_queue(2);
          maps_before = iommu.active_mapping_count();
          allocs_before = mem.outstanding_allocations();

          data = new[2];
          data[0] = 8'h01;
          data[1] = 8'h00;
          ack = VIRTIO_NET_CTRL_ACK_OK;
          iommu.map_calls = 0;
          iommu.fail_map_after = 2;
          catcher = new("map_fail_catcher");
          catcher.expect_error("ATOMIC_OPS", "*ctrl_send: failed to map control buffers*");
          uvm_report_cb::add(null, catcher);
          ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                        data, ack);
          uvm_report_cb::delete(null, catcher);
          iommu.fail_map_after = 0;
          assert((ack == VIRTIO_NET_CTRL_ACK_ERR) && (catcher.caught_count == 1) &&
                 (mem.outstanding_allocations() == allocs_before) &&
                 (iommu.active_mapping_count() == maps_before) &&
                 (transport.kick_count == 0) && (ctrl_vq.get_free_count() == 8))
              else `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                  "ctrl_send map failure leaked resources or notified the device (ack=%s caught=%0d allocs=%0d/%0d maps=%0d/%0d kicks=%0d free=%0d)",
                  ack.name(), catcher.caught_count, mem.outstanding_allocations(),
                  allocs_before, iommu.active_mapping_count(), maps_before,
                  transport.kick_count, ctrl_vq.get_free_count()))

          ops.teardown_queue(2);
          assert((iommu.active_mapping_count() == 0) &&
                 (mem.outstanding_allocations() == 0))
              else `uvm_fatal("CTRL_VQ_TEST", "map-failure test leaked control queue resources")
          mem.leak_check();
          `uvm_info("CTRL_VQ_TEST", "ctrl_send map-failure rollback test PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后 ONE TEST（`TEST=virtio_ctrl_vq_test`）。期望出现
  `UVM_FATAL ... [CTRL_VQ_TEST] ctrl_send ack-allocation failure leaked resources or notified the device (...)`
  （修复前 ack/data 申请失败后仍写内存、入队、kick 并轮询超时，消息中 `kicks=1`），之前伴随未捕获的
  `HOST_MEM`/`IOMMU_UNMAP`/`ATOMIC_OPS ctrl_send: timeout` UVM_ERROR；汇总 `UVM_FATAL :    1`。

- [ ] **Step 3: 修复 `ctrl_send`**

  `virtio_atomic_ops.sv` 1675-1687 行 old：
  ```systemverilog
          // 2. Allocate host_mem for hdr, data, and ack
          hdr_gpa = mem.alloc(2, .align(1));
          ack_gpa = mem.alloc(1, .align(1));

          write_buf = new[2];
          write_buf[0] = hdr_buf[0];
          write_buf[1] = hdr_buf[1];
          mem.write_mem(hdr_gpa, write_buf);

          data_alloc_size = (data.size() > 0) ? data.size() : 1;
          data_gpa = mem.alloc(data_alloc_size, .align(1));

          if (data.size() > 0) begin
  ```
  new：
  ```systemverilog
          // 2. Allocate host_mem for hdr, data, and ack.  每次失败都回滚本次已分配
          // 的缓冲；此时尚无映射和描述符引用它们，直接 free 即可。
          hdr_gpa = mem.alloc(2, .align(1));
          if (hdr_gpa == '1) begin
              `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control header")
              ack = VIRTIO_NET_CTRL_ACK_ERR;
              return;
          end
          ack_gpa = mem.alloc(1, .align(1));
          if (ack_gpa == '1) begin
              mem.free(hdr_gpa);
              `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control ack")
              ack = VIRTIO_NET_CTRL_ACK_ERR;
              return;
          end

          write_buf = new[2];
          write_buf[0] = hdr_buf[0];
          write_buf[1] = hdr_buf[1];
          mem.write_mem(hdr_gpa, write_buf);

          data_alloc_size = (data.size() > 0) ? data.size() : 1;
          data_gpa = mem.alloc(data_alloc_size, .align(1));
          if (data_gpa == '1) begin
              mem.free(hdr_gpa);
              mem.free(ack_gpa);
              `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control data")
              ack = VIRTIO_NET_CTRL_ACK_ERR;
              return;
          end

          if (data.size() > 0) begin
  ```
  1698-1705 行（映射段）old：
  ```systemverilog
          // 3. Map through IOMMU
          hdr_iova  = iommu.map_for_host(get_iommu_host_id(transport),
              transport.bdf, hdr_gpa, 2, DMA_TO_DEVICE);
          data_iova = iommu.map_for_host(get_iommu_host_id(transport),
              transport.bdf, data_gpa, data_alloc_size, DMA_TO_DEVICE);
          ack_iova  = iommu.map_for_host(get_iommu_host_id(transport),
              transport.bdf, ack_gpa, 1, DMA_FROM_DEVICE);
  ```
  new：
  ```systemverilog
          // 3. Map through IOMMU.  任一映射失败即停止后续映射，撤销已成功的映射并
          // 释放三块缓冲；描述符尚未发布，设备不可能访问这些 IOVA。
          data_iova = '1;
          ack_iova  = '1;
          hdr_iova  = iommu.map_for_host(get_iommu_host_id(transport),
              transport.bdf, hdr_gpa, 2, DMA_TO_DEVICE);
          if ((hdr_iova != '1) && (hdr_iova != 0))
              data_iova = iommu.map_for_host(get_iommu_host_id(transport),
                  transport.bdf, data_gpa, data_alloc_size, DMA_TO_DEVICE);
          if ((data_iova != '1) && (data_iova != 0))
              ack_iova  = iommu.map_for_host(get_iommu_host_id(transport),
                  transport.bdf, ack_gpa, 1, DMA_FROM_DEVICE);
          if ((ack_iova == '1) || (ack_iova == 0)) begin
              if ((hdr_iova != '1) && (hdr_iova != 0))
                  iommu.unmap_for_host(get_iommu_host_id(transport),
                                       transport.bdf, hdr_iova);
              if ((data_iova != '1) && (data_iova != 0))
                  iommu.unmap_for_host(get_iommu_host_id(transport),
                                       transport.bdf, data_iova);
              mem.free(hdr_gpa);
              mem.free(data_gpa);
              mem.free(ack_gpa);
              `uvm_error("ATOMIC_OPS", "ctrl_send: failed to map control buffers")
              ack = VIRTIO_NET_CTRL_ACK_ERR;
              return;
          end
  ```
  （`ack_iova` 只有在前两次映射都成功时才会被赋成有效值，所以只判断它即可覆盖三种失败。）

- [ ] **Step 4: 运行，确认通过**

  ONE TEST（`TEST=virtio_ctrl_vq_test`）。期望三行汇总均为 0，日志含
  `ctrl_send allocation-failure rollback test PASSED` 与 `ctrl_send map-failure rollback test PASSED`，
  且无 `Leak check: N blocks not freed`。

- [ ] **Step 5: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv
  git commit -m "fix: ctrl_send 检查分配与映射失败并回滚已占用资源"
  ```

---

### Task P0-4: TX 引擎委托 atomic ops，提交后真实通知设备（规范 P0.1/P2.1，TX 部分）

**缺陷确认：** `virtio_tx_engine.submit_packet`（`virtio_tx_engine.sv:109-147`）经 `submit_single` 只做 `add_buf`，
从不通知设备；`virtio_rx_engine.refill_buffers` 只调 `vq.kick()`（`virtio_rx_engine.sv:202-203`），而
`split_virtqueue::kick`（`split_virtqueue.sv:385-396`）与 `packed_virtqueue::kick`（`packed_virtqueue.sv:410-421`）
只计数与触发错误注入钩子，不发 TLP。缺陷真实存在。按规范，P0.1 直接实现 P2.1 的委托方案：引擎只构造
header 与统计，DMA/描述符/通知/回收全部交给 `virtio_atomic_ops`（`dpu_priv_dataplane.sv` 已是此形态）。

**Spec deviation（必要附带修复）：** `virtio_atomic_ops.tx_submit`（`virtio_atomic_ops.sv:961-967`）对
`net_packet::packet_item` 调 `do_pack()`+`get_bytes()`，得到的是 UVM 序列化格式（32-bit 长度前缀 + raw_data，
见 `net_packet/src/uvm_wrapper/packet_item.sv:56-62` 与 `virtio_net_packet_adapter.sv:4-6`），不是线速帧；引擎走 adapter
取 `pkt.raw_data`。不修正就无法保持 `virtio_net_packet_multi_queue_test` 的字节级断言（`check_tx_chain` 比较 data 描述符
长度与 raw 字节）。本任务让 `tx_submit` 先用 `virtio_net_packet_adapter::pack`，非 `packet_item` 对象保留原
`do_pack/get_bytes` 路径。维护测试中经 ops 发送 `packet_item` 的只有 `virtio_real_driver_multiqueue_test`
（只断言计数）与私有 ops（自行用 adapter）；MODEL responder（`virtio_pcie_dut_responder.sv`）不解析 TX payload。

**Files:**
- Modify: `virtio_net_vip/src/types/virtio_net_hdr.sv:1-3,166-168`（前置声明 + 新静态函数 `build_tx_hdr`）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:898,931,961-967`（`tx_submit` 线速字节提取）
- Modify: `virtio_net_vip/src/dataplane/virtio_tx_engine.sv:40-60,65-69,109-147,273-305,318-351`
- Modify: `virtio_net_vip/src/dataplane/virtio_rx_engine.sv:64-65`（只加 `ops` 字段，行为在 P0-5 改）
- Modify: `virtio_net_vip/src/dataplane/virtio_net_dataplane.sv:101-103`（新增 `bind_ops`）
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:421-424`（提交绑定时 `dataplane.bind_ops(ops)`）
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv:161-175,647-718,805-893`（新子测试；迁移两个 dataplane 子测试）
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv:9-11,36,252-253,277-278`
- Test: `virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、`dpu_priv_driver_flow_test`、`virtio_fabric_resource_test`

**Interfaces:**
- Consumes: `virtio_atomic_ops::tx_submit(int unsigned queue_id, virtio_net_hdr_t net_hdr, uvm_object pkt, bit use_indirect, ref int unsigned desc_id)`、
  `virtio_atomic_ops::tx_complete(int unsigned queue_id, ref uvm_object completed_pkts[$], int unsigned max_budget)`、
  `virtio_net_packet_adapter::pack(input uvm_object, ref byte unsigned raw_data[$])`。
- Produces:
  - `static function void virtio_net_hdr_util::build_tx_hdr(input byte unsigned pkt_data[$], input bit [63:0] features, input virtio_offload_engine offload, output virtio_net_hdr_t hdr)`
  - `virtio_tx_engine::ops`、`virtio_rx_engine::ops`（`virtio_atomic_ops`，借用）
  - `virtual function void virtio_net_dataplane::bind_ops(virtio_atomic_ops ops)`
  - 引擎公共签名不变：`submit_packet(int unsigned, uvm_object, bit, ref int unsigned)`、`complete_tx(int unsigned, int unsigned, ref uvm_object[$])`。
  - 删除 `virtio_tx_engine::build_net_hdr`（迁入 `build_tx_hdr`；`grep -rn build_net_hdr` 只命中定义与 :137 调用）。

- [ ] **Step 1: 写失败测试（TX 通知）**

  `virtio_indirect_desc_test.sv` `run_phase` old：
  ```systemverilog
          test_atomic_rx_num_buffers_without_mrg();

          shared_mem.leak_check();
  ```
  new：
  ```systemverilog
          test_atomic_rx_num_buffers_without_mrg();
          test_dataplane_engine_notifies_device();

          shared_mem.leak_check();
  ```
  在 `endclass : virtio_indirect_desc_test` 之前加入：
  ```systemverilog
      // dataplane 引擎是 atomic ops 的薄适配：TX 提交必须经 transport 发出真实
      // notify（修复前引擎只 add_buf，从不通知设备）。
      task test_dataplane_engine_notifies_device();
          host_mem_manager mem;
          virtio_iommu_model iommu =
              virtio_iommu_model::type_id::create("dataplane_notify_iommu");
          virtio_memory_barrier_model barrier =
              virtio_memory_barrier_model::type_id::create("dataplane_notify_barrier");
          virtqueue_error_injector err_inj =
              virtqueue_error_injector::type_id::create("dataplane_notify_err_inj");
          virtio_wait_policy wait_pol =
              virtio_wait_policy::type_id::create("dataplane_notify_wait_pol");
          virtqueue_manager vq_mgr =
              virtqueue_manager::type_id::create("dataplane_notify_vq_mgr");
          virtio_indirect_desc_test_transport transport =
              virtio_indirect_desc_test_transport::type_id::create("dataplane_notify_transport");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("dataplane_notify_ops");
          virtio_net_dataplane dataplane =
              virtio_net_dataplane::type_id::create("dataplane_notify");
          virtqueue_base base_vq;
          split_virtqueue tx_vq;
          virtio_dataplane_indirect_test_packet token;
          uvm_object completed[$];
          bit [63:0] features;
          int unsigned desc_id;

          mem = shared_mem;
          vq_mgr.mem = mem;
          vq_mgr.iommu = iommu;
          vq_mgr.barrier = barrier;
          vq_mgr.err_inj = err_inj;
          vq_mgr.wait_pol = wait_pol;
          vq_mgr.bdf = 16'h0706;
          base_vq = vq_mgr.create_queue(1, 8, VQ_SPLIT);
          assert($cast(tx_vq, base_vq))
              else `uvm_fatal("INDIRECT_TEST", "failed to create dataplane notify TX queue")
          tx_vq.alloc_rings();

          transport.bdf = 16'h0706;
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
          features = '0;
          ops.negotiated_features = features;
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 0,
                              vq_mgr, mem, iommu, 16'h0706);
          dataplane.bind_ops(ops);
          token = virtio_dataplane_indirect_test_packet::type_id::create(
              "dataplane_notify_token");

          desc_id = '1;
          dataplane.tx_engine.submit_packet(1, token, 1'b0, desc_id);
          assert((desc_id != '1) && (transport.kick_count == 1) &&
                 (transport.last_kick_queue_id == 1) &&
                 (transport.last_kick_next_avail_idx == 1))
              else `uvm_fatal("INDIRECT_TEST", $sformatf(
                  "dataplane TX did not notify the device (desc=%0d kicks=%0d)",
                  desc_id, transport.kick_count))

          complete_split(mem, tx_vq, desc_id, 0);
          dataplane.tx_engine.complete_tx(1, 1, completed);
          assert((completed.size() == 1) && (completed[0] == token))
              else `uvm_fatal("INDIRECT_TEST", "dataplane TX completion did not return the token")
          tx_vq.free_rings();
          assert(iommu.total_maps == iommu.total_unmaps)
              else `uvm_fatal("INDIRECT_TEST", "dataplane notify test leaked mappings")

          `uvm_info("INDIRECT_TEST", "dataplane engine notify test PASSED", UVM_LOW)
      endtask
  ```

- [ ] **Step 2: 运行，确认失败（编译期）**

  SYNC 后 ONE TEST（`TEST=virtio_indirect_desc_test`）。期望日志出现 `^Error-[...]`，指出 `bind_ops` 不是
  `virtio_net_dataplane` 的成员。

- [ ] **Step 3: 加入绑定接口（只做接线，不改行为）**

  `virtio_tx_engine.sv` 65-69 行 old：
  ```systemverilog
      // ===== External references (set by parent before use) =====
      virtqueue_manager           vq_mgr;
      host_mem_manager            mem;
      virtio_iommu_model          iommu;
      virtio_offload_engine       offload;
      virtio_dataplane_callback   custom_cb;   // null = standard mode
  ```
  new：
  ```systemverilog
      // ===== External references (set by parent before use) =====
      // ops 是规范 TX 路径（借用）：DMA、描述符发布、通知与完成回收都由它执行。
      virtio_atomic_ops           ops;
      virtqueue_manager           vq_mgr;
      host_mem_manager            mem;
      virtio_iommu_model          iommu;
      virtio_offload_engine       offload;
      virtio_dataplane_callback   custom_cb;   // null = standard mode
  ```
  `virtio_rx_engine.sv` 64-65 行 old：
  ```systemverilog
      // ===== External references (set by parent before use) =====
      virtqueue_manager           vq_mgr;
      host_mem_manager            mem;
      virtio_iommu_model          iommu;
      virtio_offload_engine       offload;
      virtio_dataplane_callback   custom_cb;   // null = standard mode
  ```
  new：
  ```systemverilog
      // ===== External references (set by parent before use) =====
      // ops 是规范 RX 路径（借用）：buffer 分配、通知、取包与 DMA 回收由它执行。
      virtio_atomic_ops           ops;
      virtqueue_manager           vq_mgr;
      host_mem_manager            mem;
      virtio_iommu_model          iommu;
      virtio_offload_engine       offload;
      virtio_dataplane_callback   custom_cb;   // null = standard mode
  ```
  （两个文件这段文本相同，分别在各自文件内编辑。）
  `virtio_net_dataplane.sv` 101-103 行 old：
  ```systemverilog
      // ========================================================================
      // set_dataplane_callback -- Install custom TX/RX hooks
      // ========================================================================
  ```
  new：
  ```systemverilog
      // ========================================================================
      // bind_ops -- 绑定规范数据路径
      //
      // 引擎只做 header 构造与统计；DMA、描述符、通知与回收全部委托 ops。ops 由
      // Function 或测试持有，这里只借用；须在首次收发前调用。
      // ========================================================================
      virtual function void bind_ops(virtio_atomic_ops ops);
          tx_engine.ops = ops;
          rx_engine.ops = ops;
      endfunction

      // ========================================================================
      // set_dataplane_callback -- Install custom TX/RX hooks
      // ========================================================================
  ```

- [ ] **Step 4: 运行，确认行为失败**

  ONE TEST（`TEST=virtio_indirect_desc_test`）。期望：
  `UVM_FATAL ... [INDIRECT_TEST] dataplane TX did not notify the device (desc=0 kicks=0)`，汇总 `UVM_FATAL :    1`。

- [ ] **Step 5: `build_tx_hdr` 迁入 `virtio_net_hdr_util`**

  `virtio_net_hdr.sv` 1-3 行 old：
  ```systemverilog
  `ifndef VIRTIO_NET_HDR_SV
  `define VIRTIO_NET_HDR_SV

  ```
  new：
  ```systemverilog
  `ifndef VIRTIO_NET_HDR_SV
  `define VIRTIO_NET_HDR_SV

  // build_tx_hdr 借用 offload 引擎解析报文；该类在数据面层定义，这里前置声明。
  typedef class virtio_offload_engine;

  ```
  文件尾 old：
  ```systemverilog
      endfunction : unpack_hdr

  endclass : virtio_net_hdr_util
  ```
  new：
  ```systemverilog
      endfunction : unpack_hdr

      // ------------------------------------------------------------------------
      // build_tx_hdr
      //
      // 由线速帧与协商特性推导 TX virtio_net_hdr：CSUM 时置 NEEDS_CSUM 与
      // csum_start/offset；需要 GSO 时只填 gso_type/gso_size/hdr_len（分段由设备
      // 完成）；HASH_REPORT 时填哈希。offload 只被借用来解析报文，不改变其状态。
      // ------------------------------------------------------------------------
      static function void build_tx_hdr(
          input  byte unsigned         pkt_data[$],
          input  bit [63:0]            features,
          input  virtio_offload_engine offload,
          output virtio_net_hdr_t      hdr
      );
          hdr = '{default: 0};

          // ---- Checksum offload ----
          if (features[VIRTIO_NET_F_CSUM]) begin
              hdr.flags       = VIRTIO_NET_HDR_F_NEEDS_CSUM;
              hdr.csum_start  = offload.calc_csum_start(pkt_data);
              hdr.csum_offset = offload.calc_csum_offset(pkt_data);
          end

          // ---- GSO/TSO (header fields only -- device handles segmentation) ----
          if (offload.needs_gso(pkt_data)) begin
              hdr.gso_type = offload.get_gso_type(pkt_data);
              hdr.gso_size = offload.get_mss_value();
              hdr.hdr_len  = offload.get_all_hdr_len(pkt_data);
          end

          // ---- Hash report ----
          if (features[VIRTIO_NET_F_HASH_REPORT]) begin
              hdr.hash_value  = offload.rss_calc_hash(pkt_data);
              hdr.hash_report = offload.rss_get_hash_type(pkt_data);
          end
      endfunction : build_tx_hdr

  endclass : virtio_net_hdr_util
  ```
  删除 `virtio_tx_engine.sv` 273-305 行（`build_net_hdr` 的 `// ===... build_net_hdr (protected)` 注释块与整个函数）。

- [ ] **Step 6: `ops.tx_submit` 发送线速字节**

  `virtio_atomic_ops.sv` 931 行（`normal_dma_record_t dma_record;`）之后新增声明：
  ```systemverilog
          byte unsigned    wire_bytes[$];
  ```
  961-967 行 old：
  ```systemverilog
          // 2. Get raw packet data from pkt via do_pack
          begin
              uvm_packer packer;
              packer = new();
              pkt.do_pack(packer);
              packer.get_bytes(pkt_bytes);
          end
  ```
  new：
  ```systemverilog
          // 2. Get wire bytes.  packet_item.do_pack() 带 32-bit UVM 长度前缀，不是
          // 线速帧，先经 adapter 取 raw_data；其他对象保留原 do_pack 字节流。
          if (virtio_net_packet_adapter::pack(pkt, wire_bytes)) begin
              pkt_bytes = new[wire_bytes.size()];
              foreach (wire_bytes[i]) pkt_bytes[i] = wire_bytes[i];
          end else begin
              uvm_packer packer;
              packer = new();
              pkt.do_pack(packer);
              packer.get_bytes(pkt_bytes);
          end
  ```
  898 行注释 old：`    //   2. Get raw packet data via do_pack` → new：`    //   2. Get wire bytes (net_packet adapter, else do_pack)`。

- [ ] **Step 7: TX 引擎改为薄适配**

  `virtio_tx_engine.sv` 109-147 行（`submit_packet` 整个任务）替换为：
  ```systemverilog
      virtual task submit_packet(
          int unsigned     queue_id,
          uvm_object       pkt,
          bit              use_indirect,
          ref int unsigned desc_id
      );
          byte unsigned    pkt_data[$];
          virtio_net_hdr_t hdr;

          desc_id = '1;
          if (use_indirect &&
              !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
              `uvm_error("TX_ENG", $sformatf(
                  "submit_packet: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                  queue_id))
              return;
          end
          if ((ops == null) || (ops.vq_mgr == null)) begin
              `uvm_error("TX_ENG", $sformatf(
                  "submit_packet: queue %0d has no bound atomic ops", queue_id))
              total_tx_errors++;
              return;
          end

          // ---- 1. Extract raw packet bytes ----
          pkt_data = extract_pkt_data(pkt);
          if (pkt_data.size() == 0) begin
              `uvm_error("TX_ENG",
                  $sformatf("submit_packet: empty packet data on queue %0d", queue_id))
              total_tx_errors++;
              return;
          end
          if (ops.vq_mgr.get_queue(queue_id) == null) begin
              `uvm_error("TX_ENG",
                  $sformatf("submit_packet: queue %0d not found", queue_id))
              total_tx_errors++;
              return;
          end

          // ---- 2. Build virtio_net_hdr (device performs GSO segmentation) ----
          virtio_net_hdr_util::build_tx_hdr(pkt_data, negotiated_features,
                                            offload, hdr);

          // ---- 3. ops 拥有 DMA、描述符发布与真实 notify；拒绝时已自行回滚 ----
          ops.tx_submit(queue_id, hdr, pkt, use_indirect, desc_id);
          if (desc_id == '1)
              return;

          total_tx_packets++;
          total_tx_bytes    += pkt_data.size();
          total_tx_sg_count += 2;   // [net_hdr] + [payload]

          `uvm_info("TX_ENG",
              $sformatf("submit_packet: queue=%0d desc_id=%0d pkt_size=%0d",
                        queue_id, desc_id, pkt_data.size()),
              UVM_HIGH)
      endtask : submit_packet
  ```
  `complete_tx`（318-351 行）替换为：
  ```systemverilog
      virtual task complete_tx(
          int unsigned      queue_id,
          int unsigned      budget,
          ref uvm_object    completed[$]
      );
          int unsigned before_count;

          if ((ops == null) || (ops.vq_mgr == null) ||
              (ops.vq_mgr.get_queue(queue_id) == null)) begin
              `uvm_error("TX_ENG",
                  $sformatf("complete_tx: queue %0d not found", queue_id))
              return;
          end

          // ops 按提交顺序回收每包的 header/payload DMA 所有权。
          before_count = completed.size();
          ops.tx_complete(queue_id, completed, budget);

          `uvm_info("TX_ENG",
              $sformatf("complete_tx: queue=%0d completed=%0d",
                        queue_id, completed.size() - before_count),
              UVM_HIGH)
      endtask : complete_tx
  ```
  类头注释（43-46 行）old：
  ```systemverilog
  //   3. Submits chains to a transmit virtqueue via virtqueue_manager.
  //   4. Handles TX completion: polls used ring, unmaps DMA, frees memory.
  ```
  new：
  ```systemverilog
  //   3. Delegates DMA, descriptor publication and the PCIe notify to
  //      virtio_atomic_ops.tx_submit (bound through virtio_net_dataplane.bind_ops).
  //   4. Delegates TX completion and DMA reclamation to virtio_atomic_ops.tx_complete.
  ```

- [ ] **Step 8: Function 绑定时接入 ops**

  `virtio_function_instance.sv` 421-424 行 old：
  ```systemverilog
              dataplane.rx_engine.host_id =
                  transport_ref.iommu_host_id();
              dataplane.rx_engine.bdf = transport_ref.bdf;
          end
  ```
  new：
  ```systemverilog
              dataplane.rx_engine.host_id =
                  transport_ref.iommu_host_id();
              dataplane.rx_engine.bdf = transport_ref.bdf;
              // 标准引擎经同一个 ops 收发，与 FSM/sequence 共用 DMA 所有权和通知路径。
              dataplane.bind_ops(ops);
          end
  ```
  （私有 Function 在 409-410 行已换成 `dpu_priv_*_engine`，它们覆写全部收发方法，基类 `ops` 字段被设为同一个
  私有 ops，不被读取。）

- [ ] **Step 9: 迁移另外两个 dataplane 子测试**

  `test_dataplane_tx_indirect_feature_gate` 中 old：
  ```systemverilog
          virtio_net_dataplane dataplane =
              virtio_net_dataplane::type_id::create("dataplane_gate");
  ```
  new：
  ```systemverilog
          virtio_net_dataplane dataplane =
              virtio_net_dataplane::type_id::create("dataplane_gate");
          virtio_indirect_desc_test_transport transport =
              virtio_indirect_desc_test_transport::type_id::create("dataplane_gate_transport");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("dataplane_gate_ops");
  ```
  old：
  ```systemverilog
          features = '0;
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0703);
          token = virtio_dataplane_indirect_test_packet::type_id::create("dataplane_gate_token");
  ```
  new：
  ```systemverilog
          features = '0;
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0703);
          transport.bdf = 16'h0703;
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
          ops.negotiated_features = features;
          dataplane.bind_ops(ops);
          token = virtio_dataplane_indirect_test_packet::type_id::create("dataplane_gate_token");
  ```
  old：
  ```systemverilog
          features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0703);
  ```
  new：
  ```systemverilog
          features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0703);
          ops.negotiated_features = features;
  ```
  `test_dataplane_tx_queue_full_cleanup` 中 old：
  ```systemverilog
          virtio_net_dataplane dataplane =
              virtio_net_dataplane::type_id::create("dataplane_full");
  ```
  new：
  ```systemverilog
          virtio_net_dataplane dataplane =
              virtio_net_dataplane::type_id::create("dataplane_full");
          virtio_indirect_desc_test_transport transport =
              virtio_indirect_desc_test_transport::type_id::create("dataplane_full_transport");
          virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("dataplane_full_ops");
  ```
  old：
  ```systemverilog
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0705);
          filler_token = virtio_dataplane_indirect_test_packet::type_id::create(
  ```
  new：
  ```systemverilog
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                              vq_mgr, mem, iommu, 16'h0705);
          transport.bdf = 16'h0705;
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
          ops.negotiated_features = features;
          dataplane.bind_ops(ops);
          filler_token = virtio_dataplane_indirect_test_packet::type_id::create(
  ```
  （断言保持不变：门控错误仍由引擎以 `TX_ENG` 报出且发生在任何映射之前；队列满时 ops 回滚自身映射
  （`virtio_atomic_ops.sv:1056-1068`），只有 `SPLIT_VQ` 一条错误，引擎统计不变；完成时 ops 返回提交时的 token。）

- [ ] **Step 10: multi-queue 测试绑定 ops 并断言 TX 通知**

  `virtio_net_packet_multi_queue_test.sv` old：
  ```systemverilog
  import net_packet_pkg::*;
  import virtio_net_pkg::*;

  ```
  new：
  ```systemverilog
  import net_packet_pkg::*;
  import virtio_net_pkg::*;

  // 中文说明：数据面委托 atomic ops 后会经 transport 发 notify；本测试不建 PCIe
  // 通路，用最小 transport 只记录每个队列的 notify 次数，不产生寄存器访问。
  class virtio_net_packet_mq_test_transport extends virtio_pci_transport;
      `uvm_object_utils(virtio_net_packet_mq_test_transport)

      int unsigned kicks_per_queue[int unsigned];

      function new(string name = "virtio_net_packet_mq_test_transport");
          super.new(name);
      endfunction

      virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                        bit wrap_counter);
          if (!kicks_per_queue.exists(queue_id))
              kicks_per_queue[queue_id] = 0;
          kicks_per_queue[queue_id]++;
      endtask

      function int unsigned kicks(int unsigned queue_id);
          return kicks_per_queue.exists(queue_id) ? kicks_per_queue[queue_id] : 0;
      endfunction
  endclass : virtio_net_packet_mq_test_transport

  ```
  字段 old：
  ```systemverilog
      virtio_net_dataplane     dataplane;
      split_virtqueue          queues[int unsigned];
  ```
  new：
  ```systemverilog
      virtio_net_dataplane     dataplane;
      virtio_net_packet_mq_test_transport transport;
      virtio_atomic_ops        ops;
      split_virtqueue          queues[int unsigned];
  ```
  old：
  ```systemverilog
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE,
                              2048, 0, vq_mgr, mem, iommu, DEVICE_BDF, 0);
  ```
  new：
  ```systemverilog
          dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE,
                              2048, 0, vq_mgr, mem, iommu, DEVICE_BDF, 0);
          transport = virtio_net_packet_mq_test_transport::type_id::create(
              "multi_queue_transport");
          transport.bdf = DEVICE_BDF;
          ops = virtio_atomic_ops::type_id::create("multi_queue_ops");
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
          ops.negotiated_features = features;
          dataplane.bind_ops(ops);
  ```
  old：
  ```systemverilog
              assert(queues[qid].get_free_count() == QUEUE_SIZE - 2 * PACKETS_PER_QUEUE)
                  else `uvm_fatal("NET_PACKET_TEST", "TX queue free count mismatch")
  ```
  new：
  ```systemverilog
              assert(queues[qid].get_free_count() == QUEUE_SIZE - 2 * PACKETS_PER_QUEUE)
                  else `uvm_fatal("NET_PACKET_TEST", "TX queue free count mismatch")
              assert(transport.kicks(qid) == PACKETS_PER_QUEUE)
                  else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                      "TX q%0d notified %0d times, expected %0d", qid,
                      transport.kicks(qid), PACKETS_PER_QUEUE))
  ```

- [ ] **Step 11: 运行受影响测试，确认通过**

  SYNC 后依次 ONE TEST：`virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、
  `dpu_priv_driver_flow_test`、`virtio_fabric_resource_test`（断言 dataplane 引擎 host_id，确认接线未破坏）、
  `virtio_real_driver_multiqueue_test`（经 ops 发送 packet_item，验证线速字节修正无副作用）。
  期望每个日志三行汇总均为 0；indirect 日志含 `dataplane engine notify test PASSED`。

- [ ] **Step 12: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 13: 提交**

  ```bash
  git add virtio_net_vip/src/types/virtio_net_hdr.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv \
    virtio_net_vip/src/dataplane/virtio_tx_engine.sv virtio_net_vip/src/dataplane/virtio_rx_engine.sv \
    virtio_net_vip/src/dataplane/virtio_net_dataplane.sv virtio_net_vip/src/sriov/virtio_function_instance.sv \
    virtio_net_vip/tests/virtio_indirect_desc_test.sv virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv
  git commit -m "fix: TX 引擎委托 atomic ops 提交，发送后真实通知设备"
  ```

---

### Task P0-5: RX 引擎委托 atomic ops，补充 buffer 后真实通知设备（规范 P0.1/P2.1，RX 部分）

**Files:**
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv:361`（新增 `virtio_rx_frame_t`）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:1140-1159,1232-1329`（`rx_refill` 增加 `buf_size`；`rx_receive` 拆出 `rx_receive_frames`）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv:297-299`（`rx_refill` 签名同步）
- Modify: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv:95`（`rx_refill` 覆写签名同步）
- Modify: `virtio_net_vip/src/dataplane/virtio_rx_engine.sv:148-210,223-247`（`refill_buffers`、`receive_packets` 改为薄适配）
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv`（扩展 `test_dataplane_engine_notifies_device` 的 RX 部分）
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`（RX 通知断言）
- Test: `virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、`virtio_pf_lifecycle_reset_test`、`dpu_priv_driver_flow_test`、`virtio_real_driver_rx_test`、`virtio_real_driver_flow_test`

**Interfaces:**
- Consumes: P0-4 的 `virtio_rx_engine::ops`、`virtio_net_dataplane::bind_ops`、测试件 `virtio_net_packet_mq_test_transport::kicks()`。
- Produces:
  - `typedef struct { byte unsigned payload[$]; virtio_net_hdr_t net_hdr; uvm_object token; int unsigned num_buffers; } virtio_rx_frame_t;`
  - `virtual task virtio_atomic_ops::rx_refill(int unsigned queue_id, int unsigned num_bufs, int unsigned buf_size = 0)`（0 = 原默认 header+1514；所有覆写须同签名）
  - `virtual task virtio_atomic_ops::rx_receive_frames(int unsigned queue_id, int unsigned max_budget, ref virtio_rx_frame_t frames[$])`
  - `rx_receive(int unsigned, ref uvm_object[$], int unsigned)` 签名与可观察行为不变（改为基于 `rx_receive_frames`）。
  - 引擎公共签名不变：`refill_buffers(int unsigned, int unsigned)`、`receive_packets(int unsigned, int unsigned, ref uvm_object[$])`。

- [ ] **Step 1: 写失败测试（RX 通知）**

  `virtio_indirect_desc_test.sv` 的 `test_dataplane_engine_notifies_device` 中，声明区 old：
  ```systemverilog
          virtqueue_base base_vq;
          split_virtqueue tx_vq;
          virtio_dataplane_indirect_test_packet token;
          uvm_object completed[$];
          bit [63:0] features;
          int unsigned desc_id;
  ```
  new：
  ```systemverilog
          virtqueue_base base_vq;
          split_virtqueue tx_vq;
          split_virtqueue rx_vq;
          virtio_dataplane_indirect_test_packet token;
          uvm_object completed[$];
          uvm_object received[$];
          byte frame[];
          iommu_fault_e fault;
          bit [63:0] addr;
          bit [31:0] len;
          bit [15:0] flags;
          bit [15:0] next;
          bit [63:0] features;
          int unsigned desc_id;
  ```
  old：
  ```systemverilog
          tx_vq.alloc_rings();

          transport.bdf = 16'h0706;
  ```
  new：
  ```systemverilog
          tx_vq.alloc_rings();
          base_vq = vq_mgr.create_queue(0, 8, VQ_SPLIT);
          assert($cast(rx_vq, base_vq))
              else `uvm_fatal("INDIRECT_TEST", "failed to create dataplane notify RX queue")
          rx_vq.alloc_rings();

          transport.bdf = 16'h0706;
  ```
  old：
  ```systemverilog
              else `uvm_fatal("INDIRECT_TEST", "dataplane TX completion did not return the token")
          tx_vq.free_rings();
  ```
  new：
  ```systemverilog
              else `uvm_fatal("INDIRECT_TEST", "dataplane TX completion did not return the token")

          // RX 补充同样必须经 transport 通知；修复前引擎只调 virtqueue::kick()。
          dataplane.rx_engine.refill_buffers(0, 1);
          assert((transport.kick_count == 2) && (transport.last_kick_queue_id == 0) &&
                 (rx_vq.get_pending_count() == 1))
              else `uvm_fatal("INDIRECT_TEST", $sformatf(
                  "dataplane RX refill did not notify the device (kicks=%0d pending=%0d)",
                  transport.kick_count, rx_vq.get_pending_count()))

          read_desc(mem, rx_vq.desc_table_addr, 0, addr, len, flags, next);
          assert(len == 1526)
              else `uvm_fatal("INDIRECT_TEST", $sformatf(
                  "dataplane RX buffer length %0d, expected engine buf_size 1526", len))
          frame = new[10 + 64];
          for (int unsigned i = 0; i < 10; i++) frame[i] = 8'h00;
          for (int unsigned i = 10; i < frame.size(); i++) frame[i] = i[7:0];
          assert(iommu.write_from_device_for_host(0, mem, 16'h0706, addr, frame, fault))
              else `uvm_fatal("INDIRECT_TEST", "device RX write failed")
          complete_split(mem, rx_vq, 0, frame.size());
          dataplane.rx_engine.receive_packets(0, 1, received);
          assert((received.size() == 1) && (rx_vq.get_pending_count() == 0) &&
                 (dataplane.rx_engine.total_rx_packets == 1))
              else `uvm_fatal("INDIRECT_TEST", "dataplane RX did not return the completed frame")
          rx_vq.free_rings();
          tx_vq.free_rings();
  ```

- [ ] **Step 2: 运行，确认失败**

  SYNC 后 ONE TEST（`TEST=virtio_indirect_desc_test`）。期望：
  `UVM_FATAL ... [INDIRECT_TEST] dataplane RX refill did not notify the device (kicks=1 pending=1)`。

- [ ] **Step 3: 新增帧类型**

  `virtio_net_types.sv` 361 行 old：
  ```systemverilog
  } virtio_net_hdr_t;
  ```
  new：
  ```systemverilog
  } virtio_net_hdr_t;

  // 一次 RX 完成（含 MRG_RXBUF 合并）的结果：去掉 virtio-net header 的 payload、
  // 解析出的 header、首个 used 项的 token 以及消耗的 buffer 数。由
  // virtio_atomic_ops.rx_receive_frames 产生，DMA 所有权在返回前已退休。
  typedef struct {
      byte unsigned    payload[$];
      virtio_net_hdr_t net_hdr;
      uvm_object       token;
      int unsigned     num_buffers;
  } virtio_rx_frame_t;
  ```

- [ ] **Step 4: `ops.rx_refill` 支持调用方指定 buffer 容量**

  `virtio_atomic_ops.sv` 1140-1159 行 old：
  ```systemverilog
      virtual task rx_refill(
          int unsigned     queue_id,
          int unsigned     num_bufs
      );
          virtqueue_base   vq;
          int unsigned     buf_size;
          int unsigned     buf_dma_size;
          int unsigned     hdr_size;
          int unsigned     filled = 0;

          vq = vq_mgr.get_queue(queue_id);
          if (vq == null) return;

          // Determine buffer size based on header size + typical MTU
          hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

          // Use reasonable default: header + 1514 (standard Ethernet MTU)
          buf_size = hdr_size + 1514;
          buf_dma_size = (buf_size + 3) & ~3;
  ```
  new：
  ```systemverilog
      // buf_size 为描述符可写长度（含 virtio-net header）；0 表示默认 header+1514，
      // dataplane 引擎传入其配置容量。所有覆写须保持同一签名。
      virtual task rx_refill(
          int unsigned     queue_id,
          int unsigned     num_bufs,
          int unsigned     buf_size = 0
      );
          virtqueue_base   vq;
          int unsigned     buf_dma_size;
          int unsigned     hdr_size;
          int unsigned     filled = 0;

          vq = vq_mgr.get_queue(queue_id);
          if (vq == null) return;

          // Determine buffer size based on header size + typical MTU
          hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

          // Use reasonable default: header + 1514 (standard Ethernet MTU)
          if (buf_size == 0)
              buf_size = hdr_size + 1514;
          buf_dma_size = (buf_size + 3) & ~3;
  ```
  `dpu_priv_atomic_ops.sv` 297-299 行 old：
  ```systemverilog
      // 按配置容量投递零初始化 RX buffer，无 Virtio header 预留；申请失败停止补充，
      // 已投递部分仍保持有效，随后用私有 doorbell 发布。
      virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs);
  ```
  new：
  ```systemverilog
      // 按配置容量投递零初始化 RX buffer，无 Virtio header 预留；申请失败停止补充，
      // 已投递部分仍保持有效，随后用私有 doorbell 发布。容量固定取私有配置
      // rx_size，忽略 buf_size（参数仅为保持统一 ops 签名）。
      virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs,
                             int unsigned buf_size = 0);
  ```
  `virtio_pf_lifecycle_reset_test.sv` 95 行 old：
  ```systemverilog
      virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs);
  ```
  new：
  ```systemverilog
      virtual task rx_refill(int unsigned queue_id, int unsigned num_bufs,
                             int unsigned buf_size = 0);
  ```
  （其余调用方 `virtio_driver.sv:153`、`virtio_auto_fsm.sv:877/1873/1932`、`virtio_real_driver_flow_fixture.sv:982`、
  `virtio_indirect_desc_test.sv:1045`、`virtio_pf_lifecycle_reset_test.sv:693`、`dpu_priv_driver_flow_test.sv:229` 都是两参数调用，
  使用默认值，无需修改。）

- [ ] **Step 5: 拆出 `rx_receive_frames`，`rx_receive` 基于它实现**

  `virtio_atomic_ops.sv` 1232-1329 行（`rx_receive` 的注释头到 `endtask`）整体替换为：
  ```systemverilog
      // ------------------------------------------------------------------------
      // rx_receive_frames -- Poll used ring and return header + payload frames
      //
      // 每个 used 项按 MRG_RXBUF 语义合并后续 buffer；每个描述符的 IOVA/GPA
      // 所有权在复制后立即退休。帧追加到 frames，不解析报文协议。
      // ------------------------------------------------------------------------
      virtual task rx_receive_frames(
          int unsigned          queue_id,
          int unsigned          max_budget,
          ref virtio_rx_frame_t frames[$]
      );
          virtqueue_base   vq;
          uvm_object       token;
          int unsigned     len;
          int unsigned     count = 0;
          int unsigned     hdr_size;

          vq = vq_mgr.get_queue(queue_id);
          if (vq == null) return;

          hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

          while (count < max_budget) begin
              if (vq.poll_used(token, len)) begin
                  normal_dma_record_t record;
                  byte buf_data[];
                  byte unsigned first_bytes[$];
                  virtio_rx_frame_t frame;

                  if (!rx_dma_map.exists(queue_id) ||
                      (rx_dma_map[queue_id].size() == 0)) begin
                      `uvm_error("ATOMIC_OPS", $sformatf(
                          "rx_receive: used entry has no DMA ownership queue=%0d",
                          queue_id))
                      break;
                  end
                  record = rx_dma_map[queue_id].pop_front();
                  mem.read_mem(record.gpa, len, buf_data);
                  foreach (buf_data[i]) first_bytes.push_back(buf_data[i]);
                  if (buf_data.size() < hdr_size) begin
                      `uvm_error("ATOMIC_OPS", $sformatf(
                          "rx_receive: buffer shorter than virtio header queue=%0d len=%0d hdr=%0d",
                          queue_id, buf_data.size(), hdr_size))
                      retire_normal_dma_record(record);
                      break;
                  end
                  virtio_net_hdr_util::unpack_hdr(first_bytes,
                                                  negotiated_features, frame.net_hdr);
                  for (int unsigned i = hdr_size; i < buf_data.size(); i++)
                      frame.payload.push_back(buf_data[i]);
                  // Only MRG_RXBUF gives num_buffers meaning; a VERSION_1
                  // header carries the field for a single-buffer packet.
                  frame.num_buffers = ((frame.net_hdr.num_buffers == 0) ||
                                       !negotiated_features[VIRTIO_NET_F_MRG_RXBUF]) ? 1 :
                                      frame.net_hdr.num_buffers;
                  frame.token = token;
                  retire_normal_dma_record(record);

                  // Merge continuation buffers.  Every consumed descriptor
                  // retires its own IOVA/GPA ownership only after its bytes
                  // are copied.
                  for (int unsigned merge = 1; merge < frame.num_buffers; merge++) begin
                      normal_dma_record_t merge_record;
                      byte merge_data[];
                      uvm_object merge_token;
                      int unsigned merge_len;
                      if (!vq.poll_used(merge_token, merge_len) ||
                          !rx_dma_map.exists(queue_id) ||
                          (rx_dma_map[queue_id].size() == 0)) begin
                          `uvm_error("ATOMIC_OPS", $sformatf(
                              "rx_receive: missing merged buffer queue=%0d expected=%0d got=%0d",
                              queue_id, frame.num_buffers, merge))
                          break;
                      end
                      merge_record = rx_dma_map[queue_id].pop_front();
                      mem.read_mem(merge_record.gpa, merge_len, merge_data);
                      foreach (merge_data[i]) frame.payload.push_back(merge_data[i]);
                      retire_normal_dma_record(merge_record);
                  end

                  frames.push_back(frame);
                  count++;
              end else begin
                  break;
              end
          end

          if (rx_dma_map.exists(queue_id) &&
              (rx_dma_map[queue_id].size() == 0))
              rx_dma_map.delete(queue_id);
      endtask

      // ------------------------------------------------------------------------
      // rx_receive -- Poll used ring for received packets
      //
      // 合法以太网帧解析为 packet_item；解析失败时若 used 项带 token 则返回 token。
      // ------------------------------------------------------------------------
      virtual task rx_receive(
          int unsigned     queue_id,
          ref uvm_object   received_pkts[$],
          int unsigned     max_budget
      );
          virtio_rx_frame_t frames[$];

          rx_receive_frames(queue_id, max_budget, frames);
          foreach (frames[i]) begin
              packet_item parsed_item;
              if (virtio_net_packet_adapter::unpack(frames[i].payload, parsed_item))
                  received_pkts.push_back(parsed_item);
              else if (frames[i].token != null)
                  received_pkts.push_back(frames[i].token);
          end

          if (frames.size() > 0)
              `uvm_info("ATOMIC_OPS",
                  $sformatf("rx_receive: queue_id=%0d received=%0d", queue_id, frames.size()), UVM_HIGH)
      endtask
  ```
  （与原实现逐分支等价：相同的错误消息、break 位置、合并与退休顺序；原实现缺少续 buffer 时仍解析部分 payload
  并计数，这里同样推入部分帧并计数。`dpu_priv_atomic_ops` 覆写的是 `rx_receive`，不受影响。）

- [ ] **Step 6: RX 引擎改为薄适配**

  `virtio_rx_engine.sv` 148-210 行（`refill_buffers` 的两行中文注释 + 任务体）替换为：
  ```systemverilog
      // 向 queue_id 最多补充 count 个可写 buffer（容量取 get_rx_buf_size()），受空闲
      // 描述符限制；分配、映射、所有权登记与真实 notify 由 ops 执行。队列不存在则报错。
      virtual task refill_buffers(
          int unsigned queue_id,
          int unsigned count
      );
          if ((ops == null) || (ops.vq_mgr == null) ||
              (ops.vq_mgr.get_queue(queue_id) == null)) begin
              `uvm_error("RX_ENG",
                  $sformatf("refill_buffers: queue %0d not found", queue_id))
              return;
          end
          ops.rx_refill(queue_id, count, get_rx_buf_size());
          `uvm_info("RX_ENG",
              $sformatf("refill_buffers: queue=%0d requested=%0d buf_size=%0d",
                        queue_id, count, get_rx_buf_size()),
              UVM_HIGH)
      endtask : refill_buffers
  ```
  223-247 行（`receive_packets` 的两行中文注释 + 任务体）替换为：
  ```systemverilog
      // 经 ops 取得至多 budget 个帧（ops 完成合包与 DMA 回收），可选校验 RX checksum，
      // 合法帧返回 packet_item、非法帧返回 wrapper；之后按 free-count 门限补充。
      virtual task receive_packets(
          int unsigned      queue_id,
          int unsigned      budget,
          ref uvm_object    received[$]
      );
          virtqueue_base    vq;
          virtio_rx_frame_t frames[$];

          if ((ops == null) || (ops.vq_mgr == null)) begin
              `uvm_error("RX_ENG", $sformatf(
                  "receive_packets: queue %0d has no bound atomic ops", queue_id))
              return;
          end
          vq = ops.vq_mgr.get_queue(queue_id);
          if (vq == null) begin
              `uvm_error("RX_ENG",
                  $sformatf("receive_packets: queue %0d not found", queue_id))
              return;
          end

          ops.rx_receive_frames(queue_id, budget, frames);
          foreach (frames[i]) begin
              if (negotiated_features[VIRTIO_NET_F_GUEST_CSUM] &&
                  !offload.verify_rx_csum(frames[i].net_hdr, frames[i].payload))
                  `uvm_warning("RX_ENG", $sformatf(
                      "receive_packets: RX checksum verification failed, pkt_size=%0d",
                      frames[i].payload.size()))
              if (frames[i].num_buffers > 1)
                  total_rx_merged++;
              received.push_back(build_received_packet(frames[i].payload,
                                                       frames[i].net_hdr));
              total_rx_packets++;
              total_rx_bytes += frames[i].payload.size();
          end

          `uvm_info("RX_ENG",
              $sformatf("receive_packets: queue=%0d received=%0d", queue_id, frames.size()),
              UVM_HIGH)

          // Auto-refill if free count drops below threshold
          if (vq.get_free_count() < refill_threshold)
              refill_buffers(queue_id, refill_threshold);
      endtask : receive_packets
  ```
  （`dpu_priv_rx_engine` 覆写 `refill_buffers/receive_packets/get_rx_buf_size`，不受影响。）

- [ ] **Step 7: multi-queue 测试断言 RX 通知**

  `virtio_net_packet_multi_queue_test.sv` old：
  ```systemverilog
              dataplane.rx_engine.refill_buffers(qid, PACKETS_PER_QUEUE);
              assert(read_u16(queues[qid].driver_ring_addr + 2) == PACKETS_PER_QUEUE)
                  else `uvm_fatal("NET_PACKET_TEST", "RX avail index mismatch")
  ```
  new：
  ```systemverilog
              dataplane.rx_engine.refill_buffers(qid, PACKETS_PER_QUEUE);
              assert(read_u16(queues[qid].driver_ring_addr + 2) == PACKETS_PER_QUEUE)
                  else `uvm_fatal("NET_PACKET_TEST", "RX avail index mismatch")
              assert(transport.kicks(qid) == 1)
                  else `uvm_fatal("NET_PACKET_TEST", $sformatf(
                      "RX q%0d refill notified %0d times, expected 1", qid,
                      transport.kicks(qid)))
  ```

- [ ] **Step 8: 运行受影响测试，确认通过**

  SYNC 后依次 ONE TEST：`virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、
  `virtio_pf_lifecycle_reset_test`、`dpu_priv_driver_flow_test`、`virtio_real_driver_rx_test`、`virtio_real_driver_flow_test`。
  期望每个日志三行汇总均为 0；multi-queue 日志含 `packet_item multi-queue TX/RX dataplane test PASSED`。

- [ ] **Step 9: 回归**

  REGRESSION；期望 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 10: 提交**

  ```bash
  git add virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv \
    virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv virtio_net_vip/src/dataplane/virtio_rx_engine.sv \
    virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv virtio_net_vip/tests/virtio_indirect_desc_test.sv \
    virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv
  git commit -m "fix: RX 引擎委托 atomic ops 补充与收包，补充后真实通知设备"
  ```

---

### Notes for integrator（P0）

**本阶段产出、供后续阶段使用的接口**
- `virtio_net_dataplane::bind_ops(virtio_atomic_ops ops)`；`virtio_tx_engine::ops`、`virtio_rx_engine::ops`。Function 在
  `commit_validated_pcie_components` 中自动绑定；独立构造 dataplane 的测试必须显式调用（P2.8 的
  `virtio_vq_test_kit.make_ops` 可顺带完成）。
- `virtio_net_hdr_util::build_tx_hdr(input byte unsigned pkt_data[$], input bit [63:0] features, input virtio_offload_engine offload, output virtio_net_hdr_t hdr)`。
  P1.5 若合并 `needs_uso/get_all_hdr_len`，需同步改此函数内的 offload 调用。
- `virtio_atomic_ops::rx_refill(int unsigned queue_id, int unsigned num_bufs, int unsigned buf_size = 0)`——任何新覆写
  （含 P2.8 测试件）必须带第三个参数。
- `virtio_atomic_ops::rx_receive_frames(int unsigned queue_id, int unsigned max_budget, ref virtio_rx_frame_t frames[$])` 与
  `virtio_rx_frame_t`（`virtio_net_types.sv`）。
- `ctrl_send` 失败契约（见 P0-3 Interfaces）。
- 新维护测试 `virtio_ctrl_vq_test`（manifest 位于 `virtio_admin_vq_test` 之后）及测试件
  `virtio_ctrl_vq_test_transport/_mq_ops/_mem/_iommu/_catcher`；P2.8 的 `virtio_mock_transport` 可替换
  `virtio_ctrl_vq_test_transport`、`virtio_net_packet_mq_test_transport`、`virtio_indirect_desc_test_transport`、
  `virtio_pf_lifecycle_test_transport`、`virtio_migration_dirty_test_transport`（P2.8 规范说“4 个测试内的 transport 子类”，P0 后为 6 个）。
- 维护清单数量：P0-1 后 39，P0-2 起 40。README（`VIRTIO_MAINTAINED_TESTS` 段落）与手册（6.1 节同名段落）必须与 manifest
  同序同数（`_validate_documentation_contracts`），后续增删测试的阶段（P1.8 删 `virtio_base_test` 不在清单，不涉及）都要同步这两处。

**P0-4/P0-5 之后变为不可达、交给 P2-1 删除的符号**（行号为 HEAD `62ae3e9` 原位置）
- `virtio_tx_engine.sv`：`virtio_buf_tracker` 类（:4-35，P0 后只剩 rx 引擎死代码引用）、`tx_buf_map`（:84-87）、
  `submit_single`（:149-217，内含 `custom_cb` 分支 :179-183）、`standard_tx_build_chain`（:219-271）、`cleanup_tx_buffers`（:353-377）；
  字段 `vq_mgr`、`mem`、`iommu`、`mtu` 不再被活代码读取（`virtio_net_dataplane.configure` :79-86 与
  `virtio_function_instance.sv:412-423` 仍会赋值，删除时同步删这些赋值）；`print_stats/leak_check` 读 `tx_buf_map`，删表时改写或删除二者。
- `virtio_rx_engine.sv`：`rx_buf_gpa_to_iova/rx_buf_gpa_to_size`（:85-87）、`receive_mergeable`（:249-389）、`receive_big`
  （:391-403）、`receive_small`（:405-417）、`receive_single_buf`（:419-514）、`custom_receive`（:516-582，读 `custom_cb`）、
  `cleanup_rx_buffer`（:584-601）；字段 `vq_mgr`、`mem`、`iommu` 同上；`print_stats/leak_check` 读 `rx_buf_gpa_to_iova`。
- 保留：`extract_pkt_data`、`virtio_byte_queue_t`、`build_received_packet`、`virtio_rx_pkt_wrapper`（`virtio_scoreboard.sv:474` 使用）、
  `get_rx_buf_size`、统计字段，以及 `host_id/bdf`（`virtio_fabric_resource_test.sv:969-971` 断言）。
- 新适配器已不读 `custom_cb`；P1.3 删除 `custom_cb` 字段时，上述死方法里的引用（tx `submit_single`、rx `custom_receive`）必须
  一起删掉，否则编译失败。P1 在 P2 之前执行，建议 P1.3 直接删除 `submit_single`、`standard_tx_build_chain`、`custom_receive`
  （或把这几个死方法的删除提前到 P1.3），并与 P2-1 的删除清单去重。
- `dpu_priv_dataplane` 简化（P2.1“仅选择私有 ops”）的前提：`dpu_priv_atomic_ops` 需覆写 `rx_receive_frames`（目前只覆写
  `rx_receive`），否则私有 RX 引擎改用基类 `receive_packets` 会走标准 header 解析；`tx_submit`、`tx_complete`、`rx_refill` 已有私有覆写。
  私有 TX 要求 header 全零：Function 内引擎的 `negotiated_features` 从未被设置（=0），基类 `build_tx_hdr` 正好产出全零；
  私有 `get_rx_buf_size` 覆写返回不含 header 的容量，私有 `rx_refill` 忽略 `buf_size`。

**顺序依赖**
- P0-1 先于全部任务（之后的回归即覆盖私有环测试；53 主机上的 `~/virtio_priv_run/run_priv.sh` 调用已删除的
  `examples/dpu_priv_ring/run_vcs.sh` 和 `build/examples/dpu_priv_ring/simv`，P0-1 起改用 ONE TEST 命令，或把该脚本改为两次
  `TEST=... ./scripts/vcs.sh`）。
- P0-2 创建 `virtio_ctrl_vq_test.sv`，P0-3 在其上追加；P0-4 先于 P0-5（P0-5 复用 P0-4 的 `ops` 字段、`bind_ops`、
  multi-queue 测试件和 indirect 新子测试）。
- P2.3 的 `virtio_dma_buffer_set`/`kick_with_fault` 要替换 `tx_submit`、`rx_refill`、`ctrl_send` 的手写回滚，必须保持
  P0-3 的失败契约、P0-4 的线速字节提取与 P0-5 的 `buf_size` 参数。
- P2.5 删除 `bind_pcie_components` 时注意 `commit_validated_pcie_components` 里新增的 `dataplane.bind_ops(ops)` 须保留在唯一提交入口中。

**风险**
- P0-1：三个示例文件首次与 `tests.f`、`queue_work_integration.f` 同一编译，可能出现 wildcard import 二义性或 VCS
  `Warning-[`（严格回归会拒绝）；Step 8 单独编译即可暴露，按提示限定标识符修正。
- P0-2：control VQ 号可大于 `2*num_pairs`（`num_pairs < max_virtqueue_pairs` 时）。以下既有代码仍假设队列号连续 `0..2N`，
  维护回归未覆盖、本阶段未改：`virtio_atomic_ops.setup_msix`（:2065 按 0..num_queues-1 写队列向量，control VQ 得不到向量，
  反而写到不存在的队列 `2N`）、`virtio_auto_fsm` 迁移 freeze/restore（:1223-1230、:1741-1748 用 `get_queue(q)` 遍历
  `0..num_total_queues-1`，并在 :1396 校验 `queue_snapshots[q].queue_id == q`）。修复前这两处在 MQ 扩容后同样出错，
  但 `num_pairs < max` 且不扩容的场景是本修复后新出现的问题。建议在 P3 拆出 `virtio_migration_engine` 时统一“槽位→队列号”，
  并补一条 CTRL_VQ+MQ、`num_pairs < max` 的迁移/MSI-X 测试。另外 `setup_all_queues` 在协商 MQ+CTRL_VQ 时新增一次 device-config 读
  （`read_net_config`），设备需能响应该 BAR 偏移；当前维护测试中走生产 `setup_all_queues` 且协商 MQ 的只有本任务新测试。
- P0-3：`ctrl_send` 的 `add_buf` 返回 `'1` 仍未检查（会 kick 后轮询超时，再正常清理，不泄漏）；未纳入本任务，可在 P2.3 一并处理。
- P0-4：`ops.tx_complete` 按提交顺序 FIFO 回收每包 2 条记录，原引擎按 token 回收、可容忍乱序完成；维护测试都是顺序完成。
  `ops.tx_submit` 对 `packet_item` 改发线速帧（见 Spec deviation），经 `fsm.send_packets`/`virtio_real_driver_flow_fixture.submit_tx`
  发出的 packet_item 描述符长度减少 4 字节；TX buffer 改为 ops 的 DWORD 填充分配。
- P0-5：RX buffer 由 `align(64)` 精确大小改为 ops 的 `align(1)` DWORD 填充分配，描述符长度不变；原引擎在 RX 错误项上
  `continue`，ops 路径 `break`（剩余完成项留待下次轮询），只影响错误场景。

**Spec deviations 汇总**
- P0.2：修复点只在 `virtio_atomic_ops.setup_all_queues`；`virtio_auto_fsm.do_configure_mq`（规范所列 :1132）无需修改。
- P0.1：额外修正 `virtio_atomic_ops.tx_submit` 对 `packet_item` 发送 UVM 长度前缀的问题（保证引擎委托后字节等价）；
  新增 ops 接口 `rx_refill` 第三参数 `buf_size` 与 `rx_receive_frames`（引擎需要可配置的 buffer 容量、RX checksum 校验所需
  header 与 wrapper 回退，现有 `rx_refill/rx_receive` 无法表达）。P0.1 拆成 P0-4（TX）与 P0-5（RX）两个可独立评审的提交。
- P0.4：删除 `examples/dpu_priv_ring/run_vcs.sh`、`example.f` 与 `dpu_priv_ring_tb_top`（与 `scripts/vcs.sh` 冗余）；
  `examples/virtio_system_env/example.f` 因示例源文件进入 `tests.f` 一并删除，该目录的 `run_vcs.sh` 保留并改用 `tests.f`。
- P0.2/P0.3 的复现测试放在新维护测试 `virtio_ctrl_vq_test`，清单因此为 40 项（规范基线 37 + 私有环 2 + 本测试 1）。

---

## P1：纯删除（P1.1–P1.9）

本阶段只删除无调用代码，不改变已维护测试的行为。所有 "0 引用" 结论已在 HEAD `62ae3e9` 上用
`grep` 对 `virtio_net_vip/src`、`virtio_net_vip/tests`、`examples/`、`scripts/`、`filelists/` 复核；
与 spec 不一致之处在对应任务中以 **Spec deviation** 标出。

### 执行前提与通用工具

- P0 必须已全部合入（P0 改动了 `virtio_tx_engine.sv`、`virtio_rx_engine.sv`、`virtio_atomic_ops.sv`、
  `split/packed_virtqueue.sv`、`virtio_net_dataplane.sv`、`filelists/tests.f`、`scripts/test_manifest.sh`、
  README/手册的维护测试清单等），因此本阶段**不使用 HEAD 绝对行号直接删除**。块删除一律用
  "唯一整行锚点 + 固定偏移"（块内部 P0 不改动，偏移不变），单行删除用整行文本匹配，
  小改动用 old → new 片段（Edit 工具语义：old 必须唯一匹配）。
- 下文给出的 `HEAD 行 a–b` 仅供核对；真正删除以 `p1_del` 打印的首/尾行为准。
- 每个任务开始前，在仓库根目录（59 上 `~/workspace/ryan/virtio_work`）的 shell 中先定义：

```bash
# 用法：p1_del <file> '<锚点整行文本>' <锚点前行数> <锚点后行数>
# 锚点必须恰好整行匹配一次；打印将删除区间的首/尾行及区间外相邻行供核对，然后删除闭区间。
p1_del() {
  local f="$1" line="$2" b="$3" a="$4" hits n s e
  hits=$(grep -nxF -- "$line" "$f" | cut -d: -f1)
  if [ "$(printf '%s\n' "$hits" | grep -c .)" -ne 1 ]; then
    echo "ANCHOR NOT UNIQUE/ABSENT in $f: $line" >&2; return 1
  fi
  n=$hits; s=$((n-b)); e=$((n+a))
  printf 'DELETE %s:%d-%d\n  first : [%s]\n  last  : [%s]\n  keep- : [%s]\n  keep+ : [%s]\n' \
    "$f" "$s" "$e" "$(sed -n "${s}p" "$f")" "$(sed -n "${e}p" "$f")" \
    "$(sed -n "$((s-1))p" "$f")" "$(sed -n "$((e+1))p" "$f")"
  sed -i "${s},${e}d" "$f"
}
# 用法：p1_del_line <file> '<整行文本>'   —— 删除恰好出现一次的整行
p1_del_line() {
  local f="$1" line="$2" hits
  hits=$(grep -nxF -- "$line" "$f" | cut -d: -f1)
  if [ "$(printf '%s\n' "$hits" | grep -c .)" -ne 1 ]; then
    echo "LINE NOT UNIQUE/ABSENT in $f: $line" >&2; return 1
  fi
  sed -i "${hits}d" "$f"
}
```

- 每条 `p1_del` 后面给出的 "预期" 是打印出的 `first/last/keep-/keep+`；不一致立即停止，回到对应文件人工定位。
- 任务顺序固定：P1-1 → P1-2 → … → P1-9（P1-1 先删 sequence 库，后续任务的 grep 证据才不会被 seq 文件干扰；
  多个任务改同一文件，如 `virtio_net_pkg.sv`、`virtio_net_types.sv`、`virtio_scoreboard.sv`、
  `virtio_net_dataplane.sv`、`virtio_rx_engine.sv`，全部用锚点，顺序无关行号）。
- ONE TEST 预期统一为：无 `Error-` 行；摘要中 `UVM_ERROR :    0`、`UVM_FATAL :    0`，
  `UVM_WARNING` 计数与 P1 开始前该测试的基线相同（P1 开始前先跑一遍记录基线）。
- REGRESSION 预期统一为：第一条 grep 无输出，最后一行 `STRICT_REGRESSION PASS tests=<N>`，
  `<N>` 等于 P0 完成后 manifest 的条目数（P1 不增删 manifest 条目；P1-8 删除的 `virtio_base_test` 本就不在 manifest）。

---

### Task P1-1: 删除 sequence 库、virtual sequencer 及 env 的 `v_seqr` 装配

**Files:**
- Delete: `virtio_net_vip/src/seq/`（33 个文件，2,796 行）
- Delete: `virtio_net_vip/src/env/virtio_virtual_sequencer.sv`（46 行）
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:5,126,133-191`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv:23,80-82,425-427,434-435,498-507,545-550,686,696,712-717,970-971`
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv:673-675,1051-1067,1221,1228,2619,2662,2688,2717,2743,2777,2788,2823,2905,2958,2995,3019,3059,3104,3131,3209-3271,3293,3857`
- Test: `virtio_net_vip/tests/virtio_dut_caps_test.sv`

**Interfaces:**
- Consumes: `virtio_function_instance` 在 PCIe commit 时设置 `transport.bar.pcie_rc_seqr`（`virtio_function_instance.sv:386`，`transport_ref.bar.pcie_rc_seqr = pcie_rc_seqr;`）——用作 dut_caps 正向断言的替代观测点。
- Produces: `virtio_net_env` 不再有 `v_seqr` 成员；`bind_pcie()`/`bind_pcie_endpoints()` 签名不变，不再对 virtual sequencer 判空。`virtio_sequencer`（agent 内）保留。

**证据（HEAD）：** seq 下 34 个类名（`virtio_*_seq`、`virtio_*_vseq`、`virtio_live_migration_packet`、`virtio_virtual_sequencer`）在 seq 目录之外只出现在 `virtio_net_pkg.sv` 的 include 与 `virtio_net_env.sv`/`virtio_dut_caps_test.sv` 的 `v_seqr`。
`dpu_pcie_tl_executor_integration_test.sv:104` 的 `pcie_env.v_seqr` 是 `pcie_tl_env` 自己的成员，与本任务无关，保留。

- [ ] **Step 1: 删除文件**

```bash
git rm -r -q virtio_net_vip/src/seq virtio_net_vip/src/env/virtio_virtual_sequencer.sv
```

- [ ] **Step 2: 修改 `virtio_net_pkg.sv`**

```bash
f=virtio_net_vip/src/virtio_net_pkg.sv
p1_del_line $f '  `include "env/virtio_virtual_sequencer.sv"'
p1_del $f '  // 第 9 层 – 序列库（seq/）' 2 56
```
预期打印：`first : []`（空行）、`last : [  `include "seq/virtual/virtio_stress_vseq.sv"]`、`keep- : [  `include "env/virtio_net_env.sv"]`、`keep+ : []`。

文件头注释（Edit）：
old:
```
// 队列、传输、agent、数据面、SR-IOV、环境和序列的依赖顺序纳入本地源码。
```
new:
```
// 队列、传输、agent、数据面、SR-IOV 和环境的依赖顺序纳入本地源码。
```

- [ ] **Step 3: 修改 `virtio_net_env.sv`**

```bash
f=virtio_net_vip/src/env/virtio_net_env.sv
p1_del_line $f '//   - Virtual sequencer (aggregates per-VF sequencers)'
p1_del $f '    virtio_virtual_sequencer        v_seqr;' 2 0
#   预期 first:[] last:[    virtio_virtual_sequencer        v_seqr;] keep-:[    protected int unsigned           protocol_event_vif_index;] keep+:[]
p1_del $f '        v_seqr = virtio_virtual_sequencer::type_id::create("v_seqr", this);' 2 0
#   预期 first:[] last:[        v_seqr = virtio_virtual_sequencer::type_id::create(...)] keep-:[        end] keep+:[]
p1_del $f '        // 将各功能的 sequencer 和共享 Host/IOMMU 引用接入虚拟 sequencer。' 0 9
#   预期 first:[        // 将各功能的 sequencer ...] last:[] keep-:[] keep+:[        // Wire concurrency controller]
p1_del $f '                "bind_pcie() received a null virtual sequencer")' 2 3
#   预期 first:[        if (v_seqr == null) begin] last:[        end] keep-:[        end] keep+:[]
p1_del_line $f '        v_seqr.pcie_rc_seqr = pcie_rc_seqr;'
p1_del $f '                "bind_pcie_endpoints() received a null virtual sequencer")' 2 3
#   预期 first:[        if (v_seqr == null) begin] last:[        end] keep-:[            return 0;] keep+:[]
p1_del $f '            v_seqr.pcie_rc_seqr = selected_endpoints[0].rc_seqr;' 1 0
#   预期 first:[        if (selected_endpoints.size() != 0)] keep-:[        end] keep+:[        protocol_event_vif_index = next_protocol_event_vif_index;]
```

注释（Edit 1）old:
```
    // Wire shared components into VF instances, connect analysis ports to
    // scoreboard/coverage, and set up the virtual sequencer.
```
new:
```
    // Wire shared components into VF instances and connect analysis ports to
    // scoreboard/coverage.
```
注释（Edit 2）old:
```
    // monitor, FSM, or virtual-sequencer state is committed.
```
new:
```
    // monitor, or FSM state is committed.
```

- [ ] **Step 4: 修改 `virtio_dut_caps_test.sv`**

失败路径断言中的 `X_env.v_seqr.pcie_rc_seqr != null` 与已存在的 `binding_configuration_valid()`/`bound_protocol_vif_count()` 冗余，直接删除条件行；
诊断打印参数改为同一 Function 的 `transport.bar.pcie_rc_seqr != null`，保持 `$sformatf` 参数个数不变；
唯一的正向断言（observer override 成功绑定）改为检查 Function 的 BAR accessor 已提交 `mq_pcie_seqr`。

```bash
f=virtio_net_vip/tests/virtio_dut_caps_test.sv
# 1) 整个 null-virtual-sequencer 场景及其 fixture、调用
p1_del $f '    task assert_env_null_vseqr_is_rejected_before_preflight();' 1 61
#   预期 first:[] last:[    endtask] keep-:[    endtask] keep+:[]
p1_del $f '        null_vseqr_bind_cfg = make_fatal_probe_cfg(' 0 16
#   预期 first:[        null_vseqr_bind_cfg = make_fatal_probe_cfg(] last:[] keep-:[] keep+:[        adapter_bind_cfg = make_fatal_probe_cfg("adapter_bind_cfg", 0);]
p1_del_line $f '    virtio_dut_caps_bind_probe_env null_vseqr_bind_env;'
p1_del_line $f '    virtio_net_env_config null_vseqr_bind_cfg;'
p1_del_line $f '    dpu_device_env null_vseqr_bind_device_env;'
p1_del_line $f '        assert_env_null_vseqr_is_rejected_before_preflight();'
# 2) invalid legacy 场景不再需要借用 v_seqr
p1_del_line $f '        invalid_legacy_env.v_seqr = propagated_caps_env.v_seqr;'
p1_del_line $f '        invalid_legacy_env.v_seqr = null;'
# 3) 失败路径断言条件行
for env in observer_export_env external_monitor_env propagated_caps_env multi_bind_env \
           protocol_vif_alias_bind_env alias_bind_env ops_alias_bind_env \
           endpoint_bind_env adapter_bind_env; do
  p1_del_line $f "            (${env}.v_seqr.pcie_rc_seqr != null) ||"
done
# 4) 诊断参数（保持参数个数）
sed -i \
  -e 's/^                observer_export_env\.v_seqr\.pcie_rc_seqr != null,$/                function_instance.transport.bar.pcie_rc_seqr != null,/' \
  -e 's/^                external_monitor_env\.v_seqr\.pcie_rc_seqr != null,$/                function_instance.transport.bar.pcie_rc_seqr != null,/' \
  -e 's/^                propagated_caps_env\.v_seqr\.pcie_rc_seqr != null,$/                failing_function.transport.bar.pcie_rc_seqr != null,/' \
  -e 's/^                protocol_vif_alias_bind_env\.v_seqr\.pcie_rc_seqr != null,$/                first_function.transport.bar.pcie_rc_seqr != null,/' \
  -e 's/^                alias_bind_env\.v_seqr\.pcie_rc_seqr != null,$/                first_function.transport.bar.pcie_rc_seqr != null,/' \
  -e 's/^                ops_alias_bind_env\.v_seqr\.pcie_rc_seqr != null,$/                first_function.transport.bar.pcie_rc_seqr != null,/' \
  $f
# 5) 正向断言
sed -i 's/^            (observer_override_env\.v_seqr\.pcie_rc_seqr != mq_pcie_seqr) ||$/            (function_instance.transport.bar.pcie_rc_seqr != mq_pcie_seqr) ||/' $f
```
（`for` 循环里 9 次 `p1_del_line` 必须全部成功；任一报 `NOT UNIQUE/ABSENT` 立即停止。）

- [ ] **Step 5: grep 证据**

```bash
grep -rnwE 'v_seqr|virtio_virtual_sequencer|null_vseqr_bind_env|null_vseqr_bind_cfg|null_vseqr_bind_device_env' \
  virtio_net_vip/src virtio_net_vip/tests examples scripts filelists | grep -v 'pcie_env\.v_seqr'
grep -rnE '_vseq\b|virtio_(base|init|tx|rx|ctrl|kick|queue_setup)_seq\b|seq/(base|scenario|virtual)/' \
  virtio_net_vip examples scripts filelists
test ! -e virtio_net_vip/src/seq && echo SEQ_DIR_GONE
```
预期：前两条无输出；第三条输出 `SEQ_DIR_GONE`。

- [ ] **Step 6: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_dut_caps_test ./scripts/vcs.sh > logs/virtio_dut_caps_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_dut_caps_test.log | tail -20'
```
预期：见"执行前提"中的 ONE TEST 预期。

- [ ] **Step 7: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```
预期：第一条 grep 无输出，末行 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: Commit**

```bash
git add -A virtio_net_vip/src/seq virtio_net_vip/src/env/virtio_virtual_sequencer.sv \
  virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/src/env/virtio_net_env.sv \
  virtio_net_vip/tests/virtio_dut_caps_test.sv
git commit -m "refactor: 删除未使用的 sequence 库与 virtual sequencer" \
  -m "src/seq 33 个文件和 virtio_virtual_sequencer 无测试/示例引用；env 不再创建 v_seqr。dut_caps 中依赖 v_seqr 的断言改为检查 Function BAR accessor 的 RC sequencer。"
```

---

### Task P1-2: 删除无调用的 transport/BAR/中断错误注入

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv:938-1062`
- Modify: `virtio_net_vip/src/transport/virtio_bar_accessor.sv:997-1093`
- Modify: `virtio_net_vip/src/transport/virtio_notification_manager.sv:405-443`
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv:267-272`
- Test: 全量回归（无测试直接引用被删符号）

**Interfaces:**
- Consumes: 无。
- Produces: 删除 `virtio_pci_transport::inject_status_error/inject_feature_error/inject_queue_setup_error`、`virtio_bar_accessor::read_reg_with_error/write_reg_with_error`、`virtio_notification_manager::inject_spurious_interrupt/inject_missed_interrupt/inject_wrong_vector`、`queue_setup_error_e`。`status_error_e/feature_error_e` 保留（`virtio_transaction.sv:83-84` 仍使用）。

**证据（HEAD）：** 上述 8 个方法在定义之外 0 引用（含 seq 目录）。`queue_setup_error_e` 及 `QSETUP_ERR_*` 仅被 `inject_queue_setup_error` 使用——删除方法后成为孤儿，一并删除。

- [ ] **Step 1: 删除代码块**

```bash
p1_del virtio_net_vip/src/transport/virtio_pci_transport.sv \
  '    // 错误注入：以下三个 task 故意发出违反 virtio 规范的访问序列，用于验证' 2 122
#   预期 first:[] last:[    endtask] keep-:[    endtask] keep+:[]   （HEAD 行 938-1062，其后是 endclass）
p1_del virtio_net_vip/src/transport/virtio_bar_accessor.sv '    // read_reg_with_error' 2 94
#   预期 first:[] last:[    endtask] keep-:[    endtask] keep+:[]   （HEAD 行 997-1093）
p1_del virtio_net_vip/src/transport/virtio_notification_manager.sv \
  '    // 错误注入：直接操纵本地中断模型(不发真实 TLP)，用于验证上层对异常' 2 36
#   预期 first:[] last:[    endtask] keep-:[    endfunction] keep+:[]   （HEAD 行 405-443）
p1_del virtio_net_vip/src/types/virtio_net_types.sv '} queue_setup_error_e;' 5 0
#   预期 first:[] last:[} queue_setup_error_e;] keep-:[} feature_error_e;] keep+:[]
```

- [ ] **Step 2: grep 证据**

```bash
grep -rnwE 'inject_status_error|inject_feature_error|inject_queue_setup_error|read_reg_with_error|write_reg_with_error|inject_spurious_interrupt|inject_missed_interrupt|inject_wrong_vector|queue_setup_error_e' \
  virtio_net_vip examples scripts filelists
grep -rnE 'QSETUP_ERR_' virtio_net_vip examples
```
预期：均无输出。

- [ ] **Step 3: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_e2e_test ./scripts/vcs.sh > logs/virtio_e2e_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_e2e_test.log | tail -20'
```
（e2e 覆盖 bar accessor / transport / 中断路径的编译与运行。）

- [ ] **Step 4: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 5: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_pci_transport.sv virtio_net_vip/src/transport/virtio_bar_accessor.sv \
  virtio_net_vip/src/transport/virtio_notification_manager.sv virtio_net_vip/src/types/virtio_net_types.sv
git commit -m "refactor: 删除无调用的 transport/BAR/中断错误注入接口"
```

---

### Task P1-3: 删除 dataplane/scoreboard/coverage 回调钩子

**Files:**
- Delete: `virtio_net_vip/src/callbacks/`（`virtio_dataplane_callback.sv`、`virtio_scoreboard_callback.sv`、`virtio_coverage_callback.sv`，共 126 行）
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:74,76-78`
- Modify: `virtio_net_vip/src/dataplane/virtio_net_dataplane.sv:19,101-108`
- Modify: `virtio_net_vip/src/env/virtio_coverage.sv:24-25,27,45-47,303-310,315,381-384`
- Modify: `virtio_net_vip/src/env/virtio_scoreboard.sv:21-23,25,35-37,173-174,186-196`
- Modify: `virtio_net_vip/src/dataplane/virtio_tx_engine.sv`（P0 后行号变化；锚点见下）
- Modify: `virtio_net_vip/src/dataplane/virtio_rx_engine.sv`（P0 后行号变化；锚点见下）
- Test: `virtio_net_vip/tests/virtio_coverage_test.sv`、`virtio_net_vip/tests/virtio_indirect_desc_test.sv`、`virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`

**Interfaces:**
- Consumes: P0 后的 `virtio_tx_engine`/`virtio_rx_engine`（薄适配）。
- Produces: 删除 `virtio_net_dataplane::set_dataplane_callback`、`virtio_tx_engine::custom_cb`、`virtio_rx_engine::custom_cb`、`virtio_rx_engine::custom_receive`、`virtio_coverage::custom_cov_cbs/register_custom_coverage`、`virtio_scoreboard::custom_checker`。
  **注意**：`custom_virtqueue::custom_cb`（`virtqueue_custom_callback`，私有环在用）与本任务无关，必须保留。

**证据（HEAD）：** `set_dataplane_callback`、`register_custom_coverage`、`custom_checker` 在定义外 0 引用；引擎的 `custom_cb` 只被 `set_dataplane_callback` 赋值；`custom_compare/custom_sample/custom_tx_build_chain/custom_rx_parse_buf` 只在上述从未成立的 `!= null` 分支里调用。

- [ ] **Step 1: 删除回调文件与 pkg include**

```bash
git rm -r -q virtio_net_vip/src/callbacks
f=virtio_net_vip/src/virtio_net_pkg.sv
p1_del_line $f '  `include "callbacks/virtio_dataplane_callback.sv"'
p1_del_line $f '  `include "callbacks/virtio_scoreboard_callback.sv"'
p1_del_line $f '  `include "callbacks/virtio_coverage_callback.sv"'
```
pkg 层注释（Edit）old:
```
  // 第 5 层 – 回调、事务与驱动 agent（callbacks/、types/、agent/）
```
new:
```
  // 第 5 层 – 事务与驱动 agent（types/、agent/）
```

- [ ] **Step 2: `virtio_net_dataplane.sv`**

```bash
f=virtio_net_vip/src/dataplane/virtio_net_dataplane.sv
p1_del_line $f '//   - virtio_dataplane_callback (optional custom TX/RX hooks)'
p1_del $f '    // set_dataplane_callback -- Install custom TX/RX hooks' 1 6
#   预期 first:[    // ====...] last:[] keep-:[] keep+:[    // ====...]（其后为 cleanup_all）
```

- [ ] **Step 3: `virtio_coverage.sv`**

```bash
f=virtio_net_vip/src/env/virtio_coverage.sv
p1_del $f '// Supports custom coverage callbacks (virtio_coverage_callback).' 0 1
#   预期 first:[// Supports custom coverage callbacks ...] last:[//] keep-:[//] keep+:[// Depends on:]
sed -i 's|^//   - virtio_transaction, virtio_coverage_callback$|//   - virtio_transaction|' $f
p1_del $f '    virtio_coverage_callback custom_cov_cbs[$];' 1 1
#   预期 first:[    // ===== Custom callbacks =====] last:[] keep-:[] keep+:[    // ===== Analysis import =====]
p1_del $f '    // register_custom_coverage' 1 6
#   预期 first:[    // ====...] last:[] keep-:[] keep+:[    // ====...]（其后为 write 的注释头）
sed -i 's|^    // covergroups\. Also invokes custom coverage callbacks\.$|    // covergroups.|' $f
p1_del $f '        // Custom callbacks' 1 2
#   预期 first:[] last:[            custom_cov_cbs[i].custom_sample(txn);] keep-:[            cg_sriov.sample();] keep+:[    endfunction]
```

- [ ] **Step 4: `virtio_scoreboard.sv`**

```bash
f=virtio_net_vip/src/env/virtio_scoreboard.sv
p1_del $f '// Supports a custom callback (virtio_scoreboard_callback) for' 0 2
#   预期 first:[// Supports a custom callback ...] last:[//] keep-:[//] keep+:[// Depends on:]
sed -i 's|^//   - virtio_transaction, virtio_scoreboard_callback$|//   - virtio_transaction|' $f
p1_del $f '    virtio_scoreboard_callback custom_checker;' 1 1
#   预期 first:[    // ===== Custom callback =====] last:[] keep+:[    // ===== Check enable switches (all default ON) =====]
```
Edit 1 old:
```
    // Compare expected vs actual packet data. Uses custom_checker if
    // registered, otherwise uses uvm_object::compare().
```
new:
```
    // Compare expected vs actual packet data through the net_packet byte
    // adapter, falling back to uvm_object::compare().
```
Edit 2 old:
```
        if (custom_checker != null) begin
            match = custom_checker.custom_compare(expected, actual);
        end else begin
            // net_packet packet_item compares protocol layers but the
            // dataplane contract is the exact wire byte stream.  Prefer the
            // adapter so payload bytes are included, then retain the generic
            // UVM comparison for legacy synthetic objects.
            match = virtio_net_packet_adapter::compare(expected, actual);
            if (!match)
                match = expected.compare(actual);
        end
```
new:
```
        // net_packet packet_item compares protocol layers but the
        // dataplane contract is the exact wire byte stream.  Prefer the
        // adapter so payload bytes are included, then retain the generic
        // UVM comparison for legacy synthetic objects.
        match = virtio_net_packet_adapter::compare(expected, actual);
        if (!match)
            match = expected.compare(actual);
```

- [ ] **Step 5: `virtio_tx_engine.sv`（P0 后；只删 `custom_cb` 相关）**

先定位：`grep -nE 'custom_cb|virtio_dataplane_callback' virtio_net_vip/src/dataplane/virtio_tx_engine.sv`。
对仍存在的每一项执行（不存在的跳过）：
```bash
f=virtio_net_vip/src/dataplane/virtio_tx_engine.sv
p1_del_line $f '//   - virtio_dataplane_callback (optional custom chain builder)'
p1_del_line $f '    virtio_dataplane_callback   custom_cb;   // null = standard mode'
sed -i 's|"cleanup_tx_buffers: no tracker found (custom_cb or already cleaned)",|"cleanup_tx_buffers: no tracker found (already cleaned)",|' $f
```
若 SG 链分支仍存在（HEAD `virtio_tx_engine.sv:178-183`），Edit old:
```
        // Build scatter-gather chain
        if (custom_cb != null) begin
            custom_cb.custom_tx_build_chain(token, hdr, sgs);
        end else begin
            standard_tx_build_chain(pkt_data, hdr, sgs, tracker);
        end
```
new:
```
        // Build scatter-gather chain
        standard_tx_build_chain(pkt_data, hdr, sgs, tracker);
```

- [ ] **Step 6: `virtio_rx_engine.sv`（P0 后；只删 `custom_cb` 分支与 `custom_receive`）**

先定位：`grep -nE 'custom_cb|custom_receive|virtio_dataplane_callback|按回调或 buffer 模式' virtio_net_vip/src/dataplane/virtio_rx_engine.sv`。对仍存在的项执行：
```bash
f=virtio_net_vip/src/dataplane/virtio_rx_engine.sv
p1_del_line $f '//   - virtio_dataplane_callback (optional custom RX parsing)'
p1_del_line $f '    virtio_dataplane_callback   custom_cb;   // null = standard mode'
p1_del $f '    // custom_receive (protected)' 1 66
#   预期 first:[    // ====...] last:[] keep-:[] keep+:[    // ====...]（其后为 cleanup_rx_buffer 注释头；HEAD 行 516-583，last 的上一行是 "    endtask : custom_receive"）
sed -i 's|^    // 按回调或 buffer 模式取得至多 budget 个包，追加到 received；之后按现有$|    // 按 buffer 模式取得至多 budget 个包，追加到 received；之后按现有|' $f
```
若 `receive_packets` 内的回调分支仍存在（HEAD 232-240），Edit old:
```
        if (custom_cb != null) begin
            custom_receive(queue_id, budget, received);
        end else begin
            case (buf_mode)
                RX_MODE_MERGEABLE: receive_mergeable(queue_id, budget, received);
                RX_MODE_BIG:       receive_big(queue_id, budget, received);
                RX_MODE_SMALL:     receive_small(queue_id, budget, received);
            endcase
        end
```
new:
```
        case (buf_mode)
            RX_MODE_MERGEABLE: receive_mergeable(queue_id, budget, received);
            RX_MODE_BIG:       receive_big(queue_id, budget, received);
            RX_MODE_SMALL:     receive_small(queue_id, budget, received);
        endcase
```
（`RX_MODE_BIG/SMALL` 分支由 P1-8 删除。）

- [ ] **Step 7: grep 证据**

```bash
grep -rnwE 'virtio_dataplane_callback|virtio_scoreboard_callback|virtio_coverage_callback|set_dataplane_callback|register_custom_coverage|custom_checker|custom_cov_cbs|custom_receive|custom_tx_build_chain|custom_rx_parse_buf|custom_compare|custom_sample' \
  virtio_net_vip examples scripts filelists
grep -nw 'custom_cb' virtio_net_vip/src/dataplane/*.sv
test ! -e virtio_net_vip/src/callbacks && echo CALLBACKS_GONE
```
预期：前两条无输出（`custom_virtqueue.sv`、`dpu_priv_*`、`examples/dpu_priv_ring` 中的 `custom_cb` 属于 `virtqueue_custom_callback`，不在 `dataplane/` 目录，不应被删）；第三条输出 `CALLBACKS_GONE`。

- [ ] **Step 8: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_coverage_test virtio_indirect_desc_test virtio_net_packet_multi_queue_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
```

- [ ] **Step 9: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 10: Commit**

```bash
git add -A virtio_net_vip/src/callbacks virtio_net_vip/src/virtio_net_pkg.sv \
  virtio_net_vip/src/dataplane/virtio_net_dataplane.sv virtio_net_vip/src/dataplane/virtio_tx_engine.sv \
  virtio_net_vip/src/dataplane/virtio_rx_engine.sv virtio_net_vip/src/env/virtio_coverage.sv \
  virtio_net_vip/src/env/virtio_scoreboard.sv
git commit -m "refactor: 删除从未赋值的 dataplane/scoreboard/coverage 回调钩子"
```

---

### Task P1-4: 删除 `virtio_failover_manager` 及其持有、打印和孤立配置

**Files:**
- Delete: `virtio_net_vip/src/dataplane/virtio_failover_manager.sv`（237 行）
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:109`
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv:174`
- Modify: `virtio_net_vip/src/dataplane/virtio_net_dataplane.sv:7-8,18,30,40,47,134-135`（P0 后行号变化，用锚点）
- Modify: `virtio_net_vip/src/sriov/virtio_pf_manager.sv:12,31,45,718-721`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv:107-111,574-576`
- Test: 全量回归

**Interfaces:**
- Consumes: 无。
- Produces: `virtio_net_dataplane`、`virtio_pf_manager` 不再有 `failover_mgr`；删除 `failover_state_e`；`virtio_net_env_config` 删除 `failover_enable/primary_vf_id/standby_vf_id`。`VIRTIO_NET_F_STANDBY` 特性位常量保留（仅协商）。

**证据（HEAD）：** `failover_mgr` 只在 dataplane 构造与两处 `get_status_string()` 打印中出现；`failover_state_e/FO_*` 只被 failover manager 使用。
**Spec deviation:** spec 未列出 `virtio_net_env_config` 的 `failover_enable/primary_vf_id/standby_vf_id`。它们在 HEAD 只被 `convert2string()` 打印（seq 中也无引用），是 failover 模型的配置入口，删除模型后无任何语义，一并删除，避免手册继续宣称"`failover_enable` 控制 STANDBY"。

- [ ] **Step 1: 删除文件、include、类型**

```bash
git rm -q virtio_net_vip/src/dataplane/virtio_failover_manager.sv
p1_del_line virtio_net_vip/src/virtio_net_pkg.sv '  `include "dataplane/virtio_failover_manager.sv"'
p1_del_line virtio_net_vip/src/types/virtio_net_types.sv \
  'typedef enum { FO_NORMAL, FO_PRIMARY_DOWN, FO_SWITCHING, FO_STANDBY_ACTIVE, FO_FAILBACK } failover_state_e;'
```

- [ ] **Step 2: `virtio_net_dataplane.sv`**

```bash
f=virtio_net_vip/src/dataplane/virtio_net_dataplane.sv
p1_del_line $f '//   - virtio_failover_manager (VIRTIO_NET_F_STANDBY failover)'
p1_del_line $f '    virtio_failover_manager   failover_mgr;'
p1_del_line $f '        failover_mgr = virtio_failover_manager::type_id::create("failover_mgr");'
```
Edit 1 old:
```
// Top-level dataplane wrapper that aggregates TX engine, RX engine, offload
// engine, and failover manager into a single manageable unit.
```
new:
```
// Top-level dataplane wrapper that aggregates TX engine, RX engine and
// offload engine into a single manageable unit.
```
Edit 2 old:
```
    // 构造函数：创建下属 TX/RX/offload/failover 四个子引擎；
```
new:
```
    // 构造函数：创建下属 TX/RX/offload 三个子引擎；
```
Edit 3 old（`print_stats` 末尾）:
```
            rx_buf_size, rx_refill_threshold), UVM_LOW)

        if (failover_mgr != null)
            `uvm_info("DATAPLANE", failover_mgr.get_status_string(), UVM_LOW)
    endfunction
```
new:
```
            rx_buf_size, rx_refill_threshold), UVM_LOW)
    endfunction
```

- [ ] **Step 3: `virtio_pf_manager.sv`**

```bash
f=virtio_net_vip/src/sriov/virtio_pf_manager.sv
p1_del_line $f '//   - Failover coordination (via virtio_failover_manager)'
p1_del_line $f '//   - virtio_failover_manager (STANDBY failover)'
p1_del_line $f '    virtio_failover_manager   failover_mgr;'
p1_del $f '        if (failover_mgr != null) begin' 1 2
#   预期 first:[] last:[        end] keep-:[        resource_pool.print_map();] keep+:[    endfunction]
```

- [ ] **Step 4: `virtio_net_env_config.sv`**

```bash
f=virtio_net_vip/src/env/virtio_net_env_config.sv
p1_del $f '    // ===== Failover =====' 0 4
#   预期 first:[    // ===== Failover =====] last:[] keep-:[] keep+:[    // ====...]
```
Edit（`convert2string` 末尾）old:
```
        s = {s, $sformatf("  scb_enable=%0b, cov_enable=%0b\n", scb_enable, cov_enable)};
        s = {s, $sformatf("  failover: enable=%0b, primary=%0d, standby=%0d",
                          failover_enable, primary_vf_id, standby_vf_id)};
        return s;
```
new:
```
        s = {s, $sformatf("  scb_enable=%0b, cov_enable=%0b", scb_enable, cov_enable)};
        return s;
```

- [ ] **Step 5: grep 证据**

```bash
grep -rnE 'failover|FO_(NORMAL|PRIMARY_DOWN|SWITCHING|STANDBY_ACTIVE|FAILBACK)|primary_vf_id|standby_vf_id' \
  virtio_net_vip examples scripts filelists
```
预期：无输出。

- [ ] **Step 6: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_pf_lifecycle_reset_test virtio_net_packet_multi_queue_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
```

- [ ] **Step 7: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 8: Commit**

```bash
git add -A virtio_net_vip/src/dataplane/virtio_failover_manager.sv virtio_net_vip/src/virtio_net_pkg.sv \
  virtio_net_vip/src/types/virtio_net_types.sv virtio_net_vip/src/dataplane/virtio_net_dataplane.sv \
  virtio_net_vip/src/sriov/virtio_pf_manager.sv virtio_net_vip/src/env/virtio_net_env_config.sv
git commit -m "refactor: 删除仅被打印引用的 failover 管理器及其孤立配置"
```

---

### Task P1-5: 删除未调用的 offload 分段/伪头校验，USO 头长度并入 TSO 引擎

**Files:**
- Delete: `virtio_net_vip/src/dataplane/virtio_uso_engine.sv`（204 行）
- Modify（整体重写）: `virtio_net_vip/src/dataplane/virtio_tso_engine.sv`（340 → 约 125 行）
- Modify: `virtio_net_vip/src/dataplane/virtio_csum_engine.sv:7-9,167-247`
- Modify: `virtio_net_vip/src/dataplane/virtio_offload_engine.sv:7-14,23,31,37,71,120,126,133-136`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:104`
- Test: `virtio_net_vip/tests/virtio_protocol_test.sv`、`virtio_net_vip/tests/virtio_traffic_test.sv`、`virtio_net_vip/tests/virtio_indirect_desc_test.sv`、`virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`

**Interfaces:**
- Consumes: 现有调用方（不改动）：`virtio_tx_engine`（或 P0 后的 `virtio_net_hdr_util` 头构造）调用 `offload.needs_gso()/get_gso_type()/get_mss_value()/get_all_hdr_len()/calc_csum_start()/calc_csum_offset()`；RX 调用 `offload.verify_rx_csum()`；
  `virtio_protocol_test.sv:185-242,317-328` 调用 `csum.get_ethertype/get_l4_proto/calc_csum_start/calc_csum_offset`、`tso.needs_tso/get_all_hdr_len`、`offload.needs_tso/get_gso_type/needs_gso`；
  `virtio_traffic_test.sv:813-890` 调用 `offload.calc_csum_start/calc_csum_offset/get_gso_type`。
- Produces: `virtio_tso_engine` 公共接口：
  `function bit needs_tso(byte unsigned pkt_data[$], int unsigned mss);`
  `function bit needs_uso(byte unsigned pkt_data[$], int unsigned mss);`
  `function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);`（TCP，语义不变）
  `function int unsigned get_udp_all_hdr_len(byte unsigned pkt_data[$]);`（原 `virtio_uso_engine::get_all_hdr_len`）。
  `virtio_offload_engine` 公共签名全部不变，只删除 `prepare_tx_csum` 与成员 `uso`。

**证据（HEAD）：** `segment()`（TSO/USO）、`get_tcp_seq/set_tcp_seq/set_ip_total_length/set_ip_identification`、两个 `recalc_ip_checksum` 只被 `segment()` 调用，`segment()` 在 src/tests/examples 0 调用；`csum.prepare_tx_csum` 只被 `offload.prepare_tx_csum` 调用，后者 0 调用。
`offload.needs_uso` 被 `offload.needs_gso`（tx engine 与 protocol_test 使用）和 `offload.get_all_hdr_len` 调用；`uso.get_all_hdr_len` 只被 `uso.needs_uso` 与 `offload.get_all_hdr_len` 调用——合并只改 offload 内部两行委托，**不触及 offload 之外的调用方**。
**Spec deviation:** spec 称"维护测试只用 `needs_tso/get_gso_type/calc_csum_*/rss_*`"；实际 `virtio_protocol_test` 还用 `csum.get_ethertype`、`csum.get_l4_proto`、`tso.get_all_hdr_len`、`offload.needs_gso`。这些都不在删除范围内，计划不变。

- [ ] **Step 1: 删除 USO 文件与 include**

```bash
git rm -q virtio_net_vip/src/dataplane/virtio_uso_engine.sv
p1_del_line virtio_net_vip/src/virtio_net_pkg.sv '  `include "dataplane/virtio_uso_engine.sv"'
```

- [ ] **Step 2: 重写 `virtio_net_vip/src/dataplane/virtio_tso_engine.sv`（全文）**

TCP 路径与原 `get_all_hdr_len` 逐分支等价（L2/VLAN、IPv4 IHL/IPv6、`size <= tcp_off+12` 返回 0、`data_offset*4` 下限 20）；UDP 路径与原 `virtio_uso_engine::get_all_hdr_len` 等价（L2+L3+8，无额外长度检查）。

```systemverilog
`ifndef VIRTIO_TSO_ENGINE_SV
`define VIRTIO_TSO_ENGINE_SV

// ============================================================================
// virtio_tso_engine
//
// GSO header-length helpers for TX offload decisions.  Computes the total
// ETH + IP + L4 header length of a TCP or UDP packet and decides whether its
// payload exceeds the MSS.  The VIP never segments packets itself: when
// HOST_TSO4/6 or HOST_USO is negotiated the device performs segmentation.
// 中文说明：只提供 TCP/UDP 的 GSO 头长度和“payload 是否超过 MSS”判断，供
// offload 引擎填写 virtio_net_hdr 的 gso_type/hdr_len；分段由设备完成。
// ============================================================================

class virtio_tso_engine extends uvm_object;
    `uvm_object_utils(virtio_tso_engine)

    localparam int unsigned ETH_HDR_LEN     = 14;
    localparam int unsigned VLAN_TAG_LEN    = 4;
    localparam int unsigned UDP_HDR_LEN     = 8;
    localparam int unsigned ETHERTYPE_VLAN  = 16'h8100;
    localparam int unsigned ETHERTYPE_IPV4  = 16'h0800;
    localparam int unsigned ETHERTYPE_IPV6  = 16'h86DD;

    // 构造函数：无状态引擎，仅 UVM 注册。
    function new(string name = "virtio_tso_engine");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------------
    // needs_tso — check if TCP payload exceeds MSS
    // ------------------------------------------------------------------------
    function bit needs_tso(byte unsigned pkt_data[$], int unsigned mss);
        int unsigned hdr_len;
        int unsigned payload_len;

        hdr_len = get_all_hdr_len(pkt_data);
        if (hdr_len == 0 || hdr_len >= pkt_data.size())
            return 0;

        payload_len = pkt_data.size() - hdr_len;
        return (payload_len > mss);
    endfunction

    // ------------------------------------------------------------------------
    // needs_uso — check if UDP payload exceeds MSS
    // ------------------------------------------------------------------------
    function bit needs_uso(byte unsigned pkt_data[$], int unsigned mss);
        int unsigned hdr_len;
        int unsigned payload_len;

        hdr_len = get_udp_all_hdr_len(pkt_data);
        if (hdr_len == 0 || hdr_len >= pkt_data.size())
            return 0;

        payload_len = pkt_data.size() - hdr_len;
        return (payload_len > mss);
    endfunction

    // ------------------------------------------------------------------------
    // get_l2_l3_hdr_len — ETH (+ one VLAN tag) + IPv4/IPv6 header length.
    // 中文：非 IPv4/IPv6 或长度不足时返回 0。
    // ------------------------------------------------------------------------
    protected function int unsigned get_l2_l3_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_len, l3_len;
        bit [15:0] etype;
        bit [3:0] ihl;

        if (pkt_data.size() < ETH_HDR_LEN)
            return 0;

        // L2 length
        etype = {pkt_data[12], pkt_data[13]};
        l2_len = (etype == ETHERTYPE_VLAN) ?
                 ETH_HDR_LEN + VLAN_TAG_LEN : ETH_HDR_LEN;

        if (etype == ETHERTYPE_VLAN && pkt_data.size() >= l2_len + 2)
            etype = {pkt_data[16], pkt_data[17]};

        // L3 length
        if (etype == ETHERTYPE_IPV4) begin
            if (pkt_data.size() <= l2_len)
                return 0;
            ihl = pkt_data[l2_len][7:4];
            l3_len = (ihl < 5) ? 20 : ihl * 4;
        end else if (etype == ETHERTYPE_IPV6) begin
            l3_len = 40;
        end else begin
            return 0;
        end

        return l2_len + l3_len;
    endfunction

    // ------------------------------------------------------------------------
    // get_all_hdr_len — total header length (ETH + IP + TCP)
    // ------------------------------------------------------------------------
    function int unsigned get_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned tcp_off;
        int unsigned l4_len;
        bit [3:0] data_offset;

        tcp_off = get_l2_l3_hdr_len(pkt_data);
        if (tcp_off == 0)
            return 0;

        // TCP data offset (header length)
        if (pkt_data.size() <= tcp_off + 12)
            return 0;

        data_offset = pkt_data[tcp_off + 12][7:4];
        l4_len = data_offset * 4;
        if (l4_len < 20)
            l4_len = 20;

        return tcp_off + l4_len;
    endfunction

    // ------------------------------------------------------------------------
    // get_udp_all_hdr_len — total header length (ETH + IP + UDP)
    // UDP header is always 8 bytes.
    // ------------------------------------------------------------------------
    function int unsigned get_udp_all_hdr_len(byte unsigned pkt_data[$]);
        int unsigned l2_l3_len;

        l2_l3_len = get_l2_l3_hdr_len(pkt_data);
        if (l2_l3_len == 0)
            return 0;
        return l2_l3_len + UDP_HDR_LEN;
    endfunction

endclass : virtio_tso_engine

`endif // VIRTIO_TSO_ENGINE_SV
```

- [ ] **Step 3: `virtio_csum_engine.sv`**

```bash
p1_del virtio_net_vip/src/dataplane/virtio_csum_engine.sv \
  '    // prepare_tx_csum — TX: compute pseudo-header checksum and write it' 1 79
#   预期 first:[    // ----...] last:[] keep-:[] keep+:[    // ----...]（其后为 verify_rx_csum 注释头；HEAD 167-247）
```
头注释（Edit）old:
```
// Checksum offload engine for virtio-net. Handles both TX path (partial
// checksum preparation for device completion) and RX path (full L4 checksum
// verification). Parses Ethernet/IP/TCP/UDP headers from raw packet bytes.
```
new:
```
// Checksum offload engine for virtio-net. Provides TX csum_start/csum_offset
// derivation and RX full L4 checksum verification. Parses Ethernet/IP/TCP/UDP
// headers from raw packet bytes.
```

- [ ] **Step 4: `virtio_offload_engine.sv`**

```bash
f=virtio_net_vip/src/dataplane/virtio_offload_engine.sv
p1_del_line $f '    virtio_uso_engine     uso;'
p1_del_line $f '        uso  = virtio_uso_engine::type_id::create("uso");'
sed -i 's|^        return uso\.needs_uso(pkt_data, mss);$|        return tso.needs_uso(pkt_data, mss);|' $f
sed -i 's|^            return uso\.get_all_hdr_len(pkt_data);$|            return tso.get_udp_all_hdr_len(pkt_data);|' $f
sed -i 's|^    // Delegates to TSO or USO engine depending on packet type\.$|    // Delegates to the TCP or UDP header-length helper of the TSO engine.|' $f
sed -i 's|^    // 构造函数：创建 csum/tso/uso/rss 四个子引擎并清零协商特性；$|    // 构造函数：创建 csum/tso/rss 三个子引擎并清零协商特性；|' $f
```
Edit 1（头注释）old:
```
// Unified offload engine wrapping all four sub-engines: checksum, TSO, USO,
// and RSS. Provides a single interface for TX/RX engines and the scoreboard.
//
// Sub-engines:
//   csum — checksum offload (TX partial csum, RX verification)
//   tso  — TCP Segmentation Offload
//   uso  — UDP Segmentation Offload (virtio 1.2+)
//   rss  — Receive Side Scaling (Toeplitz hash + queue selection)
```
new:
```
// Unified offload engine wrapping three sub-engines: checksum, GSO header
// length (TSO/USO) and RSS. Provides a single interface for TX/RX engines
// and the scoreboard.
//
// Sub-engines:
//   csum — checksum offload (TX csum_start/csum_offset, RX verification)
//   tso  — TCP/UDP GSO header length and MSS decision (no segmentation)
//   rss  — Receive Side Scaling (Toeplitz hash + queue selection)
```
Edit 2：删除以下 4 行（其上的 "TX checksum helpers — delegate to csum engine" 注释头保留给 `calc_csum_start/offset`）：
```bash
p1_del $f '    function void prepare_tx_csum(virtio_net_hdr_t hdr, ref byte unsigned pkt_data[$]);' 0 3
#   预期 first:[    function void prepare_tx_csum(...)] last:[] keep-:[    // ----...] keep+:[    // 委托 csum 引擎：计算 virtio_net_hdr.csum_start（L4 头起始偏移）。]
```

- [ ] **Step 5: grep 证据**

```bash
grep -rnE 'virtio_uso_engine|\buso\.|\bsegment\(|recalc_ip_checksum|get_tcp_seq|set_tcp_seq|set_ip_total_length|set_ip_identification|prepare_tx_csum' \
  virtio_net_vip examples scripts filelists
```
预期：无输出。

- [ ] **Step 6: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_protocol_test virtio_traffic_test virtio_indirect_desc_test virtio_net_packet_multi_queue_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
ssh ubuntu@10.11.10.53 'grep -c "test_tso_engine PASSED\|test_csum_engine PASSED" ~/virtio_priv_run/virtio_work/logs/virtio_protocol_test.log'
```
预期：前四个测试同 ONE TEST 预期；最后一条输出 `2`。

- [ ] **Step 7: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 8: Commit**

```bash
git add -A virtio_net_vip/src/dataplane/virtio_uso_engine.sv virtio_net_vip/src/dataplane/virtio_tso_engine.sv \
  virtio_net_vip/src/dataplane/virtio_csum_engine.sv virtio_net_vip/src/dataplane/virtio_offload_engine.sv \
  virtio_net_vip/src/virtio_net_pkg.sv
git commit -m "refactor: 删除未调用的 TSO/USO 分段与 TX 伪头校验，USO 头长度并入 TSO 引擎"
```

---

### Task P1-6: 删除 env 附件中未调用的方法

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv:11-17,247-515`
- Modify: `virtio_net_vip/src/env/virtio_concurrency_controller.sv:7-16,24,250-441`
- Modify: `virtio_net_vip/src/env/virtio_scoreboard.sv:7,19,46,376-421`（P1-3 后行号已变，用锚点）
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv:245-250`（前序任务后行号已变，用锚点）
- Test: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv`、`virtio_net_vip/tests/virtio_monitor_routing_test.sv`、`virtio_net_vip/tests/virtio_dut_caps_test.sv`

**Interfaces:**
- Consumes: 无。
- Produces: 删除 `virtio_dynamic_reconfig::live_mtu_change/live_irq_mode_switch/live_mac_change/live_vlan_update/live_rss_update`、`virtio_concurrency_controller::inject_race_window/test_flr_isolation/test_queue_reset_isolation`、`virtio_scoreboard::check_config_consistency/chk_config_consistency`、`race_point_e`。
  保留 `live_mq_resize/do_live_mq_resize`、`max_supported_qpairs*`、`qpair_count_supported`、`parallel_vf_op`、`parallel_traffic`、`virtio_traffic_worker_base`。

**证据（HEAD）：** 9 个方法在定义外 0 调用（`live_mq_resize` 被 monitor_routing/dut_caps 使用，`parallel_*` 被 pf_lifecycle_reset 使用，均保留）。`race_point_e` 只被 `inject_race_window` 使用；`chk_config_consistency` 在 HEAD 从未被读，唯一语义是开关 `check_config_consistency`——删除方法后一并删除（spec 未列，属同一检查）。

- [ ] **Step 1: `virtio_dynamic_reconfig.sv`**

```bash
p1_del virtio_net_vip/src/env/virtio_dynamic_reconfig.sv '    // live_mtu_change' 2 266
#   预期 first:[] last:[    endtask] keep-:[    endtask] keep+:[]（HEAD 247-515，其后 endclass）
```
Edit old:
```
// Reconfiguration types:
//   - MQ resize: change number of active queue pairs
//   - MTU change: update maximum transmission unit
//   - IRQ mode switch: transition between interrupt modes
//   - MAC change: update device MAC address via CTRL_MAC_ADDR_SET
//   - VLAN filter: add/remove VLAN IDs via CTRL_VLAN
//   - RSS update: reconfigure RSS hash/indirection table
```
new:
```
// Reconfiguration types:
//   - MQ resize: change number of active queue pairs
```

- [ ] **Step 2: `virtio_concurrency_controller.sv`**

```bash
f=virtio_net_vip/src/env/virtio_concurrency_controller.sv
p1_del $f '    // inject_race_window' 2 189
#   预期 first:[] last:[    endtask] keep-:[    endtask] keep+:[]（HEAD 250-441，其后 endclass）
sed -i 's|^//   - virtio_net_types\.sv (virtio_txn_type_e, race_point_e)$|//   - virtio_net_types.sv (virtio_txn_type_e)|' $f
```
Edit old:
```
// Orchestrates multi-VF parallel operations and race condition injection
// for concurrency verification scenarios.
//
// Provides:
//   - parallel_vf_op: Execute an operation on multiple VFs concurrently
//     with per-VF timeout using named fork blocks
//   - parallel_traffic: Generate traffic on multiple VFs concurrently
//   - inject_race_window: Insert timing delays at specific race points
//   - test_flr_isolation: FLR one VF while others continue traffic
//   - test_queue_reset_isolation: Reset one queue while others are active
```
new:
```
// Orchestrates multi-VF parallel operations for concurrency verification
// scenarios.
//
// Provides:
//   - parallel_vf_op: Execute an operation on multiple VFs concurrently
//     with per-VF timeout using named fork blocks
//   - parallel_traffic: Generate traffic on multiple VFs concurrently
```

- [ ] **Step 3: `virtio_scoreboard.sv`**

```bash
f=virtio_net_vip/src/env/virtio_scoreboard.sv
p1_del $f '    // check_config_consistency' 1 44
#   预期 first:[    // ====...] last:[] keep-:[] keep+:[    // ====...]（其后为 report_phase 注释头）
p1_del_line $f '    bit chk_config_consistency = 1;'
p1_del_line $f '//   8. Config consistency -- device config register vs expected values'
sed -i 's|^// 8-category verification scoreboard for virtio-net transactions\.$|// 7-category verification scoreboard for virtio-net transactions.|' $f
```

- [ ] **Step 4: `virtio_net_types.sv`**

```bash
p1_del virtio_net_vip/src/types/virtio_net_types.sv '} race_point_e;' 4 1
#   预期 first:[typedef enum {] last:[] keep-:[] keep+:[typedef enum {]（下一个是 iommu_fault_phase_e）
```

- [ ] **Step 5: grep 证据**

```bash
grep -rnwE 'live_mtu_change|live_irq_mode_switch|live_mac_change|live_vlan_update|live_rss_update|inject_race_window|test_flr_isolation|test_queue_reset_isolation|check_config_consistency|chk_config_consistency|race_point_e' \
  virtio_net_vip examples scripts filelists
grep -rnE 'RACE_(BETWEEN|DURING)_' virtio_net_vip examples
```
预期：均无输出。

- [ ] **Step 6: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_pf_lifecycle_reset_test virtio_monitor_routing_test virtio_dut_caps_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
```

- [ ] **Step 7: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 8: Commit**

```bash
git add virtio_net_vip/src/env/virtio_dynamic_reconfig.sv virtio_net_vip/src/env/virtio_concurrency_controller.sv \
  virtio_net_vip/src/env/virtio_scoreboard.sv virtio_net_vip/src/types/virtio_net_types.sv
git commit -m "refactor: 删除 dynamic_reconfig/concurrency/scoreboard 中未调用的方法"
```

---

### Task P1-7: 删除零散死方法（monitor/reg backend/cap manager/virtqueue/atomic ops/IOVA proxy/IOMMU）

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_monitor.sv:13,30,37,54,60,82,87,332-385`
- Modify: `virtio_net_vip/src/pcie/pcie_tl_dpu_reg_backend.sv:20-25,27,34,128-133,142,149,167-168,204-241,250-295`
- Modify: `virtio_net_vip/src/transport/virtio_pci_cap_manager.sv:417-426,441-445`
- Modify: `virtio_net_vip/src/virtqueue/split_virtqueue.sv:87-93,102-108,109-116`（P0 改过本文件 `kick()`，用锚点）
- Modify: `virtio_net_vip/src/virtqueue/packed_virtqueue.sv:100-106`（同上）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:437-451`（P0 改过本文件，用锚点）
- Modify: `virtio_net_vip/src/pcie/virtio_pcie_iova_host_mem_proxy.sv:12,21,34,74-81,90-91,100-103,170-189`
- Modify: `virtio_net_vip/src/iommu/virtio_iommu_model.sv:761-773,949-1008,1010,1025-1047,1085-1092`
- Test: `virtio_monitor_test`、`virtio_monitor_routing_test`、`dpu_pcie_tl_executor_integration_test`、`virtio_real_dut_iova_dma_test`、`virtio_pcie_host_mem_test`、`virtio_migration_dirty_test`、`virtio_unit_test`、`virtio_queue_semantics_test`

**Interfaces:**
- Consumes: 无。
- Produces（删除）：`virtio_monitor::check_status_transition/check_feature_dependency/check_queue_access_valid/broadcast_txn/broadcast_error/broadcast_pkt/pkt_ap/chk_feature_usage`；
  `pcie_tl_dpu_reg_backend::bind_host_root/calc_mem_transfer/payload_value/wait_for_completion/root_by_host/completion_poll_limit`；
  `virtio_pci_cap_manager::get_isr_bar/get_isr_bar_offset/all_mandatory_caps_found`；
  `split_virtqueue::read_desc_flags/read_avail_16/write_used_16`、`packed_virtqueue::read_packed_desc_flags`；
  `virtio_atomic_ops::validate_restored_indirect_ownership/claim_restored_indirect_ownership`；
  `virtio_pcie_iova_host_mem_proxy::set_direct_gpa_mode/direct_gpa_mode`（及 legacy 直通分支）；
  `virtio_iommu_model::snapshot_live_mappings/get_and_clear_dirty/get_dirty_page_mapping/get_dirty_page_mapping_for_host/get_dirty_page_records/get_dirty_page_mappings/get_dirty_page_mappings_for_host/get_live_mapping`。
  保留并仍被使用：`observe_*`、`err_ap`、`bind_domain_root`、`get_live_mapping_for_host`、`get_dirty_page_records_for_host`、`snapshot_live_mappings_for_host`、`validate/claim_restored_queue_ownership`。

**证据（HEAD）：** 上列方法在定义外 0 引用（含 `$DPU_COMMON_ROOT/src`、`$DPU_COMMON_ROOT/tests`，reg backend 的方法名在 dpu_common 中 0 出现）。
**Spec deviation（IOMMU）：** spec 说"五个无调用的 dirty/live 查询"；HEAD 实际有 **六个** 0 调用的 host0 包装：`snapshot_live_mappings`、`get_and_clear_dirty`、`get_dirty_page_mapping`、`get_dirty_page_records`、`get_dirty_page_mappings`、`get_live_mapping`；仅被它们使用的 `_for_host` 变体是 `get_dirty_page_mapping_for_host` 与 `get_dirty_page_mappings_for_host`。六个全部删除；`snapshot_live_mappings_for_host`（auto_fsm:1286）、`get_dirty_page_records_for_host`（auto_fsm:1248、unit_test:435）、`get_live_mapping_for_host`（virtqueue_base、atomic_ops）有其他调用方，保留。这些包装不在 P4.1 的迁移清单中，无冲突。
**Spec deviation（删除方法产生的孤儿，一并删除）：** monitor 的 `pkt_ap`（只被 `broadcast_pkt` 写）、`used_features`（只被 `check_feature_dependency` 累加与复位清零）、`chk_feature_usage`（只被 `check_feature_dependency` 读）；reg backend 的 `root_by_host`（只被 `bind_host_root` 写，`get_root_sequencer` 中的分支恒不成立）与 `completion_poll_limit`（只被 `wait_for_completion` 读）；IOVA proxy 的 `m_direct_gpa_mode` 及其读写分支（只有 `set_direct_gpa_mode` 能置 1）与 getter `direct_gpa_mode()`（0 引用）。

- [ ] **Step 1: `virtio_monitor.sv`**

```bash
f=virtio_net_vip/src/agent/virtio_monitor.sv
p1_del $f '    // 兼容旧接口：直接委托 observe_status_write 做状态转换检查。' 0 53
#   预期 first:[    // 兼容旧接口：直接委托 observe_status_write ...] last:[] keep-:[] keep+:[    // 构造一笔 monitor 事件事务：...]
p1_del_line $f '    uvm_analysis_port #(uvm_object)         pkt_ap;'
p1_del_line $f '    bit chk_feature_usage = 1;'
p1_del_line $f "    protected bit [63:0] used_features = '0;"
p1_del_line $f '        pkt_ap = new("pkt_ap", this);'
p1_del_line $f "        used_features = '0;"
sed -i 's|^    // 创建三个分析端口（txn/err/pkt）、四类事件 FIFO 及对应 uvm_event。$|    // 创建两个分析端口（txn/err）、四类事件 FIFO 及对应 uvm_event。|' $f
sed -i 's|^    // 复位全部协议语义状态：设备状态回 RESET、清 feature 使用记录、$|    // 复位全部协议语义状态：设备状态回 RESET、|' $f
```

- [ ] **Step 2: `pcie_tl_dpu_reg_backend.sv`**

```bash
f=virtio_net_vip/src/pcie/pcie_tl_dpu_reg_backend.sv
p1_del $f '    function void bind_host_root(input int unsigned host_id,' 1 4
#   预期 first:[    // 设置 Host 级 RC root 后备映射；...] last:[] keep+:[    // 将 host_id/segment_id 压缩为关联数组键，...]
p1_del $f '    protected function void calc_mem_transfer(' 10 27
#   预期 first:[    // 中文：输入绝对地址和字节宽度，...] last:[] keep+:[    // 将配置空间写数据按地址低 lane 左移到 PCIe CFG TLP payload 位置。]
p1_del $f '    protected function bit [63:0] payload_value(' 1 44
#   预期 first:[    // 从 Completion 返回字节数组中按 lane 提取...] last:[] keep+:[    // 把配置空间或 BAR-relative MMIO 写计划序列化为 PCIe CFG/MEM TLP；配置读写]
p1_del_line $f '        completion_poll_limit = 50000;'
sed -i 's|^    // 初始化 backend 的 root 选择和 Completion 轮询上限；此时不绑定 snapshot$|    // 初始化 backend 的 root 选择；此时不绑定 snapshot|' $f
sed -i 's|^    // 设置精确 PCIe domain 到 RC root 的映射，优先级高于 Host 级后备映射。$|    // 设置精确 PCIe domain 到 RC root 的映射。|' $f
sed -i 's|^    // 按 domain→host→default 的优先级选取 RC sequencer；不存在或越界时返回 0。$|    // 按 domain→default 的优先级选取 RC sequencer；不存在或越界时返回 0。|' $f
```
Edit 1 old:
```
    int unsigned root_by_host[int unsigned];
    // A Host can expose more than one independent PCIe segment/root.  Keep
    // the legacy host-only map as a fallback, but prefer an exact domain map
    // whenever a caller has bound one.
    int unsigned root_by_domain[longint unsigned];
    int unsigned completion_poll_limit;
```
new:
```
    // A Host can expose more than one independent PCIe segment/root, so
    // root selection is keyed by the exact {host, segment} domain.
    int unsigned root_by_domain[longint unsigned];
```
Edit 2 old:
```
        if (root_by_domain.exists(domain_map_key(host_id, segment_id)))
            root_index = root_by_domain[domain_map_key(host_id, segment_id)];
        else if (root_by_host.exists(host_id))
            root_index = root_by_host[host_id];
```
new:
```
        if (root_by_domain.exists(domain_map_key(host_id, segment_id)))
            root_index = root_by_domain[domain_map_key(host_id, segment_id)];
```

- [ ] **Step 3: `virtio_pci_cap_manager.sv`**

```bash
f=virtio_net_vip/src/transport/virtio_pci_cap_manager.sv
p1_del $f '    function bit [63:0] get_isr_bar_offset();' 1 8
#   预期 first:[    // ISR 状态区在其 BAR 内的字节偏移。] last:[] keep+:[    // device 专属 config 区在其 BAR 内的字节偏移。]
p1_del $f '    function bit all_mandatory_caps_found();' 1 3
#   预期 first:[    // Check that all mandatory capabilities were discovered] last:[] keep+:[    // Check that MSI-X is available]
```

- [ ] **Step 4: `split_virtqueue.sv` / `packed_virtqueue.sv`**

```bash
f=virtio_net_vip/src/virtqueue/split_virtqueue.sv
p1_del $f '    protected function bit [15:0] read_desc_flags(int unsigned idx);' 1 5
#   预期 first:[    // Read the flags field of a descriptor] last:[] keep+:[    // Write 16-bit value to avail ring at given byte offset]
p1_del $f '    protected function bit [15:0] read_avail_16(int unsigned byte_offset);' 1 5
#   预期 first:[    // Read 16-bit value from avail ring at given byte offset] last:[] keep+:[    // Write 16-bit value to used ring at given byte offset]
p1_del $f '    protected function void write_used_16(int unsigned byte_offset, bit [15:0] val);' 1 6
#   预期 first:[    // Write 16-bit value to used ring at given byte offset] last:[] keep+:[    // Read 16-bit value from used ring at given byte offset]
p1_del virtio_net_vip/src/virtqueue/packed_virtqueue.sv \
  '    protected function bit [15:0] read_packed_desc_flags(int unsigned idx);' 1 5
#   预期 first:[    // Read only the flags field of a packed descriptor] last:[] keep+:[    // Write 16-bit value to event suppression area ...]
```

- [ ] **Step 5: `virtio_atomic_ops.sv`**

```bash
p1_del virtio_net_vip/src/agent/virtio_atomic_ops.sv \
  '    virtual function bit validate_restored_indirect_ownership(' 2 12
#   预期 first:[] last:[    endfunction] keep-:[    endfunction] keep+:[]
#   （删除区间含 "// Compatibility name ..." 与 "// 兼容旧名：..." 两段注释及两个包装函数）
```

- [ ] **Step 6: `virtio_pcie_iova_host_mem_proxy.sv`**

```bash
f=virtio_net_vip/src/pcie/virtio_pcie_iova_host_mem_proxy.sv
p1_del $f '    function void set_direct_gpa_mode(input bit enable);' 3 4
#   预期 first:[    // 接口契约：切换 legacy 直通模式；...] last:[    function bit direct_gpa_mode(); return m_direct_gpa_mode; endfunction] keep-:[] keep+:[    // 以下统计只记录本代理...]
p1_del_line $f '    protected bit                 m_direct_gpa_mode;'
p1_del_line $f '        m_direct_gpa_mode = 0;'
sed -i 's|^//           由调用方回收底层 manager 的分配。direct GPA 只用于显式 legacy 场景。$|//           由调用方回收底层 manager 的分配。|' $f
```
Edit 1 old:
```
    // Host；未配置、范围不足或 IOMMU 翻译失败返回 0，后者递增 fault 计数；
    // 直通模式只检查 manager aperture，不经过 IOMMU。
```
new:
```
    // Host；未配置、范围不足或 IOMMU 翻译失败返回 0，后者递增 fault 计数。
```
Edit 2 old:
```
        if (!m_configured || (m_mem == null)) return 0;
        if (m_direct_gpa_mode) begin
            gpa = iova;
            return m_mem.contains_range(gpa, size);
        end
        if ((m_iommu == null) || !m_iommu.translate_for_host(
```
new:
```
        if (!m_configured || (m_mem == null)) return 0;
        if ((m_iommu == null) || !m_iommu.translate_for_host(
```
Edit 3 old:
```
    // 接口契约：addr 是设备可见 IOVA，data 是设备写入字节。正常模式通过
    // write_from_device_for_host 保留权限/dirty tracking；空数据、未配置、范围或
    // 权限失败时不写入且不递增 write_count。直通模式直接写 GPA。
    virtual function void write_mem(bit [63:0] addr, byte data[],
                                    string file = "", int line = 0);
        bit [63:0] gpa;
        iommu_fault_e fault;
        if ((data.size() == 0) || !m_configured || (m_mem == null)) return;
        if (m_direct_gpa_mode) begin
            if (!m_mem.contains_range(addr, data.size())) return;
            m_mem.write_mem(addr, data, file, line);
        end else if ((m_iommu != null) && m_iommu.write_from_device_for_host(
                         m_host_id, m_mem, m_bdf, addr, data, fault)) begin
            gpa = addr; // only used for diagnostics/debug; translation is internal
        end else begin
            m_translation_fault_count++;
            return;
        end
        m_write_count++;
    endfunction
```
new:
```
    // 接口契约：addr 是设备可见 IOVA，data 是设备写入字节。写入通过
    // write_from_device_for_host 保留权限/dirty tracking；空数据、未配置、范围或
    // 权限失败时不写入且不递增 write_count。
    virtual function void write_mem(bit [63:0] addr, byte data[],
                                    string file = "", int line = 0);
        iommu_fault_e fault;
        if ((data.size() == 0) || !m_configured || (m_mem == null)) return;
        if ((m_iommu == null) || !m_iommu.write_from_device_for_host(
                m_host_id, m_mem, m_bdf, addr, data, fault)) begin
            m_translation_fault_count++;
            return;
        end
        m_write_count++;
    endfunction
```
（`m_direct_gpa_mode` 恒为 0，原 `else if` 成功分支只做无用的 `gpa = addr`，新代码逐分支等价。）

- [ ] **Step 7: `virtio_iommu_model.sv`**

```bash
f=virtio_net_vip/src/iommu/virtio_iommu_model.sv
p1_del $f '    function bit snapshot_live_mappings(' 5 7
#   预期 first:[    // Snapshot every live mapping belonging to one requester.  Dirty-page] last:[] keep+:[    // 快照指定 {host, BDF} 的全部 live mapping（身份 + 完整 payload）。脏页]
p1_del $f '    function void get_and_clear_dirty(ref bit [63:0] dirty_pages[$]);' 2 57
#   预期 first:[    // Backwards-compatible legacy helper.  New migration code must use the] last:[] keep+:[    // 返回某脏页上全部已完成设备写的快照记录（含写后 payload 的精确字节）。]
#   （区间含 get_and_clear_dirty、get_dirty_page_mapping、get_dirty_page_mapping_for_host、get_dirty_page_records）
p1_del $f '    function void get_dirty_page_mappings(' 1 21
#   预期 first:[    // Compatibility projection for callers that need only identities.] last:[] keep+:[    // Confirm that a complete mapping snapshot still names one exact live]
p1_del $f '    function bit get_live_mapping(bit [15:0] bdf, bit [63:0] iova,' 3 4
#   预期 first:[    // Return one exact live mapping after migration has recreated a stable] last:[] keep+:[    // 按 {host, BDF, IOVA} 精确键查询单条 live mapping（iova 必须是映射起始]
sed -i 's|^    // 与 get_dirty_page_mapping_for_host 不同，这里读的是 write_from_device$|    // 数据来自 write_from_device|' $f
```

- [ ] **Step 8: grep 证据**

```bash
grep -rnwE 'check_status_transition|check_feature_dependency|check_queue_access_valid|broadcast_txn|broadcast_error|broadcast_pkt|pkt_ap|chk_feature_usage|used_features|bind_host_root|root_by_host|calc_mem_transfer|payload_value|wait_for_completion|completion_poll_limit|get_isr_bar|get_isr_bar_offset|all_mandatory_caps_found|read_avail_16|write_used_16|read_desc_flags|read_packed_desc_flags|validate_restored_indirect_ownership|claim_restored_indirect_ownership|set_direct_gpa_mode|direct_gpa_mode|m_direct_gpa_mode|snapshot_live_mappings|get_and_clear_dirty|get_dirty_page_mapping|get_dirty_page_mapping_for_host|get_dirty_page_records|get_dirty_page_mappings|get_dirty_page_mappings_for_host|get_live_mapping' \
  virtio_net_vip examples scripts filelists
```
预期：无输出（`-w` 不会匹配到保留的 `snapshot_live_mappings_for_host`、`get_dirty_page_records_for_host`、`get_live_mapping_for_host`）。

- [ ] **Step 9: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_monitor_test virtio_monitor_routing_test dpu_pcie_tl_executor_integration_test virtio_real_dut_iova_dma_test virtio_pcie_host_mem_test virtio_migration_dirty_test virtio_unit_test virtio_queue_semantics_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
```

- [ ] **Step 10: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 11: Commit**

```bash
git add virtio_net_vip/src/agent/virtio_monitor.sv virtio_net_vip/src/pcie/pcie_tl_dpu_reg_backend.sv \
  virtio_net_vip/src/transport/virtio_pci_cap_manager.sv virtio_net_vip/src/virtqueue/split_virtqueue.sv \
  virtio_net_vip/src/virtqueue/packed_virtqueue.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv \
  virtio_net_vip/src/pcie/virtio_pcie_iova_host_mem_proxy.sv virtio_net_vip/src/iommu/virtio_iommu_model.sv
git commit -m "refactor: 删除 monitor/backend/cap/virtqueue/ops/IOVA/IOMMU 中的零散死方法"
```

---

### Task P1-8: 删除 `virtio_base_test` 与 RX `RX_MODE_BIG/RX_MODE_SMALL`

**Files:**
- Delete: `virtio_net_vip/tests/virtio_base_test.sv`（127 行）
- Modify: `filelists/tests.f:36`（P0.4 可能已改本文件，用整行匹配）
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv:140`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv:379`
- Modify: `virtio_net_vip/src/dataplane/virtio_rx_engine.sv`（P0 后行号变化；锚点见下）
- Test: 全量回归 + `virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、`virtio_real_driver_rx_test`

**Interfaces:**
- Consumes: P1-3 后的 `receive_packets`（已无回调分支）。
- Produces: `rx_buf_mode_e` 只剩 `RX_MODE_MERGEABLE`（保留类型以维持 `virtio_net_dataplane::configure(..., rx_buf_mode_e rx_mode, ...)`、`virtio_driver_config_t.rx_buf_mode`、`virtio_net_env_config.default_rx_mode` 的签名；测试中的 `RX_MODE_MERGEABLE` 实参不变）；`virtio_rx_engine::get_rx_buf_size()` 恒返回 `buf_size`；删除 `receive_big/receive_small/receive_single_buf`。

**证据（HEAD）：** `virtio_base_test` 无派生类、不在 `VIRTIO_MAINTAINED_TESTS`，只在 `filelists/tests.f:36` 编译；README/手册把它当用户模板（由 P1-9 改写）。
`rx_engine.buf_mode` 只由 `virtio_net_dataplane::configure()` 赋值，后者只被 `virtio_indirect_desc_test.sv:679,696,846` 与 `virtio_net_packet_multi_queue_test.sv:252` 以 `RX_MODE_MERGEABLE` 调用。
**Spec deviation:** spec 称"无人设置 `buf_mode`/0 引用"，但 `virtio_net_env_config.sv:379` 在私有配置路径写 `driver_cfg.rx_buf_mode = RX_MODE_SMALL;`。`virtio_driver_config_t.rx_buf_mode` 在 src/tests/examples 中**从未被读取**（私有 RX 容量由 `dpu_priv_rx_engine::get_rx_buf_size()` 覆盖返回 `rx_buf_size`），该赋值无行为，删除该行。
**说明：** `receive_single_buf` 只服务于 `receive_big/receive_small`，删除 BIG/SMALL 后成为孤儿，在本任务一并删除；P2.1 不必再处理它（若 P0 已删除这些函数，对应步骤跳过）。

- [ ] **Step 1: 删除 base test**

```bash
git rm -q virtio_net_vip/tests/virtio_base_test.sv
p1_del_line filelists/tests.f 'virtio_net_vip/tests/virtio_base_test.sv'
```

- [ ] **Step 2: 类型与配置**

```bash
sed -i 's|^typedef enum { RX_MODE_MERGEABLE, RX_MODE_BIG, RX_MODE_SMALL } rx_buf_mode_e;$|typedef enum { RX_MODE_MERGEABLE } rx_buf_mode_e;|' \
  virtio_net_vip/src/types/virtio_net_types.sv
grep -c '^typedef enum { RX_MODE_MERGEABLE } rx_buf_mode_e;$' virtio_net_vip/src/types/virtio_net_types.sv   # 预期 1
p1_del_line virtio_net_vip/src/env/virtio_net_env_config.sv '            driver_cfg.rx_buf_mode = RX_MODE_SMALL;'
```

- [ ] **Step 3: `virtio_rx_engine.sv`（P0 后；对仍存在的项执行）**

先定位：`grep -nE 'RX_MODE_BIG|RX_MODE_SMALL|receive_big|receive_small|receive_single_buf|Three buffer modes' virtio_net_vip/src/dataplane/virtio_rx_engine.sv`。

```bash
f=virtio_net_vip/src/dataplane/virtio_rx_engine.sv
p1_del $f '    // receive_big (protected)' 1 123
#   预期 first:[    // ====...] last:[] keep-:[] keep+:[    // ====...]（HEAD 391-515；last 的上一行是 "    endtask : receive_single_buf"，keep+ 之后是 cleanup_rx_buffer 注释）
sed -i 's|^    // 按 buffer 模式取得至多 budget 个包，追加到 received；之后按现有$|    // 以 mergeable 模式取得至多 budget 个包，追加到 received；之后按现有|' $f
```
Edit 1（文件头）old:
```
// Three buffer modes are supported:
//   RX_MODE_MERGEABLE -- Multiple small buffers can be merged for one packet.
//                        Header includes num_buffers field.
//   RX_MODE_BIG       -- Single large buffer (64K+) per packet.
//   RX_MODE_SMALL     -- Single buffer sized for MTU + header.
```
new:
```
// Buffer mode: RX_MODE_MERGEABLE only -- several buffers can be merged for
// one packet; the header carries the num_buffers field.
```
Edit 2（`get_rx_buf_size`）old:
```
    // Returns the appropriate buffer allocation size based on the
    // current buffer mode.
    // ==================================================================
    // 查询模式对应的 buffer 容量；设为虚接口供私有协议返回不含 Virtio header 的容量。
    virtual function int unsigned get_rx_buf_size();
        int unsigned hdr_size;
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        case (buf_mode)
            RX_MODE_MERGEABLE: return buf_size;
            RX_MODE_BIG:       return 65550;
            RX_MODE_SMALL:     return 1514 + hdr_size;
            default:           return buf_size;
        endcase
    endfunction : get_rx_buf_size
```
new:
```
    // Returns the mergeable RX buffer allocation size.
    // ==================================================================
    // 查询 mergeable buffer 容量；设为虚接口供私有协议返回不含 Virtio header 的容量。
    virtual function int unsigned get_rx_buf_size();
        return buf_size;
    endfunction : get_rx_buf_size
```
Edit 3（`receive_packets` 分发）old:
```
        case (buf_mode)
            RX_MODE_MERGEABLE: receive_mergeable(queue_id, budget, received);
            RX_MODE_BIG:       receive_big(queue_id, budget, received);
            RX_MODE_SMALL:     receive_small(queue_id, budget, received);
        endcase
```
new:
```
        receive_mergeable(queue_id, budget, received);
```
Edit 4（`receive_packets` 注释）old:
```
    // Top-level RX entry point. Dispatches to the appropriate receive
    // method based on buffer mode, then auto-refills if needed.
```
new:
```
    // Top-level RX entry point. Receives mergeable buffers, then
    // auto-refills if needed.
```

- [ ] **Step 4: grep 证据**

```bash
grep -rnwE 'virtio_base_test|RX_MODE_BIG|RX_MODE_SMALL|receive_big|receive_small|receive_single_buf' \
  virtio_net_vip examples scripts filelists
test ! -e virtio_net_vip/tests/virtio_base_test.sv && echo BASE_TEST_GONE
```
预期：第一条无输出；第二条输出 `BASE_TEST_GONE`。

- [ ] **Step 5: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_indirect_desc_test virtio_net_packet_multi_queue_test virtio_real_driver_rx_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20"
done
```

- [ ] **Step 6: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```
（私有环流程测试此时已在 manifest 中，覆盖 `dpu_priv_rx_engine::get_rx_buf_size()` 与 `RX_MODE_SMALL` 赋值删除后的私有路径。）

- [ ] **Step 7: Commit**

```bash
git add -A virtio_net_vip/tests/virtio_base_test.sv filelists/tests.f virtio_net_vip/src/types/virtio_net_types.sv \
  virtio_net_vip/src/env/virtio_net_env_config.sv virtio_net_vip/src/dataplane/virtio_rx_engine.sv
git commit -m "refactor: 删除无派生的 virtio_base_test 与未使用的 RX big/small 模式"
```

---

### Task P1-9: README 与手册纠错（P1 最后一项）

**Files:**
- Modify: `README.md`（HEAD 行 15-16,20,36,47,189,198,214,227-228,250-287,697-728,882,890,935；P0.4 可能已改维护测试清单段落，以下一律用 old → new 文本）
- Modify: `docs/virtio_net_vip_manual.md`（HEAD 行 28-29,143,168-169,174-178,190-194,211-213,351-354,364-365,370,378-379,385-433,446,457-462,506,533,538,544,547,1088-1089,1129-1133,1291-1297,1336-1338,1341-1359,1371,1532-1534,1536,1547,1573-1657,1680,2083-2108,2163-2182,2267,2286,2289,2293-2297,2335,2390-2392）
- Test: `scripts/test_manifest.sh` 的文档契约检查（由 vcs.sh/strict_regression 在启动时执行）

**Interfaces:**
- Consumes: P1-1…P1-8 完成后的代码树。
- Produces: 无代码接口。

**Spec 覆盖：** 文件与行数、"依赖阻断编译"、split/packed 行数、`virtio_cpl_bridge/virtio_rc_driver_shim` → `virtio_tlm_completion_adapter/virtio_tlm_rc_driver_shim`、已删除的 sequence 库描述；外加 P1-1…P1-8 删除内容在文档中的全部引用（否则违反验收标准"README 与手册描述与代码一致"）。
**Spec deviation:** README "自动模式" 与手册 6.2.1/6.3.1 的用户示例继承 `virtio_base_test` 并使用 `virtio_smoke_vseq`/`env.v_seqr`，删除后示例无法编译；改为继承维护中的 `virtio_e2e_test`（`tests/virtio_smoke_test.sv` 即同一用法）。另 README:890 的 `virtio_bar_mem_wr_seq_bridged` 同样不存在，一并改为实际的 `virtio_bar_mem_wr_seq`。

- [ ] **Step 1: 统计数字（在全部 P1 代码提交之后运行）**

```bash
N_SRC=$(find virtio_net_vip/src -name '*.sv' | wc -l)
L_SRC=$(find virtio_net_vip/src -name '*.sv' -print0 | xargs -0 cat | wc -l)
N_TEST=$(find virtio_net_vip/tests -name '*.sv' | wc -l)
L_SPLIT=$(wc -l < virtio_net_vip/src/virtqueue/split_virtqueue.sv)
L_PACKED=$(wc -l < virtio_net_vip/src/virtqueue/packed_virtqueue.sv)
echo "N_SRC=$N_SRC L_SRC=$(printf "%'d" $L_SRC) N_TEST=$N_TEST L_SPLIT=$L_SPLIT L_PACKED=$L_PACKED"
```
下面 old → new 中的 `${N_SRC}` 等写入**上面命令打印出的实际整数**（例如 `66`），不是占位符文本；`L_SRC` 用打印出的千分位形式。

- [ ] **Step 2: README.md 编辑**

R1 old:
```
| 源文件数 | 90 个 `.sv` 文件 |
| 代码行数 | 约 20,000 行 SystemVerilog |
```
new:
```
| 源文件数 | ${N_SRC} 个 `.sv` 文件（`virtio_net_vip/src`），另有 ${N_TEST} 个测试文件 |
| 代码行数 | ${L_SRC} 行 SystemVerilog（`virtio_net_vip/src`） |
```
R2 old:
```
| EDA 工具 | Synopsys VCS（通过 `$VCS_HOME` 配置；当前固定依赖阻断编译） |
```
new:
```
| EDA 工具 | Synopsys VCS（通过 `$VCS_HOME` 配置；外部依赖版本由 `scripts/check_deps.sh` 校验） |
```
R3：`sed -i 's/（三种 buffer 模式）/（mergeable buffer 模式）/' README.md`（命中架构图与目录树两处）。
R4：`sed -i -e 's/← 记分板（8 类检查项）/← 记分板（7 类检查项）/' -e 's/← 记分板（8 类检查）/← 记分板（7 类检查）/' README.md`
R5 old:
```
- `STANDBY` — 主备切换（failover）
```
new:
```
- `STANDBY` — 主备切换特性位（仅参与协商，VIP 不建模 failover 切换）
```
R6 old:
```
| **PCIe 传输层** | 设备状态转换违规、Feature 协商异常、队列配置错误、通知错误（虚假中断/丢失中断） |
```
new:
```
| **PCIe 传输层** | Capability 信息破坏（`virtio_pci_cap_manager.inject_cap_error`） |
```
R7 old:
```
├── src/                                    ← 源代码（90 个文件）
```
new:
```
├── src/                                    ← 源代码（${N_SRC} 个文件）
```
R8 old:
```
│   │   ├── split_virtqueue.sv              ← Split 实现（约 500 行）
│   │   ├── packed_virtqueue.sv             ← Packed 实现（约 750 行）
```
new:
```
│   │   ├── split_virtqueue.sv              ← Split 实现（${L_SPLIT} 行）
│   │   ├── packed_virtqueue.sv             ← Packed 实现（${L_PACKED} 行）
```
R9 old（目录树 dataplane 段）:
```
│   │   ├── virtio_tso_engine.sv            ← TCP 分段
│   │   ├── virtio_uso_engine.sv            ← UDP 分段
│   │   ├── virtio_rss_engine.sv            ← RSS Toeplitz 哈希 + 队列选择
│   │   ├── virtio_failover_manager.sv      ← 主备切换管理
│   │   └── virtio_net_dataplane.sv         ← 数据面顶层封装
```
new:
```
│   │   ├── virtio_tso_engine.sv            ← TCP/UDP GSO 头长度判定（分段由设备完成）
│   │   ├── virtio_rss_engine.sv            ← RSS Toeplitz 哈希 + 队列选择
│   │   └── virtio_net_dataplane.sv         ← 数据面顶层封装
```
R10 old（env 段至 base_test 行；R4 已把 "8 类检查" 改成 "7 类检查"，故 old 中写 7）:
```
│   ├── env/                                ← 验证环境
│   │   ├── virtio_net_env_config.sv        ← 统一配置对象（25+ 可配参数）
│   │   ├── virtio_net_env.sv              ← 顶层环境（组件创建与连接）
│   │   ├── virtio_scoreboard.sv           ← 记分板（7 类检查）
│   │   ├── virtio_coverage.sv             ← 覆盖率收集器（8 组 covergroup）
│   │   ├── virtio_perf_monitor.sv         ← 性能监控（带宽 + 延迟）
│   │   ├── virtio_virtual_sequencer.sv    ← 虚拟序列器
│   │   ├── virtio_concurrency_controller.sv ← 并发控制器
│   │   └── virtio_dynamic_reconfig.sv     ← 动态重配置管理
│   ├── callbacks/                          ← 回调扩展点
│   │   ├── virtio_dataplane_callback.sv   ← 数据面自定义（TX 链/RX 解析/HDR 格式）
│   │   ├── virtio_scoreboard_callback.sv  ← 记分板自定义比对
│   │   └── virtio_coverage_callback.sv    ← 覆盖率自定义采样
│   └── seq/                                ← 序列库
│       ├── base/（7 个文件）                ← 基础序列（init/tx/rx/ctrl/kick/queue_setup）
│       ├── scenario/（22 个文件，9 个子目录） ← 场景序列
│       │   ├── lifecycle/                  ← 生命周期（完整循环/状态错误/Feature 错误）
│       │   ├── dataplane/                  ← 数据面（TSO/MRG_RXBUF/RSS/校验和/隧道）
│       │   ├── interrupt/                  ← 中断（自适应切换/EVENT_IDX 边界）
│       │   ├── migration/                  ← 热迁移/Failover
│       │   ├── sriov/                      ← SR-IOV（多 VF 初始化/FLR 隔离/混合队列）
│       │   ├── error/                      ← 错误注入（描述符/IOMMU/PCIe/坏包）
│       │   ├── concurrency/                ← 并发（多 VF 同时发包）
│       │   ├── dynamic/                    ← 动态变更（带流量 MQ 调整）
│       │   └── boundary/                   ← 边界（最小/最大队列/chain 满/背压/零包）
│       └── virtual/（4 个文件）             ← 虚拟序列（冒烟/全功能/多 VF/压力）
├── tests/                                  ← 测试文件
│   ├── virtio_tb_top.sv                    ← 顶层 Testbench 模块
│   ├── virtio_base_test.sv                 ← 基础测试类（默认配置）
```
new:
```
│   └── env/                                ← 验证环境
│       ├── virtio_net_env_config.sv        ← 统一配置对象（25+ 可配参数）
│       ├── virtio_net_env.sv              ← 顶层环境（组件创建与连接）
│       ├── virtio_scoreboard.sv           ← 记分板（7 类检查）
│       ├── virtio_coverage.sv             ← 覆盖率收集器（8 组 covergroup）
│       ├── virtio_perf_monitor.sv         ← 性能监控（带宽 + 延迟）
│       ├── virtio_concurrency_controller.sv ← 并发控制器（多 VF 并行操作/流量）
│       └── virtio_dynamic_reconfig.sv     ← 动态 MQ 调整
├── tests/                                  ← 测试文件
│   ├── virtio_tb_top.sv                    ← 顶层 Testbench 模块
```
R11（"自动模式" 示例）old:
```
class my_test extends virtio_base_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 覆盖默认配置
    virtual function void configure_default(virtio_net_env_config cfg);
        super.configure_default(cfg);
        cfg.default_num_pairs    = 4;           // 4 个队列对
        cfg.default_vq_type      = VQ_PACKED;   // 使用 Packed 队列
        cfg.default_irq_mode     = IRQ_POLLING;  // 轮询模式
        cfg.default_driver_mode  = DRV_MODE_AUTO;
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_function_instance pf_vio;
        virtio_smoke_vseq vseq;
        phase.raise_objection(this);

        // virtio_base_test declares a VIO-net service on PF0.  Per-function
        // behavior is authored by that service key; the runtime owner is the
        // corresponding PF function, not an undeclared positional VF.
        pf_vio = env.pf_instances[0].pf_function;
        vseq = virtio_smoke_vseq::type_id::create("vseq");
        vseq.vf_seqr = pf_vio.driver_agent.sequencer;
        vseq.start(env.v_seqr);

        phase.drop_objection(this);
    endtask
endclass
```
new:
```
// tests/virtio_e2e_test.sv 是维护中的参考骨架：build_phase 创建 pcie_tl_env、
// dpu_device_env 与 virtio_net_env（PF0 上声明一个 VIO-net service），
// connect_phase 调用 virtio_env.bind_pcie()。自定义测试继承它并只覆盖
// run_phase，用法与 tests/virtio_smoke_test.sv 相同。
class my_test extends virtio_e2e_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_pci_transport xport;
        phase.raise_objection(this);
        #200ns;

        phase1_setup_transport();   // 直接设置 BAR，不做 BAR 枚举
        phase2_virtio_init();       // 经 PCIe TLP 完成 virtio 初始化
        phase3_dataplane();         // 队列配置与 TX 报文提交

        // 运行时 owner 是 PF0 上 service 对应的 Function，而不是按位置索引 VF。
        xport = virtio_env.function_instances[0].transport;
        xport.write_device_status(DEV_STATUS_RESET);

        release_e2e_allocations();
        phase4_verify();
        phase.drop_objection(this);
    endtask
endclass
```
R12 old:
```
**解决方案**：通过 Completion Bridge 中间层（`virtio_cpl_bridge` + `virtio_rc_driver_shim` + 桥接序列）弥合异步缺口。详见 `tests/virtio_full_test.sv`。
```
new:
```
**解决方案**：通过 `src/transport/virtio_tlm_completion_adapter.sv` 中的 `virtio_tlm_completion_adapter`（按 `{tag, requester_id}` 暂存 completion）+ `virtio_tlm_rc_driver_shim`（经 factory 替换 RC driver，把 completion 复制进 adapter）+ BAR helper 序列（`wait_matching_completion()` 认领）弥合异步缺口；adapter 通过 `virtio_net_env.bind_pcie(rc_seqr, tlm_adapter)` 接入。详见 `tests/virtio_full_test.sv`。
```
R13 old:
```
**解决方案**：桥接写序列（`virtio_bar_mem_wr_seq_bridged`）使用 `start_item/finish_item` 直接构造 TLP，绕过 `uvm_do_with`。
```
new:
```
**解决方案**：BAR 写 helper 序列（`virtio_bar_mem_wr_seq`）使用 `start_item/finish_item` 直接构造 TLP，绕过 `uvm_do_with`。
```
R14（手册行数，在 Step 3 全部手册编辑之后执行）：`L_MAN=$(wc -l < docs/virtio_net_vip_manual.md); echo $L_MAN`，old:
```
| 项目手册（Markdown） | `docs/virtio_net_vip_manual.md` | 约 1900 行详细技术文档 |
```
new:
```
| 项目手册（Markdown） | `docs/virtio_net_vip_manual.md` | ${L_MAN} 行详细技术文档 |
```

- [ ] **Step 3: docs/virtio_net_vip_manual.md 编辑**

M1（目录）：
```bash
f=docs/virtio_net_vip_manual.md
p1_del_line $f '  - [4.11 Sequence 库 (seq/)](#411-sequence-库-seq)'
p1_del_line $f '  - [4.12 回调扩展点 (callbacks/)](#412-回调扩展点-callbacks)'
```
M2（架构图）：
```bash
p1_del_line $f '|  |   +-- failover_manager                 <-- STANDBY/failover            |'
p1_del $f '|  +-- virtio_virtual_sequencer                                             |' 1 3
#   预期 first:[|  |   (空白框线行)   |] last:[|      +-- pcie_rc_seqr ...|] keep-:[|  +-- pcie_tl_env (subenv) ...|] keep+:[+===...===+]
```
old:
```
|  +-- concurrency_controller              <-- 多 VF 并发操作 + 竞争注入    |
|  +-- dynamic_reconfig                     <-- 运行时 MQ/MTU/IRQ/MAC/VLAN  |
```
new:
```
|  +-- concurrency_controller              <-- 多 VF 并发操作               |
|  +-- dynamic_reconfig                     <-- 运行时 MQ 调整              |
```
M3（组件层次）old:
```
5. **驱动层**（Phase 5）：回调接口、事务类、原子操作库、自动 FSM、UVM Agent
6. **数据面层**（Phase 6）：TX/RX 引擎、offload 引擎、failover 管理
7. **SR-IOV 层**（Phase 7）：VF 资源池、VF 实例、PF 管理器
8. **环境层**（Phase 8）：配置、scoreboard、coverage、性能监控、并发控制
9. **序列层**（Phase 9）：基础序列、场景序列、虚拟序列
```
new:
```
5. **驱动层**（Phase 5）：事务类、原子操作库、自动 FSM、UVM Agent
6. **数据面层**（Phase 6）：TX/RX 引擎、offload 引擎
7. **SR-IOV 层**（Phase 7）：VF 资源池、VF 实例、PF 管理器
8. **环境层**（Phase 8）：配置、scoreboard、coverage、性能监控、并发控制
```
M4（TX 数据流）old:
```
 |  +-- offload_engine.compute_csum()  -- 如果需要 checksum offload
 |  +-- tso_engine.segment()           -- 如果需要 TSO
 |  +-- uso_engine.segment()           -- 如果需要 USO
```
new:
```
 |  +-- offload_engine.calc_csum_start()/calc_csum_offset()  -- 如果需要 checksum offload
 |  +-- offload_engine.get_gso_type()/get_all_hdr_len()      -- 如果需要 TSO/USO（分段由设备完成）
```
M5（目录树）：
```bash
p1_del $f '|   |   +-- virtio_dataplane_callback.sv    -- 数据面自定义回调 (TX chain/RX parse)' 1 2
#   预期 first:[|   +-- callbacks/] last:[|   |   +-- virtio_coverage_callback.sv ...] keep+:[|   +-- agent/]
p1_del_line $f '|   |   +-- virtio_uso_engine.sv            -- UDP Segmentation Offload 引擎'
p1_del_line $f '|   |   +-- virtio_failover_manager.sv      -- STANDBY/failover 管理'
p1_del_line $f '|   |   +-- virtio_virtual_sequencer.sv     -- 虚拟 Sequencer'
p1_del $f '|   +-- seq/' 0 45
#   预期 first:[|   +-- seq/] last:[|           +-- virtio_stress_vseq.sv] keep-:[|   |   +-- virtio_net_env.sv               -- 顶层环境] keep+:[+-- tests/]
p1_del_line $f '|   +-- virtio_base_test.sv                 -- 基础 test 类'
sed -i -e 's/^|   |   +-- virtio_tso_engine.sv            -- TCP Segmentation Offload 引擎$/|   |   +-- virtio_tso_engine.sv            -- TCP\/UDP GSO 头长度判定 (不分段)/' \
       -e 's/^|   |   +-- virtio_scoreboard.sv            -- 8 类检查的 Scoreboard$/|   |   +-- virtio_scoreboard.sv            -- 7 类检查的 Scoreboard/' $f
```
M6 old:
```
**总计：约 75 个源文件（含测试）。**
```
new:
```
**总计：`src/` ${N_SRC} 个 `.sv` 文件，`tests/` ${N_TEST} 个 `.sv` 文件。**
```
M7（目录职责表）：
```bash
p1_del_line $f '| `src/callbacks/` | 用户扩展回调接口定义 |'
p1_del_line $f '| `src/seq/` | 序列库：基础序列、场景序列、虚拟序列 |'
sed -i 's/^| `src\/dataplane\/` | 数据面引擎：TX\/RX、offload、failover |$/| `src\/dataplane\/` | 数据面引擎：TX\/RX、offload |/' $f
```
M8（类型表与特性表）：
```bash
sed -i 's/^| `VIRTIO_NET_F_STANDBY` | 62 | failover 待机模式 |$/| `VIRTIO_NET_F_STANDBY` | 62 | failover 待机模式（仅特性位） |/' $f
sed -i 's/^| `rx_buf_mode_e` | `RX_MODE_MERGEABLE`, `RX_MODE_BIG`, `RX_MODE_SMALL` | RX 缓冲区模式 |$/| `rx_buf_mode_e` | `RX_MODE_MERGEABLE` | RX 缓冲区模式（仅 mergeable） |/' $f
p1_del_line $f '| `failover_state_e` | `FO_NORMAL` 到 `FO_FAILBACK` | Failover 状态 |'
p1_del_line $f '| `race_point_e` | 7 种竞争点 | 并发竞争注入位置 |'
p1_del_line $f '| `queue_setup_error_e` | 6 种队列配置错误 | 队列配置错误注入 |'
```
M9（BAR accessor、通知管理器）：
```bash
p1_del_line $f '| `read_reg_with_error(...)` | Memory Read (BE=0) | 错误注入读 |'
p1_del_line $f '| `write_reg_with_error(...)` | Memory Write (BE=0) | 错误注入写 |'
p1_del $f '- `inject_spurious_interrupt(vector)` -- 注入虚假中断' 1 3
#   预期 first:[**错误注入：**] last:[] keep-:[] keep+:[#### 4.6.5 PCI Transport 封装 (`virtio_pci_transport`)]
```
M10（RX/Offload/Failover）：
```bash
sed -i 's/^RX 引擎支持三种 buffer 模式：$/RX 引擎只支持 mergeable buffer 模式：/' $f
p1_del_line $f '| `RX_MODE_BIG` | - | 大 buffer (如 65535) | 单个 buffer 容纳完整报文 |'
p1_del_line $f '| `RX_MODE_SMALL` | - | 页大小 (4096) | 单页 buffer |'
p1_del_line $f '| `virtio_uso_engine` | UDP 分段（1.2+） |'
sed -i -e 's/^| `virtio_csum_engine` | TX: 计算伪头部 checksum; RX: 验证完整 checksum |$/| `virtio_csum_engine` | TX: 计算 csum_start\/csum_offset; RX: 验证完整 checksum |/' \
       -e 's/^| `virtio_tso_engine` | TCP 分段，更新 IP\/TCP 头部 |$/| `virtio_tso_engine` | TCP\/UDP GSO 头长度及是否超过 MSS 的判定（分段由设备完成） |/' $f
p1_del $f '#### 4.8.5 Failover Manager' 0 18
#   预期 first:[#### 4.8.5 Failover Manager] last:[] keep-:[] keep+:[### 4.9 SR-IOV (sriov/)]
p1_del_line $f '- `failover_manager`: STANDBY feature'
```
M11（配置表、scoreboard 表）：
```bash
p1_del_line $f '| Failover | `failover_enable` | 0 | Failover 开关 |'
p1_del_line $f '| | `primary_vf_id` | 0 | 主 VF ID |'
p1_del_line $f '| | `standby_vf_id` | 1 | 备 VF ID |'
p1_del_line $f '| 配置一致性 | `chk_config_consistency` | 设备配置值匹配 |'
sed -i 's/^#### 4.10.2 Scoreboard（8 个检查类别）$/#### 4.10.2 Scoreboard（7 个检查类别）/' $f
```
M12（删除 4.11 Sequence 库与 4.12 回调两节）：
```bash
p1_del $f '### 4.11 Sequence 库 (seq/)' 0 84
#   预期 first:[### 4.11 Sequence 库 (seq/)] last:[] keep-:[] keep+:[---]（last 的上一行是 "用于注册用户自定义 covergroup 采样。"；HEAD 1573-1657）
```
M13（特性矩阵）：
```bash
sed -i 's/^| `VIRTIO_NET_F_STANDBY` | 62 | 完整 | `failover_enable` |$/| `VIRTIO_NET_F_STANDBY` | 62 | 仅协商（不建模 failover） | `default_driver_features[62]` |/' $f
```
M14（6.2.1 基本测试模板）old:
```
class my_test extends virtio_base_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 自定义配置
    virtual function void configure_default(virtio_net_env_config cfg);
        super.configure_default(cfg);
        cfg.default_num_pairs    = 2;
        cfg.default_queue_size   = 128;
        cfg.default_vq_type      = VQ_PACKED;
        cfg.scb_enable           = 1;
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_full_init_traffic_vseq vseq;
        phase.raise_objection(this);

        vseq = virtio_full_init_traffic_vseq::type_id::create("vseq");
        vseq.start(env.v_seqr);

        phase.drop_objection(this);
    endtask
endclass
```
new:
```
// 继承维护中的 tests/virtio_e2e_test.sv：它负责创建 pcie_tl_env、
// dpu_device_env、virtio_net_env 并在 connect_phase 调用 bind_pcie()。
// 配置在其 build_phase 中通过 virtio_cfg（virtio_net_env_config）设置。
class my_test extends virtio_e2e_test;
    `uvm_component_utils(my_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        #200ns;
        phase1_setup_transport();
        phase2_virtio_init();
        phase3_dataplane();
        release_e2e_allocations();
        phase4_verify();
        phase.drop_objection(this);
    endtask
endclass
```
M15（6.3.1 PCIe 接口连接）old:
```
class my_dut_test extends virtio_base_test;
    pcie_tl_env  pcie_env;

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        // nonvirtual bind_pcie() 统一绑定所有 PF/VF，并逐层传播失败。
        if (!env.bind_pcie(pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("DUT_BIND", "virtio environment PCIe bind failed")
            return;
        end
    endfunction
endclass
```
new:
```
// 摘自 tests/virtio_e2e_test.sv::connect_phase；pcie_env/virtio_env/tlm_adapter
// 均由该测试的 build_phase 创建。
virtual function void connect_phase(uvm_phase phase);
    super.connect_phase(phase);
    // nonvirtual bind_pcie() 统一绑定所有 PF/VF，并逐层传播失败。
    if (!virtio_env.bind_pcie(pcie_env.rc_agent.sequencer, tlm_adapter)) begin
        `uvm_fatal("DUT_BIND", "virtio environment PCIe bind failed")
        return;
    end
endfunction
```
M16 old:
```
`bind_pcie()` 返回 1 前会验证每个 function 的 driver/monitor/observer、独立 protocol-event VIF 和 MQ capability；任一项失败都会返回 0，并且不会提交环境级 RC sequencer 或 protocol-VIF 计数。调用方必须检查返回值。
```
new:
```
`bind_pcie()` 返回 1 前会验证每个 function 的 driver/monitor/observer、独立 protocol-event VIF 和 MQ capability；任一项失败都会返回 0，并且不会向任何 function 提交 RC sequencer，也不会推进 protocol-VIF 计数。调用方必须检查返回值。
```
M17（测试优先级）：
```bash
sed -i 's/^7\. \*\*第七优先：高级场景\*\* -- 热迁移、failover、多 VF 并发、动态重配置$/7. **第七优先：高级场景** -- 热迁移、多 VF 并发、动态 MQ 调整/' $f
```
M18（已知限制表与 8.2）old:
```
| TLM loopback `get_response()` | 在 TLM loopback 模式下，PCIe RC driver 的 `get_response()` 可能死锁 | 使用 `virtio_cpl_bridge` 中间件解决（见 `virtio_full_test.sv`） |
```
new:
```
| TLM loopback `get_response()` | 在 TLM loopback 模式下，PCIe RC driver 的 `get_response()` 可能死锁 | 使用 `virtio_tlm_completion_adapter` + `virtio_tlm_rc_driver_shim` 解决（见 `virtio_full_test.sv`） |
```
old:
```
| net_packet 集成 | TX/RX engine 使用 `uvm_object` 封装 `packet_item` | 需要 `virtio_dataplane_callback` |
```
new:
```
| net_packet 集成 | TX/RX engine 使用 `uvm_object` 封装 `packet_item` | 字节流转换由 `virtio_net_packet_adapter` 完成 |
```
old:
```
为解决 TLM loopback 模式下的 `get_response()` 死锁问题，`virtio_full_test.sv` 引入了三层中间件架构：

1. **`virtio_cpl_bridge`** -- FIFO 化的 completion 存储（单 mailbox，因 virtio 寄存器访问是顺序的）
2. **`virtio_rc_driver_shim`** -- 继承 `pcie_tl_rc_driver`，将 completion 推入 bridge
3. **Bridged Sequences** -- 使用 bridge 的 `wait_completion()` 替代 `get_response()`
```
new:
```
为解决 TLM loopback 模式下的 `get_response()` 死锁问题，`src/transport/virtio_tlm_completion_adapter.sv` 提供三部分（`virtio_full_test.sv`、`virtio_e2e_test.sv` 通过 `bind_pcie(rc_seqr, tlm_adapter)` 使用）：

1. **`virtio_tlm_completion_adapter`** -- 按 `{tag, requester_id}` 暂存 completion，直到对应等待方认领
2. **`virtio_tlm_rc_driver_shim`** -- 经 factory 替换 `pcie_tl_rc_driver`，在父类处理后把 completion 复制进 adapter
3. **BAR helper sequences** -- `virtio_bar_accessor` 的读写序列使用 adapter 的 `wait_matching_completion()` 替代 `get_response()`
```
M19（API 参考）：
```bash
p1_del_line $f '| `get_and_clear_dirty` | `function void get_and_clear_dirty(ref bit[63:0] dirty_pages[$])` | 获取并清除脏页 |'
p1_del_line $f '| `inject_status_error` | task | 状态错误注入 |'
p1_del_line $f '| `inject_feature_error` | task | Feature 错误注入 |'
p1_del_line $f '| `inject_queue_setup_error` | task | 队列配置错误注入 |'
```
（10.3 节 commit 历史表是历史记录，保持不变。）

完成后执行 Step 2 的 R14。

- [ ] **Step 4: grep 证据**

```bash
grep -nE 'virtio_base_test|_vseq\b|v_seqr|virtual_sequencer|virtio_(dataplane|scoreboard|coverage)_callback|failover_manager|failover_state_e|failover_enable|primary_vf_id|standby_vf_id|uso_engine|\.segment\(|RX_MODE_BIG|RX_MODE_SMALL|race_point_e|queue_setup_error_e|inject_(status|feature|queue_setup)_error|_reg_with_error|inject_(spurious|missed)_interrupt|inject_wrong_vector|get_and_clear_dirty|chk_config_consistency|virtio_cpl_bridge|virtio_rc_driver_shim|_bridged|阻断编译|src/seq|seq/|callbacks/|三种 buffer|8 类检查|8 个检查|约 75 个|90 个|约 20,000|约 500 行|约 750 行|约 1900 行' \
  README.md docs/virtio_net_vip_manual.md
```
预期：无输出（10.3 历史表的 "failover 管理器"、"基础和场景序列"、"base test" 不匹配上述模式）。

- [ ] **Step 5: SYNC + 文档契约检查**

`vcs.sh` 在启动时 source `scripts/test_manifest.sh`，后者校验 README/手册的维护测试清单、placement/executor 示例与禁用写法；先单跑一个测试确认契约通过：
```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_smoke_test ./scripts/vcs.sh > logs/virtio_smoke_test.log 2>&1; echo rc=$?; head -5 logs/virtio_smoke_test.log; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_smoke_test.log | tail -20'
```
预期：`rc=0`；日志开头没有 `README ...`/`manual ...`/`maintained-test list ...` 之类契约报错；其余同 ONE TEST 预期。

- [ ] **Step 6: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```

- [ ] **Step 7: 记录 P1 行数变化（验收标准要求与估算 ~5,000 对照）**

```bash
P1_BASE=$(git log --format=%H --grep='^refactor: 删除未使用的 sequence 库与 virtual sequencer$' -n 1)~1
git diff --shortstat "$P1_BASE" HEAD -- virtio_net_vip/src virtio_net_vip/tests
```
把输出（形如 `N files changed, A insertions(+), D deletions(-)`）原样写进本任务提交信息正文。

- [ ] **Step 8: Commit**

```bash
git add README.md docs/virtio_net_vip_manual.md
git commit -m "docs: 同步 README 与手册到 P1 删除后的代码" \
  -m "修正文件/行数、split/packed 行数、依赖描述、TLM completion adapter 类名；删除 sequence 库、回调、failover、USO 分段、错误注入等已删除内容的描述；用户示例改为继承 virtio_e2e_test。" \
  -m "P1 src/tests 变化：$(git diff --shortstat "$P1_BASE" HEAD -- virtio_net_vip/src virtio_net_vip/tests)"
```

---

### Notes for integrator（P1）

**本阶段产出、后续阶段依赖的接口变化**
- `virtio_net_env`：删除 `v_seqr`；`bind_pcie()`/`bind_pcie_endpoints()` 签名不变，不再对 virtual sequencer 判空，也不再写环境级 `pcie_rc_seqr`。P2.4（`bind_all` 统一）不应再出现 virtual sequencer 相关的 preflight/提交步骤。
- `virtio_tso_engine` 新增 `needs_uso(pkt, mss)`、`get_udp_all_hdr_len(pkt)`、受保护的 `get_l2_l3_hdr_len(pkt)`；`virtio_offload_engine` 删除成员 `uso` 与 `prepare_tx_csum`，其余公共签名不变（P0/P2.1 的 `virtio_net_hdr_util` 头构造可继续调用 `offload.needs_gso/get_gso_type/get_mss_value/get_all_hdr_len/calc_csum_*`）。
- `rx_buf_mode_e` 只剩 `RX_MODE_MERGEABLE`（类型保留，`dataplane.configure()` 签名不变）。
- `virtio_rx_engine`：P1-3 删除 `custom_receive` 与 `custom_cb`，P1-8 删除 `receive_big/receive_small/receive_single_buf`。**P2.1 的删除清单应去掉 `custom_receive` 与 `receive_single_buf`**，只剩 buffer tracker、chain builder、`receive_mergeable`。
- `virtio_net_dataplane`：删除 `failover_mgr`、`set_dataplane_callback()`。`virtio_pf_manager`：删除 `failover_mgr`。`virtio_net_env_config`：删除 `failover_enable/primary_vf_id/standby_vf_id`。
- `virtio_monitor`：删除 `pkt_ap`、`chk_feature_usage` 及三个 `check_*`、三个 `broadcast_*`。
- `virtio_iommu_model`：删除 6 个 host0 包装和 2 个只服务它们的 `_for_host` 变体；P4.1 的迁移清单（`map/unmap/translate/map_fixed/write_from_device/begin_/capture_dirty_generation`）不受影响。
- `pcie_tl_dpu_reg_backend`：删除 `bind_host_root`（root 只按 `{host, segment}` 选择）；`bind_domain_root` 不变。
- `virtio_pcie_iova_host_mem_proxy`：删除 legacy 直通 GPA 模式。

**顺序依赖**
- P1 必须在 P0 全部合入之后执行；本计划对 P0 改动过的文件（tx/rx engine、atomic_ops、split/packed、dataplane、tests.f、README/手册）只使用锚点或整行匹配，不依赖 HEAD 行号。
- P1-1 必须第一个执行（seq 文件引用大量将被删除的符号，先删可让后续 grep 证据干净）；P1-9 必须最后执行（统计数字取自全部删除之后）。
- P1-3 与 P1-8 都改 `virtio_rx_engine.receive_packets`：P1-8 的 Edit 3 以 P1-3 的结果为 old 文本。
- 若 P0 已把 tx/rx engine 改成不再含 `custom_cb`/`RX_MODE_BIG/SMALL` 分支的薄适配，P1-3 Step 5/6 与 P1-8 Step 3 中对应的 Edit 跳过，grep 证据仍须为空。

**Spec deviations（汇总）**
1. P1.1：`virtio_dut_caps_test` 有 18 处 `v_seqr` 引用和一个专门的 null-virtual-sequencer 场景（含 fixture `null_vseqr_bind_*`）；场景整体删除，失败路径条件删除，正向断言改查 `function_instance.transport.bar.pcie_rc_seqr`。
2. P1.2：`queue_setup_error_e`/`QSETUP_ERR_*` 删除方法后成为孤儿，一并删除（`status_error_e/feature_error_e` 仍被 `virtio_transaction` 使用，保留）。
3. P1.4：额外删除只被打印的 `failover_enable/primary_vf_id/standby_vf_id` 与 `failover_state_e`。
4. P1.5：维护测试实际还使用 `csum.get_ethertype/get_l4_proto`、`tso.get_all_hdr_len`、`offload.needs_gso`，均保留；USO 合并不触及 offload 之外的调用方。
5. P1.6：额外删除 `chk_config_consistency` 与 `race_point_e`（删除后成为孤儿）。
6. P1.7：IOMMU 实际是 6 个 0 调用的 host0 包装（spec 写 5 个）；额外删除 monitor `pkt_ap/used_features/chk_feature_usage`、reg backend `root_by_host/completion_poll_limit`、IOVA proxy 直通模式状态（均为删除后的孤儿）。
7. P1.8：`virtio_net_env_config.sv:379` 设置 `RX_MODE_SMALL`（spec 称 0 引用），但该字段从未被读，删除该行；`receive_single_buf` 随 BIG/SMALL 一并删除。
8. P1.9：README/手册的用户示例继承 `virtio_base_test` 并使用 vseq/`v_seqr`，改为继承 `virtio_e2e_test`；README 的 `virtio_bar_mem_wr_seq_bridged` 同样不存在，一并修正。

**风险**
- dut_caps 失败路径删掉了 "环境级 RC sequencer 未提交" 这一条冗余断言；`binding_configuration_valid()`、`bound_protocol_vif_count()` 以及大多数场景里已有的逐 Function `transport.bar.pcie_rc_seqr != null` 断言仍覆盖不提交语义。没有在每个场景都换成 BAR seqr 检查，是因为 `invoke_function_pcie_bind` 场景会合法地单独提交 Function，可能让替换后的断言误报。
- 移除 monitor `pkt_ap` 与 env `v_seqr` 会改变 UVM 组件树（少一个 port/一个 sequencer 子组件）；仓库内无测试依赖组件计数，但仓库外用户若连了 `pkt_ap` 会编译失败（属预期的公共接口删除）。
- `scripts/test_manifest.sh` 的文档契约在每次 vcs.sh/回归启动时执行；P1-9 若误删了 placement/executor 示例或维护测试清单段落，所有测试会在启动阶段失败——P1-9 Step 5 专门先单跑一个测试检查这一点。
- 若 P0 实际改动了本计划假设 "P0 不碰" 的文件中被删除块的内部（例如 `virtio_net_env.sv` 的 bind 函数），`p1_del` 打印的首/尾行会与预期不符；此时停下，按锚点人工重新确认区间，不要强行删除。

---

## P2a：dataplane 引擎清理、virtqueue 公共逻辑上移、atomic ops 内部去重（P2.1 / P2.2 / P2.3）

本部分实现规格 `docs/superpowers/specs/2026-10-06-architecture-simplification-design.md` 中的 P2.1、P2.2、P2.3。
文中行号都是 HEAD `62ae3e9` 的行号。P0/P1 落地后行号会漂移，所以每处修改都同时给出符号锚点，执行时以锚点为准。

执行顺序为 P2-1 → P2-2a → P2-2b → P2-3a → P2-3b → P2-3c → P2-3d。P2-2 不依赖 P2-1；P2-3a/c/d 都要改
`virtio_atomic_ops.sv`，必须按顺序执行。

---

### Task P2-1: dataplane 引擎删除已被 atomic ops 取代的内部实现，私有 dataplane 只选私有 ops

前置状态（执行顺序为 P0 → P1 → P2）：
- P0-4/P0-5 已把引擎改为 ops 的薄适配：
  - `virtio_net_dataplane::bind_ops(virtio_atomic_ops)` 负责注入 `ops`。
  - TX 调用 `virtio_net_hdr_util::build_tx_hdr(...)` 和 `ops.tx_submit/tx_complete`。
  - RX 调用 `ops.rx_refill(queue_id, count, get_rx_buf_size())` 和 `ops.rx_receive_frames(queue_id, budget, frames)`。
- P1-3 已删除 `custom_cb`、`custom_receive`、`virtio_dataplane_callback`。
- P1-8 已删除 `RX_MODE_BIG/SMALL` 和 `receive_big/receive_small/receive_single_buf`，并让 `get_rx_buf_size()` 恒返回 `buf_size`。
- P1-4 已删除 `failover_mgr`。

本任务做两件事：
1. 删除 P0 “Notes for integrator” 列出的不可达符号（不含 P1 已删除的部分）。
2. 把私有 dataplane 简化为“只选择私有 ops”。

**Files:**
- Modify (整文件替换): `virtio_net_vip/src/dataplane/virtio_tx_engine.sv`
- Modify (整文件替换): `virtio_net_vip/src/dataplane/virtio_rx_engine.sv`
- Delete: `virtio_net_vip/src/dpu_priv/dpu_priv_dataplane.sv`（HEAD 82 行，包含 `dpu_priv_tx_engine` 和 `dpu_priv_rx_engine`）
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:111`（删除 `` `include "dpu_priv/dpu_priv_dataplane.sv" ``）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv:332-364`（新增 `rx_receive_frames` 覆写，`rx_receive` 改为基于它实现）
- Modify: `virtio_net_vip/src/dataplane/virtio_net_dataplane.sv`（`configure` 位于 HEAD :53-99，`cleanup_all` 位于 HEAD :109-120）
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:396-424`（P0-4 Step 8 之后的 dataplane 装配块）、`:650`（`on_flr`）
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv`（4 处 `dataplane.configure(`）
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`（1 处 `dataplane.configure(`，以及 HEAD :353 的 `dataplane.cleanup_all();`）
- Test: `virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、`virtio_fabric_resource_test`、`dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`、`virtio_real_driver_rx_test`

**Interfaces:**
- Consumes（P0 的产出，Step 1 会逐项核对）：
  - `virtual function void virtio_net_dataplane::bind_ops(virtio_atomic_ops ops)`
  - `static function void virtio_net_hdr_util::build_tx_hdr(input byte unsigned pkt_data[$], input bit [63:0] features, input virtio_offload_engine offload, output virtio_net_hdr_t hdr)`。P0 已在 `virtio_net_hdr.sv` 顶部用 `typedef class virtio_offload_engine;` 解决 include 顺序问题，本任务不改动这一处。
  - `virtual task virtio_atomic_ops::rx_refill(int unsigned queue_id, int unsigned num_bufs, int unsigned buf_size = 0)`
  - `virtual task virtio_atomic_ops::rx_receive_frames(int unsigned queue_id, int unsigned max_budget, ref virtio_rx_frame_t frames[$])`
  - `typedef struct { byte unsigned payload[$]; virtio_net_hdr_t net_hdr; uvm_object token; int unsigned num_buffers; } virtio_rx_frame_t;`
- Produces:
  - `virtio_tx_engine`：
    - 字段：`ops, offload, bdf, host_id, negotiated_features`，以及统计 `total_tx_packets/bytes/errors/sg_count`。
    - 方法：`submit_packet`、`complete_tx`（P0 原样）、`extract_pkt_data`、`print_stats`。
  - `virtio_rx_engine`：
    - 字段：`ops, offload, bdf, host_id, negotiated_features, buf_size, refill_threshold`，以及统计 `total_rx_packets/bytes/merged`。
    - 方法：`get_rx_buf_size`、`refill_buffers`、`receive_packets`（P0 原样）、`build_received_packet`、`print_stats`。
    - 保留类 `virtio_rx_pkt_wrapper`。
  - `virtio_net_dataplane::configure(bit [63:0] features, int unsigned mtu_val, int unsigned mss_val, rx_buf_mode_e rx_mode, int unsigned rx_buf_sz, int unsigned rx_refill_thresh, bit [15:0] device_bdf, int unsigned device_host_id = 0)`：删除 `vq_mgr/hmem/iommu_mdl` 三个形参。
  - `virtual task dpu_priv_atomic_ops::rx_receive_frames(...)`：按私有 CQ 语义返回帧，payload 为原始帧，`net_hdr` 全零，`num_buffers=1`。
  - 删除 `dpu_priv_tx_engine`、`dpu_priv_rx_engine`、`virtio_net_dataplane::cleanup_all`。

**删除清单**

与 P0 “交给 P2-1 删除的符号” 一致，已扣除 P1-3/P1-8 删除的 `custom_receive/receive_big/receive_small/receive_single_buf`。

- `virtio_tx_engine.sv`：
  - `virtio_buf_tracker` 类（HEAD :4-35）
  - `tx_buf_map`（:84-87）
  - `submit_single`（:149-217；P1-3 已删除其中的 `custom_cb` 分支）
  - `standard_tx_build_chain`（:219-271）
  - `cleanup_tx_buffers`（:353-377）
  - 字段 `vq_mgr/mem/iommu/mtu`
  - `leak_check`（:438-450）
  - `print_stats` 改写为不读 `tx_buf_map`
- `virtio_rx_engine.sv`：
  - `rx_buf_gpa_to_iova/rx_buf_gpa_to_size`（:85-87）
  - `receive_mergeable`（:249-389）
  - `cleanup_rx_buffer`（:584-601）
  - 字段 `vq_mgr/mem/iommu`
  - `leak_check`（:616-636）
  - `print_stats` 改写
  - 另删两个只写不读的字段：`total_rx_errors`（只在已删除的 receive 路径中递增）和 `buf_mode`（P1-8 之后只被 `configure` 赋值）
- `virtio_net_dataplane.sv`：`cleanup_all`（它只调用上述两个 `leak_check`），以及它的两个调用点 `virtio_function_instance.sv:650`、`virtio_net_packet_multi_queue_test.sv:353`。
- `dpu_priv_dataplane.sv` 整个文件，原因见 Spec deviation 1。

**保留**（按 P0 的要求）：`extract_pkt_data`、`virtio_byte_queue_t`、`build_received_packet`、`virtio_rx_pkt_wrapper`（`virtio_scoreboard.sv:474` 使用）、`get_rx_buf_size`、统计字段，以及引擎的 `host_id/bdf`。

`virtio_fabric_resource_test.sv:969-972` 直接断言 `dataplane.{tx,rx}_engine.host_id`，所以该测试一行不改。没有把断言改为经 `ops.transport` 校验，原因如下：
- `bind_ops` 在 `commit_validated_pcie_components` 中调用，而 `host_id/bdf` 在 `apply_function_configuration` 中赋值，两者不是同一入口。
- 仅靠静态阅读无法确认 fabric 测试执行断言时 ops 已经绑定。改走 `ops.transport` 可能因空句柄触发 fatal；若为此加 null 判断，断言又会变弱。

**Spec deviation:**
1. 规格要求“`dpu_priv_dataplane` 的覆盖简化为仅选择私有 ops”。本任务更进一步，删除整个文件：私有 Function 直接使用基类引擎，只需注入私有 ops 并设置两项配置。理由如下。
   - TX：
     - 基类 `submit_packet` 调用 `build_tx_hdr`，要求 `offload` 非空。Function 从不调用 `dataplane.configure()`，所以在装配块中补上 `tx_engine.offload = dataplane.offload`。
     - 引擎和 offload 的 `negotiated_features` 都为 0，因此 CSUM 与 HASH 分支都不进入；`needs_tso/needs_uso` 先检查特性位，返回 0。结果是全零 header，正好满足私有 `tx_submit` 的 offload 拒绝检查（要求 `flags/gso_type` 为 0）。
     - `tx_complete` 已由私有 ops 覆写。
     - 顺带修复：标准 Function 自带引擎原先存在 `offload == null` 的空句柄缺口，这次也一并补上。
   - RX：
     - 基类 `refill_buffers` 调用 `ops.rx_refill(qid, count, get_rx_buf_size())`。私有覆写忽略 `buf_size`，改用私有配置 `rx_size`。
     - P1-8 之后 `get_rx_buf_size()` 恒返回 `buf_size`。装配时把它设为 `private_cfg.rx_buf_size`，`dpu_priv_driver_flow_test` 断言的 2048 仍然成立。
     - `receive_packets` 调用 `ops.rx_receive_frames`，所以私有 ops 必须覆写它（Step 2），否则会走标准 header 解析。
     - `negotiated_features=0`，因此不做 GUEST_CSUM 校验。
     - 原私有引擎不自动补充 buffer，这里用 `refill_threshold = 0` 保持该行为。
   - 统计口径变化：
     - 私有 TX 成功时，`total_tx_sg_count` 从 +1 变为 +2。
     - ops 拒绝时，只有在 P0 基类的 `submit_packet` 入口检查失败（如 queue 不存在）才计入错误，ops 内部的拒绝不计；原私有引擎会计 +1。
     - 私有 RX 收到无法解析的帧时，现在由基类返回 `virtio_rx_pkt_wrapper`；原私有引擎会报 `DPU_PRIV_OPS` 错误并丢弃该帧。直接调用 `private_ops.rx_receive` 时仍保持原行为。
     - 已 grep 确认维护测试中没有读取私有引擎统计、也没有构造畸形私有帧的地方（`examples/` 中不出现 `total_`）。
2. `configure` 删除了 `vq_mgr/hmem/iommu_mdl` 三个形参。删掉对应字段后这三个形参已无用，按规格“不保留空壳”的原则删除，并迁移全部 5 个测试调用点（见 Step 6）。

- [ ] **Step 1: 核对 P0/P1 已落地（只读）**

```bash
grep -n "function void bind_ops" virtio_net_vip/src/dataplane/virtio_net_dataplane.sv
grep -n "static function void build_tx_hdr" virtio_net_vip/src/types/virtio_net_hdr.sv
grep -n "task rx_receive_frames\|int unsigned     buf_size = 0" virtio_net_vip/src/agent/virtio_atomic_ops.sv
grep -n "ops.rx_receive_frames\|ops.rx_refill(queue_id, count, get_rx_buf_size())" virtio_net_vip/src/dataplane/virtio_rx_engine.sv
grep -rnE "custom_cb|custom_receive|receive_big|receive_small|receive_single_buf|RX_MODE_BIG|RX_MODE_SMALL|failover_mgr" virtio_net_vip/src/dataplane
```

预期：前四条每条至少输出一行（第三条应有两行），第五条无输出。如果结果不符，停止本任务，回到 P0/P1 处理。

- [ ] **Step 2: 私有 ops 覆写 `rx_receive_frames`（删除私有 RX 引擎的前提）**

位置：`dpu_priv_atomic_ops.sv` HEAD :332-364，从锚点 `// 按 RX CQ pkt_len 读取整个原始帧并解析 packet_item` 起，到 `rx_receive` 的 `endtask` 止。

old：

```systemverilog
    // 按 RX CQ pkt_len 读取整个原始帧并解析 packet_item；单 buffer 所有权在复制后
    // 回收。回调拒绝非法/多 buffer CQ 时保持索引与 DMA 记录不变。
    virtual task rx_receive(int unsigned queue_id,
                             ref uvm_object received_pkts[$], int unsigned max_budget);
        virtqueue_base vq;
        uvm_object token;
        int unsigned len;
        if (!contexts.exists(queue_id) || contexts[queue_id].tx_mode) return;
        vq = vq_mgr.get_queue(queue_id);
        for (int unsigned n = 0; n < max_budget; n++) begin
            normal_dma_record_t rec;
            byte data[];
            byte unsigned raw[$];
            packet_item pkt;
            if (!vq.poll_used(token, len)) break;
            if (!rx_dma_map.exists(queue_id) || rx_dma_map[queue_id].size() == 0) begin
                `uvm_fatal("DPU_PRIV_OPS", "RX 完成缺少 DMA 所有权记录")
                return;
            end
            rec = rx_dma_map[queue_id].pop_front();
            mem.read_mem(rec.gpa, len, data);
            foreach (data[i]) raw.push_back(data[i]);
            retire_normal_dma_record(rec);
            if (virtio_net_packet_adapter::unpack(raw, pkt))
                received_pkts.push_back(pkt);
            else
                `uvm_error("DPU_PRIV_OPS", "RX 原始帧无法解析")
        end
        if (rx_dma_map.exists(queue_id) && rx_dma_map[queue_id].size() == 0)
            rx_dma_map.delete(queue_id);
    endtask
```

new：

```systemverilog
    // 按 RX CQ pkt_len 读取整个原始帧；私有 ring 不带 Virtio-net header，帧本身即
    // payload，net_hdr 置零、num_buffers=1。单 buffer 所有权在复制后回收。回调拒绝
    // 非法/多 buffer CQ 时保持索引与 DMA 记录不变。dataplane 引擎经此入口收包。
    virtual task rx_receive_frames(int unsigned queue_id, int unsigned max_budget,
                                    ref virtio_rx_frame_t frames[$]);
        virtqueue_base vq;
        uvm_object token;
        int unsigned len;
        if (!contexts.exists(queue_id) || contexts[queue_id].tx_mode) return;
        vq = vq_mgr.get_queue(queue_id);
        for (int unsigned n = 0; n < max_budget; n++) begin
            normal_dma_record_t rec;
            byte data[];
            virtio_rx_frame_t frame;
            if (!vq.poll_used(token, len)) break;
            if (!rx_dma_map.exists(queue_id) || rx_dma_map[queue_id].size() == 0) begin
                `uvm_fatal("DPU_PRIV_OPS", "RX 完成缺少 DMA 所有权记录")
                return;
            end
            rec = rx_dma_map[queue_id].pop_front();
            mem.read_mem(rec.gpa, len, data);
            foreach (data[i]) frame.payload.push_back(data[i]);
            retire_normal_dma_record(rec);
            frame.net_hdr = '{default:0};
            frame.token = token;
            frame.num_buffers = 1;
            frames.push_back(frame);
        end
        if (rx_dma_map.exists(queue_id) && rx_dma_map[queue_id].size() == 0)
            rx_dma_map.delete(queue_id);
    endtask

    // 原始帧解析为 packet_item；私有 ring 只承载以太网帧，无法解析时报错丢弃。
    virtual task rx_receive(int unsigned queue_id,
                             ref uvm_object received_pkts[$], int unsigned max_budget);
        virtio_rx_frame_t frames[$];
        rx_receive_frames(queue_id, max_budget, frames);
        foreach (frames[i]) begin
            packet_item pkt;
            if (virtio_net_packet_adapter::unpack(frames[i].payload, pkt))
                received_pkts.push_back(pkt);
            else
                `uvm_error("DPU_PRIV_OPS", "RX 原始帧无法解析")
        end
    endtask
```

等价性说明：
- 轮询、所有权检查、读取、退休、清空键这几步的顺序与原 `rx_receive` 完全一致，唯一变化是“解析并推入”推迟到整批读完之后。
- `poll_used/read_mem/retire` 都不消耗仿真时间，所以批处理不改变可观察结果。
- `frame` 声明在循环体内（automatic），每轮都会重新初始化。

- [ ] **Step 3: 整文件替换 `virtio_net_vip/src/dataplane/virtio_tx_engine.sv`**

`submit_packet`/`complete_tx` 的函数体是 P0-4 Step 7 的原文，未作改动。最终内容：

```systemverilog
`ifndef VIRTIO_TX_ENGINE_SV
`define VIRTIO_TX_ENGINE_SV

// 原始字节队列类型；scoreboard 的 get_pkt_data 也使用它。
typedef byte unsigned virtio_byte_queue_t[$];

// ============================================================================
// virtio_tx_engine
//
// Function.dataplane 的 TX 薄适配层：
//   1. 从 packet 取线速字节，经 virtio_net_hdr_util::build_tx_hdr 推导 header；
//   2. DMA、描述符发布与 PCIe notify 委托 virtio_atomic_ops.tx_submit
//      （经 virtio_net_dataplane.bind_ops 绑定）；
//   3. 完成与 DMA 回收委托 virtio_atomic_ops.tx_complete。
// 引擎不持有 DMA 缓冲，只维护统计。私有 Function 注入私有 ops，同一引擎类即可。
// host_id/bdf 记录 Function 的 DMA 身份，供 fabric 测试断言，收发不读取。
// ============================================================================

class virtio_tx_engine extends uvm_object;
    `uvm_object_utils(virtio_tx_engine)

    // ===== External references (set by parent before use) =====
    // ops 是规范 TX 路径（借用）：DMA、描述符发布、通知与完成回收都由它执行。
    virtio_atomic_ops           ops;
    virtio_offload_engine       offload;
    bit [15:0]                  bdf;
    int unsigned                host_id;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;

    // ===== Statistics =====
    longint unsigned total_tx_packets  = 0;
    longint unsigned total_tx_bytes    = 0;
    longint unsigned total_tx_errors   = 0;
    longint unsigned total_tx_sg_count = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_tx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // ==================================================================
    // submit_packet
    //
    // Parameters:
    //   queue_id     -- Target TX virtqueue ID
    //   pkt          -- packet_item handle (as uvm_object)
    //   use_indirect -- Use indirect descriptors if supported
    //   desc_id      -- [output] Descriptor ID returned by add_buf
    // ==================================================================
    virtual task submit_packet(
        int unsigned     queue_id,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        byte unsigned    pkt_data[$];
        virtio_net_hdr_t hdr;

        desc_id = '1;
        if (use_indirect &&
            !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
            `uvm_error("TX_ENG", $sformatf(
                "submit_packet: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                queue_id))
            return;
        end
        if ((ops == null) || (ops.vq_mgr == null)) begin
            `uvm_error("TX_ENG", $sformatf(
                "submit_packet: queue %0d has no bound atomic ops", queue_id))
            total_tx_errors++;
            return;
        end

        // ---- 1. Extract raw packet bytes ----
        pkt_data = extract_pkt_data(pkt);
        if (pkt_data.size() == 0) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_packet: empty packet data on queue %0d", queue_id))
            total_tx_errors++;
            return;
        end
        if (ops.vq_mgr.get_queue(queue_id) == null) begin
            `uvm_error("TX_ENG",
                $sformatf("submit_packet: queue %0d not found", queue_id))
            total_tx_errors++;
            return;
        end

        // ---- 2. Build virtio_net_hdr (device performs GSO segmentation) ----
        virtio_net_hdr_util::build_tx_hdr(pkt_data, negotiated_features,
                                          offload, hdr);

        // ---- 3. ops 拥有 DMA、描述符发布与真实 notify；拒绝时已自行回滚 ----
        ops.tx_submit(queue_id, hdr, pkt, use_indirect, desc_id);
        if (desc_id == '1)
            return;

        total_tx_packets++;
        total_tx_bytes    += pkt_data.size();
        total_tx_sg_count += 2;   // [net_hdr] + [payload]

        `uvm_info("TX_ENG",
            $sformatf("submit_packet: queue=%0d desc_id=%0d pkt_size=%0d",
                      queue_id, desc_id, pkt_data.size()),
            UVM_HIGH)
    endtask : submit_packet

    // ==================================================================
    // complete_tx -- ops 按提交顺序回收每包的 header/payload DMA 所有权
    // ==================================================================
    virtual task complete_tx(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    completed[$]
    );
        int unsigned before_count;

        if ((ops == null) || (ops.vq_mgr == null) ||
            (ops.vq_mgr.get_queue(queue_id) == null)) begin
            `uvm_error("TX_ENG",
                $sformatf("complete_tx: queue %0d not found", queue_id))
            return;
        end

        // ops 按提交顺序回收每包的 header/payload DMA 所有权。
        before_count = completed.size();
        ops.tx_complete(queue_id, completed, budget);

        `uvm_info("TX_ENG",
            $sformatf("complete_tx: queue=%0d completed=%0d",
                      queue_id, completed.size() - before_count),
            UVM_HIGH)
    endtask : complete_tx

    // ==================================================================
    // extract_pkt_data (protected)
    //
    // net_packet::packet_item goes through virtio_net_packet_adapter so
    // the UVM length prefix is never sent; other objects keep the legacy
    // do_pack() bitstream conversion.
    // ==================================================================
    protected virtual function virtio_byte_queue_t extract_pkt_data(uvm_object pkt);
        byte unsigned data[$];
        uvm_packer packer;
        int unsigned pack_size;

        if (pkt == null) begin
            `uvm_error("TX_ENG", "extract_pkt_data: null packet handle")
            return data;
        end

        // net_packet::packet_item.do_pack() is a UVM object serialization
        // format ([size][raw bytes]), not a wire packet.  Use the explicit
        // adapter first to send only packet.pkt.raw_data.
        if (virtio_net_packet_adapter::pack(pkt, data))
            return data;

        packer = new();
        pkt.do_pack(packer);
        pack_size = packer.get_packed_size();

        if (pack_size > 0) begin
            bit bitstream[];
            byte unsigned byte_val;
            int unsigned num_bytes;

            packer.get_bits(bitstream);
            num_bytes = bitstream.size() / 8;
            for (int i = 0; i < num_bytes; i++) begin
                byte_val = 0;
                for (int b = 0; b < 8; b++)
                    byte_val = {byte_val[6:0], bitstream[i*8 + b]};
                data.push_back(byte_val);
            end
        end

        return data;
    endfunction : extract_pkt_data

    // ==================================================================
    // print_stats -- Log TX engine statistics
    // ==================================================================
    function void print_stats();
        `uvm_info("TX_ENG_STATS",
            $sformatf("TX Stats: packets=%0d bytes=%0d errors=%0d sg_chains=%0d",
                      total_tx_packets, total_tx_bytes, total_tx_errors,
                      total_tx_sg_count),
            UVM_LOW)
    endfunction : print_stats

endclass : virtio_tx_engine

`endif // VIRTIO_TX_ENGINE_SV
```

- [ ] **Step 4: 整文件替换 `virtio_net_vip/src/dataplane/virtio_rx_engine.sv`**

来源：`refill_buffers`/`receive_packets` 取 P0-5 Step 6 原文；`build_received_packet` 和 `virtio_rx_pkt_wrapper` 取 HEAD 原文；`get_rx_buf_size` 取 P1-8 之后的版本。最终内容：

```systemverilog
// 目录层次：src/dataplane；Function.dataplane 的 RX 薄适配层。
// buffer 投递、取包、合包、DMA 所有权与 notify 全部由注入的 virtio_atomic_ops
// （rx_refill / rx_receive_frames）执行；引擎只做可选的 RX checksum 校验、把帧
// 转为 packet_item（或 wrapper）、维护统计与自动补充门限。私有 Function 注入
// 私有 ops，并以 refill_threshold=0 关闭自动补充。host_id/bdf 记录 DMA 身份，
// 供 fabric 测试断言，收发不读取。
`ifndef VIRTIO_RX_ENGINE_SV
`define VIRTIO_RX_ENGINE_SV

// ============================================================================
// virtio_rx_pkt_wrapper
//
// Lightweight fallback object that carries a received packet's payload and
// parsed virtio_net_hdr back to the caller when the protocol parser rejects
// malformed data. Valid packets are returned as net_packet::packet_item.
// ============================================================================

// 协议解析失败时仍保留原始字节和 Virtio header，供错误测试检查；由接收者持有。
class virtio_rx_pkt_wrapper extends uvm_object;
    `uvm_object_utils(virtio_rx_pkt_wrapper)

    byte unsigned    payload[$];
    virtio_net_hdr_t net_hdr;
    int unsigned     pkt_len;

    // 构造函数：空包装对象（长度 0）；payload/net_hdr 由 RX 引擎回填。
    function new(string name = "virtio_rx_pkt_wrapper");
        super.new(name);
        pkt_len = 0;
    endfunction

endclass : virtio_rx_pkt_wrapper

// 只保存配置与统计；DMA 资源由 ops 所有，停机前由上层确认设备停止 DMA。
class virtio_rx_engine extends uvm_object;
    `uvm_object_utils(virtio_rx_engine)

    // ===== External references (set by parent before use) =====
    // ops 是规范 RX 路径（借用）：buffer 分配、通知、取包与 DMA 回收由它执行。
    virtio_atomic_ops           ops;
    virtio_offload_engine       offload;
    bit [15:0]                  bdf;
    int unsigned                host_id;

    // ===== Configuration =====
    bit [63:0]       negotiated_features;
    int unsigned     buf_size         = 1526;    // 描述符可写容量
    int unsigned     refill_threshold = 16;      // free < 此值时自动补充；0 关闭

    // ===== Statistics =====
    longint unsigned total_rx_packets = 0;
    longint unsigned total_rx_bytes   = 0;
    longint unsigned total_rx_merged  = 0;       // MRG_RXBUF merge events

    // 初始化未协商的引擎；构造时不分配 buffer，ops 须先绑定再投递。
    function new(string name = "virtio_rx_engine");
        super.new(name);
        negotiated_features = 64'h0;
    endfunction

    // 中文说明：优先把真实线速 payload 解析为 net_packet packet_item；
    // 对故意注入的 malformed/非 Ethernet 数据保留 wrapper，便于错误场景
    // 继续观察原始字节和 virtio header。
    protected function uvm_object build_received_packet(
        input byte unsigned payload[$],
        input virtio_net_hdr_t net_hdr
    );
        packet_item packet_obj;
        virtio_rx_pkt_wrapper fallback_obj;

        if (virtio_net_packet_adapter::unpack(payload, packet_obj))
            return packet_obj;

        fallback_obj = virtio_rx_pkt_wrapper::type_id::create("rx_pkt");
        fallback_obj.payload   = payload;
        fallback_obj.net_hdr   = net_hdr;
        fallback_obj.pkt_len   = payload.size();
        return fallback_obj;
    endfunction

    // 查询 mergeable buffer 容量（私有 Function 装配为不含 header 的私有容量）。
    virtual function int unsigned get_rx_buf_size();
        return buf_size;
    endfunction : get_rx_buf_size

    // 向 queue_id 最多补充 count 个可写 buffer（容量取 get_rx_buf_size()），受空闲
    // 描述符限制；分配、映射、所有权登记与真实 notify 由 ops 执行。队列不存在则报错。
    virtual task refill_buffers(
        int unsigned queue_id,
        int unsigned count
    );
        if ((ops == null) || (ops.vq_mgr == null) ||
            (ops.vq_mgr.get_queue(queue_id) == null)) begin
            `uvm_error("RX_ENG",
                $sformatf("refill_buffers: queue %0d not found", queue_id))
            return;
        end
        ops.rx_refill(queue_id, count, get_rx_buf_size());
        `uvm_info("RX_ENG",
            $sformatf("refill_buffers: queue=%0d requested=%0d buf_size=%0d",
                      queue_id, count, get_rx_buf_size()),
            UVM_HIGH)
    endtask : refill_buffers

    // 经 ops 取得至多 budget 个帧（ops 完成合包与 DMA 回收），可选校验 RX checksum，
    // 合法帧返回 packet_item、非法帧返回 wrapper；之后按 free-count 门限补充。
    virtual task receive_packets(
        int unsigned      queue_id,
        int unsigned      budget,
        ref uvm_object    received[$]
    );
        virtqueue_base    vq;
        virtio_rx_frame_t frames[$];

        if ((ops == null) || (ops.vq_mgr == null)) begin
            `uvm_error("RX_ENG", $sformatf(
                "receive_packets: queue %0d has no bound atomic ops", queue_id))
            return;
        end
        vq = ops.vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("RX_ENG",
                $sformatf("receive_packets: queue %0d not found", queue_id))
            return;
        end

        ops.rx_receive_frames(queue_id, budget, frames);
        foreach (frames[i]) begin
            if (negotiated_features[VIRTIO_NET_F_GUEST_CSUM] &&
                !offload.verify_rx_csum(frames[i].net_hdr, frames[i].payload))
                `uvm_warning("RX_ENG", $sformatf(
                    "receive_packets: RX checksum verification failed, pkt_size=%0d",
                    frames[i].payload.size()))
            if (frames[i].num_buffers > 1)
                total_rx_merged++;
            received.push_back(build_received_packet(frames[i].payload,
                                                     frames[i].net_hdr));
            total_rx_packets++;
            total_rx_bytes += frames[i].payload.size();
        end

        `uvm_info("RX_ENG",
            $sformatf("receive_packets: queue=%0d received=%0d", queue_id, frames.size()),
            UVM_HIGH)

        // Auto-refill if free count drops below threshold
        if (vq.get_free_count() < refill_threshold)
            refill_buffers(queue_id, refill_threshold);
    endtask : receive_packets

    // 输出收包、字节与合包计数，不改变运行态。
    function void print_stats();
        `uvm_info("RX_ENG_STATS",
            $sformatf("RX Stats: packets=%0d bytes=%0d merged=%0d",
                      total_rx_packets, total_rx_bytes, total_rx_merged),
            UVM_LOW)
    endfunction : print_stats

endclass : virtio_rx_engine

`endif // VIRTIO_RX_ENGINE_SV
```

- [ ] **Step 5: 删除私有 dataplane；修改 `virtio_net_dataplane.sv` 与 Function 装配**

5a. 删除 `virtio_net_vip/src/dpu_priv/dpu_priv_dataplane.sv`，并去掉 `virtio_net_pkg.sv` 中对应的 include 行：

```bash
grep -n 'dpu_priv/dpu_priv_dataplane.sv' virtio_net_vip/src/virtio_net_pkg.sv   # 预期 1 行（HEAD :111）
sed -i '\|^  `include "dpu_priv/dpu_priv_dataplane.sv"$|d' virtio_net_vip/src/virtio_net_pkg.sv
```

5b. 修改 `virtio_net_dataplane.sv` 中的 `configure`（锚点 `virtual function void configure(`）。

P0+P1 之后的形参表（old）：

```systemverilog
    virtual function void configure(
        bit [63:0]          features,
        int unsigned        mtu_val,
        int unsigned        mss_val,
        rx_buf_mode_e       rx_mode,
        int unsigned        rx_buf_sz,
        int unsigned        rx_refill_thresh,
        virtqueue_manager   vq_mgr,
        host_mem_manager    hmem,
        virtio_iommu_model  iommu_mdl,
        bit [15:0]          device_bdf,
        int unsigned        device_host_id = 0
    );
```

new：

```systemverilog
    virtual function void configure(
        bit [63:0]          features,
        int unsigned        mtu_val,
        int unsigned        mss_val,
        rx_buf_mode_e       rx_mode,
        int unsigned        rx_buf_sz,
        int unsigned        rx_refill_thresh,
        bit [15:0]          device_bdf,
        int unsigned        device_host_id = 0
    );
```

函数体中 TX/RX 段（old）：

```systemverilog
        // Configure TX engine
        tx_engine.vq_mgr   = vq_mgr;
        tx_engine.mem      = hmem;
        tx_engine.iommu    = iommu_mdl;
        tx_engine.offload  = offload;
        tx_engine.bdf      = device_bdf;
        tx_engine.host_id  = device_host_id;
        tx_engine.negotiated_features = features;
        tx_engine.mtu      = mtu_val;

        // Configure RX engine
        rx_engine.vq_mgr   = vq_mgr;
        rx_engine.mem      = hmem;
        rx_engine.iommu    = iommu_mdl;
        rx_engine.offload  = offload;
        rx_engine.bdf      = device_bdf;
        rx_engine.host_id  = device_host_id;
        rx_engine.negotiated_features = features;
        rx_engine.buf_mode = rx_mode;
        rx_engine.buf_size = rx_buf_sz;
        rx_engine.refill_threshold = rx_refill_thresh;
```

new：

```systemverilog
        // Configure TX engine (DMA/queues are reached through bind_ops)
        tx_engine.offload  = offload;
        tx_engine.bdf      = device_bdf;
        tx_engine.host_id  = device_host_id;
        tx_engine.negotiated_features = features;

        // Configure RX engine
        rx_engine.offload  = offload;
        rx_engine.bdf      = device_bdf;
        rx_engine.host_id  = device_host_id;
        rx_engine.negotiated_features = features;
        rx_engine.buf_size = rx_buf_sz;
        rx_engine.refill_threshold = rx_refill_thresh;
```

`rx_mode` 形参保留：P1-8 保留了这个签名，它仍会赋给 dataplane 自身的 `rx_buf_mode`，用于打印。

同一文件还需两处修改：
- 删除 `cleanup_all`：从 `// cleanup_all -- Called during reset / FLR / shutdown` 注释块的 `// ====` 行起，到它的 `endfunction` 为止。
- 文件头 `Depends on:` 中的 `//   - virtqueue_manager, host_mem_manager, virtio_iommu_model` 改为 `//   - virtio_atomic_ops (bound through bind_ops)`。

5c. 修改 `virtio_function_instance.sv` 中 `commit_validated_pcie_components` 的 dataplane 装配块（锚点 `// Keep the optional standalone dataplane wrapper`）。

P0-4 Step 8 之后的 old：

```systemverilog
        // Keep the optional standalone dataplane wrapper in the same
        // host-qualified DMA domain as the function-owned queue/atomic path.
        if (dataplane != null) begin
            // 私有 Function 的引擎也复用同一个 ops，保证 engine 与 sequence/FSM
            // 不会各自产生一套 DMA tracker 或混入标准 Virtio-net header。
            if (private_cfg != null) begin
                dpu_priv_tx_engine tx_adapter;
                dpu_priv_rx_engine rx_adapter;
                tx_adapter = new({function_name, "_private_tx"});
                rx_adapter = new({function_name, "_private_rx"});
                tx_adapter.private_ops = private_ops;
                rx_adapter.private_ops = private_ops;
                rx_adapter.buf_size = private_cfg.rx_buf_size;
                dataplane.tx_engine = tx_adapter;
                dataplane.rx_engine = rx_adapter;
            end
            dataplane.tx_engine.vq_mgr = vq_mgr_ref;
            dataplane.tx_engine.mem = hmem;
            dataplane.tx_engine.iommu = iommu_mdl;
            dataplane.tx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.tx_engine.bdf = transport_ref.bdf;
            dataplane.rx_engine.vq_mgr = vq_mgr_ref;
            dataplane.rx_engine.mem = hmem;
            dataplane.rx_engine.iommu = iommu_mdl;
            dataplane.rx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.rx_engine.bdf = transport_ref.bdf;
            // 标准引擎经同一个 ops 收发，与 FSM/sequence 共用 DMA 所有权和通知路径。
            dataplane.bind_ops(ops);
        end
```

new：

```systemverilog
        // Keep the optional standalone dataplane wrapper in the same
        // host-qualified DMA domain as the function-owned queue/atomic path.
        // 标准与私有 Function 使用同一引擎类，只是注入的 ops 不同；收发、DMA
        // 所有权与通知都在 ops 内，engine 与 FSM/sequence 共用同一张所有权表。
        if (dataplane != null) begin
            if (private_cfg != null) begin
                // 私有 buffer 容量不含 Virtio header；补充由调用方/FSM 控制。
                dataplane.rx_engine.buf_size = private_cfg.rx_buf_size;
                dataplane.rx_engine.refill_threshold = 0;
            end
            // Function 不调用 configure()：借用 dataplane 自带的 offload，特性为 0 时
            // build_tx_hdr 产出全零 header（私有 ops 要求如此）。
            dataplane.tx_engine.offload = dataplane.offload;
            dataplane.rx_engine.offload = dataplane.offload;
            dataplane.tx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.tx_engine.bdf = transport_ref.bdf;
            dataplane.rx_engine.host_id =
                transport_ref.iommu_host_id();
            dataplane.rx_engine.bdf = transport_ref.bdf;
            dataplane.bind_ops(ops);
        end
```

说明：
- 局部变量 `private_ops` 仍被同一函数开头的 `configure_private` 使用，保留。
- `apply_function_configuration` 中对 `dataplane.{tx,rx}_engine.host_id/bdf` 的赋值（HEAD :707-712）保留不动。

5d. `on_flr` 中删除 `        dataplane.cleanup_all();` 这一行（HEAD :650）。

- [ ] **Step 6: 迁移测试调用点**

6a. `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv` 中：
- 删除 `        dataplane.cleanup_all();`（HEAD :353）。
- 修改 `configure` 调用。

old：

```systemverilog
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE,
                            2048, 0, vq_mgr, mem, iommu, DEVICE_BDF, 0);
```

new：

```systemverilog
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE,
                            2048, 0, DEVICE_BDF, 0);
```

6b. `virtio_net_vip/tests/virtio_indirect_desc_test.sv` 中共 4 处调用（以下为 P0-4 之后的文本）。

`test_dataplane_tx_indirect_feature_gate` 中有 2 处，形如：

```systemverilog
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            vq_mgr, mem, iommu, 16'h0703);
```

两处都改为：

```systemverilog
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            16'h0703);
```

另外两处：
- `test_dataplane_tx_queue_full_cleanup`：`vq_mgr, mem, iommu, 16'h0705);` 改为 `16'h0705);`。
- `test_dataplane_engine_notifies_device`（P0-4 新增）：`vq_mgr, mem, iommu, 16'h0706);` 改为 `16'h0706);`。

6c. 确认没有漏改：

```bash
grep -rn "vq_mgr, mem, iommu, " virtio_net_vip/tests examples
```

预期无输出。

- [ ] **Step 7: grep 证明无残留引用**

```bash
grep -rnwE "virtio_buf_tracker|standard_tx_build_chain|submit_single|cleanup_tx_buffers|tx_buf_map|receive_mergeable|cleanup_rx_buffer|rx_buf_gpa_to_iova|rx_buf_gpa_to_size|total_rx_errors|dpu_priv_tx_engine|dpu_priv_rx_engine|cleanup_all|tx_adapter|rx_adapter" virtio_net_vip examples
grep -rnE "(tx|rx)_engine\.(vq_mgr|mem|iommu|mtu|buf_mode|leak_check|private_ops)\b" virtio_net_vip examples
grep -nE "^\s+(virtqueue_manager|host_mem_manager|virtio_iommu_model)\s" virtio_net_vip/src/dataplane/virtio_tx_engine.sv virtio_net_vip/src/dataplane/virtio_rx_engine.sv
test ! -e virtio_net_vip/src/dpu_priv/dpu_priv_dataplane.sv && echo PRIV_DATAPLANE_GONE
```

预期：前三条无输出，第四条输出 `PRIV_DATAPLANE_GONE`。

- [ ] **Step 8: SYNC 并运行受影响测试**

SYNC：

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
```

然后用 ONE TEST 命令依次运行以下测试：`virtio_indirect_desc_test`、`virtio_net_packet_multi_queue_test`、`virtio_fabric_resource_test`、`dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`、`virtio_real_driver_rx_test`。

预期：每个测试的汇总都只有 `UVM_WARNING :    0`、`UVM_ERROR :    0`、`UVM_FATAL :    0` 三行。

- [ ] **Step 9: 全量回归**

运行 REGRESSION 命令。预期最后一行为 `STRICT_REGRESSION PASS tests=40`（P0-2 之后 manifest 共 40 项）。

- [ ] **Step 10: 提交**

先删除私有 dataplane 文件，再暂存其余改动：

```
git rm -q virtio_net_vip/src/dpu_priv/dpu_priv_dataplane.sv
git add virtio_net_vip/src/dataplane/virtio_tx_engine.sv virtio_net_vip/src/dataplane/virtio_rx_engine.sv virtio_net_vip/src/dataplane/virtio_net_dataplane.sv virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv virtio_net_vip/tests/virtio_indirect_desc_test.sv
```

提交信息：`refactor: dataplane 引擎删除被 atomic ops 取代的 tracker/chain/receive 实现，私有 Function 直接复用基类引擎`

---

### Task P2-2a: 把 virtqueue 的 DMA 辅助、错误注入与 kick 上移到 virtqueue_base

**Files:**
- Modify: `virtio_net_vip/src/virtqueue/virtqueue_base.sv`：
  - `:45-48` 新增 `log_tag`
  - `:156-168` 把 `kick` 由纯虚改为实现
  - `:201-208` 把 `dma_map_buf/dma_unmap_buf` 由纯虚改为实现
  - `:363-365` 把 `inject_desc_error` 由纯虚改为实现
- Modify: `virtio_net_vip/src/virtqueue/split_virtqueue.sv`：修改 `:39-46`（构造函数）；删除 `:382-396`（kick）、`:585-639`（DMA helpers）、`:651-677`（inject_desc_error）
- Modify: `virtio_net_vip/src/virtqueue/packed_virtqueue.sv`：修改 `:53-62`（构造函数）；删除 `:407-422`（kick）、`:651-705`（DMA helpers）、`:717-745`（inject_desc_error）
- Modify: `virtio_net_vip/src/virtqueue/custom_virtqueue.sv`：修改 `:103-106`（构造函数）；删除 `:220-275`（DMA helpers）
- Test:
  - `virtio_desc_corruption_test`：覆盖 `kick`、`inject_desc_error`
  - `virtio_indirect_desc_test`、`virtio_migration_dirty_test`：覆盖 `dma_map_buf/dma_unmap_buf`
  - `dpu_priv_ring_contract_test`：custom 队列的 `kick` 仍走回调

**Interfaces:**
- Consumes：
  - `virtqueue_base::get_notify_next_idx()/get_notify_wrap()`（commit 20f7630 加入，保留不动）
  - `release_dma_mapping(int unsigned)`
  - `process_error_injection(virtqueue_error_phase_e)`
- Produces：
  - `protected string log_tag`：基类默认 `"VQ_BASE"`；split 为 `"SPLIT_VQ"`，packed 为 `"PACKED_VQ"`，custom 为 `"CUSTOM_VQ"`。
  - 基类的非纯虚实现：`virtual task kick()`、`virtual function bit [63:0] dma_map_buf(bit [63:0] gpa, int unsigned size, dma_dir_e dir)`、`virtual function void dma_unmap_buf(bit [63:0] iova)`、`virtual function void inject_desc_error(virtqueue_error_e err_type)`。
  - custom 继续覆盖 `kick` 和 `inject_desc_error`，委托给回调。

**等价性证据**（已在 HEAD 上验证，执行时可以重跑）：先把三处报告 ID 统一替换成 `TAG`，再去掉注释和缩进，然后比较。

```bash
norm(){ sed -e 's/SPLIT_VQ\|PACKED_VQ\|CUSTOM_VQ/TAG/g' -e '/^\s*\/\//d' -e 's/^\s*//'; }
cd virtio_net_vip/src/virtqueue
diff <(sed -n 592,639p split_virtqueue.sv | norm) <(sed -n 658,705p packed_virtqueue.sv | norm) && echo SP_DMA_SAME
diff <(sed -n 592,639p split_virtqueue.sv | norm) <(sed -n 228,275p custom_virtqueue.sv | norm) && echo SC_DMA_SAME
diff <(sed -n 654,677p split_virtqueue.sv | norm) <(sed -n 720,745p packed_virtqueue.sv | norm)
```

预期：
- 打印 `SP_DMA_SAME` 和 `SC_DMA_SAME`。
- 第三条只显示两处 `$sformatf` 在换行或拼接方式上的差异。`{"... null, ", "cannot inject %s"}` 拼接后与单个字符串的文本相同，语义一致。

关于 `kick` 日志：split 打印 `avail_idx`，packed 打印 `next_avail_idx` 和 `wrap`。基类实现改为打印 `get_notify_next_idx()/get_notify_wrap()`。这两个函数在 split 中返回 `avail_idx/0`，在 packed 中返回 `next_avail_idx/avail_wrap_counter`，数值不变，只有 UVM_HIGH 日志中的字段名变了。

**Spec deviation:** split/packed 的 `kick` 日志字段名统一为 `next_idx`/`wrap`（UVM_HIGH）。没有测试匹配这段文本：`grep -rn "kick: queue_id" virtio_net_vip/tests examples` 无输出。

- [ ] **Step 1: 在基类新增 `log_tag`**

在 `virtqueue_base.sv` 的 `// ===== State =====` 段（HEAD :45-47）之后插入：

```systemverilog

    // ===== Logging =====
    // 各格式在构造函数里设置自己的报告 ID（SPLIT_VQ/PACKED_VQ/CUSTOM_VQ），
    // 基类公共实现用它打印，测试 report catcher 匹配的 ID 保持不变。
    protected string log_tag = "VQ_BASE";
```

- [ ] **Step 2: 把基类 `kick` 改为实现**

`virtqueue_base.sv` HEAD :156-168。旧代码：

```systemverilog
    // 驱动侧核心三件套：add_buf 把 SG 列表序列化成描述符（前 n_out_sgs 个为
    // 设备只读、后 n_in_sgs 个为设备可写，indirect=1 走间接表）并发布给设备，
    // 返回描述符头 ID（失败约定返回超界值）；kick 是 task，按需向设备发通知
    // （可能消耗仿真时间等待）；poll_used 非阻塞收割一条完成：命中时输出
    // add_buf 存入的 token 与设备写入长度 len 并返回 1，空则返回 0。
    pure virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
    pure virtual task kick();
```

替换为：

```systemverilog
    // 驱动侧核心三件套：add_buf 把 SG 列表序列化成描述符（前 n_out_sgs 个为
    // 设备只读、后 n_in_sgs 个为设备可写，indirect=1 走间接表）并发布给设备，
    // 返回描述符头 ID（失败约定返回超界值）；kick 见下方基类实现；poll_used
    // 非阻塞收割一条完成：命中时输出 add_buf 存入的 token 与设备写入长度 len
    // 并返回 1，空则返回 0。
    pure virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );

    // 标准 split/packed 的 kick：计数并在通知边界前后消费 PRE/POST_NOTIFY 故障。
    // 它不发 PCIe TLP；生产路径由 virtio_atomic_ops 经 transport 发通知。
    // custom 队列覆盖为回调。
    virtual task kick();
        total_kick_ops++;
        void'(process_error_injection(VQ_FAULT_PRE_NOTIFY));
        `uvm_info(log_tag,
            $sformatf("kick: queue_id=%0d next_idx=%0d wrap=%0b",
                      queue_id, get_notify_next_idx(), get_notify_wrap()),
            UVM_HIGH)
        void'(process_error_injection(VQ_FAULT_POST_NOTIFY));
    endtask
```

`process_error_injection` 定义在文件后面。SV 类内方法允许前向引用，所以没有问题。

- [ ] **Step 3: 把基类 `dma_map_buf/dma_unmap_buf` 改为实现**

`virtqueue_base.sv` HEAD :201-208。旧代码：

```systemverilog
    // 队列托管 DMA 映射：dma_map_buf 用本队列的 {host_id, bdf} 域把调用方的
    // GPA 映射为 IOVA 并登记到 dma_mappings（GPA 所有权仍归调用方），返回
    // IOVA；dma_unmap_buf 按 IOVA 解除映射并注销登记。经此登记的映射才会被
    // leak_check/teardown 统一清理。
    pure virtual function bit [63:0] dma_map_buf(
        bit [63:0] gpa, int unsigned size, dma_dir_e dir
    );
    pure virtual function void dma_unmap_buf(bit [63:0] iova);
```

替换为：

```systemverilog
    // 队列托管 DMA 映射：dma_map_buf 用本队列的 {host_id, bdf} 域把调用方的
    // GPA 映射为 IOVA 并登记到 dma_mappings（GPA 所有权仍归调用方），返回
    // IOVA；经此登记的映射才会被 leak_check/teardown 统一清理。映射失败
    // （IOVA 为 '1）也照常登记，由上层检查返回值。与 ring 格式无关，三种队列共用。
    virtual function bit [63:0] dma_map_buf(
        bit [63:0] gpa, int unsigned size, dma_dir_e dir
    );
        bit [63:0] iova;
        iommu_mapping_t mapping;

        iova = iommu.map_for_host(host_id, bdf, gpa, size, dir);

        mapping.host_id = host_id;
        mapping.bdf     = bdf;
        mapping.gpa     = gpa;
        mapping.iova    = iova;
        mapping.size    = size;
        mapping.dir     = dir;
        mapping.desc_id = 0;
        dma_mappings.push_back(mapping);

        `uvm_info(log_tag,
            $sformatf("dma_map_buf: queue_id=%0d gpa=0x%016x iova=0x%016x size=%0d dir=%s",
                      queue_id, gpa, iova, size, dir.name()),
            UVM_HIGH)

        return iova;
    endfunction

    // 按 IOVA 查登记表，命中则经 release_dma_mapping() 解除 IOMMU 映射并注销
    // 登记；找不到报 uvm_error——重复 unmap 或 unmap 未登记地址属调用方 bug。
    virtual function void dma_unmap_buf(bit [63:0] iova);
        int found_idx = -1;

        foreach (dma_mappings[i]) begin
            if (dma_mappings[i].iova == iova) begin
                found_idx = i;
                break;
            end
        end

        if (found_idx >= 0) begin
            release_dma_mapping(found_idx);
            `uvm_info(log_tag,
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x", queue_id, iova),
                UVM_HIGH)
        end else begin
            `uvm_error(log_tag,
                $sformatf("dma_unmap_buf: queue_id=%0d iova=0x%016x not found in dma_mappings",
                          queue_id, iova))
        end
    endfunction
```

- [ ] **Step 4: 把基类 `inject_desc_error` 改为实现**

`virtqueue_base.sv` HEAD :363-365。旧代码：

```systemverilog
    // 由子类实现的描述符级错误注入入口：按 err_type 直接破坏本队列 ring 中的
    // 具体字段，供定向错误用例使用（区别于上面按 err_inj 配置消费的通用钩子）。
    pure virtual function void inject_desc_error(virtqueue_error_e err_type);
```

替换为：

```systemverilog
    // 定向错误注入分派：三种 barrier-skip 错误直接交给 barrier 模型（属内存序
    // 语义，与描述符无关）；其余类型配置给 err_inj 并显式限定到本 queue_id，
    // 由后续 add_buf/kick 路径上的钩子按 phase 消费。err_inj 为空仅告警。
    // custom 队列覆盖为回调，因为通用注入器不认识自定义布局。
    virtual function void inject_desc_error(virtqueue_error_e err_type);
        case (err_type)
            VQ_ERR_SKIP_WMB_BEFORE_AVAIL,
            VQ_ERR_SKIP_RMB_BEFORE_USED,
            VQ_ERR_SKIP_MB_BEFORE_KICK: begin
                barrier.inject_barrier_skip(err_type);
            end
            default: begin
                if (err_inj != null)
                    // Scope the request to this queue; the old zero-argument
                    // form silently targeted queue 0 even when a fault was
                    // requested through a VF/PF queue object.
                    err_inj.configure(err_type, 0, queue_id);
                else
                    `uvm_warning(log_tag,
                        $sformatf("inject_desc_error: queue_id=%0d err_inj is null, cannot inject %s",
                                  queue_id, err_type.name()))
            end
        endcase

        `uvm_info(log_tag,
            $sformatf("inject_desc_error: queue_id=%0d type=%s", queue_id, err_type.name()),
            UVM_MEDIUM)
    endfunction
```

- [ ] **Step 5: 三个子类设置 `log_tag`，并删除重复实现**

5a. `split_virtqueue.sv`：
- 构造函数（HEAD :39-46）：在 `avail_idx         = 0;` 之后加一行 `        log_tag           = "SPLIT_VQ";`。
- 删除 `kick`（HEAD :382-396，从 `// kick -- Notify the device` 注释块的 `// ----` 起，到 `endtask` 止）。
- 删除 `// DMA helpers` 段（:585-639，从 `// =====` 分隔行起，到 `dma_unmap_buf` 的 `endfunction` 止）。
- 删除 `inject_desc_error` 及其上方 3 行中文注释（:651-677）。
- 保留 `descriptor_format()`（:645-649）。

5b. `packed_virtqueue.sv`：
- 构造函数（HEAD :53-62）：在 `desc_ring_size     = 0;` 之后加一行 `        log_tag            = "PACKED_VQ";`。
- 删除 `kick`（:407-422）。
- 删除 `// DMA helpers (same pattern as split virtqueue)` 段（:651-705）。
- 删除 `inject_desc_error` 及其注释（:717-745）。
- 保留 `descriptor_format()`（:710-715）。

5c. `custom_virtqueue.sv`：
- 构造函数（HEAD :103-106）：在 `custom_cb = null;` 之后加一行 `        log_tag = "CUSTOM_VQ";`。
- 删除 `// DMA helpers (transport-independent, same as split/packed)` 段（:220-275）。
- `kick`、`inject_desc_error` 的回调覆盖保留。

5d. `virtqueue_base.sv` 文件头注释（HEAD :10-12）改为：

```systemverilog
// Subclasses (split_virtqueue, packed_virtqueue, custom_virtqueue) implement
// the ring-format pure virtual methods. This class provides common state,
// setup logic, DMA helpers, kick/error-injection defaults and utility methods
// (dump_ring, leak_check). Subclasses set log_tag in their constructors.
```

- [ ] **Step 6: 用 grep 证明子类不再有重复实现**

```bash
grep -nE "function bit \[63:0\] dma_map_buf|function void dma_unmap_buf|task kick\(\)|function void inject_desc_error" virtio_net_vip/src/virtqueue/*.sv
```

预期恰好 6 行：`virtqueue_base.sv` 中的 4 个定义，加上 `custom_virtqueue.sv` 中的 2 个覆盖。

```
virtio_net_vip/src/virtqueue/custom_virtqueue.sv:<n>:    virtual task kick();
virtio_net_vip/src/virtqueue/custom_virtqueue.sv:<n>:    virtual function void inject_desc_error(virtqueue_error_e err_type);
virtio_net_vip/src/virtqueue/virtqueue_base.sv:<n>:    virtual task kick();
virtio_net_vip/src/virtqueue/virtqueue_base.sv:<n>:    virtual function bit [63:0] dma_map_buf(
virtio_net_vip/src/virtqueue/virtqueue_base.sv:<n>:    virtual function void dma_unmap_buf(bit [63:0] iova);
virtio_net_vip/src/virtqueue/virtqueue_base.sv:<n>:    virtual function void inject_desc_error(virtqueue_error_e err_type);
```

- [ ] **Step 7: SYNC 并运行受影响的测试**

SYNC 命令同 P2-1 Step 8。用 ONE TEST 命令依次运行 `virtio_desc_corruption_test`、`virtio_indirect_desc_test`、`virtio_migration_dirty_test`、`virtio_queue_semantics_test`、`dpu_priv_ring_contract_test`。预期全部为 0 WARNING/ERROR/FATAL。

- [ ] **Step 8: 全量回归**

运行 REGRESSION 命令（同 P2-1 Step 9），预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 9: 提交**

```bash
git add virtio_net_vip/src/virtqueue/virtqueue_base.sv virtio_net_vip/src/virtqueue/split_virtqueue.sv \
        virtio_net_vip/src/virtqueue/packed_virtqueue.sv virtio_net_vip/src/virtqueue/custom_virtqueue.sv
git commit -m "refactor: virtqueue 的 dma_map_buf/dma_unmap_buf、inject_desc_error、kick 上移到基类并用 log_tag 保留报告 ID"
```

---

### Task P2-2b: 把 virtqueue 生命周期的公共前段与快照头上移

**Files:**
- Modify: `virtio_net_vip/src/virtqueue/virtqueue_base.sv`：删除 `pure virtual function void detach_all_unused`（HEAD :154）；在 `discard_staged_migration_ownership`（HEAD :586-589）之后新增 3 个 protected 函数。
- Modify: `virtio_net_vip/src/virtqueue/split_virtqueue.sv`：修改 `free_rings`（HEAD :182-199）、`reset_queue`（:204-220）、`save_state`（:695-703）；删除 `detach_all_unused`（:222-240）。
- Modify: `virtio_net_vip/src/virtqueue/packed_virtqueue.sv`：修改 `free_rings`（HEAD :192-209）、`reset_queue`（:214-234）、`save_state`（:757-765）；删除 `detach_all_unused`（:236-253）。
- Test:
  - `virtio_migration_dirty_test`：覆盖 save/restore
  - `virtio_admin_vq_test`：覆盖 `detach_all_unused` + `reset_queue`
  - `virtio_pf_lifecycle_reset_test`、`virtio_queue_semantics_test`

**Interfaces:**
- Consumes：`release_all_dma_mappings()`、`discard_staged_migration_ownership()`、`release_all_indirect_tables()`、`token_map`，以及 P2-2a 的 `log_tag`。
- Produces（`virtqueue_base`）：
  - `protected function void release_queue_ownership();`：释放队列登记的全部 DMA 映射，丢弃迁移暂存，清空 token，释放全部间接表。
  - `protected function void clear_op_counters();`
  - `protected function void fill_snapshot_header(int unsigned last_avail, int unsigned last_used, bit avail_wrap, bit used_wrap, ref virtqueue_snapshot_t snap);`：ref 参数放在最后，避开 VCS 的 ref 传染规则。
  - `virtual function void detach_all_unused(ref uvm_object tokens[$]);`：基类实现，custom 仍然覆盖。

**等价性论证：**
- `detach_all_unused`：split 与 packed 的实现去掉 ID 后逐行相同。在 HEAD 上运行 `diff <(sed -n 225,240p split_virtqueue.sv | norm) <(sed -n 239,253p packed_virtqueue.sv | norm)` 无差异（`norm` 的定义见 P2-2a）。
  调用顺序从“token、DMA、迁移暂存、间接表”变为 `release_queue_ownership` 中的“DMA、迁移暂存、token、间接表”。这四个结构互不引用，顺序不影响结果。
- `reset_queue`：它首先调用本类的 `free_rings()`，后者已执行过 `release_queue_ownership()`。所以原来紧随其后的 `token_map.delete(); release_all_dma_mappings(); discard_staged_migration_ownership();`（packed 还有 `release_all_indirect_tables()`）作用在空结构上，都是空操作：
  `release_all_dma_mappings` 只在 `dma_mappings.size()!=0` 时循环，间接表释放只遍历现有的键。删除这些调用不改变行为。
- packed `save_state`：原来写入 `snap.driver_addr = driver_event_addr; snap.device_addr = device_event_addr;`。改用 `driver_ring_addr/device_ring_addr` 填写快照头，得到的值相同，原因如下：
  - `alloc_rings`（HEAD :157-162）同时设置 `driver_ring_addr = driver_event_addr` 和 `device_ring_addr = device_event_addr`；
  - `free_rings`（:200-203）同时清零这四个字段；
  - `restore_state` 只比较、不赋值（:801-802）。

- [ ] **Step 1: 在基类新增公共函数，把 `detach_all_unused` 改为实现**

`virtqueue_base.sv`：
- 删除 HEAD :154 的 `    pure virtual function void detach_all_unused(ref uvm_object tokens[$]);`。
- 把 :147-150 注释的末句“detach_all_unused：摘除所有尚未被设备消费的缓冲并把对应 token 交还调用方（tokens 输出队列）。”改为“detach_all_unused 见基类实现。”。

在 `discard_staged_migration_ownership` 的 `endfunction`（HEAD :589）之后插入：

```systemverilog

    // free_rings/detach 的公共前段：释放队列登记的全部 DMA 映射、丢弃迁移
    // 暂存、清空 token 并释放全部间接表。四个结构互不引用，顺序无关。
    protected function void release_queue_ownership();
        release_all_dma_mappings();
        discard_staged_migration_ownership();
        token_map.delete();
        release_all_indirect_tables();
    endfunction

    // reset_queue 的统计清零。
    protected function void clear_op_counters();
        total_add_buf_ops   = 0;
        total_poll_used_ops = 0;
        total_kick_ops      = 0;
    endfunction

    // save_state 的公共快照头；ring 内容与格式私有字段由各格式补充。
    protected function void fill_snapshot_header(
        int unsigned last_avail,
        int unsigned last_used,
        bit          avail_wrap,
        bit          used_wrap,
        ref virtqueue_snapshot_t snap
    );
        snap.queue_id       = queue_id;
        snap.queue_size     = queue_size;
        snap.desc_addr      = desc_table_addr;
        snap.driver_addr    = driver_ring_addr;
        snap.device_addr    = device_ring_addr;
        snap.last_avail_idx = last_avail;
        snap.last_used_idx  = last_used;
        snap.avail_wrap     = avail_wrap;
        snap.used_wrap      = used_wrap;
    endfunction

    // 摘除所有尚未被设备消费的缓冲：token 按 token_map 键序交还调用方，
    // 随后释放队列所有权。custom 队列覆盖为回调。
    virtual function void detach_all_unused(ref uvm_object tokens[$]);
        foreach (token_map[desc_id])
            tokens.push_back(token_map[desc_id]);
        release_queue_ownership();
        `uvm_info(log_tag,
            $sformatf("detach_all_unused: queue_id=%0d returned %0d tokens",
                      queue_id, tokens.size()),
            UVM_HIGH)
    endfunction
```

- [ ] **Step 2: split 改用公共函数**

`free_rings`（HEAD :183-186）。旧代码：

```systemverilog
        release_all_dma_mappings();
        discard_staged_migration_ownership();
        token_map.delete();
        release_all_indirect_tables();
        if (desc_table_addr != 0)  mem.free(desc_table_addr);
```
替换为：
```systemverilog
        release_queue_ownership();
        if (desc_table_addr != 0)  mem.free(desc_table_addr);
```

`reset_queue`（HEAD :210-216）。旧代码：

```systemverilog
        event_idx_enabled = 0;
        token_map.delete();
        release_all_dma_mappings();
        discard_staged_migration_ownership();
        total_add_buf_ops   = 0;
        total_poll_used_ops = 0;
        total_kick_ops      = 0;
```
替换为：
```systemverilog
        event_idx_enabled = 0;
        clear_op_counters();
```

删除 `detach_all_unused`（HEAD :222-240，从 `// detach_all_unused -- Collect all outstanding tokens and clean up` 注释块的 `// ----` 起，到 `endfunction` 止）。

`save_state`（HEAD :695-703）。旧代码：

```systemverilog
        snap.queue_id       = queue_id;
        snap.queue_size     = queue_size;
        snap.desc_addr      = desc_table_addr;
        snap.driver_addr    = driver_ring_addr;
        snap.device_addr    = device_ring_addr;
        snap.last_avail_idx = avail_idx;
        snap.last_used_idx  = last_used_idx;
        snap.avail_wrap     = 0;
        snap.used_wrap      = 0;
```
替换为：
```systemverilog
        fill_snapshot_header(avail_idx, last_used_idx, 1'b0, 1'b0, snap);
```

- [ ] **Step 3: packed 改用公共函数**

`free_rings`（HEAD :193-196）：与 split 相同，把前 4 行换成 `        release_queue_ownership();`。

`reset_queue`（HEAD :221-232）。旧代码：

```systemverilog
        free_id_list.delete();
        token_map.delete();
        release_all_dma_mappings();
        discard_staged_migration_ownership();
        release_all_indirect_tables();
        total_add_buf_ops   = 0;
        total_poll_used_ops = 0;
        total_kick_ops      = 0;
```
替换为：
```systemverilog
        free_id_list.delete();
        clear_op_counters();
```

删除 `detach_all_unused`（HEAD :236-253）。

`save_state`（HEAD :757-765）。旧代码：

```systemverilog
        snap.queue_id       = queue_id;
        snap.queue_size     = queue_size;
        snap.desc_addr      = desc_table_addr;
        snap.driver_addr    = driver_event_addr;
        snap.device_addr    = device_event_addr;
        snap.last_avail_idx = next_avail_idx;
        snap.last_used_idx  = next_used_idx;
        snap.avail_wrap     = avail_wrap_counter;
        snap.used_wrap      = used_wrap_counter;
```
替换为：
```systemverilog
        // driver/device_ring_addr 与 event 地址在 alloc_rings/free_rings 中同步维护。
        fill_snapshot_header(next_avail_idx, next_used_idx,
                             avail_wrap_counter, used_wrap_counter, snap);
```

- [ ] **Step 4: 用 grep 证明**

```bash
grep -nE "function void detach_all_unused" virtio_net_vip/src/virtqueue/*.sv
grep -nE "total_kick_ops *= *0|snap\.queue_id *=" virtio_net_vip/src/virtqueue/split_virtqueue.sv virtio_net_vip/src/virtqueue/packed_virtqueue.sv
```

预期：第一条只有 `virtqueue_base.sv` 和 `custom_virtqueue.sv` 各一行；第二条无输出。

- [ ] **Step 5: SYNC 并运行受影响的测试**

用 ONE TEST 命令依次运行 `virtio_migration_dirty_test`、`virtio_admin_vq_test`、`virtio_pf_lifecycle_reset_test`、`virtio_queue_semantics_test`、`virtio_stress_unit_test`。预期全部为 0 WARNING/ERROR/FATAL。

- [ ] **Step 6: 全量回归**

预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 7: 提交**

```bash
git add virtio_net_vip/src/virtqueue/virtqueue_base.sv virtio_net_vip/src/virtqueue/split_virtqueue.sv \
        virtio_net_vip/src/virtqueue/packed_virtqueue.sv
git commit -m "refactor: virtqueue 的 detach_all_unused、free/reset 公共前段与快照头赋值上移到基类"
```

---

### Task P2-3a: atomic ops 新增 kick_with_fault，替换 4 处重复的通知代码

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`：
  - 在 `has_pending_normal_dma`（HEAD :97-108）之后新增 `kick_with_fault`；
  - 替换 `tx_submit` :1073-1084、`rx_refill` :1217-1225、`admin_vq_submit` :1497-1504、`ctrl_send` :1724-1730。
- Test:
  - `virtio_indirect_desc_test`：其中 `test_atomic_notify_cursor` 校验 split/packed 的游标
  - `virtio_admin_vq_test`：校验 `transport.kick_count`
  - `virtio_desc_corruption_test`、`virtio_dual_test`、`virtio_traffic_test`

**Interfaces:**
- Consumes：`virtqueue_base::process_error_injection`、`get_notify_next_idx()`、`get_notify_wrap()`、`virtio_pci_transport::kick(int unsigned queue_id, int unsigned next_avail_idx, bit wrap_counter)`。
- Produces：`protected task kick_with_fault(virtqueue_base vq, int unsigned qid, virtio_pci_transport via = null);`

**Spec deviation:** 规格中的签名是 `kick_with_fault(vq, qid)`。Admin VQ 通过 `admin_context.transport` 发通知，而不是 `ops.transport`，所以增加了第三个可选参数 `via`；`via` 为 null 时使用 `transport`。

- [ ] **Step 1: 新增 `kick_with_fault`**

在 `has_pending_normal_dma` 的 `endfunction`（HEAD :108）之后插入：

```systemverilog

    // 生产路径的通知边界：PRE_NOTIFY 故障钩子 → transport 通知（携带 ring 游标
    // next_idx/wrap）→ POST_NOTIFY 故障钩子。不调用 virtqueue::kick()，那只计数；
    // 调用方自己决定是否需要通知（needs_notification 等）。via 为空时用本 ops 的
    // transport，Admin VQ 传入其上下文 transport。
    protected task kick_with_fault(virtqueue_base vq, int unsigned qid,
                                   virtio_pci_transport via = null);
        virtio_pci_transport notify_transport;

        notify_transport = (via != null) ? via : transport;
        void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
        notify_transport.kick(qid, vq.get_notify_next_idx(), vq.get_notify_wrap());
        void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
    endtask
```

- [ ] **Step 2: 替换 4 处调用**

`tx_submit`（HEAD :1073-1084）。旧代码：

```systemverilog
        // 8. Kick if device needs notification
        if (vq.needs_notification()) begin
            // The production atomic path owns the PCIe notify, so it does
            // not call virtqueue::kick().  Keep the queue fault boundary
            // around the real transport write; otherwise configured
            // descriptor corruption is consumed only by legacy callers that
            // invoke kick() directly and never reaches normal TX flows.
            void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(queue_id, vq.get_notify_next_idx(),
                           vq.get_notify_wrap());
            void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end
```
替换为：
```systemverilog
        // 8. Kick if device needs notification
        if (vq.needs_notification())
            kick_with_fault(vq, queue_id);
```

`rx_refill`（HEAD :1217-1225）。旧代码：

```systemverilog
        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification()) begin
            // Mirror tx_submit(): rx_refill also bypasses virtqueue::kick()
            // and emits the notify through the PCI transport directly.
            void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(queue_id, vq.get_notify_next_idx(),
                           vq.get_notify_wrap());
            void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end
```
替换为：
```systemverilog
        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification())
            kick_with_fault(vq, queue_id);
```

`admin_vq_submit`（HEAD :1497-1504）。旧代码：

```systemverilog
                    submitted = 1;
                    void'(admin_context.vq.process_error_injection(
                        VQ_FAULT_PRE_NOTIFY));
                    admin_context.transport.kick(admin_context.queue_id,
                                                 admin_context.vq.get_notify_next_idx(),
                                                 admin_context.vq.get_notify_wrap());
                    void'(admin_context.vq.process_error_injection(
                        VQ_FAULT_POST_NOTIFY));
```
替换为：
```systemverilog
                    submitted = 1;
                    kick_with_fault(admin_context.vq, admin_context.queue_id,
                                    admin_context.transport);
```

`ctrl_send`（HEAD :1724-1730）。旧代码：

```systemverilog
        // 6. Kick control queue
        if (ctrl_vq.needs_notification()) begin
            void'(ctrl_vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(ctrl_qid, ctrl_vq.get_notify_next_idx(),
                           ctrl_vq.get_notify_wrap());
            void'(ctrl_vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end
```
替换为：
```systemverilog
        // 6. Kick control queue
        if (ctrl_vq.needs_notification())
            kick_with_fault(ctrl_vq, ctrl_qid);
```

P0-3 只改了 `ctrl_send` 的分配段和映射段，kick 段与 HEAD 相同；以锚点 `// 6. Kick control queue` 定位。

- [ ] **Step 3: 用 grep 证明**

```bash
grep -n "VQ_FAULT_PRE_NOTIFY\|VQ_FAULT_POST_NOTIFY\|transport.kick(" virtio_net_vip/src/agent/virtio_atomic_ops.sv
```

预期恰好 3 行，全部位于 `kick_with_fault` 内部。

- [ ] **Step 4: SYNC 并运行受影响的测试**

用 ONE TEST 命令依次运行 `virtio_indirect_desc_test`、`virtio_admin_vq_test`、`virtio_desc_corruption_test`、`virtio_dual_test`、`virtio_traffic_test`。预期全部为 0 WARNING/ERROR/FATAL。

- [ ] **Step 5: 全量回归**

预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

```bash
git add virtio_net_vip/src/agent/virtio_atomic_ops.sv
git commit -m "refactor: atomic ops 用 kick_with_fault 统一 PRE_NOTIFY/kick/POST_NOTIFY 通知边界"
```

---

### Task P2-3b: 新增 virtio_dma_buffer_set，管理单次提交的 DMA 缓冲生命周期

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_dma_buffer_set.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:83`：在 `` `include "agent/virtio_atomic_ops.sv" `` 之前加一行 include。
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`：新增 `test_dma_buffer_set`，并在 `run_phase`（HEAD :184-204）中调用。

**Interfaces:**
- Consumes：`host_mem_manager::alloc/write_mem/mem_set/free`、`virtio_iommu_model::map_for_host/unmap_for_host`、`dma_dir_e`。它们都在 pkg 中更早被 include。
- Produces（`class virtio_dma_buffer_set extends uvm_object`）：
  - `function void bind_domain(host_mem_manager m, virtio_iommu_model io, int unsigned hid, bit [15:0] requester_bdf);`
  - `function int alloc(int unsigned size, int unsigned align = 1);`：返回索引；失败时返回 -1，且不登记。
  - `function void write(int unsigned idx, byte data[]);`、`function void fill(int unsigned idx, byte value);`
  - `function bit map(int unsigned idx, dma_dir_e dir);`：IOVA 为 `'1` 或 0 时视为失败，返回 0。
  - `function bit [63:0] get_gpa(int unsigned idx);`、`get_iova(idx)`、`function int unsigned count();`、`get_host_id()`、`get_bdf()`
  - `function void release_all();`：先按添加顺序 unmap 已映射项，再按添加顺序 free 全部 GPA，最后清空登记。
  - `function void disown();`：所有权已转交，只清空登记。
  - `function void quarantine_into(ref bit [63:0] q_iovas[$], ref bit [63:0] q_gpas[$]);`：按添加顺序把已映射的 IOVA 和全部 GPA 追加到隔离列表，然后清空登记。

- [ ] **Step 1: 先写失败的测试**

修改 `virtio_unit_test.sv`：
- 在 `run_phase` 中 `test_late_driver_agent_binding();`（HEAD :200）之后加一行 `        test_dma_buffer_set();`。
- 在 `test_host_mem` 任务（HEAD :252）之前插入：

```systemverilog
    // virtio_dma_buffer_set：alloc→write/fill→map→失败回滚、disown 与隔离转出
    // 的所有权约定。单页 IOVA aperture 让第二次映射必然失败。
    task test_dma_buffer_set();
        host_mem_manager mem = host_mem_manager::type_id::create("dma_set_mem");
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("dma_set_iommu");
        virtio_dma_buffer_set dma_set = new("dma_set");
        virtio_expected_iommu_map_error_catcher map_error;
        bit [63:0] q_iovas[$];
        bit [63:0] q_gpas[$];
        bit [63:0] kept_gpa;
        bit [63:0] kept_iova;
        byte wdata[];
        byte rdata[];
        int first_idx;
        int second_idx;
        string why;

        mem.init_region(64'h2000_0000, 64'h2000_FFFF);
        assert(iommu.configure_iova_aperture(64'h0000_0001_0000_0000,
                                             64'h0000_0001_0000_1000,
                                             IOMMU_IOVA_FIRST_FIT, why))
            else `uvm_fatal("TEST", why)
        dma_set.bind_domain(mem, iommu, 0, 16'h0100);

        // 1. alloc + write/fill：按索引写入各自 GPA
        first_idx = dma_set.alloc(64);
        second_idx = dma_set.alloc(32);
        assert(first_idx == 0 && second_idx == 1 && dma_set.count() == 2)
            else `uvm_fatal("TEST", "dma_set alloc did not register two buffers")
        wdata = new[4];
        foreach (wdata[i]) wdata[i] = 8'h10 + i;
        dma_set.write(first_idx, wdata);
        dma_set.fill(second_idx, 8'hFF);
        mem.read_mem(dma_set.get_gpa(first_idx), 4, rdata);
        assert(rdata[0] == 8'h10 && rdata[3] == 8'h13)
            else `uvm_fatal("TEST", "dma_set write landed at the wrong GPA")
        mem.read_mem(dma_set.get_gpa(second_idx), 32, rdata);
        assert(byte unsigned'(rdata[31]) == 8'hFF)
            else `uvm_fatal("TEST", "dma_set fill did not cover the whole buffer")

        // 2. 第二次映射失败：release_all 解除已映射项并释放全部 GPA
        assert(dma_set.map(first_idx, DMA_TO_DEVICE) && dma_set.get_iova(first_idx) != 0)
            else `uvm_fatal("TEST", "dma_set first map failed")
        map_error = new("dma_set_map_error");
        uvm_report_cb::add(null, map_error);
        assert(!dma_set.map(second_idx, DMA_FROM_DEVICE))
            else `uvm_fatal("TEST", "dma_set map succeeded beyond the IOVA aperture")
        uvm_report_cb::delete(null, map_error);
        dma_set.release_all();
        assert(map_error.caught_count == 1 && dma_set.count() == 0 &&
               iommu.total_maps == 1 && iommu.total_unmaps == 1)
            else `uvm_fatal("TEST", "dma_set rollback left mappings or registrations")

        // 3. disown：所有权已转交，release_all 不得再触碰资源
        first_idx = dma_set.alloc(16);
        assert(first_idx == 0 && dma_set.map(first_idx, DMA_TO_DEVICE))
            else `uvm_fatal("TEST", "dma_set remap after rollback failed")
        kept_gpa = dma_set.get_gpa(first_idx);
        kept_iova = dma_set.get_iova(first_idx);
        dma_set.disown();
        dma_set.release_all();
        assert(dma_set.count() == 0 && iommu.total_unmaps == 1)
            else `uvm_fatal("TEST", "dma_set released resources it had disowned")
        iommu.unmap_for_host(0, 16'h0100, kept_iova);
        mem.free(kept_gpa);

        // 4. quarantine：已映射 IOVA 与全部 GPA 按添加顺序转出
        first_idx = dma_set.alloc(8);
        second_idx = dma_set.alloc(8);
        assert(dma_set.map(first_idx, DMA_TO_DEVICE))
            else `uvm_fatal("TEST", "dma_set quarantine setup map failed")
        kept_gpa = dma_set.get_gpa(first_idx);
        kept_iova = dma_set.get_iova(first_idx);
        dma_set.quarantine_into(q_iovas, q_gpas);
        assert(dma_set.count() == 0 && q_iovas.size() == 1 && q_gpas.size() == 2 &&
               q_iovas[0] == kept_iova && q_gpas[0] == kept_gpa)
            else `uvm_fatal("TEST", "dma_set quarantine did not transfer ownership in order")
        iommu.unmap_for_host(0, 16'h0100, q_iovas[0]);
        foreach (q_gpas[i]) mem.free(q_gpas[i]);

        mem.leak_check();
        iommu.leak_check();
        `uvm_info("UNIT_TEST", "test_dma_buffer_set PASSED", UVM_LOW)
    endtask
```

- [ ] **Step 2: 运行，预期编译失败**

SYNC 后运行 ONE TEST，`<test_name>` 为 `virtio_unit_test`。预期输出包含指向 `virtio_dma_buffer_set` 的 VCS 编译错误，例如 `Error-[IND] Identifier not declared` 或 `Error-[SV-UDT]`。

- [ ] **Step 3: 创建 `virtio_net_vip/src/agent/virtio_dma_buffer_set.sv`**

```systemverilog
// 目录层次：src/agent；一次提交（TX/RX/control VQ/Admin VQ）涉及的普通数据 DMA
// 缓冲集合，负责 alloc → write → map → 失败回滚 → 退休。本类不报告错误，由调用方
// 用自己的报告 ID 说明失败原因。所有权经 disown（交给 ops 的 TX/RX 跟踪表）或
// quarantine_into（设备未确认停 DMA）转出后，release_all 不再触碰这些资源。
// 释放顺序：先按添加顺序 unmap 已映射项，再按添加顺序 free 全部 GPA。
`ifndef VIRTIO_DMA_BUFFER_SET_SV
`define VIRTIO_DMA_BUFFER_SET_SV

class virtio_dma_buffer_set extends uvm_object;
    `uvm_object_utils(virtio_dma_buffer_set)

    protected host_mem_manager   mem;
    protected virtio_iommu_model iommu;
    protected int unsigned       host_id;
    protected bit [15:0]         bdf;

    // 四个并行队列，索引即 alloc() 的返回值。
    protected bit [63:0]   gpas[$];
    protected bit [63:0]   iovas[$];
    protected int unsigned sizes[$];
    protected bit          mapped[$];

    // 构造空集合；alloc 之前必须先 bind_domain。
    function new(string name = "virtio_dma_buffer_set");
        super.new(name);
    endfunction

    // 绑定本次提交使用的 Host memory、IOMMU 和 {host_id, bdf} 请求者域。
    function void bind_domain(host_mem_manager m, virtio_iommu_model io,
                              int unsigned hid, bit [15:0] requester_bdf);
        mem     = m;
        iommu   = io;
        host_id = hid;
        bdf     = requester_bdf;
    endfunction

    // 分配 size 字节并登记，返回索引；分配失败返回 -1 且不登记。
    function int alloc(int unsigned size, int unsigned align = 1);
        bit [63:0] gpa;

        gpa = mem.alloc(size, .align(align));
        if (gpa == '1)
            return -1;
        gpas.push_back(gpa);
        iovas.push_back(64'h0);
        sizes.push_back(size);
        mapped.push_back(1'b0);
        return gpas.size() - 1;
    endfunction

    // 把 data 写到第 idx 个缓冲起始处（长度可小于分配长度）。
    function void write(int unsigned idx, byte data[]);
        mem.write_mem(gpas[idx], data);
    endfunction

    // 用 value 填满第 idx 个缓冲的整个分配长度。
    function void fill(int unsigned idx, byte value);
        mem.mem_set(gpas[idx], value, sizes[idx]);
    endfunction

    // 按分配长度映射第 idx 个缓冲；IOVA 为 '1 或 0 视为失败并返回 0，
    // 失败项不标记为已映射，release_all 只释放其 GPA。
    function bit map(int unsigned idx, dma_dir_e dir);
        bit [63:0] iova;

        iova = iommu.map_for_host(host_id, bdf, gpas[idx], sizes[idx], dir);
        if ((iova == '1) || (iova == 0))
            return 0;
        iovas[idx]  = iova;
        mapped[idx] = 1'b1;
        return 1;
    endfunction

    function bit [63:0] get_gpa(int unsigned idx);
        return gpas[idx];
    endfunction

    function bit [63:0] get_iova(int unsigned idx);
        return iovas[idx];
    endfunction

    function int unsigned count();
        return gpas.size();
    endfunction

    function int unsigned get_host_id();
        return host_id;
    endfunction

    function bit [15:0] get_bdf();
        return bdf;
    endfunction

    // 回滚或退休：先 unmap 全部已映射项，再 free 全部 GPA，最后清空登记。
    // 只能在设备不会再访问这些缓冲时调用（未提交、已完成或已确认复位）。
    function void release_all();
        foreach (mapped[i]) begin
            if (mapped[i])
                iommu.unmap_for_host(host_id, bdf, iovas[i]);
        end
        foreach (gpas[i])
            mem.free(gpas[i]);
        clear();
    endfunction

    // 所有权已转交其他记录（例如 ops 的 tx/rx_dma_map），只清登记。
    function void disown();
        clear();
    endfunction

    // 设备未确认停止 DMA：把已映射 IOVA 与全部 GPA 按添加顺序追加到隔离列表，
    // 本集合放弃所有权，由隔离列表的持有者在确认复位后回收。
    function void quarantine_into(ref bit [63:0] q_iovas[$], ref bit [63:0] q_gpas[$]);
        foreach (mapped[i]) begin
            if (mapped[i])
                q_iovas.push_back(iovas[i]);
        end
        foreach (gpas[i])
            q_gpas.push_back(gpas[i]);
        clear();
    endfunction

    protected function void clear();
        gpas.delete();
        iovas.delete();
        sizes.delete();
        mapped.delete();
    endfunction
endclass : virtio_dma_buffer_set

`endif // VIRTIO_DMA_BUFFER_SET_SV
```

- [ ] **Step 4: 加入 package**

`virtio_net_vip/src/virtio_net_pkg.sv` HEAD :82-83。旧代码：

```systemverilog
  `include "dataplane/virtio_net_packet_adapter.sv"
  `include "agent/virtio_atomic_ops.sv"
```
替换为：
```systemverilog
  `include "dataplane/virtio_net_packet_adapter.sv"
  `include "agent/virtio_dma_buffer_set.sv"
  `include "agent/virtio_atomic_ops.sv"
```

- [ ] **Step 5: 运行，预期 PASS**

SYNC 后运行 ONE TEST `virtio_unit_test`。预期日志中出现 `test_dma_buffer_set PASSED`（`grep -c "test_dma_buffer_set PASSED" logs/virtio_unit_test.log` 输出 1），且 grep 汇总为 0 WARNING/ERROR/FATAL。

- [ ] **Step 6: 全量回归**

预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 7: 提交**

```bash
git add virtio_net_vip/src/agent/virtio_dma_buffer_set.sv virtio_net_vip/src/virtio_net_pkg.sv \
        virtio_net_vip/tests/virtio_unit_test.sv
git commit -m "feat: 新增 virtio_dma_buffer_set 统一单次提交的 DMA 分配、映射、回滚与隔离"
```

---

### Task P2-3c: tx_submit / rx_refill 改用 virtio_dma_buffer_set

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`：
  - 在 `kick_with_fault`（P2-3a）之后新增 `adopt_dma_set`；
  - 整体替换 `tx_submit`（HEAD :907-1089）和 `rx_refill`（HEAD :1140-1230）。
- Test:
  - `virtio_indirect_desc_test`：其中 `test_atomic_tx_queue_full_cleanup` 校验拒绝后的 maps、token 和 kick 数
  - `virtio_migration_dirty_test`：`snapshot/restore_normal_dma_ownership` 会读取 `tx/rx_dma_map`
  - `virtio_unit_test`、`virtio_stress_unit_test`、`virtio_pf_lifecycle_reset_test`、`virtio_traffic_test`、`virtio_dual_test`，以及两个私有环测试

**Interfaces:**
- Consumes：P2-3a 的 `kick_with_fault`；P2-3b 的 `virtio_dma_buffer_set`；`normal_dma_record_t`、`tx_dma_map`、`rx_dma_map`（HEAD :42-49，不改）。
- Produces：`protected function void adopt_dma_set(virtio_dma_buffer_set dma_set, ref normal_dma_record_t records[$]);`

**必须保持的 DMA 所有权语义：**
- **完成路径的退休顺序。** `tx_complete`（HEAD :1094-1131）按“每包两条记录、header 在前”的顺序 `pop_front` 退休。新代码在 `add_buf` 成功后按 hdr、pkt 的顺序 `adopt`，顺序不变。
- **登记时机。** 原代码在 `add_buf` 之前就把记录压入 `tx/rx_dma_map`，拒绝后再 `pop_back`。`add_buf` 是 function，执行期间不让出时间，也不调用其他所有权路径，所以改成成功后再登记，结果完全相同：拒绝时映射表中既不留记录，也不留空键。
- **通知之前已登记。** 记录在 `kick_with_fault`（task，可能耗时）之前登记，因此并发的 `device_reset_verified/teardown_queue` 仍能看到并退休它们，与原来相同。
- **子类不受影响。**
  - `dpu_priv_atomic_ops` 完整覆写了 `tx_submit/tx_complete/rx_refill/rx_receive/rx_receive_frames/ctrl_send`（其中 `rx_receive_frames` 在 P2-1 加入）。它只用到基类的 `normal_dma_record_t`、`tx_dma_map`、`rx_dma_map`、`retire_normal_dma_record(s)`、`contexts`，这些本任务都不改。
  - 测试子类 `virtio_pf_lifecycle_blocking_ops` 覆写 `rx_refill` 后调用 `super`。P0-5 已把它改成三参数签名 `(queue_id, num_bufs, buf_size = 0)`，本任务签名不变。
  - P0-4 的线速字节修正（`wire_bytes` 段）和 P0-5 的 `buf_size` 参数都逐字保留。`virtio_net_packet_multi_queue_test` 对 TX 数据描述符长度、RX buffer 长度 ≥2048 的断言因此照样成立，该测试已加入下面的测试列表。
  - `virtio_migration_dirty_real_reset_ops` 使用 `retire_normal_dma_records`，也不受影响。
- **失败路径顺序。** unmap/free 的顺序与 HEAD 相同，都是 hdr 在前。

- [ ] **Step 1: 新增 `adopt_dma_set`**

在 `kick_with_fault` 的 `endtask` 之后插入：

```systemverilog

    // 把 buffer set 中的全部缓冲按添加顺序转成普通 DMA 所有权记录，追加到
    // records，然后让 set 放弃所有权。之后只由完成路径或已确认的设备复位退休。
    // 调用方保证每一项都已映射（只在 add_buf 成功后调用）。
    protected function void adopt_dma_set(
        virtio_dma_buffer_set   dma_set,
        ref normal_dma_record_t records[$]
    );
        normal_dma_record_t record;

        for (int unsigned i = 0; i < dma_set.count(); i++) begin
            record.host_id = dma_set.get_host_id();
            record.bdf     = dma_set.get_bdf();
            record.gpa     = dma_set.get_gpa(i);
            record.iova    = dma_set.get_iova(i);
            records.push_back(record);
        end
        dma_set.disown();
    endfunction
```

- [ ] **Step 2: 替换 `tx_submit`**

用下面的完整任务替换 `virtual task tx_submit(` 到其 `endtask` 之间的内容（HEAD :907-1089；P0-4 Step 6 之后行号有变化，以锚点为准）。HEAD :893-906 的头注释（P0 已把第 2 条改为 `Get wire bytes ...`）保持不动。

P0-4 Step 6 修改后的代码（old，本任务原样保留）：一是局部变量 `byte unsigned    wire_bytes[$];`（P0 加在 `normal_dma_record_t dma_record;` 之后；`dma_record` 本任务会删掉，`wire_bytes` 保留）；二是第 2 步取线速字节的写法：

```systemverilog
        // 2. Get wire bytes.  packet_item.do_pack() 带 32-bit UVM 长度前缀，不是
        // 线速帧，先经 adapter 取 raw_data；其他对象保留原 do_pack 字节流。
        if (virtio_net_packet_adapter::pack(pkt, wire_bytes)) begin
            pkt_bytes = new[wire_bytes.size()];
            foreach (wire_bytes[i]) pkt_bytes[i] = wire_bytes[i];
        end else begin
            uvm_packer packer;
            packer = new();
            pkt.do_pack(packer);
            packer.get_bytes(pkt_bytes);
        end
```

下面新代码中的第 2 步与之逐字相同。

```systemverilog
    virtual task tx_submit(
        int unsigned     queue_id,
        virtio_net_hdr_t net_hdr,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        virtqueue_base   vq;
        byte unsigned    hdr_bytes[$];
        byte unsigned    pkt_bytes[];
        int unsigned     hdr_size;
        int unsigned     hdr_dma_size;
        int unsigned     pkt_size;
        int unsigned     pkt_dma_size;
        int              hdr_idx;
        int              pkt_idx;
        virtio_sg_list   sgs[2];
        virtio_sg_entry  hdr_entry;
        virtio_sg_entry  pkt_entry;
        byte             hdr_data[];
        byte             pkt_data[];
        byte unsigned    wire_bytes[$];
        virtio_dma_buffer_set dma_set;

        desc_id = '1;
        if (use_indirect &&
            !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                queue_id))
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d", queue_id), UVM_HIGH)

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: queue %0d not found", queue_id))
            return;
        end

        // 1. Pack net_hdr to bytes
        virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
        hdr_size = hdr_bytes.size();
        // PCIe Memory Read completions are DWORD based.  Keep the descriptor
        // length byte-accurate, but give the model/RC responder a DWORD-padded
        // backing allocation so a final partial DWORD never crosses an exact
        // host_mem block boundary.
        hdr_dma_size = (hdr_size + 3) & ~3;

        // 2. Get wire bytes.  packet_item.do_pack() 带 32-bit UVM 长度前缀，不是
        // 线速帧，先经 adapter 取 raw_data；其他对象保留原 do_pack 字节流。
        if (virtio_net_packet_adapter::pack(pkt, wire_bytes)) begin
            pkt_bytes = new[wire_bytes.size()];
            foreach (wire_bytes[i]) pkt_bytes[i] = wire_bytes[i];
        end else begin
            uvm_packer packer;
            packer = new();
            pkt.do_pack(packer);
            packer.get_bytes(pkt_bytes);
        end
        pkt_size = pkt_bytes.size();

        // If packet has no data from do_pack, use minimum Ethernet frame size
        if (pkt_size == 0)
            pkt_size = 64;
        // Keep the backing allocation DWORD padded after the minimum-size
        // fallback as well; otherwise an empty packet would request a
        // zero-byte host_mem allocation even though the descriptor carries
        // the 64-byte minimum frame.
        pkt_dma_size = (pkt_size + 3) & ~3;

        // 3. Allocate host_mem for hdr + data buffers.  A failed second
        //    allocation rolls back the first; nothing is mapped yet.
        dma_set = new("tx_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);
        hdr_idx = dma_set.alloc(hdr_dma_size);
        pkt_idx = (hdr_idx < 0) ? -1 : dma_set.alloc(pkt_dma_size);
        if (pkt_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
            return;
        end

        // 4. Write hdr and data to host_mem
        hdr_data = new[hdr_size];
        foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
        dma_set.write(hdr_idx, hdr_data);

        if (pkt_bytes.size() > 0) begin
            pkt_data = new[pkt_size];
            foreach (pkt_bytes[i]) pkt_data[i] = pkt_bytes[i];
            dma_set.write(pkt_idx, pkt_data);
        end

        // 5. Map through IOMMU (DMA_TO_DEVICE -- device reads these buffers)
        if (!dma_set.map(hdr_idx, DMA_TO_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map header for queue %0d", queue_id))
            return;
        end
        if (!dma_set.map(pkt_idx, DMA_TO_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map payload for queue %0d", queue_id))
            return;
        end

        // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]
        hdr_entry.addr = dma_set.get_iova(hdr_idx);
        hdr_entry.len  = hdr_size;
        sgs[0].entries.push_back(hdr_entry);

        pkt_entry.addr = dma_set.get_iova(pkt_idx);
        pkt_entry.len  = pkt_size;
        sgs[1].entries.push_back(pkt_entry);

        // 7. Add buffers to virtqueue (n_out=2, n_in=0).  The data buffers
        //    belong to this operation, not to add_buf(); a rejected chain
        //    rolls back and never reaches the completion map or notify path.
        desc_id = vq.add_buf(sgs, 2, 0, pkt, use_indirect);
        if (desc_id == '1) begin
            dma_set.release_all();
            return;
        end

        // Hand both ownership records (hdr first, matching tx_complete's
        // two-per-packet retirement) to completion/reset before notifying.
        if (!tx_dma_map.exists(queue_id))
            tx_dma_map[queue_id] = {};
        adopt_dma_set(dma_set, tx_dma_map[queue_id]);

        // 8. Kick if device needs notification
        if (vq.needs_notification())
            kick_with_fault(vq, queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d desc_id=%0d hdr_iova=0x%016h pkt_iova=0x%016h",
                      queue_id, desc_id, hdr_entry.addr, pkt_entry.addr), UVM_HIGH)
    endtask
```

- [ ] **Step 3: 替换 `rx_refill`**

用下面的任务替换从 `virtual task rx_refill(` 开始、到对应 `endtask` 为止的内容（HEAD :1140-1230）。P0-5 Step 4 之后，这段的开头（old，即 P0 结果）如下，本任务原样保留：

```systemverilog
    // buf_size 为描述符可写长度（含 virtio-net header）；0 表示默认 header+1514，
    // dataplane 引擎传入其配置容量。所有覆写须保持同一签名。
    virtual task rx_refill(
        int unsigned     queue_id,
        int unsigned     num_bufs,
        int unsigned     buf_size = 0
    );
        virtqueue_base   vq;
        int unsigned     buf_dma_size;
        int unsigned     hdr_size;
        int unsigned     filled = 0;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        // Determine buffer size based on header size + typical MTU
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        // Use reasonable default: header + 1514 (standard Ethernet MTU)
        if (buf_size == 0)
            buf_size = hdr_size + 1514;
        buf_dma_size = (buf_size + 3) & ~3;
```

new：

```systemverilog
    // buf_size 为描述符可写长度（含 virtio-net header）；0 表示默认 header+1514，
    // dataplane 引擎传入其配置容量。所有覆写须保持同一签名。
    virtual task rx_refill(
        int unsigned     queue_id,
        int unsigned     num_bufs,
        int unsigned     buf_size = 0
    );
        virtqueue_base   vq;
        int unsigned     buf_dma_size;
        int unsigned     hdr_size;
        int unsigned     filled = 0;
        virtio_dma_buffer_set dma_set;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        // Determine buffer size based on header size + typical MTU
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        // Use reasonable default: header + 1514 (standard Ethernet MTU)
        if (buf_size == 0)
            buf_size = hdr_size + 1514;
        buf_dma_size = (buf_size + 3) & ~3;

        // 每个 buffer 是一次独立提交：成功后所有权转入 rx_dma_map，集合清空复用。
        dma_set = new("rx_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);

        while (filled < num_bufs && vq.get_free_count() > 0) begin
            int              buf_idx;
            virtio_sg_list   sgs[1];
            virtio_sg_entry  buf_entry;
            int unsigned     result;

            // Allocate RX buffer from host memory
            buf_idx = dma_set.alloc(buf_dma_size);
            if (buf_idx < 0) begin
                `uvm_warning("ATOMIC_OPS",
                    $sformatf("rx_refill: host_mem alloc failed at buffer %0d", filled))
                break;
            end

            // Zero-fill the buffer
            dma_set.fill(buf_idx, 8'h00);

            // Map through IOMMU (DMA_FROM_DEVICE -- device writes to this buffer)
            if (!dma_set.map(buf_idx, DMA_FROM_DEVICE)) begin
                dma_set.release_all();
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "rx_refill: failed to map buffer %0d for queue %0d",
                    filled, queue_id))
                break;
            end

            // Build sg: single device-writable buffer (n_out=0, n_in=1)
            buf_entry.addr = dma_set.get_iova(buf_idx);
            buf_entry.len  = buf_size;
            sgs[0].entries.push_back(buf_entry);

            result = vq.add_buf(sgs, 0, 1, null, 0);
            if (result == '1) begin
                dma_set.release_all();
                break;
            end

            // Track the complete DMA ownership pair for completion/reset.
            if (!rx_dma_map.exists(queue_id))
                rx_dma_map[queue_id] = {};
            adopt_dma_set(dma_set, rx_dma_map[queue_id]);
            filled++;
        end

        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification())
            kick_with_fault(vq, queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("rx_refill: queue_id=%0d filled=%0d/%0d", queue_id, filled, num_bufs),
            UVM_HIGH)
    endtask
```

注：`dma_set` 在循环中复用。每轮结束时，它要么经 `adopt_dma_set` 清空，要么在 `release_all` 后 `break`，所以每轮开始时 `buf_idx` 都是 0。

- [ ] **Step 4: 用 grep 证明**

```bash
grep -nE "dma_record\.|tx_dma_map\[queue_id\]\.pop_back|rx_dma_map\[queue_id\]\.pop_back|mem\.free\((hdr|pkt|buf)_gpa\)" virtio_net_vip/src/agent/virtio_atomic_ops.sv
```

预期无输出，说明 `tx_submit/rx_refill` 中手写的登记与回滚代码已全部删除。

- [ ] **Step 5: SYNC 并运行受影响的测试**

用 ONE TEST 命令依次运行 `virtio_indirect_desc_test`、`virtio_unit_test`、`virtio_stress_unit_test`、`virtio_migration_dirty_test`、`virtio_pf_lifecycle_reset_test`、`virtio_traffic_test`、`virtio_dual_test`、`virtio_net_packet_multi_queue_test`、`virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`、`dpu_priv_driver_flow_test`、`dpu_priv_ring_contract_test`。预期全部为 0 WARNING/ERROR/FATAL。

- [ ] **Step 6: 全量回归**

预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 7: 提交**

```bash
git add virtio_net_vip/src/agent/virtio_atomic_ops.sv
git commit -m "refactor: tx_submit/rx_refill 改用 virtio_dma_buffer_set 管理分配映射与回滚"
```

---

### Task P2-3d: admin_vq_submit / ctrl_send 改用 virtio_dma_buffer_set

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`：整体替换 `admin_vq_submit`（HEAD :1341-1615）和 `ctrl_send`（HEAD :1630-1782）。
- Test:
  - `virtio_admin_vq_test`：覆盖分配失败、映射失败、拒绝、超时、复位失败后隔离等路径
  - `virtio_pf_lifecycle_reset_test`、`virtio_dual_test`、`virtio_traffic_test`、`virtio_e2e_test`、`virtio_full_integration_test`、`virtio_dut_caps_test`
  - `virtio_ctrl_vq_test`（P0-2/P0-3 新增：control VQ 编号，以及 `ctrl_send` 分配/映射失败回滚）

**Interfaces:**
- Consumes：P2-3a 的 `kick_with_fault(vq, qid, via)`；P2-3b 的 `virtio_dma_buffer_set`（含 `quarantine_into`）；`virtio_admin_vq_context` 的 `quarantined_iovas/quarantined_gpas/dma_quarantined`（types :510-511，不改）。
- Produces：无新接口。

**Spec deviation / 行为说明：**
1. **释放顺序统一为添加顺序。**
   - 原来：Admin VQ 先 unmap/free response，再处理 request；`ctrl_send` 按 hdr、data、ack 的顺序释放，而分配顺序是 hdr、ack、data。
   - 现在：Admin 先 request 后 response；ctrl 按 hdr、ack、data。Admin 隔离列表中的顺序也随之变为 request 在前。
   - 没有可观察的差异：
     - `host_mem_manager::free` 的 buddy 和 linear 合并结果与释放顺序无关，只有 history 的记录顺序不同；
     - `unmap_in_domain` 只删除键并追加 `unmap_history`；
     - PF manager（`virtio_pf_manager.sv:289-298`）按列表逐个回收；
     - 测试只检查隔离列表的长度（`virtio_admin_vq_test.sv:1443-1444,1542`）。
2. **错误 ID 和消息文本不变。**
   - Admin：报告 ID 与消息和 HEAD 逐字一致。`virtio_admin_vq_test.sv:1253-1254` 中的 catcher 匹配的是 `"admin_vq_submit: queue 7 rejected"`。
   - `ctrl_send`：保持 P0-3 的失败契约不变（P0-3 Interfaces）。任何分配或映射失败时，都设置 `ack = VIRTIO_NET_CTRL_ACK_ERR`，报 `ATOMIC_OPS` 错误，并释放已分配和已映射的全部资源，不入队、不通知。错误消息逐字保留：
     - `ctrl_send: host_mem alloc failed for control header`
     - `ctrl_send: host_mem alloc failed for control ack`
     - `ctrl_send: host_mem alloc failed for control data`
     - `ctrl_send: failed to map control buffers`
   - `virtio_ctrl_vq_test` 的两个 P0-3 子测试会验证这一契约：
     - 16B ops 内存下，ack 分配失败。预期捕获 2 条错误（`HOST_MEM` 加上 `*ctrl_send: host_mem alloc failed*`），无残留分配和映射，`kick_count==0`。
     - 第 2 次映射失败（即 data 映射失败）。预期捕获 1 条错误（`*ctrl_send: failed to map control buffers*`），header 映射已撤销，ack 从未被映射。下文代码中三次 `map` 用 `||` 短路串联，因此满足这一条。
3. **新增 `add_buf` 拒绝检查。** P0 integrator notes 说明 `ctrl_send` 的 `add_buf` 失败仍未检查，可以在 P2.3 一并处理，本任务加上这项检查：拒绝时报 `ATOMIC_OPS` 错误 `ctrl_send: control queue %0d rejected descriptor chain`，返回 ERR 并回滚，不再 kick，也不再轮询到超时。行为变化只出现在队列已满的错误场景，没有维护测试覆盖这一路径（已 grep `virtio_net_vip/tests`，没有 control 队列满的用例）。
4. **control VQ 编号查找保持不变。** P0-2 只修改了 `setup_all_queues` 中 control VQ 的建立位置，没有改 `ctrl_send` 的 `// Find control queue` 段（按 `ring_iovas` 取最大队列号）。该段在下文中与 HEAD 逐字相同。

- [ ] **Step 1: 替换 `admin_vq_submit`**

用下面的任务替换从 `virtual task admin_vq_submit(` 到对应 `endtask` 的内容（HEAD :1341-1615）：

```systemverilog
    virtual task admin_vq_submit(
        virtio_admin_vq_context admin_context,
        byte unsigned           cmd_data[],
        ref byte unsigned       result[],
        ref bit                 ok,
        input bit               lock_already_held = 0
    );
        virtio_dma_buffer_set dma_set;
        int              request_idx;
        int              response_idx;
        bit              submitted;
        bit              completion_seen;
        bit              reset_required;
        bit              reset_complete;
        int unsigned     desc_id;
        int unsigned     used_len;
        int unsigned     max_polls;
        int unsigned     poll_count;
        int unsigned     poll_interval;
        int unsigned     effective_timeout;
        int unsigned     response_len;
        longint unsigned poll_quotient;
        uvm_object       completed_token;
        uvm_object       detached_tokens[$];
        virtio_sg_list   sgs[];
        virtio_sg_entry  entry;
        byte             write_buf[];
        byte             response_buf[];

        ok = 0;
        result = new[0];
        submitted = 0;
        completion_seen = 0;
        reset_required = 0;
        reset_complete = 0;
        dma_set = new("admin_vq_dma");

        if (admin_context == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: null Admin VQ context")
            return;
        end
        if (admin_context.submit_lock == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ context has no submission lock")
            return;
        end

        if (!lock_already_held)
            admin_context.submit_lock.get(1);
        begin : admin_vq_submit_locked
        do begin
        // The PF manager validates before calling this helper.  Repeat the
        // context checks while holding the shared-VQ lock: a prior command
        // may have performed recovery while this caller waited for ownership.
        if ((admin_context.vq == null) ||
            (admin_context.transport == null) || (admin_context.mem == null) ||
            (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
            (admin_context.response_capacity == 0) || !admin_context.configured ||
            !admin_context.special_vq_lease_valid || admin_context.special_vq_lease.frozen ||
            !admin_context.negotiated_features[VIRTIO_F_ADMIN_VQ]) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: incomplete Admin VQ context")
            break;
        end
        // This public helper may be called without virtio_pf_manager.  Once
        // it owns the submission lock, confirm that descriptors, DMA, and
        // notification still address one VQ/requester/memory/IOMMU binding.
        // Reject before allocation or any queue/device-visible side effect.
        if ((admin_context.queue_id != admin_context.vq.queue_id) ||
            (admin_context.vq.host_id !=
                admin_context.transport.iommu_host_id()) ||
            (admin_context.vq.bdf != admin_context.transport.bdf) ||
            (admin_context.vq.mem != admin_context.mem) ||
            (admin_context.vq.iommu != admin_context.iommu)) begin
            `uvm_error("ATOMIC_OPS",
                "admin_vq_submit: Admin VQ binding is inconsistent")
            break;
        end
        if (admin_context.full_reset_owner == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ has no PF lifecycle reset owner")
            break;
        end
        if (admin_context.recovery_required || admin_context.dma_quarantined) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ requires verified recovery")
            break;
        end
        if (cmd_data.size() == 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: empty Admin VQ request")
            break;
        end

        dma_set.bind_domain(admin_context.mem, admin_context.iommu,
                            get_iommu_host_id(admin_context.transport),
                            admin_context.transport.bdf);
        request_idx = dma_set.alloc(cmd_data.size());
        if (request_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request allocation failed")
            break;
        end
        response_idx = dma_set.alloc(admin_context.response_capacity);
        if (response_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: response allocation failed")
            break;
        end

        write_buf = new[cmd_data.size()];
        foreach (cmd_data[index])
            write_buf[index] = cmd_data[index];
        dma_set.write(request_idx, write_buf);
        dma_set.fill(response_idx, 8'hFF);

        if (!dma_set.map(request_idx, DMA_TO_DEVICE)) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request DMA map failed")
            break;
        end
        if (!dma_set.map(response_idx, DMA_FROM_DEVICE)) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: response DMA map failed")
            break;
        end

        sgs = new[2];
        entry.addr = dma_set.get_iova(request_idx);
        entry.len = cmd_data.size();
        entry.is_indirect = 0;
        sgs[0].entries.push_back(entry);
        entry.addr = dma_set.get_iova(response_idx);
        entry.len = admin_context.response_capacity;
        entry.is_indirect = 0;
        sgs[1].entries.push_back(entry);

        desc_id = admin_context.vq.add_buf(sgs, 1, 1, null, 0);
        if (desc_id == '1) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: queue %0d rejected Admin VQ descriptor chain",
                admin_context.queue_id))
            break;
        end

        submitted = 1;
        kick_with_fault(admin_context.vq, admin_context.queue_id,
                        admin_context.transport);

        // Both timeout and interval derive from the shared wait policy;
        // there is no operation-specific arbitrary delay here.
        effective_timeout = admin_context.wait_pol.effective_timeout(
            admin_context.wait_pol.default_timeout_ns
        );
        poll_interval = admin_context.wait_pol.default_poll_interval_ns;
        if (poll_interval == 0)
            poll_interval = 1;
        // Cap the widened quotient before adding one.  A saturated
        // UINT_MAX timeout with interval one must not wrap its poll count
        // to zero.
        poll_quotient = effective_timeout / poll_interval;
        if (poll_quotient >= admin_context.wait_pol.max_poll_attempts)
            max_polls = admin_context.wait_pol.max_poll_attempts;
        else
            max_polls = poll_quotient + 1;
        poll_count = 0;

        while (poll_count < max_polls) begin
            if (admin_context.vq.poll_used(completed_token, used_len)) begin
                completion_seen = 1;
                break;
            end
            poll_count++;
            if (poll_count < max_polls)
                #(poll_interval * 1ns);
        end

        if (!completion_seen) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: timeout waiting for Admin VQ %0d completion after %0dns",
                admin_context.queue_id, effective_timeout))
            reset_required = 1;
        end else if ((used_len == 0) || (used_len > admin_context.response_capacity)) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "admin_vq_submit: invalid Admin VQ response length %0d (capacity=%0d)",
                used_len, admin_context.response_capacity))
            reset_required = 1;
        end else begin
            response_len = used_len - 1;
            admin_context.mem.read_mem(dma_set.get_gpa(response_idx), used_len, response_buf);
            result = new[response_len];
            foreach (result[index])
                result[index] = response_buf[index + 1];
            if (response_buf[0] != VIRTIO_NET_OK) begin
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "admin_vq_submit: device rejected Admin VQ request with status 0x%02h",
                    response_buf[0]))
            end else begin
                ok = 1;
            end
        end
        end while (0);

        // A rejected add_buf() owns no descriptor.  For an accepted request
        // that timed out or returned malformed completion data, reset before
        // releasing its software ownership or DMA buffers: a late completion
        // must not DMA into memory we are about to free.  Q_RESET is valid
        // only when VIRTIO_F_RING_RESET was negotiated; Admin VQ alone does
        // not imply that feature, so otherwise reset the whole device.
        if (submitted && reset_required) begin
            if (admin_context.negotiated_features[VIRTIO_F_RING_RESET])
                admin_context.transport.write_queue_reset_verified(
                    admin_context.queue_id, reset_complete
                );
            else
                admin_context.full_reset_owner.reset_pf_lifecycle(reset_complete);
            admin_context.configured = 0;
            admin_context.recovery_required = 1;
            if (reset_complete) begin
                admin_context.vq.detach_all_unused(detached_tokens);
                admin_context.vq.reset_queue();
                admin_context.vq.alloc_rings();
            end else begin
                admin_context.dma_quarantined = 1;
                dma_set.quarantine_into(admin_context.quarantined_iovas,
                                        admin_context.quarantined_gpas);
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "admin_vq_submit: Admin VQ %0d reset did not complete; DMA is quarantined",
                    admin_context.queue_id))
            end
        end

        // 未隔离时（各失败路径、正常完成、已确认复位）统一释放本次缓冲；
        // 隔离后集合已为空，这里是空操作。
        dma_set.release_all();
        end : admin_vq_submit_locked
        if (!lock_already_held)
            admin_context.submit_lock.put(1);
    endtask
```

结构说明：
- HEAD 中嵌套的 `if/else` 改成了 `do ... while (0)` 内的 `break`，每个分支的执行条件不变。
- 删除的局部变量：`request_gpa/response_gpa/request_iova/response_iova/request_allocated/response_allocated/request_mapped/response_mapped/release_safe`。
- `release_safe` 原来的作用是“隔离时不释放”，现在由 `quarantine_into` 清空集合来实现。

- [ ] **Step 2: 替换 `ctrl_send`**

用下面的 task 替换 `virtual task ctrl_send(` 到对应 `endtask` 之间的全部内容。替换范围在 HEAD 上是 :1630-1782；P0-3 之后行号会变，以锚点为准。

old（P0-3 Step 3 之后的分配段和映射段，下面称“P0 结果”）：

```systemverilog
        // 2. Allocate host_mem for hdr, data, and ack.  每次失败都回滚本次已分配
        // 的缓冲；此时尚无映射和描述符引用它们，直接 free 即可。
        hdr_gpa = mem.alloc(2, .align(1));
        if (hdr_gpa == '1) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control header")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end
        ack_gpa = mem.alloc(1, .align(1));
        if (ack_gpa == '1) begin
            mem.free(hdr_gpa);
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control ack")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end

        write_buf = new[2];
        write_buf[0] = hdr_buf[0];
        write_buf[1] = hdr_buf[1];
        mem.write_mem(hdr_gpa, write_buf);

        data_alloc_size = (data.size() > 0) ? data.size() : 1;
        data_gpa = mem.alloc(data_alloc_size, .align(1));
        if (data_gpa == '1) begin
            mem.free(hdr_gpa);
            mem.free(ack_gpa);
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control data")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end
        ...
        // 3. Map through IOMMU.  任一映射失败即停止后续映射，撤销已成功的映射并
        // 释放三块缓冲；描述符尚未发布，设备不可能访问这些 IOVA。
        data_iova = '1;
        ack_iova  = '1;
        hdr_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, hdr_gpa, 2, DMA_TO_DEVICE);
        if ((hdr_iova != '1) && (hdr_iova != 0))
            data_iova = iommu.map_for_host(get_iommu_host_id(transport),
                transport.bdf, data_gpa, data_alloc_size, DMA_TO_DEVICE);
        if ((data_iova != '1) && (data_iova != 0))
            ack_iova  = iommu.map_for_host(get_iommu_host_id(transport),
                transport.bdf, ack_gpa, 1, DMA_FROM_DEVICE);
        if ((ack_iova == '1) || (ack_iova == 0)) begin
            if ((hdr_iova != '1) && (hdr_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, hdr_iova);
            if ((data_iova != '1) && (data_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, data_iova);
            mem.free(hdr_gpa);
            mem.free(data_gpa);
            mem.free(ack_gpa);
            `uvm_error("ATOMIC_OPS", "ctrl_send: failed to map control buffers")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end
```

新代码与 P0 结果保持以下一致：
- 分配顺序：header → ack → data。
- 映射顺序：hdr → data → ack，任一步失败即停止后续映射。
- 4 条错误消息逐字相同。
- 失败时返回 ERR，回滚已分配/已映射的资源，不入队、不通知。

区别只有回滚的执行者：现在由 `virtio_dma_buffer_set` 完成。在 header 分配之后、ack/data 分配之前，P0 结果会先写 header；新代码把这次写入移到三块都分配成功之后。写入不影响分配，所以没有可观察的差异。

```systemverilog
    virtual task ctrl_send(
        virtio_ctrl_class_e  ctrl_class,
        bit [7:0]            cmd,
        byte unsigned        data[],
        ref virtio_ctrl_ack_e ack
    );
        virtqueue_base   ctrl_vq;
        int unsigned     ctrl_qid;
        byte unsigned    hdr_buf[2];
        virtio_dma_buffer_set dma_set;
        int              hdr_idx;
        int              ack_idx;
        int              data_idx;
        virtio_sg_list   sgs[3];
        virtio_sg_entry  entry;
        int unsigned     result;
        uvm_object       token;
        int unsigned     used_len;
        byte             ack_readback[];
        byte             write_buf[];
        bit              got_used;
        int unsigned     data_alloc_size;

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h data_len=%0d",
                      ctrl_class.name(), cmd, data.size()), UVM_MEDIUM)

        // 所有失败路径都返回 ERR；只有读到设备写回的 OK 才改为 OK。
        ack = VIRTIO_NET_CTRL_ACK_ERR;

        // Find control queue (highest queue ID among managed queues)
        ctrl_qid = 0;
        begin
            int unsigned max_qid = 0;
            foreach (ring_iovas[qid]) begin
                if (qid > max_qid) max_qid = qid;
            end
            ctrl_qid = max_qid;
        end

        ctrl_vq = vq_mgr.get_queue(ctrl_qid);
        if (ctrl_vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("ctrl_send: control queue %0d not found", ctrl_qid))
            return;
        end

        // 1. Build ctrl header: {class[7:0], cmd[7:0]}
        hdr_buf[0] = ctrl_class;
        hdr_buf[1] = cmd;

        // 2. Allocate host_mem in the original hdr -> ack -> data order.  每次
        // 失败都回滚本次已分配的缓冲（尚无映射和描述符引用它们）。
        data_alloc_size = (data.size() > 0) ? data.size() : 1;
        dma_set = new("ctrl_dma");
        dma_set.bind_domain(mem, iommu, get_iommu_host_id(transport), transport.bdf);
        hdr_idx = dma_set.alloc(2);
        if (hdr_idx < 0) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control header")
            return;
        end
        ack_idx = dma_set.alloc(1);
        if (ack_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control ack")
            return;
        end
        data_idx = dma_set.alloc(data_alloc_size);
        if (data_idx < 0) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: host_mem alloc failed for control data")
            return;
        end

        write_buf = new[2];
        write_buf[0] = hdr_buf[0];
        write_buf[1] = hdr_buf[1];
        dma_set.write(hdr_idx, write_buf);

        if (data.size() > 0) begin
            write_buf = new[data.size()];
            foreach (data[i]) write_buf[i] = data[i];
            dma_set.write(data_idx, write_buf);
        end

        // Initialize ack to 0xFF (invalid)
        write_buf = new[1];
        write_buf[0] = 8'hFF;
        dma_set.write(ack_idx, write_buf);

        // 3. Map through IOMMU in the original hdr -> data -> ack order.  `||`
        // 短路：任一映射失败即停止后续映射，撤销已成功的映射并释放三块缓冲；
        // 描述符尚未发布，设备不可能访问这些 IOVA。
        if (!dma_set.map(hdr_idx, DMA_TO_DEVICE) ||
            !dma_set.map(data_idx, DMA_TO_DEVICE) ||
            !dma_set.map(ack_idx, DMA_FROM_DEVICE)) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", "ctrl_send: failed to map control buffers")
            return;
        end

        // 4. Build scatter-gather: [hdr(out)] [data(out)] [ack(in)]
        entry.addr = dma_set.get_iova(hdr_idx);
        entry.len  = 2;
        sgs[0].entries.push_back(entry);

        entry.addr = dma_set.get_iova(data_idx);
        entry.len  = data_alloc_size;
        sgs[1].entries.push_back(entry);

        entry.addr = dma_set.get_iova(ack_idx);
        entry.len  = 1;
        sgs[2].entries.push_back(entry);

        // 5. Add to control queue (n_out=2, n_in=1); a rejected chain owns
        //    no descriptor, so roll back without notifying.
        result = ctrl_vq.add_buf(sgs, 2, 1, null, 0);
        if (result == '1) begin
            dma_set.release_all();
            `uvm_error("ATOMIC_OPS", $sformatf(
                "ctrl_send: control queue %0d rejected descriptor chain", ctrl_qid))
            return;
        end

        // 6. Kick control queue
        if (ctrl_vq.needs_notification())
            kick_with_fault(ctrl_vq, ctrl_qid);

        // 7. Poll used ring until ack buffer is filled
        got_used = 0;
        begin
            int unsigned poll_count = 0;
            int unsigned max_polls;
            int unsigned interval = wait_pol.default_poll_interval_ns;

            max_polls = wait_pol.effective_timeout(wait_pol.default_timeout_ns) /
                        ((interval > 0) ? interval : 1) + 1;
            if (max_polls > wait_pol.max_poll_attempts)
                max_polls = wait_pol.max_poll_attempts;

            while (poll_count < max_polls) begin
                if (ctrl_vq.poll_used(token, used_len)) begin
                    got_used = 1;
                    break;
                end
                #(interval * 1ns);
                poll_count++;
            end
        end

        if (!got_used) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: timeout waiting for control VQ completion")
        end else begin
            // 8. Read ack status from host_mem
            mem.read_mem(dma_set.get_gpa(ack_idx), 1, ack_readback);
            if (ack_readback[0] == VIRTIO_NET_OK)
                ack = VIRTIO_NET_CTRL_ACK_OK;
        end

        // Cleanup IOMMU mappings and host memory
        dma_set.release_all();

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h ack=%s",
                      ctrl_class.name(), cmd, ack.name()), UVM_MEDIUM)
    endtask
```

等价性说明：
- `ack` 的最终值不变。HEAD 只在 queue 不存在、超时或读回非 OK 时赋 `ack = ERR`；现在入口处统一预置 ERR，只在读到 OK 时改成 OK，每条路径的最终值都与原来相同。
- 超时路径与 HEAD 一样，不复位就直接释放缓冲。这是 HEAD 的既有行为，不在本任务范围内。

- [ ] **Step 3: 用 grep 证明**

```bash
grep -nE "request_gpa|response_gpa|request_mapped|response_mapped|release_safe|hdr_gpa|ack_gpa|data_gpa|hdr_iova|ack_iova|data_iova" virtio_net_vip/src/agent/virtio_atomic_ops.sv
grep -n "mem\.alloc(\|map_for_host(" virtio_net_vip/src/agent/virtio_atomic_ops.sv
```

预期：
- 第一条无输出。
- 第二条只剩迁移相关函数（`materialize_migration_mapping` 等，HEAD :130-197）中的调用；`tx_submit/rx_refill/admin_vq_submit/ctrl_send` 中不再出现。

- [ ] **Step 4: SYNC 并运行受影响的测试**

用 ONE TEST 命令依次运行 `virtio_admin_vq_test`、`virtio_pf_lifecycle_reset_test`、`virtio_dual_test`、`virtio_traffic_test`、`virtio_e2e_test`、`virtio_full_integration_test`、`virtio_dut_caps_test`，`virtio_ctrl_vq_test`、`virtio_net_packet_multi_queue_test`。预期全部为 0 WARNING/ERROR/FATAL。

- [ ] **Step 5: 全量回归**

预期 `STRICT_REGRESSION PASS tests=40`。

- [ ] **Step 6: 提交**

```bash
git add virtio_net_vip/src/agent/virtio_atomic_ops.sv
git commit -m "refactor: admin_vq_submit/ctrl_send 改用 virtio_dma_buffer_set，隔离与回滚统一由集合完成"
```

---

### Notes for integrator（P2a）

**本部分产出、供其他阶段使用的接口**
- `virtio_dma_buffer_set`（`src/agent/virtio_dma_buffer_set.sv`）
  - pkg 中的位置：排在 `virtio_atomic_ops.sv` 之前。
  - 方法：`bind_domain/alloc/write/fill/map/get_gpa/get_iova/count/get_host_id/get_bdf/release_all/disown/quarantine_into`。
  - P3 把 atomic ops 拆成多个 include 片段后，这个文件仍须排在所有片段之前。
  - `dpu_priv_atomic_ops` 的 `tx_submit/rx_refill` 仍是手写回滚，可作为后续去重点，本部分没有改动。
- `virtio_atomic_ops`
  - `protected task kick_with_fault(virtqueue_base vq, int unsigned qid, virtio_pci_transport via = null)`
  - `protected function void adopt_dma_set(virtio_dma_buffer_set, ref normal_dma_record_t records[$])`
  - P3 的 `virtio_driver_protocol.kick`，其标准实现可以委托给 `kick_with_fault`。
- `virtqueue_base`
  - 新增成员：`protected string log_tag`、`release_queue_ownership()`、`clear_op_counters()`、`fill_snapshot_header(last_avail, last_used, avail_wrap, used_wrap, ref snap)`。
  - 以下方法改为非纯虚：`kick()`、`dma_map_buf()`、`dma_unmap_buf()`、`inject_desc_error()`、`detach_all_unused()`。
  - P2.8 的 `virtio_vq_test_kit` 可以直接依赖这些实现。
- dataplane
  - `virtio_tx_engine`/`virtio_rx_engine`：外部引用只剩 `ops`、`offload`，以及给 fabric 断言用的 `host_id/bdf`。
  - `virtio_net_dataplane::configure` 去掉了 `vq_mgr/hmem/iommu_mdl` 三个形参。P2.8 test kit 构造 dataplane 时，按 `configure(features, mtu, mss, rx_mode, rx_buf_sz, refill_thresh, bdf[, host_id])` 加 `bind_ops(ops)` 的方式调用。
  - 已删除：`dpu_priv_dataplane.sv`（两个私有引擎）和 `virtio_net_dataplane.cleanup_all()`。
  - `dpu_priv_atomic_ops` 新增 `rx_receive_frames` 覆写，`rx_receive` 改为基于它实现。
  - P2.5（统一 function instance 的绑定入口）修改 `commit_validated_pcie_components` 时，必须保留 P2-1 Step 5c 写入的 dataplane 装配块。该块负责：设置私有 rx `buf_size/refill_threshold`、注入 `offload`、设置 `host_id/bdf`、调用 `bind_ops(ops)`。

**依赖的 P0 接口（已对照 P0.md 核实，P2-1 Step 1 用 grep 复核）**
- `virtio_net_dataplane::bind_ops(virtio_atomic_ops)`。
- `static function void virtio_net_hdr_util::build_tx_hdr(input byte unsigned pkt_data[$], input bit [63:0] features, input virtio_offload_engine offload, output virtio_net_hdr_t hdr)`。include 顺序问题由 P0 在 `virtio_net_hdr.sv` 顶部用 `typedef class virtio_offload_engine;` 解决。
- `rx_refill(int unsigned queue_id, int unsigned num_bufs, int unsigned buf_size = 0)`。P2-3c 原样保留这一签名和 `if (buf_size == 0)` 默认值逻辑；之后新增的覆写也必须带第三个参数。
- `rx_receive_frames(int unsigned queue_id, int unsigned max_budget, ref virtio_rx_frame_t frames[$])` 与 `virtio_rx_frame_t`。
- P0-4 中 `tx_submit` 对线速字节的修正（经 packet adapter 去掉 UVM 长度前缀）：P2-3c 逐字保留。
- P0-3 中 `ctrl_send` 的失败契约和 4 条错误消息：P2-3d 逐字保留，由 `virtio_ctrl_vq_test` 验证。
- P0-2 只修改了 `setup_all_queues` 的 control VQ 编号；`ctrl_send` 的查找段没有变化，P2-3d 也保持原样。
- 与 P1 的边界：P1-3 删除 `custom_cb/custom_receive`（以及 `submit_single` 中的 custom 分支）；P1-8 删除 `receive_big/receive_small/receive_single_buf/RX_MODE_BIG/SMALL`，并把 `get_rx_buf_size` 改为恒返回 `buf_size`。P2-1 的删除清单已经去掉这些项。

**排序依赖**
- 执行顺序：P0 → P1 → P2。
- P2-1 依赖 P0-4、P0-5、P1-3、P1-8（Step 1 用 grep 核对）。
- P2-2a/b 不依赖 P0/P1 的语义改动，可以与 P2-1 互换顺序。
- P2-3a → P2-3b → P2-3c → P2-3d 必须按顺序执行，因为 c/d 的整函数替换中已经用到 `kick_with_fault` 和 `adopt_dma_set`。
- P3 拆分 `virtio_atomic_ops` 文件，必须安排在 P2-3d 之后。
- 回归数量按 P0 之后的 manifest 计，为 40 项。

**风险**
- P2-1 删除 `dpu_priv_dataplane.sv` 之后，私有 Function 的 dataplane 改走基类引擎和私有 ops，依赖以下三个条件：
  - 私有 ops 覆写 `rx_receive_frames`（Step 2）。
  - 装配时 `offload` 非空且特性为 0，从而 `build_tx_hdr` 生成全零 header。
  - `refill_threshold=0`。
  任一条件被后续阶段改动（例如 P3 的 `virtio_driver_protocol` 重新设置引擎特性），私有 TX 都会被私有 ops 的 offload 检查拒绝。`dpu_priv_driver_flow_test` 覆盖这条路径。
- 在 Function 装配中补上 `tx/rx_engine.offload = dataplane.offload` 后，标准 Function 自带引擎原有的 `offload == null` 空句柄缺口随之消除。但引擎的 `negotiated_features` 仍不随 FSM 协商结果更新（HEAD 起就是如此，不属于本部分范围）。
- 私有 dataplane 的统计口径与畸形帧处理发生变化（见 P2-1 Spec deviation 1）。维护测试不读取这些统计。
- `ctrl_send` 新增 `add_buf` 拒绝检查（P2-3d deviation 3），只改变 control 队列满时的错误路径。
- Admin/ctrl 的 unmap/free 顺序调整为添加顺序（P2-3d），只影响 host_mem history 和 IOMMU unmap_history 的记录顺序，没有测试读取。

**Spec deviations 汇总**
1. P2.1
   - 整个删除 `dpu_priv_dataplane.sv`，私有 Function 只换注入的 ops，不再“简化覆写”。
   - 私有 ops 新增 `rx_receive_frames`。
   - Function 装配时补上 `offload`。
   - 删除只剩写入的引擎字段 `buf_mode`、`total_rx_errors`，以及 `dataplane.cleanup_all`。
   - `configure` 去掉 3 个已无用途的形参。
   - 保留 `host_id/bdf`；`virtio_fabric_resource_test` 一行不改。
2. P2.2：split/packed 的 `kick` 日志字段名统一为同一组（UVM_HIGH 级别）。
3. P2.3
   - `kick_with_fault` 增加可选参数 `via`，供 Admin VQ 使用其上下文中的 transport。
   - buffer set 的释放顺序统一为添加顺序。
   - `ctrl_send` 补上 `add_buf` 拒绝检查。

---

## P2（下半）：绑定入口统一、snapshot 上下文、删除 transport 第二条 init 路径、测试公共件

覆盖规范 P2.4–P2.8。基线 HEAD `62ae3e9`。文中行号均为 HEAD 行号；P0/P1/P2-1~P2-3 合入后行号会整体平移，
执行时以每处给出的锚点文本为准。

前置依赖（必须先合入）：

- **P1-1** 已删除 `virtio_virtual_sequencer`、env 的 `v_seqr` 字段/创建/判空/赋值，以及 `virtio_dut_caps_test` 中全部
  `v_seqr` 引用（见 P1.md Task P1-1）。本文件的 env 新代码**不含** `v_seqr`。
- **P0-4/P0-5（= 规范 P2.1 的 TX/RX 委托）与 P2-1** 已改写 dataplane 引擎，并在 `virtio_indirect_desc_test`、
  `virtio_net_packet_multi_queue_test` 中新增 transport/ops 接线；**P0-2/P0-3** 新增 `virtio_ctrl_vq_test.sv`。
  P2-8 以这些任务合入后的文本为准（P0.md 中给出的新代码），下文明确列出要改的文本。
- **P0-1** 已把私有环两个测试纳入 manifest，`strict_regression` 已覆盖它们。

通用命令（以下步骤直接引用）：

- SYNC：`rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/`
- ONE TEST：`ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=<test_name> ./scripts/vcs.sh > logs/<test_name>.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/<test_name>.log | tail -20'`
  预期：只有 `UVM_WARNING :    0`、`UVM_ERROR :    0`、`UVM_FATAL :    0` 三行汇总，没有 `Error-` 行，也没有非零计数。
- REGRESSION：`ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'`
  预期：第一个 grep 没有输出，最后一行为 `STRICT_REGRESSION PASS tests=<N>`。
- PRIV（额外交叉检查私有环）：`ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p2b'`，预期 `flow_rc=0`、`contract_rc=0`，各项计数均为 0。

---

### Task P2-4: env 的 PCIe 绑定统一为 `bind_all(plan)`

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv:518-1112`：从注释 `// 将一个 RC sequencer 及可选 completion/monitor 绑定到全部 VIO Function。`
  开始，到 `bind_function_pcie_endpoint` 的 `endfunction` 为止，整段替换
- Test: `virtio_dut_caps_test`、`virtio_monitor_routing_test`、`virtio_e2e_test`、`virtio_pcie_host_mem_test`、`virtio_real_driver_flow_test`

**Interfaces:**
- Consumes（function instance 现有接口，P2-5 再改名）：`preflight_bind_pcie(seqr)`、
  `commit_preflight_bind_pcie(hmem, iommu, barrier, err_inj, wait_pol, seqr)`、`cancel_preflight_bind_pcie()`、
  `pending_pcie_fsm_candidate()`、`pending_pcie_ops_candidate()`；`virtio_tlm_completion_adapter::bind_registered_rc_driver()`、
  `domain_rc_driver_binding_supported()`、`bind_domain_rc_driver()`；`virtio_pci_transport::bind_pcie_endpoint(endpoint)`。
- Produces:
  - 公共签名保持不变：`function bit bind_pcie(uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr, virtio_tlm_completion_adapter tlm_adapter = null, pcie_tl_base_monitor pcie_rc_monitor = null, pcie_tl_base_monitor pcie_ep_monitor = null)`、
    `function bit bind_pcie_endpoints(virtio_pcie_function_endpoint endpoints[$])`。
  - 新增类内类型 `virtio_net_env::pcie_bind_plan_t`（struct 字段：`function_instance`、`rc_seqr`、`rc_monitor`、`ep_monitor`、`endpoint`）。
  - 新增受保护函数：`bind_all(pcie_bind_plan_t plan[$], virtio_tlm_completion_adapter legacy_adapter)`、`abort_bind(plan)`、
    `preflight_plan(plan, output staged_protocol_vifs[DPU_MAX_FUNCTIONS])`、`validate_plan_adapters(plan)`、`commit_plan_adapters(plan)`、
    `select_function_endpoint(function_index, endpoints, output selected_index)`、`function_pcie_handles_valid(fi)`、
    `resolve_protocol_vif(fi, slot_index, staged_vif, output vif)`。
  - 签名保持不变（测试子类 `virtio_dut_caps_bind_probe_env::invoke_function_pcie_bind`，dut_caps:631-639，会调用它）：
    `protected function bit bind_function_pcie(fi, seqr, rc_mon, ep_mon, inout int unsigned next_idx, input virtual virtio_protocol_event_if staged_protocol_vif = null)`；
    `protected function bit preflight_function_pcie(fi, seqr, inout next_idx, output vif)`。
  - 删除：`protected function bit bind_function_pcie_endpoint(...)`，它只被 env 自己调用。

行为保持：所有 `uvm_fatal` 的 ID 和消息文本逐字保留，dut_caps 的 catcher 依赖以下文本：
`"bind_pcie() received a null PCIe RC sequencer"`、`"bind_pcie() received a PCIe RC monitor with a null tlp_ap"`、
`"Active function indices 0 and 1 staged the same protocol event interface"`（以及 `... PCIe FSM candidate`、`... PCIe ops candidate`）、
`"No protocol event interface configured for active function %0d"`、`"Function PCIe bind requires a monitor observer"`、
`"Observer mandatory bind preflight failed for function BDF 0x%04h: ..."`。检查顺序与原实现一致：
configuration_valid → 空 sequencer → 身份与 domain → monitor tlp_ap → 逐个 Function 预检并做别名检查 → adapter 拓扑校验 → adapter 绑定 → 逐个 Function 提交。

- [ ] **Step 1: 记录基线。** SYNC 后用 ONE TEST 跑 `virtio_dut_caps_test` 和 `virtio_monitor_routing_test`，确认 P1 合入后均为 0/0/0，作为对照。

- [ ] **Step 2: 替换 env 的绑定代码。** 用下面的代码整体替换 HEAD 518-1112：

```systemverilog
    // 一个 Function 的 PCIe 绑定计划：bind_pcie 为单 domain 内全部 Function 填入
    // 同一组 RC sequencer/monitor（endpoint 为空）；bind_pcie_endpoints 为每个
    // Function 填入按完整身份选中的 endpoint，提交时额外绑定 completion adapter
    // 与 transport 的 endpoint 通路。
    typedef struct {
        virtio_function_instance      function_instance;
        uvm_sequencer #(pcie_tl_tlp)  rc_seqr;
        pcie_tl_base_monitor          rc_monitor;
        pcie_tl_base_monitor          ep_monitor;
        virtio_pcie_function_endpoint endpoint;
    } pcie_bind_plan_t;

    // 将一个 RC sequencer 及可选 completion/monitor 绑定到全部 VIO Function。
    // 本函数只负责构造单 domain 计划与入口校验，预检、回滚与提交统一由 bind_all
    // 完成；任一 Function 失败则返回 0、标记环境无效且不保留部分绑定。
    // Bind one required RC sequencer and optional TLM completion adapter to
    // all snapshot-declared VIO functions.
    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
        pcie_bind_plan_t plan[$];
        pcie_bind_plan_t entry;
        dpu_pcie_domain_key_t legacy_domain;

        if (!configuration_valid)
            return 0;
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("VIRTIO_ENV", "bind_pcie() received a null PCIe RC sequencer")
            configuration_valid = 0;
            return 0;
        end

        // 标量兼容接口只能描述一条外部 PCIe 通路：同一 domain 内可服务多个
        // Function，但不得把它静默广播到多个独立 domain。
        foreach (function_instances[function_index]) begin
            if ((function_instances[function_index] == null) ||
                !function_instances[function_index].pcie_id_valid) begin
                `uvm_fatal("VIRTIO_ENV",
                    "bind_pcie() requires snapshot-resolved PCIe identities")
                configuration_valid = 0;
                return 0;
            end
            if (function_index == 0)
                legacy_domain = function_instances[0].pcie_id.domain;
            else if (!dpu_same_domain_key(
                    legacy_domain,
                    function_instances[function_index].pcie_id.domain)) begin
                `uvm_fatal("VIRTIO_ENV",
                    {"bind_pcie() cannot bind VIO functions from multiple ",
                     "PCIe domains; use bind_pcie_endpoints()"})
                configuration_valid = 0;
                return 0;
            end
            entry.function_instance = function_instances[function_index];
            entry.rc_seqr = pcie_rc_seqr;
            entry.rc_monitor = pcie_rc_monitor;
            entry.ep_monitor = pcie_ep_monitor;
            entry.endpoint = null;
            plan.push_back(entry);
        end

        // Analysis 连接属于原子提交的一部分：在任何 Function 预检分配候选之前
        // 校验调用方给出的 monitor。
        if ((pcie_rc_monitor != null) && (pcie_rc_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe RC monitor with a null tlp_ap")
            return abort_bind(plan);
        end
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe EP monitor with a null tlp_ap")
            return abort_bind(plan);
        end
        return bind_all(plan, tlm_adapter);
    endfunction

    // 按完整 {host, segment, BDF} 为每个 snapshot Function 选择独立 endpoint，
    // 构造计划后交给 bind_all；数量、身份或预检不匹配时返回 0，且全部校验
    // 通过前不提交任何连接。
    // Bind every snapshot function to one explicitly keyed external path.
    function bit bind_pcie_endpoints(
        input virtio_pcie_function_endpoint endpoints[$]
    );
        pcie_bind_plan_t plan[$];
        pcie_bind_plan_t entry;
        bit endpoint_used[];
        int selected_index;
        string why;

        if (!configuration_valid)
            return 0;
        if (endpoints.size() != function_instances.size()) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                {"bind_pcie_endpoints() requires exactly one endpoint per ",
                 "active function: endpoints=%0d functions=%0d"},
                endpoints.size(), function_instances.size()))
            configuration_valid = 0;
            return 0;
        end

        endpoint_used = new[endpoints.size()];
        foreach (endpoints[endpoint_index]) begin
            if (endpoints[endpoint_index] == null) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "PCIe endpoint index %0d is null", endpoint_index))
                configuration_valid = 0;
                return 0;
            end
            if (!endpoints[endpoint_index].validate(why)) begin
                `uvm_fatal("VIRTIO_ENV", why)
                configuration_valid = 0;
                return 0;
            end
            for (int unsigned prior_index = 0;
                 prior_index < endpoint_index; prior_index++) begin
                if (endpoints[prior_index].matches_id(
                    endpoints[endpoint_index].pcie_id)) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "Duplicate PCIe endpoint mapping for %s",
                        dpu_pcie_function_id_name(
                            endpoints[endpoint_index].pcie_id)))
                    configuration_valid = 0;
                    return 0;
                end
            end
        end

        foreach (function_instances[function_index]) begin
            if (!select_function_endpoint(
                    function_index, endpoints, selected_index)) begin
                configuration_valid = 0;
                return 0;
            end
            endpoint_used[selected_index] = 1;
            entry.function_instance = function_instances[function_index];
            entry.endpoint = endpoints[selected_index];
            entry.rc_seqr = entry.endpoint.rc_seqr;
            entry.rc_monitor = entry.endpoint.rc_monitor;
            entry.ep_monitor = entry.endpoint.ep_monitor;
            plan.push_back(entry);
        end
        foreach (endpoint_used[endpoint_index]) begin
            if (!endpoint_used[endpoint_index]) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "PCIe endpoint %s does not map to an active function",
                    dpu_pcie_function_id_name(
                        endpoints[endpoint_index].pcie_id)))
                configuration_valid = 0;
                return 0;
            end
        end
        return bind_all(plan, null);
    endfunction

    // 为第 function_index 个 Function 选出唯一身份匹配的 endpoint，并确认其
    // transport 身份一致；失败时 UVM_FATAL 并返回 0（由调用方置环境无效）。
    protected function bit select_function_endpoint(
        input int unsigned function_index,
        input virtio_pcie_function_endpoint endpoints[$],
        output int selected_index
    );
        virtio_function_instance function_instance;
        int match_count;

        selected_index = -1;
        match_count = 0;
        function_instance = function_instances[function_index];
        if ((function_instance == null) || !function_instance.pcie_id_valid) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Active function index %0d has no resolved PCIe identity",
                function_index))
            return 0;
        end
        foreach (endpoints[endpoint_index]) begin
            if (endpoints[endpoint_index].matches_id(function_instance.pcie_id)) begin
                match_count++;
                selected_index = endpoint_index;
            end
        end
        if (match_count != 1) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "PCIe endpoint mapping count for %s is %0d, expected 1",
                dpu_pcie_function_id_name(function_instance.pcie_id),
                match_count))
            return 0;
        end
        if ((function_instance.transport == null) ||
            !function_instance.transport.pcie_id_valid ||
            !endpoints[selected_index].matches_id(
                function_instance.transport.pcie_id)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Transport identity does not match function %s",
                dpu_pcie_function_id_name(function_instance.pcie_id)))
            return 0;
        end
        return 1;
    endfunction

    // 两个公共绑定入口共用的提交路径：
    //   1) 逐个 Function 无副作用预检，拒绝共享协议接口/FSM/ops 候选；
    //   2) 校验 endpoint 的 completion adapter 与 RC driver/domain 拓扑；
    //   3) 绑定 completion adapter（标量 adapter 或按 domain 的 adapter）；
    //   4) 逐个提交 Function 与 endpoint 通路，最后发布协议接口槽位计数。
    // 任一步失败都由 abort_bind 统一回滚预检候选并标记环境无效。
    protected function bit bind_all(
        input pcie_bind_plan_t plan[$],
        input virtio_tlm_completion_adapter legacy_adapter
    );
        int unsigned next_protocol_event_vif_index;
        virtual virtio_protocol_event_if staged_protocol_vifs[DPU_MAX_FUNCTIONS];

        if (!preflight_plan(plan, staged_protocol_vifs))
            return abort_bind(plan);
        if (!validate_plan_adapters(plan))
            return abort_bind(plan);
        if ((legacy_adapter != null) &&
            !legacy_adapter.bind_registered_rc_driver())
            return abort_bind(plan);
        if (!commit_plan_adapters(plan))
            return abort_bind(plan);

        next_protocol_event_vif_index = 0;
        foreach (plan[plan_index]) begin
            if (!bind_function_pcie(
                    plan[plan_index].function_instance,
                    plan[plan_index].rc_seqr,
                    plan[plan_index].rc_monitor,
                    plan[plan_index].ep_monitor,
                    next_protocol_event_vif_index,
                    staged_protocol_vifs[plan_index]))
                return abort_bind(plan);
            // 身份匹配已在构造计划时校验；这里只安装选中的 sequencer 与 adapter。
            if ((plan[plan_index].endpoint != null) &&
                !plan[plan_index].function_instance.transport.bind_pcie_endpoint(
                    plan[plan_index].endpoint))
                return abort_bind(plan);
        end
        protocol_event_vif_index = next_protocol_event_vif_index;
        return 1;
    endfunction

    // 统一回滚：丢弃计划内所有 Function 的预检候选并标记环境无效；恒返回 0，
    // 供调用方以 `return abort_bind(plan);` 一行退出。
    protected function bit abort_bind(input pcie_bind_plan_t plan[$]);
        foreach (plan[plan_index]) begin
            if (plan[plan_index].function_instance != null)
                plan[plan_index].function_instance.cancel_preflight_bind_pcie();
        end
        configuration_valid = 0;
        return 0;
    endfunction

    // 逐个 Function 预检并暂存其协议接口；若两个 Function 暂存了同一协议接口、
    // 同一 FSM 或同一 ops 候选（会共享运行态）则 UVM_FATAL 并返回 0。
    protected function bit preflight_plan(
        input pcie_bind_plan_t plan[$],
        output virtual virtio_protocol_event_if staged_protocol_vifs[DPU_MAX_FUNCTIONS]
    );
        int unsigned next_protocol_event_vif_index;
        virtio_auto_fsm staged_fsms[$];
        virtio_atomic_ops staged_ops[$];
        string alias_name;

        next_protocol_event_vif_index = 0;
        foreach (plan[plan_index]) begin
            if (!preflight_function_pcie(
                    plan[plan_index].function_instance,
                    plan[plan_index].rc_seqr,
                    next_protocol_event_vif_index,
                    staged_protocol_vifs[plan_index]))
                return 0;
            staged_fsms.push_back(
                plan[plan_index].function_instance.pending_pcie_fsm_candidate());
            staged_ops.push_back(
                plan[plan_index].function_instance.pending_pcie_ops_candidate());
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                alias_name = "";
                if (staged_protocol_vifs[plan_index] ==
                    staged_protocol_vifs[prior_index])
                    alias_name = "protocol event interface";
                else if (staged_fsms[plan_index] == staged_fsms[prior_index])
                    alias_name = "PCIe FSM candidate";
                else if (staged_ops[plan_index] == staged_ops[prior_index])
                    alias_name = "PCIe ops candidate";
                if (alias_name != "") begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "Active function indices %0d and %0d staged the same %s",
                        prior_index, plan_index, alias_name))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 只读校验 endpoint 计划中的 completion adapter 拓扑：一个 RC driver 只能
    // 喂一个 adapter；同一 adapter 内一个 domain 只能对应一个 RC driver，一个
    // RC driver 也不能代表多个 domain。标量计划（endpoint 为空）直接通过。
    protected function bit validate_plan_adapters(input pcie_bind_plan_t plan[$]);
        virtio_pcie_function_endpoint endpoint;
        virtio_pcie_function_endpoint prior_endpoint;
        bit same_domain;
        string why;

        foreach (plan[plan_index]) begin
            endpoint = plan[plan_index].endpoint;
            if ((endpoint == null) || (endpoint.completion_adapter == null))
                continue;
            if (!endpoint.completion_adapter.domain_rc_driver_binding_supported(
                    endpoint.pcie_id.domain, endpoint.rc_driver, why)) begin
                `uvm_fatal("VIRTIO_ENV", why)
                return 0;
            end
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                prior_endpoint = plan[prior_index].endpoint;
                if ((prior_endpoint == null) ||
                    (prior_endpoint.completion_adapter == null))
                    continue;
                if ((prior_endpoint.rc_driver == endpoint.rc_driver) &&
                    (prior_endpoint.completion_adapter !=
                     endpoint.completion_adapter)) begin
                    `uvm_fatal("VIRTIO_ENV",
                        "One RC driver cannot feed distinct completion adapters")
                    return 0;
                end
                if (prior_endpoint.completion_adapter != endpoint.completion_adapter)
                    continue;
                same_domain = dpu_same_domain_key(
                    prior_endpoint.pcie_id.domain, endpoint.pcie_id.domain);
                if (same_domain && (prior_endpoint.rc_driver != endpoint.rc_driver)) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "PCIe domain %s selects distinct RC drivers",
                        dpu_pcie_domain_key_name(endpoint.pcie_id.domain)))
                    return 0;
                end
                if (!same_domain && (prior_endpoint.rc_driver == endpoint.rc_driver)) begin
                    `uvm_fatal("VIRTIO_ENV",
                        "One RC driver cannot represent distinct PCIe domains")
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 每个 (adapter, domain) 组合只绑定一次 RC driver；必须在
    // validate_plan_adapters 通过之后调用，任一绑定失败返回 0。
    protected function bit commit_plan_adapters(input pcie_bind_plan_t plan[$]);
        virtio_pcie_function_endpoint endpoint;
        bit already_bound;

        foreach (plan[plan_index]) begin
            endpoint = plan[plan_index].endpoint;
            if ((endpoint == null) || (endpoint.completion_adapter == null))
                continue;
            already_bound = 0;
            for (int unsigned prior_index = 0;
                 prior_index < plan_index; prior_index++) begin
                if ((plan[prior_index].endpoint != null) &&
                    (plan[prior_index].endpoint.completion_adapter ==
                     endpoint.completion_adapter) &&
                    dpu_same_domain_key(
                        plan[prior_index].endpoint.pcie_id.domain,
                        endpoint.pcie_id.domain))
                    already_bound = 1;
            end
            if (!already_bound &&
                !endpoint.completion_adapter.bind_domain_rc_driver(
                    endpoint.pcie_id.domain, endpoint.rc_driver))
                return 0;
        end
        return 1;
    endfunction

    // Function 绑定共用的空值检查：Function、driver agent、monitor 与 observer
    // 都必须存在；失败时 UVM_FATAL 并返回 0。
    protected function bit function_pcie_handles_valid(
        input virtio_function_instance function_instance
    );
        if ((function_instance == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.monitor == null) ||
            (function_instance.driver_agent.observer == null)) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        return 1;
    endfunction

    // 解析第 slot_index 个协议接口槽位：先确认槽位池未耗尽；staged_protocol_vif
    // 非空时沿用预检结果，否则从 config_db 读取 protocol_event_vif_<slot>。
    // 失败时 UVM_FATAL 并返回 0。
    protected function bit resolve_protocol_vif(
        input virtio_function_instance function_instance,
        input int unsigned slot_index,
        input virtual virtio_protocol_event_if staged_protocol_vif,
        output virtual virtio_protocol_event_if protocol_vif
    );
        protocol_vif = staged_protocol_vif;
        if (slot_index >= DPU_MAX_FUNCTIONS) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Protocol event interface pool exhausted at function BDF 0x%04h",
                function_instance.bdf))
            return 0;
        end
        if (protocol_vif != null)
            return 1;
        if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                null, "uvm_test_top",
                $sformatf("protocol_event_vif_%0d", slot_index), protocol_vif) ||
            (protocol_vif == null)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "No protocol event interface configured for active function %0d",
                slot_index))
            return 0;
        end
        return 1;
    endfunction

    // 预检单个 Function 所需的 observer、协议接口槽位和 FSM/ops；成功时返回 1、
    // 暂存 protocol_vif 并推进槽位索引，失败时 UVM_FATAL 且不提交任何连接。
    protected function bit preflight_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        inout int unsigned next_protocol_event_vif_index,
        output virtual virtio_protocol_event_if protocol_vif
    );
        string observer_why;

        protocol_vif = null;
        if (!function_pcie_handles_valid(function_instance))
            return 0;
        if (!function_instance.driver_agent.observer.
            preflight_mandatory_function_binding(
                function_instance.transport, observer_why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                {"Observer mandatory bind preflight failed for function ",
                 "BDF 0x%04h: %s"},
                function_instance.bdf, observer_why))
            return 0;
        end
        if (!resolve_protocol_vif(function_instance,
                next_protocol_event_vif_index, null, protocol_vif))
            return 0;
        if (!function_instance.preflight_bind_pcie(pcie_rc_seqr))
            return 0;
        next_protocol_event_vif_index++;
        return 1;
    endfunction

    // 提交一个已预检 Function 的共享内存、IOMMU、RC sequencer 和 monitor 连接；
    // 成功返回 1 并消费一个协议接口槽位，空句柄或提交失败返回 0。
    protected function bit bind_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input pcie_tl_base_monitor pcie_rc_monitor,
        input pcie_tl_base_monitor pcie_ep_monitor,
        inout int unsigned next_protocol_event_vif_index,
        input virtual virtio_protocol_event_if staged_protocol_vif = null
    );
        virtual virtio_protocol_event_if protocol_vif;

        if (!function_pcie_handles_valid(function_instance) ||
            !resolve_protocol_vif(function_instance,
                next_protocol_event_vif_index, staged_protocol_vif,
                protocol_vif))
            return 0;
        if (!function_instance.commit_preflight_bind_pcie(
            host_mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr)) begin
            return 0;
        end
        function_instance.driver_agent.observer.
            commit_mandatory_function_binding(
            function_instance.bdf, function_instance.transport);
        function_instance.driver_agent.monitor.protocol_vif = protocol_vif;
        next_protocol_event_vif_index++;
        if (pcie_rc_monitor != null)
            pcie_rc_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor != pcie_rc_monitor))
            pcie_ep_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        return 1;
    endfunction
```

- [ ] **Step 3: 用 grep 确认旧路径已全部删除。**
  `grep -n "bind_function_pcie_endpoint\|staged_pcie_fsms\|staged_pcie_ops\|legacy_domain_valid\|selected_endpoints\|v_seqr" virtio_net_vip/src/env/virtio_net_env.sv`
  预期：无输出。
  `grep -c "cancel_preflight_bind_pcie" virtio_net_vip/src/env/virtio_net_env.sv` 预期为 `1`，唯一一处在 `abort_bind` 中。

- [ ] **Step 4: SYNC 后逐个跑受影响的测试**（ONE TEST）：`virtio_dut_caps_test`、`virtio_monitor_routing_test`、`virtio_e2e_test`、
  `virtio_pcie_host_mem_test`、`virtio_real_driver_flow_test`。预期均为 0/0/0。
  若 `virtio_dut_caps_test` 报出未被 catcher 捕获的 `Active function indices ... staged the same ...`，核对 `preflight_plan` 的消息拼接是否与 Step 2 一致。

- [ ] **Step 5: 跑 REGRESSION 和 PRIV。** 预期 `STRICT_REGRESSION PASS tests=<N>`，PRIV 各项均为 0。

- [ ] **Step 6: 提交。**
  `git add virtio_net_vip/src/env/virtio_net_env.sv`
  `git commit -m "refactor: env 的 bind_pcie/bind_pcie_endpoints 统一走 bind_all 计划提交"`

---

### Task P2-5: function instance 的绑定入口统一为 preflight/commit/cancel

**Files:**
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:64-94`（`prepare_driver_candidates`）、`:212-337`（preflight/pending/cancel/commit）、
  `:339-345`（`commit_validated_pcie_components` 的头注释）、`:444-565`（删除 `bind_pcie_components`，重写 `wire_shared` 和 `bind_pcie`）
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`：P2-4 新代码中 `abort_bind`、`bind_function_pcie` 两处调用改名
- Modify: `virtio_net_vip/tests/virtio_full_test.sv:31,97-106`
- Modify: `virtio_net_vip/tests/virtio_dual_test.sv:123,135,275-281,290-296`
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv:482-530,1267-1282,2144-2150,2172-2185,2499-2546,3187,3190`
- Test: `virtio_dut_caps_test`、`virtio_full_integration_test`、`virtio_dual_test`、`virtio_real_driver_flow_test`、PRIV

调用方核查（在 HEAD 全仓 grep `bind_pcie_components\|wire_shared\|\.bind_pcie(\|commit_preflight_bind_pcie\|cancel_preflight_bind_pcie`）：

| 调用点 | 处理 |
|---|---|
| `tests/virtio_full_test.sv:101` `bind_pcie_components` | 先设置 Function 的 transport/vq_mgr/driver_agent.ops，再调 `wire_shared` |
| `tests/virtio_dual_test.sv:276,291` | 同上，A、B 各一处 |
| `tests/virtio_dut_caps_test.sv:496-513` 子类覆写了 `bind_pcie_components` | 删除该覆写和 `public_bind_count` |
| `tests/virtio_dut_caps_test.sv:2146,2178,2528` | 改为 `wire_shared` |
| `tests/virtio_dut_caps_test.sv:2577` `base_function.bind_pcie(...)` | 不变（`bind_pcie` 仍保留，消息 `function_0 is missing driver agent` 不变） |
| `tests/virtio_dut_caps_test.sv:3172,3512` `preflight_bind_pcie` | 不变 |
| `tests/virtio_dut_caps_test.sv:3187,3190` | 改名为 `cancel_bind_pcie`、`commit_bind_pcie` |
| `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv:156` `wire_shared` | 不变（签名不变） |
| `examples/virtio_system_env/virtio_system_env_example_test.sv:527,553` env 接口 | 不变 |
| `examples/dpu_priv_ring/README.md:82-83`、`docs/virtio_net_vip_manual.md:1391` 提到 `wire_shared` | 描述仍然正确，不改 |

**Interfaces:**
- Consumes: P2-4 中 env 的 `abort_bind` 和 `bind_function_pcie`。
- Produces（function instance 的公共入口，P3-4 `virtio_driver_protocol` 依赖它们）：
  - `function bit preflight_bind_pcie(input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr)`：签名不变。
  - `function bit commit_bind_pcie(input host_mem_manager hmem, input virtio_iommu_model iommu_mdl, input virtio_memory_barrier_model bar_mdl, input virtqueue_error_injector einj, input virtio_wait_policy wpol, input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr)`：由原 `commit_preflight_bind_pcie` 改名。
  - `function void cancel_bind_pcie()`：由原 `cancel_preflight_bind_pcie` 改名。
  - `function bit wire_shared(hmem, iommu_mdl, bar_mdl, einj, wpol, pcie_rc_seqr)` 与 `function bit bind_pcie(pcie_rc_seqr)`：签名不变，内部改为 preflight + commit 的包装。
  - `protected function bit prepare_driver_candidates(string label, virtio_driver_config_t behavior, ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm)`：标准与私有 ops/FSM 的唯一工厂选择点。
  - 删除：`bind_pcie_components(...)`。

- [ ] **Step 1: 把 `prepare_driver_candidates`（HEAD 64-94）改成唯一的工厂选择点。** 整段替换为：

```systemverilog
    // 根据本 Function 的配置选择并创建匹配的 ops/FSM 候选；这是 driver 工厂
    // 选择的唯一位置，不访问设备。已提供对象与私有配置类型冲突时拒绝，防止标准
    // FSM 驱动私有 ring；factory 返回空对象时 UVM_FATAL。配置仅在提交时冻结。
    protected function bit prepare_driver_candidates(
        string label, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm
    );
        dpu_priv_atomic_ops private_ops;
        dpu_priv_auto_fsm private_fsm;
        string why;
        if (private_cfg != null) begin
            if (!private_cfg.validate(behavior.num_queue_pairs, why) ||
                behavior.vq_type != VQ_CUSTOM || behavior.irq_mode != IRQ_POLLING) begin
                `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
                return 0;
            end
            if (candidate_ops == null)
                candidate_ops = dpu_priv_atomic_ops::type_id::create({label, "_ops"});
            if (candidate_fsm == null)
                candidate_fsm = dpu_priv_auto_fsm::type_id::create({label, "_fsm"});
            if (!$cast(private_ops, candidate_ops) || !$cast(private_fsm, candidate_fsm)) begin
                `uvm_error("FUNCTION_BIND", "私有配置与已绑定 ops/FSM 类型冲突")
                return 0;
            end
            return 1;
        end
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create({label, "_fsm"}, this);
        if (candidate_fsm == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned a null PCIe FSM", label))
            return 0;
        end
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create({label, "_ops"}, this);
        if (candidate_ops == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned null PCIe atomic ops", label))
            return 0;
        end
        return 1;
    endfunction
```
  标准分支的创建顺序（先 FSM 后 ops）、名称 `function_<vf_index>_fsm`/`function_<vf_index>_ops`、父对象 `this`，都与原 `preflight_bind_pcie` 一致。
  因此 dut_caps 里的实例 override 路径 `uvm_test_top.factory_ops_function.function_0_ops` 和 `<full_name>.function_0_fsm` 仍然生效。

- [ ] **Step 2: 替换 HEAD 212-337（preflight / pending / cancel / commit）。** 整段替换为：

```systemverilog
    // 两阶段绑定的预检半段：检查 RC sequencer、driver agent、transport 子对象和
    // 本 Function 的 qpair 上限，只暂存 FSM/ops 候选，不修改任何已提交的连接；
    // 失败返回 0 并保留 UVM_FATAL 诊断。环境对全部 Function 预检后才逐个提交，
    // 后面的 Function 失败不会留下前面 Function 的部分绑定。
    function bit preflight_bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        string function_name;
        string why;
        virtio_auto_fsm candidate_fsm;
        virtio_atomic_ops candidate_ops;

        cancel_bind_pcie();
        function_name = $sformatf("function_%0d", vf_index);
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s received a null PCIe RC sequencer", function_name))
            return 0;
        end
        if (driver_agent == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing driver agent", function_name))
            return 0;
        end
        if ((transport == null) || (vq_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing transport or virtqueue manager", function_name))
            return 0;
        end
        if ((transport.bar == null) || (transport.notify_mgr == null) ||
            (transport.cap_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                {"%s is missing transport BAR, notify manager, or ",
                 "capability manager"}, function_name))
            return 0;
        end
        candidate_fsm = driver_agent.fsm;
        candidate_ops = driver_agent.ops;
        if (!prepare_driver_candidates(function_name, drv_cfg, candidate_ops, candidate_fsm))
            return 0;
        if (!candidate_fsm.mq_pair_limit_binding_supported(
            drv_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end
        pending_pcie_fsm = candidate_fsm;
        pending_pcie_ops = candidate_ops;
        pcie_bind_prepared = 1;
        return 1;
    endfunction

    // 返回预检阶段暂存的 FSM 候选，仅供环境在提交前检查；未预检时返回 null。
    function virtio_auto_fsm pending_pcie_fsm_candidate();
        return pending_pcie_fsm;
    endfunction

    // 返回预检阶段暂存的原子操作对象；调用者不得把它绑定到另一份 snapshot。
    function virtio_atomic_ops pending_pcie_ops_candidate();
        return pending_pcie_ops;
    endfunction

    // 两阶段绑定的取消入口：丢弃尚未提交的 FSM/ops 候选，供批量绑定回滚；
    // 不触碰已经提交的连接。
    function void cancel_bind_pcie();
        pending_pcie_fsm = null;
        pending_pcie_ops = null;
        pcie_bind_prepared = 0;
    endfunction

    // 两阶段绑定的提交半段：把预检成功的候选一次性接入共享 Host/IOMMU/PCIe
    // 资源；缺少预检状态时 UVM_FATAL 并返回 0，成功后清除暂存句柄。
    function bit commit_bind_pcie(
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;

        if (!pcie_bind_prepared || (pending_pcie_fsm == null) ||
            (pending_pcie_ops == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "function_%0d PCIe bind commit requires successful preflight",
                vf_index))
            return 0;
        end
        ops = pending_pcie_ops;
        fsm = pending_pcie_fsm;
        if (!commit_validated_pcie_components(
            $sformatf("function_%0d", vf_index), transport, vq_mgr,
            driver_agent, hmem, iommu_mdl, bar_mdl, einj, wpol, drv_cfg,
            pcie_rc_seqr, ops, fsm)) begin
            return 0;
        end
        mem = hmem;
        iommu = iommu_mdl;
        barrier = bar_mdl;
        err_inj = einj;
        wait_pol = wpol;
        cancel_bind_pcie();
        return 1;
    endfunction
```

- [ ] **Step 3: 修改 `commit_validated_pcie_components` 的头注释（HEAD 339-345）。** 原注释：
```systemverilog
    // 统一提交已经通过空句柄、factory 和 qpair 上限检查的组件；失败只返回 0，
    // 不接受半初始化的 driver/transport。
    // 中文：输入已验证的 transport、queue、driver 和共享资源，执行最终接线；边界
    // 检查未通过时返回 0，不创建半初始化的数据面。
    // Commit only handles that have passed all null/factory/MQ checks.  The
    // environment reaches this helper through preflight; the standalone API
    // below performs the same checks before calling it.
```
  改为：
```systemverilog
    // 只由 commit_bind_pcie 调用：接线已通过 preflight_bind_pcie 空句柄、factory
    // 与 qpair 上限检查的组件；失败只返回 0，不接受半初始化的 driver/transport。
```
  函数体不动，保留 P0-4/P2-1 改过的 dataplane 适配段。

- [ ] **Step 4: 替换 HEAD 444-565（`bind_pcie_components`、`wire_shared`、`bind_pcie`）。** 整段替换为：

```systemverilog
    // 单 Function 便捷入口：preflight + commit 的组合；任一半段失败都丢弃候选，
    // 不保留部分接线。环境批量绑定直接使用两阶段接口以保证多 Function 原子性。
    function bit wire_shared(
        host_mem_manager hmem,
        virtio_iommu_model iommu_mdl,
        virtio_memory_barrier_model bar_mdl,
        virtqueue_error_injector einj,
        virtio_wait_policy wpol,
        uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        if (preflight_bind_pcie(pcie_rc_seqr) &&
            commit_bind_pcie(hmem, iommu_mdl, bar_mdl, einj, wpol, pcie_rc_seqr))
            return 1;
        cancel_bind_pcie();
        return 0;
    endfunction

    // standalone 便捷入口：使用实例当前保存的共享对象绑定一个 RC sequencer。
    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        return wire_shared(
            mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr);
    endfunction
```

- [ ] **Step 5: 修改 env 中的两处调用。** 在 `virtio_net_vip/src/env/virtio_net_env.sv` 中：
  `abort_bind` 内的 `plan[plan_index].function_instance.cancel_preflight_bind_pcie();` 改为 `plan[plan_index].function_instance.cancel_bind_pcie();`；
  `bind_function_pcie` 内的 `if (!function_instance.commit_preflight_bind_pcie(` 改为 `if (!function_instance.commit_bind_pcie(`。

- [ ] **Step 6: 迁移 `virtio_full_test.sv`。**
  删除第 31 行 `    virtio_auto_fsm fsm;`（`fsm` 只在第 104 行接收绑定输出）。把 HEAD 97-106：
```systemverilog
        transport.bdf = 16'h0100;  // Bus=1, Dev=0, Func=0
        if (!binding_function.bind_pcie_components(
            "full_function", transport, vq_mgr, null, host_mem, iommu,
            barrier, err_inj, wait_pol, binding_function.drv_cfg,
            pcie_env.rc_agent.sequencer, ops, fsm)) begin
            `uvm_fatal("FULL_TEST", "failed to bind function to PCIe")
            return;
        end
```
  改为：
```systemverilog
        transport.bdf = 16'h0100;  // Bus=1, Dev=0, Func=0
        // 测试自建的 transport/vq_mgr/ops 交给 Function 的统一绑定入口接线。
        binding_function.transport = transport;
        binding_function.vq_mgr = vq_mgr;
        binding_function.driver_agent.ops = ops;
        if (!binding_function.wire_shared(
            host_mem, iommu, barrier, err_inj, wait_pol,
            pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("FULL_TEST", "failed to bind function to PCIe")
            return;
        end
```

- [ ] **Step 7: 迁移 `virtio_dual_test.sv`。** 删除第 123 行 `    virtio_auto_fsm       fsm_a;` 和第 135 行 `    virtio_auto_fsm       fsm_b;`。
  把 HEAD 275-281 改为：
```systemverilog
        transport_a.bdf = 16'h0100;
        binding_function_a.transport = transport_a;
        binding_function_a.vq_mgr = vq_mgr_a;
        binding_function_a.driver_agent.ops = ops_a;
        if (!binding_function_a.wire_shared(
            mem_a, iommu_a, barrier_a, err_inj_a, wait_pol_a,
            pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("DUAL_TEST", "failed to bind function A to PCIe")
            return;
        end
```
  把 HEAD 290-296 改为：
```systemverilog
        transport_b.bdf = 16'h0200;
        binding_function_b.transport = transport_b;
        binding_function_b.vq_mgr = vq_mgr_b;
        binding_function_b.driver_agent.ops = ops_b;
        if (!binding_function_b.wire_shared(
            mem_b, iommu_b, barrier_b, err_inj_b, wait_pol_b,
            pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("DUAL_TEST", "failed to bind function B to PCIe")
            return;
        end
```
  说明：`fsm_a` 和 `fsm_b` 全文件没有别的引用。Function 的 driver agent 是 PASSIVE，没有 driver；`virtio_monitor` 和 `virtio_pcie_observer_adapter`
  都没有 run_phase。所以新增的 `driver_agent.ops/fsm/monitor.transport` 赋值在运行期没有副作用。

- [ ] **Step 8: 迁移 `virtio_dut_caps_test.sv`。**
  1. 恶意子类（HEAD 482-530）：删除字段 `int unsigned public_bind_count;` 和构造函数里的 `public_bind_count = 0;`，删除整个
     `virtual function bit bind_pcie_components(...) ... endfunction`（HEAD 496-513）。`wire_shared` 与 `bind_pcie` 的覆写保留。
  2. HEAD 1267-1282（以 `if ((production_function.public_bind_count != 0) ||` 开头的 if 块）改为：
```systemverilog
        if ((production_function.public_wire_shared_count != 0) ||
            (production_function.public_function_bind_count != 0) ||
            (production_function.driver_agent.fsm == null) ||
            (production_function.driver_agent.fsm.max_supported_mq_pairs() !=
             1)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"production env bind bypassed mandatory function guard: ",
                 "wire=%0d bind=%0d fsm=%0d"},
                production_function.public_wire_shared_count,
                production_function.public_function_bind_count,
                (production_function.driver_agent.fsm == null) ? 0 :
                    production_function.driver_agent.fsm.
                        max_supported_mq_pairs()))
        end
```
  3. `assert_driver_mq_dispatch_uses_dut_cap` 中 HEAD 2144-2150：
```systemverilog
        ops = ops_spy;
        fsm = fsm_probe;
        if (!mq_binding_function.bind_pcie_components(
            "mq_cap_function", transport, vq_mgr, null, null, null, null,
            null, null, driver_cfg, mq_pcie_seqr, ops, fsm)) begin
            `uvm_fatal("DUT_CAPS", "valid MQ function PCIe bind failed")
        end
```
     改为：
```systemverilog
        ops = ops_spy;
        fsm = fsm_probe;
        mq_binding_function.transport = transport;
        mq_binding_function.vq_mgr = vq_mgr;
        mq_binding_function.drv_cfg = driver_cfg;
        mq_binding_function.driver_agent.ops = ops;
        mq_binding_function.driver_agent.fsm = fsm;
        if (!mq_binding_function.wire_shared(
            null, null, null, null, null, mq_pcie_seqr)) begin
            `uvm_fatal("DUT_CAPS", "valid MQ function PCIe bind failed")
        end
```
     HEAD 2172-2185 是从 `driver_cfg.max_vio_net_qpairs_per_device = 2;` 到“failed MQ-limit rebind”判定 `if (...) begin` 的部分，改为：
```systemverilog
        driver_cfg.max_vio_net_qpairs_per_device = 2;
        mq_binding_function.transport = rebind_transport;
        mq_binding_function.vq_mgr = rebind_vq_mgr;
        mq_binding_function.drv_cfg = driver_cfg;
        rebind_catcher = new(
            "mq_bind_rebind_catcher", mq_binding_function,
            {"function_0 could not bind its MQ pair limit: ",
             "FSM MQ pair limit is already bound to 1; cannot rebind to 2"});
        uvm_report_cb::add(null, rebind_catcher);
        bind_succeeded = mq_binding_function.wire_shared(
            null, null, null, null, null, mq_pcie_seqr);
        uvm_report_cb::delete(null, rebind_catcher);
        mq_binding_function.transport = transport;
        mq_binding_function.vq_mgr = vq_mgr;
        if ((rebind_catcher.caught_count != 1) || bind_succeeded ||
            (mq_binding_function.driver_agent.ops != ops_spy) ||
            (mq_binding_function.driver_agent.fsm != fsm_probe) ||
            (ops_spy.transport != transport) || (ops_spy.vq_mgr != vq_mgr)) begin
```
     说明：`mq_binding_function` 没有设置 `vf_index`，默认为 0，所以名称是 `function_0`。失败发生在 `preflight_bind_pcie` 的 MQ 检查，
     和旧 `bind_pcie_components` 是同一条检查，只是消息前缀变了。`mq_binding_function` 在该任务之后没有其他使用。
  4. `assert_function_bind_guard_cannot_be_overridden`（HEAD 2499-2546）整段替换为：
```systemverilog
    task assert_function_bind_guard_cannot_be_overridden();
        virtio_function_instance base_function;
        virtio_dut_caps_expected_mq_bind_fatal catcher;
        int unsigned saved_qpair_limit;
        bit bind_succeeded;

        // 通过基类句柄调用非虚的 wire_shared：子类覆写不可达，MQ 守卫必须执行。
        base_function = malicious_binding_function;
        saved_qpair_limit = base_function.drv_cfg.max_vio_net_qpairs_per_device;
        base_function.drv_cfg.max_vio_net_qpairs_per_device = 33;
        catcher = new(
            "malicious_binding_catcher", base_function,
            {"function_0 could not bind its MQ pair limit: ",
             "FSM MQ pair limit 33 exceeds model ceiling 32"});
        uvm_report_cb::add(null, catcher);
        bind_succeeded = base_function.wire_shared(
            null, null, null, null, null, mq_pcie_seqr);
        uvm_report_cb::delete(null, catcher);
        base_function.drv_cfg.max_vio_net_qpairs_per_device = saved_qpair_limit;

        if ((catcher.caught_count != 1) || bind_succeeded ||
            (malicious_binding_function.public_wire_shared_count != 0) ||
            (base_function.driver_agent.ops != null) ||
            (base_function.driver_agent.fsm != null) ||
            (base_function.pending_pcie_fsm_candidate() != null) ||
            (base_function.pending_pcie_ops_candidate() != null)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"base-typed function bind bypassed mandatory MQ guard: ",
                 "reports=%0d public=%0d"},
                catcher.caught_count,
                malicious_binding_function.public_wire_shared_count))
        end
    endtask
```
     说明：run_phase 中该任务（HEAD 3845）排在 `assert_preflight_uses_factory_fsm_candidate`（HEAD 3868，它给同一对象设置 FSM 实例 override）之前。
     所以这里预检创建的是普通 `virtio_auto_fsm`，其 `mq_pair_limit_binding_supported(33)` 给出的消息与旧 `fsm_probe` 相同。
     driver agent 的 ops/fsm 保持为 null，后续 `assert_env_null_protocol_vif_returns`、`assert_preflight_uses_factory_fsm_candidate` 对 null 的断言不受影响。
  5. HEAD 3187 的 `factory_ops_function.cancel_preflight_bind_pcie();` 改为 `factory_ops_function.cancel_bind_pcie();`；
     HEAD 3190 的 `commit_succeeded = factory_ops_function.commit_preflight_bind_pcie(` 改为 `commit_succeeded = factory_ops_function.commit_bind_pcie(`。

- [ ] **Step 9: 用 grep 确认旧名称已全部删除。**
  `grep -rnE "bind_pcie_components|commit_preflight_bind_pcie|cancel_preflight_bind_pcie|public_bind_count|\bfsm_[ab]\b" virtio_net_vip examples README.md docs/*.md`
  预期：无输出。
  `grep -c "virtio_auto_fsm::type_id::create\|virtio_atomic_ops::type_id::create" virtio_net_vip/src/sriov/virtio_function_instance.sv` 预期为 `2`，两处都在 `prepare_driver_candidates` 中。

- [ ] **Step 10: SYNC 后跑测试。** 用 ONE TEST 跑 `virtio_dut_caps_test`、`virtio_full_integration_test`、`virtio_dual_test`、`virtio_real_driver_flow_test`，均应为 0/0/0。
  再跑 PRIV，因为私有环走的是 `wire_shared` 的私有分支。

- [ ] **Step 11: 跑 REGRESSION**，预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 12: 提交。**
  `git add virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/src/env/virtio_net_env.sv virtio_net_vip/tests/virtio_full_test.sv virtio_net_vip/tests/virtio_dual_test.sv virtio_net_vip/tests/virtio_dut_caps_test.sv`
  `git commit -m "refactor: function 绑定只保留 preflight/commit/cancel 三个入口，删除 bind_pcie_components"`

---

### Task P2-6: 引入 `vio_snapshot_ctx`，snapshot 只校验一次

**Files:**
- Create: `virtio_net_vip/src/sriov/vio_snapshot_ctx.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv:56-58`：在 `sriov/virtio_resource_client.sv` 之前 include 新文件
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv:33-56`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:26-27,108-210,716-726`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_instance.sv:21-47`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_instance.sv:58,66-127,260-262,277-279,309`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv:55,90-94,111,183-186,268-293`
- Test: `virtio_dut_caps_test`、`virtio_fabric_resource_test`、`virtio_monitor_routing_test`、`virtio_pf_lifecycle_reset_test`、`virtio_e2e_test`

**Spec deviation:**
- 测试会用非法 snapshot 直接调用各类的**公共入口**并断言失败或具体消息：`configure_from_service`、`configure_services`、
  `resource_client.bind_to_service`、`vf_resource_pool.import_service_bindings`。见 `virtio_monitor_routing_test:358-362,534,581,593,1013-1036`、
  `virtio_dut_caps_test:1388-1558,3552,3713-3740`、`virtio_fabric_resource_test:1081,1116`。所以这些校验不能直接删掉。
  做法：公共入口保留为薄包装，统一由 `vio_snapshot_ctx::create_checked` 完成 frozen/引用/seeded 校验；生产路径
  （env → PF → Function → resource client）只传 ctx，下游不再重复校验。
- `virtio_vf_resource_pool.import_service_bindings` 中的 frozen 检查和“钉住同一 resource snapshot”是该类自身的不变量（独立对象、没有 manager），保留不动。
- `virtio_pf_instance` 中 manager 与 snapshot 的 DUT 能力逐项比对、`virtio.qpair` 资源类查询，是 PF 服务组自己的前置条件，只出现在这里，不算重复校验。
  它们留在 `configure_services_ctx`，不并入 ctx。并入 ctx 会让 `unbuilt_function` 用备用 manager 配置时提前失败，改变 dut_caps 期望的消息。
- 组合失败（既改绑到另一份 device snapshot、service 又无法解析）时，诊断顺序变为先报改绑。测试中不存在这种组合。

**Interfaces:**
- Produces:
  - `class vio_snapshot_ctx extends uvm_object`：`static function vio_snapshot_ctx create_checked(dpu_device_snapshot, dpu_resource_snapshot, dpu_resource_manager, output string why)`，
    以及只读访问器 `device_snapshot()`、`resource_snapshot()`、`manager()`。
  - `virtio_function_instance::configure_from_ctx(input vio_snapshot_ctx ctx, input dpu_service_key_t service_key, input uvm_object pcie_ctx = null)`：virtual，VF 覆写。
  - `virtio_resource_client::bind_to_ctx(input vio_snapshot_ctx ctx, input dpu_service_key_t service_key, output string why)`。
  - `virtio_pf_instance::configure_services_ctx(input dpu_function_key_t parent_pf_key, input vio_snapshot_ctx ctx, input dpu_service_key_t service_keys[$], output string why)`。
  - env 新字段 `protected vio_snapshot_ctx snapshot_ctx;`，后续“设备发现绑定”设计的 verify_snapshot 从这里接入。
  - 签名保持不变：`configure_from_service`、`configure_services`、`bind_to_service`、`build_snapshot_topology(output string why)`。
- Consumes: 无新依赖。

- [ ] **Step 1: 新建 `virtio_net_vip/src/sriov/vio_snapshot_ctx.sv`：**

```systemverilog
`ifndef VIO_SNAPSHOT_CTX_SV
`define VIO_SNAPSHOT_CTX_SV

// 目录层次：src/sriov。一次校验、此后只读的 VIO snapshot 上下文：冻结的 device
// snapshot、引用它的冻结 resource snapshot、以及由这一对 snapshot 播种的 resource
// manager。env 构建一次后向 PF/Function/resource client 下传，下游不再重复校验
// frozen/引用/seeded 关系。本对象只借用三者，不拥有其生命周期。
class vio_snapshot_ctx extends uvm_object;
    `uvm_object_utils(vio_snapshot_ctx)

    local dpu_device_snapshot   m_device_snapshot;
    local dpu_resource_snapshot m_resource_snapshot;
    local dpu_resource_manager  m_manager;

    // 构造出的对象在 create_checked 赋值前不可用；外部不能修改三个引用。
    function new(string name = "vio_snapshot_ctx");
        super.new(name);
    endfunction

    // 校验三者关系：device snapshot 已冻结；resource snapshot 已冻结且引用该
    // device snapshot；manager 已由这一对 snapshot 播种。成功返回只读上下文，
    // 失败返回 null 并在 why 中给出原因。
    static function vio_snapshot_ctx create_checked(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_resource_manager manager,
        output string why
    );
        vio_snapshot_ctx ctx;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "VIO snapshot context requires a frozen device snapshot";
            return null;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = {"VIO snapshot context requires a frozen resource snapshot ",
                   "of the same device snapshot"};
            return null;
        end
        if ((manager == null) || !manager.is_snapshot_seeded() ||
            !manager.is_seeded_from_snapshots(device_snapshot, resource_snapshot)) begin
            why = {"VIO snapshot context requires a resource manager seeded ",
                   "from the same snapshot pair"};
            return null;
        end
        ctx = vio_snapshot_ctx::type_id::create("vio_snapshot_ctx");
        ctx.m_device_snapshot = device_snapshot;
        ctx.m_resource_snapshot = resource_snapshot;
        ctx.m_manager = manager;
        return ctx;
    endfunction

    // 只读访问器：返回已校验的冻结 device snapshot。
    function dpu_device_snapshot device_snapshot();
        return m_device_snapshot;
    endfunction

    // 只读访问器：返回已校验的冻结 resource snapshot。
    function dpu_resource_snapshot resource_snapshot();
        return m_resource_snapshot;
    endfunction

    // 只读访问器：返回由同一对 snapshot 播种的 resource manager。
    function dpu_resource_manager manager();
        return m_manager;
    endfunction
endclass : vio_snapshot_ctx

`endif // VIO_SNAPSHOT_CTX_SV
```

- [ ] **Step 2: 在包中 include 新文件。** `virtio_net_vip/src/virtio_net_pkg.sv` 中的：
```systemverilog
  // Resource clients are transport discovery callbacks and need to be
  // complete before the PCI transport class is compiled.
  `include "sriov/virtio_resource_client.sv"
```
  改为：
```systemverilog
  // Resource clients are transport discovery callbacks and need to be
  // complete before the PCI transport class is compiled.  The snapshot
  // context they consume is compiled first.
  `include "sriov/vio_snapshot_ctx.sv"
  `include "sriov/virtio_resource_client.sv"
```

- [ ] **Step 3: 拆分 resource client 的绑定入口（HEAD 33-56）。** 原来的函数头注释、签名和 pair 检查：
```systemverilog
    // 把本 client 绑定到一个 service 的 qpair 资源视图。
    // 校验链：snapshot 对必须冻结且互相引用 → service 必须是 VIO_NET 且
    // 所有权自洽 → 至少存在一条 qpair 绑定 → 已绑定时只允许幂等重绑。
    // 成功后按 local_pair 升序保存映射（冒泡排序，规模小无性能问题），
    // 并把 runtime_ready 清零（需重新 mark）。失败通过 why 给出原因。
    // 注意：RX/TX 共享同一 global qpair id，方向仅由 local virtqueue id 区分。
    function bit bind_to_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        dpu_function_key_t owner;
        dpu_vio_qpair_binding_t bindings[$];
        virtio_qpair_mapping_t candidate_mappings[$];
        virtio_qpair_mapping_t mapping;
        virtio_qpair_mapping_t swap;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "virtio resource client requires an exact frozen snapshot pair";
            return 0;
        end
```
  替换为：
```systemverilog
    // 独立调用入口（测试直接使用）：先确认 snapshot 对冻结且互相引用，再执行
    // 与 ctx 路径相同的绑定。失败通过 why 给出原因且不改变已有绑定。
    function bit bind_to_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "virtio resource client requires an exact frozen snapshot pair";
            return 0;
        end
        return bind_validated(device_snapshot, resource_snapshot, service_key, why);
    endfunction

    // 生产入口：ctx 已由 env 校验，不再重复检查 snapshot 对。
    function bit bind_to_ctx(
        input vio_snapshot_ctx ctx,
        input dpu_service_key_t service_key,
        output string why
    );
        why = "";
        if (ctx == null) begin
            why = "virtio resource client requires a validated snapshot context";
            return 0;
        end
        return bind_validated(ctx.device_snapshot(), ctx.resource_snapshot(),
                              service_key, why);
    endfunction

    // 绑定主体（snapshot 对已校验）：service 必须是 VIO_NET 且所有权自洽 →
    // 至少存在一条 qpair 绑定 → 已绑定时只允许幂等重绑。成功后按 local_pair
    // 升序保存映射并清 runtime_ready。RX/TX 共享同一 global qpair id，方向仅由
    // local virtqueue id 区分。
    local function bit bind_validated(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        dpu_function_key_t owner;
        dpu_vio_qpair_binding_t bindings[$];
        virtio_qpair_mapping_t candidate_mappings[$];
        virtio_qpair_mapping_t mapping;
        virtio_qpair_mapping_t swap;

        why = "";
```
  HEAD 58-117 的函数体（从 `if ((service_key.service_kind != DPU_SERVICE_VIO_NET) ||` 到 `endfunction`）不变，成为 `bind_validated` 的函数体。

- [ ] **Step 4: function instance 改为使用 ctx。**
  1. 把 HEAD 26-27 的字段：
```systemverilog
    protected dpu_device_snapshot configuration_snapshot;
    protected dpu_resource_snapshot configuration_resource_snapshot;
```
     改为：
```systemverilog
    // 已校验的 snapshot 上下文；非空表示本实例已被某个 service 配置。
    protected vio_snapshot_ctx snapshot_ctx;
```
  2. HEAD 108-210（`configure_from_service` 的注释到 `endfunction`）整段替换为：
```systemverilog
    // 独立调用入口（测试与兼容路径）：先拒绝非冻结 device snapshot 和改绑到另一份
    // device snapshot，再由 vio_snapshot_ctx 一次性校验 resource snapshot/manager，
    // 最后委托 configure_from_ctx。调用方不能传入 raw BDF/BAR。
    virtual function bit configure_from_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        input dpu_resource_manager manager,
        input uvm_object pcie_ctx = null
    );
        vio_snapshot_ctx ctx;
        string why;

        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a frozen device snapshot")
            return 0;
        end
        if (!device_snapshot_assignable(device_snapshot))
            return 0;
        ctx = vio_snapshot_ctx::create_checked(
            device_snapshot, resource_snapshot, manager, why);
        if (ctx == null) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration requires its exact frozen resource ",
                 "snapshot and pair-seeded manager"})
            return 0;
        end
        return configure_from_ctx(ctx, service_key, pcie_ctx);
    endfunction

    // 生产入口：ctx 已由 env 校验。解析本 service 的 owner、PCIe 身份和三个 BAR，
    // 拒绝改绑（device snapshot / resource snapshot / service / manager / PCIe
    // context），在提交前导入资源视图；任何失败 UVM_FATAL 并保持原有绑定。
    virtual function bit configure_from_ctx(
        input vio_snapshot_ctx ctx,
        input dpu_service_key_t service_key,
        input uvm_object pcie_ctx = null
    );
        dpu_device_snapshot device_snapshot;
        dpu_function_key_t key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t bar;
        string why;

        if (ctx == null) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a validated snapshot context")
            return 0;
        end
        device_snapshot = ctx.device_snapshot();
        if (service_key.service_kind != DPU_SERVICE_VIO_NET) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a VIO-net service key")
            return 0;
        end
        if (!device_snapshot.get_service_owner(service_key, key, why) ||
            !device_snapshot.get_pcie_id(key, pcie_id, why) ||
            !device_snapshot.get_bar(key, DPU_BAR_DEVICE_MEMORY, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MAILBOX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MSIX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot_assignable(device_snapshot))
            return 0;
        if (!ctx.manager().contains_function(key)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration requires its exact frozen resource ",
                 "snapshot and pair-seeded manager"})
            return 0;
        end
        if ((snapshot_ctx != null) &&
            ((snapshot_ctx.resource_snapshot() != ctx.resource_snapshot()) ||
             (dpu_service_key_name(this.service_key) !=
              dpu_service_key_name(service_key)) ||
             ((resource_manager != null) && (resource_manager != ctx.manager())) ||
             (pcie_ctx_ref != pcie_ctx))) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different resource snapshot, service, manager, or PCIe context"})
            return 0;
        end
        if ((resource_client != null) &&
            !resource_client.bind_to_ctx(ctx, service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return 0;
        end
        snapshot_ctx = ctx;
        function_kind = key.kind;
        function_key = key;
        this.service_key = service_key;
        bdf = pcie_id.bdf;
        this.pcie_id = pcie_id;
        pcie_id_valid = 1;
        vf_index = key.vf_id;
        bar_pairs = bars;
        resource_manager = ctx.manager();
        pcie_ctx_ref = pcie_ctx;
        apply_function_configuration();
        return 1;
    endfunction

    // 已配置的 Function 不得迁移到另一份 device snapshot；违反时 UVM_FATAL 并返回 0。
    local function bit device_snapshot_assignable(
        input dpu_device_snapshot device_snapshot
    );
        if ((snapshot_ctx != null) &&
            (snapshot_ctx.device_snapshot() != device_snapshot)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different device snapshot"})
            return 0;
        end
        return 1;
    endfunction
```
     消息核对：`virtio_fabric_resource_test:1116` 用伪造的 snapshot 对加原 manager 调用，wrapper 中先检查改绑，所以仍报 “different device snapshot”。
     `virtio_dut_caps_test:1481` 用相同 device snapshot、null manager 调用，ctx 失败，报 “exact frozen resource snapshot and pair-seeded manager”。
     dut_caps:1433 的 `unbuilt_function` 使用合法的备用 pair，ctx 通过后命中第二个改绑检查，报 “different resource snapshot, service, manager, or PCIe context”。
  3. `apply_function_configuration` 末尾（HEAD 716-726）：
```systemverilog
        if (configuration_resource_snapshot == null)
            return;
        if (!resource_client.bind_to_service(
                configuration_snapshot, configuration_resource_snapshot,
                service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return;
        end
        transport.configure_fabric_managed(resource_client);
```
     改为：
```systemverilog
        if (snapshot_ctx == null)
            return;
        // configure_from_ctx 在子对象已构建时已于提交前导入资源；只有子对象尚未
        // 构建（resource_client 在 build_phase 才创建）时由这里完成唯一一次导入。
        if (!resource_client.is_bound_to_service() &&
            !resource_client.bind_to_ctx(snapshot_ctx, service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return;
        end
        transport.configure_fabric_managed(resource_client);
```

- [ ] **Step 5: 把 VF 守卫移到 ctx 入口。** `virtio_net_vip/src/sriov/virtio_vf_instance.sv` 的 HEAD 21-47 替换为：
```systemverilog
    // 在基类解析之前加一道 VF 守卫：service 必须由 ctx 中的冻结 snapshot 声明，
    // 且其 owner 的 kind 必须是 VF——防止把 PF 服务错绑到 VF 实例上。
    // configure_from_service 经基类包装后也会走到这里。
    virtual function bit configure_from_ctx(
        input vio_snapshot_ctx ctx,
        input dpu_service_key_t service_key,
        input uvm_object pcie_ctx = null
    );
        dpu_function_key_t owner;
        string why;

        if ((ctx == null) ||
            !ctx.device_snapshot().get_service_owner(service_key, owner, why)) begin
            `uvm_fatal("VF_INSTANCE",
                "VF instance requires a frozen snapshot-declared service")
            return 0;
        end
        if (owner.kind != DPU_FUNCTION_VF) begin
            `uvm_fatal("VF_INSTANCE",
                "virtio_vf_instance requires a VF-owned service")
            return 0;
        end
        return super.configure_from_ctx(ctx, service_key, pcie_ctx);
    endfunction
```
  文件头注释第 7 行“并在配置入口处强制校验 service 的 owner 必须是 VF function”仍然正确，不改。

- [ ] **Step 6: 把 PF 服务组拆成包装函数和 ctx 主体。** 修改 `virtio_net_vip/src/sriov/virtio_pf_instance.sv`：
  1. HEAD 66-127 替换为下面的代码。范围是从 `// 从冻结 snapshot 一次性解析并创建整个 PF 服务组` 开始，到 pair 检查（`VIO service group requires its exact frozen resource snapshot`）的 `end`：
```systemverilog
    // 独立调用入口（测试直接使用）：用 vio_snapshot_ctx 一次性校验 snapshot 对与
    // manager，失败时在 why 中说明且不创建任何子对象；成功后委托 configure_services_ctx。
    function bit configure_services(
        input dpu_function_key_t parent_pf_key,
        input dpu_device_snapshot snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_keys[$],
        input dpu_resource_manager manager,
        output string why
    );
        vio_snapshot_ctx ctx;

        ctx = vio_snapshot_ctx::create_checked(
            snapshot, resource_snapshot, manager, why);
        if (ctx == null) begin
            why = {"VIO service group: ", why};
            return 0;
        end
        return configure_services_ctx(parent_pf_key, ctx, service_keys, why);
    endfunction

    // 从已校验的 ctx 一次性解析并创建整个 PF 服务组（PF + 全部 VF）。
    // 前置校验（全部通过前不改动任何成员，保证失败无副作用）：
    //   - 只允许配置一次；parent 必须是 PF key（vf_id==0）；
    //   - manager 能查到 virtio.qpair 资源类，DUT 能力（host/PF/VF/队列/MSI-X/
    //     BAR profile）与 snapshot 逐项一致；
    //   - 每个 service：必须是 VIO_NET、有 qpair 绑定、owner 属于本 PF 组、
    //     owner 不重复、PCIe id 可解析、三个 BAR 角色齐全且顺序正确、
    //     manager 包含该 function。
    // 通过后：记录 pf_key/host_id/pf_id，按 owner 类型创建 pf_function 或
    // vf_functions[]（各自 configure_from_ctx），并把每个 service 的 qpair 绑定
    // 导入 pf_manager.resource_pool；成功返回 1，失败 why 说明。
    function bit configure_services_ctx(
        input dpu_function_key_t parent_pf_key,
        input vio_snapshot_ctx ctx,
        input dpu_service_key_t service_keys[$],
        output string why
    );
        dpu_device_snapshot snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_resource_manager manager;
        dpu_function_key_t owner;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_role_e required_roles[$];
        dpu_function_key_t seen_owners[$];
        dpu_function_key_t resolved_owners[$];
        dpu_resource_class_id_t qpair_class_id;
        dpu_dut_caps snapshot_caps;
        dpu_dut_caps manager_caps;
        bit owner_seen;
        int unsigned vf_count;
        dpu_vio_qpair_binding_t service_bindings[$];

        why = "";
        if (services_configured) begin
            why = "PF service group is already configured";
            return 0;
        end
        if ((parent_pf_key.kind != DPU_FUNCTION_PF) ||
            (parent_pf_key.vf_id != 0)) begin
            why = "VIO service group requires a PF parent key";
            return 0;
        end
        if (ctx == null) begin
            why = "VIO service group requires a validated snapshot context";
            return 0;
        end
        snapshot = ctx.device_snapshot();
        resource_snapshot = ctx.resource_snapshot();
        manager = ctx.manager();
```
     从 HEAD 128（`if (!manager.lookup_resource_class(`）到函数末尾的代码保持不变，只改写下面两处调用。
  2. HEAD 260-262：
```systemverilog
                if (!pf_function.configure_from_service(
                        snapshot, resource_snapshot,
                        service_keys[index], manager)) begin
```
     改为：
```systemverilog
                if (!pf_function.configure_from_ctx(
                        ctx, service_keys[index])) begin
```
  3. HEAD 277-279：
```systemverilog
                if (!vf_functions[vf_index].configure_from_service(
                        snapshot, resource_snapshot,
                        service_keys[index], manager)) begin
```
     改为：
```systemverilog
                if (!vf_functions[vf_index].configure_from_ctx(
                        ctx, service_keys[index])) begin
```
  4. HEAD 58 注释中的 `实际拓扑必须经 configure_services` 改为 `实际拓扑必须经 configure_services/configure_services_ctx`。
     HEAD 309 注释中的 `未经 configure_services 的实例直接 fatal` 改为 `未经 configure_services(_ctx) 的实例直接 fatal`。

- [ ] **Step 7: env 中只在一处创建 ctx。** 修改 `virtio_net_vip/src/env/virtio_net_env.sv`：
  1. 在 HEAD 55 `protected dpu_resource_manager device_resource_manager;` 之后加：
```systemverilog
    // 一次校验后的只读 snapshot 上下文；下游 PF/Function/resource client 只消费它。
    protected vio_snapshot_ctx snapshot_ctx;
```
     在构造函数（HEAD 90-94）的 `effective_dut_caps = null;` 之后加 `        snapshot_ctx = null;`。
  2. 在 `build_snapshot_topology` 中 HEAD 111 的 `why = "";` 之后插入：
```systemverilog
        // build_phase 已建立 snapshot_ctx；测试探针跳过 build_phase、直接写入三个
        // snapshot 字段时在这里补建，校验规则仍只有 vio_snapshot_ctx 一处。
        if (snapshot_ctx == null) begin
            snapshot_ctx = vio_snapshot_ctx::create_checked(
                device_snapshot, resource_snapshot, device_resource_manager, why);
            if (snapshot_ctx == null)
                return 0;
        end
```
     `virtio_monitor_routing_test.sv:150-174` 中的 `virtio_resource_topology_probe.configure_and_build` 正是这种用法：它跳过 build_phase，直接写字段后调用
     `build_snapshot_topology`，传入的是空但合法的 resource snapshot。ctx 校验通过后，因为“没有 qpair 绑定”而失败，原断言仍然成立，探针代码不用改。
  3. HEAD 183-186：
```systemverilog
            if (!pf_instances[index].configure_services(
                    group_keys[index], device_snapshot, resource_snapshot,
                    grouped_services[index], device_resource_manager, why))
                return 0;
```
     改为：
```systemverilog
            if (!pf_instances[index].configure_services_ctx(
                    group_keys[index], snapshot_ctx,
                    grouped_services[index], why))
                return 0;
```
  4. `build_phase` 中 HEAD 268-293 替换为下面的代码。范围是从 `if (!uvm_config_db#(dpu_device_snapshot)::get(` 到 `published resource manager does not belong to the snapshot pair` 所在 if 块的 `end`：
```systemverilog
        // 三者由全局 DPU 发布；这里一次性校验 frozen/引用/seeded 关系并封装为只读
        // 上下文，下游 PF/Function/resource client 不再重复校验。
        void'(uvm_config_db#(dpu_device_snapshot)::get(
            this, "", "dpu_device_snapshot", device_snapshot));
        void'(uvm_config_db#(dpu_resource_snapshot)::get(
            this, "", "dpu_resource_snapshot", resource_snapshot));
        void'(uvm_config_db#(dpu_resource_manager)::get(
            this, "", "dpu_resource_manager", device_resource_manager));
        snapshot_ctx = vio_snapshot_ctx::create_checked(
            device_snapshot, resource_snapshot, device_resource_manager, why);
        if (snapshot_ctx == null) begin
            `uvm_fatal("VIRTIO_ENV", {"published snapshot context is invalid: ", why})
            return;
        end
```
     旧的四条 env 消息没有测试依赖：在 HEAD 上执行 `grep -rn "published frozen\|snapshot-seeded device resource manager\|does not belong to the snapshot pair" virtio_net_vip/tests examples` 结果为空。

- [ ] **Step 8: 用 grep 收集证据。**
  `grep -rn "configuration_snapshot\|configuration_resource_snapshot" virtio_net_vip examples` 预期：无输出。
  `grep -rln "is_seeded_from_snapshots" virtio_net_vip/src` 预期：只有 `virtio_net_vip/src/sriov/vio_snapshot_ctx.sv`。
  `grep -rn "bind_to_ctx(" virtio_net_vip/src` 预期：`virtio_resource_client.sv` 中的定义，以及 `virtio_function_instance.sv` 中两处调用，分别在 `configure_from_ctx` 和 `apply_function_configuration`。
  后者有 `!is_bound_to_service()` 守卫，所以每次配置只导入一次。
  `grep -rn "configure_from_service(" virtio_net_vip/src` 预期：只有 `virtio_function_instance.sv` 中的定义。

- [ ] **Step 9: SYNC 后跑测试。** 用 ONE TEST 跑 `virtio_dut_caps_test`、`virtio_fabric_resource_test`、`virtio_monitor_routing_test`、`virtio_pf_lifecycle_reset_test`、`virtio_e2e_test`，均应为 0/0/0。
  重点断言：`virtio_dut_caps_test` 中 “different device snapshot”、“exact frozen resource snapshot and pair-seeded manager”、
  “different resource snapshot, service, manager, or PCIe context” 三条 catcher 的计数都为 1；`virtio_fabric_resource_test` 中伪造的 snapshot 仍报 “different device snapshot”。

- [ ] **Step 10: 跑 REGRESSION 和 PRIV。**

- [ ] **Step 11: 提交。**
  `git add virtio_net_vip/src/sriov/vio_snapshot_ctx.sv virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/src/sriov/virtio_resource_client.sv virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/src/sriov/virtio_vf_instance.sv virtio_net_vip/src/sriov/virtio_pf_instance.sv virtio_net_vip/src/env/virtio_net_env.sv`
  `git commit -m "refactor: 引入 vio_snapshot_ctx，snapshot 关系只在 env 校验一次"`

---

### Task P2-7: 删除 `virtio_pci_transport.full_init_sequence`，fixture 改用 ops 单步接口

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv:639-783`（删除）
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv:750-814`
- Modify: `docs/virtio_net_vip_manual.md:1138-1150,2372`、`docs/virtio_verification_flow.md:110-111,117`
- Test: `virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`

**Interfaces:**
- Consumes（`virtio_atomic_ops`，HEAD 行号）：`device_reset_verified(ref bit)`:460、`set_acknowledge()`:528、`set_driver()`:536、
  `negotiate_features(bit [63:0], ref bit [63:0])`:625（同时写入 `ops.negotiated_features`）、`set_features_ok(ref bit)`:548、
  `set_failed()`:595、`setup_msix(int unsigned)`:2050、`set_driver_ok()`:583。transport 的 `read_num_queues(ref int unsigned)`:492、
  `discover_and_init_bars()`、`read_device_status()`。
- Produces：transport 只保留寄存器访问以及 `setup_single_queue`、`kick`。init 时序只出现在两处：`virtio_auto_fsm.full_init()`，以及调用方自己编排的 ops 单步调用。

等价性说明（旧 → 新）：
- reset：用的是同一个 `transport.reset_device_verified`。ops 新增的上下文检查（transport/vq_mgr/iommu 非空）在 env 绑定之后恒成立；开始时还没有任何队列，因此 ops 的 DMA 清理是空操作。
- 之后依次是 ACK、DRIVER。
- 特性协商：旧代码直接调 transport，再由 fixture 手工同步 `ops.negotiated_features`（20f7630 加的同步）；新代码由 `ops.negotiate_features` 自己写入，所以删除这段同步。
- 之后是 FEATURES_OK 加回读，读 num_queues 校验容量，再做 MSI-X（notify_mgr 的调用序列相同），最后 DRIVER_OK。
- 唯一的行为差别：旧实现在 DRIVER_OK 之前对每个队列额外执行 `select_queue/read_queue_num_max/read_queue_notify_off`，并预先填好 `queue_notify_off[]`；新实现不做这一步。
  `setup_queue()` 中的 `transport.setup_single_queue` 会读 notify_off，并按需扩展 `queue_notify_off[]`（HEAD transport:812-826），而 kick 只会发给已经建立的队列。
- 三个 real-driver 测试对 responder 计数只比较“之后 > 之前”（`virtio_real_driver_flow_test.sv:100-122`），少几次 MMIO 读不影响结果。

- [ ] **Step 1: 删除 transport 中的 `full_init_sequence`。** 删除 `virtio_net_vip/src/transport/virtio_pci_transport.sv` 的 HEAD 639-783：
  从 `    // ========================================================================`、`    // full_init_sequence` 注释块开始，到该 task 的 `    endtask` 及其后的一个空行为止。
  从 HEAD 784 开始的 `// setup_single_queue` 注释块保留。

- [ ] **Step 2: 改写 fixture 的 `start_driver_flow`。** 把 `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv` 的 HEAD 750-814 替换为：
```systemverilog
    // 用 atomic ops 的单步接口完成 reset → ACK → DRIVER → 特性协商 → FEATURES_OK
    // → 设备队列数校验 → MSI-X → DRIVER_OK。不调用 virtio_auto_fsm.full_init()：
    // 它的队列建立阶段会再分配一次 ring；ring 只由 setup_queue() 这一唯一的
    // atomic-op 分配入口创建。
    virtual task start_driver_flow(ref bit ok);
        virtio_function_instance function_instance;
        virtio_driver_config_t driver_cfg;
        virtio_atomic_ops ops;
        bit step_ok;
        bit [63:0] negotiated;
        bit [7:0] status;
        int unsigned device_queue_count;
        int unsigned total_queues;
        string why;

        ok = 0;
        if (!m_flow_ready) begin
            `uvm_error("REAL_FLOW", "start_driver_flow called before build_flow")
            return;
        end
        if (m_driver_flow_started) begin
            `uvm_error("REAL_FLOW",
                       "start_driver_flow called while a flow is already active")
            return;
        end
        function_instance = selected_function(why);
        if (function_instance == null) begin
            `uvm_error("REAL_FLOW", why)
            return;
        end
        if ((function_instance.transport == null) ||
            (function_instance.driver_agent == null) ||
            (function_instance.driver_agent.ops == null)) begin
            `uvm_error("REAL_FLOW",
                       "selected function has no bound transport/driver ops")
            return;
        end

        driver_cfg = function_instance.drv_cfg;
        if (driver_cfg.num_queue_pairs == 0) begin
            `uvm_error("REAL_FLOW", "driver configuration requests zero queue pairs")
            return;
        end

        ops = function_instance.driver_agent.ops;
        function_instance.transport.discover_and_init_bars();
        ops.device_reset_verified(step_ok);
        if (!step_ok) begin
            `uvm_error("REAL_FLOW", "device reset did not complete")
            return;
        end
        ops.set_acknowledge();
        ops.set_driver();
        // ops 自己记录协商结果，virtio-net header 长度由它推导，无需再手工同步。
        ops.negotiate_features(driver_cfg.driver_features, negotiated);
        ops.set_features_ok(step_ok);
        if (!step_ok) begin
            ops.set_failed();
            `uvm_error("REAL_FLOW", "device rejected the negotiated features")
            return;
        end
        // 只校验设备队列数能容纳本配置；各队列 notify 偏移由 setup_queue() 读回。
        function_instance.transport.read_num_queues(device_queue_count);
        total_queues = 2 * driver_cfg.num_queue_pairs;
        if (negotiated[VIRTIO_NET_F_CTRL_VQ])
            total_queues++;
        if (total_queues > device_queue_count) begin
            ops.set_failed();
            `uvm_error("REAL_FLOW", $sformatf(
                "configuration needs %0d queues but device supports %0d",
                total_queues, device_queue_count))
            return;
        end
        ops.setup_msix(total_queues);
        ops.set_driver_ok();

        function_instance.transport.read_device_status(status);
        if (!(status & DEV_STATUS_DRIVER_OK)) begin
            `uvm_error("REAL_FLOW", $sformatf(
                "transport did not reach DRIVER_OK (status=0x%02h)", status))
            return;
        end
        // 让共享 FSM 的生命周期视图与设备一致，供只读检查的调用方使用。
        if (function_instance.driver_agent.fsm != null)
            function_instance.driver_agent.fsm.state = FSM_READY;
        m_driver_flow_started = 1;
        ok = 1;
    endtask
```
  若 P3-1（execution_profile）已先合入并改动了本函数的前置检查，只替换 `discover_and_init_bars()` 到 `FSM_READY` 之间的部分，前置检查沿用 P3 的版本。

- [ ] **Step 3: 更新文档。**
  1. 把 `docs/virtio_net_vip_manual.md` 的 HEAD 1138-1150 替换为：
````markdown
**初始化序列**：transport 只提供寄存器访问；spec 7.2 的 9 步由 `virtio_auto_fsm::full_init()`
（含队列建立）编排，或由调用方直接按 `virtio_atomic_ops` 单步接口编排（真实驱动 fixture
即如此，队列只在 `setup_queue()` 中建立）：

```
Step 1: ops.device_reset_verified()       -- 写 status=0, 轮询直到读回 0
Step 2: ops.set_acknowledge()             -- 确认设备存在
Step 3: ops.set_driver()                  -- 声明驱动身份
Step 4: ops.negotiate_features()          -- 两阶段 feature 协商并记录结果
Step 5: ops.set_features_ok()             -- 确认 feature, 回读验证
Step 6: transport.read_num_queues()       -- 获取设备支持的队列数（fixture 校验用）
Step 7: ops.setup_queue()                 -- 分配 ring、写地址、读 notify_off、使能
Step 8: ops.setup_msix()                  -- MSI-X 表初始化 + 向量绑定
Step 9: ops.set_driver_ok()               -- 驱动就绪
```
````
  2. 删除同一文件 HEAD 2372 的表格行 ``| `full_init_sequence` | task | 完整 9 步初始化 |``。
  3. `docs/virtio_verification_flow.md` 的 HEAD 110-111：
```markdown
3. **spec 7.2 状态机**：`virtio_pci_transport::full_init_sequence`
   （pci_transport.sv:605），全是 common cfg BAR 的 MemWr/MemRd：
```
     改为：
```markdown
3. **spec 7.2 状态机**：`virtio_auto_fsm::do_full_init` 经 `virtio_atomic_ops`
   单步接口执行（真实驱动 fixture 直接调用同一组单步接口），全是 common cfg BAR 的 MemWr/MemRd：
```
     HEAD 117 的 `   - 读 num_queues(0x12)。` 改为 `   - 读 num_queues(0x12)（仅 fixture 用于校验队列容量）。`

- [ ] **Step 4: 用 grep 收集证据。**
  `grep -rn "full_init_sequence" virtio_net_vip examples README.md docs/*.md` 预期：无输出。
  `grep -n "ops.negotiated_features =" virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv` 预期：无输出，说明手工同步已删除。

- [ ] **Step 5: SYNC 后跑测试。** 用 ONE TEST 跑 `virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`，均应为 0/0/0。
  如果 rx 或 multiqueue 报 `kick: queue_id N out of range`，说明有地方在 `setup_queue` 之前就 kick 了。这时应停下来核对测试意图，不要恢复预读 notify_off 的做法。

- [ ] **Step 6: 跑 REGRESSION。**

- [ ] **Step 7: 提交。**
  `git add virtio_net_vip/src/transport/virtio_pci_transport.sv virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv docs/virtio_net_vip_manual.md docs/virtio_verification_flow.md`
  `git commit -m "refactor: 删除 transport.full_init_sequence，真实驱动 fixture 改用 ops 单步初始化"`

---

### Task P2-8a: 测试公共件 `virtio_mock_transport` 与 `virtio_vq_test_kit`；迁移 transport 子类和重复的完成写回

**Files:**
- Create: `virtio_net_vip/tests/virtio_mock_transport.sv`、`virtio_net_vip/tests/virtio_vq_test_kit.sv`
- Modify: `filelists/tests.f:7`：在 `virtio_net_vip/tests/virtio_queue_host_mem_provider_adapter.sv` 之后加两行
- Modify: `virtio_net_vip/tests/virtio_admin_vq_test.sv:9-66,110,299-326,378,522,818,968,1212,1324,1360,1368,1404,1440`
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv:109-132,302-333,374,492,635,705,791,881,982,985,986,1058,1069-1087`（另含 P0-4 新增的 `test_dataplane_engine_notifies_device` 中的类名）
- Modify: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv:9-38`
- Modify: `virtio_net_vip/tests/virtio_migration_dirty_test.sv:8-96,1593-1625,1634-1638`
- Modify: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`：P0-2 新建的文件，见 P0.md 中的 `virtio_ctrl_vq_test_transport`
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv:89-115,282-283,329`（另含 P0-4 新增的 `virtio_net_packet_mq_test_transport`）
- Modify: `virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv:112-137,195-196`
- Modify: `virtio_net_vip/tests/virtio_queue_semantics_test.sv:58-79,119`
- Modify: `virtio_net_vip/tests/virtio_traffic_test.sv:1147-1167,1318-1341`
- Test: `virtio_admin_vq_test`、`virtio_indirect_desc_test`、`virtio_migration_dirty_test`、`virtio_pf_lifecycle_reset_test`、`virtio_ctrl_vq_test`、
  `virtio_host_mem_reclaim_test`、`virtio_queue_semantics_test`、`virtio_net_packet_multi_queue_test`、`virtio_traffic_test`

**Interfaces:**
- Produces（P2-8b 及后续测试使用）：
  - `class virtio_mock_transport extends virtio_pci_transport`，字段：
    - kick 记录：`kick_count`、`last_kick_queue_id`、`last_kick_next_avail_idx`、`last_kick_wrap_counter`、`kicks_per_queue[int unsigned]`
    - 设备状态：`mock_status`（默认 `DEV_STATUS_DRIVER_OK`）
    - 设备复位：`device_reset_count`、`device_reset_complete`（默认 1）
    - 队列复位：`queue_reset_count`、`last_reset_queue_id`、`queue_reset_complete`（默认 1）
    - net config：`mock_net_config`（默认全 0，其中 `max_virtqueue_pairs = 1`）、`net_config_reads`
    - 队列编程：`queue_num_max`（默认 8）、`programmed_qids[$]`、`programmed_queue_*[int unsigned]`

    方法：`kicks(qid)`、`get_programmed_queue(qid, ref desc, ref driver, ref device, ref size)`。
  - `class virtio_vq_test_kit extends uvm_object`，字段 `mem/iommu/barrier/err_inj/wait_pol/vq_mgr/host_id`，方法：
    - `static function virtio_vq_test_kit create_kit(string prefix, host_mem_manager mem, virtio_iommu_model iommu, bit [15:0] bdf, int unsigned host_id = 0, virtqueue_manager vq_mgr = null)`
    - `function split_virtqueue make_split(string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf)`
    - `function packed_virtqueue make_packed(string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf)`
    - `function split_virtqueue add_split(int unsigned queue_id, int unsigned queue_size)`
    - `function packed_virtqueue add_packed(int unsigned queue_id, int unsigned queue_size)`
    - `function virtio_atomic_ops make_ops(virtio_pci_transport transport, string name = "", virtio_atomic_ops ops = null)`
    - `static function void complete_split_at(host_mem_manager mem, virtqueue_base vq, int unsigned used_slot, int unsigned head, int unsigned used_len, int unsigned used_idx)`
    - `static function void complete_packed(host_mem_manager mem, virtqueue_base vq, int unsigned head)`
- Spec deviation:
  - 规范只列出 `make_split/make_packed/make_ops/complete_split_at/complete_packed`。但队列有两种创建方式：经 vq_mgr 注册（ops 要按 queue_id 查找）和独立 setup。
    因此分别提供 `add_split/add_packed` 与 `make_split/make_packed`，另加 `create_kit` 来构造共享支撑对象。
  - `virtio_migration_dirty_test_transport` 保留为 mock 的一个很小的子类，只增加“验证复位后状态读回 0”这一点，因为 admin 测试依赖的是相反语义：“复位不改状态”。
  - 规范说要迁移 4 个 transport 子类；P0-2 和 P0-4 又新增了 `virtio_ctrl_vq_test_transport` 和 `virtio_net_packet_mq_test_transport` 两个桩，这里一并迁移。

- [ ] **Step 1: 新建 `virtio_net_vip/tests/virtio_mock_transport.sv`：**
```systemverilog
`ifndef VIRTIO_MOCK_TRANSPORT_SV
`define VIRTIO_MOCK_TRANSPORT_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// 目录层次：tests。无 PCIe 的 transport 测试替身：记录 kick 次数与最后一次参数；
// 设备状态、net config、设备/队列复位结果可编程；队列编程（setup_single_queue）
// 记录为可查询的寄存器模型。未覆写的方法仍走真实 PCIe 路径（无 sequencer 时
// UVM_FATAL），因此只用于不访问这些寄存器的用例。
class virtio_mock_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_mock_transport)

    int unsigned kick_count;
    int unsigned last_kick_queue_id;
    int unsigned last_kick_next_avail_idx;
    bit          last_kick_wrap_counter;
    int unsigned kicks_per_queue[int unsigned];
    bit [7:0]    mock_status;
    int unsigned device_reset_count;
    bit          device_reset_complete;
    int unsigned queue_reset_count;
    int unsigned last_reset_queue_id;
    bit          queue_reset_complete;
    virtio_net_device_config_t mock_net_config;
    int unsigned net_config_reads;
    int unsigned queue_num_max;
    int unsigned programmed_qids[$];
    bit          programmed_queue_valid[int unsigned];
    bit [63:0]   programmed_queue_desc[int unsigned];
    bit [63:0]   programmed_queue_driver[int unsigned];
    bit [63:0]   programmed_queue_device[int unsigned];
    int unsigned programmed_queue_size[int unsigned];

    // 默认：设备处于 DRIVER_OK，设备复位与队列复位都能完成，net config 报告
    // 1 个队列对，队列最大长度 8。
    function new(string name = "virtio_mock_transport");
        super.new(name);
        kick_count = 0;
        last_kick_queue_id = 0;
        last_kick_next_avail_idx = 0;
        last_kick_wrap_counter = 0;
        mock_status = DEV_STATUS_DRIVER_OK;
        device_reset_count = 0;
        device_reset_complete = 1;
        queue_reset_count = 0;
        last_reset_queue_id = '1;
        queue_reset_complete = 1;
        mock_net_config = '{default: 0};
        mock_net_config.max_virtqueue_pairs = 1;
        net_config_reads = 0;
        queue_num_max = 8;
    endfunction

    // 记录通知而不发 TLP，便于检查生产调用方给出的游标与每个队列的通知次数。
    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
        kick_count++;
        last_kick_queue_id       = queue_id;
        last_kick_next_avail_idx = next_avail_idx;
        last_kick_wrap_counter   = wrap_counter;
        if (!kicks_per_queue.exists(queue_id))
            kicks_per_queue[queue_id] = 0;
        kicks_per_queue[queue_id]++;
    endtask

    // 返回某个队列收到的通知次数；从未通知过返回 0。
    function int unsigned kicks(int unsigned queue_id);
        return kicks_per_queue.exists(queue_id) ? kicks_per_queue[queue_id] : 0;
    endfunction

    // 设备状态读写只作用于 mock_status。
    virtual task read_device_status(ref bit [7:0] status);
        status = mock_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        mock_status = status;
    endtask

    // 设备复位：计数并返回可编程的完成结果；不改变 mock_status。
    virtual task reset_device_verified(ref bit reset_complete);
        device_reset_count++;
        reset_complete = device_reset_complete;
    endtask

    // 队列复位：计数、记录队列号，verified 形式返回可编程的完成结果。
    virtual task write_queue_reset(int unsigned queue_id);
        queue_reset_count++;
        last_reset_queue_id = queue_id;
    endtask

    virtual task write_queue_reset_verified(int unsigned queue_id,
                                            ref bit reset_complete);
        queue_reset_count++;
        last_reset_queue_id = queue_id;
        reset_complete = queue_reset_complete;
    endtask

    // 设备配置空间读回 mock_net_config，并计数。
    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        net_config_reads++;
        cfg = mock_net_config;
    endtask

    // 队列寄存器模型：select/enable 不产生访问，num_max 可编程，setup 记录编程值。
    virtual task select_queue(int unsigned queue_id);
    endtask

    virtual task write_queue_enable(bit enable);
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        max_size = queue_num_max;
    endtask

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        programmed_qids.push_back(queue_id);
        programmed_queue_valid[queue_id]  = 1;
        programmed_queue_desc[queue_id]   = desc_addr;
        programmed_queue_driver[queue_id] = driver_addr;
        programmed_queue_device[queue_id] = device_addr;
        programmed_queue_size[queue_id]   = queue_size;
    endtask

    // 返回 setup_single_queue 记录的编程值；该队列未编程时返回 0 且输出清零。
    function bit get_programmed_queue(
        int unsigned queue_id,
        ref bit [63:0] desc_addr,
        ref bit [63:0] driver_addr,
        ref bit [63:0] device_addr,
        ref int unsigned queue_size
    );
        desc_addr = '0;
        driver_addr = '0;
        device_addr = '0;
        queue_size = 0;
        if (!programmed_queue_valid.exists(queue_id) ||
            !programmed_queue_valid[queue_id])
            return 0;
        desc_addr = programmed_queue_desc[queue_id];
        driver_addr = programmed_queue_driver[queue_id];
        device_addr = programmed_queue_device[queue_id];
        queue_size = programmed_queue_size[queue_id];
        return 1;
    endfunction
endclass : virtio_mock_transport

`endif // VIRTIO_MOCK_TRANSPORT_SV
```
  关于覆写范围：六个旧桩覆写过的方法这里全部覆盖。有些用例过去没有覆写某个方法（例如 admin、indirect、pf_lifecycle 没有覆写 `select_queue`、`write_device_status`、`read_net_config`）。
  在 HEAD 下，这些用例只要调用到这类方法，就会因为 `pcie_rc_seqr == null` 触发 `BAR_ACCESSOR` fatal（`virtio_bar_accessor.sv:688,732`）。回归能通过，说明这些用例不会调用它们，
  所以扩大覆写范围不会改变行为。迁移测试读 net config 时没有同时协商 CTRL_VQ 和 MQ，因此不受默认 `max_virtqueue_pairs = 1` 影响。

- [ ] **Step 2: 新建 `virtio_net_vip/tests/virtio_vq_test_kit.sv`：**
```systemverilog
`ifndef VIRTIO_VQ_TEST_KIT_SV
`define VIRTIO_VQ_TEST_KIT_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// 目录层次：tests。virtqueue 级测试公共件：一套共享支撑对象（barrier、error
// injector、wait policy、queue manager）、split/packed 队列创建、atomic ops 接线，
// 以及设备侧 used ring 写回和 packed USED 标志写回。Host memory 与 IOMMU 由调用方
// 提供（可以是测试子类），本类不拥有它们的生命周期。
class virtio_vq_test_kit extends uvm_object;
    `uvm_object_utils(virtio_vq_test_kit)

    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector    err_inj;
    virtio_wait_policy          wait_pol;
    virtqueue_manager           vq_mgr;
    int unsigned                host_id;

    function new(string name = "virtio_vq_test_kit");
        super.new(name);
    endfunction

    // 以 prefix 命名新建 barrier/err_inj/wait_pol；vq_mgr 为空时新建，否则复用调用方
    // 的 manager（例如 Function 自带的 vq_mgr）。共享引用、bdf 与 host_id 写入 manager。
    static function virtio_vq_test_kit create_kit(
        string prefix,
        host_mem_manager mem,
        virtio_iommu_model iommu,
        bit [15:0] bdf,
        int unsigned host_id = 0,
        virtqueue_manager vq_mgr = null
    );
        virtio_vq_test_kit kit;

        kit = virtio_vq_test_kit::type_id::create({prefix, "_kit"});
        kit.mem = mem;
        kit.iommu = iommu;
        kit.host_id = host_id;
        kit.barrier = virtio_memory_barrier_model::type_id::create({prefix, "_barrier"});
        kit.err_inj = virtqueue_error_injector::type_id::create({prefix, "_err_inj"});
        kit.wait_pol = virtio_wait_policy::type_id::create({prefix, "_wait_pol"});
        if (vq_mgr == null)
            vq_mgr = virtqueue_manager::type_id::create({prefix, "_vq_mgr"});
        kit.vq_mgr = vq_mgr;
        kit.vq_mgr.mem = mem;
        kit.vq_mgr.iommu = iommu;
        kit.vq_mgr.barrier = kit.barrier;
        kit.vq_mgr.err_inj = kit.err_inj;
        kit.vq_mgr.wait_pol = kit.wait_pol;
        kit.vq_mgr.bdf = bdf;
        kit.vq_mgr.host_id = host_id;
        return kit;
    endfunction

    // 独立创建（不登记到 vq_mgr）并分配一个 split 队列，供只测队列本身的用例。
    function split_virtqueue make_split(
        string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf
    );
        split_virtqueue vq;

        vq = split_virtqueue::type_id::create(name);
        vq.setup(queue_id, queue_size, mem, iommu, barrier, err_inj, wait_pol,
                 bdf, host_id);
        vq.alloc_rings();
        return vq;
    endfunction

    // 独立创建（不登记到 vq_mgr）并分配一个 packed 队列。
    function packed_virtqueue make_packed(
        string name, int unsigned queue_id, int unsigned queue_size, bit [15:0] bdf
    );
        packed_virtqueue vq;

        vq = packed_virtqueue::type_id::create(name);
        vq.setup(queue_id, queue_size, mem, iommu, barrier, err_inj, wait_pol,
                 bdf, host_id);
        vq.alloc_rings();
        return vq;
    endfunction

    // 经 vq_mgr.create_queue 登记并分配一个 split 队列，供 atomic ops 按 queue_id 查找。
    function split_virtqueue add_split(int unsigned queue_id, int unsigned queue_size);
        split_virtqueue vq;

        if (!$cast(vq, vq_mgr.create_queue(queue_id, queue_size, VQ_SPLIT)))
            `uvm_fatal("VQ_TEST_KIT", $sformatf(
                "could not create managed split queue %0d", queue_id))
        vq.alloc_rings();
        return vq;
    endfunction

    // 经 vq_mgr.create_queue 登记并分配一个 packed 队列。
    function packed_virtqueue add_packed(int unsigned queue_id, int unsigned queue_size);
        packed_virtqueue vq;

        if (!$cast(vq, vq_mgr.create_queue(queue_id, queue_size, VQ_PACKED)))
            `uvm_fatal("VQ_TEST_KIT", $sformatf(
                "could not create managed packed queue %0d", queue_id))
        vq.alloc_rings();
        return vq;
    endfunction

    // 把 ops 接到本套件的 vq_mgr/mem/iommu/wait_pol 与给定 transport；ops 为空时新建
    // 标准 virtio_atomic_ops。不修改 transport.bdf，由调用方设置。
    function virtio_atomic_ops make_ops(
        virtio_pci_transport transport, string name = "", virtio_atomic_ops ops = null
    );
        if (ops == null)
            ops = virtio_atomic_ops::type_id::create(name);
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        return ops;
    endfunction

    // 设备侧 split 完成：在 used ring 第 used_slot 槽写入小端 {id=head, len=used_len}，
    // 再把 used.idx 写为 used_idx。槽位取模与 idx 递增由调用方负责，同一函数覆盖
    // 顺序、乱序与回绕场景。
    static function void complete_split_at(
        host_mem_manager mem,
        virtqueue_base vq,
        int unsigned used_slot,
        int unsigned head,
        int unsigned used_len,
        int unsigned used_idx
    );
        byte entry[];
        byte idx_bytes[];

        entry = new[8];
        for (int unsigned i = 0; i < 4; i++) begin
            entry[i]     = head[i * 8 +: 8];
            entry[i + 4] = used_len[i * 8 +: 8];
        end
        idx_bytes = new[2];
        idx_bytes[0] = used_idx[7:0];
        idx_bytes[1] = used_idx[15:8];
        mem.write_mem(vq.device_ring_addr + 4 + used_slot * 8, entry);
        mem.write_mem(vq.device_ring_addr + 2, idx_bytes);
    endfunction

    // 设备侧 packed 完成：在描述符 head 的 flags 上置 USED 位（其余字段不变）。
    static function void complete_packed(
        host_mem_manager mem,
        virtqueue_base vq,
        int unsigned head
    );
        byte flags[];
        bit [15:0] value;

        mem.read_mem(vq.desc_table_addr + head * 16 + 14, 2, flags);
        value = {flags[1], flags[0]} | VIRTQ_DESC_F_USED;
        flags[0] = value[7:0];
        flags[1] = value[15:8];
        mem.write_mem(vq.desc_table_addr + head * 16 + 14, flags);
    endfunction
endclass : virtio_vq_test_kit

`endif // VIRTIO_VQ_TEST_KIT_SV
```

- [ ] **Step 3: 更新 filelist。** 在 `filelists/tests.f` 的
```
virtio_net_vip/tests/virtio_queue_host_mem_provider_adapter.sv
```
  之后插入：
```
// 测试公共件：无 PCIe 的 transport 替身与 virtqueue 测试 kit，须先于使用者编译。
virtio_net_vip/tests/virtio_mock_transport.sv
virtio_net_vip/tests/virtio_vq_test_kit.sv
```
  `scripts/test_manifest.sh` 只校验 dpu_common 的必需测试源在 tests.f 中恰好出现一次，不受这里影响。

- [ ] **Step 4: 确认新文件能编译。** SYNC 后用 ONE TEST 跑一次 `virtio_unit_test`，预期 0/0/0。此时这两个文件还没有使用者。

- [ ] **Step 5: 迁移 `virtio_admin_vq_test.sv`。**
  1. 删除 HEAD 9-66：两行注释 `// This transport keeps the Admin VQ test in-process...`、`class virtio_admin_vq_test_transport ... endclass`，以及其后的空行。
  2. 执行 `sed -i 's/virtio_admin_vq_test_transport/virtio_mock_transport/g; s/transport\(_for_unmap\)\?\.reset_count/transport\1.queue_reset_count/g' virtio_net_vip/tests/virtio_admin_vq_test.sv`
     这条命令会命中 HEAD 110、818、968、1324、1368、1404、1440 处的队列复位计数；`last_reset_owner.reset_count` 的前缀不同，不受影响。
  3. 删除 HEAD 299-326 的 `complete_split` 和 `complete_split_at` 两个函数，保留 `read_split_desc`。
  4. 改写调用：
     - HEAD 378 `complete_split_at(mem, vq, used_slot, head, device_response.size());` → `virtio_vq_test_kit::complete_split_at(mem, vq, used_slot, head, device_response.size(), used_slot + 1);`
     - HEAD 522 和 1212 `complete_split(mem, vq, 0, device_response.size());` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, 0, device_response.size(), 1);`
     - HEAD 1360 `complete_split(mem, vq, 0, 0);` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, 0, 0, 1);`

     旧实现只写 used.idx 的低字节（slot+1）、高字节写 0；新实现写完整的 16 位。槽位都小于 8，两者逐字节相同。
  5. 验证：`grep -nE "virtio_admin_vq_test_transport|complete_split\(|transport(_for_unmap)?\.reset_count" virtio_net_vip/tests/virtio_admin_vq_test.sv` 预期：无输出。

- [ ] **Step 6: 迁移 `virtio_indirect_desc_test.sv`。**
  1. 删除 HEAD 109-132：三行注释和 `class virtio_indirect_desc_test_transport ... endclass`。然后执行
     `sed -i 's/virtio_indirect_desc_test_transport/virtio_mock_transport/g' virtio_net_vip/tests/virtio_indirect_desc_test.sv`，
     这也会覆盖 P0-4 在三个 dataplane 子测试中新增的创建语句。
  2. 删除 HEAD 302-333 的 `complete_split` 和 `complete_packed`。
  3. 改写调用（锚点文本 → 新文本）：
     - `complete_split(mem, vq, head, 144);` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, head, 144, 1);`
     - `complete_packed(mem, vq, head);` → `virtio_vq_test_kit::complete_packed(mem, vq, head);`
     - 两处 `complete_split(mem, vq, desc_id, 0);` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, desc_id, 0, 1);`
     - 两处 `complete_split(mem, vq, filler_desc, 0);` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, filler_desc, 0, 1);`
     - `complete_split(mem, split_vq, split_desc, 0);` → `virtio_vq_test_kit::complete_split_at(mem, split_vq, 0, split_desc, 0, 1);`
     - `complete_packed(mem, packed_vq, 0);` 与 `complete_packed(mem, packed_vq, 2);` → `virtio_vq_test_kit::complete_packed(mem, packed_vq, 0);` 与 `virtio_vq_test_kit::complete_packed(mem, packed_vq, 2);`
     - `complete_split(mem, vq, 0, frame.size());` → `virtio_vq_test_kit::complete_split_at(mem, vq, 0, 0, frame.size(), 1);`
     - P0-4 新增的 `test_dataplane_engine_notifies_device` 中如果有 `complete_split(mem, <vq>, <head>, <len>);`，统一改成 `virtio_vq_test_kit::complete_split_at(mem, <vq>, 0, <head>, <len>, 1);`。
  4. 把 `test_atomic_rx_num_buffers_without_mrg` 中注释 `// Complete the second buffer as used entry 1 ...` 后面的 `begin ... end` 块（HEAD 1069-1087）替换为：
```systemverilog
        begin
            read_desc(mem, vq.desc_table_addr, 1, addr, len, flags, next);
            frame[10] = 8'h01;
            assert(iommu.write_from_device_for_host(0, mem, 16'h0705, addr, frame, fault))
                else `uvm_fatal("INDIRECT_TEST", "device RX write failed")
            virtio_vq_test_kit::complete_split_at(mem, vq, 1, 1, frame.size(), 2);
        end
```
     旧代码写入的是 id=1、len=frame.size() 的低 32 位、used.idx=2，与上面这行逐字节相同。
  5. 验证：`grep -nE "(^|[^:])complete_split\(|(^|[^:])complete_packed\(|used_entry|virtio_indirect_desc_test_transport" virtio_net_vip/tests/virtio_indirect_desc_test.sv` 预期：无输出。

- [ ] **Step 7: 迁移 `virtio_pf_lifecycle_reset_test.sv`。** 删除 HEAD 9-38：三行注释和 `class virtio_pf_lifecycle_test_transport ... endclass`。然后执行
  `sed -i 's/virtio_pf_lifecycle_test_transport/virtio_mock_transport/g' virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv`。

- [ ] **Step 8: 迁移 `virtio_migration_dirty_test.sv`。**
  1. HEAD 8-96（注释和整个 `virtio_migration_dirty_test_transport` 类）替换为：
```systemverilog
// 迁移恢复路径要求“已验证复位”后设备状态读回 0；其余寄存器模型（状态读写、
// net config、队列编程记录、num_max）沿用公共 mock transport。
class virtio_migration_dirty_test_transport extends virtio_mock_transport;
    `uvm_object_utils(virtio_migration_dirty_test_transport)

    function new(string name = "virtio_migration_dirty_test_transport");
        super.new(name);
    endfunction

    virtual task reset_device_verified(ref bit reset_complete);
        super.reset_device_verified(reset_complete);
        mock_status = '0;
    endtask
endclass : virtio_migration_dirty_test_transport
```
     旧字段 `device_status` 只在类内使用。测试用到的 `device_reset_complete`（HEAD 2017）、`queue_num_max`（HEAD 1318）、`get_programmed_queue`（HEAD 1348、1426）在基类中都有同名成员。
  2. 删除 HEAD 1593-1625 的 `publish_split_tx_completion` 和 `publish_packed_tx_completion`。
  3. `publish_tx_completion` 的函数体（HEAD 1634-1638）：
```systemverilog
        if (vq_type == VQ_SPLIT)
            publish_split_tx_completion(mem, vq, completion_index,
                                        descriptor_or_head);
        else
            publish_packed_tx_completion(mem, vq, descriptor_or_head);
```
     改为：
```systemverilog
        if (vq_type == VQ_SPLIT)
            virtio_vq_test_kit::complete_split_at(
                mem, vq, completion_index - 1, descriptor_or_head, 0,
                completion_index);
        else
            virtio_vq_test_kit::complete_packed(mem, vq, descriptor_or_head);
```
     旧 packed 版本先读出 16 字节描述符，执行 `descriptor[15] |= 8'h80` 后整体写回，也就是把 flags 的 bit15（即 `VIRTQ_DESC_F_USED`）置位，结果与 `complete_packed` 相同。

- [ ] **Step 9: 迁移 P0 新增的两个桩。**
  1. `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`（P0-2 创建）：删除 `class virtio_ctrl_vq_test_transport ... endclass : virtio_ctrl_vq_test_transport` 及其前面两行注释
     （`// 寄存器桩：common-config 访问只记录、不发 TLP；read_net_config 返回可编程的` 和 `// max_virtqueue_pairs，用于验证 controlq 按 2*max_virtqueue_pairs 编号。`）。然后执行
     `sed -i 's/virtio_ctrl_vq_test_transport/virtio_mock_transport/g; s/transport\.max_virtqueue_pairs\b/transport.mock_net_config.max_virtqueue_pairs/g' virtio_net_vip/tests/virtio_ctrl_vq_test.sv`
     （旧桩的 `max_virtqueue_pairs` 默认 1、`read_queue_num_max` 返回 8，与 mock 的默认值相同；`programmed_qids`、`kick_count` 同名。）
  2. `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`（P0-4 加入）：删除注释
     `// 中文说明：数据面委托 atomic ops 后会经 transport 发 notify；本测试不建 PCIe` 和 `// 通路，用最小 transport 只记录每个队列的 notify 次数，不产生寄存器访问。`，
     删除类 `virtio_net_packet_mq_test_transport ... endclass`，然后执行 `sed -i 's/virtio_net_packet_mq_test_transport/virtio_mock_transport/g' virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`
     （`transport.kicks(qid)` 由 mock 的同名方法提供）。

- [ ] **Step 10: 迁移其余的完成写回。**
  1. `virtio_host_mem_reclaim_test.sv`：删除 HEAD 112-137 的 `write_used_entry` task；把 HEAD 195-196
     `write_used_entry(vq, i, desc_ids[i], 64,` / `used_idx + 1, host0_mem);` 改为 `virtio_vq_test_kit::complete_split_at(host0_mem, vq, i, desc_ids[i], 64, used_idx + 1);`。
  2. `virtio_queue_semantics_test.sv`：删除 HEAD 58-79 的 `write_split_used` task；把 HEAD 119
     `write_split_used(vq, i, desc_ids[i], device_used_idx + 1);` 改为 `virtio_vq_test_kit::complete_split_at(mem, vq, i, desc_ids[i], 256, device_used_idx + 1);`。旧代码的 len 字节是 `{0,1,0,0}`，即 256。
  3. `virtio_net_packet_multi_queue_test.sv`：删除 HEAD 89-115 的 `write_used_entry` 函数。把 HEAD 282-283
     `write_used_entry(queues[qid], i, tx_descs[qid][i],` / `10 + tx_packets[qid][i].pkt.raw_data.size(), i + 1);` 改为
     `virtio_vq_test_kit::complete_split_at(mem, queues[qid], i, tx_descs[qid][i], 10 + tx_packets[qid][i].pkt.raw_data.size(), i + 1);`；
     把 HEAD 329 `write_used_entry(queues[qid], i, desc_id, rx_data.size(), i + 1);` 改为 `virtio_vq_test_kit::complete_split_at(mem, queues[qid], i, desc_id, rx_data.size(), i + 1);`。
     旧代码分两次写 id 和 len，新代码一次写 8 字节，最终的内存内容相同。
  4. `virtio_traffic_test.sv`：
     在 `test_queue_stress` 中，把注释 `// Simulate device processing all 256 entries` 之后的 for 循环（HEAD 1147-1167）替换为：
```systemverilog
            for (int unsigned i = 0; i < desc_ids.size(); i++) begin
                virtio_vq_test_kit::complete_split_at(
                    mem, vq, used_idx % queue_size, desc_ids[i], 128, used_idx + 1);
                used_idx++;
            end
```
     在 `test_mixed_queue_types` 中，把注释 `// Simulate device processing for split queue` 之后的 `begin ... end` 块（HEAD 1318-1341）替换为：
```systemverilog
            begin
                int unsigned used_idx = 0;
                for (int unsigned i = 0; i < split_desc_ids.size(); i++) begin
                    virtio_vq_test_kit::complete_split_at(
                        mem, split_vq, used_idx % split_queue_size,
                        split_desc_ids[i], 0, used_idx + 1);
                    used_idx++;
                end
            end
```
     以下 packed 队列的完成路径保持不动：traffic 中从 HEAD 1396 开始的段、`queue_semantics` 的 HEAD 150-165、`traffic` 的 HEAD 400-425。
     它们会同时改写 AVAIL 和 USED 两位，语义与 `complete_packed` 不同。

- [ ] **Step 11: 用 grep 收集证据。**
  `grep -rnE "class virtio_(admin_vq|indirect_desc|pf_lifecycle|ctrl_vq|net_packet_mq)_test_transport|function void complete_split|task write_used_entry|function void write_used_entry|task write_split_used|publish_split_tx_completion|publish_packed_tx_completion|function void complete_packed" virtio_net_vip/tests`
  预期：无输出。
  `grep -rln "extends virtio_pci_transport" virtio_net_vip/tests` 预期：只有 `virtio_net_vip/tests/virtio_mock_transport.sv`。

- [ ] **Step 12: SYNC 后跑测试。** 用 ONE TEST 跑 `virtio_admin_vq_test`、`virtio_indirect_desc_test`、`virtio_migration_dirty_test`、`virtio_pf_lifecycle_reset_test`、`virtio_ctrl_vq_test`、
  `virtio_host_mem_reclaim_test`、`virtio_queue_semantics_test`、`virtio_net_packet_multi_queue_test`、`virtio_traffic_test`，均应为 0/0/0。

- [ ] **Step 13: 跑 REGRESSION。**

- [ ] **Step 14: 提交。**
  `git add filelists/tests.f virtio_net_vip/tests/virtio_mock_transport.sv virtio_net_vip/tests/virtio_vq_test_kit.sv virtio_net_vip/tests/virtio_admin_vq_test.sv virtio_net_vip/tests/virtio_indirect_desc_test.sv virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv virtio_net_vip/tests/virtio_migration_dirty_test.sv virtio_net_vip/tests/virtio_ctrl_vq_test.sv virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv virtio_net_vip/tests/virtio_queue_semantics_test.sv virtio_net_vip/tests/virtio_traffic_test.sv`
  `git commit -m "test: 新增 virtio_mock_transport 与 virtio_vq_test_kit，合并 transport 桩和完成写回实现"`

---

### Task P2-8b: 用 `virtio_vq_test_kit` 替换测试中的组件创建与接线样板

范围核查：以 HEAD 中全部 29 处 `virtio_memory_barrier_model::type_id::create`，加上 P0-4 新增的 `test_dataplane_engine_notifies_device` 为准。处理方式如下：

| 文件:任务 | 处理 |
|---|---|
| desc_corruption:build_phase（4 个队列） | b1 迁移 |
| stress_unit:3 个任务 | b1 迁移 |
| queue_semantics:build_phase（2 个队列） | b1 迁移 |
| unit:test_split_virtqueue | b1 迁移 |
| host_mem_reclaim:test_split_queue_reclaim | b1 迁移，只迁支撑对象；队列需要 reset 后重新 setup，保留手工 setup |
| indirect_desc:9 个任务（含 P0-4 新增的 1 个） | b2 迁移 |
| admin_vq:configure_admin_context | b2 迁移 |
| traffic:3 个任务 | b3 迁移 |
| net_packet_multi_queue:run_phase | b3 迁移 |
| dual:build_phase 以及 4 个任务中的 16 个队列 | b3 迁移。vq_mgr_a/b 保持独立：它们的 bdf 为 0，供 Function 绑定使用，改由 kit 设置 bdf 会改变 IOMMU 键 |
| pf_lifecycle:3 个任务（HEAD 462、613、714） | b4 迁移 |
| migration_dirty:setup_outstanding_ownership_context | b4 迁移 |
| migration_dirty:run_production_ring_restore_uses_setup_rings（HEAD 1306-1322） | **不迁移**：vq_mgr 只接了 barrier，err_inj/wait_pol 是有意留空的，kit 会把它们补齐，改变队列行为 |
| full_test:build_phase | **不迁移**：P4.2 会整体重写这个测试的设备建模 |
| 只做部分接线、不创建 barrier 的站点（pf_lifecycle HEAD 569、778；migration HEAD 611、727、826、950、1085；unit HEAD 315；admin HEAD 632、700；dut_caps HEAD 3042） | **不迁移**：这些站点有意只接部分字段（例如不接 mem/wait_pol，用来覆盖“上下文不完整”的分支），kit 的完整接线会改变被测分支 |

每个子任务都以这几步结束：grep 收集证据 → SYNC → 跑受影响的测试 → REGRESSION → 提交。

#### Task P2-8b1: 独立队列测试

**Files:** `virtio_net_vip/tests/virtio_desc_corruption_test.sv:17-19,32-36,74-76,156-158,220-222,300-302`、`virtio_net_vip/tests/virtio_stress_unit_test.sv:54-56,63-65,169-171,177-179,213-215,222-228`、
`virtio_net_vip/tests/virtio_queue_semantics_test.sv:20-22,41-43,85-88,172-175`、`virtio_net_vip/tests/virtio_unit_test.sv:518-520,526-528`、`virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv:141-143,147-149,153-154,163-164`
**Test:** `virtio_desc_corruption_test`、`virtio_stress_unit_test`、`virtio_queue_semantics_test`、`virtio_unit_test`、`virtio_host_mem_reclaim_test`
**Interfaces:** Consumes P2-8a 的 `create_kit`、`make_split`、`make_packed`。

- [ ] **Step 1: desc_corruption。** 把成员 HEAD 17-19 的三行（`barrier`、`err_inj`、`wait_pol`）替换为 `    virtio_vq_test_kit            kit;`。
  把 build_phase 中 HEAD 32-36 的三个 create 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("corruption", mem, iommu, 16'h1500);
```
  四个队列：
  - HEAD 74-76 → `        vq = kit.make_split("any_phase_split_vq", 3, 4, 16'h1503);`
  - HEAD 156-158 → `        vq = kit.make_split("corruption_split_vq", 0, 8, 16'h1500);`
  - HEAD 220-222 → `        vq = kit.make_packed("corruption_packed_vq", 1, 8, 16'h1501);`
  - HEAD 300-302 → `        vq = kit.make_split("timed_split_vq", 2, 4, 16'h1502);`

  剩余的 `err_inj.` 引用用 sed 统一改：`sed -i 's/\berr_inj\./kit.err_inj./g' virtio_net_vip/tests/virtio_desc_corruption_test.sv`。
  验证：`grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol)\b" virtio_net_vip/tests/virtio_desc_corruption_test.sv` 预期：无输出。

- [ ] **Step 2: stress_unit。**
  `test_large_descriptor_count`：HEAD 54-56 的三行声明替换为 `        virtio_vq_test_kit kit;`；HEAD 63-65 替换为
```systemverilog
        kit = virtio_vq_test_kit::create_kit("ld", mem, iommu, 16'h0100);
        vq = kit.make_split("ld_vq", 0, queue_size, 16'h0100);
```
  `test_packed_virtqueue`：HEAD 169-171 替换为 `        virtio_vq_test_kit kit;`；HEAD 177-179 替换为
```systemverilog
        kit = virtio_vq_test_kit::create_kit("pq", mem, iommu, 16'h0300);
        vq = kit.make_packed("pq", 0, 32, 16'h0300);
```
  `test_virtqueue_manager`：HEAD 213-215 替换为 `        virtio_vq_test_kit kit;`；HEAD 222-228 替换为
```systemverilog
        kit = virtio_vq_test_kit::create_kit("vm", mem, iommu, 16'h0400);
        mgr = kit.vq_mgr;
```
  之后直接测试 `mgr.create_queue` 的代码保持不变。
  验证：`grep -nE "\b(barrier|err_inj|wait_pol)\b" virtio_net_vip/tests/virtio_stress_unit_test.sv` 预期：无输出。

- [ ] **Step 3: queue_semantics。** 成员 HEAD 20-22 替换为 `    virtio_vq_test_kit kit;`；build_phase 中 HEAD 41-43 替换为
  `        kit = virtio_vq_test_kit::create_kit("queue", mem, iommu, 16'h0100);`；
  HEAD 85-88 替换为 `        vq = kit.make_split("semantic_split_vq", 0, QUEUE_SIZE, 16'h0100);`；
  HEAD 172-175 替换为 `        vq = kit.make_packed("semantic_packed_vq", 1, QUEUE_SIZE, 16'h0100);`。
  验证：`grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol)\b" virtio_net_vip/tests/virtio_queue_semantics_test.sv` 预期：无输出。

- [ ] **Step 4: unit 的 `test_split_virtqueue`。** HEAD 518-520 替换为 `        virtio_vq_test_kit kit;`；HEAD 526-528 替换为
```systemverilog
        kit = virtio_vq_test_kit::create_kit("sq", mem, iommu, 16'h0100);
        vq = kit.make_split("vq", 0, 16, 16'h0100);
```

- [ ] **Step 5: host_mem_reclaim 的 `test_split_queue_reclaim`。** HEAD 141-143 替换为 `        virtio_vq_test_kit kit;`；HEAD 147-149 替换为
  `        kit = virtio_vq_test_kit::create_kit("reclaim", host0_mem, iommu, 16'h0100);`。
  HEAD 153-154 和 163-164 两处
  `vq.setup(0, QUEUE_SIZE, host0_mem, iommu, barrier, err_inj,` / `wait_pol, 16'h0100, 0);` 都改为
  `vq.setup(0, QUEUE_SIZE, host0_mem, iommu, kit.barrier, kit.err_inj,` / `kit.wait_pol, 16'h0100, 0);`。

- [ ] **Step 6: SYNC 后用 ONE TEST 跑这 5 个测试，再跑 REGRESSION。**
- [ ] **Step 7: 提交。** `git add virtio_net_vip/tests/virtio_desc_corruption_test.sv virtio_net_vip/tests/virtio_stress_unit_test.sv virtio_net_vip/tests/virtio_queue_semantics_test.sv virtio_net_vip/tests/virtio_unit_test.sv virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv`
  `git commit -m "test: 独立队列测试改用 virtio_vq_test_kit 创建支撑对象与队列"`

#### Task P2-8b2: indirect_desc 与 admin_vq

**Files:** `virtio_net_vip/tests/virtio_indirect_desc_test.sv`（9 个任务，见下）、`virtio_net_vip/tests/virtio_admin_vq_test.sv:391-409,416`
**Test:** `virtio_indirect_desc_test`、`virtio_admin_vq_test`
**Interfaces:** Consumes P2-8a 的 `create_kit`、`make_split`、`make_packed`、`add_split`、`add_packed`、`make_ops`。

下面每个任务都先做同样的声明替换：
- 把带初始化的声明 `virtio_memory_barrier_model barrier = ...;`、`virtqueue_error_injector err_inj = ...;`、`virtio_wait_policy wait_pol = ...;`
  （每条占一到两行），连同 `virtqueue_manager vq_mgr = ...;`，整体替换为一行 `        virtio_vq_test_kit kit;`。
- 把带初始化的 `virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("...");` 改为 `        virtio_atomic_ops ops;`。
- 删除 `virtqueue_base base_vq;`。

然后按各步骤替换 `mem = shared_mem;` 之后的接线代码：

- [ ] **Step 1: `test_split_indirect_descriptor`。** HEAD 359-361 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("split", mem, iommu, 16'h0700);
        vq = kit.make_split("split_vq", 0, 16, 16'h0700);
```
- [ ] **Step 2: `test_packed_indirect_descriptor`。** HEAD 477-479 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("packed", mem, iommu, 16'h0701);
        vq = kit.make_packed("packed_vq", 1, 16, 16'h0701);
```
- [ ] **Step 3: `test_tx_indirect_feature_gate`。** HEAD 598-614（从 `vq_mgr.mem = mem;` 到 `ops.wait_pol = wait_pol;`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("tx_gate", mem, iommu, 16'h0702);
        vq = kit.add_split(0, 16);
        transport.bdf = 16'h0702;
        ops = kit.make_ops(transport, "tx_gate_ops");
```
- [ ] **Step 4: `test_dataplane_tx_indirect_feature_gate`。** HEAD 667-676（从 `vq_mgr.mem = mem;` 到 `vq.alloc_rings();`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("dataplane_gate", mem, iommu, 16'h0703);
        vq = kit.add_split(0, 16);
```
  P0-4 在这个任务中加入了五行 `ops.transport = transport;` … `ops.wait_pol = wait_pol;`，替换为 `        ops = kit.make_ops(transport, "dataplane_gate_ops");`；
  后面的 `ops.negotiated_features = features;` 和 `dataplane.bind_ops(ops);` 保留。
  两处 `dataplane.configure(..., vq_mgr, mem, iommu, 16'h0703);` 中的 `vq_mgr` 都改为 `kit.vq_mgr`。
- [ ] **Step 5: `test_atomic_tx_queue_full_cleanup`。** HEAD 748-764 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("atomic_full", mem, iommu, 16'h0704);
        vq = kit.add_split(0, 2);
        transport.bdf = 16'h0704;
        ops = kit.make_ops(transport, "atomic_full_ops");
```
- [ ] **Step 6: `test_dataplane_tx_queue_full_cleanup`。** HEAD 834-843 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("dataplane_full", mem, iommu, 16'h0705);
        vq = kit.add_split(0, 2);
```
  P0-4 加入的五行 `ops.transport = transport;` … `ops.wait_pol = wait_pol;` 替换为 `        ops = kit.make_ops(transport, "dataplane_full_ops");`。
  `dataplane.configure(..., vq_mgr, mem, iommu, 16'h0705);` 中的 `vq_mgr` 改为 `kit.vq_mgr`。
- [ ] **Step 7: `test_atomic_notify_cursor`。** HEAD 921-941 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("cursor", mem, iommu, 16'h0704);
        split_vq = kit.add_split(0, 16);
        packed_vq = kit.add_packed(1, 4);
        transport.bdf = 16'h0704;
        ops = kit.make_ops(transport, "cursor_ops");
```
- [ ] **Step 8: `test_atomic_rx_num_buffers_without_mrg`。** HEAD 1026-1042 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("rx_nomrg", mem, iommu, 16'h0705);
        vq = kit.add_split(0, 16);
        transport.bdf = 16'h0705;
        ops = kit.make_ops(transport, "rx_nomrg_ops");
```
- [ ] **Step 9: P0-4 新增的 `test_dataplane_engine_notifies_device`。** 先按上面的规则替换声明。然后把从 `vq_mgr.mem = mem;` 到 `ops.wait_pol = wait_pol;` 的部分
  （包括 `base_vq = vq_mgr.create_queue(1, 8, VQ_SPLIT);`、`$cast`、`tx_vq.alloc_rings();`、`transport.bdf = 16'h0706;`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("dataplane_notify", mem, iommu, 16'h0706);
        tx_vq = kit.add_split(1, 8);
        transport.bdf = 16'h0706;
        ops = kit.make_ops(transport, "dataplane_notify_ops");
```
  该任务中 `dataplane.configure(..., vq_mgr, mem, iommu, 16'h0706);` 的 `vq_mgr` 改为 `kit.vq_mgr`。
  逐个任务核对过：被替换的接线块之后，这些任务中再没有引用 `barrier`、`err_inj`、`wait_pol`、`base_vq`；`ops` 的其他字段（如 `negotiated_features`）仍在原位置之后照常赋值。
- [ ] **Step 10: 验证 indirect。** `grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol|base_vq)\b|(^|[^.])vq_mgr\b|ops\.(transport|vq_mgr|mem|iommu|wait_pol) =" virtio_net_vip/tests/virtio_indirect_desc_test.sv` 预期：无输出。

- [ ] **Step 11: admin 的 `configure_admin_context`。** HEAD 391-393 的三行声明替换为 `        virtio_vq_test_kit          kit;`；删除 HEAD 397-399 的三个 create；
  删除 HEAD 401 的 `vq = split_virtqueue::type_id::create("admin_split_vq");`。HEAD 403-409 改为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("admin", mem, iommu, 16'h0708);
        mem.init_region(64'h7100_0000, 64'h7103_FFFF);
        kit.wait_pol.default_poll_interval_ns = 1;
        kit.wait_pol.default_timeout_ns = 8;
        kit.wait_pol.max_poll_attempts = 16;
        transport.bdf = 16'h0708;
        vq = kit.make_split("admin_split_vq", 7, 8, 16'h0708);
```
  HEAD 416 的 `ctx.wait_pol = wait_pol;` 改为 `ctx.wait_pol = kit.wait_pol;`。
  验证：`sed -n '/task configure_admin_context/,/endtask/p' virtio_net_vip/tests/virtio_admin_vq_test.sv | grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol)\b"` 预期：无输出。

- [ ] **Step 12: SYNC 后跑** `virtio_indirect_desc_test` 和 `virtio_admin_vq_test`，再跑 REGRESSION。
- [ ] **Step 13: 提交。** `git add virtio_net_vip/tests/virtio_indirect_desc_test.sv virtio_net_vip/tests/virtio_admin_vq_test.sv`
  `git commit -m "test: indirect_desc 与 admin_vq 改用 virtio_vq_test_kit 接线"`

#### Task P2-8b3: traffic、net_packet_multi_queue、dual

**Files:** `virtio_net_vip/tests/virtio_traffic_test.sv:433-435,467-469,474-481,499,503,1075-1077,1088-1090,1100-1102,1222-1224,1243-1245,1249-1255`、
`virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv:32-35,218-221,232-248`（以及 P0-4 加入的 ops 接线、后续的 `vq_mgr` 引用）、
`virtio_net_vip/tests/virtio_dual_test.sv:116,120-121,128,132-133,233,237-238,247,251-252,876-890,1096-1110,1266-1280,1507-1521`（以及 connect_phase 中的 `barrier_*`、`err_inj_*`、`wait_pol_*`）
**Test:** `virtio_traffic_test`、`virtio_net_packet_multi_queue_test`、`virtio_dual_test`

- [ ] **Step 1: traffic 的 `test_large_traffic`。** HEAD 433-435 替换为 `        virtio_vq_test_kit kit;`；HEAD 467-469 替换为
  `        kit = virtio_vq_test_kit::create_kit("lt", mem, iommu, 16'h0100);`；HEAD 474-476 替换为 `        txq = kit.make_split("lt_txq", 1, queue_size, 16'h0100);`；
  HEAD 479-481 替换为 `        rxq = kit.make_split("lt_rxq", 0, queue_size, 16'h0100);`。
  批次循环中 HEAD 499 和 503 两处 `setup(..., mem, iommu, barrier, err_inj, wait_pol, 16'h0100);` 改为 `setup(..., mem, iommu, kit.barrier, kit.err_inj, kit.wait_pol, 16'h0100);`。
- [ ] **Step 2: traffic 的 `test_queue_stress`。** HEAD 1075-1077 替换为 `        virtio_vq_test_kit kit;`；HEAD 1088-1090 替换为
  `        kit = virtio_vq_test_kit::create_kit("qs", mem, iommu, 16'h0100);`；HEAD 1100-1102 替换为
  `            vq = kit.make_split($sformatf("qs_vq_%0d", cycle), 0, queue_size, 16'h0100);`。
- [ ] **Step 3: traffic 的 `test_mixed_queue_types`。** HEAD 1222-1224 替换为 `        virtio_vq_test_kit kit;`；删除 HEAD 1243-1245；HEAD 1249-1255 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("mq", mem, iommu, 16'h0500);
        mgr = kit.vq_mgr;
```
  之后直接测试 `mgr.create_queue` 的代码保持不变。
  验证：`grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol)\b" virtio_net_vip/tests/virtio_traffic_test.sv` 预期：无输出。
- [ ] **Step 4: net_packet_multi_queue。** 成员 HEAD 32-35 替换为 `    virtio_vq_test_kit       kit;`；删除 run_phase 中 HEAD 218-221。
  HEAD 232-248（从 `vq_mgr.mem = mem;` 到四个队列循环的 `end`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit("multi_queue", mem, iommu, DEVICE_BDF);

        // Four independent split queues, each with four outstanding packets.
        for (int unsigned qid = 0; qid < 4; qid++) begin
            queues[qid] = kit.add_split(qid, QUEUE_SIZE);
            assert(queues[qid].get_free_count() == QUEUE_SIZE)
                else `uvm_fatal("NET_PACKET_TEST", "queue ring allocation failed")
        end
```
  P0-4 加入的 ops 接线：
```systemverilog
          ops = virtio_atomic_ops::type_id::create("multi_queue_ops");
          ops.transport = transport;
          ops.vq_mgr = vq_mgr;
          ops.mem = mem;
          ops.iommu = iommu;
          ops.wait_pol = wait_pol;
```
  替换为 `        ops = kit.make_ops(transport, "multi_queue_ops");`。
  剩余的 `vq_mgr` 引用（`dataplane.configure(...)` 的参数、`vq_mgr.leak_check();`）执行
  `sed -i 's/\([^._a-z]\)vq_mgr\b/\1kit.vq_mgr/g' virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv` 统一改为 `kit.vq_mgr`。
  验证：`grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol|vq_mgr)\b" virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv` 预期：无输出。
- [ ] **Step 5: dual。**
  成员：删除 HEAD 116 `virtio_wait_policy    wait_pol_a;`、HEAD 120-121（`barrier_a`、`err_inj_a`）、HEAD 128 `wait_pol_b`、HEAD 132-133（`barrier_b`、`err_inj_b`）。
  在 `virtio_function_instance binding_function_a;` 之后加 `    virtio_vq_test_kit    kit_a;`，在 `binding_function_b;` 之后加 `    virtio_vq_test_kit    kit_b;`。
  build_phase：删除 HEAD 233、237、238、247、251、252 这六行 create。在 HEAD 235 `iommu_a = ...` 之后加
  `        kit_a       = virtio_vq_test_kit::create_kit("dual_a", mem_a, iommu_a, 16'h0100);`，在 HEAD 249 `iommu_b = ...` 之后加
  `        kit_b       = virtio_vq_test_kit::create_kit("dual_b", mem_b, iommu_b, 16'h0200);`。
  然后执行 `sed -i 's/\bbarrier_\([ab]\)\b/kit_\1.barrier/g; s/\berr_inj_\([ab]\)\b/kit_\1.err_inj/g; s/\bwait_pol_\([ab]\)\b/kit_\1.wait_pol/g' virtio_net_vip/tests/virtio_dual_test.sv`。
  这条命令覆盖 connect_phase 中 `wire_shared` 的实参，以及 `wait_pol_a/b.*` 的超时设置。
  16 组队列创建原本每组三行：`xxx = split_virtqueue::type_id::create("<name>");` / `xxx.setup(<qid>, <size>, mem_?, iommu_?, kit_?.barrier, kit_?.err_inj, kit_?.wait_pol, <bdf>);` / `xxx.alloc_rings();`。每组替换为一行：
  - HEAD 876-890：`txq_a = kit_a.make_split("txq_a", 1, queue_size_a, 16'h0100);`、`rxq_a = kit_a.make_split("rxq_a", 0, queue_size_a, 16'h0100);`、
    `txq_b = kit_b.make_split("txq_b", 1, queue_size_b, 16'h0200);`、`rxq_b = kit_b.make_split("rxq_b", 0, queue_size_b, 16'h0200);`
  - HEAD 1096-1110：同上，名称后缀为 `_vs`，长度为 `queue_size`
  - HEAD 1266-1280：同上，名称后缀为 `_ws`，长度为 `queue_size`
  - HEAD 1507-1521：同上，名称后缀为 `_bw`，长度为 `queue_size`

  各组之间的空行保留。vq_mgr_a/b 不经过 kit，原因见本任务开头的范围表。
  验证：`grep -nE "\b(barrier|err_inj|wait_pol)_[ab]\b|split_virtqueue::type_id::create" virtio_net_vip/tests/virtio_dual_test.sv` 预期：无输出。
- [ ] **Step 6: SYNC 后跑** `virtio_traffic_test`、`virtio_net_packet_multi_queue_test`、`virtio_dual_test`，再跑 REGRESSION。
- [ ] **Step 7: 提交。** `git add virtio_net_vip/tests/virtio_traffic_test.sv virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv virtio_net_vip/tests/virtio_dual_test.sv`
  `git commit -m "test: traffic、net_packet_multi_queue、dual 改用 virtio_vq_test_kit 建队列"`

#### Task P2-8b4: pf_lifecycle_reset 与 migration_dirty

**Files:** `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv:469-471,483-488,493,513-525,620-622,641-646,656-675,717,720-722,732,737-742,749-761`、
`virtio_net_vip/tests/virtio_migration_dirty_test.sv:1532-1534,1547-1554,1558-1567`
**Test:** `virtio_pf_lifecycle_reset_test`、`virtio_migration_dirty_test`

- [ ] **Step 1: `test_pf_reset_waits_for_real_dataplane_worker`。** HEAD 469-471 替换为 `        virtio_vq_test_kit                  kit;`；删除 HEAD 483-488 的三个 create；
  删除 HEAD 493 的 `wait_pol.default_poll_interval_ns = 10;`。HEAD 513-525（从 `pf_function.vq_mgr.mem = mem;` 到 `ops.wait_pol = wait_pol;`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit(
            "real_worker_reset", mem, iommu, transport.bdf,
            pf_function.vq_mgr.host_id, pf_function.vq_mgr);
        kit.wait_pol.default_poll_interval_ns = 10;
        void'(kit.add_split(0, cfg.queue_size));
        void'(kit.add_split(1, cfg.queue_size));
        void'(kit.make_ops(transport, "", ops));
```
  它前面的 `pf_function.transport = transport;` 和 `transport.bdf = 16'h0030;` 保持不变。`host_id` 取 Function 自己的值，与原来一致。
- [ ] **Step 2: `test_verified_reset_retires_pending_normal_dma`。** HEAD 620-622 替换为 `        virtio_vq_test_kit                  kit;`；删除 HEAD 641-646。
  HEAD 656-675（从 `pf_function.vq_mgr.mem = mem;` 到 `ops.wait_pol = wait_pol;`，包括中间的 `ring_allocation_count = ...` 行）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit(
            "pending_dma_reset", mem, iommu, transport.bdf,
            pf_function.vq_mgr.host_id, pf_function.vq_mgr);
        rx_vq = kit.add_split(0, 8);
        tx_vq = kit.add_split(1, 8);
        ring_allocation_count = mem.outstanding_allocations();

        void'(kit.make_ops(transport, "", ops));
```
- [ ] **Step 3: `test_tx_second_allocation_failure_releases_header`。** HEAD 717 的 `virtqueue_manager vq_mgr;` 和 HEAD 720-722 的三行，一起替换为 `        virtio_vq_test_kit                   kit;`。
  删除 HEAD 732 的 `vq_mgr = ...create(...)` 和 HEAD 737-742 的三个 create。HEAD 749-761 替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit(
            "tx_second_alloc_fail", mem, iommu, transport.bdf);
        // 16 字节的 Host memory 只够 header，队列只登记不分配 ring。
        assert(kit.vq_mgr.create_queue(0, 8, VQ_SPLIT) != null)
            else `uvm_fatal("PF_LIFECYCLE", "failed to create TX allocation rollback queue")
        void'(kit.make_ops(transport, "", ops));
```
  验证：`grep -nE "(^|[^.])\b(barrier|err_inj|wait_pol)\b|vq_mgr\.(mem|iommu|barrier|err_inj|wait_pol|bdf) =" virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv` 预期：无输出。
  HEAD 569 和 778 两个任务只接了部分字段（只有 `ops.transport/vq_mgr/iommu`），保持原样。
- [ ] **Step 4: migration 的 `setup_outstanding_ownership_context`。** HEAD 1532-1534 替换为 `        virtio_vq_test_kit         kit;`；删除 HEAD 1547-1554（vq_mgr、barrier、err_inj、wait_pol 四个 create）。
  HEAD 1558-1567（从 `vq_mgr.mem = mem;` 到 `ops.wait_pol = wait_pol;`）替换为：
```systemverilog
        kit = virtio_vq_test_kit::create_kit(
            context_name, mem, iommu, transport.bdf);
        vq_mgr = kit.vq_mgr;
        void'(kit.make_ops(transport, "", ops));
```
  `vq_mgr` 是 ref 输出参数，调用方会继续使用它；之后的 `ops.use_full_queue_pair_setup = 1;` 等赋值保持不变。
- [ ] **Step 5: SYNC 后跑** `virtio_pf_lifecycle_reset_test` 和 `virtio_migration_dirty_test`，再跑 REGRESSION。
- [ ] **Step 6: 提交。** `git add virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv virtio_net_vip/tests/virtio_migration_dirty_test.sv`
  `git commit -m "test: pf_lifecycle_reset 与 migration_dirty 的完整接线改用 virtio_vq_test_kit"`

---

### Task P2-8c: 把 `virtio_perf_monitor_ext` 并入 `virtio_perf_monitor`

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_perf_monitor.sv:126`：在 `on_sent` 的 `endfunction` 之后新增常量和三个函数
- Modify: `virtio_net_vip/tests/virtio_dual_test.sv:29-99,142,263-264`
- Modify: `README.md:896`
- Test: `virtio_dual_test`

**Spec deviation:** 规范只点名了 `configure_bw()`。但 `virtio_perf_monitor_ext` 还有 `reset_stats()` 和 `advance_logical_refill()`，如果只迁移 `configure_bw`，这个子类仍得保留。
这三个函数都只操作 monitor 自己的统计数据和令牌桶，所以一并上移，然后删除子类。`build_phase` 中的 1ms 初始桶不改，env 路径行为不变；`configure_bw` 继续使用子类原来的 100us 窗口。

**Interfaces:**
- Produces：`virtio_perf_monitor::configure_bw(int unsigned mbps)`、`reset_stats()`、`advance_logical_refill(int unsigned bytes)`（返回逻辑等待时间，单位 ns），以及 `localparam BW_BURST_WINDOW_NS = 100_000`。

- [ ] **Step 1: 在 `virtio_perf_monitor.sv` 中 `on_sent` 之后（HEAD 126 的 `endfunction` 之后）插入：**
```systemverilog

    // ========================================================================
    // 运行时重配 -- build_phase 只在构建时初始化令牌桶；运行中改带宽需调用这里
    // ========================================================================

    localparam int unsigned BW_BURST_WINDOW_NS = 100_000;

    // 按 mbps 重配限速：令牌桶容量为 BW_BURST_WINDOW_NS 时间窗内的字节数并
    // 立即装满；mbps=0 关闭限速并清空令牌桶。
    function void configure_bw(int unsigned mbps);
        longint unsigned scaled_bucket_bytes;

        bw_limit_mbps = mbps;
        if (mbps > 0) begin
            bw_limit_enable = 1;
            scaled_bucket_bytes = mbps;
            scaled_bucket_bytes *= BW_BURST_WINDOW_NS;
            scaled_bucket_bytes /= 8000;
            bucket_size  = scaled_bucket_bytes;
            token_bucket = bucket_size;  // start full
            last_refill_time = $realtime;
        end else begin
            bw_limit_enable = 0;
            bucket_size  = 0;
            token_bucket = 0;
        end
    endfunction

    // 不推进仿真时间地为一个 bytes 大小的包补足令牌：返回所需的逻辑等待 ns，
    // 并按该等待时间补充令牌（不超过桶容量）。要求限速已开启且速率非零。
    function int unsigned advance_logical_refill(int unsigned bytes);
        longint unsigned wait_numerator;
        longint unsigned wait_ns;
        longint unsigned refill_tokens;
        longint unsigned refill_total;

        if (!bw_limit_enable || (bw_limit_mbps == 0)) begin
            `uvm_fatal("PERF_MON",
                "logical bandwidth refill requires a nonzero enabled rate")
            return 0;
        end

        wait_numerator = bytes;
        wait_numerator *= 8000;
        wait_ns = (wait_numerator / bw_limit_mbps) + 1;
        refill_tokens = wait_ns;
        refill_tokens *= bw_limit_mbps;
        refill_tokens /= 8000;
        refill_total = token_bucket;
        refill_total += refill_tokens;
        token_bucket = (refill_total > bucket_size) ?
            bucket_size : refill_total;
        last_refill_time = $realtime;
        return wait_ns;
    endfunction

    // 清空全部统计，开始新的测量阶段；限速开启时把令牌桶重新装满。
    function void reset_stats();
        global_stats = '{default: 0, start_time: 0, end_time: 0};
        vf_stats.delete();
        latency_samples.delete();
        last_refill_time = $realtime;
        if (bw_limit_enable)
            token_bucket = bucket_size;
    endfunction
```
  `uvm_fatal` 的 ID 由 `DUAL_TEST` 改为 `PERF_MON`。它只在误用时触发，回归中不会出现。

- [ ] **Step 2: dual 测试改用基类。** 删除 `virtio_dual_test.sv` 的 HEAD 29-99：`// Extended perf monitor` 注释框、`class virtio_perf_monitor_ext ... endclass`，以及其后的空行。
  HEAD 142 的 `    virtio_perf_monitor_ext bw_mon;` 改为 `    virtio_perf_monitor   bw_mon;`。
  HEAD 263-264：
```systemverilog
        // 7b. Extended perf monitor for bandwidth control test
        bw_mon = virtio_perf_monitor_ext::type_id::create("bw_mon", this);
```
  改为：
```systemverilog
        // 7b. Perf monitor for bandwidth control test (runtime reconfigured)
        bw_mon = virtio_perf_monitor::type_id::create("bw_mon", this);
```
  HEAD 1473-1572 中对 `configure_bw`、`reset_stats`、`advance_logical_refill`、`can_send`、`on_sent` 的调用都保持不变。

- [ ] **Step 3: 更新 README。** 把 HEAD 896 的
  ``**解决方案**：使用 `virtio_perf_monitor_ext` 子类的 `configure_bw()` 方法进行运行时重配。``
  改为 ``**解决方案**：调用 `virtio_perf_monitor::configure_bw()` 进行运行时重配（`reset_stats()` 开始新的测量阶段）。``

- [ ] **Step 4: 用 grep 确认。** `grep -rn "virtio_perf_monitor_ext" virtio_net_vip examples README.md docs/*.md` 预期：无输出。

- [ ] **Step 5: SYNC 后跑** `virtio_dual_test`（ONE TEST），预期 0/0/0，且带宽阶段日志中三个阶段的 throttle 计数与改动前一致；然后跑 REGRESSION。

- [ ] **Step 6: 提交。** `git add virtio_net_vip/src/env/virtio_perf_monitor.sv virtio_net_vip/tests/virtio_dual_test.sv README.md`
  `git commit -m "refactor: perf monitor 运行时重配并入 virtio_perf_monitor.configure_bw"`

---

### Notes for integrator（P2b）

**本部分产出、供其他阶段使用的接口**
- env：类内类型 `pcie_bind_plan_t`，以及 `protected function bit bind_all(pcie_bind_plan_t plan[$], virtio_tlm_completion_adapter legacy_adapter)`、`protected vio_snapshot_ctx snapshot_ctx`。
  后续“设备发现绑定 / AF 直配”设计的 verify_snapshot 应接在 `vio_snapshot_ctx::create_checked` 之后、`build_snapshot_topology` 之前。新的绑定来源只需构造 `pcie_bind_plan_t` 队列，交给 `bind_all`。
- function instance：`preflight_bind_pcie`、`commit_bind_pcie`、`cancel_bind_pcie`。P3-4 的 `virtio_driver_protocol` 如果要改变 ops/FSM 的选择，只需改
  `prepare_driver_candidates` 这一处。另有 `configure_from_ctx(ctx, service_key, pcie_ctx)`，是 virtual 的，VF 覆写它。
- resource client：`bind_to_ctx(ctx, service_key, why)`。PF：`configure_services_ctx(parent_pf_key, ctx, service_keys, why)`。
- transport 中不再有 init 时序。P3-3 的 `virtio_config_backend` 只需覆盖 ops 的单步接口，fixture 已经按单步调用。
- 测试公共件：`virtio_mock_transport` 和 `virtio_vq_test_kit`。在 `filelists/tests.f` 中它们位于 provider adapter 之后、所有测试之前。以后的新测试应直接使用它们，不要再写 transport 子类。

**顺序依赖**
- P1-1 必须先于 P2-4：新的 env 代码不含 `v_seqr`。
- 顺序为 P2-4 → P2-5 → P2-6。P2-5 的 Step 5 改的是 P2-4 新写的两行；P2-6 改的 function instance 区域与 P2-5 不重叠，但在同一个文件里，需按顺序合入。
- P0-4/P2-1 要先于 P2-5：`commit_validated_pcie_components` 的 dataplane 适配段由它们改写，P2-5 只改这个函数的头注释，不动函数体。
- P0-2/P0-3/P0-4/P0-5/P2-1 要先于 P2-8a/P2-8b：P2-8 会迁移 P0 新增的两个 transport 桩，以及 P0 在 indirect、net_packet_multi_queue 中加入的 ops 接线（文本取自 P0.md）。
- P2-8a 先于 P2-8b；b1 到 b4 之间互相独立，可以任意顺序。P2-8c 本身独立，但与 P2-5、P2-8b3 改的是同一个 dual 文件，应放在 P2-5 之后、按顺序合入。
- P4.2 会重写 `virtio_full_test` 和 `virtio_dual_test` 的设备建模。所以 P2-5 对这两个测试只做最小迁移（设置 Function 句柄后调 `wire_shared`），P2-8b 不迁移 full_test。
- P3 如果拆分 `virtio_atomic_ops`/`virtio_auto_fsm` 文件，P2-7 依赖的单步接口名不能改。P3-1 如果改写了 fixture 的 `start_driver_flow`，P2-7 Step 2 只替换 init 序列这一段。

**风险**
- P2-4：`preflight_plan` 通过 `output` 传递固定大小数组 `[DPU_MAX_FUNCTIONS]`。如果 VCS 对 output 非打包数组报错，就把预检循环内联到 `bind_all` 中，逻辑不变。
- P2-5：full、dual、dut_caps 迁移后，Function 自带的 transport/vq_mgr 会被测试自己的对象替换；Function 的 PASSIVE driver agent 也会多得到 ops/fsm/monitor.transport 赋值。
  已核实 monitor 和 observer 都没有 run_phase，没有副作用。另外，dut_caps 中 MQ 失败消息的前缀由 `mq_cap_function_rebind`/`malicious_function` 变成 `function_0`。
- P2-6：`apply_function_configuration` 用 `is_bound_to_service()` 判断是否需要导入资源。如果有地方在配置之前就让 Function 的 resource client 绑定了别的 service，导入会被静默跳过。
  当前代码和测试中没有这种用法，而且 `configure_from_ctx` 的改绑检查发生在导入之前。
- P2-7：旧流程在 DRIVER_OK 之前会预读所有队列的 notify 偏移。如果 REAL_DUT 设备要求在 DRIVER_OK 之前读过这些寄存器（规范没有这个要求），就在 fixture 中补读，不能恢复 transport 的 init 任务。
- P2-8a：mock 的 `read_net_config` 默认报告 1 个队列对，`write_queue_enable` 是空操作。这两项来自 P0 的 ctrl_vq 桩；对其他测试没有影响，原因见 Step 1 的说明。
- P2-8b：dual 中的 vq_mgr_a/b 保持 bdf=0，避免改变 IOMMU 键；kit 内部另外创建的 vq_mgr 在 dual 中不会被使用。

**Spec deviations 汇总**
- P2.4：`bind_all` 额外接收一个 `legacy_adapter` 参数，即标量 `bind_pcie` 的那个 completion adapter，因为它的绑定方式（`bind_registered_rc_driver`）与 endpoint 的按 domain 绑定不同。
- P2.6：公共入口保留为薄包装并保留入口校验，因为测试会直接用非法 snapshot 调用并断言结果。`vf_resource_pool` 的 frozen/钉住检查和 PF 的能力比对不属于重复校验，保留。
- P2.8：kit 多了 `create_kit`、`add_split`、`add_packed`；migration 测试保留一个很小的 mock 子类；P0 新增的两个桩一并迁移；只做部分接线的站点和 full_test 明确不迁移（见 P2-8b 的范围表）。
- P2.8 perf：`reset_stats` 和 `advance_logical_refill` 随 `configure_bw` 一起上移，否则子类删不掉。

---

## P3：接入点（策略对象与大类拆分）

本阶段把散落在 fixture、transport、bar accessor、atomic ops、driver、function instance
与私有 FSM 中的模式分支收敛到 5 个策略对象，并把 `virtio_auto_fsm` 的迁移代码与
`virtio_atomic_ops` 的类体按职责拆出。全部为代码迁移：维护回归的可观察行为不变
（日志 ID/消息文本保持，报告捕获器无需修改）。

前置状态假设（P0–P2 已合入）：
- P0.2 已修正 ctrl VQ 编号；可能已引入 `ops.setup_queue_range()`（P3-7 兼容两种情况）。
- P0.4 已把私有环两个测试纳入 manifest，因此 REGRESSION 覆盖私有环。
- P2-3 已在 ops 中加入 `virtio_dma_buffer_set` 与 `kick_with_fault(vq, qid)`。
- P2-5 已把 function instance 绑定收敛为 preflight/commit/cancel（`bind_pcie_components` 已删除，
  `wire_shared/bind_pcie` 为一行包装）。
- P2-7 已删除 `virtio_pci_transport.full_init_sequence`，fixture 改走 ops 单步接口。

所有锚点均以 HEAD `62ae3e9` 的符号名 + 代码原文给出；行号仅供参考（P0–P2 会使其漂移）。
执行每一步编辑前先用 `grep -n` 定位锚点原文。

任务顺序：P3-1 → P3-2 → P3-3 → P3-4 → P3-5 → P3-6 → P3-7 → P3-9 → P3-8。
P3-5 修改 P3-2 新建的发现策略文件；P3-9 修改 P3-3/P3-6 的产物；P3-8 必须最后执行（它按段落移动 P3-3/P3-7/P3-9 改过的 ops 代码）。

---

### Task P3-1: `virtio_execution_profile` —— 用执行策略替换 MODEL/REAL_DUT 枚举比较

**Files:**
- Create: `virtio_net_vip/src/env/virtio_execution_profile.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（第 8 层 `env/virtio_net_env_config.sv` include 之前，HEAD :124）
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`（`validate_execution_mode` HEAD :260-276；新增 `execution_profile()`）
- Modify: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`（删除 `model_only`/`can_start`，HEAD :217-233）
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`（HEAD :192/:203/:208/:211/:235/:274/:351/:370/:408/:444/:458/:479/:599/:613/:668-670，共 15 处 `execution_mode` 判断 + 1 个访问器）
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_test.sv:66`、`virtio_net_vip/tests/virtio_real_driver_multiqueue_test.sv:46`、`virtio_net_vip/tests/virtio_real_driver_rx_test.sv:57`
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树各加一行）
- Test: `virtio_net_vip/tests/virtio_execution_mode_test.sv`

**Interfaces:**
- Consumes: `virtio_execution_mode_e`（`types/virtio_net_types.sv:145-147`）、`pcie_tl_if_mode_e {TLM_MODE, SV_IF_MODE}`（pcie_tl_pkg，`pcie_tl_env_config.if_mode` 的类型）、`uvm_active_passive_enum`。
- Produces:
  - `virtual class virtio_execution_profile extends uvm_object`，纯虚方法：
    `function virtio_execution_mode_e mode()`、`function bit has_model_device()`、
    `function bit supports_host_mem_responder()`、`function bit needs_physical_link()`、
    `function pcie_tl_if_mode_e pcie_if_mode()`、`function uvm_active_passive_enum ep_is_active()`、
    `function bit ep_auto_response()`、`function string endpoint_unready_reason()`。
  - `class virtio_model_execution_profile`、`class virtio_real_dut_execution_profile`。
  - 包级函数 `function automatic virtio_execution_profile virtio_select_execution_profile(virtio_execution_mode_e mode)`（保留值返回 null）。
  - `virtio_net_env_config::execution_profile()`。
  - fixture：`virtio_real_driver_flow_fixture::execution_profile()`（替代被删除的 `execution_mode()`）。

**Spec deviation:**
- 简报称 fixture 在 :192-274 有 16 处判断；HEAD 实际为整个文件 15 处 `virtio_cfg.execution_mode` 比较
  （:192,:203,:208,:211,:235,:274,:351,:370,:408,:444,:458,:479,:599,:613）外加 `execution_mode()`
  访问器（:668-670）。本任务全部迁移。
- `virtio_pcie_dut_responder::can_start()/model_only()`（:217-233）在 src/tests/examples/docs 中 0 调用，
  "迁移"即删除，并附 grep 证据。
- `virtio_net_env.sv:262` 只是调用 `validate_execution_mode()`，不是分支；保持不变（其内部改为经策略校验）。
- `apply_plusargs()` 的字符串→枚举解析（:233-241）是输入解析而非行为分支，保留。

- [ ] **Step 1: 写失败测试。** 在 `virtio_net_vip/tests/virtio_execution_mode_test.sv` 中，把
  ```systemverilog
  import virtio_net_pkg::*;
  ```
  改为
  ```systemverilog
  import pcie_tl_pkg::*;
  import virtio_net_pkg::*;
  ```
  在 `run_phase` 中声明区（`virtio_net_env_config probe;` 之后）加入
  ```systemverilog
        virtio_execution_profile profile;
  ```
  并在 `phase.drop_objection(this);` 之前插入：
  ```systemverilog
        // 执行策略由 execution_mode 唯一决定；fixture/测试只询问策略，不再比较枚举。
        probe.execution_mode = VIRTIO_EXEC_MODEL;
        profile = probe.execution_profile();
        if ((profile == null) || (profile.mode() != VIRTIO_EXEC_MODEL) ||
            !profile.has_model_device() || profile.needs_physical_link() ||
            profile.supports_host_mem_responder() ||
            (profile.pcie_if_mode() != TLM_MODE) ||
            (profile.ep_is_active() != UVM_ACTIVE) || !profile.ep_auto_response())
            `uvm_error("MODE", "MODEL execution profile does not select the local device model")
        probe.execution_mode = VIRTIO_EXEC_REAL_DUT;
        profile = probe.execution_profile();
        if ((profile == null) || (profile.mode() != VIRTIO_EXEC_REAL_DUT) ||
            profile.has_model_device() || !profile.needs_physical_link() ||
            !profile.supports_host_mem_responder() ||
            (profile.pcie_if_mode() != SV_IF_MODE) ||
            (profile.ep_is_active() != UVM_PASSIVE) || profile.ep_auto_response())
            `uvm_error("MODE", "REAL_DUT execution profile does not select the physical link")
        probe.execution_mode = virtio_execution_mode_e'(2'b11);
        if (probe.execution_profile() != null)
            `uvm_error("MODE", "reserved execution mode produced an execution profile")
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，然后
  `ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_execution_mode_test ./scripts/vcs.sh > logs/virtio_execution_mode_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_execution_mode_test.log | tail -20'`
  期望：编译失败，出现 `Error-[` 行，指出 `virtio_execution_profile` 未声明（Identifier not declared）。

- [ ] **Step 3: 新建 `virtio_net_vip/src/env/virtio_execution_profile.sv`：**
  ```systemverilog
  `ifndef VIRTIO_EXECUTION_PROFILE_SV
  `define VIRTIO_EXECUTION_PROFILE_SV

  // ============================================================================
  // virtio_execution_profile
  //
  // 目录层次：src/env；MODEL / REAL_DUT 执行主体的唯一选择点。fixture 与环境只向
  // 策略询问"是否有本地设备模型、PCIe 接口模式、EP 是否主动、是否需要物理链路"，
  // 不再比较 virtio_execution_mode_e。策略是无状态只读对象，不创建也不持有任何
  // PCIe/Host memory 组件；组件的创建与绑定仍由调用方完成。
  // ============================================================================

  virtual class virtio_execution_profile extends uvm_object;
      // 无状态；构造不访问配置或设备。
      function new(string name = "virtio_execution_profile");
          super.new(name);
      endfunction

      // 对应的配置枚举，仅供日志与配置回显使用。
      pure virtual function virtio_execution_mode_e mode();
      // 是否由本地 MODEL 扮演设备：创建 TLM completion adapter、EP responder，
      // 安装端点配置镜像并用 MODEL DMA adapter 产生设备侧 DMA。
      pure virtual function bit has_model_device();
      // 是否允许创建 RC 侧 Host-memory DMA responder（只服务 EP 发起的 MemRd/MemWr）。
      pure virtual function bit supports_host_mem_responder();
      // 是否必须绑定 RC->EP 与 EP->RC 两条物理 VIF 才能运行驱动流程。
      pure virtual function bit needs_physical_link();
      // pcie_tl_env_config.if_mode 的取值。
      pure virtual function pcie_tl_if_mode_e pcie_if_mode();
      // pcie_tl_env_config.ep_is_active 的取值。
      pure virtual function uvm_active_passive_enum ep_is_active();
      // pcie_tl_env_config.ep_auto_response 的取值。
      pure virtual function bit ep_auto_response();
      // 端点尚未准备好时给调用方的诊断文本。
      pure virtual function string endpoint_unready_reason();
  endclass

  // 无 RTL DUT：VIP 的 responder 扮演设备，PCIe 走 TLM 回环。
  class virtio_model_execution_profile extends virtio_execution_profile;
      `uvm_object_utils(virtio_model_execution_profile)

      // 无状态；构造不访问配置或设备。
      function new(string name = "virtio_model_execution_profile");
          super.new(name);
      endfunction

      virtual function virtio_execution_mode_e mode();
          return VIRTIO_EXEC_MODEL;
      endfunction
      virtual function bit has_model_device();
          return 1'b1;
      endfunction
      virtual function bit supports_host_mem_responder();
          return 1'b0;
      endfunction
      virtual function bit needs_physical_link();
          return 1'b0;
      endfunction
      virtual function pcie_tl_if_mode_e pcie_if_mode();
          return TLM_MODE;
      endfunction
      virtual function uvm_active_passive_enum ep_is_active();
          return UVM_ACTIVE;
      endfunction
      virtual function bit ep_auto_response();
          return 1'b1;
      endfunction
      virtual function string endpoint_unready_reason();
          return "endpoint image was not derived from the frozen snapshot";
      endfunction
  endclass

  // 真实 DUT：端点配置与 BAR 响应来自 RTL，VIP 只保留被动观察与可选 RC 服务。
  class virtio_real_dut_execution_profile extends virtio_execution_profile;
      `uvm_object_utils(virtio_real_dut_execution_profile)

      // 无状态；构造不访问配置或设备。
      function new(string name = "virtio_real_dut_execution_profile");
          super.new(name);
      endfunction

      virtual function virtio_execution_mode_e mode();
          return VIRTIO_EXEC_REAL_DUT;
      endfunction
      virtual function bit has_model_device();
          return 1'b0;
      endfunction
      virtual function bit supports_host_mem_responder();
          return 1'b1;
      endfunction
      virtual function bit needs_physical_link();
          return 1'b1;
      endfunction
      virtual function pcie_tl_if_mode_e pcie_if_mode();
          return SV_IF_MODE;
      endfunction
      virtual function uvm_active_passive_enum ep_is_active();
          return UVM_PASSIVE;
      endfunction
      virtual function bit ep_auto_response();
          return 1'b0;
      endfunction
      virtual function string endpoint_unready_reason();
          return "REAL_DUT endpoint identity/interface was not prepared";
      endfunction
  endclass

  // 唯一的枚举→策略映射；保留/未知编码返回 null，由调用方报告非法配置。
  function automatic virtio_execution_profile virtio_select_execution_profile(
      virtio_execution_mode_e mode
  );
      virtio_model_execution_profile model_profile;
      virtio_real_dut_execution_profile real_dut_profile;

      case (mode)
          VIRTIO_EXEC_MODEL: begin
              model_profile = virtio_model_execution_profile::type_id::create(
                  "model_execution_profile");
              return model_profile;
          end
          VIRTIO_EXEC_REAL_DUT: begin
              real_dut_profile = virtio_real_dut_execution_profile::type_id::create(
                  "real_dut_execution_profile");
              return real_dut_profile;
          end
          default: return null;
      endcase
  endfunction

  `endif // VIRTIO_EXECUTION_PROFILE_SV
  ```

- [ ] **Step 4: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv` 第 8 层：
  ```systemverilog
    `include "env/virtio_net_env_config.sv"
  ```
  改为
  ```systemverilog
    `include "env/virtio_execution_profile.sv"
    `include "env/virtio_net_env_config.sv"
  ```

- [ ] **Step 5: env_config 改经策略校验并导出策略。** 在 `virtio_net_vip/src/env/virtio_net_env_config.sv`
  的 `validate_execution_mode` 中：
  ```systemverilog
        why = "";
        case (execution_mode)
            VIRTIO_EXEC_MODEL, VIRTIO_EXEC_REAL_DUT: begin end
            default: begin
                why = "invalid virtio execution mode";
                return 0;
            end
        endcase
  ```
  改为
  ```systemverilog
        why = "";
        if (virtio_select_execution_profile(execution_mode) == null) begin
            why = "invalid virtio execution mode";
            return 0;
        end
  ```
  并在 `validate_execution_mode` 之前的注释行 `// 枚举底层值仍可能被强制赋成保留值，因此在环境创建前显式校验。` 之前插入：
  ```systemverilog
    // 返回 execution_mode 对应的执行策略；保留编码返回 null。每次调用返回新的
    // 无状态对象，调用方可缓存。
    function virtio_execution_profile execution_profile();
        return virtio_select_execution_profile(execution_mode);
    endfunction

  ```

- [ ] **Step 6: 删除无调用的 responder 模式判定。** `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`
  删除以下整段（从注释 `// 该组件是没有 RTL DUT 时使用的设备行为模型。REAL_DUT 模式必须绕过` 起，
  到 `can_start` 的 `endfunction` 止，含其后一个空行）：
  ```systemverilog
    // 该组件是没有 RTL DUT 时使用的设备行为模型。REAL_DUT 模式必须绕过
    // 它，避免模型和真实 DUT 同时消费 notify 或产生 DMA。
    // 固定返回 1，供 fixture 在选择 MODEL/REAL_DUT 执行主体时做能力判定。
    function bit model_only(); return 1'b1; endfunction

    // 能力检查：仅 VIRTIO_EXEC_MODEL 返回成功；不改变运行状态，失败原因写入 why。
    function bit can_start(
        input virtio_execution_mode_e mode,
        output string why
    );
        why = "";
        if (mode != VIRTIO_EXEC_MODEL) begin
            why = "virtio_pcie_dut_responder is MODEL-only";
            return 1'b0;
        end
        return 1'b1;
    endfunction
  ```
  证据：`grep -rn "can_start\|model_only" virtio_net_vip examples README.md docs/*.md` 期望输出为空。

- [ ] **Step 7: fixture 迁移（`virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`）。**
  1. 成员区：在 `protected int unsigned            m_poll_timeout_ns;` 之后加
     ```systemverilog
    // 由 virtio_cfg.execution_mode 解析出的执行策略；build_phase 之后不变。
    protected virtio_execution_profile m_profile;
     ```
     并在 `new()` 中 `m_selected_function = null;` 之后加 `        m_profile = null;`。
  2. build_phase，紧接在调用 `virtio_cfg.apply_plusargs(mode_why)` 的 `begin ... end` 块之后加入：
     ```systemverilog
        m_profile = virtio_cfg.execution_profile();
        if (m_profile == null) begin
            `uvm_fatal("REAL_FLOW", "virtio execution mode has no execution profile")
            return;
        end
     ```
  3. 旧：
     ```systemverilog
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) begin
            tlm_adapter = virtio_tlm_completion_adapter::type_id::create(
                "tlm_adapter");
            tlm_adapter.install_factory_overrides();
        end else begin
            tlm_adapter = null;
            host_mem_responder =
                virtio_pcie_real_dut_host_mem_responder::type_id::create(
                    "host_mem_responder", this);
        end
     ```
     新：
     ```systemverilog
        if (m_profile.has_model_device()) begin
            tlm_adapter = virtio_tlm_completion_adapter::type_id::create(
                "tlm_adapter");
            tlm_adapter.install_factory_overrides();
        end else begin
            tlm_adapter = null;
            if (m_profile.supports_host_mem_responder())
                host_mem_responder =
                    virtio_pcie_real_dut_host_mem_responder::type_id::create(
                        "host_mem_responder", this);
        end
     ```
  4. 旧：
     ```systemverilog
        pcie_cfg.if_mode = (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                            SV_IF_MODE : TLM_MODE;
     ```
     新：`        pcie_cfg.if_mode = m_profile.pcie_if_mode();`
  5. 旧：
     ```systemverilog
        pcie_cfg.ep_is_active = (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                                UVM_PASSIVE : UVM_ACTIVE;
        pcie_cfg.ep_auto_response =
            (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ? 1'b0 : 1'b1;
     ```
     新：
     ```systemverilog
        pcie_cfg.ep_is_active = m_profile.ep_is_active();
        pcie_cfg.ep_auto_response = m_profile.ep_auto_response();
     ```
  6. 旧（build_phase 末尾）：
     ```systemverilog
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL)
            responder = virtio_pcie_dut_responder::type_id::create(
     ```
     新：
     ```systemverilog
        if (m_profile.has_model_device())
            responder = virtio_pcie_dut_responder::type_id::create(
     ```
  7. connect_phase 旧：`        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) &&`（下一行为
     `            (responder != null) && (host_mem_owners != null) &&`）
     新：`        if ((m_profile != null) && m_profile.has_model_device() &&`
  8. end_of_elaboration_phase 旧：
     ```systemverilog
        if (virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) begin
            if ((m_pcie_env.ep_agent.ep_driver == null) ||
     ```
     新：
     ```systemverilog
        if (m_profile.has_model_device()) begin
            if ((m_pcie_env.ep_agent.ep_driver == null) ||
     ```
  9. 旧：
     ```systemverilog
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
            real_dut_host_mem_responder_enable &&
            (host_mem_responder != null)) begin
     ```
     新：
     ```systemverilog
        if (m_profile.supports_host_mem_responder() &&
            real_dut_host_mem_responder_enable &&
            (host_mem_responder != null)) begin
     ```
  10. 旧：
      ```systemverilog
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_MODEL) &&
            (responder != null)) begin
            virtio_function_instance selected_function;
      ```
      新：
      ```systemverilog
        if (m_profile.has_model_device() && (responder != null)) begin
            virtio_function_instance selected_function;
      ```
  11. build_flow 旧：
      ```systemverilog
            why = (virtio_cfg != null) &&
                  (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) ?
                  "REAL_DUT endpoint identity/interface was not prepared" :
                  "endpoint image was not derived from the frozen snapshot";
      ```
      新：
      ```systemverilog
            why = (m_profile != null) ? m_profile.endpoint_unready_reason() :
                  "endpoint image was not derived from the frozen snapshot";
      ```
  12. 旧：
      ```systemverilog
        if ((virtio_cfg != null) &&
            (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT)) begin
            if (m_host_mem_responder_conflict) begin
      ```
      新：
      ```systemverilog
        if ((m_profile != null) && m_profile.needs_physical_link()) begin
            if (m_host_mem_responder_conflict) begin
      ```
  13. 旧：
      ```systemverilog
        if ((virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
            real_dut_host_mem_responder_enable &&
            !m_host_mem_responder_bound) begin
      ```
      新：
      ```systemverilog
        if (m_profile.supports_host_mem_responder() &&
            real_dut_host_mem_responder_enable &&
            !m_host_mem_responder_bound) begin
      ```
  14. `real_dut_link_ready()` 旧：
      ```systemverilog
        return (virtio_cfg != null) &&
               (virtio_cfg.execution_mode == VIRTIO_EXEC_REAL_DUT) &&
               m_pcie_vif_bound && m_pcie_path_bound;
      ```
      新：
      ```systemverilog
        return (m_profile != null) && m_profile.needs_physical_link() &&
               m_pcie_vif_bound && m_pcie_path_bound;
      ```
  15. `enable_real_dut_host_mem_responder()` 旧：
      ```systemverilog
        if ((virtio_cfg == null) ||
            (virtio_cfg.execution_mode != VIRTIO_EXEC_REAL_DUT)) begin
            why = "Host-memory responder can only be enabled in REAL_DUT mode";
      ```
      新：
      ```systemverilog
        if ((m_profile == null) || !m_profile.supports_host_mem_responder()) begin
            why = "Host-memory responder can only be enabled in REAL_DUT mode";
      ```
  16. 访问器旧：
      ```systemverilog
    function virtio_execution_mode_e execution_mode();
        return virtio_cfg.execution_mode;
    endfunction
      ```
      新：
      ```systemverilog
    // 测试按执行策略选择断言来源（MODEL responder 计数或 REAL_DUT 被动观察），
    // 不比较执行模式枚举。
    function virtio_execution_profile execution_profile();
        return m_profile;
    endfunction
      ```

- [ ] **Step 8: 三个测试改问策略。**
  - `virtio_net_vip/tests/virtio_real_driver_flow_test.sv` 旧 `    is_model = (flow.execution_mode() == VIRTIO_EXEC_MODEL);`
    新 `    is_model = flow.execution_profile().has_model_device();`
  - `virtio_net_vip/tests/virtio_real_driver_multiqueue_test.sv` 同一行同样替换。
  - `virtio_net_vip/tests/virtio_real_driver_rx_test.sv` 旧 `    if (flow.execution_mode() == VIRTIO_EXEC_REAL_DUT)`
    新 `    if (!flow.execution_profile().has_model_device())`

- [ ] **Step 9: 证明 fixture/测试/responder 不再比较枚举。**
  `grep -rn "execution_mode\b\|VIRTIO_EXEC_MODEL\|VIRTIO_EXEC_REAL_DUT" virtio_net_vip/tests/virtio_real_driver_*.sv virtio_net_vip/src/pcie`
  期望输出为空。

- [ ] **Step 10: 文档。** `README.md` 目录树中 `│   │   ├── virtio_net_env_config.sv        ← 统一配置对象（25+ 可配参数）`
  之前插入 `│   │   ├── virtio_execution_profile.sv     ← MODEL/REAL_DUT 执行策略（唯一选择点）`；
  `docs/virtio_net_vip_manual.md` 目录树 `|   |   +-- virtio_net_env_config.sv        -- 环境配置对象`
  之前插入 `|   |   +-- virtio_execution_profile.sv     -- MODEL/REAL_DUT 执行策略`。

- [ ] **Step 11: SYNC 并运行受影响测试（期望 PASS）。**
  `rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/`
  依次以 ONE TEST 运行 `virtio_execution_mode_test`、`virtio_real_driver_flow_test`、
  `virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`，例如：
  `ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_real_driver_flow_test ./scripts/vcs.sh > logs/virtio_real_driver_flow_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_real_driver_flow_test.log | tail -20'`
  期望：每个测试的 grep 只剩 `UVM_WARNING :    0`、`UVM_ERROR :    0`、`UVM_FATAL :    0` 计数行。

- [ ] **Step 12: REGRESSION。**
  `ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'`
  期望：第一条 grep 无输出，末行 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 13: 提交。**
  ```bash
  git add virtio_net_vip/src/env/virtio_execution_profile.sv virtio_net_vip/src/virtio_net_pkg.sv \
          virtio_net_vip/src/env/virtio_net_env_config.sv virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv \
          virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv virtio_net_vip/tests/virtio_real_driver_flow_test.sv \
          virtio_net_vip/tests/virtio_real_driver_multiqueue_test.sv virtio_net_vip/tests/virtio_real_driver_rx_test.sv \
          virtio_net_vip/tests/virtio_execution_mode_test.sv README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 引入 virtio_execution_profile 收敛 MODEL/REAL_DUT 分支"
  ```

---

### Task P3-2: `virtio_discovery_strategy` —— enumerate / fabric_preconfigured 发现策略

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_discovery_strategy.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（`transport/virtio_pci_transport.sv` include 之前，HEAD :70）
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv`（字段区 HEAD :60-66；`new()` :74-91；`configure_fabric_managed` :138-145；`discover_and_init_bars` :845-865；删除 `fabric_capabilities_use_device_window` :867-899；`discover_fabric_preconfigured_bars` :900-938）
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`（`do_full_init` 中 Step 1 BAR discovery，HEAD :779-782）
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树各加一行）
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`

**Interfaces:**
- Consumes: `virtio_pci_transport`（前向 `typedef class virtio_pci_transport;` 已在 `types/virtio_net_types.sv:24`）、`virtio_bar_accessor.{enumerate_bars, program_fabric_bar_pairs, fabric_bar_layout_is_active, requester_id}`、`virtio_pci_cap_manager.discover_capabilities()` 与 `*_cap/*_found/msix_table_bir` 字段、`virtio_resource_client::mark_runtime_ready(output string why)`。
- Produces:
  - `virtual class virtio_discovery_strategy extends uvm_object`：
    `pure virtual function string strategy_name();`
    `pure virtual task discover(virtio_pci_transport transport, output bit ok, output string why);`
  - `class virtio_enumerate_discovery`（`strategy_name()=="enumerate"`）、
    `class virtio_fabric_preconfigured_discovery`（`strategy_name()=="fabric_preconfigured"`，含 protected
    `capabilities_use_fabric_windows(virtio_pci_transport transport, output string why)`，P3-5 改为查 `fabric_bar_layout`）。
  - transport：`virtio_discovery_strategy discovery_strategy;`、
    `function void set_discovery_strategy(virtio_discovery_strategy strategy);`、
    `function string discovery_strategy_name();`；`discover_and_init_bars()` 成为唯一发现入口；
    `discover_fabric_preconfigured_bars()` 保留为显式入口（`virtio_fabric_resource_test.sv:785` 直接调用）。
  - 供后续设计：`verify_snapshot` 策略继承 `virtio_discovery_strategy`，经 `set_discovery_strategy()` 安装，
    在 `discover()` 内先读身份再委托 `virtio_fabric_preconfigured_discovery`。

**Spec deviation:** 规格把 bar accessor 中的 fabric 判断（约 34 处）列在本行；这些判断实为 BAR 角色布局约束，
在 P3-5（`fabric_bar_layout`）中统一处理，本任务只迁移"走哪条发现路径"的分支（FSM :779-782、transport :846-849）。

- [ ] **Step 1: 写失败测试。** 在 `virtio_net_vip/tests/virtio_unit_test.sv` 中紧接
  `endclass : virtio_expected_iommu_map_error_catcher` 之后插入：
  ```systemverilog

// 记录型发现策略：只统计调用与入参，验证 transport 把发现完全委托给策略对象。
class virtio_unit_recording_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_unit_recording_discovery)

    int unsigned discover_count;
    virtio_pci_transport last_transport;

    function new(string name = "virtio_unit_recording_discovery");
        super.new(name);
        discover_count = 0;
        last_transport = null;
    endfunction

    virtual function string strategy_name();
        return "unit_recording";
    endfunction

    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        discover_count++;
        last_transport = transport;
        why = "";
        ok = 1;
    endtask
endclass : virtio_unit_recording_discovery
  ```
  在 `run_phase` 中 `test_late_driver_agent_binding();` 之后加一行 `        test_discovery_strategy_selection();`，
  并在类末尾（`test_tlm_completion_factory_owner` 的 `endtask` 之后、`endclass` 之前）加入：
  ```systemverilog

    // transport 的发现路径只由策略对象决定：默认 enumerate，Fabric 托管切换为
    // fabric_preconfigured，外部可注入新策略（后续 verify_snapshot 的接入点）。
    task test_discovery_strategy_selection();
        virtio_pci_transport transport;
        virtio_unit_recording_discovery recorder;
        virtio_resource_client client;

        transport = virtio_pci_transport::type_id::create("discovery_transport");
        if (transport.discovery_strategy_name() != "enumerate")
            `uvm_error("TEST", {"default discovery strategy is ",
                                transport.discovery_strategy_name()})
        client = virtio_resource_client::type_id::create("discovery_client");
        transport.configure_fabric_managed(client);
        if (transport.discovery_strategy_name() != "fabric_preconfigured")
            `uvm_error("TEST", {"Fabric-managed transport selected ",
                                transport.discovery_strategy_name()})
        recorder = virtio_unit_recording_discovery::type_id::create(
            "discovery_recorder");
        transport.set_discovery_strategy(recorder);
        transport.discover_and_init_bars();
        if ((recorder.discover_count != 1) || (recorder.last_transport != transport))
            `uvm_error("TEST", $sformatf(
                "discover_and_init_bars did not delegate exactly once (count=%0d)",
                recorder.discover_count))
        `uvm_info("UNIT_TEST", "test_discovery_strategy_selection PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，然后 ONE TEST `virtio_unit_test`：
  `ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_unit_test ./scripts/vcs.sh > logs/virtio_unit_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_unit_test.log | tail -20'`
  期望：`Error-[` 编译错误，`virtio_discovery_strategy` 未声明。

- [ ] **Step 3: 新建 `virtio_net_vip/src/transport/virtio_discovery_strategy.sv`：**
  ```systemverilog
`ifndef VIRTIO_DISCOVERY_STRATEGY_SV
`define VIRTIO_DISCOVERY_STRATEGY_SV

// ============================================================================
// virtio_discovery_strategy
//
// 目录层次：src/transport；BAR/capability 发现策略。transport 只持有当前策略并在
// discover_and_init_bars() 中调用；策略借用 transport 的 bar/cap_mgr/notify_mgr，
// 不拥有它们，也不保存跨调用状态。
//   enumerate            : PCI BAR sizing + 本地地址分配，仅用于非 Fabric function。
//   fabric_preconfigured : 按冻结 snapshot 的 BAR 租约写配置空间，只扫描 capability，
//                          再经 resource client 进入 device-ready。
// 后续 verify_snapshot 策略在 fabric_preconfigured 之前读硬件身份并与 snapshot 核对。
// 本文件在 virtio_pci_transport 之前编译，经 types 中的前向 typedef 引用 transport。
// ============================================================================

virtual class virtio_discovery_strategy extends uvm_object;
    // 无状态；构造不访问设备。
    function new(string name = "virtio_discovery_strategy");
        super.new(name);
    endfunction

    // 策略名，供配置回显与测试断言。
    pure virtual function string strategy_name();
    // 发现并初始化 transport 的 BAR/capability 视图；ok=0 时 why 给出原因，
    // 调用方负责报告。实现可对不可恢复的配置错误直接 fatal。
    pure virtual task discover(virtio_pci_transport transport, output bit ok,
                               output string why);
endclass

// 传统 PCI 枚举：sizing 全部 BAR、按本地窗口分配地址，再扫描 virtio capability。
class virtio_enumerate_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_enumerate_discovery)

    // 无状态；构造不访问设备。
    function new(string name = "virtio_enumerate_discovery");
        super.new(name);
    endfunction

    virtual function string strategy_name();
        return "enumerate";
    endfunction

    //   1. bar.enumerate_bars()
    //   2. cap_mgr.bar_ref = bar
    //   3. cap_mgr.discover_capabilities()
    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        why = "";
        `uvm_info("TRANSPORT", "Starting BAR discovery and capability enumeration", UVM_MEDIUM)

        // Set BDF on bar accessor
        transport.bar.requester_id = transport.bdf;

        // Step 1: Enumerate BARs
        transport.bar.enumerate_bars();

        // Step 2: Wire bar reference into cap manager
        transport.cap_mgr.bar_ref = transport.bar;

        // Step 3: Discover virtio PCI capabilities
        transport.cap_mgr.discover_capabilities();

        `uvm_info("TRANSPORT", "BAR discovery and capability enumeration complete", UVM_MEDIUM)
        ok = 1;
    endtask
endclass

// Fabric owns BAR placement, but the root complex still must program all
// three 64-bit BAR pairs through PCI config space before discovery.  This
// path then scans capabilities and lets the virtio resource client mark
// the function device-ready.
class virtio_fabric_preconfigured_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_fabric_preconfigured_discovery)

    // 无状态；构造不访问设备。
    function new(string name = "virtio_fabric_preconfigured_discovery");
        super.new(name);
    endfunction

    virtual function string strategy_name();
        return "fabric_preconfigured";
    endfunction

    // Fabric 专用校验(无副作用)：确认发现到的 virtio 能力落在 Fabric 约定的
    // BAR 角色窗口内——common/ISR/device/pci cfg 在 BAR0、notify 在 BAR2
    // (mailbox)、MSI-X 在 BAR4；任何偏离都拒绝并经 why 说明原因，
    // 防止把错误的 BAR 角色布局当成合法 DUT profile。
    protected function bit capabilities_use_fabric_windows(
        virtio_pci_transport transport,
        output string why
    );
        why = "";
        if (!transport.cap_mgr.common_cfg_found || !transport.cap_mgr.notify_found ||
            !transport.cap_mgr.isr_found) begin
            why = "mandatory virtio capabilities were not discovered";
            return 0;
        end
        // The Fabric profile has a split functional layout: BAR0/1 carries
        // common/ISR/device configuration, while BAR2/3 is the mailbox and
        // therefore owns the virtio notification capability.  Do not force
        // notify into BAR0; doing so rejects the real-DUT profile even though
        // the discovered BAR role and notify address are correct.
        if ((transport.cap_mgr.common_cfg_cap.bar != 0) ||
            (transport.cap_mgr.notify_cap.bar != 2) ||
            (transport.cap_mgr.isr_cap.bar != 0) ||
            (transport.cap_mgr.device_cfg_found &&
             (transport.cap_mgr.device_cfg_cap.bar != 0)) ||
            (transport.cap_mgr.pci_cfg_found &&
             (transport.cap_mgr.pci_cfg_cap.bar != 0))) begin
            why = "virtio functional capability did not resolve to Fabric BAR0/1";
            return 0;
        end
        if (transport.cap_mgr.msix_found &&
            (transport.cap_mgr.msix_table_bir != 4)) begin
            why = "MSI-X capability did not resolve to Fabric BAR4/5";
            return 0;
        end
        return 1;
    endfunction

    // 只对 Fabric 托管 function 生效：编程三对 BAR、扫描 capability、核对 BAR 角色窗口，
    // 最后由 resource client 标记 device-ready。配置错误直接 fatal（与原 transport 行为一致）。
    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        string check_why;

        ok = 0;
        why = "";
        if (!transport.is_fabric_managed()) begin
            `uvm_fatal("TRANSPORT",
                "Fabric preconfigured discovery requested for a non-Fabric function")
        end
        if (!transport.bar.fabric_bar_layout_is_active()) begin
            `uvm_fatal("TRANSPORT",
                "Fabric function has no preconfigured BAR role layout")
        end
        if (transport.fabric_resource_client == null) begin
            `uvm_fatal("TRANSPORT",
                "Fabric function has no resource client for device-ready lifecycle")
        end

        transport.bar.requester_id = transport.bdf;
        transport.cap_mgr.bar_ref = transport.bar;
        transport.notify_mgr.bar = transport.bar;
        transport.bar.program_fabric_bar_pairs();
        transport.cap_mgr.discover_capabilities();
        if (!capabilities_use_fabric_windows(transport, check_why)) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "Fabric capability discovery rejected BAR roles: %s", check_why))
        end
        transport.fabric_capability_discovered = 1;
        if (!transport.fabric_resource_client.mark_runtime_ready(check_why)) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "Fabric device-ready transition failed after discovery: %s", check_why))
        end
        `uvm_info("TRANSPORT",
            "Fabric BAR configuration and capability discovery complete without BAR enumeration",
            UVM_MEDIUM)
        ok = 1;
    endtask
endclass

`endif // VIRTIO_DISCOVERY_STRATEGY_SV
  ```

- [ ] **Step 4: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv`：
  ```systemverilog
  `include "transport/virtio_notification_manager.sv"
  `include "transport/virtio_pci_transport.sv"
  ```
  改为
  ```systemverilog
  `include "transport/virtio_notification_manager.sv"
  `include "transport/virtio_discovery_strategy.sv"
  `include "transport/virtio_pci_transport.sv"
  ```

- [ ] **Step 5: transport 改为持有策略。** `virtio_net_vip/src/transport/virtio_pci_transport.sv`：
  1. 字段区 `virtio_resource_client  fabric_resource_client;` 之后加：
     ```systemverilog

    // 当前 BAR/capability 发现策略：构造时为 enumerate，configure_fabric_managed()
    // 切换为 fabric_preconfigured；后续设计经 set_discovery_strategy() 注入 verify_snapshot。
    virtio_discovery_strategy discovery_strategy;
     ```
  2. `new()` 中 `pcie_id_valid   = 0;` 之后加
     `        discovery_strategy = virtio_enumerate_discovery::type_id::create("enumerate_discovery");`
  3. `configure_fabric_managed` 中 `fabric_resource_client = resource_client;` 之后加
     ```systemverilog
        discovery_strategy = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
     ```
  4. `is_fabric_managed()` 函数之后插入：
     ```systemverilog

    // 替换发现策略（例如核对 snapshot 的 verify_snapshot）；null 被拒绝并保持原策略。
    function void set_discovery_strategy(virtio_discovery_strategy strategy);
        if (strategy == null) begin
            `uvm_error("TRANSPORT", "set_discovery_strategy received null")
            return;
        end
        discovery_strategy = strategy;
    endfunction

    // 当前发现策略名；纯查询。
    function string discovery_strategy_name();
        return discovery_strategy.strategy_name();
    endfunction
     ```
  5. 把 `discover_and_init_bars` 的方法体（从 `virtual task discover_and_init_bars();` 到其 `endtask`）整体替换为：
     ```systemverilog
    virtual task discover_and_init_bars();
        bit ok;
        string why;

        discovery_strategy.discover(this, ok, why);
        if (!ok)
            `uvm_fatal("TRANSPORT", {"BAR/capability discovery failed: ", why})
    endtask
     ```
     其上方注释块（`// discover_and_init_bars` 到 `//   3. cap_mgr.discover_capabilities()`）替换为：
     ```systemverilog
    // ========================================================================
    // discover_and_init_bars
    //
    // 唯一的发现入口：委托当前 discovery_strategy（enumerate / fabric_preconfigured /
    // 后续 verify_snapshot）。策略失败时 fatal，因为后续所有寄存器访问都依赖它。
    // ========================================================================
     ```
  6. 删除 `fabric_capabilities_use_device_window` 整个函数及其上方注释（从
     `// Fabric 专用校验(无副作用)：确认发现到的 virtio 能力落在 Fabric 约定的` 到该函数 `endfunction`，含其后一个空行）。
  7. 把 `discover_fabric_preconfigured_bars` 上方注释与方法体（从 `// Fabric owns BAR placement, but the root complex still must program all`
     到该任务 `endtask`）整体替换为：
     ```systemverilog
    // Fabric 预配置发现的显式入口（virtio_fabric_resource_test 直接调用）；与
    // configure_fabric_managed() 安装的策略为同一实现，不经 discovery_strategy 分派。
    virtual task discover_fabric_preconfigured_bars();
        virtio_fabric_preconfigured_discovery fabric_discovery;
        bit ok;
        string why;

        fabric_discovery = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
        fabric_discovery.discover(this, ok, why);
        if (!ok)
            `uvm_fatal("TRANSPORT", {"Fabric discovery failed: ", why})
    endtask
     ```

- [ ] **Step 6: FSM 去掉发现分支。** `virtio_net_vip/src/agent/virtio_auto_fsm.sv` 的 `do_full_init` 中：
  ```systemverilog
        if (ops.transport.is_fabric_managed())
            ops.transport.discover_fabric_preconfigured_bars();
        else
            ops.transport.discover_and_init_bars();
  ```
  改为
  ```systemverilog
        ops.transport.discover_and_init_bars();
  ```
  并把上方注释 `// full_init 的实现体（入参已由 full_init 校验）：按 virtio 1.x 顺序推进`
  下一行中的 `DISCOVERING（BAR 发现，Fabric 托管走预配置路径）` 改为 `DISCOVERING（BAR 发现，按 transport 的发现策略）`。

- [ ] **Step 7: 证明分支已移除。**
  `grep -rn "is_fabric_managed()" virtio_net_vip/src` 期望只剩 `virtio_pci_transport.sv`（定义）与
  `virtio_discovery_strategy.sv`（fabric 策略的自检）两处；
  `grep -n "fabric_capabilities_use_device_window" -r virtio_net_vip` 期望为空。

- [ ] **Step 8: 文档。** `README.md` 目录树 `│   │   └── virtio_pci_transport.sv         ← 传输层顶层封装（完整初始化序列）`
  之前插入 `│   │   ├── virtio_discovery_strategy.sv    ← BAR/capability 发现策略（enumerate / fabric_preconfigured）`；
  `docs/virtio_net_vip_manual.md` 目录树 `|   |   +-- virtio_pci_transport.sv         -- PCI 传输封装 (完整初始化序列)`
  之前插入 `|   |   +-- virtio_discovery_strategy.sv    -- BAR/capability 发现策略`；手册"discover_and_init_bars | task | BAR 枚举 + capability 发现"
  表格行（HEAD :2371）改为 `| \`discover_and_init_bars\` | task | 委托当前发现策略（enumerate / fabric_preconfigured） |`。

- [ ] **Step 9: SYNC 并运行受影响测试（期望 PASS）。** SYNC 后 ONE TEST 依次运行
  `virtio_unit_test`、`virtio_fabric_resource_test`、`virtio_dut_caps_test`、`virtio_real_driver_flow_test`、`virtio_e2e_test`
  （命令同 BRIEF 的 ONE TEST，替换 `<test_name>`）。期望各自只剩三行 0 计数。

- [ ] **Step 10: REGRESSION。** 运行 BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 11: 提交。**
  ```bash
  git add virtio_net_vip/src/transport/virtio_discovery_strategy.sv virtio_net_vip/src/virtio_net_pkg.sv \
          virtio_net_vip/src/transport/virtio_pci_transport.sv virtio_net_vip/src/agent/virtio_auto_fsm.sv \
          virtio_net_vip/tests/virtio_unit_test.sv README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 引入 virtio_discovery_strategy 统一 BAR 发现路径"
  ```

---

### Task P3-3: `virtio_config_backend` —— 设备配置副作用的唯一出口（common-config / dpu_priv）

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_config_backend.sv`（抽象类 + `virtio_queue_program_t` + common-config 实现）
- Create: `virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv`（包装 `dpu_priv_device_control`）
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（`dpu_priv/dpu_priv_driver_config.sv` include 之后，HEAD :72）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`：字段区（HEAD :27-54）、新增 `cfg_backend()`（`has_pending_normal_dma` 之后）、
  `device_reset_verified`（:460-517）、`set_acknowledge`..`set_failed`（:528-602）、`read_device_features`/`write_driver_features`/`negotiate_features`（:611-630）、
  `setup_queue`（:639-771）、`teardown_queue`（:776-819）、`reset_queue`（:824-833）、`setup_msix`（:2050-2079）、`teardown_msix`（:2084-2087）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`：`device_control` 字段（:12）、`configure_private`（:24-40）、`context_ready`（:52-62）、
  `setup_queue` 中 `device_control.configure_queue`（:125）、`teardown_queue`（:176-185）、`device_reset_verified`（:193-206）、`kick_queue`（:209-220）
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树）
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`

**Interfaces:**
- Consumes: transport 现有 common-config 任务（`reset_device_verified`、`read/write_device_status`、`read_device_features`、`write_driver_features`、
  `negotiate_features`、`select_queue`、`read_queue_num_max`、`setup_single_queue`、`write_queue_enable`、`write_queue_reset`、
  `write_config_msix_vector`、`write_queue_msix_vector`）与 `notify_mgr`/`cap_mgr`；`dpu_priv_device_control`（`reset_device/configure_queue/disable_queue/notify_queue`）、
  `dpu_priv_queue_context_t`。
- Produces（后续 `virtio_af_direct_backend` 直接继承本接口）：
  ```systemverilog
  typedef struct {
      int unsigned host_id; bit [15:0] bdf;
      int unsigned queue_id; int unsigned queue_size; virtqueue_type_e vq_type;
      bit [63:0] desc_iova; bit [63:0] driver_iova; bit [63:0] device_iova;
      int unsigned ring_bytes; int unsigned msix_vector;
      int unsigned local_qid; int unsigned rx_buf_size; bit tx_mode;
      int unsigned notify_bar; bit [31:0] notify_offset;
  } virtio_queue_program_t;
  function automatic virtio_queue_program_t virtio_empty_queue_program();
  virtual class virtio_config_backend extends uvm_object;
      function void bind_transport(virtio_pci_transport transport_ref);
      function virtio_pci_transport bound_transport();
      pure virtual task reset(output bit ok);
      pure virtual task read_status(output bit [7:0] status);
      pure virtual task write_status(bit [7:0] status);
      pure virtual task read_device_features(output bit [63:0] features);
      pure virtual task write_driver_features(bit [63:0] features);
      pure virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
      pure virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
      pure virtual task configure_queue(virtio_queue_program_t q, output bit ok);
      pure virtual task enable_queue(virtio_queue_program_t q, output bit ok);
      pure virtual task disable_queue(virtio_queue_program_t q, output bit ok);
      pure virtual task reset_queue(int unsigned queue_id, output bit ok);
      pure virtual task set_msix(int unsigned queue_ids[$], output bit ok);
      pure virtual task clear_msix(output bit ok);
  endclass
  class virtio_common_cfg_backend extends virtio_config_backend;   // 现行行为
  class dpu_priv_config_backend extends virtio_config_backend;     // dpu_priv_device_control 包装
      dpu_priv_device_control control;
      static function dpu_priv_queue_context_t to_context(virtio_queue_program_t q);
      static function virtio_queue_program_t from_context(dpu_priv_queue_context_t ctx);
      task notify_queue(dpu_priv_queue_context_t ctx, bit [31:0] value);
  ```
  ops：公有字段 `virtio_config_backend config_backend;`（空时自动使用 common-config）、
  `protected function virtio_config_backend cfg_backend();`、`protected virtio_queue_program_t queue_programs[int unsigned];`。

**语义说明（行为保持）：**
- common-config 的 `configure_queue` 即 `transport.setup_single_queue`（其末尾已写 `Q_ENABLE=1`），因此 `enable_queue` 返回 ok=1 不发 TLP；
  寄存器访问序列与 HEAD 完全一致。`disable_queue` = `select_queue + write_queue_enable(0)`；`reset_queue` = `write_queue_reset`
  （与 HEAD 相同的无返回包装，超时由 transport 自报错误，ok 恒为 1）。
- ops 现在检查 `disable_queue`/`reset_queue`/`set_msix` 的 ok；common-config 恒为 1，故仅为后续 af_direct 的失败保留路径（"拆除失败保留资源"）。
- `cfg_backend()` 每次调用都把后端重新绑定到当前 `transport`：测试直接给 `ops.transport` 赋 mock 时，后端仍调用该 mock 的覆写方法。

- [ ] **Step 1: 写失败测试。** `virtio_net_vip/tests/virtio_unit_test.sv` 中，在 P3-2 加入的
  `endclass : virtio_unit_recording_discovery` 之后插入：
  ```systemverilog

// 记录型配置后端：验证 atomic ops 的全部设备配置副作用都经由注入的后端，
// 这是后续 AF 直配后端替换 common-config 的接入点。
class virtio_unit_recording_backend extends virtio_config_backend;
    `uvm_object_utils(virtio_unit_recording_backend)

    string calls[$];
    bit [7:0] status_reg;
    virtio_queue_program_t configured_program;
    virtio_queue_program_t disabled_program;

    function new(string name = "virtio_unit_recording_backend");
        super.new(name);
        status_reg = 0;
    endfunction

    virtual task reset(output bit ok);
        calls.push_back("reset");
        ok = 1;
    endtask
    virtual task read_status(output bit [7:0] status);
        calls.push_back("read_status");
        status = status_reg;
    endtask
    virtual task write_status(bit [7:0] status);
        calls.push_back("write_status");
        status_reg = status;
    endtask
    virtual task read_device_features(output bit [63:0] features);
        calls.push_back("read_device_features");
        features = 64'h3;
    endtask
    virtual task write_driver_features(bit [63:0] features);
        calls.push_back("write_driver_features");
    endtask
    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        calls.push_back("set_features");
        accepted = driver_caps & 64'h3;
    endtask
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        calls.push_back("query_queue_max");
        max_size = 8;
    endtask
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("configure_queue");
        configured_program = q;
        ok = 1;
    endtask
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("enable_queue");
        ok = 1;
    endtask
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("disable_queue");
        disabled_program = q;
        ok = 1;
    endtask
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        calls.push_back("reset_queue");
        ok = 1;
    endtask
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        calls.push_back("set_msix");
        ok = 1;
    endtask
    virtual task clear_msix(output bit ok);
        calls.push_back("clear_msix");
        ok = 1;
    endtask
endclass : virtio_unit_recording_backend
  ```
  在 `run_phase` 的 `test_discovery_strategy_selection();` 之后加 `        test_config_backend_injection();`，并在类末尾
  （`test_discovery_strategy_selection` 的 `endtask` 之后）加入：
  ```systemverilog

    // atomic ops 的 status/feature/queue/MSI-X/复位副作用全部经注入后端，且队列
    // 编程参数（host/BDF/IOVA/大小/环类型）完整交给后端并在拆除时原样交回。
    task test_config_backend_injection();
        virtio_atomic_ops ops;
        virtio_unit_recording_backend backend;
        virtio_pci_transport transport;
        virtqueue_manager vq_mgr;
        virtio_iommu_model iommu;
        host_mem_manager mem;
        bit [63:0] result;
        bit ok;
        string expected[$];

        ops = virtio_atomic_ops::type_id::create("backend_ops");
        backend = virtio_unit_recording_backend::type_id::create("recording_backend");
        transport = virtio_pci_transport::type_id::create("backend_transport");
        vq_mgr = virtqueue_manager::type_id::create("backend_vq_mgr");
        iommu = virtio_iommu_model::type_id::create("backend_iommu");
        mem = host_mem_manager::type_id::create("backend_mem");
        mem.init_region(64'h7600_0000, 64'h7600_FFFF);
        transport.bdf = 16'h0131;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.config_backend = backend;

        ops.set_acknowledge();
        ops.negotiate_features(64'h5, result);
        ops.setup_queue(0, 4, VQ_SPLIT, ok);
        if (!ok)
            `uvm_error("TEST", "setup_queue failed with recording backend")
        ops.teardown_queue(0);
        ops.reset_queue(0);
        ops.setup_msix(1);
        ops.device_reset_verified(ok);

        expected = '{"write_status", "set_features", "query_queue_max",
                     "configure_queue", "enable_queue", "disable_queue",
                     "reset_queue", "set_msix", "reset"};
        if (backend.calls != expected)
            `uvm_error("TEST", $sformatf("unexpected backend call sequence %p", backend.calls))
        if ((result != 64'h1) || (ops.negotiated_features != 64'h1) ||
            (backend.status_reg != DEV_STATUS_ACKNOWLEDGE) || !ok ||
            (backend.bound_transport() != transport))
            `uvm_error("TEST", "backend results were not propagated to ops")
        if ((backend.configured_program.queue_id != 0) ||
            (backend.configured_program.queue_size != 4) ||
            (backend.configured_program.vq_type != VQ_SPLIT) ||
            (backend.configured_program.bdf != 16'h0131) ||
            (backend.configured_program.desc_iova == 0) ||
            (backend.configured_program.driver_iova == 0) ||
            (backend.configured_program.device_iova == 0) ||
            (backend.disabled_program.desc_iova !=
             backend.configured_program.desc_iova) ||
            (vq_mgr.get_queue_count() != 0))
            `uvm_error("TEST", "queue program was not passed through the backend")
        `uvm_info("UNIT_TEST", "test_config_backend_injection PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，ONE TEST `virtio_unit_test`。期望 `Error-[` 编译错误：`virtio_config_backend` 未声明。

- [ ] **Step 3: 新建 `virtio_net_vip/src/transport/virtio_config_backend.sv`：**
  ```systemverilog
`ifndef VIRTIO_CONFIG_BACKEND_SV
`define VIRTIO_CONFIG_BACKEND_SV

// ============================================================================
// virtio_config_backend
//
// 目录层次：src/transport；atomic ops 的设备配置副作用（status、feature、队列编程、
// 队列启停/复位、MSI-X、Function 复位）的唯一出口。ops 负责 Host memory、IOMMU 与
// ring 所有权，后端只负责"把已经准备好的参数写进设备"。后端借用 transport，
// 由 ops 在每次调用前重新绑定；后端不持有 DMA 资源。
//   virtio_common_cfg_backend : 标准 virtio-pci common-config（现行行为）。
//   dpu_priv_config_backend   : DPU 私有环控制面（dpu_priv_device_control）。
//   后续 virtio_af_direct_backend：VIP 扮演 AF 直接写 DPU 队列/特性/中断表。
// 失败约定：configure/enable 返回 ok=0 时设备不得访问该队列；disable/reset 返回
// ok=0 时调用方保留全部 ring 与数据 DMA，不得释放。
// ============================================================================

// 一条队列的设备视角编程参数。标准环使用 desc/driver/device 三个 IOVA；私有环
// (VQ_CUSTOM) 的 desc_iova 为整块 desc+CQ 起点、device_iova 为 CQ、ring_bytes 为
// 整块长度。local_qid 为 Function 内队列号（标准 virtio 即 queue_id）。
typedef struct {
    int unsigned     host_id;
    bit [15:0]       bdf;
    int unsigned     queue_id;
    int unsigned     queue_size;
    virtqueue_type_e vq_type;
    bit [63:0]       desc_iova;
    bit [63:0]       driver_iova;
    bit [63:0]       device_iova;
    int unsigned     ring_bytes;
    int unsigned     msix_vector;
    int unsigned     local_qid;
    int unsigned     rx_buf_size;
    bit              tx_mode;
    int unsigned     notify_bar;
    bit [31:0]       notify_offset;
} virtio_queue_program_t;

// 全零的队列编程参数（环类型取 VQ_SPLIT）；避免对含枚举成员的结构使用 '{default:0}。
function automatic virtio_queue_program_t virtio_empty_queue_program();
    virtio_queue_program_t program;

    program.host_id       = 0;
    program.bdf           = '0;
    program.queue_id      = 0;
    program.queue_size    = 0;
    program.vq_type       = VQ_SPLIT;
    program.desc_iova     = '0;
    program.driver_iova   = '0;
    program.device_iova   = '0;
    program.ring_bytes    = 0;
    program.msix_vector   = 0;
    program.local_qid     = 0;
    program.rx_buf_size   = 0;
    program.tx_mode       = 0;
    program.notify_bar    = 0;
    program.notify_offset = '0;
    return program;
endfunction

virtual class virtio_config_backend extends uvm_object;
    // 当前绑定的 Function transport（借用）；ops 每次取后端时重新绑定。
    protected virtio_pci_transport transport;

    // 构造不访问设备；transport 由 bind_transport 注入。
    function new(string name = "virtio_config_backend");
        super.new(name);
        transport = null;
    endfunction

    // 绑定执行配置的 Function；只保存引用，不发起访问。
    function void bind_transport(virtio_pci_transport transport_ref);
        transport = transport_ref;
    endfunction

    // 返回当前绑定的 transport，供诊断与测试。
    function virtio_pci_transport bound_transport();
        return transport;
    endfunction

    // Function 级复位；ok=1 表示设备已确认停止全部 DMA。
    pure virtual task reset(output bit ok);
    // 设备 status 读/写（标准 virtio 生命周期）。
    pure virtual task read_status(output bit [7:0] status);
    pure virtual task write_status(bit [7:0] status);
    // 设备特性读取与驱动特性写入。
    pure virtual task read_device_features(output bit [63:0] features);
    pure virtual task write_driver_features(bit [63:0] features);
    // 完整协商：与设备能力取交集并写回，accepted 为最终生效的特性。
    pure virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
    // 查询指定队列的设备最大深度；0 表示队列不可用。
    pure virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
    // 编程一条队列（地址、深度、向量、环类型）。
    pure virtual task configure_queue(virtio_queue_program_t q, output bit ok);
    // 允许设备开始访问已编程的队列。
    pure virtual task enable_queue(virtio_queue_program_t q, output bit ok);
    // 停止队列并等待其 DMA 排空。
    pure virtual task disable_queue(virtio_queue_program_t q, output bit ok);
    // 单队列复位（virtio 1.2 Q_RESET 语义）。
    pure virtual task reset_queue(int unsigned queue_id, output bit ok);
    // 为 queue_ids 中的每条队列（升序的实际队列号）与 config change 建立 MSI-X
    // （或回退 INTx）。队列号可以不连续（control VQ 位于 2*max_virtqueue_pairs）。
    pure virtual task set_msix(int unsigned queue_ids[$], output bit ok);
    // 屏蔽全部 MSI-X 向量。
    pure virtual task clear_msix(output bit ok);
endclass

// 标准 virtio-pci common-config 后端：逐字保留 atomic ops 在 HEAD 中的寄存器序列。
class virtio_common_cfg_backend extends virtio_config_backend;
    `uvm_object_utils(virtio_common_cfg_backend)

    // 构造不访问设备。
    function new(string name = "virtio_common_cfg_backend");
        super.new(name);
    endfunction

    // 写 status=0 并轮询回读 0；超时由 transport 报告。
    virtual task reset(output bit ok);
        bit reset_complete;

        transport.reset_device_verified(reset_complete);
        ok = reset_complete;
    endtask

    virtual task read_status(output bit [7:0] status);
        bit [7:0] value;

        transport.read_device_status(value);
        status = value;
    endtask

    virtual task write_status(bit [7:0] status);
        transport.write_device_status(status);
    endtask

    virtual task read_device_features(output bit [63:0] features);
        bit [63:0] value;

        transport.read_device_features(value);
        features = value;
    endtask

    virtual task write_driver_features(bit [63:0] features);
        transport.write_driver_features(features);
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        bit [63:0] value;

        transport.negotiate_features(driver_caps, value);
        accepted = value;
    endtask

    // Q_SELECT 后读 Q_SIZE。
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        int unsigned value;

        transport.select_queue(queue_id);
        transport.read_queue_num_max(value);
        max_size = value;
    endtask

    // setup_single_queue 写大小/三个地址/向量/notify_off 并在末尾置 Q_ENABLE=1。
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        transport.setup_single_queue(q.queue_id, q.queue_size,
                                     q.desc_iova, q.driver_iova, q.device_iova,
                                     q.msix_vector);
        ok = 1;
    endtask

    // common-config 的使能已在 configure_queue 末尾完成，这里不再发 TLP。
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        ok = 1;
    endtask

    // Q_SELECT 后写 Q_ENABLE=0；标准设备无停止确认，按已停止处理。
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        transport.select_queue(q.queue_id);
        transport.write_queue_enable(0);
        ok = 1;
    endtask

    // 写 Q_RESET 并轮询完成；超时由 transport 报告（与 HEAD 的无返回包装一致）。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        transport.write_queue_reset(queue_id);
        ok = 1;
    endtask

    // 有 MSI-X capability 时建表、分配向量并绑定 config/队列向量；否则回退 INTx。
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        interrupt_mode_e actual_mode;

        if (transport.cap_mgr.has_msix()) begin
            transport.notify_mgr.setup_msix(
                transport.cap_mgr.get_msix_table_size(),
                transport.cap_mgr.msix_table_bir,
                transport.cap_mgr.msix_table_offset
            );
            transport.notify_mgr.allocate_irq_vectors(queue_ids.size(), actual_mode);

            // Bind config change vector
            transport.write_config_msix_vector(transport.notify_mgr.config_vector);

            // Bind per-queue vectors（P3-3 中 queue_ids 恒为 0..n-1，与 HEAD 相同）
            foreach (queue_ids[i]) begin
                transport.write_queue_msix_vector(
                    queue_ids[i], transport.notify_mgr.queue_vectors[queue_ids[i]]);
            end

            // Unmask all vectors
            transport.notify_mgr.unmask_all();
        end else begin
            transport.notify_mgr.irq_mode = IRQ_INTX;
            transport.notify_mgr.intx_enabled = 1;
        end
        ok = 1;
    endtask

    virtual task clear_msix(output bit ok);
        transport.notify_mgr.mask_all();
        ok = 1;
    endtask
endclass

`endif // VIRTIO_CONFIG_BACKEND_SV
  ```

- [ ] **Step 4: 新建 `virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv`：**
  ```systemverilog
// 目录层次：src/dpu_priv；把 DPU 私有环控制面接到统一的 virtio_config_backend。
// 依赖 dpu_priv_device_control（用户/后续 AF 直配实现）与 virtio_queue_program_t；
// control 为借用引用，本对象不持有 Host 内存或映射。私有协议没有标准 status/feature/
// MSI-X 寄存器，这些入口显式拒绝且不访问设备。
`ifndef DPU_PRIV_CONFIG_BACKEND_SV
`define DPU_PRIV_CONFIG_BACKEND_SV

class dpu_priv_config_backend extends virtio_config_backend;
    `uvm_object_utils(dpu_priv_config_backend)

    // 设备控制实现；由 dpu_priv_atomic_ops.configure_private 注入。
    dpu_priv_device_control control;

    // 构造不访问设备；control 由私有 ops 注入。
    function new(string name = "dpu_priv_config_backend");
        super.new(name);
        control = null;
    endfunction

    // 统一编程参数 → 私有控制上下文（字段一一对应，私有环 desc_iova 即 ring_iova）。
    static function dpu_priv_queue_context_t to_context(virtio_queue_program_t q);
        dpu_priv_queue_context_t ctx;

        ctx = '{default:0};
        ctx.host_id = q.host_id;
        ctx.bdf = q.bdf;
        ctx.queue_id = q.queue_id;
        ctx.local_qid = q.local_qid;
        ctx.queue_size = q.queue_size;
        ctx.rx_buf_size = q.rx_buf_size;
        ctx.tx_mode = q.tx_mode;
        ctx.ring_iova = q.desc_iova;
        ctx.cq_iova = q.device_iova;
        ctx.ring_bytes = q.ring_bytes;
        ctx.notify_bar = q.notify_bar;
        ctx.notify_offset = q.notify_offset;
        return ctx;
    endfunction

    // 私有控制上下文 → 统一编程参数；to_context(from_context(ctx)) 恒等。
    static function virtio_queue_program_t from_context(dpu_priv_queue_context_t ctx);
        virtio_queue_program_t q;

        q = virtio_empty_queue_program();
        q.host_id = ctx.host_id;
        q.bdf = ctx.bdf;
        q.queue_id = ctx.queue_id;
        q.queue_size = ctx.queue_size;
        q.vq_type = VQ_CUSTOM;
        q.desc_iova = ctx.ring_iova;
        q.device_iova = ctx.cq_iova;
        q.ring_bytes = ctx.ring_bytes;
        q.local_qid = ctx.local_qid;
        q.rx_buf_size = ctx.rx_buf_size;
        q.tx_mode = ctx.tx_mode;
        q.notify_bar = ctx.notify_bar;
        q.notify_offset = ctx.notify_offset;
        return q;
    endfunction

    // 私有协议不使用的标准寄存器入口统一报告，不访问设备。
    protected function void reject(string operation);
        `uvm_error("DPU_PRIV_OPS", {operation, ": 私有驱动不使用标准 Virtio 控制寄存器"})
    endfunction

    // Function 级复位由控制后端确认停 DMA；Host/BDF 取自绑定的 transport。
    virtual task reset(output bit ok);
        bit done;

        control.reset_device(transport.iommu_host_id(), transport.bdf, done);
        ok = done;
    endtask

    virtual task read_status(output bit [7:0] status);
        status = 0;
        reject("read_status");
    endtask

    virtual task write_status(bit [7:0] status);
        reject("write_status");
    endtask

    virtual task read_device_features(output bit [63:0] features);
        features = 0;
        reject("read_device_features");
    endtask

    virtual task write_driver_features(bit [63:0] features);
        reject("write_driver_features");
    endtask

    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        accepted = 0;
        reject("set_features");
    endtask

    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        max_size = 0;
        reject("query_queue_max");
    endtask

    // 配置并启动一条私有队列；失败时控制后端保证该队列未启动 DMA。
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        bit done;

        control.configure_queue(to_context(q), done);
        ok = done;
    endtask

    // 私有队列在 configure_queue 中已经启动。
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        ok = 1;
    endtask

    // 停止队列并等待 DMA 排空；只有 ok=1 才允许调用方释放 ring 与数据缓冲。
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        bit done;

        control.disable_queue(to_context(q), done);
        ok = done;
    endtask

    // 私有队列复位由 ops 以 teardown+setup 实现，不存在标准 Q_RESET。
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        ok = 0;
        reject("reset_queue");
    endtask

    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        ok = 0;
        reject("set_msix");
    endtask

    virtual task clear_msix(output bit ok);
        ok = 0;
        reject("clear_msix");
    endtask

    // 私有 doorbell：等价于驱动 writel(value, notify_addr)，经控制后端发出。
    task notify_queue(dpu_priv_queue_context_t ctx, bit [31:0] value);
        control.notify_queue(transport, ctx, value);
    endtask
endclass
`endif
  ```

- [ ] **Step 5: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv`：
  ```systemverilog
  `include "transport/virtio_pci_transport.sv"
  `include "dpu_priv/dpu_priv_driver_config.sv"
  ```
  改为
  ```systemverilog
  `include "transport/virtio_pci_transport.sv"
  `include "dpu_priv/dpu_priv_driver_config.sv"
  `include "transport/virtio_config_backend.sv"
  `include "dpu_priv/dpu_priv_config_backend.sv"
  ```

- [ ] **Step 6: atomic ops 经后端访问设备（`virtio_net_vip/src/agent/virtio_atomic_ops.sv`）。**
  1. 字段区 `bit [63:0]                 negotiated_features;` 之后加：
     ```systemverilog

    // ===== Device configuration backend =====
    // 设备配置副作用的唯一出口；为空时使用绑定当前 transport 的 common-config
    // 后端。私有 ops 与后续 AF 直配在此注入其他实现。
    virtio_config_backend      config_backend;
     ```
     在 `protected bit [63:0]         ring_iovas[int unsigned][$];` 之后加：
     ```systemverilog
    // 每个已编程队列的设备视角参数；拆除时原样交回后端，复位后清空。
    protected virtio_queue_program_t queue_programs[int unsigned];
     ```
  2. `has_pending_normal_dma()` 的 `endfunction` 之后插入：
     ```systemverilog

    // 返回本 ops 的配置后端：未注入时创建 common-config 后端；每次调用都重新绑定
    // 当前 transport，测试或 Function 替换 transport 后不会访问旧对象。
    protected function virtio_config_backend cfg_backend();
        if (config_backend == null)
            config_backend = virtio_common_cfg_backend::type_id::create(
                {get_name(), "_cfg_backend"});
        config_backend.bind_transport(transport);
        return config_backend;
    endfunction
     ```
  3. `device_reset_verified`：声明区 `int unsigned rx_qids[$];` 之后加 `        virtio_config_backend backend;`；
     `        transport.reset_device_verified(reset_complete);` 改为
     ```systemverilog
        backend = cfg_backend();
        backend.reset(reset_complete);
     ```
     `        ring_iovas.delete();` 之后加 `        queue_programs.delete();`。
  4. 状态/特性任务整体替换为（从 `virtual task set_acknowledge();` 到 `negotiate_features` 的 `endtask`，各方法上方的
     `// ---` 注释块保留不动）：
     ```systemverilog
    virtual task set_acknowledge();
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.write_status(DEV_STATUS_ACKNOWLEDGE);
        `uvm_info("ATOMIC_OPS", "set_acknowledge: done", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver -- OR current status with DRIVER bit and write back
    // ------------------------------------------------------------------------
    virtual task set_driver();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_DRIVER;
        backend.write_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_features_ok -- Set FEATURES_OK and verify device accepted it
    // ------------------------------------------------------------------------
    virtual task set_features_ok(ref bit ok);
        virtio_config_backend backend;
        bit [7:0] status;
        bit [7:0] readback;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_FEATURES_OK;
        backend.write_status(status);

        // Poll to confirm FEATURES_OK is still set
        backend.read_status(readback);
        ok = (readback & DEV_STATUS_FEATURES_OK) ? 1 : 0;

        if (!ok) begin
            `uvm_error("ATOMIC_OPS",
                "set_features_ok: device rejected features (FEATURES_OK not set)")
        end else begin
            `uvm_info("ATOMIC_OPS",
                $sformatf("set_features_ok: confirmed, status=0x%02h", readback), UVM_HIGH)
        end
    endtask

    // ------------------------------------------------------------------------
    // verify_features_ok -- Re-read status and check FEATURES_OK bit
    // ------------------------------------------------------------------------
    virtual task verify_features_ok(ref bit ok);
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        ok = (status & DEV_STATUS_FEATURES_OK) ? 1 : 0;
        `uvm_info("ATOMIC_OPS",
            $sformatf("verify_features_ok: status=0x%02h ok=%0b", status, ok), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver_ok -- OR current status with DRIVER_OK bit
    // ------------------------------------------------------------------------
    virtual task set_driver_ok();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_DRIVER_OK;
        backend.write_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver_ok: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_failed -- OR current status with FAILED bit
    // ------------------------------------------------------------------------
    virtual task set_failed();
        virtio_config_backend backend;
        bit [7:0] status;

        backend = cfg_backend();
        backend.read_status(status);
        status = status | DEV_STATUS_FAILED;
        backend.write_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_failed: status=0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // Feature Negotiation
    // ========================================================================

    // ------------------------------------------------------------------------
    // read_device_features -- Read device-offered feature bits
    // ------------------------------------------------------------------------
    virtual task read_device_features(ref bit [63:0] features);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.read_device_features(features);
    endtask

    // ------------------------------------------------------------------------
    // write_driver_features -- Write driver-selected feature bits
    // ------------------------------------------------------------------------
    virtual task write_driver_features(bit [63:0] features);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.write_driver_features(features);
    endtask

    // ------------------------------------------------------------------------
    // negotiate_features -- AND device features with driver caps, write result
    // ------------------------------------------------------------------------
    virtual task negotiate_features(bit [63:0] driver_caps, ref bit [63:0] result);
        virtio_config_backend backend;

        backend = cfg_backend();
        backend.set_features(driver_caps, result);
        negotiated_features = result;
        `uvm_info("ATOMIC_OPS",
            $sformatf("negotiate_features: result=0x%016h", result), UVM_MEDIUM)
    endtask
     ```
     （替换范围的起点是 `virtual task set_acknowledge();`，终点是 `negotiate_features` 的 `endtask`；
     `set_acknowledge` 上方的注释块与 `// Queue Management` 横幅不在替换范围内。）
  5. `setup_queue` 整体替换（从 `virtual task setup_queue(` 到其 `endtask`）：
     ```systemverilog
    virtual task setup_queue(
        int unsigned       queue_id,
        int unsigned       queue_size,
        virtqueue_type_e   vq_type,
        output bit          ok
    );
        virtqueue_base     vq;
        virtio_config_backend backend;
        virtio_queue_program_t program;
        int unsigned       max_size;
        int unsigned       eff_size;
        int unsigned       desc_size;
        int unsigned       avail_size;
        int unsigned       used_size;
        bit [63:0]         desc_iova;
        bit [63:0]         avail_iova;
        bit [63:0]         used_iova;
        int unsigned       msix_vector;
        bit                configured;

        ok = 0;
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            (mem == null)) begin
            `uvm_error("ATOMIC_OPS", "setup_queue: incomplete queue context")
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d size=%0d type=%s",
                      queue_id, queue_size, vq_type.name()), UVM_MEDIUM)

        // 1-2. Select queue and read device-advertised max queue size
        backend = cfg_backend();
        backend.query_queue_max(queue_id, max_size);

        // 3. Determine effective size
        if (queue_size == 0)
            eff_size = max_size;
        else if (queue_size > max_size) begin
            `uvm_warning("ATOMIC_OPS",
                $sformatf("setup_queue: requested size %0d exceeds max %0d, using max",
                          queue_size, max_size))
            eff_size = max_size;
        end else
            eff_size = queue_size;

        if (eff_size == 0) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: device reported zero-sized queue %0d", queue_id))
            return;
        end

        // 4. Create queue via manager
        vq = vq_mgr.create_queue(queue_id, eff_size, vq_type);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("setup_queue: failed to create queue %0d", queue_id))
            return;
        end

        // 5. Allocate ring memory
        vq.alloc_rings();

        // 6. Compute ring region sizes for IOMMU mapping
        case (vq_type)
            VQ_SPLIT: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
            VQ_PACKED: begin
                desc_size  = 16 * eff_size;
                // Packed rings place two independent 4-byte event
                // suppression structures after the descriptor table.  Map
                // each structure at its own programmed GPA; mapping 8 bytes
                // from device_event_addr would run past the contiguous ring.
                avail_size = 4;
                used_size  = 4;
            end
            default: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
        endcase

        // 7. Map ring addresses through IOMMU
        desc_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.desc_table_addr, desc_size, DMA_BIDIRECTIONAL);
        avail_iova = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.driver_ring_addr, avail_size, DMA_BIDIRECTIONAL);
        used_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.device_ring_addr, used_size, DMA_BIDIRECTIONAL);
        if ((desc_iova == '1) || (desc_iova == 0) ||
            (avail_iova == '1) || (avail_iova == 0) ||
            (used_iova == '1) || (used_iova == 0)) begin
            if ((desc_iova != '1) && (desc_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, desc_iova);
            if ((avail_iova != '1) && (avail_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, avail_iova);
            if ((used_iova != '1) && (used_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, used_iova);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: failed to map queue_id=%0d rings", queue_id))
            return;
        end

        // Track ring IOVAs for cleanup
        ring_iovas[queue_id] = '{desc_iova, avail_iova, used_iova};

        // 8. Determine MSI-X vector for this queue
        if (transport.notify_mgr.queue_vectors.size() > queue_id)
            msix_vector = transport.notify_mgr.queue_vectors[queue_id];
        else
            msix_vector = 0;

        // 9. 经配置后端编程并启用队列（common-config：写大小/地址/向量并置
        // Q_ENABLE）。后端拒绝时设备不得访问该队列，因此可以立即回收 ring 映射。
        program = virtio_empty_queue_program();
        program.host_id     = get_iommu_host_id(transport);
        program.bdf         = transport.bdf;
        program.queue_id    = queue_id;
        program.queue_size  = eff_size;
        program.vq_type     = vq_type;
        program.desc_iova   = desc_iova;
        program.driver_iova = avail_iova;
        program.device_iova = used_iova;
        program.msix_vector = msix_vector;
        program.local_qid   = queue_id;
        program.tx_mode     = queue_id[0];
        backend.configure_queue(program, configured);
        if (configured)
            backend.enable_queue(program, configured);
        if (!configured) begin
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, desc_iova);
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, avail_iova);
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf, used_iova);
            ring_iovas.delete(queue_id);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: config backend rejected queue_id=%0d", queue_id))
            return;
        end
        queue_programs[queue_id] = program;

        // 10. Mark queue as enabled
        vq.state = VQ_ENABLED;
        vq.queue_enable = 1;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d complete, desc_iova=0x%016h avail_iova=0x%016h used_iova=0x%016h",
                      queue_id, desc_iova, avail_iova, used_iova), UVM_MEDIUM)
        ok = 1;
    endtask
     ```
  6. `teardown_queue` 中
     ```systemverilog
        virtqueue_base vq;
        uvm_object tokens[$];
     ```
     改为
     ```systemverilog
        virtqueue_base vq;
        uvm_object tokens[$];
        virtio_config_backend backend;
        virtio_queue_program_t program;
        bit stopped;
     ```
     并把
     ```systemverilog
        // 1. Disable queue on transport
        transport.select_queue(queue_id);
        transport.write_queue_enable(0);
     ```
     改为
     ```systemverilog
        // 1. 经配置后端停用队列；后端未确认停止时保留全部 ring/DMA 所有权。
        if (queue_programs.exists(queue_id))
            program = queue_programs[queue_id];
        else begin
            program = virtio_empty_queue_program();
            program.host_id  = get_iommu_host_id(transport);
            program.bdf      = transport.bdf;
            program.queue_id = queue_id;
        end
        backend = cfg_backend();
        backend.disable_queue(program, stopped);
        if (!stopped) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "teardown_queue: config backend did not confirm queue_id=%0d stopped; retaining queue DMA",
                queue_id))
            return;
        end
     ```
     并在 `        // 5. Destroy queue` / `        vq_mgr.destroy_queue(queue_id);` 之后加 `        queue_programs.delete(queue_id);`。
  7. `reset_queue` 方法体替换为：
     ```systemverilog
    virtual task reset_queue(int unsigned queue_id);
        virtio_config_backend backend;
        bit reset_ok;

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Write Q_RESET and poll until complete
        backend = cfg_backend();
        backend.reset_queue(queue_id, reset_ok);
        if (!reset_ok) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "reset_queue: config backend did not confirm queue_id=%0d reset", queue_id))
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d reset complete", queue_id), UVM_MEDIUM)
    endtask
     ```
  8. `setup_msix` 方法体替换为：
     ```systemverilog
    virtual task setup_msix(int unsigned num_queues);
        virtio_config_backend backend;
        int unsigned queue_ids[$];
        bit msix_ok;

        // 队列号 0..num_queues-1（与 HEAD 相同）；P3-9 改为 vq_mgr 中的实际队列号。
        for (int unsigned q = 0; q < num_queues; q++)
            queue_ids.push_back(q);
        backend = cfg_backend();
        backend.set_msix(queue_ids, msix_ok);
        if (!msix_ok)
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_msix: config backend rejected %0d queue vectors", num_queues))

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_msix: num_queues=%0d mode=%s",
                      num_queues, transport.notify_mgr.irq_mode.name()), UVM_MEDIUM)
    endtask
     ```
  9. `teardown_msix` 方法体替换为：
     ```systemverilog
    virtual task teardown_msix();
        virtio_config_backend backend;
        bit cleared;

        backend = cfg_backend();
        backend.clear_msix(cleared);
        `uvm_info("ATOMIC_OPS", "teardown_msix: all vectors masked", UVM_MEDIUM)
    endtask
     ```
  10. 证据：`grep -nE "transport\.(reset_device_verified|read_device_status|write_device_status|read_device_features|write_driver_features|negotiate_features|select_queue|read_queue_num_max|setup_single_queue|write_queue_enable|write_queue_reset\(|write_config_msix_vector|write_queue_msix_vector)" virtio_net_vip/src/agent/virtio_atomic_ops.sv`
      期望输出为空（`admin_vq_submit` 使用的是 `admin_context.transport.write_queue_reset_verified`，不在此模式内）。

- [ ] **Step 7: 私有 ops 经 dpu_priv 后端访问控制面（`virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`）。**
  1. `    protected dpu_priv_device_control device_control;` 改为
     ```systemverilog
    // 私有控制面后端：包装 env_cfg 注入的 dpu_priv_device_control，同时作为本 ops
    // 的 config_backend；doorbell 也经它发出。
    protected dpu_priv_config_backend private_backend;
     ```
  2. `configure_private` 中 `        device_control = cfg.control;` 改为
     ```systemverilog
        private_backend = dpu_priv_config_backend::type_id::create(
            {get_name(), "_private_backend"});
        private_backend.control = cfg.control;
        config_backend = private_backend;
     ```
  3. `context_ready` 中 `        if ((device_control == null) || (transport == null) || (mem == null) ||` 改为
     `        if ((private_backend == null) || (private_backend.control == null) || (transport == null) || (mem == null) ||`。
  4. `setup_queue`：声明区 `bit configured;` 之后加 `        virtio_config_backend backend;`；
     `        device_control.configure_queue(ctx, configured);` 改为
     ```systemverilog
        backend = cfg_backend();
        backend.configure_queue(dpu_priv_config_backend::from_context(ctx), configured);
     ```
  5. `teardown_queue` 整体替换为：
     ```systemverilog
    virtual task teardown_queue(int unsigned queue_id);
        virtio_config_backend backend;
        bit stopped;
        if (!contexts.exists(queue_id)) return;
        backend = cfg_backend();
        backend.disable_queue(dpu_priv_config_backend::from_context(contexts[queue_id]),
                              stopped);
        if (!stopped) begin
            `uvm_error("DPU_PRIV_OPS", "teardown: 未确认 DMA 停止，保留队列资源")
            return;
        end
        release_stopped_queue(queue_id);
    endtask
     ```
  6. `device_reset_verified` 整体替换为：
     ```systemverilog
    virtual task device_reset_verified(ref bit reset_complete);
        virtio_config_backend backend;
        int unsigned qids[$];
        reset_complete = 0;
        if (!context_ready()) return;
        backend = cfg_backend();
        backend.reset(reset_complete);
        if (!reset_complete) begin
            `uvm_error("DPU_PRIV_OPS", "reset: 未确认 Function 停止 DMA，保留资源")
            return;
        end
        foreach (contexts[qid]) qids.push_back(qid);
        foreach (qids[i]) release_stopped_queue(qids[i]);
        negotiated_features = 0;
    endtask
     ```
  7. `kick_queue` 中 `        device_control.notify_queue(transport, contexts[queue_id], cb.last_notify_word);` 改为
     ```systemverilog
        private_backend.bind_transport(transport);
        private_backend.notify_queue(contexts[queue_id], cb.last_notify_word);
     ```
  8. 证据：`grep -n "device_control" virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv` 期望为空。

- [ ] **Step 8: 文档。** README 目录树在 `virtio_discovery_strategy.sv` 行之后插入
  `│   │   ├── virtio_config_backend.sv        ← 设备配置后端接口 + common-config 实现`；
  手册目录树相应位置插入 `|   |   +-- virtio_config_backend.sv        -- 设备配置后端接口 + common-config 实现`。
  （README/手册在 HEAD 均未列出 `src/dpu_priv/` 目录，故不为 `dpu_priv_config_backend.sv` 加目录树条目。）

- [ ] **Step 9: SYNC 并运行受影响测试（期望 PASS）。** SYNC 后 ONE TEST 依次运行
  `virtio_unit_test`、`virtio_migration_dirty_test`、`virtio_admin_vq_test`、`virtio_pf_lifecycle_reset_test`、
  `virtio_indirect_desc_test`、`virtio_real_driver_flow_test`、`virtio_dut_caps_test`；私有环两个测试（P0.4 后在 manifest 中）
  同样运行；若 P0.4 尚未合入则运行 `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p3-3'`，期望 `flow_rc=0`、`contract_rc=0`、计数全 0。

- [ ] **Step 10: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 11: 提交。**
  ```bash
  git add virtio_net_vip/src/transport/virtio_config_backend.sv virtio_net_vip/src/dpu_priv/dpu_priv_config_backend.sv \
          virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv \
          virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv virtio_net_vip/tests/virtio_unit_test.sv \
          README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 引入 virtio_config_backend 收敛设备配置写入路径"
  ```

---

### Task P3-4: `virtio_driver_protocol` —— 标准 / DPU 私有驱动协议对象

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_driver_protocol.sv`（抽象类 + `virtio_standard_driver_protocol`）
- Create: `virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（`dpu_priv/dpu_priv_auto_fsm.sv` 之后、`agent/virtio_driver.sv` 之前，HEAD :86-87；`dpu_priv/dpu_priv_dataplane.sv` 之后，HEAD :112）
- Modify: `virtio_net_vip/src/agent/virtio_driver.sv`（`process_transaction` HEAD :58-108、`dispatch_atomic_op` :117-200，`$cast`/`is_private` 在 :60-62、:119-131、:158-190）
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`（`prepare_driver_candidates` :66-94、`preflight_bind_pcie` :253-273、`cancel_preflight_bind_pcie` :296-300、
  `commit_preflight_bind_pcie` :304-336、`commit_validated_pcie_components` :360-370/:399-410/:431-435、`shutdown` :619-645、字段区 :47-51、`new()` :55-62）
- Modify: `virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv`（`do_full_init` :19-39 的 `$cast`）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 与 `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv`（新增 `uses_private_ring()`）
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树）
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`

**Interfaces:**
- Consumes: `virtio_atomic_ops`、`virtio_auto_fsm`（`state`、`stop_dataplane()`）、`virtio_transaction`（`queue_id/completed_pkts/received_pkts/success`）、
  `dpu_priv_atomic_ops.{configure_private, kick_queue}`、`dpu_priv_driver_config.{validate, rx_buf_size}`、`dpu_priv_tx_engine/dpu_priv_rx_engine`（`private_ops`、`buf_size`）。
- Produces:
  ```systemverilog
  virtual class virtio_driver_protocol extends uvm_object;
      pure virtual function string protocol_name();
      pure virtual function bit allows_status_access();
      pure virtual function bit requires_verified_reset();
      pure virtual function bit prepare_candidates(string label, uvm_component parent,
          virtio_driver_config_t behavior, ref virtio_atomic_ops candidate_ops,
          ref virtio_auto_fsm candidate_fsm);
      pure virtual function bit bind_ops(virtio_atomic_ops ops,
          virtio_driver_config_t behavior, output string why);
      pure virtual function void install_dataplane(virtio_net_dataplane dataplane,
          virtio_atomic_ops ops, string label);
      pure virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
      pure virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
      pure virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm, virtio_transaction req);
  endclass
  class virtio_standard_driver_protocol; class dpu_priv_driver_protocol (dpu_priv_driver_config private_cfg;)
  ```
  `virtio_driver::protocol`（公有字段，空则标准）、`virtio_function_instance::protocol`（提交后的协议）、
  `virtio_atomic_ops::uses_private_ring()`（虚函数，基类 0，私有 1）。

**Spec deviation:**
- P2-5 之后 function instance 中 `private_cfg != null` 仍在 `prepare_driver_candidates`（选择点）、preflight、commit 私有冻结、
  dataplane 适配器安装、`shutdown` 出现；本任务把选择保留为唯一一处（`prepare_driver_candidates` 内），其余全部改为协议分派。
- 私有 FSM 的 `$cast(private_ops, ops)` 有两个用途：配对校验与读取 `get_queue_context(0)` 的实际队列深度。配对校验改为
  `ops.uses_private_ring()`；队列深度改读 `ops.vq_mgr.get_queue(0).queue_size`（私有 `setup_queue` 以同一 `size` 创建该 vq，二者恒等）。
- `dpu_priv_driver_protocol::bind_ops` 在 ops 类型不符时给出 why 文本（HEAD 该路径 why 为空串）；仅错误路径文本变化。
- 若 P2-1 已改写 function instance 中私有 dataplane 适配器块（HEAD :401-410），把 P2-1 之后该 `if (private_cfg != null) begin ... end`
  块的内容原样移入 `dpu_priv_driver_protocol::install_dataplane`（以下代码按 HEAD 写出）。

- [ ] **Step 1: 写失败测试。** `virtio_net_vip/tests/virtio_unit_test.sv` 中，在 `endclass : virtio_unit_recording_backend` 之后插入：
  ```systemverilog

// 私有控制后端桩：所有操作立即成功，只用于驱动协议的配置冻结检查，不产生 DMA。
class virtio_unit_priv_control_stub extends dpu_priv_device_control;
    `uvm_object_utils(virtio_unit_priv_control_stub)

    function new(string name = "virtio_unit_priv_control_stub");
        super.new(name);
    endfunction

    virtual task reset_device(int unsigned host_id, bit [15:0] bdf, output bit ok);
        ok = 1;
    endtask
    virtual task configure_queue(dpu_priv_queue_context_t ctx, output bit ok);
        ok = 1;
    endtask
    virtual task disable_queue(dpu_priv_queue_context_t ctx, output bit ok);
        ok = 1;
    endtask
endclass : virtio_unit_priv_control_stub

// 按 ID 与完整消息匹配一条预期 UVM_ERROR；其他报告照常抛出。
class virtio_unit_exact_error_catcher extends uvm_report_catcher;
    string expected_id;
    string expected_message;
    int unsigned caught_count;

    function new(string name, string configured_id, string configured_message);
        super.new(name);
        expected_id = configured_id;
        expected_message = configured_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == expected_id) &&
            (get_message() == expected_message)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_unit_exact_error_catcher
  ```
  `run_phase` 中 `test_config_backend_injection();` 之后加 `        test_driver_protocol_selection();`，类末尾加入：
  ```systemverilog

    // 驱动协议决定 ops/FSM 的类型、status 访问权限与关机复位语义；私有协议拒绝
    // 接管已绑定的标准 ops。
    task test_driver_protocol_selection();
        virtio_standard_driver_protocol standard;
        dpu_priv_driver_protocol private_protocol;
        dpu_priv_driver_config private_cfg;
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;
        dpu_priv_atomic_ops typed_ops;
        dpu_priv_auto_fsm typed_fsm;
        virtio_driver_config_t behavior;
        virtio_unit_exact_error_catcher catcher;
        string why;

        behavior = '{default: 0};
        behavior.num_queue_pairs = 1;
        standard = virtio_standard_driver_protocol::type_id::create(
            "unit_standard_protocol");
        ops = null;
        fsm = null;
        if (!standard.allows_status_access() || standard.requires_verified_reset() ||
            !standard.prepare_candidates("unit_standard", null, behavior, ops, fsm) ||
            (ops == null) || (fsm == null) || ops.uses_private_ring() ||
            !standard.bind_ops(ops, behavior, why))
            `uvm_error("TEST", "standard driver protocol did not select standard ops/FSM")

        private_cfg = dpu_priv_driver_config::type_id::create("unit_private_cfg");
        private_cfg.control = virtio_unit_priv_control_stub::type_id::create(
            "unit_private_control");
        private_protocol = dpu_priv_driver_protocol::type_id::create(
            "unit_private_protocol");
        private_protocol.private_cfg = private_cfg;
        behavior.vq_type = VQ_CUSTOM;
        behavior.irq_mode = IRQ_POLLING;
        ops = null;
        fsm = null;
        if (private_protocol.allows_status_access() ||
            !private_protocol.requires_verified_reset() ||
            !private_protocol.prepare_candidates("unit_private", null, behavior, ops, fsm) ||
            !$cast(typed_ops, ops) || !$cast(typed_fsm, fsm) ||
            (typed_ops == null) || (typed_fsm == null) || !ops.uses_private_ring() ||
            !private_protocol.bind_ops(ops, behavior, why))
            `uvm_error("TEST", {"private driver protocol did not select private ops/FSM: ", why})

        ops = virtio_atomic_ops::type_id::create("unit_conflicting_ops");
        fsm = null;
        catcher = new("protocol_conflict_catcher", "FUNCTION_BIND",
                      "私有配置与已绑定 ops/FSM 类型冲突");
        uvm_report_cb::add(null, catcher);
        if (private_protocol.prepare_candidates("unit_conflict", null, behavior, ops, fsm))
            `uvm_error("TEST", "private protocol accepted a standard ops candidate")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count != 1)
            `uvm_error("TEST", "private protocol did not report the ops/FSM type conflict")
        `uvm_info("UNIT_TEST", "test_driver_protocol_selection PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，ONE TEST `virtio_unit_test`。期望 `Error-[` 编译错误：`virtio_standard_driver_protocol` 未声明。

- [ ] **Step 3: ops 增加私有环标识。** `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 中 P3-3 加入的 `cfg_backend()` 的 `endfunction` 之后插入：
  ```systemverilog

    // 是否为 DPU 私有环 ops；私有 FSM 用它确认 ops/FSM 配对，无需类型转换。
    virtual function bit uses_private_ring();
        return 0;
    endfunction
  ```
  `virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv` 中 `get_queue_context` 的 `endfunction` 之后插入：
  ```systemverilog

    // 私有环 ops 标识，供私有 FSM 校验配对。
    virtual function bit uses_private_ring();
        return 1;
    endfunction
  ```

- [ ] **Step 4: 新建 `virtio_net_vip/src/agent/virtio_driver_protocol.sv`：**
  ```systemverilog
`ifndef VIRTIO_DRIVER_PROTOCOL_SV
`define VIRTIO_DRIVER_PROTOCOL_SV

// dataplane 在本文件之后编译；这里只把它作为参数类型使用。
typedef class virtio_net_dataplane;

// ============================================================================
// virtio_driver_protocol
//
// 目录层次：src/agent；一个 Function 的驱动协议（标准 virtio / DPU 私有环）。
// Function 只在 prepare_driver_candidates 中选择一次协议；此后 ops/FSM 候选的创建
// 与校验、协议专属配置冻结、dataplane 引擎安装、MANUAL kick/poll、驱动复位与
// 关机复位语义全部由协议对象分派，driver/function/FSM 不再做类型转换。
// 协议对象不持有 ring/DMA；资源始终归所选 ops 所有。
// ============================================================================

virtual class virtio_driver_protocol extends uvm_object;
    // 构造不访问设备。
    function new(string name = "virtio_driver_protocol");
        super.new(name);
    endfunction

    // 协议名，供日志与测试。
    pure virtual function string protocol_name();
    // MANUAL 事务是否可直接读写标准 virtio status 寄存器。
    pure virtual function bit allows_status_access();
    // 驱动复位与 Function 关机是否必须等待设备确认停 DMA（失败保留全部资源）。
    pure virtual function bit requires_verified_reset();
    // 预检：校验行为配置，按需创建 ops/FSM 候选；已提供的对象类型不符时返回 0。
    // 不访问设备，不冻结配置。
    pure virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
    // 提交：把协议专属配置冻结进 ops；失败时 why 说明原因。
    pure virtual function bit bind_ops(virtio_atomic_ops ops,
                                       virtio_driver_config_t behavior,
                                       output string why);
    // 让 Function 的 dataplane 引擎与 sequence/FSM 共用同一个 ops。
    pure virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                                 virtio_atomic_ops ops, string label);
    // MANUAL ATOMIC_KICK。
    pure virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
    // MANUAL ATOMIC_POLL_USED。
    pure virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
    // VIO_TXN_RESET。
    pure virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                            virtio_transaction req);
endclass

// 标准 virtio-pci 驱动：逐字保留 HEAD 中 driver/function 的非私有分支行为。
class virtio_standard_driver_protocol extends virtio_driver_protocol;
    `uvm_object_utils(virtio_standard_driver_protocol)

    // 构造不访问设备。
    function new(string name = "virtio_standard_driver_protocol");
        super.new(name);
    endfunction

    virtual function string protocol_name();
        return "standard";
    endfunction

    virtual function bit allows_status_access();
        return 1;
    endfunction

    virtual function bit requires_verified_reset();
        return 0;
    endfunction

    // 未提供时用 factory 创建标准 FSM 与 ops；创建失败留给调用方的空句柄检查报告。
    virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create(
                {label, "_fsm"}, parent);
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create(
                {label, "_ops"}, parent);
        return 1;
    endfunction

    // 标准驱动没有需要冻结的协议专属配置。
    virtual function bit bind_ops(virtio_atomic_ops ops,
                                  virtio_driver_config_t behavior,
                                  output string why);
        why = "";
        return 1;
    endfunction

    // 标准 dataplane 引擎保持 Function 构造时的默认实例。
    virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                            virtio_atomic_ops ops, string label);
    endfunction

    virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
        virtqueue_base vq;

        vq = ops.vq_mgr.get_queue(queue_id);
        if (vq != null)
            vq.kick();
        else
            `uvm_error("VIRTIO_DRV",
                $sformatf("ATOMIC_KICK: queue %0d not found", queue_id))
    endtask

    virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
        uvm_object token;
        int unsigned len;
        virtqueue_base vq;

        vq = ops.vq_mgr.get_queue(req.queue_id);
        if (vq != null)
            void'(vq.poll_used(token, len));
        else
            `uvm_error("VIRTIO_DRV",
                $sformatf("ATOMIC_POLL_USED: queue %0d not found", req.queue_id))
    endtask

    virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                       virtio_transaction req);
        ops.device_reset();
    endtask
endclass

`endif // VIRTIO_DRIVER_PROTOCOL_SV
  ```

- [ ] **Step 5: 新建 `virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv`：**
  ```systemverilog
// 目录层次：src/dpu_priv；DPU 私有环驱动协议。依赖私有 ops/FSM/dataplane 适配器与
// dpu_priv_driver_config（借用，env_cfg 按 service key 注入）。不访问标准 status/MSI-X；
// 复位与关机必须由控制后端确认停 DMA，失败保留资源并进入错误态。
`ifndef DPU_PRIV_DRIVER_PROTOCOL_SV
`define DPU_PRIV_DRIVER_PROTOCOL_SV

class dpu_priv_driver_protocol extends virtio_driver_protocol;
    `uvm_object_utils(dpu_priv_driver_protocol)

    // 本 Function 的私有配置；prepare/bind 前由 Function 注入。
    dpu_priv_driver_config private_cfg;

    // 构造不访问设备。
    function new(string name = "dpu_priv_driver_protocol");
        super.new(name);
        private_cfg = null;
    endfunction

    virtual function string protocol_name();
        return "dpu_priv";
    endfunction

    // 私有协议的状态控制由 AF/mailbox 后端负责。
    virtual function bit allows_status_access();
        return 0;
    endfunction

    virtual function bit requires_verified_reset();
        return 1;
    endfunction

    // 校验私有配置与 VQ_CUSTOM/polling 行为，创建私有 ops/FSM；已提供的对象类型冲突时拒绝。
    virtual function bit prepare_candidates(
        string label, uvm_component parent, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm);
        dpu_priv_atomic_ops private_ops;
        dpu_priv_auto_fsm private_fsm;
        string why;

        why = "private_cfg 未注入";
        if ((private_cfg == null) ||
            !private_cfg.validate(behavior.num_queue_pairs, why) ||
            behavior.vq_type != VQ_CUSTOM || behavior.irq_mode != IRQ_POLLING) begin
            `uvm_error("FUNCTION_BIND", {"私有驱动配置非法: ", why})
            return 0;
        end
        if (candidate_ops == null)
            candidate_ops = dpu_priv_atomic_ops::type_id::create({label, "_ops"});
        if (candidate_fsm == null)
            candidate_fsm = dpu_priv_auto_fsm::type_id::create({label, "_fsm"});
        if (!$cast(private_ops, candidate_ops) || !$cast(private_fsm, candidate_fsm)) begin
            `uvm_error("FUNCTION_BIND", "私有配置与已绑定 ops/FSM 类型冲突")
            return 0;
        end
        return (candidate_ops != null) && (candidate_fsm != null);
    endfunction

    // 冻结一份私有配置进 ops（有活动队列时 ops 拒绝重配）。
    virtual function bit bind_ops(virtio_atomic_ops ops,
                                  virtio_driver_config_t behavior,
                                  output string why);
        dpu_priv_atomic_ops private_ops;

        why = "";
        if (!$cast(private_ops, ops) || (private_ops == null)) begin
            why = "私有协议要求 dpu_priv_atomic_ops";
            return 0;
        end
        return private_ops.configure_private(private_cfg, behavior.num_queue_pairs, why);
    endfunction

    // 私有 Function 的引擎复用同一个 ops，保证 engine 与 sequence/FSM 不会各自产生
    // 一套 DMA tracker 或混入标准 Virtio-net header。
    virtual function void install_dataplane(virtio_net_dataplane dataplane,
                                            virtio_atomic_ops ops, string label);
        dpu_priv_atomic_ops private_ops;
        dpu_priv_tx_engine tx_adapter;
        dpu_priv_rx_engine rx_adapter;

        if ((dataplane == null) || !$cast(private_ops, ops))
            return;
        tx_adapter = new({label, "_private_tx"});
        rx_adapter = new({label, "_private_rx"});
        tx_adapter.private_ops = private_ops;
        rx_adapter.private_ops = private_ops;
        rx_adapter.buf_size = private_cfg.rx_buf_size;
        dataplane.tx_engine = tx_adapter;
        dataplane.rx_engine = rx_adapter;
    endfunction

    // 发布内存屏障后发送私有 32-bit doorbell。
    virtual task kick(virtio_atomic_ops ops, int unsigned queue_id);
        dpu_priv_atomic_ops private_ops;

        if (!$cast(private_ops, ops) || (private_ops == null)) begin
            `uvm_error("VIRTIO_DRV", "私有协议未绑定私有 ops")
            return;
        end
        private_ops.kick_queue(queue_id);
    endtask

    // 私有完成必须经过 ops 回收数据 DMA，不能裸 poll 丢弃 token。
    virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);
        int unsigned budget;

        budget = 1;
        if (req.queue_id % 2)
            ops.tx_complete(req.queue_id, req.completed_pkts, budget);
        else
            ops.rx_receive(req.queue_id, req.received_pkts, budget);
    endtask

    // 先停止后台 worker，再确认设备停止 DMA；结果决定 FSM 进入重初始化或错误态。
    virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm,
                       virtio_transaction req);
        if (fsm.state == FSM_RUNNING) fsm.stop_dataplane();
        ops.device_reset_verified(req.success);
        fsm.state = req.success ? FSM_REINIT_REQUIRED : FSM_ERROR;
    endtask
endclass
`endif
  ```

- [ ] **Step 6: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv`：
  ```systemverilog
  `include "dpu_priv/dpu_priv_auto_fsm.sv"
  `include "agent/virtio_driver.sv"
  ```
  改为
  ```systemverilog
  `include "dpu_priv/dpu_priv_auto_fsm.sv"
  `include "agent/virtio_driver_protocol.sv"
  `include "agent/virtio_driver.sv"
  ```
  且
  ```systemverilog
  `include "dpu_priv/dpu_priv_dataplane.sv"
  ```
  改为
  ```systemverilog
  `include "dpu_priv/dpu_priv_dataplane.sv"
  `include "dpu_priv/dpu_priv_driver_protocol.sv"
  ```

- [ ] **Step 7: driver 经协议分派（`virtio_net_vip/src/agent/virtio_driver.sv`）。**
  1. `    virtio_auto_fsm     fsm;` 之后加：
     ```systemverilog
    // Function 提交绑定时注入；为空时（standalone/测试）按标准 virtio 处理。
    virtio_driver_protocol protocol;
     ```
  2. `new()` 之后插入：
     ```systemverilog

    // 当前驱动协议；未注入时惰性创建标准协议。
    protected function virtio_driver_protocol active_protocol();
        if (protocol == null)
            protocol = virtio_standard_driver_protocol::type_id::create("standard_protocol");
        return protocol;
    endfunction
     ```
  3. `process_transaction` 中：
     ```systemverilog
        bit setup_ok;
        dpu_priv_atomic_ops private_ops;
        bit is_private;
        is_private = $cast(private_ops, ops);
     ```
     改为
     ```systemverilog
        bit setup_ok;
        virtio_driver_protocol proto;
        proto = active_protocol();
     ```
     且
     ```systemverilog
            VIO_TXN_RESET: begin
                if (is_private) begin
                    if (fsm.state == FSM_RUNNING) fsm.stop_dataplane();
                    ops.device_reset_verified(req.success);
                    fsm.state = req.success ? FSM_REINIT_REQUIRED : FSM_ERROR;
                end else ops.device_reset();
            end
     ```
     改为
     ```systemverilog
            VIO_TXN_RESET:      proto.reset(ops, fsm, req);
     ```
     方法上方注释 `// 按事务类型调用统一 API；私有复位须先停止后台 worker，再确认设备停止 DMA。`
     改为 `// 按事务类型调用统一 API；复位语义（是否先停 worker 并确认停 DMA）由驱动协议决定。`
  4. `dispatch_atomic_op` 中：
     ```systemverilog
        bit setup_ok;
        dpu_priv_atomic_ops private_ops;
        bit is_private;
        int unsigned private_poll_budget = 1;

        // 私有协议的状态控制由 AF/mailbox 后端负责；显式拒绝标准状态访问，
        // 其余请求继续分派到同一 Function 的 ops，保持 DMA 所有权一致。
        is_private = $cast(private_ops, ops);
        if (is_private && ((req.atomic_op == ATOMIC_SET_STATUS) ||
                           (req.atomic_op == ATOMIC_READ_STATUS))) begin
     ```
     改为
     ```systemverilog
        bit setup_ok;
        virtio_driver_protocol proto;

        // 协议不允许标准状态访问时（私有环由 AF/mailbox 后端控制状态）显式拒绝，
        // 其余请求继续分派到同一 Function 的 ops，保持 DMA 所有权一致。
        proto = active_protocol();
        if (!proto.allows_status_access() &&
            ((req.atomic_op == ATOMIC_SET_STATUS) ||
             (req.atomic_op == ATOMIC_READ_STATUS))) begin
     ```
     且把 `ATOMIC_KICK: begin ... end` 整个分支（从 `            ATOMIC_KICK: begin` 到其配对 `            end`）替换为
     ```systemverilog
            ATOMIC_KICK:
                proto.kick(ops, req.queue_id);
     ```
     把 `ATOMIC_POLL_USED: begin ... end` 整个分支替换为
     ```systemverilog
            ATOMIC_POLL_USED:
                proto.poll_used(ops, req);
     ```
  5. 证据：`grep -n "dpu_priv\|is_private\|\$cast" virtio_net_vip/src/agent/virtio_driver.sv` 期望为空。

- [ ] **Step 8: function instance 只在一处选择协议（`virtio_net_vip/src/sriov/virtio_function_instance.sv`）。**
  1. 字段区 `    local bit              pcie_bind_prepared;` 之后加：
     ```systemverilog
    // 提交后的驱动协议（标准/私有）；预检阶段的候选保存在 pending_protocol。
    virtio_driver_protocol protocol;
    local virtio_driver_protocol pending_protocol;
     ```
     `new()` 中 `        pcie_bind_prepared = 0;` 之后加
     ```systemverilog
        protocol = null;
        pending_protocol = null;
     ```
  2. `prepare_driver_candidates` 整体（含上方两行注释）替换为：
     ```systemverilog
    // 选择本 Function 的驱动协议并由协议创建/校验 ops/FSM 候选；预检不访问设备。
    // private_cfg 是否为空只在这里判断一次，其余标准/私有差异都经协议对象分派。
    protected function bit prepare_driver_candidates(
        string label, virtio_driver_config_t behavior,
        ref virtio_atomic_ops candidate_ops, ref virtio_auto_fsm candidate_fsm
    );
        dpu_priv_driver_protocol private_protocol;

        if (private_cfg != null) begin
            private_protocol = dpu_priv_driver_protocol::type_id::create(
                {label, "_protocol"});
            private_protocol.private_cfg = private_cfg;
            pending_protocol = private_protocol;
        end else begin
            pending_protocol = virtio_standard_driver_protocol::type_id::create(
                {label, "_protocol"});
        end
        return pending_protocol.prepare_candidates(
            label, this, behavior, candidate_ops, candidate_fsm);
    endfunction
     ```
  3. `preflight_bind_pcie` 中：
     ```systemverilog
        if ((private_cfg != null) &&
            !prepare_driver_candidates(function_name, drv_cfg, candidate_ops, candidate_fsm))
            return 0;
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create(
                {function_name, "_fsm"}, this);
        if (candidate_fsm == null) begin
     ```
     改为
     ```systemverilog
        if (!prepare_driver_candidates(function_name, drv_cfg, candidate_ops, candidate_fsm))
            return 0;
        if (candidate_fsm == null) begin
     ```
     且
     ```systemverilog
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create(
                {function_name, "_ops"}, this);
        if (candidate_ops == null) begin
     ```
     改为
     ```systemverilog
        if (candidate_ops == null) begin
     ```
     （若 P2-5 已把调用改成无条件的 `if (!prepare_driver_candidates(...)) return 0;` 且删除了两段 factory 创建，则本子步无改动。）
  4. `cancel_preflight_bind_pcie` 中 `        pcie_bind_prepared = 0;` 之前加 `        pending_protocol = null;`。
  5. `commit_preflight_bind_pcie` 中 `        cancel_preflight_bind_pcie();`（成功路径、`wait_pol = wpol;` 之后那一处）之前加
     `        protocol = pending_protocol;`。
  6. `commit_validated_pcie_components`（或 P2-5 合并后的提交函数）中：
     ```systemverilog
        string why;
        dpu_priv_atomic_ops private_ops;

        if (private_cfg != null) begin
            if (!$cast(private_ops, ops) ||
                !private_ops.configure_private(private_cfg, driver_cfg.num_queue_pairs, why)) begin
                `uvm_error("FUNCTION_BIND", {"无法冻结私有驱动配置: ", why})
                return 0;
            end
        end
     ```
     改为
     ```systemverilog
        string why;

        if (pending_protocol == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s PCIe bind commit has no driver protocol", function_name))
            return 0;
        end
        if (!pending_protocol.bind_ops(ops, driver_cfg, why)) begin
            `uvm_error("FUNCTION_BIND", {"无法冻结私有驱动配置: ", why})
            return 0;
        end
     ```
     同函数中：
     ```systemverilog
            // 私有 Function 的引擎也复用同一个 ops，保证 engine 与 sequence/FSM
            // 不会各自产生一套 DMA tracker 或混入标准 Virtio-net header。
            if (private_cfg != null) begin
                dpu_priv_tx_engine tx_adapter;
                dpu_priv_rx_engine rx_adapter;
                tx_adapter = new({function_name, "_private_tx"});
                rx_adapter = new({function_name, "_private_rx"});
                tx_adapter.private_ops = private_ops;
                rx_adapter.private_ops = private_ops;
                rx_adapter.buf_size = private_cfg.rx_buf_size;
                dataplane.tx_engine = tx_adapter;
                dataplane.rx_engine = rx_adapter;
            end
     ```
     改为
     ```systemverilog
            // 引擎实现由驱动协议决定（私有协议换成委托同一 ops 的适配器）。
            pending_protocol.install_dataplane(dataplane, ops, function_name);
     ```
     同函数中：
     ```systemverilog
                driver_agent_ref.driver.ops = ops;
                driver_agent_ref.driver.fsm = fsm;
     ```
     改为
     ```systemverilog
                driver_agent_ref.driver.ops = ops;
                driver_agent_ref.driver.fsm = fsm;
                driver_agent_ref.driver.protocol = pending_protocol;
     ```
  7. `shutdown` 中 `        if (private_cfg != null) begin` 改为
     `        if ((protocol != null) && protocol.requires_verified_reset()) begin`；
     其上方注释中 `私有后端未确认停 DMA 时保留` 改为 `要求确认停 DMA 的协议（私有环）在后端未确认时保留`。
  8. 证据：`grep -n "private_cfg != null\|dpu_priv_atomic_ops\|dpu_priv_tx_engine\|dpu_priv_rx_engine\|\$cast" virtio_net_vip/src/sriov/virtio_function_instance.sv`
     期望只剩 `prepare_driver_candidates` 中的一行 `if (private_cfg != null) begin`。

- [ ] **Step 9: 私有 FSM 去掉类型转换（`virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv`）。** `do_full_init` 中：
  ```systemverilog
        dpu_priv_atomic_ops private_ops;
        dpu_priv_queue_context_t ctx;
        bit ok;
        if ((state == FSM_RUNNING) || !$cast(private_ops, ops) ||
  ```
  改为
  ```systemverilog
        virtqueue_base first_vq;
        bit ok;
        if ((state == FSM_RUNNING) || (ops == null) || !ops.uses_private_ring() ||
  ```
  且
  ```systemverilog
        if (private_ops.get_queue_context(0, ctx)) drv_cfg.queue_size = ctx.queue_size;
  ```
  改为
  ```systemverilog
        first_vq = ops.vq_mgr.get_queue(0);
        if (first_vq != null) drv_cfg.queue_size = first_vq.queue_size;
  ```
  证据：`grep -rn "\$cast" virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv` 期望为空。

- [ ] **Step 10: 文档。** README 目录树 `│   │   ├── virtio_driver.sv               ← UVM Driver（事务分发）` 之前插入
  `│   │   ├── virtio_driver_protocol.sv       ← 驱动协议（标准 / DPU 私有环）分派`；手册
  `|   |   +-- virtio_driver.sv               -- UVM Driver (事务分发)` 之前插入
  `|   |   +-- virtio_driver_protocol.sv      -- 驱动协议 (标准 / DPU 私有环)`。

- [ ] **Step 11: SYNC 并运行受影响测试（期望 PASS）。** ONE TEST：`virtio_unit_test`、`virtio_dut_caps_test`、`virtio_pf_lifecycle_reset_test`、
  `virtio_e2e_test`、`virtio_monitor_routing_test`、私有环两个测试（若 P0.4 未合入则 `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p3-4'`，
  期望 `flow_rc=0`、`contract_rc=0`、计数全 0）。

- [ ] **Step 12: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 13: 提交。**
  ```bash
  git add virtio_net_vip/src/agent/virtio_driver_protocol.sv virtio_net_vip/src/dpu_priv/dpu_priv_driver_protocol.sv \
          virtio_net_vip/src/virtio_net_pkg.sv virtio_net_vip/src/agent/virtio_driver.sv \
          virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/src/dpu_priv/dpu_priv_auto_fsm.sv \
          virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/dpu_priv/dpu_priv_atomic_ops.sv \
          virtio_net_vip/tests/virtio_unit_test.sv README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 引入 virtio_driver_protocol 取代私有驱动类型判断"
  ```

---

### Task P3-5: `fabric_bar_layout` —— 由 snapshot BAR 租约构造的 BAR 角色布局

**Files:**
- Create: `virtio_net_vip/src/transport/fabric_bar_layout.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（`transport/virtio_bar_accessor.sv` include 之前，HEAD :65）
- Modify: `virtio_net_vip/src/transport/virtio_bar_accessor.sv`：字段 :306-308、`new()` :325-339、`configure_fabric_bar_pairs` :364-435、
  `fabric_bar_layout_is_active` :437-441、`fabric_bar_pair_is_programmable` :447-506、`program_fabric_bar_pairs` :512-551、
  `allow_functional_bar_access` :556-586、`allow_msix_bar_access` :590-598、`enumerate_bars` :879-883
- Modify: `virtio_net_vip/src/transport/virtio_discovery_strategy.sv`（P3-2 的 `capabilities_use_fabric_windows`，即 HEAD transport :871-899 的写死 BAR0/2/4）
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树）
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`；回归中 `virtio_fabric_resource_test` 校验全部既有错误消息

**Interfaces:**
- Consumes: `dpu_bar_pair_lease_t {role, even_bar_id, base, size}`、`dpu_bar_role_e {DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX}`（dpu_resource_pkg）。
- Produces:
  ```systemverilog
  class fabric_bar_layout extends uvm_object;
      localparam int unsigned PAIR_COUNT = 3;
      static function void slot_contract(int unsigned slot, output int unsigned even_bar_id,
                                         output dpu_bar_role_e role);
      static function bit build(dpu_bar_pair_lease_t bars[$], output fabric_bar_layout layout,
                                output string why);
      function int unsigned even_bar_for(dpu_bar_role_e role);
      function bit role_of(int unsigned bar_id, output dpu_bar_role_e role);
      function bit has_role(int unsigned bar_id, dpu_bar_role_e role);
  endclass
  ```
  `virtio_bar_accessor::fabric_layout`（null = 非 Fabric）与 `function fabric_bar_layout get_fabric_layout();`。
  `fabric_bar_layout_is_active()` 签名保持（`virtio_fabric_resource_test` 使用）。

**Spec deviation:** BAR 角色约定（BAR0=device-memory、BAR2=mailbox、BAR4=MSI-X）是 DUT profile 契约，`virtio_fabric_resource_test`
断言非约定租约被拒绝（"invalid role ... expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X"）。因此契约表保留，但只存在于
`fabric_bar_layout::slot_contract` 一处；bar accessor 与发现策略改为查询布局对象，不再写死 BAR 号。
`allow_functional_bar_access` 中"BAR0/BAR2 角色不兼容"分支在布局通过校验后不可达（HEAD 亦然），删除。

- [ ] **Step 1: 写失败测试。** `virtio_net_vip/tests/virtio_unit_test.sv` 的 `run_phase` 中 `test_driver_protocol_selection();` 之后加
  `        test_fabric_bar_layout_roles();`，类末尾加入：
  ```systemverilog

    // BAR 角色只由 snapshot 租约构造的布局对象回答；非法租约给出与 bar accessor
    // 相同的上下文消息且不产生布局。
    task test_fabric_bar_layout_roles();
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t lease;
        fabric_bar_layout layout;
        dpu_bar_role_e role;
        string why;

        lease.role = DPU_BAR_MAILBOX;
        lease.even_bar_id = 2;
        lease.base = 64'h0001_0000_2000_0000;
        lease.size = 64'h0000_0000_0001_0000;
        bars.push_back(lease);
        lease.role = DPU_BAR_MSIX;
        lease.even_bar_id = 4;
        lease.base = 64'h0001_0000_3000_0000;
        lease.size = 64'h0000_0000_0001_0000;
        bars.push_back(lease);
        lease.role = DPU_BAR_DEVICE_MEMORY;
        lease.even_bar_id = 0;
        lease.base = 64'h0001_0000_1000_0000;
        lease.size = 64'h0000_0000_0010_0000;
        bars.push_back(lease);
        if (!fabric_bar_layout::build(bars, layout, why) || (layout == null) ||
            (layout.even_bar_for(DPU_BAR_DEVICE_MEMORY) != 0) ||
            (layout.even_bar_for(DPU_BAR_MAILBOX) != 2) ||
            (layout.even_bar_for(DPU_BAR_MSIX) != 4) ||
            !layout.role_of(5, role) || (role != DPU_BAR_MSIX) ||
            !layout.has_role(1, DPU_BAR_DEVICE_MEMORY) ||
            layout.has_role(2, DPU_BAR_MSIX))
            `uvm_error("TEST", {"valid Fabric BAR leases produced a wrong layout: ", why})

        bars[0].even_bar_id = 4;
        if (fabric_bar_layout::build(bars, layout, why) || (layout != null) ||
            (why != "Fabric BAR lease 0 has invalid role 1 for even BAR4; expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X"))
            `uvm_error("TEST", {"misplaced mailbox lease was not rejected: ", why})

        bars.delete();
        if (fabric_bar_layout::build(bars, layout, why) ||
            (why != "Fabric BAR lease set must contain exactly three unique pairs; got 0"))
            `uvm_error("TEST", {"empty Fabric BAR lease set was not rejected: ", why})
        `uvm_info("UNIT_TEST", "test_fabric_bar_layout_roles PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，ONE TEST `virtio_unit_test`。期望 `Error-[` 编译错误：`fabric_bar_layout` 未声明。

- [ ] **Step 3: 新建 `virtio_net_vip/src/transport/fabric_bar_layout.sv`：**
  ```systemverilog
`ifndef FABRIC_BAR_LAYOUT_SV
`define FABRIC_BAR_LAYOUT_SV

// ============================================================================
// fabric_bar_layout
//
// 目录层次：src/transport；Fabric function 的 BAR 角色布局，由冻结 snapshot 的
// dpu_bar_pair_lease_t 构造且构造后不可变。DUT profile 的角色契约（哪一对偶数 BAR
// 承载 device-memory / mailbox / MSI-X）只在 slot_contract 中定义一次；bar accessor
// 的访问守卫与发现策略的 capability 窗口校验都查询本对象，不再写死 BAR 号。
// 本对象不持有 BAR 基址/大小的运行副本（仍由 bar accessor 的 bar_base/bar_size 保存）。
// ============================================================================

class fabric_bar_layout extends uvm_object;
    `uvm_object_utils(fabric_bar_layout)

    // 契约规定的 64-bit BAR 对数；slot 序号即错误信息中的 "pair slot"。
    localparam int unsigned PAIR_COUNT = 3;

    // 按 slot 存放的已校验租约。
    protected dpu_bar_pair_lease_t leases[PAIR_COUNT];

    // 空布局；只能经 build() 得到有效实例。
    function new(string name = "fabric_bar_layout");
        super.new(name);
    endfunction

    // 唯一的 BAR 角色契约表：slot → (偶数 BAR, 角色)。
    static function void slot_contract(int unsigned slot,
                                       output int unsigned even_bar_id,
                                       output dpu_bar_role_e role);
        case (slot)
            0: begin
                even_bar_id = 0;
                role = DPU_BAR_DEVICE_MEMORY;
            end
            1: begin
                even_bar_id = 2;
                role = DPU_BAR_MAILBOX;
            end
            default: begin
                even_bar_id = 4;
                role = DPU_BAR_MSIX;
            end
        endcase
    endfunction

    // 校验整组租约：恰好三对、每对符合契约、无重复、无缺失。全部通过才返回新布局；
    // 失败时 layout=null，why 为带上下文的诊断（文本与 HEAD 的 bar accessor 一致）。
    static function bit build(dpu_bar_pair_lease_t bars[$],
                              output fabric_bar_layout layout,
                              output string why);
        bit lease_seen[PAIR_COUNT];
        fabric_bar_layout candidate;

        layout = null;
        why = "";
        if (bars.size() != PAIR_COUNT) begin
            why = $sformatf(
                "Fabric BAR lease set must contain exactly three unique pairs; got %0d",
                bars.size());
            return 0;
        end
        candidate = new("fabric_bar_layout");
        foreach (bars[index]) begin
            int found_slot;

            found_slot = -1;
            for (int unsigned slot = 0; slot < PAIR_COUNT; slot++) begin
                int unsigned even_bar_id;
                dpu_bar_role_e role;

                slot_contract(slot, even_bar_id, role);
                if ((bars[index].even_bar_id == even_bar_id) &&
                    (bars[index].role == role))
                    found_slot = slot;
            end
            if (found_slot < 0) begin
                why = $sformatf(
                    "Fabric BAR lease %0d has invalid role %0d for even BAR%0d; expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X",
                    index, bars[index].role, bars[index].even_bar_id);
                return 0;
            end
            if (lease_seen[found_slot]) begin
                why = $sformatf(
                    "Fabric BAR lease %0d duplicates the required BAR%0d role %0d pair",
                    index, bars[index].even_bar_id, bars[index].role);
                return 0;
            end
            lease_seen[found_slot] = 1;
            candidate.leases[found_slot] = bars[index];
        end
        for (int unsigned lease_slot = 0; lease_slot < PAIR_COUNT; lease_slot++) begin
            if (!lease_seen[lease_slot]) begin
                why = $sformatf(
                    "Fabric BAR lease set is missing required pair slot %0d",
                    lease_slot);
                return 0;
            end
        end
        layout = candidate;
        return 1;
    endfunction

    // 承载指定角色的偶数 BAR 号；build 已保证三种角色齐全，找不到时返回不存在的 6。
    function int unsigned even_bar_for(dpu_bar_role_e role);
        foreach (leases[slot]) begin
            if (leases[slot].role == role)
                return leases[slot].even_bar_id;
        end
        return 6;
    endfunction

    // 查询任一 BAR（含 64-bit 对的高半部分）所属角色；不属于任何租约时返回 0。
    function bit role_of(int unsigned bar_id, output dpu_bar_role_e role);
        role = DPU_BAR_DEVICE_MEMORY;
        foreach (leases[slot]) begin
            if ((bar_id == leases[slot].even_bar_id) ||
                (bar_id == leases[slot].even_bar_id + 1)) begin
                role = leases[slot].role;
                return 1;
            end
        end
        return 0;
    endfunction

    // bar_id 是否属于指定角色的租约。
    function bit has_role(int unsigned bar_id, dpu_bar_role_e role);
        dpu_bar_role_e actual;

        return role_of(bar_id, actual) && (actual == role);
    endfunction
endclass

`endif // FABRIC_BAR_LAYOUT_SV
  ```

- [ ] **Step 4: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv`：
  ```systemverilog
  typedef class virtio_tlm_completion_adapter;
  `include "transport/virtio_bar_accessor.sv"
  ```
  改为
  ```systemverilog
  typedef class virtio_tlm_completion_adapter;
  `include "transport/fabric_bar_layout.sv"
  `include "transport/virtio_bar_accessor.sv"
  ```

- [ ] **Step 5: bar accessor 改查布局（`virtio_net_vip/src/transport/virtio_bar_accessor.sv`）。**
  1. 字段：
     ```systemverilog
    bit         fabric_bar_layout_active;
    bit         fabric_bar_role_valid[6];
    dpu_bar_role_e fabric_bar_role[6];
     ```
     改为
     ```systemverilog
    // Fabric BAR 角色布局（由 snapshot 租约构造）；null 表示非 Fabric function。
    fabric_bar_layout fabric_layout;
     ```
  2. `new()` 中删除 `        fabric_bar_layout_active = 0;` 一行，在 `next_bar_alloc_addr = ...;` 之后加 `        fabric_layout = null;`；
     循环体中删除
     ```systemverilog
            fabric_bar_role_valid[i] = 0;
            fabric_bar_role[i] = DPU_BAR_DEVICE_MEMORY;
     ```
  3. `configure_fabric_bar_pairs` 整体（从 `virtual function void configure_fabric_bar_pairs(` 到其 `endfunction`）替换为：
     ```systemverilog
    virtual function void configure_fabric_bar_pairs(
        input dpu_bar_pair_lease_t bars[$]
    );
        fabric_bar_layout layout;
        string why;

        if (!fabric_bar_layout::build(bars, layout, why)) begin
            `uvm_error("BAR_ACCESSOR", why)
            return;
        end

        // Do not mutate an existing Fabric layout until the entire input set
        // has validated.  A malformed retry must not leave a partial layout
        // that can later be programmed into PCI config space.
        fabric_layout = layout;
        for (int unsigned bar_id = 0; bar_id < 6; bar_id++) begin
            bar_base[bar_id] = '0;
            bar_size[bar_id] = '0;
            bar_type[bar_id] = '0;
        end
        foreach (bars[index]) begin
            bar_base[bars[index].even_bar_id] = bars[index].base;
            bar_size[bars[index].even_bar_id] = bars[index].size;
            bar_type[bars[index].even_bar_id] = 3'b100;
        end
    endfunction
     ```
  4. `fabric_bar_layout_is_active` 函数体改为 `        return (fabric_layout != null);`，并在其 `endfunction` 后插入：
     ```systemverilog

    // 返回当前 Fabric BAR 布局（非 Fabric 时为 null），供发现策略校验 capability 窗口。
    function fabric_bar_layout get_fabric_layout();
        return fabric_layout;
    endfunction
     ```
  5. `fabric_bar_pair_is_programmable`：声明区 `bit [63:0] pair_size;` 之后加
     ```systemverilog
        dpu_bar_role_e low_role;
        dpu_bar_role_e high_role;
     ```
     并把
     ```systemverilog
        if (!fabric_bar_role_valid[even_bar_id] ||
            !fabric_bar_role_valid[even_bar_id + 1]) begin
     ```
     改为
     ```systemverilog
        if ((fabric_layout == null) ||
            !fabric_layout.role_of(even_bar_id, low_role) ||
            !fabric_layout.role_of(even_bar_id + 1, high_role)) begin
     ```
     把
     ```systemverilog
        if ((fabric_bar_role[even_bar_id] != expected_role) ||
            (fabric_bar_role[even_bar_id + 1] != expected_role)) begin
     ```
     改为
     ```systemverilog
        if ((low_role != expected_role) || (high_role != expected_role)) begin
     ```
  6. `program_fabric_bar_pairs` 中 `        if (!fabric_bar_layout_active) begin` 改为 `        if (fabric_layout == null) begin`，且
     ```systemverilog
        if (!fabric_bar_pair_is_programmable(
            0, DPU_BAR_DEVICE_MEMORY, why
        ) || !fabric_bar_pair_is_programmable(
            2, DPU_BAR_MAILBOX, why
        ) || !fabric_bar_pair_is_programmable(
            4, DPU_BAR_MSIX, why
        )) begin
     ```
     改为
     ```systemverilog
        if (!fabric_bar_pair_is_programmable(
            fabric_layout.even_bar_for(DPU_BAR_DEVICE_MEMORY),
            DPU_BAR_DEVICE_MEMORY, why
        ) || !fabric_bar_pair_is_programmable(
            fabric_layout.even_bar_for(DPU_BAR_MAILBOX), DPU_BAR_MAILBOX, why
        ) || !fabric_bar_pair_is_programmable(
            fabric_layout.even_bar_for(DPU_BAR_MSIX), DPU_BAR_MSIX, why
        )) begin
     ```
  7. `allow_functional_bar_access` 整体（含上方三行中文注释）替换为：
     ```systemverilog
    // Fabric 访问守卫：非 Fabric 模式一律放行；Fabric 模式下功能 MMIO 只允许
    // 布局中 device-memory 或 mailbox 角色的偶数基址，MSI-X BAR 与奇数 BAR 一律
    // 拒绝。拒绝路径带 uvm_error 副作用，调用方按返回值放弃访问。
    protected function bit allow_functional_bar_access(input int unsigned bar_id);
        int unsigned msix_bar;
        int unsigned device_bar;
        int unsigned mailbox_bar;

        if (fabric_layout == null)
            return 1;
        if ((bar_id > 5) || ((bar_id % 2) != 0)) begin
            `uvm_error("BAR_FUNCTION_WINDOW", $sformatf(
                "functional MMIO access must use an even Fabric BAR base, not BAR%0d",
                bar_id))
            return 0;
        end
        msix_bar = fabric_layout.even_bar_for(DPU_BAR_MSIX);
        if (bar_id == msix_bar) begin
            `uvm_error("BAR_MSIX_ONLY", $sformatf(
                "functional MMIO access to MSI-X-only BAR%0d was blocked", bar_id))
            return 0;
        end
        device_bar = fabric_layout.even_bar_for(DPU_BAR_DEVICE_MEMORY);
        mailbox_bar = fabric_layout.even_bar_for(DPU_BAR_MAILBOX);
        if ((bar_id == device_bar) || (bar_id == mailbox_bar))
            return 1;
        `uvm_error("BAR_FUNCTION_WINDOW", $sformatf(
            "functional MMIO access must use Fabric BAR%0d/%0d or BAR%0d/%0d, not BAR%0d",
            device_bar, device_bar + 1, mailbox_bar, mailbox_bar + 1, bar_id))
        return 0;
    endfunction
     ```
  8. `allow_msix_bar_access` 整体（含上方两行注释）替换为：
     ```systemverilog
    // MSI-X 访问守卫：与上面对偶——Fabric 模式下 MSI-X 表访问只允许布局中
    // MSI-X 角色的偶数 BAR，其余拒绝并报错；非 Fabric 模式放行。
    protected function bit allow_msix_bar_access(input int unsigned bar_id);
        int unsigned msix_bar;

        if (fabric_layout == null)
            return 1;
        msix_bar = fabric_layout.even_bar_for(DPU_BAR_MSIX);
        if (bar_id == msix_bar)
            return 1;
        `uvm_error("BAR_MSIX_ONLY", $sformatf(
            "MSI-X access must use Fabric BAR%0d/%0d, not BAR%0d",
            msix_bar, msix_bar + 1, bar_id))
        return 0;
    endfunction
     ```
  9. `enumerate_bars` 中 `        if (fabric_bar_layout_active) begin` 改为 `        if (fabric_layout != null) begin`。
  10. 证据：`grep -rn "fabric_bar_role\|fabric_bar_layout_active" virtio_net_vip examples` 期望为空。

- [ ] **Step 6: 发现策略改查布局（`virtio_net_vip/src/transport/virtio_discovery_strategy.sv`）。** `capabilities_use_fabric_windows` 整体替换为：
  ```systemverilog
    // Fabric 专用校验(无副作用)：确认发现到的 virtio 能力落在 BAR 布局约定的
    // 角色窗口内——common/ISR/device/pci cfg 在 device-memory BAR、notify 在
    // mailbox BAR、MSI-X 在 MSI-X BAR；任何偏离都拒绝并经 why 说明原因，
    // 防止把错误的 BAR 角色布局当成合法 DUT profile。
    protected function bit capabilities_use_fabric_windows(
        virtio_pci_transport transport,
        output string why
    );
        fabric_bar_layout layout;
        int unsigned device_bar;
        int unsigned mailbox_bar;
        int unsigned msix_bar;

        why = "";
        layout = transport.bar.get_fabric_layout();
        device_bar = layout.even_bar_for(DPU_BAR_DEVICE_MEMORY);
        mailbox_bar = layout.even_bar_for(DPU_BAR_MAILBOX);
        msix_bar = layout.even_bar_for(DPU_BAR_MSIX);
        if (!transport.cap_mgr.common_cfg_found || !transport.cap_mgr.notify_found ||
            !transport.cap_mgr.isr_found) begin
            why = "mandatory virtio capabilities were not discovered";
            return 0;
        end
        // The Fabric profile has a split functional layout: the device-memory
        // pair carries common/ISR/device configuration, while the mailbox pair
        // owns the virtio notification capability.  Do not force notify into
        // the device-memory BAR; doing so rejects the real-DUT profile even
        // though the discovered BAR role and notify address are correct.
        if ((transport.cap_mgr.common_cfg_cap.bar != device_bar) ||
            (transport.cap_mgr.notify_cap.bar != mailbox_bar) ||
            (transport.cap_mgr.isr_cap.bar != device_bar) ||
            (transport.cap_mgr.device_cfg_found &&
             (transport.cap_mgr.device_cfg_cap.bar != device_bar)) ||
            (transport.cap_mgr.pci_cfg_found &&
             (transport.cap_mgr.pci_cfg_cap.bar != device_bar))) begin
            why = $sformatf(
                "virtio functional capability did not resolve to Fabric BAR%0d/%0d",
                device_bar, device_bar + 1);
            return 0;
        end
        if (transport.cap_mgr.msix_found &&
            (transport.cap_mgr.msix_table_bir != msix_bar)) begin
            why = $sformatf("MSI-X capability did not resolve to Fabric BAR%0d/%0d",
                            msix_bar, msix_bar + 1);
            return 0;
        end
        return 1;
    endfunction
  ```
  （调用点已在 `fabric_bar_layout_is_active()` 检查之后，`layout` 非空。）证据：
  `grep -nE "\.bar != [0-9]|bir != [0-9]" virtio_net_vip/src/transport/*.sv` 期望为空。

- [ ] **Step 7: 文档。** README 目录树 `│   │   ├── virtio_bar_accessor.sv          ← BAR 读写 → PCIe TLP 翻译` 之前插入
  `│   │   ├── fabric_bar_layout.sv            ← snapshot BAR 租约 → BAR 角色布局`；手册
  `|   |   +-- virtio_bar_accessor.sv          -- BAR MMIO/Config -> PCIe TLP 翻译` 之前插入
  `|   |   +-- fabric_bar_layout.sv            -- snapshot BAR 租约 -> BAR 角色布局`。

- [ ] **Step 8: SYNC 并运行受影响测试（期望 PASS）。** ONE TEST：`virtio_unit_test`、`virtio_fabric_resource_test`（覆盖全部租约/编程/
  访问守卫消息）、`virtio_dut_caps_test`、`virtio_real_driver_flow_test`、`virtio_e2e_test`。

- [ ] **Step 9: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 10: 提交。**
  ```bash
  git add virtio_net_vip/src/transport/fabric_bar_layout.sv virtio_net_vip/src/virtio_net_pkg.sv \
          virtio_net_vip/src/transport/virtio_bar_accessor.sv virtio_net_vip/src/transport/virtio_discovery_strategy.sv \
          virtio_net_vip/tests/virtio_unit_test.sv README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 引入 fabric_bar_layout 消除写死的 BAR 角色"
  ```

---

### Task P3-6: `virtio_migration_engine` —— 迁移计算与恢复步骤移出 `virtio_auto_fsm`

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_migration_engine.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`（`agent/virtio_atomic_ops.sv` 与 `agent/virtio_auto_fsm.sv` 之间，HEAD :82-83）
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`：删除 `MIGRATION_PAGE_SIZE`/`migration_record_group_t`（HEAD :28-29）；字段区与 `new()`（:54-76）；
  删除迁移辅助函数块 HEAD :144-706（`migration_page_checksum` … `build_dirty_fallback_payload`，含 `rollback_migration_restore`），
  代之以 `migration_snapshot_checksum` 包装；`freeze_for_migration` HEAD :1182-1325 与 `do_restore_from_migration` HEAD :1352-1789 改为委托
- Test: 无新测试——`virtio_migration_dirty_test`（24 个迁移用例，含全部错误消息捕获器）为行为基准；另跑 `virtio_dut_caps_test`、私有环测试

**Interfaces:**
- Consumes: `virtio_atomic_ops`（`device_reset_verified/set_acknowledge/set_driver/negotiate_features/set_features_ok/set_failed/setup_all_queues/
  snapshot_normal_dma_ownership/materialize_migration_mapping/restore_normal_dma_ownership/validate_restored_queue_ownership/claim_restored_queue_ownership`、
  `iommu/mem/transport/vq_mgr/negotiated_features`）、快照类型（`virtio_device_snapshot_t`、`virtio_dirty_page_snapshot_t`、`virtio_mapping_snapshot_t`、
  `virtio_normal_dma_snapshot_t`、`iommu_mapping_t`、`virtqueue_snapshot_t`）。
- Produces（`virtio_migration_engine`，诊断 ID 仍为 `"AUTO_FSM"`）：
  ```systemverilog
  typedef virtio_dirty_page_snapshot_t migration_record_group_t[$];
  function bit [63:0] migration_page_checksum(byte page_data[]);
  function bit [63:0] migration_snapshot_checksum(virtio_device_snapshot_t snap);
  function bit migration_mapping_page_span(bit [63:0] page_id, iommu_mapping_t mapping,
                                           ref bit [63:0] span_gpa, ref int unsigned span_size);
  task rollback(virtio_atomic_ops ops);
  task capture_snapshot(virtio_atomic_ops ops, int unsigned host_id, int unsigned num_pairs,
                        int unsigned num_queues, output bit ok, ref virtio_device_snapshot_t snap);
  function bit validate_restore_snapshot(virtio_atomic_ops ops, int unsigned host_id,
      int unsigned configured_queue_size, virtio_device_snapshot_t snap,
      output bit set_failed_required);
  function void collect_dirty_fallback_groups(virtio_device_snapshot_t snap,
                                              output migration_record_group_t mapping_groups[$]);
  task restore_device_and_dma(virtio_atomic_ops ops, virtio_device_snapshot_t snap,
                              migration_record_group_t mapping_groups[$], output bit ok);
  task restore_queues(virtio_atomic_ops ops, virtio_device_snapshot_t snap,
                      virtio_driver_config_t cfg, output bit ok);
  ```
  FSM 保留的公共/受保护 API（测试与派生类依赖，签名不变）：`freeze_for_migration(ref snap)`（`virtio_migration_dirty_test.sv:385` 覆写、
  `dpu_priv_auto_fsm` 覆写、`virtio_driver` VIO_TXN_FREEZE）；`restore_from_migration(snap, output ok)`（`virtio_driver` VIO_TXN_RESTORE、
  `virtio_dut_caps_test.sv:426` 覆写）；`protected virtual do_restore_from_migration(snap, output ok)`（`virtio_migration_dirty_test.sv:356` 调用、
  `virtio_dut_caps_test.sv:442` 与 `dpu_priv_auto_fsm` 覆写）；`protected migration_snapshot_checksum(snap)`（`virtio_migration_dirty_test.sv:349,427`）；
  `protected active_num_pairs/num_total_queues`（`virtio_migration_dirty_test.sv` `configure_snapshot_queue_count`）；
  `virtual stop_dataplane/start_dataplane`（迁移测试 FSM 覆写，仍由 FSM 调用）。

**说明：** 引擎方法体由 HEAD 代码机械移动得到，变换只有：(1) 去掉 `state = FSM_ERROR;`（失败后由 FSM 统一置 ERROR；状态赋值与 `uvm_error`
的先后对报告捕获器不可见）；(2) `iommu_host_id()` → 参数 `host_id`，`drv_cfg.queue_size/vq_type` → 参数；(3) 校验段的 `ops.set_failed(); return;`
→ `set_failed_required = 1; return 0;`，由 FSM 在返回后调用 `ops.set_failed()`（调用顺序与 HEAD 相同：先报错后写 FAILED）；
(4) `rollback_migration_restore()` → `rollback(ops)`。所有 `uvm_error` 的 ID 与文本逐字不变。

- [ ] **Step 1: 记录基线。** SYNC 后 ONE TEST `virtio_migration_dirty_test`，保存 `logs/virtio_migration_dirty_test.log` 中
  `grep -c "PASSED" ` 结果与 `Migration dirty-page tests PASSED` 一行，作为移动后的比对基准（期望 0 个 ERROR/FATAL）。

- [ ] **Step 2: 新建 `virtio_net_vip/src/agent/virtio_migration_engine.sv`，内容如下（完整文件）：**
  ```systemverilog
`ifndef VIRTIO_MIGRATION_ENGINE_SV
`define VIRTIO_MIGRATION_ENGINE_SV

// ============================================================================
// virtio_migration_engine
//
// 目录层次：src/agent；承担 virtio_auto_fsm 的热迁移计算与恢复步骤：快照校验和、
// freeze 时的 DMA/脏页采集、restore 前的完整性校验，以及复位后的映射/队列重建。
// 依赖 virtio_atomic_ops（借用，调用方传入）、IOMMU/Host memory 与快照类型。
// 引擎不持有 FSM 状态：状态迁移、数据面启停仍由 FSM 负责；失败时引擎只报告并
// 返回 ok=0，由 FSM 置 FSM_ERROR。诊断沿用 "AUTO_FSM" ID 与原消息文本，
// 既有测试的 report catcher 不需要修改。
// ============================================================================

class virtio_migration_engine extends uvm_object;
    `uvm_object_utils(virtio_migration_engine)

    localparam int unsigned MIGRATION_PAGE_SIZE = 4096;
    typedef virtio_dirty_page_snapshot_t migration_record_group_t[$];

    // 无状态对象：构造不访问任何设备或 Host memory。
    function new(string name = "virtio_migration_engine");
        super.new(name);
    endfunction

    // The checksum is calculated over one migration-owned mapping span.  It
    // is used only for migration integrity validation, not as a cryptographic
    // primitive.
    function bit [63:0] migration_page_checksum(byte page_data[]);
        bit [63:0] checksum;

        checksum = 64'hcbf2_9ce4_8422_2325;
        foreach (page_data[i]) begin
            checksum = (checksum ^ {56'h0, page_data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // FNV-1a 累积步进：把一个 64-bit 字按小端字节序逐字节混入校验和。
    // 输入当前校验和与数据字，返回更新后的校验和（纯函数，无副作用）。
    protected function bit [63:0] migration_checksum_word(
        bit [63:0] checksum, bit [63:0] value
    );
        for (int unsigned byte_index = 0; byte_index < 8; byte_index++) begin
            checksum = (checksum ^ {56'h0, value[byte_index * 8 +: 8]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // FNV-1a 累积步进：把 byte 动态数组逐字节混入校验和并返回新值。
    protected function bit [63:0] migration_checksum_bytes(
        bit [63:0] checksum, byte data[]
    );
        foreach (data[i]) begin
            checksum = (checksum ^ {56'h0, data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // 同 migration_checksum_bytes，但输入为 byte unsigned 数组——SV 中
    // 两种元素类型不能隐式互换，故需要单独重载而非复用。
    protected function bit [63:0] migration_checksum_unsigned_bytes(
        bit [63:0] checksum, byte unsigned data[]
    );
        foreach (data[i]) begin
            checksum = (checksum ^ {56'h0, data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // Bind every field consumed by restore into one snapshot checksum.  Dirty
    // payloads also retain their per-record checksums so corruption can be
    // diagnosed precisely; this wider checksum catches metadata and queue
    // bytes before queue/device state is reconstructed.
    function bit [63:0] migration_snapshot_checksum(
        virtio_device_snapshot_t snap
    );
        bit [63:0] checksum;

        checksum = 64'hcbf2_9ce4_8422_2325;
        checksum = migration_checksum_word(checksum, 64'h5649_5254_4d49_4731);
        checksum = migration_checksum_word(checksum, snap.negotiated_features);
        checksum = migration_checksum_word(checksum, {56'h0, snap.device_status});
        checksum = migration_checksum_word(checksum, snap.net_config.mac);
        checksum = migration_checksum_word(checksum, {48'h0, snap.net_config.status});
        checksum = migration_checksum_word(checksum,
            {48'h0, snap.net_config.max_virtqueue_pairs});
        checksum = migration_checksum_word(checksum, {48'h0, snap.net_config.mtu});
        checksum = migration_checksum_word(checksum, {32'h0, snap.net_config.speed});
        checksum = migration_checksum_word(checksum, {56'h0, snap.net_config.duplex});
        checksum = migration_checksum_word(checksum,
            {56'h0, snap.net_config.rss_max_key_size});
        checksum = migration_checksum_word(checksum,
            {48'h0, snap.net_config.rss_max_indirection_table_length});
        checksum = migration_checksum_word(checksum,
            {32'h0, snap.net_config.supported_hash_types});
        checksum = migration_checksum_word(checksum, {32'h0, snap.num_queue_pairs});
        checksum = migration_checksum_word(checksum, {32'h0, snap.queue_count});
        checksum = migration_checksum_word(checksum, snap.dirty_generation);

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.queue_snapshots.size()});
        foreach (snap.queue_snapshots[q]) begin
            virtqueue_snapshot_t queue_snapshot;

            queue_snapshot = snap.queue_snapshots[q];
            checksum = migration_checksum_word(checksum, {32'h0, queue_snapshot.queue_id});
            checksum = migration_checksum_word(checksum, {32'h0, queue_snapshot.queue_size});
            checksum = migration_checksum_word(checksum, queue_snapshot.desc_addr);
            checksum = migration_checksum_word(checksum, queue_snapshot.driver_addr);
            checksum = migration_checksum_word(checksum, queue_snapshot.device_addr);
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.last_avail_idx});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.last_used_idx});
            checksum = migration_checksum_word(checksum,
                {63'h0, queue_snapshot.avail_wrap});
            checksum = migration_checksum_word(checksum,
                {63'h0, queue_snapshot.used_wrap});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.ring_data.size()});
            checksum = migration_checksum_unsigned_bytes(checksum,
                                                         queue_snapshot.ring_data);
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.pending_tokens.size()});
            foreach (queue_snapshot.pending_tokens[t]) begin
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_snapshot.pending_tokens[t].head_id});
                checksum = migration_checksum_word(checksum,
                    (queue_snapshot.pending_tokens[t].token == null) ? 0 : 1);
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.indirect_tables.size()});
            foreach (queue_snapshot.indirect_tables[t]) begin
                virtqueue_indirect_snapshot_t indirect_snapshot;

                indirect_snapshot = queue_snapshot.indirect_tables[t];
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.head_id});
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.mapping.host_id});
                checksum = migration_checksum_word(checksum,
                    {48'h0, indirect_snapshot.mapping.bdf});
                checksum = migration_checksum_word(checksum,
                    indirect_snapshot.mapping.gpa);
                checksum = migration_checksum_word(checksum,
                    indirect_snapshot.mapping.iova);
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.mapping.size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, int'(indirect_snapshot.mapping.dir)});
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.byte_size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.entry_count});
                checksum = migration_checksum_word(checksum,
                    (indirect_snapshot.token == null) ? 0 : 1);
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.queue_dma_mappings.size()});
            foreach (queue_snapshot.queue_dma_mappings[m]) begin
                iommu_mapping_t queue_dma_mapping;

                queue_dma_mapping = queue_snapshot.queue_dma_mappings[m];
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_dma_mapping.host_id});
                checksum = migration_checksum_word(checksum,
                    {48'h0, queue_dma_mapping.bdf});
                checksum = migration_checksum_word(checksum,
                    queue_dma_mapping.gpa);
                checksum = migration_checksum_word(checksum,
                    queue_dma_mapping.iova);
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_dma_mapping.size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, int'(queue_dma_mapping.dir)});
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_dma_mapping.desc_id});
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.split_free_head});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.split_num_free});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.packed_free_ids.size()});
            foreach (queue_snapshot.packed_free_ids[i])
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_snapshot.packed_free_ids[i]});
        end

        checksum = migration_checksum_word(checksum, {32'h0, snap.dirty_pages.size()});
        foreach (snap.dirty_pages[p])
            checksum = migration_checksum_word(checksum, snap.dirty_pages[p]);

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.dirty_page_records.size()});
        foreach (snap.dirty_page_records[r]) begin
            virtio_dirty_page_snapshot_t record;

            record = snap.dirty_page_records[r];
            checksum = migration_checksum_word(checksum, record.page_id);
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.desc_id});
            checksum = migration_checksum_word(checksum, record.mapped_gpa);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapped_size});
            checksum = migration_checksum_word(checksum, record.checksum);
            checksum = migration_checksum_word(checksum,
                {32'h0, record.payload.size()});
            checksum = migration_checksum_bytes(checksum, record.payload);
        end

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.mapping_records.size()});
        foreach (snap.mapping_records[r]) begin
            virtio_mapping_snapshot_t record;

            record = snap.mapping_records[r];
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.desc_id});
            checksum = migration_checksum_word(checksum, record.checksum);
            checksum = migration_checksum_word(checksum,
                {32'h0, record.payload.size()});
            checksum = migration_checksum_bytes(checksum, record.payload);
        end
        checksum = migration_checksum_word(checksum,
            {32'h0, snap.normal_dma_records.size()});
        foreach (snap.normal_dma_records[r]) begin
            virtio_normal_dma_snapshot_t record;

            record = snap.normal_dma_records[r];
            checksum = migration_checksum_word(checksum, {32'h0, record.queue_id});
            checksum = migration_checksum_word(checksum, {63'h0, record.is_tx});
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
        end
        return checksum;
    endfunction

    // Return the portion of an IOMMU mapping that belongs to one 4 KiB dirty
    // page.  The host-memory allocation need only cover this span; the rest
    // of the page is not implicitly owned by the mapping being validated.
    function bit migration_mapping_page_span(
        bit [63:0] page_id,
        iommu_mapping_t mapping,
        ref bit [63:0] span_gpa,
        ref int unsigned span_size
    );
        bit [63:0] page_base;
        bit [63:0] page_end;
        bit [63:0] mapping_end;
        bit [63:0] span_end;

        page_base = page_id << 12;
        page_end = page_base + MIGRATION_PAGE_SIZE;
        mapping_end = mapping.gpa + mapping.size;
        span_gpa = (mapping.gpa > page_base) ? mapping.gpa : page_base;
        span_end = (mapping_end < page_end) ? mapping_end : page_end;
        span_size = 0;
        if (span_end <= span_gpa)
            return 0;
        span_size = span_end - span_gpa;
        return 1;
    endfunction

    // Source identity identifies one mapping at freeze.  It includes GPA so
    // separate source allocations cannot be silently coalesced.
    protected function bit same_migration_source_mapping(
        iommu_mapping_t left,
        iommu_mapping_t right
    );
        return (left.host_id == right.host_id) &&
               (left.bdf  == right.bdf)  &&
               (left.gpa  == right.gpa)  &&
               (left.iova == right.iova) &&
               (left.size == right.size) &&
               (left.dir  == right.dir);
    endfunction

    // A restored mapping intentionally receives fresh host memory.  Layout
    // comparison therefore proves the stable DMA view without requiring its
    // new destination GPA to equal the source GPA.
    protected function bit same_restored_migration_layout(
        iommu_mapping_t left,
        iommu_mapping_t right
    );
        return (left.host_id == right.host_id) &&
               (left.bdf  == right.bdf)  &&
               (left.iova == right.iova) &&
               (left.size == right.size) &&
               (left.dir  == right.dir);
    endfunction

    // Normal DMA completion is FIFO- and role-specific.  Validate every
    // ownership record against the saved queue-pair topology before reset
    // materializes any source mapping: RX queues are even, TX queues are odd,
    // and neither data path may target an optional control queue.
    protected function bit validate_normal_dma_restore_records(
        virtio_atomic_ops ops,
        int unsigned host_id,
        virtio_device_snapshot_t snap
    );
        int unsigned control_queue_count;
        int unsigned expected_queue_count;

        // Legacy synthetic snapshots may omit a full queue-pair topology when
        // they do not transfer any normal FIFO ownership.  Once normal DMA is
        // present, though, every FIFO record depends on this exact topology:
        // pairs provide consecutive RX/TX queues and CTRL_VQ, if negotiated,
        // contributes precisely one trailing control queue.
        if (snap.normal_dma_records.size() != 0) begin
            control_queue_count =
                snap.negotiated_features[VIRTIO_NET_F_CTRL_VQ] ? 1 : 0;
            if (snap.num_queue_pairs >
                ((32'hffff_ffff - control_queue_count) / 2)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA queue-pair count %0d overflows queue topology",
                    snap.num_queue_pairs))
                return 0;
            end
            expected_queue_count = (snap.num_queue_pairs << 1) +
                                   control_queue_count;
            if (snap.queue_count != expected_queue_count) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA topology mismatch pairs=%0d ctrl=%0d queues=%0d expected=%0d",
                    snap.num_queue_pairs, control_queue_count,
                    snap.queue_count, expected_queue_count))
                return 0;
            end
        end

        foreach (snap.normal_dma_records[i]) begin
            virtio_normal_dma_snapshot_t record;
            bit expected_is_tx;
            dma_dir_e expected_dir;
            bit found_mapping;

            record = snap.normal_dma_records[i];
            expected_is_tx = ((record.queue_id % 2) != 0);
            expected_dir = expected_is_tx ? DMA_TO_DEVICE : DMA_FROM_DEVICE;
            found_mapping = 0;

            // queue_id / 2 avoids overflowing a malformed num_queue_pairs * 2
            // expression and also excludes the control queue from normal DMA.
            if ((record.queue_id >= snap.queue_count) ||
                (record.queue_id >= snap.queue_snapshots.size()) ||
                ((record.queue_id / 2) >= snap.num_queue_pairs) ||
                (snap.queue_snapshots[record.queue_id].queue_id !=
                 record.queue_id) ||
                (record.is_tx != expected_is_tx) ||
                (record.mapping.host_id != host_id) ||
                (record.mapping.bdf != ops.transport.bdf) ||
                (record.mapping.size == 0) ||
                (record.mapping.dir != expected_dir)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA record %0d has invalid queue/role topology qid=%0d is_tx=%0d",
                    i, record.queue_id, record.is_tx))
                return 0;
            end

            // Every normal ownership record must refer to exactly one complete
            // saved mapping, so later FIFO ownership transfer cannot consume a
            // missing or duplicated temporary migration allocation.
            foreach (snap.mapping_records[m]) begin
                if (same_migration_source_mapping(record.mapping,
                                                  snap.mapping_records[m].mapping)) begin
                    found_mapping = 1;
                    break;
                end
            end
            if (!found_mapping) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA record %0d has no complete mapping IOVA=0x%016h",
                    i, record.mapping.iova))
                return 0;
            end
            foreach (snap.normal_dma_records[j]) begin
                if ((j < i) &&
                    same_migration_source_mapping(record.mapping,
                                                  snap.normal_dma_records[j].mapping)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: duplicate normal DMA ownership IOVA=0x%016h",
                        record.mapping.iova))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // Explicit dma_map_buf() ownership is neither a TX/RX completion FIFO nor
    // an indirect table.  It must nevertheless name one complete source
    // mapping, be unique across all queue ownership classes, and remain
    // queue-local before reset materializes a destination allocation.
    protected function bit validate_queue_dma_restore_records(
        virtio_atomic_ops ops,
        int unsigned host_id,
        virtio_device_snapshot_t snap
    );
        foreach (snap.queue_snapshots[q]) begin
            foreach (snap.queue_snapshots[q].queue_dma_mappings[i]) begin
                iommu_mapping_t mapping;
                bit found_mapping;

                mapping = snap.queue_snapshots[q].queue_dma_mappings[i];
                found_mapping = 0;
                if ((mapping.host_id != host_id) ||
                    (mapping.bdf != ops.transport.bdf) ||
                    (mapping.iova == 0) ||
                    (mapping.size == 0) ||
                    (mapping.desc_id != 0)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: invalid queue DMA IOVA=0x%016h queue_id=%0d",
                        mapping.iova, snap.queue_snapshots[q].queue_id))
                    return 0;
                end
                foreach (snap.mapping_records[m]) begin
                    if (same_migration_source_mapping(
                        mapping, snap.mapping_records[m].mapping)) begin
                        found_mapping = 1;
                        break;
                    end
                end
                if (!found_mapping) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: queue DMA IOVA=0x%016h has no complete mapping",
                        mapping.iova))
                    return 0;
                end
                foreach (snap.queue_snapshots[other_q]) begin
                    foreach (snap.queue_snapshots[other_q].queue_dma_mappings[j]) begin
                        iommu_mapping_t other_mapping;

                        if ((other_q > q) || ((other_q == q) && (j >= i)))
                            continue;
                        other_mapping =
                            snap.queue_snapshots[other_q].queue_dma_mappings[j];
                        if ((mapping.host_id == other_mapping.host_id) &&
                            (mapping.bdf == other_mapping.bdf) &&
                            (mapping.iova == other_mapping.iova)) begin
                            `uvm_error("AUTO_FSM", $sformatf(
                                "restore_from_migration: duplicate queue DMA IOVA=0x%016h",
                                mapping.iova))
                            return 0;
                        end
                    end
                end
                foreach (snap.normal_dma_records[n]) begin
                    if ((mapping.host_id == snap.normal_dma_records[n].mapping.host_id) &&
                        (mapping.bdf == snap.normal_dma_records[n].mapping.bdf) &&
                        (mapping.iova == snap.normal_dma_records[n].mapping.iova)) begin
                        `uvm_error("AUTO_FSM", $sformatf(
                            "restore_from_migration: queue DMA overlaps normal ownership IOVA=0x%016h",
                            mapping.iova))
                        return 0;
                    end
                end
                foreach (snap.queue_snapshots[owner_q]) begin
                    foreach (snap.queue_snapshots[owner_q].indirect_tables[t]) begin
                        if ((mapping.host_id ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.host_id) &&
                            (mapping.bdf ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.bdf) &&
                            (mapping.iova ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.iova)) begin
                            `uvm_error("AUTO_FSM", $sformatf(
                                "restore_from_migration: queue DMA overlaps indirect ownership IOVA=0x%016h",
                                mapping.iova))
                            return 0;
                        end
                    end
                end
            end
        end
        return 1;
    endfunction

    // Queue rings have a destination ownership path distinct from ordinary
    // DMA: setup_all_queues() allocates, maps, and programs fresh rings
    // before restore_state() overlays their contents.  Use the saved source
    // addresses, not a destination queue instance, so this predicate applies
    // equally while filtering complete records and dirty fallback groups.
    protected function bit is_source_queue_ring_mapping(
        iommu_mapping_t mapping,
        virtio_device_snapshot_t snap
    );
        foreach (snap.queue_snapshots[q]) begin
            if (((snap.queue_snapshots[q].desc_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].desc_addr)) ||
                ((snap.queue_snapshots[q].driver_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].driver_addr)) ||
                ((snap.queue_snapshots[q].device_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].device_addr)))
                return 1;
        end
        return 0;
    endfunction

    // Dirty records are a loss-safe fallback for mappings that completed and
    // retired during the drain.  They contain only the mapping/page spans
    // captured at completed-write boundaries, so all other bytes remain zero.
    protected function bit build_dirty_fallback_payload(
        migration_record_group_t source_records,
        ref iommu_mapping_t source_mapping,
        ref byte source_payload[]
    );
        source_mapping = '{default: 0};
        source_payload.delete();
        if (source_records.size() == 0) begin
            `uvm_error("AUTO_FSM",
                "build_dirty_fallback_payload: no dirty records supplied")
            return 0;
        end
        source_mapping = source_records[0].mapping;
        if (source_mapping.size == 0) begin
            `uvm_error("AUTO_FSM",
                "build_dirty_fallback_payload: zero-size source mapping")
            return 0;
        end
        source_payload = new[source_mapping.size];
        foreach (source_payload[i])
            source_payload[i] = 0;
        foreach (source_records[i]) begin
            bit [63:0] span_offset;

            if (!same_migration_source_mapping(source_records[i].mapping,
                                               source_mapping) ||
                (source_records[i].mapped_size == 0) ||
                (source_records[i].payload.size() !=
                 source_records[i].mapped_size) ||
                (source_records[i].mapped_gpa < source_mapping.gpa)) begin
                `uvm_error("AUTO_FSM",
                    "build_dirty_fallback_payload: inconsistent source record")
                return 0;
            end
            span_offset = source_records[i].mapped_gpa - source_mapping.gpa;
            if ((span_offset >= source_mapping.size) ||
                (source_records[i].mapped_size >
                 (source_mapping.size - span_offset))) begin
                `uvm_error("AUTO_FSM",
                    "build_dirty_fallback_payload: source span exceeds mapping")
                return 0;
            end
            for (int unsigned byte_index = 0;
                 byte_index < source_records[i].mapped_size; byte_index++) begin
                source_payload[span_offset + byte_index] =
                    source_records[i].payload[byte_index];
            end
        end
        return 1;
    endfunction

    // Any failure after the restore reset has acknowledged must immediately
    // return all queue rings, normal FIFO records, and still-temporary
    // migration mappings to verified-reset ownership.  Releasing only the
    // temporary migration list is insufficient once a normal DMA record or
    // indirect table has been claimed by a queue FIFO.
    task rollback(virtio_atomic_ops ops);
        bit reset_complete;

        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: rollback verified device reset did not complete")
        end
    endtask

    // freeze 的采集段：调用方已开启脏页 generation 并停止数据面。输入当前队列对数
    // 与队列总数，输出完整快照与校验和；任一采集失败报告 AUTO_FSM 错误并 ok=0，
    // 快照内容此时不可用于恢复。
    task capture_snapshot(
        virtio_atomic_ops ops,
        int unsigned host_id,
        int unsigned num_pairs,
        int unsigned num_queues,
        output bit ok,
        ref virtio_device_snapshot_t snap
    );
        ok = 0;
        // 3. Save negotiated features and device status
        snap.negotiated_features = ops.negotiated_features;
        begin
            bit [7:0] dev_status;
            ops.transport.read_device_status(dev_status);
            snap.device_status = dev_status;
        end

        // 4. Read device config
        ops.transport.read_net_config(snap.net_config);

        // 5. Save all queue states
        snap.num_queue_pairs = num_pairs;
        snap.queue_count = num_queues;
        snap.queue_snapshots = new[num_queues];

        for (int unsigned q = 0; q < num_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            if (vq != null) begin
                virtqueue_snapshot_t tmp_snap;
                vq.save_state(tmp_snap);
                snap.queue_snapshots[q] = tmp_snap;
            end
        end
        if (!ops.snapshot_normal_dma_ownership(snap.normal_dma_records)) begin
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: unable to capture normal DMA ownership")
            return;
        end

        // 6. Atomically capture this generation.  Each completed device write
        // already saved its exact post-write mapping span in the IOMMU before
        // normal completion could unmap/free its backing allocation.
        ops.iommu.capture_dirty_generation_for_host(host_id,
                                                    snap.dirty_pages);
        snap.dirty_page_records.delete();
        foreach (snap.dirty_pages[i]) begin
            virtio_dirty_page_snapshot_t records[$];

            ops.iommu.get_dirty_page_records_for_host(
                host_id,
                snap.dirty_pages[i], records);
            if (records.size() == 0) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "freeze_for_migration: dirty page 0x%016h has no generation mapping",
                    snap.dirty_pages[i]))
                return;
            end
            foreach (records[m]) begin
                virtio_dirty_page_snapshot_t record;

                record = records[m];
                if (!migration_mapping_page_span(record.page_id, record.mapping,
                                                 record.mapped_gpa,
                                                 record.mapped_size)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: dirty page 0x%016h has empty mapping span",
                        record.page_id))
                    return;
                end
                if (record.payload.size() != record.mapped_size) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: dirty page 0x%016h has invalid captured payload",
                        record.page_id))
                    return;
                end
                record.checksum = migration_page_checksum(record.payload);
                snap.dirty_page_records.push_back(record);
            end
        end

        // Dirty records protect completed device writes.  Capture the whole
        // payload of every mapping still live after quiesce as well, because
        // queue snapshots can retain clean DMA_TO_DEVICE or indirect IOVAs.
        if (!ops.iommu.snapshot_live_mappings_for_host(
                host_id,
                ops.mem, ops.transport.bdf, snap.mapping_records)) begin
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: unable to capture live mapping payloads")
            return;
        end
        begin
            virtio_mapping_snapshot_t dma_records[$];

            foreach (snap.mapping_records[i]) begin
                virtio_mapping_snapshot_t record;

                record = snap.mapping_records[i];
                if (is_source_queue_ring_mapping(record.mapping, snap))
                    continue;
                if ((record.mapping.size == 0) ||
                    (record.payload.size() != record.mapping.size)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: live mapping IOVA=0x%016h has invalid payload",
                        record.mapping.iova))
                    return;
                end
                record.checksum = migration_page_checksum(record.payload);
                dma_records.push_back(record);
            end
            snap.mapping_records = dma_records;
        end
        snap.integrity_checksum = migration_snapshot_checksum(snap);
        ok = 1;
    endtask

    // restore 的复位前校验：快照校验和、队列拓扑、普通/队列 DMA 所有权、脏页与
    // 完整映射记录逐项核对。返回 0 表示拒绝；set_failed_required=1 时调用方须
    // 向设备写 FAILED（与原 FSM 行为一致：结构性错误写 FAILED，载荷错误不写）。
    function bit validate_restore_snapshot(
        virtio_atomic_ops ops,
        int unsigned host_id,
        int unsigned configured_queue_size,
        virtio_device_snapshot_t snap,
        output bit set_failed_required
    );
        set_failed_required = 0;
        if ((snap.dirty_generation == 0) ||
            (snap.integrity_checksum != migration_snapshot_checksum(snap))) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: snapshot integrity checksum mismatch")
            set_failed_required = 1;
            return 0;
        end
        if (snap.queue_count != snap.queue_snapshots.size()) begin
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue count mismatch saved=%0d snapshots=%0d",
                snap.queue_count, snap.queue_snapshots.size()))
            set_failed_required = 1;
            return 0;
        end
        foreach (snap.queue_snapshots[q]) begin
            if ((snap.queue_snapshots[q].queue_id != q) ||
                (snap.queue_snapshots[q].queue_size == 0) ||
                ((configured_queue_size != 0) &&
                 (snap.queue_snapshots[q].queue_size != configured_queue_size))) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: invalid queue snapshot index=%0d id=%0d size=%0d",
                    q, snap.queue_snapshots[q].queue_id,
                    snap.queue_snapshots[q].queue_size))
                set_failed_required = 1;
                return 0;
            end
        end
        if (!validate_normal_dma_restore_records(ops, host_id, snap)) begin
            set_failed_required = 1;
            return 0;
        end
        if (!validate_queue_dma_restore_records(ops, host_id, snap)) begin
            set_failed_required = 1;
            return 0;
        end
        foreach (snap.dirty_pages[p]) begin
            bit page_has_record;
            page_has_record = 0;
            foreach (snap.dirty_page_records[r]) begin
                if (snap.dirty_page_records[r].page_id == snap.dirty_pages[p]) begin
                    page_has_record = 1;
                    break;
                end
            end
            if (!page_has_record) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has no checksum record",
                    snap.dirty_pages[p]))
                return 0;
            end
        end
        foreach (snap.dirty_page_records[i]) begin
            virtio_dirty_page_snapshot_t record;
            byte page_data[];
            bit [63:0] expected_gpa;
            int unsigned expected_size;
            bit [63:0] checksum;
            bit page_is_listed;
            bit mapping_retired;

            record = snap.dirty_page_records[i];
            if ((record.mapping.host_id != host_id) ||
                (record.mapping.bdf != ops.transport.bdf)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty record belongs to host=%0d BDF=0x%04h, expected host=%0d BDF=0x%04h",
                    record.mapping.host_id, record.mapping.bdf,
                    host_id, ops.transport.bdf))
                return 0;
            end
            page_is_listed = 0;
            foreach (snap.dirty_pages[p]) begin
                if (snap.dirty_pages[p] == record.page_id) begin
                    page_is_listed = 1;
                    break;
                end
            end
            if (!page_is_listed) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page record %0d is not in the saved page set",
                    i))
                return 0;
            end
            if (!migration_mapping_page_span(record.page_id, record.mapping,
                                             expected_gpa, expected_size) ||
                (record.mapped_gpa != expected_gpa) ||
                (record.mapped_size != expected_size)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid mapping span",
                    record.page_id))
                return 0;
            end
            if (record.payload.size() != record.mapped_size) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid snapshot payload size",
                    record.page_id))
                return 0;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h snapshot payload checksum mismatch",
                    record.page_id))
                return 0;
            end
            if (!ops.iommu.verify_dirty_page_mapping(record.page_id,
                                                      record.mapping,
                                                      mapping_retired)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h IOMMU mapping mismatch",
                    record.page_id))
                return 0;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapped_gpa, record.mapped_size, page_data);
                checksum = migration_page_checksum(page_data);
                if (checksum != record.checksum) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: dirty page 0x%016h live backing checksum mismatch",
                        record.page_id))
                    return 0;
                end
            end
        end

        // Complete records are captured only while their source mappings are
        // live.  At restore the mapping may still be live (so compare its
        // backing bytes) or may have retired through the ordinary reset path
        // (so consume only the snapshot-owned payload).
        foreach (snap.mapping_records[i]) begin
            virtio_mapping_snapshot_t record;
            byte live_data[];
            bit [63:0] checksum;
            bit mapping_retired;

            record = snap.mapping_records[i];
            if ((record.mapping.host_id != host_id) ||
                (record.mapping.bdf != ops.transport.bdf) ||
                (record.mapping.size == 0) ||
                (record.payload.size() != record.mapping.size)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h has invalid payload size",
                    record.mapping.iova))
                return 0;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h payload checksum mismatch",
                    record.mapping.iova))
                return 0;
            end
            if (!ops.iommu.verify_mapping_identity(record.mapping,
                                                    mapping_retired)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h IOMMU identity mismatch",
                    record.mapping.iova))
                return 0;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapping.gpa, record.mapping.size,
                                 live_data);
                checksum = migration_page_checksum(live_data);
                if (checksum != record.checksum) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: complete mapping IOVA=0x%016h live backing checksum mismatch",
                        record.mapping.iova))
                    return 0;
                end
            end
            foreach (snap.mapping_records[j]) begin
                if ((j > i) &&
                    (record.mapping.host_id == snap.mapping_records[j].mapping.host_id) &&
                    (record.mapping.bdf == snap.mapping_records[j].mapping.bdf) &&
                    (record.mapping.iova == snap.mapping_records[j].mapping.iova)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: duplicate complete mapping IOVA=0x%016h",
                        record.mapping.iova))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 把没有完整映射记录、且不属于源 ring 的脏页按源映射分组，供复位后用
    // build_dirty_fallback_payload 重建；纯计算，不访问设备。
    function void collect_dirty_fallback_groups(
        virtio_device_snapshot_t snap,
        output migration_record_group_t mapping_groups[$]
    );
        mapping_groups.delete();
        // Group only non-ring dirty spans with no complete live-mapping
        // record.  Ring dirty records remain checksum-validated above, but
        // the queue snapshot overlays their saved bytes on setup-owned
        // destination rings rather than materializing source-ring DMA.
        foreach (snap.dirty_page_records[i]) begin
            int matching_group;
            bit complete_mapping_exists;

            if (is_source_queue_ring_mapping(
                    snap.dirty_page_records[i].mapping, snap))
                continue;
            complete_mapping_exists = 0;
            foreach (snap.mapping_records[r]) begin
                if (same_migration_source_mapping(
                    snap.dirty_page_records[i].mapping,
                    snap.mapping_records[r].mapping)) begin
                    complete_mapping_exists = 1;
                    break;
                end
            end
            if (complete_mapping_exists)
                continue;
            matching_group = -1;
            foreach (mapping_groups[group_index]) begin
                if ((mapping_groups[group_index].size() != 0) &&
                    same_migration_source_mapping(
                        mapping_groups[group_index][0].mapping,
                        snap.dirty_page_records[i].mapping)) begin
                    matching_group = group_index;
                    break;
                end
            end
            if (matching_group >= 0) begin
                mapping_groups[matching_group].push_back(
                    snap.dirty_page_records[i]);
            end else begin
                migration_record_group_t new_group;

                new_group.push_back(snap.dirty_page_records[i]);
                mapping_groups.push_back(new_group);
            end
        end
    endfunction

    // restore 的设备与 DMA 段：验证式复位、恢复原特性字、按固定 IOVA 重建完整映射
    // 和脏页回退映射、恢复普通 DMA 所有权。复位后任一步失败先回滚再报告并写 FAILED。
    task restore_device_and_dma(
        virtio_atomic_ops ops,
        virtio_device_snapshot_t snap,
        migration_record_group_t mapping_groups[$],
        output bit ok
    );
        bit feat_ok;
        bit reset_complete;
        bit [63:0] restored_features;

        ok = 0;
        // 1. Reset and re-initialize transport.  No restored ownership may be
        // materialized unless the device has positively acknowledged reset.
        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: verified device reset did not complete")
            ops.set_failed();
            return;
        end
        ops.set_acknowledge();
        ops.set_driver();

        // 2. Restore the exact negotiated feature word.  A different result
        // changes queue semantics and makes all saved ring state unsafe.
        ops.negotiate_features(snap.negotiated_features, restored_features);
        if (restored_features != snap.negotiated_features) begin
            rollback(ops);
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: negotiated feature mismatch saved=0x%016h restored=0x%016h",
                snap.negotiated_features, restored_features))
            ops.set_failed();
            return;
        end

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            rollback(ops);
            `uvm_error("AUTO_FSM", "restore_from_migration: feature negotiation failed")
            ops.set_failed();
            return;
        end

        // 3. Restore all complete records first, before queue setup consumes
        // new IOVAs.  This preserves every live source mapping at its stable
        // descriptor-visible address without descriptor-format parsing.
        foreach (snap.mapping_records[i]) begin
            iommu_mapping_t destination;

            if (!ops.materialize_migration_mapping(
                    snap.mapping_records[i].mapping,
                    snap.mapping_records[i].payload, destination) ||
                !same_restored_migration_layout(
                    destination, snap.mapping_records[i].mapping)) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: failed to materialize complete source IOVA 0x%016h",
                    snap.mapping_records[i].mapping.iova))
                ops.set_failed();
                return;
            end
        end

        // A non-ring mapping that retired during drain cannot have a complete
        // source capture.  Materialize its dirty spans through the same
        // payload path so it receives ordinary reset ownership exactly once.
        foreach (mapping_groups[group_index]) begin
            iommu_mapping_t destination;
            iommu_mapping_t source_mapping;
            byte source_payload[];

            if (!build_dirty_fallback_payload(mapping_groups[group_index],
                                              source_mapping, source_payload) ||
                !ops.materialize_migration_mapping(source_mapping,
                                                   source_payload, destination) ||
                !same_restored_migration_layout(destination, source_mapping)) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: failed to materialize source IOVA 0x%016h",
                    source_mapping.iova))
                ops.set_failed();
                return;
            end
        end

        // Normal data DMA is consumed FIFO-by-FIFO by tx_complete() and
        // rx_receive().  Reconnect it before queues are exposed again.
        if (!ops.restore_normal_dma_ownership(snap.normal_dma_records)) begin
            rollback(ops);
            `uvm_error("AUTO_FSM",
                "restore_from_migration: failed to restore normal DMA ownership")
            ops.set_failed();
            return;
        end
        ok = 1;
    endtask

    // restore 的队列段：按快照队列对数建队，校验队列所有权后逐队列覆盖 ring 状态并
    // 提交所有权。失败回滚到验证式复位并写 FAILED。
    task restore_queues(
        virtio_atomic_ops ops,
        virtio_device_snapshot_t snap,
        virtio_driver_config_t cfg,
        output bit ok
    );
        bit setup_ok;
        bit queue_restore_ok;

        ok = 0;
        // 4. Restore queues: setup fresh, then overlay snapshot data.  No
        // queue-format-specific descriptor address rewriting is needed: each
        // source DMA IOVA already resolves through its restored fixed mapping.
        ops.setup_all_queues(snap.num_queue_pairs, cfg.vq_type,
                             cfg.queue_size, setup_ok);
        if (!setup_ok || (ops.vq_mgr.get_queue_count() != snap.queue_count)) begin
            rollback(ops);
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue setup failed or created %0d/%0d queues",
                ops.vq_mgr.get_queue_count(), snap.queue_count))
            ops.set_failed();
            return;
        end

        // Confirm that every queue-owned indirect table and dma_map_buf()
        // mapping can be reconstructed, but defer the physical ownership
        // transfer until each queue's complete overlay has succeeded. This
        // leaves later queues rollback-owned if an earlier overlay rejects.
        if (!ops.validate_restored_queue_ownership(snap)) begin
            rollback(ops);
            `uvm_error("AUTO_FSM",
                "restore_from_migration: queue-owned DMA validation failed")
            ops.set_failed();
            return;
        end

        // Restore ring data and indices from snapshot
        for (int unsigned q = 0; q < snap.queue_count; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            queue_restore_ok = (vq != null) &&
                               vq.restore_state(snap.queue_snapshots[q]);
            if (!queue_restore_ok) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d state overlay failed", q))
                ops.set_failed();
                return;
            end
            if (!ops.claim_restored_queue_ownership(snap.queue_snapshots[q])) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d ownership commit failed", q))
                ops.set_failed();
                return;
            end
            vq.commit_restored_migration_ownership();
        end
        ok = 1;
    endtask
endclass : virtio_migration_engine

`endif // VIRTIO_MIGRATION_ENGINE_SV
  ```

- [ ] **Step 3: 纳入 package。** `virtio_net_vip/src/virtio_net_pkg.sv`：
  ```systemverilog
  `include "agent/virtio_atomic_ops.sv"
  `include "agent/virtio_auto_fsm.sv"
  ```
  改为
  ```systemverilog
  `include "agent/virtio_atomic_ops.sv"
  `include "agent/virtio_migration_engine.sv"
  `include "agent/virtio_auto_fsm.sv"
  ```

- [ ] **Step 4: FSM 删除已移动的定义（`virtio_net_vip/src/agent/virtio_auto_fsm.sv`）。**
  1. 删除类头两行及其后空行：
     ```systemverilog
    localparam int unsigned MIGRATION_PAGE_SIZE = 4096;
    typedef virtio_dirty_page_snapshot_t migration_record_group_t[$];
     ```
  2. `    local bit               mq_pair_limit_bound;` 之后加：
     ```systemverilog
    // 迁移计算与恢复步骤（校验和、采集、校验、重建）；FSM 只负责状态与数据面启停。
    protected virtio_migration_engine migration;
     ```
     `new()` 中 `        mq_pair_limit_bound = 0;` 之后加
     `        migration = virtio_migration_engine::type_id::create({name, "_migration"});`
  3. 删除从注释行 `    // The checksum is calculated over one migration-owned mapping span.  It` 起、到注释行
     `    // A worker belongs to precisely one start_dataplane() generation.  The` 之前止的整段（HEAD :144-706，含
     `migration_page_checksum`、`migration_checksum_word/bytes/unsigned_bytes`、`migration_snapshot_checksum`、`migration_mapping_page_span`、
     `same_migration_source_mapping`、`same_restored_migration_layout`、`validate_normal_dma_restore_records`、`validate_queue_dma_restore_records`、
     `rollback_migration_restore`、`is_source_queue_ring_mapping`、`build_dirty_fallback_payload`），在原位置插入：
     ```systemverilog
    // 迁移快照整体校验和（委托迁移引擎）；派生 FSM/测试改写快照后据此重算。
    protected function bit [63:0] migration_snapshot_checksum(
        virtio_device_snapshot_t snap
    );
        return migration.migration_snapshot_checksum(snap);
    endfunction

     ```
  4. `freeze_for_migration` 方法体（从 `    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);` 到其 `    endtask`）替换为：
     ```systemverilog
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        bit capture_ok;

        `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)

        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: missing IOMMU or host-memory context")
            return;
        end

        // 1. Enable a new generation before requesting dataplane quiesce.
        // Any in-flight device write observed while workers drain belongs to
        // this snapshot, and no older dirty bitmap can leak into it.
        snap.dirty_generation =
            ops.iommu.begin_dirty_generation_for_host(iommu_host_id());

        // 2. Stop data plane
        if (state == FSM_RUNNING) begin
            state = FSM_SUSPENDING;
            stop_dataplane();
            // Override state since stop_dataplane sets FSM_READY
            state = FSM_SUSPENDING;
        end

        // 3-6. 特性/状态/设备配置/队列/普通 DMA 所有权/脏页/完整映射采集与整体校验和。
        migration.capture_snapshot(ops, iommu_host_id(), active_num_pairs,
                                   num_total_queues, capture_ok, snap);
        if (!capture_ok) begin
            state = FSM_ERROR;
            return;
        end

        state = FSM_FROZEN;

        `uvm_info("AUTO_FSM",
            $sformatf("freeze_for_migration: frozen, %0d queues, %0d dirty pages, and %0d live mappings saved",
                      num_total_queues, snap.dirty_pages.size(),
                      snap.mapping_records.size()), UVM_LOW)
    endtask
     ```
  5. `do_restore_from_migration` 方法体（从 `    protected virtual task do_restore_from_migration(` 到其 `    endtask`）替换为：
     ```systemverilog
    protected virtual task do_restore_from_migration(
        virtio_device_snapshot_t snap,
        output bit ok
    );
        bit set_failed_required;
        bit step_ok;
        virtio_migration_engine::migration_record_group_t mapping_groups[$];

        ok = 0;

        `uvm_info("AUTO_FSM", "restore_from_migration: starting restore", UVM_LOW)

        state = FSM_FROZEN;

        // Verify all saved backing pages before reset, queue reconstruction,
        // or dataplane restart.  Keeping the pre-freeze mapping alive here
        // lets migration reject unmap/remap changes deterministically.
        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null) || (ops.vq_mgr == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: incomplete transport, queue, IOMMU, or host-memory context")
            return;
        end
        if (!migration.validate_restore_snapshot(ops, iommu_host_id(),
                                                 drv_cfg.queue_size, snap,
                                                 set_failed_required)) begin
            state = FSM_ERROR;
            if (set_failed_required)
                ops.set_failed();
            return;
        end
        migration.collect_dirty_fallback_groups(snap, mapping_groups);

        // 1-3. 验证式复位、恢复原特性字、按固定 IOVA 重建映射与普通 DMA 所有权。
        migration.restore_device_and_dma(ops, snap, mapping_groups, step_ok);
        if (!step_ok) begin
            state = FSM_ERROR;
            return;
        end

        // 4. 按快照拓扑重建队列并覆盖 ring 状态。
        active_num_pairs = snap.num_queue_pairs;
        num_total_queues = snap.queue_count;
        migration.restore_queues(ops, snap, drv_cfg, step_ok);
        if (!step_ok) begin
            state = FSM_ERROR;
            return;
        end

        // 5. Restore MSI-X
        ops.setup_msix(num_total_queues);

        // 6. DRIVER_OK
        ops.set_driver_ok();
        state = FSM_READY;

        // 7. Restart data plane
        start_dataplane();
        if (state != FSM_RUNNING) begin
            migration.rollback(ops);
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: data plane did not restart")
            ops.set_failed();
            return;
        end

        ok = 1;

        `uvm_info("AUTO_FSM", "restore_from_migration: restore complete, data plane running", UVM_LOW)
    endtask
     ```
     `do_restore_from_migration` 上方注释块保持不变。
  6. FSM 文件头注释 `// Depends on:` 列表中 `//   - virtio_atomic_ops (low-level driver operations)` 之后加
     `//   - virtio_migration_engine (migration checksum/capture/restore steps)`。

- [ ] **Step 5: 证明移动完整。**
  `grep -nE "migration_checksum_word|migration_page_checksum\(|validate_normal_dma_restore_records|validate_queue_dma_restore_records|build_dirty_fallback_payload|rollback_migration_restore|is_source_queue_ring_mapping|same_migration_source_mapping|MIGRATION_PAGE_SIZE|migration_record_group_t mapping" virtio_net_vip/src/agent/virtio_auto_fsm.sv`
  期望只剩 `migration_record_group_t mapping_groups[$];` 所在的 `virtio_migration_engine::` 声明一行；
  `wc -l virtio_net_vip/src/agent/virtio_auto_fsm.sv` 期望约 1,050 行（HEAD 2,177 行，减少约 1,130 行）。

- [ ] **Step 6: SYNC 并运行受影响测试（期望 PASS）。** ONE TEST：`virtio_migration_dirty_test`（与 Step 1 基线一致：
  `Migration dirty-page tests PASSED`，0 ERROR/FATAL）、`virtio_dut_caps_test`、`virtio_unit_test`；私有环两个测试（P0.4 未合入时
  `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p3-6'`，期望 `flow_rc=0`、`contract_rc=0`、计数全 0）。

- [ ] **Step 7: 文档。** README 目录树 `│   │   ├── virtio_auto_fsm.sv             ← 自动状态机（12 状态 + 5 后台任务）` 之后插入
  `│   │   ├── virtio_migration_engine.sv      ← 热迁移校验和/采集/恢复步骤`；手册
  `|   |   +-- virtio_auto_fsm.sv             -- 自动生命周期状态机 (12 状态)` 之后插入
  `|   |   +-- virtio_migration_engine.sv     -- 热迁移校验和/采集/恢复步骤`。

- [ ] **Step 8: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 9: 提交。**
  ```bash
  git add virtio_net_vip/src/agent/virtio_migration_engine.sv virtio_net_vip/src/virtio_net_pkg.sv \
          virtio_net_vip/src/agent/virtio_auto_fsm.sv README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 将 auto_fsm 迁移代码移入 virtio_migration_engine"
  ```

---

### Task P3-7: `ops.setup_queue_range()` —— `setup_all_queues` 与 `do_configure_mq` 共用按队列对建队

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（新增 `setup_queue_range`，置于 `setup_all_queues` 之前；改写 `setup_all_queues` HEAD :838-887 的队列对循环与 ctrl 失败回滚）
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`（`do_configure_mq` HEAD :1110-1160 的扩容循环）
- Test: `virtio_net_vip/tests/virtio_unit_test.sv`

**Interfaces:**
- Consumes: `setup_queue(int unsigned queue_id, int unsigned queue_size, virtqueue_type_e vq_type, output bit ok)`、`teardown_queue(int unsigned queue_id)`（均为虚方法，私有 ops 与测试 spy 的覆写照常生效）。
- Produces: `virtual task setup_queue_range(int unsigned first_pair, int unsigned num_pairs, virtqueue_type_e vq_type, int unsigned queue_size, output bit ok);`
  —— pair i 的 receiveq=2i、transmitq=2i+1；任一失败时按创建顺序拆除本次已建队列并 ok=0，不触碰范围外队列。

**与 P0.2 的衔接：** 若 P0.2 已引入同名方法，比较签名：
- 签名与上面一致 → 跳过 Step 3，只做 Step 4/5 中尚未完成的调用点迁移（Step 1 的测试仍加入，作为回归保护；Step 2 期望改为直接 PASS）。
- 签名不同 → 保留 P0.2 的签名，Step 1 测试与 Step 4/5 的调用改用 P0.2 的参数顺序；不得并存两个版本。
P0.2 对 ctrl VQ 编号的计算（`ctrl_qid = ...` 一行）在 Step 4 中原样保留。

**Spec deviation（错误路径）：** HEAD 的 `do_configure_mq` 扩容时若第 k 对 RX 建队失败，直接返回且保留本次已建的前 k-1 对（其后
`active_num_pairs` 不更新，形成未计入的活动队列）；复用 `setup_queue_range` 后失败会拆除本次扩容新建的全部队列，错误文本由
`configure_mq: failed to setup RX queue %0d` / `TX queue %0d` 统一为 `configure_mq: failed to setup queue pairs %0d..%0d`。
`grep -rn "failed to setup RX queue\|failed to setup TX queue" virtio_net_vip/tests examples` 在 HEAD 为空，无测试依赖旧文本。

- [ ] **Step 1: 写失败测试。** `virtio_net_vip/tests/virtio_unit_test.sv` 中，在 `endclass : virtio_unit_exact_error_catcher` 之后插入：
  ```systemverilog

// 建队探针：setup_queue 只记录队列号并在 fail_qid 上失败，teardown 只记录；
// 用于验证 setup_queue_range 的队列编号与失败回滚，不访问设备。
class virtio_unit_range_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_unit_range_ops)

    int unsigned fail_qid;
    int unsigned setup_qids[$];
    int unsigned teardown_qids[$];

    function new(string name = "virtio_unit_range_ops");
        super.new(name);
        fail_qid = '1;
    endfunction

    virtual task setup_queue(int unsigned queue_id, int unsigned queue_size,
                             virtqueue_type_e vq_type, output bit ok);
        setup_qids.push_back(queue_id);
        ok = (queue_id != fail_qid);
    endtask

    virtual task teardown_queue(int unsigned queue_id);
        teardown_qids.push_back(queue_id);
    endtask
endclass : virtio_unit_range_ops
  ```
  `run_phase` 中 `test_fabric_bar_layout_roles();` 之后加 `        test_setup_queue_range_rollback();`，类末尾加入：
  ```systemverilog

    // 范围建队按 RX=2i/TX=2i+1 编号；失败时只拆除本次已建队列。
    task test_setup_queue_range_rollback();
        virtio_unit_range_ops ops;
        bit ok;
        int unsigned expected_setup[$];
        int unsigned expected_teardown[$];

        ops = virtio_unit_range_ops::type_id::create("range_ops");
        ops.setup_queue_range(1, 2, VQ_SPLIT, 8, ok);
        expected_setup = '{2, 3, 4, 5};
        if (!ok || (ops.setup_qids != expected_setup) || (ops.teardown_qids.size() != 0))
            `uvm_error("TEST", $sformatf("range setup created %p torn down %p",
                                         ops.setup_qids, ops.teardown_qids))

        ops.setup_qids.delete();
        ops.fail_qid = 5;
        ops.setup_queue_range(1, 2, VQ_SPLIT, 8, ok);
        expected_teardown = '{2, 3, 4};
        if (ok || (ops.setup_qids != expected_setup) ||
            (ops.teardown_qids != expected_teardown))
            `uvm_error("TEST", $sformatf("range rollback created %p torn down %p",
                                         ops.setup_qids, ops.teardown_qids))
        `uvm_info("UNIT_TEST", "test_setup_queue_range_rollback PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC，ONE TEST `virtio_unit_test`。期望 `Error-[` 编译错误：`setup_queue_range` 不是 `virtio_unit_range_ops` 的成员
  （P0.2 已提供同签名方法时此步直接 PASS，见上）。

- [ ] **Step 3: 新增 `setup_queue_range`。** `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 中，紧接在
  `    // setup_all_queues -- Create all queue pairs + control queue` 所在注释块之前插入：
  ```systemverilog
    // ------------------------------------------------------------------------
    // setup_queue_range -- 建立 [first_pair, first_pair+num_pairs) 的 RX/TX 队列对
    //
    // 队列号按 virtio-net 约定：pair i 的 receiveq 为 2i、transmitq 为 2i+1。
    // 任一队列失败时按创建顺序拆除本次已建队列并返回 ok=0，不触碰范围外队列；
    // setup_queue/teardown_queue 为虚方法，私有 ops 的停 DMA 确认语义照常生效。
    // ------------------------------------------------------------------------
    virtual task setup_queue_range(
        int unsigned     first_pair,
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit       ok
    );
        int unsigned created_qids[$];
        bit queue_ok;

        ok = 0;
        for (int unsigned i = first_pair; i < first_pair + num_pairs; i++) begin
            setup_queue(i * 2, queue_size, vq_type, queue_ok);  // receiveq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2);
            setup_queue(i * 2 + 1, queue_size, vq_type, queue_ok);  // transmitq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2 + 1);
        end
        ok = 1;
    endtask

  ```

- [ ] **Step 4: `setup_all_queues` 复用。** 同文件 `setup_all_queues` 中：
  1. 声明 `        int unsigned created_qids[$];` 删除。
  2. 队列对循环
     ```systemverilog
        // Setup receive and transmit queue pairs
        for (int unsigned i = 0; i < num_pairs; i++) begin
            setup_queue(i * 2, queue_size, vq_type, queue_ok);  // receiveq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2);
            setup_queue(i * 2 + 1, queue_size, vq_type, queue_ok);  // transmitq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2 + 1);
        end
     ```
     改为
     ```systemverilog
        // Setup receive and transmit queue pairs
        setup_queue_range(0, num_pairs, vq_type, queue_size, queue_ok);
        if (!queue_ok)
            return;
     ```
  3. ctrl 队列失败分支中
     ```systemverilog
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
     ```
     改为
     ```systemverilog
                for (int unsigned qid = 0; qid < num_pairs * 2; qid++)
                    teardown_queue(qid);
     ```
     （与 HEAD 一致：ctrl 失败时按创建顺序拆除全部 2*num_pairs 个数据队列。`ctrl_qid = ...` 一行保持 P0.2 后的内容。）
  4. 证据：`grep -n "created_qids" virtio_net_vip/src/agent/virtio_atomic_ops.sv` 期望只出现在 `setup_queue_range` 内。

- [ ] **Step 5: `do_configure_mq` 复用。** `virtio_net_vip/src/agent/virtio_auto_fsm.sv` 中：
  ```systemverilog
            // Setup new queues if expanding
            if (num_pairs > active_num_pairs) begin
                for (int unsigned i = active_num_pairs; i < num_pairs; i++) begin
                    ops.setup_queue(i * 2, drv_cfg.queue_size, drv_cfg.vq_type,
                                    setup_ok);
                    if (!setup_ok) begin
                        state = FSM_ERROR;
                        `uvm_error("AUTO_FSM", $sformatf(
                            "configure_mq: failed to setup RX queue %0d", i * 2))
                        return;
                    end
                    ops.setup_queue(i * 2 + 1, drv_cfg.queue_size, drv_cfg.vq_type,
                                    setup_ok);
                    if (!setup_ok) begin
                        ops.teardown_queue(i * 2);
                        state = FSM_ERROR;
                        `uvm_error("AUTO_FSM", $sformatf(
                            "configure_mq: failed to setup TX queue %0d", i * 2 + 1))
                        return;
                    end
                end
            end
  ```
  改为
  ```systemverilog
            // Setup new queues if expanding; a failure tears down every pair
            // created by this expansion before reporting.
            if (num_pairs > active_num_pairs) begin
                ops.setup_queue_range(active_num_pairs, num_pairs - active_num_pairs,
                                      drv_cfg.vq_type, drv_cfg.queue_size, setup_ok);
                if (!setup_ok) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "configure_mq: failed to setup queue pairs %0d..%0d",
                        active_num_pairs, num_pairs - 1))
                    return;
                end
            end
  ```
  （若 P0.2 已改写该循环，以 P0.2 后的循环整体为替换对象，替换结果相同。）方法上方注释
  `// 再收敛队列——缩容拆除多余的 RX/TX 队列，扩容按对新建（RX 建失败直接`
  `// FSM_ERROR；TX 建失败回滚同对 RX 再报错），最后更新 active_num_pairs。`
  改为
  `// 再收敛队列——缩容拆除多余的 RX/TX 队列，扩容经 ops.setup_queue_range 按对新建`
  `// （任一失败拆除本次新建的全部队列并 FSM_ERROR），最后更新 active_num_pairs。`
  证据：`grep -n "ops.setup_queue(" virtio_net_vip/src/agent/virtio_auto_fsm.sv` 期望只剩 `reset_single_queue` 中一处。

- [ ] **Step 6: SYNC 并运行受影响测试（期望 PASS）。** ONE TEST：`virtio_unit_test`、`virtio_dut_caps_test`（mq spy 计数）、
  `virtio_monitor_routing_test`（`live_mq_resize(vf, 1, 2, 0)` 扩容路径，HEAD :1057）、`virtio_net_packet_multi_queue_test`、
  `virtio_real_driver_multiqueue_test`；私有环两个测试（经 `dpu_priv_atomic_ops.setup_all_queues` → `super`）。

- [ ] **Step 7: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: 提交。**
  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/virtio_auto_fsm.sv \
          virtio_net_vip/tests/virtio_unit_test.sv
  git commit -m "refactor: do_configure_mq 复用 ops.setup_queue_range 按对建队"
  ```

---

### Task P3-9: control VQ 不在 0..2N-1 之后连续时，迁移与 MSI-X 按实际队列号工作（TDD）

**缺陷确认（P0-2、P3-3、P3-6、P3-7 之后的代码）：** P0-2 把 control VQ 建在 `2*max(num_pairs, max_virtqueue_pairs)`。
设备 `max_virtqueue_pairs=4`、当前 1 对 + CTRL_VQ 时，队列集合为 `{0, 1, 8}`，FSM 的 `num_total_queues=3`。
- 迁移 freeze：`virtio_migration_engine::capture_snapshot` 的 "5. Save all queue states" 以 `ops.vq_mgr.get_queue(q)` 遍历 `q=0..num_queues-1`
  （HEAD 位置 `virtio_auto_fsm.sv:1223-1230`）：槽位 2 取 `get_queue(2)==null` 留默认值，control VQ 8 未保存。
- 迁移 restore：`validate_restore_snapshot` 要求 `queue_snapshots[q].queue_id == q`（HEAD `virtio_auto_fsm.sv:1396`），槽位 2 的默认 `queue_id=0`
  触发 `invalid queue snapshot index=2 id=0 size=0` 并写 FAILED；即使放过，`restore_queues` 的覆盖循环 `get_queue(q)`（HEAD :1741-1748）在 q=2 为 null。
- MSI-X：`virtio_common_cfg_backend::set_msix`（P3-3，源自 HEAD `virtio_atomic_ops.sv:2050-2079`）为 `0..n-1` 分配向量并写
  `write_queue_msix_vector(2, …)`——队列 2 不存在，control VQ 8 没有向量。`virtio_notification_manager.queue_vectors[]` 按队列号索引
  （`virtio_atomic_ops.setup_queue` HEAD :753、`virtio_monitor.sv:479-495` 读取），而 `allocate_irq_vectors`（HEAD notification manager :168-225）
  只生成长度 n 的槽位数组，`queue_vectors[8]` 越界。
维护回归没有覆盖该拓扑（P0-2 的 `virtio_ctrl_vq_test` 只测建队与 MQ 扩容）。P0 integrator notes 已登记此风险。

**Files:**
- Modify: `virtio_net_vip/tests/virtio_ctrl_vq_test.sv`（P0-2 创建；新增测试件类与子测试 `test_ctrl_vq_outside_data_range_migration_and_msix`）
- Modify: `virtio_net_vip/src/virtqueue/virtqueue_manager.sv`（新增 `get_queue_ids`，`get_queue_count` 之后，HEAD :191-193）
- Modify: `virtio_net_vip/src/transport/virtio_notification_manager.sv`（新增 `remap_queue_vectors`，`bind_queue_vector` 横幅之前，HEAD :231）
- Modify: `virtio_net_vip/src/transport/virtio_config_backend.sv`（`virtio_common_cfg_backend::set_msix` 分配后重排向量）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（`setup_msix` 改用实际队列号；本任务在 P3-8 拆分之前执行）
- Modify: `virtio_net_vip/src/agent/virtio_migration_engine.sv`（`capture_snapshot`、`validate_restore_snapshot`、`restore_queues`）
- Test: `virtio_ctrl_vq_test`；`virtio_migration_dirty_test` 作为既有迁移行为基准

**测试放在 `virtio_ctrl_vq_test` 的理由：** 它已有可编程 `max_virtqueue_pairs` 的设备 config 语义；`virtio_migration_dirty_test` 的 transport
`read_net_config` 恒返回 0，改造会牵动其 24 个用例。新测试件自带 transport 子类（不依赖 P0-2 的 `virtio_ctrl_vq_test_transport`，
P2-8 若替换后者不受影响），只复用 P0-2 的 `virtio_ctrl_vq_test_mem/_iommu`（泄漏断言）。

**Interfaces:**
- Consumes: P0-2 的 control VQ 编号（`setup_all_queues` 协商 CTRL_VQ+MQ 时读 `read_net_config`）；P3-3 的
  `virtio_config_backend::set_msix(int unsigned queue_ids[$], output bit ok)`；P3-6 的引擎方法；`virtqueue_base::save_state`（写入真实 `queue_id`，
  `split_virtqueue.sv:695`）。
- Produces:
  - `virtqueue_manager::get_queue_ids(output int unsigned queue_ids[$])`（升序）。
  - `virtio_notification_manager::remap_queue_vectors(int unsigned queue_ids[$])`：槽位向量 → 按队列号索引，空洞填 `32'hFFFF`（VIRTIO_MSI_NO_VECTOR）。
  - 快照约定：`queue_snapshots[i]` 按实际队列号升序；`i < 2*num_queue_pairs` 时 `queue_id == i`（普通 DMA 记录仍按 queue_id 索引槽位）；
    其后槽位（control VQ）`queue_id >= 2*num_queue_pairs` 且严格递增。
  - `ops.setup_msix(num_queues)`：`vq_mgr` 中队列数等于 `num_queues` 时绑定实际队列号，否则（尚未建队的手工调用）沿用 `0..num_queues-1`。

**行为保持：** 队列号连续 `0..n-1` 时（全部现有维护测试），`get_queue_ids` 与旧的 `0..n-1` 相同、`remap_queue_vectors` 为恒等、
新校验规则对 `queue_id==q` 的快照等价，现有输出不变；只有不连续拓扑的行为改变（即修复）。

- [ ] **Step 1: 写失败测试。** `virtio_net_vip/tests/virtio_ctrl_vq_test.sv` 中，在 `class virtio_ctrl_vq_test extends uvm_test;` 之前插入：
  ```systemverilog
// MSI-X 表写入桩：只吞掉表项 MMIO，不需要 PCIe 通路；向量分配仍走生产 notification manager。
class virtio_ctrl_vq_test_null_bar extends virtio_bar_accessor;
    `uvm_object_utils(virtio_ctrl_vq_test_null_bar)

    function new(string name = "virtio_ctrl_vq_test_null_bar");
        super.new(name);
    endfunction

    virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset,
                                int unsigned size, bit [31:0] data);
    endtask
endclass : virtio_ctrl_vq_test_null_bar

// 迁移/MSI-X 用寄存器桩：status/复位/特性协商/队列编程/向量绑定在本地建模并记录；
// max_virtqueue_pairs 可编程，使 control VQ 位于 2*max_virtqueue_pairs（与数据队列不连续）。
class virtio_ctrl_vq_migration_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_ctrl_vq_migration_transport)

    int unsigned max_virtqueue_pairs;
    bit [7:0]    device_status;
    int unsigned programmed_qids[$];
    int unsigned msix_bound_qids[$];
    int unsigned msix_bound_vectors[int unsigned];

    function new(string name = "virtio_ctrl_vq_migration_transport");
        virtio_ctrl_vq_test_null_bar null_bar;
        super.new(name);
        max_virtqueue_pairs = 1;
        device_status = 0;
        null_bar = virtio_ctrl_vq_test_null_bar::type_id::create("ctrl_vq_null_bar");
        bar = null_bar;
        notify_mgr.bar = null_bar;
        cap_mgr.bar_ref = null_bar;
    endfunction

    virtual task read_device_status(ref bit [7:0] status);
        status = device_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        device_status = status;
    endtask

    virtual task reset_device_verified(ref bit reset_complete);
        device_status = 0;
        reset_complete = 1;
    endtask

    virtual task negotiate_features(bit [63:0] driver_supported,
                                    ref bit [63:0] negotiated);
        negotiated = driver_supported;
        driver_features = negotiated;
    endtask

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        cfg = '{default: 0};
        cfg.max_virtqueue_pairs = max_virtqueue_pairs;
    endtask

    virtual task select_queue(int unsigned queue_id);
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        max_size = 8;
    endtask

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        programmed_qids.push_back(queue_id);
    endtask

    virtual task write_queue_enable(bit enable);
    endtask

    virtual task write_config_msix_vector(int unsigned vector);
    endtask

    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);
        msix_bound_qids.push_back(queue_id);
        msix_bound_vectors[queue_id] = vector;
    endtask

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
    endtask
endclass : virtio_ctrl_vq_migration_transport

// 数据面启停只切换状态；迁移采集/恢复全部走生产 FSM 与迁移引擎。
class virtio_ctrl_vq_test_migration_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_ctrl_vq_test_migration_fsm)

    function new(string name = "virtio_ctrl_vq_test_migration_fsm");
        super.new(name);
    endfunction

    function void set_topology(int unsigned num_pairs, int unsigned num_queues);
        active_num_pairs = num_pairs;
        num_total_queues = num_queues;
    endfunction

    virtual task stop_dataplane();
        state = FSM_READY;
    endtask

    virtual task start_dataplane();
        state = FSM_RUNNING;
    endtask
endclass : virtio_ctrl_vq_test_migration_fsm

  ```
  在 `virtio_ctrl_vq_test::run_phase` 中 `` `uvm_info("CTRL_VQ_TEST", "control VQ tests PASSED", UVM_NONE) `` 之前加
  `        test_ctrl_vq_outside_data_range_migration_and_msix();`，并在类的最后一个 `endtask` 之后、`endclass : virtio_ctrl_vq_test` 之前加入：
  ```systemverilog

    // 设备 max_virtqueue_pairs=4、当前 1 对 + CTRL_VQ：队列为 {0,1,8}。MSI-X 必须给
    // control VQ 8 绑定向量（不得写不存在的队列 2）；freeze 必须保存队列 8，restore
    // 必须按实际队列号重建并覆盖，全过程不泄漏 ring/DMA。
    task test_ctrl_vq_outside_data_range_migration_and_msix();
        virtio_ctrl_vq_migration_transport transport =
            virtio_ctrl_vq_migration_transport::type_id::create("gap_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("gap_ops");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("gap_vq_mgr");
        virtio_ctrl_vq_test_mem mem = virtio_ctrl_vq_test_mem::type_id::create("gap_mem");
        virtio_ctrl_vq_test_iommu iommu =
            virtio_ctrl_vq_test_iommu::type_id::create("gap_iommu");
        virtio_ctrl_vq_test_migration_fsm fsm =
            virtio_ctrl_vq_test_migration_fsm::type_id::create("gap_fsm");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("gap_barrier");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("gap_wait_pol");
        virtio_device_snapshot_t snapshot;
        int unsigned expected_qids[$];
        int unsigned snapshot_qids[$];
        bit ok;
        bit restore_ok;

        mem.init_region(64'h7100_0000, 64'h7100_FFFF);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0902;
        transport.bdf = 16'h0902;
        transport.max_virtqueue_pairs = 4;
        transport.cap_mgr.msix_found = 1;
        transport.cap_mgr.msix_table_size = 8;
        transport.cap_mgr.msix_table_bir = 4;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;
        expected_qids = '{0, 1, 8};

        ops.setup_all_queues(1, VQ_SPLIT, 8, ok);
        if (!ok || (vq_mgr.get_queue_count() != 3) || (vq_mgr.get_queue(8) == null))
            `uvm_fatal("CTRL_VQ_TEST", "setup did not place the control VQ at 2*max_virtqueue_pairs=8")

        // MSI-X：每条实际队列一个向量，control VQ 8 必须绑定，不得写队列 2。
        ops.setup_msix(3);
        if ((transport.msix_bound_qids != expected_qids) ||
            (transport.notify_mgr.queue_vectors.size() <= 8) ||
            (transport.notify_mgr.queue_vectors[8] != transport.msix_bound_vectors[8]) ||
            (transport.msix_bound_vectors[8] == 0) ||
            (transport.msix_bound_vectors[8] == transport.msix_bound_vectors[1]) ||
            (transport.notify_mgr.queue_vectors[2] != 32'hFFFF))
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "MSI-X vectors were not bound to the actual queue set: bound=%p vectors=%p",
                transport.msix_bound_qids, transport.notify_mgr.queue_vectors))

        // freeze：快照按实际队列号保存 control VQ 8。
        fsm.ops = ops;
        fsm.drv_cfg = '{default: 0};
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.drv_cfg.queue_size = 8;
        fsm.drv_cfg.vq_type = VQ_SPLIT;
        fsm.set_topology(1, 3);
        fsm.state = FSM_RUNNING;
        fsm.freeze_for_migration(snapshot);
        foreach (snapshot.queue_snapshots[i])
            snapshot_qids.push_back(snapshot.queue_snapshots[i].queue_id);
        if ((fsm.state != FSM_FROZEN) || (snapshot.queue_count != 3) ||
            (snapshot_qids != expected_qids) ||
            (snapshot.queue_snapshots[2].queue_size != 8))
            `uvm_fatal("CTRL_VQ_TEST", $sformatf(
                "freeze did not capture the control VQ outside 0..2N-1: state=%s ids=%p",
                fsm.state.name(), snapshot_qids))

        // restore：复位后按快照重建 {0,1,8}，覆盖状态并重新绑定向量。
        ops.device_reset();
        if (vq_mgr.get_queue_count() != 0)
            `uvm_fatal("CTRL_VQ_TEST", "verified reset did not release source queues")
        transport.msix_bound_qids.delete();
        fsm.restore_from_migration(snapshot, restore_ok);
        if (!restore_ok || (fsm.state != FSM_RUNNING) ||
            (vq_mgr.get_queue_count() != 3) || (vq_mgr.get_queue(8) == null) ||
            (vq_mgr.get_queue(2) != null) ||
            (transport.msix_bound_qids != expected_qids))
            `uvm_error("CTRL_VQ_TEST", $sformatf(
                "restore did not rebuild the control VQ outside 0..2N-1: ok=%0b state=%s bound=%p",
                restore_ok, fsm.state.name(), transport.msix_bound_qids))

        foreach (expected_qids[i])
            ops.teardown_queue(expected_qids[i]);
        if ((vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("CTRL_VQ_TEST", "control VQ migration/MSI-X test leaked queue resources")
        mem.leak_check();

        `uvm_info("CTRL_VQ_TEST",
            "control VQ outside data range migration and MSI-X test PASSED", UVM_LOW)
    endtask
  ```

- [ ] **Step 2: 运行确认失败。** SYNC 后：
  `ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=virtio_ctrl_vq_test ./scripts/vcs.sh > logs/virtio_ctrl_vq_test.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/virtio_ctrl_vq_test.log | tail -20'`
  期望：编译通过（测试未直接引用新 API），运行出现
  `UVM_ERROR ... [CTRL_VQ_TEST] MSI-X vectors were not bound to the actual queue set: bound='{0, 1, 2} ...`，随后
  `UVM_FATAL ... [CTRL_VQ_TEST] freeze did not capture the control VQ outside 0..2N-1: state=FSM_FROZEN ids='{0, 1, 0}`；
  汇总 `UVM_ERROR :    1`、`UVM_FATAL :    1`。（`queue_vectors[8]` 越界读在 VCS 中返回 0 而不中止；若本环境对越界读报运行时错误，
  RED 文本改为该越界错误，属同一缺陷。）

- [ ] **Step 3: 队列管理器导出实际队列号。** `virtio_net_vip/src/virtqueue/virtqueue_manager.sv` 中 `get_queue_count` 的 `endfunction` 之后插入：
  ```systemverilog

    // ------------------------------------------------------------------
    // get_queue_ids -- 按队列号升序返回全部受管队列号（control VQ 可不连续，
    // 位于 2*max_virtqueue_pairs）；只读，不改变管理器状态。
    // ------------------------------------------------------------------
    function void get_queue_ids(output int unsigned queue_ids[$]);
        queue_ids.delete();
        foreach (queues[queue_id])
            queue_ids.push_back(queue_id);
    endfunction
  ```

- [ ] **Step 4: 通知管理器按队列号重排向量。** `virtio_net_vip/src/transport/virtio_notification_manager.sv` 中，在
  `    // bind_queue_vector` 所在横幅注释块（其上一行 `    // ====...`）之前插入：
  ```systemverilog
    // ========================================================================
    // remap_queue_vectors
    //
    // allocate_irq_vectors 按槽位 0..n-1 分配向量；队列号不连续时（control VQ
    // 位于 2*max_virtqueue_pairs）把槽位 i 的向量与回调使能移到 queue_ids[i]，
    // 空洞队列号记为 VIRTIO_MSI_NO_VECTOR(0xFFFF)。queue_ids 须升序且数量等于
    // 已分配槽位数，否则保持原样；queue_ids 为 0..n-1 时结果与原数组相同。
    // ========================================================================

    function void remap_queue_vectors(int unsigned queue_ids[$]);
        int unsigned slot_vectors[];
        bit          slot_cb[];
        int unsigned span;

        if ((queue_ids.size() == 0) || (queue_ids.size() != queue_vectors.size()) ||
            (queue_ids.size() != cb_enabled.size()))
            return;
        slot_vectors = queue_vectors;
        slot_cb = cb_enabled;
        span = queue_ids[queue_ids.size() - 1] + 1;
        queue_vectors = new[span];
        cb_enabled = new[span];
        foreach (queue_vectors[q]) begin
            queue_vectors[q] = 32'hFFFF;
            cb_enabled[q] = 1;
        end
        foreach (queue_ids[i]) begin
            queue_vectors[queue_ids[i]] = slot_vectors[i];
            cb_enabled[queue_ids[i]] = slot_cb[i];
        end
    endfunction

  ```

- [ ] **Step 5: common-config 后端在分配后重排。** `virtio_net_vip/src/transport/virtio_config_backend.sv` 的 `virtio_common_cfg_backend::set_msix` 中，在
  `            transport.notify_mgr.allocate_irq_vectors(queue_ids.size(), actual_mode);` 之后加
  `            transport.notify_mgr.remap_queue_vectors(queue_ids);`，
  并把其下注释 `// Bind per-queue vectors（P3-3 中 queue_ids 恒为 0..n-1，与 HEAD 相同）` 改为
  `// Bind per-queue vectors：只写实际存在的队列号（control VQ 可不连续）`。

- [ ] **Step 6: ops 用实际队列号建立 MSI-X。** `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 的 `setup_msix` 中：
  ```systemverilog
        // 队列号 0..num_queues-1（与 HEAD 相同）；P3-9 改为 vq_mgr 中的实际队列号。
        for (int unsigned q = 0; q < num_queues; q++)
            queue_ids.push_back(q);
  ```
  改为
  ```systemverilog
        // 绑定 vq_mgr 中实际存在的队列号（control VQ 可位于 2*max_virtqueue_pairs）；
        // 数量与 num_queues 不符（尚未建队的手工调用）时沿用 0..num_queues-1。
        if ((vq_mgr != null) && (vq_mgr.get_queue_count() == num_queues))
            vq_mgr.get_queue_ids(queue_ids);
        else begin
            for (int unsigned q = 0; q < num_queues; q++)
                queue_ids.push_back(q);
        end
  ```

- [ ] **Step 7: 迁移引擎按实际队列号保存/校验/覆盖（`virtio_net_vip/src/agent/virtio_migration_engine.sv`）。**
  1. `capture_snapshot` 形参列表 `    );` 之后、`        ok = 0;` 之前插入声明 `        int unsigned queue_ids[$];`，并把
     ```systemverilog
        snap.queue_snapshots = new[num_queues];

        for (int unsigned q = 0; q < num_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            if (vq != null) begin
                virtqueue_snapshot_t tmp_snap;
                vq.save_state(tmp_snap);
                snap.queue_snapshots[q] = tmp_snap;
            end
        end
     ```
     改为
     ```systemverilog
        snap.queue_snapshots = new[num_queues];

        // 槽位按实际队列号升序填充：数据队列 0..2N-1 连续，control VQ 可位于
        // 2*max_virtqueue_pairs。队列少于 num_queues 时剩余槽位保持默认值（restore 拒绝）。
        ops.vq_mgr.get_queue_ids(queue_ids);
        for (int unsigned slot = 0;
             (slot < num_queues) && (slot < queue_ids.size()); slot++) begin
            virtqueue_base vq;
            virtqueue_snapshot_t tmp_snap;
            vq = ops.vq_mgr.get_queue(queue_ids[slot]);
            vq.save_state(tmp_snap);
            snap.queue_snapshots[slot] = tmp_snap;
        end
     ```
  2. `validate_restore_snapshot` 中
     ```systemverilog
        foreach (snap.queue_snapshots[q]) begin
            if ((snap.queue_snapshots[q].queue_id != q) ||
                (snap.queue_snapshots[q].queue_size == 0) ||
     ```
     改为
     ```systemverilog
        foreach (snap.queue_snapshots[q]) begin
            bit queue_id_valid;

            // 数据队列槽位与队列号一致（普通 DMA 记录按 queue_id 索引槽位）；其后槽位
            // 只能是 control VQ：队列号不小于 2*num_queue_pairs 且严格递增。
            if (q < 2 * snap.num_queue_pairs)
                queue_id_valid = (snap.queue_snapshots[q].queue_id == q);
            else
                queue_id_valid =
                    (snap.queue_snapshots[q].queue_id >= 2 * snap.num_queue_pairs) &&
                    ((q == 0) ||
                     (snap.queue_snapshots[q].queue_id > snap.queue_snapshots[q - 1].queue_id));
            if (!queue_id_valid ||
                (snap.queue_snapshots[q].queue_size == 0) ||
     ```
  3. `restore_queues` 的覆盖循环中 `            vq = ops.vq_mgr.get_queue(q);` 改为
     `            vq = ops.vq_mgr.get_queue(snap.queue_snapshots[q].queue_id);`，
     并把同循环两条 `uvm_error` 的实参 `q))`（`queue %0d state overlay failed` 与 `queue %0d ownership commit failed`）改为
     `snap.queue_snapshots[q].queue_id))`；消息文本不变（`virtio_migration_dirty_test` 的捕获器按 `*state overlay failed*` 通配匹配）。
  4. 证据：`grep -n "get_queue(q)" virtio_net_vip/src/agent/virtio_migration_engine.sv` 期望为空；
     `grep -n "q < num_queues; q++" virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/transport/virtio_config_backend.sv`
     期望只剩 `setup_msix` 回退分支一处。

- [ ] **Step 8: 运行确认通过。** SYNC，同 Step 2 命令，期望三行汇总均为 0，日志含
  `control VQ outside data range migration and MSI-X test PASSED`。再以 ONE TEST 运行 `virtio_migration_dirty_test`、`virtio_monitor_test`
  （`queue_vectors` 的读者）、`virtio_unit_test`、`virtio_real_driver_flow_test`、`virtio_e2e_test`，期望各自 0 计数。

- [ ] **Step 9: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 10: 提交。** `git add virtio_net_vip/tests/virtio_ctrl_vq_test.sv virtio_net_vip/src/virtqueue/virtqueue_manager.sv virtio_net_vip/src/transport/virtio_notification_manager.sv virtio_net_vip/src/transport/virtio_config_backend.sv virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/virtio_migration_engine.sv`，
  提交信息：`fix: 迁移快照与 MSI-X 绑定按实际队列号覆盖 2*max_virtqueue_pairs 处的 control VQ`。

---

### Task P3-8: 按职责拆分 `virtio_atomic_ops` 类体（类内 `` `include ``）

**Files:**
- Create: `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_migration_ownership.svh`、
  `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_lifecycle.svh`、`virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_queue.svh`、
  `virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_datapath.svh`、`virtio_net_vip/src/agent/atomic_ops/virtio_atomic_ops_ctrl_admin.svh`
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`（类体从 `device_dma_write` 上方注释到 `endclass` 之前全部移出，HEAD :106-2088）
- Modify: `README.md`、`docs/virtio_net_vip_manual.md`（目录树）
- Test: 编译 + REGRESSION（纯文本移动，无行为变化）；私有环测试验证 `dpu_priv_atomic_ops` 覆写不受影响

**Interfaces:**
- Consumes: P3-3/P3-4/P3-7 之后的 `virtio_atomic_ops.sv`。
- Produces: 对外仍是同一个 `class virtio_atomic_ops`（类名、方法签名、成员可见性、factory 注册不变）；`dpu_priv_atomic_ops` 及全部测试子类无改动。

**方案选择：** SystemVerilog 的 `` `include `` 是预处理文本替换（IEEE 1800-2017 §22.4），可出现在类体内任意位置，被包含片段与直接写在类中等价；
VCS 支持。备选的 `extern` 方法需要在类内保留约 60 个原型并在类外以 `virtio_atomic_ops::` 限定重写全部定义（签名重复两份、默认参数只能写在原型上），
维护成本更高，故采用类内 include。片段使用 `.svh` 扩展名，不进入任何 filelist，也不被 `test_manifest.sh` 的 `--include='*.sv'` 扫描；
通过 `virtio_net.f` 已有的 `+incdir+virtio_net_vip/src` 以 `agent/atomic_ops/<name>.svh` 解析（examples 的 `run_vcs.sh` 同样使用 `virtio_net.f`）。
片段不加 `` `ifndef `` 守卫（只允许被包含一次，且只在类体内）。

**拆分边界（按现有段落横幅，脚本校验唯一性）：**

| 片段 | 内容 |
|---|---|
| 主文件 `virtio_atomic_ops.sv` | 文件头、字段、构造函数、`get_iommu_host_id`、`retire_normal_dma_record(s)`、`has_pending_normal_dma`、`cfg_backend`、`uses_private_ring`，以及 P2-3 放在这些辅助函数之间的内容 |
| `_migration_ownership.svh` | 从 `// Device-side writers must use this completed-write boundary instead of`（`device_dma_write`）到 `Device Lifecycle` 横幅之前：迁移映射物化、普通 DMA 所有权快照/恢复、恢复后队列所有权校验/认领 |
| `_lifecycle.svh` | `Device Lifecycle` + `Feature Negotiation` 段，以及 `Interrupt Handling` 段（`handle_interrupt`、`napi_poll`、`setup_msix`、`teardown_msix`） |
| `_queue.svh` | `Queue Management` 段（`setup_queue`、`teardown_queue`、`reset_queue`、`setup_queue_range`、`setup_all_queues`） |
| `_datapath.svh` | `TX Data Path` + `RX Data Path` 段（含 P2-3 放在其中的 `kick_with_fault` 等辅助） |
| `_ctrl_admin.svh` | `Control VQ` + `Control VQ Convenience Wrappers` 段（`admin_vq_submit`、`ctrl_send`、`ctrl_set_*`、`ctrl_announce_ack`） |

- [ ] **Step 1: 记录基线。** 在仓库根目录：
  `grep -cE "^\s*(virtual |protected |local |static )*(function|task)\b" virtio_net_vip/src/agent/virtio_atomic_ops.sv`
  记下方法数 M（HEAD 为 50；P1/P2/P3 后会变化，以实测为准）。

- [ ] **Step 2: 在 scratch 目录写拆分脚本 `split_atomic_ops.py`（不提交），内容：**
  ```python
  #!/usr/bin/env python3
  # 在仓库根目录运行：把 virtio_atomic_ops 的类体按段落横幅移入 agent/atomic_ops/*.svh。
  import pathlib

  src = pathlib.Path('virtio_net_vip/src/agent/virtio_atomic_ops.sv')
  out_dir = pathlib.Path('virtio_net_vip/src/agent/atomic_ops')
  lines = src.read_text().split('\n')

  def banner_start(title):
      # 横幅三行：'    // ====...'、'    // <title>'、'    // ====...'；返回第一行下标。
      hits = [i for i in range(1, len(lines) - 1)
              if lines[i].rstrip() == '    // ' + title
              and lines[i - 1].startswith('    // ====')]
      assert len(hits) == 1, (title, hits)
      return hits[0] - 1

  def line_of(prefix):
      hits = [i for i, l in enumerate(lines) if l.startswith(prefix)]
      assert len(hits) == 1, (prefix, hits)
      return hits[0]

  mig = line_of('    // Device-side writers must use this completed-write boundary instead of')
  life = banner_start('Device Lifecycle')
  queue = banner_start('Queue Management')
  tx = banner_start('TX Data Path')
  ctrl = banner_start('Control VQ')
  irq = banner_start('Interrupt Handling')
  end = line_of('endclass : virtio_atomic_ops')
  assert mig < life < queue < tx < ctrl < irq < end

  header = ('    // 本文件是 virtio_atomic_ops 类体的一部分（{what}），只由\n'
            '    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。\n')
  parts = [
      ('virtio_atomic_ops_migration_ownership.svh', '迁移恢复与 DMA 所有权', lines[mig:life]),
      ('virtio_atomic_ops_lifecycle.svh', '设备生命周期、特性协商与中断',
       lines[life:queue] + [''] + lines[irq:end]),
      ('virtio_atomic_ops_queue.svh', '队列建立与拆除', lines[queue:tx]),
      ('virtio_atomic_ops_datapath.svh', 'TX/RX 数据路径', lines[tx:ctrl]),
      ('virtio_atomic_ops_ctrl_admin.svh', 'Admin VQ 与 control VQ', lines[ctrl:irq]),
  ]
  out_dir.mkdir(exist_ok=True)
  moved = []
  for name, what, body in parts:
      while body and body[-1].strip() == '':
          body = body[:-1]
      (out_dir / name).write_text(header.format(what=what) + '\n' + '\n'.join(body) + '\n')
      moved += body
  includes = ['    `include "agent/atomic_ops/%s"' % name for name, _, _ in parts]
  src.write_text('\n'.join(lines[:mig] + includes + [''] + lines[end:]))

  # 自检：移动前后非空行的多重集完全相同（只新增 include 行与片段文件头）。
  before = sorted(l for l in lines[mig:end] if l.strip())
  after = sorted(l for l in moved if l.strip())
  assert before == after, 'moved content differs'
  print('split ok')
  ```
  运行：`python3 <scratch>/split_atomic_ops.py`，期望输出 `split ok`。

- [ ] **Step 3: 主文件头注释。** `virtio_net_vip/src/agent/virtio_atomic_ops.sv` 头注释 `//   - virtio_net_hdr.sv (header pack/unpack)` 之后加：
  ```systemverilog
//
// 类体按职责拆分（类内 `include，对外仍是同一个类，子类覆写不受影响）：
//   atomic_ops/virtio_atomic_ops_migration_ownership.svh  迁移恢复与 DMA 所有权
//   atomic_ops/virtio_atomic_ops_lifecycle.svh            生命周期、特性协商、中断
//   atomic_ops/virtio_atomic_ops_queue.svh                队列建立与拆除
//   atomic_ops/virtio_atomic_ops_datapath.svh             TX/RX 数据路径
//   atomic_ops/virtio_atomic_ops_ctrl_admin.svh           Admin VQ 与 control VQ
  ```

- [ ] **Step 4: 校验方法数不变。**
  `cat virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/atomic_ops/*.svh | grep -cE "^\s*(virtual |protected |local |static )*(function|task)\b"`
  期望等于 Step 1 的 M；`wc -l virtio_net_vip/src/agent/virtio_atomic_ops.sv` 期望约 130 行。

- [ ] **Step 5: 文档。** README 目录树 `│   │   ├── virtio_atomic_ops.sv            ← 原子操作库（约 30 个方法）` 之后插入
  `│   │   ├── atomic_ops/                     ← 原子操作类体分片（lifecycle/queue/datapath/ctrl_admin/migration_ownership）`；
  手册 `|   |   +-- virtio_atomic_ops.sv            -- 原子操作库 (~30 个方法)` 之后插入
  `|   |   +-- atomic_ops/*.svh                -- 原子操作类体分片 (类内 include)`。

- [ ] **Step 6: SYNC 并编译/运行受影响测试（期望 PASS）。** ONE TEST：`virtio_unit_test`（编译整个 package）、`virtio_admin_vq_test`、
  `virtio_migration_dirty_test`、`virtio_indirect_desc_test`；私有环两个测试（P0.4 未合入时
  `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p3-8'`，期望 `flow_rc=0`、`contract_rc=0`、计数全 0）。

- [ ] **Step 7: REGRESSION。** BRIEF 的 REGRESSION 命令，期望 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: 提交。**
  ```bash
  git add virtio_net_vip/src/agent/virtio_atomic_ops.sv virtio_net_vip/src/agent/atomic_ops/ README.md docs/virtio_net_vip_manual.md
  git commit -m "refactor: 按职责拆分 virtio_atomic_ops 类体为 include 片段"
  ```

---

### Notes for integrator（P3）

**本阶段产出、供其他阶段/后续设计使用的接口**

| 接口 | 定义位置 | 使用方 |
|---|---|---|
| `virtio_execution_profile`（`has_model_device/supports_host_mem_responder/needs_physical_link/pcie_if_mode/ep_is_active/ep_auto_response/endpoint_unready_reason/mode`）、`virtio_select_execution_profile()`、`virtio_net_env_config::execution_profile()` | `src/env/virtio_execution_profile.sv` | fixture；后续设计"MODEL 模式 responder 按 snapshot 生成身份"按 `has_model_device()` 分支 |
| `virtio_discovery_strategy::{strategy_name, discover(transport, output ok, output why)}`、`virtio_pci_transport::{set_discovery_strategy, discovery_strategy_name, discovery_strategy}` | `src/transport/virtio_discovery_strategy.sv` | 后续 `verify_snapshot`：继承基类，`discover()` 先读 VID/DID/BAR 尺寸/BAR2 qinfo/AF 0x1010，再委托 `virtio_fabric_preconfigured_discovery`；由 env 在 `configure_fabric_managed()` 之后调用 `set_discovery_strategy()` 安装 |
| `virtio_config_backend`（`reset/read_status/write_status/read_device_features/write_driver_features/set_features/query_queue_max/configure_queue/enable_queue/disable_queue/reset_queue/set_msix/clear_msix`）、`virtio_queue_program_t`、`virtio_empty_queue_program()`、`virtio_atomic_ops::config_backend` | `src/transport/virtio_config_backend.sv` | 后续 `virtio_af_direct_backend` 继承；`configure_queue` 的 `vq_type` → `virtio_mode`、`queue_size` → `q_depth`、`desc_iova`、`msix_vector`、`local_qid`（标准环 = queue_id）、`host_id/bdf` → identity binding 查 gfid；`disable_queue` ok=0 时 ops 已保证保留资源 |
| `dpu_priv_config_backend`（`control`、`to_context/from_context`、`notify_queue`） | `src/dpu_priv/dpu_priv_config_backend.sv` | 后续"`dpu_priv_device_control` 默认实现委托 af_direct"：只需提供一个 `dpu_priv_device_control` 子类，私有 ops 链路不变 |
| `virtio_driver_protocol`（标准 / `dpu_priv_driver_protocol`）、`virtio_driver::protocol`、`virtio_function_instance::protocol`、`virtio_atomic_ops::uses_private_ring()` | `src/agent/virtio_driver_protocol.sv`、`src/dpu_priv/dpu_priv_driver_protocol.sv` | 后续设计数据面 ⑥ 的协议选择 |
| `fabric_bar_layout`（`build/slot_contract/even_bar_for/role_of/has_role`）、`virtio_bar_accessor::get_fabric_layout()` | `src/transport/fabric_bar_layout.sv` | 后续 `verify_snapshot` 用 `even_bar_for(DPU_BAR_MAILBOX)` 定位 BAR2 qinfo、用 `even_bar_for(DPU_BAR_DEVICE_MEMORY)` 定位 AF 0x1010，而不写死 BAR 号 |
| `virtqueue_manager::get_queue_ids()`、`virtio_notification_manager::remap_queue_vectors()`、快照槽位约定（数据队列 `queue_id==slot`，其后为 control VQ） | P3-9 | 遍历队列集合的代码与后续 af_direct 的 `set_msix(queue_ids)` 应使用实际队列号而非 `0..n-1` |
| `virtio_migration_engine`、`virtio_atomic_ops::setup_queue_range()` | `src/agent/virtio_migration_engine.sv`、ops queue 片段 | P4.1（IOMMU 旧接口迁移）只需修改引擎中的 `verify_dirty_page_mapping/verify_mapping_identity` 调用点 |

**顺序依赖**
- P3 整体在 P0–P2 之后。P3-3 依赖 P2-3 之后的 ops（不触及 `tx_submit/rx_refill/ctrl_send/admin_vq_submit`，无文本冲突）；P3-4 依赖 P2-5 的 preflight/commit 形态（Step 8.3 已给出两种形态的处理）；
  P3-7 依赖 P0.2（见该任务"与 P0.2 的衔接"）；P3-1 与 P2-7 同改 `virtio_real_driver_flow_fixture.sv`，但 P3-1 只改 build/connect/eoe/build_flow/访问器，不触及 P2-7 改写的驱动初始化路径。
- P3 内部：P3-5 修改 P3-2 新建文件；P3-4 的 `uses_private_ring()` 插在 P3-3 的 `cfg_backend()` 之后；P3-9 在 P3-7 之后、P3-8 之前（改 P3-3 的 `set_msix` 实现与 P3-6 的引擎）；P3-8 必须最后（按段落横幅移动 P3-3/P3-4/P3-7/P3-9 改过的代码）。
- P3-9 依赖 P0-2 的 `virtio_ctrl_vq_test.sv`（`virtio_ctrl_vq_test_mem/_iommu` 与其 `run_phase`），并关闭 P0 integrator notes 中“迁移与 MSI-X 仍假设队列号连续 0..2N”的遗留风险。
- P4.2（删除非 fabric BAR 枚举）完成后应同时删除 `virtio_enumerate_discovery`，并把 transport 构造时的默认策略改为 fabric_preconfigured（或要求显式安装）；`fabric_bar_layout` 中 `fabric_layout == null` 的非 Fabric 放行分支随之可删除。
- P4.1 改 IOMMU 接口时，迁移相关调用点已集中在 `virtio_migration_engine.sv`（不再在 FSM）。

**风险**
- 前向类型引用：`virtio_discovery_strategy.sv` 在 `virtio_pci_transport.sv` 之前编译，经 `types/virtio_net_types.sv:24` 的 `typedef class virtio_pci_transport;` 访问 transport 成员；
  `virtio_driver_protocol.sv` 以 `typedef class virtio_net_dataplane;` 仅作参数类型。这是 UVM 库自身常用的写法（如 sequence 通过前向声明的 sequencer 句柄调用方法），
  但若 VCS 报错，回退方案：把 `virtio_discovery_strategy.sv` 移到 transport 之后 include，并在 package 中 transport 之前加
  `typedef class virtio_enumerate_discovery; typedef class virtio_fabric_preconfigured_discovery;`。
- 报告客户端变化：被移入 `uvm_object` 的诊断（迁移引擎的 `AUTO_FSM`、发现策略的 `TRANSPORT`、私有协议的 `FUNCTION_BIND` 错误、protocol 的 `VIRTIO_DRV`）
  现在由全局 report server（uvm_root）发出而非原组件/report object。已核对：所有按 `get_client()` 过滤的捕获器（`virtio_dut_caps_test.sv` 的 configure_mq、
  full_init、restore 包装、preflight `FUNCTION_BIND` fatal）对应的消息都保留在原对象中；`virtio_migration_dirty_test` 的捕获器只按 ID+消息匹配。
- `virtio_driver` 的标准 `ATOMIC_KICK` 仍为 `vq.kick()`（P0.1 指出 split/packed 的 `kick()` 只计数不发 TLP）。P3-4 逐字保留该行为；若 P0.1/P2-3 的意图是 MANUAL kick 也走
  `ops.kick_with_fault`，应在 `virtio_standard_driver_protocol::kick` 中改调，并补测试——这是行为变化，不在 P3 内做。
- af_direct 的下发顺序（所有 TX `queue_en=0` → RX → RSS → MSI-X → `CONTROL_QUEUE` 使能 TX → `vport_fwd`）是批量顺序；P3 的 `setup_queue` 每条队列 `configure_queue` 后立即
  `enable_queue`。后续 af_direct 后端可在 `enable_queue` 中只登记 TX 队列，并在 `set_msix`（FSM 在全部建队后调用）之后的首个时机统一写 `CONTROL_QUEUE`，或扩展 FSM
  增加"全部队列已编程"钩子；P3 不预置该钩子（YAGNI）。
- P3-9：`virtio_config_backend::set_msix` 的签名在 P3-3 即定为 `set_msix(int unsigned queue_ids[$], output bit ok)`（P3-3 中 ops 传 0..n-1，与 HEAD 等价），避免 P3-9 再改抽象接口。不连续拓扑下 `queue_vectors` 空洞为 0xFFFF；之后 MQ 扩容新建的队列 2/3 在 `setup_queue` 中取到 0xFFFF（NO_VECTOR）而非旧代码里错误的槽位向量，直到下一次 `setup_msix`。P3-9 RED 依赖 VCS 对动态数组越界读返回默认值；若报运行时错误，RED 文本变为越界错误，属同一缺陷。
- P3-7 改变 `do_configure_mq` 扩容失败路径（回滚本次新建的全部队列、错误文本统一），无测试依赖旧文本（已 grep）。

**Spec deviations 汇总**
1. fixture `execution_mode` 判断实际 15 处 + 1 个访问器（简报称 :192-274 有 16 处）；`env.sv:262` 与 `apply_plusargs` 解析不是行为分支，保留。
2. `virtio_pcie_dut_responder::can_start/model_only` 0 调用，P3-1 直接删除。
3. bar accessor 的约 34 处 fabric 判断属于 BAR 角色布局，归入 P3-5（`fabric_bar_layout`），P3-2 只迁移发现路径分支。
4. BAR 角色契约（BAR0/2/4）是 DUT profile 契约且被 `virtio_fabric_resource_test` 断言，P3-5 保留为 `fabric_bar_layout::slot_contract` 唯一一处，而非完全由租约推导；
   `allow_functional_bar_access` 中不可达的"角色不兼容"分支删除。
5. 私有 ops 的 `setup_queue` 仍保留覆写（私有环的 custom vq、回调与单块连续映射是 ring 格式差异，不是配置后端职责）；其中的设备控制调用（configure/disable/reset/notify）
   全部改经 `dpu_priv_config_backend`。私有 ops 对标准 status/feature/MSI-X 的拒绝覆写保留（错误文本不变），后端对应入口同样拒绝作为第二道防线。
6. 私有 FSM 的 `$cast` 改为 `ops.uses_private_ring()` + 读 `vq_mgr.get_queue(0).queue_size`；`dpu_priv_driver_protocol::bind_ops` 类型不符时 why 由空串改为说明文本。
7. `atomic_ops` 拆分采用类内 `` `include ``（.svh 片段，无守卫），理由见 P3-8；同时把 `Interrupt Handling` 段（含 `setup_msix/teardown_msix/napi_poll`）归入 lifecycle 片段。
8. 迁移引擎约 1,120 行（规格估计约 1,150 行）；FSM 由 2,177 行降至约 1,050 行。

---

## P4：遗留路径迁移

本阶段对应 spec “P4：遗留路径迁移”（P4.1 / P4.2 / P4.3）。行号均为 HEAD `62ae3e9` 的位置，并附符号锚点。
P0–P3 执行后行号会漂移，执行时以符号或原文重新定位（`grep -n`）。P3 的接口按 `plan_parts/P3.md`
（P3-2 `virtio_discovery_strategy`）引用。

任务顺序与依赖：

| Task | 内容 | 前置 |
|---|---|---|
| P4-1 | IOMMU：测试调用点迁移到 `*_for_host(0, ...)` | P1.7（IOMMU 无调用查询已删） |
| P4-2 | IOMMU：删除非 host 包装与 host0 标量双写 | P4-1 |
| P4-3 | fixture：多 PF 端点镜像、completion 超时旋钮、`function_by_bdf()` | P2.7、P3-1（fixture 已改造） |
| P4-4 | `virtio_full_integration_test` 迁移到 snapshot/fabric 流程（含确认点） | P4-3 |
| P4-5 | `virtio_dual_test` 迁移到 snapshot/fabric 流程（含确认点） | P4-3、P2.8 |
| P4-6 | 删除 `enumerate_bars`、`virtio_enumerate_discovery` | P4-4、P4-5、P3-2 |
| P4-7 | function instance：删除 standalone 绑定入口与 standalone 身份分支 | P2.5 |
| P4-8 | DMA host domain 严格化（transport / atomic ops / auto_fsm / monitor）+ 测试身份迁移 | P4-7、P2.8 |
| P4-9 | auto_fsm：删除 MQ 上限 0 的 standalone 兼容编码（含确认点） | P4-8 |

---

### Task P4-1: IOMMU 测试调用点迁移到 `*_for_host(0, ...)`

**Files:**
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv:224-239`（`test_iommu_translation_overflow`）、`:284-304`（`test_iommu`）、`:481-510`（`test_iommu_random_aperture`）
- Modify: `virtio_net_vip/tests/virtio_stress_unit_test.sv:138-160`（`test_iommu_fault_injection`）
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv:265-266`
- Modify: `virtio_net_vip/tests/virtio_admin_vq_test.sv:91-115`（`virtio_admin_vq_test_iommu::map/unmap` 覆写）、`:368-376`、`:511-520`、`:1209-1210`
- Modify: `virtio_net_vip/tests/virtio_migration_dirty_test.sv:376,584-607,641,714,760,811,857,986,1124-1125,1181,1360,1493`
- Test: `virtio_unit_test`、`virtio_stress_unit_test`、`virtio_indirect_desc_test`、`virtio_admin_vq_test`、`virtio_migration_dirty_test`

**Interfaces:**
- Consumes（HEAD 已存在，签名不变）：
  - `virtual function bit [63:0] map_for_host(int unsigned host_id, bit [15:0] bdf, bit [63:0] gpa, int unsigned size, dma_dir_e dir, string file = "", int line = 0)`（`virtio_iommu_model.sv:194`）
  - `virtual function void unmap_for_host(int unsigned host_id, bit [15:0] bdf, bit [63:0] iova, string file = "", int line = 0)`（`:412`）
  - `virtual function bit [63:0] map_fixed_for_host(int unsigned host_id, bit [15:0] bdf, bit [63:0] gpa, int unsigned size, dma_dir_e dir, bit [63:0] requested_iova, string file = "", int line = 0)`（`:300`）
  - `function bit translate_for_host(int unsigned host_id, bit [15:0] bdf, bit [63:0] iova, int unsigned size, dma_dir_e access_dir, ref bit [63:0] gpa, ref iommu_fault_e fault)`（`:483`）
  - `function bit write_from_device_for_host(int unsigned host_id, host_mem_manager mem, bit [15:0] bdf, bit [63:0] iova, byte data[], ref iommu_fault_e fault)`（`:847`）
  - `function bit [63:0] begin_dirty_generation_for_host(int unsigned host_id)`（`:715`）
  - `function void capture_dirty_generation_for_host(int unsigned host_id, ref bit [63:0] dirty_pages[$])`（`:747`）
- Produces: 测试和 test double 不再引用非 host 接口；`virtio_admin_vq_test_iommu` 改为覆写 `map_for_host/unmap_for_host`。这是 P4-2 删除非 host 包装的前提。

等价性说明：HEAD 中 `map_for_host(0, ...)`、`unmap_for_host(0, ...)`、`map_fixed_for_host(0, ...)` 会回落到虚方法 `map()/unmap()/map_fixed()`，再进入 `*_in_domain(0, ...)`。`translate()`、`write_from_device()`、`begin_/capture_dirty_generation()` 本身就是 `*_for_host(0, ...)` 的一行转发。因此所有替换都走同一条 host0 实现路径。

`virtio_admin_vq_test_iommu` 覆写迁移后，生产代码（全部经 `map_for_host/unmap_for_host` 调用）仍命中覆写。HEAD 中 host≠0 的调用不经过旧覆写；admin 测试里 host≠0 的场景（`:611`、`:714`）都是“拒绝绑定”路径，断言 `iommu.total_maps == 0`，不产生 map，所以 `map_attempts` 计数不变。

迁移测试 `:593-596` 中，两次 `DMA_FROM_DEVICE/BIDIRECTIONAL` 翻译的 `uvm_error` 文本由 `translate_for_host` 发出（`:496`，文本含 `write_from_device`），`:475` 的 catcher 仍然匹配。

- [ ] **Step 1: 记录迁移前基线**（53 上执行，供 Step 7 对比）

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
for t in virtio_unit_test virtio_stress_unit_test virtio_indirect_desc_test virtio_admin_vq_test virtio_migration_dirty_test; do
ssh ubuntu@10.11.10.53 "source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=$t ./scripts/vcs.sh > logs/$t.log 2>&1; grep -E \"^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+\" logs/$t.log | tail -20; grep -c IOMMU_ logs/$t.log"
done
```
预期：每个测试 `UVM_WARNING : 0`、`UVM_ERROR : 0`、`UVM_FATAL : 0`。记下每个测试的 `IOMMU_` 行数。

- [ ] **Step 2: 迁移 `virtio_unit_test.sv`**

`test_iommu_translation_overflow`（`:224-239`）：
```systemverilog
// old
        if (iommu.map_fixed(16'h0124, 64'h0000_0000_7000_0000,
                            4096, DMA_TO_DEVICE, fixed_iova) != fixed_iova)
// new
        if (iommu.map_fixed_for_host(0, 16'h0124, 64'h0000_0000_7000_0000,
                                     4096, DMA_TO_DEVICE, fixed_iova) != fixed_iova)
```
```systemverilog
// old
        ok = iommu.translate(16'h0124, fixed_iova, 32'hffff_ffff,
                             DMA_TO_DEVICE, gpa, fault);
// new
        ok = iommu.translate_for_host(0, 16'h0124, fixed_iova, 32'hffff_ffff,
                                      DMA_TO_DEVICE, gpa, fault);
```
```systemverilog
// old
        iommu.unmap(16'h0124, fixed_iova);
// new
        iommu.unmap_for_host(0, 16'h0124, fixed_iova);
```
`test_iommu`（`:284-304`）：
```systemverilog
// old
        iova = iommu.map(16'h0100, 64'hDEAD_0000, 4096, DMA_TO_DEVICE);
// new
        iova = iommu.map_for_host(0, 16'h0100, 64'hDEAD_0000, 4096, DMA_TO_DEVICE);
```
```systemverilog
// old
        ok = iommu.translate(16'h0100, iova, 64, DMA_TO_DEVICE, gpa, fault);
// new
        ok = iommu.translate_for_host(0, 16'h0100, iova, 64, DMA_TO_DEVICE, gpa, fault);
```
```systemverilog
// old
        write_iova = iommu.map(16'h0100, 64'hBEEF_0000, 4096,
                               DMA_FROM_DEVICE);
        ok = iommu.translate(16'h0100, write_iova, 64, DMA_TO_DEVICE,
                             gpa, fault);
// new
        write_iova = iommu.map_for_host(0, 16'h0100, 64'hBEEF_0000, 4096,
                                        DMA_FROM_DEVICE);
        ok = iommu.translate_for_host(0, 16'h0100, write_iova, 64, DMA_TO_DEVICE,
                                      gpa, fault);
```
```systemverilog
// old
        iommu.unmap(16'h0100, iova);
        iommu.unmap(16'h0100, write_iova);
// new
        iommu.unmap_for_host(0, 16'h0100, iova);
        iommu.unmap_for_host(0, 16'h0100, write_iova);
```
`test_iommu_random_aperture`（`:481-510`）：
```systemverilog
// old
            iova = iommu.map(16'h0123, 64'h6000_0000 + index * 4096,
                             4096, DMA_TO_DEVICE);
// new
            iova = iommu.map_for_host(0, 16'h0123, 64'h6000_0000 + index * 4096,
                                      4096, DMA_TO_DEVICE);
```
```systemverilog
// old
            ok = iommu.translate(16'h0123, iova, 4096,
                                 DMA_TO_DEVICE, gpa, fault);
// new
            ok = iommu.translate_for_host(0, 16'h0123, iova, 4096,
                                          DMA_TO_DEVICE, gpa, fault);
```
```systemverilog
// old
        if (iommu.map_fixed(16'h0123, 64'h7000_0000, 4096,
                            DMA_TO_DEVICE, 64'h4000_0000) != '1)
// new
        if (iommu.map_fixed_for_host(0, 16'h0123, 64'h7000_0000, 4096,
                                     DMA_TO_DEVICE, 64'h4000_0000) != '1)
```
```systemverilog
// old
            iommu.unmap(16'h0123, iovas[index]);
// new
            iommu.unmap_for_host(0, 16'h0123, iovas[index]);
```

- [ ] **Step 3: 迁移 `virtio_stress_unit_test.sv`（`test_iommu_fault_injection`）与 `virtio_indirect_desc_test.sv`**

```systemverilog
// stress :138 old
        iova = iommu.map(16'h0200, 64'hBEEF_0000, 4096, DMA_BIDIRECTIONAL);
// new
        iova = iommu.map_for_host(0, 16'h0200, 64'hBEEF_0000, 4096, DMA_BIDIRECTIONAL);
```
`:151` 与 `:156` 两行文本相同，均替换为：
```systemverilog
// old
        ok = iommu.translate(16'h0200, iova, 64, DMA_TO_DEVICE, gpa, fault);
// new
        ok = iommu.translate_for_host(0, 16'h0200, iova, 64, DMA_TO_DEVICE, gpa, fault);
```
```systemverilog
// stress :160 old
        iommu.unmap(16'h0200, iova);
// new
        iommu.unmap_for_host(0, 16'h0200, iova);
```
```systemverilog
// indirect_desc :265-266 old
        translated = iommu.translate(vq.bdf, main_addr, main_len,
                                     DMA_TO_DEVICE, table_gpa, fault);
// new
        translated = iommu.translate_for_host(0, vq.bdf, main_addr, main_len,
                                              DMA_TO_DEVICE, table_gpa, fault);
```

- [ ] **Step 4: 迁移 `virtio_admin_vq_test.sv`**

`virtio_admin_vq_test_iommu` 的两个覆写（`:91-115`）整段替换为：
```systemverilog
    function bit [63:0] map_for_host(int unsigned host_id,
                             bit [15:0] bdf,
                             bit [63:0] gpa,
                             int unsigned size,
                             dma_dir_e dir,
                             string file = "",
                             int line = 0);
        map_attempts++;
        if (fail_on_map_attempt != 0 && map_attempts == fail_on_map_attempt)
            return '1;
        return super.map_for_host(host_id, bdf, gpa, size, dir, file, line);
    endfunction

    function void unmap_for_host(int unsigned host_id,
                        bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        if (observe_unmap_order && !saw_unmap) begin
            saw_unmap = 1;
            queue_reset_requested_before_first_unmap =
                (transport_for_unmap != null && transport_for_unmap.reset_count != 0);
            device_reset_requested_before_first_unmap =
                (transport_for_unmap != null && transport_for_unmap.device_reset_count != 0);
        end
        super.unmap_for_host(host_id, bdf, iova, file, line);
    endfunction
```
`:368-369`：
```systemverilog
// old
        assert(iommu.translate(vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                               request_gpa, fault))
// new
        assert(iommu.translate_for_host(0, vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                                        request_gpa, fault))
```
`:375-376`：
```systemverilog
// old
        assert(iommu.write_from_device(mem, vq.bdf, in_addr,
                                       device_response, fault))
// new
        assert(iommu.write_from_device_for_host(0, mem, vq.bdf, in_addr,
                                                device_response, fault))
```
`:511-512`：
```systemverilog
// old
                assert(iommu.translate(vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                                       response_gpa, fault))
// new
                assert(iommu.translate_for_host(0, vq.bdf, out_addr, out_len, DMA_TO_DEVICE,
                                                response_gpa, fault))
```
`:519-520` 与 `:1209-1210` 两处文本相同，均替换为：
```systemverilog
// old
                assert(iommu.write_from_device(mem, vq.bdf, in_addr,
                                               device_response, fault))
// new
                assert(iommu.write_from_device_for_host(0, mem, vq.bdf, in_addr,
                                                        device_response, fault))
```

- [ ] **Step 5: 迁移 `virtio_migration_dirty_test.sv`**

逐行替换。缩进保持原样，续行对齐到新的左括号。

| HEAD 行 | old | new |
|---|---|---|
| 376 | `iommu.unmap(bdf, mapped_iova);` | `iommu.unmap_for_host(0, bdf, mapped_iova);` |
| 584 | `iova = iommu.map(16'h0900, gpa, 64, DMA_FROM_DEVICE);` | `iova = iommu.map_for_host(0, 16'h0900, gpa, 64, DMA_FROM_DEVICE);` |
| 585 | `bidir_iova = iommu.map(16'h0900, gpa, 64, DMA_BIDIRECTIONAL);` | `bidir_iova = iommu.map_for_host(0, 16'h0900, gpa, 64, DMA_BIDIRECTIONAL);` |
| 589 | `iommu.begin_dirty_generation();` | `void'(iommu.begin_dirty_generation_for_host(0));` |
| 593 | `translated = iommu.translate(16'h0900, iova, 16, DMA_FROM_DEVICE,` | `translated = iommu.translate_for_host(0, 16'h0900, iova, 16, DMA_FROM_DEVICE,` |
| 595 | `bidir_translated = iommu.translate(16'h0900, bidir_iova, 16,` | `bidir_translated = iommu.translate_for_host(0, 16'h0900, bidir_iova, 16,` |
| 598 | `iommu.capture_dirty_generation(dirty_pages);` | `iommu.capture_dirty_generation_for_host(0, dirty_pages);` |
| 606 | `iommu.unmap(16'h0900, bidir_iova);` | `iommu.unmap_for_host(0, 16'h0900, bidir_iova);` |
| 607 | `iommu.unmap(16'h0900, iova);` | `iommu.unmap_for_host(0, 16'h0900, iova);` |
| 641 | `backing_iova = iommu.map(16'h0901, backing_gpa, PAGE_SIZE * 2,` | `backing_iova = iommu.map_for_host(0, 16'h0901, backing_gpa, PAGE_SIZE * 2,` |
| 714 | `iommu.unmap(16'h0901, backing_iova);` | `iommu.unmap_for_host(0, 16'h0901, backing_iova);` |
| 760 | `backing_iova = iommu.map(16'h0902, backing_gpa, 64, DMA_FROM_DEVICE);` | `backing_iova = iommu.map_for_host(0, 16'h0902, backing_gpa, 64, DMA_FROM_DEVICE);` |
| 811 | `iommu.unmap(16'h0902, backing_iova);` | `iommu.unmap_for_host(0, 16'h0902, backing_iova);` |
| 857 | `backing_iova = iommu.map(16'h0903, backing_gpa, 64, DMA_FROM_DEVICE);` | `backing_iova = iommu.map_for_host(0, 16'h0903, backing_gpa, 64, DMA_FROM_DEVICE);` |
| 986 | `backing_iova = iommu.map(16'h0904, backing_gpa, 64, DMA_FROM_DEVICE);` | `backing_iova = iommu.map_for_host(0, 16'h0904, backing_gpa, 64, DMA_FROM_DEVICE);` |
| 1124 | `dirty_iova = iommu.map(16'h0905, dirty_gpa, 64, DMA_FROM_DEVICE);` | `dirty_iova = iommu.map_for_host(0, 16'h0905, dirty_gpa, 64, DMA_FROM_DEVICE);` |
| 1125 | `tx_iova = iommu.map(16'h0905, tx_gpa, 64, DMA_TO_DEVICE);` | `tx_iova = iommu.map_for_host(0, 16'h0905, tx_gpa, 64, DMA_TO_DEVICE);` |
| 1181 | `if (iommu.translate(transport.bdf, tx_iova, tx_payload.size(),` | `if (iommu.translate_for_host(0, transport.bdf, tx_iova, tx_payload.size(),` |
| 1360 | `payload_iova = iommu.map(transport.bdf, payload_gpa, 16, DMA_TO_DEVICE);` | `payload_iova = iommu.map_for_host(0, transport.bdf, payload_gpa, 16, DMA_TO_DEVICE);` |
| 1493 | `payload_translated = iommu.translate(transport.bdf, payload_iova,` | `payload_translated = iommu.translate_for_host(0, transport.bdf, payload_iova,` |

说明：这些测试的 transport/ops 在 HEAD 都没有 PCIe identity，`iommu_host_id()==0`，生产侧映射在 host0。P4-8 给这些 transport 配的也是 host0 identity，所以字面量 `0` 在 P4-8 之后仍然正确。

- [ ] **Step 6: grep 证明测试侧无残留**

```bash
grep -rnE "(iommu[a-z_]*|super)\.(map|unmap|translate|map_fixed|write_from_device|begin_dirty_generation|capture_dirty_generation)\s*\(" --include=*.sv virtio_net_vip examples
```
预期：无输出。前缀限定为 `iommu*`/`super`，是为了排除 P2-3b 新增的 `virtio_dma_buffer_set::map(idx, dir)`（调用形如 `dma_set.map(...)`）。`examples/` 在 HEAD 已无调用，`src/seq/` 已被 P1.1 删除。

- [ ] **Step 7: SYNC + 受影响测试**

```bash
rsync -a --delete --exclude .git --exclude build --exclude logs --exclude csrc ./ ubuntu@10.11.10.53:virtio_priv_run/virtio_work/
```
对 `virtio_unit_test virtio_stress_unit_test virtio_indirect_desc_test virtio_admin_vq_test virtio_migration_dirty_test` 逐个运行 ONE TEST：
```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && TEST=<test_name> ./scripts/vcs.sh > logs/<test_name>.log 2>&1; grep -E "^Error-|UVM_(ERROR|FATAL) [^:]|UVM_(WARNING|ERROR|FATAL) *: *[0-9]+" logs/<test_name>.log | tail -20'
```
预期：三项计数都为 0，`grep -c IOMMU_` 与 Step 1 基线一致。

- [ ] **Step 8: REGRESSION**

```bash
ssh ubuntu@10.11.10.53 'source ~/virtio_priv_run/env.sh && cd ~/virtio_priv_run/virtio_work && ./scripts/strict_regression.sh > ../reg.log 2>&1; grep STRICT_RESULT ../reg.log | grep -v " PASS$"; tail -1 ../reg.log'
```
预期：第一条 grep 无输出，末行为 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 9: Commit**

```bash
git add virtio_net_vip/tests/virtio_unit_test.sv virtio_net_vip/tests/virtio_stress_unit_test.sv \
        virtio_net_vip/tests/virtio_indirect_desc_test.sv virtio_net_vip/tests/virtio_admin_vq_test.sv \
        virtio_net_vip/tests/virtio_migration_dirty_test.sv
git commit -m "refactor: 测试改用 host 限定的 IOMMU 接口"
```

---

### Task P4-2: 删除 IOMMU 非 host 包装与 host0 标量双写

**Files:**
- Modify: `virtio_net_vip/src/iommu/virtio_iommu_model.sv`
  - 头注释 `:10-18`
  - 字段 `:45-48`（`next_iova`）、`:70`（`dirty_tracking_enable`）、`:79-80`（`dirty_generation_counter`、`active_dirty_generation`）
  - `configure_iova_aperture` `:143`
  - `map`/`map_for_host` `:175-206`，`map_in_domain` 注释 `:208`
  - `map_fixed`/`map_fixed_for_host` `:276-317`
  - `unmap`/`unmap_for_host` `:397-425`
  - `translate` `:455-482`
  - `begin_dirty_generation` 与 `begin_dirty_generation_for_host` 的注释/双写 `:704-727`
  - `capture_dirty_generation` `:736-741`
  - `write_from_device` `:827-841`
  - P1.7 之后若仍存在：`snapshot_live_mappings`（`:766-773`）、`get_and_clear_dirty`（`:949-958`）、`get_dirty_page_mapping`（`:963-967`）、`get_dirty_page_records`（`:1002-1006`）、`get_dirty_page_mappings`（`:1025-1030`）、`get_live_mapping`（`:1088-1092`）
  - host0 标量访问器 `:1373-1431`，`reset()` `:1436-1455`
- Modify: `docs/virtio_net_vip_manual.md:219,240,252,275,745-746,749,759,761,763,783,821-823,2324,2326,2328,2335`；`README.md:62`
- Test: `virtio_unit_test`、`virtio_migration_dirty_test`、`virtio_admin_vq_test`、`virtio_real_dut_iova_dma_test`、`virtio_indirect_desc_test`、全回归

**Interfaces:**
- Consumes: P4-1 已完成，不再有非 host 调用者。
- Produces: `map_for_host`、`map_fixed_for_host`、`unmap_for_host`、`translate_for_host`、`validate_for_host`、`write_from_device_for_host`、`begin_dirty_generation_for_host`、`capture_dirty_generation_for_host` 签名不变；语义改为直接进入显式域，不再回落到已删除的虚方法。test double 只能覆写 `*_for_host`。

**host0 标量双写核查结论**（HEAD `:1373-1431`）：
- `get_next_iova`、`get_dirty_generation_counter`、`get_dirty_tracking_enable` 对 host 0 读标量 `next_iova`、`dirty_generation_counter`、`dirty_tracking_enable`，对其他 host 读 `*_by_host` 表。
- 对应的 `set_*` 对 host 0 同时写标量和表。
- `active_dirty_generation`（`:80`）只在 `begin_dirty_generation_for_host` `:726-727` 与 `reset()` 中写入，**没有任何读者**。
- 仓库内对这四个标量的外部引用为 0。`dirty_tracking_enable` 虽是 public 字段，但只出现在历史文档 `docs/superpowers/plans/2026-04-23-virtio-net-driver-vip-plan.md:277`。

删除后行为不变，理由如下：
1. 初值：标量 `next_iova = DEFAULT_IOVA_BASE`；表缺省返回 `iova_base`，而 `iova_base` 初值也是 `DEFAULT_IOVA_BASE`。计数器和开关初值都是 0，与表缺省一致。
2. `configure_iova_aperture` 同时执行 `next_iova = base` 与 `next_iova_by_host.delete()`。删除标量后，表缺省返回新的 `iova_base`，等于 `base`。
3. `reset()` 把标量复位为 `iova_base/0/0` 并清空表；删除后，表缺省给出相同值。
4. 每次 `set_*` 对 host 0 都双写，所以标量与表项始终相同。

`iova_base` 也是 public 字段，但仓库内没有直接赋值：`grep -rnE "\.(iova_base|iova_limit)\s*="` 只命中 `virtio_net_env_config` 的同名字段，不是本模型的字段。

`active_dirty_generation_by_host`（`:82`、`:725`）同样只写不读，但它不属于 host0 双写，本任务不删，记入 Notes。

- [ ] **Step 1: 确认 P1.7 残留且无调用者**

```bash
grep -nE "function .*\b(snapshot_live_mappings|get_and_clear_dirty|get_dirty_page_mapping|get_dirty_page_records|get_dirty_page_mappings|get_live_mapping)\s*\(" virtio_net_vip/src/iommu/virtio_iommu_model.sv
grep -rnwE "snapshot_live_mappings|get_and_clear_dirty|get_dirty_page_mapping|get_dirty_page_records|get_dirty_page_mappings|get_live_mapping" --include=*.sv virtio_net_vip examples | grep -v src/iommu/virtio_iommu_model.sv
```
预期：第二条无输出（HEAD 已验证 0 调用）。第一条列出的函数在 Step 5 一并删除；P1.7 已删的不会出现。

- [ ] **Step 2: 删除 `map`，并让 `map_for_host` 直接进入域实现**

把 HEAD `:175-206`（从 `// map -- Allocate IOVA ...` 注释块起，到 `map_for_host` 的 `endfunction`）整段替换为：
```systemverilog
    // ------------------------------------------------------------------
    // map_for_host -- Allocate IOVA and create a mapping entry
    //
    // Map a GPA in one explicit host/IOMMU requester domain.  Each host owns
    // an independent IOVA namespace, so the returned IOVA may equal an IOVA
    // allocated by another host without aliasing its mapping.  Test doubles
    // that need to observe or fail allocations override this method.
    // ------------------------------------------------------------------
    virtual function bit [63:0] map_for_host(int unsigned host_id,
                            bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        return map_in_domain(host_id, bdf, gpa, size, dir, file, line);
    endfunction
```
`map_in_domain` 注释首行（`:208`）：`// map()/map_for_host() 的公共实现：在指定 {host_id, BDF} 域内分配一段页` → `// map_for_host() 的实现：在指定 {host_id, BDF} 域内分配一段页`。

- [ ] **Step 3: 删除 `map_fixed`、`unmap`、`translate`**

`map_fixed`：`:276-285` 的注释块保留，首行 `// map_fixed -- Create a mapping at a previously assigned stable IOVA` 改为 `// map_fixed_for_host -- Create a mapping at a previously assigned stable IOVA`。把 HEAD `:286-317`（从 `virtual function bit [63:0] map_fixed(` 到 `map_fixed_for_host` 的 `endfunction`，含中间 `:298-299` 两行中文注释）替换为：
```systemverilog
    virtual function bit [63:0] map_fixed_for_host(int unsigned host_id,
                                          bit [15:0] bdf,
                                          bit [63:0] gpa,
                                          int unsigned size,
                                          dma_dir_e dir,
                                          bit [63:0] requested_iova,
                                          string file = "",
                                          int line = 0);
        return map_fixed_in_domain(host_id, bdf, gpa, size, dir,
                                   requested_iova, file, line);
    endfunction
```
`unmap`：把 HEAD `:397-425`（从 `// unmap -- Remove a mapping` 注释块起，到 `unmap_for_host` 的 `endfunction`）替换为：
```systemverilog
    // ------------------------------------------------------------------
    // unmap_for_host -- Remove a mapping from one host requester domain
    //
    // Moves the entry to unmap_history for use-after-unmap detection.
    // Reports an error if the mapping is not found.
    // ------------------------------------------------------------------
    virtual function void unmap_for_host(int unsigned host_id,
                        bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        unmap_in_domain(host_id, bdf, iova, file, line);
    endfunction
```
`translate`：
- 删除 HEAD `:470-477`（`function bit translate(...)` 到它的 `endfunction`）。
- 上方注释块（`:455-469`）首行 `// translate -- Resolve IOVA to GPA with full checking` 改为 `// translate_for_host -- Resolve IOVA to GPA with full checking`，并删除重复的残行 `//   -> range check -> permission check -> compute GPA.`（`:467`）。
- `:479` 中文注释开头的“translate 的 host-qualified 入口：”改为“设备读翻译入口：”，其余不变。
- `translate_for_host` 的错误消息文本（`:496`，含 `use write_from_device()`）保持不变，`virtio_migration_dirty_test.sv:475` 的 catcher 依赖它。

- [ ] **Step 4: 删除脏页代际与设备写的非 host 包装**

- 删除 HEAD `:704-709`：`// Start a fresh migration generation ...` 注释与 `begin_dirty_generation()`。把这段英文注释移到 `begin_dirty_generation_for_host` 上方。
- `:711-714` 中文注释末句“返回新代际号；host 0 同时维护 legacy 全局字段以兼容旧接口。”改为“返回新代际号。”
- 删除 `:726-727`：
```systemverilog
        if (host_id == 0)
            active_dirty_generation = next_generation;
```
- 删除 HEAD `:739-741` 的 `capture_dirty_generation()`，上方英文注释 `:736-738` 保留给 `_for_host` 版本。
- 删除 HEAD `:832-841` 的 `write_from_device(...)`，上方英文注释 `:827-831` 保留并紧贴 `write_from_device_for_host`。

- [ ] **Step 5: 删除 Step 1 列出的残留非 host 查询包装**

对 Step 1 第一条 grep 仍列出的每个函数，删除整个 `function ... endfunction`。HEAD 位置：`snapshot_live_mappings` `:766-773`、`get_and_clear_dirty` `:949-958`（连同上方 2 行注释）、`get_dirty_page_mapping` `:963-967`、`get_dirty_page_records` `:1002-1006`、`get_dirty_page_mappings` `:1025-1030`、`get_live_mapping` `:1088-1092`。紧随其后的 `_for_host` 版本及其注释保留，英文注释移到 `_for_host` 版本上方。

- [ ] **Step 6: 删除 host0 标量与双写**

字段：删除 `:45`、`:70`、`:79`、`:80`：
```systemverilog
    protected bit [63:0] next_iova = DEFAULT_IOVA_BASE;
    bit dirty_tracking_enable = 0;
    protected bit [63:0] dirty_generation_counter = 0;
    protected bit [63:0] active_dirty_generation = 0;
```
`:46-47` 注释改为：
```systemverilog
    // IOVA spaces are independent per host/IOMMU requester domain.  A host
    // without an entry has not allocated yet and starts at iova_base.
```
`configure_iova_aperture`：删除 `:143` 的 `next_iova = base;`。

HEAD `:1373-1431` 的六个访问器整段替换为：
```systemverilog
    // 读取指定 Host 的 bump 分配游标；未分配过的 Host 懒返回 iova_base。
    protected function bit [63:0] get_next_iova(int unsigned host_id);
        if (!next_iova_by_host.exists(host_id))
            return iova_base;
        return next_iova_by_host[host_id];
    endfunction

    // 写指定 Host 的 bump 游标。
    protected function void set_next_iova(
        int unsigned host_id, bit [63:0] value
    );
        next_iova_by_host[host_id] = value;
    endfunction

    // 读指定 Host 的脏页代际计数；未初始化的 Host 视为 0（从未开启过代际）。
    protected function bit [63:0] get_dirty_generation_counter(
        int unsigned host_id
    );
        if (!dirty_generation_counter_by_host.exists(host_id))
            return 0;
        return dirty_generation_counter_by_host[host_id];
    endfunction

    // 写指定 Host 的代际计数。
    protected function void set_dirty_generation_counter(
        int unsigned host_id, bit [63:0] value
    );
        dirty_generation_counter_by_host[host_id] = value;
    endfunction

    // 查询指定 Host 是否开启脏页跟踪；表中无记录时缺省视为关闭。
    protected function bit get_dirty_tracking_enable(int unsigned host_id);
        return dirty_tracking_enable_by_host.exists(host_id) &&
               dirty_tracking_enable_by_host[host_id];
    endfunction

    // 设置指定 Host 的脏页跟踪开关。
    protected function void set_dirty_tracking_enable(
        int unsigned host_id, bit enable
    );
        dirty_tracking_enable_by_host[host_id] = enable;
    endfunction
```
`reset()`：删除 `:1442-1444` 与 `:1449`：
```systemverilog
        dirty_tracking_enable = 0;
        dirty_generation_counter = 0;
        active_dirty_generation = 0;
        next_iova          = iova_base;
```

- [ ] **Step 7: 头注释与文档**

`virtio_iommu_model.sv:10-18` 改为：
```systemverilog
//   - Host-qualified 域隔离：requester 身份是 {host_id, BDF}，
//     map/unmap/translate/validate 全部以 *_for_host() 形式显式携带
//     host_id——不同 Host 下相同 BDF 互不可见，这是多 Host DPU 场景的核心语义；
//   - GPA↔IOVA 双向翻译：可配置 aperture（configure_iova_aperture），
//     IOVA 分配策略 IOMMU_IOVA_RANDOM（默认，随机化布局）/ FIRST_FIT
//     （调试用），并支持 map_fixed_for_host() 在指定 IOVA 重建映射（迁移恢复）；
//   - 设备写唯一入口 write_from_device_for_host()：权限检查与脏页
//     记录绑定在同一路径，REAL_DUT 的 IOVA proxy 即走此入口；
//   - 迁移支撑：4KB 粒度脏页跟踪 + 代际快照
//     （begin/capture_dirty_generation_for_host）、live mapping 快照与校验；
```
`docs/virtio_net_vip_manual.md`：
- `:219`、`:252`：` iommu.map() --> GPA -> IOVA 映射` → ` iommu.map_for_host() --> GPA -> IOVA 映射`。
- `:240`、`:275`：`iommu.unmap()` → `iommu.unmap_for_host()`。
- `:745-746`：删除“旧 API 和”四个字，句子变为“生产路径从冻结的 `dpu_pcie_function_id_t.domain.host_id` 取得 Host；未绑定 PCIe identity 的 standalone 对象兼容地落到 host0。”（后半句由 P4-8 改写）。
- `:749`：`` 不通过 `iommu.map()`。 `` → `` 不通过 `iommu.map_for_host()`。 ``
- 删除 4.4.1 表中 `map()`、`unmap()`、`translate()` 三行（`:759`、`:761`、`:763`）。
- `:783`：`` `translate()` 按以下顺序执行检查： `` → `` `translate_for_host()` 按以下顺序执行检查： ``
- `:821-823`：删除“`begin_dirty_generation()` / `capture_dirty_generation()` 和旧 dirty helper 仍表示 host0。”，保留“Host-scoped bitmap、mapping snapshot 和 generation state 不会因相同 GPA page number 而在不同 Host 之间合并。”
- 9.2 表：删除 `map`、`unmap`、`translate` 三行（`:2324`、`:2326`、`:2328`）。若 Step 5 删除了 `get_and_clear_dirty`，同时删除 `:2335` 行。

`README.md:62`：`` 这里的 `iommu.map` 只管理 `` → `` 这里的 `iommu.map_for_host` 只管理 ``。

- [ ] **Step 8: grep 证明**

```bash
grep -nE "function .*\b(map|unmap|translate|map_fixed|write_from_device|begin_dirty_generation|capture_dirty_generation|snapshot_live_mappings|get_and_clear_dirty|get_dirty_page_mapping|get_dirty_page_records|get_dirty_page_mappings|get_live_mapping)\s*\(" virtio_net_vip/src/iommu/virtio_iommu_model.sv
grep -nE "\b(next_iova|dirty_tracking_enable|dirty_generation_counter|active_dirty_generation)\b" virtio_net_vip/src/iommu/virtio_iommu_model.sv
grep -nE "\b(map|unmap|map_fixed)\s*\(\s*bdf" virtio_net_vip/src/iommu/virtio_iommu_model.sv
grep -nE "iommu\.(map|unmap|translate)\(\)|begin_dirty_generation\(\)|capture_dirty_generation\(\)" README.md docs/virtio_net_vip_manual.md
```
预期：四条都无输出。`*_by_host` 名称因 `\b` 边界不会被第二条匹配。

- [ ] **Step 9: SYNC + 受影响测试**

SYNC（同 P4-1 的 rsync 命令）后，对 `virtio_unit_test virtio_migration_dirty_test virtio_admin_vq_test virtio_real_dut_iova_dma_test virtio_indirect_desc_test` 逐个运行 ONE TEST。预期全部 0 WARNING/ERROR/FATAL。`virtio_admin_vq_test` 的 map-failure 用例（`fail_on_map_attempt = 2`，`:1282`）仍报 `admin_vq_submit: response DMA map failed`，并被 catcher 吸收。

- [ ] **Step 10: REGRESSION**（命令同 P4-1 Step 8）。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 11: Commit**

```bash
git add virtio_net_vip/src/iommu/virtio_iommu_model.sv docs/virtio_net_vip_manual.md README.md
git commit -m "refactor: 删除 IOMMU 非 host 接口与 host0 标量双写"
```

---

### Task P4-3: fixture 支持多 PF 端点镜像、completion 超时与按 BDF 取 Function

**Files:**
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`
  - 字段：在 `:29` 之后新增 `vio_pf_count`、`pcie_cpl_timeout_ns`
  - `new()` `:83-96`
  - `build_phase`：声明区 `:99-101`、device builder 段 `:105-116`、`pcie_cfg.cpl_timeout_ns` `:217`
  - 新增 `function_by_bdf()`，放在 `pcie_env()` 访问器 `:518-520` 之后
  - `install_endpoint_image()` `:1132-1133`（`return 1;` 之前）
- Test: `virtio_real_driver_flow_test`、`virtio_real_driver_multiqueue_test`、`virtio_real_driver_rx_test`（默认值下必须零行为变化）。新功能由 P4-5 的 `virtio_dual_test` 覆盖。

**Interfaces:**
- Consumes: `virtio_test_device_builder::add_pf/add_real_dut_bars/allow_vio_service/add_fixed_vio_request/select_af`（`virtio_test_device_builder.sv:107-196`）、`dpu_device_snapshot::get_bar()`、`dpu_dut_caps.max_pfs_per_host`（public 字段，默认 4）。P3-1 对 fixture 的 execution_profile 改造不触及本任务的锚点。
- Produces:
  - `int unsigned vio_pf_count;`：默认 1。必须在 fixture 的 `build_phase` 之前设置，也就是在测试 `build_phase` 中 create 之后立即设置。
  - `int pcie_cpl_timeout_ns;`：默认 100000，与 HEAD `:217` 相同。
  - `function virtio_function_instance function_by_bdf(input bit [15:0] bdf);`
  - `install_endpoint_image()` 额外为非 AF 的 VIO Function 在其 BAR0 lease 写入 common-config 缺省值与 ISR 字节。配置空间仍只有一份，各 Function 的 Fabric discovery 自行编程 BAR。

- [ ] **Step 1: 新增字段与构造默认值**

在 `:29` `bit real_dut_host_mem_responder_enable;` 之后插入：
```systemverilog
    // 中文说明：snapshot 中声明的 host0 VIO PF 数量（默认 1，即 AF 本身）。
    // 需要多个 Function 共享同一 PCIe EP 模型的测试，在 create 之后、本组件
    // build_phase 之前设置；PF 0 始终是 AF。
    int unsigned                vio_pf_count;
    // PCIe completion 超时（ns）。默认值与原 fixture 相同；会长时间推进仿真
    // 时间的测试可在 build_phase 之前放宽。
    int                         pcie_cpl_timeout_ns;
```
`new()` 中，在 `real_dut_host_mem_responder_enable = 0;`（`:95`）之后插入：
```systemverilog
        vio_pf_count = 1;
        pcie_cpl_timeout_ns = 100000;
```

- [ ] **Step 2: build_phase 按 `vio_pf_count` 声明 PF**

声明区（`:99-101`）在 `dpu_function_cfg pf_cfg;` 之后加一行：
```systemverilog
        dpu_function_cfg af_cfg;
```
把 `:105-116` 替换为：
```systemverilog
        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        if ((vio_pf_count == 0) ||
            (vio_pf_count > device_builder.device_cfg.dut_caps.max_pfs_per_host)) begin
            `uvm_fatal("REAL_FLOW", $sformatf(
                "vio_pf_count=%0d is outside 1..%0d", vio_pf_count,
                device_builder.device_cfg.dut_caps.max_pfs_per_host))
            return;
        end
        void'(device_builder.add_host_domain(0, 0));
        af_cfg = null;
        for (int unsigned pf_id = 0; pf_id < vio_pf_count; pf_id++) begin
            pf_cfg = device_builder.add_pf(0, pf_id, 0);
            device_builder.add_real_dut_bars(pf_cfg);
            void'(device_builder.allow_vio_service(pf_cfg));
            vio_devices.push_back(pf_cfg.key);
            if (af_cfg == null)
                af_cfg = pf_cfg;
        end
        // The shared real-flow fixture provisions two queue pairs per VIO
        // PF so callers can exercise the normal RX0/TX1 and RX2/TX3 layout.
        // Individual tests may still set up only the queues they need.
        void'(device_builder.add_fixed_vio_request(0, vio_devices,
                                                    2 * vio_pf_count));
        device_builder.select_af(af_cfg);
```
`:217`：`pcie_cfg.cpl_timeout_ns = 100000;` → `pcie_cfg.cpl_timeout_ns = pcie_cpl_timeout_ns;`

- [ ] **Step 3: 新增 `function_by_bdf()`**

在 `function pcie_tl_env pcie_env(); ... endfunction`（`:518-520`）之后插入：
```systemverilog
    // 按冻结 snapshot 分配的 BDF 返回 env 中的 Function；未找到返回 null。
    // 供需要直接驱动 transport 寄存器的测试使用，身份仍只来自 snapshot。
    function virtio_function_instance function_by_bdf(input bit [15:0] bdf);
        if (m_virtio_env == null)
            return null;
        foreach (m_virtio_env.function_instances[index]) begin
            if ((m_virtio_env.function_instances[index] != null) &&
                (m_virtio_env.function_instances[index].bdf == bdf))
                return m_virtio_env.function_instances[index];
        end
        return null;
    endfunction
```

- [ ] **Step 4: 为非 AF Function 写入端点镜像**

在 `install_endpoint_image()` 中 `ep_drv.mem_space[common_bar.base + ISR_OFFSET] = 8'h00;`（`:1132`）与 `return 1;`（`:1133`）之间插入：
```systemverilog
        // Additional VIO PFs share this EP model's single configuration
        // space; each function's Fabric discovery reprograms the BAR
        // registers from its own lease before scanning capabilities.  Only
        // the per-function common-config defaults live at distinct BAR0
        // lease addresses and must be installed here.
        foreach (m_virtio_env.function_instances[index]) begin
            virtio_function_instance peer;
            dpu_bar_pair_lease_t peer_common_bar;

            peer = m_virtio_env.function_instances[index];
            if ((peer == null) || !peer.pcie_id_valid ||
                (peer.bdf == m_pcie_id.bdf))
                continue;
            if (!m_device_snapshot.get_bar(peer.function_key,
                    DPU_BAR_DEVICE_MEMORY, peer_common_bar, why))
                return 0;
            if ((peer_common_bar.size < (DEVICE_OFFSET + DEVICE_LENGTH)) ||
                (peer_common_bar.size <= ISR_OFFSET)) begin
                why = $sformatf(
                    "snapshot BAR0 lease of BDF 0x%04h is too small for the virtio image",
                    peer.bdf);
                return 0;
            end
            write_common_defaults(ep_drv, peer_common_bar.base,
                                  virtio_cfg.default_num_pairs * 2);
            ep_drv.mem_space[peer_common_bar.base + ISR_OFFSET] = 8'h00;
        end
```
`vio_pf_count == 1` 时 env 只有 AF 一个 Function，循环全部 `continue`，镜像与 HEAD 完全相同。

- [ ] **Step 5: SYNC + 三个 real-driver 测试**

SYNC 后对 `virtio_real_driver_flow_test virtio_real_driver_multiqueue_test virtio_real_driver_rx_test` 逐个运行 ONE TEST。预期 0 WARNING/ERROR/FATAL，与改动前一致。

- [ ] **Step 6: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 7: Commit**

```bash
git add virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv
git commit -m "test: real-driver fixture 支持多 PF 端点镜像与按 BDF 取 Function"
```

---

### Task P4-4: `virtio_full_integration_test` 迁移到 snapshot/fabric 流程

**Files:**
- Modify: `virtio_net_vip/tests/virtio_full_test.sv`（HEAD 845 行）
  - 删除：`setup_ep_virtio_config` 及注释块 `:163-329`、`init_ep_mmio_regs` `:331-389`、`ep_device_behavior` `:391-452`、EP Memory Helpers `:806-843`
  - 改写：头注释 `:1-11`、字段 `:19-35`、`build_phase` `:52-92`、`connect_phase` `:97-114`、`run_phase` `:126-130`、`test_full_init` 的步骤 1–2 `:458,463-494`
- Modify: `filelists/tests.f`：把 `:45` 的 fixture 行移到 `:19` 之后，使它先于 `virtio_full_test.sv`（`:34`）编译
- Test: `virtio_full_integration_test`

**Interfaces:**
- Consumes:
  - P4-3：`virtio_real_driver_flow_fixture.function_by_bdf()`，以及已有的 `function_bdf()`、`build_flow(output string why)`、`execution_mode()`、`pcie_env()`、public 字段 `tlm_adapter`。
  - P3-2：`virtio_pci_transport::discover_and_init_bars()` 是唯一发现入口，委托 `discovery_strategy`。env Function 由 `configure_fabric_managed()` 安装 `virtio_fabric_preconfigured_discovery`。
  - transport 寄存器任务（HEAD 签名不变）：`reset_device`、`write_device_status`、`negotiate_features`、`read_device_status`、`read_num_queues`、`select_queue`、`read_queue_num_max`、`read_queue_notify_off`；以及 `bar.read_reg/write_reg/config_read/config_write`。
- Produces: 测试不再调用 `bar.enumerate_bars()`（P4-6 删除的前提之一）。测试类名 `virtio_full_integration_test` 不变，manifest 不需改动。

迁移映射（全部断言保留）：

| 原检查 | 迁移后 |
|---|---|
| Test 1：`enumerate_bars` + 手写 EP 镜像 + `cap_mgr.discover_capabilities()`，断言 common/notify capability 存在 | 改为 `transport.discover_and_init_bars()`：编程 Fabric lease 并发现 capability，镜像来自 snapshot。断言不变 |
| Test 1：reset → ACK → DRIVER → 协商 → FEATURES_OK 回读断言 → num_queues → 3 个队列查询 → DRIVER_OK 回读断言 | 原样保留（HEAD `:496-588`） |
| Test 2：BAR0 上 1000 个 MMIO TLP，断言 `read_errors == 0` | 原样保留。BAR0 改为 snapshot lease（32 MB），偏移 `0x1000+`、`0x3000+` 都在 lease 内 |
| Test 3：`pcie_env.bw_shaper` 带宽整形 | 原样保留（`pcie_env = flow.pcie_env()`） |
| Test 4：VID/DID = `1AF4/1041`、Command 寄存器写回读、背靠背读、Q_SELECT RAW | 原样保留。fixture 的 `install_endpoint_image` 调用同样的 `init_type0_header(16'h1AF4, 16'h1041, ...)` |

已知非等价点（Step 6 确认点逐项核对）：
- (a) PCIe env 配置改由 fixture 提供：`scb_enable=1`（原为 0）、`use_unified_mem=1`。
- (b) 新增 virtio monitor/observer/协议断言观察这些寄存器访问。原测试的 `driver_agent` 为 PASSIVE，也没有接 observer。
- (c) 去掉了 `ep_device_behavior` 对 DFSELECT/Q_SELECT 的回显，设备特性改由 fixture 镜像提供（`DF = 0x1`）。`negotiated` 只打印，不断言。
- (d) Test 2 写入的 BAR0 `0x1000` 在新布局中是 ISR；原布局中是 notify。

- [ ] **Step 1: 迁移前基线**

SYNC 后运行 ONE TEST（`virtio_full_integration_test`），然后保存日志：
```bash
ssh ubuntu@10.11.10.53 'cp ~/virtio_priv_run/virtio_work/logs/virtio_full_integration_test.log ~/virtio_priv_run/full_integration.pre_p4.log; grep -E "Test Results|OVERALL|Test [0-9] PASSED" ~/virtio_priv_run/full_integration.pre_p4.log'
```
预期：`Test Results: 4/4 passed, 0 failed`，以及 `OVERALL: PASS -- All tests passed`。

- [ ] **Step 2: 调整 filelist 编译顺序**

`filelists/tests.f`：删除 `:45` 的 `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`，在 `:19` 的 `virtio_net_vip/tests/virtio_shared_mem_fixture.sv` 之后插入同一行。原因：`$unit` 中的类型必须先声明后使用。fixture 只依赖已编译的 package 和更早列出的 `virtio_test_device_builder.sv`。

- [ ] **Step 3: 改写头注释、字段、build/connect/run**

头注释 `:1-5` 改为：
```systemverilog
// ============================================================================
// virtio_full_test.sv
//
// Full integration test on the snapshot-derived Fabric flow.  The endpoint
// image, BDF and BAR leases come from virtio_real_driver_flow_fixture (frozen
// dpu-common snapshot); discovery programs the leased BARs instead of running
// PCI BAR enumeration.
// 中文说明：端点镜像、BDF 与 BAR 租约全部来自 fixture 冻结 snapshot；测试保留
// 原有四项检查（初始化、大流量、带宽整形、协议完整性）。
// ============================================================================
```
删除 `:10` 的 `import host_mem_pkg::*;`（不再使用 Host memory 类型）。

字段 `:19-35` 替换为：
```systemverilog
    // Snapshot-derived PCIe/virtio flow (one host0 VIO PF)
    virtio_real_driver_flow_fixture flow;

    // Handles borrowed from the fixture
    pcie_tl_env pcie_env;
    virtio_pci_transport transport;
    virtio_tlm_completion_adapter tlm_adapter;
```
`build_phase`（`:52-92`）替换为：
```systemverilog
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
    endfunction
```
`connect_phase`（`:97-114`）替换为：
```systemverilog
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        pcie_env = flow.pcie_env();
        tlm_adapter = flow.tlm_adapter;
    endfunction
```
`run_phase` 中 `:126-130`：
```systemverilog
// old
        // Wait for reset to deassert
        #200ns;

        // Setup EP with virtio config
        setup_ep_virtio_config();
// new
        // Wait for reset to deassert
        #200ns;

        // Resolve the snapshot function and its endpoint image
        bind_snapshot_function();
```
在 `run_phase` 之前新增：
```systemverilog
    // ========================================================================
    // Resolve the fixture's snapshot function (BDF/BAR leases are never test
    // constants) and apply the original fast wait policy to its transport.
    // ========================================================================
    virtual task bind_snapshot_function();
        virtio_function_instance function_instance;
        string why;

        if (!flow.build_flow(why))
            `uvm_fatal("FULL_TEST", {"fixture flow is not ready: ", why})
        if (flow.execution_mode() != VIRTIO_EXEC_MODEL)
            `uvm_fatal("FULL_TEST", "full integration test requires MODEL execution mode")
        if ((pcie_env == null) || (tlm_adapter == null))
            `uvm_fatal("FULL_TEST", "fixture did not expose its PCIe env and completion adapter")
        function_instance = flow.function_by_bdf(flow.function_bdf());
        if ((function_instance == null) || (function_instance.transport == null) ||
            (function_instance.transport.wait_pol == null))
            `uvm_fatal("FULL_TEST", "fixture did not expose the snapshot function transport")
        transport = function_instance.transport;

        // 4. Configure wait policy for fast simulation
        transport.wait_pol.default_poll_interval_ns = 100;
        transport.wait_pol.reset_timeout_ns = 10000;
        transport.wait_pol.queue_reset_timeout_ns = 10000;
        transport.wait_pol.max_poll_attempts = 100;
        `uvm_info("FULL_TEST", $sformatf(
            "Snapshot function BDF=0x%04h bound", transport.bdf), UVM_LOW)
    endtask
```
（P3-1 若把 `execution_mode()` 改成返回 profile 对象，这里按 P3-1 的接口改为等价的 “是否 MODEL” 判断。）

- [ ] **Step 4: 删除手写端点镜像与 EP 内存辅助函数**

删除 HEAD `:163-452`：从 `// Setup EP Config Space with Virtio Capabilities` 注释块起，到 `ep_device_behavior` 的 `endtask`。
删除 HEAD `:806-843`：从 `// EP Memory Helpers` 注释块起，到 `read_ep_mem32` 的 `endfunction`。

- [ ] **Step 5: Test 1 的步骤 1–2 改为 Fabric 发现**

`test_full_init` 中删除 HEAD `:458` 的 `bit [63:0] bar0_base;`，把 `:463-494` 替换为：
```systemverilog
        // Step 1: Fabric BAR programming and capability discovery.  BAR
        // placement comes from the frozen snapshot lease; no enumeration.
        `uvm_info("FULL_TEST", "Step 1: Fabric BAR programming and capability discovery", UVM_LOW)
        transport.discover_and_init_bars();
        `uvm_info("FULL_TEST", $sformatf("BAR0 lease at 0x%016h",
            transport.bar.bar_base[0]), UVM_LOW)

        if (!transport.cap_mgr.common_cfg_found) begin
            `uvm_error("FULL_TEST", "Common Config capability not found!")
            tests_failed++;
            return;
        end
        if (!transport.cap_mgr.notify_found) begin
            `uvm_error("FULL_TEST", "Notify capability not found!")
            tests_failed++;
            return;
        end
        `uvm_info("FULL_TEST", "Capabilities discovered successfully", UVM_LOW)
```
以下文本不变：HEAD `:496-588`（从 Step 3 起的 reset/ACK/DRIVER/协商/FEATURES_OK/num_queues/队列查询/DRIVER_OK）、Test 2–4（`:594-784`）、`report_results`（`:789-804`）。它们引用的 `transport`、`pcie_env`、`tlm_adapter` 现在都是从 fixture 借来的句柄。

- [ ] **Step 6: SYNC + 运行 + 确认点**

SYNC 后运行 ONE TEST（`virtio_full_integration_test`），然后：
```bash
ssh ubuntu@10.11.10.53 'grep -E "Test Results|OVERALL|Test [0-9] PASSED" ~/virtio_priv_run/virtio_work/logs/virtio_full_integration_test.log; grep -nE "UVM_(WARNING|ERROR|FATAL) " ~/virtio_priv_run/virtio_work/logs/virtio_full_integration_test.log | head -20'
```
预期：`Test Results: 4/4 passed, 0 failed`、`OVERALL: PASS -- All tests passed`，三项计数为 0。

**确认点（spec 风险条款）：** 如果出现任何新的 WARNING/ERROR/FATAL，或任一子测试结果与 Step 1 基线不同（典型来源见上文非等价点 a–d，例如 PCIe scoreboard、virtio monitor 对 ISR 或 Q_SELECT=0xA5 访问的报告），**立即停止**，不得修改断言去迁就实现。把差异日志和下列候选方案交给用户，确认测试意图后再继续：
1. 把 Test 2/3 的 scratch 写偏移从 `0x1000+` 改到 BAR0 中不属于任何 capability 的 `0x3000+` 区域；
2. 给 fixture 增加 `pcie_scb_enable` 旋钮，本测试设为 0，恢复原 PCIe 配置；
3. 保持原样，把相应 monitor 报告当作真实协议问题处理。

- [ ] **Step 7: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: Commit**

```bash
git add virtio_net_vip/tests/virtio_full_test.sv filelists/tests.f
git commit -m "test: full integration 测试改走 snapshot 端点镜像与 Fabric 发现"
```

---

### Task P4-5: `virtio_dual_test` 迁移到 snapshot/fabric 流程

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dual_test.sv`（HEAD 1977 行）
  - 改写：头注释 `:9-11`、字段 `:109-136`、`build_phase` `:206-257`、`connect_phase` `:271-303`、`run_phase` `:317-319`、`init_both_vips` `:619-684`
  - 删除：`setup_ep_virtio_config` `:359-508`、`init_ep_mmio_regs` `:510-561`、`ep_device_behavior` `:563-617`、EP Memory Helpers `:1936-1973`
- Test: `virtio_dual_test`

**Interfaces:**
- Consumes: P4-3 的 `vio_pf_count`、`pcie_cpl_timeout_ns`、`function_by_bdf()`；P4-4 调整后的 filelist 顺序；P3-2 的 `discover_and_init_bars()`。
- Produces: 测试不再调用 `bar.enumerate_bars()`；类名 `virtio_dual_test` 不变。

HEAD 核实的关键事实：
- dual 测试中只有 `init_both_vips()`（`:622-684`）使用 PCIe。
- Test 1–5（`test_bidirectional_traffic`、`test_variable_sizes`、`test_queue_wrap_stress`、`test_bandwidth_control`）只使用 `mem_a/mem_b`、`iommu_a/iommu_b`、`barrier_*`、`err_inj_*`、`wait_pol_*` 上的独立 `split_virtqueue`（BDF 字面量 `16'h0100/16'h0200`）和 `bw_mon`，不访问 transport 或 PCIe。
- `vq_mgr_*`、`ops_*`、`fsm_*`、`binding_function_*` 只在 `connect_phase` 的绑定中使用（`:300` 之后无引用）。

因此迁移只改初始化部分，带宽控制等断言代码一行不动。

迁移方式：
- fixture 以 `vio_pf_count = 2` 声明两个 host0 PF：PF0 为 AF，即 VIP A；PF1 为 VIP B。两者共享一个 `pcie_tl_env`/EP 模型，与原测试的 “shared device” 一致。
- 两个 PF 各自用 snapshot lease 完成 Fabric 发现，再执行测试自带的 `run_virtio_init()`。
- 原测试中 VIP B 复制 VIP A 的 BAR0；迁移后 VIP B 使用自己的 lease 和 P4-3 安装的镜像。
- PCIe completion 超时设为 `pcie_cpl_timeout_ns = 500_000_000`，保持原值（HEAD `:226`）。

- [ ] **Step 1: 迁移前基线**

SYNC 后运行 ONE TEST（`virtio_dual_test`），然后：
```bash
ssh ubuntu@10.11.10.53 'cp ~/virtio_priv_run/virtio_work/logs/virtio_dual_test.log ~/virtio_priv_run/dual.pre_p4.log; grep -E "Test Results|OVERALL|PASSED|FAILED|data_ok|data_err" ~/virtio_priv_run/dual.pre_p4.log | tail -40'
```
预期：`OVERALL: PASS -- All dual VIP tests passed`。保存所有子测试的计数行，供 Step 6 对比。

- [ ] **Step 2: 头注释与字段**

`:9-11` 替换为：
```systemverilog
// Architecture:
//   VIP A / VIP B 的 PCIe 身份（BDF、BAR lease）来自 fixture 冻结 snapshot 中
//   的两个 host0 PF，共享同一个 pcie_tl_env/EP 模型，经 Fabric 预配置流程完成
//   初始化；数据面互打使用各自独立的 Host memory/IOMMU（队列 BDF 0x0100/0x0200）。
```
字段 `:109-136` 替换为：
```systemverilog
    // Snapshot-derived shared PCIe/virtio flow (two host0 VIO PFs)
    virtio_real_driver_flow_fixture flow;

    // Borrowed from the fixture
    virtio_tlm_completion_adapter tlm_adapter;

    // ---- VIP A components ----
    virtio_pci_transport  transport_a;
    virtio_wait_policy    wait_pol_a;
    host_mem_manager      mem_a;
    virtio_iommu_model    iommu_a;
    virtio_memory_barrier_model barrier_a;
    virtqueue_error_injector    err_inj_a;

    // ---- VIP B components ----
    virtio_pci_transport  transport_b;
    virtio_wait_policy    wait_pol_b;
    host_mem_manager      mem_b;
    virtio_iommu_model    iommu_b;
    virtio_memory_barrier_model barrier_b;
    virtqueue_error_injector    err_inj_b;
```

- [ ] **Step 3: build_phase / connect_phase / run_phase**

`build_phase`：删除 `:206` 的 `pcie_tl_env_config pcie_cfg;`，把 `:209-257` 替换为：
```systemverilog
        // Two snapshot PFs share one PCIe EP model; the fixture owns the TLM
        // completion adapter, the endpoint images and the BAR leases.
        flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
        flow.vio_pf_count = 2;
        // 500ms: accommodate bandwidth test time advances
        flow.pcie_cpl_timeout_ns = 500_000_000;

        // 5. Create VIP A data-plane components
        wait_pol_a  = virtio_wait_policy::type_id::create("wait_pol_a");
        mem_a       = host_mem_manager::type_id::create("mem_a");
        iommu_a     = virtio_iommu_model::type_id::create("iommu_a");
        barrier_a   = virtio_memory_barrier_model::type_id::create("barrier_a");
        err_inj_a   = virtqueue_error_injector::type_id::create("err_inj_a");

        // 6. Create VIP B data-plane components
        wait_pol_b  = virtio_wait_policy::type_id::create("wait_pol_b");
        mem_b       = host_mem_manager::type_id::create("mem_b");
        iommu_b     = virtio_iommu_model::type_id::create("iommu_b");
        barrier_b   = virtio_memory_barrier_model::type_id::create("barrier_b");
        err_inj_b   = virtqueue_error_injector::type_id::create("err_inj_b");
```
`:259-264` 的 perf monitor 创建保持不变；如果 P2.8 已把 `bw_mon` 改为 `virtio_perf_monitor`，以 P2.8 之后的文本为准。

`connect_phase`：删除 `:274-282`（VIP A 绑定）与 `:289-297`（VIP B 绑定），在 `super.connect_phase(phase);` 之后插入：
```systemverilog
        tlm_adapter = flow.tlm_adapter;
```
保留 `:284-287`、`:299-302` 的 `wait_pol_a/b` 设置；注释 `// ---- Wire VIP A ----`、`// ---- Wire VIP B ----` 分别改为 `// ---- VIP A wait policy ----`、`// ---- VIP B wait policy ----`。

`run_phase` `:317-319`：
```systemverilog
// old
        // Setup EP and run full init for both VIPs
        setup_ep_virtio_config();
        init_both_vips();
// new
        // Run full init for both VIPs on the snapshot-derived endpoint
        init_both_vips();
```

- [ ] **Step 4: 删除手写端点镜像与 EP 内存辅助函数**

删除 HEAD `:359-617`：从 `// Setup EP Config Space` 注释块起，到 `ep_device_behavior` 的 `endtask`。
删除 HEAD `:1936-1973`：从 `// EP Memory Helpers` 注释块起，到 `read_ep_mem32` 的 `endfunction`。

- [ ] **Step 5: 改写 `init_both_vips`**

HEAD `:619-684` 整段替换为：
```systemverilog
    // ========================================================================
    // Init Both VIPs (sequentially through the shared snapshot-derived EP)
    // ========================================================================
    virtual task init_both_vips();
        virtio_net_env           env;
        virtio_function_instance function_a;
        virtio_function_instance function_b;
        string                   why;

        if (!flow.build_flow(why))
            `uvm_fatal("DUAL_TEST", {"fixture flow is not ready: ", why})
        if (flow.execution_mode() != VIRTIO_EXEC_MODEL)
            `uvm_fatal("DUAL_TEST", "dual VIP test requires MODEL execution mode")
        env = flow.virtio_env();
        function_a = flow.function_by_bdf(flow.function_bdf());
        function_b = null;
        foreach (env.function_instances[index]) begin
            if ((env.function_instances[index] != null) &&
                (env.function_instances[index] != function_a)) begin
                function_b = env.function_instances[index];
                break;
            end
        end
        if ((function_a == null) || (function_b == null) ||
            (function_a.transport == null) || (function_b.transport == null))
            `uvm_fatal("DUAL_TEST", "fixture did not provide two snapshot VIO functions")
        transport_a = function_a.transport;
        transport_b = function_b.transport;

        `uvm_info("DUAL_TEST", "--- Initializing VIP A ---", UVM_LOW)

        // Fabric BAR programming + capability discovery (VIP A)
        transport_a.discover_and_init_bars();
        `uvm_info("DUAL_TEST", $sformatf("VIP A: BDF=0x%04h BAR0=0x%016h",
            transport_a.bdf, transport_a.bar.bar_base[0]), UVM_LOW)

        if (!transport_a.cap_mgr.common_cfg_found) begin
            `uvm_fatal("DUAL_TEST", "VIP A: Common Config capability not found")
        end

        // Full virtio init for VIP A
        run_virtio_init(transport_a, "VIP_A");

        #100ns;
        tlm_adapter.drain();

        // VIP B is the second snapshot PF on the same PCIe EP model
        `uvm_info("DUAL_TEST", "--- Initializing VIP B ---", UVM_LOW)

        transport_b.discover_and_init_bars();
        `uvm_info("DUAL_TEST", $sformatf("VIP B: BDF=0x%04h BAR0=0x%016h",
            transport_b.bdf, transport_b.bar.bar_base[0]), UVM_LOW)

        if (!transport_b.cap_mgr.common_cfg_found) begin
            `uvm_fatal("DUAL_TEST", "VIP B: Common Config capability not found")
        end

        // Full virtio init for VIP B
        run_virtio_init(transport_b, "VIP_B");

        #100ns;
        tlm_adapter.drain();

        // Initialize host memory regions (separate for A and B)
        mem_a.init_region(64'hA000_0000, 64'hAFFF_FFFF);  // 256MB for A
        mem_b.init_region(64'hB000_0000, 64'hBFFF_FFFF);  // 256MB for B
        iommu_a.strict_permission_check = 0;
        iommu_b.strict_permission_check = 0;

        `uvm_info("DUAL_TEST", "Both VIPs initialized successfully", UVM_LOW)
    endtask
```
`run_virtio_init`（`:689-733`）、所有流量/带宽测试和 `report_results` 文本都不变。

- [ ] **Step 6: SYNC + 运行 + 确认点**

SYNC 后运行 ONE TEST（`virtio_dual_test`），然后：
```bash
ssh ubuntu@10.11.10.53 'grep -E "Test Results|OVERALL|PASSED|FAILED|data_ok|data_err" ~/virtio_priv_run/virtio_work/logs/virtio_dual_test.log | tail -40 > /tmp/dual.post; grep -E "Test Results|OVERALL|PASSED|FAILED|data_ok|data_err" ~/virtio_priv_run/dual.pre_p4.log | tail -40 > /tmp/dual.pre; diff <(sed -E "s/^.*@ *[0-9]+[a-z]*: *//" /tmp/dual.pre) <(sed -E "s/^.*@ *[0-9]+[a-z]*: *//" /tmp/dual.post)'
```
预期：
- 三项计数为 0。
- `diff` 只允许出现与仿真时间相关的差异（带宽测试打印的 `elapsed` 和吞吐）。
- 所有通过/失败计数和数据比对计数与基线相同，并出现 `OVERALL: PASS -- All dual VIP tests passed`。

**确认点（spec 风险条款）：** 如果出现新的 WARNING/ERROR/FATAL、`FEATURES_OK` 或 `DRIVER_OK` 未置位、或任何计数差异，**立即停止**，不得修改断言。把日志差异和以下事实交给用户，确认测试意图：
- VIP B 从“与 A 共享同一 BAR 的第二个 requester”变为“snapshot 中的第二个 PF，拥有独立 lease”。
- PCIe env 配置改由 fixture 提供（`scb_enable=1` 等；原为 `scb_enable=0`）。
- 两个 Function 上都挂有 monitor/observer。

候选处理：给 fixture 增加 `pcie_scb_enable` 旋钮；或把 VIP B 改为 snapshot 中 PF0 的 VF。

- [ ] **Step 7: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: Commit**

```bash
git add virtio_net_vip/tests/virtio_dual_test.sv
git commit -m "test: dual VIP 测试改走双 PF snapshot 端点与 Fabric 发现"
```

---

### Task P4-6: 删除 `enumerate_bars` 与 `virtio_enumerate_discovery`

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_discovery_strategy.sv`（P3-2 新建）：头注释中的 enumerate 行；删除 `class virtio_enumerate_discovery` 及其上方注释
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv`：`discovery_strategy` 字段注释、`new()` 中的缺省策略、`discover_and_init_bars` 注释（均为 P3-2 加入的文本）
- Modify: `virtio_net_vip/src/transport/virtio_bar_accessor.sv`：头注释 `:10`、`:16`；字段注释 `:304`；`:316-318`（`next_bar_alloc_addr`）；构造注释 `:321-322` 与 `:330`；`enumerate_bars` `:859-996`
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`：P3-2 新增的 `test_discovery_strategy_selection` 中缺省策略断言
- Modify: `README.md:145` 及 P3-2 加入的目录树行；`docs/virtio_net_vip_manual.md:1087,1091-1094,2220-2223,2371`
- Test: 全回归（重点：`virtio_unit_test`、`virtio_e2e_test`、real-driver 系列、`virtio_fabric_resource_test`、`virtio_dut_caps_test`、private ring 测试）

**Interfaces:**
- Consumes: P4-4、P4-5 已完成，测试侧不再调用 `enumerate_bars`。P3-2 产出：`virtual class virtio_discovery_strategy`、`virtio_enumerate_discovery`、`virtio_fabric_preconfigured_discovery`、transport 的 `discovery_strategy` / `set_discovery_strategy()` / `discovery_strategy_name()`。
- Produces:
  - 发现策略只剩 `virtio_fabric_preconfigured_discovery`。后续设计在其上新增 verify_snapshot。
  - transport 构造时的缺省策略改为 `virtio_fabric_preconfigured_discovery`。未调用 `configure_fabric_managed()` 的 transport 进入 `discover_and_init_bars()` 时，由该策略报 `uvm_fatal("TRANSPORT", "Fabric preconfigured discovery requested for a non-Fabric function")`（文本沿用 HEAD `:907-909`）。
  - `discovery_strategy_name()` 的缺省值从 `"enumerate"` 变为 `"fabric_preconfigured"`。

- [ ] **Step 1: 确认无调用者**

```bash
grep -rn "enumerate_bars\|next_bar_alloc_addr\|virtio_enumerate_discovery\|\"enumerate\"" --include=*.sv --include=*.svh --include=*.f virtio_net_vip examples filelists
```
预期只命中：`virtio_bar_accessor.sv`（定义）、`virtio_discovery_strategy.sv`（enumerate 类）、`virtio_pci_transport.sv`（`new()` 中的缺省构造）、`virtio_unit_test.sv`（P3-2 测试中的 `"enumerate"` 断言）。

- [ ] **Step 2: 先改测试缺省断言（预期失败）**

`virtio_unit_test.sv` 的 `test_discovery_strategy_selection`（P3-2 新增）：
```systemverilog
// old
    // transport 的发现路径只由策略对象决定：默认 enumerate，Fabric 托管切换为
    // fabric_preconfigured，外部可注入新策略（后续 verify_snapshot 的接入点）。
// new
    // transport 的发现路径只由策略对象决定：缺省即 fabric_preconfigured（非 Fabric
    // 托管的 transport 发现时由该策略 fatal），外部可注入新策略（verify_snapshot）。
```
```systemverilog
// old
        if (transport.discovery_strategy_name() != "enumerate")
// new
        if (transport.discovery_strategy_name() != "fabric_preconfigured")
```
SYNC 后运行 ONE TEST（`virtio_unit_test`）。预期 FAIL：`UVM_ERROR ... [TEST] default discovery strategy is enumerate`。

- [ ] **Step 3: 删除 enumerate 策略，修改缺省值**

`virtio_discovery_strategy.sv`：
- 删除头注释中的一行 `//   enumerate            : PCI BAR sizing + 本地地址分配，仅用于非 Fabric function。`
- 删除 `// 传统 PCI 枚举：sizing 全部 BAR、按本地窗口分配地址，再扫描 virtio capability。` 以及 `class virtio_enumerate_discovery ... endclass`（含其后一个空行）。

`virtio_pci_transport.sv`：
```systemverilog
// old
    // 当前 BAR/capability 发现策略：构造时为 enumerate，configure_fabric_managed()
    // 切换为 fabric_preconfigured；后续设计经 set_discovery_strategy() 注入 verify_snapshot。
// new
    // 当前 BAR/capability 发现策略：构造时即为 fabric_preconfigured（未经
    // configure_fabric_managed() 的 transport 发现时由该策略 fatal）；后续设计经
    // set_discovery_strategy() 注入 verify_snapshot。
```
```systemverilog
// old
        discovery_strategy = virtio_enumerate_discovery::type_id::create("enumerate_discovery");
// new
        discovery_strategy = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
```
`discover_and_init_bars` 上方注释中，`委托当前 discovery_strategy（enumerate / fabric_preconfigured /` 改为 `委托当前 discovery_strategy（fabric_preconfigured /`。

`configure_fabric_managed()` 中重新安装 fabric 策略的语句保留：它会覆盖 `configure_fabric_managed` 之前注入的策略，P3-2 的单测依赖这个顺序。

- [ ] **Step 4: 删除 `enumerate_bars` 与地址分配器**

`virtio_bar_accessor.sv`：
- 删除 `:10`：`//   - enumerate_bars:         Standard PCI BAR enumeration`
- `:16`：`// 职责：字节使能计算与数据抽取、BAR 枚举与地址分配、Fabric 模式下的 BAR` → `// 职责：字节使能计算与数据抽取、Fabric 模式下的 BAR`
- `:304`：`bit [63:0]  bar_size[6];        // BAR0-5 sizes (for enumeration)` → `bit [63:0]  bar_size[6];        // BAR0-5 sizes (from Fabric leases)`
- 删除 `:316-318`：空行、`// ===== BAR enumeration base address allocator =====`、`bit [63:0]   next_bar_alloc_addr;`
- 构造注释 `:321-322`：“构造：清空全部 BAR 表项与 Fabric 角色，MMIO 分配窗口从 0xC000_0000 起步；此时未注入 sequencer，所有访问入口都会 fatal。”改为“构造：清空全部 BAR 表项与 Fabric 角色；此时未注入 sequencer，所有访问入口都会 fatal。”
- 删除 `:330`：`next_bar_alloc_addr = 64'h0000_0000_C000_0000;  // Default MMIO window`
- 删除 `:859-996`：从 `// ====` 加 `// enumerate_bars` 注释块起，到 `enumerate_bars` 的 `endtask`，含其后的空行。

- [ ] **Step 5: 文档**

`README.md:145`：`BAR 配置/发现（Fabric: program frozen lease；legacy: enumerate）` → `BAR 配置/发现（program frozen Fabric lease）`。P3-2 加入的目录树行 `← BAR/capability 发现策略（enumerate / fabric_preconfigured）` 改为 `← BAR/capability 发现策略（fabric_preconfigured）`。

`docs/virtio_net_vip_manual.md`：
- 删除表行 `:1087`：`` | `enumerate_bars()` | Config Read/Write | PCI BAR 枚举 | ``
- `:1091-1094` 段落替换为：`Fabric-owned function 禁止 BAR sizing/enumeration；地址必须来自冻结 dpu_common lease，并由 \`program_fabric_bar_pairs()\` 编程 config-space BAR 后再发现 capability。`
- `:2220-2223`：删除整句“旧的 `bar_accessor.enumerate_bars()` 顺序分配（默认从 `0xC000_0000` 开始）只适用于 legacy/TLM 模型路径；Fabric-owned function 会明确报告 `BAR_FABRIC_OWNED`，不能再用 `bar.next_bar_alloc_addr` 覆盖它。”
- `:2371`（P3-2 已改为 `` | `discover_and_init_bars` | task | 委托当前发现策略（enumerate / fabric_preconfigured） | ``）→ `` | `discover_and_init_bars` | task | 委托当前发现策略（fabric_preconfigured） | ``

- [ ] **Step 6: grep 证明**

```bash
grep -rn "enumerate_bars\|next_bar_alloc_addr\|BAR_FABRIC_OWNED\|virtio_enumerate_discovery" --include=*.sv --include=*.svh --include=*.f --include=*.md virtio_net_vip examples filelists scripts README.md docs/virtio_net_vip_manual.md
grep -rn "\"enumerate\"\|enumerate /" --include=*.sv --include=*.md virtio_net_vip README.md docs/virtio_net_vip_manual.md
```
预期：两条都无输出。

- [ ] **Step 7: SYNC + 重点测试**

对 `virtio_unit_test virtio_full_integration_test virtio_dual_test virtio_e2e_test virtio_real_driver_flow_test virtio_fabric_resource_test virtio_dut_caps_test` 逐个运行 ONE TEST，预期 0 WARNING/ERROR/FATAL，`virtio_unit_test` 打印 `test_discovery_strategy_selection PASSED`。

private ring：P0.4 后已由回归覆盖。如果尚未进入 manifest，运行 `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p4-6'`，预期 `flow_rc=0`、`contract_rc=0`，计数全 0。

- [ ] **Step 8: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 9: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_discovery_strategy.sv virtio_net_vip/src/transport/virtio_pci_transport.sv \
        virtio_net_vip/src/transport/virtio_bar_accessor.sv virtio_net_vip/tests/virtio_unit_test.sv \
        README.md docs/virtio_net_vip_manual.md
git commit -m "refactor: 删除非 fabric BAR 枚举与 enumerate 发现策略"
```

---

### Task P4-7: 删除 function instance 的 standalone 绑定入口与 standalone 身份分支

**Files:**
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`：删除 `wire_shared`/`bind_pcie` `:525-566`；改写 `apply_function_configuration` `:686-701`；改写 `commit_validated_pcie_components` 注释 `:344-345`、`:396-397`
- Modify: `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv:156-157`；`examples/dpu_priv_ring/README.md:82-83`
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`：`virtio_dut_caps_malicious_function` `:482-534`；`:1267-1278`；`assert_public_bind_null_driver_agent_returns` `:2577`
- Modify: `docs/virtio_net_vip_manual.md:1391`
- Test: `virtio_dut_caps_test`、`virtio_pf_lifecycle_reset_test`、`virtio_monitor_routing_test`、`virtio_admin_vq_test`、private ring `dpu_priv_driver_flow_test`、全回归

**Interfaces:**
- Consumes：P2.5 之后唯一保留的绑定入口（HEAD `virtio_function_instance.sv`）。前提：P2.5 已删除 `bind_pcie_components`，并把 `wire_shared/bind_pcie` 改为一行包装。
  - `function bit preflight_bind_pcie(input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr)`（`:219`）
  - `function bit commit_preflight_bind_pcie(input host_mem_manager hmem, input virtio_iommu_model iommu_mdl, input virtio_memory_barrier_model bar_mdl, input virtqueue_error_injector einj, input virtio_wait_policy wpol, input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr)`（`:304`）
  - `function void cancel_preflight_bind_pcie()`（`:296`）
- Produces:
  - `virtio_function_instance` 不再有 `wire_shared()` 和 `bind_pcie()`。
  - 未经 `configure_from_service()` 的实例在 `apply_function_configuration()` 中不派生任何身份，transport 保持未配置。P4-8 依赖这一点：否则 build_phase 中的 `transport.iommu_host_id()` 会对 standalone 实例 fatal。

“standalone” 的核实结论：
- 含义：没有通过 `configure_from_service()` 绑定冻结 snapshot 的 `virtio_function_instance` 或 transport（`pcie_id_valid == 0`）。测试直接 create 它们，再手工注入共享对象。
- HEAD 中的实例：full/dual 的 `binding_function_*`，dut_caps 的 `mq_binding_function`、`malicious_binding_function`、`null_driver_binding_function`，pf_lifecycle 的并发 VF 桩。
- HEAD 中 `wire_shared/bind_pcie` 的调用者：
  - `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv:156`：调用对象是 env 中已配置 identity 的 Function，并非真正的 standalone。
  - `virtio_dut_caps_test.sv:2577`。
  - 另有 dut_caps 的覆写桩 `:515-534`。
- `apply_function_configuration` 的 else 分支（`:695-701`）只在 build_phase 对 `pcie_id_valid == 0` 的实例生效。此时 `bdf == 0`，写入的值与各对象的构造默认值相同：`transport.bdf`、`notify_mgr.function_bdf`、`bar.requester_id`、`vq_mgr.host_id/bdf`、引擎的 `host_id/bdf` 都默认为 0。因此删除后行为不变。

- [ ] **Step 1: 列出 P2.5 之后的调用者**

```bash
grep -rnE "\b(wire_shared|bind_pcie)\s*\(" --include=*.sv virtio_net_vip examples | grep -vE "env[a-z_]*\.bind_pcie\(|virtio_net_env\.sv"
```
预期（HEAD 形态）：`examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv:156`、`virtio_net_vip/tests/virtio_dut_caps_test.sv:515`、`:527`（这两处是覆写声明）、`:2577`，以及 `virtio_function_instance.sv` 自身。

如果 P2.5 把其他调用迁到了 `wire_shared/bind_pcie`，按下面的规则一并迁移：
- `X.wire_shared(m, i, b, e, w, seqr)` → `(X.preflight_bind_pcie(seqr) && X.commit_preflight_bind_pcie(m, i, b, e, w, seqr))`
- `X.bind_pcie(seqr)` → `(X.preflight_bind_pcie(seqr) && X.commit_preflight_bind_pcie(X.mem, X.iommu, X.barrier, X.err_inj, X.wait_pol, seqr))`

- [ ] **Step 2: 迁移 private ring 示例**

`examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv:156-157`：
```systemverilog
// old
                if (!f.wire_shared(env.host_mem, env.iommu, env.barrier,
                                     env.err_inj, env.wait_pol, unused_rc))
// new
                if (!(f.preflight_bind_pcie(unused_rc) &&
                      f.commit_preflight_bind_pcie(env.host_mem, env.iommu,
                          env.barrier, env.err_inj, env.wait_pol, unused_rc)))
```
`examples/dpu_priv_ring/README.md:83`：`` Function 的 `wire_shared()` 绑定资源。 `` → `` Function 的 `preflight_bind_pcie()` + `commit_preflight_bind_pcie()` 绑定资源。 ``

- [ ] **Step 3: 迁移 `virtio_dut_caps_test.sv`**

`virtio_dut_caps_malicious_function` 中：
- 删除字段 `int unsigned public_wire_shared_count;`、`int unsigned public_function_bind_count;`（`:486-487`）。
- 删除 `new()` 中的 `public_wire_shared_count = 0;`、`public_function_bind_count = 0;`（`:492-493`）。
- 删除 `wire_shared` 与 `bind_pcie` 两个覆写（`:515-532`）。

`public_bind_count` 与 `bind_pcie_components` 覆写由 P2.5 处理，本任务不动它们在 P2.5 之后的形态。

`:1267-1278`（production env 绑定守卫检查）：
```systemverilog
// old
        if ((production_function.public_bind_count != 0) ||
            (production_function.public_wire_shared_count != 0) ||
            (production_function.public_function_bind_count != 0) ||
            (production_function.driver_agent.fsm == null) ||
            (production_function.driver_agent.fsm.max_supported_mq_pairs() !=
             1)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"production env bind bypassed mandatory function guard: ",
                 "components=%0d wire=%0d bind=%0d fsm=%0d"},
                production_function.public_bind_count,
                production_function.public_wire_shared_count,
                production_function.public_function_bind_count,
// new
        if ((production_function.public_bind_count != 0) ||
            (production_function.driver_agent.fsm == null) ||
            (production_function.driver_agent.fsm.max_supported_mq_pairs() !=
             1)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"production env bind bypassed mandatory function guard: ",
                 "components=%0d fsm=%0d"},
                production_function.public_bind_count,
```
如果 P2.5 已删除 `public_bind_count`，new 文本中不再出现它对应的条件和格式参数：判断只剩 fsm 两项，格式串改为 `"production env bind bypassed mandatory function guard: fsm=%0d"`。

`assert_public_bind_null_driver_agent_returns` `:2577`：
```systemverilog
// old
        bind_succeeded = base_function.bind_pcie(mq_pcie_seqr);
// new
        bind_succeeded = base_function.preflight_bind_pcie(mq_pcie_seqr);
```
`preflight_bind_pcie` 对 null driver agent 报相同的 ID 和文本：`FUNCTION_BIND` / `function_0 is missing driver agent`（HEAD `:243-246`），且没有副作用，所以 `state_unchanged` 断言不变。

- [ ] **Step 4: 删除 `wire_shared`/`bind_pcie` 与 standalone 身份分支**

删除 `virtio_function_instance.sv` HEAD `:525-566`：从 `// 兼容旧 standalone 调用方 ...` 注释起，到 `bind_pcie` 的 `endfunction`。

`apply_function_configuration`（HEAD `:686-701`）：
```systemverilog
// old
    // 把 snapshot 的 PCIe identity、BAR lease、Host-qualified DMA identity 和
    // service resources 同步到 transport/queue/dataplane；未绑定 snapshot 时仅
    // 保留 standalone 兼容路径，不创建新的资源所有权。
    protected function void apply_function_configuration();
        string why;

        if ((transport == null) || (vq_mgr == null) || (resource_client == null))
            return;
        if (pcie_id_valid)
            transport.configure_pcie_identity(pcie_id);
        else begin
            // Compatibility for standalone instances authored before a
            // frozen snapshot is attached.  Environment-owned functions
            // always take the full-identity branch above.
            transport.bdf = bdf;
            transport.notify_mgr.set_function_bdf(bdf);
            transport.bar.requester_id = bdf;
        end
// new
    // 把 snapshot 的 PCIe identity、BAR lease、Host-qualified DMA identity 和
    // service resources 同步到 transport/queue/dataplane；尚未绑定冻结
    // snapshot 的实例不派生任何身份，transport 保持未配置。
    protected function void apply_function_configuration();
        string why;

        if ((transport == null) || (vq_mgr == null) || (resource_client == null))
            return;
        if (!pcie_id_valid)
            return;
        transport.configure_pcie_identity(pcie_id);
```
`commit_validated_pcie_components` 的注释：
- `:344-345`：“The environment reaches this helper through preflight; the standalone API below performs the same checks before calling it.” → “The environment reaches this helper only through preflight.”
- `:396-397`：“Keep the optional standalone dataplane wrapper in the same host-qualified DMA domain as the function-owned queue/atomic path.” → “Keep the function-owned dataplane in the same host-qualified DMA domain as the queue/atomic path.”

`docs/virtio_net_vip_manual.md:1391`：“底层 nonvirtual \`wire_shared()\` 返回 \`bit\`，只有 MQ capability guard 和全部组件接线成功才返回 1；” → “底层 nonvirtual \`preflight_bind_pcie()\`/\`commit_preflight_bind_pcie()\` 返回 \`bit\`，只有 MQ capability guard 和全部组件接线成功才返回 1；”

- [ ] **Step 5: grep 证明**

```bash
grep -rnw "wire_shared" --include=*.sv --include=*.md virtio_net_vip examples README.md docs/virtio_net_vip_manual.md
grep -nE "function bit bind_pcie\(|Compatibility for standalone" virtio_net_vip/src/sriov/virtio_function_instance.sv
```
预期：两条都无输出。`virtio_net_env::bind_pcie` 是 env 的方法，不受影响。

- [ ] **Step 6: SYNC + 受影响测试**

对 `virtio_dut_caps_test virtio_pf_lifecycle_reset_test virtio_monitor_routing_test virtio_admin_vq_test` 以及 private ring `dpu_priv_driver_flow_test`（P0.4 后的 manifest 名称）逐个运行 ONE TEST。若 private ring 尚未进入 manifest，运行 `ssh ubuntu@10.11.10.53 '~/virtio_priv_run/run_priv.sh p4-7'`，预期 `flow_rc=0`、`contract_rc=0`，计数全 0。所有测试预期 0 WARNING/ERROR/FATAL。

- [ ] **Step 7: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 8: Commit**

```bash
git add virtio_net_vip/src/sriov/virtio_function_instance.sv virtio_net_vip/tests/virtio_dut_caps_test.sv \
        examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv examples/dpu_priv_ring/README.md \
        docs/virtio_net_vip_manual.md
git commit -m "refactor: 删除 function instance 的 standalone 绑定入口与身份兼容分支"
```

---

### Task P4-8: DMA host domain 严格化（删除 host0 兜底）并迁移测试身份

**Files:**
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv:105-109`（`iommu_host_id`）
- Modify: `virtio_net_vip/src/agent/virtio_atomic_ops.sv:64-73`（`get_iommu_host_id`）。P3 拆分后用 `grep -rn "function int unsigned get_iommu_host_id" virtio_net_vip/src/agent` 定位。
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv:76-82`（`iommu_host_id`）。P3 可能已把它移入 `virtio_migration_engine`，用 `grep -rn "function int unsigned iommu_host_id" virtio_net_vip/src` 定位。
- Modify: `virtio_net_vip/src/agent/virtio_monitor.sv:403`
- Modify: `virtio_net_vip/tests/virtio_vq_test_kit.sv`（P2.8 产物，新增 `host0_pcie_id`）
- Modify: `virtio_net_vip/tests/virtio_unit_test.sv`（新增 catcher 与 `test_transport_requires_frozen_identity`）
- Modify（测试 transport 身份）：`virtio_admin_vq_test.sv:407,556`；`virtio_indirect_desc_test.sv:609,759,936,1037`；`virtio_pf_lifecycle_reset_test.sv:512,577-578,652,748,788-789`；`virtio_migration_dirty_test.sv:650,768,865,994,1138,1317,1557`；`virtio_dut_caps_test.sv:2139,2168-2169,2512-2513`
- Modify: `README.md:59-60`；`docs/virtio_net_vip_manual.md:745-746`
- Test: 上述测试、`virtio_monitor_test`、`virtio_net_packet_multi_queue_test`、全回归

**Interfaces:**
- Consumes:
  - P4-7：standalone 实例不再在 build_phase 调用 `iommu_host_id()`。
  - P2.8：`virtio_vq_test_kit` 假设为只含静态方法的 `class virtio_vq_test_kit`，且已列入 `filelists/tests.f`。
  - `virtio_pci_transport::configure_pcie_identity(input dpu_pcie_function_id_t)`（HEAD `:95`）。
  - `dpu_pcie_function_id_t`（`dpu_common/src/dpu_device_types.sv:44-47`，形如 `'{domain: '{host_id, segment_id}, bdf}`）。
- Produces:
  - `virtio_pci_transport::iommu_host_id()`：没有冻结 identity 时 `uvm_fatal("TRANSPORT", ...has no frozen PCIe identity...)`，不再返回 0。
  - `virtio_atomic_ops::get_iommu_host_id(t)` 和 `virtio_auto_fsm::iommu_host_id()`：缺 transport 时 fatal，不再返回 0。
  - `static function dpu_pcie_function_id_t virtio_vq_test_kit::host0_pcie_id(input bit [15:0] bdf)`
  - monitor 对未绑定 identity 的 transport 报告 `monitor_host_id = 0`，与 `monitor_segment_id` 规则相同。这只是观测值，不参与 DMA。

**Spec deviation:** spec 表格只列出 dut_caps 和 unit 两个迁移测试。核实发现，依赖“无 identity 的 transport 落到 host0”的维护测试还有：
- `virtio_admin_vq_test`：Admin 路径 `virtio_pf_manager.sv:97,291` 与 `virtio_atomic_ops.sv:1423-1606` 调用 `iommu_host_id()`。
- `virtio_indirect_desc_test`、`virtio_pf_lifecycle_reset_test`、`virtio_migration_dirty_test`：经 ops 的 DMA 路径调用。
- `virtio_monitor_test`：经 monitor `:403` 调用。

本任务一并迁移这些测试。`virtio_unit_test` 中的 `host1_transport` 已配置 identity（`:416-417`），unit 只新增严格化测试。迁移只在测试侧补上与 HEAD 等价的 host0 identity，BDF 取原 `transport.bdf` 字面量，不改变 DMA 域。

- [ ] **Step 1: 写失败测试**

在 `virtio_vq_test_kit` 类中新增方法（文件头若没有 `import dpu_resource_pkg::*;` 则补上）：
```systemverilog
    // 中文说明：单元测试用的 host0 PCIe identity（segment 0，BDF 由调用方给出）。
    // 取代旧的“transport 未配置 identity 时默认 host0”兼容路径。
    static function dpu_pcie_function_id_t host0_pcie_id(input bit [15:0] bdf);
        dpu_pcie_function_id_t pcie_id;
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = bdf;
        return pcie_id;
    endfunction
```
在 `virtio_unit_test.sv` 中 `endclass : virtio_expected_iommu_map_error_catcher` 之后新增：
```systemverilog

// Absorbs exactly the transport fatal raised when a DMA host domain is
// requested from a transport that never received a frozen PCIe identity.
class virtio_unit_expected_identity_fatal_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_unit_expected_identity_fatal_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_FATAL) && (get_id() == "TRANSPORT") &&
            uvm_is_match("*has no frozen PCIe identity*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_unit_expected_identity_fatal_catcher
```
在 `test_iommu_translation_overflow` 任务之前新增：
```systemverilog
    // A transport without a frozen PCIe identity has no DMA host domain; it
    // must not silently fall back to host0.
    task test_transport_requires_frozen_identity();
        virtio_pci_transport transport =
            virtio_pci_transport::type_id::create("identityless_transport");
        virtio_unit_expected_identity_fatal_catcher catcher;
        int unsigned host_id;

        catcher = new("identity_fatal_catcher");
        uvm_report_cb::add(null, catcher);
        host_id = transport.iommu_host_id();
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count != 1)
            `uvm_fatal("TEST", $sformatf(
                "identityless transport resolved DMA host %0d without a fatal",
                host_id))
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0042));
        if (transport.iommu_host_id() != 0)
            `uvm_fatal("TEST", "host0 identity did not resolve DMA host 0")
        `uvm_info("UNIT_TEST", "test_transport_requires_frozen_identity PASSED", UVM_LOW)
    endtask
```
在 `run_phase` 的 `test_iommu_translation_overflow();` 之后加一行 `        test_transport_requires_frozen_identity();`。

- [ ] **Step 2: 运行，确认失败**

SYNC 后运行 ONE TEST（`virtio_unit_test`）。预期 FAIL：`UVM_FATAL ... [TEST] identityless transport resolved DMA host 0 without a fatal`。

- [ ] **Step 3: 实现严格化**

`virtio_pci_transport.sv:105-109`：
```systemverilog
// old
    // Canonical DMA requester-domain projection.  Fabric functions use the
    // frozen PCIe identity; legacy standalone transports remain in host0.
    function int unsigned iommu_host_id();
        return pcie_id_valid ? pcie_id.domain.host_id : 0;
    endfunction
// new
    // Canonical DMA requester-domain projection.  The host comes only from
    // the frozen PCIe identity; a transport without one has no DMA domain.
    function int unsigned iommu_host_id();
        if (!pcie_id_valid) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "transport BDF=0x%04h has no frozen PCIe identity; DMA host domain is undefined",
                bdf))
            return 0;
        end
        return pcie_id.domain.host_id;
    endfunction
```
`virtio_atomic_ops.sv:64-73`：
```systemverilog
// old
    // A numeric BDF is scoped by the PCIe host domain.  Standalone transports
    // without a frozen identity retain the legacy host0 behavior.
    protected function int unsigned get_iommu_host_id(
        virtio_pci_transport t
    );
        if (t != null)
            return t.iommu_host_id();
        return 0;
    endfunction
// new
    // A numeric BDF is scoped by the PCIe host domain taken from the bound
    // transport's frozen identity; there is no implicit host0 fallback.
    protected function int unsigned get_iommu_host_id(
        virtio_pci_transport t
    );
        if (t == null) begin
            `uvm_fatal("ATOMIC_OPS",
                "DMA host domain requested without a bound transport")
            return 0;
        end
        return t.iommu_host_id();
    endfunction
```
`virtio_auto_fsm.sv:76-82`（或 P3 之后所在的文件）：
```systemverilog
// old
    // 取本 function 在 IOMMU 视角下的 host id（经 transport 转发）；
    // ops/transport 尚未接入时返回 0，调用方按默认 host 处理。
    protected function int unsigned iommu_host_id();
        if ((ops != null) && (ops.transport != null))
            return ops.transport.iommu_host_id();
        return 0;
    endfunction
// new
    // 取本 function 在 IOMMU 视角下的 host id（经 transport 转发）；
    // ops/transport 尚未接入属于接线错误，直接 fatal，不默认 host0。
    protected function int unsigned iommu_host_id();
        if ((ops == null) || (ops.transport == null)) begin
            `uvm_fatal("AUTO_FSM",
                "DMA host domain requested before ops/transport were bound")
            return 0;
        end
        return ops.transport.iommu_host_id();
    endfunction
```
`virtio_monitor.sv:403`：
```systemverilog
// old
        txn.monitor_host_id = (transport == null) ? 0 : transport.iommu_host_id();
// new
        txn.monitor_host_id = (transport == null || !transport.pcie_id_valid) ?
                              0 : transport.pcie_id.domain.host_id;
```
`README.md:59-60`：“…与独立 TX/RX dataplane；未绑定全局 identity 的旧 standalone 用法默认属于 host0。”改为“…与独立 TX/RX dataplane；未绑定冻结 identity 的 transport 没有 DMA host domain，请求时直接报错。”

`docs/virtio_net_vip_manual.md:745-746`（P4-2 已修改）：“…取得 Host；未绑定 PCIe identity 的 standalone 对象兼容地落到 host0。”改为“…取得 Host；未绑定 PCIe identity 的 transport 没有 DMA host domain，请求时直接报错。”

- [ ] **Step 4: 运行受影响测试，收集需要迁移的 transport**

SYNC 后，对 `virtio_unit_test virtio_admin_vq_test virtio_indirect_desc_test virtio_pf_lifecycle_reset_test virtio_migration_dirty_test virtio_dut_caps_test virtio_monitor_test virtio_net_packet_multi_queue_test` 逐个运行 ONE TEST，然后：
```bash
ssh ubuntu@10.11.10.53 'cd ~/virtio_priv_run/virtio_work && grep -l "has no frozen PCIe identity\|DMA host domain requested" logs/*.log'
```
预期：
- `virtio_unit_test` PASS。
- FAIL 列表（由 HEAD 推断）：`virtio_admin_vq_test`、`virtio_indirect_desc_test`、`virtio_pf_lifecycle_reset_test`、`virtio_migration_dirty_test`、`virtio_dut_caps_test`。
- `virtio_monitor_test` 和 `virtio_net_packet_multi_queue_test` PASS。如果后者因 P2.1 的接线而 FAIL，对报出的 transport 按 Step 5 的规则补 identity。

- [ ] **Step 5: 迁移测试 transport 身份**

统一规则：把对 transport 的 `X.bdf = <expr>;` 替换为 `X.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(<expr>));`。`configure_pcie_identity` 会同时设置 `bdf`、`bar.requester_id`、`notify_mgr.function_bdf`。这些 mock transport 不发 TLP，三个值都与原 `bdf` 一致。

如果 P2.8 已把这些赋值收进 kit/mock 的某个辅助函数，只需在该辅助函数内按同一规则改一处。

HEAD 中的逐个位置：

| 文件:行 | old | new |
|---|---|---|
| admin_vq:407 | `transport.bdf = 16'h0708;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0708));` |
| admin_vq:556 | `wrong_transport.bdf = 16'h0808;` | `wrong_transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0808));` |
| indirect_desc:609 | `transport.bdf = 16'h0702;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0702));` |
| indirect_desc:759、:936 | `transport.bdf = 16'h0704;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0704));` |
| indirect_desc:1037 | `transport.bdf = 16'h0705;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0705));` |
| pf_lifecycle:512 | `transport.bdf = 16'h0030;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0030));` |
| pf_lifecycle:652 | `transport.bdf = 16'h0020;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0020));` |
| pf_lifecycle:748 | `transport.bdf = 16'h0040;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0040));` |
| migration_dirty:650 | `transport.bdf = 16'h0901;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0901));` |
| migration_dirty:768 | `transport.bdf = 16'h0902;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0902));` |
| migration_dirty:865 | `transport.bdf = 16'h0903;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0903));` |
| migration_dirty:994 | `transport.bdf = 16'h0904;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0904));` |
| migration_dirty:1138 | `transport.bdf = 16'h0905;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0905));` |
| migration_dirty:1317 | `transport.bdf = (vq_type == VQ_SPLIT) ? 16'h0906 : 16'h0907;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id((vq_type == VQ_SPLIT) ? 16'h0906 : 16'h0907));` |
| migration_dirty:1557 | `transport.bdf = 16'h0910;` | `transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0910));` |

HEAD 中有些 transport 没有设置 `bdf`（即 BDF 为 0）。在这些 transport 的创建语句之后插入一行，BDF 保持 0，与 HEAD 等价：
- `virtio_pf_lifecycle_reset_test.sv:577-578`（`"verified_reset_transport"`）之后：
  `        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0000));`
- `virtio_pf_lifecycle_reset_test.sv:789`（`transport.device_reset_complete = 0;`）之后：同上一行。
- `virtio_dut_caps_test.sv` 中三处，分别在创建语句之后插入：
  - `:2139`（`"mq_transport"`）之后：`        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0000));`
  - `:2168-2169`（变量 `rebind_transport`）之后：`        rebind_transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0000));`
  - `:2512-2513`（`"malicious_binding_transport"`）之后：`        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0000));`
  - 如果 P2.5 把这些用例改为绑定 standalone Function 自带的 transport，则对 `<function>.transport` 做同样的插入。

如果 Step 4 报出表外的 transport，按统一规则在其创建处或赋 BDF 处补 identity，并把位置写进提交说明。

- [ ] **Step 6: 运行，确认通过**

SYNC 后重跑 Step 4 的 8 个测试。预期：
- 全部 0 WARNING/ERROR/FATAL；
- `virtio_unit_test` 打印 `test_transport_requires_frozen_identity PASSED`；
- Step 4 的 grep 无输出。

- [ ] **Step 7: grep 证明**

```bash
grep -nE "pcie_id_valid \? pcie_id\.domain\.host_id : 0" virtio_net_vip/src/transport/virtio_pci_transport.sv
grep -rnE "^\s*[a-z_]*transport[a-z_]*\.bdf\s*=" --include=*.sv virtio_net_vip/tests
grep -rn "standalone transports\|legacy host0" --include=*.sv virtio_net_vip/src
```
预期：三条都无输出。

- [ ] **Step 8: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。private ring 若尚未进入 manifest，运行 `run_priv.sh p4-8`，预期 `flow_rc=0`、`contract_rc=0`。

- [ ] **Step 9: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_pci_transport.sv virtio_net_vip/src/agent \
        virtio_net_vip/tests/virtio_vq_test_kit.sv virtio_net_vip/tests/virtio_unit_test.sv \
        virtio_net_vip/tests/virtio_admin_vq_test.sv virtio_net_vip/tests/virtio_indirect_desc_test.sv \
        virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv virtio_net_vip/tests/virtio_migration_dirty_test.sv \
        virtio_net_vip/tests/virtio_dut_caps_test.sv README.md docs/virtio_net_vip_manual.md
git commit -m "refactor: DMA host domain 只取自冻结 PCIe identity，删除 host0 兜底"
```
如果 P3 已把 `iommu_host_id()` 或 `get_iommu_host_id()` 移到 `virtio_net_vip/src/agent` 之外，在 `git add` 中补上那个文件的路径。

---

### Task P4-9: 删除 auto_fsm 中 MQ 上限 0 的 standalone 兼容编码

**Files:**
- Modify: `virtio_net_vip/src/agent/virtio_auto_fsm.sv:84-136`（`mq_pair_limit_binding_supported`、`bind_mq_pair_limit`）
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv:2125-2130`（`assert_driver_mq_dispatch_uses_dut_cap`）
- Test: `virtio_dut_caps_test`、全回归

**Interfaces:**
- Consumes：
  - HEAD `function bit mq_pair_limit_binding_supported(input int unsigned configured_limit, output string why)`（`:88`）
  - HEAD `function bit bind_mq_pair_limit(input int unsigned configured_limit, output string why)`（`:119`）
  - 调用者：`virtio_function_instance.sv:272`（preflight）、`:372`（commit），以及 P2.5 之后的绑定路径。
- Produces:
  - 两个函数签名不变。
  - `configured_limit == 0` 时返回 0，并给出 `why = "FSM MQ pair limit must be a nonzero per-function value"`。
  - 未绑定 FSM 的默认上限（构造函数 `:72` 中的 `DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE`）不变。

依据：
- spec 把 P4.3 中 auto_fsm 的位置标为 `~:85`。HEAD `:84-86` 注释原文是：“Zero is the compatibility encoding used by standalone/legacy driver configs created before this field existed.”
- 维护测试中唯一依赖这一编码的是 dut_caps `:2125`：它期望 `bind_mq_pair_limit(0, why)` 成功。
- env Function 的 `drv_cfg.max_vio_net_qpairs_per_device` 由 `virtio_net_env_config::make_default_driver_config()`（`virtio_net_env_config.sv:210`）赋值，是非零的 `max_pairs`。
- HEAD 中用默认（0）`drv_cfg` 绑定的只有 full/dual 的 standalone `binding_function_*`，它们已在 P4-4/P4-5 中删除。

- [ ] **Step 0: 确认点**

向用户确认：spec P4.3 中的 “auto_fsm (~:85)” 是否指 MQ 上限 0 兼容编码（本任务），而不只是 `iommu_host_id()` 的 host0 兜底（已在 P4-8 处理）。如果用户否定，跳过本任务，并在 Notes 中保留“MQ 0 兼容编码仍在”的说明。

- [ ] **Step 1: 写失败测试**

`virtio_dut_caps_test.sv:2125-2130`：
```systemverilog
// old
        if (!standalone_fsm_probe.bind_mq_pair_limit(0, why) ||
            (standalone_fsm_probe.observed_max_supported_qpairs() != 32)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "legacy zero-valued qpair-limit bind was not compatible: %s",
                why))
        end
// new
        if (standalone_fsm_probe.bind_mq_pair_limit(0, why) ||
            (why != "FSM MQ pair limit must be a nonzero per-function value") ||
            (standalone_fsm_probe.observed_max_supported_qpairs() != 32)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "zero-valued qpair-limit bind was not rejected: %s", why))
        end
```
`:2120-2124` 中“未绑定 FSM 默认 32”的检查保持不变：它验证的是未绑定时的默认值，与 0 兼容编码无关。

- [ ] **Step 2: 运行，确认失败**

SYNC 后运行 ONE TEST（`virtio_dut_caps_test`）。预期 FAIL：`UVM_FATAL ... [DUT_CAPS] zero-valued qpair-limit bind was not rejected: `。

- [ ] **Step 3: 实现**

把 `virtio_auto_fsm.sv:84-136` 中的两个函数（含各自注释）替换为：
```systemverilog
    // Snapshot the function's effective MQ limit.  The limit always comes
    // from the function's frozen DUT capability and must be nonzero.
    // Repeated binds are idempotent, but a different value is rejected so a
    // live FSM cannot diverge from its configured queue state.
    function bit mq_pair_limit_binding_supported(
        input int unsigned configured_limit,
        output string why
    );
        if (configured_limit == 0) begin
            why = "FSM MQ pair limit must be a nonzero per-function value";
            return 0;
        end
        if (configured_limit > DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) begin
            why = $sformatf(
                "FSM MQ pair limit %0d exceeds model ceiling %0d",
                configured_limit, DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
            return 0;
        end
        if (!mq_pair_limit_bound ||
            (configured_limit == max_vio_net_qpairs_per_device)) begin
            why = "";
            return 1;
        end
        why = $sformatf(
            "FSM MQ pair limit is already bound to %0d; cannot rebind to %0d",
            max_vio_net_qpairs_per_device, configured_limit);
        return 0;
    endfunction

    // 把 function 级 MQ 队列对上限绑定进 FSM：上限必须非零；首次绑定生效并置
    // mq_pair_limit_bound，重复绑定同值幂等，改绑不同值被
    // mq_pair_limit_binding_supported 拒绝（why 给出原因）。
    // 返回 1 表示绑定成功或幂等命中。
    function bit bind_mq_pair_limit(
        input int unsigned configured_limit,
        output string why
    );
        if (!mq_pair_limit_binding_supported(configured_limit, why))
            return 0;
        if (!mq_pair_limit_bound) begin
            max_vio_net_qpairs_per_device = configured_limit;
            mq_pair_limit_bound = 1;
        end
        why = "";
        return 1;
    endfunction
```
dut_caps 中已有的文本断言不变：“exceeds model ceiling 32”（`:2525-2526`）和 “already bound to 1; cannot rebind to 2”（`:2163-2164`、`:2176`）。

- [ ] **Step 4: 运行，确认通过**

SYNC 后运行 `virtio_dut_caps_test`、`virtio_monitor_routing_test`、`virtio_pf_lifecycle_reset_test`、`virtio_admin_vq_test`。预期 0 WARNING/ERROR/FATAL。

如果出现 `could not bind its MQ pair limit: FSM MQ pair limit must be a nonzero per-function value`，说明某条绑定路径仍在使用默认为 0 的 `drv_cfg`，这是 standalone 残留。此时停止并报告调用点。修复方式是给该 Function 配置 `drv_cfg = cfg.make_default_driver_config(<pairs>)`，但需先经用户确认。

- [ ] **Step 5: grep 证明**

```bash
grep -nE "configured_limit == 0\)\)|compatibility encoding|0/未知按模型上限展开|isunknown\(configured_limit\)" virtio_net_vip/src/agent/virtio_auto_fsm.sv
```
预期：无输出。

- [ ] **Step 6: REGRESSION**。预期 `STRICT_REGRESSION PASS tests=<N>`。

- [ ] **Step 7: Commit**

```bash
git add virtio_net_vip/src/agent/virtio_auto_fsm.sv virtio_net_vip/tests/virtio_dut_caps_test.sv
git commit -m "refactor: 删除 FSM MQ 上限为 0 的 standalone 兼容编码"
```

---

### Notes for integrator（P4）

**本阶段产出、其他阶段或后续设计会用到的接口**
- `virtio_real_driver_flow_fixture`（P4-3）：
  - `int unsigned vio_pf_count`，默认 1；
  - `int pcie_cpl_timeout_ns`，默认 100000；
  - `function virtio_function_instance function_by_bdf(input bit [15:0] bdf)`；
  - `install_endpoint_image()` 为非 AF 的 VIO PF 安装 common-config 镜像。
- `static function dpu_pcie_function_id_t virtio_vq_test_kit::host0_pcie_id(input bit [15:0] bdf)`（P4-8）。
- 无 identity 或缺 transport 时一律 fatal（P4-8）。后续 af_direct / verify_snapshot 设计不得再假设 host0 兜底：
  - `virtio_pci_transport::iommu_host_id()`：无 identity 时 fatal；
  - `virtio_atomic_ops::get_iommu_host_id()`、`virtio_auto_fsm::iommu_host_id()`：缺 transport 时 fatal。
- IOMMU 只剩 `*_for_host` 接口；test double 覆写 `map_for_host/unmap_for_host`（P4-2）。
- 发现策略只剩 `virtio_fabric_preconfigured_discovery`，并且是 transport 构造时的缺省策略；`discovery_strategy_name()` 缺省返回 `"fabric_preconfigured"`。verify_snapshot 继承 `virtio_discovery_strategy`，通过 `set_discovery_strategy()` 安装（P4-6）。
- `bind_mq_pair_limit(0, ...)` 返回失败（P4-9，以确认点结论为准）。

**依赖与顺序假设（执行前核对）**
- P1.7 已删除 IOMMU 中无调用的 dirty/live 查询包装；P4-2 Step 1/5 会兜底删除残留的非 host 包装。
- P2.5：`bind_pcie_components` 已删除，`wire_shared/bind_pcie` 为一行包装（P3.md 的前置假设与此一致）。dut_caps 中 HEAD `:2146/:2178/:2528` 的绑定用例由 P2.5 改写。P4-7 只删除 `wire_shared/bind_pcie` 及其覆写和计数器；P4-8 Step 5 在 dut_caps 中插入 identity 时，以 P2.5 之后的 transport 变量为准。
- P2-3b 新增 `virtio_dma_buffer_set::map(idx, dir)`，P4-1 的 grep 已用前缀 `iommu*`/`super` 排除它。P2-3 的 `dma_set.bind_domain(..., get_iommu_host_id(transport), ...)` 在 P4-8 之后对缺 transport 的情况会 fatal，这是预期行为。
- P2.7：fixture 的 `start_driver_flow` 不再调用 `full_init_sequence`。P4-4/P4-5 不调用 `start_driver_flow`，只调用 `discover_and_init_bars()`。
- P2.8：`tests/virtio_vq_test_kit.sv` 是 `class virtio_vq_test_kit`（静态方法）且已列入 `filelists/tests.f`；`virtio_mock_transport` 替换了 4 个测试的 transport 子类。P4-8 表中的 `transport.bdf = ...` 行如果已被 P2.8 收进辅助函数，只改辅助函数。`virtio_perf_monitor_ext` 已并入 `virtio_perf_monitor.configure_bw()`，P4-5 不触碰 `bw_mon` 代码。
- P3-2（`plan_parts/P3.md`）：
  - `virtio_discovery_strategy.sv` 同时定义 `virtio_enumerate_discovery` 和 `virtio_fabric_preconfigured_discovery`；
  - transport 在 `new()` 中缺省构造 enumerate，`configure_fabric_managed()` 切换为 fabric；
  - FSM 已只调用 `discover_and_init_bars()`；
  - unit 测试 `test_discovery_strategy_selection` 断言缺省为 `"enumerate"`，P4-6 改为 `"fabric_preconfigured"`。
- P3 的其余部分：`iommu_host_id()` 可能已移入 `virtio_migration_engine`，`get_iommu_host_id()` 所在的 atomic ops 子文件用 grep 定位。P3-1 对 fixture 的 execution_profile 改造不影响 P4-3 的锚点（device builder 段、`cpl_timeout_ns`、`install_endpoint_image`）。如果 `execution_mode()` 被替换，P4-4/P4-5 中的 MODEL 判断按 P3-1 的接口改写。
- P0.4：private ring 测试已进入 manifest，名称以 P0.4 为准，文中以 `dpu_priv_driver_flow_test` 指代。P4-7 修改了 `examples/dpu_priv_ring/dpu_priv_driver_flow_test.sv`。
- P4-4 把 `filelists/tests.f` 中的 fixture 行前移。如果 P2.8/P3 新增的测试公共件也被 fixture 引用，需要排在 fixture 之前。

**风险**
- P4-4/P4-5 是 spec 标注的高风险项。两个测试从“手写 EP 镜像 + 测试私有 PCIe 配置”迁到 fixture（`scb_enable=1`，monitor/observer/协议断言全开）。两处 Step 6 都设了确认点：任何非等价差异都先停下确认测试意图，不改断言。
  - dual 的 VIP B 从“共享 A 的 BAR 的第二个 requester”变为“snapshot 中的第二个 PF”，这是必然的建模变化，需在确认点向用户说明。
- P4-3 让两个 PF 共用一个 EP 配置空间：各自的 discovery 会重写 BAR 寄存器，后写者覆盖前者。之后的 MMIO 只用各自 lease 的基址，不回读配置空间中的 BAR。如果未来测试打破这个前提，需要另建多 EP 模型。
- P4-8 改变了 transport 的失败模式：从静默落到 host0 变成 fatal，可能暴露 spec 未列出的 standalone 用法。Step 4 以 FAIL 列表驱动迁移。`virtio_monitor` 保留“未绑定 transport 报告 host 0”的观测规则（与 `monitor_segment_id` 一致），该值不参与 DMA。
- P4-6 改变了 transport 的缺省发现策略：非 Fabric transport 调用发现时，从“执行 BAR 枚举”变为 fatal。HEAD 中维护测试里唯一的此类调用来自 full/dual，已由 P4-4/P4-5 移除；`virtio_e2e_test` 绕过了发现，不受影响。

**Spec deviations（汇总）**
1. P4.3 受影响的测试多于 spec 所列（dut_caps、unit），还包括：
   - admin_vq、indirect_desc、pf_lifecycle_reset、migration_dirty：需要补 transport identity；
   - monitor：改为在 src 侧调整观测规则；
   - `examples/dpu_priv_ring/dpu_priv_driver_flow_test`：调用了 `wire_shared`，而它绑定的 Function 实际上已有 identity。
2. P4.2 需要扩展共享 fixture（多 PF 镜像、completion 超时旋钮、`function_by_bdf`），否则 dual 测试无法用 snapshot 生成第二个端点。dual 测试的 5 个子测试本身不经过 PCIe，迁移只影响初始化段。
3. P4.3 中 auto_fsm 的 “~:85” 解读为 MQ 上限 0 兼容编码，另外处理 `iommu_host_id()` 的 host0 兜底。P4-9 设了确认点。
4. P4.1 的迁移测试列表与 spec 一致；`examples/` 中没有非 host 的 IOMMU 调用。

**范围外但已发现的遗留（本阶段不处理，建议作为后续条目）**
- `virtio_iommu_model.active_dirty_generation_by_host`（`:82`、`:725`）只写不读。
- `virtio_pcie_observer_adapter::commit_mandatory_function_binding()`（`:78-100`）中，对无 identity transport 的非身份绑定分支。
- `virtio_e2e_test.sv:798-806` 直接改写 env Function 的 `bar_base[]` 后做 capability 发现，绕过了 Fabric lease 编程。
- `virtio_dynamic_reconfig` 的 “standalone 默认 32 qpairs”（dut_caps `:1965-2016` 覆盖）。
- `virtqueue_base`/`virtqueue_manager` 的 `host_id` 默认为 0（独立 virtqueue 单元测试依赖它）。
- 行数：本阶段预计 src/tests 净删约 1,100 行（full −430、dual −330、bar accessor −150、IOMMU −110、function instance −45、enumerate 策略 −35，新增约 120），高于 spec 估算的 600。验收统计时按实际记录。

---

