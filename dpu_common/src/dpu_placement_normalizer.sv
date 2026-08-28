`ifndef DPU_PLACEMENT_NORMALIZER_SV
`define DPU_PLACEMENT_NORMALIZER_SV

class dpu_placement_normalizer extends uvm_object;
    `uvm_object_utils(dpu_placement_normalizer)

    typedef struct {
        dpu_function_key_t key;
        dpu_function_key_t parent_pf;
        bit is_template;
        dpu_function_cfg function_cfg;
        dpu_vf_template_cfg vf_template;
    } candidate_t;

    function new(string name = "dpu_placement_normalizer");
        super.new(name);
    endfunction

    protected function bit key_less(input dpu_function_key_t lhs,
                                    input dpu_function_key_t rhs);
        if (lhs.host_id != rhs.host_id) return lhs.host_id < rhs.host_id;
        if (lhs.pf_id != rhs.pf_id) return lhs.pf_id < rhs.pf_id;
        if (lhs.kind != rhs.kind) return lhs.kind < rhs.kind;
        return lhs.vf_id < rhs.vf_id;
    endfunction

    protected function void sort_candidates(ref candidate_t candidates[$]);
        candidate_t swap;
        for (int left = 0; left < candidates.size(); left++) begin
            for (int right = left + 1; right < candidates.size(); right++) begin
                if (key_less(candidates[right].key, candidates[left].key)) begin
                    swap = candidates[left]; candidates[left] = candidates[right];
                    candidates[right] = swap;
                end
            end
        end
    endfunction

    protected function bit valid_key(input dpu_function_key_t key,
                                     input dpu_dut_caps caps);
        if ((key.host_id >= caps.max_hosts) ||
            (key.pf_id >= caps.max_pfs_per_host))
            return 0;
        case (key.kind)
            DPU_FUNCTION_PF: return key.vf_id == 0;
            DPU_FUNCTION_VF: return key.vf_id < caps.max_vfs_per_pf;
            default: return 0;
        endcase
    endfunction

    protected function bit contains_key(input dpu_function_key_t keys[$],
                                        input dpu_function_key_t key);
        foreach (keys[index])
            if (dpu_same_function_key(keys[index], key)) return 1;
        return 0;
    endfunction

    protected function bit contains_int(input int unsigned values[$],
                                        input int unsigned value);
        foreach (values[index]) if (values[index] == value) return 1;
        return 0;
    endfunction

    protected function bit has_eligibility(input dpu_service_kind_e kinds[$]);
        return dpu_service_kind_is_eligible(kinds, DPU_SERVICE_VIO_NET);
    endfunction

    protected function bit source_has_vio(input dpu_function_cfg function_cfg);
        foreach (function_cfg.services[index]) begin
            if ((function_cfg.services[index] != null) &&
                (function_cfg.services[index].service_kind == DPU_SERVICE_VIO_NET))
                return 1;
        end
        return 0;
    endfunction

    protected function bit find_explicit_function(
        input dpu_device_cfg cfg, input dpu_function_key_t key,
        output dpu_function_cfg found
    );
        foreach (cfg.functions[index]) begin
            if ((cfg.functions[index] != null) &&
                dpu_same_function_key(cfg.functions[index].key, key)) begin
                found = cfg.functions[index];
                return 1;
            end
        end
        found = null;
        return 0;
    endfunction

    protected function bit filter_matches(input dpu_vio_candidate_filter filter,
                                          input candidate_t candidate);
        if ((filter.host_ids.size() != 0) &&
            !contains_int(filter.host_ids, candidate.key.host_id)) return 0;
        if ((filter.vf_ids.size() != 0) &&
            !contains_int(filter.vf_ids, candidate.key.vf_id)) return 0;
        if ((filter.function_keys.size() != 0) &&
            !contains_key(filter.function_keys, candidate.key)) return 0;
        if ((filter.parent_pf_keys.size() != 0) &&
            !contains_key(filter.parent_pf_keys, candidate.parent_pf)) return 0;
        return 1;
    endfunction

    protected function bit validate_filter(input dpu_vio_candidate_filter filter,
                                           input dpu_dut_caps caps,
                                           output string why);
        why = "";
        if (filter == null) begin why = "candidate filter is null"; return 0; end
        foreach (filter.host_ids[index]) begin
            if ((filter.host_ids[index] >= caps.max_hosts) ||
                ((index != 0) && contains_int(filter.host_ids[0:index-1],
                                               filter.host_ids[index]))) begin
                why = "candidate filter has an invalid or duplicate host"; return 0;
            end
        end
        foreach (filter.vf_ids[index]) begin
            if ((filter.vf_ids[index] >= caps.max_vfs_per_pf) ||
                ((index != 0) && contains_int(filter.vf_ids[0:index-1],
                                               filter.vf_ids[index]))) begin
                why = "candidate filter has an invalid or duplicate VF"; return 0;
            end
        end
        foreach (filter.parent_pf_keys[index]) begin
            if (!valid_key(filter.parent_pf_keys[index], caps) ||
                (filter.parent_pf_keys[index].kind != DPU_FUNCTION_PF) ||
                ((index != 0) && contains_key(filter.parent_pf_keys[0:index-1],
                                               filter.parent_pf_keys[index]))) begin
                why = "candidate filter has an invalid or duplicate parent PF"; return 0;
            end
        end
        foreach (filter.function_keys[index]) begin
            if (!valid_key(filter.function_keys[index], caps) ||
                ((index != 0) && contains_key(filter.function_keys[0:index-1],
                                               filter.function_keys[index]))) begin
                why = "candidate filter has an invalid or duplicate function"; return 0;
            end
        end
        return 1;
    endfunction

    protected function bit validate_pools(input dpu_device_cfg cfg,
                                          output string why);
        dpu_function_cfg parent;
        dpu_function_key_t template_key;
        why = "";
        foreach (cfg.vf_pools[pool_index]) begin
            if (cfg.vf_pools[pool_index] == null) begin why = "null VF pool"; return 0; end
            if ((cfg.vf_pools[pool_index].parent_pf.kind != DPU_FUNCTION_PF) ||
                !valid_key(cfg.vf_pools[pool_index].parent_pf, cfg.dut_caps) ||
                !find_explicit_function(cfg, cfg.vf_pools[pool_index].parent_pf, parent)) begin
                why = "VF pool parent is not an explicit PF"; return 0;
            end
            for (int prior_pool = 0; prior_pool < pool_index; prior_pool++) begin
                if (dpu_same_function_key(cfg.vf_pools[prior_pool].parent_pf,
                                          cfg.vf_pools[pool_index].parent_pf)) begin
                    why = "multiple VF pools name the same parent PF"; return 0;
                end
            end
            foreach (cfg.vf_pools[pool_index].vf_templates[template_index]) begin
                if (cfg.vf_pools[pool_index].vf_templates[template_index] == null) begin
                    why = "null VF template"; return 0;
                end
                template_key = cfg.vf_pools[pool_index].parent_pf;
                template_key.kind = DPU_FUNCTION_VF;
                template_key.vf_id = cfg.vf_pools[pool_index].vf_templates[template_index].vf_id;
                if (!valid_key(template_key, cfg.dut_caps) ||
                    (cfg.vf_pools[pool_index].vf_templates[template_index].domain_key.host_id !=
                     cfg.vf_pools[pool_index].parent_pf.host_id) ||
                    !has_eligibility(cfg.vf_pools[pool_index].vf_templates[template_index].eligible_service_kinds) ||
                    find_explicit_function(cfg, template_key, parent)) begin
                    why = "VF template is invalid, ineligible, or collides with an explicit function";
                    return 0;
                end
                foreach (cfg.vf_pools[pool_index].vf_templates[template_index].bars[bar_index]) begin
                    if (cfg.vf_pools[pool_index].vf_templates[template_index].bars[bar_index] == null) begin
                        why = "VF template has a null BAR"; return 0;
                    end
                end
                for (int prior = 0; prior < template_index; prior++) begin
                    if (cfg.vf_pools[pool_index].vf_templates[prior].vf_id ==
                        cfg.vf_pools[pool_index].vf_templates[template_index].vf_id) begin
                        why = "VF pool has a duplicate VF ID"; return 0;
                    end
                end
            end
        end
        return 1;
    endfunction

    protected function bit collect_candidates(
        input dpu_device_cfg cfg, input dpu_vio_placement_request request,
        output candidate_t candidates[$]
    );
        candidate_t candidate;
        candidates.delete();
        foreach (cfg.functions[index]) begin
            if ((cfg.functions[index] != null) && !source_has_vio(cfg.functions[index]) &&
                has_eligibility(cfg.functions[index].eligible_service_kinds)) begin
                candidate.key = cfg.functions[index].key;
                candidate.parent_pf = candidate.key;
                if (candidate.parent_pf.kind == DPU_FUNCTION_VF) begin
                    candidate.parent_pf.kind = DPU_FUNCTION_PF;
                    candidate.parent_pf.vf_id = 0;
                end
                candidate.is_template = 0;
                candidate.function_cfg = cfg.functions[index];
                candidate.vf_template = null;
                if ((((request.candidate_kind == DPU_VIO_CANDIDATE_PF_ONLY) &&
                      (candidate.key.kind == DPU_FUNCTION_PF)) ||
                     ((request.candidate_kind == DPU_VIO_CANDIDATE_VF_ONLY) &&
                      (candidate.key.kind == DPU_FUNCTION_VF)) ||
                     (request.candidate_kind == DPU_VIO_CANDIDATE_PF_AND_VF)) &&
                    filter_matches(request.candidate_filter, candidate))
                    candidates.push_back(candidate);
            end
        end
        if (request.candidate_kind != DPU_VIO_CANDIDATE_PF_ONLY) begin
            foreach (cfg.vf_pools[pool_index]) begin
                foreach (cfg.vf_pools[pool_index].vf_templates[template_index]) begin
                    candidate.parent_pf = cfg.vf_pools[pool_index].parent_pf;
                    candidate.key = candidate.parent_pf;
                    candidate.key.kind = DPU_FUNCTION_VF;
                    candidate.key.vf_id = cfg.vf_pools[pool_index].vf_templates[template_index].vf_id;
                    candidate.is_template = 1;
                    candidate.function_cfg = null;
                    candidate.vf_template = cfg.vf_pools[pool_index].vf_templates[template_index];
                    if (filter_matches(request.candidate_filter, candidate))
                        candidates.push_back(candidate);
                end
            end
        end
        sort_candidates(candidates);
        return candidates.size() != 0;
    endfunction

    protected function bit find_candidate_index(input candidate_t candidates[$],
                                                input dpu_function_key_t key,
                                                output int unsigned found_index);
        foreach (candidates[index]) begin
            if (dpu_same_function_key(candidates[index].key, key)) begin
                found_index = index;
                return 1;
            end
        end
        found_index = 0;
        return 0;
    endfunction

    protected function int unsigned xorshift32(ref int unsigned state);
        if (state == 0) state = 32'h6d2b79f5;
        state ^= state << 13;
        state ^= state >> 17;
        state ^= state << 5;
        return state;
    endfunction

    protected function void shuffle_candidates(ref candidate_t candidates[$],
                                               input int unsigned seed);
        candidate_t swap;
        int unsigned state;
        int unsigned swap_index;

        state = seed;
        for (int index = candidates.size() - 1; index > 0; index--) begin
            swap_index = xorshift32(state) % (index + 1);
            swap = candidates[index];
            candidates[index] = candidates[swap_index];
            candidates[swap_index] = swap;
        end
    endfunction

    protected function int unsigned target_minimum(
        input dpu_vio_placement_request request,
        input dpu_function_key_t key,
        output bit is_exact,
        output int unsigned pinned_count
    );
        int unsigned minimum;

        is_exact = 0;
        pinned_count = 0;
        minimum = 1;
        foreach (request.qpair_overrides[index]) begin
            if ((request.qpair_overrides[index].owner_mode == DPU_ASSIGN_PINNED) &&
                dpu_same_function_key(request.qpair_overrides[index].requested_owner,
                                      key))
                pinned_count++;
        end
        foreach (request.device_constraints[index]) begin
            if (dpu_same_function_key(request.device_constraints[index].function_key,
                                      key)) begin
                if (request.device_constraints[index].mode == DPU_COUNT_EXACT) begin
                    is_exact = 1;
                    minimum = request.device_constraints[index].qpair_count;
                end else begin
                    minimum = request.device_constraints[index].qpair_count;
                end
                break;
            end
        end
        if (!is_exact && (pinned_count > minimum))
            minimum = pinned_count;
        return minimum;
    endfunction

    protected function void set_failure(ref dpu_placement_diagnostic diagnostic,
                                        input dpu_placement_stage_e stage,
                                        input dpu_placement_error_e code,
                                        input string why,
                                        input int unsigned request_id,
                                        input bit has_request);
        diagnostic.set(stage, code, why);
        if (has_request) diagnostic.set_request_context(request_id);
    endfunction

    function bit normalize(input dpu_device_cfg device_cfg,
                           input dpu_resource_placement_cfg placement_cfg,
                           output dpu_device_cfg normalized_device_cfg,
                           output dpu_normalized_placement_plan normalized_plan,
                           output dpu_placement_diagnostic diagnostic);
        dpu_resource_pool_config_t profile;
        dpu_vio_placement_request ordered_requests[$];
        candidate_t candidates[$];
        candidate_t effective_candidates[$];
        candidate_t selected[$];
        dpu_normalized_vio_request normalized_request;
        dpu_vio_participant_target_t target;
        dpu_normalized_vio_pair_t pair;
        dpu_vio_qpair_override overrides_by_pair[$];
        dpu_service_decl service;
        dpu_function_key_t consumed[$];
        int unsigned profile_count;
        int unsigned required_devices;
        int unsigned remaining;
        int unsigned pair_index;
        int unsigned best_index;
        int unsigned total_selected_qpairs;
        int unsigned selected_minimums[$];
        int unsigned selected_pinned_counts[$];
        int unsigned assigned_counts[$];
        int unsigned exact_sum;
        int unsigned flexible_capacity_sum;
        int unsigned minimum_sum;
        int unsigned candidate_index;
        int unsigned selected_index;
        bit selected_is_exact[$];
        bit pair_assigned[$];
        dpu_service_key_t pair_owners[$];
        string why;

        profile_count = 0;
        total_selected_qpairs = 0;

        normalized_device_cfg = null;
        normalized_plan = null;
        diagnostic = dpu_placement_diagnostic::type_id::create("placement_diagnostic");
        if ((device_cfg == null) || (placement_cfg == null) || (device_cfg.dut_caps == null)) begin
            set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                        "placement normalization received a null source", 0, 0);
            return 0;
        end
        if (!device_cfg.dut_caps.validate(why)) begin
            set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                        why, 0, 0); return 0;
        end
        foreach (device_cfg.functions[index]) begin
            if ((device_cfg.functions[index] == null) ||
                !valid_key(device_cfg.functions[index].key, device_cfg.dut_caps)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "device configuration has an invalid explicit function", 0, 0); return 0;
            end
            for (int prior = 0; prior < index; prior++) begin
                if ((device_cfg.functions[prior] != null) &&
                    dpu_same_function_key(device_cfg.functions[prior].key,
                                          device_cfg.functions[index].key)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                                "device configuration has duplicate explicit functions", 0, 0); return 0;
                end
            end
            if (source_has_vio(device_cfg.functions[index])) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_SOURCE_VIO_SERVICE,
                            "source configuration predeclares a VIO service", 0, 0); return 0;
            end
        end
        if (!validate_pools(device_cfg, why)) begin
            set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_VF_POOL,
                        why, 0, 0); return 0;
        end
        foreach (placement_cfg.vio_requests[index]) begin
            if (placement_cfg.vio_requests[index] == null) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "placement configuration has a null request", 0, 0); return 0;
            end
            ordered_requests.push_back(placement_cfg.vio_requests[index]);
        end
        for (int left = 0; left < ordered_requests.size(); left++) begin
            for (int right = left + 1; right < ordered_requests.size(); right++) begin
                if (ordered_requests[right].request_id < ordered_requests[left].request_id) begin
                    dpu_vio_placement_request request_swap;
                    request_swap = ordered_requests[left]; ordered_requests[left] = ordered_requests[right];
                    ordered_requests[right] = request_swap;
                end
            end
        end
        foreach (placement_cfg.profiles[index]) begin
            if (placement_cfg.profiles[index].name == "virtio.qpair") begin
                profile = placement_cfg.profiles[index]; profile_count++;
            end
        end
        if ((ordered_requests.size() != 0) || (profile_count != 0)) begin
            if ((profile_count != 1) || (profile.kind != DPU_RESOURCE_KIND_QUEUE) ||
                (profile.capacity == 0) || (profile.max_per_function == 0) ||
                (profile.capacity > device_cfg.dut_caps.vio_global_qpair_count) ||
                (profile.max_per_function > device_cfg.dut_caps.max_vio_net_qpairs_per_device)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_PROFILE,
                            "virtio.qpair profile is missing, ambiguous, or expands DUT capacity", 0, 0); return 0;
            end
        end
        normalized_device_cfg = dpu_device_cfg::type_id::create("normalized_device_cfg");
        normalized_device_cfg.copy_from(device_cfg);
        normalized_plan = dpu_normalized_placement_plan::type_id::create("normalized_placement_plan");
        if (profile_count == 0) begin
            normalized_plan.effective_global_capacity = 0;
            normalized_plan.effective_device_capacity = 0;
        end else begin
            normalized_plan.effective_global_capacity = (profile.capacity < device_cfg.dut_caps.vio_global_qpair_count) ? profile.capacity : device_cfg.dut_caps.vio_global_qpair_count;
            normalized_plan.effective_device_capacity = (profile.max_per_function < device_cfg.dut_caps.max_vio_net_qpairs_per_device) ? profile.max_per_function : device_cfg.dut_caps.max_vio_net_qpairs_per_device;
        end
        normalized_plan.set_profiles(placement_cfg.profiles);
        normalized_plan.set_reservations(placement_cfg.reserved_global_qpair_ids,
                                        placement_cfg.reserved_global_qpair_ranges);
        foreach (ordered_requests[request_index]) begin
            if ((request_index != 0) && (ordered_requests[request_index - 1].request_id == ordered_requests[request_index].request_id)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_DUPLICATE_REQUEST,
                            "placement configuration has duplicate request IDs", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            if ((ordered_requests[request_index].candidate_kind != DPU_VIO_CANDIDATE_PF_ONLY) &&
                (ordered_requests[request_index].candidate_kind != DPU_VIO_CANDIDATE_VF_ONLY) &&
                (ordered_requests[request_index].candidate_kind != DPU_VIO_CANDIDATE_PF_AND_VF)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "request has an unknown candidate kind", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            if ((ordered_requests[request_index].total_qpairs == 0) ||
                (ordered_requests[request_index].service_instance_id != 0) ||
                ((ordered_requests[request_index].ordering != DPU_PLACEMENT_CANONICAL) &&
                 (ordered_requests[request_index].ordering != DPU_PLACEMENT_SEEDED_RANDOM)) ||
                !validate_filter(ordered_requests[request_index].candidate_filter,
                                 device_cfg.dut_caps, why)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "request has invalid placement fields", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            if (ordered_requests[request_index].total_qpairs >
                (normalized_plan.effective_global_capacity - total_selected_qpairs)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                            DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED,
                            "global qpair capacity cannot satisfy request demand",
                            ordered_requests[request_index].request_id, 1);
                normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            if ((ordered_requests[request_index].device_policy != DPU_VIO_DEVICE_FIXED) &&
                (ordered_requests[request_index].fixed_devices.size() != 0)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "only FIXED requests may name fixed devices", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            if (!collect_candidates(device_cfg, ordered_requests[request_index], candidates)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_NO_ELIGIBLE_DEVICE,
                            "request has no eligible devices", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            effective_candidates = candidates;
            if (ordered_requests[request_index].ordering == DPU_PLACEMENT_SEEDED_RANDOM)
                shuffle_candidates(effective_candidates, ordered_requests[request_index].seed);

            foreach (ordered_requests[request_index].device_constraints[constraint_index]) begin
                if ((ordered_requests[request_index].device_constraints[constraint_index] == null) ||
                    (ordered_requests[request_index].device_constraints[constraint_index].qpair_count == 0) ||
                    (ordered_requests[request_index].device_constraints[constraint_index].qpair_count >
                     normalized_plan.effective_device_capacity) ||
                    ((ordered_requests[request_index].device_constraints[constraint_index].mode != DPU_COUNT_EXACT) &&
                     (ordered_requests[request_index].device_constraints[constraint_index].mode != DPU_COUNT_AT_LEAST)) ||
                    !find_candidate_index(candidates,
                        ordered_requests[request_index].device_constraints[constraint_index].function_key,
                        candidate_index)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_INPUT,
                                DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                "device constraint is null, invalid, or ineligible",
                                ordered_requests[request_index].request_id, 1);
                    if (ordered_requests[request_index].device_constraints[constraint_index] != null)
                        diagnostic.set_function_context(ordered_requests[request_index].device_constraints[constraint_index].function_key);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                for (int prior = 0; prior < constraint_index; prior++) begin
                    if ((ordered_requests[request_index].device_constraints[prior] != null) &&
                        dpu_same_function_key(
                            ordered_requests[request_index].device_constraints[prior].function_key,
                            ordered_requests[request_index].device_constraints[constraint_index].function_key)) begin
                        set_failure(diagnostic, DPU_PLACE_STAGE_INPUT,
                                    DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                    "request has duplicate device constraints",
                                    ordered_requests[request_index].request_id, 1);
                        diagnostic.set_function_context(ordered_requests[request_index].device_constraints[constraint_index].function_key);
                        normalized_device_cfg = null; normalized_plan = null; return 0;
                    end
                end
            end
            overrides_by_pair.delete();
            for (int index = 0; index < ordered_requests[request_index].total_qpairs; index++)
                overrides_by_pair.push_back(null);
            foreach (ordered_requests[request_index].qpair_overrides[override_index]) begin
                if ((ordered_requests[request_index].qpair_overrides[override_index] == null) ||
                    (ordered_requests[request_index].qpair_overrides[override_index].request_pair_index >=
                     ordered_requests[request_index].total_qpairs) ||
                    ((ordered_requests[request_index].qpair_overrides[override_index].owner_mode != DPU_ASSIGN_AUTO) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].owner_mode != DPU_ASSIGN_PINNED) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].owner_mode != DPU_ASSIGN_PREFERRED)) ||
                    ((ordered_requests[request_index].qpair_overrides[override_index].local_mode != DPU_ASSIGN_AUTO) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].local_mode != DPU_ASSIGN_PINNED) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].local_mode != DPU_ASSIGN_PREFERRED)) ||
                    ((ordered_requests[request_index].qpair_overrides[override_index].global_mode != DPU_ASSIGN_AUTO) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].global_mode != DPU_ASSIGN_PINNED) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].global_mode != DPU_ASSIGN_PREFERRED)) ||
                    ((ordered_requests[request_index].qpair_overrides[override_index].local_mode != DPU_ASSIGN_AUTO) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].requested_local_pair_id > 31)) ||
                    ((ordered_requests[request_index].qpair_overrides[override_index].global_mode != DPU_ASSIGN_AUTO) &&
                     (ordered_requests[request_index].qpair_overrides[override_index].requested_global_qpair_id > 2047))) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                                "qpair override is null, out of range, or has an invalid mode or ID",
                                ordered_requests[request_index].request_id, 1);
                    if (ordered_requests[request_index].qpair_overrides[override_index] != null)
                        diagnostic.set_pair_context(ordered_requests[request_index].qpair_overrides[override_index].request_pair_index);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                pair_index = ordered_requests[request_index].qpair_overrides[override_index].request_pair_index;
                if (overrides_by_pair[pair_index] != null) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                                "request has duplicate qpair overrides",
                                ordered_requests[request_index].request_id, 1);
                    diagnostic.set_pair_context(pair_index);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                if ((ordered_requests[request_index].qpair_overrides[override_index].owner_mode == DPU_ASSIGN_PINNED) &&
                    !find_candidate_index(candidates,
                        ordered_requests[request_index].qpair_overrides[override_index].requested_owner,
                        candidate_index)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                "pinned qpair owner is not an eligible candidate",
                                ordered_requests[request_index].request_id, 1);
                    diagnostic.set_function_context(ordered_requests[request_index].qpair_overrides[override_index].requested_owner);
                    diagnostic.set_pair_context(pair_index);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                overrides_by_pair[pair_index] = ordered_requests[request_index].qpair_overrides[override_index];
            end
            selected.delete();
            selected_minimums.delete();
            selected_pinned_counts.delete();
            selected_is_exact.delete();
            if (ordered_requests[request_index].device_policy == DPU_VIO_DEVICE_FIXED) begin
                if (ordered_requests[request_index].fixed_devices.size() == 0) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_INVALID_REQUEST,
                                "FIXED request has an empty device list", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                foreach (ordered_requests[request_index].fixed_devices[fixed_index]) begin
                    if (!find_candidate_index(candidates,
                            ordered_requests[request_index].fixed_devices[fixed_index], candidate_index) ||
                        ((fixed_index != 0) && contains_key(
                            ordered_requests[request_index].fixed_devices[0:fixed_index-1],
                            ordered_requests[request_index].fixed_devices[fixed_index]))) begin
                        set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_INVALID_REQUEST,
                                    "FIXED request has an ineligible or duplicate device", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
                    end
                end
                foreach (effective_candidates[index]) begin
                    if (contains_key(ordered_requests[request_index].fixed_devices,
                                     effective_candidates[index].key))
                        selected.push_back(effective_candidates[index]);
                end
            end else if (ordered_requests[request_index].device_policy == DPU_VIO_DEVICE_ALL_ELIGIBLE) begin
                selected = effective_candidates;
            end else if (ordered_requests[request_index].device_policy == DPU_VIO_DEVICE_AUTO_MINIMUM) begin
                required_devices = (ordered_requests[request_index].total_qpairs +
                    normalized_plan.effective_device_capacity - 1) /
                    normalized_plan.effective_device_capacity;
                foreach (effective_candidates[index]) begin
                    bit mandatory;
                    mandatory = 0;
                    foreach (ordered_requests[request_index].device_constraints[constraint_index]) begin
                        if (dpu_same_function_key(
                            ordered_requests[request_index].device_constraints[constraint_index].function_key,
                            effective_candidates[index].key)) mandatory = 1;
                    end
                    foreach (overrides_by_pair[pair_index]) begin
                        if ((overrides_by_pair[pair_index] != null) &&
                            (overrides_by_pair[pair_index].owner_mode == DPU_ASSIGN_PINNED) &&
                            dpu_same_function_key(overrides_by_pair[pair_index].requested_owner,
                                                  effective_candidates[index].key)) mandatory = 1;
                    end
                    if (mandatory) selected.push_back(effective_candidates[index]);
                end
                foreach (overrides_by_pair[pair_index]) begin
                    if ((overrides_by_pair[pair_index] != null) &&
                        (overrides_by_pair[pair_index].owner_mode == DPU_ASSIGN_PREFERRED) &&
                        (selected.size() < required_devices) &&
                        find_candidate_index(effective_candidates,
                            overrides_by_pair[pair_index].requested_owner, candidate_index) &&
                        !find_candidate_index(selected,
                            overrides_by_pair[pair_index].requested_owner, selected_index))
                        selected.push_back(effective_candidates[candidate_index]);
                end
            end else begin
                set_failure(diagnostic, DPU_PLACE_STAGE_INPUT, DPU_PLACE_ERR_INVALID_REQUEST,
                            "request has an unknown device policy", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            // FIXED/ALL_ELIGIBLE must include every constraint and pinned owner.
            foreach (ordered_requests[request_index].device_constraints[constraint_index]) begin
                if (!find_candidate_index(selected,
                    ordered_requests[request_index].device_constraints[constraint_index].function_key,
                    selected_index)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                "selected devices omit a constrained participant",
                                ordered_requests[request_index].request_id, 1);
                    diagnostic.set_function_context(ordered_requests[request_index].device_constraints[constraint_index].function_key);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
            end
            foreach (overrides_by_pair[pair_index]) begin
                if ((overrides_by_pair[pair_index] != null) &&
                    (overrides_by_pair[pair_index].owner_mode == DPU_ASSIGN_PINNED) &&
                    !find_candidate_index(selected, overrides_by_pair[pair_index].requested_owner,
                                          selected_index)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                "selected devices omit a pinned qpair owner",
                                ordered_requests[request_index].request_id, 1);
                    diagnostic.set_function_context(overrides_by_pair[pair_index].requested_owner);
                    diagnostic.set_pair_context(pair_index);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
            end
            exact_sum = 0;
            flexible_capacity_sum = 0;
            minimum_sum = 0;
            foreach (selected[index]) begin
                selected_minimums.push_back(target_minimum(ordered_requests[request_index],
                    selected[index].key, selected_is_exact[index],
                    selected_pinned_counts[index]));
                if (selected_is_exact[index]) begin
                    if (selected_pinned_counts[index] > selected_minimums[index]) begin
                        set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                    DPU_PLACE_ERR_DEVICE_CONSTRAINT_CONFLICT,
                                    "EXACT device count is below its pinned qpair count",
                                    ordered_requests[request_index].request_id, 1);
                        diagnostic.set_function_context(selected[index].key);
                        normalized_device_cfg = null; normalized_plan = null; return 0;
                    end
                    exact_sum += selected_minimums[index];
                end else begin
                    flexible_capacity_sum += normalized_plan.effective_device_capacity;
                end
                if (selected_minimums[index] > normalized_plan.effective_device_capacity) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                "participant minimum exceeds effective device capacity",
                                ordered_requests[request_index].request_id, 1);
                    diagnostic.set_function_context(selected[index].key);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                minimum_sum += selected_minimums[index];
            end
            if (ordered_requests[request_index].device_policy == DPU_VIO_DEVICE_AUTO_MINIMUM) begin
                foreach (effective_candidates[index]) begin
                    if ((exact_sum + flexible_capacity_sum >=
                         ordered_requests[request_index].total_qpairs) ||
                        find_candidate_index(selected, effective_candidates[index].key,
                                             selected_index))
                        continue;
                    selected.push_back(effective_candidates[index]);
                    selected_minimums.push_back(target_minimum(ordered_requests[request_index],
                        effective_candidates[index].key, selected_is_exact[selected.size() - 1],
                        selected_pinned_counts[selected.size() - 1]));
                    if (selected_is_exact[selected.size() - 1])
                        exact_sum += selected_minimums[selected.size() - 1];
                    else
                        flexible_capacity_sum += normalized_plan.effective_device_capacity;
                    if (selected_minimums[selected.size() - 1] >
                        normalized_plan.effective_device_capacity) begin
                        set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                    DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                    "participant minimum exceeds effective device capacity",
                                    ordered_requests[request_index].request_id, 1);
                        diagnostic.set_function_context(effective_candidates[index].key);
                        normalized_device_cfg = null; normalized_plan = null; return 0;
                    end
                    minimum_sum += selected_minimums[selected.size() - 1];
                end
            end
            if ((selected.size() == 0) ||
                (minimum_sum > ordered_requests[request_index].total_qpairs) ||
                (exact_sum + flexible_capacity_sum <
                 ordered_requests[request_index].total_qpairs)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                            "selected participants cannot satisfy demand", ordered_requests[request_index].request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            foreach (selected[index]) begin
                if (contains_key(consumed, selected[index].key)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_DUPLICATE_SERVICE_OWNER,
                                "a prior request already owns the selected function", ordered_requests[request_index].request_id, 1);
                    diagnostic.set_function_context(selected[index].key);
                    normalized_device_cfg = null; normalized_plan = null; return 0;
                end
            end
            normalized_request = dpu_normalized_vio_request::type_id::create(
                $sformatf("normalized_request_%0d", ordered_requests[request_index].request_id));
            normalized_request.request_id = ordered_requests[request_index].request_id;
            normalized_request.service_instance_id = ordered_requests[request_index].service_instance_id;
            normalized_request.total_qpairs = ordered_requests[request_index].total_qpairs;
            normalized_request.seed = ordered_requests[request_index].seed;
            normalized_request.device_policy = ordered_requests[request_index].device_policy;
            normalized_request.ordering = ordered_requests[request_index].ordering;
            foreach (candidates[index]) normalized_request.canonical_candidates.push_back(candidates[index].key);
            foreach (selected[index]) begin
                normalized_request.effective_candidates.push_back(selected[index].key);
                target.request_id = normalized_request.request_id;
                target.service_key.function_key = selected[index].key;
                target.service_key.service_kind = DPU_SERVICE_VIO_NET;
                target.service_key.service_instance_id = 0;
                target.qpair_count = selected_minimums[index];
                normalized_request.targets.push_back(target);
            end
            remaining = normalized_request.total_qpairs - minimum_sum;
            while (remaining != 0) begin
                best_index = 0;
                for (int index = 1; index < normalized_request.targets.size(); index++) begin
                    if (!selected_is_exact[index] &&
                        (selected_is_exact[best_index] ||
                         (normalized_request.targets[index].qpair_count <
                          normalized_request.targets[best_index].qpair_count)))
                        best_index = index;
                end
                if (selected_is_exact[best_index] ||
                    (normalized_request.targets[best_index].qpair_count >=
                     normalized_plan.effective_device_capacity)) begin
                    set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                "water-level balancing exceeded device capacity", normalized_request.request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
                end
                normalized_request.targets[best_index].qpair_count++;
                remaining--;
            end
            assigned_counts.delete();
            pair_assigned.delete();
            pair_owners.delete();
            foreach (normalized_request.targets[index]) assigned_counts.push_back(0);
            for (int index = 0; index < normalized_request.total_qpairs; index++) begin
                pair_assigned.push_back(0);
                if ((overrides_by_pair[index] != null) &&
                    (overrides_by_pair[index].owner_mode == DPU_ASSIGN_PINNED)) begin
                    find_candidate_index(selected, overrides_by_pair[index].requested_owner,
                                         selected_index);
                    pair_owners.push_back(normalized_request.targets[selected_index].service_key);
                    assigned_counts[selected_index]++;
                    pair_assigned[index] = 1;
                end else
                    pair_owners.push_back(normalized_request.targets[0].service_key);
            end
            for (int index = 0; index < normalized_request.total_qpairs; index++) begin
                if (!pair_assigned[index] && (overrides_by_pair[index] != null) &&
                    (overrides_by_pair[index].owner_mode == DPU_ASSIGN_PREFERRED) &&
                    find_candidate_index(selected, overrides_by_pair[index].requested_owner,
                                         selected_index) &&
                    (assigned_counts[selected_index] <
                     normalized_request.targets[selected_index].qpair_count)) begin
                    pair_owners[index] = normalized_request.targets[selected_index].service_key;
                    assigned_counts[selected_index]++;
                    pair_assigned[index] = 1;
                end
            end
            for (int index = 0; index < normalized_request.total_qpairs; index++) begin
                if (!pair_assigned[index]) begin
                    for (selected_index = 0; selected_index < normalized_request.targets.size(); selected_index++) begin
                        if (assigned_counts[selected_index] <
                            normalized_request.targets[selected_index].qpair_count) break;
                    end
                    if (selected_index == normalized_request.targets.size()) begin
                        set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION,
                                    DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                                    "pair owner expansion exceeded target capacity",
                                    normalized_request.request_id, 1);
                        diagnostic.set_pair_context(index);
                        normalized_device_cfg = null; normalized_plan = null; return 0;
                    end
                    pair_owners[index] = normalized_request.targets[selected_index].service_key;
                    assigned_counts[selected_index]++;
                end
                pair.request_pair_index = index;
                pair.service_key = pair_owners[index];
                if (overrides_by_pair[index] == null) begin
                    pair.local_mode = DPU_ASSIGN_AUTO;
                    pair.requested_local_pair_id = 0;
                    pair.global_mode = DPU_ASSIGN_AUTO;
                    pair.requested_global_qpair_id = 0;
                end else begin
                    pair.local_mode = overrides_by_pair[index].local_mode;
                    pair.requested_local_pair_id = overrides_by_pair[index].requested_local_pair_id;
                    pair.global_mode = overrides_by_pair[index].global_mode;
                    pair.requested_global_qpair_id = overrides_by_pair[index].requested_global_qpair_id;
                end
                normalized_request.pairs.push_back(pair);
            end
            foreach (selected[index]) begin
                consumed.push_back(selected[index].key);
                if (selected[index].is_template) begin
                    dpu_function_cfg materialized;
                    materialized = dpu_function_cfg::type_id::create(
                        $sformatf("materialized_%s", dpu_function_key_name(selected[index].key)));
                    materialized.key = selected[index].key;
                    materialized.domain_key = selected[index].vf_template.domain_key;
                    materialized.bdf_mode = selected[index].vf_template.bdf_mode;
                    materialized.pinned_bdf = selected[index].vf_template.pinned_bdf;
                    foreach (selected[index].vf_template.bars[bar_index]) begin
                        dpu_bar_request copied_bar;
                        copied_bar = dpu_bar_request::type_id::create("materialized_bar");
                        copied_bar.copy_from(selected[index].vf_template.bars[bar_index]);
                        materialized.bars.push_back(copied_bar);
                    end
                    materialized.eligible_service_kinds = selected[index].vf_template.eligible_service_kinds;
                    service = dpu_service_decl::type_id::create("materialized_vio_service");
                    service.service_kind = DPU_SERVICE_VIO_NET;
                    service.service_instance_id = 0;
                    materialized.services.push_back(service);
                    normalized_device_cfg.functions.push_back(materialized);
                end else begin
                    foreach (normalized_device_cfg.functions[function_index]) begin
                        if (dpu_same_function_key(normalized_device_cfg.functions[function_index].key,
                                                  selected[index].key)) begin
                            service = dpu_service_decl::type_id::create("normalized_vio_service");
                            service.service_kind = DPU_SERVICE_VIO_NET;
                            service.service_instance_id = 0;
                            normalized_device_cfg.functions[function_index].services.push_back(service);
                        end
                    end
                end
            end
            if (!normalized_plan.add_request(normalized_request, why)) begin
                set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_INVALID_REQUEST,
                            why, normalized_request.request_id, 1); normalized_device_cfg = null; normalized_plan = null; return 0;
            end
            total_selected_qpairs += normalized_request.total_qpairs;
        end
        if (!normalized_plan.freeze(why)) begin
            set_failure(diagnostic, DPU_PLACE_STAGE_SELECTION, DPU_PLACE_ERR_INVALID_REQUEST,
                        why, 0, 0); normalized_device_cfg = null; normalized_plan = null; return 0;
        end
        return 1;
    endfunction
endclass : dpu_placement_normalizer

`endif // DPU_PLACEMENT_NORMALIZER_SV
