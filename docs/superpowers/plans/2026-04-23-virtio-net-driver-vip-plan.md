# Virtio-Net Driver UVM VIP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a UVM virtio-net driver VIP that simulates a complete guest OS driver at the PCIe TL layer, targeting DPU/SmartNIC verification.

**Architecture:** Layered env (virtio_net_env > vf_instances > driver_agent/virtqueue/transport/dataplane) with pcie_tl_env as subenv, host_mem_manager for memory, net_packet for protocol packets. Split/packed/custom virtqueue via strategy pattern. Dual-layer driver: atomic ops + auto FSM.

**Tech Stack:** SystemVerilog, UVM 1.2+, pcie_tl_vip (existing), host_mem_manager (existing), net_packet (existing)

**Spec:** `docs/superpowers/specs/2026-04-23-virtio-net-driver-vip-design.md`

---

## Phase Summary

| Phase | Tasks | Key Deliverables | Dependencies |
|-------|-------|-----------------|--------------|
| 1 | 1-3 | Package skeleton, types, wait_policy, memory_barrier | None |
| 2 | 4 | IOMMU model | Phase 1 |
| 3 | 5-8 | Virtqueue base + split + packed + custom + manager | Phase 1+2 |
| 4 | 9-12 | PCI transport (regs, cap_mgr, bar_accessor, notification, transport) | Phase 1 |
| 5 | 13-16 | Callbacks, transaction, driver agent (atomic_ops, auto_fsm, driver, monitor) | Phase 3+4 |
| 6 | 17-21 | Data plane (csum, tso, uso, rss, offload, tx, rx, failover, dataplane) | Phase 3+5 |
| 7 | 22-24 | SR-IOV (resource_pool, vf_instance, pf_manager) | Phase 5 |
| 8 | 25-29 | Env assembly (config, scoreboard, coverage, perf, concurrency, dynamic, env) | Phase 5+6+7 |
| 9 | 30-34 | Sequence library (base, scenario, virtual) | Phase 8 |
| 10 | 35-37 | Tests and integration (base_test, smoke_test, tb_top) | All |

---

## Phase 1: Foundation — Package, Types, Shared Utilities

### Task 1: Project skeleton and package

**Files:**
- Create: `virtio_net_vip/src/virtio_net_pkg.sv`
- Create: `virtio_net_vip/ext/` (symlinks)

- [ ] **Step 1: Create directory structure**

```bash
cd /home/ubuntu/ryan/virtio_work
mkdir -p virtio_net_vip/src/{types,virtqueue,transport,dataplane,agent,sriov,iommu,shared,env,callbacks}
mkdir -p virtio_net_vip/src/seq/{base,scenario/{lifecycle,dataplane,interrupt,migration,sriov,error,concurrency,dynamic,boundary},virtual}
mkdir -p virtio_net_vip/tests
mkdir -p virtio_net_vip/ext
```

- [ ] **Step 2: Create symlinks to external components**

```bash
cd /home/ubuntu/ryan/virtio_work/virtio_net_vip/ext
ln -s /home/ubuntu/ryan/shm_work/host_mem host_mem
ln -s /home/ubuntu/ryan/shm_work/net_packet net_packet
ln -s /home/ubuntu/ryan/pcie_work/pcie_tl_vip pcie_tl_vip
```

- [ ] **Step 3: Write initial package file**

Create `virtio_net_vip/src/virtio_net_pkg.sv` with `package virtio_net_pkg`, importing `uvm_pkg` and `host_mem_pkg`, and including all source files in dependency order per spec Section 19. Start with only Phase 1 includes uncommented; comment out later phases until those files exist.

- [ ] **Step 4: Commit**

```bash
git init
git add virtio_net_vip/
git commit -m "feat: project skeleton with package and external symlinks"
```

**Acceptance:** Directory structure exists, symlinks resolve, package file compiles with Phase 1 includes only.

---

### Task 2: Type definitions

**Files:**
- Create: `virtio_net_vip/src/types/virtio_net_types.sv`
- Create: `virtio_net_vip/src/types/virtio_net_hdr.sv`

- [ ] **Step 1: Write virtio_net_types.sv**

All enums, structs, typedefs, and feature bit parameters from spec Section 4. Contents:

Feature bit parameters (per virtio spec numbering):
```systemverilog
parameter int VIRTIO_NET_F_CSUM = 0;
parameter int VIRTIO_NET_F_GUEST_CSUM = 1;
// ... (full list per spec Section 4.1)
parameter int VIRTIO_F_RING_PACKED = 34;
parameter int VIRTIO_F_IN_ORDER = 35;
parameter int VIRTIO_F_NOTIFICATION_DATA = 38;
parameter int VIRTIO_F_RING_RESET = 40;
```

Net HDR constants:
```systemverilog
parameter bit [7:0] VIRTIO_NET_HDR_F_NEEDS_CSUM = 8'h01;
parameter bit [7:0] VIRTIO_NET_HDR_F_DATA_VALID = 8'h02;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_NONE     = 8'h00;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_TCPV4    = 8'h01;
parameter bit [7:0] VIRTIO_NET_HDR_GSO_UDP_L4   = 8'h05;
// ... (full list)
```

Descriptor flags:
```systemverilog
parameter bit [15:0] VIRTQ_DESC_F_NEXT     = 16'h0001;
parameter bit [15:0] VIRTQ_DESC_F_WRITE    = 16'h0002;
parameter bit [15:0] VIRTQ_DESC_F_INDIRECT = 16'h0004;
```

Control VQ classes/commands/ack:
```systemverilog
parameter bit [7:0] VIRTIO_NET_CTRL_RX = 8'h00;
// ... (full list)
parameter bit [7:0] VIRTIO_NET_OK  = 8'h00;
parameter bit [7:0] VIRTIO_NET_ERR = 8'h01;
```

All enumerations from spec Section 4.1:
```systemverilog
typedef enum { VQ_SPLIT, VQ_PACKED, VQ_CUSTOM } virtqueue_type_e;
typedef enum { VQ_RESET, VQ_CONFIGURE, VQ_ENABLED } virtqueue_state_e;
typedef enum bit [7:0] { DEV_STATUS_RESET = 8'h00, ... } device_status_e;
// ... (all enums: driver_mode_e, rx_buf_mode_e, interrupt_mode_e, dma_dir_e,
//      fsm_state_e, vf_state_e, failover_state_e, iommu_fault_e,
//      virtqueue_error_e, virtio_txn_type_e, virtio_atomic_op_e,
//      scb_error_e, race_point_e, iommu_fault_phase_e,
//      status_error_e, feature_error_e, queue_setup_error_e,
//      virtio_ctrl_ack_e, virtio_ctrl_class_e)
```

