# Global DPU Configuration Ownership Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace VIO-owned host/PF/VF, capability, BDF, and BAR configuration with a domain-aware global DPU configuration that resolves into an immutable snapshot and produces a driver-aligned PCI BAR/AF bootstrap plan.

**Architecture:** A mutable `dpu_device_cfg` is structurally validated and deterministically resolved into a frozen `dpu_device_snapshot`. `dpu_device_env` publishes that snapshot and a snapshot-seeded generic resource manager to protocol children; VIO binds behavior by `dpu_service_key_t`. A common bootstrap builder lowers resolved BARs and the selected PF0 AF declaration into the existing generic register-plan/executor pipeline.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, PCIe TL VIP, existing `dpu_reg_plan`/`dpu_reg_executor` infrastructure, Bash regression scripts.

**Spec:** `docs/superpowers/specs/2026-08-27-global-dpu-configuration-ownership-design.md`

## Global Constraints

- Begin execution in an isolated worktree created with `superpowers:using-git-worktrees`.
- Do not implement or depend on `cosim_control`.
- The final tree has one topology path only; temporary branch-local dual-path support introduced to keep intermediate commits buildable must be deleted in Task 10.
- Host and PF objects are always explicit. This subproject does not auto-create VFs from queue demand.
- BDF and BAR reverse lookups always include `{host_id,segment_id}`.
- PF0 on any declared host may be selected as AF. PF1+, VFs, an existing valid AF, or an unexpected arbitration winner are hard failures.
- AF constants are BAR0+`0x1010`, magic `0x5555AAAA`, and BAR0+`0x60040`; host ID uses bits `[2:0]` and valid bit 3.
- The real-DUT BAR profile is BAR0/1 device memory, BAR2/3 mailbox, BAR4/5 MSI-X.
- The real-DUT VIO limit remains 32 qpairs per PF/VF, local qid `0..31`; total-demand placement is outside this plan.
- No production real-DUT executor or DUT-internal BDF/MSI-X/notify/QSCH/DSCH/VIO/RDMA/VBLK table writer is added.
- Run every VCS compile/simulation on `ubuntu@10.11.10.53` through a bash login shell. Do not persist its password in files, URLs, or Git configuration.
- Use these remote helpers for each VCS step; authentication may use the session's AGENTS.md credentials without writing them to the repository:

```bash
remote_stage=/home/ubuntu/test_cosim/virtio-global-device-subproject2
stage_remote() {
  ssh ubuntu@10.11.10.53 "mkdir -p $remote_stage"
  rsync -a --delete --exclude .git --exclude build ./ \
    ubuntu@10.11.10.53:"$remote_stage/"
}
run_remote_test() {
  local test_name="$1"
  ssh ubuntu@10.11.10.53 \
    "bash -lic 'cd $remote_stage && mkdir -p build/strict && \
      TEST=$test_name ./scripts/vcs.sh >build/strict/$test_name.log 2>&1 && \
      ./scripts/strict_log_check.sh sim build/strict/$test_name.log'"
}
```

- Run `stage_remote` after every code edit batch, then call `run_remote_test` with the exact test names in that task. A focused run passes only when the command exits zero and `scripts/strict_log_check.sh sim` accepts its log; the final gate is `scripts/strict_regression.sh`.

---

## File Structure

### New DPU common files

- `dpu_common/src/dpu_device_types.sv`: canonical function/domain/service identities, allocation modes, BAR roles/profile records, address ranges, device lifecycle, and key-format helpers.
- `dpu_common/src/dpu_device_cfg.sv`: mutable authoring objects for hosts, domains, functions, BDF/BAR requests, services, and AF selection; owns deep-copy behavior only.
- `dpu_common/src/dpu_device_snapshot.sv`: frozen resolved values and typed forward/reverse queries; owns no allocation policy.
- `dpu_common/src/dpu_device_resolver.sv`: structural validation and deterministic all-or-nothing BDF/BAR allocation.
- `dpu_common/src/dpu_execution_report.sv`: terminal status plus defensive copies of per-operation execution results.
- `dpu_common/src/dpu_device_bootstrap_plan_builder.sv`: PCI BAR and AF declaration register-plan lowering.
- `dpu_common/src/dpu_device_env.sv`: UVM lifecycle owner that resolves, publishes, builds bootstrap plans, and applies them through the existing orchestrator.

### New tests and test support

- `dpu_common/tests/dpu_device_resolver_test.sv`: authoring validation, deterministic resolver, snapshot, device-env publication, and resource-manager seeding.
- `dpu_common/tests/dpu_device_bootstrap_plan_test.sv`: exact PCI BAR/AF plan and execution-report coverage.
- `virtio_net_vip/tests/virtio_test_device_builder.sv`: test-only explicit topology/scenario builder; it is not a product compatibility translator.

### Existing files with changed responsibility

- `dpu_common/src/dpu_resource_types.sv`: retains generic pool/lease records; function, service, and BAR identity move to `dpu_device_types.sv`.
- `dpu_common/src/dpu_dut_caps.sv`: owns the real-DUT BAR capability profile in addition to hardware maxima.
- `dpu_common/src/dpu_resource_manager.sv`: retains generic resource classes, leases, readiness, freeze/restore, and capability snapshots; loses topology authoring and BAR allocation.
- `dpu_common/src/dpu_resource_pkg.sv`: includes the new files in dependency order and removes `dpu_fabric_env.sv` at the hard-cut task.
- `dpu_common/src/dpu_config_orchestrator.sv`, `dpu_common/src/dpu_reg_executor.sv`, `dpu_common/src/dpu_spy_reg_executor.sv`: add non-breaking execution-report export.
- `virtio_net_vip/src/env/virtio_net_env_config.sv`: becomes behavior-only and stores service-keyed driver overrides.
- `virtio_net_vip/src/env/virtio_net_env.sv`: consumes a frozen snapshot and stops creating topology or a Fabric environment.
- `virtio_net_vip/src/sriov/virtio_pf_instance.sv`: creates only snapshot-declared VIO services under one explicit PF key.
- `virtio_net_vip/src/sriov/virtio_function_instance.sv`, `virtio_vf_instance.sv`, and `virtio_resource_client.sv`: consume resolved identity/BARs and snapshot-seeded shared resources.
- `virtio_net_vip/src/transport/virtio_bar_accessor.sv`: recognizes BAR2/3 as mailbox rather than reserved.
- `dpu_common/src/dpu_fabric_env.sv`: deleted after all consumers migrate.

