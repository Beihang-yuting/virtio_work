# PCIe Per-Root Host-Memory Binding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect every PCIe Root unified-memory responder to its top-level, per-Host `host_mem_manager` without resetting an existing 64-bit aperture.

**Architecture:** The top level resolves concrete managers from `host_mem_pool`, while `pcie_tl_env_config` accepts protocol-neutral `host_mem_api` handles indexed by Root. `pcie_tl_env` validates and distributes those handles to the existing RC DMA responders, retaining only a root-0 config-db fallback for legacy single-Root tests.

**Tech Stack:** SystemVerilog, UVM, `host_mem_pkg`, `pcie_tl_vip`, VCS.

**Spec:** `docs/superpowers/specs/2026-09-02-pcie-host-memory-binding-design.md`

## Global Constraints

- Do not add a second PCIe DMA responder or an IOVA translation layer.
- Do not make `pcie_tl_pkg` depend on `virtio_net_pkg` or `host_mem_pool`.
- Preserve already initialized Host-memory and device-memory apertures.
- Require complete explicit bindings for every enabled Root in multi-Root mode.
- Preserve the legacy `"host_mem"` config-db path for a single Root.
- Run every simulation on `ubuntu@10.11.10.53` through a Bash login shell.
- Preserve all unrelated dirty-worktree changes and do not commit or push without a new user request.

---

### Task 1: Executable Per-Root Binding Contract

**Files:**
- Create: `virtio_net_vip/tests/virtio_pcie_host_mem_test.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`
- Modify: `README.md` (maintained-test list only)
- Modify: `docs/virtio_net_vip_manual.md` (maintained-test list only)

**Interfaces:**
- Consumes: `host_mem_pool.create_host()`, `host_mem_pool.get_host()`, the existing DPU/VIO environment construction flow, and PCIe EP TLM sequencers.
- Produces: maintained UVM test `virtio_pcie_host_mem_test` specifying the config API and end-to-end two-Root behavior.

- [x] **Step 1: Write the failing integration test**

  Create two Hosts with the same high GPA aperture and preallocate the same
  numerical address from each. Build one Host-0 VIO environment and a
  two-Root/two-EP PCIe environment. The test calls this not-yet-implemented
  API:

  ```systemverilog
  if (!pcie_cfg.bind_host_memory(0, 0, host0_mem, why))
      `uvm_fatal("PCIE_HOST_MEM_TEST", {"root0 bind failed: ", why})
  if (!pcie_cfg.bind_host_memory(1, 1, host1_mem, why))
      `uvm_fatal("PCIE_HOST_MEM_TEST", {"root1 bind failed: ", why})
  ```

  In `run_phase`, use `pcie_tl_rw_seq` on `ep_agents[0]` and
  `ep_agents[1]` to perform fixed-payload writes and completion-backed reads.
  Compare both returned byte arrays to hand-authored Host-specific patterns.

- [x] **Step 2: Register the focused test exactly once**

  Add the source before `virtio_tb_top.sv` in `filelists/tests.f`, and add
  `virtio_pcie_host_mem_test` once to `VIRTIO_MAINTAINED_TESTS` in
  `scripts/test_manifest.sh`. Insert the same test name at the same list
  position in README and the manual so the existing documentation-contract
  checker continues to validate the manifest as the single source of truth.

- [x] **Step 3: Run the static manifest check locally**

  Run: `bash scripts/test_manifest.sh`

  Expected: PASS with no output.

- [x] **Step 4: Synchronize and verify RED on the VCS host**

  Run the compile path for `virtio_pcie_host_mem_test` on `10.11.10.53`.

  Expected: compile failure naming missing methods such as
  `bind_host_memory`; the failure must be caused by the absent production
  interface rather than syntax or testbench setup.

### Task 2: Configuration Mapping and Root Distribution

**Files:**
- Modify: `virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/env/pcie_tl_env_config.sv`
- Modify: `virtio_net_vip/ext/pcie_tl_vip/pcie_tl_vip/src/env/pcie_tl_env.sv`

**Interfaces:**
- Consumes: `host_mem_api.get_host_id()`, `host_mem_api.is_initialized()`, and the Root count already resolved by `pcie_tl_env`.
- Produces: `bind_host_memory()`, `get_host_memory()`, `host_memory_binding_count()`, `validate_host_memory_bindings()`, and `pcie_tl_env.host_mem_by_root[]`.

