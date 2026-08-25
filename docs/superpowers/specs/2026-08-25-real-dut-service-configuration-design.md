# Real DUT Function-Attached Service Configuration Design

## 1. Purpose

This design defines how the verification environment configures the real PCIe
DUT through an administrator function (AF).  It covers PCIe topology, BDF and
BAR ownership, MSI-X, VIO-net notification and queues, scheduler and packet
processing dependencies, and extension points for RDMA, virtio-blk, and future
services.

The design is based on the interfaces used by the `dpu_snd1.ko` source tree at
`/home/ubuntu/wn/icpu-kernel-driver` on `10.11.10.53`, while keeping hardware
capabilities separate from driver software limits.  The default AF is
`host0/pf0`, but the AF identity remains configurable.

The audited binary reports version `2.1.0+f2c9cd6`, was built from branch
`lance_net_mailbox`, and has SHA-256
`5eab997f6cf926fef7a5740b5962c1aaf4ba6475d8d9bf28aca7a15f3d85282b`.
The module was not loaded during the audit; register and lifecycle behavior in
this document comes from its matching build source and binary metadata.

The real DUT path is in scope.  `cosim_control`, BAR2 mailbox command delivery,
and mailbox-based function configuration are out of scope.  Configuration is
lowered to PCIe Memory Write TLPs issued through the AF BAR0.  Function BAR4 is
used for the standard MSI-X table and PBA view.

## 2. Design principles

1. A PCIe function is the shared ownership and isolation boundary.  Its BDF,
   BARs, source ID, global function ID, local MSI-X namespace, and scheduler
   root are shared by every service attached to that function.
2. VIO-net, RDMA, and virtio-blk are independent service instances attached to
   a PF or VF.  A function may carry several service kinds concurrently.
3. Service-local IDs and DUT-global IDs are separate namespaces joined by an
   explicit binding.  Neither function coordinates nor allocation order imply
   a global ID.
4. Scenarios are presets that create declarative configuration.  They do not
   allocate IDs and do not write registers.
5. Hardware capabilities, scenario requests, resolved resource bindings, and
   register operations are separate layers.
6. A configuration plan must pass complete validation before its first PCIe
   write.  Partial resource allocation or partial register programming is not
   an accepted result.

## 3. Configuration model

The logical hierarchy is:

```text
dpu_device_cfg
├── dpu_dut_caps
├── administrator function key
├── hosts[]
│   └── functions[]
│       ├── PCIe identity and BAR declarations
│       └── services[]
│           ├── VIO_NET instance
│           │   └── qpair bindings[]
│           ├── RDMA instance
│           │   └── RDMA-specific objects
│           └── VBLK instance
│               └── virtio device and virtqueues[]
└── scenario metadata
```

### 3.1 Function identity

Every PF and VF is identified by a full key:

```systemverilog
typedef struct {
    int unsigned        host_id;
    int unsigned        pf_id;
    dpu_function_kind_e kind;
    int unsigned        vf_id;
} dpu_function_key_t;
```

No table may use a bare PF ID or VF ID as its owner.  The full key is used for
forward and reverse lookup of the BDF, BAR lease, source ID, global function
ID, service instances, and resource leases.

### 3.2 Service identity

A service instance has a stable key independent of its queue IDs:

```systemverilog
typedef struct {
    dpu_function_key_t function_key;
    dpu_service_kind_e service_kind;
    int unsigned       instance_id;
} dpu_service_key_t;
```

The initial service kinds are `DPU_SERVICE_VIO_NET`, `DPU_SERVICE_RDMA`, and
`DPU_SERVICE_VBLK`.  `DPU_SERVICE_VFS` can be added without changing the PCIe
topology or generic resource manager.

For the current DUT profile, one PF or VF exposes at most one VIO-net device.
The same function may simultaneously contain an RDMA service and a VBLK
service.  VBLK owns an additional virtio-device object because its
`virtio_dev_id`, admin/data virtqueues, backend state, and device lifecycle do
not fit the VIO-net qpair model.

### 3.3 Service extension contract

Each service type supplies the following operations through a service-specific
configuration and plan builder:

```text
declare_resources()
validate()
resolve_bindings()
build_register_plan()
build_lifecycle_plan()
```

Adding a service requires a configuration type, resource declarations, a plan
builder, block-specific sequences, and checkers.  It must not require changes
to function topology, BAR allocation, BDF lookup, scenario selection, or the
generic lease core.

## 4. Capability model and limits

Capabilities belong to the DUT profile, not to a scenario enum and not to a
protocol-independent core constant.  The default real-DUT profile contains:

```text
max hosts                         2
PFs per host                      4
VFs per PF                       16
global MSI-X vectors            256
encoded VIO global qpair IDs   2048 (11-bit ID: 0..2047)
VIO-net qpairs per device        32 (local pair: 0..31)
```

Notify storage limits are modeled separately from the global qpair namespace.
The register definition exposes 1024 entries per VIO notify bank, while the
examined driver build keeps a 128-entry software shadow and a 128-entry queue
bitmap.  These values must not silently replace the 11-bit global qpair ID
domain.  A DUT version selects the implemented active-notify and active-qpair
capacities explicitly.

The examined driver enforces the per-device limit with
`DPU_MAX_RING_NUM == 32`: `req_ring_num` becomes both `num_rxq` and `num_txq`,
is clamped to 32, and one function supplies one notify address.  Therefore the
32-qpair limit is mandatory for both PF and VF VIO-net devices, not a scenario
default that a test may raise.

The limit is enforced at two boundaries:

1. VIO-net validation rejects more than 32 configured qpairs or any
   `local_pair_id` outside `0..31`.
2. The Fabric `virtio.qpair` profile retains `max_per_function == 32` as a
   defensive aggregate quota.

The VIO client must reject ranges whose end exceeds 31, including
`first_local_pair=32,count=1` and `first_local_pair=31,count=2`.  Different
functions may reuse the same local pair ID because their notify addresses and
function ownership differ.

## 5. VIO-net queue binding

One VIO-net qpair is the allocation unit.  A binding contains:

```text
owner service key
local_pair_id                       0..31
requested/resolved global_qpair_id 0..2047
RX/TX local MSI-X vectors
resolved global MSI-X vectors
source and destination ports
traffic class and scheduler parent
queue depth, descriptor addresses, mode, and lifecycle state
```

For local pair `p`:

```text
RX virtio local_qid = 2*p
TX virtio local_qid = 2*p + 1
```

The real driver allocates one `txrx_queues[p]` value for the pair.  That same
global qpair index selects the VTX and VRX entries in their respective hardware
blocks.  The environment must therefore represent:

```text
local_pair_id -> global_qpair_id
```

It must not derive two global IDs as `2*g` and `2*g+1`.  Direction selects the
VTX or VRX block; it does not create a second global qpair allocation.

### 5.1 Allocation policies

The binding supports three policies:

```text
AUTO       allocate any free global qpair ID
PINNED     allocate the requested ID or fail
PREFERRED try the requested ID, then use any free ID
```

Global IDs assigned to one PF or VF may be sparse and in any order.  For
example, local pairs `0,1,2` may bind to global pairs `1700,13,511`.  A global
ID is exclusive while leased.  Reserved hardware IDs and AF-owned queues are
removed from the allocatable set by the DUT profile.

Normal VIO-net configurations use contiguous local pairs `0..N-1`, matching
the driver and virtio-net device model.  Sparse local pairs are permitted only
by an explicit negative-test policy and still cannot exceed 31.

## 6. AF and register-access architecture

Exactly one active function is selected as AF.  The default is `host0/pf0`.
AF selection is validated against the declared topology before BAR allocation.
The AF owns the configuration executor and issues real PCIe Memory Write TLPs
to its BAR0.

The executor consumes an ordered register plan.  A register operation contains
the target block, BAR-relative address, width, payload, write mask if needed,
and optional readback policy.  The plan builder, not the low-level PCIe
sequence, packs register fields.

The existing `virtio_bar_mem_wr_seq` accepts a caller payload but does not copy
it into the lower `pcie_tl_mem_wr_seq` payload.  The lower sequence can
therefore randomize the DWORDs.  This is a blocking defect: it must be fixed by
a failing payload-propagation test before any real-DUT configuration sequence
is considered trustworthy.

## 7. BDF and BAR ownership

Every activated function receives forward and reverse mappings:

```text
function key -> BDF, source ID, global function ID, BAR leases
BDF          -> function key
BAR address  -> function key, BAR role, BAR-relative offset
global func  -> function key
```

The default BAR roles are:

```text
BAR0  function/device memory and AF configuration access
BAR2  mailbox/reserved aperture; functional mailbox path is out of scope
BAR4  standard MSI-X table and PBA aperture
```

BAR allocation validates size, alignment, 64-bit aperture overflow, overlap,
and uniqueness.  Register plans use BAR-relative addresses and are resolved to
PCIe addresses only by the executor.

The AF programs the DUT BDF map at:

```text
BAR0 + 0x56000 + global_func_id*4
```

AF declaration and host identity use:

```text
BAR0 + 0x1010   magic 0x5555AAAA
BAR0 + 0x60040  AF host ID
```

## 8. VIO notify programming

The logical VIO notify match is:

```text
{host_id, notify_addr[60:7], local_pair_id} -> global_qpair_id
```

