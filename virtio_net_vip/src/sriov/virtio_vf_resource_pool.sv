`ifndef VIRTIO_VF_RESOURCE_POOL_SV
`define VIRTIO_VF_RESOURCE_POOL_SV

// Read-only service-keyed naming and lookup view over frozen qpair bindings.
// Control/Admin-VQ identity is intentionally outside this snapshot view.
typedef struct {
    dpu_service_key_t service_key;
    int unsigned      virtio_pair_index;
    int unsigned      local_pair_id;
    int unsigned      local_qid;
    int unsigned      global_qid;
    string            queue_name;
} virtio_local_queue_mapping_t;

class virtio_vf_resource_pool extends uvm_object;
    `uvm_object_utils(virtio_vf_resource_pool)

    protected virtio_local_queue_mapping_t queue_map[$];
    protected dpu_resource_snapshot bound_resource_snapshot;

    function new(string name = "virtio_vf_resource_pool");
        super.new(name);
        bound_resource_snapshot = null;
    endfunction

    protected function bit same_service(
        input dpu_service_key_t lhs,
        input dpu_service_key_t rhs
    );
        return dpu_service_key_name(lhs) == dpu_service_key_name(rhs);
    endfunction

    // One real-DUT global qid identifies an RX/TX pair.  The two directional
    // entries are therefore allowed to share a global qid only when they
    // belong to the same service and the same local pair.
    protected function bit same_pair_directions(
        input virtio_local_queue_mapping_t lhs,
        input virtio_local_queue_mapping_t rhs
    );
        return same_service(lhs.service_key, rhs.service_key) &&
               (lhs.virtio_pair_index == rhs.virtio_pair_index) &&
               (lhs.local_pair_id == rhs.local_pair_id) &&
               (lhs.local_qid != rhs.local_qid) &&
               ((lhs.local_qid ^ rhs.local_qid) == 1);
    endfunction

    function bit import_service_bindings(
        input dpu_service_key_t service_key,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_vio_qpair_binding_t bindings[$];
        virtio_local_queue_mapping_t imported[$];
        virtio_local_queue_mapping_t mapping;
        int unsigned existing_count;

        why = "";
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "queue view requires a frozen resource snapshot";
            return 0;
        end
        if ((bound_resource_snapshot != null) &&
            (bound_resource_snapshot != resource_snapshot)) begin
            why = "queue view cannot be rebound to a different resource snapshot";
            return 0;
        end
        resource_snapshot.list_vio_bindings_for_service(service_key, bindings);
        if (bindings.size() == 0) begin
            why = "queue view service has no qpair bindings";
            return 0;
        end
        foreach (bindings[index]) begin
            if (dpu_service_key_name(bindings[index].service_key) !=
                dpu_service_key_name(service_key)) begin
                why = "queue view received a binding for another service";
                return 0;
            end
            mapping.service_key = service_key;
            mapping.virtio_pair_index = bindings[index].virtio_pair_index;
            mapping.local_pair_id = bindings[index].local_pair_id;
            mapping.local_qid = bindings[index].rx_local_virtqueue_id;
            // A tx/rx pair is one hardware queue resource.  The driver uses
            // the same global queue index for VTX and VRX; local_qid remains
            // directional (even=RX, odd=TX).
            mapping.global_qid = bindings[index].global_qpair_id;
            mapping.queue_name = $sformatf("%s_receiveq_%0d",
                dpu_service_key_name(service_key),
                bindings[index].local_pair_id);
            imported.push_back(mapping);
            mapping.local_qid = bindings[index].tx_local_virtqueue_id;
            mapping.global_qid = bindings[index].global_qpair_id;
            mapping.queue_name = $sformatf("%s_transmitq_%0d",
                dpu_service_key_name(service_key),
                bindings[index].local_pair_id);
            imported.push_back(mapping);
        end

        // An exact reimport from the pinned snapshot is idempotent. Any
        // differing mapping for an existing service is rejected before the
        // pool is mutated.
        existing_count = 0;
        foreach (queue_map[index]) begin
            if (!same_service(queue_map[index].service_key, service_key))
                continue;
            if ((existing_count >= imported.size()) ||
                (queue_map[index].local_qid != imported[existing_count].local_qid) ||
                (queue_map[index].global_qid != imported[existing_count].global_qid) ||
                (queue_map[index].queue_name != imported[existing_count].queue_name)) begin
                why = "queue view service mapping cannot be reassigned";
                return 0;
            end
            existing_count++;
        end
        if (existing_count != 0) begin
            if (existing_count != imported.size()) begin
                why = "queue view service mapping cannot be reassigned";
                return 0;
            end
            return 1;
        end

        // Validate the complete candidate against itself and the existing
        // pool before committing any queue. A global qid may occur twice in
        // one service only for the RX/TX entries of one local pair; it must
        // remain unique across services and local pairs.
        foreach (imported[left]) begin
            for (int right = left + 1; right < imported.size(); right++) begin
                if ((imported[left].global_qid == imported[right].global_qid) &&
                    !same_pair_directions(imported[left], imported[right])) begin
                    why = "queue view has an ambiguous global reverse mapping";
                    return 0;
                end
                if (same_service(imported[left].service_key,
                                 imported[right].service_key) &&
                    (imported[left].local_qid == imported[right].local_qid)) begin
                    why = "queue view has a duplicate service/local mapping";
                    return 0;
                end
                if (imported[left].queue_name == imported[right].queue_name) begin
                    why = "queue view has a duplicate queue name";
                    return 0;
                end
            end
            foreach (queue_map[existing_index]) begin
                if (imported[left].global_qid ==
                    queue_map[existing_index].global_qid) begin
                    why = "queue view global qid makes reverse lookup ambiguous";
                    return 0;
                end
                if (same_service(imported[left].service_key,
                                 queue_map[existing_index].service_key) &&
                    (imported[left].local_qid ==
                     queue_map[existing_index].local_qid)) begin
                    why = "queue view has a duplicate service/local mapping";
                    return 0;
                end
                if (imported[left].queue_name ==
                    queue_map[existing_index].queue_name) begin
                    why = "queue view has a duplicate queue name";
                    return 0;
                end
            end
        end
        foreach (imported[index])
            queue_map.push_back(imported[index]);
        if (bound_resource_snapshot == null)
            bound_resource_snapshot = resource_snapshot;
        return 1;
    endfunction

    function bit local_to_global_for_service(
        input dpu_service_key_t service_key,
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        foreach (queue_map[index]) begin
            if (same_service(queue_map[index].service_key, service_key) &&
                (queue_map[index].local_qid == local_qid)) begin
                global_qid = queue_map[index].global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction

    function bit global_to_service_local(
        input int unsigned global_qid,
        output dpu_service_key_t service_key,
        output int unsigned local_qid
    );
        foreach (queue_map[index]) begin
            if (queue_map[index].global_qid == global_qid) begin
                service_key = queue_map[index].service_key;
                // A global qid identifies a pair, so reverse lookup exposes
                // the resolved RX virtqueue ID.  Callers that need TX can
                // query the paired entry instead of deriving it arithmetically.
                local_qid = queue_map[index].local_qid;
                return 1;
            end
        end
        service_key.function_key.host_id = 0;
        service_key.function_key.pf_id = 0;
        service_key.function_key.kind = DPU_FUNCTION_PF;
        service_key.function_key.vf_id = 0;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        local_qid = '0;
        return 0;
    endfunction

    function string get_queue_name(
        input dpu_service_key_t service_key,
        input int unsigned local_qid
    );
        foreach (queue_map[index]) begin
            if (same_service(queue_map[index].service_key, service_key) &&
                (queue_map[index].local_qid == local_qid))
                return queue_map[index].queue_name;
        end
        return "";
    endfunction

    function int unsigned get_total_queues();
        return queue_map.size();
    endfunction

    function void print_map();
        foreach (queue_map[index]) begin
            `uvm_info("VF_RES_POOL", $sformatf(
                "service=%s local_qid=%0d global_qid=%0d %s",
                dpu_service_key_name(queue_map[index].service_key),
                queue_map[index].local_qid, queue_map[index].global_qid,
                queue_map[index].queue_name), UVM_LOW)
        end
    endfunction
endclass : virtio_vf_resource_pool

`endif // VIRTIO_VF_RESOURCE_POOL_SV