---

### Task 1: Canonical Device Identities and Real-DUT BAR Profile

**Files:**
- Create: `dpu_common/src/dpu_device_types.sv`
- Modify: `dpu_common/src/dpu_resource_types.sv:1-60`
- Modify: `dpu_common/src/dpu_dut_caps.sv:1-109`
- Modify: `dpu_common/src/dpu_resource_pkg.sv:8-23`
- Modify: `dpu_common/src/dpu_resource_manager.sv:509-570`
- Modify: `virtio_net_vip/src/transport/virtio_bar_accessor.sv:224-475`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:1-135`
- Modify: `dpu_common/tests/dpu_resource_manager_test.sv:20-82`
- Modify: `virtio_net_vip/tests/virtio_fabric_resource_test.sv:98-623`

**Interfaces:**
- Produces: `dpu_function_key_t`, `dpu_pcie_domain_key_t`, `dpu_pcie_function_id_t`, `dpu_service_key_t`, `dpu_allocation_mode_e`, `dpu_bar_role_e`, `dpu_bar_profile_t`, `dpu_device_state_e`.
- Produces: `dpu_function_key_name()`, `dpu_service_key_name()`, `dpu_same_function_key()`, and `dpu_same_domain_key()` package functions.
- Produces: `dpu_dut_caps::lookup_bar_profile(kind, role, output profile, output why)`.

- [ ] **Step 1: Add failing compile-time and runtime BAR-profile assertions**

Change the PF BAR assertion and the BAR-accessor test to require mailbox semantics:

```systemverilog
if ((bars[1].role != DPU_BAR_MAILBOX) ||
    (bars[1].even_bar_id != 2))
    `uvm_fatal("DPU_RESOURCE", "PF mailbox BAR pair is incorrect")

if (!caps.lookup_bar_profile(
    DPU_FUNCTION_PF, DPU_BAR_MAILBOX, profile, why) ||
    (profile.even_bar_id != 2) ||
    (profile.size != 64'h0000_0000_0001_0000))
    `uvm_fatal("DPU_CAPS", {"missing PF mailbox profile: ", why})
```

Replace the reserved-BAR negative check in `virtio_fabric_resource_test` with
a check that configured BAR2 carries `DPU_BAR_MAILBOX`. Add a public
`probe_functional_bar_access(bar_id)` wrapper to the existing accessor test
subclass; it calls the protected `allow_functional_bar_access`. Assert the
probe returns true for BAR2 without emitting `BAR_RESERVED`.

- [ ] **Step 2: Run the focused test and verify RED**

Run on 53:

```bash
run_remote_test dpu_resource_manager_test
```

Expected: compile failure naming undefined `DPU_BAR_MAILBOX` or missing `lookup_bar_profile`.

- [ ] **Step 3: Define canonical types and key helpers**

Put these declarations in `dpu_device_types.sv` and remove their old duplicates from `dpu_resource_types.sv`:

```systemverilog
typedef enum int unsigned { DPU_FUNCTION_PF, DPU_FUNCTION_VF }
    dpu_function_kind_e;
typedef enum int unsigned { DPU_ALLOC_AUTO, DPU_ALLOC_PINNED }
    dpu_allocation_mode_e;
typedef enum int unsigned {
    DPU_SERVICE_VIO_NET, DPU_SERVICE_RDMA, DPU_SERVICE_VBLK
} dpu_service_kind_e;
typedef enum int unsigned { DPU_AF_SELECTED } dpu_af_selection_mode_e;
typedef enum int unsigned {
    DPU_BAR_DEVICE_MEMORY, DPU_BAR_MAILBOX, DPU_BAR_MSIX
} dpu_bar_role_e;
typedef enum int unsigned {
    DPU_DEVICE_UNRESOLVED, DPU_DEVICE_RESOLVED,
    DPU_DEVICE_APPLYING, DPU_DEVICE_ACTIVE, DPU_DEVICE_FAILED
} dpu_device_state_e;

typedef struct {
    int unsigned host_id;
    int unsigned pf_id;
    dpu_function_kind_e kind;
    int unsigned vf_id;
} dpu_function_key_t;
typedef struct { int unsigned host_id; int unsigned segment_id; }
    dpu_pcie_domain_key_t;
typedef struct { dpu_pcie_domain_key_t domain; bit [15:0] bdf; }
    dpu_pcie_function_id_t;
typedef struct {
    dpu_function_key_t function_key;
    dpu_service_kind_e service_kind;
    int unsigned service_instance_id;
} dpu_service_key_t;
typedef struct { bit [15:0] first_bdf; bit [15:0] last_bdf; }
    dpu_bdf_range_t;
typedef struct { bit [63:0] base; bit [63:0] limit; }
    dpu_address_range_t;
