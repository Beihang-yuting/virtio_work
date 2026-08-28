# VIO Qpair Resource Placement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a declarative pipeline that converts total VIO-net qpair demand and PF/VF constraints into materialized device configuration, a frozen device snapshot, and a frozen resource snapshot with explicit local/global qpair bindings.

**Architecture:** `dpu_placement_normalizer` selects explicit PF/VF devices or declared VF templates and expands policy choices into a normalized placement plan. The existing device resolver freezes BDF/BAR/service identity, then `dpu_resource_resolver` assigns local/global qpair IDs and freezes a service-keyed resource snapshot; the device environment publishes both snapshots only after snapshot-importing resource-manager initialization succeeds.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, existing DPU device/resource packages, existing VIO-net UVM VIP, Bash strict regression scripts.

**Spec:** `docs/superpowers/specs/2026-08-28-vio-qpair-resource-placement-design.md`

## Global Constraints

- Begin execution in an isolated worktree created with `superpowers:using-git-worktrees`.
- Host and PF inventory is explicit; qpair demand never synthesizes either one.
- A new VF is materialized only from an explicitly declared template under its explicit parent PF.
- One VIO participant owns `1..32` qpairs; a scenario profile may narrow but never widen this DUT limit.
- `local_pair_id` is `0..31`; sparse values are legal.
- `global_qpair_id` is `0..2047`; one RX/TX pair consumes one global pair ID.
- RX local virtqueue ID is `2*local_pair_id`; TX local virtqueue ID is `2*local_pair_id+1`.
- The current real-DUT profile requires `service_instance_id == 0` and at most one VIO-net service per PF/VF.
- `PINNED` conflicts fail; `PREFERRED` conflicts fall back to `AUTO`.
- Global reservations accept individual IDs and inclusive ranges; valid
  overlaps normalize to one ascending union before allocation.
- Automatic global IDs always use the lowest unreserved free ID, independent of seed.
- All request resolution and publication is deterministic and all-or-nothing.
- Source authoring objects remain unchanged; snapshots return defensive copies and cannot mutate after freeze.
- Final production code has one VIO qpair authority: the frozen resource snapshot. Incremental `virtio.qpair` acquire/release authoring is removed.
- Temporary branch-local compatibility used only to compile intermediate shared-filelist commits must be deleted in Task 11.
- Do not implement MSI-X, notify, BDF-table programming, ports, qsch/dsch,
  forwarding, control/Admin-VQ resource placement, RDMA/VBLK resolution, a
  production DUT executor, or `cosim_control`.
- Run every VCS compile/simulation on `ubuntu@10.11.10.53` through `bash -lic`; do not persist the password in repository files, URLs, helpers, or Git configuration.
- Use these execution-time helpers for every VCS step:

```bash
remote_stage=/home/ubuntu/test_cosim/virtio-vio-qpair-placement
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

- Run `stage_remote` after every code-edit batch. A focused test is green only when VCS exits zero and `scripts/strict_log_check.sh sim` accepts its log.
- Keep the final `dpu_resource_pkg.sv` dependency order as
  `dpu_device_types.sv`, `dpu_placement_types.sv`, `dpu_resource_types.sv`,
  `dpu_placement_cfg.sv`, existing register/capability/device configuration
  classes, `dpu_normalized_placement_plan.sv`,
  `dpu_placement_normalizer.sv`, `dpu_device_snapshot.sv`,
  `dpu_device_resolver.sv`, `dpu_resource_snapshot.sv`,
  `dpu_resource_resolver.sv`, `dpu_configuration_resolver.sv`, manager, plan
  builders, and environment. If an existing class introduces a stricter
  dependency, move that class later without changing the first four entries.

---

## File Structure

### New DPU common files

- `dpu_common/src/dpu_placement_types.sv`: placement enums, tagged resource owner, normalized target/binding records, diagnostic codes, and stable key helpers.
- `dpu_common/src/dpu_placement_cfg.sv`: deep-copy authoring classes for filters, constraints, overrides, requests, profiles, and individual/range global reservations.
- `dpu_common/src/dpu_normalized_placement_plan.sv`: frozen explicit participants, target counts, pair owners/ID intents, candidate orders, seed, and effective profile.
- `dpu_common/src/dpu_placement_normalizer.sv`: source validation, candidate collection, deterministic device selection, VF materialization, balancing, and pair-owner expansion.
- `dpu_common/src/dpu_resource_snapshot.sv`: immutable service-keyed qpair bindings, metadata, reservations, and typed queries.
- `dpu_common/src/dpu_resource_resolver.sv`: local/global ID passes and device/resource cross-snapshot validation.
- `dpu_common/src/dpu_configuration_resolver.sv`: candidate-only orchestration of normalizer, device resolver, and resource resolver.

### New focused tests

- `dpu_common/tests/dpu_placement_test.sv`: request copy, VF pools, all policies, balancing, constraints, seed reproducibility, and normalization failures.
- `dpu_common/tests/dpu_resource_resolver_test.sv`: snapshot integrity, ID allocation, reservations, multi-request ordering, coordinator atomicity, and defensive queries.

### Existing files with changed responsibility

- `dpu_common/src/dpu_device_cfg.sv`: gains service eligibility and per-parent VF template pools; active VIO services remain normalized output only.
- `dpu_common/src/dpu_resource_types.sv`: lease ownership becomes function-or-service tagged ownership.
- `dpu_common/src/dpu_resource_pkg.sv`: includes new declarations/classes in dependency order.
- `dpu_common/src/dpu_resource_manager.sv`: imports frozen resource leases and becomes query-only for placement-owned VIO qpairs.
- `dpu_common/src/dpu_device_env.sv`: resolves placement, publishes both snapshots, and initializes the manager after both candidates freeze.
- `virtio_net_vip/src/sriov/virtio_resource_client.sv`: imports one service's immutable bindings instead of acquiring/releasing them.
- `virtio_net_vip/src/sriov/virtio_function_instance.sv`, `virtio_vf_instance.sv`, `virtio_pf_instance.sv`: bind both snapshots by service key.
- `virtio_net_vip/src/env/virtio_net_env.sv`: requires and distributes the frozen resource snapshot.
- `virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv`: remains a local naming/query view and imports snapshot-backed mappings only.
- `virtio_net_vip/tests/virtio_test_device_builder.sv`: authors eligibility and placement requests rather than predeclared VIO services.
- `filelists/tests.f`, `scripts/test_manifest.sh`: register both focused tests exactly once.
- `README.md`, `docs/virtio_net_vip_manual.md`: document final authoring and immutable consumption.

---

### Task 1: Placement Request Types and Deep-Copy Authoring

**Files:**
- Create: `dpu_common/src/dpu_placement_types.sv`
- Create: `dpu_common/src/dpu_placement_cfg.sv`
- Create: `dpu_common/tests/dpu_placement_test.sv`
- Modify: `dpu_common/src/dpu_resource_types.sv:10-44`
- Modify: `dpu_common/src/dpu_resource_manager.sv:490-510`
- Modify: `dpu_common/src/dpu_resource_pkg.sv:8-30`
- Modify: `virtio_net_vip/tests/virtio_admin_vq_test.sv:410-422`
- Modify: `filelists/tests.f:1-12`
- Modify: `scripts/test_manifest.sh:3-50`

**Interfaces:**
- Produces placement policy/order/constraint/assignment/stage/error enums.
- Produces `dpu_resource_owner_t`, `dpu_global_id_range_t`, `dpu_vio_participant_target_t`, `dpu_normalized_vio_pair_t`, and `dpu_vio_qpair_binding_t`.
- Produces `dpu_vio_candidate_filter`, `dpu_vio_device_constraint`, `dpu_vio_qpair_override`, `dpu_vio_placement_request`, `dpu_resource_placement_cfg`, and `dpu_placement_diagnostic`.
- `dpu_resource_placement_cfg.profiles[$]` owns `dpu_resource_pool_config_t` scenario profiles; `virtio.qpair` supplies effective global/per-device limits.
- `dpu_resource_placement_cfg.reserved_global_qpair_ids[$]` stores individual
  reservations; `reserved_global_qpair_ranges[$]` stores inclusive ranges. A
  single reserved ID is not represented by a magic range sentinel.

- [ ] **Step 1: Register a failing placement-authoring test**

Add `dpu_placement_test` after `dpu_device_resolver_test` in the maintained
manifest, add its source exactly once in `filelists/tests.f`, and require it
exactly once in `_validate_virtio_test_manifest()`.

Start with this deep-copy contract:

```systemverilog
source = dpu_resource_placement_cfg::type_id::create("source");
request = dpu_vio_placement_request::type_id::create("request");
request.request_id = 7;
request.total_qpairs = 100;
request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
request.device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
source.vio_requests.push_back(request);
reserved.first_id = 9;
reserved.last_id = 12;
source.reserved_global_qpair_ranges.push_back(reserved);
clone = dpu_resource_placement_cfg::type_id::create("clone");
clone.copy_from(source);
clone.vio_requests[0].total_qpairs = 1;
clone.reserved_global_qpair_ranges[0].first_id = 10;
if ((source.vio_requests[0].total_qpairs != 100) ||
    (source.reserved_global_qpair_ranges[0].first_id != 9))
    `uvm_fatal("PLACEMENT", "placement clone aliases its source")
```

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_placement_test
```

Expected: VCS compile failure naming undefined placement classes or enums.

- [ ] **Step 3: Define exact placement declarations**

```systemverilog
typedef enum int unsigned {
  DPU_VIO_CANDIDATE_PF_ONLY, DPU_VIO_CANDIDATE_VF_ONLY,
  DPU_VIO_CANDIDATE_PF_AND_VF
} dpu_vio_candidate_kind_e;
typedef enum int unsigned {
  DPU_VIO_DEVICE_AUTO_MINIMUM, DPU_VIO_DEVICE_FIXED,
  DPU_VIO_DEVICE_ALL_ELIGIBLE
} dpu_vio_device_policy_e;
typedef enum int unsigned {
  DPU_PLACEMENT_CANONICAL, DPU_PLACEMENT_SEEDED_RANDOM
} dpu_placement_order_e;
typedef enum int unsigned { DPU_COUNT_EXACT, DPU_COUNT_AT_LEAST }
  dpu_count_constraint_mode_e;
