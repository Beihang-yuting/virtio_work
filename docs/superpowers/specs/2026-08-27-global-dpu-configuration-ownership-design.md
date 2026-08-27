# Global DPU Configuration Ownership Design

**Date:** 2026-08-27

**Status:** Design approved; written specification pending user review

**Umbrella design:** `2026-08-25-real-dut-service-configuration-design.md`

**Subproject:** 2, global DPU configuration ownership

## 1. Purpose

This subproject makes one global DPU configuration the sole authority for the
real DUT's PCIe topology. Host, PCIe domain, PF/VF identity, BDF placement, BAR
placement, administrator-function selection, DUT capabilities, and service
ownership no longer belong to the VIO environment.

The mutable authoring configuration is compiled into an immutable snapshot
before protocol environments or register-plan builders consume it. The
migration is a hard cut: the old VIO-owned topology and BDF derivation paths are
removed instead of being retained behind a compatibility translator.

The subproject preserves the generic register-plan and injected-executor
architecture. It adds the PCI BAR and AF-declaration bootstrap plan needed to
make the selected topology actionable, but it does not add a production
real-DUT executor or lower later BDF, MSI-X, notify, scheduler, forwarding,
VIO, RDMA, or VBLK tables.

## 2. Confirmed decisions

1. `dpu_device_cfg` is the only mutable authoring input for global topology
   and capability.
2. Successful resolution publishes an immutable `dpu_device_snapshot`.
   Consumers never read resolved state from the authoring object.
3. Hosts, PCIe domains, PFs, and VFs are explicit objects. Sparse PF and VF
   IDs are legal; count matrices do not generate topology.
4. Every function has the full key `{host_id,pf_id,kind,vf_id}` and explicitly
   selects a `{host_id,segment_id}` domain.
5. Every domain declares independent BDF ranges, reserved BDFs, and MMIO
   windows. BDF and BAR uniqueness is domain-qualified.
6. BDF and BAR requests support `AUTO` and `PINNED`. Pinned requests are
   placed first; automatic requests use deterministic stable ordering.
7. The real-DUT BAR profile maps BAR0/1 to device memory and AF registers,
   BAR2/3 to mailbox, and BAR4/5 to MSI-X.
8. A function can own VIO-net, RDMA, and VBLK simultaneously. A service key is
   `{function_key,service_kind,service_instance_id}`.
9. The current profile allows at most one VIO-net service instance and 32 VIO
   qpairs per PF or VF.
10. AF selection uses strict `SELECTED` semantics. PF0 on any declared host is
    eligible; PF1 and later PFs and every VF are ineligible.
11. If the selected PF0 finds an existing AF or loses arbitration, execution
    fails. It does not adopt the winner, clear the existing AF, or retry
    destructively.
12. `virtio_net_env_config` is keyed by service identity and retains only VIO
    driver, queue, traffic, and verification behavior.
13. This implementation stops at explicit PF/VF and service ownership.
    Demand-driven VF activation and total-qpair placement are a following
    subproject, with their extension contracts reserved here.

## 3. Scope

### 3.1 In scope

- global capability, host, domain, function, BDF, BAR, AF, and service types;
- deterministic domain-qualified BDF and BAR resolution;
- immutable snapshot construction and typed forward/reverse lookup;
- strict validation and transactional snapshot publication;
- top-level DPU device environment ownership;
- VIO migration to snapshot and service-key consumption;
- PCI BAR bootstrap and driver-aligned AF declaration plan construction;
- spy-executor verification of AF operations and dependencies;
- focused resolver tests and migration of the maintained regression suite.

### 3.2 Out of scope

- a production PCIe or real-DUT executor;
- automatic VF activation from total queue demand;
- random or balanced VIO qpair placement;
- local/global qpair, MSI-X vector, notify, port, or scheduler allocation;
- DUT-internal BDF, MSI-X, notify, QSCH/DSCH, forwarding, VTX/VRX, RDMA, or
  VBLK table lowering;
- implicit AF takeover, AF cleanup, or execution rollback;
- compatibility translation from removed VIO topology fields.

