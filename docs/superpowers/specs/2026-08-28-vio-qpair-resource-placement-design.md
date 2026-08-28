# VIO Qpair Resource Placement Design

**Date:** 2026-08-28
**Status:** Design approved in chat; written-spec review pending
**Scope:** Declarative VIO-net qpair demand, PF/VF placement, VF template
activation, deterministic local/global qpair allocation, and immutable resource
publication

## 1. Purpose

The global DPU device configuration already owns physical PCIe topology,
domain identity, BDF/BAR requests, AF selection, and service ownership. The
next layer must let a scenario state a total VIO-net qpair demand without
deriving topology from that demand or incrementally mutating shared resource
state.

This design adds a declarative placement pipeline that:

- selects eligible explicit PF/VF devices;
- activates VFs only from explicitly declared per-PF VF template pools;
- supports fully automatic, fully fixed, and partially constrained placement;
- enforces the real-DUT limit of 32 VIO qpairs per PF/VF and 2048 global
  qpairs;
- assigns arbitrary sparse device-local pair IDs and unique global qpair IDs;
- records every automatic or seeded-random decision in a frozen resource
  snapshot; and
- publishes device and resource state atomically.

MSI-X, notify, BDF-table register plans, ports, qsch/dsch, forwarding, RDMA,
VBLK, and real-DUT register execution are outside this subproject.

## 2. Terminology

This design avoids the ambiguous term "active device."

- A **device instance** is an explicit or materialized PF/VF in the normalized
  device configuration. It may own BDF/BAR resources without owning VIO
  qpairs.
- A **service-eligible device** may host a named service but does not yet own
  that service.
- A **VIO participant** is a device selected by a VIO placement request. It
  owns one VIO service key and at least one qpair.
- A **VF template** is a complete, inactive VF description in a parent PF's VF
  pool. It consumes no BDF/BAR or qpair resource until selected.

A device may have no service, or may later host VIO-net, RDMA, and VBLK
simultaneously. Only VIO participants are required to own VIO qpairs.

Three qpair identities remain distinct:

- `request_pair_index` identifies a pair within one placement request;
- `local_pair_id` identifies a pair within one VIO participant; and
- `global_qpair_id` identifies the pair in the DUT-global VIO qpair space.

For local pair `p`, the RX local virtqueue ID is `2*p`, and the TX local
virtqueue ID is `2*p + 1`. One RX/TX pair consumes one global qpair ID.

## 3. Fixed hardware and ownership invariants

- Host and PF inventory is always explicit. Queue demand never creates a host
  or PF.
- A VF can be materialized only from a template declared under its explicit
  parent PF. The resolver never invents a VF ID.
- A VIO participant owns between 1 and 32 qpairs, inclusive. A smaller
  scenario profile may narrow 32 but may never expand it.
- `local_pair_id` is in `0..31` and may be sparse.
- `global_qpair_id` is in `0..2047` and is unique across all VIO placement
  requests in one resolved configuration.
- The current real-DUT profile permits at most one VIO-net service instance on
  one PF/VF.
- Device, service, and resource identities are explicit in snapshots. No
  consumer may reconstruct them from array position or allocation order.

## 4. Chosen architecture

The implementation uses layered resolution and two immutable snapshots:

```text
global device cfg + VF pools + resource placement cfg
                         |
                         v
               placement normalizer
                    /             \
       normalized device cfg       normalized placement plan
                   |               |
                   v               |
          device resolver          |
                   |               |
                   v               v
          device snapshot ---> resource resolver
                   |               |
                   |               v
                   |       resource snapshot
                   |               |
                   +-------+-------+
                           |
                           v
                     atomic publish
```

The resource resolver runs after the device resolver because resource
bindings must reference service keys that exist in the frozen device
snapshot. Both resolvers work on candidates. The environment publishes
nothing until both snapshots are frozen and the resource manager has imported
the resolved leases.

This was selected over a single combined resolver and over a mutable,
manager-centric allocator. The layered design keeps PCIe identity independent
from VIO policy, keeps placement deterministic, and leaves a clean extension
point for RDMA and VBLK.

## 5. Component responsibilities

### 5.1 `dpu_device_cfg`

`dpu_device_cfg` remains the source of device facts: DUT capability, hosts,
PCIe domains, explicit functions, BDF/BAR requests, and AF selection. It gains
a `vf_pools[]` collection. Each `dpu_vf_pool_cfg` names one explicit parent PF
key and contains complete `dpu_vf_template_cfg` objects. A PF can own at most
one pool, and a pool is invalid unless its parent PF is explicit.