All structs from spec Section 4.2:
```systemverilog
typedef struct { bit [63:0] addr; int unsigned len; } virtio_sg_entry;
typedef struct { virtio_sg_entry entries[$]; } virtio_sg_list;
// ... (all structs: virtio_used_info, virtqueue_snapshot_t, iommu_mapping_t,
//      iommu_mapping_entry_t, iommu_fault_rule_t, virtio_net_hdr_t,
//      virtio_net_device_config_t, virtio_pci_cap_t, msix_entry_t,
//      virtio_rss_config_t, virtio_driver_config_t, pkt_latency_t,
//      perf_stats_t, scoreboard_stats_t, queue_mapping_t,
//      virtio_device_snapshot_t)
```

- [ ] **Step 2: Write virtio_net_hdr.sv**

`virtio_net_hdr_util` class with static methods:
- `get_hdr_size(features) -> int`: returns 10/12/20 based on MRG_RXBUF/HASH_REPORT
- `pack_hdr(hdr, features, ref data[$])`: serialize to byte array (little-endian)
- `unpack_hdr(data[$], features, ref hdr)`: deserialize from byte array

```systemverilog
class virtio_net_hdr_util;
    static function int unsigned get_hdr_size(bit [63:0] features);
        if (features[VIRTIO_NET_F_HASH_REPORT]) return 20;
        else if (features[VIRTIO_NET_F_MRG_RXBUF]) return 12;
        else return 10;
    endfunction

    static function void pack_hdr(virtio_net_hdr_t hdr, bit [63:0] features, ref byte unsigned data[$]);
        // ... serialize fields to little-endian bytes
    endfunction

    static function void unpack_hdr(byte unsigned data[$], bit [63:0] features, ref virtio_net_hdr_t hdr);
        // ... deserialize from little-endian bytes
    endfunction
endclass
```

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/types/
git commit -m "feat: type definitions - enums, structs, feature bits, net_hdr utilities"
```

**Acceptance:** All enums and structs compile. `virtio_net_hdr_util` pack/unpack round-trips correctly.

---

### Task 3: Wait policy and memory barrier model

**Files:**
- Create: `virtio_net_vip/src/shared/virtio_wait_policy.sv`
- Create: `virtio_net_vip/src/shared/virtio_memory_barrier_model.sv`

- [ ] **Step 1: Write virtio_wait_policy.sv**

Per spec Section 5. Key implementation:

```systemverilog
class virtio_wait_policy extends uvm_object;
    // Timeout config (all in ns, per spec Section 5.1 table)
    int unsigned default_poll_interval_ns = 10;
    int unsigned default_timeout_ns       = 10000;   // 10us
    int unsigned flr_timeout_ns           = 10000;   // 10us
    int unsigned reset_timeout_ns         = 5000;    // 5us
    int unsigned queue_reset_timeout_ns   = 5000;    // 5us
    int unsigned vf_ready_timeout_ns      = 10000;   // 10us
    int unsigned cpl_timeout_ns           = 5000;    // 5us
    int unsigned status_change_timeout_ns = 5000;    // 5us
    int unsigned rx_wait_timeout_ns       = 50000;   // 50us
    int unsigned timeout_multiplier       = 1;
    int unsigned max_poll_attempts        = 10000;

    function int unsigned effective_timeout(int unsigned base_ns);
        return base_ns * timeout_multiplier;
    endfunction

    // CRITICAL: All fork blocks MUST be named. Never use bare `disable fork`.
    task wait_event_or_timeout(string description, uvm_event evt,
                               int unsigned timeout_ns, ref bit triggered);
        int unsigned eff_timeout = effective_timeout(timeout_ns);
        triggered = 0;
        fork : wait_evt_blk
            begin evt.wait_trigger(); triggered = 1; end
            begin #(eff_timeout * 1ns); end
        join_any
        disable wait_evt_blk;  // named block only
        if (!triggered)
            `uvm_error("WAIT_POLICY", $sformatf("%s: timeout after %0dns", description, eff_timeout))
    endtask
endclass
```

Safety rules enforced:
- `poll_interval_ns` clamped to min 1
- `max_poll_attempts` caps iterations
- All `effective_timeout()` applies multiplier
- Success logged at UVM_HIGH, failure at uvm_error

- [ ] **Step 2: Write virtio_memory_barrier_model.sv**

```systemverilog
class virtio_memory_barrier_model extends uvm_object;
    bit skip_wmb_before_avail = 0;
    bit skip_rmb_before_used  = 0;
    bit skip_mb_before_kick   = 0;
    int unsigned wmb_count=0, rmb_count=0, mb_count=0, skipped_count=0;

    function void wmb(string ctx = "");  // smp_wmb after desc write, before avail update
    function void rmb(string ctx = "");  // smp_rmb before reading used ring
    function void mb(string ctx = "");   // smp_mb after avail update, before kick check
    function void inject_barrier_skip(virtqueue_error_e err_type);
    function void clear_all_skips();
    function void print_stats();
endclass
```

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/shared/
git commit -m "feat: wait_policy framework and memory barrier model"
```

**Acceptance:** Both classes compile. wait_policy named fork block pattern verified.

---

## Phase 2: IOMMU Model

### Task 4: IOMMU model

**Files:**
- Create: `virtio_net_vip/src/iommu/virtio_iommu_model.sv`

- [ ] **Step 1: Write virtio_iommu_model.sv**

Per spec Section 11. Key methods:

```systemverilog
class virtio_iommu_model extends uvm_object;
    bit strict_permission_check = 1;
    bit fault_inject_enable = 0;
    bit dirty_tracking_enable = 0;

    // map(bdf, gpa, size, dir) -> iova: allocate IOVA, create mapping
    function bit [63:0] map(bit [15:0] bdf, bit [63:0] gpa, int unsigned size,
                            dma_dir_e dir, string file="", int line=0);

    // unmap(bdf, iova): remove mapping, save to unmap_history
    function void unmap(bit [15:0] bdf, bit [63:0] iova, string file="", int line=0);

    // translate(bdf, iova, size, dir) -> {gpa, fault}: lookup + range + permission check
    function bit translate(bit [15:0] bdf, bit [63:0] iova, int unsigned size,
                           dma_dir_e access_dir, ref bit [63:0] gpa, ref iommu_fault_e fault);

    // Fault injection
    function void add_fault_rule(iommu_fault_rule_t rule);
    function void clear_fault_rules();

    // Use-after-unmap detection via unmap_history
    function bit check_use_after_unmap(bit [15:0] bdf, bit [63:0] iova);

    // Dirty page tracking for migration
    function void mark_dirty(bit [63:0] gpa, int unsigned size);
    function void get_and_clear_dirty(ref bit [63:0] dirty_pages[$]);

    // Leak check in report_phase
    function void leak_check();