The table and commit registers are:

```text
VIO notify bank    BAR0 + 0x28000 + bank*0x4000
VIO notify commit  BAR0 + 0x20044
```

The driver maintains inactive and active banks.  Configuration copies the
complete shadow into the inactive bank, writes invalid values to unused
entries, verifies programmed data where supported, and commits the bank only
after all entries succeed.  The invalid entry is:

```text
DWORD0 0xFFFFFFFF
DWORD1 0xFFFFFFFF
DWORD2 0x000007FF
DWORD3 0x00000000
```

One function contributes at most 32 entries because one notify address belongs
to one VIO-net device and local pair IDs are limited to `0..31`.  A 33rd qpair
must be owned by another function/device with its own notify address.

Notify entries are built from resolved bindings.  Notify programming never
allocates a qpair and never infers ownership from a global ID.

## 9. MSI-X model

MSI-X contains three related mappings:

```text
{src_id, local_vector} -> global_vector
global_vector          -> {host_id, global_func_id}
function BAR4 entry    -> DUT global MSI-X table entry
```

AF BAR0 tables are:

```text
global MSI-X table  BAR0 + 0x48000 + global_vector*16
PBA                 BAR0 + 0x50000
MSI-X interval      BAR0 + 0x52000 + global_vector*4
MSI-X info          BAR0 + 0x54000 + global_vector*4
MSI-X linear        BAR0 + 0xC0000 + ((src_id<<7)+local_vector)*4
```

The interval DWORD uses bits `[15:0]` for rate in 32-us units and bits
`[31:16]` for packet count.  The scenario may select disabled, rate-only,
packet-only, or combined moderation through declarative parameters.

The PBA is DUT-maintained pending state.  AF configuration does not write PBA
bits.  Verification checks BAR4 PBA visibility and pending/unmask behavior.

## 10. Scheduler and packet-processing dependencies

QSCH is part of functional queue bring-up, not an optional QoS add-on.  The
relevant tables are:

```text
DSCH base     BAR0 + 0xA00000
QSCH base     BAR0 + 0xB00000
QSCH init     BAR0 + 0xB00100
Q2TC          BAR0 + 0xB10000 + global_qpair_id*4
N2G           BAR0 + 0xB11000 + global_func_id*4
G2P           BAR0 + 0xB12000 + global_func_id*4
SP/WRR        BAR0 + 0xB13000 + global_func_id*4
WRR weight    BAR0 + 0xB14000 + global_func_id*4
```

The logical scheduler tree has a function root and service subtrees.  VIO-net,
RDMA, and VBLK queues on one function may use different traffic classes and
leaves while sharing the function root.  Current hardware lowering may fold
logical service nodes when a hardware level is unavailable, but ownership must
remain visible in the declarative model and checker.

For VIO-net, the dependency order is:

```text
resolve global qpair
-> build notify mapping
-> program N2G/G2P
-> program per-global-qpair Q2TC
-> program SP/WRR and weights
-> program route and port tables
-> program VTX/VRX parameters and contexts
-> enable queues
```

VTX/VRX contexts include descriptor address, depth, global MSI-X binding,
global function ID, ports, virtio mode, and enable/reset state.  RSS,
IPRO/EPRO/vport, MAC/VLAN/FDB/promiscuous configuration, and queue
reset/recovery are explicit dependencies of a complete traffic scenario.

## 11. VBLK extension

VBLK attaches to a function as a service but uses an independent virtio-device
and queue model.  It owns:

```text
virtio_dev_id
admin and data virtqueues
global virtqueue IDs
BLK notify entries
AQ/DQ contexts
backend/vDPA state
enable, disable, reset, and status lifecycle
```

Its notify registers are:

```text
BLK notify table   BAR0 + 0x34000
BLK notify commit  BAR0 + 0x20050
```

VBLK global virtqueues use a resource class separate from VIO-net global
qpairs.  They share the function's BDF, BARs, global function ID, source ID,
and MSI-X namespace but do not consume the VIO-net 32-qpair quota.

## 12. RDMA extension

RDMA follows the same function-attached service contract while declaring its
own QPN, CQN, CEQ, HMC/context, notify, and route resources.  RDMA resources do
not consume VIO-net qpairs or VBLK virtqueues.  Shared MSI-X, port, and
scheduler resources are resolved by the same global binding phase, allowing
the validator to detect conflicts before register lowering.

## 13. Scenarios and parameter overrides

Scenario enums are catalog keys such as:

```text
DPU_SCENARIO_VIO_ONLY
DPU_SCENARIO_VIO_RDMA
DPU_SCENARIO_VIO_VBLK
DPU_SCENARIO_CONVERGED
```

