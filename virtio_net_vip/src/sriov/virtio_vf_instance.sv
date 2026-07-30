`ifndef VIRTIO_VF_INSTANCE_SV
`define VIRTIO_VF_INSTANCE_SV

// Compatibility surface for existing flat-VF environments.  The complete
// implementation belongs to virtio_function_instance; this wrapper prevents
// legacy callers from accidentally creating a PF through a VF API.
class virtio_vf_instance extends virtio_function_instance;
    `uvm_component_utils(virtio_vf_instance)

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_VF;
    endfunction

    virtual function void configure_function(
        input dpu_function_kind_e kind,
        input dpu_function_key_t key,
        input bit [15:0] device_bdf,
        input dpu_bar_pair_lease_t bars[$],
        input dpu_resource_manager manager = null,
        input uvm_object pcie_ctx = null
    );
        if ((kind != DPU_FUNCTION_VF) || (key.kind != DPU_FUNCTION_VF)) begin
            `uvm_fatal("VF_INSTANCE",
                "compatibility virtio_vf_instance requires a VF function key")
            return;
        end
        super.configure_function(kind, key, device_bdf, bars, manager, pcie_ctx);
    endfunction

    virtual function void configure_fabric_function(
        input dpu_function_key_t key,
        input dpu_bar_pair_lease_t bars[$],
        input dpu_resource_manager manager
    );
        configure_function(
            DPU_FUNCTION_VF, key, bdf, bars, manager, pcie_ctx_ref
        );
    endfunction
endclass : virtio_vf_instance

`endif // VIRTIO_VF_INSTANCE_SV
