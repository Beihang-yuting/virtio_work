# Virtio Real Driver Full-Flow Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or **superpowers:executing-plans** to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route every maintained virtio-net business/data-plane scenario through the frozen DPU topology, PCIe config/MMIO/notify path, device-side DMA responder, used-ring completion, interrupt/polling, and teardown.

**Architecture:** A reusable `virtio_real_driver_flow_fixture` owns the PCIe-TL env, DPU snapshots, per-Host shared memory, virtio env, and one `virtio_pcie_dut_responder` per active function. The fixture builds the endpoint register image from the snapshot and exposes driver-facing lifecycle/queue/packet tasks. The responder consumes monitor-verified notifies, performs IOVA-checked device accesses, emits PCIe DMA TLPs and MSI-X/INTx events, and never frees driver-owned buffers.

**Tech Stack:** SystemVerilog, UVM 1.2, VCS on `10.11.10.53`, external `dpu_common`, external `host_mem`, external `pcie_tl_vip`, external `net_packet`.

**Spec:** `docs/superpowers/specs/2026-09-06-virtio-real-driver-flow-design.md`

## Global Constraints

- `virtio_net_vip/ext/host_mem` remains the only Host-memory implementation.
- One Host ID uses one `host_mem_manager` from a shared `host_mem_pool`; different Hosts use different managers.
- Function identity, BDF, PCIe domain, and BAR leases come only from the frozen DPU snapshots.
- No business/data-plane test may increment a used index or complete a packet directly from its test task.
- Device completion must follow a monitor-verified notify and a responder DMA operation.
- Existing user changes and external-checkout isolation must be preserved.
- Every task ends with a VCS compile or focused simulation on host 53; no success claim without fresh output.

---

### Task 1: Add a failing golden-flow contract test

**Files:**
- Create: `virtio_net_vip/tests/virtio_real_driver_flow_test.sv`
- Modify: `filelists/tests.f`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Test name: `virtio_real_driver_flow_test`.
- The initial test imports `virtio_real_driver_flow_fixture` and asserts that
  `build_flow()` produces a frozen snapshot, a nonzero resolved BDF, three
  snapshot BAR leases, and one shared Host manager.

- [ ] Write the failing test with these assertions before adding the fixture:

```systemverilog
class virtio_real_driver_flow_test extends uvm_test;
  `uvm_component_utils(virtio_real_driver_flow_test)
  virtio_real_driver_flow_fixture flow;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
  endfunction
  task run_phase(uvm_phase phase);
    string why;
    phase.raise_objection(this);
    if (flow.build_flow(why) == 0)
      `uvm_fatal("REAL_FLOW", why)
    if (!flow.snapshot_is_frozen())
      `uvm_error("REAL_FLOW", "flow snapshot is not frozen")
    if (flow.function_bdf() == 16'h0)
      `uvm_error("REAL_FLOW", "flow did not resolve a function BDF")
    if (flow.bar_count() != 3)
      `uvm_error("REAL_FLOW", "flow did not resolve three BAR pairs")
    if (flow.host_mem() == null)
      `uvm_error("REAL_FLOW", "flow did not expose shared Host memory")
    phase.drop_objection(this);
  endtask
endclass
```

- [ ] Run `TEST=virtio_real_driver_flow_test scripts/vcs.sh --compile-only` on host 53 and
  confirm the expected compile failure names the missing fixture/type.

### Task 2: Implement the shared full-flow fixture and snapshot endpoint image

**Files:**
- Create: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_test.sv`
- Modify: `filelists/tests.f`
- Modify: `virtio_net_vip/src/env/virtio_net_env_config.sv` only if an explicit
  endpoint image binding field is required by the existing config API.

**Interfaces:**
- `function bit build_flow(output string why)`
- `function bit snapshot_is_frozen()`
- `function bit [15:0] function_bdf()`
- `function int unsigned bar_count()`
- `function host_mem_manager host_mem()`
- `function virtio_net_env virtio_env()`
- `function pcie_tl_env pcie_env()`
- `function dpu_device_snapshot device_snapshot()`
- `function dpu_resource_snapshot resource_snapshot()`

- [ ] Add only declarations and a `build_flow()` body that returns 0 with a
  deterministic `"endpoint image not implemented"` diagnostic; rerun the test
  and confirm it now fails at the intended assertion rather than at elaboration.
- [ ] Build the DPU topology with `virtio_test_device_builder`: Host 0/domain 0,
  PF0/BDF from the builder, real DUT BAR roles, one VIO service, one qpair, and
  AF selection. Publish the frozen device/resource snapshots and the seeded
  resource manager through the same config-db keys consumed by
  `virtio_net_env`.
- [ ] Create one `host_mem_pool`, create Host 0 with the configured aperture and
  `HOST_MEM_RANDOM`, and inject the pool into the DPU owner and VIO config.
- [ ] Create the PCIe-TL env in TLM mode with RC and EP agents, completion
  adapter, infinite credit, and scoreboard enabled. Do not assign a test BAR
  base.
- [ ] Resolve the selected function's three BAR leases from the snapshot and
  program the EP config-space Type-0 header, BAR registers, virtio vendor
  capabilities, MSI-X table/PBA capability, and common-config register defaults.
  The capability BAR numbers and offsets must be checked against the lease
  sizes before being installed.
- [ ] Create `virtio_net_env` under the DPU env, bind it to the PCIe RC path,
  and make `end_of_elaboration` expose EP-driver/config-manager handles to the
  transport completion sequences.
- [ ] Make Task 1 pass and assert that no raw test BAR constant appears in the
  fixture.
- [ ] Run the focused test on host 53 and record the compile/run command in the
  plan log.

### Task 3: Add the failing notify-to-DMA responder contract

**Files:**
- Create: `virtio_net_vip/src/pcie/virtio_pcie_dut_responder.sv`
- Modify: `virtio_net_vip/src/agent/virtio_monitor.sv` only if a typed notify
  analysis port is needed in addition to the existing transaction FIFO.
- Modify: `filelists/virtio_net.f`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`

**Interfaces:**
- `function bit bind_function(virtio_monitor monitor,
  virtio_pci_transport transport, virtqueue_manager vq_mgr,
  host_mem_manager mem, virtio_iommu_model iommu,
  pcie_tl_ep_driver ep_driver, output string why)`
- `task start()` and `task stop()`
- `function int unsigned notify_count()`
- `function int unsigned dma_read_count()`
- `function int unsigned dma_write_count()`
- `function int unsigned interrupt_count()`

- [ ] Add a failing golden-flow assertion that one driver kick increments
  `notify_count()` and that no completion is generated before the responder is
  started.
- [ ] Implement a monitor subscriber/consumer that accepts only
  `VIO_TXN_ATOMIC_OP`/`ATOMIC_KICK` events already validated by
  `virtio_monitor.observe_queue_notify()`. Capture queue ID, notify payload,
  queue notify offset, BDF, and Host/domain context.
- [ ] Add queue-state storage populated from common-config writes: queue size,
  descriptor/driver/device ring IOVA, enable state, MSI-X vector, and ring type.
  Reject unknown, disabled, or reset queues without starting a worker.
- [ ] Add IOVA access helpers that call `iommu.translate_for_host(host_id,
  bdf, iova, size, dir, gpa, fault)` for every descriptor, indirect-table,
  buffer, and ring access. On failure, report queue/BDF/IOVA and do not write a
  used entry or interrupt.
- [ ] Add a PCIe DMA transaction backend. For device reads, issue EP-originated
  Memory Read TLPs and consume RC completions; for device writes, issue
  EP-originated Memory Write TLPs. Backing bytes are obtained from the bound
  Host manager only through the PCIe-TL memory backend/translation adapter, not
  by directly completing a descriptor in the test task.
- [ ] Add split-ring TX/RX completion: walk avail entries, read descriptor
  chains, copy TX payload into an RX buffer when a paired RX buffer exists,
  write used entries, and emit the programmed MSI-X Memory Write. Keep the
  responder independent of driver-owned allocation lifetime.
- [ ] Add packed-ring completion with correct AVAIL/USED wrap bits and the same
  DMA/interrupt path.
- [ ] Add reset cancellation and worker accounting; `stop()` must return only
  after all workers have exited.
- [ ] Run the responder unit contract through the golden test and require
  `notify_count()==1`, nonzero DMA counters, and zero unexpected UVM errors.

### Task 4: Implement and verify the golden complete driver flow

**Files:**
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_test.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`
- Modify: `virtio_net_vip/src/transport/virtio_pci_transport.sv` only for
  missing state readback hooks discovered by the test.
- Modify: `virtio_net_vip/src/transport/virtio_notification_manager.sv` only
  for missing MSI-X table/PBA observability.

**Interfaces:**
- `task start_driver_flow(ref bit ok)`
- `task setup_queue(int unsigned queue_id, int unsigned queue_size,
  virtqueue_type_e type, ref bit ok)`
- `task reset_and_teardown(ref bit ok)`

- [ ] Add a red assertion requiring the trace to contain, in order, config
  capability discovery, status reset/ACK/DRIVER, FEATURES_OK readback, queue
  discovery, MSI-X vector programming, DRIVER_OK, queue ring-address writes,
  notify, DMA, used-ring completion, interrupt/poll, and teardown.
- [ ] Implement `start_driver_flow()` with the existing production transport
  path: `discover_and_init_bars()`, `full_init_sequence()`, queue allocation,
  `setup_single_queue()`, and `DRIVER_OK` state validation.
- [ ] Implement `setup_queue()` as a driver operation that allocates rings via
  `virtqueue_manager`, writes queue addresses through common config, enables the
  queue, and registers the queue with the responder. It must not write ring
  memory directly from the test.
- [ ] Drive one TX packet through the driver/atomic path, wait for the responder
  used-ring write and MSI-X completion, then call the normal driver completion
  path and verify the shared Host manager/IOMMU ownership is released.
- [ ] Implement `reset_and_teardown()` as queue reset followed by device reset,
  responder stop, queue ring free, IOVA leak check, and Host-memory leak check.
- [ ] Run `virtio_real_driver_flow_test` on host 53 and require a trace with
  actual resolved absolute BAR/notify addresses and zero outstanding resources.

### Task 5: Migrate traffic and net_packet multi-queue scenarios

**Files:**
- Modify: `virtio_net_vip/tests/virtio_traffic_test.sv`
- Modify: `virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv`
- Modify: `virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv`

**Interfaces:**
- Preserve `+TRAFFIC_PACKETS=N`.
- Add fixture helper `task submit_net_packet(int unsigned queue_id,
  packet_item packet, bit indirect, ref int unsigned desc_id)`.

- [ ] Add a red guard in each test that fails if no responder notify or PCIe
  DMA event was observed for a submitted packet.
- [ ] Replace direct `split_virtqueue` creation in the main traffic path with
  `setup_queue()` for each RX/TX pair. Keep packet generation and integrity
  checks unchanged.
- [ ] Submit TX packets through the real driver atomic operation, let the
  responder consume the notify and write the used ring, then complete through
  `virtio_tx_engine.complete_tx()` so normal unmap/free executes.
- [ ] Refill RX queues through `virtio_rx_engine.refill_buffers()`, inject RX
  payload only after a real queue notify, complete via used ring and MSI-X, and
  parse returned `packet_item` objects from `net_packet`.
- [ ] Run four queues with independent notify offsets/vectors and assert no
  cross-queue completion or buffer ownership leak.
- [ ] Run 1,000 packets and `+TRAFFIC_PACKETS=20000` on host 53; require exact
  submitted/received/data-matched counts and zero Host/IOMMU leaks.

### Task 6: Migrate indirect descriptors and queue/reclaim stress

**Files:**
- Modify: `virtio_net_vip/tests/virtio_indirect_desc_test.sv`
- Modify: `virtio_net_vip/tests/virtio_queue_semantics_test.sv`
- Modify: `virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv`
- Modify: `scripts/test_manifest.sh`

**Interfaces:**
- Existing test names remain stable.
- All tests obtain `host_mem` and `iommu` from the full-flow fixture or its
  shared pool binding.

- [ ] Add a red assertion that an indirect submission produces one real notify,
  one responder descriptor walk, and one used-ring completion.
- [ ] Migrate split and packed indirect cases to negotiated feature setup and
  driver queue setup. Invalid nested, length-overflow, and feature-gate cases
  must fail before responder DMA/interrupt counters increment.
- [ ] Run split full/drain/wrap and packed wrap-bit cycles through enabled
  queues; ring byte inspection may verify state, but completion must originate
  in the responder.
- [ ] Keep randomized alloc/free and fragmentation coverage, but perform the
  queue portion after driver initialization and queue reset. Verify every ring,
  indirect table, SG buffer, packet buffer, IOVA mapping, and responder worker
  is retired.
- [ ] Run the three focused tests independently on host 53, then include them
  in the maintained manifest only after each has zero unexpected UVM errors and
  clean leak checks.

### Task 7: Remove bypasses and document the complete-flow contract

**Files:**
- Modify: `virtio_net_vip/tests/virtio_e2e_test.sv`
- Modify: `virtio_net_vip/tests/virtio_full_test.sv`
- Modify: `virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv` only where a
  private Host manager or direct completion bypass remains.
- Modify: `README.md`
- Modify: `docs/virtio_net_vip_manual.md`
- Modify: `scripts/test_manifest.sh`

- [ ] Add a static manifest check that business tests reference
  `virtio_real_driver_flow_fixture` and do not call a direct device loopback
  helper as their only completion path.
- [ ] Remove fixed BAR constants and duplicate endpoint capability setup from
  `virtio_e2e_test`; call the fixture snapshot image builder instead.
- [ ] Remove private `host_mem_manager::type_id::create()` calls from full-flow
  business tests; use the pool-owned Host manager.
- [ ] Mark pure DPU control-plane and intentionally negative protocol unit tests
  as unit/control-plane in the manifest; document that they do not count as
  full DUT dataplane coverage.
- [ ] Add Chinese comments describing the real flow, ownership boundary,
  notify matching, IOVA translation, MSI-X/PBA handling, and extension hook for
  future RDMA/VBLK service adapters.

### Task 8: Full verification on VCS host 53

**Files:**
- Modify: `docs/virtio_net_vip_manual.md` with exact verified commands/results.

- [ ] Run `scripts/check_deps.sh` with external `DPU_COMMON_ROOT`,
  `HOST_MEM_ROOT`, `PCIE_TL_VIP_ROOT`, and `NET_PACKET_ROOT`.
- [ ] Run `TEST=virtio_real_driver_flow_test scripts/vcs.sh --compile-only` and
  the equivalent `TEST=<name> scripts/vcs.sh --compile-only` commands for E2E, traffic,
  multi-queue, indirect, queue semantics, reclaim, and lifecycle reset.
- [ ] Run `+TRAFFIC_PACKETS=20000` and capture submitted, received, matched,
  notify, DMA, interrupt, and leak counters.
- [ ] Run the maintained regression and inspect logs for `UVM_ERROR`,
  `UVM_FATAL`, IOVA faults, notify mismatches, unexpected completions, and
  Host-memory leak warnings.
- [ ] Verify `git diff --check`, the exact external dependency revisions, and
  that no access token or local DPU source copy was reintroduced.