typedef enum int unsigned {
  DPU_ASSIGN_AUTO, DPU_ASSIGN_PINNED, DPU_ASSIGN_PREFERRED
} dpu_assignment_mode_e;
typedef enum int unsigned {
  DPU_RESOURCE_OWNER_FUNCTION, DPU_RESOURCE_OWNER_SERVICE
} dpu_resource_owner_kind_e;
typedef enum int unsigned {
  DPU_PLACE_STAGE_NONE, DPU_PLACE_STAGE_INPUT, DPU_PLACE_STAGE_SELECTION,
  DPU_PLACE_STAGE_DEVICE_RESOLUTION, DPU_PLACE_STAGE_RESOURCE_RESOLUTION,
  DPU_PLACE_STAGE_CROSS_SNAPSHOT
} dpu_placement_stage_e;
typedef enum int unsigned {
  DPU_PLACE_ERR_NONE,
  DPU_PLACE_ERR_INVALID_PROFILE,
  DPU_PLACE_ERR_DUPLICATE_REQUEST,
  DPU_PLACE_ERR_INVALID_REQUEST,
  DPU_PLACE_ERR_INVALID_FILTER,
  DPU_PLACE_ERR_INVALID_VF_POOL,
  DPU_PLACE_ERR_SOURCE_VIO_SERVICE,
  DPU_PLACE_ERR_NO_ELIGIBLE_DEVICE,
  DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
  DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
  DPU_PLACE_ERR_DUPLICATE_SERVICE_OWNER,
  DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
  DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
  DPU_PLACE_ERR_INVALID_RESERVATION,
  DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
  DPU_PLACE_ERR_GLOBAL_QID_RESERVED,
  DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
  DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED,
  DPU_PLACE_ERR_DEVICE_RESOLUTION_FAILED,
  DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH
} dpu_placement_error_e;
typedef struct {
  dpu_resource_owner_kind_e kind;
  dpu_function_key_t function_key;
  dpu_service_key_t service_key;
} dpu_resource_owner_t;
typedef struct { int unsigned first_id; int unsigned last_id; }
  dpu_global_id_range_t;
typedef struct {
  int unsigned request_id;
  dpu_service_key_t service_key;
  int unsigned qpair_count;
} dpu_vio_participant_target_t;
typedef struct {
  int unsigned request_pair_index;
  dpu_service_key_t service_key;
  dpu_assignment_mode_e local_mode;
  int unsigned requested_local_pair_id;
  dpu_assignment_mode_e global_mode;
  int unsigned requested_global_qpair_id;
} dpu_normalized_vio_pair_t;
typedef struct {
  int unsigned request_id;
  int unsigned request_pair_index;
  dpu_service_key_t service_key;
  int unsigned local_pair_id;
  int unsigned rx_local_virtqueue_id;
  int unsigned tx_local_virtqueue_id;
  int unsigned global_qpair_id;
} dpu_vio_qpair_binding_t;
```

The externally stable subset includes `DPU_PLACE_ERR_NO_ELIGIBLE_DEVICE`,
`DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED`,
`DPU_PLACE_ERR_LOCAL_QID_CONFLICT`, `DPU_PLACE_ERR_GLOBAL_QID_RESERVED`,
`DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED`, and
`DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH`. Change
`dpu_resource_lease_t.owner` to `dpu_resource_owner_t`. Include files in this
order: device types, placement types, resource types, placement cfg, then the
exact class order in Global Constraints.

The diagnostic class exposes `clear()`, `set(stage, code, message)`,
`set_request_context(request_id)`, `set_function_context(function_key)`,
`set_service_context(service_key)`, `set_pair_context(request_pair_index)`, and
`set_device_resolution_failure(detail)`. Each context setter raises its
matching presence bit so zero is distinguishable from an absent context; every
new error path calls `set()` first and then only the applicable context setters.

- [ ] **Step 4: Implement request classes and defensive copy**

```systemverilog
class dpu_vio_candidate_filter extends uvm_object;
  `uvm_object_utils(dpu_vio_candidate_filter)
  int unsigned host_ids[$];
  dpu_function_key_t parent_pf_keys[$];
  int unsigned vf_ids[$];
  dpu_function_key_t function_keys[$];
endclass
class dpu_vio_device_constraint extends uvm_object;
  `uvm_object_utils(dpu_vio_device_constraint)
  dpu_function_key_t function_key;
  dpu_count_constraint_mode_e mode;
  int unsigned qpair_count;
endclass
class dpu_vio_qpair_override extends uvm_object;
  `uvm_object_utils(dpu_vio_qpair_override)
  int unsigned request_pair_index;
  dpu_assignment_mode_e owner_mode;
  dpu_function_key_t requested_owner;
  dpu_assignment_mode_e local_mode;
  int unsigned requested_local_pair_id;
  dpu_assignment_mode_e global_mode;
  int unsigned requested_global_qpair_id;
endclass
class dpu_vio_placement_request extends uvm_object;
  `uvm_object_utils(dpu_vio_placement_request)
  int unsigned request_id, service_instance_id, total_qpairs, seed;
  dpu_vio_candidate_kind_e candidate_kind;
  dpu_vio_device_policy_e device_policy;
  dpu_placement_order_e ordering;
  dpu_vio_candidate_filter candidate_filter;
  dpu_function_key_t fixed_devices[$];
  dpu_vio_device_constraint device_constraints[$];
  dpu_vio_qpair_override qpair_overrides[$];
endclass
class dpu_resource_placement_cfg extends uvm_object;
  `uvm_object_utils(dpu_resource_placement_cfg)
  dpu_resource_pool_config_t profiles[$];
  dpu_vio_placement_request vio_requests[$];
  int unsigned reserved_global_qpair_ids[$];
  dpu_global_id_range_t reserved_global_qpair_ranges[$];
endclass
class dpu_placement_diagnostic extends uvm_object;
  `uvm_object_utils(dpu_placement_diagnostic)
  dpu_placement_stage_e stage;
  dpu_placement_error_e error_code;
  bit has_request_id, has_function_key, has_service_key, has_pair_index;
  int unsigned request_id, request_pair_index;
  dpu_function_key_t function_key;
  dpu_service_key_t service_key;
  string message;
endclass
```

Filters contain `host_ids[$]`, `parent_pf_keys[$]`, `vf_ids[$]`, and
`function_keys[$]`; empty means unrestricted and nonempty dimensions combine
with AND. Every class implements `copy_from()` and `do_copy()` in the existing
configuration style. Deep-copy `candidate_filter`, constraint/override/request
objects, and profile/reservation queues; scalar and struct queues copy by
value. Constructors create a non-null request filter, default request ordering
to `DPU_PLACEMENT_CANONICAL`, default all override modes to `DPU_ASSIGN_AUTO`,
and default `service_instance_id` to zero. Diagnostics store presence bits plus
request/function/service/pair context; `clear()` resets all fields.

Keep this intermediate commit compiling by adapting the old manager assignment
and Admin-VQ test lease literal without changing their behavior:

```systemverilog
lease.owner.kind = DPU_RESOURCE_OWNER_FUNCTION;
lease.owner.function_key = key;

