`ifndef DPU_NORMALIZED_PLACEMENT_PLAN_SV
`define DPU_NORMALIZED_PLACEMENT_PLAN_SV

class dpu_normalized_vio_request extends uvm_object;
    `uvm_object_utils(dpu_normalized_vio_request)

    int unsigned request_id, service_instance_id, total_qpairs, seed;
    dpu_vio_device_policy_e device_policy;
    dpu_placement_order_e ordering;
    dpu_function_key_t canonical_candidates[$];
    dpu_function_key_t effective_candidates[$];
    dpu_vio_participant_target_t targets[$];
    dpu_normalized_vio_pair_t pairs[$];

    function new(string name = "dpu_normalized_vio_request");
        super.new(name);
    endfunction

    function void copy_from(input dpu_normalized_vio_request rhs);
        request_id = rhs.request_id;
        service_instance_id = rhs.service_instance_id;
        total_qpairs = rhs.total_qpairs;
        seed = rhs.seed;
        device_policy = rhs.device_policy;
        ordering = rhs.ordering;
        canonical_candidates = rhs.canonical_candidates;
        effective_candidates = rhs.effective_candidates;
        targets = rhs.targets;
        pairs = rhs.pairs;
    endfunction

    virtual function void do_copy(uvm_object rhs);
        dpu_normalized_vio_request typed_rhs;
        super.do_copy(rhs);
        if ($cast(typed_rhs, rhs))
            copy_from(typed_rhs);
    endfunction
endclass : dpu_normalized_vio_request

class dpu_normalized_placement_plan extends uvm_object;
    `uvm_object_utils(dpu_normalized_placement_plan)

    int unsigned effective_global_capacity, effective_device_capacity;
    protected dpu_normalized_vio_request requests[$];
    protected dpu_resource_pool_config_t profiles[$];
    protected int unsigned reserved_global_qpair_ids[$];
    protected dpu_global_id_range_t reserved_global_qpair_ranges[$];
    protected bit frozen;

    function new(string name = "dpu_normalized_placement_plan");
        super.new(name);
        frozen = 0;
    endfunction

    protected function bit request_less(
        input dpu_normalized_vio_request lhs,
        input dpu_normalized_vio_request rhs
    );
        return lhs.request_id < rhs.request_id;
    endfunction

    protected function void sort_requests();
        dpu_normalized_vio_request swap;
        for (int left = 0; left < requests.size(); left++) begin
            for (int right = left + 1; right < requests.size(); right++) begin
                if (request_less(requests[right], requests[left])) begin
                    swap = requests[left];
                    requests[left] = requests[right];
                    requests[right] = swap;
                end
            end
        end
    endfunction

    protected function int unsigned target_order(
        input dpu_normalized_vio_request request,
        input dpu_vio_participant_target_t target
    );
        foreach (request.effective_candidates[index]) begin
            if (dpu_same_function_key(request.effective_candidates[index],
                                      target.service_key.function_key))
                return index;
        end
        return request.effective_candidates.size();
    endfunction

    protected function void sort_targets(input dpu_normalized_vio_request request);
        dpu_vio_participant_target_t swap;
        int unsigned left_order;
        int unsigned right_order;
        for (int left = 0; left < request.targets.size(); left++) begin
            for (int right = left + 1; right < request.targets.size(); right++) begin
                left_order = target_order(request, request.targets[left]);
                right_order = target_order(request, request.targets[right]);
                if ((right_order < left_order) ||
                    ((right_order == left_order) &&
                     (dpu_function_key_name(request.targets[right].service_key.function_key) <
                      dpu_function_key_name(request.targets[left].service_key.function_key)))) begin
                    swap = request.targets[left];
                    request.targets[left] = request.targets[right];
                    request.targets[right] = swap;
                end
            end
        end
    endfunction

    protected function void sort_pairs(input dpu_normalized_vio_request request);
        dpu_normalized_vio_pair_t swap;
        for (int left = 0; left < request.pairs.size(); left++) begin
            for (int right = left + 1; right < request.pairs.size(); right++) begin
                if (request.pairs[right].request_pair_index <
                    request.pairs[left].request_pair_index) begin
                    swap = request.pairs[left];
                    request.pairs[left] = request.pairs[right];
                    request.pairs[right] = swap;
                end
            end
        end
    endfunction

    protected function bit reservations_are_valid(
        input int unsigned ids[$],
        input dpu_global_id_range_t ranges[$]
    );
        foreach (ids[index]) begin
            if (ids[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS)
                return 0;
        end
        foreach (ranges[index]) begin
            if ((ranges[index].first_id > ranges[index].last_id) ||
                (ranges[index].last_id >= DPU_MAX_VIO_GLOBAL_QPAIRS))
                return 0;
        end
        return 1;
    endfunction

    protected function void canonicalize_reservations();
        dpu_global_id_range_t intervals[$];
        dpu_global_id_range_t merged[$];
        dpu_global_id_range_t swap;

        intervals = reserved_global_qpair_ranges;
        foreach (reserved_global_qpair_ids[index]) begin
            intervals.push_back('{first_id: reserved_global_qpair_ids[index],
                                  last_id: reserved_global_qpair_ids[index]});
        end
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
        foreach (intervals[index]) begin
            if ((merged.size() == 0) ||
                (intervals[index].first_id >
                 (merged[merged.size() - 1].last_id + 1))) begin
                merged.push_back(intervals[index]);
            end else if (intervals[index].last_id >
                         merged[merged.size() - 1].last_id) begin
                merged[merged.size() - 1].last_id = intervals[index].last_id;
            end
        end
        reserved_global_qpair_ids.delete();
        reserved_global_qpair_ranges.delete();
        foreach (merged[index]) begin
            if (merged[index].first_id == merged[index].last_id)
                reserved_global_qpair_ids.push_back(merged[index].first_id);
            else
                reserved_global_qpair_ranges.push_back(merged[index]);
        end
    endfunction

    function bit add_request(input dpu_normalized_vio_request request,
                             output string why);
        dpu_normalized_vio_request request_copy;
        why = "";
        if (frozen) begin
            why = "cannot add a request to a frozen placement plan";
            return 0;
        end
        if (request == null) begin
            why = "cannot add a null normalized request";
            return 0;
        end
        foreach (requests[index]) begin
            if (requests[index].request_id == request.request_id) begin
                why = "normalized placement plan has a duplicate request ID";
                return 0;
            end
        end
        foreach (request.pairs[index]) begin
            for (int prior = 0; prior < index; prior++) begin
                if (request.pairs[prior].request_pair_index ==
                    request.pairs[index].request_pair_index) begin
                    why = "normalized placement plan has duplicate explicit pair records";
                    return 0;
                end
            end
        end
        request_copy = dpu_normalized_vio_request::type_id::create(
            $sformatf("%s_request_%0d", get_name(), request.request_id));
        request_copy.copy_from(request);
        sort_targets(request_copy);
        sort_pairs(request_copy);
        requests.push_back(request_copy);
        return 1;
    endfunction

    function bit freeze(output string why);
        why = "";
        if (frozen)
            return 1;
        sort_requests();
        frozen = 1;
        return 1;
    endfunction

    function bit is_frozen();
        return frozen;
    endfunction

    function void set_profiles(input dpu_resource_pool_config_t value[$]);
        if (!frozen)
            profiles = value;
    endfunction

    function void set_reservations(input int unsigned ids[$],
                                   input dpu_global_id_range_t ranges[$]);
        if (!frozen) begin
            reserved_global_qpair_ids = ids;
            reserved_global_qpair_ranges = ranges;
            // Preserve malformed authoring for the resolver's structured
            // validation.  Every valid authoring form is normalized to one
            // ascending, non-overlapping union before any query or allocation.
            if (reservations_are_valid(ids, ranges))
                canonicalize_reservations();
        end
    endfunction

    function void list_targets(input int unsigned request_id,
                               ref dpu_vio_participant_target_t targets[$]);
        targets.delete();
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                targets = requests[index].targets;
                return;
            end
        end
    endfunction

    function void list_pairs(input int unsigned request_id,
                             ref dpu_normalized_vio_pair_t pairs[$]);
        pairs.delete();
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                pairs = requests[index].pairs;
                return;
            end
        end
    endfunction

    function void list_requests(ref dpu_normalized_vio_request value[$]);
        dpu_normalized_vio_request request_copy;
        value.delete();
        foreach (requests[index]) begin
            request_copy = dpu_normalized_vio_request::type_id::create(
                $sformatf("%s_request_copy_%0d", get_name(), index));
            request_copy.copy_from(requests[index]);
            value.push_back(request_copy);
        end
    endfunction

    function bit get_request(input int unsigned request_id,
                             output dpu_normalized_vio_request request);
        request = null;
        foreach (requests[index]) begin
            if (requests[index].request_id == request_id) begin
                request = dpu_normalized_vio_request::type_id::create(
                    $sformatf("%s_request_copy_%0d", get_name(), request_id));
                request.copy_from(requests[index]);
                return 1;
            end
        end
        return 0;
    endfunction

    function void list_reserved_global_qpair_ids(ref int unsigned ids[$]);
        ids = reserved_global_qpair_ids;
    endfunction

    function void list_reserved_global_qpair_ranges(
        ref dpu_global_id_range_t ranges[$]
    );
        ranges = reserved_global_qpair_ranges;
    endfunction

    function void list_resource_profiles(
        ref dpu_resource_pool_config_t value[$]
    );
        value = profiles;
    endfunction
endclass : dpu_normalized_placement_plan

`endif // DPU_NORMALIZED_PLACEMENT_PLAN_SV