endclass
```

Internal storage: `mapping_table[{bdf,iova}]`, `unmap_history[$]`, `dirty_bitmap[gpa_page]`, bump IOVA allocator.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/iommu/
git commit -m "feat: IOMMU model with map/unmap/translate, fault injection, dirty tracking"
```

**Acceptance:** map -> translate -> unmap round-trip works. Fault injection triggers correctly. Leak check detects outstanding mappings.

---

## Phase 3: Virtqueue Abstraction Layer

### Task 5: Virtqueue error injector

**Files:**
- Create: `virtio_net_vip/src/virtqueue/virtqueue_error_injector.sv`

- [ ] **Step 1: Write virtqueue_error_injector.sv**

```systemverilog
class virtqueue_error_injector extends uvm_object;
    bit inject_enable = 0;
    virtqueue_error_e err_type;
    int unsigned inject_after_n_ops = 0;
    int unsigned target_queue_id = 0;
    int unsigned inject_probability = 100;

    function void configure(virtqueue_error_e err, int unsigned after_n=0,
                            int unsigned qid=0, int unsigned prob=100);
    function void disable_injection();
    function bit should_inject(int unsigned current_queue_id);
    function void reset_counter();
    function void print_history();
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/virtqueue/virtqueue_error_injector.sv
git commit -m "feat: virtqueue error injector with configurable triggers"
```

---

### Task 6: Virtqueue abstract base class

**Files:**
- Create: `virtio_net_vip/src/virtqueue/virtqueue_base.sv`

- [ ] **Step 1: Write virtqueue_base.sv**

Per spec Section 6.1. Virtual class with pure virtual methods:

```systemverilog
virtual class virtqueue_base extends uvm_object;
    int unsigned queue_id, global_queue_id, queue_size;
    bit [63:0] desc_table_addr, driver_ring_addr, device_ring_addr;
    host_mem_manager mem;
    virtio_iommu_model iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector err_inj;
    virtio_wait_policy wait_pol;
    bit [15:0] bdf;
    virtqueue_state_e state = VQ_RESET;
    protected uvm_object token_map[int unsigned];
    protected iommu_mapping_t dma_mappings[$];

    virtual function void setup(int unsigned qid, int unsigned size, ...);

    // Pure virtual: lifecycle, driver ops, notification, DMA, query, error, migration
    pure virtual function void alloc_rings();
    pure virtual function void free_rings();
    pure virtual function void reset_queue();
    pure virtual function void detach_all_unused(ref uvm_object tokens[$]);
    pure virtual function int unsigned add_buf(virtio_sg_list sgs[], int unsigned n_out_sgs,
                                                int unsigned n_in_sgs, uvm_object token, bit indirect);
    pure virtual task kick();
    pure virtual function bit poll_used(ref uvm_object token, ref int unsigned len);
    pure virtual function void disable_cb();
    pure virtual function void enable_cb();
    pure virtual function void enable_cb_delayed();
    pure virtual function bit vq_poll(int unsigned last_used);
    pure virtual function int unsigned get_free_count();
    pure virtual function int unsigned get_pending_count();
    pure virtual function bit needs_notification();
    pure virtual function bit [63:0] dma_map_buf(bit [63:0] gpa, int unsigned size, dma_dir_e dir);
    pure virtual function void dma_unmap_buf(bit [63:0] iova);
    pure virtual function void inject_desc_error(virtqueue_error_e err_type);
    pure virtual function void save_state(ref virtqueue_snapshot_t snap);
    pure virtual function void restore_state(virtqueue_snapshot_t snap);

    // Common: dump_ring(), leak_check()
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/virtqueue/virtqueue_base.sv
git commit -m "feat: virtqueue abstract base class"
```

---

### Task 7: Split virtqueue implementation

**Files:**
- Create: `virtio_net_vip/src/virtqueue/split_virtqueue.sv`

- [ ] **Step 1: Write split_virtqueue.sv**

Per spec Section 6.2. ~400-500 lines. Key implementation:

```systemverilog
class split_virtqueue extends virtqueue_base;
    // Internal state
    protected int unsigned free_head;
    protected int unsigned last_used_idx;
    protected int unsigned num_free;
    protected bit [15:0] desc_next[int unsigned];  // free list chain

    function void alloc_rings();
        // Desc: 16 * queue_size, align 4096
        // Avail: 6 + 2*queue_size, align 2
        // Used: 6 + 8*queue_size, align 4096
        // Initialize free list: desc[i].next = i+1
    endfunction

    function int unsigned add_buf(virtio_sg_list sgs[], ...);
        // Take n descriptors from free list
        // Write each desc entry: addr, len, flags (NEXT chain), next
        // Write avail ring[avail_idx % queue_size] = head
        // barrier.wmb()
        // Increment avail_idx, write to host_mem
        // barrier.mb()
        // Store token in token_map[head]
    endfunction

    function bit poll_used(ref uvm_object token, ref int unsigned len);
        // barrier.rmb()
        // Read used_idx from host_mem
        // If new entries: read {id, len} from used ring
        // Recover token from token_map[id]
        // Reclaim descriptors back to free list
    endfunction

    function bit needs_notification();
        // EVENT_IDX: compare avail_idx vs used_event
        // Non-EVENT_IDX: check VIRTQ_USED_F_NO_NOTIFY flag
    endfunction
endclass
```

