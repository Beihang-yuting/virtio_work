`ifndef VIRTIO_VF_RESOURCE_POOL_SV
`define VIRTIO_VF_RESOURCE_POOL_SV

// A local virtio queue-name view.  It is deliberately not a resource
// allocator: Fabric owns global identifiers and a function's
// virtio_resource_client supplies any global IDs this view exposes.
typedef struct {
    dpu_function_key_t function_key;
    int unsigned       local_qid;
    int unsigned       global_qid;
    bit                has_global_qid;
    string             queue_name;
} virtio_local_queue_mapping_t;

class virtio_vf_resource_pool extends uvm_object;
    `uvm_object_utils(virtio_vf_resource_pool)

    protected virtio_local_queue_mapping_t queue_map[$];

    function new(string name = "virtio_vf_resource_pool");
        super.new(name);
    endfunction

    protected function bit same_function(
        input dpu_function_key_t lhs,
        input dpu_function_key_t rhs
    );
        return (lhs.host_id == rhs.host_id) &&
               (lhs.pf_id == rhs.pf_id) &&
               (lhs.kind == rhs.kind) &&
               (lhs.vf_id == rhs.vf_id);
    endfunction

    function void register_function_queues(
        input dpu_function_key_t key,
        input int unsigned num_pairs
    );
        virtio_local_queue_mapping_t mapping;

        unregister_function(key);
        for (int unsigned pair_id = 0; pair_id < num_pairs; pair_id++) begin
            mapping.function_key = key;
            mapping.local_qid = 2 * pair_id;
            mapping.global_qid = '0;
            mapping.has_global_qid = 0;
            mapping.queue_name = $sformatf("function_%0d_%0d_%0d_%0d_receiveq_%0d",
                key.host_id, key.pf_id, key.kind, key.vf_id, pair_id);
            queue_map.push_back(mapping);

            mapping.local_qid = 2 * pair_id + 1;
            mapping.queue_name = $sformatf("function_%0d_%0d_%0d_%0d_transmitq_%0d",
                key.host_id, key.pf_id, key.kind, key.vf_id, pair_id);
            queue_map.push_back(mapping);
        end

        mapping.function_key = key;
        mapping.local_qid = 2 * num_pairs;
        mapping.global_qid = '0;
        mapping.has_global_qid = 0;
        mapping.queue_name = $sformatf("function_%0d_%0d_%0d_%0d_controlq",
            key.host_id, key.pf_id, key.kind, key.vf_id);
        queue_map.push_back(mapping);
    endfunction

    protected function void import_queue_mapping(
        input dpu_function_key_t key,
        input int unsigned local_qid,
        input int unsigned global_qid,
        input string queue_name
    );
        virtio_local_queue_mapping_t mapping;

        foreach (queue_map[index]) begin
            if (same_function(queue_map[index].function_key, key) &&
                (queue_map[index].local_qid == local_qid)) begin
                queue_map[index].global_qid = global_qid;
                queue_map[index].has_global_qid = 1;
                return;
            end
        end
        mapping.function_key = key;
        mapping.local_qid = local_qid;
        mapping.global_qid = global_qid;
        mapping.has_global_qid = 1;
        mapping.queue_name = queue_name;
        queue_map.push_back(mapping);
    endfunction

    // Import is a view operation: these global IDs were granted by Fabric;
    // this class never chooses or increments an ID itself.
    function void import_qpair_leases(
        input dpu_function_key_t key,
        input virtio_resource_client client
    );
        virtio_local_queue_mapping_t mapping;

        if (client == null)
            return;
        foreach (client.qpair_mappings[index]) begin
            mapping.local_qid = 2 * client.qpair_mappings[index].local_pair;
            mapping.queue_name = $sformatf("function_%0d_%0d_%0d_%0d_receiveq_%0d",
                key.host_id, key.pf_id, key.kind, key.vf_id,
                client.qpair_mappings[index].local_pair);
            import_queue_mapping(key, mapping.local_qid,
                client.qpair_mappings[index].rx_global_qid, mapping.queue_name);

            mapping.local_qid++;
            mapping.queue_name = $sformatf("function_%0d_%0d_%0d_%0d_transmitq_%0d",
                key.host_id, key.pf_id, key.kind, key.vf_id,
                client.qpair_mappings[index].local_pair);
            import_queue_mapping(key, mapping.local_qid,
                client.qpair_mappings[index].tx_global_qid, mapping.queue_name);
        end
    endfunction

    function void unregister_function(input dpu_function_key_t key);
        virtio_local_queue_mapping_t remaining[$];

        foreach (queue_map[index]) begin
            if (!same_function(queue_map[index].function_key, key))
                remaining.push_back(queue_map[index]);
        end
        queue_map = remaining;
    endfunction

    function void unregister_all();
        queue_map.delete();
    endfunction

    function bit local_to_global_for_function(
        input dpu_function_key_t key,
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        foreach (queue_map[index]) begin
            if (same_function(queue_map[index].function_key, key) &&
                (queue_map[index].local_qid == local_qid) &&
                queue_map[index].has_global_qid) begin
                global_qid = queue_map[index].global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction

    // Legacy APIs preserve PF-manager call sites.  They register local VF
    // names only; their global IDs now remain Fabric-owned and unavailable
    // until a client imports a lease.
    function void register_vf_queues(int unsigned vf_id, int unsigned num_pairs);
        dpu_function_key_t key;

        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_VF;
        key.vf_id = vf_id;
        register_function_queues(key, num_pairs);
    endfunction

    function void register_vfs(int unsigned num_vfs, int unsigned pairs_per_vf = 1);
        for (int unsigned vf_id = 0; vf_id < num_vfs; vf_id++)
            register_vf_queues(vf_id, pairs_per_vf);
    endfunction

    function void unregister_vf(int unsigned vf_id);
        dpu_function_key_t key;

        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_VF;
        key.vf_id = vf_id;
        unregister_function(key);
    endfunction

    function int unsigned local_to_global(int unsigned vf_id, int unsigned local_qid);
        dpu_function_key_t key;
        int unsigned global_qid;

        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_VF;
        key.vf_id = vf_id;
        if (local_to_global_for_function(key, local_qid, global_qid))
            return global_qid;
        `uvm_error("VF_RES_POOL", $sformatf(
            "no Fabric global mapping for VF%0d local_qid=%0d", vf_id, local_qid))
        return 0;
    endfunction

    function void global_to_local(
        int unsigned global_qid,
        ref int unsigned vf_id,
        ref int unsigned local_qid
    );
        foreach (queue_map[index]) begin
            if (queue_map[index].has_global_qid &&
                (queue_map[index].global_qid == global_qid)) begin
                vf_id = queue_map[index].function_key.vf_id;
                local_qid = queue_map[index].local_qid;
                return;
            end
        end
        `uvm_error("VF_RES_POOL", $sformatf(
            "no Fabric local mapping for global_qid=%0d", global_qid))
        vf_id = '0;
        local_qid = '0;
    endfunction

    function int unsigned get_total_queues();
        return queue_map.size();
    endfunction

    function int unsigned get_vf_queue_count(int unsigned vf_id);
        int unsigned count;

        count = 0;
        foreach (queue_map[index]) begin
            if ((queue_map[index].function_key.kind == DPU_FUNCTION_VF) &&
                (queue_map[index].function_key.vf_id == vf_id))
                count++;
        end
        return count;
    endfunction

    function string get_queue_name(int unsigned vf_id, int unsigned local_qid);
        foreach (queue_map[index]) begin
            if ((queue_map[index].function_key.kind == DPU_FUNCTION_VF) &&
                (queue_map[index].function_key.vf_id == vf_id) &&
                (queue_map[index].local_qid == local_qid))
                return queue_map[index].queue_name;
        end
        return "";
    endfunction

    // Kept for legacy PF-manager users.  This only compares mappings that
    // Fabric already granted; it cannot create a conflicting global ID.
    function bit check_resource_conflict(int unsigned vf_id_a, int unsigned vf_id_b);
        foreach (queue_map[left_index]) begin
            if (!queue_map[left_index].has_global_qid ||
                (queue_map[left_index].function_key.kind != DPU_FUNCTION_VF) ||
                (queue_map[left_index].function_key.vf_id != vf_id_a))
                continue;
            foreach (queue_map[right_index]) begin
                if (queue_map[right_index].has_global_qid &&
                    (queue_map[right_index].function_key.kind == DPU_FUNCTION_VF) &&
                    (queue_map[right_index].function_key.vf_id == vf_id_b) &&
                    (queue_map[left_index].global_qid ==
                     queue_map[right_index].global_qid)) begin
                    return 1;
                end
            end
        end
        return 0;
    endfunction

    function void print_map();
        foreach (queue_map[index]) begin
            `uvm_info("VF_RES_POOL", $sformatf(
                "function=%0d:%0d:%0d:%0d local_qid=%0d global_qid=%0d valid=%0b %s",
                queue_map[index].function_key.host_id,
                queue_map[index].function_key.pf_id,
                queue_map[index].function_key.kind,
                queue_map[index].function_key.vf_id,
                queue_map[index].local_qid, queue_map[index].global_qid,
                queue_map[index].has_global_qid, queue_map[index].queue_name),
                UVM_LOW)
        end
    endfunction
endclass : virtio_vf_resource_pool

`endif // VIRTIO_VF_RESOURCE_POOL_SV
