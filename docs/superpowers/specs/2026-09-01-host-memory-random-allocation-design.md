# Per-Host Random Host Memory Allocation Design

**Date:** 2026-09-01

**Status:** Design approved in chat; written specification pending user review

**Scope:** Host memory allocation foundation for VIO, future RDMA, and future
VBLK environments

## 1. Goal

Model each Host as an independent 64-bit GPA address domain with one shared
Host memory allocator. VIO, RDMA, and VBLK services belonging to the same Host
must allocate from the same allocator so their backing memory cannot overlap.
Different Hosts must use different allocator objects and may reuse the same
numeric GPA values. Allocation is random by default for verification, while a
first-fit policy remains available for stable debugging and regression.

The allocator uses the simulator's existing random state. The environment does
not introduce master seeds, derived seeds, or seed persistence. The same
simulator seed, topology/configuration, and allocation call order must produce
the same layout.

## 2. Decisions

1. A top-level Host/DPU environment owns one `host_mem_manager` per `host_id`.
2. All service environments select the manager by
   `service_key.function_key.host_id` and receive an existing handle; they do
   not construct their own memory manager.
3. The existing buddy/linear allocator data structures remain. Placement
   policy is independent of allocator structure.
4. `RANDOM` placement is the default. `FIRST_FIT` remains configurable.
5. Random placement uses the simulator/UVM random stream directly. No custom
   seed field or seed-management API is added.
6. Random allocation always returns memory backed by the initialized allocator
   region; arbitrary 64-bit addresses are invalid.
7. BAR/MMIO and other reserved ranges are registered with the corresponding
   Host allocator before service allocations begin.
8. BAR reservations are Host-scoped. Equal numeric addresses on different
   Hosts do not conflict.
9. VIO/RDMA/VBLK service-specific data planes are outside this subproject. The
   allocator API remains generic so each future environment can reuse it.
10. IOVA allocation remains a separate IOMMU concern. Numeric IOVA equality
    with a BAR is not treated as a conflict unless a future unified address
    space mode explicitly requests that behavior.

## 3. Address and ownership model

```text
dpu_host_env
|-- host_mem[0]
|     |-- VIO services on host0
|     |-- RDMA services on host0
|     `-- VBLK services on host0
|
`-- host_mem[1]
      |-- VIO services on host1
      |-- RDMA services on host1
      `-- VBLK services on host1
```

Each allocation is physically unique only within its Host object. A future
allocation ledger may annotate the existing allocation record with service
owner and purpose for diagnostics, but callers continue to use the existing
`alloc`, `free`, `read_mem`, and `write_mem` API.

The Host memory region is a finite configured aperture `[mem_base, mem_end]`
with an inclusive `mem_end` as currently implemented. A 64-bit GPA width does
not imply that the complete `2^64` byte space is backed by storage.

## 4. Placement policy

The package adds a placement policy separate from `alloc_mode_e`:

```systemverilog
typedef enum {
    HOST_MEM_RANDOM,
    HOST_MEM_FIRST_FIT
} host_mem_alloc_policy_e;
```

`alloc_mode_e` continues to select `MODE_BUDDY` or `MODE_LINEAR`; the new
policy selects how an eligible free location is chosen.

### 4.1 Buddy mode

For a request `(size, alignment)`:

1. Round the request to the existing buddy size and effective alignment.
2. Find the smallest free level that can satisfy the request, searching larger
   levels only when necessary.
3. Collect all free block addresses at the selected level.
4. In `HOST_MEM_RANDOM`, choose an index using the simulator random stream.
5. Split a larger block as the current allocator does, then record the chosen
   block and allocate backing storage.
6. In `HOST_MEM_FIRST_FIT`, retain the current lowest-address selection.

Choosing a random address within the smallest eligible level preserves memory
utilization while still varying placement. Larger-level selection can be added
later as an explicit fragmentation-stress policy.

### 4.2 Linear mode

For a request `(size, alignment)`:

1. Collect all free segments large enough for an aligned allocation.
2. In `HOST_MEM_RANDOM`, choose a candidate segment randomly.
3. Choose an aligned offset within that segment using the simulator random
   stream.
4. Split the segment around the allocation and update the free list.
5. In `HOST_MEM_FIRST_FIT`, retain the current lowest-address segment and
   offset behavior.

All candidates must pass the existing range, alignment, overflow, and backing
storage checks. If no candidate exists, allocation fails with the existing
insufficient-space error path.

## 5. Reservation model

The allocator gains a reservation operation for non-RAM address ranges:

```systemverilog
reserve_range(bit [63:0] base,
              bit [63:0] size,
              string owner = "",
              string file = "",
              int line = 0);