ctx.special_vq_lease.owner.kind = DPU_RESOURCE_OWNER_FUNCTION;
ctx.special_vq_lease.owner.function_key.host_id = 0;
ctx.special_vq_lease.owner.function_key.pf_id = 0;
ctx.special_vq_lease.owner.function_key.kind = DPU_FUNCTION_PF;
ctx.special_vq_lease.owner.function_key.vf_id = 0;
ctx.special_vq_lease.owner.service_key = '{default: '0};
```

- [ ] **Step 5: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_placement_types.sv \
  dpu_common/src/dpu_placement_cfg.sv dpu_common/src/dpu_resource_types.sv \
  dpu_common/src/dpu_resource_manager.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_placement_test.sv \
  virtio_net_vip/tests/virtio_admin_vq_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: add VIO placement request model"
```

---

### Task 2: Service Eligibility and Per-PF VF Template Pools

**Files:**
- Modify: `dpu_common/src/dpu_device_cfg.sv:173-350`
- Modify: `dpu_common/tests/dpu_placement_test.sv`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv:270-610`

**Interfaces:**
- Produces `dpu_vf_template_cfg`, `dpu_vf_pool_cfg`, `dpu_function_cfg.eligible_service_kinds[$]`, and `dpu_device_cfg.vf_pools[$]`.
- Produces
  `function automatic bit dpu_service_kind_is_eligible(input dpu_service_kind_e kinds[$], input dpu_service_kind_e service_kind)`.

- [ ] **Step 1: Add failing VF-pool ownership and copy tests**

```systemverilog
pool = dpu_vf_pool_cfg::type_id::create("pf2_pool");
pool.parent_pf = make_function_key(0, 2, DPU_FUNCTION_PF, 0);
template = dpu_vf_template_cfg::type_id::create("vf7_template");
template.vf_id = 7;
template.domain_key.host_id = 0;
template.domain_key.segment_id = 0;
template.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
pool.vf_templates.push_back(template);
cfg.vf_pools.push_back(pool);
clone.copy_from(cfg);
clone.vf_pools[0].vf_templates[0].vf_id = 9;
if (cfg.vf_pools[0].vf_templates[0].vf_id != 7)
  `uvm_fatal("PLACEMENT", "VF template clone aliases its source")
```

Also assert an explicit function can be VIO+RDMA eligible while `services`
remains empty.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 3: Add pool/template classes and deep-copy integration**

```systemverilog
class dpu_vf_template_cfg extends uvm_object;
  `uvm_object_utils(dpu_vf_template_cfg)
  int unsigned vf_id;
  dpu_pcie_domain_key_t domain_key;
  dpu_allocation_mode_e bdf_mode;
  bit [15:0] pinned_bdf;
  dpu_bar_request bars[$];
  dpu_service_kind_e eligible_service_kinds[$];
endclass
class dpu_vf_pool_cfg extends uvm_object;
  `uvm_object_utils(dpu_vf_pool_cfg)
  dpu_function_key_t parent_pf;
  dpu_vf_template_cfg vf_templates[$];
endclass
```

Deep-copy BAR requests, eligibility queues, pools, and templates. A template
has no active `services` field. Extend explicit function and device copy paths.

- [ ] **Step 4: Preserve standalone device-resolver coverage**

Keep direct `dpu_device_resolver` service tests valid. Add eligibility and
pool clone assertions to its deep-copy test; the later placement coordinator,
not the base resolver, rejects source VIO declarations.

- [ ] **Step 5: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_placement_test
run_remote_test dpu_device_resolver_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_device_cfg.sv \
  dpu_common/tests/dpu_placement_test.sv \
  dpu_common/tests/dpu_device_resolver_test.sv
git commit -m "feat: add explicit VF template pools"
```

---

### Task 3: Canonical Selection, VF Materialization, and Basic Balancing

**Files:**
- Create: `dpu_common/src/dpu_normalized_placement_plan.sv`
- Create: `dpu_common/src/dpu_placement_normalizer.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_placement_test.sv`

**Interfaces:**
- Produces frozen `dpu_normalized_vio_request` and `dpu_normalized_placement_plan`.
- Produces
  `function bit dpu_placement_normalizer::normalize(input dpu_device_cfg device_cfg, input dpu_resource_placement_cfg placement_cfg, output dpu_device_cfg normalized_device_cfg, output dpu_normalized_placement_plan normalized_plan, output dpu_placement_diagnostic diagnostic)`.
- `dpu_normalized_vio_request` contains `request_id`, `service_instance_id`,
  `total_qpairs`, effective policy/order/seed, canonical and effective
  candidate function-key queues, selected participant targets, and normalized
  pair records. `dpu_normalized_placement_plan` owns a frozen request queue,
  effective `global_capacity`, `device_capacity`, normalized reservation IDs
  and ranges, defensive copies of the declared resource profiles, and exposes
  `list_requests()` and `get_request(request_id, ...)` in addition to the
  target/pair queries below.

- [ ] **Step 1: Add failing selection-policy tests**

Build four eligible PFs and require 100 qpairs to produce `25/25/25/25` and
101 to produce `26/25/25/25`. Add `FIXED`, `ALL_ELIGIBLE`, PF-only, VF-only,
and a mixed PF/VF request; the VF-only fixed request names VF7 from a pool.
Require normalized output to contain materialized VF7 with
`{VF7,VIO_NET,0}`, while source objects and unselected templates remain
unchanged.

```systemverilog
if (!normalizer.normalize(source_cfg, placement_cfg,
                          normalized_cfg, plan, diagnostic))
  `uvm_fatal("PLACEMENT", diagnostic.message)
plan.list_targets(request.request_id, targets);
if ((targets.size() != 4) || (targets[0].qpair_count != 25) ||
    (targets[1].qpair_count != 25) || (targets[2].qpair_count != 25) ||
    (targets[3].qpair_count != 25))
  `uvm_fatal("PLACEMENT", "100-qpair balance is not 25/25/25/25")
```

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 3: Implement the frozen normalized plan**

```systemverilog
class dpu_normalized_vio_request extends uvm_object;
  `uvm_object_utils(dpu_normalized_vio_request)
  int unsigned request_id, service_instance_id, total_qpairs, seed;
  dpu_vio_device_policy_e device_policy;
  dpu_placement_order_e ordering;
  dpu_function_key_t canonical_candidates[$];
  dpu_function_key_t effective_candidates[$];
  dpu_vio_participant_target_t targets[$];
  dpu_normalized_vio_pair_t pairs[$];
endclass

class dpu_normalized_placement_plan extends uvm_object;
  `uvm_object_utils(dpu_normalized_placement_plan)
  int unsigned effective_global_capacity, effective_device_capacity;
  dpu_normalized_vio_request requests[$];
  dpu_resource_pool_config_t profiles[$];
  int unsigned reserved_global_qpair_ids[$];
  dpu_global_id_range_t reserved_global_qpair_ranges[$];
endclass

function bit add_request(input dpu_normalized_vio_request request,
                         output string why);
function bit freeze(output string why);
function bit is_frozen();
function void list_targets(input int unsigned request_id,
  ref dpu_vio_participant_target_t targets[$]);
function void list_pairs(input int unsigned request_id,
  ref dpu_normalized_vio_pair_t pairs[$]);
function void list_requests(ref dpu_normalized_vio_request requests[$]);
function bit get_request(input int unsigned request_id,
  output dpu_normalized_vio_request request);
function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
function void list_reserved_global_qpair_ranges(
  ref dpu_global_id_range_t ranges[$]);
function void list_resource_profiles(
  ref dpu_resource_pool_config_t profiles[$]);
```

Clear output queues, return copies, sort requests by ID, targets by effective
participant order, and pairs by request-pair index.

- [ ] **Step 4: Implement validation and candidate collection**

Locate exactly one `virtio.qpair` profile for nonempty VIO requests. Reject
profile expansion, duplicate request IDs, zero demand, nonzero service
instance, source VIO services, malformed filters/pools/templates, empty or
duplicate fixed lists, and out-of-cap values. Apply filter dimensions with AND
and canonical-sort by `{host,pf,kind,vf}`. Resolve requests by ascending
`request_id`, track function keys already selected by an earlier request, and
reject a later selection of the same function as
`DPU_PLACE_ERR_DUPLICATE_SERVICE_OWNER`.

Pool validation requires one pool at most per explicit parent PF, an explicit
PF-kind parent key, unique/in-range VF IDs, a template domain on the parent's
host, no collision with an explicit function key, non-null BAR objects, and
VIO eligibility before selection. For `parent_pf_keys`, a PF candidate matches
its own key and a VF/template candidate matches its explicit parent PF key.

For this independently testable intermediate commit, reject
`SEEDED_RANDOM`, nonempty device constraints, and nonempty pair overrides as
`DPU_PLACE_ERR_INVALID_REQUEST`; Task 4 removes those three temporary guards
when their full semantics and tests land. Never silently treat an authored
advanced policy as canonical/AUTO.

```systemverilog
effective_global_capacity = (profile.capacity < caps.vio_global_qpair_count) ?
  profile.capacity : caps.vio_global_qpair_count;