## 4. Real-driver evidence

AF behavior was checked against the real driver on the VCS host:

```text
host:       10.11.10.53
repository: /home/ubuntu/wn/icpu-kernel-driver
branch:     lance_net_mailbox
commit:     f2c9cd66b6e6b972055efe094b6277c5e362958d
```

The relevant definitions are:

```text
DPU_MEMORY_BAR                  0
DPU_MAILBOX_BAR                 2
DPU_AF_DECLARATION_ADDR         0x1010
DPU_AF_SETTING_MAGIC_NUM        0x5555AAAA
DPU_AF_HOST_ID_REG_ADDR         0x60040
INTF_PCMPL_CFG_AF_HOST_ID_ADDR  0x20040
INTF_AHID_HOST_ID_MASK          0x7
INTF_AHID_HOST_ID_VALID_MASK    0x8
```

`main.c` enables `af_mode` by default. A non-VF whose `pfvf_id` is zero can
attempt AF declaration, so PF0 on every host is a candidate. The driver reads
BAR0+0x1010, rejects an already-valid declaration, writes `0x5555AAAA`, reads
the hardware-selected host back, and rejects the probe if another host won.
The winner writes its host ID and valid bit to BAR0+0x60040.

Writing zero to BAR0+0x1010 does not release the declaration. Driver cleanup
instead clears BAR0+0x60040 and BAR0+0x20040. Normal configuration therefore
must not model an existing AF as forcibly preemptible.

The driver identifies BAR0 as device memory and BAR2 as mailbox. Both are
64-bit BARs, represented by pairs BAR0/1 and BAR2/3. The real-DUT profile uses
BAR4/5 as the MSI-X pair. This replaces the old `DPU_BAR_RESERVED` meaning for
BAR2.

## 5. Architecture and ownership

```text
scenario or custom authoring
          |
          v
    dpu_device_cfg
          |
          v
 dpu_device_resolver
  - validate structure
  - allocate BDFs
  - allocate BARs
  - validate AF
  - index services
          |
          v
dpu_device_snapshot (immutable)
          |
          +--> common PCI/AF plan builder
          +--> VIO-net plan builder
          +--> future RDMA plan builder
          +--> future VBLK plan builder
          |
          v
    dpu_reg_plan
          |
          v
dpu_config_orchestrator
          |
          v
 injected dpu_reg_executor
```

- `dpu_device_cfg` declares desired global state. It neither allocates
  resources nor writes hardware.
- `dpu_device_resolver` performs an all-or-nothing compilation in a private
  workspace.
- `dpu_device_snapshot` is the only resolved truth and exposes typed queries
  without mutable internal handles.
- `dpu_device_env` owns the global device lifecycle and is the parent
  configuration authority for protocol environments.
- plan builders consume snapshots and contribute generic operations and
  dependencies.
- `dpu_config_orchestrator` freezes, preflights, and dispatches a plan.
- executors translate operations into a transport. They do not allocate
  resources or branch on service type or scenario.

The existing `dpu_resource_manager` is no longer a topology, aperture, or BAR
authority. Its reusable generic lease mechanisms remain available for later
qpair, interrupt, and other shared-resource resolution; topology-specific
state and allocation move into the device resolver.

The top-level DPU environment resolves the snapshot before creating or binding
service-dependent components. A unit-level VIO environment may be instantiated
directly only when it receives an already-resolved snapshot and service-key
configuration.

## 6. Authoring model

```text
dpu_device_cfg
|-- dut_caps
|-- hosts[]
|   `-- pcie_domains[]
|       |-- bdf_ranges[]
|       |-- reserved_bdfs[]
|       `-- mmio_windows[]
|-- functions[]
|   |-- function_key
|   |-- domain_key
|   |-- bdf_request
|   |-- bar_requests[]
|   `-- services[]
`-- af_request
```

Array sizes are derived facts, not parallel count fields. A configuration may
declare host0 with PF0 and PF3, and PF3 with VF0 and VF7, without declaring
intermediate IDs.

### 6.1 Function and domain identity