A VF template contains its VF ID, domain, BDF/BAR requests, and eligible
service kinds; its full function key is derived from the parent PF and VF ID.
Explicit function configuration gains the same eligibility declaration.
Service eligibility is separate from `dpu_function_cfg.services`: eligibility
means "may host," while a service declaration means "does host." A VF template
must not contain an active service declaration.

In the placement-enabled path, source device configuration must not predeclare
VIO-net services. The normalizer is the single owner that creates VIO service
declarations. Explicit PF/VF instances can still be selected through the same
eligibility model.

### 5.2 `dpu_resource_placement_cfg`

This is the authoring root for business-resource demand. It contains one or
more `dpu_vio_placement_request` objects and global VIO qpair reservations.
Future RDMA and VBLK request collections are parallel additions; they cannot
define host/PF topology.

### 5.3 `dpu_placement_normalizer`

The normalizer validates requests, builds candidate sets, selects VIO
participants, expands automatic and seeded choices into explicit target
counts, materializes selected VF templates, and adds VIO service declarations
to a copied device configuration. It does not assign BDF/BAR addresses or
local/global qpair IDs.

Its outputs are a normalized `dpu_device_cfg` and a normalized placement plan
that contains explicit participants, per-participant target counts, request
pair ownership decisions, effective ordering, and seed.

### 5.4 `dpu_device_resolver`

The existing device resolver consumes the normalized device configuration and
remains the only authority for BDF, BAR, AF, and device/service identity. It
produces a frozen `dpu_device_snapshot`.

### 5.5 `dpu_resource_resolver`

The resource resolver consumes the frozen device snapshot and normalized
placement plan. It assigns device-local and DUT-global qpair IDs, validates
cross-snapshot references, and produces a frozen `dpu_resource_snapshot`.

### 5.6 `dpu_resource_manager`

The resource manager imports the exact leases from the frozen resource
snapshot. It does not repeat participant selection or allocate placement-owned
VIO qpair IDs. Imported VIO qpair leases are frozen and query-only so manager
state cannot diverge from the published snapshot. Existing fixtures that
incrementally acquire `virtio.qpair` leases migrate to placement requests.

## 6. Placement request model

Each `dpu_vio_placement_request` contains:

- a stable, unique integral `request_id`;
- a VIO `service_instance_id`;
- `total_qpairs`, which must be nonzero;
- candidate kind `PF_ONLY`, `VF_ONLY`, or `PF_AND_VF`;
- device policy `AUTO_MINIMUM`, `FIXED`, or `ALL_ELIGIBLE`;
- ordering mode `CANONICAL` or `SEEDED_RANDOM`, plus the seed;
- host, PF, explicit-function, and VF-pool candidate filters;
- `fixed_devices[]`, used only by `FIXED`;
- per-device `EXACT` or `AT_LEAST` qpair constraints;
- per-qpair owner/local/global overrides.

Global ID reservations are owned once by `dpu_resource_placement_cfg`, not by
individual requests, because every request allocates from the same DUT-global
space. Reservations are expressed as individual IDs or inclusive ranges.
Valid overlapping reservations normalize to one canonical union; reversed or
out-of-range reservations are invalid.

`PF_AND_VF` has no implicit preference for PF or VF. Canonical or seeded order
is the only default selection order.

The current real-DUT profile requires `service_instance_id == 0`. The field
remains explicit so a future capability profile can widen the limit without
changing service identity.

The device policies mean:

- `AUTO_MINIMUM` retains all devices forced by hard constraints and adds the
  minimum number of eligible candidates required to satisfy capacity.
- `FIXED` uses exactly the caller-provided device-key list. It never selects an
  additional device. The list may name eligible explicit functions or declared
  VF templates.
- `ALL_ELIGIBLE` uses every eligible explicit device and every eligible VF
  template in the request's filtered candidate scope. Selected VF templates
  are materialized.

Every selected VIO participant must receive at least one qpair. Therefore
`FIXED` and `ALL_ELIGIBLE` fail when `total_qpairs` is smaller than the selected
device count.

## 7. Partial customization

A per-device constraint names a concrete function key and supplies:

- `EXACT N`: the participant owns exactly `N` qpairs and receives no automatic
  remainder; or
- `AT_LEAST N`: the participant owns at least `N` qpairs and may receive more
  up to its effective capacity.

Naming a device in either constraint makes it a mandatory participant. A
qpair whose owner is `PINNED` also makes its owner mandatory. A preferred
owner is best effort: under `AUTO_MINIMUM` it is considered before ordinary
candidates when this does not increase the minimum participant count, but it
does not force an extra device.

Each qpair override names `request_pair_index` and independently controls:

- owner device: `AUTO`, `PINNED`, or `PREFERRED`;
- local pair ID: `AUTO`, `PINNED`, or `PREFERRED`; and
- global qpair ID: `AUTO`, `PINNED`, or `PREFERRED`.