effective_device_capacity =
  (profile.max_per_function < caps.max_vio_net_qpairs_per_device) ?
  profile.max_per_function : caps.max_vio_net_qpairs_per_device;
```

- [ ] **Step 5: Implement policies and water-level balancing**

```systemverilog
case (request.device_policy)
  DPU_VIO_DEVICE_AUTO_MINIMUM:
    required_devices = (request.total_qpairs + effective_device_capacity - 1) /
                       effective_device_capacity;
  DPU_VIO_DEVICE_FIXED: required_devices = request.fixed_devices.size();
  DPU_VIO_DEVICE_ALL_ELIGIBLE: required_devices = candidates.size();
endcase
```

Reject zero participants, demand below participant count, or capacity
shortfall. Start targets at one and repeatedly increment the lowest target
below capacity, tie-breaking by effective order. Materialize selected templates
by copying identity/BDF/BAR/eligibility into a new function and adding one VIO
service; set every target's `request_id` from its enclosing request and do not
resolve BDF/BAR here.

- [ ] **Step 6: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_normalized_placement_plan.sv \
  dpu_common/src/dpu_placement_normalizer.sv \
  dpu_common/src/dpu_resource_pkg.sv dpu_common/tests/dpu_placement_test.sv
git commit -m "feat: normalize VIO device placement"
```

---

### Task 4: Exact/At-Least Constraints, Pair Ownership, and Seeded Ordering

**Files:**
- Modify: `dpu_common/src/dpu_placement_normalizer.sv`
- Modify: `dpu_common/src/dpu_normalized_placement_plan.sv`
- Modify: `dpu_common/tests/dpu_placement_test.sv`

**Interfaces:**
- Extends normalization to all owner `AUTO/PINNED/PREFERRED` modes.
- Uses local Fisher-Yates with xorshift32; seed zero maps to `32'h6d2b79f5`.
- Normalized pairs carry explicit owner and unchanged local/global intents.

- [ ] **Step 1: Add failing constraint and reproducibility tests**

Require `EXACT 20`, `EXACT 4`, and 76 remaining pairs to select three flexible
devices and produce `20/4/26/25/25`. Add a pinned owner forcing a VF template,
a preferred owner that falls back outside `FIXED`, identical-seed equality,
and a different-seed valid-result check. Reorder authoring queues and require
identical canonical-mode output. Add failures for duplicate constraints,
duplicate overrides, an override index at `total_qpairs`, count zero, exact
below pinned count, ineligible pinned owner, selection of one function by two
requests, and ALL_ELIGIBLE demand below candidate count. Assert diagnostic
code and context, not only message text.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 3: Implement deterministic local shuffle**

```systemverilog
protected function int unsigned xorshift32(ref int unsigned state);
  if (state == 0) state = 32'h6d2b79f5;
  state ^= state << 13;
  state ^= state >> 17;
  state ^= state << 5;
  return state;
endfunction
```

Apply descending Fisher-Yates to a candidate copy. Never call `$urandom`,
`std::randomize`, or alter process-global seed state.

- [ ] **Step 4: Apply hard constraints before automatic selection**

Build mandatory participants from device constraints and owner-pinned pairs.
Compute exact counts or flexible minimum `max(1, AT_LEAST, pinned_count)`.
AUTO_MINIMUM adds preferred-owner candidates only when the minimum device count
does not increase, then effective-order candidates until:

```systemverilog
exact_sum + flexible_capacity_sum >= request.total_qpairs
```

Reject minimum sums beyond total. Keep exact targets fixed and water-level
only flexible targets.

- [ ] **Step 5: Expand explicit pair owners**

Place owner-pinned indices first, then preferred indices with a selected-owner
slot, then automatic/fallback indices in ascending request-pair order. Emit
exactly `total_qpairs` records and copy local/global modes and requested values.

- [ ] **Step 6: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_placement_test
```

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_placement_normalizer.sv \
  dpu_common/src/dpu_normalized_placement_plan.sv \
  dpu_common/tests/dpu_placement_test.sv
git commit -m "feat: add constrained seeded VIO placement"
```

---

### Task 5: Immutable Resource Snapshot and Typed Queries

**Files:**
- Create: `dpu_common/src/dpu_resource_snapshot.sv`
- Create: `dpu_common/tests/dpu_resource_resolver_test.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Produces `dpu_resource_snapshot::set_normalized_plan()`, `add_vio_binding()`, `freeze(device_snapshot, diagnostic)`, and `is_frozen()`.
- Produces canonical binding lists, request-index lookup, service/local lookup, global reverse lookup, participant listing, and defensive metadata/reservation access.
- Exact builder signatures are
  `set_normalized_plan(input dpu_normalized_placement_plan plan,
  output dpu_placement_diagnostic diagnostic)`,
  `add_vio_binding(input dpu_vio_qpair_binding_t binding,
  output dpu_placement_diagnostic diagnostic)`, and
  `freeze(input dpu_device_snapshot device_snapshot,
  output dpu_placement_diagnostic diagnostic)`. Builder calls reject a frozen
  snapshot and all query methods return copies.

- [ ] **Step 1: Register a failing resource-snapshot test**

Add `dpu_resource_resolver_test` after `dpu_placement_test` in both manifests
and exact-once validation. Build a frozen device snapshot with one VIO service:

```systemverilog
binding.request_id = 3;
binding.request_pair_index = 0;
binding.service_key = service_key;
binding.local_pair_id = 17;
binding.rx_local_virtqueue_id = 34;
binding.tx_local_virtqueue_id = 35;
binding.global_qpair_id = 91;
if (!resource_snapshot.add_vio_binding(binding, diagnostic) ||
    !resource_snapshot.freeze(device_snapshot, diagnostic))
  `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
if (!resource_snapshot.get_vio_binding_by_global(91, observed) ||
    (observed.local_pair_id != 17))
  `uvm_fatal("RESOURCE_SNAPSHOT", "global reverse lookup disagrees")
```

Mutate returned metadata and queues and verify a second query is unchanged.
Require add-after-freeze to fail.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
```

Expected: compile failure naming undefined `dpu_resource_snapshot`.

- [ ] **Step 3: Implement guarded snapshot construction**

Index each binding by:

```systemverilog
request_key = $sformatf("%0d:%0d", request_id, request_pair_index);
service_local_key = {dpu_service_key_name(service_key),
                     $sformatf(":%0d", local_pair_id)};
global_key = $sformatf("%0d", global_qpair_id);
```

Reject duplicate request, service/local, or global keys immediately. Freeze
requires a frozen device snapshot and verifies every service exists and is
VIO-net, local/derived/global IDs fit the effective profile, every participant
has a binding, and request counts match totals. Canonical order is
`{request_id,request_pair_index}`.

- [ ] **Step 4: Implement defensive read APIs**

```systemverilog
function void list_vio_bindings(ref dpu_vio_qpair_binding_t bindings[$]);
function bit get_vio_binding(input int unsigned request_id,
  input int unsigned request_pair_index,
  output dpu_vio_qpair_binding_t binding);
function bit get_vio_binding_by_service_local(
  input dpu_service_key_t service_key, input int unsigned local_pair_id,
  output dpu_vio_qpair_binding_t binding);
function bit get_vio_binding_by_global(
  input int unsigned global_qpair_id,
  output dpu_vio_qpair_binding_t binding);
function void list_vio_bindings_for_service(
  input dpu_service_key_t service_key,
  ref dpu_vio_qpair_binding_t bindings[$]);
function void list_vio_participants(
  ref dpu_vio_participant_target_t participants[$]);
function bit get_normalized_request(input int unsigned request_id,
  output dpu_normalized_vio_request request);
function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
function void list_reserved_global_qpair_ranges(
  ref dpu_global_id_range_t ranges[$]);
function void list_resource_profiles(
  ref dpu_resource_pool_config_t profiles[$]);
function bit references_device_snapshot(input dpu_device_snapshot snapshot);
```

Every list method clears output first. Bindings preserve
`{request_id,request_pair_index}` order, participants preserve request/effective
participant order, reservation IDs/ranges are ascending canonical unions, and
normalized requests are defensive copies carrying policy/order/seed and both
candidate orders. `freeze()` stores the exact frozen device-snapshot handle;
`references_device_snapshot()` returns true only for that same non-null handle.