```systemverilog
typedef struct {
    int unsigned        host_id;
    int unsigned        pf_id;
    dpu_function_kind_e kind;
    int unsigned        vf_id;
} dpu_function_key_t;

typedef struct {
    int unsigned host_id;
    int unsigned segment_id;
} dpu_pcie_domain_key_t;

typedef struct {
    dpu_pcie_domain_key_t domain;
    bit [15:0]            bdf;
} dpu_pcie_function_id_t;
```

A PF uses canonical `vf_id == 0`; `kind` distinguishes it from VF0. A VF is
valid only when the PF with the same host and PF ID exists. A function's domain
host must equal its function-key host. No global API accepts a bare PF ID, VF
ID, BDF, or BAR address.

### 6.2 Service identity

```systemverilog
typedef enum int unsigned {
    DPU_SERVICE_VIO_NET,
    DPU_SERVICE_RDMA,
    DPU_SERVICE_VBLK
} dpu_service_kind_e;

typedef struct {
    dpu_function_key_t function_key;
    dpu_service_kind_e service_kind;
    int unsigned       service_instance_id;
} dpu_service_key_t;
```

`service_instance_id` is local to one `{function_key,service_kind}` pair. It is
not a VF ID, qid, or interrupt vector. VIO-net instance zero and RDMA instance
zero can coexist on one function because their service kinds differ. The
current profile rejects more than one VIO-net instance on a function.

### 6.3 BDF requests

Every domain declares inclusive valid BDF ranges and reserved BDFs. A function
requests either `AUTO` or `PINNED {bdf}`. PINNED is exact. AUTO receives the
lowest numerically available valid BDF after reservations and all pinned
requests have been placed.

### 6.4 BAR requests and roles

Each function declares every required 64-bit BAR pair:

```text
role
even_bar_id
size
alignment
placement = AUTO | PINNED
pinned_base (PINNED only)
```

The initial real-DUT roles are:

```text
DPU_BAR_DEVICE_MEMORY  BAR0/1  function memory and AF register access
DPU_BAR_MAILBOX        BAR2/3  function mailbox access
DPU_BAR_MSIX           BAR4/5  MSI-X table/PBA aperture
```

The DUT capability profile defines legal roles, pairs, sizes, and alignments
for PFs and VFs. A service module never invents or relocates a function BAR.

### 6.5 AF request

The first version supports:

```text
mode      = SELECTED
requester = complete dpu_function_key_t
```

The requester must identify a declared PF0. A default scenario may select
host0/PF0, but PF0 on every declared host has equal eligibility.

## 7. Deterministic resolution

Resolution uses a private workspace and proceeds in this order:

1. Deep-copy the authoring configuration and capability profile.
2. Validate unique host/domain keys and valid ranges/windows.
3. Validate function keys, bounds, parent PFs, and domain references.
4. Validate service keys and profile-specific instance limits.
5. Validate the selected AF and PF0 eligibility.
6. Sort functions by `{host_id,pf_id,kind,vf_id}`.
7. Place PINNED BDF requests and reject reservations, duplicates, and values
   outside the domain's ranges.
8. Place AUTO BDF requests in sorted order using the lowest available BDF.
9. Validate and place all PINNED BAR requests.
10. Place AUTO BAR requests in stable `{domain,function,bar_role}` order using
    the lowest aligned address in a compatible MMIO window.
11. Build forward/reverse indexes and cross-check every entry.
12. Publish a snapshot only if every step succeeds.

BAR validation rejects odd or out-of-range pairs, role/pair mismatches, zero or
invalid size/alignment, misaligned bases, addresses outside compatible windows,
reserved or allocated overlap in one domain, duplicate roles, and duplicate
pairs on one function.

Equal numeric BDFs and BAR ranges are legal in different domains and illegal
when they collide in one `{host_id,segment_id}` domain. Resolution failure
returns a precise reason, performs no DUT access, and leaves the old snapshot
untouched. Allocation never depends on object creation or associative-array
iteration order.

## 8. Immutable snapshot contract

