`ifndef DPU_RESOURCE_RESOLVER_SV
`define DPU_RESOURCE_RESOLVER_SV

class dpu_resource_resolver extends uvm_object;
    `uvm_object_utils(dpu_resource_resolver)

    typedef struct {
        int unsigned request_id;
        dpu_normalized_vio_pair_t pair;
        int unsigned local_id;
        int unsigned virtio_pair_index;
        int unsigned global_id;
        bit local_assigned;
        bit global_assigned;
    } dpu_qpair_candidate_t;

    function new(string name = "dpu_resource_resolver");
        super.new(name);
    endfunction

    // The Linux driver distributes contiguous RX/TX rings across q-vectors
    // using DIV_ROUND_UP(remaining_rings, remaining_vectors).  Keep the same
    // deterministic mapping when a function has fewer LAN MSI-X vectors than
    // qpairs, so shared-vector plans exercise the real interrupt topology.
    protected function automatic int unsigned pair_vector_index(
        input int unsigned pair_index,
        input int unsigned qpair_count,
        input int unsigned vector_count
    );
        int unsigned remaining_rings;
        int unsigned remaining_vectors;
        int unsigned ring_base;
        int unsigned rings_for_vector;

        if ((vector_count == 0) || (qpair_count == 0))
            return 0;
        remaining_rings = qpair_count;
        remaining_vectors = vector_count;
        ring_base = 0;
        for (int unsigned vector = 0; vector < vector_count; vector++) begin
            rings_for_vector = (remaining_rings + remaining_vectors - 1) /
                               remaining_vectors;
            if (pair_index < ring_base + rings_for_vector)
                return vector;
            ring_base += rings_for_vector;
            remaining_rings -= rings_for_vector;
            remaining_vectors--;
        end
        return vector_count - 1;
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
        int unsigned next_msix_vector;
        int unsigned af_extra_global_ids[$];
        int unsigned af_regular_qpair_count;
        int unsigned function_qpair_count[string];
        int unsigned function_lan_msix_count[string];
        int unsigned function_msix_base[string];
        dpu_function_key_t function_keys[$];
        dpu_function_key_t expected_af_key;
        dpu_bar_pair_lease_t expected_af_bar0;
        dpu_dut_caps caps;
        string function_name;
        string caps_why;
        string seen_services[string];
        int unsigned next_virtio_pair_index[string];

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
        caps = device_snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(caps_why)) begin
            set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                        (caps == null) ?
                        "resource resolver cannot read DUT capabilities" :
                        {"resource resolver has invalid DUT capabilities: ",
                         caps_why});
            return 0;
        end
        if (!device_snapshot.get_expected_af(expected_af_key,
                                             expected_af_bar0, caps_why)) begin
            set_failure(diagnostic,
                        DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH,
                        {"resource resolver cannot resolve AF: ", caps_why});
            return 0;
        end
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
                candidate.virtio_pair_index = 0;
                candidate.global_id = 0;
                candidate.local_assigned = 0;
                candidate.global_assigned = 0;
                candidates.push_back(candidate);
            end
        end

        // The host Virtio-net view numbers its queue pairs densely within
        // each service.  That protocol ordinal is deliberately independent
        // from the DUT local qpair ID, which may be pinned or sparse.
        foreach (candidates[index]) begin
            string service_name;
            service_name = dpu_service_key_name(candidates[index].pair.service_key);
            if (!next_virtio_pair_index.exists(service_name))
                next_virtio_pair_index[service_name] = 0;
            candidates[index].virtio_pair_index =
                next_virtio_pair_index[service_name];
            next_virtio_pair_index[service_name]++;
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

        // dpu_configure_notify_addr() passes num_rxq +
        // DPU_AF_EXTRA_RES_NUM to dpu_af_configure_qid_map().  These qids
        // share the same 128-entry allocation bitmap as ordinary functions,
        // but remain separate from guest VIO bindings.
        af_regular_qpair_count = 0;
        foreach (candidates[index]) begin
            if (dpu_same_function_key(
                    candidates[index].pair.service_key.function_key,
                    expected_af_key))
                af_regular_qpair_count++;
        end
        if ((af_regular_qpair_count + caps.af_extra_queue_count) >
            caps.max_vio_net_qpairs_per_device) begin
            set_failure(diagnostic,
                        DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                        "AF ordinary and extra qpairs exceed the per-device ceiling");
            diagnostic.set_function_context(expected_af_key);
            return 0;
        end
        for (int unsigned offset = 0;
             offset < caps.af_extra_queue_count; offset++) begin
            int unsigned value;
            if (!lowest_free_global(reserved, global_occupied,
                                    global_capacity, value)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED,
                            "no global qpair ID remains for AF extra queues");
                diagnostic.set_function_context(expected_af_key);
                return 0;
            end
            af_extra_global_ids.push_back(value);
            global_occupied[value] = 1;
        end

        // Resolve the driver's local-vector -> global-vector bindings once
        // while the resource snapshot is still mutable.  The AF driver
        // allocates a contiguous LAN-vector prefix for each function, then
        // reserves mailbox and (for AF) extra control vectors.  The register
        // plan later consumes this explicit result; it must not infer a
        // global vector from a binding ordinal.
        device_snapshot.list_functions(function_keys);
        next_msix_vector = 0;
        foreach (function_keys[function_index]) begin
            function_name = dpu_function_key_name(function_keys[function_index]);
            function_qpair_count[function_name] = 0;
            function_lan_msix_count[function_name] = 0;
            foreach (candidates[candidate_index]) begin
                if (dpu_same_function_key(
                        candidates[candidate_index].pair.service_key.function_key,
                        function_keys[function_index]))
                    function_qpair_count[function_name]++;
            end
            if ((function_qpair_count[function_name] == 0) &&
                !dpu_same_function_key(function_keys[function_index],
                                       expected_af_key))
                continue;
            // A zero request uses the existing one-vector-per-qpair default.
            // Otherwise the explicit count models the driver's
            // min(online_cpus, rxq) result and enables legal sharing.
            foreach (requests[request_index]) begin
                bit request_matches;
                request_matches = 0;
                foreach (candidates[candidate_index]) begin
                    if (dpu_same_function_key(
                            candidates[candidate_index].pair.service_key.function_key,
                            function_keys[function_index]) &&
                        (candidates[candidate_index].request_id ==
                         requests[request_index].request_id)) begin
                        request_matches = 1;
                        break;
                    end
                end
                if (request_matches)
                    function_lan_msix_count[function_name] =
                        requests[request_index].lan_msix_vectors;
            end
            if (function_lan_msix_count[function_name] == 0)
                function_lan_msix_count[function_name] =
                    function_qpair_count[function_name];
            if (function_lan_msix_count[function_name] >
                function_qpair_count[function_name]) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_REQUEST,
                            "LAN MSI-X vector count exceeds function qpair count");
                return 0;
            end
            function_msix_base[function_name] = next_msix_vector;
            next_msix_vector += function_lan_msix_count[function_name];
            next_msix_vector += caps.mailbox_msix_vectors;
            if (dpu_same_function_key(function_keys[function_index],
                                      expected_af_key))
                next_msix_vector += caps.af_extra_msix_vectors;
            if (next_msix_vector > caps.global_msix_vector_count) begin
                set_failure(diagnostic,
                            DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                            "resolved MSI-X bindings exceed DUT global vector capacity");
                return 0;
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
            binding.virtio_pair_index = candidates[index].virtio_pair_index;
            binding.local_pair_id = candidates[index].local_id;
            binding.rx_local_virtqueue_id =
                2 * candidates[index].virtio_pair_index;
            binding.tx_local_virtqueue_id =
                (2 * candidates[index].virtio_pair_index) + 1;
            binding.global_qpair_id = candidates[index].global_id;
            function_name = dpu_function_key_name(
                candidates[index].pair.service_key.function_key);
            binding.local_msix_vector_id = pair_vector_index(
                candidates[index].virtio_pair_index,
                function_qpair_count[function_name],
                function_lan_msix_count[function_name]);
            if (!function_msix_base.exists(function_name) ||
                (function_msix_base[function_name] +
                 binding.local_msix_vector_id >=
                 caps.global_msix_vector_count)) begin
                set_pair_failure(diagnostic,
                                 DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                 "VIO binding has no resolved global MSI-X vector",
                                 candidates[index]);
                resource_snapshot = null;
                return 0;
            end
            binding.global_msix_vector_id = function_msix_base[function_name] +
                binding.local_msix_vector_id;
            if (!resource_snapshot.add_vio_binding(binding, diagnostic)) begin
                resource_snapshot = null;
                return 0;
            end
        end
        foreach (af_extra_global_ids[offset]) begin
            dpu_af_extra_queue_binding_t binding;
            dpu_af_extra_queue_kind_e kind;
            int unsigned eth_port_id;
            int unsigned eth_queue_id;
            string af_name;

            if (!dpu_decode_af_extra_queue_offset(
                    offset, kind, eth_port_id, eth_queue_id)) begin
                set_failure(diagnostic, DPU_PLACE_ERR_INVALID_PROFILE,
                            "DUT AF extra queue capability has no driver layout");
                resource_snapshot = null;
                return 0;
            end
            af_name = dpu_function_key_name(expected_af_key);
            binding.af_function_key = expected_af_key;
            binding.kind = kind;
            binding.extra_queue_offset = offset;
            binding.local_queue_index = af_regular_qpair_count + offset;
            binding.global_qpair_id = af_extra_global_ids[offset];
            binding.local_msix_vector_id =
                function_lan_msix_count[af_name] + offset;
            binding.global_msix_vector_id = function_msix_base[af_name] +
                binding.local_msix_vector_id;
            binding.eth_port_id = eth_port_id;
            binding.eth_queue_id = eth_queue_id;
            if (!resource_snapshot.add_af_extra_queue_binding(
                    binding, diagnostic)) begin
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