- [ ] **Step 5: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_resource_snapshot.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_resource_resolver_test.sv \
  filelists/tests.f scripts/test_manifest.sh
git commit -m "feat: add immutable DPU resource snapshot"
```

---

### Task 6: Local/Global Qpair ID Resolver and Reservations

**Files:**
- Create: `dpu_common/src/dpu_resource_resolver.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_resource_resolver_test.sv`

**Interfaces:**
- Produces
  `function bit dpu_resource_resolver::resolve(input dpu_device_snapshot device_snapshot, input dpu_normalized_placement_plan normalized_plan, output dpu_resource_snapshot resource_snapshot, output dpu_placement_diagnostic diagnostic)`.
- Consumes explicit pair owners and local/global intents.
- Produces one frozen resource snapshot or `null` on failure.

- [ ] **Step 1: Add failing ID-allocation tests**

Use four pairs on one service and reserve global IDs `1..2`:

```text
pair 0: local PINNED 3, global PINNED 7
pair 1: local PREFERRED 3, global PREFERRED 7
pair 2: local AUTO, global AUTO
pair 3: local AUTO, global AUTO
```

Require local IDs `3,0,1,2` and global IDs `7,0,3,4`, plus correct derived
RX/TX local IDs. Add a second service proving local-ID reuse across devices and
global uniqueness. Add failures for duplicate pinned local/global IDs, pinned
reserved ID, local 32, global 2048, malformed reservations, and aggregate
demand beyond unreserved capacity. Malformed-reservation cases include
individual ID 2048, reversed range `9..8`, and range endpoint 2048. Assert
diagnostic code/context.
Author ID 2 once as an individual reservation and again inside the `1..2`
range to prove valid overlap canonicalizes instead of failing.

Require `DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE` for local 32,
`DPU_PLACE_ERR_LOCAL_QID_CONFLICT` for duplicate local pins,
`DPU_PLACE_ERR_INVALID_RESERVATION` for each malformed reservation,
`DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE` for global 2048,
`DPU_PLACE_ERR_GLOBAL_QID_RESERVED` for a pinned reserved ID,
`DPU_PLACE_ERR_GLOBAL_QID_CONFLICT` for duplicate global pins, and
`DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED` for aggregate exhaustion.
Range/configuration errors carry no pair context; pair-specific failures carry
request and pair.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
```

- [ ] **Step 3: Normalize reservations and run global pinned pass**

Validate each individual ID and each inclusive range against `0..2047`, copy
individual IDs into one interval list as `[id,id]`, sort all intervals by
`first_id`, merge overlapping or adjacent intervals into a canonical union, and
set a 2048-entry reservation bitmap. Across requests sorted by ID, reserve
every pinned global ID before preferred/automatic work. Any reserved,
colliding, or out-of-range pin aborts with request/pair context and a null
output snapshot.

- [ ] **Step 4: Implement local passes per service**

Process local pinned, then local preferred, then preferred fallbacks/AUTO in
pair order. Select the lowest free value below effective device capacity:

```systemverilog
binding.local_pair_id = local_pair_id;
binding.rx_local_virtqueue_id = 2 * local_pair_id;
binding.tx_local_virtqueue_id = 2 * local_pair_id + 1;
```

- [ ] **Step 5: Implement preferred/automatic global passes and freeze**

Try preferred globals after all pins. Failed preferences join AUTO items in
canonical request/pair order. Allocate the lowest ID that is neither reserved
nor occupied, add every binding to a candidate, and freeze against the exact
device snapshot. Clear output on all failures.

- [ ] **Step 6: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
run_remote_test dpu_placement_test
```

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_resource_resolver.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_resource_resolver_test.sv
git commit -m "feat: resolve VIO local and global qpair IDs"
```

---

### Task 7: End-to-End Coordinator and Multi-Request Atomicity

**Files:**
- Create: `dpu_common/src/dpu_configuration_resolver.sv`
- Modify: `dpu_common/src/dpu_resource_pkg.sv`
- Modify: `dpu_common/tests/dpu_resource_resolver_test.sv`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv`

**Interfaces:**
- Produces
  `function bit dpu_configuration_resolver::resolve(input dpu_device_cfg device_cfg, input dpu_resource_placement_cfg placement_cfg, output dpu_device_snapshot device_snapshot, output dpu_resource_snapshot resource_snapshot, output dpu_placement_diagnostic diagnostic)`.
- Calls normalizer, existing device resolver, and resource resolver in order.
- Returns two frozen snapshots only on complete success.

- [ ] **Step 1: Add failing end-to-end and atomicity tests**

Author request IDs 20 then 10, each fixed to a different eligible device, and
require request 10's AUTO global ID to be lower. Select one VF template and
require its BDF/BAR/service only in the output snapshot.

Then pin two pairs to one global ID:

```systemverilog
failed_device_snapshot = prior_device_snapshot;
failed_resource_snapshot = prior_resource_snapshot;
if (coordinator.resolve(bad_device_cfg, bad_placement,
                        failed_device_snapshot, failed_resource_snapshot,
                        diagnostic))
  `uvm_fatal("CONFIG_RESOLVER", "conflicting configuration resolved")
if ((failed_device_snapshot != null) || (failed_resource_snapshot != null))
  `uvm_fatal("CONFIG_RESOLVER", "failure leaked candidate snapshots")
```

Verify source objects are unchanged and separately held prior snapshots remain
frozen/queryable.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
```

- [ ] **Step 3: Implement candidate-only orchestration**

```systemverilog
device_snapshot = null;
resource_snapshot = null;
diagnostic.clear();
if (!normalizer.normalize(device_cfg, placement_cfg,
    normalized_cfg, normalized_plan, diagnostic)) return 0;
if (!device_resolver.resolve(normalized_cfg, candidate_device, why)) begin
  diagnostic.set_device_resolution_failure(why);
  return 0;
end
if (!resource_resolver.resolve(candidate_device, normalized_plan,
    candidate_resource, diagnostic)) return 0;
device_snapshot = candidate_device;
resource_snapshot = candidate_resource;
return 1;
```

Map base device-resolver failures to a stable stage/code while preserving its
detail string. Never mutate caller-owned snapshots.

- [ ] **Step 4: Add cross-snapshot negative probes**

Corrupt/delete service ownership before resource freeze and require
`DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH`. Require every participant to have at least one
binding and exact request totals.

- [ ] **Step 5: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_resource_resolver_test
run_remote_test dpu_device_resolver_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_configuration_resolver.sv \
  dpu_common/src/dpu_resource_pkg.sv \
  dpu_common/tests/dpu_resource_resolver_test.sv \
  dpu_common/tests/dpu_device_resolver_test.sv
git commit -m "feat: resolve device and resource snapshots atomically"
```

---

### Task 8: Snapshot-Importing Resource Manager

**Files:**
- Modify: `dpu_common/src/dpu_resource_manager.sv:1-605`
- Modify: `dpu_common/tests/dpu_resource_manager_test.sv:1-549`
- Modify: `dpu_common/tests/dpu_resource_resolver_test.sv`

**Interfaces:**
- Produces
  `function bit configure_from_snapshots(input dpu_resource_registry_authority authority, input dpu_device_snapshot device_snapshot, input dpu_resource_snapshot resource_snapshot, output string why)`.
- Produces
  `function bit is_seeded_from_snapshots(input dpu_device_snapshot device_snapshot, input dpu_resource_snapshot resource_snapshot)` and service-keyed `local_pair_to_global_qpair()`.
- Imports VIO bindings as frozen `DPU_RESOURCE_OWNER_SERVICE` leases.
- Keeps old singular-snapshot and mutation methods compile-visible only until
  Task 11; the new path never calls them.

- [ ] **Step 1: Rewrite manager tests around immutable import**

Replace incremental capacity/freeze/release assertions with a coordinator
result containing sparse locals and reserved globals:

```systemverilog
authority = manager.claim_registry_authority();
if (!manager.configure_from_snapshots(
    authority, device_snapshot, resource_snapshot, why))
  `uvm_fatal("DPU_RESOURCE", {"snapshot import failed: ", why})
if (!manager.is_seeded_from_snapshots(device_snapshot, resource_snapshot))
  `uvm_fatal("DPU_RESOURCE", "manager lost snapshot identity")
if (!manager.local_pair_to_global_qpair(
    service_key, qpair_class_id, 17, global_id) ||
    (global_id != 91))
  `uvm_fatal("DPU_RESOURCE", "manager query disagrees with snapshot")
```