The snapshot provides typed queries equivalent to:

```text
function key                     -> {domain, BDF}
{domain, BDF}                    -> function key
{function key, BAR role}         -> resolved BAR lease
{domain, address}                -> function key, BAR role, offset
service key                      -> owning function
function key and/or service kind -> service list
expected AF function             -> AF BAR0 lease
```

Public methods return packed values, scalars, or defensive copies. They do not
return handles to protected configuration objects or internal queues. Queries
reject use before publication. The snapshot records the expected AF; hardware
confirmation belongs to the execution report and never mutates the snapshot.

## 9. PCI BAR and AF bootstrap plan

The common bootstrap builder consumes only the frozen snapshot. It emits
domain-qualified PCI configuration writes for resolved BARs, followed by this
strict sequence against the selected PF0's BAR0:

```text
1. READ_VERIFY BAR0+0x1010, mask 0x8, expected 0
2. MMIO_WRITE BAR0+0x1010, value 0x5555AAAA
3. READ_VERIFY BAR0+0x1010,
       mask 0xF, expected 0x8 | selected_host_id
4. MMIO_WRITE BAR0+0x60040,
       value 0x8 | selected_host_id
5. READ_VERIFY BAR0+0x60040,
       mask 0xF, expected 0x8 | selected_host_id
6. BARRIER
```

Step 2 can race with another host, so step 3 is mandatory even when step 1 saw
no valid AF. A different winner is an execution failure. Every AF operation
resolves through the selected function's domain-qualified BAR0 lease. All later
AF table modules depend on the final barrier.

Steps 1 through 4 preserve the driver's declaration, arbitration readback, and
host-ID programming flow. Step 5 is an intentional verification hardening: the
checked driver does not read BAR0+0x60040 back after writing it.

Executor preflight must prove every PCI configuration and MMIO target routable
before the first write. With no executor, the orchestrator reports
`NOT_EXECUTED`, never hardware success.

## 10. Failure and recovery

```text
UNRESOLVED -> RESOLVED -> APPLYING -> ACTIVE
                                `-> FAILED
```

- Resolver failure leaves the previous snapshot untouched and writes nothing.
- Plan freeze or executor preflight failure writes nothing.
- Execution failure stops dependent and later operations and records the
  failed operation and executor error.
- PCIe and MMIO writes are not generally transactional. Execution failure
  marks the device context `FAILED` and does not claim rollback.
- Configuration never clears an existing AF and never changes the selected AF
  to match an unexpected winner.
- Cleanup, reset, and AF re-declaration require a separate explicit recovery
  plan outside this subproject.

`dpu_execution_report` holds terminal and per-operation results separately from
the authoring configuration and snapshot.

## 11. VIO environment migration

`virtio_net_env_config` loses these global or positional fields:

```text
num_hosts
num_pfs_per_host[]
num_vfs_per_pf[][]
num_vfs
max_vfs
dut_caps
pf_bdf
positional vf_configs[]
```

It retains queue size, negotiated features, queue layout, RX mode, interrupt
policy, IOMMU policy, traffic behavior, scoreboard, and coverage controls.
Per-device overrides are indexed by `dpu_service_key_t` rather than flat VF
array position.

`virtio_net_env` no longer creates a `dpu_fabric_env`, derives PF BDFs with an
arithmetic formula, creates topology from count matrices, installs one global
MMIO aperture, or copies DUT capability from its protocol configuration. It
enumerates VIO service keys from a frozen snapshot and queries each function's
domain/BDF/BAR identity.

There is no compatibility translator. Tests and environments using removed
fields must migrate in the same change set.

## 12. Service extension contract

A PF or VF may own VIO-net, RDMA, and VBLK simultaneously because PCIe
function ownership and business resources are separate layers:

```text
dpu_device_snapshot + service-key configuration maps
          |
          v
declare all resource requests
          |
          v
shared dpu_resource_resolver
          |
          v
immutable dpu_resource_snapshot
          |
          v
