# Virtio-Net Driver UVM VIP Design Spec

**Date:** 2026-04-23
**Status:** Pending Review
**Scope:** UVM virtio-net driver verification component, PCIe TL layer, DPU/SmartNIC DUT

---

## 1. Overview

A UVM-based verification component that simulates a complete guest OS virtio-net driver, targeting DPU/SmartNIC virtio hardware acceleration engines. The component works at the PCIe Transaction Layer, integrating with the existing `pcie_tl_vip` (as subenv), `host_mem_manager` (memory backend), and `net_packet` (protocol packet generator).

### 1.1 Design Principles

- Dual-layer driver model: atomic operation library (manual) + automatic state machine (auto), runtime switchable
- Three virtqueue implementations via abstract base class: split, packed, custom (user-extensible)
- Full SR-IOV support with PF/VF management, reusing `pcie_tl_vip`'s `func_manager`
- All waits use poll-with-timeout or event-with-timeout via `wait_policy`; no bare `#delay` allowed
- All fork blocks are named; `disable <block_name>` only, never `disable fork`
- External components integrated without modification via interface adapters

### 1.2 Supported Virtio Specification

- virtio 1.2 / 1.3
- Split virtqueue + Packed virtqueue + Custom descriptor format
- Full feature set (configurable per-test via feature mask)

### 1.3 External Component Dependencies

| Component | Location | Role | Integration |
|-----------|----------|------|-------------|
| `pcie_tl_vip` | `/ryan/pcie_work/pcie_tl_vip` | PCIe TL subenv (RC/EP agents, func_manager, SR-IOV) | Subenv, zero modification |
| `host_mem_manager` | `/ryan/shm_work/host_mem` | Buddy allocator for descriptor rings and data buffers | Shared instance |
| `net_packet` | `/ryan/shm_work/net_packet` | Protocol packet generator (L2-L4, tunnels, RDMA) | `packet_item` UVM wrapper |

---

## 2. Architecture

```
virtio_net_env (top-level)
|
+-- pf_manager (simplified)
|   +-- ref: pcie_tl_env.func_manager        <-- reuse PCIe PF/VF management
|   +-- virtio_vf_resource_pool              <-- virtio-specific queue mapping
|   +-- admin_vq                             <-- PF admin virtqueue (1.2+)
|   +-- failover_manager                     <-- STANDBY/failover
|
+-- vf_instances[N]                          <-- one per VF (or PF in non-SRIOV mode)
|   +-- virtio_driver_agent                  <-- core UVM agent
|   |   +-- virtio_driver                    <-- dual-layer: auto_fsm + atomic_ops
|   |   +-- virtio_monitor                   <-- passive TLP observation
|   |   +-- virtio_sequencer
|   +-- virtqueue_manager                    <-- queue set for this VF
|   |   +-- split_virtqueue / packed_virtqueue / custom_virtqueue
|   +-- virtio_net_dataplane
|   |   +-- tx_engine                        <-- net_packet integration
|   |   +-- rx_engine                        <-- buffer merge + parse
|   |   +-- offload_engine                   <-- csum/TSO/USO/RSS
|   +-- virtio_pci_transport
|   |   +-- pci_cap_manager                  <-- virtio capability discovery
|   |   +-- bar_accessor                     <-- BAR R/W -> PCIe TLP
|   |   +-- notification_manager             <-- MSI-X/INTx/polling/adaptive
|   +-- virtio_net_config                    <-- per-VF feature/config
|
+-- iommu_model                              <-- GPA->IOVA mapping + permissions + fault injection
+-- wait_policy                              <-- unified timeout/polling framework
+-- perf_monitor                             <-- latency profiling + bandwidth limiting
+-- error_injector                           <-- unified error injection controller
+-- virtio_scoreboard                        <-- data/protocol/offload/DMA verification
+-- virtio_coverage                          <-- 8 covergroups, lazy construction
+-- concurrency_controller                   <-- multi-VF parallel ops + race injection
+-- dynamic_reconfig                         <-- live MQ/MTU/IRQ/MAC/VLAN changes
|
+-- host_mem_manager (external)              <-- /ryan/shm_work/host_mem
+-- net_packet (external)                    <-- /ryan/shm_work/net_packet
+-- pcie_tl_env (subenv)                     <-- /ryan/pcie_work/pcie_tl_vip
|
+-- virtio_virtual_sequencer
    +-- pf_seqr
    +-- vf_seqrs[N]
    +-- pcie_rc_seqr
```

### 2.1 Key Design Decisions

1. **VF instances are dynamically created** based on `num_vfs` config (0 = pure PF mode, PF itself acts as virtio-net device)
2. **SR-IOV PF/VF management is delegated to `pcie_tl_vip`'s `func_manager`** -- virtio layer only manages virtio-specific state (queue mapping, feature negotiation, driver lifecycle)
3. **Three external components integrated without modification** via reference injection
4. **Custom virtqueue + dataplane/scoreboard/coverage callbacks** for vendor-specific descriptor format extensions