Require second configure, wrong authority, unfrozen inputs, profile expansion,
and mismatched device/resource snapshots to fail without partial state. Retain
DUT-capability and 1024-function coverage using a resolved device snapshot.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_resource_manager_test
```

- [ ] **Step 3: Import profiles and leases into a candidate manager**

```systemverilog
resource_snapshot.list_resource_profiles(profiles);
if (!resource_snapshot.is_frozen() ||
    !resource_snapshot.references_device_snapshot(device_snapshot)) begin
  why = "resource snapshot is not frozen against the supplied device snapshot";
  return 0;
end
lease.owner.kind = DPU_RESOURCE_OWNER_SERVICE;
lease.owner.function_key = binding.service_key.function_key;
lease.owner.service_key = binding.service_key;
lease.local_id = binding.local_pair_id;
lease.class_id = qpair_class_id;
lease.global_id = binding.global_qpair_id;
lease.frozen = 1;
```

Register the copied profiles in a fresh candidate manager, then check exact
service existence plus global, per-service, per-function, and class counts.
Copy candidate associative arrays and both configured snapshot handles into
`this` only after every profile and binding has passed; any failure leaves the
receiver unconfigured.

- [ ] **Step 4: Add query-only service indexes**

```systemverilog
function bit local_pair_to_global_qpair(input dpu_service_key_t service_key,
  input dpu_resource_class_id_t class_id, input int unsigned local_pair_id,
  output int unsigned global_qpair_id);
function void list_service_leases(input dpu_service_key_t service_key,
  ref dpu_resource_lease_t leases[$]);
```

Return copies in ascending local ID order.

- [ ] **Step 5: Run and verify GREEN**

```bash
stage_remote
run_remote_test dpu_resource_manager_test
run_remote_test dpu_resource_resolver_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_resource_manager.sv \
  dpu_common/tests/dpu_resource_manager_test.sv \
  dpu_common/tests/dpu_resource_resolver_test.sv
git commit -m "refactor: import immutable VIO resource leases"
```

---

### Task 9: Device-Environment Dual-Snapshot Publication

**Files:**
- Modify: `dpu_common/src/dpu_device_env.sv:1-150`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv:55-1400`
- Modify: `dpu_common/tests/dpu_resource_resolver_test.sv`

**Interfaces:**
- `dpu_device_env_config` gains non-null `placement_cfg` and loses sibling `resource_profiles` at the hard cut.
- Produces
  `function dpu_resource_snapshot dpu_device_env::get_resource_snapshot()`.
- Publishes device snapshot, resource snapshot, and manager only after all candidates succeed.

- [ ] **Step 1: Add failing publication assertions**

```systemverilog
if (!uvm_config_db#(dpu_resource_snapshot)::get(
    this, "", "dpu_resource_snapshot", resource_snapshot) ||
    (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
    (resource_snapshot != owner.get_resource_snapshot()))
  `uvm_fatal("DEVICE_ENV_TEST", "child did not receive exact resource snapshot")
if (!manager.is_seeded_from_snapshots(snapshot, resource_snapshot))
  `uvm_fatal("DEVICE_ENV_TEST", "manager was not seeded from published pair")
```

Build the environment with a placement request instead of a predeclared VIO
service and require service ownership and qpair binding to agree.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test dpu_device_resolver_test
```

- [ ] **Step 3: Resolve all candidates before assigning environment state**

Create `placement_cfg` in `dpu_device_env_config.new()`. Build local
device/resource candidates through `dpu_configuration_resolver`, then build a
candidate manager with `configure_from_snapshots()`. Assign protected fields
only after all succeed.

For this intermediate task only, retain a no-request branch for shared-filelist
callers not yet migrated. Mark it with exactly
`TEMPORARY_PLACEMENT_MIGRATION_PATH` so Task 11 can prove deletion.

- [ ] **Step 4: Publish after successful assignment**

```systemverilog
uvm_config_db#(dpu_device_snapshot)::set(
  this, "*", "dpu_device_snapshot", snapshot);
uvm_config_db#(dpu_resource_snapshot)::set(
  this, "*", "dpu_resource_snapshot", resource_snapshot);
uvm_config_db#(dpu_resource_manager)::set(
  this, "*", "dpu_resource_manager", resource_manager);
```

The parent build phase completes before child build phases, so children cannot
observe the pair between assignments.

- [ ] **Step 5: Run focused integration tests and verify GREEN**

```bash
stage_remote
run_remote_test dpu_device_resolver_test
run_remote_test dpu_resource_resolver_test
run_remote_test dpu_resource_manager_test
```

- [ ] **Step 6: Commit**

```bash
git add dpu_common/src/dpu_device_env.sv \
  dpu_common/tests/dpu_device_resolver_test.sv \
  dpu_common/tests/dpu_resource_resolver_test.sv
git commit -m "feat: publish device and resource snapshots together"
```

---

### Task 10: VIO Read-Only Resource-Snapshot Consumer Path

**Files:**
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv:1-262`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv:1-572`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_instance.sv:1-38`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_instance.sv:35-260`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_manager.sv:290-455`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv:35-260`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv:1-230`
- Modify: `virtio_net_vip/tests/virtio_fabric_resource_test.sv`
- Modify: `virtio_net_vip/tests/virtio_monitor_routing_test.sv`

**Interfaces:**
- Produces
  `function bit virtio_resource_client::bind_to_service(input dpu_device_snapshot device_snapshot, input dpu_resource_snapshot resource_snapshot, input dpu_service_key_t service_key, output string why)`.
- Changes `virtio_function_instance::configure_from_service()` to
  `(device_snapshot, resource_snapshot, service_key, manager, pcie_ctx=null)`
  and `virtio_pf_instance::configure_services()` to
  `(parent_pf_key, device_snapshot, resource_snapshot, service_keys, manager,
  why)`; VF wrappers forward the same two snapshots and service key.
- Old signatures remain compile-visible only until Task 11.

- [ ] **Step 1: Add failing immutable-mapping assertions**

Require bindings immediately after function configuration and unchanged across
capability discovery, FLR, and reinit. Use sparse local pair IDs `{0,3,17}`
and require local qid 6 to map pair 3 RX, proving the view did not synthesize a
control queue at `2*qpair_count`:

```systemverilog
if (!function_instance.resource_client.local_qid_to_global_qid(
    2 * expected_local_pair, observed_rx) ||
    (observed_rx != 2 * expected_global_pair))
  `uvm_fatal("FABRIC_RESOURCE", "RX mapping did not come from snapshot")
if (!function_instance.resource_client.local_qid_to_global_qid(6, observed_rx) ||
    (observed_rx != 2 * global_pair_for_local_3))
  `uvm_fatal("FABRIC_RESOURCE", "sparse pair 3 was replaced by a derived control queue")
function_instance.on_flr();
if (!function_instance.resource_client.local_qid_to_global_qid(
    2 * expected_local_pair, observed_after_flr) ||
    (observed_after_flr != observed_rx))
  `uvm_fatal("FABRIC_RESOURCE", "FLR mutated immutable placement")
```

Delete focused expectations that FLR/shutdown release global assignments or
make them available to another function. Keep runtime queue/dataplane cleanup.

- [ ] **Step 2: Run and verify RED**

```bash
stage_remote
run_remote_test virtio_fabric_resource_test
```

- [ ] **Step 3: Import snapshot mappings in the resource client**

Bind once to the exact snapshots/service, verify ownership and nonempty
bindings, and import ascending local pairs:

```systemverilog
resource_snapshot.list_vio_bindings_for_service(service_key, bindings);
foreach (bindings[index]) begin
  mapping.local_pair = bindings[index].local_pair_id;
  mapping.rx_global_qid = 2 * bindings[index].global_qpair_id;
  mapping.tx_global_qid = 2 * bindings[index].global_qpair_id + 1;
  qpair_mappings.push_back(mapping);
end
```

Replace `mark_device_ready()` with `mark_runtime_ready()`, a local one-way
client transition that never modifies placement. The new path exposes no
reserve/release operation and `has_pending_qpair_cleanup()` is unnecessary.
The client stores the exact two snapshot handles, service key, imported mapping
queue, and runtime-ready bit; it stores no manager, resource class ID, or lease
queue on the new path.

- [ ] **Step 4: Thread the resource snapshot through VIO topology**

Retrieve `dpu_resource_snapshot` in `virtio_net_env`, pass it through
`virtio_pf_instance::configure_services()` to function/VF configuration, and
verify every VIO service has bindings. Remove lease-release calls from FLR and
shutdown on the new path; those operations reset runtime state only.

- [ ] **Step 5: Keep the VF resource pool a pure view**

Change `virtio_local_queue_mapping_t` ownership from `function_key` to
`service_key`. Replace positional/function-key APIs with:

```systemverilog
function bit import_service_bindings(
  input dpu_service_key_t service_key,
  input dpu_resource_snapshot resource_snapshot,
  output string why);