`PINNED` failure is fatal. `PREFERRED` falls back to `AUTO` when the preferred
choice is unavailable. Unmentioned pairs and fields are automatic. Constraint
counts must be in `1..effective_device_capacity`; duplicate constraints or
duplicate overrides for one `request_pair_index` are invalid.

## 8. Deterministic placement algorithm

### 8.1 Candidate construction

For each request, the normalizer collects matching explicit functions and VF
templates, verifies parent PF and service eligibility, removes functions
already consumed by another VIO request, and sorts by:

```text
{host_id, pf_id, function_kind, vf_id}
```

`SEEDED_RANDOM` applies a resolver-local Fisher-Yates shuffle to that canonical
collection using a documented 32-bit xorshift generator. Seed zero is mapped
to the fixed nonzero state `32'h6d2b79f5`. Resolution never consumes global
SystemVerilog random state. The same configuration and seed must produce the
same order and result. Requests themselves resolve in stable `request_id`
order.

### 8.2 Hard constraints and device selection

The normalizer first reserves mandatory devices and validates their fixed
counts. An `EXACT` count smaller than the number of owner-pinned pairs, an
ineligible pinned owner, or a count above effective capacity is fatal.

For `AUTO_MINIMUM`, candidates are added until:

```text
sum(EXACT counts) + sum(flexible participant capacities) >= total_qpairs
```

while the participants' required minimum counts still fit in `total_qpairs`.
Preferred owner devices are used before ordinary candidates when they fit the
same minimum device count. `FIXED` and `ALL_ELIGIBLE` use their already defined
sets without automatic additions.

### 8.3 Balanced target counts

`EXACT` targets remain fixed. Every flexible participant starts at the maximum
of:

- one qpair;
- its `AT_LEAST` count; and
- its owner-pinned pair count.

The normalizer assigns each remaining qpair to the flexible participant with
the lowest current target count, subject to capacity. Ties use effective
candidate order. This water-level rule honors large minimums without giving
already-heavy participants an artificial round-robin advantage.

Examples with a 32-qpair device limit:

- 100 qpairs on four ordinary participants produces `25/25/25/25`.
- 101 qpairs produces `26/25/25/25` in effective order.
- `EXACT 20`, `EXACT 4`, and 76 remaining qpairs require three flexible
  participants and produce `20/4/26/25/25`.

### 8.4 Pair-to-owner expansion

Within the calculated target counts, owner-pinned pair indices are placed
first. Owner-preferred indices are placed next when their selected owner still
has a target slot. Remaining indices fill remaining target slots in
`request_pair_index` and effective participant order. The normalized plan
records every resulting owner explicitly.

## 9. Local and global ID allocation

For each participant, local IDs resolve in this order:

1. reserve valid, noncolliding pinned IDs;
2. use a preferred ID when it remains free; and
3. give each automatic/fallback pair the lowest free ID in `0..31`.

Sparse results such as `{0, 3, 17}` are valid. Local pair IDs are unique only
within one VIO service/device.

Global IDs resolve across all requests in stable request and pair order:

1. mark every valid configured reservation unavailable;
2. reserve valid, unique pinned IDs;
3. use preferred IDs when they remain available; and
4. give each automatic/fallback pair the lowest free ID in `0..2047`.

Seeded ordering may affect participant and balancing tie choices, but never
changes the "lowest available" rule for an automatic global ID.

## 10. Immutable resource snapshot

Each final `dpu_vio_qpair_binding` records:

```text
request_id
request_pair_index
service_key
local_pair_id
rx_local_virtqueue_id
tx_local_virtqueue_id
global_qpair_id
```

The snapshot also records the effective device policy, ordering mode, seed,
canonical/effective candidate orders, selected participant list, target
counts, and global reservations. This is sufficient to reproduce and audit
all automatic decisions without rerunning random selection.

Before freeze, the snapshot accepts bindings only through guarded builder
methods. After freeze it exposes defensive-copy, read-only queries:

- list bindings in canonical `{request_id, request_pair_index}` order;
- lookup by `{request_id, request_pair_index}`;
- list or lookup by service key and local pair ID; and
- reverse lookup by global qpair ID.

The snapshot stores no BDF/BAR copies. Consumers join it to the frozen device
snapshot through `dpu_service_key_t`.

## 11. Multi-service extension contract

One function can own several service keys:

```text
{function, VIO_NET, 0}
{function, RDMA,    0}
{function, VBLK,    0}
```

Resource ownership therefore uses a tagged owner:

```text
owner_kind = FUNCTION | SERVICE
function_key
service_key
```

