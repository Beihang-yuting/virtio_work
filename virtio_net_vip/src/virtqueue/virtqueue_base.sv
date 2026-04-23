`ifndef VIRTQUEUE_BASE_SV
`define VIRTQUEUE_BASE_SV

// ============================================================================
// virtqueue_base
//
// Abstract base class defining the interface all virtqueue implementations
// must follow. Extends uvm_object (NOT uvm_component).
//
// Subclasses (split_virtqueue, packed_virtqueue, custom_virtqueue) must
// implement all pure virtual methods. This class provides common state,
// setup logic, and utility methods (dump_ring, leak_check).
//
// Depends on:
//   - virtio_net_types.sv (virtqueue_state_e, virtqueue_error_e, dma_dir_e,
//     virtio_sg_list, virtqueue_snapshot_t, iommu_mapping_t)
//   - host_mem_pkg (host_mem_manager)
//   - virtio_iommu_model, virtio_memory_barrier_model, virtio_wait_policy
//   - virtqueue_error_injector
// ============================================================================

virtual class virtqueue_base extends uvm_object;

    // ===== Queue identity =====
    int unsigned    queue_id;
    int unsigned    global_queue_id;
    int unsigned    queue_size;

    // ===== Memory layout (set by alloc_rings) =====
    bit [63:0]      desc_table_addr;
    bit [63:0]      driver_ring_addr;
    bit [63:0]      device_ring_addr;

    // ===== External component references (set by setup) =====
    host_mem_manager          mem;
    virtio_iommu_model        iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector  err_inj;
    virtio_wait_policy        wait_pol;

    // ===== BDF for IOMMU operations =====
    bit [15:0]      bdf;

    // ===== State =====
    virtqueue_state_e state = VQ_RESET;
    bit               queue_enable = 0;

    // ===== Token tracking: desc_id -> caller context =====
    protected uvm_object token_map[int unsigned];

    // ===== DMA mapping tracking =====
    protected iommu_mapping_t dma_mappings[$];

    // ===== Statistics =====
    int unsigned    total_add_buf_ops = 0;
    int unsigned    total_poll_used_ops = 0;
    int unsigned    total_kick_ops = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtqueue_base");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // setup -- Initialize queue with external references
    //
    // Called by virtqueue_manager after creating the queue instance.
    // Stores all references and sets the queue state to VQ_RESET.
    //
    // Parameters:
    //   qid        -- Queue ID within the device
    //   size       -- Number of descriptors in the queue
    //   m          -- Host memory manager reference
    //   io         -- IOMMU model reference
    //   b          -- Memory barrier model reference
    //   e          -- Error injector reference
    //   w          -- Wait/timeout policy reference
    //   device_bdf -- PCI BDF for IOMMU operations
    // ------------------------------------------------------------------
    virtual function void setup(
        int unsigned qid,
        int unsigned size,
        host_mem_manager m,
        virtio_iommu_model io,
        virtio_memory_barrier_model b,
        virtqueue_error_injector e,
        virtio_wait_policy w,
        bit [15:0] device_bdf
    );
        queue_id        = qid;
        queue_size      = size;
        mem             = m;
        iommu           = io;
        barrier         = b;
        err_inj         = e;
        wait_pol        = w;
        bdf             = device_bdf;
        state           = VQ_RESET;

        `uvm_info("VQ_BASE",
            $sformatf("setup: queue_id=%0d size=%0d bdf=0x%04x",
                      qid, size, device_bdf),
            UVM_HIGH)
    endfunction

    // =================================================================
    // Pure virtual methods -- subclass MUST implement
    // =================================================================

    // ----- Lifecycle -----
    pure virtual function void alloc_rings();
    pure virtual function void free_rings();
    pure virtual function void reset_queue();
    pure virtual function void detach_all_unused(ref uvm_object tokens[$]);

    // ----- Driver operations -----
    pure virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
    pure virtual task kick();
    pure virtual function bit poll_used(
        ref uvm_object      token,
        ref int unsigned     len
    );

    // ----- Notification control (NAPI style) -----
    pure virtual function void disable_cb();
    pure virtual function void enable_cb();
    pure virtual function void enable_cb_delayed();
    pure virtual function bit  vq_poll(int unsigned last_used);

    // ----- Query -----
    pure virtual function int unsigned get_free_count();
    pure virtual function int unsigned get_pending_count();
    pure virtual function bit          needs_notification();

    // ----- DMA helpers -----
    pure virtual function bit [63:0] dma_map_buf(
        bit [63:0] gpa, int unsigned size, dma_dir_e dir
    );
    pure virtual function void dma_unmap_buf(bit [63:0] iova);

    // ----- Error injection -----
    pure virtual function void inject_desc_error(virtqueue_error_e err_type);

    // ----- Migration snapshot -----
    pure virtual function void save_state(ref virtqueue_snapshot_t snap);
    pure virtual function void restore_state(virtqueue_snapshot_t snap);

    // =================================================================
    // Common methods -- base class provides implementation
    // =================================================================

    // ------------------------------------------------------------------
    // detach -- Reset and disable this queue
    // ------------------------------------------------------------------
    virtual function void detach();
        reset_queue();
        queue_enable = 0;
        state = VQ_RESET;
    endfunction

    // ------------------------------------------------------------------
    // dump_ring -- Log queue state summary
    //
    // Logs queue_id, state, size, free/pending counts at UVM_LOW.
    // If desc_table_addr != 0 and mem is valid, dumps first few
    // descriptor table entries via mem.hexdump.
    // ------------------------------------------------------------------
    virtual function void dump_ring();
        int unsigned free_cnt;
        int unsigned pending_cnt;

        free_cnt    = get_free_count();
        pending_cnt = get_pending_count();

        `uvm_info("VQ_DUMP",
            $sformatf({"queue_id=%0d state=%s size=%0d enable=%0b ",
                       "free=%0d pending=%0d ",
                       "desc_addr=0x%016x driver_addr=0x%016x device_addr=0x%016x"},
                      queue_id, state.name(), queue_size, queue_enable,
                      free_cnt, pending_cnt,
                      desc_table_addr, driver_ring_addr, device_ring_addr),
            UVM_LOW)

        if (desc_table_addr != 0 && mem != null) begin
            // Dump first 4 descriptor entries (16 bytes each = 64 bytes)
            `uvm_info("VQ_DUMP",
                $sformatf("Descriptor table hexdump (first 64 bytes at 0x%016x):",
                          desc_table_addr),
                UVM_LOW)
            mem.hexdump(desc_table_addr, 64);
        end
    endfunction

    // ------------------------------------------------------------------
    // leak_check -- Warn about outstanding tokens or DMA mappings
    //
    // Called at test end or queue teardown to detect resource leaks.
    // Warns if token_map has outstanding entries (descriptor leak).
    // Warns if dma_mappings has outstanding entries (DMA mapping leak).
    // ------------------------------------------------------------------
    virtual function void leak_check();
        if (token_map.size() > 0) begin
            `uvm_warning("VQ_LEAK",
                $sformatf("queue_id=%0d: %0d outstanding token(s) in token_map (descriptor leak)",
                          queue_id, token_map.size()))
            foreach (token_map[desc_id]) begin
                `uvm_warning("VQ_LEAK",
                    $sformatf("  desc_id=%0d token=%s",
                              desc_id,
                              (token_map[desc_id] != null) ? token_map[desc_id].get_name() : "null"))
            end
        end

        if (dma_mappings.size() > 0) begin
            `uvm_warning("VQ_LEAK",
                $sformatf("queue_id=%0d: %0d outstanding DMA mapping(s) (DMA mapping leak)",
                          queue_id, dma_mappings.size()))
            foreach (dma_mappings[i]) begin
                `uvm_warning("VQ_LEAK",
                    $sformatf("  [%0d] bdf=0x%04x gpa=0x%016x iova=0x%016x size=%0d dir=%s",
                              i, dma_mappings[i].bdf, dma_mappings[i].gpa,
                              dma_mappings[i].iova, dma_mappings[i].size,
                              dma_mappings[i].dir.name()))
            end
        end

        if (token_map.size() == 0 && dma_mappings.size() == 0) begin
            `uvm_info("VQ_LEAK",
                $sformatf("queue_id=%0d: clean -- no outstanding tokens or DMA mappings",
                          queue_id),
                UVM_LOW)
        end
    endfunction

endclass : virtqueue_base

`endif // VIRTQUEUE_BASE_SV