function bit local_to_global_for_service(
  input dpu_service_key_t service_key,
  input int unsigned local_qid,
  output int unsigned global_qid);
function bit global_to_service_local(
  input int unsigned global_qid,
  output dpu_service_key_t service_key,
  output int unsigned local_qid);
function string get_queue_name(
  input dpu_service_key_t service_key,
  input int unsigned local_qid);
```

`import_service_bindings()` creates exactly the RX/TX entries named by each
snapshot binding (`2*local_pair_id` and `2*local_pair_id+1`) and copies their
derived global queue IDs. It never loops over `0..qpair_count-1`, chooses or
increments an ID, reconstructs host0/pf0, or synthesizes a control queue at
`2*qpair_count`; control/Admin-VQ identity is outside this qpair snapshot.

Remove the `resource_pool.register_vfs()` call from
`virtio_pf_manager::enable_sriov()` and import each configured service from the
resource snapshot in `virtio_pf_instance::configure_services()`. FLR,
disable-SR-IOV, and shutdown must not unregister immutable mappings; they reset
runtime queue/dataplane state only.

- [ ] **Step 6: Run focused tests and verify GREEN**

```bash
stage_remote
run_remote_test virtio_fabric_resource_test
run_remote_test virtio_monitor_routing_test
run_remote_test dpu_resource_resolver_test
```

- [ ] **Step 7: Commit**

```bash
git add virtio_net_vip/src/sriov/virtio_resource_client.sv \
  virtio_net_vip/src/sriov/virtio_function_instance.sv \
  virtio_net_vip/src/sriov/virtio_vf_instance.sv \
  virtio_net_vip/src/sriov/virtio_pf_instance.sv \
  virtio_net_vip/src/sriov/virtio_pf_manager.sv \
  virtio_net_vip/src/env/virtio_net_env.sv \
  virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv \
  virtio_net_vip/tests/virtio_fabric_resource_test.sv \
  virtio_net_vip/tests/virtio_monitor_routing_test.sv
git commit -m "refactor: consume frozen VIO qpair bindings"
```

---

### Task 11: Migrate Fixtures and Hard-Cut Incremental VIO Leasing

**Files:**
- Modify: `virtio_net_vip/tests/virtio_test_device_builder.sv:1-205`
- Modify: `dpu_common/tests/dpu_device_bootstrap_plan_test.sv`
- Modify: `dpu_common/tests/dpu_device_resolver_test.sv`
- Modify: `dpu_common/tests/dpu_resource_manager_test.sv`
- Modify: `virtio_net_vip/tests/virtio_dut_caps_test.sv`
- Modify: `virtio_net_vip/tests/virtio_fabric_resource_test.sv`
- Modify: `virtio_net_vip/tests/virtio_monitor_routing_test.sv`
- Modify: `dpu_common/src/dpu_device_env.sv`
- Modify: `dpu_common/src/dpu_resource_manager.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_resource_client.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_function_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_instance.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_pf_manager.sv`
- Modify: `virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`

**Interfaces:**
- Produces the final single public path: device inventory/eligibility plus `dpu_resource_placement_cfg`.
- Deletes dynamic `virtio.qpair` acquire/release/freeze/restore and every temporary branch.
- Keeps read-only manager APIs `claim_registry_authority()`,
  `configure_from_snapshots()`, `snapshot_dut_caps()`,
  `lookup_resource_class()`, `contains_function()`, `is_snapshot_seeded()`,
  `is_seeded_from_snapshots()`, service-keyed
  `local_pair_to_global_qpair()`, and
  `list_service_leases()`. Deletes singular-snapshot configuration/identity
  APIs and the function-keyed `local_to_global()` method.

- [ ] **Step 1: Inventory legacy call sites**

```bash
rg -n 'add_vio_service|services\.push_back|resource_profiles|configure_from_snapshot\b|is_seeded_from_snapshot\b|bind_to_device|acquire_leases|release_leases|mark_function_device_ready|mark_device_ready|freeze_function|restore_function|reserve_qpairs|release_qpairs|freeze_qpairs|restore_qpairs|has_pending_qpair_cleanup|TEMPORARY_PLACEMENT_MIGRATION_PATH' \
  dpu_common virtio_net_vip --glob '*.sv'
```

Classify every hit as production API, direct device-resolver coverage (which
may still test generic service snapshots), or an environment fixture that must
migrate. Placement-enabled fixtures may not predeclare VIO services.

- [ ] **Step 2: Add builder eligibility and placement APIs**

```systemverilog
function dpu_service_key_t allow_vio_service(
  input dpu_function_cfg function_cfg);
  dpu_service_key_t key;
  if (!dpu_service_kind_is_eligible(
      function_cfg.eligible_service_kinds, DPU_SERVICE_VIO_NET))
    function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
  key.function_key = function_cfg.key;
  key.service_kind = DPU_SERVICE_VIO_NET;
  key.service_instance_id = 0;
  return key;
endfunction

function dpu_vio_placement_request add_fixed_vio_request(
  input int unsigned request_id,
  input dpu_function_key_t devices[$],
  input int unsigned total_qpairs);
  dpu_vio_placement_request request;
  request = dpu_vio_placement_request::type_id::create(
    $sformatf("vio_request_%0d", request_id));
  request.request_id = request_id;
  request.service_instance_id = 0;
  request.total_qpairs = total_qpairs;
  request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
  request.device_policy = DPU_VIO_DEVICE_FIXED;
  request.ordering = DPU_PLACEMENT_CANONICAL;
  request.fixed_devices = devices;
  placement_cfg.vio_requests.push_back(request);
  return request;
