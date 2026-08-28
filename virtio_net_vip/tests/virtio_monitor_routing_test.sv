`ifndef VIRTIO_MONITOR_ROUTING_TEST_SV
`define VIRTIO_MONITOR_ROUTING_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

class virtio_monitor_corruptible_resource_snapshot extends dpu_resource_snapshot;
    `uvm_object_utils(virtio_monitor_corruptible_resource_snapshot)

    function new(string name = "virtio_monitor_corruptible_resource_snapshot");
        super.new(name);
    endfunction

    function bit force_service_global_pair(
        input dpu_service_key_t service_key,
        input int unsigned global_pair_id
    );
        foreach (m_bindings[index]) begin
            if (dpu_service_key_name(m_bindings[index].service_key) ==
                dpu_service_key_name(service_key)) begin
                m_bindings[index].global_qpair_id = global_pair_id;
                return 1;
            end
        end
        return 0;
    endfunction
endclass : virtio_monitor_corruptible_resource_snapshot

// Captures the semantic events emitted by an individual virtio function.
// Keeping one collector per function makes the routing contract observable:
// a shared PCIe monitor stream must reach exactly its addressed function.
class virtio_monitor_routing_collector extends uvm_subscriber #(virtio_transaction);
    `uvm_component_utils(virtio_monitor_routing_collector)

    int unsigned count;
    virtio_transaction transactions[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void write(virtio_transaction t);
        count++;
        transactions.push_back(t);
    endfunction
endclass : virtio_monitor_routing_collector

// Queue-reset rejection is a required negative observation.  Catch only the
// expected semantic monitor reports so the regression can prove both resets
// reject a subsequent notification without leaving an unhandled UVM_ERROR.
class virtio_monitor_routing_error_catcher extends uvm_report_catcher;
    int unsigned monitor_errors;

    function new(string name = "virtio_monitor_routing_error_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_id() == "VIRTIO_MON") && (get_severity() == UVM_ERROR)) begin
            monitor_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_error_catcher

// The PF/VF isolation trace deliberately violates only the VF DRIVER_OK
// dependency.  Keep that expected SVA diagnostic scoped to the injection so
// any other protocol error remains visible to the global report server.
class virtio_monitor_routing_protocol_sva_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_monitor_routing_protocol_sva_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "VIRTIO_PROTOCOL_SVA") &&
            (get_message() == "DRIVER_OK observed before FEATURES_OK")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_protocol_sva_catcher

// Queue-reset negative traffic intentionally generates only the disabled
// queue-notify SVA.  Keep that expected diagnostic scoped to this subtest.
class virtio_monitor_routing_disabled_notify_sva_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_monitor_routing_disabled_notify_sva_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "VIRTIO_PROTOCOL_SVA") &&
            (get_message() == "notify observed for a disabled queue")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_disabled_notify_sva_catcher

// Calls configure_services() during the owning test's build phase but does
// not manufacture compatibility children if the preflight is rejected.
class virtio_service_preflight_probe extends virtio_pf_instance;
    `uvm_component_utils(virtio_service_preflight_probe)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
    endfunction
endclass : virtio_service_preflight_probe

// Exposes the real main-environment topology builder without running the
// rest of the environment build. An empty exact resource snapshot must be a
// hard failure, never an implicit legacy allocation selector.
class virtio_resource_topology_probe extends virtio_net_env;
    `uvm_component_utils(virtio_resource_topology_probe)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
    endfunction

    function bit configure_and_build(
        input dpu_device_snapshot exact_device_snapshot,
        input dpu_resource_snapshot exact_resource_snapshot,
        input dpu_resource_manager exact_manager,
        output string why
    );
        device_snapshot = exact_device_snapshot;
        resource_snapshot = exact_resource_snapshot;
        device_resource_manager = exact_manager;
        return build_snapshot_topology(why);
    endfunction
endclass : virtio_resource_topology_probe

