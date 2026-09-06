# Virtio Model/Real-DUT Execution Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task with verification checkpoints.

**Goal:** 保留可独立运行的 virtio 设备模拟器，同时增加真实 DUT 旁路模式，并将 PCIe TL 依赖切换到外部 `pcie_work`。

**Architecture:** 使用一个全局执行模式枚举选择 `MODEL` 或 `REAL_DUT`。MODEL 模式由现有 responder 作为设备行为模拟器，经过项目内测试专用 DMA adapter 产生 PCIe TLP；REAL_DUT 模式不创建主动 responder，由真实 DUT 产生 TLP，外部 `pcie_work` 和共享 `host_mem` 负责协议及内存服务。两种模式共用 driver、queue、Host memory、packet 和 scoreboard。

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS, external `pcie_work/pcie_tl_vip`, external `host_mem`, external `net_packet`。

**Spec:** `docs/superpowers/specs/2026-09-06-virtio-model-real-dut-execution-modes-design.md`

## Global Constraints

- 所有 PCIe TL 源文件必须从 `$PCIE_WORK_ROOT/pcie_tl_vip/src` 编译，主工程不得再从 `virtio_net_vip/ext/pcie_tl_vip` 编译源码。
- `MODEL` 模式的 DMA adapter 仅是测试模型，不能在 REAL_DUT 模式绑定、启动或补发 TLP。
- 所有模式复用外部 `host_mem_api`；同一个 Host 的 PF/VF/Root 共享 manager，不同 Host 使用不同 manager。
- 每个 PF/VF 的 VIO queue pair 上限保持 `DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE`（当前为 32）。
- 使用中文注释解释模式边界、Host memory 归属和 REAL_DUT 旁路规则。
- 仿真验证必须在 `10.11.10.53` 使用登录 shell 的 VCS 环境执行。
- 不覆盖或丢弃当前工作树已有修改；解除本地 PCIe 子模块前必须保存可恢复的二进制 diff 备份。

## File Map