Function-owned resources include base PCIe identity such as BDF/BAR.
Service-owned resources include VIO qpairs and future RDMA/VBLK queues,
MSI-X, notify, ports, and scheduler bindings. The tagged form prevents two
services on one function from becoming indistinguishable. Capacity validation
can consequently enforce global, per-service, and per-function limits instead
of treating resource ownership and quota scope as the same concept. For the
current one-VIO-instance profile, the VIO per-service and per-function limits
both resolve to 32 qpairs.

Future service normalizers run in parallel conceptually, then a device
materialization union instantiates a selected VF once and merges its service
declarations. A shared arbitration stage allocates resources used across
services. This subproject implements only the VIO qpair normalizer/resolver;
it adds no empty RDMA/VBLK implementation.

## 12. Plan and execution boundary

Placement is a pure configuration decision and performs no DUT access:

```text
device snapshot + resource snapshot
                 |
                 v
       service plan builders
                 |
                 v
          dpu_reg_plan
                 |
                 v
      user-provided executor
```

Future notify, MSI-X, BDF-table, qsch/dsch, RDMA, and VBLK plan builders read
the two frozen snapshots and emit register plans. The executor receives only a
validated plan and does not branch on placement scenarios. Users remain free
to provide or extend a real-DUT executor.

## 13. Validation and diagnostics

Validation is layered:

1. **Input structure:** duplicate IDs/templates, missing parent PFs, malformed
   filters or reservations, empty fixed lists, and out-of-range pair indices.
2. **Placement:** missing candidates, fixed/constraint conflicts, zero-qpair
   participants, over-32 devices, and duplicate VIO service ownership.
3. **Resource uniqueness:** local/global collisions, reservations, range and
   capacity exhaustion, including aggregate demand beyond the unreserved
   portion of the 2048-entry global space.
4. **Cross-snapshot consistency:** every binding references a declared frozen
   service, every VIO participant owns at least one pair, and request totals
   exactly match final bindings.

A failed resolution returns a structured diagnostic containing:

```text
stage
error_code
request_id
function_key or service_key when relevant
request_pair_index when relevant
message
```

Stable codes include `NO_ELIGIBLE_DEVICE`, `DEVICE_CAPACITY_EXHAUSTED`,
`LOCAL_QID_CONFLICT`, `GLOBAL_QID_RESERVED`, `GLOBAL_QID_EXHAUSTED`, and
`SNAPSHOT_REFERENCE_MISMATCH`. The message supplies human-readable detail but
tests and callers can rely on the code and context fields.

## 14. Transaction and publication semantics

Resolution is all-or-nothing across every placement request in one environment
configuration:

- source objects remain read-only;
- VF materialization, service declarations, placement results, snapshots, and
  manager state are built as candidates;
- all device and resource snapshots are frozen and cross-checked before
  publication;
- manager import must also succeed before publication; and
- any failure discards all candidates and retains the previously published
  state.

At UVM build time, the environment publishes the fully resolved references
only after candidate construction succeeds. A future runtime replacement must
swap a single resolved-state handle containing both snapshots; it must not
publish them independently.

## 15. Test strategy

### 15.1 Placement tests

- 100/101 qpair balanced examples;
- all three device policies;
- PF-only, VF-only, and mixed candidate sets;
- canonical and seeded-random reproducibility;
- exact, at-least, pinned, preferred, and automatic combinations;
- partial per-device customization followed by automatic remainder; and
- insertion-order independence for canonical mode.

### 15.2 ID tests

- sparse local IDs and the 32-pair boundary;
- RX/TX local virtqueue derivation;
- pinned/preferred/automatic global IDs;
- reservations and the 2048-pair boundary; and
- local/global collision and exhaustion diagnostics.

### 15.3 VF and snapshot tests

- activation only from declared VF templates;
- explicit parent-PF enforcement;
- unselected templates consume no BDF/BAR;
- selected templates appear in the device snapshot exactly once;
- frozen, defensive-copy snapshot behavior; and
- agreement among all forward and reverse lookup APIs.

### 15.4 Transaction and integration tests

- multiple requests share one global allocation table;
- a failure in any request publishes no partial result;
- a previously published state remains unchanged after failure;
- manager import exactly matches resource-snapshot leases; and
- identical configuration and seed produce equivalent normalized output.

All focused tests and the complete strict regression run on `10.11.10.53` as
user `ubuntu` through `bash -lic`, so the host's VCS and license environment is
loaded.

## 16. Explicit non-goals

This subproject does not implement:

- notify, MSI-X interval/PBA, BDF-table, port, qsch, or dsch allocation or
  register programming;
- VIO dataplane traffic or forwarding policy;
- RDMA/VBLK resource resolution;
- a real-DUT production executor;
- `cosim_control`; or
- a compatibility translator for incremental VIO qpair lease authoring.

Those features must consume the immutable device/resource results defined
here instead of adding alternate topology or resource authorities.
