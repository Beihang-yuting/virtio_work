# Virtio Shared Host-Memory Tests Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reuse the external `host_mem` implementation through one shared manager per Host and add meaningful queue, descriptor, packet, and memory-reclamation coverage.

**Architecture:** A test-level `host_mem_pool` owns Host managers; traffic and queue tests receive the Host handle instead of constructing managers in individual tasks.  Existing advanced tests are retained and strengthened with explicit ownership/reclamation checks.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS on host 53, external `host_mem` Git submodule, existing virtio/net_packet VIPs.

**Spec:** `docs/superpowers/specs/2026-09-06-virtio-shared-host-memory-tests-design.md`

## Global Constraints

- `virtio_net_vip/ext/host_mem` is the only Host-memory implementation.
- Same Host ID uses one shared `host_mem_manager`; different Host IDs use different managers.
- Do not reset or overwrite unrelated user changes in the dirty worktree.
- Verify every completed task with VCS compile/test output before claiming success.

### Task 1: Establish a reusable traffic Host-memory fixture

**Files:**
- Create: `virtio_net_vip/tests/virtio_shared_mem_fixture.sv`
- Modify: `filelists/tests.f`
- Test: `virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv`

**Interfaces:**
- Produces `virtio_shared_mem_fixture::create_host()` and
  `virtio_shared_mem_fixture::get_host(int unsigned host_id)`.
- The fixture owns only `host_mem_pool`; allocator implementation remains in
  the external submodule.

- [ ] Write a focused test that creates Host 0 and Host 1 through the fixture,
  obtains handles twice, and verifies repeated Host 0 lookups return the same
  object while Host 1 is a different object.
- [ ] Compile the focused test and confirm it fails before the fixture exists.
- [ ] Implement the fixture with one pool, configurable aperture/policy, and
  idempotent setup guard.  Use `host_mem_pool::create_host()` exactly once per
  Host.
- [ ] Compile and run the focused test on host 53; require zero UVM errors and
  zero leak warnings after teardown.

### Task 2: Add dedicated Host-memory reclamation coverage

**Files:**
- Create: `virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Test name: `virtio_host_mem_reclaim_test`.
- Uses the fixture from Task 1 and the existing `split_virtqueue`,
  `packed_virtqueue`, `virtio_iommu_model`, and `virtqueue_manager` classes.

- [ ] Add a failing assertion for repeated split-ring fill/drain followed by
  `free_rings()` and `host_mem.leak_check()`.
- [ ] Implement randomized buffer sizes and alignments, explicitly retain each
  allocated GPA, free it only after used-ring completion, and free every queue
  ring during reset and destroy.
- [ ] Add a second Host allocation pass and verify Host 0/Host 1 address reuse
  is independent; do not treat equal numeric GPAs across Hosts as a collision.
- [ ] Add the test to the maintained manifest and compile/run it on host 53.

### Task 3: Convert large traffic to shared Host memory

**Files:**
- Modify: `virtio_net_vip/tests/virtio_traffic_test.sv`
- Modify: `filelists/tests.f`
- Modify: `README.md`

**Interfaces:**
- `+TRAFFIC_PACKETS=N` remains the traffic-count override.
- `virtio_traffic_test` obtains the Host manager from the shared fixture and
  does not call `host_mem_manager::type_id::create()` inside traffic tasks.

- [ ] Replace the test-only protected-counter subclass and private `lt_mem`
  construction with the shared Host handle.
- [ ] Track TX/RX buffer GPAs and free them after used-ring consumption; free
  all rings after the final batch.
- [ ] Extend queue-stress and mixed split/packed paths to free their data
  buffers, not only their rings.
- [ ] Run 1,000 packets and then `+TRAFFIC_PACKETS=20000` on host 53; require
  clean packet counts, data integrity, and Host-memory leak check.
- [ ] Document the traffic plusarg and reclamation expectations.

### Task 4: Strengthen descriptor and queue regression coverage

**Files:**
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv`
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`
- Modify: `virtio_net_vip/tests/virtio_queue_semantics_test.sv` (create if the
  current queue stress coverage is insufficient)
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Existing test names remain stable.
- New queue test, if needed, is named `virtio_queue_semantics_test`.

- [ ] Add split-ring wrap/full/empty and reset/reuse checks with the shared Host
  manager.
- [ ] Add packed-ring wrap-bit and descriptor-reuse checks.
- [ ] Add indirect-table lifetime and invalid-flag/length checks, followed by
  explicit table and buffer cleanup.
- [ ] Extend net_packet multi-queue traffic to a configurable packet count and
  verify all four queues reclaim descriptors and buffers.
- [ ] Compile and run each changed test independently before adding it to the
  full regression.

### Task 5: Verification and documentation checkpoint

**Files:**
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`

- [ ] Run `scripts/check_deps.sh` with the pinned external `host_mem` checkout.
- [ ] Run focused tests on host 53, then the maintained regression list.
- [ ] Check logs for `UVM_ERROR`, `UVM_FATAL`, `HOST_MEM` leak warnings, and
  descriptor/IOMMU failures.
- [ ] Record exact commands and results in the documentation.
- [ ] Review the final diff and leave unrelated user changes untouched.