typedef struct {
    dpu_function_kind_e kind;
    dpu_bar_role_e role;
    int unsigned even_bar_id;
    bit [63:0] size;
    bit [63:0] alignment;
} dpu_bar_profile_t;
```

Key-name helpers must format every identity field, for example
`"h%0d.pf%0d.k%0d.vf%0d"` and append service kind/instance for a service key.

- [ ] **Step 4: Add the default real-DUT BAR profiles to capabilities**

Add `dpu_bar_profile_t bar_profiles[$]`, deep-copy it in `copy_from`, validate unique `{kind,role}` and `{kind,even_bar_id}` entries, and initialize:

```text
PF DEVICE_MEMORY BAR0 size 0x02000000 alignment 0x02000000
PF MAILBOX       BAR2 size 0x00010000 alignment 0x00010000
PF MSIX          BAR4 size 0x00010000 alignment 0x00010000
VF DEVICE_MEMORY BAR0 size 0x00004000 alignment 0x00004000
VF MAILBOX       BAR2 size 0x00004000 alignment 0x00004000
VF MSIX          BAR4 size 0x00008000 alignment 0x00008000
```

- [ ] **Step 5: Change every BAR2 consumer from reserved to mailbox**

Use `DPU_BAR_MAILBOX` in the temporary legacy allocator and BAR accessor. In `allow_functional_bar_access`, permit BAR0 only for `DPU_BAR_DEVICE_MEMORY`, BAR2 only for `DPU_BAR_MAILBOX`, reject odd upper slots, and continue reserving BAR4 for MSI-X-specific APIs. Delete `reserved_bar_access_error_count` and `virtio_function_instance::is_reserved_bar`.

- [ ] **Step 6: Run focused GREEN tests**

Run on 53 and strict-check both logs:

```bash
run_remote_test dpu_resource_manager_test
run_remote_test virtio_fabric_resource_test
```

Expected: both PASS with zero UVM warnings/errors/fatals; BAR2 is reported as mailbox.

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_device_types.sv \
  dpu_common/src/dpu_resource_types.sv dpu_common/src/dpu_dut_caps.sv \
  dpu_common/src/dpu_resource_pkg.sv dpu_common/src/dpu_resource_manager.sv \
  dpu_common/tests/dpu_resource_manager_test.sv \
  virtio_net_vip/src/transport/virtio_bar_accessor.sv \
  virtio_net_vip/src/sriov/virtio_function_instance.sv \
  virtio_net_vip/tests/virtio_fabric_resource_test.sv
git commit -m "refactor: define real DPU device identities and BAR roles"
```

### Task 2: Declarative Device Configuration and Structural Validation

**Files:**
- Create: `dpu_common/src/dpu_device_cfg.sv`
- Create: `dpu_common/src/dpu_device_resolver.sv`
- Create: `dpu_common/tests/dpu_device_resolver_test.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Consumes: Task 1 identity and capability types.
- Produces: `dpu_mmio_window_cfg`, `dpu_pcie_domain_cfg`, `dpu_host_cfg`, `dpu_bar_request`, `dpu_service_decl`, `dpu_function_cfg`, `dpu_af_request`, and `dpu_device_cfg`.
- Produces: `dpu_device_resolver::validate(cfg, output why)`.

- [ ] **Step 1: Register the new failing test**

Add `dpu_device_resolver_test.sv` after `dpu_reg_plan_test.sv` in `filelists/tests.f` and add `dpu_device_resolver_test` after `dpu_reg_plan_test` in `VIRTIO_MAINTAINED_TESTS`.

- [ ] **Step 2: Write the structural-validation RED cases**

The test constructs a valid sparse configuration containing host0/PF0,
host1/PF0, host1/PF3, and host1/PF3/VF7, with VIO and RDMA on VF7 and AF on
host1/PF0. Clone and mutate it to assert these exact failures:

```text
duplicate host key
duplicate PCIe domain key
function refers to a domain on another host
VF function requires its declared parent PF
duplicate function key
duplicate service key
current DUT profile permits one VIO-net instance per function
AF requester must be a declared PF0
BAR request has duplicate role
BAR request role/pair does not match the DUT profile
```

Use `resolver.validate(cfg, why)` and check the diagnostic contains the named key.

- [ ] **Step 3: Run RED on 53**

```bash
run_remote_test dpu_device_resolver_test
```

Expected: compile failure because `dpu_device_cfg` and resolver classes do not exist.

- [ ] **Step 4: Implement focused authoring objects with deep copies**

Use queues of owned objects and a `copy_from` method on every class. The main fields are:

```systemverilog
class dpu_function_cfg extends uvm_object;
    dpu_function_key_t key;
    dpu_pcie_domain_key_t domain_key;
    dpu_allocation_mode_e bdf_mode;
    bit [15:0] pinned_bdf;
    dpu_bar_request bars[$];
    dpu_service_decl services[$];
endclass

class dpu_device_cfg extends uvm_object;
    dpu_dut_caps dut_caps;
    dpu_host_cfg hosts[$];
    dpu_function_cfg functions[$];
    dpu_af_request af_request;
endclass
```

`dpu_mmio_window_cfg` contains `[base,limit)`, a queue of allowed BAR roles,
and `allows_role(role)`. Domain configuration contains BDF ranges, reserved
BDFs, MMIO windows, and reserved MMIO ranges.

- [ ] **Step 5: Implement structural validation without allocation**

Use canonical string keys from Task 1 for duplicate maps. Validate capabilities first, then hosts/domains, functions/parents, services, BAR request shape/profile, and AF. Do not assign BDFs/BARs and do not mutate `cfg`.

- [ ] **Step 6: Run GREEN and a regression neighbor**

```bash
run_remote_test dpu_device_resolver_test
run_remote_test dpu_resource_manager_test
```

Expected: both PASS and strict log checks succeed.

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_device_cfg.sv \
  dpu_common/src/dpu_device_resolver.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_device_resolver_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: add declarative global DPU configuration"
```

### Task 3: Deterministic BDF/BAR Resolver and Immutable Snapshot

**Files:**
- Create: `dpu_common/src/dpu_device_snapshot.sv`
- Modify: `dpu_common/src/dpu_device_types.sv`
- Modify: `dpu_common/src/dpu_device_resolver.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv`

**Interfaces:**
- Produces: `dpu_bar_address_match_t` containing
  `{function_key,role,bar_base,bar_size,offset}`.
- Produces: `dpu_device_resolver::resolve(cfg, output snapshot, output why)`.
- Produces snapshot queries `get_pcie_id`, `find_function`, `get_bar`, `list_bars`, `resolve_bar_address`, `get_service_owner`, `list_functions`, `list_services`, `get_expected_af`, `snapshot_dut_caps`, and `is_frozen`.

- [ ] **Step 1: Add allocation and snapshot RED cases**

Cover these exact results in `dpu_device_resolver_test`:

```text
PINNED BDFs are placed before AUTO BDFs
AUTO uses the lowest free BDF in canonical function order
reserved/out-of-range/duplicate/exhausted BDF requests fail
PINNED BARs are placed before AUTO BARs
AUTO BAR uses the lowest aligned compatible address
odd pair, role mismatch, misalignment, reservation, overlap, and exhaustion fail
same numeric BDF/BAR is accepted in different domains
same numeric BDF/BAR colliding in one domain fails
forward and reverse queries agree
published snapshot returns defensive copies and rejects mutation after freeze
a failed second resolve returns null and leaves the first snapshot unchanged
```

- [ ] **Step 2: Run RED**

```bash
run_remote_test dpu_device_resolver_test
```

Expected: compile failure naming `dpu_device_snapshot` or missing `resolve`.

- [ ] **Step 3: Implement snapshot storage and freeze contract**

Store functions, BDFs, BARs, and services in protected canonical-key maps.
Mutation methods must return false after `freeze(why)`. Query methods require a
frozen snapshot and return values/copies only. Use signatures such as:

```systemverilog
function bit get_pcie_id(
    input dpu_function_key_t key,
    output dpu_pcie_function_id_t pcie_id,
    output string why);
function bit get_bar(
    input dpu_function_key_t key,
    input dpu_bar_role_e role,
    output dpu_bar_pair_lease_t bar,
    output string why);
function bit resolve_bar_address(
    input dpu_pcie_domain_key_t domain,
    input bit [63:0] address,
    output dpu_bar_address_match_t match,
    output string why);
function void list_functions(ref dpu_function_key_t keys[$]);
function bit list_bars(
    input dpu_function_key_t key,
    ref dpu_bar_pair_lease_t bars[$],
    output string why);
function void list_services(
    input dpu_service_kind_e kind,
    ref dpu_service_key_t keys[$]);
function bit get_expected_af(
    output dpu_function_key_t key,
    output dpu_bar_pair_lease_t bar0,
    output string why);
function dpu_dut_caps snapshot_dut_caps();
```

- [ ] **Step 4: Implement deterministic BDF resolution**

Deep-copy configuration, sort functions by `{host_id,pf_id,kind,vf_id}`, place
every pinned BDF first, then scan each domain's sorted ranges for AUTO. Check
`candidate[2:0]` and device bits only through the valid configured BDF ranges;
do not derive BDFs from PF/VF arithmetic.

- [ ] **Step 5: Implement deterministic BAR resolution**

For each domain, sort windows by base. Place pinned requests first. For AUTO,
align with `(cursor + alignment - 1) & ~(alignment - 1)`, reject overflow, and
scan past reserved/allocated intervals until a fitting range is found. Sort
AUTO requests by `{domain,function_key,bar_role}`.

- [ ] **Step 6: Build indexes, validate AF BAR0, and atomically publish**

Before `freeze`, cross-check every function/BDF, function/BAR, reverse-address,
and service-owner entry. Require the selected AF to have a BAR0
`DPU_BAR_DEVICE_MEMORY` lease and `host_id <= 7`. Assign the output snapshot
only after `freeze` succeeds; otherwise set it to null.

- [ ] **Step 7: Run GREEN**

```bash
run_remote_test dpu_device_resolver_test
```

Expected: PASS with deterministic values asserted twice from differently ordered authoring arrays.

- [ ] **Step 8: Commit**

```bash
git add dpu_common/src/dpu_device_types.sv \
  dpu_common/src/dpu_device_snapshot.sv \
  dpu_common/src/dpu_device_resolver.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_device_resolver_test.sv
git commit -m "feat: resolve domain-aware DPU BDF and BAR mappings"
```

### Task 4: Device Environment and Snapshot-Seeded Resource Manager

**Files:**
- Create: `dpu_common/src/dpu_device_env.sv`
- Modify: `dpu_common/src/dpu_resource_manager.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv`
- Modify: `dpu_common/tests/dpu_resource_manager_test.sv`

**Interfaces:**
- Produces: `dpu_device_env_config` containing `device_cfg`, `resource_profiles[$]`, and optional `executor`.
- Produces: `dpu_device_env::get_snapshot()`, `get_resource_manager()`, and `get_state()`.
- Produces: `dpu_resource_manager::configure_from_snapshot(authority, snapshot, profiles, why)`.
- Existing legacy Fabric methods remain only until Task 10 so intermediate maintained tests compile.

- [ ] **Step 1: Add environment publication and manager-seeding RED tests**

Create a `dpu_snapshot_probe` child under `dpu_device_env`. In its build phase,
require the exact same frozen snapshot and resource-manager handles from
`uvm_config_db`. Assert the manager already knows all snapshot functions, has
copied DUT capabilities, has the configured `virtio.qpair` profile, and cannot
register an undeclared function.

- [ ] **Step 2: Run RED**

```bash
run_remote_test dpu_device_resolver_test
```

Expected: compile failure because `dpu_device_env` is undefined.

- [ ] **Step 3: Add one-shot snapshot seeding to the generic manager**

Introduce `dpu_resource_registry_authority` and a one-shot
`configure_from_snapshot` path. It must copy caps, enumerate snapshot function
keys into function state, register the supplied generic resource profiles, and
seal the registry atomically. It must not own a domain aperture, BAR cursor, or
new BAR allocation on this path.

- [ ] **Step 4: Implement `dpu_device_env` build ownership**

In `build_phase`, retrieve `dpu_device_env_config` as `cfg`, resolve its
`device_cfg`, seed a fresh resource manager, set state to
`DPU_DEVICE_RESOLVED`, and publish both objects to `"*"`. Any failure emits one
`uvm_fatal` containing the resolver/manager reason and publishes neither
object.

- [ ] **Step 5: Migrate the resource-manager test to the new owner for its new-path cases**

Keep lease quota/freeze/restore coverage, but obtain the manager from a device
environment whose snapshot declares every tested function. Move BAR placement
expectations to `dpu_device_resolver_test`; the generic resource test must not
assert that the manager calculates BAR bases.

- [ ] **Step 6: Run focused GREEN tests**

```bash
run_remote_test dpu_device_resolver_test
run_remote_test dpu_resource_manager_test
```

