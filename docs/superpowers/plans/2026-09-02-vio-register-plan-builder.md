# VIO Real-DUT Register Plan Builder Implementation Plan

> **For agentic workers:** This plan is executed inline in the current session. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Convert the frozen DPU topology and VIO qpair snapshots into a validated, dependency-ordered register plan for real-DUT BDF, MSI-X, and VIO notify/qpair configuration while preserving a user-injected executor callback.

**Architecture:** `dpu_vio_register_plan_builder` consumes only frozen `dpu_device_snapshot` and `dpu_resource_snapshot`, packs driver-derived table entries into generic `dpu_reg_op` writes, and never performs PCIe I/O. `dpu_device_env` exposes build/apply methods; `dpu_reg_executor` remains the user extension point. QSCH/DSCH is represented only by a future module boundary until all driver bitfields and dependencies are audited.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1.

**Spec:** `docs/superpowers/specs/2026-08-25-real-dut-service-configuration-design.md`

## Global Constraints

- Consume immutable snapshots; do not allocate or renumber BDF, global qpair, or MSI-X IDs in the builder.
- Keep RX/TX Virtio queue IDs as `2*virtio_pair_index` and `2*virtio_pair_index+1`; both directions use one `global_qpair_id`.
- Use Host-qualified `{host_id, segment_id, BDF}` targets for every operation.
- Emit no PCIe writes when plan validation or executor preflight fails.
- Use the selected AF's BAR0 for internal DUT table writes; use PCI config operations for BAR programming.
- Do not introduce `PLAN_ONLY`, `MODEL`, or `REAL` user modes.
- Do not implement RDMA/VBLK data planes, random IOVA allocation, or unverified QSCH/DSCH bitfields in this task.
- Run VCS verification on `ubuntu@10.11.10.53` through a Bash login shell.

### Task 1: Add driver-derived VIO register types and packers

**Files:**
- Create: `dpu_common/src/dpu_vio_reg_plan_types.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Test: `dpu_common/tests/dpu_vio_reg_plan_test.sv`

- [x] Define typed inputs for notify entries, MSI-X info/linear entries, BDF entries, and per-service register-plan policy.
- [x] Implement pure pack functions with explicit width/range validation and driver offsets from `register.h`.
- [x] Add focused tests for bit packing, 128-byte notify alignment, host-qualified IDs, and invalid ranges.

### Task 2: Build BDF/MSI-X/notify/qpair register plan

**Files:**
- Create: `dpu_common/src/dpu_vio_register_plan_builder.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Test: `dpu_common/tests/dpu_vio_reg_plan_test.sv`

- [x] Require frozen device/resource snapshots with an exact snapshot reference.
- [x] Resolve selected AF and all VIO services from snapshots.
- [x] Emit dependency edges for BAR bootstrap, BDF map, MSI-X linear/info/interval, notify table entries, and final table-ready commit; keep PBA explicitly read-only.
- [x] Emit one notify entry per RX/TX Virtio queue using the explicit binding fields, never by deriving from sparse local IDs.
- [x] Validate per-function qpair count against placement and the 32-pair DUT ceiling.

### Task 3: Expose the plan and executor callback at the device environment

**Files:**
- Modify: `dpu_common/src/dpu_device_env.sv`
- Test: `dpu_common/tests/dpu_vio_reg_plan_test.sv`

- [x] Add `build_vio_register_plan()` and `apply_vio_register_plan()` wrappers that preserve device state transitions.
- [x] Reuse the existing injected `dpu_reg_executor`; do not add a mode enum.
- [x] Verify spy executor ordering and custom executor callback behavior.

### Task 4: Maintain regression and documentation

**Files:**
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`

- [x] Register the focused VIO register-plan test exactly once.
- [x] Document operation ownership, driver-derived address map, and callback integration.
- [x] Run focused VCS test, maintained strict regression, `git diff --check`, and shell syntax checks.

### Task 5: Model AF extra queues and expose dataplane-plan extension seams

**Files:**
- Modify: `dpu_common/src/dpu_resource_types.sv`
- Modify: `dpu_common/src/dpu_placement_types.sv`
- Modify: `dpu_common/src/dpu_dut_caps.sv`
- Modify: `dpu_common/src/dpu_resource_resolver.sv`
- Modify: `dpu_common/src/dpu_resource_snapshot.sv`
- Create: `dpu_common/src/dpu_vio_dataplane_plan_extension.sv`
- Modify: `dpu_common/src/dpu_vio_register_plan_builder.sv`
- Modify: `dpu_common/src/dpu_device_env.sv`
- Test: `dpu_common/tests/dpu_vio_reg_plan_test.sv`
- Test: `dpu_common/tests/dpu_resource_resolver_test.sv`

**Interfaces:**
- Produces: `dpu_af_extra_queue_binding_t`, `dpu_resource_snapshot::list_af_extra_queue_bindings()`, and `dpu_vio_dataplane_plan_extension`.
- Consumes: the selected AF, resolved global qpair/MSI-X pools, and the existing mutable `dpu_reg_plan` assembled by `dpu_vio_register_plan_builder`.

- [x] Add failing resolver/snapshot tests proving that the real-driver AF profile allocates 11 independent extra qpair bindings after ordinary VIO qpairs, reserves unique global qpair IDs, and rejects `ordinary + extra > 32`.
- [x] Add failing plan tests proving that AF extra queues append to the AF notify block with `local_queue_index = ordinary_pair_count + extra_queue_offset`, use extra queue MSI-X bindings, and keep the full shadow image at the driver-supported 128 entries.
- [x] Add `af_extra_queue_count = 11` and `vio_notify_entries_per_bank = 128` to the default real-DUT capability profile, with validation against the 32-pair and 1024-entry encoded ceilings.
- [x] Resolve AF extra queue and MSI-X bindings into the same global resource pools as ordinary VIO resources, then publish them as a separate immutable snapshot collection that is not visible through the guest VIO resource client.
- [x] Lower the frozen AF extra bindings into BDF/MSI-X/interval/notify operations without deriving or renumbering IDs in the register-plan builder.
- [x] Add `dpu_vio_dataplane_plan_extension` with separate no-op `contribute_qsch()`, `contribute_vtx()`, and `contribute_vrx()` hooks; invoke it only after the core BDF/MSI-X/notify plan is complete and do not add unverified register offsets.
- [x] Run the focused resolver and VIO register-plan VCS tests on `10.11.10.53`, then run the maintained strict regression and static checks.

### Task 6: Match driver notify verification and add snapshot-owned teardown

**Files:**
- Modify: `dpu_common/src/dpu_vio_reg_plan_types.sv`
- Modify: `dpu_common/src/dpu_vio_register_plan_builder.sv`
- Modify: `dpu_common/src/dpu_device_env.sv`
- Test: `dpu_common/tests/dpu_vio_reg_plan_test.sv`

- [x] Make the real-DUT default emit the complete 128-entry inactive notify shadow.
- [x] Poll-read each low/high word with the driver's five-attempt, five-microsecond policy before commit.
- [x] Add a separate teardown plan that commits an invalid notify shadow and clears only snapshot-owned MSI-X info/linear and BDF mappings.
- [x] Preserve PBA and function BAR4 MSI-X address/data as hardware/Host-owned state.
- [x] Default to the inactive notify bank, track only successfully committed bank changes, and keep setup/teardown BDF ownership symmetric.
- [x] Run the focused VCS test and maintained strict regression on `10.11.10.53`, then run final static checks.
