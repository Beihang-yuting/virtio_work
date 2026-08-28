`ifndef VIRTIO_FUNCTION_INSTANCE_SV
`define VIRTIO_FUNCTION_INSTANCE_SV

// One independently addressable virtio function.  A PF and every VF own the
// same driver, transport, queue-manager, dataplane, Fabric identity, and BAR
// leases; only their function key and transport VF bit differ.
class virtio_function_instance extends uvm_component;
    `uvm_component_utils(virtio_function_instance)

    // Identity and snapshot-owned placement.
    int unsigned            vf_index;
    bit [15:0]              bdf;
    dpu_pcie_function_id_t  pcie_id;
    bit                     pcie_id_valid;
    dpu_function_key_t      function_key;
    dpu_function_kind_e     function_kind;
    dpu_service_key_t       service_key;
    dpu_bar_pair_lease_t    bar_pairs[$];
    dpu_resource_manager    resource_manager;
    virtio_resource_client  resource_client;
    protected dpu_device_snapshot configuration_snapshot;
    protected dpu_resource_snapshot configuration_resource_snapshot;

    // PCIe context is owned by the PCIe function manager, not this function.
    uvm_object              pcie_ctx_ref;

    // Owned virtio function components.
    virtio_driver_agent     driver_agent;
    virtqueue_manager       vq_mgr;
    virtio_net_dataplane    dataplane;
    virtio_pci_transport    transport;

    // Shared infrastructure references.
    host_mem_manager            mem;
    virtio_iommu_model          iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector    err_inj;
    virtio_wait_policy          wait_pol;

    vf_state_e             state = VF_CREATED;
    virtio_driver_config_t drv_cfg;
    local virtio_auto_fsm  pending_pcie_fsm;
    local virtio_atomic_ops pending_pcie_ops;
    local bit              pcie_bind_prepared;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_PF;
        pcie_id_valid = 0;
        pending_pcie_fsm = null;
        pending_pcie_ops = null;
        pcie_bind_prepared = 0;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        driver_agent = virtio_driver_agent::type_id::create("driver_agent", this);
        vq_mgr = virtqueue_manager::type_id::create("vq_mgr");
        dataplane = virtio_net_dataplane::type_id::create("dataplane");
        transport = virtio_pci_transport::type_id::create("transport");
        resource_client = virtio_resource_client::type_id::create("resource_client");
        apply_function_configuration();
    endfunction

    // Resolve all identity and placement from one frozen, service-keyed device
    // snapshot. Callers cannot provide raw BDF/BAR values, and an established
    // function binding cannot move to a different snapshot.
    virtual function bit configure_from_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        input dpu_resource_manager manager,
        input uvm_object pcie_ctx = null
    );
        dpu_function_key_t key;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t bar;
        string why;

        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a frozen device snapshot")
            return 0;
        end
        if (service_key.service_kind != DPU_SERVICE_VIO_NET) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                "function configuration requires a VIO-net service key")
            return 0;
        end
        if (!device_snapshot.get_service_owner(service_key, key, why) ||
            !device_snapshot.get_pcie_id(key, pcie_id, why) ||
            !device_snapshot.get_bar(key, DPU_BAR_DEVICE_MEMORY, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MAILBOX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if (!device_snapshot.get_bar(key, DPU_BAR_MSIX, bar, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not resolve snapshot VIO function: %s", why))
            return 0;
        end
        bars.push_back(bar);
        if ((configuration_snapshot != null) &&
            (configuration_snapshot != device_snapshot)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different device snapshot"})
            return 0;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot) ||
            (manager == null) ||
            !manager.is_seeded_from_snapshots(
                device_snapshot, resource_snapshot) ||
            !manager.contains_function(key)) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration requires its exact frozen resource ",
                 "snapshot and pair-seeded manager"})
            return 0;
        end
        if ((configuration_resource_snapshot != null) &&
            ((configuration_resource_snapshot != resource_snapshot) ||
             (dpu_service_key_name(this.service_key) !=
              dpu_service_key_name(service_key)) ||
             ((resource_manager != null) && (resource_manager != manager)) ||
             (pcie_ctx_ref != pcie_ctx))) begin
            `uvm_fatal("FUNCTION_INSTANCE",
                {"function configuration ownership cannot be reassigned to a ",
                 "different resource snapshot, service, manager, or PCIe context"})
            return 0;
        end
        if (resource_client != null) begin
            if (!resource_client.bind_to_service(
                    device_snapshot, resource_snapshot, service_key, why)) begin
                `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                    "could not import service resources for %s: %s",
                    dpu_service_key_name(service_key), why))
                return 0;
            end
        end
        configuration_snapshot = device_snapshot;
        configuration_resource_snapshot = resource_snapshot;
        function_kind = key.kind;
        function_key = key;
        this.service_key = service_key;
        bdf = pcie_id.bdf;
        this.pcie_id = pcie_id;
        pcie_id_valid = 1;
        vf_index = key.vf_id;
        bar_pairs = bars;
        resource_manager = manager;
        pcie_ctx_ref = pcie_ctx;
        apply_function_configuration();
        return 1;
    endfunction

    // Side-effect-free half of PCIe binding.  The environment preflights all
    // active functions before any one-shot FSM, observer, or monitor state is
    // committed, so a later function cannot leave earlier functions bound.
    function bit preflight_bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        string function_name;
        string why;
        virtio_auto_fsm candidate_fsm;
        virtio_atomic_ops candidate_ops;

        cancel_preflight_bind_pcie();
        function_name = $sformatf("function_%0d", vf_index);
        if (pcie_rc_seqr == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s received a null PCIe RC sequencer", function_name))
            return 0;
        end
        if (driver_agent == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing driver agent", function_name))
            return 0;
        end
        if ((transport == null) || (vq_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing transport or virtqueue manager", function_name))
            return 0;
        end
        if ((transport.bar == null) || (transport.notify_mgr == null) ||
            (transport.cap_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                {"%s is missing transport BAR, notify manager, or ",
                 "capability manager"}, function_name))
            return 0;
        end
        candidate_fsm = driver_agent.fsm;
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create(
                {function_name, "_fsm"}, this);
        if (candidate_fsm == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned a null PCIe FSM", function_name))
            return 0;
        end
        candidate_ops = driver_agent.ops;
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create(
                {function_name, "_ops"}, this);
        if (candidate_ops == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned null PCIe atomic ops", function_name))
            return 0;
        end
        if (!candidate_fsm.mq_pair_limit_binding_supported(
            drv_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end
        pending_pcie_fsm = candidate_fsm;
        pending_pcie_ops = candidate_ops;
        pcie_bind_prepared = 1;
        return 1;
    endfunction

    function virtio_auto_fsm pending_pcie_fsm_candidate();
        return pending_pcie_fsm;
    endfunction

    function virtio_atomic_ops pending_pcie_ops_candidate();
        return pending_pcie_ops;
    endfunction

    function void cancel_preflight_bind_pcie();
        pending_pcie_fsm = null;
        pending_pcie_ops = null;
        pcie_bind_prepared = 0;
    endfunction

    function bit commit_preflight_bind_pcie(
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;

        if (!pcie_bind_prepared || (pending_pcie_fsm == null) ||
            (pending_pcie_ops == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "function_%0d PCIe bind commit requires successful preflight",
                vf_index))
            return 0;
        end
        ops = pending_pcie_ops;
        fsm = pending_pcie_fsm;
        if (!commit_validated_pcie_components(
            $sformatf("function_%0d", vf_index), transport, vq_mgr,
            driver_agent, hmem, iommu_mdl, bar_mdl, einj, wpol, drv_cfg,
            pcie_rc_seqr, ops, fsm)) begin
            return 0;
        end
        mem = hmem;
        iommu = iommu_mdl;
        barrier = bar_mdl;
        err_inj = einj;
        wait_pol = wpol;
        cancel_preflight_bind_pcie();
        return 1;
    endfunction

    // Commit only handles that have passed all null/factory/MQ checks.  The
    // environment reaches this helper through preflight; the standalone API
    // below performs the same checks before calling it.
    local function bit commit_validated_pcie_components(
        input string function_name,
        input virtio_pci_transport transport_ref,
        input virtqueue_manager vq_mgr_ref,
        input virtio_driver_agent driver_agent_ref,
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input virtio_driver_config_t driver_cfg,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        input virtio_atomic_ops ops,
        input virtio_auto_fsm fsm
    );
        string why;

        if (!fsm.bind_mq_pair_limit(
            driver_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end

        vq_mgr_ref.mem = hmem;
        vq_mgr_ref.iommu = iommu_mdl;
        vq_mgr_ref.barrier = bar_mdl;
        vq_mgr_ref.err_inj = einj;
        vq_mgr_ref.wait_pol = wpol;
        transport_ref.wait_pol = wpol;
        transport_ref.bar.pcie_rc_seqr = pcie_rc_seqr;
        transport_ref.notify_mgr.bar = transport_ref.bar;
        transport_ref.cap_mgr.bar_ref = transport_ref.bar;

        ops.transport = transport_ref;
        ops.vq_mgr = vq_mgr_ref;
        ops.mem = hmem;
        ops.iommu = iommu_mdl;
        ops.wait_pol = wpol;

        fsm.ops = ops;
        fsm.drv_cfg = driver_cfg;

        if (driver_agent_ref != null) begin
            driver_agent_ref.ops = ops;
            driver_agent_ref.fsm = fsm;
            if (driver_agent_ref.driver != null) begin
                driver_agent_ref.driver.ops = ops;
                driver_agent_ref.driver.fsm = fsm;
            end
            if (driver_agent_ref.monitor != null) begin
                driver_agent_ref.monitor.transport = transport_ref;
                driver_agent_ref.monitor.vq_mgr = vq_mgr_ref;
            end
        end
        return 1;
    endfunction

    // Public binding primitive.  The environment uses it for each active
    // PF/VF; standalone TLM tests use a compatible function instance too.
    function bit bind_pcie_components(
        input string function_name,
        input virtio_pci_transport transport_ref,
        input virtqueue_manager vq_mgr_ref,
        input virtio_driver_agent driver_agent_ref,
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input virtio_driver_config_t driver_cfg,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        ref virtio_atomic_ops ops,
        ref virtio_auto_fsm fsm
    );
        string why;
        virtio_auto_fsm candidate_fsm;
        virtio_atomic_ops candidate_ops;

        if (pcie_rc_seqr == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s received a null PCIe RC sequencer", function_name))
            return 0;
        end
        if ((transport_ref == null) || (vq_mgr_ref == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s is missing transport or virtqueue manager", function_name))
            return 0;
        end
        if ((transport_ref.bar == null) ||
            (transport_ref.notify_mgr == null) ||
            (transport_ref.cap_mgr == null)) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                {"%s is missing transport BAR, notify manager, or ",
                 "capability manager"}, function_name))
            return 0;
        end

        candidate_fsm = fsm;
        if (candidate_fsm == null)
            candidate_fsm = virtio_auto_fsm::type_id::create(
                {function_name, "_fsm"});
        if (candidate_fsm == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned a null PCIe FSM", function_name))
            return 0;
        end
        candidate_ops = ops;
        if (candidate_ops == null)
            candidate_ops = virtio_atomic_ops::type_id::create(
                {function_name, "_ops"});
        if (candidate_ops == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s factory returned null PCIe atomic ops", function_name))
            return 0;
        end
        if (!candidate_fsm.mq_pair_limit_binding_supported(
            driver_cfg.max_vio_net_qpairs_per_device, why
        )) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "%s could not bind its MQ pair limit: %s", function_name, why))
            return 0;
        end
        if (!commit_validated_pcie_components(
            function_name, transport_ref, vq_mgr_ref, driver_agent_ref,
            hmem, iommu_mdl, bar_mdl, einj, wpol, driver_cfg, pcie_rc_seqr,
            candidate_ops, candidate_fsm)) begin
            return 0;
        end
        ops = candidate_ops;
        fsm = candidate_fsm;
        return 1;
    endfunction

    function bit wire_shared(
        host_mem_manager hmem,
        virtio_iommu_model iommu_mdl,
        virtio_memory_barrier_model bar_mdl,
        virtqueue_error_injector einj,
        virtio_wait_policy wpol,
        uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;

        if (driver_agent == null) begin
            `uvm_fatal("FUNCTION_BIND", $sformatf(
                "function_%0d is missing driver agent", vf_index))
            return 0;
        end
        ops = driver_agent.ops;
        fsm = driver_agent.fsm;
        if (!bind_pcie_components(
            $sformatf("function_%0d", vf_index), transport, vq_mgr,
            driver_agent, hmem, iommu_mdl, bar_mdl, einj, wpol, drv_cfg,
            pcie_rc_seqr, ops, fsm)) begin
            return 0;
        end
        mem = hmem;
        iommu = iommu_mdl;
        barrier = bar_mdl;
        err_inj = einj;
        wait_pol = wpol;
        return 1;
    endfunction

    function bit bind_pcie(
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr
    );
        return wire_shared(
            mem, iommu, barrier, err_inj, wait_pol, pcie_rc_seqr);
    endfunction

    virtual task init(virtio_driver_config_t cfg);
        drv_cfg = cfg;
        state = VF_CONFIGURED;
    endtask

    // A full reset requested through the PF Admin VQ belongs to this normal
    // PF lifecycle owner, not to the separate Admin VQ.  Quiesce any running
    // FSM before the verified device reset; only confirmed completion permits
    // the function and FSM to become eligible for a fresh initialization.
    virtual task reset_pf_lifecycle(ref bit reset_complete);
        virtio_atomic_ops pf_ops;
        virtio_auto_fsm   pf_fsm;

        reset_complete = 0;
        if (function_kind != DPU_FUNCTION_PF) begin
            `uvm_error("FUNCTION_INSTANCE",
                "reset_pf_lifecycle: only a PF may own full-device recovery")
            return;
        end
        if ((driver_agent == null) || (driver_agent.ops == null) ||
            (driver_agent.fsm == null)) begin
            `uvm_error("FUNCTION_INSTANCE",
                "reset_pf_lifecycle: PF driver/FSM/ops lifecycle is not bound")
            return;
        end

        pf_ops = driver_agent.ops;
        pf_fsm = driver_agent.fsm;
        if (pf_fsm.state == FSM_RUNNING)
            pf_fsm.stop_dataplane();

        pf_ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            // device_reset_verified() retained normal PF queue/DMA ownership;
            // record the failed lifecycle instead of representing a usable or
            // successfully reinitialized function.
            state = VF_RESET_FAILED;
            pf_fsm.state = FSM_ERROR;
            return;
        end

        state = VF_REINIT_REQUIRED;
        pf_fsm.state = FSM_REINIT_REQUIRED;
    endtask

    virtual task shutdown();
        if ((state == VF_ACTIVE) && (driver_agent.fsm != null))
            driver_agent.fsm.stop_dataplane();
        if (driver_agent.ops != null)
            driver_agent.ops.device_reset();
        if (resource_client != null)
            resource_client.reset_runtime_state();
        state = VF_DISABLED;
    endtask

    virtual function void on_flr();
        vq_mgr.detach_all_queues();
        dataplane.cleanup_all();
        if (resource_client != null)
            resource_client.reset_runtime_state();
        state = VF_FLR;
    endfunction

    virtual task reinit_after_flr(virtio_driver_config_t cfg);
        state = VF_CREATED;
        init(cfg);
    endtask

    virtual function vf_state_e get_state();
        return state;
    endfunction

    virtual function void set_active();
        if ((state == VF_REINIT_REQUIRED) || (state == VF_RESET_FAILED)) begin
            `uvm_error("FUNCTION_INSTANCE", $sformatf(
                "set_active: function %0d:%0d:%0d:%0d requires reinitialization before activation from state %s",
                function_key.host_id, function_key.pf_id, function_key.kind,
                function_key.vf_id, state.name()))
            return;
        end
        if (state != VF_CONFIGURED) begin
            `uvm_warning("FUNCTION_INSTANCE", $sformatf(
                "set_active: function %0d:%0d:%0d:%0d is in state %s",
                function_key.host_id, function_key.pf_id, function_key.kind,
                function_key.vf_id, state.name()))
        end
        state = VF_ACTIVE;
    endfunction

    protected function void apply_function_configuration();
        string why;

        if ((transport == null) || (vq_mgr == null) || (resource_client == null))
            return;
        if (pcie_id_valid)
            transport.configure_pcie_identity(pcie_id);
        else begin
            // Compatibility for standalone instances authored before a
            // frozen snapshot is attached.  Environment-owned functions
            // always take the full-identity branch above.
            transport.bdf = bdf;
            transport.notify_mgr.set_function_bdf(bdf);
            transport.bar.requester_id = bdf;
        end
        transport.is_vf = (function_kind == DPU_FUNCTION_VF);
        transport.vf_index = vf_index;
        vq_mgr.bdf = bdf;
        if (bar_pairs.size() != 0)
            transport.bar.configure_fabric_bar_pairs(bar_pairs);

        if (configuration_resource_snapshot == null)
            return;
        if (!resource_client.bind_to_service(
                configuration_snapshot, configuration_resource_snapshot,
                service_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not import service resources for %s: %s",
                dpu_service_key_name(service_key), why))
            return;
        end
        transport.configure_fabric_managed(resource_client);
    endfunction
endclass : virtio_function_instance

`endif // VIRTIO_FUNCTION_INSTANCE_SV
