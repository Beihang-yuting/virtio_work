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
// connect_phase because the PCIe env is created by the test, not by this
// env. The test should:
//   1. Create both pcie_tl_env and virtio_net_env
//   2. In connect_phase, wire pcie_rc_seqr into vf_instances via
//      wire_shared() and into v_seqr.pcie_rc_seqr
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

    // ===== Virtual sequencer =====
    virtio_virtual_sequencer        v_seqr;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // ========================================================================
    // Build Phase
    //
    // Retrieve config, create all components. VF instance count is driven
    // by cfg.num_vfs (minimum 1 for pure PF mode).
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        int unsigned num_instances;

        super.build_phase(phase);

        // Get config from config_db
        if (!uvm_config_db #(virtio_net_env_config)::get(this, "", "cfg", cfg))
            `uvm_fatal("VIRTIO_ENV", "No virtio_net_env_config found in config_db")

        // Validate config
        if (!cfg.validate())
            `uvm_warning("VIRTIO_ENV", "Config validation reported issues -- continuing")

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

        // Create PF manager
        pf_mgr = virtio_pf_manager::type_id::create("pf_mgr");
        pf_mgr.wait_pol = wait_pol;

        // Create VF instances (at least 1 for pure PF mode)
        num_instances = (cfg.num_vfs > 0) ? cfg.num_vfs : 1;
        vf_instances = new[num_instances];
        foreach (vf_instances[i]) begin
            vf_instances[i] = virtio_vf_instance::type_id::create(
                $sformatf("vf_%0d", i), this);
        end

        // Create verification components (conditionally)
        if (cfg.scb_enable)
            scb = virtio_scoreboard::type_id::create("scb", this);
        if (cfg.cov_enable)
            cov = virtio_coverage::type_id::create("cov", this);

        // Create concurrency/dynamic reconfig
        conc_ctrl    = virtio_concurrency_controller::type_id::create("conc_ctrl");
        dyn_reconfig = virtio_dynamic_reconfig::type_id::create("dyn_reconfig");

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

        // Wire shared components into VF instances
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

        // Wire PF manager
        pf_mgr.vf_instances = vf_instances;

        // Connect monitor analysis ports to scoreboard/coverage
        foreach (vf_instances[i]) begin
            if (scb != null)
                vf_instances[i].driver_agent.monitor.txn_ap.connect(scb.txn_imp);
            if (cov != null)
                vf_instances[i].driver_agent.monitor.txn_ap.connect(cov.analysis_imp);
        end

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

        `uvm_info("VIRTIO_ENV", "========== Environment Report ==========", UVM_LOW)

        // Leak checks
        host_mem.leak_check();
        iommu.leak_check();
        foreach (vf_instances[i])
            vf_instances[i].vq_mgr.leak_check();

        // Barrier stats
        barrier.print_stats();

        `uvm_info("VIRTIO_ENV", "========== End Environment Report ==========", UVM_LOW)
    endfunction

endclass : virtio_net_env

`endif // VIRTIO_NET_ENV_SV