---

## 3. Feature Set

### 3.1 Mandatory (always enabled)

- `VIRTIO_NET_F_MAC`
- `VIRTIO_F_VERSION_1`
- `VIRTIO_F_ACCESS_PLATFORM` (IOMMU)

### 3.2 Data Plane Features (configurable)

| Feature | Description |
|---------|-------------|
| `VIRTIO_NET_F_MRG_RXBUF` | Multi-buffer merge receive |
| `VIRTIO_NET_F_MQ` + `CTRL_MQ` | Multi-queue with ctrl vq RSS/pair config |
| `VIRTIO_NET_F_CSUM` / `GUEST_CSUM` | Hardware checksum offload |
| `VIRTIO_NET_F_HOST_TSO4/6` / `GUEST_TSO4/6` | TCP segmentation offload |
| `VIRTIO_NET_F_HOST_UFO` / `GUEST_UFO` | UDP fragmentation offload |
| `VIRTIO_NET_F_GSO` | Generic segmentation offload |
| `VIRTIO_NET_F_RSS` / `HASH_REPORT` | RSS distribution + hash reporting (1.1+) |
| `VIRTIO_F_RING_PACKED` | Packed virtqueue support |
| `VIRTIO_F_RING_INDIRECT_DESC` | Indirect descriptor tables |
| `VIRTIO_F_EVENT_IDX` | Event index notification suppression |
| `VIRTIO_F_IN_ORDER` | In-order completion (packed queue) |
| `VIRTIO_F_NOTIFICATION_DATA` | Extended kick data with avail index (1.2+) |
| `VIRTIO_NET_F_GUEST_USO4/6` | UDP segmentation offload (1.2+) |

### 3.3 Control Plane Features (configurable)

| Feature | Description |
|---------|-------------|
| `CTRL_VQ` + `CTRL_RX` | Promisc/allmulti/unicast/multicast filter |
| `CTRL_VLAN` | VLAN filter |
| `CTRL_ANNOUNCE` / `STATUS` | Link up/down notification, gratuitous ARP |
| `VIRTIO_NET_F_MTU` / `SPEED_DUPLEX` | MTU and speed/duplex reporting |
| `CTRL_MAC_TABLE` | Unicast/multicast MAC table management |

### 3.4 Advanced Features

| Feature | Description |
|---------|-------------|
| `VIRTIO_NET_F_STANDBY` | Failover between primary and standby VFs |
| `VIRTIO_F_RING_RESET` | Per-queue reset (1.2+) |
| SR-IOV | Full PF/VF lifecycle, per-VF independent feature negotiation |
| Admin VQ | PF-level management queue for VF control (1.2+) |
| Live Migration | Freeze/restore queue state + dirty page tracking |

---

## 4. Type Definitions

### 4.1 Enumerations

