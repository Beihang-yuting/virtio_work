`ifndef VIRTIO_NET_ENV_SV
`define VIRTIO_NET_ENV_SV

// ============================================================================
// virtio_net_env
//
// Top-level UVM environment for the virtio-net driver VIP.
//
// Creates and wires all components:
//   - PF manager (SR-IOV orchestration)
//   - VF instances (per-VF driver wrappers, dynamic array)
//   - Shared infrastructure: IOMMU, host memory, barriers, error injector,
//     wait policy, performance monitor
//   - Verification: scoreboard, coverage (conditionally created)
//   - Concurrency controller, dynamic reconfiguration
//   - Virtual sequencer (aggregates per-VF sequencers)
//
// Config is retrieved from uvm_config_db in build_phase. The test must set:
//   uvm_config_db#(virtio_net_env_config)::set(this, "env", "cfg", cfg)
//
// PCIe subenv connection (pcie_tl_env) is deferred to the test's
// connect_phase because the PCIe env is created by the test.  Tests bind it
// once through bind_pcie(), which wires every active function.
//
// Depends on:
//   - All Phase 1-7 components
//   - All Phase 8 env components (config, scoreboard, coverage, etc.)
// ============================================================================

class virtio_net_env extends uvm_env;
    `uvm_component_utils(virtio_net_env)

    // ===== Config =====
    virtio_net_env_config cfg;

    // ===== PF manager =====
    virtio_pf_manager pf_mgr;

    // ===== Snapshot-owned VIO function view =====
    virtio_pf_instance         pf_instances[];
    virtio_function_instance   function_instances[];
    protected dpu_device_snapshot device_snapshot;
    protected dpu_resource_manager device_resource_manager;
    protected bit              configuration_valid;
    local dpu_dut_caps         effective_dut_caps;

    // ===== VF instances enumerated from declared VIO services =====
    virtio_vf_instance vf_instances[];

    // ===== Shared components =====
    virtio_iommu_model              iommu;
    host_mem_manager                host_mem;
    virtio_wait_policy              wait_pol;
    virtio_memory_barrier_model     barrier;
    virtqueue_error_injector        err_inj;
    virtio_perf_monitor             perf_mon;
    virtio_concurrency_controller   conc_ctrl;
    virtio_dynamic_reconfig         dyn_reconfig;

    // ===== Verification =====
    virtio_scoreboard               scb;
    virtio_coverage                 cov;

    // ===== PCIe subenv (stored as uvm_object, $cast at runtime) =====
    // The actual pcie_tl_env is created by the test and passed via config_db
    uvm_object                      pcie_env_ref;
    protected int unsigned           protocol_event_vif_index;

    // ===== Virtual sequencer =====
    virtio_virtual_sequencer        v_seqr;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
        configuration_valid = 0;
        effective_dut_caps = null;
        protocol_event_vif_index = 0;
    endfunction

    protected function bit build_snapshot_topology(output string why);
        dpu_service_key_t service_keys[$];
        dpu_service_key_t grouped_services[$][$];
        dpu_function_key_t group_keys[$];
        dpu_function_key_t owner;
        dpu_function_key_t parent_key;
        int unsigned group_index;
        bit found;
        int unsigned vf_count;
        int unsigned function_count;

        why = "";
        device_snapshot.list_services(DPU_SERVICE_VIO_NET, service_keys);
        if (service_keys.size() == 0) begin
            why = "frozen device snapshot declares no VIO services";
            return 0;
        end
        foreach (service_keys[index]) begin
            if (!device_snapshot.get_service_owner(service_keys[index], owner, why))
                return 0;
            parent_key = owner;
            parent_key.kind = DPU_FUNCTION_PF;
            parent_key.vf_id = 0;
            found = 0;
            foreach (group_keys[candidate]) begin
                if (dpu_same_function_key(group_keys[candidate], parent_key)) begin
                    group_index = candidate;
                    found = 1;
                    break;
                end
            end
            if (!found) begin
                group_index = group_keys.size();
                group_keys.push_back(parent_key);
            end
            grouped_services[group_index].push_back(service_keys[index]);
        end

        pf_instances = new[group_keys.size()];
        foreach (group_keys[index]) begin
            pf_instances[index] = virtio_pf_instance::type_id::create(
                $sformatf("pf_%0d_%0d", group_keys[index].host_id,
                          group_keys[index].pf_id), this);
            if (!pf_instances[index].configure_services(
                    group_keys[index], device_snapshot,
                    grouped_services[index], device_resource_manager, why)) begin
                return 0;
            end
        end
        function_count = 0;
        foreach (pf_instances[index]) begin
            virtio_function_instance grouped_functions[$];

            pf_instances[index].collect_functions(grouped_functions);
            function_count += grouped_functions.size();
        end
        function_instances = new[function_count];
        function_count = 0;
        foreach (pf_instances[index]) begin
            virtio_function_instance grouped_functions[$];

            pf_instances[index].collect_functions(grouped_functions);
            foreach (grouped_functions[function_index]) begin
                function_instances[function_count] = grouped_functions[function_index];
                function_count++;
            end
        end

        vf_count = 0;
        foreach (function_instances[index]) begin
            if (function_instances[index].function_kind == DPU_FUNCTION_VF)
                vf_count++;
        end
        vf_instances = new[vf_count];
        vf_count = 0;
        foreach (function_instances[index]) begin
            if (function_instances[index].function_kind == DPU_FUNCTION_VF) begin
                if (!$cast(vf_instances[vf_count], function_instances[index])) begin
                    why = "snapshot VIO VF function did not construct a VF instance";
                    return 0;
                end
                vf_count++;
            end
        end
        return 1;
    endfunction

    function dpu_dut_caps snapshot_effective_dut_caps();
        dpu_dut_caps snapshot;

        if (effective_dut_caps == null)
            return null;
        snapshot = dpu_dut_caps::type_id::create(
            "virtio_env_effective_dut_caps_snapshot");
        snapshot.copy_from(effective_dut_caps);
        return snapshot;
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Retrieve behavior plus the mandatory frozen snapshot and create all
    // components from declared VIO services.
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        string why;

        super.build_phase(phase);

        // Get config from config_db
        if (!uvm_config_db #(virtio_net_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal("VIRTIO_ENV", "No virtio_net_env_config found in config_db")
            return;
        end

        if (!uvm_config_db#(dpu_device_snapshot)::get(
                this, "", "dpu_device_snapshot", device_snapshot) ||
            (device_snapshot == null) || !device_snapshot.is_frozen()) begin
            `uvm_fatal("VIRTIO_ENV",
                "a published frozen device snapshot is required")
            return;
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
                this, "", "dpu_resource_manager", device_resource_manager) ||
            (device_resource_manager == null) ||
            !device_resource_manager.is_snapshot_seeded()) begin
            `uvm_fatal("VIRTIO_ENV",
                "a published snapshot-seeded device resource manager is required")
            return;
        end
        if (!cfg.validate_against_snapshot(device_snapshot, why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "VIO behavior does not match the published device snapshot: %s", why))
            return;
        end
        effective_dut_caps = device_snapshot.snapshot_dut_caps();
        if (effective_dut_caps == null) begin
            `uvm_fatal("VIRTIO_ENV",
                "published device snapshot has no DUT capabilities")
            return;
        end
        configuration_valid = 1;

        `uvm_info("VIRTIO_ENV",
            $sformatf("build_phase: %s", cfg.convert2string()),
            UVM_LOW)

        // Create shared components
        host_mem = host_mem_manager::type_id::create("host_mem");
        host_mem.init_region(cfg.mem_base, cfg.mem_end);

        iommu = virtio_iommu_model::type_id::create("iommu");
        iommu.strict_permission_check = cfg.iommu_strict;

        wait_pol = virtio_wait_policy::type_id::create("wait_pol");
        barrier  = virtio_memory_barrier_model::type_id::create("barrier");
        err_inj  = virtqueue_error_injector::type_id::create("err_inj");

        perf_mon = virtio_perf_monitor::type_id::create("perf_mon", this);
        perf_mon.bw_limit_enable = cfg.bw_limit_enable;
        perf_mon.bw_limit_mbps   = cfg.bw_limit_mbps;

        if (!build_snapshot_topology(why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "could not construct VIO functions from device snapshot: %s", why))
            return;
        end

        // Create verification components (conditionally)
        if (cfg.scb_enable)
            scb = virtio_scoreboard::type_id::create("scb", this);
        if (cfg.cov_enable)
            cov = virtio_coverage::type_id::create("cov", this);

        // Create concurrency/dynamic reconfig
        conc_ctrl    = virtio_concurrency_controller::type_id::create("conc_ctrl");
        dyn_reconfig = virtio_dynamic_reconfig::type_id::create("dyn_reconfig");
        if (!dyn_reconfig.bind_device_snapshot(device_snapshot, why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Dynamic reconfiguration device snapshot bind failed: %s", why))
            return;
        end

        // Virtual sequencer
        v_seqr = virtio_virtual_sequencer::type_id::create("v_seqr", this);

    endfunction

    // ========================================================================
    // Connect Phase
    //
    // Wire shared components into VF instances, connect analysis ports to
    // scoreboard/coverage, and set up the virtual sequencer.
    //
    // Note: wire_shared() for VF instances requires pcie_rc_seqr which
    // comes from the PCIe TL env. That connection is deferred to the
    // test's connect_phase.
    // ========================================================================

    virtual function void connect_phase(uvm_phase phase);
        virtio_driver_config_t driver_cfg;
        string why;

        super.connect_phase(phase);
        if (!configuration_valid)
            return;

        if (pf_instances.size() != 0) begin
            pf_mgr = pf_instances[0].pf_manager;
            pf_mgr.wait_pol = wait_pol;
        end
        foreach (function_instances[function_index]) begin
            if (!cfg.get_service_config(
                    function_instances[function_index].service_key,
                    effective_dut_caps.max_vio_net_qpairs_per_device,
                    driver_cfg, why)) begin
                configuration_valid = 0;
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "could not resolve VIO behavior for snapshot function: %s", why))
                return;
            end
            function_instances[function_index].drv_cfg = driver_cfg;
            if (scb != null) begin
                function_instances[function_index].driver_agent.monitor.txn_ap.connect(
                    scb.txn_imp
                );
            end
            if (cov != null) begin
                function_instances[function_index].driver_agent.monitor.txn_ap.connect(
                    cov.analysis_imp
                );
            end
        end

        // Wire virtual sequencer
        v_seqr.vf_seqrs = new[vf_instances.size()];
        foreach (vf_instances[i])
            v_seqr.vf_seqrs[i] = vf_instances[i].driver_agent.sequencer;

        // Wire virtual sequencer shared refs
        v_seqr.pf_mgr_ref   = pf_mgr;
        v_seqr.iommu_ref    = iommu;
        v_seqr.host_mem_ref = host_mem;

        // Wire concurrency controller
        conc_ctrl.vf_instances = vf_instances;
        conc_ctrl.wait_pol     = wait_pol;

        // Wire the compatibility PF manager alias.
        if (pf_mgr != null)
            pf_mgr.vf_instances = vf_instances;

    endfunction

    // Bind one required RC sequencer and optional TLM completion adapter to
    // all snapshot-declared VIO functions.
    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
        int unsigned next_protocol_event_vif_index;
        virtio_function_instance active_functions[$];
        virtual virtio_protocol_event_if candidate_protocol_vif;
        virtual virtio_protocol_event_if staged_protocol_vifs[DPU_MAX_FUNCTIONS];
        virtio_auto_fsm staged_pcie_fsms[DPU_MAX_FUNCTIONS];
        virtio_atomic_ops staged_pcie_ops[DPU_MAX_FUNCTIONS];

        if (!configuration_valid)
            return 0;
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("VIRTIO_ENV", "bind_pcie() received a null PCIe RC sequencer")
            configuration_valid = 0;
            return 0;
        end
        if (v_seqr == null) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a null virtual sequencer")
            configuration_valid = 0;
            return 0;
        end

        foreach (function_instances[function_index])
            active_functions.push_back(function_instances[function_index]);

        // Analysis connections are part of the atomic bind commit.  Validate
        // every supplied source port before function preflight allocates
        // candidates and before either the optional adapter or any function
        // can commit state.
        if ((pcie_rc_monitor != null) &&
            (pcie_rc_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe RC monitor with a null tlp_ap")
            foreach (active_functions[cancel_index])
                active_functions[cancel_index].cancel_preflight_bind_pcie();
            configuration_valid = 0;
            return 0;
        end
        if ((pcie_ep_monitor != null) &&
            (pcie_ep_monitor.tlp_ap == null)) begin
            `uvm_fatal("VIRTIO_ENV",
                "bind_pcie() received a PCIe EP monitor with a null tlp_ap")
            foreach (active_functions[cancel_index])
                active_functions[cancel_index].cancel_preflight_bind_pcie();
            configuration_valid = 0;
            return 0;
        end

        next_protocol_event_vif_index = 0;
        foreach (active_functions[function_index]) begin
            if (!preflight_function_pcie(
                active_functions[function_index], pcie_rc_seqr,
                next_protocol_event_vif_index,
                candidate_protocol_vif)) begin
                foreach (active_functions[cancel_index])
                    active_functions[cancel_index].cancel_preflight_bind_pcie();
                configuration_valid = 0;
                return 0;
            end
            staged_protocol_vifs[function_index] = candidate_protocol_vif;
            staged_pcie_fsms[function_index] =
                active_functions[function_index].pending_pcie_fsm_candidate();
            staged_pcie_ops[function_index] =
                active_functions[function_index].pending_pcie_ops_candidate();
            for (int unsigned prior_index = 0;
                 prior_index < function_index; prior_index++) begin
                if (staged_protocol_vifs[function_index] ==
                    staged_protocol_vifs[prior_index]) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        {"Active function indices %0d and %0d staged the ",
                         "same protocol event interface"},
                        prior_index, function_index))
                    foreach (active_functions[cancel_index])
                        active_functions[cancel_index].
                            cancel_preflight_bind_pcie();
                    configuration_valid = 0;
                    return 0;
                end
                if (staged_pcie_fsms[function_index] ==
                    staged_pcie_fsms[prior_index]) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        {"Active function indices %0d and %0d staged the ",
                         "same PCIe FSM candidate"},
                        prior_index, function_index))
                    foreach (active_functions[cancel_index])
                        active_functions[cancel_index].
                            cancel_preflight_bind_pcie();
                    configuration_valid = 0;
                    return 0;
                end
                if (staged_pcie_ops[function_index] ==
                    staged_pcie_ops[prior_index]) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        {"Active function indices %0d and %0d staged the ",
                         "same PCIe ops candidate"},
                        prior_index, function_index))
                    foreach (active_functions[cancel_index])
                        active_functions[cancel_index].
                            cancel_preflight_bind_pcie();
                    configuration_valid = 0;
                    return 0;
                end
            end
        end

        // Bind the optional completion adapter only after every function has
        // passed side-effect-free preflight and before any function commit.
        if ((tlm_adapter != null) &&
            !tlm_adapter.bind_registered_rc_driver()) begin
            foreach (active_functions[cancel_index])
                active_functions[cancel_index].cancel_preflight_bind_pcie();
            configuration_valid = 0;
            return 0;
        end

        next_protocol_event_vif_index = 0;
        foreach (active_functions[function_index]) begin
            if (!bind_function_pcie(
                active_functions[function_index], pcie_rc_seqr,
                pcie_rc_monitor, pcie_ep_monitor,
                next_protocol_event_vif_index,
                staged_protocol_vifs[function_index])) begin
                foreach (active_functions[cancel_index])
                    active_functions[cancel_index].cancel_preflight_bind_pcie();
                configuration_valid = 0;
                return 0;
            end
        end
        v_seqr.pcie_rc_seqr = pcie_rc_seqr;
        protocol_event_vif_index = next_protocol_event_vif_index;
        return 1;
    endfunction

    protected function bit preflight_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        inout int unsigned next_protocol_event_vif_index,
        output virtual virtio_protocol_event_if protocol_vif
    );
        string protocol_vif_key;
        string observer_why;

        if (function_instance == null) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        if ((function_instance.driver_agent == null) ||
            (function_instance.driver_agent.monitor == null) ||
            (function_instance.driver_agent.observer == null)) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        if (!function_instance.driver_agent.observer.
            preflight_mandatory_function_binding(
                function_instance.transport, observer_why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                {"Observer mandatory bind preflight failed for function ",
                 "BDF 0x%04h: %s"},
                function_instance.bdf, observer_why))
            return 0;
        end
        if (next_protocol_event_vif_index >= DPU_MAX_FUNCTIONS) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Protocol event interface pool exhausted at function BDF 0x%04h",
                function_instance.bdf))
            return 0;
        end
        protocol_vif_key = $sformatf("protocol_event_vif_%0d",
            next_protocol_event_vif_index);
        if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                null, "uvm_test_top", protocol_vif_key, protocol_vif) ||
            (protocol_vif == null)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "No protocol event interface configured for active function %0d",
                next_protocol_event_vif_index))
            return 0;
        end
        if (!function_instance.preflight_bind_pcie(pcie_rc_seqr))
            return 0;
        next_protocol_event_vif_index++;
        return 1;
    endfunction

    protected function bit bind_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input pcie_tl_base_monitor pcie_rc_monitor,
        input pcie_tl_base_monitor pcie_ep_monitor,
        inout int unsigned next_protocol_event_vif_index,
        input virtual virtio_protocol_event_if staged_protocol_vif = null
    );
        virtual virtio_protocol_event_if protocol_vif;
        string protocol_vif_key;

        if (function_instance == null) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        if ((function_instance.driver_agent == null) ||
            (function_instance.driver_agent.monitor == null) ||
            (function_instance.driver_agent.observer == null)) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
            return 0;
        end
        if (next_protocol_event_vif_index >= DPU_MAX_FUNCTIONS) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Protocol event interface pool exhausted at function BDF 0x%04h",
                function_instance.bdf))
            return 0;
        end
        protocol_vif = staged_protocol_vif;
        if (protocol_vif == null) begin
            protocol_vif_key = $sformatf("protocol_event_vif_%0d",
                next_protocol_event_vif_index);
            if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                    null, "uvm_test_top", protocol_vif_key, protocol_vif) ||
                (protocol_vif == null)) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "No protocol event interface configured for active function %0d",
                    next_protocol_event_vif_index))
                return 0;
            end
        end
        if (!function_instance.commit_preflight_bind_pcie(
            host_mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr)) begin
            return 0;
        end
        function_instance.driver_agent.observer.
            commit_mandatory_function_binding(
            function_instance.bdf, function_instance.transport);
        function_instance.driver_agent.monitor.protocol_vif = protocol_vif;
        next_protocol_event_vif_index++;
        if (pcie_rc_monitor != null)
            pcie_rc_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor != pcie_rc_monitor))
            pcie_ep_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        return 1;
    endfunction

    // ========================================================================
    // Report Phase
    //
    // Run leak checks and print barrier statistics.
    // Performance and verification reports are handled by their own
    // report_phase methods (called automatically by UVM).
    // ========================================================================

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        if (!configuration_valid)
            return;

        `uvm_info("VIRTIO_ENV", "========== Environment Report ==========", UVM_LOW)

        // Leak checks
        host_mem.leak_check();
        iommu.leak_check();
        foreach (function_instances[index])
            function_instances[index].vq_mgr.leak_check();

        // Barrier stats
        barrier.print_stats();

        `uvm_info("VIRTIO_ENV", "========== End Environment Report ==========", UVM_LOW)
    endfunction

endclass : virtio_net_env

`endif // VIRTIO_NET_ENV_SV