- Modify: `virtio_net_vip/src/types/virtio_net_types.sv` — 增加执行模式和完成方式枚举。
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv` — 保存模式、解析命令行、校验模式冲突。
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv` — 根据模式禁止或启动主动 responder，并保持共享 Host memory 绑定。
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv` — 编译新的模式和 MODEL DMA adapter 文件。
- Create: `virtio_net_vip/src/pcie/virtio_pcie_model_dma_adapter.sv` — 使用远程 EP driver 的公开 `send_tlp()` 实现测试专用 DMA Read/Write。
- Modify: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv` — 仅允许 MODEL 模式运行，调用 adapter，不直接依赖本地 PCIe 扩展 API。
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv` — 支持模式配置、共享 adapter 和 MSI-X/polling 选择。
- Create: `virtio_net_vip/tests/virtio_execution_mode_test.sv` — 检查默认 MODEL、REAL_DUT 旁路和非法配置。
- Create: `virtio_net_vip/tests/virtio_model_completion_mode_test.sv` — 覆盖 MSI-X 与 polling 的完整 TX/RX 完成路径。
- Create: `virtio_net_vip/tests/virtio_model_full_queue_test.sv` — 覆盖满队列、多队列、回收和大流量。
- Modify: `filelists/virtio_net.f`, `filelists/tests.f`, `scripts/test_manifest.sh` — 加入新源文件和外部 PCIe 编译顺序。
- Modify: `scripts/check_deps.sh`, `scripts/bootstrap.sh` — 检查 `$PCIE_WORK_ROOT`，停止初始化本地 PCIe 子模块。
- Modify: `README.md`, `docs/virtio_net_vip_manual.md` — 记录两种模式、外部依赖和运行命令。

### Task 1: Add execution and completion mode contracts

**Files:**
- Modify: `virtio_net_vip/src/types/virtio_net_types.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`
- Create: `virtio_net_vip/tests/virtio_execution_mode_test.sv`
- Test list: `filelists/tests.f`, `scripts/test_manifest.sh`

**Interfaces:**
- Produce `virtio_execution_mode_e` with `VIRTIO_EXEC_MODEL` and `VIRTIO_EXEC_REAL_DUT`.
- Produce `virtio_completion_mode_e` with `VIRTIO_COMPLETION_MSIX` and `VIRTIO_COMPLETION_POLLING`.
- Add `virtio_net_env_config.execution_mode`, defaulting to `VIRTIO_EXEC_MODEL`.
- Add `virtio_net_env_config.completion_mode`, defaulting to `VIRTIO_COMPLETION_MSIX`.
- Add `function bit apply_plusargs(output string why)` and `function bit validate_execution_mode(output string why)`.

- [ ] **Step 1: Write the failing configuration test**

  In `virtio_execution_mode_test.sv`, create a config object and assert:

  ```systemverilog
  if (cfg.execution_mode != VIRTIO_EXEC_MODEL)
      `uvm_error("MODE", "default execution mode is not MODEL")
  cfg.execution_mode = VIRTIO_EXEC_REAL_DUT;
  if (!cfg.validate_execution_mode(why))
      `uvm_error("MODE", why)
  ```

  Also set `+VIRTIO_EXEC_MODE=REAL_DUT` in the test invocation and assert the parsed enum is `VIRTIO_EXEC_REAL_DUT`.

- [ ] **Step 2: Run the focused test before implementation**

  Run on 53:

  ```bash
  vcs -full64 -sverilog -ntb_opts uvm-1.2 -f filelists/virtio_net.f -f filelists/tests.f \
      -top virtio_tb_top -o simv_mode -l compile_mode.log
  ./simv_mode +UVM_TESTNAME=virtio_execution_mode_test -l mode_fail.log
  ```

  Expected result: compile failure because the new enum/config methods do not exist.

- [ ] **Step 3: Implement the enums and configuration methods**

  Put the enums next to the existing virtio policy enums. `apply_plusargs()` accepts only `MODEL` and `REAL_DUT` for `VIRTIO_EXEC_MODE`, accepts `MSIX` and `POLLING` for `VIRTIO_COMPLETION_MODE`, and returns a readable error for every other value. `validate_execution_mode()` rejects a null/invalid enum value and rejects any configuration that requests REAL_DUT while an active model responder has been explicitly bound.

- [ ] **Step 4: Run the focused test after implementation**

  Expected result: UVM_ERROR/UVM_FATAL are both zero; default mode is MODEL, plusarg mode is REAL_DUT, and invalid strings return a validation error without changing the previous valid configuration.

- [ ] **Step 5: Commit the isolated contract change**

  ```bash
  git add virtio_net_vip/src/types/virtio_net_types.sv \
      virtio_net_vip/src/env/virtio_net_env_config.sv \
      virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/virtio_execution_mode_test.sv \
      filelists/tests.f scripts/test_manifest.sh
  git commit -m "feat: add virtio model and real DUT execution modes"
  ```

### Task 2: Isolate the existing responder as a MODEL-only device simulator

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`
- Modify: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`
- Modify: `virtio_net_vip/tests/virtio_execution_mode_test.sv`

**Interfaces:**
- `virtio_pcie_dut_responder.bind_function(...)` remains source compatible.
- Add `function bit model_only();` returning 1.
- Add `function bit active();` and `function bit can_start(virtio_execution_mode_e mode, output string why);`.
- Change fixture startup to call `responder.start()` only when `cfg.execution_mode == VIRTIO_EXEC_MODEL`.
- REAL_DUT mode must leave `responder` null or unbound and must not consume notify FIFO.

- [ ] **Step 1: Add mode assertions to the test**

  Extend `virtio_execution_mode_test.sv` with a MODEL fixture assertion that `active()` becomes true after startup, and a REAL_DUT fixture assertion that no responder is created/bound and no worker count is non-zero.

- [ ] **Step 2: Run the test to observe the current conflict**

  Run both mode variants. Expected result before implementation: REAL_DUT still creates or starts the responder, proving the guard is missing.

- [ ] **Step 3: Add the MODEL-only guard**

  In `virtio_net_env`, perform the mode check before `bind_function_pcie*` starts any responder. In the fixture, construct and bind the responder only for MODEL. Add Chinese diagnostics that identify the accidental dual-driver case as a fatal configuration error.

- [ ] **Step 4: Run both mode variants**

  ```bash
  ./simv_mode +UVM_TESTNAME=virtio_execution_mode_test +VIRTIO_EXEC_MODE=MODEL
  ./simv_mode +UVM_TESTNAME=virtio_execution_mode_test +VIRTIO_EXEC_MODE=REAL_DUT
  ```

  Expected result: MODEL has one active responder; REAL_DUT has no active responder and no fatal error.

- [ ] **Step 5: Commit the isolation change**

  ```bash
  git add virtio_net_vip/src/env/virtio_net_env.sv \
      virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv \
      virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv \
      virtio_net_vip/tests/virtio_execution_mode_test.sv
  git commit -m "feat: isolate virtio responder to model mode"
  ```

### Task 3: Replace the local PCIe DMA extension with a MODEL test adapter

**Files:**
- Create: `virtio_net_vip/src/pcie/virtio_pcie_model_dma_adapter.sv`
- Modify: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`
- Test: `virtio_net_vip/tests/virtio_real_driver_flow_test.sv`, `virtio_net_vip/tests/virtio_real_driver_rx_test.sv`