```systemverilog
typedef enum { VQ_SPLIT, VQ_PACKED, VQ_CUSTOM } virtqueue_type_e;
typedef enum { VQ_RESET, VQ_CONFIGURE, VQ_ENABLED } virtqueue_state_e;

typedef enum bit [7:0] {
    DEV_STATUS_RESET              = 8'h00,
    DEV_STATUS_ACKNOWLEDGE        = 8'h01,
    DEV_STATUS_DRIVER             = 8'h02,
    DEV_STATUS_FEATURES_OK        = 8'h08,
    DEV_STATUS_DRIVER_OK          = 8'h04,
    DEV_STATUS_DEVICE_NEEDS_RESET = 8'h40,
    DEV_STATUS_FAILED             = 8'h80
} device_status_e;

typedef enum { DRV_MODE_AUTO, DRV_MODE_MANUAL, DRV_MODE_HYBRID } driver_mode_e;
typedef enum { RX_MODE_MERGEABLE, RX_MODE_BIG, RX_MODE_SMALL } rx_buf_mode_e;
typedef enum { IRQ_MSIX_PER_QUEUE, IRQ_MSIX_SHARED, IRQ_INTX, IRQ_POLLING } interrupt_mode_e;
typedef enum { DMA_TO_DEVICE, DMA_FROM_DEVICE, DMA_BIDIRECTIONAL } dma_dir_e;

typedef enum {
    FSM_IDLE, FSM_RESETTING, FSM_DISCOVERING, FSM_NEGOTIATING,
    FSM_QUEUE_SETUP, FSM_MSIX_SETUP, FSM_READY, FSM_RUNNING,
    FSM_SUSPENDING, FSM_FROZEN, FSM_ERROR, FSM_RECOVERING
} fsm_state_e;

typedef enum { VF_CREATED, VF_CONFIGURED, VF_ACTIVE, VF_FLR, VF_DISABLED } vf_state_e;
typedef enum { FO_NORMAL, FO_PRIMARY_DOWN, FO_SWITCHING, FO_STANDBY_ACTIVE, FO_FAILBACK } failover_state_e;

typedef enum {
    IOMMU_NO_FAULT, IOMMU_FAULT_UNMAPPED, IOMMU_FAULT_PERMISSION,
    IOMMU_FAULT_OUT_OF_RANGE, IOMMU_FAULT_DEVICE_ABORT, IOMMU_FAULT_PAGE_NOT_PRESENT
} iommu_fault_e;

typedef enum {
    // Descriptor chain errors
    VQ_ERR_CIRCULAR_CHAIN, VQ_ERR_OOB_INDEX, VQ_ERR_ZERO_LEN_BUF,
    VQ_ERR_KICK_BEFORE_ENABLE, VQ_ERR_AVAIL_IDX_SKIP, VQ_ERR_WRONG_FLAGS,
    VQ_ERR_INDIRECT_IN_INDIRECT, VQ_ERR_DESC_UNALIGNED,
    // Memory barrier errors
    VQ_ERR_SKIP_WMB_BEFORE_AVAIL, VQ_ERR_SKIP_RMB_BEFORE_USED, VQ_ERR_SKIP_MB_BEFORE_KICK,
    // Descriptor lifecycle errors
    VQ_ERR_DOUBLE_FREE_DESC, VQ_ERR_USE_AFTER_FREE_DESC, VQ_ERR_STALE_DESC,
    VQ_ERR_DETACH_WHILE_ACTIVE,
    // Ring operation errors
    VQ_ERR_AVAIL_RING_OVERFLOW, VQ_ERR_USED_RING_CORRUPT, VQ_ERR_WRONG_USED_LEN,
    // DMA/IOMMU errors
    VQ_ERR_USE_AFTER_UNMAP, VQ_ERR_WRONG_DMA_DIR,
    VQ_ERR_IOMMU_FAULT_ON_DESC, VQ_ERR_IOMMU_FAULT_ON_DATA,
    // Packed queue specific
    VQ_ERR_WRONG_WRAP_COUNTER, VQ_ERR_AVAIL_USED_FLAG_CORRUPT,
    // Notification errors
    VQ_ERR_KICK_AFTER_DISABLE, VQ_ERR_SPURIOUS_INTERRUPT, VQ_ERR_EVENT_IDX_BACKWARD
} virtqueue_error_e;

typedef enum {
    VIO_TXN_INIT, VIO_TXN_RESET, VIO_TXN_SHUTDOWN,
    VIO_TXN_SEND_PKTS, VIO_TXN_WAIT_PKTS, VIO_TXN_START_DP, VIO_TXN_STOP_DP,
    VIO_TXN_CTRL_CMD, VIO_TXN_SET_MQ, VIO_TXN_SET_RSS,
    VIO_TXN_ATOMIC_OP,
    VIO_TXN_FREEZE, VIO_TXN_RESTORE,
    VIO_TXN_RESET_QUEUE, VIO_TXN_SETUP_QUEUE,
    VIO_TXN_INJECT_ERROR
} virtio_txn_type_e;

typedef enum {
    SCB_ERR_DATA_MISMATCH, SCB_ERR_CSUM_MISMATCH, SCB_ERR_GSO_SIZE_EXCEED,
    SCB_ERR_FEATURE_VIOLATION, SCB_ERR_SPURIOUS_NOTIFY, SCB_ERR_MISSED_NOTIFY,
    SCB_ERR_DMA_OOB, SCB_ERR_DMA_DIR_MISMATCH, SCB_ERR_DMA_AFTER_UNMAP,
    SCB_ERR_ORDERING_VIOLATION, SCB_ERR_CONFIG_INCONSISTENT, SCB_ERR_UNEXPECTED_RX
} scb_error_e;

typedef enum {
    RACE_BETWEEN_KICK_AND_IRQ, RACE_DURING_QUEUE_RESET,
    RACE_BETWEEN_AVAIL_AND_KICK, RACE_DURING_CONFIG_CHANGE,
    RACE_BETWEEN_MAP_AND_DESC, RACE_DURING_FEATURE_NEGOTIATION, RACE_DURING_FLR
} race_point_e;

typedef enum {
    FAULT_PHASE_DESC_READ, FAULT_PHASE_DATA_READ,
    FAULT_PHASE_DATA_WRITE, FAULT_PHASE_USED_WRITE
} iommu_fault_phase_e;

typedef enum {
    STATUS_ERR_SKIP_ACKNOWLEDGE, STATUS_ERR_SKIP_DRIVER,
    STATUS_ERR_SKIP_FEATURES_OK, STATUS_ERR_DRIVER_OK_BEFORE_FEATURES_OK,
    STATUS_ERR_WRITE_AFTER_FAILED
} status_error_e;

typedef enum {
    FEAT_ERR_PARTIAL_WRITE_LO_ONLY, FEAT_ERR_PARTIAL_WRITE_HI_ONLY,
    FEAT_ERR_WRONG_SELECT_VALUE, FEAT_ERR_USE_UNNEGOTIATED_FEATURE,
    FEAT_ERR_CHANGE_AFTER_FEATURES_OK
} feature_error_e;

typedef enum {
    QSETUP_ERR_ENABLE_BEFORE_ADDR, QSETUP_ERR_SIZE_EXCEEDS_MAX,
    QSETUP_ERR_SIZE_NOT_POWER_OF_2, QSETUP_ERR_ADDR_UNALIGNED,
    QSETUP_ERR_ENABLE_TWICE, QSETUP_ERR_SELECT_OOB_QUEUE
} queue_setup_error_e;
```