Memory layout for descriptor entry (16 bytes, little-endian):
```
Offset 0:  addr[63:0]    (8 bytes)
Offset 8:  len[31:0]     (4 bytes)
Offset 12: flags[15:0]   (2 bytes)
Offset 14: next[15:0]    (2 bytes)
```

Avail ring layout:
```
Offset 0: flags[15:0]
Offset 2: idx[15:0]
Offset 4: ring[0..queue_size-1] (each 16-bit)
Offset 4+2*queue_size: used_event[15:0] (if EVENT_IDX)
```

Used ring layout:
```
Offset 0: flags[15:0]
Offset 2: idx[15:0]
Offset 4: ring[0..queue_size-1] = {id[31:0], len[31:0]} (each 8 bytes)
Offset 4+8*queue_size: avail_event[15:0] (if EVENT_IDX)
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/virtqueue/split_virtqueue.sv
git commit -m "feat: split virtqueue - descriptor table, avail/used ring management"
```

**Acceptance:** alloc_rings allocates from host_mem. add_buf writes correct descriptor layout. poll_used reads used ring correctly.

---

### Task 8: Packed virtqueue, custom virtqueue, and manager

**Files:**
- Create: `virtio_net_vip/src/virtqueue/packed_virtqueue.sv`
- Create: `virtio_net_vip/src/virtqueue/custom_virtqueue.sv`
- Create: `virtio_net_vip/src/virtqueue/virtqueue_manager.sv`

- [ ] **Step 1: Write packed_virtqueue.sv**

Per spec Section 6.3. Single ring, AVAIL/USED flags, wrap counter:

```systemverilog
class packed_virtqueue extends virtqueue_base;
    protected int unsigned next_avail_idx;
    protected int unsigned next_used_idx;
    protected bit avail_wrap_counter;
    protected bit used_wrap_counter;
    protected bit in_order_completion;

    // Packed descriptor: 16 bytes per entry, single ring
    // addr[63:0], len[31:0], id[15:0], flags[15:0]
    // AVAIL flag (bit 7), USED flag (bit 15), WRITE (bit 1), NEXT (bit 0), INDIRECT (bit 2)

    function void alloc_rings();
        // Single ring: 16 * queue_size, align 4096
        // Driver Event Suppression: 4 bytes
        // Device Event Suppression: 4 bytes
    endfunction

    function int unsigned add_buf(...);
        // Write desc at next_avail_idx with AVAIL=avail_wrap_counter, USED=!avail_wrap_counter
        // Chain with NEXT flag if multiple descriptors
        // Wrap: if next_avail_idx reaches queue_size, reset to 0, flip avail_wrap_counter
    endfunction

    function bit poll_used(...);
        // Check desc at next_used_idx: if USED flag matches used_wrap_counter -> used
        // IN_ORDER: process sequentially without scanning
    endfunction
endclass
```

- [ ] **Step 2: Write custom_virtqueue.sv**

Per spec Section 6.4:

```systemverilog
class custom_virtqueue extends virtqueue_base;
    int unsigned desc_entry_size = 16;
    string desc_field_defs[];
    virtqueue_custom_callback cb;

    // Delegate to user callback for ring ops
    function void alloc_rings();
        if (cb != null) cb.custom_alloc_rings(this);
    endfunction

    function int unsigned add_buf(...);
        if (cb != null) return cb.custom_add_buf(this, sgs, n_out_sgs, n_in_sgs, token, indirect);
        return 0;
    endfunction

    // Helper methods for callback implementations
    function void write_desc_field(int unsigned idx, string field, bit [63:0] value);
    function bit [63:0] read_desc_field(int unsigned idx, string field);
endclass

// Callback base class (in callbacks/ dir, but defined here for reference)
virtual class virtqueue_custom_callback extends uvm_object;
    pure virtual function void custom_alloc_rings(custom_virtqueue vq);
    pure virtual function int unsigned custom_add_buf(custom_virtqueue vq, ...);
    pure virtual function bit custom_poll_used(custom_virtqueue vq, ...);
endclass
```

- [ ] **Step 3: Write virtqueue_manager.sv**

```systemverilog
class virtqueue_manager extends uvm_object;
    protected virtqueue_base queues[int unsigned];
    // Shared refs: mem, iommu, barrier, err_inj, wait_pol, bdf

    function virtqueue_base create_queue(int unsigned qid, int unsigned size, virtqueue_type_e vq_type);
        // Factory create by type, setup(), store in queues[]
    endfunction

    function virtqueue_base get_queue(int unsigned qid);
    function void destroy_queue(int unsigned qid);
    function void destroy_all();
    function void detach_all_queues();
    function int unsigned get_queue_count();
    function void leak_check();
endclass
```

- [ ] **Step 4: Commit**

```bash
git add virtio_net_vip/src/virtqueue/packed_virtqueue.sv
git add virtio_net_vip/src/virtqueue/custom_virtqueue.sv
git add virtio_net_vip/src/virtqueue/virtqueue_manager.sv
git commit -m "feat: packed/custom virtqueue and queue manager"
```

**Acceptance:** All three virtqueue types can be created via manager. Split and packed alloc_rings produce correct memory layouts.

---

## Phase 4: PCI Transport Layer

### Task 9: PCI register offsets

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_pci_regs.sv`

- [ ] **Step 1: Write virtio_pci_regs.sv**

All Common Config register offsets from spec Section 4.3:

```systemverilog
parameter VIRTIO_PCI_COMMON_DFSELECT      = 12'h00;
parameter VIRTIO_PCI_COMMON_DF            = 12'h04;
// ... (all 18 registers through Q_RESET = 12'h3A)
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_pci_regs.sv
git commit -m "feat: virtio PCI common config register offsets"
```

---

### Task 10: PCI capability manager

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_pci_cap_manager.sv`

- [ ] **Step 1: Write virtio_pci_cap_manager.sv**

Per spec Section 7.1. Traverses config space capability chain to find virtio caps (cfg_type 1-5) and MSI-X:

```systemverilog
class virtio_pci_cap_manager extends uvm_object;
    virtio_pci_cap_t common_cfg_cap, notify_cap, isr_cap, device_cfg_cap, pci_cfg_cap;
    int unsigned notify_off_multiplier;
    int unsigned msix_table_size;
    bit [63:0] msix_table_bar_addr, msix_pba_bar_addr;

    // Traverse capability linked list via config reads
    virtual task discover_capabilities(/* bar_accessor ref */);
    // Read cap_id at each offset, parse virtio vendor-specific caps (id=0x09)
    // Parse MSI-X capability (id=0x11)

    function bit [63:0] get_common_cfg_addr();
    function bit [63:0] get_notify_addr(int unsigned queue_id);
    function bit [63:0] get_isr_addr();
    function bit [63:0] get_device_cfg_addr();
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_pci_cap_manager.sv
git commit -m "feat: PCI capability discovery for virtio caps and MSI-X"
```