service plan builders
```

The future resource snapshot owns local/global qids, MSI-X vectors, notify
entries, ports, and scheduler bindings. They are never inferred from function
coordinates or allocation order. Scenario enums are authoring presets; they do
not allocate IDs or branch the executor. Custom authoring remains available.

## 13. Reserved demand-driven placement design

This section fixes the following subproject's extension boundary and is not
implemented here.

Host and PF inventory always comes from explicit physical topology. Queue
demand never synthesizes a PF. VFs may be explicit or, in a future
normalization stage, activated from an explicitly declared PF VF pool.

A future VIO placement request can express total qpairs, candidate filters,
PF/VF kinds, explicit per-device assignments, `EXACT` or `AT_LEAST`
constraints, `AUTO_MINIMUM`/`FIXED`/`ALL_ELIGIBLE` device count, seeded-random
or deterministic selection, balanced distribution, and AUTO/PINNED qids.

For 100 qpairs and the real-DUT maximum of 32 qpairs per VIO device,
`AUTO_MINIMUM` selects at least `ceil(100/32) == 4` devices and distributes 25
to each. For 101, one seed-selected device receives 26 and the other three 25.

Explicit assignments are applied first. Exact assignments of 20 and 4 leave
76, which needs three additional devices and distributes as 26, 25, and 25.
`EXACT` devices receive no remainder; `AT_LEAST` devices may receive more up to
32. Random decisions use a recorded seed and expand into explicit requests
before snapshot or plan publication.

The future dataplane binding is:

```text
PCIe function {domain, BDF, BAR}
  -> VIO service {service key, notify identity}
  -> qpair {local qid, global qid}
  -> shared resources {MSI-X, notify, ports, scheduler path}
  -> network endpoint and forwarding policy
```

The current VIO limit is 32 qpair IDs, local qid 0 through 31, per device. This
means 32 TX and 32 RX queues when individual virtqueues are counted. RDMA and
VBLK use independent capability limits.

## 14. Validation strategy

Focused resolver/snapshot tests cover sparse topology, missing parent PFs,
duplicate identities, capability limits, same numeric BDF/BAR in different
domains, same-domain collisions, reservations, pinned and deterministic AUTO
placement, exhaustion, BAR role/pair/alignment/window validation, lookup
agreement, atomic publication, defensive copies, service coexistence, the
one-VIO-instance profile limit, AF PF0 on every host, and rejection of PF1+,
VFs, missing functions, or missing AF BAR0.

Spy-executor tests cover domain-qualified PCI BAR operations, exact AF
addresses/masks/payloads/dependencies, declaration pre-read, winner verification,
host-ID write/readback, final barrier ordering, plan-only behavior, zero writes
after validation or preflight failure, and execution failure reporting without
snapshot mutation.

Migrated VIO tests prove snapshot/service-key construction, removal of BDF
arithmetic and the single aperture, cross-domain routing with reused numeric
BDF/BAR values, service-key behavior overrides, and preservation of the
32-qpair device limit.

All VCS compile and simulation runs occur on `ubuntu@10.11.10.53` in a bash
login shell. The new focused tests and every test in the maintained regression
manifest must pass strict log checking with zero unexpected UVM errors or
fatals. The pre-change baseline is 19 of 19 passing tests.

## 15. Acceptance criteria

1. `dpu_device_cfg` is the only topology/capability authoring authority.
2. Resolution is deterministic, domain-aware, and publishes only complete
   immutable snapshots.
3. Sparse explicit PF/VF topology and PINNED/AUTO BDF/BAR placement pass.
4. Forward/reverse BDF and BAR lookup requires full domain identity and agrees.
5. PF0 on any host can be selected as AF; PF1+ and VF selection fail before
   execution.
6. The AF plan preserves the checked driver declaration/arbitration flow, adds
   host-ID readback verification, and fails rather than adopting an unexpected
   winner.
7. VIO configuration and environment contain no global topology, capability,
   BDF/BAR allocation, or AF authority.
8. VIO behavior binds by service key and frozen snapshot.
9. No production executor or later table programming is falsely claimed.
10. Focused tests and the complete maintained VCS regression pass on the
    designated host.
