`ifndef DPU_RESOURCE_MANAGER_TEST_SV
`define DPU_RESOURCE_MANAGER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

// ============================================================================
// dpu_resource_manager_test
//
// Defines the topology boundary contract for the future resource manager:
// 4 hosts x 16 PFs plus 60 x 16 VFs consume all 1024 function identities.
// The manager implementation is intentionally deferred to Task 3.
// ============================================================================

class dpu_resource_manager_test extends uvm_test;
    `uvm_component_utils(dpu_resource_manager_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key(
        int unsigned host_id,
        int unsigned pf_id,
        dpu_function_kind_e kind,
        int unsigned vf_id
    );
        dpu_function_key_t key;

        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    virtual task run_phase(uvm_phase phase);
        dpu_resource_manager manager;
        dpu_function_key_t key;
        string why;

        phase.raise_objection(this);
        manager = dpu_resource_manager::type_id::create("manager");

        for (int unsigned host_id = 0; host_id < DPU_MAX_HOSTS; host_id++) begin
            for (int unsigned pf_id = 0; pf_id < DPU_MAX_PFS_PER_HOST; pf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_PF, 0);
                if (!manager.register_function(key, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "PF registration failed for host %0d PF %0d: %s",
                        host_id, pf_id, why))
                end
            end
        end

        for (int unsigned function_index = 0; function_index < 60; function_index++) begin
            int unsigned host_id;
            int unsigned pf_id;

            host_id = function_index / DPU_MAX_PFS_PER_HOST;
            pf_id = function_index % DPU_MAX_PFS_PER_HOST;
            for (int unsigned vf_id = 0; vf_id < DPU_MAX_VFS_PER_PF; vf_id++) begin
                key = make_function_key(host_id, pf_id, DPU_FUNCTION_VF, vf_id);
                if (!manager.register_function(key, why)) begin
                    `uvm_fatal("DPU_RESOURCE", $sformatf(
                        "VF registration failed for host %0d PF %0d VF %0d: %s",
                        host_id, pf_id, vf_id, why))
                end
            end
        end

        key = make_function_key(3, 12, DPU_FUNCTION_VF, 0);
        if (manager.register_function(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "the 961st VF registration unexpectedly succeeded")
        end

        key = make_function_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.validate_vf_key(key, why)) begin
            `uvm_fatal("DPU_RESOURCE", "VF key with vf_id == 16 unexpectedly validated")
        end

        phase.drop_objection(this);
    endtask

endclass : dpu_resource_manager_test

`endif // DPU_RESOURCE_MANAGER_TEST_SV