### 4.2 Structures

```systemverilog
typedef struct { bit [63:0] addr; int unsigned len; } virtio_sg_entry;
typedef struct { virtio_sg_entry entries[$]; } virtio_sg_list;

typedef struct {
    int unsigned desc_id, len;
    realtime submit_time, complete_time;
} virtio_used_info;

typedef struct {
    int unsigned queue_id, queue_size;
    bit [63:0] desc_addr, driver_addr, device_addr;
    int unsigned last_avail_idx, last_used_idx;
    bit avail_wrap, used_wrap;
    byte unsigned ring_data[];
} virtqueue_snapshot_t;

typedef struct {
    bit [15:0] bdf; bit [63:0] gpa, iova;
    int unsigned size; dma_dir_e dir; int unsigned desc_id;
} iommu_mapping_t;

typedef struct {
    bit [15:0] bdf; bit [63:0] gpa, iova;
    int unsigned size; dma_dir_e dir; bit valid;
    realtime map_time; string caller_file; int caller_line;
} iommu_mapping_entry_t;

typedef struct {
    bit [15:0] bdf_mask; bit [63:0] iova_start, iova_end;
    dma_dir_e dir; iommu_fault_e fault_type;
    int unsigned trigger_count, triggered;
} iommu_fault_rule_t;

typedef struct {
    bit [7:0] flags, gso_type;
    bit [15:0] hdr_len, gso_size, csum_start, csum_offset;
    bit [15:0] num_buffers;
    bit [31:0] hash_value; bit [15:0] hash_report;
} virtio_net_hdr_t;

typedef struct {
    bit [47:0] mac; bit [15:0] status, max_virtqueue_pairs, mtu;
    bit [31:0] speed; bit [7:0] duplex, rss_max_key_size;
    bit [15:0] rss_max_indirection_table_length; bit [31:0] supported_hash_types;
} virtio_net_device_config_t;

typedef struct {
    bit [7:0] cap_id, cap_next, cfg_type, bar;
    bit [31:0] offset, length;
} virtio_pci_cap_t;

typedef struct { bit [63:0] msg_addr; bit [31:0] msg_data; bit masked; } msix_entry_t;

typedef struct {
    int unsigned hash_key_size; byte unsigned hash_key[];
    int unsigned indirection_table[]; bit [31:0] hash_types;
} virtio_rss_config_t;

typedef struct {
    int unsigned num_queue_pairs, queue_size;
    virtqueue_type_e vq_type; bit [63:0] driver_features;
    rx_buf_mode_e rx_buf_mode; int unsigned rx_buf_size, rx_refill_threshold;
    interrupt_mode_e irq_mode; int unsigned napi_budget, coal_max_packets, coal_max_usecs;
    bit bw_limit_enable; int unsigned bw_limit_mbps; driver_mode_e mode;
} virtio_driver_config_t;

typedef struct {
    realtime desc_fill_time, kick_time, device_start_time, device_done_time;
    realtime interrupt_time, poll_time, complete_time;
} pkt_latency_t;

typedef struct {
    longint unsigned tx_packets, tx_bytes, rx_packets, rx_bytes;
    realtime start_time, end_time;
} perf_stats_t;

typedef struct {
    int unsigned tx_sent, tx_matched, tx_mismatched;
    int unsigned rx_received, rx_matched, rx_mismatched;
    int unsigned csum_errors, gso_errors, feature_errors, notify_errors;
    int unsigned dma_errors, ordering_errors, unexpected_rx;
} scoreboard_stats_t;
```

### 4.3 Common Config Register Offsets

