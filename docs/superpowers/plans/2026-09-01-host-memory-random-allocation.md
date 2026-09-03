# Per-Host Random Host Memory Allocation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add simulator-seeded random Host memory placement with BAR/reserved-range exclusion and per-Host shared allocator ownership, while preserving existing VIO memory call sites.

**Architecture:** `host_mem_manager` keeps its existing buddy/linear data structures and adds an orthogonal placement policy. A Host memory pool owns one manager per `host_id`; all services on one Host receive the same handle and different Hosts receive different handles. Reservations are installed before service allocations and are removed from the free structures, so random GPA allocation always returns backed, non-reserved memory.

**Tech Stack:** SystemVerilog, UVM 1.2, Synopsys VCS W-2024.09-SP1, existing `host_mem_manager`, current virtio-net VIP.

**Spec:** `docs/superpowers/specs/2026-09-01-host-memory-random-allocation-design.md`

## Progress update (2026-09-01)

Implemented and verified in the current working tree:

- Random Buddy/Linear placement, reservation subtraction, per-Host pool
  identity/isolation, 64-bit boundary handling, and backing-storage checks.
- VIO `host_mem_binding` and `host_mem_pool_binding` selection with Host-ID
  validation; base VIO tests now construct a pool at the composition root.
- Frozen-snapshot BAR reservation importer.  BARs in a separate MMIO aperture
  are skipped, partial aperture intersections fail, and identical imports are
  idempotent.
- Focused Host-memory tests, standalone legacy Host-memory tests, smoke/unit
  tests, and the maintained 24-test strict regression pass on VCS.

Still intentionally deferred: explicit seed-comparison tooling, a mixed
RDMA/VBLK service stress test, and a protocol-neutral pool owner inside
`dpu_common` (the pool remains an application/composition-layer object because
the DPU package must not depend on the Virtio Host-memory implementation).

## Global Constraints

- Use the simulator/UVM random state directly; do not add a custom seed field, derived seed, or seed-management API.
- `HOST_MEM_RANDOM` is the default placement policy; `HOST_MEM_FIRST_FIT` remains available for stable debug and regression.
- `MODE_BUDDY` and `MODE_LINEAR` remain allocator-structure choices and are independent from placement policy.
- A 64-bit GPA is an address width, not an instruction to allocate from the complete `2^64` byte range; allocations must remain inside initialized regions.
- Reservations are Host-scoped and must be installed before the first service allocation.
- Different Host managers may return equal numeric GPAs; allocations from one manager must never overlap.
- Existing `alloc`, `free`, `read_mem`, `write_mem`, poison, bounds, history, and leak behavior remain compatible.
- Do not change IOMMU semantics, add random IOVA allocation, implement RDMA/VBLK data planes, or add the PCIe DMA target in this plan.
- Preserve all existing uncommitted user changes; do not reset, checkout, or overwrite unrelated files.
- Run VCS compile/simulation on `ubuntu@10.11.10.53` through a Bash login shell. Do not persist credentials or tokens.

## File Structure

### Files to modify

- `virtio_net_vip/ext/host_mem/src/host_mem_pkg.sv`: placement-policy enum, reservation metadata, and abstract API declarations.
- `virtio_net_vip/ext/host_mem/src/host_mem_manager.sv`: policy state, reservation bookkeeping, random Buddy/Linear selection, and per-manager validation.
- `virtio_net_vip/src/env/virtio_net_env_config.sv`: expose Host memory placement policy and Host memory aperture configuration without adding seed fields.
- `virtio_net_vip/src/env/virtio_net_env.sv`: create or bind the manager supplied for the selected Host and apply reservations before VIO components allocate.
- `filelists/virtio_net.f`: include any new Host memory source in dependency order.
- `scripts/test_manifest.sh`: register the focused Host memory random test exactly once.
- `filelists/tests.f`: compile the focused test exactly once.

### Files to create

- `virtio_net_vip/ext/host_mem/src/host_mem_pool.sv`: UVM object owning one `host_mem_manager` per Host ID and returning the existing handle for a Host.
- `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`: focused tests for random Buddy/Linear allocation, reservations, per-Host isolation, and seed reproducibility.

### Files not changed in this phase

- `virtio_net_vip/src/iommu/virtio_iommu_model.sv`: IOVA remains the existing optional model.
- `virtio_net_vip/src/transport/virtio_bar_accessor.sv` and PCIe TL VIP: PCIe DMA memory targeting is a separate phase.
- VIO queue/data-plane call sites: they continue to use `host_mem_api` and need no per-call policy logic.

---

### Task 1: Add policy, reservation, and Host pool interfaces