// Exercises the public virtio_net_env PCIe binding with two Fabric functions.
// A TLP emitted on the external endpoint monitor is addressed only by the PF
// BAR range; the VF must neither observe it nor classify it as DMA.
class virtio_monitor_routing_test extends uvm_test;
    `uvm_component_utils(virtio_monitor_routing_test)

    pcie_tl_env                    pcie_env;
    pcie_tl_env                    reused_pcie_env;
    dpu_device_env                 device_env;
    virtio_net_env                 virtio_env;
    pcie_tl_env_config             pcie_cfg;
    pcie_tl_env_config             reused_pcie_cfg;
    dpu_device_env_config          device_env_cfg;
    virtio_net_env_config          virtio_cfg;
    virtio_test_device_builder     device_builder;
    virtio_tlm_completion_adapter  tlm_adapter;
    virtio_monitor_routing_collector pf_collector;
    virtio_monitor_routing_collector vf_collector;
    virtio_monitor_routing_collector reused_domain_collector;

    localparam bit [15:0] PF_BDF       = 16'h0128;
    localparam bit [15:0] VF_BDF       = 16'h02e0;
    localparam bit [63:0] PF_BAR0_BASE = 64'h0000_0002_0000_0000;
    localparam bit [63:0] PF_BAR2_BASE = 64'h0000_0002_0200_0000;
    localparam bit [63:0] PF_BAR4_BASE = 64'h0000_0002_0201_0000;
    localparam bit [63:0] VF_BAR0_BASE = 64'h0000_0002_0202_0000;
    localparam bit [63:0] VF_BAR2_BASE = 64'h0000_0002_0202_4000;
    localparam bit [63:0] VF_BAR4_BASE = 64'h0000_0002_0202_8000;
    localparam bit [31:0] COMMON_OFF   = 32'h0000_0100;
    localparam bit [31:0] COMMON_LEN   = 32'h0000_0040;
    localparam bit [31:0] NOTIFY_OFF   = 32'h0000_0200;
    localparam bit [31:0] NOTIFY_LEN   = 32'h0000_0040;
    localparam bit [63:0] PF_MSIX_ADDR = 64'h0000_0000_FEE0_0450;
    localparam bit [31:0] PF_MSIX_DATA = 32'h0000_0045;
    localparam bit [31:0] DOMAIN_MMIO_OFF = 32'h0000_0800;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    protected function void pin_real_dut_bars(
        input dpu_function_cfg function_cfg,
        input bit [63:0] device_base,
        input bit [63:0] mailbox_base,
        input bit [63:0] msix_base
    );
        bit [63:0] bases[3];

        bases[0] = device_base;
        bases[1] = mailbox_base;
        bases[2] = msix_base;
        device_builder.add_real_dut_bars(function_cfg);
        foreach (function_cfg.bars[index]) begin
            function_cfg.bars[index].placement = DPU_ALLOC_PINNED;
            function_cfg.bars[index].pinned_base = bases[index];
        end
    endfunction

    protected function virtio_function_instance find_vio_function(
        input dpu_function_key_t key
    );
        foreach (virtio_env.function_instances[index]) begin
            if (dpu_same_function_key(
                    virtio_env.function_instances[index].function_key, key)) begin
                return virtio_env.function_instances[index];
            end
        end
        return null;
    endfunction

    protected function dpu_service_key_t allow_vio_service(
        input dpu_function_cfg function_cfg
    );
        dpu_service_key_t key;

        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        key.function_key = function_cfg.key;
        key.service_kind = DPU_SERVICE_VIO_NET;
        key.service_instance_id = 0;
        return key;
    endfunction

    protected function void author_snapshot_qpair_placement(
        input dpu_function_key_t sparse_owner
    );
        dpu_vio_placement_request request;
        dpu_vio_device_constraint count_rule;
        dpu_vio_qpair_override override;
        int unsigned sparse_locals[3] = '{0, 3, 17};
        int unsigned sparse_globals[3] = '{30, 33, 47};

        request = dpu_vio_placement_request::type_id::create(
            "routing_snapshot_qpair_request");
        request.request_id = 2000;
        request.total_qpairs = 5;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        foreach (device_env_cfg.device_cfg.functions[index]) begin
            request.fixed_devices.push_back(
                device_env_cfg.device_cfg.functions[index].key);
            count_rule = dpu_vio_device_constraint::type_id::create(
                $sformatf("routing_exact_qpairs_%0d", index));
            count_rule.function_key = device_env_cfg.device_cfg.functions[index].key;
            count_rule.mode = DPU_COUNT_EXACT;
            count_rule.qpair_count = dpu_same_function_key(
                count_rule.function_key, sparse_owner) ? 3 : 1;
            request.device_constraints.push_back(count_rule);
        end
        foreach (sparse_locals[index]) begin
            override = dpu_vio_qpair_override::type_id::create(
                $sformatf("routing_sparse_qpair_%0d", index));
            override.request_pair_index = index;
            override.owner_mode = DPU_ASSIGN_PINNED;
            override.requested_owner = sparse_owner;
            override.local_mode = DPU_ASSIGN_PINNED;
            override.requested_local_pair_id = sparse_locals[index];
            override.global_mode = DPU_ASSIGN_PINNED;
            override.requested_global_qpair_id = sparse_globals[index];
            request.qpair_overrides.push_back(override);
        end
        device_env_cfg.placement_cfg.vio_requests.push_back(request);
    endfunction

    // Breaks caught: the client accepts a null, unfrozen, or cross-paired
    // resource snapshot and publishes partial binding state.
    protected function bit check_service_bind_requires_exact_pair();
        virtio_resource_client client;
        dpu_device_snapshot snapshot;
        dpu_device_snapshot alternate_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_resource_snapshot alternate_resource_snapshot;
        dpu_resource_snapshot unfrozen_resource_snapshot;
        dpu_device_env_config env_cfg;
        dpu_device_env_config alternate_env_cfg;
        dpu_resource_manager manager;
        dpu_resource_manager alternate_manager;
        dpu_function_key_t parent_key;
        dpu_function_key_t alternate_parent_key;
        dpu_service_key_t service_keys[$];
        dpu_service_key_t alternate_service_keys[$];
        string why;

        if (!resolve_probe_snapshot(
                "exact_pair_probe", 1, snapshot, resource_snapshot, env_cfg,
                manager, parent_key, service_keys) ||
            !resolve_probe_snapshot(
                "alternate_pair_probe", 1, alternate_snapshot,
                alternate_resource_snapshot, alternate_env_cfg,
                alternate_manager, alternate_parent_key,
                alternate_service_keys)) begin
            return 0;
        end
        client = virtio_resource_client::type_id::create(
            "exact_pair_probe_client");
        unfrozen_resource_snapshot = dpu_resource_snapshot::type_id::create(
            "unfrozen_resource_snapshot");
        if (client.bind_to_service(
                null, resource_snapshot, service_keys[0], why) ||
            client.bind_to_service(
                snapshot, unfrozen_resource_snapshot, service_keys[0], why) ||
            client.bind_to_service(
                snapshot, alternate_resource_snapshot,
                service_keys[0], why) ||
            client.is_bound_to_service()) begin
            `uvm_error("EXACT_PAIR_BIND",
                "resource client accepted an invalid pair or retained state")
            return 0;
        end
        return 1;
    endfunction

    protected function bit resolve_probe_snapshot(
        input string label,
        input bit add_vf_bars,
        output dpu_device_snapshot snapshot,
        output dpu_resource_snapshot resource_snapshot,
        output dpu_device_env_config env_cfg,
        output dpu_resource_manager manager,
        output dpu_function_key_t parent_key,
        ref dpu_service_key_t service_keys[$]
    );
        virtio_test_device_builder builder;
        dpu_function_cfg pf_cfg;
        dpu_function_cfg vf_cfg;
        dpu_function_key_t fixed_devices[$];
        dpu_configuration_resolver resolver;
        dpu_placement_diagnostic diagnostic;
        dpu_resource_registry_authority authority;
        string why;

        builder = virtio_test_device_builder::type_id::create(
            {label, "_builder"});
        void'(builder.add_host_domain(0, 0, 16'h0100, 16'h03ff,
            64'h0000_0002_0000_0000, 64'h0000_0003_0000_0000));
        pf_cfg = builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, 16'h0128);
        vf_cfg = builder.add_vf(
            0, 0, 0, 0, DPU_ALLOC_PINNED, 16'h02e0);
        builder.add_real_dut_bars(pf_cfg);
        if (add_vf_bars)
            builder.add_real_dut_bars(vf_cfg);
        void'(builder.allow_vio_service(pf_cfg));
        void'(builder.allow_vio_service(vf_cfg));
        fixed_devices.push_back(pf_cfg.key);
        fixed_devices.push_back(vf_cfg.key);
        void'(builder.add_fixed_vio_request(0, fixed_devices, 2));
        builder.select_af(pf_cfg);
        env_cfg = builder.make_env_config();
        resolver = dpu_configuration_resolver::type_id::create(
            {label, "_resolver"});
        if (!resolver.resolve(
                env_cfg.device_cfg, env_cfg.placement_cfg, snapshot,
                resource_snapshot, diagnostic)) begin
            `uvm_fatal("FIX1_SETUP", $sformatf(
                "could not resolve %s snapshot pair: %s",
                label, diagnostic.message))
            return 0;
        end
        manager = dpu_resource_manager::type_id::create({label, "_manager"});
        authority = manager.claim_registry_authority();
        if ((authority == null) || !manager.configure_from_snapshots(
                authority, snapshot, resource_snapshot, why)) begin
            `uvm_fatal("FIX1_SETUP", $sformatf(
                "could not import %s snapshot pair: %s", label, why))
            return 0;
        end
        snapshot.list_services(DPU_SERVICE_VIO_NET, service_keys);
        parent_key = pf_cfg.key;
        return 1;
    endfunction

    protected function bit make_empty_resource_pair(
        input string label,
        input dpu_device_snapshot snapshot,
        input dpu_device_env_config env_cfg,
        output dpu_resource_snapshot empty_resource,
        output dpu_resource_manager manager
    );
        dpu_normalized_placement_plan plan;
        dpu_placement_diagnostic diagnostic;
        dpu_resource_registry_authority authority;
        string why;

        plan = dpu_normalized_placement_plan::type_id::create(
            {label, "_empty_plan"});
        plan.effective_global_capacity =
            env_cfg.placement_cfg.profiles[0].capacity;
        plan.effective_device_capacity =
            env_cfg.placement_cfg.profiles[0].max_per_function;
        plan.set_profiles(env_cfg.placement_cfg.profiles);
        if (!plan.freeze(why)) begin
            `uvm_fatal("FIX1_SETUP", {"could not freeze empty plan: ", why})
            return 0;
        end
        empty_resource = dpu_resource_snapshot::type_id::create(
            {label, "_empty_resource"});
        diagnostic = dpu_placement_diagnostic::type_id::create(
            {label, "_empty_diagnostic"});
        if (!empty_resource.set_normalized_plan(plan, diagnostic) ||
            !empty_resource.freeze(snapshot, diagnostic)) begin
            `uvm_fatal("FIX1_SETUP",
                {"could not freeze empty resource snapshot: ", diagnostic.message})
            return 0;
        end
        manager = dpu_resource_manager::type_id::create({label, "_manager"});
        authority = manager.claim_registry_authority();
        if ((authority == null) || !manager.configure_from_snapshots(
                authority, snapshot, empty_resource, why)) begin
            `uvm_fatal("FIX1_SETUP",
                {"could not seed empty snapshot pair: ", why})
            return 0;
        end
        return 1;
    endfunction

    // Break caught: the main environment sees an exact empty resource
    // snapshot and silently routes VIO services through legacy allocation.
    protected function bit check_empty_resource_snapshot_is_rejected();
        dpu_device_snapshot snapshot;
        dpu_resource_snapshot resolved_resource;
        dpu_resource_snapshot empty_resource;
        dpu_device_env_config env_cfg;
        dpu_resource_manager resolved_manager;
        dpu_resource_manager manager;
        dpu_function_key_t parent_key;
        dpu_service_key_t service_keys[$];
        virtio_resource_topology_probe probe;
        string why;

        if (!resolve_probe_snapshot(
                "fix_round1_empty_resource", 1, snapshot, resolved_resource,
                env_cfg, resolved_manager, parent_key, service_keys) ||
            !make_empty_resource_pair(
                "fix_round1_empty_resource", snapshot, env_cfg,
                empty_resource, manager)) begin
            return 0;
        end
        probe = virtio_resource_topology_probe::type_id::create(
            "fix_round1_empty_resource_probe", this);
        if (probe.configure_and_build(snapshot, empty_resource, manager, why) ||
            (probe.pf_instances.size() != 0)) begin
            `uvm_error("FIX_ROUND1_EMPTY_RESOURCE",
                "main VIO environment accepted an exact empty resource snapshot")
            return 0;
        end
        return 1;
    endfunction

    // Break caught: a later service fails BAR validation after the earlier PF
    // child has already been constructed.
    protected function bit check_late_bar_failure_is_atomic();
        dpu_device_snapshot snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_device_env_config env_cfg;
        dpu_resource_manager manager;
        dpu_function_key_t parent_key;
        dpu_service_key_t service_keys[$];
        virtio_service_preflight_probe probe;
        string why;
        bit configured;

        if (!resolve_probe_snapshot(
                "fix1_missing_vf_bar", 0, snapshot, resource_snapshot,
                env_cfg, manager, parent_key, service_keys)) begin
            return 0;
        end
        probe = virtio_service_preflight_probe::type_id::create(
            "fix1_missing_vf_bar_probe", this);
        configured = probe.configure_services(
            parent_key, snapshot, resource_snapshot,
            service_keys, manager, why);
        if (configured || (probe.pf_function != null) ||
            (probe.vf_functions.size() != 0)) begin
            `uvm_error("FIX1_SERVICE_ATOMIC",
                {"late missing BAR did not reject before all PF/VF child ",
                 "construction"})
            return 0;
        end
        return 1;
    endfunction

    // Break caught: group construction begins before qpair and manager
    // authority dependencies have been validated.
    protected function bit check_manager_dependencies_are_preflighted();
        dpu_device_snapshot snapshot;
        dpu_device_snapshot alternate_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_resource_snapshot alternate_resource_snapshot;
        dpu_device_env_config env_cfg;
        dpu_device_env_config alternate_env_cfg;
        dpu_resource_manager manager;
        dpu_resource_manager alternate_manager;
        dpu_function_key_t parent_key;
        dpu_function_key_t alternate_parent_key;
        dpu_service_key_t service_keys[$];
        dpu_service_key_t alternate_service_keys[$];
        virtio_service_preflight_probe null_manager_probe;
        virtio_service_preflight_probe mismatch_probe;
        string why;
        bit configured;
        bit passed;

        if (!resolve_probe_snapshot(
                "fix1_manager_preflight", 1, snapshot, resource_snapshot,
                env_cfg, manager, parent_key, service_keys) ||
            !resolve_probe_snapshot(
                "fix1_manager_preflight_alternate", 1, alternate_snapshot,
                alternate_resource_snapshot, alternate_env_cfg,
                alternate_manager, alternate_parent_key,
                alternate_service_keys)) begin
            return 0;
        end
        null_manager_probe = virtio_service_preflight_probe::type_id::create(
            "fix1_null_manager_probe", this);
        passed = 1;
        configured = null_manager_probe.configure_services(
            parent_key, snapshot, resource_snapshot,
            service_keys, null, why);
        if (configured || (null_manager_probe.pf_function != null) ||
            (null_manager_probe.vf_functions.size() != 0)) begin
            `uvm_error("EXACT_NULL_MANAGER_PREFLIGHT",
                "null manager was not rejected before PF/VF construction")
            passed = 0;
        end

        mismatch_probe = virtio_service_preflight_probe::type_id::create(
            "fix1_mismatched_manager_probe", this);
        configured = mismatch_probe.configure_services(
            parent_key, snapshot, resource_snapshot,
            service_keys, alternate_manager, why);
        if (configured || (mismatch_probe.pf_function != null) ||
            (mismatch_probe.vf_functions.size() != 0)) begin
            `uvm_error("EXACT_MISMATCH_PREFLIGHT",
                "mismatched manager was not rejected before PF/VF construction")
            passed = 0;
        end
        return passed;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg pf_cfg;
        dpu_function_cfg vf_cfg;
        dpu_function_cfg reused_pf_cfg;
        dpu_service_key_t pf_service_key;
        dpu_service_key_t vf_service_key;
        dpu_service_key_t reused_pf_service_key;
        virtio_driver_config_t pf_behavior;
        virtio_driver_config_t vf_behavior;
        virtio_driver_config_t reused_pf_behavior;
        string why;
        bit fix1_checks_passed;

        super.build_phase(phase);

        fix1_checks_passed = check_service_bind_requires_exact_pair();
        fix1_checks_passed = check_late_bar_failure_is_atomic() &&
                             fix1_checks_passed;
        fix1_checks_passed = check_manager_dependencies_are_preflighted() &&
                             fix1_checks_passed;
        fix1_checks_passed = check_empty_resource_snapshot_is_rejected() &&
                             fix1_checks_passed;
        if (!fix1_checks_passed) begin
            `uvm_fatal("FIX1_RED",
                "snapshot device binding/service preflight checks failed")
            return;
        end

        // Both TLM roots use the same completion bridge.  The endpoint bind
        // below must retain the selected PCIe domain when equal tag/BDF values
        // are in flight concurrently.
        tlm_adapter = virtio_tlm_completion_adapter::type_id::create(
            "domain_tlm_adapter");
        tlm_adapter.install_factory_overrides();

        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 1;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = UVM_ACTIVE;
        pcie_cfg.ep_auto_response = 1;
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.scb_enable = 0;
        pcie_cfg.cov_enable = 0;
        pcie_cfg.response_delay_min = 20;
        pcie_cfg.response_delay_max = 20;
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        reused_pcie_cfg = pcie_tl_env_config::type_id::create(
            "reused_pcie_cfg");
        reused_pcie_cfg.if_mode = TLM_MODE;
        reused_pcie_cfg.rc_agent_enable = 1;
        reused_pcie_cfg.ep_agent_enable = 1;
        reused_pcie_cfg.rc_is_active = UVM_ACTIVE;
        reused_pcie_cfg.ep_is_active = UVM_ACTIVE;
        reused_pcie_cfg.ep_auto_response = 1;
        reused_pcie_cfg.infinite_credit = 1;
        reused_pcie_cfg.scb_enable = 0;
        reused_pcie_cfg.cov_enable = 0;
        reused_pcie_cfg.response_delay_min = 0;
        reused_pcie_cfg.response_delay_max = 0;
        uvm_config_db#(pcie_tl_env_config)::set(
            this, "reused_pcie_env", "cfg", reused_pcie_cfg);
        reused_pcie_env = pcie_tl_env::type_id::create(
            "reused_pcie_env", this);

        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        dpu_resource_snapshot::type_id::set_type_override(
            virtio_monitor_corruptible_resource_snapshot::get_type());
        void'(device_builder.add_host_domain(0, 0, 16'h0100, 16'h03ff,
            64'h0000_0002_0000_0000, 64'h0000_0003_0000_0000));
        void'(device_builder.add_host_domain(1, 0, 16'h0100, 16'h03ff,
            64'h0000_0002_0000_0000, 64'h0000_0003_0000_0000));
        pf_cfg = device_builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, PF_BDF);
        vf_cfg = device_builder.add_vf(
            0, 0, 0, 0, DPU_ALLOC_PINNED, VF_BDF);
        pin_real_dut_bars(
            pf_cfg, PF_BAR0_BASE, PF_BAR2_BASE, PF_BAR4_BASE);
        device_builder.add_real_dut_bars(vf_cfg);
        pf_service_key = allow_vio_service(pf_cfg);
        vf_service_key = allow_vio_service(vf_cfg);
        reused_pf_cfg = device_builder.add_pf(
            1, 0, 0, DPU_ALLOC_PINNED, PF_BDF);
        pin_real_dut_bars(
            reused_pf_cfg, PF_BAR0_BASE, PF_BAR2_BASE, PF_BAR4_BASE);
        reused_pf_service_key = allow_vio_service(reused_pf_cfg);
        device_builder.select_af(pf_cfg);
        device_env_cfg = device_builder.make_env_config();
        author_snapshot_qpair_placement(pf_cfg.key);

        virtio_cfg = virtio_net_env_config::type_id::create("virtio_cfg");
        virtio_cfg.scb_enable = 1;
        virtio_cfg.cov_enable = 1;
        pf_behavior = virtio_cfg.make_default_driver_config(32);
        pf_behavior.num_queue_pairs = 3;
        vf_behavior = virtio_cfg.make_default_driver_config(32);
        vf_behavior.num_queue_pairs = 5;
        reused_pf_behavior = virtio_cfg.make_default_driver_config(32);
        reused_pf_behavior.num_queue_pairs = 7;
        if (!virtio_cfg.add_service_config(
                pf_service_key, pf_behavior, why)) begin
            `uvm_fatal("ROUTING_TEST", {"could not author PF behavior: ", why})
            return;
        end
        if (!virtio_cfg.add_service_config(
                vf_service_key, vf_behavior, why)) begin
            `uvm_fatal("ROUTING_TEST", {"could not author VF behavior: ", why})
            return;
        end
        if (!virtio_cfg.add_service_config(
                reused_pf_service_key, reused_pf_behavior, why)) begin
            `uvm_fatal("ROUTING_TEST",
                {"could not author reused-domain PF behavior: ", why})
            return;
        end

        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_env_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.virtio_env", "cfg", virtio_cfg);
        virtio_env = virtio_net_env::type_id::create("virtio_env", device_env);

        pf_collector = virtio_monitor_routing_collector::type_id::create(
            "pf_collector", this);
        vf_collector = virtio_monitor_routing_collector::type_id::create(
            "vf_collector", this);
        reused_domain_collector =
            virtio_monitor_routing_collector::type_id::create(
                "reused_domain_collector", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        dpu_device_snapshot snapshot;
        dpu_function_key_t host0_pf_key;
        dpu_function_key_t host1_pf_key;
        dpu_pcie_function_id_t host0_pf_pcie;
        dpu_pcie_function_id_t host0_vf_pcie;
        dpu_pcie_function_id_t host1_pf_pcie;
        virtio_pcie_function_endpoint endpoints[$];
        virtio_pcie_function_endpoint endpoint;
        virtio_function_instance reused_pf;
        string why;

        super.connect_phase(phase);

        if ((virtio_env.pf_instances.size() != 2) ||
            (virtio_env.pf_instances[0] == null) ||
            (virtio_env.pf_instances[0].pf_function == null) ||
            (virtio_env.pf_instances[0].vf_functions.size() != 1)) begin
            `uvm_fatal("MON_ROUTE",
                "VIO environment did not consume the parent device snapshot")
            return;
        end

        host0_pf_key.host_id = 0;
        host0_pf_key.pf_id = 0;
        host0_pf_key.kind = DPU_FUNCTION_PF;
        host0_pf_key.vf_id = 0;
        host1_pf_key = host0_pf_key;
        host1_pf_key.host_id = 1;
        snapshot = device_env.get_snapshot();
        reused_pf = find_vio_function(host1_pf_key);
        if ((snapshot == null) || (reused_pf == null) ||
            !snapshot.get_pcie_id(host0_pf_key, host0_pf_pcie, why) ||
            !snapshot.get_pcie_id(
                virtio_env.pf_instances[0].vf_functions[0].function_key,
                host0_vf_pcie, why) ||
            !snapshot.get_pcie_id(host1_pf_key, host1_pf_pcie, why)) begin
            `uvm_fatal("MON_ROUTE", {"could not resolve endpoint identities: ", why})
            return;
        end

        endpoint = virtio_pcie_function_endpoint::type_id::create(
            "host0_pf_endpoint");
        endpoint.configure(host0_pf_pcie, pcie_env.rc_agent.sequencer,
            pcie_env.rc_agent.rc_driver, tlm_adapter,
            pcie_env.rc_agent.monitor, pcie_env.ep_agent.monitor);
        endpoints.push_back(endpoint);
        endpoint = virtio_pcie_function_endpoint::type_id::create(
            "host0_vf_endpoint");
        endpoint.configure(host0_vf_pcie, pcie_env.rc_agent.sequencer,
            pcie_env.rc_agent.rc_driver, tlm_adapter,
            pcie_env.rc_agent.monitor, pcie_env.ep_agent.monitor);
        endpoints.push_back(endpoint);
        endpoint = virtio_pcie_function_endpoint::type_id::create(
            "host1_pf_endpoint");
        endpoint.configure(host1_pf_pcie, reused_pcie_env.rc_agent.sequencer,
            reused_pcie_env.rc_agent.rc_driver, tlm_adapter,
            reused_pcie_env.rc_agent.monitor,
            reused_pcie_env.ep_agent.monitor);
        endpoints.push_back(endpoint);

        // Public binding must select the configured endpoint with the complete
        // {host, segment, BDF} identity.  Equal numeric BDF/BAR values in the
        // two domains are intentional.
        if (!virtio_env.bind_pcie_endpoints(endpoints)) begin
            `uvm_fatal("MON_ROUTE", "failed to bind virtio environment to PCIe")
            return;
        end

        virtio_env.pf_instances[0].pf_function.driver_agent.monitor.txn_ap.connect(
            pf_collector.analysis_export);
        virtio_env.pf_instances[0].vf_functions[0].driver_agent.monitor.txn_ap.connect(
            vf_collector.analysis_export);
        reused_pf.driver_agent.monitor.txn_ap.connect(
            reused_domain_collector.analysis_export);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_function_instance pf;
        virtio_function_instance vf;
        virtio_function_instance reused_pf;
        dpu_function_key_t reused_pf_key;
        dpu_service_key_t reverse_service_key;
        int unsigned reverse_local_qid;
        pcie_tl_mem_tlp tlp;
        int unsigned snapshot_global_qid;

        phase.raise_objection(this);
        @(posedge virtio_tb_top.rst_n);
        @(posedge virtio_tb_top.clk);

        pf = virtio_env.pf_instances[0].pf_function;
        vf = virtio_env.pf_instances[0].vf_functions[0];
        reused_pf_key = pf.function_key;
        reused_pf_key.host_id = 1;
        reused_pf = find_vio_function(reused_pf_key);
        if (!pf.resource_client.local_qid_to_global_qid(
                6, snapshot_global_qid) || (snapshot_global_qid != 66)) begin
            `uvm_fatal("ROUTING_TEST",
                "immediate sparse pair 3 mapping did not come from snapshot")
        end
        if (!virtio_env.pf_instances[0].pf_manager.resource_pool.
                local_to_global_for_service(
                    pf.service_key, 6, snapshot_global_qid) ||
            (snapshot_global_qid != 66) ||
            !virtio_env.pf_instances[0].pf_manager.resource_pool.
                global_to_service_local(
                    66, reverse_service_key, reverse_local_qid) ||
            (dpu_service_key_name(reverse_service_key) !=
             dpu_service_key_name(pf.service_key)) ||
            (reverse_local_qid != 6) ||
            (virtio_env.pf_instances[0].pf_manager.resource_pool.get_queue_name(
                pf.service_key, 6) != $sformatf("%s_receiveq_3",
                    dpu_service_key_name(pf.service_key)))) begin
            `uvm_fatal("ROUTING_TEST",
                "service-keyed pool replaced sparse pair 3 with control queue")
        end
        assert(reused_pf != null)
            else `uvm_fatal("ROUTING_TEST",
                "reused-domain VIO function was not constructed")
        assert((pf.bdf == PF_BDF) && (pf.transport.bdf == PF_BDF) &&
               (vf.bdf == VF_BDF) && (vf.transport.bdf == VF_BDF))
            else `uvm_fatal("ROUTING_TEST",
                "PF/VF BDFs did not come from the frozen snapshot")
        assert(vf.bdf != (pf.bdf + 1))
            else `uvm_fatal("ROUTING_TEST",
                "VF BDF unexpectedly used arithmetic PF+VF placement")
        assert((pf.bar_pairs.size() == 3) &&
               (pf.bar_pairs[0].base == PF_BAR0_BASE) &&
               (pf.bar_pairs[1].base == PF_BAR2_BASE) &&
               (pf.bar_pairs[2].base == PF_BAR4_BASE) &&
               (vf.bar_pairs.size() == 3) &&
               (vf.bar_pairs[0].base == VF_BAR0_BASE) &&
               (vf.bar_pairs[1].base == VF_BAR2_BASE) &&
               (vf.bar_pairs[2].base == VF_BAR4_BASE))
            else `uvm_fatal("ROUTING_TEST",
                "PF/VF BAR copies differ from resolved snapshot values")
        assert((pf.resource_manager == device_env.get_resource_manager()) &&
               (vf.resource_manager == device_env.get_resource_manager()))
            else `uvm_fatal("ROUTING_TEST",
                "VIO functions did not receive the global resource manager")
        assert((pf.drv_cfg.num_queue_pairs == 3) &&
               (vf.drv_cfg.num_queue_pairs == 5) &&
               (reused_pf.drv_cfg.num_queue_pairs == 7))
            else `uvm_fatal("ROUTING_TEST",
                "PF/VF behavior was not routed by canonical service key")
        if ($test$plusargs("ROUTING_BIND_ONLY")) begin
            assert((pf.driver_agent.ops != null) &&
                   (pf.driver_agent.fsm != null) &&
                   (vf.driver_agent.ops != null) &&
                   (vf.driver_agent.fsm != null))
                else `uvm_fatal("ROUTING_TEST",
                    "no-adapter binding left an active function unbound")
            phase.drop_objection(this);
            return;
        end
        configure_function_ranges(pf);
        configure_function_ranges(vf);
        configure_function_ranges(reused_pf);
        virtio_env.cov.enable_all();

        tlp = make_pf_status_write(pf);
        // This is the production observation boundary, not a direct call into
        // a virtio adapter: the public bind_pcie() connection must carry it.
        pcie_env.ep_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == 1)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "PF should observe exactly one addressed BAR event, saw %0d",
                pf_collector.count))
        assert(pf_collector.transactions[0].is_monitor_event &&
               pf_collector.transactions[0].monitor_event == VIRTIO_MON_BAR_ACCESS)
            else `uvm_fatal("ROUTING_TEST", "PF event was not a populated BAR access")
        assert(pf_collector.transactions[0].monitor_addr == tlp.addr)
            else `uvm_fatal("ROUTING_TEST", "PF event address differs from monitor TLP")
        assert(vf_collector.count == 0)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "VF observed another function's MMIO (%0d events)", vf_collector.count))
        assert(reused_domain_collector.count == 0)
            else `uvm_fatal("ROUTING_TEST",
                "same-BDF/BAR function in another domain observed host0 MMIO")

        reused_pcie_env.ep_agent.monitor.tlp_ap.write(
            make_pf_status_write(reused_pf));
        assert(reused_domain_collector.count == 1)
            else `uvm_fatal("ROUTING_TEST",
                "host1 endpoint monitor did not reach its same-BDF/BAR owner")
        assert((pf_collector.count == 1) && (vf_collector.count == 0))
            else `uvm_fatal("ROUTING_TEST",
                "host1 endpoint monitor leaked into the host0 domain")
        assert(virtio_env.scb.monitor_event_count == 2)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "shared scoreboard should receive both domain-owned monitor events, saw %0d",
                virtio_env.scb.monitor_event_count))
        assert(virtio_env.cov.cg_lifecycle.get_inst_coverage() > 0.0)
            else `uvm_fatal("ROUTING_TEST",
                "shared coverage did not receive the routed lifecycle event")

        test_default_msix_memory_write(pf, vf);
        test_real_msix_memory_write(pf, vf);
        test_protocol_vif_isolation(pf, vf);
        test_queue_and_device_resets(pf);
        if (!pf.resource_client.local_qid_to_global_qid(
                6, snapshot_global_qid) || (snapshot_global_qid != 66) ||
            !virtio_env.pf_instances[0].pf_manager.resource_pool.
                local_to_global_for_service(
                    pf.service_key, 6, snapshot_global_qid) ||
            (snapshot_global_qid != 66)) begin
            `uvm_fatal("ROUTING_TEST",
                "runtime reset mutated immutable sparse placement")
        end
        test_resource_pool_snapshot_and_collision_rejection(pf, vf);
        assert_domain_reused_transport_path(pf, reused_pf);

        `uvm_info("ROUTING_TEST", "External PCIe monitor routing PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // Breaks caught: a pool can be rebound to a second resource snapshot, or
    // can partially append a service whose global qid makes reverse lookup
    // ambiguous with an already imported service.
    protected task test_resource_pool_snapshot_and_collision_rejection(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        dpu_configuration_resolver resolver;
        dpu_device_snapshot alternate_device;
        dpu_resource_snapshot alternate_resource;
        dpu_placement_diagnostic diagnostic;
        virtio_vf_resource_pool pool;
        virtio_monitor_corruptible_resource_snapshot corruptible;
        int unsigned original_count;
        int unsigned global_qid;
        string why;

        resolver = dpu_configuration_resolver::type_id::create(
            "pool_alternate_resolver");
        if (!resolver.resolve(
                device_env_cfg.device_cfg, device_env_cfg.placement_cfg,
                alternate_device, alternate_resource, diagnostic)) begin
            `uvm_fatal("ROUTING_TEST",
                {"could not build alternate snapshot pair: ", diagnostic.message})
        end
        pool = virtio_vf_resource_pool::type_id::create("snapshot_owner_pool");
        if (!pool.import_service_bindings(
                pf.service_key, device_env.get_resource_snapshot(), why)) begin
            `uvm_fatal("ROUTING_TEST", {"initial pool import failed: ", why})
        end
        original_count = pool.get_total_queues();
        if (pool.import_service_bindings(
                pf.service_key, alternate_resource, why) ||
            (pool.get_total_queues() != original_count) ||
            !pool.local_to_global_for_service(pf.service_key, 6, global_qid) ||
            (global_qid != 66)) begin
            `uvm_fatal("ROUTING_TEST",
                "pool accepted a different resource snapshot or mutated state")
        end

        pool = virtio_vf_resource_pool::type_id::create("collision_pool");
        if (!pool.import_service_bindings(
                pf.service_key, device_env.get_resource_snapshot(), why) ||
            !$cast(corruptible, device_env.get_resource_snapshot()) ||
            !corruptible.force_service_global_pair(vf.service_key, 30)) begin
            `uvm_fatal("ROUTING_TEST",
                "could not prepare cross-service collision probe")
        end
        original_count = pool.get_total_queues();
        if (pool.import_service_bindings(
                vf.service_key, device_env.get_resource_snapshot(), why) ||
            (pool.get_total_queues() != original_count) ||
            pool.local_to_global_for_service(vf.service_key, 0, global_qid)) begin
            `uvm_fatal("ROUTING_TEST",
                "pool accepted an ambiguous global qid or partially mutated")
        end
    endtask

    // The production transport and accessor must preserve endpoint identity
    // for both requests and completions.  The two roots intentionally use the
    // same BDF and BAR address and return different data; host0 is delayed so
    // equal tag/BDF completions arrive in the opposite order.
    protected task assert_domain_reused_transport_path(
        input virtio_function_instance host0_pf,
        input virtio_function_instance host1_pf
    );
        bit [31:0] host0_cfg;
        bit [31:0] host1_cfg;
        bit [31:0] host0_mmio;
        bit [31:0] host1_mmio;
        bit [31:0] host0_cfg_written;
        bit [31:0] host1_cfg_written;
        bit [31:0] host0_mmio_written;
        bit [31:0] host1_mmio_written;
        bit [63:0] mmio_address;

        if ((host0_pf.pcie_id.bdf != host1_pf.pcie_id.bdf) ||
            dpu_same_domain_key(
                host0_pf.pcie_id.domain, host1_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host0_pf.transport.pcie_id.domain,
                host0_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host1_pf.transport.pcie_id.domain,
                host1_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host0_pf.transport.bar.pcie_id.domain,
                host0_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host1_pf.transport.bar.pcie_id.domain,
                host1_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host0_pf.driver_agent.observer.function_pcie_id.domain,
                host0_pf.pcie_id.domain) ||
            !dpu_same_domain_key(
                host1_pf.driver_agent.observer.function_pcie_id.domain,
                host1_pf.pcie_id.domain)) begin
            `uvm_fatal("ROUTING_TEST",
                "full PCIe identity did not reach function/transport/accessor/observer")
        end
        if ((host0_pf.transport.bar.pcie_rc_seqr !=
             pcie_env.rc_agent.sequencer) ||
            (host1_pf.transport.bar.pcie_rc_seqr !=
             reused_pcie_env.rc_agent.sequencer)) begin
            `uvm_fatal("ROUTING_TEST",
                "domain-qualified endpoint selection chose the wrong RC sequencer")
        end

        pcie_env.cfg_mgr.cfg_space[0] = 8'h34;
        pcie_env.cfg_mgr.cfg_space[1] = 8'h12;
        pcie_env.cfg_mgr.cfg_space[2] = 8'h78;
        pcie_env.cfg_mgr.cfg_space[3] = 8'h56;
        reused_pcie_env.cfg_mgr.cfg_space[0] = 8'hcd;
        reused_pcie_env.cfg_mgr.cfg_space[1] = 8'hab;
        reused_pcie_env.cfg_mgr.cfg_space[2] = 8'h21;
        reused_pcie_env.cfg_mgr.cfg_space[3] = 8'h43;
        fork
            host0_pf.transport.bar.config_read(12'h000, host0_cfg);
            host1_pf.transport.bar.config_read(12'h000, host1_cfg);
        join
        if ((host0_cfg != 32'h5678_1234) ||
            (host1_cfg != 32'h4321_abcd)) begin
            `uvm_fatal("ROUTING_TEST", $sformatf(
                "domain-qualified config completions aliased: host0=0x%08h host1=0x%08h",
                host0_cfg, host1_cfg))
        end

        fork
            host0_pf.transport.bar.config_write(
                PCI_CFG_COMMAND, 32'h0000_0005, 4'h3);
            host1_pf.transport.bar.config_write(
                PCI_CFG_COMMAND, 32'h0000_0006, 4'h3);
        join
        fork
            host0_pf.transport.bar.config_read(
                PCI_CFG_COMMAND, host0_cfg_written);
            host1_pf.transport.bar.config_read(
                PCI_CFG_COMMAND, host1_cfg_written);
        join
        if ((host0_cfg_written[15:0] != 16'h0005) ||
            (host1_cfg_written[15:0] != 16'h0006)) begin
            `uvm_fatal("ROUTING_TEST",
                "domain-qualified config write/readback crossed endpoints")
        end

        mmio_address = PF_BAR0_BASE + DOMAIN_MMIO_OFF;
        write_ep_mem32(pcie_env.ep_agent.ep_driver,
            mmio_address, 32'ha0a0_0001);
        write_ep_mem32(reused_pcie_env.ep_agent.ep_driver,
            mmio_address, 32'hb0b0_0002);
        fork
            host0_pf.transport.bar.read_reg(
                0, DOMAIN_MMIO_OFF, 4, host0_mmio);
            host1_pf.transport.bar.read_reg(
                0, DOMAIN_MMIO_OFF, 4, host1_mmio);
        join
        if ((host0_mmio != 32'ha0a0_0001) ||
            (host1_mmio != 32'hb0b0_0002)) begin
            `uvm_fatal("ROUTING_TEST", $sformatf(
                "domain-qualified MMIO completions aliased: host0=0x%08h host1=0x%08h",
                host0_mmio, host1_mmio))
        end

        fork
            host0_pf.transport.bar.write_reg(
                0, DOMAIN_MMIO_OFF, 4, 32'h0a0a_1111);
            host1_pf.transport.bar.write_reg(
                0, DOMAIN_MMIO_OFF, 4, 32'h0b0b_2222);
        join
        // Posted writes retire at the RC sequencer before the asynchronous
        // TLM loopback invokes the EP model.  Poll the real endpoint memories
        // for bounded completion instead of racing that transport handoff.
        for (int unsigned poll = 0; poll < 100; poll++) begin
            host0_mmio_written = read_ep_mem32(
                pcie_env.ep_agent.ep_driver, mmio_address);
            host1_mmio_written = read_ep_mem32(
                reused_pcie_env.ep_agent.ep_driver, mmio_address);
            if ((host0_mmio_written == 32'h0a0a_1111) &&
                (host1_mmio_written == 32'h0b0b_2222)) begin
                break;
            end
            #1ns;
        end
        if ((host0_mmio_written != 32'h0a0a_1111) ||
            (host1_mmio_written != 32'h0b0b_2222)) begin
            `uvm_fatal("ROUTING_TEST", $sformatf(
                {"domain-qualified MMIO writes crossed endpoint memories: ",
                 "host0=0x%08h host1=0x%08h"},
                host0_mmio_written, host1_mmio_written))
        end
    endtask

    protected function void write_ep_mem32(
        input pcie_tl_ep_driver ep_driver,
        input bit [63:0] address,
        input bit [31:0] data
    );
        ep_driver.mem_space[address] = data[7:0];
        ep_driver.mem_space[address + 1] = data[15:8];
        ep_driver.mem_space[address + 2] = data[23:16];
        ep_driver.mem_space[address + 3] = data[31:24];
    endfunction

    protected function bit [31:0] read_ep_mem32(
        input pcie_tl_ep_driver ep_driver,
        input bit [63:0] address
    );
        bit [31:0] data;

        data[7:0] = ep_driver.mem_space.exists(address) ?
            ep_driver.mem_space[address] : 8'h00;
        data[15:8] = ep_driver.mem_space.exists(address + 1) ?
            ep_driver.mem_space[address + 1] : 8'h00;
        data[23:16] = ep_driver.mem_space.exists(address + 2) ?
            ep_driver.mem_space[address + 2] : 8'h00;
        data[31:24] = ep_driver.mem_space.exists(address + 3) ?
            ep_driver.mem_space[address + 3] : 8'h00;
        return data;
    endfunction

    protected function void configure_function_ranges(
        input virtio_function_instance function_instance
    );
        function_instance.transport.cap_mgr.common_cfg_found = 1;
        function_instance.transport.cap_mgr.common_cfg_cap.bar = 0;
        function_instance.transport.cap_mgr.common_cfg_cap.offset = COMMON_OFF;
        function_instance.transport.cap_mgr.common_cfg_cap.length = COMMON_LEN;
        function_instance.transport.cap_mgr.notify_found = 1;
        function_instance.transport.cap_mgr.notify_cap.bar = 0;
        function_instance.transport.cap_mgr.notify_cap.offset = NOTIFY_OFF;
        function_instance.transport.cap_mgr.notify_cap.length = NOTIFY_LEN;
    endfunction

    // MSI/MSI-X delivery is an endpoint Memory Write to a host APIC address,
    // not necessarily a PCIe Message TLP.  requester_id is deliberately zero
    // here because monitor implementations commonly omit it for this path.
    // Normal MSI-X setup must reserve a distinct address/data identity per
    // Fabric function; otherwise an APIC write for one function broadcasts to
    // every observer with the same default table entry.
    protected task test_default_msix_memory_write(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        pcie_tl_mem_tlp tlp;
        int unsigned pf_count_before;
        int unsigned vf_count_before;

        pf.transport.notify_mgr.setup_msix(1, 4, 32'h0);
        vf.transport.notify_mgr.setup_msix(1, 4, 32'h0);
        assert((pf.transport.notify_mgr.msix_table[0].msg_addr !=
                vf.transport.notify_mgr.msix_table[0].msg_addr) ||
               (pf.transport.notify_mgr.msix_table[0].msg_data !=
                vf.transport.notify_mgr.msix_table[0].msg_data))
            else `uvm_fatal("ROUTING_TEST",
                "normal PF/VF MSI-X setup produced an ambiguous default entry")

        pf_count_before = pf_collector.count;
        vf_count_before = vf_collector.count;
        tlp = make_mem_write(pf.transport.notify_mgr.msix_table[0].msg_addr,
            pf.transport.notify_mgr.msix_table[0].msg_data, 16'h0000);
        pcie_env.rc_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == (pf_count_before + 1))
            else `uvm_fatal("ROUTING_TEST",
                "default zero-requester MSI-X write did not reach its PF owner")
        assert(pf_collector.transactions[$].monitor_event == VIRTIO_MON_INTERRUPT)
            else `uvm_fatal("ROUTING_TEST",
                "default PF MSI-X write was not decoded as an interrupt")
        assert(vf_collector.count == vf_count_before)
            else `uvm_fatal("ROUTING_TEST",
                "default PF MSI-X write was broadcast to the VF observer")
    endtask

    // Explicitly provisioned MSI-X entries remain a supported routing case.
    protected task test_real_msix_memory_write(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        pcie_tl_mem_tlp tlp;
        int unsigned pf_count_before;
        int unsigned vf_count_before;

        pf.transport.notify_mgr.msix_table = new[1];
        pf.transport.notify_mgr.msix_table[0].msg_addr = PF_MSIX_ADDR;
        pf.transport.notify_mgr.msix_table[0].msg_data = PF_MSIX_DATA;
        pf.transport.notify_mgr.msix_table[0].masked = 0;
        vf.transport.notify_mgr.msix_table = new[1];
        vf.transport.notify_mgr.msix_table[0].msg_addr = PF_MSIX_ADDR + 4;
        vf.transport.notify_mgr.msix_table[0].msg_data = PF_MSIX_DATA + 1;
        vf.transport.notify_mgr.msix_table[0].masked = 0;
        pf_count_before = pf_collector.count;
        vf_count_before = vf_collector.count;

        tlp = make_mem_write(PF_MSIX_ADDR, PF_MSIX_DATA, 16'h0000);
        pcie_env.rc_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == (pf_count_before + 1))
            else `uvm_fatal("ROUTING_TEST",
                "zero-requester MSI-X memory write did not reach the PF monitor")
        assert(pf_collector.transactions[$].monitor_event == VIRTIO_MON_INTERRUPT)
            else `uvm_fatal("ROUTING_TEST",
                "APIC memory write was not decoded as a virtio interrupt")
        assert(pf_collector.transactions[$].interrupt_vector == PF_MSIX_DATA)
            else `uvm_fatal("ROUTING_TEST", "MSI-X vector data was not preserved")
        assert(vf_collector.count == vf_count_before)
            else `uvm_fatal("ROUTING_TEST",
                "MSI-X write reached a function with a different MSI-X entry")
    endtask

    // The protocol checker maintains history (FEATURES_OK seen) inside its
    // event interface.  PF and VF traffic must therefore be driven through
    // distinct interfaces: a PF FEATURES_OK must never make a VF DRIVER_OK
    // trace look legal.
    protected task test_protocol_vif_isolation(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        virtual virtio_protocol_event_if pf_protocol_vif;
        virtual virtio_protocol_event_if vf_protocol_vif;
        virtio_monitor_routing_protocol_sva_catcher sva_catcher;

        pf_protocol_vif = pf.driver_agent.monitor.protocol_vif;
        vf_protocol_vif = vf.driver_agent.monitor.protocol_vif;
        assert((pf_protocol_vif != null) && (vf_protocol_vif != null))
            else `uvm_fatal("ROUTING_TEST",
                "each bound function requires a protocol event interface")
        assert(pf_protocol_vif != vf_protocol_vif)
            else `uvm_fatal("ROUTING_TEST",
                "PF and VF share protocol event state")

        pf.driver_agent.monitor.chk_status_transition = 0;
        vf.driver_agent.monitor.chk_status_transition = 0;
        pf_protocol_vif.assertions_enable = 0;
        vf_protocol_vif.assertions_enable = 0;
        pf.driver_agent.monitor.reset_protocol_state();
        vf.driver_agent.monitor.reset_protocol_state();

        // The routed PF reset and reset_protocol_state() pulses are staged.
        // MSI-X observations only add a pulse for queue completions, so drain
        // the actual PF/VF queue contents rather than assuming a fixed depth.
        drain_staged_protocol_pulses(pf_protocol_vif, vf_protocol_vif);
        pf_protocol_vif.protocol_error_count = 0;
        vf_protocol_vif.protocol_error_count = 0;
        pf_protocol_vif.assertions_enable = 1;
        vf_protocol_vif.assertions_enable = 1;

        // PF establishes DRIVER before FEATURES_OK.  The VF's DRIVER_OK is
        // intentionally illegal and must trip only the VF assertion state.
        emit_status_and_advance(pf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        emit_status_and_advance(pf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        sva_catcher = new();
        uvm_report_cb::add(null, sva_catcher);
        emit_status_and_advance(vf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_DRIVER_OK);
        assert(pf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST",
                "PF protocol checker observed another function's illegal trace")
        assert(vf_protocol_vif.protocol_error_count == 1)
            else `uvm_fatal("ROUTING_TEST",
                "VF DRIVER_OK without VF FEATURES_OK did not trip its SVA")
        assert(sva_catcher.caught_count == 1)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected one scoped VF DRIVER_OK SVA report, saw %0d",
                sva_catcher.caught_count))
        uvm_report_cb::delete(null, sva_catcher);

        // Reset both checker histories, then prove that independent legal
        // traces pass without cross-function contamination.
        emit_status_and_advance(pf, DEV_STATUS_RESET);
        emit_status_and_advance(vf, DEV_STATUS_RESET);
        pf_protocol_vif.protocol_error_count = 0;
        vf_protocol_vif.protocol_error_count = 0;
        drive_legal_status_trace(pf);
        drive_legal_status_trace(vf);
        assert(pf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST", "legal PF trace tripped its SVA")
        assert(vf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST", "legal VF trace tripped its SVA")
    endtask

    // Configure and enable the same queue twice.  Q_RESET and device-status
    // reset must each clear both adapter and semantic-monitor queue state, so
    // the following notify is rejected in both cases.
    protected task test_queue_and_device_resets(
        input virtio_function_instance pf
    );
        virtio_monitor_routing_error_catcher error_catcher;
        virtio_monitor_routing_disabled_notify_sva_catcher sva_catcher;
        virtual virtio_protocol_event_if protocol_vif;
        int unsigned protocol_errors_before;

        // Do not let an uninstantiated functional virtqueue reject the notify
        // for us; this test isolates observer/monitor reset state.
        pf.driver_agent.monitor.vq_mgr = null;
        protocol_vif = pf.driver_agent.monitor.protocol_vif;
        assert(protocol_vif != null)
            else `uvm_fatal("ROUTING_TEST",
                "queue-reset test requires a protocol event interface")
        protocol_vif.assertions_enable = 1;
        error_catcher = new();
        sva_catcher = new();
        protocol_errors_before = protocol_vif.protocol_error_count;
        uvm_report_cb::add(null, error_catcher);
        uvm_report_cb::add(null, sva_catcher);

        configure_and_enable_queue(pf, 3);
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_RESET, 32'h1);
        emit_notify(pf, 3);
        assert(error_catcher.monitor_errors == 1)
            else `uvm_fatal("ROUTING_TEST",
                "notify after Q_RESET was not rejected")
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_ENABLE, 32'h1);
        assert(error_catcher.monitor_errors == 2)
            else `uvm_fatal("ROUTING_TEST",
                "adapter kept queue configuration after Q_RESET")

        configure_and_enable_queue(pf, 3);
        emit_common_write(pf, VIRTIO_PCI_COMMON_STATUS, DEV_STATUS_RESET);
        emit_notify(pf, 3);
        assert(error_catcher.monitor_errors == 3)
            else `uvm_fatal("ROUTING_TEST",
                "notify after device reset was not rejected")
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_ENABLE, 32'h1);
        assert(error_catcher.monitor_errors == 4)
            else `uvm_fatal("ROUTING_TEST",
                "adapter kept queue configuration after device reset")

        drain_staged_protocol_pulses(protocol_vif, null);
        assert(sva_catcher.caught_count == 2)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected two scoped disabled-notify SVA reports, saw %0d",
                sva_catcher.caught_count))
        assert(protocol_vif.protocol_error_count == (protocol_errors_before + 2))
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected two disabled-notify protocol errors, saw %0d -> %0d",
                protocol_errors_before, protocol_vif.protocol_error_count))

        uvm_report_cb::delete(null, sva_catcher);
        uvm_report_cb::delete(null, error_catcher);
    endtask

    // Each interface releases at most one staged pulse on a negedge.  Capture
    // the exact pending depth first, then fail rather than spinning if a new
    // callback prevents these known pre-baseline events from draining.
    protected task drain_staged_protocol_pulses(
        input virtual virtio_protocol_event_if pf_protocol_vif,
        input virtual virtio_protocol_event_if vf_protocol_vif
    );
        int unsigned pending_pulses;
        int unsigned release_count;

        pending_pulses = pf_protocol_vif.staged_pulses.size();
        if (vf_protocol_vif != null)
            pending_pulses += vf_protocol_vif.staged_pulses.size();
        while ((pf_protocol_vif.staged_pulses.size() != 0) ||
               ((vf_protocol_vif != null) &&
                (vf_protocol_vif.staged_pulses.size() != 0))) begin
            assert(release_count < pending_pulses)
                else `uvm_fatal("ROUTING_TEST", $sformatf(
                    "staged protocol pulses grew while draining (%0d releases, %0d initial)",
                    release_count, pending_pulses))
            @(negedge virtio_tb_top.clk);
            @(posedge virtio_tb_top.clk);
            #1step;
            release_count++;
        end
    endtask

    protected task configure_and_enable_queue(
        input virtio_function_instance function_instance,
        input int unsigned queue_id
    );
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_SELECT, queue_id);
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_SIZE, 32'd64);
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_ENABLE, 32'd1);
    endtask

    protected task drive_legal_status_trace(
        input virtio_function_instance function_instance
    );
        emit_status_and_advance(function_instance, DEV_STATUS_ACKNOWLEDGE);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK |
            DEV_STATUS_DRIVER_OK);
    endtask

    protected task emit_status_and_advance(
        input virtio_function_instance function_instance,
        input bit [7:0] status
    );
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_STATUS, status);
        // The callback can enqueue on the same negedge at which the interface
        // drains its queue.  Cross the next release edge and then the following
        // SVA sample; #1step leaves the observed/reactive regions before checking.
        @(posedge virtio_tb_top.clk);
        @(negedge virtio_tb_top.clk);
        @(posedge virtio_tb_top.clk);
        #1step;
    endtask

    protected task emit_common_write(
        input virtio_function_instance function_instance,
        input bit [11:0] offset,
        input bit [31:0] data
    );
        pcie_env.ep_agent.monitor.tlp_ap.write(make_mem_write(
            function_instance.transport.bar.bar_base[0] + COMMON_OFF + offset,
            data, 16'h0000));
    endtask

    protected task emit_notify(
        input virtio_function_instance function_instance,
        input int unsigned queue_id
    );
        pcie_env.ep_agent.monitor.tlp_ap.write(make_mem_write(
            function_instance.transport.bar.bar_base[0] + NOTIFY_OFF,
            queue_id, 16'h0000));
    endtask

    protected function pcie_tl_mem_tlp make_pf_status_write(
        input virtio_function_instance pf
    );
        return make_mem_write(
            pf.transport.bar.bar_base[0] + COMMON_OFF + VIRTIO_PCI_COMMON_STATUS,
            DEV_STATUS_RESET, 16'h0000);
    endfunction

    protected function pcie_tl_mem_tlp make_mem_write(
        input bit [63:0] address,
        input bit [31:0] data,
        input bit [15:0] requester_id
    );
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("monitor_mem_write");
        tlp.kind = TLP_MEM_WR;
        tlp.fmt = FMT_4DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.is_64bit = 1;
        tlp.requester_id = requester_id;
        tlp.addr = address;
        tlp.length = 10'd1;
        tlp.first_be = 4'hF;
        tlp.last_be = 4'h0;
        tlp.payload = new[4];
        tlp.payload[0] = data[7:0];
        tlp.payload[1] = data[15:8];
        tlp.payload[2] = data[23:16];
        tlp.payload[3] = data[31:24];
        return tlp;
    endfunction
endclass : virtio_monitor_routing_test

`endif // VIRTIO_MONITOR_ROUTING_TEST_SV