```systemverilog
parameter VIRTIO_PCI_COMMON_DFSELECT      = 12'h00;
parameter VIRTIO_PCI_COMMON_DF            = 12'h04;
parameter VIRTIO_PCI_COMMON_GFSELECT      = 12'h08;
parameter VIRTIO_PCI_COMMON_GF            = 12'h0C;
parameter VIRTIO_PCI_COMMON_MSIX          = 12'h10;
parameter VIRTIO_PCI_COMMON_NUMQ          = 12'h12;
parameter VIRTIO_PCI_COMMON_STATUS        = 12'h14;
parameter VIRTIO_PCI_COMMON_CFGGENERATION = 12'h15;
parameter VIRTIO_PCI_COMMON_Q_SELECT      = 12'h16;
parameter VIRTIO_PCI_COMMON_Q_SIZE        = 12'h18;
parameter VIRTIO_PCI_COMMON_Q_MSIX        = 12'h1A;
parameter VIRTIO_PCI_COMMON_Q_ENABLE      = 12'h1C;
parameter VIRTIO_PCI_COMMON_Q_NOFF        = 12'h1E;
parameter VIRTIO_PCI_COMMON_Q_DESCLO      = 12'h20;
parameter VIRTIO_PCI_COMMON_Q_DESCHI      = 12'h24;
parameter VIRTIO_PCI_COMMON_Q_AVAILLO     = 12'h28;
parameter VIRTIO_PCI_COMMON_Q_AVAILHI     = 12'h2C;
parameter VIRTIO_PCI_COMMON_Q_USEDLO      = 12'h30;
parameter VIRTIO_PCI_COMMON_Q_USEDHI      = 12'h34;
parameter VIRTIO_PCI_COMMON_Q_NDATA       = 12'h38;
parameter VIRTIO_PCI_COMMON_Q_RESET       = 12'h3A;
```

---

## 5. Wait Policy Framework

All waits in the VIP use `virtio_wait_policy`. No bare `#delay` is allowed. All fork blocks must be named; only `disable <block_name>` is used, never `disable fork`.

### 5.1 Timeout Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `default_poll_interval_ns` | 10 | Poll interval for register reads |
| `default_timeout_ns` | 10000 (10us) | Default timeout |
| `flr_timeout_ns` | 10000 (10us) | VF FLR completion |
| `reset_timeout_ns` | 5000 (5us) | Device reset completion |
| `queue_reset_timeout_ns` | 5000 (5us) | Per-queue reset completion |
| `vf_ready_timeout_ns` | 10000 (10us) | VF ready after SR-IOV enable |
| `cpl_timeout_ns` | 5000 (5us) | PCIe completion timeout |
| `status_change_timeout_ns` | 5000 (5us) | Device status change |
| `rx_wait_timeout_ns` | 50000 (50us) | RX packet wait |
| `timeout_multiplier` | 1 | Global multiplier for stress tests |
| `max_poll_attempts` | 10000 | Absolute max poll count (deadlock guard) |

### 5.2 Wait Methods

Three wait primitives, all with dual protection (time + count):

1. **`poll_reg_until()`** -- poll BAR register until `(read_val & mask) == (expected & mask)` or timeout. `poll_interval_ns` clamped to minimum 1.
2. **`poll_config_until()`** -- poll config space register until match or timeout.
3. **`wait_event_or_timeout()`** -- wait for named UVM event or timeout, using **named fork block** (`fork : blk_name ... join_any; disable blk_name`).

### 5.3 Safety Rules

- `poll_interval_ns` clamped to minimum 1 to prevent infinite loop
- `max_poll_attempts` caps loop iterations even if timeout arithmetic overflows
- All effective timeouts computed via `base_ns * timeout_multiplier`
- All wait methods log success with `UVM_HIGH` and failure with `uvm_error`
- All `forever` background tasks check a `running` flag and respond to `stop_event`

### 5.4 Named Fork Block Rule

```systemverilog
// CORRECT: named fork block
fork : my_wait_block
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable my_wait_block;

// FORBIDDEN: bare disable fork
fork
    begin evt.wait_trigger(); end
    begin #(timeout * 1ns); end
join_any
disable fork;  // KILLS ALL child processes in calling thread
```

---

## 6. Virtqueue Abstraction Layer

### 6.1 Abstract Base Class (`virtqueue_base`)

Pure virtual methods that split/packed/custom must implement:

| Category | Methods |
|----------|---------|
| Lifecycle | `alloc_rings()`, `free_rings()`, `reset_queue()`, `detach_all_unused(ref tokens[$])` |
| Driver ops | `add_buf(sgs[], n_out_sgs, n_in_sgs, token, indirect) -> desc_id`, `kick()`, `poll_used(ref token, ref len) -> bit` |
| Notification | `disable_cb()`, `enable_cb()`, `enable_cb_delayed()`, `vq_poll(last_used) -> bit` |
| DMA | `dma_map_buf(gpa, size, dir) -> iova`, `dma_unmap_buf(iova)` |
| Query | `get_free_count()`, `get_pending_count()`, `needs_notification() -> bit` |
| Error injection | `inject_desc_error(err_type)` |
| Migration | `save_state(ref snap)`, `restore_state(snap)` |