**Files:**
- Modify: `virtio_net_vip/ext/host_mem/src/host_mem_pkg.sv`
- Create: `virtio_net_vip/ext/host_mem/src/host_mem_pool.sv`
- Modify: `filelists/virtio_net.f`
- Create: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- `host_mem_alloc_policy_e` values are `HOST_MEM_RANDOM` and `HOST_MEM_FIRST_FIT`.
- `host_mem_reservation_t` contains `base`, `size`, and `owner`.
- `host_mem_api` adds `set_alloc_policy(host_mem_alloc_policy_e policy)`, `get_alloc_policy()`, and `reserve_range(bit [63:0] base, bit [63:0] size, string owner = "", string file = "", int line = 0)`.
- `host_mem_pool` exposes `create_host(host_id, base, end_addr, alloc_mode_e mode = MODE_BUDDY, int unsigned granule = DEFAULT_MIN_GRANULE, host_mem_alloc_policy_e policy = HOST_MEM_RANDOM)`, `get_host(host_id)`, and `has_host(host_id)`.

- [ ] **Step 1: Write failing interface tests**

Add tests that instantiate a pool, create Host 0 and Host 1 with equal numeric regions, assert the handles differ, and assert the same pool returns the same handle for repeated `get_host(0)`. Add a reservation call and assert it succeeds before any allocation.

```systemverilog
host_mem_pool pool;
host_mem_manager h0_a, h0_b, h1;
pool = host_mem_pool::type_id::create("pool");
assert(pool.create_host(0, 64'h1000, 64'h1ffff));
assert(pool.create_host(1, 64'h1000, 64'h1ffff));
h0_a = pool.get_host(0);
h0_b = pool.get_host(0);
h1   = pool.get_host(1);
assert(h0_a == h0_b);
assert(h0_a != h1);
assert(h0_a.reserve_range(64'h4000, 64'h1000, "BAR0"));
```

- [ ] **Step 2: Run RED**

Run the focused test on the VCS host. Expected result: compile failure because the policy, pool, and reservation interfaces do not yet exist.

```bash
remote_stage=/home/ubuntu/test_host_mem_random
ssh ubuntu@10.11.10.53 "mkdir -p $remote_stage"
rsync -a --exclude .git --exclude build ./ ubuntu@10.11.10.53:"$remote_stage/"
ssh ubuntu@10.11.10.53 "bash -lic 'cd $remote_stage && TEST=host_mem_random_tb ./scripts/vcs.sh'"
```

- [ ] **Step 3: Add declarations and pool shell**

Keep `alloc_mode_e` unchanged. Add the policy enum and reservation struct to `host_mem_pkg.sv`. Extend `host_mem_api` with the exact methods above. Implement `host_mem_pool` with an associative array `host_mem_manager managers[int unsigned]`; reject duplicate Host IDs, invalid ranges, and missing Host lookups without creating a replacement object.

- [ ] **Step 4: Run GREEN for the interface test**

Run `host_mem_random_tb` again and require the pool identity, reservation, and invalid-input assertions to pass. Existing host memory tests must still compile.

### Task 2: Implement random Buddy placement

**Files:**
- Modify: `virtio_net_vip/ext/host_mem/src/host_mem_manager.sv`
- Modify: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`

**Interfaces:**
- `host_mem_manager::set_alloc_policy()` and `get_alloc_policy()` implement the abstract API.
- Buddy `alloc()` selects an address randomly only when policy is `HOST_MEM_RANDOM`; first-fit behavior remains unchanged for `HOST_MEM_FIRST_FIT`.

- [ ] **Step 1: Add failing Buddy placement assertions**

Initialize two managers with the same 1 MiB region. Allocate a sequence of same-sized aligned blocks under the simulator random state and assert every returned address is aligned and non-overlapping. Add a first-fit comparison that expects the lowest free block after reset.

- [ ] **Step 2: Run RED**

The random-placement test must fail the first-fit address diversity assertion while the existing deterministic allocator still returns the lowest address.

- [ ] **Step 3: Implement candidate selection**

In Buddy mode, preserve the existing search for the smallest eligible level. When that level is selected, enumerate its free block addresses into a dynamic array, choose an index using `$urandom_range(0, candidates.size()-1)`, and delete/split the selected block exactly as the current allocator does. Use the existing `.first()` only for `HOST_MEM_FIRST_FIT`. Do not randomize outside the initialized region and do not change backing-storage allocation.

- [ ] **Step 4: Run GREEN and existing stress tests**

Run the focused random test and the existing 10K Buddy stress cases. Require no duplicate addresses, no data corruption, valid alignment, and a clean leak check.

### Task 3: Implement random Linear placement

**Files:**
- Modify: `virtio_net_vip/ext/host_mem/src/host_mem_manager.sv`
- Modify: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`

**Interfaces:**
- Linear `alloc_linear()` honors the same `host_mem_alloc_policy_e` as Buddy mode.

- [ ] **Step 1: Write failing Linear tests**

Initialize a linear region with at least four eligible free segments, allocate aligned blocks, free selected blocks, and assert random mode can select different eligible segments without overlap.

