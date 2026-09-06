# Virtio Real Driver Full-Flow Verification Design

## Goal

Make every maintained virtio-net business/data-plane test follow the same
PCIe-backed driver flow used by a real virtio-pci driver.  Tests must exercise
the DPU topology published for the function, PCI configuration/capability
discovery, BAR-relative MMIO, queue setup, notify decoding, device DMA,
used-ring completion, MSI-X/INTx or polling, and resource teardown.  Direct
virtqueue manipulation remains available only inside the device responder and
for control-plane/unit tests that explicitly do not claim DUT dataplane
coverage.

## Scope and non-goals

This design covers the existing VIO/virtio-net environment and the external
`host_mem`, `pcie_tl_vip`, and `net_packet` dependencies.  RDMA and VBLK
datapaths are not implemented here; their future environments will consume the
same Host-memory pool and the same PCIe function/endpoint binding interfaces.
The design does not invent unverified production DPU register offsets.  DPU
BAR/BDF/resource placement is consumed from the frozen `dpu_common` snapshots.

`dpu_common` resolver/executor tests remain control-plane tests.  They verify
topology, BAR leases, resource lowering, and executor routing.  All tests that
claim virtio service, queue, descriptor, packet, interrupt, or DMA behavior
must use the full-flow fixture described below.

## Existing gap

`virtio_net_env` already consumes a frozen device/resource snapshot, binds a
shared Host manager and IOMMU, and connects each function to a PCIe RC
sequencer and semantic monitor.  `virtio_pci_transport` already performs the
driver-side reset, feature negotiation, queue discovery, MSI-X setup, queue
address programming, and capability-derived notify writes.

The current regression does not use those facilities consistently:

* `virtio_e2e_test` has a real RC-to-EP TLM path, but its endpoint BAR and
  capability image is assembled from fixed test constants rather than the
  resolved leases, and it has no reusable device-side notify/DMA responder.
* Traffic, multi-queue, indirect-descriptor, and queue stress tests can submit
  directly to `virtqueue` objects and write Host memory without producing the
  PCIe config/MMIO/notify/DMA/interrupt sequence that a driver produces.
* Some older integration tests construct a private `host_mem_manager` instead
  of resolving the manager from the top-level `host_mem_pool`.

Consequently, a passing direct loopback test does not prove that the actual
notify address, queue ID, BDF, BAR mapping, MSI-X vector, or PCIe DMA path is
correct.

## Architecture

### 1. Full-flow fixture

Add a reusable test-level fixture named `virtio_real_driver_flow_fixture`.
It owns and exposes:

* one `dpu_device_env` and its frozen device/resource snapshots;
* one `pcie_tl_env` with the required RC/EP agents;
* one `host_mem_pool`, with one manager per Host ID;
* one `virtio_net_env` bound to the selected snapshot function;
* the PCIe completion adapter and per-function endpoint binding;
* a `virtio_pcie_dut_responder` for each active VIO function.

The fixture creates the DPU topology first.  PF/VF identity, BDF, PCIe domain,
and BAR leases are read from the snapshot; no test is allowed to supply a raw
BDF or BAR base to the transport.  The fixture exposes a small scenario API:

```systemverilog
function bit build_flow(output string why);
task start_driver_flow(ref bit ok);
task setup_queue(int unsigned queue_id, int unsigned queue_size,
                 virtqueue_type_e type, ref bit ok);
task submit_tx(int unsigned queue_id, uvm_object packet,
               bit indirect, ref int unsigned desc_id);
task wait_for_completion(int unsigned queue_id, int unsigned budget,
                         ref uvm_object completed[$]);
task reset_and_teardown(ref bit ok);
```

The fixture API is a driver-facing façade.  It delegates all MMIO and queue
state changes to `virtio_driver`/`virtio_pci_transport`; it does not update
queue indices or Host memory directly on behalf of the driver.

### 2. Snapshot-derived PCIe endpoint image

The fixture programs the PCIe endpoint model from the frozen function view:

* Type-0 header vendor/device/class and the snapshot BDF;
* BAR0/1, BAR2/3, and BAR4/5 bases/sizes from the three DPU BAR leases;
* common-config, notify, ISR, and device-config virtio capabilities;
* notify-off multiplier and per-queue notify offsets;
* MSI-X capability, table BIR/offset, PBA BIR/offset, and vector count.

The endpoint register model must retain the values written through PCIe
common-config MMIO: feature selectors, negotiated features, status, queue
select/size/MSI-X vector, queue descriptor/driver/device addresses, queue
enable/reset, and queue notify offsets.  Reads return this register state, so
the driver observes the same state it programmed.

### 3. Device-side PCIe responder

Add `virtio_pcie_dut_responder` as a testbench-side model of the real DUT
dataplane boundary.  It is not a second driver and it is not a direct queue
loopback helper.  It is driven by the observed PCIe/virtio events:

1. The observer accepts a notify only when the queue is configured and enabled.
2. The responder receives the queue ID and notify payload from the monitor.
3. It reads the queue descriptor/avail data through the queue's device-visible
   IOVA and translates each access with the bound `virtio_iommu_model`.