Common state: `queue_id`, `global_queue_id`, `queue_size`, ring addresses, `token_map[desc_id]`, `dma_mappings[$]`, references to `host_mem_manager`, `iommu_model`, `memory_barrier_model`, `virtqueue_error_injector`, `wait_policy`.

### 6.2 Split Virtqueue

Memory layout per queue (allocated from `host_mem_manager`):

- Descriptor Table: 16 bytes x queue_size (align 4096)
  - `addr[63:0]`, `len[31:0]`, `flags[15:0]` (NEXT/WRITE/INDIRECT), `next[15:0]`
- Available Ring: 6 + 2 x queue_size bytes (align 2)
  - `flags[15:0]`, `idx[15:0]`, `ring[queue_size]`, `used_event[15:0]`
- Used Ring: 6 + 8 x queue_size bytes (align 4096)
  - `flags[15:0]`, `idx[15:0]`, `ring[queue_size] = {id[31:0], len[31:0]}`, `avail_event[15:0]`

Internal state: `free_head`, `last_used_idx`, `num_free`, `desc_state[queue_size]`.

### 6.3 Packed Virtqueue

Single descriptor ring: 16 bytes x queue_size. Each entry: `addr[63:0]`, `len[31:0]`, `id[15:0]`, `flags[15:0]` (AVAIL/USED/WRITE/NEXT/INDIRECT).

Driver/Device Event Suppression structures (4 bytes each).

Internal state: `next_avail_idx`, `next_used_idx`, `avail_wrap_counter`, `used_wrap_counter`, `in_order_completion` (for `VIRTIO_F_IN_ORDER` fast path).

### 6.4 Custom Virtqueue

User provides: `desc_entry_size`, `desc_field_defs[]`, `virtqueue_custom_callback` with overrides for ring alloc/add_buf/poll_used. Helper methods: `write_desc_field(idx, field, value)`, `read_desc_field(idx, field)`.

### 6.5 host_mem Collaboration Flow

```
alloc_rings():
  desc_table_addr = host_mem.alloc(entry_size * queue_size, align=4096)
  driver_ring_addr = host_mem.alloc(avail_ring_size, align=2)
  device_ring_addr = host_mem.alloc(used_ring_size, align=4096)
  host_mem.mem_set(all addrs, 0)  ->  init free descriptor list

add_buf(sgs, n_out, n_in, token, indirect):
  take descriptors from free list
  per sg: host_mem.alloc() -> iommu.map() -> write descriptor via host_mem.write_mem()
  update available ring, memory barrier, record submit_time

poll_used(ref token, ref len):
  host_mem.read_mem(used idx) -> check new entries -> read {id, len}
  recover token, reclaim descriptors, iommu.unmap(), host_mem.free()
  record complete_time
```

### 6.6 Queue Number Control

- Without `MQ`: fixed 3 queues (receiveq_0, transmitq_0, controlq)
- With `MQ`: `2 * num_pairs + 1`, set via `CTRL_MQ_VQ_PAIRS_SET`
- `num_queues` read from Common Config to validate against device limit
- SR-IOV: each VF has independent queue set, `global_queue_id` managed by `vf_resource_pool`

### 6.7 Per-Queue Reset (`VIRTIO_F_RING_RESET`, 1.2+)

1. Write `queue_reset` bit
2. `wait_policy.poll_reg_until()` until device clears the bit
3. Reconfigure or disable; other queues unaffected

### 6.8 Migration

- `save_state()`: dump ring memory, indices, wrap counters
- `restore_state()`: allocate new memory, restore content, rebuild internal state
- `detach_all_unused()`: reclaim all outstanding descriptors/tokens for FLR/reset cleanup

---

## 7. Virtio PCI Transport Layer

### 7.1 Components

- **pci_cap_manager**: discover virtio PCI capabilities (cfg_type 1-5) + MSI-X from config space linked list
- **bar_accessor**: BAR MMIO R/W -> PCIe Memory TLPs via `pcie_tl_env` RC Agent sequencer; config R/W -> PCIe Config TLPs
- **notification_manager**: MSI-X/INTx/polling/adaptive, NAPI control, three-level IRQ fallback (per-queue MSI-X -> shared MSI-X -> INTx)

### 7.2 Device Initialization Sequence

Strict order per virtio spec:

1. `reset_device()`: write status=0, `poll_reg_until(status==0)`
2. `write_status(ACKNOWLEDGE)` -> `write_status(ACKNOWLEDGE|DRIVER)`
3. `read_device_features()`: select=0 low32, select=1 high32
4. `write_driver_features()`: select=0 low32, select=1 high32
5. `write_status(|FEATURES_OK)`, `poll_reg_until(FEATURES_OK still set)`
6. Per-queue: `select_queue` -> `read_queue_num_max` -> `write_queue_size` -> allocate rings -> write desc/avail/used addr -> `read_queue_notify_off` -> set MSI-X vector -> enable
7. Setup MSI-X vectors, bind config change vector
8. `write_status(|DRIVER_OK)`
9. Any failure -> `write_status(|FAILED)`

