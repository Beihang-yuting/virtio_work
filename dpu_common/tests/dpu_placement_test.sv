`ifndef DPU_PLACEMENT_TEST_SV
`define DPU_PLACEMENT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_placement_test extends uvm_test;
    `uvm_component_utils(dpu_placement_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key(
        input int unsigned host_id, input int unsigned pf_id,
        input dpu_function_kind_e kind, input int unsigned vf_id
    );
        dpu_function_key_t key;
        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    function automatic dpu_device_cfg make_source_cfg();
        dpu_device_cfg cfg;
        dpu_host_cfg host;
        dpu_function_cfg function_cfg;
        dpu_vf_pool_cfg pool;
        dpu_vf_template_cfg template;
        dpu_bar_request bar;

        cfg = dpu_device_cfg::type_id::create("source_cfg");
        cfg.dut_caps.max_pfs_per_host = 4;
        cfg.dut_caps.max_vio_net_qpairs_per_device = 32;
        host = dpu_host_cfg::type_id::create("host0");
        host.host_id = 0;
        cfg.hosts.push_back(host);
        for (int unsigned pf_id = 0; pf_id < 4; pf_id++) begin
            function_cfg = dpu_function_cfg::type_id::create(
                $sformatf("pf%0d", pf_id));
            function_cfg.key = make_function_key(0, pf_id, DPU_FUNCTION_PF, 0);
            function_cfg.domain_key.host_id = 0;
            function_cfg.domain_key.segment_id = 0;
            function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
            cfg.functions.push_back(function_cfg);
        end
        pool = dpu_vf_pool_cfg::type_id::create("pf0_vf_pool");
        pool.parent_pf = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        template = dpu_vf_template_cfg::type_id::create("vf7_template");
        template.vf_id = 7;
        template.domain_key.host_id = 0;
        template.domain_key.segment_id = 0;
        bar = dpu_bar_request::type_id::create("vf7_bar");
        template.bars.push_back(bar);
        template.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        pool.vf_templates.push_back(template);
        cfg.vf_pools.push_back(pool);
        return cfg;
    endfunction

    function automatic dpu_resource_placement_cfg make_placement_cfg();
        dpu_resource_placement_cfg cfg;
        dpu_resource_pool_config_t profile;
        cfg = dpu_resource_placement_cfg::type_id::create("placement_cfg");
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        cfg.profiles.push_back(profile);
        return cfg;
    endfunction

    function automatic dpu_vio_placement_request make_request(
        input int unsigned request_id, input int unsigned total_qpairs,
        input dpu_vio_candidate_kind_e candidate_kind,
        input dpu_vio_device_policy_e policy
    );
        dpu_vio_placement_request request;
        request = dpu_vio_placement_request::type_id::create(
            $sformatf("request_%0d", request_id));
        request.request_id = request_id;
        request.total_qpairs = total_qpairs;
        request.candidate_kind = candidate_kind;
        request.device_policy = policy;
        return request;
    endfunction

    function void require_targets(
        input dpu_normalized_placement_plan plan, input int unsigned request_id,
        input int unsigned expected_count, input int unsigned expected_first
    );
        dpu_vio_participant_target_t targets[$];
        plan.list_targets(request_id, targets);
        if ((targets.size() != expected_count) ||
            (targets[0].qpair_count != expected_first)) begin
            `uvm_fatal("PLACEMENT", $sformatf(
                "request %0d has unexpected normalized targets", request_id))
        end
        foreach (targets[index]) begin
            if (targets[index].request_id != request_id)
                `uvm_fatal("PLACEMENT", "target lost enclosing request ID")
        end
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_cfg source_cfg;
        dpu_device_cfg normalized_cfg;
        dpu_resource_placement_cfg placement_cfg;
        dpu_vio_placement_request request;
        dpu_placement_normalizer normalizer;
        dpu_normalized_placement_plan plan;
        dpu_placement_diagnostic diagnostic;
        dpu_normalized_vio_request unordered_request;
        dpu_vio_participant_target_t target;
        dpu_vio_participant_target_t targets[$];
        dpu_normalized_vio_pair_t pair;
        dpu_normalized_vio_pair_t pairs[$];
        string why;
        dpu_function_key_t vf7;
        bit found_vf7;

        super.build_phase(phase);
        normalizer = dpu_placement_normalizer::type_id::create("normalizer");
        diagnostic = dpu_placement_diagnostic::type_id::create("diagnostic");

        source_cfg = make_source_cfg();
        placement_cfg = make_placement_cfg();
        request = make_request(10, 100, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_AUTO_MINIMUM);
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 10, 4, 25);
        plan.list_targets(10, targets);
        if ((targets[1].qpair_count != 25) || (targets[2].qpair_count != 25) ||
            (targets[3].qpair_count != 25))
            `uvm_fatal("PLACEMENT", "100-qpair balance is not 25/25/25/25")

        placement_cfg = make_placement_cfg();
        request = make_request(11, 101, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_AUTO_MINIMUM);
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 11, 4, 26);
        plan.list_targets(11, targets);
        if ((targets[1].qpair_count != 25) || (targets[2].qpair_count != 25) ||
            (targets[3].qpair_count != 25))
            `uvm_fatal("PLACEMENT", "101-qpair balance is not 26/25/25/25")

        placement_cfg = make_placement_cfg();
        request = make_request(12, 64, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_FIXED);
        request.fixed_devices.push_back(make_function_key(0, 1, DPU_FUNCTION_PF, 0));
        request.fixed_devices.push_back(make_function_key(0, 3, DPU_FUNCTION_PF, 0));
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 12, 2, 32);

        placement_cfg = make_placement_cfg();
        request = make_request(13, 100, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_ALL_ELIGIBLE);
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 13, 4, 25);

        placement_cfg = make_placement_cfg();
        request = make_request(14, 1, DPU_VIO_CANDIDATE_VF_ONLY,
                               DPU_VIO_DEVICE_FIXED);
        vf7 = make_function_key(0, 0, DPU_FUNCTION_VF, 7);
        request.fixed_devices.push_back(vf7);
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 14, 1, 1);
        found_vf7 = 0;
        foreach (normalized_cfg.functions[index]) begin
            if (dpu_same_function_key(normalized_cfg.functions[index].key, vf7)) begin
                found_vf7 = (normalized_cfg.functions[index].services.size() == 1) &&
                    (normalized_cfg.functions[index].services[0].service_kind ==
                     DPU_SERVICE_VIO_NET) &&
                    (normalized_cfg.functions[index].services[0].service_instance_id == 0);
            end
        end
        if (!found_vf7 || (source_cfg.functions.size() != 4) ||
            (source_cfg.vf_pools[0].vf_templates[0].vf_id != 7) ||
            (normalized_cfg.vf_pools[0].vf_templates[0].vf_id != 7))
            `uvm_fatal("PLACEMENT", "VF materialization mutated source or template")

        placement_cfg = make_placement_cfg();
        request = make_request(15, 5, DPU_VIO_CANDIDATE_PF_AND_VF,
                               DPU_VIO_DEVICE_FIXED);
        request.fixed_devices.push_back(make_function_key(0, 2, DPU_FUNCTION_PF, 0));
        request.fixed_devices.push_back(vf7);
        placement_cfg.vio_requests.push_back(request);
        if (!normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                  plan, diagnostic))
            `uvm_fatal("PLACEMENT", diagnostic.message)
        require_targets(plan, 15, 2, 3);

        placement_cfg = make_placement_cfg();
        placement_cfg.profiles[0].capacity = 64;
        request = make_request(16, 100, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_AUTO_MINIMUM);
        placement_cfg.vio_requests.push_back(request);
        if (normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                 plan, diagnostic) || (normalized_cfg != null) ||
            (plan != null) ||
            (diagnostic.error_code != DPU_PLACE_ERR_GLOBAL_QID_EXHAUSTED))
            `uvm_fatal("PLACEMENT", "global qpair capacity overflow was accepted")

        placement_cfg = make_placement_cfg();
        request = make_request(17, 1, DPU_VIO_CANDIDATE_PF_ONLY,
                               DPU_VIO_DEVICE_AUTO_MINIMUM);
        request.candidate_kind = dpu_vio_candidate_kind_e'(99);
        placement_cfg.vio_requests.push_back(request);
        if (normalizer.normalize(source_cfg, placement_cfg, normalized_cfg,
                                 plan, diagnostic) || (normalized_cfg != null) ||
            (plan != null) ||
            (diagnostic.error_code != DPU_PLACE_ERR_INVALID_REQUEST))
            `uvm_fatal("PLACEMENT", "invalid candidate kind was accepted")

        plan = dpu_normalized_placement_plan::type_id::create("unordered_plan");
        unordered_request = dpu_normalized_vio_request::type_id::create(
            "unordered_request");
        unordered_request.request_id = 18;
        unordered_request.effective_candidates.push_back(
            make_function_key(0, 1, DPU_FUNCTION_PF, 0));
        unordered_request.effective_candidates.push_back(
            make_function_key(0, 2, DPU_FUNCTION_PF, 0));
        target.request_id = 18;
        target.service_key.function_key = make_function_key(0, 2, DPU_FUNCTION_PF, 0);
        target.service_key.service_kind = DPU_SERVICE_VIO_NET;
        target.service_key.service_instance_id = 0;
        target.qpair_count = 1;
        unordered_request.targets.push_back(target);
        target.service_key.function_key = make_function_key(0, 1, DPU_FUNCTION_PF, 0);
        unordered_request.targets.push_back(target);
        pair.request_pair_index = 1;
        pair.service_key = target.service_key;
        pair.local_mode = DPU_ASSIGN_AUTO;
        pair.global_mode = DPU_ASSIGN_AUTO;
        pair.requested_local_pair_id = 0;
        pair.requested_global_qpair_id = 0;
        unordered_request.pairs.push_back(pair);
        pair.request_pair_index = 0;
        unordered_request.pairs.push_back(pair);
        if (!plan.add_request(unordered_request, why) || !plan.freeze(why))
            `uvm_fatal("PLACEMENT", why)
        plan.list_targets(18, targets);
        plan.list_pairs(18, pairs);
        if (!dpu_same_function_key(targets[0].service_key.function_key,
                                   make_function_key(0, 1, DPU_FUNCTION_PF, 0)) ||
            (pairs[0].request_pair_index != 0) ||
            (pairs[1].request_pair_index != 1))
            `uvm_fatal("PLACEMENT", "normalized plan query order is not canonical")
    endfunction
endclass : dpu_placement_test

`endif // DPU_PLACEMENT_TEST_SV
