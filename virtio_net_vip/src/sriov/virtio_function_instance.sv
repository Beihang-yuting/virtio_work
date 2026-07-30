`ifndef VIRTIO_FUNCTION_INSTANCE_SV
`define VIRTIO_FUNCTION_INSTANCE_SV

// A DPU function is a complete virtio device, whether it is a PF or a VF.
// The compatibility virtio_vf_instance base owns the driver agent, transport,
// queue manager, and dataplane.  This specialization adds the Fabric
// identity and makes the PF/VF distinction explicit for new topology users.
class virtio_function_instance extends virtio_vf_instance;
    `uvm_component_utils(virtio_function_instance)

    dpu_function_kind_e function_kind;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_PF;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        apply_function_configuration();
    endfunction

    // Configuration may precede this component's build_phase.  The saved
    // identity is applied once transport and queue-manager objects exist.
    virtual function void configure_function(
        input dpu_function_kind_e kind,
        input dpu_function_key_t key,
        input bit [15:0] device_bdf,
        input dpu_bar_pair_lease_t bars[$],
        input dpu_resource_manager manager = null,
        input uvm_object pcie_ctx = null
    );
        function_kind = kind;
        function_key = key;
        bdf = device_bdf;
        vf_index = key.vf_id;
        bar_pairs = bars;
        resource_manager = manager;
        pcie_ctx_ref = pcie_ctx;
        apply_function_configuration();
    endfunction

    // BAR2/3 is a consumed address-space reservation, never a functional
    // transport window.  Monitors and focused tests use this helper rather
    // than creating a fake transport binding for the reserved pair.
    virtual function bit is_reserved_bar(input int unsigned bar_id);
        return (bar_id == 2) || (bar_id == 3);
    endfunction

    protected function void apply_function_configuration();
        string why;

        if ((transport == null) || (vq_mgr == null))
            return;

        transport.bdf = bdf;
        transport.is_vf = (function_kind == DPU_FUNCTION_VF);
        transport.vf_index = vf_index;
        transport.bar.requester_id = bdf;
        if ((resource_manager != null) || (bar_pairs.size() != 0))
            transport.bar.configure_fabric_bar_pairs(bar_pairs);
        vq_mgr.bdf = bdf;

        if (resource_manager != null) begin
            if ((resource_client == null) ||
                !resource_client.bind_to_fabric(
                    resource_manager, function_key, why
                )) begin
                `uvm_fatal("FUNCTION_INSTANCE", $sformatf(
                    "could not bind Fabric resources for %0d:%0d:%0d:%0d: %s",
                    function_key.host_id, function_key.pf_id, function_key.kind,
                    function_key.vf_id, why))
            end
            transport.configure_fabric_managed(resource_client);
        end
    endfunction
endclass : virtio_function_instance

`endif // VIRTIO_FUNCTION_INSTANCE_SV