---

### Task 11: BAR accessor

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_bar_accessor.sv`

- [ ] **Step 1: Write virtio_bar_accessor.sv**

Per spec Section 7. Translates BAR MMIO to PCIe TLPs via RC sequencer:

```systemverilog
class virtio_bar_accessor extends uvm_object;
    bit [63:0] bar_base[6];
    uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr;
    bit [15:0] requester_id;

    virtual task read_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size, ref bit [31:0] data);
        // Construct pcie_tl_mem_rd_seq, start on pcie_rc_seqr, wait completion, extract data
    endtask

    virtual task write_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size, bit [31:0] data);
        // Construct pcie_tl_mem_wr_seq, start on pcie_rc_seqr
    endtask

    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
        // PCIe Config Read TLP
    endtask

    virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        // PCIe Config Write TLP
    endtask

    virtual task kick_queue(int unsigned queue_id, bit [31:0] notify_offset, int unsigned multiplier);
        // Write to notify BAR offset
    endtask
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/transport/virtio_bar_accessor.sv
git commit -m "feat: BAR accessor - MMIO to PCIe TLP translation"
```

---

### Task 12: Notification manager and transport wrapper

**Files:**
- Create: `virtio_net_vip/src/transport/virtio_notification_manager.sv`
- Create: `virtio_net_vip/src/transport/virtio_pci_transport.sv`

- [ ] **Step 1: Write virtio_notification_manager.sv**

Per spec Section 7.7. MSI-X/INTx/polling/adaptive, NAPI control, three-level fallback:

```systemverilog
class virtio_notification_manager extends uvm_object;
    interrupt_mode_e irq_mode;
    bit event_idx_enable, coalescing_enable;
    msix_entry_t msix_table[];
    int unsigned config_vector;
    int unsigned queue_vectors[];
    bit intx_enabled;
    bit cb_enabled[];
    int unsigned total_interrupts, spurious_interrupts;

    virtual task setup_msix(/* bar_accessor */, int unsigned num_vectors);
    virtual task allocate_irq_vectors(int unsigned num_queues, ref interrupt_mode_e actual_mode);
    virtual task bind_queue_vector(int unsigned queue_id, int unsigned vector);
    virtual task mask_vector(int unsigned vector);
    virtual task unmask_vector(int unsigned vector);
    virtual task read_and_clear_isr(ref bit [7:0] status);
    virtual function void on_interrupt_received(int unsigned vector);
    virtual function void on_config_change_interrupt();
    virtual function void enter_polling_mode(int unsigned queue_id);
    virtual function void exit_polling_mode(int unsigned queue_id);
    virtual task inject_spurious_interrupt(int unsigned vector);
endclass
```

- [ ] **Step 2: Write virtio_pci_transport.sv**

Per spec Section 7.2-7.6. Top-level transport wrapper:

```systemverilog
class virtio_pci_transport extends uvm_object;
    virtio_pci_cap_manager cap_mgr;
    virtio_bar_accessor bar;
    virtio_notification_manager notify_mgr;
    virtio_wait_policy wait_pol;

    bit [15:0] bdf;
    bit is_vf;
    int unsigned vf_index;
    int unsigned num_queues;
    int unsigned queue_notify_off[];
    bit [63:0] device_features, driver_features;
    bit notification_data_enable;
    bit [7:0] current_status;

    // Device status operations (with poll via wait_policy)
    virtual task reset_device();           // write 0, poll until status==0
    virtual task read_device_status(ref bit [7:0] status);
    virtual task write_device_status(bit [7:0] status);

    // Feature negotiation (64-bit: select=0 low32, select=1 high32)
    virtual task read_device_features(ref bit [63:0] features);
    virtual task write_driver_features(bit [63:0] features);
    virtual task negotiate_features(bit [63:0] driver_supported, ref bit [63:0] negotiated);

    // Config generation check
    virtual task read_config_generation(ref bit [7:0] gen);
    virtual task read_net_config_atomic(ref virtio_net_device_config_t cfg);

    // Queue configuration
    virtual task select_queue(int unsigned queue_id);
    virtual task read_queue_num_max(ref int unsigned max_size);
    virtual task write_queue_size(int unsigned size);
    virtual task read_queue_notify_off(ref int unsigned off);
    virtual task write_queue_desc_addr(bit [63:0] addr);
    virtual task write_queue_driver_addr(bit [63:0] addr);
    virtual task write_queue_device_addr(bit [63:0] addr);
    virtual task write_queue_enable(bit enable);
    virtual task write_queue_reset(int unsigned queue_id);
    virtual task read_num_queues(ref int unsigned num);

    // MSI-X vector binding
    virtual task write_config_msix_vector(int unsigned vector);
    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);

    // Kick (supports NOTIFICATION_DATA)
    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx, bit wrap_counter);

    // Full init sequence (spec Section 7.2, steps 1-9)
    virtual task full_init_sequence(bit [63:0] driver_supported_features,
                                     int unsigned num_queue_pairs, ref bit init_success);

    // Error injection
    virtual task inject_status_error(status_error_e err);
    virtual task inject_feature_error(feature_error_e err);
    virtual task inject_queue_setup_error(queue_setup_error_e err);
endclass
```

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/transport/
git commit -m "feat: notification manager and PCI transport with full init sequence"
```

**Acceptance:** Transport can perform full init sequence against pcie_tl_vip in TLM loopback mode.

---

## Phase 5: Driver Agent

### Task 13: Callbacks and transaction

**Files:**
- Create: `virtio_net_vip/src/callbacks/virtio_dataplane_callback.sv`
- Create: `virtio_net_vip/src/callbacks/virtio_scoreboard_callback.sv`
- Create: `virtio_net_vip/src/callbacks/virtio_coverage_callback.sv`
- Create: `virtio_net_vip/src/types/virtio_transaction.sv`

- [ ] **Step 1: Write callback base classes**

