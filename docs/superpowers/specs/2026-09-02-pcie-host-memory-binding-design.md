# PCIe Per-Root Host-Memory Binding Design

## Scope

Bind the existing `pcie_tl_vip` unified-memory DMA responder to the same
per-Host `host_mem_manager` objects already owned by the top-level
`host_mem_pool`. This change does not introduce a second PCIe DMA responder,
an IOVA translation service, or QSCH/VTX/VRX register programming.

The resulting ownership rule is:

```text
top-level host_mem_pool
  Host 0 manager ──> VIO Host 0 ──> virtqueue/ring/buffer allocation
                 └─> PCIe Root 0 ──> DUT-originated DMA MRd/MWr response
  Host 1 manager ──> PCIe Root 1 ──> independent Host 1 DMA address domain
```

An RDMA or VBLK environment can later receive another handle from the same
pool without changing the PCIe package interface.

## Existing Behavior and Defect

`pcie_tl_env` already routes endpoint-originated MRd, MWr, and Atomic TLPs to
`pcie_tl_rc_driver`, which reads and writes a `host_mem_api` backend and emits
read completions. The responder itself is complete enough for this stage.

The current unified-memory distribution block has two ownership defects:

1. It calls `init_region(0, 0xFFFF_FFFF, ...)` unconditionally on a memory
   object obtained through config-db. If the top level already initialized a
   randomized 64-bit Host aperture, this silently adds an unrelated low 4-GiB
   region when no allocation has yet occurred, or reports an initialization
   error after allocations exist.
2. It assigns the Host-memory handle only to `rc_agent`, the root-0 alias.
   Additional roots therefore have no Host-specific DMA backend.

## Public Configuration Interface

`pcie_tl_env_config` will own an associative mapping from `root_index` to a
pair of `host_id` and `host_mem_api` handle. The following methods form the
public contract:

```systemverilog
function bit bind_host_memory(
    input int unsigned root_index,
    input int unsigned host_id,
    input host_mem_api mem,
    output string why
);

function bit get_host_memory(
    input int unsigned root_index,
    output int unsigned host_id,
    output host_mem_api mem,
    output string why
);

function int unsigned host_memory_binding_count();

function bit validate_host_memory_bindings(
    input int unsigned root_count,
    output string why
);
```

`bind_host_memory()` rejects a null handle, a manager whose
`get_host_id()` differs from `host_id`, and every second binding attempt for
the same root. A failed call leaves the previous mapping unchanged.

`get_host_memory()` fails for an unbound root. Validation requires exactly
one binding for every enabled root index from zero through `root_count - 1`
and rejects bindings outside that range. This makes a partially configured
multi-Root topology fail before traffic begins.

The config object stores only the protocol-neutral base type
`host_mem_pkg::host_mem_api`. It must not import `virtio_net_pkg` or refer to
`host_mem_pool`, because `virtio_net_pkg` already depends on `pcie_tl_pkg`.

## Environment Binding and Compatibility

When `use_unified_mem` is enabled, `pcie_tl_env.connect_phase()` selects one
of two paths:

- If the config contains explicit Root bindings, it validates the complete
  set and assigns each handle to `rc_agents[root].rc_driver.mem`.
- If no explicit binding exists, the existing config-db key `"host_mem"`
  remains a root-0 compatibility fallback. This fallback is valid only when
  there is at most one enabled Root; a multi-Root topology must use explicit
  bindings.

The environment exposes `host_mem_by_root[]` for integration checks and
keeps `host_mem` as the root-0 compatibility alias.

For either path, initialization follows one rule:

```text
manager already initialized  -> preserve its aperture and allocator state
manager not initialized      -> initialize the legacy 0..0xFFFF_FFFF aperture
initialization still invalid -> fatal configuration error
```

The same non-destructive initialization guard is applied to legacy
`dev_mem_N` backends. Premap allocation remains controlled by the existing
`mem_access_mode` setting and occurs only after a usable manager exists.
Because PREMAP reserves backing storage in the manager rather than in a Root
port, one PCIe environment allocates it once per unique `host_mem_api` handle;
multiple Roots bound to the same Host manager do not consume duplicate
apertures. An allocator failure sentinel is a fatal PCIe configuration error
for explicit Root, legacy Root-0, and device-memory paths.

## Data Flow

The normal DUT DMA path remains:

```text
DUT/EP TLP carrying Host GPA
  -> PCIe EP-to-Root routing
  -> Root-specific pcie_tl_rc_driver
  -> that Root's shared host_mem_api
  -> MWr updates backing storage, or MRd returns CplD data
```

The address in the TLP is used directly as Host GPA for this stage. No
verification-only IOVA lookup is inserted between PCIe and Host memory.

Different Hosts own different manager objects. They may use numerically
identical GPA ranges without aliasing because each Root responder holds its
own object handle.

## Error Handling

Configuration API failures return `0`, set a precise `why` string, and do not
emit a UVM report. This allows callers and focused tests to decide reporting
policy.

The environment treats these runtime-configuration conditions as fatal:

- an explicit binding set is incomplete or contains an out-of-range root;
- a required root-0 legacy config-db handle is missing;
- a multi-Root topology attempts to use the single root-0 fallback;
- a selected manager cannot be initialized;
- a validated binding cannot be retrieved during distribution;
- a requested PREMAP allocation cannot be satisfied.

## Verification

A maintained integration test will construct two manager objects with the
same high 64-bit GPA aperture, bind them to Root 0/Host 0 and Root 1/Host 1,
and inject the Host 0 manager into the VIO environment from the same pool.
It will prove:

- invalid, mismatched, duplicate, missing, and incomplete bindings are
  rejected without corrupting valid state;
- VIO Host 0, PCIe Root 0, and the pool expose the identical object handle;
- PCIe Root 1 uses a distinct Host 1 handle;
- neither manager gains the legacy low 4-GiB aperture;
- both Hosts can allocate the same GPA value while storing different bytes;
- actual EP0/EP1 MWr and MRd TLPs reach only their owning Root manager and
  return the correct data;
- two Roots sharing one manager consume exactly one PREMAP allocation, while
  an undersized aperture is rejected as a PCIe configuration failure.

The focused test and the complete maintained regression run on
`10.11.10.53` with its login-shell VCS environment.

## Non-Goals

- Implementing a new responder in the parent VIO environment.
- Translating IOVA to GPA in the verification environment.
- Random BAR placement.
- QSCH/DSCH, VTX, or VRX register lowering.
- RDMA or VBLK environments.
- Multiple simultaneously active AF instances.
