# Virtio Shared Host-Memory and Advanced Test Design

## Goal

Use the external `host_mem` project as the only Host-memory implementation and
test the complete allocation lifecycle across virtqueue rings, descriptors,
packet buffers, queue reset, and teardown.  The same Host manager must be
shared by all services attached to one Host, while different Hosts remain
isolated.

## Scope

This phase covers the existing VIO/virtio-net verification environment.  RDMA
and VBLK business datapaths remain out of scope, but their future environments
must be able to obtain the same `host_mem_pool` handle.  The phase adds a
dedicated reclamation test and converts the traffic/queue tests to use one
shared Host manager instead of creating a manager in every task.

## Architecture

`virtio_net_vip/ext/host_mem` remains a Git submodule pinned to the external
`Beihang-yuting/host_mem` repository.  The virtio project stores only typed
handles and a test fixture; it does not copy or reimplement the allocator.

At test-top level, `host_mem_pool` owns one `host_mem_manager` per Host.  All
queues and business tests for Host 0 obtain `pool.get_host(0)`.  A future Host 1
gets a separate manager.  Queue tasks never initialize or construct their own
manager.

The reclamation test tracks every ring and data-buffer allocation, checks that
buffers are released after used-ring consumption, checks that reset/destroy
releases ring allocations, and finishes with `leak_check()` on every Host
manager.  The test also exercises randomized allocation policy and repeated
fill/drain cycles.

## Test Layers

1. Shared Host-memory reclamation and fragmentation.
2. Split and packed virtqueue full/empty, wrap, reset, and reuse.
3. Direct and indirect descriptor chains, including invalid ownership cases.
4. `net_packet` multi-queue TX/RX traffic with large packet counts.
5. PCIe/DMA integration and BAR reservation checks after the first four layers
   are stable.

Existing queue, indirect-descriptor, and packet tests remain in the regression
set; this phase changes their memory ownership to use the shared fixture and
adds focused assertions rather than replacing them with a single smoke test.

## Constraints

- Do not add a second Host-memory implementation under `virtio_work`.
- Do not put access tokens in repository files or remote URLs.
- Keep external dependency SHA and origin validation in `scripts/check_deps.sh`.
- Every new test must run through the VCS login-shell flow on host 53.
- A passing test requires zero UVM errors/fatals and a clean Host-memory leak
  check.