### 7.3 Config Generation Check

Device config reads loop: read `config_generation` before/after, retry if changed.

### 7.4 Notification / Kick

- Standard: write `queue_id` to `notify_base + queue_notify_off * multiplier`
- `NOTIFICATION_DATA`: write 32-bit `{avail_idx/wrap_counter, vqn}`
- `queue_notify_off` read per-queue from Common Config, not assumed equal to `queue_id`

### 7.5 Error Injection

Categories: status transition errors, feature negotiation errors, config generation skip, queue setup errors, notification errors (spurious/missed/wrong vector).

---

## 8. Virtio Driver Agent

### 8.1 Dual-Layer Architecture

- **Atomic ops library**: one method per real driver operation (reset, set_status, setup_queue, tx_submit, rx_receive, ctrl_send, etc.)
- **Auto FSM**: complete lifecycle state machine (IDLE -> DISCOVERING -> NEGOTIATING -> QUEUE_SETUP -> MSIX_SETUP -> READY -> RUNNING)
- **Mode selection**: AUTO / MANUAL / HYBRID, runtime switchable

### 8.2 Auto FSM Background Tasks

All run inside named fork block `dataplane_tasks`, check `dataplane_running` flag, exit on `stop_event`:
- `rx_refill_loop()`, `tx_complete_loop()`, `interrupt_handler_loop()`, `adaptive_irq_loop()`, `config_change_handler()`

Stopped via `dataplane_running = 0; -> stop_event; disable dataplane_tasks`.

### 8.3 Transaction-Driven Driver

`virtio_driver` extends `uvm_driver #(virtio_transaction)`, dispatches by `txn_type`:
- Lifecycle: INIT, RESET, SHUTDOWN
- Data plane: SEND_PKTS, WAIT_PKTS, START_DP, STOP_DP
- Control: CTRL_CMD, SET_MQ, SET_RSS
- Atomic: ATOMIC_OP (manual mode)
- Migration: FREEZE, RESTORE
- Queue: RESET_QUEUE, SETUP_QUEUE
- Error: INJECT_ERROR

### 8.4 Monitor

Passive observation via `pcie_tl_env` monitor analysis port. Reconstructs virtio semantics from TLPs (BAR writes -> register ops, notify writes -> kicks, DMA -> descriptor/data access, MSI-X -> interrupts). Protocol checks: status transitions, feature usage, queue protocol, notification, DMA compliance.

---

## 9. Data Plane

### 9.1 TX Engine

Flow: `build_net_hdr()` -> offload check (TSO/USO segmentation) -> `standard_tx_build_chain()` or `custom_cb` -> `vq.add_buf()` -> `kick()` if `needs_notification()`.

Standard chain: `[net_hdr sg] [pkt_data sg]`, each allocated from `host_mem` and mapped via `iommu`. Completion: `poll_used()` -> recover token -> unmap -> free.

### 9.2 RX Engine

Three modes: Mergeable (small buffers + `num_buffers` merge), Big (single large buffer), Small (single page). Auto-refill when free count below threshold. Offload verification on received packets.

### 9.3 Offload Engine

- **csum_engine**: pseudo header checksum for TX, full verify for RX
- **tso_engine**: TCP segmentation with IP/TCP header updates
- **uso_engine**: UDP segmentation (1.2+)
- **rss_engine**: Toeplitz hash, indirection table lookup, queue selection

### 9.4 Failover Manager

States: NORMAL -> PRIMARY_DOWN -> SWITCHING -> STANDBY_ACTIVE. Gratuitous ARP via CTRL_ANNOUNCE. Metrics: loss count, switch time.

---

## 10. PF Manager and SR-IOV

### 10.1 pcie_tl_vip Reuse (no reimplementation)

Delegated to `pcie_tl_func_manager`: PF/VF context, BDF calculation, VF enable/disable, per-VF config space, BDF lookup, VF BAR state, SR-IOV Capability registers.

### 10.2 Virtio-Layer PF Manager

- References `pcie_tl_func_manager` directly
- `virtio_vf_resource_pool`: local_qid <-> global_qid mapping
- `failover_manager`: STANDBY feature
- `admin_vq`: PF admin queue (1.2+)
- VF lifecycle: create `virtio_vf_instance` per VF, configure with BDF/BAR from `func_context`

### 10.3 VF FLR

1. Virtio: `on_flr()` (detach, cleanup DMA)
2. PCIe: Config Write FLR bit
3. `poll_config_until()` VF accessible
4. Optional reinit

---

## 11. IOMMU Model

