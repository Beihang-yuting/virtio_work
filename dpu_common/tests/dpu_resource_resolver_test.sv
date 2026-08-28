`ifndef DPU_RESOURCE_RESOLVER_TEST_SV
`define DPU_RESOURCE_RESOLVER_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_resource_resolver_test extends uvm_test;
    `uvm_component_utils(dpu_resource_resolver_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_function_key();
        dpu_function_key_t key;
        key.host_id = 0;
        key.pf_id = 0;
        key.kind = DPU_FUNCTION_PF;
        key.vf_id = 0;
        return key;
    endfunction

    function automatic dpu_device_snapshot make_device_snapshot(
        output dpu_service_key_t service_key,
        input int unsigned service_instance_id = 0,
        input bit add_second_vio_service = 0
    );
        dpu_device_snapshot snapshot;
        dpu_dut_caps caps;
        dpu_function_key_t function_key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bar;
        dpu_service_key_t second_service_key;
        string why;

        snapshot = dpu_device_snapshot::type_id::create("device_snapshot");
        caps = dpu_dut_caps::type_id::create("dut_caps");
        function_key = make_function_key();
        pcie_id.domain.host_id = 0;
        pcie_id.domain.segment_id = 0;
        pcie_id.bdf = 16'h0010;
        bar.role = DPU_BAR_DEVICE_MEMORY;
        bar.even_bar_id = 0;
        bar.base = 64'h0000_0001_0000_0000;
        bar.size = 64'h0000_0000_0200_0000;
        service_key.function_key = function_key;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = service_instance_id;
        if (!snapshot.set_dut_caps(caps, why) ||
            !snapshot.add_function(function_key, pcie_id, why) ||
            !snapshot.add_bar(function_key, bar, why) ||
            !snapshot.add_service(service_key, why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        if (add_second_vio_service) begin
            second_service_key = service_key;
            second_service_key.service_instance_id =
                (service_instance_id == 0) ? 1 : 0;
            if (!snapshot.add_service(second_service_key, why))
                `uvm_fatal("RESOURCE_SNAPSHOT", why)
        end
        if (!snapshot.set_expected_af(function_key, why) ||
            !snapshot.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return snapshot;
    endfunction

    function automatic dpu_normalized_placement_plan make_plan(
        input dpu_service_key_t service_key,
        input int unsigned effective_global_capacity = 128,
        input int unsigned effective_device_capacity = 32,
        input int unsigned total_qpairs = 1,
        input int unsigned participant_qpairs = 1
    );
        dpu_normalized_placement_plan plan;
        dpu_normalized_vio_request request;
        dpu_vio_participant_target_t target;
        dpu_normalized_vio_pair_t pair;
        dpu_resource_pool_config_t profile;
        int unsigned reservation_ids[$];
        dpu_global_id_range_t reservation_ranges[$];
        string why;

        plan = dpu_normalized_placement_plan::type_id::create("plan");
        plan.effective_global_capacity = effective_global_capacity;
        plan.effective_device_capacity = effective_device_capacity;
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        plan.set_profiles('{profile});
        reservation_ids.push_back(4);
        reservation_ranges.push_back('{first_id: 8, last_id: 9});
        plan.set_reservations(reservation_ids, reservation_ranges);
        request = dpu_normalized_vio_request::type_id::create("request");
        request.request_id = 3;
        request.service_instance_id = 0;
        request.total_qpairs = total_qpairs;
        request.seed = 17;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.ordering = DPU_PLACEMENT_CANONICAL;
        request.canonical_candidates.push_back(service_key.function_key);
        request.effective_candidates.push_back(service_key.function_key);
        target.request_id = 3;
        target.service_key = service_key;
        target.qpair_count = participant_qpairs;
        request.targets.push_back(target);
        for (int unsigned pair_index = 0; pair_index < total_qpairs;
             pair_index++) begin
            pair.request_pair_index = pair_index;
            pair.service_key = service_key;
            pair.local_mode = DPU_ASSIGN_AUTO;
            pair.requested_local_pair_id = 0;
            pair.global_mode = DPU_ASSIGN_AUTO;
            pair.requested_global_qpair_id = 0;
            request.pairs.push_back(pair);
        end
        if (!plan.add_request(request, why) || !plan.freeze(why))
            `uvm_fatal("RESOURCE_SNAPSHOT", why)
        return plan;
    endfunction

    function automatic void expect_freeze_failure(
        input string name,
        input dpu_normalized_placement_plan plan,
        input dpu_device_snapshot device_snapshot,
        input dpu_vio_qpair_binding_t binding,
        input dpu_placement_error_e expected_error,
        input bit expect_request_context,
        input bit expect_pair_context,
        input bit expect_service_context,
        input bit expect_function_context
    );
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;

        resource_snapshot = dpu_resource_snapshot::type_id::create(name);
        diagnostic = dpu_placement_diagnostic::type_id::create({name, "_diag"});
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        if (resource_snapshot.freeze(device_snapshot, diagnostic) ||
            (diagnostic.error_code != expected_error) ||
            (diagnostic.has_request_id != expect_request_context) ||
            (diagnostic.has_pair_index != expect_pair_context) ||
            (diagnostic.has_service_key != expect_service_context) ||
            (diagnostic.has_function_key != expect_function_context))
            `uvm_fatal("RESOURCE_SNAPSHOT", {name, " accepted invalid snapshot or lost diagnostic context"})
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_snapshot device_snapshot;
        dpu_normalized_placement_plan plan;
        dpu_resource_snapshot resource_snapshot;
        dpu_service_key_t service_key;
        dpu_placement_diagnostic diagnostic;
        dpu_vio_qpair_binding_t binding;
        dpu_vio_qpair_binding_t observed;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_normalized_vio_request request;
        dpu_normalized_vio_request request_again;
        int unsigned reservation_ids[$];
        dpu_vio_qpair_binding_t invalid_binding;
        dpu_device_snapshot nonzero_instance_snapshot;
        dpu_device_snapshot multiple_vio_snapshot;
        dpu_service_key_t nonzero_instance_service;
        dpu_service_key_t multiple_vio_service;
        dpu_placement_diagnostic null_diagnostic;

        super.build_phase(phase);
        device_snapshot = make_device_snapshot(service_key);
        plan = make_plan(service_key);
        diagnostic = dpu_placement_diagnostic::type_id::create("diagnostic");
        resource_snapshot = dpu_resource_snapshot::type_id::create(
            "resource_snapshot");
        binding.request_id = 3;
        binding.request_pair_index = 0;
        binding.service_key = service_key;
        binding.local_pair_id = 17;
        binding.rx_local_virtqueue_id = 34;
        binding.tx_local_virtqueue_id = 35;
        binding.global_qpair_id = 91;
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic) ||
            !resource_snapshot.freeze(device_snapshot, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        if (!resource_snapshot.get_vio_binding_by_global(91, observed) ||
            (observed.local_pair_id != 17))
            `uvm_fatal("RESOURCE_SNAPSHOT", "global reverse lookup disagrees")
        observed.local_pair_id = 0;
        if (!resource_snapshot.get_vio_binding(3, 0, observed) ||
            (observed.local_pair_id != 17))
            `uvm_fatal("RESOURCE_SNAPSHOT", "binding query leaked mutable state")
        resource_snapshot.list_vio_bindings(bindings);
        bindings[0].global_qpair_id = 0;
        resource_snapshot.list_vio_bindings(bindings);
        if ((bindings.size() != 1) || (bindings[0].global_qpair_id != 91))
            `uvm_fatal("RESOURCE_SNAPSHOT", "binding list leaked mutable state")
        if (!resource_snapshot.get_normalized_request(3, request))
            `uvm_fatal("RESOURCE_SNAPSHOT", "normalized request is missing")
        request.targets[0].qpair_count = 0;
        if (!resource_snapshot.get_normalized_request(3, request_again) ||
            (request_again.targets[0].qpair_count != 1))
            `uvm_fatal("RESOURCE_SNAPSHOT", "normalized request leaked mutable state")
        resource_snapshot.list_reserved_global_qpair_ids(reservation_ids);
        reservation_ids[0] = 0;
        resource_snapshot.list_reserved_global_qpair_ids(reservation_ids);
        if ((reservation_ids.size() != 1) || (reservation_ids[0] != 4))
            `uvm_fatal("RESOURCE_SNAPSHOT", "reservation query leaked mutable state")
        if (!resource_snapshot.references_device_snapshot(device_snapshot))
            `uvm_fatal("RESOURCE_SNAPSHOT", "device snapshot identity was not retained")
        if (resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", "frozen snapshot accepted a binding")

        invalid_binding = binding;
        invalid_binding.local_pair_id = 32;
        invalid_binding.rx_local_virtqueue_id = 64;
        invalid_binding.tx_local_virtqueue_id = 65;
        expect_freeze_failure("local_hard_limit", make_plan(service_key, 128, 33),
                              device_snapshot, invalid_binding,
                              DPU_PLACE_ERR_LOCAL_QID_OUT_OF_RANGE, 1, 1, 1, 0);

        invalid_binding = binding;
        invalid_binding.global_qpair_id = 2048;
        expect_freeze_failure("global_hard_limit", make_plan(service_key, 2049, 32),
                              device_snapshot, invalid_binding,
                              DPU_PLACE_ERR_GLOBAL_QID_OUT_OF_RANGE, 1, 1, 1, 0);

        expect_freeze_failure("participant_hard_limit",
                              make_plan(service_key, 128, 33, 33, 33),
                              device_snapshot, binding,
                              DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED,
                              1, 0, 1, 0);

        nonzero_instance_snapshot = make_device_snapshot(nonzero_instance_service, 1);
        invalid_binding = binding;
        invalid_binding.service_key = nonzero_instance_service;
        expect_freeze_failure("nonzero_service_instance",
                              make_plan(nonzero_instance_service),
                              nonzero_instance_snapshot, invalid_binding,
                              DPU_PLACE_ERR_INVALID_REQUEST, 1, 0, 1, 1);

        multiple_vio_snapshot = make_device_snapshot(multiple_vio_service, 0, 1);
        invalid_binding = binding;
        invalid_binding.service_key = multiple_vio_service;
        expect_freeze_failure("multiple_vio_services",
                              make_plan(multiple_vio_service), multiple_vio_snapshot,
                              invalid_binding, DPU_PLACE_ERR_INVALID_REQUEST,
                              1, 0, 1, 1);

        resource_snapshot = dpu_resource_snapshot::type_id::create("null_diagnostic");
        if (!resource_snapshot.set_normalized_plan(plan, diagnostic) ||
            !resource_snapshot.add_vio_binding(binding, diagnostic))
            `uvm_fatal("RESOURCE_SNAPSHOT", diagnostic.message)
        null_diagnostic = null;
        if (resource_snapshot.freeze(null, null_diagnostic) ||
            (null_diagnostic == null) ||
            (null_diagnostic.error_code != DPU_PLACE_ERR_SNAPSHOT_REFERENCE_MISMATCH))
            `uvm_fatal("RESOURCE_SNAPSHOT", "failure did not publish a usable diagnostic")
    endfunction
endclass : dpu_resource_resolver_test

`endif // DPU_RESOURCE_RESOLVER_TEST_SV