Per spec Section 18:

```systemverilog
// virtio_dataplane_callback.sv
virtual class virtio_dataplane_callback extends uvm_object;
    pure virtual function void custom_tx_build_chain(packet_item pkt, virtio_net_hdr_t hdr, ref virtio_sg_list sgs[$]);
    pure virtual function void custom_rx_parse_buf(byte unsigned raw_data[$], ref virtio_net_hdr_t hdr, ref packet_item pkt);
    pure virtual function int unsigned custom_hdr_size();
endclass

// virtio_scoreboard_callback.sv
virtual class virtio_scoreboard_callback extends uvm_object;
    pure virtual function bit custom_compare(packet_item expected, packet_item actual);
    pure virtual function void custom_extract_fields(byte unsigned raw_desc[], ref string field_values[string]);
endclass

// virtio_coverage_callback.sv
virtual class virtio_coverage_callback extends uvm_object;
    pure virtual function void custom_sample(/* virtio_transaction txn */);
endclass
```

- [ ] **Step 2: Write virtio_transaction.sv**

Per spec Section 8.4:

```systemverilog
class virtio_transaction extends uvm_sequence_item;
    `uvm_object_utils(virtio_transaction)
    rand virtio_txn_type_e txn_type;
    // All fields per spec: queue_id, packets, ctrl_class/cmd/data, features, status,
    // num_pairs, rss_cfg, snapshot, atomic_op, error_scenario, net_hdr, pkt, indirect,
    // desc_id, budget, num_bufs, completed_pkts, received_pkts, expected_count, timeout, etc.
endclass
```

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/callbacks/ virtio_net_vip/src/types/virtio_transaction.sv
git commit -m "feat: callback interfaces and virtio_transaction sequence item"
```

---

### Task 14: Atomic operations library

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_atomic_ops.sv`

- [ ] **Step 1: Write virtio_atomic_ops.sv**

Per spec Section 8.2. One method per real driver operation:

```systemverilog
class virtio_atomic_ops extends uvm_object;
    virtio_pci_transport transport;
    virtqueue_manager vq_mgr;
    host_mem_manager mem;
    virtio_iommu_model iommu;

    // Lifecycle: device_reset, set_acknowledge, set_driver, set_features_ok,
    //            verify_features_ok, set_driver_ok, set_failed
    // Feature: read_device_features, write_driver_features, negotiate_features
    // Queue: setup_queue, teardown_queue, reset_queue, setup_all_queues
    // TX: tx_submit, tx_complete
    // RX: rx_refill, rx_receive
    // Control: ctrl_send, ctrl_set_mac, ctrl_set_promisc, ctrl_set_allmulti,
    //          ctrl_set_mac_table, ctrl_set_vlan_filter, ctrl_set_mq_pairs,
    //          ctrl_set_rss, ctrl_announce_ack
    // Interrupt: handle_interrupt, napi_poll, setup_msix, teardown_msix
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/agent/virtio_atomic_ops.sv
git commit -m "feat: atomic operations library - one method per driver operation"
```

---

### Task 15: Auto FSM

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_auto_fsm.sv`

- [ ] **Step 1: Write virtio_auto_fsm.sv**

Per spec Section 8.3. Complete lifecycle FSM with named fork background tasks:

```systemverilog
class virtio_auto_fsm extends uvm_object;
    fsm_state_e state = FSM_IDLE;
    virtio_atomic_ops ops;
    virtio_driver_config_t drv_cfg;
    protected bit dataplane_running = 0;
    protected event stop_event;

    // Lifecycle
    virtual task full_init();
    virtual task start_dataplane();     // named fork : dataplane_tasks
    virtual task stop_dataplane();      // dataplane_running=0, ->stop_event, disable dataplane_tasks
    virtual task send_packets(packet_item pkts[$], int unsigned queue_id = 0);
    virtual task wait_packets(int unsigned expected, ref packet_item received[$], int unsigned timeout_ns);

    // Reconfiguration
    virtual task configure_mq(int unsigned num_pairs);
    virtual task configure_rss(virtio_rss_config_t cfg);

    // Migration
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
    virtual task restore_from_migration(virtio_device_snapshot_t snap);

    // Error recovery
    virtual task handle_device_needs_reset();
    virtual task reset_single_queue(int unsigned queue_id);

    // Background tasks (all check dataplane_running, exit on stop_event)
    protected virtual task rx_refill_loop(int unsigned queue_id);
    protected virtual task tx_complete_loop(int unsigned queue_id);
    protected virtual task interrupt_handler_loop();
    protected virtual task adaptive_irq_loop();
    protected virtual task config_change_handler();
endclass
```

**Critical implementation rule:** All background tasks run inside `fork : dataplane_tasks ... join_none`. Each task loops with `while (dataplane_running)` and uses `fork : <named_block> ... join_any; disable <named_block>;` for internal waits.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/agent/virtio_auto_fsm.sv
git commit -m "feat: auto FSM with named-fork background tasks"
```

---

### Task 16: Driver, monitor, sequencer, agent

**Files:**
- Create: `virtio_net_vip/src/agent/virtio_driver.sv`
- Create: `virtio_net_vip/src/agent/virtio_monitor.sv`
- Create: `virtio_net_vip/src/agent/virtio_sequencer.sv`
- Create: `virtio_net_vip/src/agent/virtio_driver_agent.sv`

- [ ] **Step 1: Write virtio_driver.sv**

Per spec Section 8.3. Extends `uvm_driver #(virtio_transaction)`, dispatches by txn_type.

- [ ] **Step 2: Write virtio_monitor.sv**

Per spec Section 8.4. Passive TLP observation, protocol checks, analysis ports.

- [ ] **Step 3: Write virtio_sequencer.sv and virtio_driver_agent.sv**

Standard UVM agent: creates driver (if active), monitor, sequencer.

- [ ] **Step 4: Commit**

```bash
git add virtio_net_vip/src/agent/
git commit -m "feat: driver agent - driver, monitor, sequencer, agent wrapper"
```

**Acceptance:** Agent builds and connects without errors in a minimal env.

---

## Phase 6: Data Plane

### Task 17: Checksum, TSO, USO engines

**Files:**
- Create: `virtio_net_vip/src/dataplane/virtio_csum_engine.sv`
- Create: `virtio_net_vip/src/dataplane/virtio_tso_engine.sv`
- Create: `virtio_net_vip/src/dataplane/virtio_uso_engine.sv`