- `map(bdf, gpa, size, dir) -> iova`, `unmap(bdf, iova)`, `translate(bdf, iova, size, dir) -> {gpa, fault}`
- Permission checking (configurable strict mode)
- Fault injection via `iommu_fault_rule_t` (BDF mask, IOVA range, direction, trigger count)
- Use-after-unmap detection via `unmap_history`
- Dirty page tracking for migration
- Leak check in `report_phase`

---

## 12. Scoreboard

8 independently switchable checks: data integrity, offload correctness, queue protocol, feature compliance, notification, DMA compliance, ordering, config consistency.

Custom callback `virtio_scoreboard_callback` for vendor-specific comparison.

Report: match/mismatch counts, error breakdown, unmatched TX (leak), unexpected RX.

---

## 13. Coverage

8 covergroups (lazy construction, all default OFF): Features, Queue Ops, Data Plane, Offload, Notification, Errors, Lifecycle, SR-IOV.

Custom callback `virtio_coverage_callback` for user-registered covergroups.

---

## 14. Performance Monitor

- Bandwidth limiting: synchronous token bucket via `sync_refill()` (no background task)
- Latency profiling: 7-stage per-packet timestamps, min/max/avg/p50/p95/p99 report
- Per-VF and global statistics

---

## 15. Concurrency and Dynamic Reconfiguration

### 15.1 Concurrency Controller

- `parallel_vf_op()`: per-VF independent timeout, named fork blocks
- `inject_race_window()`: delay at specific race points
- `test_flr_isolation()`, `test_queue_reset_isolation()`

### 15.2 Dynamic Reconfiguration

Live operations (with `traffic_active` flag): MQ resize, MTU change, IRQ mode switch, MAC change, VLAN update, RSS update.

---

## 16. Sequence Library

### 16.1 Structure

```
seq/base/          -- atomic sequences (init, tx, rx, ctrl, kick, queue_setup)
seq/scenario/
  lifecycle/       -- full lifecycle, status errors, feature errors
  dataplane/       -- TSO, MRG_RXBUF, RSS, checksum, tunnel
  interrupt/       -- adaptive IRQ, event_idx boundary
  migration/       -- live migration, failover
  sriov/           -- multi-VF init, FLR isolation, mixed queue types
  error/           -- descriptor errors, IOMMU faults, PCIe cross errors, bad packets
  concurrency/     -- multi-VF parallel traffic
  dynamic/         -- live MQ resize
  boundary/        -- min/max queue, max chain, indirect full, backpressure, zero-len
seq/virtual/       -- smoke, full traffic, multi-VF, stress
```

---

## 17. Top-Level Configuration

`virtio_net_env_config` fields:

| Category | Parameters |
|----------|-----------|
| Topology | `num_vfs`, `max_vfs` |
| Per-VF | `vf_configs[]` |
| Defaults | `default_num_pairs`, `default_queue_size`, `default_vq_type`, `default_driver_features`, `default_rx_mode`, `default_irq_mode`, `default_napi_budget` |
| PCIe | `pf_bdf`, `pcie_if_mode` |
| Memory | `mem_base`, `mem_end` |
| IOMMU | `iommu_strict` |
| Performance | `bw_limit_enable`, `bw_limit_mbps` |
| Verification | `scb_enable`, `cov_enable` |
| Failover | `failover_enable`, `primary_vf_id`, `standby_vf_id` |

---

## 18. Callback Extension Points

| Callback | Purpose | Used By |
|----------|---------|---------|
| `virtqueue_custom_callback` | Custom ring alloc/add_buf/poll_used | `custom_virtqueue` |
| `virtio_dataplane_callback` | Custom TX chain, RX parse, net_hdr format | `tx_engine`, `rx_engine` |
| `virtio_scoreboard_callback` | Custom comparison, field extraction | `virtio_scoreboard` |
| `virtio_coverage_callback` | Custom covergroup sampling | `virtio_coverage` |

---

## 19. File Structure

```
virtio_net_vip/
+-- src/
|   +-- virtio_net_pkg.sv
|   +-- types/ (3 files)
|   +-- virtqueue/ (6 files)
|   +-- transport/ (5 files)
|   +-- dataplane/ (9 files)
|   +-- agent/ (6 files)
|   +-- sriov/ (3 files)
|   +-- iommu/ (1 file)
|   +-- shared/ (2 files: wait_policy, memory_barrier_model)
|   +-- env/ (8 files)
|   +-- callbacks/ (3 files)
|   +-- seq/
|       +-- base/ (7 files)
|       +-- scenario/ (22 files across 9 subdirs)
|       +-- virtual/ (4 files)
+-- tests/ (3 files)
+-- ext/
    +-- host_mem -> /ryan/shm_work/host_mem
    +-- net_packet -> /ryan/shm_work/net_packet
    +-- pcie_tl_vip -> /ryan/pcie_work/pcie_tl_vip
```

Total: ~65 source files.