The selected catalog entry creates a complete `dpu_device_cfg`.  User
parameters then override declarative fields such as topology size, function
selection, service enablement, exact global IDs, vectors, routes, and
scheduler policy.  The same validation and allocation pipeline runs after
overrides.  A scenario cannot bypass a DUT capability, allocate a global ID,
or issue a register write.

## 14. Resolution and execution pipeline

The configuration pipeline is:

```text
scenario preset
-> user parameter overrides
-> topology and service validation
-> transactional resource reservation
-> resolved binding graph
-> block-specific register lowering
-> ordered register plan validation
-> AF BAR0/BAR4 PCIe execution
-> readback and state verification
-> traffic enable
```

Resource resolution is transactional.  A failed PINNED ID, quota violation,
notify-capacity violation, vector collision, invalid port, or scheduler error
releases every tentative lease and produces no register plan.  Once lowering
starts, the resolved configuration is frozen.  FLR, disable, teardown, and
migration use service lifecycle plans to freeze, restore, or release the exact
saved bindings.

## 15. Error handling

Validation errors identify the full function and service keys and the rejected
resource.  Required failures include:

- topology coordinates outside DUT capabilities;
- no AF, multiple AFs, or AF referring to an inactive function;
- duplicate BDF, global function ID, BAR range, global qpair, or MSI-X owner;
- a VIO-net device with more than 32 qpairs;
- VIO local pair outside `0..31` or duplicate within a device;
- an unavailable PINNED global ID or exhausted resource class;
- notify entry exhaustion independent of global qpair availability;
- invalid MSI-X local/global mapping;
- incomplete scheduler, route, VTX, or VRX dependencies;
- any write payload that is not propagated unchanged to the PCIe TLP.

Hardware write failures stop execution before dependent blocks are enabled.
Banked tables commit only after the complete inactive image has been written
successfully.

## 16. Verification strategy

Implementation follows test-driven development.  Every behavior is first
introduced by a test that fails for the intended reason.  VCS simulation runs
on `ubuntu@10.11.10.53` through a Bash login shell so the VCS and license
environment from `~/.bashrc` is active.

Minimum coverage includes:

1. PF and VF VIO-net devices accept exactly 32 local pairs `0..31`.
2. `local_pair=32`, `local_pair=31,count=2`, and a cumulative 33rd pair fail.
3. Different functions may each own local pair zero.
4. Sparse PINNED global pair IDs resolve to the requested owners and duplicate
   ownership fails atomically.
5. VTX and VRX use the same resolved global qpair index in separate blocks.
6. A function can carry VIO-net, RDMA, and VBLK without cross-consuming their
   private resource classes.
7. BDF, BAR, source ID, global function, MSI-X, notify, route, scheduler, and
   queue-context plans agree end to end.
8. VIO and BLK inactive-bank writes use exact packed payloads and commit only
   after a full valid image.
9. BAR4 MSI-X table/PBA accesses resolve to the correct function and PBA
   pending/unmask behavior is DUT-driven.
10. FLR, disable, migration freeze/restore, and teardown neither leak nor
    silently reassign resources.
11. A real traffic test observes notify, descriptor processing, DMA, interrupt,
    and packet completion through the DUT rather than a bypass model.

## 17. Current-code migration boundaries

The current code already provides generic BAR leases, function BDF fields, a
generic resource manager, a VIO qpair client, BAR4 MSI-X writes, and PCIe
sequences.  The migration must preserve those reusable pieces while changing
the following contracts:

- add function/BDF/BAR/global-function reverse lookups;
- make DUT capabilities the source of topology and service limits;
- validate VIO local pair range `0..31` in addition to the existing quota;
- add exact/PREFERRED global-ID lease requests;
- replace RX/TX `2*g` derivation with one global qpair binding;
- add AF register plans for BDF, MSI-X, notify, QSCH/DSCH, route, VTX/VRX,
  VBLK, and service lifecycle;
- fix BAR Memory Write payload propagation before using the executor;
- connect production queue setup and teardown to resolved leases;
- add PBA behavior and end-to-end real-DUT data-plane checking.

This document is the umbrella architecture.  Implementation is split into
independently testable subprojects, each with its own implementation plan and
completion gate:

1. capability/topology validation and the mandatory 32-qpair VIO limit;
2. exact global-resource binding and corrected one-ID-per-qpair semantics;
3. PCIe payload correctness and common AF BDF/BAR/MSI-X tables;
4. VIO notify, scheduler, route, VTX/VRX, and real data-plane verification;
5. VBLK service resources and lifecycle;
6. RDMA service resources and lifecycle.

The first implementation plan must cover only subproject 1.  Later plans may
rely on its capability object and validation contract but cannot weaken the
per-device 32-qpair invariant.
