`ifndef VIRTIO_FUNCTION_INSTANCE_SV
`define VIRTIO_FUNCTION_INSTANCE_SV

// One independently addressable virtio function.  A PF and every VF own the
// same driver, transport, queue-manager, dataplane, Fabric identity, and BAR
// leases; only their function key and transport VF bit differ.
class virtio_function_instance extends uvm_component;
    `uvm_component_utils(virtio_function_instance)

    // Identity and Fabric-owned placement.
    int unsigned            vf_index;
    bit [15:0]              bdf;
    dpu_function_key_t      function_key;
    dpu_function_kind_e     function_kind;
    dpu_bar_pair_lease_t    bar_pairs[$];
    dpu_resource_manager    resource_manager;
    virtio_resource_client  resource_client;

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
    protected bit [63:0]   legacy_bar_base;
    protected bit          legacy_bar_base_valid;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_PF;
        legacy_bar_base_valid = 0;
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

    // Fabric topology supplies all identity and BAR leases before transport
    // discovery.  BAR0/1 is the virtio function window, BAR2/3 is a consumed
    // reservation, and BAR4/5 is MSI-X only; the BAR accessor enforces roles.
    virtual function void configure_function(
        input dpu_function_kind_e kind,
        input dpu_function_key_t key,
        input bit [15:0] device_bdf,
        input dpu_bar_pair_lease_t bars[$],
        input dpu_resource_manager manager = null,
        input uvm_object pcie_ctx = null
    );
        if (kind != key.kind) begin
            `uvm_error("FUNCTION_INSTANCE", $sformatf(
                "transport kind %0d disagrees with Fabric function key kind %0d",
                kind, key.kind))
            return;
        end
        function_kind = kind;
        function_key = key;
        bdf = device_bdf;
        vf_index = key.vf_id;
        bar_pairs = bars;
        resource_manager = manager;
        pcie_ctx_ref = pcie_ctx;
        apply_function_configuration();
    endfunction

    // Legacy flat-VF callers configure a local BAR0 rather than Fabric BAR
    // leases.  A compatibility VF wrapper fixes function_kind to VF.
    virtual function void configure(
        input int unsigned configured_vf_index,
        input bit [15:0] device_bdf,
        input bit [63:0] bar_base,
        input uvm_object pcie_ctx
    );
        vf_index = configured_vf_index;
        bdf = device_bdf;
        pcie_ctx_ref = pcie_ctx;
        legacy_bar_base = bar_base;
        legacy_bar_base_valid = 1;
        apply_function_configuration();
    endfunction

    virtual function void configure_bar_pairs(
        input dpu_bar_pair_lease_t bars[$]
    );
        bar_pairs = bars;
        apply_function_configuration();
    endfunction

    virtual function bit is_reserved_bar(input int unsigned bar_id);
        return (bar_id == 2) || (bar_id == 3);
    endfunction

    virtual function void wire_shared(
        host_mem_manager hmem,
        virtio_iommu_model iommu_mdl,
        virtio_memory_barrier_model bar_mdl,
        virtqueue_error_injector einj,
        virtio_wait_policy wpol,
        uvm_sequencer #(uvm_sequence_item) pcie_rc_seqr
    );
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;

        mem = hmem;
        iommu = iommu_mdl;
        barrier = bar_mdl;
        err_inj = einj;
        wait_pol = wpol;
        vq_mgr.mem = hmem;
        vq_mgr.iommu = iommu_mdl;
        vq_mgr.barrier = bar_mdl;
        vq_mgr.err_inj = einj;
        vq_mgr.wait_pol = wpol;
        transport.wait_pol = wpol;
        $cast(transport.bar.pcie_rc_seqr, pcie_rc_seqr);
        transport.notify_mgr.bar = transport.bar;
        transport.cap_mgr.bar_ref = transport.bar;

        ops = virtio_atomic_ops::type_id::create(
            $sformatf("function_%0d_ops", vf_index));
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = hmem;
        ops.iommu = iommu_mdl;
        ops.wait_pol = wpol;
        fsm = virtio_auto_fsm::type_id::create(
            $sformatf("function_%0d_fsm", vf_index));
        fsm.ops = ops;
        fsm.drv_cfg = drv_cfg;
        driver_agent.ops = ops;
        driver_agent.fsm = fsm;
    endfunction

    virtual task init(virtio_driver_config_t cfg);
        drv_cfg = cfg;
        state = VF_CONFIGURED;
    endtask

    virtual task shutdown();
        if ((state == VF_ACTIVE) && (driver_agent.fsm != null))
            driver_agent.fsm.stop_dataplane();
        if (driver_agent.ops != null)
            driver_agent.ops.device_reset();
        release_fabric_qpairs("shutdown");
        state = VF_DISABLED;
    endtask

    virtual function void on_flr();
        vq_mgr.detach_all_queues();
        dataplane.cleanup_all();
        release_fabric_qpairs("FLR");
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
        transport.bdf = bdf;
        transport.is_vf = (function_kind == DPU_FUNCTION_VF);
        transport.vf_index = vf_index;
        transport.bar.requester_id = bdf;
        vq_mgr.bdf = bdf;
        if (bar_pairs.size() != 0)
            transport.bar.configure_fabric_bar_pairs(bar_pairs);
        else if (legacy_bar_base_valid)
            transport.bar.bar_base[0] = legacy_bar_base;

        if (resource_manager == null)
            return;
        if (!resource_client.bind_to_fabric(resource_manager, function_key, why)) begin
            `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                "could not bind Fabric resources for %0d:%0d:%0d:%0d: %s",
                function_key.host_id, function_key.pf_id, function_key.kind,
                function_key.vf_id, why))
        end
        transport.configure_fabric_managed(resource_client);
    endfunction

    protected function void release_fabric_qpairs(input string lifecycle);
        string why;

        if ((resource_manager == null) || (resource_client == null) ||
            !resource_client.has_pending_qpair_cleanup()) begin
            return;
        end
        if (!resource_client.release_qpairs(why)) begin
            `uvm_error("FUNCTION_INSTANCE", $sformatf(
                "%s could not release Fabric QP leases for %0d:%0d:%0d:%0d: %s",
                lifecycle, function_key.host_id, function_key.pf_id,
                function_key.kind, function_key.vf_id, why))
        end
    endfunction
endclass : virtio_function_instance

`endif // VIRTIO_FUNCTION_INSTANCE_SV
