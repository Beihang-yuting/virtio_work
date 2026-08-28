`ifndef DPU_RESOURCE_RESOLVER_SV
`define DPU_RESOURCE_RESOLVER_SV

class dpu_resource_resolver extends uvm_object;
    `uvm_object_utils(dpu_resource_resolver)

    typedef struct {
        int unsigned request_id;
        dpu_normalized_vio_pair_t pair;
        int unsigned local_id;
        int unsigned global_id;
        bit local_assigned;
        bit global_assigned;
    } dpu_qpair_candidate_t;

    function new(string name = "dpu_resource_resolver");
        super.new(name);
    endfunction

    protected function void ensure_diagnostic(
        output dpu_placement_diagnostic diagnostic
    );
        if (diagnostic == null)
            diagnostic = dpu_placement_diagnostic::type_id::create(
                {get_name(), "_diagnostic"});
    endfunction

    protected function void set_failure(
        output dpu_placement_diagnostic diagnostic,
        input dpu_placement_error_e error_code,
        input string message
    );
        ensure_diagnostic(diagnostic);
        diagnostic.set(DPU_PLACE_STAGE_RESOURCE_RESOLUTION, error_code, message);
    endfunction

    protected function void set_pair_failure(
        output dpu_placement_diagnostic diagnostic,
        input dpu_placement_error_e error_code,
        input string message,
        input dpu_qpair_candidate_t candidate
    );
        set_failure(diagnostic, error_code, message);
        diagnostic.set_request_context(candidate.request_id);
        diagnostic.set_pair_context(candidate.pair.request_pair_index);
        diagnostic.set_service_context(candidate.pair.service_key);
    endfunction

    protected function bit same_service(
        input dpu_service_key_t lhs,
        input dpu_service_key_t rhs
    );
        return dpu_service_key_name(lhs) == dpu_service_key_name(rhs);
    endfunction

    protected function bit lowest_free_local(
        input bit occupied[DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE],
        input int unsigned capacity,
        output int unsigned local_id
    );
        local_id = 0;
        for (int unsigned index = 0; index < capacity; index++) begin
            if (!occupied[index]) begin
                local_id = index;
                return 1;
            end
        end
        return 0;
    endfunction

    protected function bit lowest_free_global(
        input bit reserved[DPU_MAX_VIO_GLOBAL_QPAIRS],
        input bit occupied[DPU_MAX_VIO_GLOBAL_QPAIRS],
        input int unsigned capacity,
        output int unsigned global_id
    );
        global_id = 0;
        for (int unsigned index = 0; index < capacity; index++) begin
            if (!reserved[index] && !occupied[index]) begin
                global_id = index;
                return 1;
            end
        end
        return 0;
    endfunction

    protected function void sort_intervals(ref dpu_global_id_range_t intervals[$]);
        dpu_global_id_range_t swap;
        for (int left = 0; left < intervals.size(); left++) begin
            for (int right = left + 1; right < intervals.size(); right++) begin
                if ((intervals[right].first_id < intervals[left].first_id) ||
                    ((intervals[right].first_id == intervals[left].first_id) &&
                     (intervals[right].last_id < intervals[left].last_id))) begin
                    swap = intervals[left];
                    intervals[left] = intervals[right];
                    intervals[right] = swap;
                end
            end
        end
    endfunction

    function bit resolve(
        input dpu_device_snapshot device_snapshot,
        input dpu_normalized_placement_plan normalized_plan,
        output dpu_resource_snapshot resource_snapshot,
        output dpu_placement_diagnostic diagnostic
    );
        dpu_normalized_vio_request requests[$];
        dpu_normalized_vio_pair_t pairs[$];
        dpu_qpair_candidate_t candidates[$];
        dpu_global_id_range_t source_ranges[$];
        dpu_global_id_range_t intervals[$];
        dpu_global_id_range_t merged_intervals[$];
        int unsigned source_ids[$];
        bit reserved[DPU_MAX_VIO_GLOBAL_QPAIRS];
        bit global_occupied[DPU_MAX_VIO_GLOBAL_QPAIRS];
        int unsigned local_capacity;
        int unsigned global_capacity;
        string seen_services[string];

        resource_snapshot = null;
        ensure_diagnostic(diagnostic);
        diagnostic.clear();
        reserved = '{default: 0};
        global_occupied = '{default: 0};
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        "resource resolver requires a frozen device snapshot");
            return 0;
        end
        if ((normalized_plan == null) || !normalized_plan.is_frozen()) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                        "resource resolver requires a frozen normalized placement plan");
            return 0;
        end
        local_capacity = (normalized_plan.effective_device_capacity <
                          DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ?
                         normalized_plan.effective_device_capacity :
                         DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        global_capacity = (normalized_plan.effective_global_capacity <
                           DPU_MAX_VIO_GLOBAL_QPAIRS) ?
                          normalized_plan.effective_global_capacity :
                          DPU_MAX_VIO_GLOBAL_QPAIRS;
        if ((local_capacity == 0) || (global_capacity == 0)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        "resource resolver has no effective qpair capacity");
            return 0;
        end

        normalized_plan.list_reserved_global_qpair_ids(source_ids);
        normalized_plan.list_reserved_global_qpair_ranges(source_ranges);
        foreach (source_ids[index]) begin
            if (source_ids[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_RESERVATION,
                            "reserved global qpair ID exceeds the fixed ceiling");
                return 0;
            end
            intervals.push_back('{first_id: source_ids[index],
                                  last_id: source_ids[index]});
        end
        foreach (source_ranges[index]) begin
            if ((source_ranges[index].first_id > source_ranges[index].last_id) ||
                (source_ranges[index].last_id >= DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_RESERVATION,
                            "reserved global qpair range is invalid");
                return 0;
            end
            intervals.push_back(source_ranges[index]);
        end
        sort_intervals(intervals);
        foreach (intervals[index]) begin
            if ((merged_intervals.size() == 0) ||
                (intervals[index].first_id >
                 (merged_intervals[merged_intervals.size() - 1].last_id + 1)))
                merged_intervals.push_back(intervals[index]);
            else if (intervals[index].last_id >
                     merged_intervals[merged_intervals.size() - 1].last_id)
                merged_intervals[merged_intervals.size() - 1].last_id =
                    intervals[index].last_id;
        end
        foreach (merged_intervals[index]) begin
            for (int unsigned value = merged_intervals[index].first_id;
                 value <= merged_intervals[index].last_id; value++)
                reserved[value] = 1;
        end

        normalized_plan.list_requests(requests);
        foreach (requests[request_index]) begin
            normalized_plan.list_pairs(requests[request_index].request_id, pairs);
            foreach (pairs[pair_index]) begin
                dpu_qpair_candidate_t candidate;
                candidate.request_id = requests[request_index].request_id;
                candidate.pair = pairs[pair_index];
                candidate.local_id = 0;
                candidate.global_id = 0;
                candidate.local_assigned = 0;
                candidate.global_assigned = 0;
                candidates.push_back(candidate);
            end
        end

        // A global PINNED intent is resolved before every local or fallback
        // pass, making pin conflicts independent of request declaration order.
        foreach (candidates[index]) begin
            if (candidates[index].pair.global_mode == DPU_ASSIGN_PINNED) begin
                if ((candidates[index].pair.requested_global_qpair_id >=
                     DPU_MAX_VIO_GLOBAL_QPAIRS) ||
                    (candidates[index].pair.requested_global_qpair_id >=
                     global_capacity)) begin
                    set_pair_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE,
                        "pinned global qpair ID exceeds effective capacity", candidates[index]);
                    return 0;
                end
                if (reserved[candidates[index].pair.requested_global_qpair_id]) begin
                    set_pair_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_RESERVED,
                        "pinned global qpair ID is reserved", candidates[index]);
                    return 0;
                end
                if (global_occupied[candidates[index].pair.requested_global_qpair_id]) begin
                    set_pair_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_CONFLICT,
                        "pinned global qpair ID conflicts with another pin", candidates[index]);
                    return 0;
                end
                candidates[index].global_id =
                    candidates[index].pair.requested_global_qpair_id;
                candidates[index].global_assigned = 1;
                global_occupied[candidates[index].global_id] = 1;
            end
        end

        foreach (candidates[service_index]) begin
            bit local_occupied[DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE];
            string service_name;

            service_name = dpu_service_key_name(candidates[service_index].pair.service_key);
            if (seen_services.exists(service_name))
                continue;
            seen_services[service_name] = service_name;
            local_occupied = '{default: 0};
            foreach (candidates[index]) begin
                if (same_service(candidates[index].pair.service_key,
                                 candidates[service_index].pair.service_key) &&
                    (candidates[index].pair.local_mode == DPU_ASSIGN_PINNED)) begin
                    if ((candidates[index].pair.requested_local_pair_id >=
                         DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) ||
                        (candidates[index].pair.requested_local_pair_id >=
                         local_capacity)) begin
                        set_pair_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE,
                            "pinned local qpair ID exceeds effective capacity", candidates[index]);
                        return 0;
                    end
                    if (local_occupied[candidates[index].pair.requested_local_pair_id]) begin
                        set_pair_failure(diagnostic, DPU_PLACE_ERR_LOCAL_QID_CONFLICT,
                            "pinned local qpair ID conflicts within its service", candidates[index]);
                        return 0;
                    end
                    candidates[index].local_id = candidates[index].pair.requested_local_pair_id;
                    candidates[index].local_assigned = 1;
                    local_occupied[candidates[index].local_id] = 1;
                end
            end
            foreach (candidates[index]) begin
                if (same_service(candidates[index].pair.service_key,
                                 candidates[service_index].pair.service_key) &&
                    (candidates[index].pair.local_mode == DPU_ASSIGN_PREFERRED)) begin
                    if ((candidates[index].pair.requested_local_pair_id < local_capacity) &&
                        !local_occupied[candidates[index].pair.requested_local_pair_id]) begin
                        candidates[index].local_id = candidates[index].pair.requested_local_pair_id;
                        candidates[index].local_assigned = 1;
                        local_occupied[candidates[index].local_id] = 1;
                    end
                end
            end
            foreach (candidates[index]) begin
                int unsigned value;
                if (same_service(candidates[index].pair.service_key,
                                 candidates[service_index].pair.service_key) &&
                    !candidates[index].local_assigned) begin
                    if (!lowest_free_local(local_occupied, local_capacity, value)) begin
                        set_pair_failure(diagnostic, DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                            "no local qpair ID remains for service", candidates[index]);
                        return 0;
                    end
                    candidates[index].local_id = value;
                    candidates[index].local_assigned = 1;
                    local_occupied[value] = 1;
                end
            end
        end

        foreach (candidates[index]) begin
            if (candidates[index].pair.global_mode == DPU_ASSIGN_PREFERRED) begin
                if ((candidates[index].pair.requested_global_qpair_id < global_capacity) &&
                    !reserved[candidates[index].pair.requested_global_qpair_id] &&
                    !global_occupied[candidates[index].pair.requested_global_qpair_id]) begin
                    candidates[index].global_id =
                        candidates[index].pair.requested_global_qpair_id;
                    candidates[index].global_assigned = 1;
                    global_occupied[candidates[index].global_id] = 1;
                end
            end
        end
        foreach (candidates[index]) begin
            int unsigned value;
            if (!candidates[index].global_assigned) begin
                if (!lowest_free_global(reserved, global_occupied, global_capacity, value)) begin
                    set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED,
                                "no unreserved global qpair ID remains");
                    return 0;
                end
                candidates[index].global_id = value;
                candidates[index].global_assigned = 1;
                global_occupied[value] = 1;
            end
        end

        resource_snapshot = dpu_resource_snapshot::type_id::create(
            {get_name(), "_resource_snapshot"});
        if (!resource_snapshot.set_normalized_plan(normalized_plan, diagnostic)) begin
            resource_snapshot = null;
            return 0;
        end
        foreach (candidates[index]) begin
            dpu_vio_qpair_binding_t binding;
            binding.request_id = candidates[index].request_id;
            binding.request_pair_index = candidates[index].pair.request_pair_index;
            binding.service_key = candidates[index].pair.service_key;
            binding.local_pair_id = candidates[index].local_id;
            binding.rx_local_virtqueue_id = 2 * candidates[index].local_id;
            binding.tx_local_virtqueue_id = (2 * candidates[index].local_id) + 1;
            binding.global_qpair_id = candidates[index].global_id;
            if (!resource_snapshot.add_vio_binding(binding, diagnostic)) begin
                resource_snapshot = null;
                return 0;
            end
        end
        if (!resource_snapshot.freeze(device_snapshot, diagnostic)) begin
            resource_snapshot = null;
            return 0;
        end
        diagnostic.clear();
        return 1;
    endfunction
endclass : dpu_resource_resolver

`endif // DPU_RESOURCE_RESOLVER_SV