Expected: both PASS; a child receives the exact global snapshot/manager, and qpair behavior is unchanged.

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_device_env.sv \
  dpu_common/src/dpu_resource_manager.sv dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_device_resolver_test.sv \
  dpu_common/tests/dpu_resource_manager_test.sv
git commit -m "feat: add global DPU device environment ownership"
```

### Task 5: PCI BAR/AF Bootstrap Plan and Execution Report

**Files:**
- Create: `dpu_common/src/dpu_execution_report.sv`
- Create: `dpu_common/src/dpu_device_bootstrap_plan_builder.sv`
- Create: `dpu_common/tests/dpu_device_bootstrap_plan_test.sv`
- Modify: `dpu_common/src/dpu_reg_executor.sv`
- Modify: `dpu_common/src/dpu_spy_reg_executor.sv`
- Modify: `dpu_common/src/dpu_config_orchestrator.sv`
- Modify: `dpu_common/src/dpu_device_env.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Produces: `dpu_execution_report` with terminal status/reason and copied operation results.
- Produces: `dpu_reg_executor::export_results(report)` with a no-result base implementation and spy override.
- Produces: `dpu_config_orchestrator::apply_with_report(plan, output report)` while preserving existing `apply(plan,status,why)`.
- Produces: `dpu_device_bootstrap_plan_builder::build(snapshot, output plan, output why)`.
- Produces: `dpu_device_env::build_bootstrap_plan` and `apply_bootstrap`.

- [ ] **Step 1: Register and write the exact bootstrap RED test**

Add the test after `dpu_device_resolver_test` in both manifests. Resolve a
two-host config selecting host1/PF0 and assert the ordered plan contains:

```text
two 32-bit PCI config writes per 64-bit BAR pair
AF valid-bit pre-read at BAR0 offset 0x1010
0x5555AAAA write at offset 0x1010
winner read with mask 0xF and expected 0x9
host-ID write 0x9 at offset 0x60040
host-ID readback with mask 0xF and expected 0x9
final barrier
```

Every op must carry host1, the selected segment, selected BDF, and the correct
BAR/target space. AF reads depend on completed selected-BAR programming; the
final barrier depends on host-ID readback.

- [ ] **Step 2: Run RED**

```bash
run_remote_test dpu_device_bootstrap_plan_test
```

Expected: compile failure naming the missing builder/report.

- [ ] **Step 3: Implement defensive execution reports**

Store `{op_id,result}` records privately. `result_at` returns copied scalar
values. `apply_with_report` uses the existing freeze/preflight/execute flow,
sets report status/reason on every exit, and asks the executor to export
results. Keep `apply` as a wrapper so `dpu_reg_plan_test` call sites remain valid.

Update package include order to
`dpu_reg_plan_types`, `dpu_reg_op`, `dpu_reg_plan`,
`dpu_execution_report`, `dpu_reg_executor`, `dpu_spy_reg_executor`, then
`dpu_config_orchestrator`; snapshot/resolver/resource-manager/bootstrap/device
environment includes follow after capabilities and authoring types.

- [ ] **Step 4: Implement BAR plan lowering**

For each resolved BAR in stable function/role order, emit a 4-byte PCI config
write at `0x10 + even_bar_id*4` with `{base[31:4],4'b0100}`, then its high
dword at the next register. Target identity is `{host_id,segment_id,bdf}` from
the snapshot, never a raw global BDF.

- [ ] **Step 5: Implement strict AF lowering**

Emit the six operations from the spec with 4-byte widths, exact masks/payloads,
`DPU_REG_TARGET_AF_BAR0`, bootstrap phase, and explicit dependencies. Do not
emit cleanup of `0x20040` or `0x60040`.

- [ ] **Step 6: Integrate explicit build/apply into `dpu_device_env`**

`build_bootstrap_plan` is valid only in `RESOLVED`. `apply_bootstrap` moves to
`APPLYING`; success moves to `ACTIVE`, execution failure to `FAILED`, and
`NOT_EXECUTED` or preflight failure returns to/stays `RESOLVED` because no DUT
write occurred.

- [ ] **Step 7: Test success, no-executor, preflight failure, and injected AF failure**

Use `dpu_spy_reg_executor::fail_preflight` and `fail_operation` to prove report
contents and state transitions. Confirm the immutable snapshot handle and
lookups do not change after failure.

- [ ] **Step 8: Run GREEN regression neighbors**

```bash
run_remote_test dpu_device_bootstrap_plan_test
run_remote_test dpu_reg_plan_test
run_remote_test dpu_device_resolver_test
```

Expected: all PASS with strict logs.

- [ ] **Step 9: Commit**

```bash
git add dpu_common/src/dpu_execution_report.sv \
  dpu_common/src/dpu_device_bootstrap_plan_builder.sv \
  dpu_common/src/dpu_reg_executor.sv dpu_common/src/dpu_spy_reg_executor.sv \
  dpu_common/src/dpu_config_orchestrator.sv dpu_common/src/dpu_device_env.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_device_bootstrap_plan_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: build and report DPU PCI AF bootstrap plans"
```

### Task 6: Service-Keyed VIO Behavior Configuration

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`

**Interfaces:**
- Consumes: frozen `dpu_device_snapshot` and `dpu_service_key_t`.
- Produces: `add_service_config`, `get_service_config`, `make_default_driver_config`, `validate_local`, and `validate_against_snapshot`.
- Old positional fields remain only so unconverted tests compile; Task 10 deletes them.

- [ ] **Step 1: Write service-key identity RED tests**

Create two VIO keys with the same `pf_id/vf_id` on different hosts and assign
different queue sizes. Assert exact-key lookup returns the correct setting,
an RDMA key is rejected, duplicate VIO keys are rejected, an undeclared VIO
service is rejected against the snapshot, and an absent override returns the
default behavior capped by `snapshot_dut_caps().max_vio_net_qpairs_per_device`.

- [ ] **Step 2: Run RED**

```bash
run_remote_test virtio_dut_caps_test
```

Expected: compile failure naming `add_service_config`.

- [ ] **Step 3: Implement explicit keyed entries**

Store owned entries containing `{dpu_service_key_t key,
virtio_driver_config_t cfg}`. Use `dpu_service_key_name` for duplicate/lookup
indexes and retain defensive copies. Use these final signatures:

```systemverilog
function bit add_service_config(
    input dpu_service_key_t key,
    input virtio_driver_config_t driver_cfg,
    output string why);