endfunction
```

The builder constructor creates `placement_cfg`, installs exactly one
real-DUT `virtio.qpair` profile there (`capacity=2048`,
`max_per_function=32`), and `make_env_config()` deep-copies both `device_cfg`
and `placement_cfg`. Delete `add_vio_service()`; source functions never receive
an active VIO service declaration.

- [ ] **Step 3: Migrate maintained fixtures to explicit demand**

Apply this exact migration map:

- `dpu_device_bootstrap_plan_test.sv`: give its non-VIO environment an empty
  placement request list and move its existing profile into `placement_cfg`;
  bootstrap/BAR expectations stay unchanged.
- `dpu_device_resolver_test.sv`: keep direct base-resolver service-validation
  tests unchanged, but convert both `dpu_device_env` fixtures to eligibility plus
  fixed requests; replace singular manager seeding tests with coordinator
  output and `configure_from_snapshots()` atomicity/defensive-profile checks.
- `dpu_resource_manager_test.sv`: retain capability, 1024-function, class, and
  query coverage through coordinator-built snapshots; delete dynamic
  ready/acquire/release/freeze/restore expectations already superseded by the
  import tests from Task 8.
- `virtio_dut_caps_test.sv`: `make_device_env_fixture()` marks every selected
  PF/VF eligible and creates one fixed request whose total/EXACT constraints
  express the former per-function qpair count; rewrite local-limit cases as
  pinned/EXACT placement diagnostics and snapshot bindings, while retaining
  runtime MQ/dataplane capability checks.
- `virtio_fabric_resource_test.sv`: each topology builder marks the same
  functions eligible and creates one fixed request; reserve one pair per former
  `reserve_qpairs(0,1)` participant, use sparse pinned locals for sparse tests,
  and replace release/reuse assertions with FLR/reinit snapshot-stability
  assertions.
- `virtio_monitor_routing_test.sv`: build its PF/VF fixed request before the
  environment, replace the non-seeded-manager bind probe with null/unfrozen/
  mismatched snapshot bind probes, and pass the resource snapshot through every
  service-configuration probe.

For any fixture with N former one-pair participants, use one fixed request with
those N keys and `total_qpairs=N`. Capacity failures use profiles,
`EXACT`/`AT_LEAST`, pinned IDs, or intentionally invalid placement and assert a
specific diagnostic code/context. No test constructs a placement-owned VIO
lease directly.

- [ ] **Step 4: Delete temporary and mutation paths**

Remove the environment legacy branch and sibling `resource_profiles`; profiles
live in placement cfg. Remove `acquire_leases`, `release_leases`,
`mark_function_device_ready`, `freeze_function`, `restore_function`, and their
`activated`, `device_ready`, and `frozen` function-state flags from the manager.
Remove singular `configure_from_snapshot()` and
`is_seeded_from_snapshot()`, the function-keyed `local_to_global()` method,
and every test caller. From the resource client remove `bind_to_device()`,
`mark_device_ready()`, `reserve_qpairs()`, `release_qpairs()`,
`freeze_qpairs()`, `restore_qpairs()`, `has_pending_qpair_cleanup()`, manager
and lease handles, and old configure signatures. Replace the runtime-ready
call with `mark_runtime_ready()` and remove lifecycle lease cleanup. Delete the
resource-pool positional APIs `register_vf_queues()`, `register_vfs()`,
`unregister_vf()`, function-keyed lookup/import APIs, and any remaining
`unregister_all()` runtime call; only service-keyed immutable view methods
remain. Direct base-device-resolver tests may still declare generic services
outside the placement-enabled environment path.

- [ ] **Step 5: Prove the hard cut statically**

```bash
test "$(rg -n 'TEMPORARY_PLACEMENT_MIGRATION_PATH' dpu_common virtio_net_vip --glob '*.sv' | wc -l)" -eq 0
test "$(rg -n 'configure_from_snapshot\b|is_seeded_from_snapshot\b|acquire_leases|release_leases|mark_function_device_ready|freeze_function|restore_function' dpu_common virtio_net_vip --glob '*.sv' | wc -l)" -eq 0
test "$(rg -n 'bind_to_device|mark_device_ready|reserve_qpairs|release_qpairs|freeze_qpairs|restore_qpairs|has_pending_qpair_cleanup' dpu_common virtio_net_vip --glob '*.sv' | wc -l)" -eq 0
test "$(rg -n 'resource_profiles' dpu_common/src/dpu_device_env.sv | wc -l)" -eq 0
test "$(rg -n '^\s*bit\s+(activated|device_ready|frozen);' dpu_common/src/dpu_resource_manager.sv | wc -l)" -eq 0
test "$(rg -n 'function\s+bit\s+local_to_global\s*\(' dpu_common/src/dpu_resource_manager.sv | wc -l)" -eq 0
test "$(rg -n 'register_vf_queues|register_vfs|unregister_vf|local_to_global_for_function|import_qpair_leases|unregister_function|unregister_all' virtio_net_vip/src --glob '*.sv' | wc -l)" -eq 0
```

- [ ] **Step 6: Run the migration-focused set**

```bash
stage_remote
run_remote_test dpu_placement_test
run_remote_test dpu_resource_resolver_test
run_remote_test dpu_resource_manager_test
run_remote_test dpu_device_resolver_test
run_remote_test dpu_device_bootstrap_plan_test
run_remote_test virtio_dut_caps_test
run_remote_test virtio_fabric_resource_test
run_remote_test virtio_monitor_routing_test
```

- [ ] **Step 7: Commit**

```bash
git add dpu_common/src/dpu_device_env.sv \
  dpu_common/src/dpu_resource_manager.sv \
  dpu_common/tests/dpu_device_bootstrap_plan_test.sv \
  dpu_common/tests/dpu_device_resolver_test.sv \
  dpu_common/tests/dpu_resource_manager_test.sv \
  virtio_net_vip/src/sriov/virtio_resource_client.sv \
  virtio_net_vip/src/sriov/virtio_function_instance.sv \
  virtio_net_vip/src/sriov/virtio_pf_instance.sv \
  virtio_net_vip/src/sriov/virtio_pf_manager.sv \
  virtio_net_vip/src/sriov/virtio_vf_instance.sv \
  virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv \
  virtio_net_vip/src/env/virtio_net_env.sv \
  virtio_net_vip/tests/virtio_test_device_builder.sv \
  virtio_net_vip/tests/virtio_dut_caps_test.sv \
  virtio_net_vip/tests/virtio_fabric_resource_test.sv \
  virtio_net_vip/tests/virtio_monitor_routing_test.sv
git commit -m "refactor: hard cut VIO qpair authoring to placement"
```

---

### Task 12: Documentation, Static Contracts, and Full Verification

**Files:**
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Documents final public authoring/query APIs only.
- Final maintained manifest contains 23 tests: the previous 21 plus both new focused tests.

- [ ] **Step 1: Add failing documentation/static contracts**

Extend `_validate_global_dpu_static_contracts()` using its existing awk/grep
style to require one README occurrence of each public entry point and forbid
stale incremental authoring text:

```bash
placement_decl_count="$(grep -c \
  'dpu_resource_placement_cfg placement_cfg;' "$manifest_root/README.md" || true)"
auto_policy_count="$(grep -c \
  'DPU_VIO_DEVICE_AUTO_MINIMUM' "$manifest_root/README.md" || true)"
resource_snapshot_count="$(grep -c \
  'dpu_resource_snapshot resource_snapshot;' \
  "$manifest_root/README.md" || true)"
if [[ "$placement_decl_count" -ne 1 || "$auto_policy_count" -ne 1 ||
      "$resource_snapshot_count" -ne 1 ]]; then
  echo "README placement example is missing or duplicated" >&2
  return 1
fi
if grep -Eiq 'acquire[_ -]leases|release[_ -]leases|reserve[_ -]qpairs|release[_ -]qpairs|freeze[_ -]qpairs|restore[_ -]qpairs' \
    "$manifest_root/README.md" \
    "$manifest_root/docs/virtio_net_vip_manual.md"; then
  echo "stale incremental qpair authoring documentation is forbidden" >&2
  return 1
fi
```

Run `./scripts/test_manifest.sh`; it must fail until docs are updated.

- [ ] **Step 2: Document final end-to-end authoring**

```systemverilog
dpu_resource_placement_cfg placement_cfg;
dpu_resource_snapshot resource_snapshot;
env_cfg = dpu_device_env_config::type_id::create("env_cfg");
placement_cfg = env_cfg.placement_cfg;
// Author hosts, explicit PFs, optional VF pools, BARs, and eligibility.
qpair_profile.name = "virtio.qpair";
qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
qpair_profile.capacity = 2048;
qpair_profile.max_per_function = 32;
placement_cfg.profiles.push_back(qpair_profile);
vio_request = dpu_vio_placement_request::type_id::create("vio_request");
vio_request.request_id = 0;
vio_request.service_instance_id = 0;
vio_request.total_qpairs = 100;
vio_request.candidate_kind = DPU_VIO_CANDIDATE_VF_ONLY;
vio_request.device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
vio_request.ordering = DPU_PLACEMENT_CANONICAL;
placement_cfg.vio_requests.push_back(vio_request);
```

Explain all policies/constraint modes, 32/2048 limits, three ID namespaces,
snapshot queries, FLR identity stability, and that notify/MSI-X/scheduler plan
builders are later consumers. Update both maintained-test lists in manifest
order by inserting `dpu_placement_test` and `dpu_resource_resolver_test` at the
same positions used by `VIRTIO_MAINTAINED_TESTS`.

- [ ] **Step 3: Run local non-VCS checks**

```bash
bash -n scripts/test_manifest.sh scripts/strict_regression.sh scripts/vcs.sh
./scripts/test_manifest.sh
git diff --check
```

Expected: all exit zero and diff check is silent.

- [ ] **Step 4: Run complete strict regression on 53**

```bash
stage_remote
ssh ubuntu@10.11.10.53 \
  "bash -lic 'cd $remote_stage && STRICT_TEST_TIMEOUT_SECONDS=180 ./scripts/strict_regression.sh'"
```

Expected final line: `STRICT_REGRESSION PASS tests=23`, exit zero, and no log
rejected by strict checking.

- [ ] **Step 5: Verify final ownership and scope**

```bash
rg -n 'DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE|DPU_MAX_VIO_GLOBAL_QPAIRS' dpu_common/src
rg -n 'dpu_resource_snapshot' dpu_common/src virtio_net_vip/src
rg -n 'configure_from_snapshot\b|is_seeded_from_snapshot\b|bind_to_device|acquire_leases|release_leases|mark_function_device_ready|mark_device_ready|freeze_function|restore_function|reserve_qpairs|release_qpairs|freeze_qpairs|restore_qpairs|has_pending_qpair_cleanup|TEMPORARY_PLACEMENT_MIGRATION_PATH' \
  dpu_common/src virtio_net_vip/src --glob '*.sv'
git status --short
```

Expected: canonical constants remain, snapshot consumers are present, the
legacy search is empty, and status contains only intended changes.

- [ ] **Step 6: Commit documentation and final verified fixes**

```bash
git add README.md docs/virtio_net_vip_manual.md scripts/test_manifest.sh
git commit -m "docs: document immutable VIO resource placement"
```

- [ ] **Step 7: Request final code review before integration**

Use `superpowers:requesting-code-review` on the complete feature diff. Resolve
only verified findings, rerun their focused tests, then rerun full strict
regression before `superpowers:finishing-a-development-branch`.