- [ ] **Step 1-3: Write all three engine files**

Per spec Section 9.3. Each engine is a pure utility class with static-like methods.

- [ ] **Step 4: Commit**

```bash
git add virtio_net_vip/src/dataplane/virtio_{csum,tso,uso}_engine.sv
git commit -m "feat: checksum, TSO, USO offload engines"
```

---

### Task 18: RSS engine and offload wrapper

**Files:**
- Create: `virtio_net_vip/src/dataplane/virtio_rss_engine.sv`
- Create: `virtio_net_vip/src/dataplane/virtio_offload_engine.sv`

- [ ] **Step 1-2: Write RSS engine (Toeplitz hash + indirection table) and offload wrapper**

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/dataplane/virtio_{rss,offload}_engine.sv
git commit -m "feat: RSS engine and unified offload engine"
```

---

### Task 19: TX engine

**Files:**
- Create: `virtio_net_vip/src/dataplane/virtio_tx_engine.sv`

- [ ] **Step 1: Write virtio_tx_engine.sv**

Per spec Section 9.1. Builds net_hdr, integrates with net_packet via `packet_item`, constructs sg chains, supports custom callback.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/dataplane/virtio_tx_engine.sv
git commit -m "feat: TX engine with net_packet integration and offload support"
```

---

### Task 20: RX engine

**Files:**
- Create: `virtio_net_vip/src/dataplane/virtio_rx_engine.sv`

- [ ] **Step 1: Write virtio_rx_engine.sv**

Per spec Section 9.2. Three buffer modes (mergeable/big/small), auto-refill, offload verification.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/dataplane/virtio_rx_engine.sv
git commit -m "feat: RX engine with three buffer modes and MRG_RXBUF merge"
```

---

### Task 21: Failover manager and dataplane wrapper

**Files:**
- Create: `virtio_net_vip/src/dataplane/virtio_failover_manager.sv`
- Create: `virtio_net_vip/src/dataplane/virtio_net_dataplane.sv`

- [ ] **Step 1-2: Write failover manager (per spec Section 9.4) and dataplane top-level wrapper**

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/dataplane/virtio_{failover_manager,net_dataplane}.sv
git commit -m "feat: failover manager and dataplane top-level"
```

---

## Phase 7: SR-IOV

### Task 22: VF resource pool

**Files:**
- Create: `virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv`

- [ ] **Step 1: Write resource pool**

Per spec Section 10.2. local_qid <-> global_qid mapping, queue name registry.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/sriov/virtio_vf_resource_pool.sv
git commit -m "feat: VF resource pool with queue mapping"
```

---

### Task 23: VF instance

**Files:**
- Create: `virtio_net_vip/src/sriov/virtio_vf_instance.sv`

- [ ] **Step 1: Write VF instance wrapper**

Per spec Section 10.4. Contains driver_agent, vq_mgr, dataplane, transport. References `pcie_tl_func_context`.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/sriov/virtio_vf_instance.sv
git commit -m "feat: VF instance with per-VF virtio driver"
```

---

### Task 24: PF manager

**Files:**
- Create: `virtio_net_vip/src/sriov/virtio_pf_manager.sv`

- [ ] **Step 1: Write simplified PF manager**

Per spec Section 10.2. Delegates to `pcie_tl_func_manager`, manages VF instances, failover, admin VQ. FLR uses `wait_policy.poll_config_until()`.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/sriov/virtio_pf_manager.sv
git commit -m "feat: PF manager delegating SR-IOV to pcie_tl_func_manager"
```

---

## Phase 8: Env Assembly

### Task 25: Env configuration

**Files:**
- Create: `virtio_net_vip/src/env/virtio_net_env_config.sv`

- [ ] **Step 1: Write config object**

Per spec Section 17. All config fields with `uvm_object_utils`.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/env/virtio_net_env_config.sv
git commit -m "feat: unified env configuration object"
```

---

### Task 26: Scoreboard

**Files:**
- Create: `virtio_net_vip/src/env/virtio_scoreboard.sv`

- [ ] **Step 1: Write scoreboard**

Per spec Section 12. 8 check categories, per-check enable switches, custom callback, statistics, report_phase.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/env/virtio_scoreboard.sv
git commit -m "feat: scoreboard with 8 check categories and custom callback"
```

---

### Task 27: Coverage

**Files:**
- Create: `virtio_net_vip/src/env/virtio_coverage.sv`

- [ ] **Step 1: Write coverage collector**

Per spec Section 13. 8 covergroups (lazy construction, default OFF), custom callback.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/env/virtio_coverage.sv
git commit -m "feat: coverage collector with 8 lazy-constructed covergroups"
```

---

### Task 28: Performance monitor

**Files:**
- Create: `virtio_net_vip/src/env/virtio_perf_monitor.sv`

- [ ] **Step 1: Write performance monitor**

Per spec Section 14. Synchronous token bucket (no background task), latency profiling, per-VF stats.