function bit get_service_config(
    input dpu_service_key_t key,
    input int unsigned max_pairs,
    output virtio_driver_config_t driver_cfg,
    output string why);
function bit validate_against_snapshot(
    input dpu_device_snapshot snapshot,
    output string why);
```

- [ ] **Step 4: Separate local behavior validation from global capability**

`validate_local` checks queue size, memory range, and protocol behavior without
owning DUT caps. `validate_against_snapshot` requires a frozen snapshot,
checks every configured key is a declared VIO service, and enforces the
snapshot's 32-pair profile limit.

- [ ] **Step 5: Run GREEN**

```bash
run_remote_test virtio_dut_caps_test
```

Expected: PASS; cross-host equal VF IDs do not alias.

- [ ] **Step 6: Commit**

```bash
git add virtio_net_vip/src/env/virtio_net_env_config.sv \
  virtio_net_vip/tests/virtio_dut_caps_test.sv
git commit -m "feat: bind VIO behavior by global service key"
```

### Task 7: Snapshot-Driven VIO Function Construction

**Files:**
- Create: `virtio_net_vip/tests/virtio_test_device_builder.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv`
- Modify: `virtio_net_vip/tests/virtio_monitor_routing_test.sv`
- Modify: `filelists/tests.f`

**Interfaces:**
- Produces test builder methods `add_host_domain`, `add_pf`, `add_vf`, `add_vio_service`, `add_real_dut_bars`, `select_af`, and `make_env_config`.
- Produces: `virtio_pf_instance::configure_services(parent_pf_key, snapshot, service_keys, manager)` and `collect_functions(ref functions[$])`.
- Produces: `virtio_resource_client::bind_to_device`; the old name delegates temporarily until Task 10.
- Produces: canonical `virtio_net_env::function_instances[]`, with
  `vf_instances[]` retained only as the actual-VF view.

- [ ] **Step 1: Add the test-only explicit configuration builder**

The builder must add explicit objects and call no resolver-private API. Its
`add_real_dut_bars` creates three AUTO requests from the selected function
kind's capability profile. `make_env_config` returns a `dpu_device_env_config`
with the qpair profile `{name="virtio.qpair",kind=QUEUE,capacity=2048,max=32}`.

- [ ] **Step 2: Convert monitor routing into the snapshot-path RED test**

Author host0/domain0/PF0/VF0, attach VIO service instance 0 to both functions,
select PF0 as AF, create `dpu_device_env` as parent and `virtio_net_env` as its
child, and set VIO behavior at `device_env.virtio_env`. Preserve the existing
PF/VF monitor-routing assertions.

Use this hierarchy and config path exactly:

```systemverilog
uvm_config_db#(dpu_device_env_config)::set(
    this, "device_env", "cfg", device_env_cfg);
device_env = dpu_device_env::type_id::create("device_env", this);
uvm_config_db#(virtio_net_env_config)::set(
    this, "device_env.virtio_env", "cfg", virtio_cfg);
virtio_env = virtio_net_env::type_id::create("virtio_env", device_env);
```

- [ ] **Step 3: Run RED**

```bash
run_remote_test virtio_monitor_routing_test
```

Expected: VIO environment fatal because it cannot consume the published snapshot.

- [ ] **Step 4: Build PF/VF service groups from snapshot keys**

The VIO environment retrieves `dpu_device_snapshot` and
`dpu_resource_manager` from config DB, validates its behavior config, lists
`DPU_SERVICE_VIO_NET`, groups keys by parent PF, and creates one
`virtio_pf_instance` per group. `virtio_pf_instance` queries each service
owner's BDF and three BAR roles and creates a PF or VF function component only
for declared VIO services.

Use these final signatures:

```systemverilog
function bit configure_services(
    input dpu_function_key_t parent_pf_key,
    input dpu_device_snapshot snapshot,
    input dpu_service_key_t service_keys[$],
    input dpu_resource_manager manager,
    output string why);
function void collect_functions(
    ref virtio_function_instance functions[$]);
```

- [ ] **Step 5: Configure function objects from resolved values**

Pass exact key, `pcie_id.bdf`, BAR copies, and the global manager to
`configure_function`. Remove all arithmetic VF BDF construction from the new
path. `collect_functions` returns PF and VF VIO functions in canonical service
order so sequencer and monitor wiring are stable.

- [ ] **Step 6: Bind generic resources by device identity**

Rename user-facing messages and methods from Fabric binding to device binding.
`bind_to_device` verifies the manager already contains the function from the
snapshot, looks up `virtio.qpair`, snapshots caps, and preserves one-shot
ownership semantics.

- [ ] **Step 7: Run GREEN**

```bash
run_remote_test virtio_monitor_routing_test
run_remote_test dpu_device_resolver_test
```

Expected: monitor routing PASS; PF and VF identities/BDFs come from snapshot.

- [ ] **Step 8: Commit**

```bash
git add virtio_net_vip/tests/virtio_test_device_builder.sv \
  virtio_net_vip/src/env/virtio_net_env.sv \
  virtio_net_vip/src/sriov/virtio_pf_instance.sv \
  virtio_net_vip/src/sriov/virtio_function_instance.sv \
  virtio_net_vip/src/sriov/virtio_vf_instance.sv \
  virtio_net_vip/src/sriov/virtio_resource_client.sv \
  virtio_net_vip/tests/virtio_monitor_routing_test.sv filelists/tests.f
git commit -m "feat: construct VIO functions from DPU snapshots"
```

### Task 8: Migrate Shared and Standalone VIO Tests

**Files:**
- Modify: `virtio_net_vip/tests/virtio_base_test.sv`
- Modify: `virtio_net_vip/tests/virtio_e2e_test.sv`
- Modify: `virtio_net_vip/tests/virtio_coverage_test.sv`
- Modify: `virtio_net_vip/tests/virtio_admin_vq_test.sv`
- Modify: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv`
- Modify: `virtio_net_vip/tests/virtio_smoke_test.sv`