- [ ] **Step 2: Run RED**

The test must fail while `alloc_linear()` always starts at the lowest segment/offset.

- [ ] **Step 3: Implement random segment/offset**

Collect every free segment for which an aligned allocation fits. Choose a segment index with `$urandom_range`. Within that segment, compute the first and last aligned candidate and choose an aligned offset with `$urandom_range` over the candidate count. Split the free segment around the allocation using the existing merge/release helpers. Preserve overflow checks and return `'1` without mutation when no candidate exists.

- [ ] **Step 4: Run GREEN and linear stress**

Run the focused Linear tests and the existing 15K Linear stress case. Require no overlaps, no data corruption, and clean leak checks.

### Task 4: Add reservation-aware free-space management

**Files:**
- Modify: `virtio_net_vip/ext/host_mem/src/host_mem_manager.sv`
- Modify: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`

**Interfaces:**
- `reserve_range(base, size, owner, file, line)` accepts a half-open range `[base, base+size)` and records it as Host-local metadata.

- [ ] **Step 1: Write failing reservation tests**

Test a reservation inside a Buddy region and inside a Linear region. Assert allocations never overlap the reserved interval. Test invalid zero-size, overflow, out-of-region, overlapping, and post-allocation reservations; each must fail without mutating existing allocations.

- [ ] **Step 2: Run RED**

The tests must show allocations currently enter the reserved interval or that the reservation API is missing.

- [ ] **Step 3: Implement reservation subtraction**

Validate the half-open range without overflow. Reject a reservation after any allocation if it intersects a live allocation. For reservations before allocation, subtract the interval from every initialized Buddy free block (split blocks or rebuild free blocks after reservation) and from every Linear free segment. Store reservation metadata for diagnostics. Reject duplicate/overlapping reservations.

- [ ] **Step 4: Run GREEN and regression**

Run reservation-focused tests plus all existing Host memory tests. Verify random Buddy and Linear allocators skip every reservation.

### Task 5: Expose policy and per-Host binding to the VIO environment

**Files:**
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv`
- Modify: `virtio_net_vip/src/env/virtio_net_env.sv`
- Modify: `virtio_net_vip/ext/host_mem/src/host_mem_pool.sv`
- Modify: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`

**Interfaces:**
- `virtio_net_env_config` adds `host_id`, `host_mem_policy`, and the existing `mem_base/mem_end` remains the Host aperture for this environment.
- The environment accepts an optional `host_mem_manager host_mem_binding`; when present, it must use that handle rather than create a private manager.
- If no binding is supplied, the existing single-Host behavior creates one manager with `host_id` and `host_mem_policy` for backward compatibility.

- [ ] **Step 1: Write failing binding tests**

Create two VIO environment configurations with different Host IDs and inject managers from one pool. Assert each environment uses the injected handle and that no child path creates a replacement object. Assert a missing Host binding is rejected before VIO allocations.

- [ ] **Step 2: Run RED**

The test must fail because `virtio_net_env_config` has no Host ID/policy/binding fields and `virtio_net_env` always creates its own manager.

- [ ] **Step 3: Implement binding**

In `build_phase`, select the injected manager when non-null; otherwise create the legacy manager, set its policy, initialize its region, and expose the actual handle through the existing virtual sequencer. Keep all VIO queue/data-plane call sites unchanged. Add a Host ID consistency check between the environment configuration and injected manager metadata.

- [ ] **Step 4: Run GREEN**

Run the binding test and existing VIO unit, fabric-resource, admin-VQ, migration, and data-plane tests. Confirm random policy is active without changing the `host_mem_api` calls.

### Task 6: Complete focused verification and documentation

**Files:**
- Modify: `virtio_net_vip/ext/host_mem/tb/host_mem_random_tb.sv`
- Modify: `scripts/test_manifest.sh`
- Modify: `filelists/tests.f`
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`

- [ ] **Step 1: Add simulator-seed reproducibility checks**

Run the same focused test twice with the same VCS seed and compare the printed allocation sequence. Run with a different seed and require a different sequence when multiple candidates exist. Do not add a seed field to any environment configuration.

- [ ] **Step 2: Add mixed-service shared-object stress**

Use one Host manager and label callers as VIO, RDMA-like, and VBLK-like. Randomly interleave allocations, writes, reads, frees, and reallocation. Use an independent live-range checker to assert no overlap and verify the data pattern before every free.

- [ ] **Step 3: Run the complete Host memory and VIO regression**

Stage the repository to `10.11.10.53`, run the focused test, then run the maintained strict regression. Require VCS exit zero, strict log-check success, no new UVM errors, and clean leak checks.

- [ ] **Step 4: Document operation modes**

Document `HOST_MEM_RANDOM` as the default verification policy, `HOST_MEM_FIRST_FIT` as the stable debug policy, one shared manager per Host, and the fact that this phase does not model IOVA or PCIe DMA translation.
