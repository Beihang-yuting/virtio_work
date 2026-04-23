`ifndef VIRTIO_VF_RESOURCE_POOL_SV
`define VIRTIO_VF_RESOURCE_POOL_SV

// ============================================================================
// virtio_vf_resource_pool
//
// Virtio-specific queue mapping: local_qid (per-VF) <-> global_qid (globally
// unique). Each VF gets a set of queues: receiveq_0..N-1, transmitq_0..N-1,
// and a controlq.
//
// Queue numbering within a VF:
//   receiveq_i  = local_qid 2*i
//   transmitq_i = local_qid 2*i+1
//   controlq    = local_qid 2*num_pairs
//
// SR-IOV PF/VF management (BDF, config space, BAR, VF enable/disable) is
// delegated to pcie_tl_vip's pcie_tl_func_manager. This class manages only
// the virtio-level queue resource mapping.
//
// Depends on:
//   - virtio_net_types.sv (queue_mapping_t)
// ============================================================================

class virtio_vf_resource_pool extends uvm_object;
    `uvm_object_utils(virtio_vf_resource_pool)

    // ===== Queue mapping storage =====
    protected queue_mapping_t queue_map[$];
    protected int unsigned    next_global_qid = 0;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_vf_resource_pool");
        super.new(name);
    endfunction

    // ========================================================================
    // register_vf_queues -- Register all queues for a single VF
    //
    // Creates: receiveq_0..N-1, transmitq_0..N-1, controlq
    // Queue numbering:
    //   receiveq_i  = local_qid 2*i
    //   transmitq_i = local_qid 2*i+1
    //   controlq    = local_qid 2*num_pairs
    // ========================================================================

    function void register_vf_queues(int unsigned vf_id, int unsigned num_pairs);
        int unsigned local_qid;
        queue_mapping_t m;

        // Receive and transmit queue pairs
        for (int unsigned i = 0; i < num_pairs; i++) begin
            // Receive queue
            local_qid = 2 * i;
            m.vf_id      = vf_id;
            m.local_qid  = local_qid;
            m.global_qid = next_global_qid;
            m.queue_name  = $sformatf("vf%0d_receiveq_%0d", vf_id, i);
            queue_map.push_back(m);
            next_global_qid++;

            // Transmit queue
            local_qid = 2 * i + 1;
            m.vf_id      = vf_id;
            m.local_qid  = local_qid;
            m.global_qid = next_global_qid;
            m.queue_name  = $sformatf("vf%0d_transmitq_%0d", vf_id, i);
            queue_map.push_back(m);
            next_global_qid++;
        end

        // Control queue
        local_qid = 2 * num_pairs;
        m.vf_id      = vf_id;
        m.local_qid  = local_qid;
        m.global_qid = next_global_qid;
        m.queue_name  = $sformatf("vf%0d_controlq", vf_id);
        queue_map.push_back(m);
        next_global_qid++;

        `uvm_info("VF_RES_POOL",
            $sformatf("register_vf_queues: vf_id=%0d, num_pairs=%0d, queues=%0d (global_qid %0d..%0d)",
                      vf_id, num_pairs, 2 * num_pairs + 1,
                      next_global_qid - (2 * num_pairs + 1), next_global_qid - 1),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // register_vfs -- Register all VFs at once (convenience)
    // ========================================================================

    function void register_vfs(int unsigned num_vfs, int unsigned pairs_per_vf = 1);
        for (int unsigned vf = 0; vf < num_vfs; vf++) begin
            register_vf_queues(vf, pairs_per_vf);
        end

        `uvm_info("VF_RES_POOL",
            $sformatf("register_vfs: %0d VFs registered with %0d pairs each, total queues=%0d",
                      num_vfs, pairs_per_vf, queue_map.size()),
            UVM_LOW)
    endfunction

    // ========================================================================
    // unregister_vf -- Unregister a single VF's queues
    //
    // Removes all queue mappings for the specified vf_id. Does NOT
    // reassign global_qids -- gaps are expected and acceptable.
    // ========================================================================

    function void unregister_vf(int unsigned vf_id);
        queue_mapping_t remaining[$];
        int unsigned removed = 0;

        foreach (queue_map[i]) begin
            if (queue_map[i].vf_id == vf_id) begin
                removed++;
            end else begin
                remaining.push_back(queue_map[i]);
            end
        end

        queue_map = remaining;

        `uvm_info("VF_RES_POOL",
            $sformatf("unregister_vf: vf_id=%0d, removed %0d queue(s), remaining=%0d",
                      vf_id, removed, queue_map.size()),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // unregister_all -- Unregister all VF queues
    // ========================================================================

    function void unregister_all();
        int unsigned prev_size = queue_map.size();
        queue_map.delete();
        next_global_qid = 0;

        `uvm_info("VF_RES_POOL",
            $sformatf("unregister_all: cleared %0d queue mapping(s)", prev_size),
            UVM_MEDIUM)
    endfunction

    // ========================================================================
    // local_to_global -- Lookup: local_qid -> global_qid
    //
    // Returns the global_qid for a given VF's local_qid.
    // Issues uvm_error and returns 0 if not found.
    // ========================================================================

    function int unsigned local_to_global(int unsigned vf_id, int unsigned local_qid);
        foreach (queue_map[i]) begin
            if (queue_map[i].vf_id == vf_id && queue_map[i].local_qid == local_qid)
                return queue_map[i].global_qid;
        end

        `uvm_error("VF_RES_POOL",
            $sformatf("local_to_global: no mapping for vf_id=%0d, local_qid=%0d",
                      vf_id, local_qid))
        return 0;
    endfunction

    // ========================================================================
    // global_to_local -- Lookup: global_qid -> {vf_id, local_qid}
    //
    // Writes vf_id and local_qid by reference.
    // Issues uvm_error if not found (vf_id and local_qid set to 0).
    // ========================================================================

    function void global_to_local(int unsigned global_qid,
                                   ref int unsigned vf_id,
                                   ref int unsigned local_qid);
        foreach (queue_map[i]) begin
            if (queue_map[i].global_qid == global_qid) begin
                vf_id     = queue_map[i].vf_id;
                local_qid = queue_map[i].local_qid;
                return;
            end
        end

        `uvm_error("VF_RES_POOL",
            $sformatf("global_to_local: no mapping for global_qid=%0d", global_qid))
        vf_id     = 0;
        local_qid = 0;
    endfunction

    // ========================================================================
    // get_total_queues -- Get total queue count across all VFs
    // ========================================================================

    function int unsigned get_total_queues();
        return queue_map.size();
    endfunction

    // ========================================================================
    // get_vf_queue_count -- Get queue count for a specific VF
    // ========================================================================

    function int unsigned get_vf_queue_count(int unsigned vf_id);
        int unsigned count = 0;
        foreach (queue_map[i]) begin
            if (queue_map[i].vf_id == vf_id)
                count++;
        end
        return count;
    endfunction

    // ========================================================================
    // get_queue_name -- Get queue name for a specific VF + local_qid
    //
    // Returns empty string if not found.
    // ========================================================================

    function string get_queue_name(int unsigned vf_id, int unsigned local_qid);
        foreach (queue_map[i]) begin
            if (queue_map[i].vf_id == vf_id && queue_map[i].local_qid == local_qid)
                return queue_map[i].queue_name;
        end

        `uvm_warning("VF_RES_POOL",
            $sformatf("get_queue_name: no mapping for vf_id=%0d, local_qid=%0d",
                      vf_id, local_qid))
        return "";
    endfunction

    // ========================================================================
    // check_resource_conflict -- Check for resource conflicts between VFs
    //
    // Returns 1 if any global_qid is shared between two VFs (which would
    // indicate a bug in the registration logic). Under normal operation
    // this should always return 0.
    // ========================================================================

    function bit check_resource_conflict(int unsigned vf_id_a, int unsigned vf_id_b);
        int unsigned globals_a[$];
        int unsigned globals_b[$];

        // Collect global_qids for each VF
        foreach (queue_map[i]) begin
            if (queue_map[i].vf_id == vf_id_a)
                globals_a.push_back(queue_map[i].global_qid);
            else if (queue_map[i].vf_id == vf_id_b)
                globals_b.push_back(queue_map[i].global_qid);
        end

        // Check for intersection
        foreach (globals_a[i]) begin
            foreach (globals_b[j]) begin
                if (globals_a[i] == globals_b[j]) begin
                    `uvm_error("VF_RES_POOL",
                        $sformatf("check_resource_conflict: global_qid=%0d shared by vf_id=%0d and vf_id=%0d",
                                  globals_a[i], vf_id_a, vf_id_b))
                    return 1;
                end
            end
        end

        return 0;
    endfunction

    // ========================================================================
    // print_map -- Print the full mapping table
    // ========================================================================

    function void print_map();
        `uvm_info("VF_RES_POOL",
            $sformatf("Queue mapping table (%0d entries):", queue_map.size()),
            UVM_LOW)

        `uvm_info("VF_RES_POOL",
            "  VF_ID | LOCAL_QID | GLOBAL_QID | QUEUE_NAME", UVM_LOW)
        `uvm_info("VF_RES_POOL",
            "  ------+-----------+------------+---------------------", UVM_LOW)

        foreach (queue_map[i]) begin
            `uvm_info("VF_RES_POOL",
                $sformatf("  %5d | %9d | %10d | %s",
                          queue_map[i].vf_id, queue_map[i].local_qid,
                          queue_map[i].global_qid, queue_map[i].queue_name),
                UVM_LOW)
        end
    endfunction

endclass : virtio_vf_resource_pool

`endif // VIRTIO_VF_RESOURCE_POOL_SV
