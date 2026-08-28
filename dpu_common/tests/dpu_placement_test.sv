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
        input int unsigned host_id,
        input int unsigned pf_id,
        input dpu_function_kind_e kind,
        input int unsigned vf_id
    );
        dpu_function_key_t key;

        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_resource_placement_cfg source;
        dpu_resource_placement_cfg clone;
        dpu_vio_placement_request request;
        dpu_global_id_range_t reserved;
        dpu_device_cfg cfg;
        dpu_device_cfg device_clone;
        dpu_function_cfg function_cfg;
        dpu_vf_pool_cfg pool;
        dpu_vf_template_cfg template;

        super.build_phase(phase);
        source = dpu_resource_placement_cfg::type_id::create("source");
        request = dpu_vio_placement_request::type_id::create("request");
        request.request_id = 7;
        request.total_qpairs = 100;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        request.device_policy = DPU_VIO_DEVICE_AUTO_MINIMUM;
        source.vio_requests.push_back(request);
        reserved.first_id = 9;
        reserved.last_id = 12;
        source.reserved_global_qpair_ranges.push_back(reserved);
        clone = dpu_resource_placement_cfg::type_id::create("clone");
        clone.copy_from(source);
        clone.vio_requests[0].total_qpairs = 1;
        clone.reserved_global_qpair_ranges[0].first_id = 10;
        if ((source.vio_requests[0].total_qpairs != 100) ||
            (source.reserved_global_qpair_ranges[0].first_id != 9))
            `uvm_fatal("PLACEMENT", "placement clone aliases its source")

        cfg = dpu_device_cfg::type_id::create("cfg");
        function_cfg = dpu_function_cfg::type_id::create("pf2");
        function_cfg.key = make_function_key(0, 2, DPU_FUNCTION_PF, 0);
        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_RDMA);
        if ((function_cfg.services.size() != 0) ||
            !dpu_service_kind_is_eligible(function_cfg.eligible_service_kinds,
                                          DPU_SERVICE_VIO_NET) ||
            !dpu_service_kind_is_eligible(function_cfg.eligible_service_kinds,
                                          DPU_SERVICE_RDMA))
            `uvm_fatal("PLACEMENT", "explicit eligibility is not separate from services")
        pool = dpu_vf_pool_cfg::type_id::create("pf2_pool");
        pool.parent_pf = make_function_key(0, 2, DPU_FUNCTION_PF, 0);
        template = dpu_vf_template_cfg::type_id::create("vf7_template");
        template.vf_id = 7;
        template.domain_key.host_id = 0;
        template.domain_key.segment_id = 0;
        template.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        pool.vf_templates.push_back(template);
        cfg.vf_pools.push_back(pool);
        device_clone = dpu_device_cfg::type_id::create("device_clone");
        device_clone.copy_from(cfg);
        device_clone.vf_pools[0].vf_templates[0].vf_id = 9;
        if (cfg.vf_pools[0].vf_templates[0].vf_id != 7)
            `uvm_fatal("PLACEMENT", "VF template clone aliases its source")
    endfunction
endclass : dpu_placement_test

`endif // DPU_PLACEMENT_TEST_SV