**Interfaces:**
- Consumes: Task 7 test builder and snapshot VIO path.
- Produces: `virtio_base_test` fields `device_env`, `device_builder`, `device_cfg`, `cfg`, and `env`.

- [ ] **Step 1: Convert the shared base test fixture**

Create one explicit host0/domain0/PF0 VIO service and select PF0 as AF in
`virtio_base_test::build_phase`. Create `device_env` under the test and `env`
under `device_env`. Replace `set_num_vfs(n)` with test-only
`add_vio_vfs(n)`, which explicitly adds VF0 through VF`n-1` and their VIO
services before UVM child build begins.

- [ ] **Step 2: Convert standalone E2E and coverage fixtures**

Replace `num_vfs`, `pf_bdf`, and capability writes with explicit device
builder calls. Preserve BDF `16'h0100` only through a PINNED BDF request when a
test checks that exact requester ID.

- [ ] **Step 3: Update direct instance references where PF service replaces flat VF0**

Use `env.function_instances[0]` for service-generic checks. Use
`env.pf_instances[0].pf_function` only for PF lifecycle assertions, and
`env.pf_instances[0].vf_functions[index]` only when the test explicitly
declared a VF service.

- [ ] **Step 4: Run affected focused tests**

```bash
run_remote_test virtio_unit_test
run_remote_test virtio_e2e_test
run_remote_test virtio_coverage_test
run_remote_test virtio_admin_vq_test
run_remote_test virtio_pf_lifecycle_reset_test
run_remote_test virtio_smoke_test
```

Expected: all six PASS with strict logs.

- [ ] **Step 5: Commit**

```bash
git add virtio_net_vip/tests/virtio_base_test.sv \
  virtio_net_vip/tests/virtio_e2e_test.sv \
  virtio_net_vip/tests/virtio_coverage_test.sv \
  virtio_net_vip/tests/virtio_admin_vq_test.sv \
  virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv \
  virtio_net_vip/tests/virtio_smoke_test.sv
git commit -m "test: migrate VIO fixtures to global device snapshots"
```

### Task 9: Migrate Capability Ownership Tests

**Files:**
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv`

**Interfaces:**
- Consumes: `dpu_device_snapshot::snapshot_dut_caps` and service-key VIO config.
- Produces no new public interface.

- [ ] **Step 1: Reclassify old capability tests by owner**

Keep VIO-local tests for queue count, queue size, bind identity, dynamic
reconfiguration, and malicious snapshot copies in `virtio_dut_caps_test`.
Delete duplicate host/PF/VF matrix validation from this file because Task 2/3
now tests it in `dpu_device_resolver_test`.

- [ ] **Step 2: Replace every VIO-owned capability fixture**

For each phase-window, multi-bind, alias, adapter, endpoint, and fatal-probe
environment, create a dedicated explicit device config/snapshot with the
needed capability values. Pass only behavior configuration to VIO. Obtain the
manager and caps through the owning `dpu_device_env`/snapshot.

Add and use this exact boundary in `virtio_dynamic_reconfig`:

```systemverilog
function bit bind_device_snapshot(
    input dpu_device_snapshot snapshot,
    output string why);
```

It rejects null/unfrozen snapshots, obtains a defensive capability copy with
`snapshot.snapshot_dut_caps()`, and preserves the existing one-shot capability
binding semantics. Delete direct VIO-environment calls to `bind_dut_caps`.

- [ ] **Step 3: Preserve negative ownership tests against the new boundary**

Verify a VIO config cannot change `max_hosts`, `max_pfs_per_host`,
`max_vfs_per_pf`, global qpair capacity, or the 32-pair ceiling because it has
no `dut_caps` handle. Verify a copied snapshot/caps mutation does not alter the
device env, resource manager, dynamic reconfig, or another VIO function.

- [ ] **Step 4: Rename Fabric resource-client calls**

Replace `bind_to_fabric`/`is_bound_to_fabric` uses with
`bind_to_device`/`is_bound_to_device`, preserving the existing one-owner,
same-key idempotence and reassignment rejection tests.

- [ ] **Step 5: Run focused GREEN tests**

```bash
run_remote_test virtio_dut_caps_test
run_remote_test dpu_device_resolver_test
run_remote_test dpu_resource_manager_test
```

Expected: all PASS; no VIO test config owns DUT caps.

- [ ] **Step 6: Commit**

```bash
git add virtio_net_vip/tests/virtio_dut_caps_test.sv \
  virtio_net_vip/src/env/virtio_dynamic_reconfig.sv
git commit -m "test: move DUT capability authority to device snapshots"
```

### Task 10: Migrate Fabric Coverage and Perform the Hard Cut

**Files:**
- Modify: `virtio_net_vip/tests/virtio_fabric_resource_test.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv`
- Modify: `dpu_common/src/dpu_resource_manager.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Delete: `dpu_common/src/dpu_fabric_env.sv`

**Interfaces:**
- Finalizes the spec interfaces and removes all legacy topology/BAR authority.

- [ ] **Step 1: Rewrite Fabric resource coverage as device-snapshot coverage**

Author the existing four PF and 22 VF functions explicitly, attach one VIO
service to every tested function, and keep one-qpair-per-function lease
coverage. Replace the old adjacent-PF BDF formula assertion with deterministic
AUTO ordering and explicit reverse lookups.

- [ ] **Step 2: Add independent-domain reuse coverage**

Create host0/segment0 and host1/segment0 with the same PINNED BDF and same
numeric BAR bases. Assert both resolve and route by domain. Add a same-domain
clone and assert the resolver rejects the BDF/BAR collision before any resource
manager or PCIe operation exists.

- [ ] **Step 3: Replace reserved BAR assertions with mailbox assertions**

Require BAR2/3 role `DPU_BAR_MAILBOX`, exact snapshot forward/reverse mapping,
six config-write TLPs for three pairs, and permitted BAR2 functional access.
Continue rejecting functional access through BAR4/5 except the MSI-X API.

