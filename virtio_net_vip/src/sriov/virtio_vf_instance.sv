`ifndef VIRTIO_VF_INSTANCE_SV
`define VIRTIO_VF_INSTANCE_SV

// VF specialization of the snapshot/service-resolved function instance.
// 中文文件头：
// 职责——virtio_function_instance 的 VF 特化：仅把 function_kind 固定为 VF，
//   并在配置入口处强制校验 service 的 owner 必须是 VF function。
// 依赖——全部实际组件创建与 snapshot 解析逻辑复用基类；本类不新增状态。
// 所有权——VF 的 BDF/BAR/资源仍由冻结 snapshot 与 resource manager 拥有，
//   本实例只是绑定视图；PCIe 上下文归 PF 侧的 function manager 管理。
class virtio_vf_instance extends virtio_function_instance;
    `uvm_component_utils(virtio_vf_instance)

    // 构造函数：与基类相同，仅把 function_kind 覆盖为 DPU_FUNCTION_VF，
    // 使后续 snapshot 解析走 VF 路径（transport VF 位等由基类据此设置）。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_kind = DPU_FUNCTION_VF;
    endfunction

    // 在基类解析之前加一道 VF 守卫：service 必须由冻结 snapshot 声明，
    // 且其 owner 的 kind 必须是 VF——防止把 PF 服务错绑到 VF 实例上。
    // 校验通过后完全委托基类 configure_from_service。
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
