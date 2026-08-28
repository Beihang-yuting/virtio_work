`ifndef VIRTIO_VF_INSTANCE_SV
`define VIRTIO_VF_INSTANCE_SV

// VF specialization of the snapshot/service-resolved function instance.
class virtio_vf_instance extends virtio_function_instance;
    `uvm_component_utils(virtio_vf_instance)

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_VF;
    endfunction

    virtual function bit configure_from_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        input dpu_resource_manager manager,
        input uvm_object pcie_ctx = null
    );
        dpu_function_key_t owner;
        string why;

        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            !device_snapshot.get_service_owner(service_key, owner, why)) begin
            `uvm_fatal("VF_INSTANCE",
                "VF instance requires a frozen snapshot-declared service")
            return 0;
        end
        if (owner.kind != DPU_FUNCTION_VF) begin
            `uvm_fatal("VF_INSTANCE",
                "virtio_vf_instance requires a VF-owned service")
            return 0;
        end
        return super.configure_from_service(
            device_snapshot, resource_snapshot, service_key, manager, pcie_ctx);
    endfunction

endclass : virtio_vf_instance

`endif // VIRTIO_VF_INSTANCE_SV
