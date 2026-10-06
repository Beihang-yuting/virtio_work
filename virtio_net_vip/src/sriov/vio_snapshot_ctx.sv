`ifndef VIO_SNAPSHOT_CTX_SV
`define VIO_SNAPSHOT_CTX_SV

// 目录层次：src/sriov。一次校验、此后只读的 VIO snapshot 上下文：冻结的 device
// snapshot、引用它的冻结 resource snapshot、以及由这一对 snapshot 播种的 resource
// manager。env 构建一次后向 PF/Function/resource client 下传，下游不再重复校验
// frozen/引用/seeded 关系。本对象只借用三者，不拥有其生命周期。
class vio_snapshot_ctx extends uvm_object;
    `uvm_object_utils(vio_snapshot_ctx)

    local dpu_device_snapshot   m_device_snapshot;
    local dpu_resource_snapshot m_resource_snapshot;
    local dpu_resource_manager  m_manager;

    // 构造出的对象在 create_checked 赋值前不可用；外部不能修改三个引用。
    function new(string name = "vio_snapshot_ctx");
        super.new(name);
    endfunction

    // 校验三者关系：device snapshot 已冻结；resource snapshot 已冻结且引用该
    // device snapshot；manager 已由这一对 snapshot 播种。成功返回只读上下文，
    // 失败返回 null 并在 why 中给出原因。
    static function vio_snapshot_ctx create_checked(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_resource_manager manager,
        output string why
    );
        vio_snapshot_ctx ctx;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen()) begin
            why = "VIO snapshot context requires a frozen device snapshot";
            return null;
        end
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = {"VIO snapshot context requires a frozen resource snapshot ",
                   "of the same device snapshot"};
            return null;
        end
        if ((manager == null) || !manager.is_snapshot_seeded() ||
            !manager.is_seeded_from_snapshots(device_snapshot, resource_snapshot)) begin
            why = {"VIO snapshot context requires a resource manager seeded ",
                   "from the same snapshot pair"};
            return null;
        end
        ctx = vio_snapshot_ctx::type_id::create("vio_snapshot_ctx");
        ctx.m_device_snapshot = device_snapshot;
        ctx.m_resource_snapshot = resource_snapshot;
        ctx.m_manager = manager;
        return ctx;
    endfunction

    // 只读访问器：返回已校验的冻结 device snapshot。
    function dpu_device_snapshot device_snapshot();
        return m_device_snapshot;
    endfunction

    // 只读访问器：返回已校验的冻结 resource snapshot。
    function dpu_resource_snapshot resource_snapshot();
        return m_resource_snapshot;
    endfunction

    // 只读访问器：返回由同一对 snapshot 播种的 resource manager。
    function dpu_resource_manager manager();
        return m_manager;
    endfunction
endclass : vio_snapshot_ctx

`endif // VIO_SNAPSHOT_CTX_SV