```

Reservations are installed before the first service allocation. The manager
must reject invalid or overflowing ranges and reject overlapping reservations
unless an explicit future shared-reservation policy is introduced.

The top-level flow is:

```text
resolve Host/PCIe/BAR layout
    -> group BAR leases by host_id
    -> reserve each BAR in host_mem[host_id]
    -> initialize/validate Host RAM aperture
    -> create and bind VIO/RDMA/VBLK environments
    -> perform random allocations
```

The initial implementation may reserve ranges after `init_region` provided it
removes them from the free structures before any allocation. It must not allow
an already allocated block to be silently invalidated by a later reservation.

## 6. Shared-object binding

The top-level environment creates the manager map in deterministic Host ID
order. Every service binding performs these checks:

- the service Host ID is declared;
- `host_mem[host_id]` is non-null;
- the service receives the same object handle owned by the top-level Host
  environment;
- a child environment does not create a private replacement manager.

The existing VIO environment remains compatible because it continues to call
the existing memory API. Future RDMA and VBLK environments receive the same
`host_mem_api` handle for their Host and use the same allocation path.

## 7. Randomness and reproducibility

No environment-level seed is stored or derived. Random selection uses native
SystemVerilog/UVM randomization or `$urandom_range` in the shared allocator.
The implementation must not use associative-array `.first()` as the random
choice.

Reproducibility is defined by:

```text
same simulator seed
+ same Host/service configuration
+ same allocator policy
+ same allocation call order
= same allocation results
```

The environment may print allocation history through the existing debug
facilities, but a manifest and custom seed protocol are not required for this
subproject.

## 8. Validation and invariants

The implementation must preserve these invariants:

- allocations from one `host_mem_manager` never overlap;
- allocations from different Host managers may have equal numeric addresses;
- no allocation overlaps a reservation in the same Host manager;
- every returned address has backing storage;
- every returned address satisfies the requested alignment;
- `free` and subsequent random reuse preserve allocator invariants;
- allocation failure does not mutate free lists or backing storage;
- existing poison, bounds, leak, and history checks remain valid.

BAR/GPA overlap is checked only when the BAR lease is imported into the same
Host manager. IOVA/BAR numeric overlap remains legal in the default separate
address-space model.

## 9. Test requirements

The first implementation must add focused tests for:

1. Random buddy allocations are aligned, backed, and non-overlapping.
2. Random linear allocations are aligned, backed, and non-overlapping.
3. Two Host managers may return equal numeric addresses without conflict.
4. A single Host manager shared by VIO-like, RDMA-like, and VBLK-like callers
   never overlaps allocations.
5. Reserved BAR ranges are never returned by random allocation.
6. Random `free`/reallocate sequences preserve memory integrity and leak checks.
7. Different simulator seeds produce different layouts when multiple eligible
   candidates exist.
8. The same simulator seed and call sequence produce the same layout.
9. Existing VIO regression tests continue to pass with random placement enabled
   by default.

## 10. Files and boundaries

Initial implementation is limited to:

- `virtio_net_vip/ext/host_mem/src/host_mem_pkg.sv`: placement policy and
  reservation API declarations;
- `virtio_net_vip/ext/host_mem/src/host_mem_manager.sv`: random candidate
  selection, reservation bookkeeping, and shared-object invariants;
- `virtio_net_vip/src/env/virtio_net_env.sv` and its configuration: bind the
  manager selected by `service_key.function_key.host_id` without changing VIO
  call sites;
- focused Host memory tests and a shared-Host integration test.

BAR resolver changes and RDMA/VBLK data-plane implementation are separate
follow-up subprojects. The first phase must not change IOMMU address semantics
or introduce a unified BAR/IOVA address pool.