- [ ] **Step 4: Delete legacy VIO configuration and topology branches**

Remove `num_hosts`, `num_pfs_per_host`, `num_vfs_per_pf`, `num_vfs`,
`max_vfs`, `dut_caps`, `pf_bdf`, positional `vf_configs`, their helper methods,
`fabric_pf_bdf`, `build_fabric_topology`, the flat compatibility build branch,
and every single-aperture constant. The VIO env must fatal if no frozen device
snapshot or no declared VIO service is supplied.

- [ ] **Step 5: Delete legacy instance/resource-manager entry points**

Remove `virtio_pf_instance::configure_topology`,
`configure_fabric_resources`, `virtio_function_instance::configure` with raw
VF/BDF/BAR values, `virtio_vf_instance::configure_fabric_function`, and the
old resource-client Fabric names. Remove resource-manager aperture/cursor/BAR
allocation, client function registration, `activate_function`, and Fabric
authority methods. Retain only snapshot seeding and generic lease lifecycle.

- [ ] **Step 6: Delete `dpu_fabric_env` and prove forbidden names are gone**

Run:

```bash
! rg -n "dpu_fabric_env|DPU_BAR_RESERVED|fabric_pf_bdf|uses_fabric_topology|total_fabric_(pfs|vfs)|num_pfs_per_host|num_vfs_per_pf|pf_bdf" \
  dpu_common/src virtio_net_vip/src virtio_net_vip/tests
```

Expected: exit zero from the leading `!`, meaning no matches.

- [ ] **Step 7: Run the hard-cut focused set**

```bash
run_remote_test dpu_device_resolver_test
run_remote_test dpu_device_bootstrap_plan_test
run_remote_test dpu_resource_manager_test
run_remote_test virtio_fabric_resource_test
run_remote_test virtio_dut_caps_test
run_remote_test virtio_monitor_routing_test
run_remote_test virtio_unit_test
```

Expected: all PASS; compile proves no test uses removed fields.

- [ ] **Step 8: Commit**

```bash
git add -A dpu_common/src dpu_common/tests \
  virtio_net_vip/src virtio_net_vip/tests/virtio_fabric_resource_test.sv
git commit -m "refactor: hard cut VIO topology to global DPU ownership"
```

### Task 11: Documentation, Static Guards, and Full VCS Regression

**Files:**
- Modify: `README.md:300-345`
- Modify: `docs/virtio_net_vip_manual.md:1230-1280`
- Modify: `docs/virtio_net_vip_manual.md:1410-1440`
- Modify: `scripts/test_manifest.sh`
- Modify: `filelists/tests.f`

**Interfaces:**
- Documents the final authoring and execution boundary; no source interface changes.

- [ ] **Step 1: Update user-facing configuration examples**

Show one explicit host/domain/PF0/VF0 configuration, three BAR requests per
function, AF selection, VIO service declaration, and a service-key behavior
override. State that BAR2/3 is mailbox, VIO has no topology fields, and an
executor is injected separately.

- [ ] **Step 2: Document future placement without implementing it**

Describe `total_qpairs=100` as a later normalization feature: four devices are
required by the 32-pair limit, Host/PF inventory remains explicit, VFs may be
activated from declared pools later, and execution receives only explicit
resolved bindings. Name `AUTO_MINIMUM`, `FIXED`, and `ALL_ELIGIBLE` device
selection plus `EXACT` and `AT_LEAST` partial-assignment semantics so the
document matches the reserved extension contract.

- [ ] **Step 3: Run static consistency checks**

```bash
git diff --check
rg -n "DPU_BAR_MAILBOX|DPU_AF_DECLARATION_ADDR|dpu_device_snapshot|dpu_service_key_t" \
  dpu_common/src virtio_net_vip/src README.md docs/virtio_net_vip_manual.md
! rg -n "BAR2/3.*reserved|DPU_BAR_RESERVED|dpu_fabric_env|pf_bdf|num_pfs_per_host|num_vfs_per_pf" \
  dpu_common/src virtio_net_vip/src README.md docs/virtio_net_vip_manual.md
```

Expected: first searches show the new contracts; forbidden search returns no matches.

- [ ] **Step 4: Confirm the maintained manifest contains both new tests exactly once**

```bash
test "$(grep -c '^  dpu_device_resolver_test$' scripts/test_manifest.sh)" -eq 1
test "$(grep -c '^  dpu_device_bootstrap_plan_test$' scripts/test_manifest.sh)" -eq 1
test "$(grep -c '^dpu_common/tests/dpu_device_resolver_test.sv$' filelists/tests.f)" -eq 1
test "$(grep -c '^dpu_common/tests/dpu_device_bootstrap_plan_test.sv$' filelists/tests.f)" -eq 1
```

- [ ] **Step 5: Run the full strict regression on 53**

Stage the tree with the global recipe, then run:

```bash
ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd /home/ubuntu/test_cosim/virtio-global-device-subproject2 && STRICT_TEST_TIMEOUT_SECONDS=180 ./scripts/strict_regression.sh'"
```

Expected final line: `STRICT_REGRESSION PASS tests=21` with all previous 19 tests plus `dpu_device_resolver_test` and `dpu_device_bootstrap_plan_test` passing.

- [ ] **Step 6: Review the final diff against every acceptance criterion**

Check the spec sections 2, 3, 7, 9, 11, 14, and 15. Confirm there is no
production executor, automatic VF placement, qpair placement policy, or later
DUT-table implementation in the diff.

- [ ] **Step 7: Commit**

```bash
git add README.md docs/virtio_net_vip_manual.md \
  scripts/test_manifest.sh filelists/tests.f
git commit -m "docs: describe global DPU configuration ownership"
```

- [ ] **Step 8: Record final verification evidence**

```bash
git status --short
git log --oneline --decorate -12
```

Expected: clean worktree; commits for all 11 tasks; remote strict regression evidence retained in `/home/ubuntu/test_cosim/virtio-global-device-subproject2/build/strict/`.