4. It reads TX buffers or writes RX buffers and used-ring entries through the
   PCIe EP-to-RC DMA request path.  The responder must emit the corresponding
   PCIe Memory Read/Completion or Memory Write TLPs; it must not call
   `host_mem.read_mem()` as a substitute for a DMA transaction in a test that
   claims PCIe dataplane coverage.
5. It reads the programmed MSI-X table entry and emits the MSI-X Memory Write
   to the configured message address/data.  INTx and polling are selected only
   when the driver/transport negotiated those modes.
6. Reset or queue reset stops outstanding responder work and releases any
   responder-owned temporary state.  Driver-owned descriptor buffers are
   released only when the driver polls the used ring and unmaps/frees them.

The responder is intentionally protocol-neutral about future RDMA/VBLK
payload formats.  Its queue descriptor, DMA, interrupt, and ownership hooks
are reusable; VIO-net packet parsing is supplied by a service-specific adapter
that can use `net_packet`.

### 4. Single complete driver sequence

Every virtio business test starts with the following sequence:

```text
frozen DPU topology
  -> PCIe config/BDF/BAR image
  -> capability discovery
  -> device reset
  -> ACKNOWLEDGE | DRIVER
  -> feature negotiation and FEATURES_OK readback
  -> queue count/size/notify-off discovery
  -> MSI-X table/PBA programming and vector binding
  -> DRIVER_OK
  -> queue ring allocation and common-config ring-address writes
  -> queue enable
  -> descriptor/indirect-table allocation in shared Host memory
  -> notify BAR write with queue-specific notify_off
  -> responder DMA read/write over PCIe
  -> used-ring update and MSI-X/INTx/poll notification
  -> driver completion, IOVA unmap, and Host buffer free
  -> queue reset/device reset
  -> queue, IOVA, responder, and Host-memory leak checks
```

No scenario may mark a packet or descriptor complete by incrementing a used
index directly from the test task.  The only component allowed to complete a
submission is the responder after it has consumed a real notify and performed
the corresponding DMA operation.

## Scenario migration

The migration keeps stable test names where possible:

* `virtio_e2e_test` becomes the golden single-queue flow and validates the
  fixture, endpoint image, notify address, queue addresses, and MSI-X path.
* `virtio_traffic_test` runs large traffic through the fixture.  The existing
  `+TRAFFIC_PACKETS=N` override remains.  TX/RX buffers are allocated by the
  real dataplane path, completed by the responder, and reclaimed by the driver.
* `virtio_net_packet_multi_queue_test` creates four queues through driver queue
  setup and uses `net_packet` items on the TX/RX service adapter.  The test
  checks per-queue notify offsets, per-queue vectors, and cross-queue data
  integrity.
* `virtio_indirect_desc_test` negotiates `VIRTIO_F_RING_INDIRECT_DESC`, writes
  indirect tables through the driver-owned Host allocations, and lets the
  responder walk those tables through IOVA.  Invalid nested/length/feature
  cases still use the same driver entry point and must fail before a PCIe DMA
  completion is generated.
* `virtio_queue_semantics_test` and `virtio_host_mem_reclaim_test` keep their
  allocator and wraparound stress, but setup, notify, completion, queue reset,
  and final leak checks run after the full driver initialization.  They are
  allowed to inspect ring bytes for assertions, but not to synthesize device
  completion without a responder event.
* Older `virtio_full_test` and duplicate E2E setup code are reduced to calls
  into the fixture.  Any private Host manager or fixed BAR image is removed.

Pure control-plane tests in `dpu_common` and intentionally negative protocol
unit tests remain separate and are labeled as such in the manifest.  They do
not count as DUT dataplane coverage.

## Error and ownership rules

* A missing or non-frozen snapshot, mismatched BDF/domain, missing BAR lease,
  capability outside its BAR, or duplicate Host manager binding is fatal during
  fixture construction.
* A notify for an unknown/disabled queue is rejected by the observer and must
  not start responder DMA or an interrupt.
* An IOVA translation failure, direction violation, DMA outside the Host
  aperture, MSI-X table/PBA mismatch, or used-ring index corruption is a test
  failure and is reported with Host/BDF/queue context.
* Test-owned packet buffers, descriptor tables, and ring allocations are
  released by the normal driver completion/reset path.  The responder never
  frees driver-owned allocations.
* One Host uses one shared manager from the external `host_mem_pool`; another
  Host uses a separate manager.  Numeric GPA equality across different Hosts
  is not a collision.

## Verification and acceptance criteria

The implementation is accepted only when all of the following are observed on
VCS host 53:

1. The full-flow golden test compiles with the external `dpu_common` and
   `host_mem` checkouts and reports zero unexpected UVM errors/fatals.
2. Logs show config-space capability discovery, resolved BDF/BAR addresses,
   queue ring-address writes, queue-specific notify absolute addresses, DMA
   reads/writes, and MSI-X/INTx or polling completion.
3. Single-queue, four-queue, indirect-descriptor, and large-traffic scenarios
   preserve packet/descriptor integrity and complete through the responder.
4. Reset and teardown leave zero outstanding Host allocations, zero outstanding
   IOVA mappings, and no live responder workers.
5. A negative notify, invalid indirect table, or bad DMA mapping is rejected
   before a completion/interrupt is generated.
6. The maintained manifest distinguishes control-plane unit tests from
   full-flow virtio business tests, and the manual documents the exact flow and
   extension points for future RDMA/VBLK environments.

