`ifndef VIRTQUEUE_MANAGER_SV
`define VIRTQUEUE_MANAGER_SV

// ============================================================================
// virtqueue_manager
//
// Factory and container for virtqueue instances. Creates split, packed, or
// custom virtqueues by type, injects shared references, and provides
// lifecycle management (create, get, destroy, leak check).
//
// Usage:
//   1. Create a virtqueue_manager instance
//   2. Set shared references (mem, iommu, barrier, err_inj, wait_pol, bdf)
//   3. Call create_queue() for each queue needed
//   4. Use get_queue() to retrieve queues by ID
//   5. Call destroy_all() or leak_check() at teardown
//
// Depends on:
//   - virtqueue_base, split_virtqueue, packed_virtqueue, custom_virtqueue
//   - host_mem_manager, virtio_iommu_model, virtio_memory_barrier_model
//   - virtqueue_error_injector, virtio_wait_policy
//   - virtio_net_types.sv (virtqueue_type_e)
// ============================================================================

class virtqueue_manager extends uvm_object;
    `uvm_object_utils(virtqueue_manager)

    // ===== Queue storage: queue_id -> instance =====
    protected virtqueue_base queues[int unsigned];

    // ===== Shared references (set externally before creating queues) =====
    host_mem_manager          mem;
    virtio_iommu_model        iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector  err_inj;
    virtio_wait_policy        wait_pol;
    bit [15:0]                bdf;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtqueue_manager");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // create_queue -- Create a virtqueue by type and register it
    //
    // Factory-creates a split_virtqueue, packed_virtqueue, or
    // custom_virtqueue based on vq_type. Calls setup() with all shared
    // references, stores in queues[queue_id], and returns the instance.
    //
    // Parameters:
    //   queue_id   -- Unique queue identifier within the device
    //   queue_size -- Number of descriptors in the queue
    //   vq_type    -- VQ_SPLIT, VQ_PACKED, or VQ_CUSTOM
    //
    // Returns: the created virtqueue_base handle
    // ------------------------------------------------------------------
    function virtqueue_base create_queue(int unsigned queue_id,
                                         int unsigned queue_size,
                                         virtqueue_type_e vq_type);
        virtqueue_base vq;
        string qname;

        // Check for duplicate queue_id
        if (queues.exists(queue_id)) begin
            `uvm_error("VQ_MGR",
                $sformatf("create_queue: queue_id=%0d already exists", queue_id))
            return queues[queue_id];
        end

        qname = $sformatf("vq_%0d", queue_id);

        case (vq_type)
            VQ_SPLIT: begin
                split_virtqueue sq = split_virtqueue::type_id::create(qname);
                vq = sq;
            end
            VQ_PACKED: begin
                packed_virtqueue pq = packed_virtqueue::type_id::create(qname);
                vq = pq;
            end
            VQ_CUSTOM: begin
                custom_virtqueue cq = custom_virtqueue::type_id::create(qname);
                vq = cq;
            end
            default: begin
                `uvm_error("VQ_MGR",
                    $sformatf("create_queue: unknown vq_type=%s", vq_type.name()))
                return null;
            end
        endcase

        // Initialize with shared references
        vq.setup(queue_id, queue_size, mem, iommu, barrier, err_inj, wait_pol, bdf);

        // Store in map
        queues[queue_id] = vq;

        `uvm_info("VQ_MGR",
            $sformatf("create_queue: queue_id=%0d size=%0d type=%s",
                      queue_id, queue_size, vq_type.name()),
            UVM_MEDIUM)

        return vq;
    endfunction

    // ------------------------------------------------------------------
    // get_queue -- Retrieve a queue by its ID
    //
    // Returns the virtqueue_base handle, or null with an error if
    // the queue_id is not found.
    // ------------------------------------------------------------------
    function virtqueue_base get_queue(int unsigned queue_id);
        if (!queues.exists(queue_id)) begin
            `uvm_error("VQ_MGR",
                $sformatf("get_queue: queue_id=%0d not found", queue_id))
            return null;
        end
        return queues[queue_id];
    endfunction

    // ------------------------------------------------------------------
    // destroy_queue -- Free rings and remove a single queue
    // ------------------------------------------------------------------
    function void destroy_queue(int unsigned queue_id);
        if (!queues.exists(queue_id)) begin
            `uvm_error("VQ_MGR",
                $sformatf("destroy_queue: queue_id=%0d not found", queue_id))
            return;
        end

        queues[queue_id].free_rings();
        queues.delete(queue_id);

        `uvm_info("VQ_MGR",
            $sformatf("destroy_queue: queue_id=%0d destroyed", queue_id),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // destroy_all -- Destroy all managed queues
    // ------------------------------------------------------------------
    function void destroy_all();
        int unsigned qids[$];

        // Collect all queue IDs first to avoid modifying map during iteration
        foreach (queues[qid]) begin
            qids.push_back(qid);
        end

        foreach (qids[i]) begin
            queues[qids[i]].free_rings();
            queues.delete(qids[i]);
        end

        `uvm_info("VQ_MGR",
            $sformatf("destroy_all: destroyed %0d queue(s)", qids.size()),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // detach_all_queues -- Call detach_all_unused() on all queues
    // ------------------------------------------------------------------
    function void detach_all_queues();
        foreach (queues[qid]) begin
            uvm_object tokens[$];
            queues[qid].detach_all_unused(tokens);
            `uvm_info("VQ_MGR",
                $sformatf("detach_all_queues: queue_id=%0d detached %0d tokens",
                          qid, tokens.size()),
                UVM_HIGH)
        end
    endfunction

    // ------------------------------------------------------------------
    // get_queue_count -- Return the number of managed queues
    // ------------------------------------------------------------------
    function int unsigned get_queue_count();
        return queues.size();
    endfunction

    // ------------------------------------------------------------------
    // leak_check -- Call leak_check() on all managed queues
    //
    // Should be called at test end to detect outstanding tokens or
    // DMA mappings that were not properly cleaned up.
    // ------------------------------------------------------------------
    function void leak_check();
        `uvm_info("VQ_MGR",
            $sformatf("leak_check: checking %0d queue(s)", queues.size()),
            UVM_LOW)

        foreach (queues[qid]) begin
            queues[qid].leak_check();
        end
    endfunction

endclass : virtqueue_manager

`endif // VIRTQUEUE_MANAGER_SV