**Interfaces:**
- `class virtio_pcie_model_dma_adapter extends uvm_object`.
- `function bit bind(pcie_tl_ep_driver ep_driver, bit [15:0] requester, output string why)`.
- `task read(input bit [63:0] addr, input int unsigned size, output bit [7:0] data[])`.
- `task write(input bit [63:0] addr, input bit [7:0] data[])`.
- The adapter uses only remote VIP public `pcie_tl_ep_driver.send_tlp()` and the request fields `rb_done`, `rb_data`, and `rb_status`; it must not call `dma_read_tlp()` or `dma_write_tlp()`.

- [ ] **Step 1: Add adapter API tests**

  Add a small test in `virtio_real_driver_flow_test.sv` that binds the adapter to the EP driver, writes a 17-byte pattern at an unaligned 64-bit address, reads it back, and compares all bytes.

- [ ] **Step 2: Run the adapter test against the current local VIP**

  Expected result: the test compiles only after the adapter is included; the existing responder path still uses its old custom methods, so this step establishes the new API without changing the responder.

- [ ] **Step 3: Implement legal TLP construction**

  For a request at `addr` and `size`, align the TLP address down to a DWORD boundary, compute `dw_count = (size + addr[1:0] + 3) / 4`, calculate exact first/last byte enables, pad writes to complete DWORDs, set `FMT_3DW/FMT_4DW`, `TLP_MEM_RD/TLP_MEM_WR`, requester BDF and `CONSTRAINT_LEGAL`, and reject a transfer that exceeds 1024 DWORDs. Reads wait up to 100 us for `rb_done` and return exactly the requested byte range from `rb_data`.

- [ ] **Step 4: Route the responder through the adapter**

  Replace direct calls to `m_ep_driver.dma_read_tlp()` and `m_ep_driver.dma_write_tlp()` with adapter calls. Keep the existing IOMMU/page-boundary split in the responder because it is part of the MODEL behavior. Add a fatal bind error if the adapter is absent in MODEL mode.

- [ ] **Step 5: Run the real-driver TX/RX tests**

  Run `virtio_real_driver_flow_test`, `virtio_real_driver_rx_test`, and `virtio_real_driver_multiqueue_test`; expected request/completion matching and payload mismatch counters remain unchanged from the previous passing baseline.

- [ ] **Step 6: Commit the adapter migration**

  ```bash
  git add virtio_net_vip/src/pcie/virtio_pcie_model_dma_adapter.sv \
      virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv \
      virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/virtio_real_driver_flow_test.sv \
      virtio_net_vip/tests/virtio_real_driver_rx_test.sv
  git commit -m "feat: add model-only PCIe DMA adapter"
  ```

### Task 4: Switch PCIe source and dependency checks to external pcie_work

