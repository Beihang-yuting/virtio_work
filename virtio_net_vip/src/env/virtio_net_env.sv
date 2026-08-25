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

    // ===== DPU Fabric function topology =====
    dpu_fabric_env             fabric;
    virtio_pf_instance         pf_instances[];
    protected bit              fabric_topology;
    protected bit              configuration_valid;

    // ===== VF instances (dynamic array based on num_vfs) =====
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
    endfunction

    protected function bit [15:0] fabric_pf_bdf(
        input int unsigned host_id,
        input int unsigned pf_id
    );
        return cfg.pf_bdf +
               ((host_id * DPU_MAX_PFS_PER_HOST + pf_id) *
                (DPU_MAX_VFS_PER_PF + 1));
    endfunction

    protected function void build_fabric_topology();
        int unsigned flat_pf_id;

        pf_instances = new[cfg.total_fabric_pfs()];
        flat_pf_id = 0;
        for (int unsigned host_id = 0; host_id < cfg.num_hosts; host_id++) begin
            for (int unsigned pf_id = 0;
                 pf_id < cfg.num_pfs_per_host[host_id];
                 pf_id++) begin
                pf_instances[flat_pf_id] = virtio_pf_instance::type_id::create(
                    $sformatf("pf_%0d_%0d", host_id, pf_id), this
                );
                pf_instances[flat_pf_id].configure_topology(
                    host_id, pf_id, cfg.num_vfs_per_pf[host_id][pf_id],
                    fabric_pf_bdf(host_id, pf_id)
                );
                flat_pf_id++;
            end
        end
    endfunction

    protected function void configure_fabric_resources();
        dpu_fabric_env_config fabric_cfg;
        dpu_resource_pool_config_t qpair_profile;
        dpu_resource_manager resource_manager;
        string why;

        fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0100_0000_0000;
        fabric_cfg.dut_caps.copy_from(cfg.dut_caps);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            cfg.dut_caps.max_vio_net_qpairs_per_device;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Fabric QP profile registration failed: %s", why))
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", resource_manager
        )) begin
            `uvm_fatal("VIRTIO_ENV", "Fabric did not publish a resource manager")
        end
        foreach (pf_instances[index]) begin
            if (!resource_manager.register_function(pf_instances[index].pf_key, why)) begin
                `uvm_fatal("VIRTIO_ENV", $sformatf(
                    "PF registration failed for topology entry %0d: %s", index, why))
            end
            foreach (pf_instances[index].vf_keys[vf_id]) begin
                if (!resource_manager.register_function(
                    pf_instances[index].vf_keys[vf_id], why
                )) begin
                    `uvm_fatal("VIRTIO_ENV", $sformatf(
                        "VF registration failed for topology entry %0d VF %0d: %s",
                        index, vf_id, why))
                end
            end
        end
        foreach (pf_instances[index])
            pf_instances[index].configure_fabric_resources(resource_manager);
    endfunction

    protected function void flatten_fabric_vfs();
        int unsigned flat_vf_id;

        vf_instances = new[cfg.total_fabric_vfs()];
        flat_vf_id = 0;
        foreach (pf_instances[pf_index]) begin
            foreach (pf_instances[pf_index].vf_functions[vf_id]) begin
                vf_instances[flat_vf_id] =
                    pf_instances[pf_index].vf_functions[vf_id];
                flat_vf_id++;
            end
        end
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Retrieve config, create all components. VF instance count is driven
    // by cfg.num_vfs (minimum 1 for pure PF mode).
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        int unsigned num_instances;
        string why;

        super.build_phase(phase);

        // Get config from config_db
        if (!uvm_config_db #(virtio_net_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal("VIRTIO_ENV", "No virtio_net_env_config found in config_db")
            return;
        end

        // Validate config
        if (!cfg.validate()) begin
            `uvm_fatal("VIRTIO_ENV",
                "Invalid virtio-net configuration; refusing to build environment")
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

        fabric_topology = cfg.uses_fabric_topology();
        if (fabric_topology) begin
            fabric = dpu_fabric_env::type_id::create("fabric", this);
            build_fabric_topology();
            vf_instances = new[0];
        end
        else begin
            // Compatibility path for existing flat-VF tests and sequences.
            pf_mgr = virtio_pf_manager::type_id::create("pf_mgr");
            pf_mgr.wait_pol = wait_pol;
            num_instances = (cfg.num_vfs > 0) ? cfg.num_vfs : 1;
            vf_instances = new[num_instances];
            foreach (vf_instances[i]) begin
                vf_instances[i] = virtio_vf_instance::type_id::create(
                    $sformatf("vf_%0d", i), this);
            end
        end

        // Create verification components (conditionally)
        if (cfg.scb_enable)
            scb = virtio_scoreboard::type_id::create("scb", this);
        if (cfg.cov_enable)
            cov = virtio_coverage::type_id::create("cov", this);

        // Create concurrency/dynamic reconfig
        conc_ctrl    = virtio_concurrency_controller::type_id::create("conc_ctrl");
        dyn_reconfig = virtio_dynamic_reconfig::type_id::create("dyn_reconfig");
        if (!dyn_reconfig.bind_dut_caps(cfg.dut_caps, why)) begin
            configuration_valid = 0;
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Dynamic reconfiguration capability bind failed: %s", why))
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
        super.connect_phase(phase);
        if (!configuration_valid)
            return;

        if (fabric_topology) begin
            configure_fabric_resources();
            flatten_fabric_vfs();
            pf_mgr = pf_instances[0].pf_manager;
            pf_mgr.wait_pol = wait_pol;
            foreach (pf_instances[pf_index]) begin
                pf_instances[pf_index].pf_function.drv_cfg =
                    cfg.get_default_driver_config();
                if (scb != null) begin
                    pf_instances[pf_index].pf_function.driver_agent.monitor.txn_ap.connect(
                        scb.txn_imp
                    );
                end
                if (cov != null) begin
                    pf_instances[pf_index].pf_function.driver_agent.monitor.txn_ap.connect(
                        cov.analysis_imp
                    );
                end
            end
        end

        // Wire shared components into the compatibility VF view.
        foreach (vf_instances[i]) begin
            // Set VF config from env config
            vf_instances[i].drv_cfg = cfg.get_vf_config(i);

            // Note: wire_shared() needs pcie_rc_seqr which comes from
            // the PCIe TL env. This connection happens in the test's
            // connect_phase after both envs exist.
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
        pf_mgr.vf_instances = vf_instances;

        // Connect monitor analysis ports to scoreboard/coverage
        foreach (vf_instances[i]) begin
            if (scb != null)
                vf_instances[i].driver_agent.monitor.txn_ap.connect(scb.txn_imp);
            if (cov != null)
                vf_instances[i].driver_agent.monitor.txn_ap.connect(cov.analysis_imp);
        end

    endfunction

    // Bind one required RC sequencer and optional TLM completion adapter to
    // all live functions. Fabric topology owns independent PF and VF
    // functions, so it must not be reduced to the compatibility vf_instances
    // view.
    virtual function void bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_tlm_completion_adapter tlm_adapter = null,
        input pcie_tl_base_monitor pcie_rc_monitor = null,
        input pcie_tl_base_monitor pcie_ep_monitor = null
    );
        if (!configuration_valid)
            return;
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("VIRTIO_ENV", "bind_pcie() received a null PCIe RC sequencer")
        end

        // A non-null adapter owns the factory-created RC shim. Bind and
        // validate that shim only when the caller supplies the adapter.
        if (tlm_adapter != null)
            tlm_adapter.bind_registered_rc_driver();
        v_seqr.pcie_rc_seqr = pcie_rc_seqr;
        protocol_event_vif_index = 0;
        if (fabric_topology) begin
            foreach (pf_instances[pf_index]) begin
                bind_function_pcie(
                    pf_instances[pf_index].pf_function, pcie_rc_seqr,
                    pcie_rc_monitor, pcie_ep_monitor);
                foreach (pf_instances[pf_index].vf_functions[vf_index])
                    bind_function_pcie(
                        pf_instances[pf_index].vf_functions[vf_index],
                        pcie_rc_seqr, pcie_rc_monitor, pcie_ep_monitor);
            end
        end
        else begin
            foreach (vf_instances[vf_index])
                bind_function_pcie(vf_instances[vf_index], pcie_rc_seqr,
                    pcie_rc_monitor, pcie_ep_monitor);
        end
    endfunction

    protected virtual function void bind_function_pcie(
        input virtio_function_instance function_instance,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input pcie_tl_base_monitor pcie_rc_monitor,
        input pcie_tl_base_monitor pcie_ep_monitor
    );
        virtual virtio_protocol_event_if protocol_vif;
        string protocol_vif_key;

        function_instance.mem = host_mem;
        function_instance.iommu = iommu;
        function_instance.barrier = barrier;
        function_instance.err_inj = err_inj;
        function_instance.wait_pol = wait_pol;
        function_instance.bind_pcie(pcie_rc_seqr);
        if ((function_instance.driver_agent == null) ||
            (function_instance.driver_agent.observer == null)) begin
            `uvm_fatal("VIRTIO_ENV", "Function PCIe bind requires a monitor observer")
        end
        function_instance.driver_agent.observer.configure_function(
            function_instance.bdf, function_instance.transport);
        if (protocol_event_vif_index >= DPU_MAX_FUNCTIONS) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "Protocol event interface pool exhausted at function BDF 0x%04h",
                function_instance.bdf))
        end
        protocol_vif_key = $sformatf("protocol_event_vif_%0d",
            protocol_event_vif_index);
        if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                null, "uvm_test_top", protocol_vif_key, protocol_vif)) begin
            `uvm_fatal("VIRTIO_ENV", $sformatf(
                "No protocol event interface configured for active function %0d",
                protocol_event_vif_index))
        end
        function_instance.driver_agent.monitor.protocol_vif = protocol_vif;
        protocol_event_vif_index++;
        if (pcie_rc_monitor != null)
            pcie_rc_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
        if ((pcie_ep_monitor != null) && (pcie_ep_monitor != pcie_rc_monitor))
            pcie_ep_monitor.tlp_ap.connect(
                function_instance.driver_agent.observer.analysis_export);
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
        foreach (vf_instances[i])
            vf_instances[i].vq_mgr.leak_check();
        if (fabric_topology) begin
            foreach (pf_instances[index])
                pf_instances[index].pf_function.vq_mgr.leak_check();
        end

        // Barrier stats
        barrier.print_stats();

        `uvm_info("VIRTIO_ENV", "========== End Environment Report ==========", UVM_LOW)
    endfunction

endclass : virtio_net_env

`endif // VIRTIO_NET_ENV_SV
