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

    virtual function void build_phase(uvm_phase phase);
        dpu_resource_placement_cfg source;
        dpu_resource_placement_cfg clone;
        dpu_vio_placement_request request;
        dpu_global_id_range_t reserved;

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
    endfunction
endclass : dpu_placement_test

`endif // DPU_PLACEMENT_TEST_SV