```systemverilog
class virtio_perf_monitor extends uvm_component;
    bit bw_limit_enable = 0;
    int unsigned bw_limit_mbps;
    protected int unsigned token_bucket, bucket_size;
    protected realtime last_refill_time;

    // Synchronous refill -- no background task
    protected function void sync_refill();
        // Calculate elapsed time, add tokens proportionally
    endfunction

    function bit can_send(int unsigned bytes);
        if (!bw_limit_enable) return 1;
        sync_refill();
        return token_bucket >= bytes;
    endfunction

    function void on_sent(int unsigned bytes);
        if (bw_limit_enable) begin sync_refill(); token_bucket -= bytes; end
    endfunction

    // Latency recording and reporting
    function void record_latency(pkt_latency_t sample);
    virtual function void report_phase(uvm_phase phase);
        // min/max/avg/p50/p95/p99 per stage
    endfunction
endclass
```

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/env/virtio_perf_monitor.sv
git commit -m "feat: performance monitor with sync token bucket and latency profiling"
```

---

### Task 29: Virtual sequencer, concurrency, dynamic reconfig, top-level env

**Files:**
- Create: `virtio_net_vip/src/env/virtio_virtual_sequencer.sv`
- Create: `virtio_net_vip/src/env/virtio_concurrency_controller.sv`
- Create: `virtio_net_vip/src/env/virtio_dynamic_reconfig.sv`
- Create: `virtio_net_vip/src/env/virtio_net_env.sv`

- [ ] **Step 1: Write virtual_sequencer**

Holds pf_seqr, vf_seqrs[], pcie_rc_seqr, shared component refs.

- [ ] **Step 2: Write concurrency_controller**

Per spec Section 15.1. parallel_vf_op with per-VF timeout (named fork), race injection, isolation tests.

- [ ] **Step 3: Write dynamic_reconfig**

Per spec Section 15.2. Live MQ/MTU/IRQ/MAC/VLAN/RSS changes with traffic_active flag.

- [ ] **Step 4: Write virtio_net_env.sv**

Top-level env: build_phase creates all components conditionally based on config, connect_phase wires everything, report_phase runs leak checks.

- [ ] **Step 5: Commit**

```bash
git add virtio_net_vip/src/env/
git commit -m "feat: top-level env with virtual sequencer, concurrency, dynamic reconfig"
```

**Acceptance:** Full env builds and connects without errors.

---

## Phase 9: Sequence Library

### Task 30: Base sequences

**Files:**
- Create: `virtio_net_vip/src/seq/base/virtio_base_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_init_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_tx_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_rx_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_ctrl_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_queue_setup_seq.sv`
- Create: `virtio_net_vip/src/seq/base/virtio_kick_seq.sv`

- [ ] **Step 1: Write all 7 base sequences**

Per spec Section 16.1. Each creates a `virtio_transaction` with appropriate `txn_type`, start_item/finish_item.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/seq/base/
git commit -m "feat: base sequences (init, tx, rx, ctrl, kick, queue_setup)"
```

---

### Task 31: Lifecycle and dataplane scenario sequences

**Files:**
- Create: 3 lifecycle sequences + 5 dataplane sequences (8 files total)

- [ ] **Step 1: Write lifecycle scenarios**

`virtio_lifecycle_full_seq`, `virtio_status_error_seq`, `virtio_feature_error_seq`

- [ ] **Step 2: Write dataplane scenarios**

`virtio_tso_seq`, `virtio_mrg_rxbuf_seq`, `virtio_rss_distribution_seq`, `virtio_csum_offload_seq`, `virtio_tunnel_pkt_seq`

- [ ] **Step 3: Commit**

```bash
git add virtio_net_vip/src/seq/scenario/lifecycle/ virtio_net_vip/src/seq/scenario/dataplane/
git commit -m "feat: lifecycle and dataplane scenario sequences"
```

---

### Task 32: Interrupt, migration, SR-IOV scenario sequences

**Files:**
- Create: 2 interrupt + 2 migration + 3 SR-IOV sequences (7 files total)

- [ ] **Step 1: Write all 7 sequences**

Per spec Section 16.1.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/seq/scenario/{interrupt,migration,sriov}/
git commit -m "feat: interrupt, migration, SR-IOV scenario sequences"
```

---

### Task 33: Error, concurrency, dynamic, boundary scenario sequences

**Files:**
- Create: 4 error + 1 concurrency + 1 dynamic + 1 boundary (7 files total)

- [ ] **Step 1: Write all 7 sequences**

Per spec Section 16.1.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/seq/scenario/{error,concurrency,dynamic,boundary}/
git commit -m "feat: error, concurrency, dynamic, boundary scenario sequences"
```

---

### Task 34: Virtual sequences

**Files:**
- Create: `virtio_net_vip/src/seq/virtual/virtio_smoke_vseq.sv`
- Create: `virtio_net_vip/src/seq/virtual/virtio_full_init_traffic_vseq.sv`
- Create: `virtio_net_vip/src/seq/virtual/virtio_multi_vf_vseq.sv`
- Create: `virtio_net_vip/src/seq/virtual/virtio_stress_vseq.sv`

- [ ] **Step 1: Write all 4 virtual sequences**

Per spec Section 16.2. Smoke: init->tx->rx->reset. Multi-VF: parallel init + parallel traffic. Stress: concurrent everything.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/src/seq/virtual/
git commit -m "feat: virtual sequences (smoke, full traffic, multi-VF, stress)"
```

---

## Phase 10: Tests and Integration

### Task 35: Base test

**Files:**
- Create: `virtio_net_vip/tests/virtio_base_test.sv`

- [ ] **Step 1: Write base test**

Extends `uvm_test`, creates `virtio_net_env_config` with sensible defaults, creates `virtio_net_env`. Provides convenience methods for subclass customization.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/tests/virtio_base_test.sv
git commit -m "feat: base test with default configuration"
```

---

### Task 36: Smoke test

**Files:**
- Create: `virtio_net_vip/tests/virtio_smoke_test.sv`

- [ ] **Step 1: Write smoke test**

TLM loopback mode. Runs `virtio_smoke_vseq`: init -> start dataplane -> TX 10 packets -> RX wait -> reset. Verifies scoreboard reports 0 mismatches.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/tests/virtio_smoke_test.sv
git commit -m "feat: smoke test with TLM loopback"
```

---

### Task 37: Top-level testbench

**Files:**
- Create: `virtio_net_vip/tests/virtio_tb_top.sv`

- [ ] **Step 1: Write tb_top**

Instantiate `pcie_tl_if`, clock/reset generation, set interface in `uvm_config_db`, run UVM test.

- [ ] **Step 2: Commit**

```bash
git add virtio_net_vip/tests/virtio_tb_top.sv
git commit -m "feat: top-level testbench module"
```

**Acceptance:** All 5 smoke test scenarios pass. Scoreboard reports 0 mismatches. No descriptor or DMA mapping leaks.

---

## Risk Items

1. **Split/Packed virtqueue complexity** -- Ring management is most error-prone. Mitigate: implement split first, verify with smoke test, then port to packed.
2. **PCIe integration** -- bar_accessor must correctly construct TLP sequences for pcie_tl_vip. Mitigate: test with TLM loopback mode first.
3. **IOMMU performance** -- Associative array lookup per translation. Mitigate: direct-mapped cache for hot paths if needed.
4. **Background task lifecycle** -- Named fork + stop_event pairing. Mitigate: test start/stop/restart cycles.
5. **net_packet integration** -- packet_item pack/unpack through virtio_net_hdr + buffer split/merge. Mitigate: dedicated TX->RX loopback test.