- [x] **Step 1: Add the minimal config mapping API**

  Store parallel associative arrays keyed by `int unsigned root_index`:

  ```systemverilog
  protected host_mem_api  host_mem_bindings[int unsigned];
  protected int unsigned host_ids_by_root[int unsigned];
  ```

  Implement the four public methods from the design. Return a descriptive
  `why` string for null, Host-ID mismatch, duplicate, missing, incomplete,
  and out-of-range cases. Never replace a successful earlier binding after a
  rejected call.

- [x] **Step 2: Distribute explicit managers in the PCIe environment**

  Allocate `host_mem_by_root = new[rc_agents.size()]`. When explicit bindings
  exist, validate the full set and assign:

  ```systemverilog
  host_mem_by_root[r] = root_mem;
  rc_agents[r].rc_driver.mem = root_mem;
  host_mem = host_mem_by_root[0];
  ```

  If no explicit binding exists, accept the legacy `"host_mem"` config-db
  key only for root 0 and fail a multi-Root configuration.

- [x] **Step 3: Guard all legacy initialization calls**

  Call `init_region(0, 0xFFFF_FFFF, ...)` only when
  `is_initialized()` is false. Check `is_initialized()` afterward and report
  a fatal error if initialization was rejected. Apply the same guard to every
  `dev_mem_N` handle.

- [x] **Step 4: Synchronize and verify GREEN on the VCS host**

  Compile and run only `virtio_pcie_host_mem_test`.

  Expected: PASS with zero UVM errors/fatals; both Root DMA round trips return
  their own Host pattern and the high aperture remains unchanged.

- [x] **Step 5: Run PCIe legacy compatibility tests on the VCS host**

  Build and run the PCIe TL VIP tests `pcie_tl_unified_mem_test` and
  `pcie_tl_switch_unified_mem_test` using the subproject filelist.

  Expected: both retain their root-0 config-db behavior and PASS.

### Task 3: Documentation and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`

**Interfaces:**
- Consumes: the implemented binding API and the top-level Host-memory ownership rule.
- Produces: user-facing examples for future VIO/RDMA/VBLK integration.

- [x] **Step 1: Document top-level ownership and PCIe binding**

  Add a concise example showing one pool manager shared by VIO and PCIe:

  ```systemverilog
  host0_mem = host_mem_owners.get_host(0);
  vio_cfg.host_mem_pool_binding = host_mem_owners;
  if (!pcie_cfg.bind_host_memory(0, 0, host0_mem, why))
      `uvm_fatal("TOP_CFG", why)
  ```

  Explain that future service environments receive the same manager handle,
  while PCIe owns the actual DUT DMA request/response path.

- [x] **Step 2: Run local static checks**

  Run:

  ```bash
  bash scripts/test_manifest.sh
  bash scripts/tests/strict_log_check_test.sh
  bash scripts/tests/strict_regression_test.sh
  ```

  Expected: every command exits zero.

- [x] **Step 3: Run the complete maintained VCS regression**

  Synchronize the working tree and run:

  ```bash
  STRICT_TEST_TIMEOUT_SECONDS=180 ./scripts/strict_regression.sh
  ```

  Expected: every maintained test, including
  `virtio_pcie_host_mem_test`, reports `STRICT_RESULT ... PASS`, followed by
  `STRICT_REGRESSION PASS`.

- [x] **Step 4: Review the final diff for scope and ownership**

  Confirm that no production code was added outside the PCIe config/env
  binding path, no existing user edits were overwritten, and no token or
  credential was persisted.

### Task 4: Review Hardening for Shared-Manager PREMAP

- [x] Add a regression fixture in which two Roots bind the same Host manager
  and the aperture is exactly one `premap_size` allocation.
- [x] Verify RED from the second per-Root allocation, then allocate only once
  per unique `host_mem_api` handle.
- [x] Add an undersized-aperture fixture and verify RED when the PCIe
  environment ignores the allocator's failure sentinel.
- [x] Reject failed PREMAP allocations for explicit Root, legacy Root-0, and
  device-memory paths with a `PCIE_TL_HOST_MEM` fatal.
- [x] Re-run the focused test and all 26 maintained tests on the VCS host.