**Files:**
- Modify: `filelists/virtio_net.f`
- Modify: `filelists/tests.f`
- Modify: `scripts/check_deps.sh`
- Modify: `scripts/bootstrap.sh`
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`
- Remove from tracked build dependency: `virtio_net_vip/ext/pcie_tl_vip`

**Interfaces:**
- Required environment variable: `PCIE_WORK_ROOT`, resolving to an external checkout whose `pcie_tl_vip/src` exists.
- Required pinned revision for the checked remote `main`: `c2dc2a177892f6a53d71c336493ca7d8dddce42f`.
- Required source files: `pcie_tl_if.sv`, `shared/pcie_tl_bdf_utils_pkg.sv`, `shared/pcie_tl_device_profile_pkg.sv`, `topology/pcie_topology_pkg.sv`, `pcie_tl_pkg.sv`, `env/pcie_tl_env.sv`, `agent/pcie_tl_ep_driver.sv`.

- [ ] **Step 1: Save the dirty local submodule before changing tracking**

  ```bash
  backup_dir="../virtio_work-pcie_tl_vip-local-backup-$(date +%Y%m%d%H%M%S)"
  mkdir -p "$backup_dir"
  git -C virtio_net_vip/ext/pcie_tl_vip diff --binary > "$backup_dir/local.diff"
  cp -a virtio_net_vip/ext/pcie_tl_vip/. "$backup_dir/tree/"
  ```

  Verify that `local.diff` and `tree/` exist before removing the tracked gitlink. Do not delete the backup.

- [ ] **Step 2: Add dependency-check failure coverage**

  Extend `scripts/check_deps.sh` with `PCIE_WORK_ROOT`, origin and SHA checks, and a required-source check. Run it with `PCIE_WORK_ROOT` unset and with a temporary checkout at the wrong revision; expected failures must identify the missing variable or SHA mismatch.

- [ ] **Step 3: Change the PCIe filelist compile order**

  Compile the external sources in this order:

  ```text
  +incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src
  +incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src/topology
  $PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_if.sv
  $PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_bdf_utils_pkg.sv
  $PCIE_WORK_ROOT/pcie_tl_vip/src/shared/pcie_tl_device_profile_pkg.sv
  $PCIE_WORK_ROOT/pcie_tl_vip/src/topology/pcie_topology_pkg.sv
  $PCIE_WORK_ROOT/pcie_tl_vip/src/pcie_tl_pkg.sv
  ```

  Keep Host memory sources before the PCIe package and keep the local virtio package after the external package.

- [ ] **Step 4: Stop bootstrap from initializing the PCIe submodule**

  Remove only `virtio_net_vip/ext/pcie_tl_vip` from the bootstrap update list and dependency comments. Leave the Host memory initialization unchanged. Remove the tracked PCIe gitlink only after the backup and external filelist compile check succeed.

- [ ] **Step 5: Update user-facing dependency documentation**

  Document `PCIE_WORK_ROOT`, the pinned revision, the MODEL-only adapter, the REAL_DUT bypass, and the two run commands. Remove statements claiming the PCIe VIP is a local submodule.

- [ ] **Step 6: Compile the complete filelist**

  Run `scripts/check_deps.sh`, then compile on 53 with the external checkout. Expected result: no source path under `virtio_net_vip/ext/pcie_tl_vip` appears in the VCS command log, and the package compiles with zero errors.

- [ ] **Step 7: Commit the dependency switch**

  ```bash
  git add filelists/virtio_net.f filelists/tests.f scripts/check_deps.sh \
      scripts/bootstrap.sh README.md docs/virtio_net_vip_manual.md
  git rm virtio_net_vip/ext/pcie_tl_vip
  git commit -m "build: use external pcie_work PCIe TL VIP"
  ```

### Task 5: Add complete MODEL completion and queue stress coverage

**Files:**
- Create: `virtio_net_vip/tests/virtio_model_completion_mode_test.sv`
- Create: `virtio_net_vip/tests/virtio_model_full_queue_test.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`
- Modify: `filelists/tests.f`, `scripts/test_manifest.sh`

**Interfaces:**
- Completion test sets `cfg.completion_mode` to `VIRTIO_COMPLETION_MSIX` or `VIRTIO_COMPLETION_POLLING` and sets the matching driver interrupt policy.
- Full-queue test uses the fixture's shared `host_mem`, `virtio_pcie_dut_responder.inject_rx_packet()`, and packet adapter; it does not allocate a private memory model.

- [ ] **Step 1: Add MSI-X and polling test variants**

  Run the same TX/RX body twice. In MSI-X mode assert interrupt count is non-zero and polling completion count is zero; in polling mode assert no MSI-X is required and the driver observes used-ring progress.

- [ ] **Step 2: Add full-queue setup**

  Configure four queues, queue size 256, fill every available descriptor, issue notify for each queue, and continue until at least 4096 TX and 4096 RX packets have completed. Use randomized packet sizes from 64 to 9216 bytes and keep a per-queue expected payload map.

- [ ] **Step 3: Add reclaim and reset checks**

  After each batch, assert descriptor allocations return to the pre-batch live count. Reset the function while workers are active, wait for `responder.wait_stopped()`, verify no worker remains, and assert the shared Host memory manager can allocate the released buffers again.

- [ ] **Step 4: Run focused MODEL tests**

  Run both completion modes, the full queue test, indirect descriptor test, queue semantics test, RX test and multi-queue test. Expected result: zero UVM errors/fatals, no payload mismatches, no request/completion leaks, and no Host memory leak.

- [ ] **Step 5: Commit the stress coverage**

  ```bash
  git add virtio_net_vip/tests/virtio_model_completion_mode_test.sv \
      virtio_net_vip/tests/virtio_model_full_queue_test.sv \
      virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv \
      filelists/tests.f scripts/test_manifest.sh
  git commit -m "test: cover virtio model completion and full queues"
  ```

### Task 6: Add REAL_DUT passive integration checks

**Files:**
- Create: `virtio_net_vip/src/pcie/virtio_real_dut_observer.sv`
- Create: `virtio_net_vip/tests/virtio_real_dut_mode_test.sv`
- Modify: `virtio_net_vip/src/virtio_net_pkg.sv`
- Modify: `filelists/tests.f`, `scripts/test_manifest.sh`

**Interfaces:**
- `virtio_real_dut_observer` is a passive UVM subscriber/analysis component; it has no `start()` method that generates TLP.
- It records notify count, observed DUT PCIe requests/completions, MSI-X writes and Host memory data checks.
- `virtio_real_dut_mode_test` sets `VIRTIO_EXEC_REAL_DUT`, binds shared Host memory and PCIe monitors, and fails if any MODEL responder or MODEL DMA adapter becomes active.

- [ ] **Step 1: Write the passive-mode test**

  Assert that REAL_DUT setup completes without creating a model responder, and expose counters for external DUT traffic. With no RTL DUT connected, the test must end with a clear “no DUT traffic observed” warning rather than fabricating traffic.

- [ ] **Step 2: Implement the passive observer**

  Connect the observer to the existing PCIe monitor and virtio monitor analysis ports. Do not read descriptor memory or update used rings from this component; those are DUT responsibilities in REAL_DUT mode.

- [ ] **Step 3: Run the passive-mode test**

  Expected result: zero UVM errors/fatals, zero model DMA requests, and an explicit no-DUT-traffic diagnostic when the test is run without an RTL DUT.

- [ ] **Step 4: Commit the REAL_DUT boundary**

  ```bash
  git add virtio_net_vip/src/pcie/virtio_real_dut_observer.sv \
      virtio_net_vip/src/virtio_net_pkg.sv \
      virtio_net_vip/tests/virtio_real_dut_mode_test.sv \
      filelists/tests.f scripts/test_manifest.sh
  git commit -m "feat: add passive real DUT virtio mode"
  ```

### Task 7: Run full regression and verify dependency isolation

**Files:**
- Modify only if failures reveal a concrete issue: `scripts/test_manifest.sh`, `README.md`, `docs/virtio_net_vip_manual.md`.
- Test logs: `/home/ubuntu/virtio_codex.V3EaQt/` on 53; do not commit logs.

**Interfaces:**
- MODEL regression uses `+VIRTIO_EXEC_MODE=MODEL`.
- REAL_DUT smoke uses `+VIRTIO_EXEC_MODE=REAL_DUT` and requires an attached DUT for traffic assertions.

- [ ] **Step 1: Verify clean external dependency selection**

  On 53, set `DPU_COMMON_ROOT`, `NET_PACKET_ROOT`, `PCIE_WORK_ROOT`, VCS variables and run `scripts/check_deps.sh`. Confirm the reported PCIe SHA is `c2dc2a177892f6a53d71c336493ca7d8dddce42f` and no local PCIe subtree is used.

- [ ] **Step 2: Compile once with the complete filelist**

  Compile using the project VCS script and save the log. Expected result: zero compile errors; only pre-existing external `net_packet` warnings are allowed.

- [ ] **Step 3: Run MODEL regression**

  Run execution-mode, real-driver flow, RX, multiqueue, queue semantics, indirect descriptor, host memory reclaim, completion mode and full queue tests with `+VIRTIO_EXEC_MODE=MODEL`. Record UVM and PCIe request/completion statistics.

- [ ] **Step 4: Run REAL_DUT smoke**

  Run the passive real-DUT test with `+VIRTIO_EXEC_MODE=REAL_DUT`. With an RTL DUT attached, require observed DUT PCIe traffic and matching Host memory data; without an RTL DUT, require only the explicit no-traffic diagnostic and no model-generated traffic.

- [ ] **Step 5: Review repository state**

  Run `git status --short`, `git diff --check`, and `git ls-files virtio_net_vip/ext/pcie_tl_vip`. Expected result: no tracked local PCIe source, no accidental changes to unrelated user work, and the backup directory remains outside the repository.

- [ ] **Step 6: Commit final documentation or test fixes**

  ```bash
  git add README.md docs/virtio_net_vip_manual.md scripts/test_manifest.sh
  git commit -m "test: verify model and real DUT execution paths"
  ```
