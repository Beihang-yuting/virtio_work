`ifndef VIRTIO_RESOURCE_CLIENT_SV
`define VIRTIO_RESOURCE_CLIENT_SV

// Read-only VIO view of one service's placement-owned qpair bindings.
// 中文文件头：
// 职责——为单个 VIO-net service 提供其 qpair 绑定（local pair/virtqueue id
//   与 global qpair id 的映射表）的只读视图，并维护 runtime_ready 标记。
// 依赖——绑定时要求一对互相引用的冻结 device/resource snapshot；映射数据
//   全部来自 resource_snapshot.list_vio_bindings_for_service，本类不自造。
// 所有权——绑定是一次性的（service_binding_owned）：同一 snapshot 对+同一
//   service key 重复绑定幂等返回成功，任何改绑都被拒绝；映射队列由本类
//   持有拷贝，外部只能通过 list/query 接口读取。
class virtio_resource_client extends uvm_object;
    `uvm_object_utils(virtio_resource_client)

    protected virtio_qpair_mapping_t qpair_mappings[$];
    local dpu_device_snapshot   bound_device_snapshot;
    local dpu_resource_snapshot bound_resource_snapshot;
    local dpu_service_key_t     bound_service_key;
    local bit                   service_binding_owned;
    protected bit               runtime_ready;

    // 构造函数：初始化为未绑定、未就绪状态；不接受任何 snapshot 参数，
    // 绑定必须显式走 bind_to_service。
    function new(string name = "virtio_resource_client");
        super.new(name);
        bound_device_snapshot = null;
        bound_resource_snapshot = null;
        service_binding_owned = 0;
        runtime_ready = 0;
    endfunction

    // 把本 client 绑定到一个 service 的 qpair 资源视图。
    // 校验链：snapshot 对必须冻结且互相引用 → service 必须是 VIO_NET 且
    // 所有权自洽 → 至少存在一条 qpair 绑定 → 已绑定时只允许幂等重绑。
    // 成功后按 local_pair 升序保存映射（冒泡排序，规模小无性能问题），
    // 并把 runtime_ready 清零（需重新 mark）。失败通过 why 给出原因。
    // 注意：RX/TX 共享同一 global qpair id，方向仅由 local virtqueue id 区分。
    function bit bind_to_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        dpu_function_key_t owner;
        dpu_vio_qpair_binding_t bindings[$];
        virtio_qpair_mapping_t candidate_mappings[$];
        virtio_qpair_mapping_t mapping;
        virtio_qpair_mapping_t swap;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "virtio resource client requires an exact frozen snapshot pair";
            return 0;
        end
        if ((service_key.service_kind != DPU_SERVICE_VIO_NET) ||
            !device_snapshot.get_service_owner(service_key, owner, why) ||
            !dpu_same_function_key(owner, service_key.function_key)) begin
            if (why == "")
                why = "virtio resource client service ownership is invalid";
            return 0;
        end
        resource_snapshot.list_vio_bindings_for_service(service_key, bindings);
        if (bindings.size() == 0) begin
            why = "virtio resource client service has no qpair bindings";
            return 0;
        end
        if (service_binding_owned) begin
            if ((device_snapshot == bound_device_snapshot) &&
                (resource_snapshot == bound_resource_snapshot) &&
                (dpu_service_key_name(service_key) ==
                 dpu_service_key_name(bound_service_key))) begin
                return 1;
            end
            why = "virtio resource client snapshot binding cannot be reassigned";
            return 0;
        end
        foreach (bindings[index]) begin
            if (dpu_service_key_name(bindings[index].service_key) !=
                dpu_service_key_name(service_key)) begin
                why = "resource snapshot returned a binding for another service";
                return 0;
            end
            mapping.virtio_pair_index = bindings[index].virtio_pair_index;
            mapping.local_pair = bindings[index].local_pair_id;
            mapping.rx_virtqueue_id = bindings[index].rx_local_virtqueue_id;
            mapping.tx_virtqueue_id = bindings[index].tx_local_virtqueue_id;
            // The real DUT allocates one txrx queue resource per VIO pair.
            // VTX and VRX both consume that same global queue index; only
            // the local virtqueue IDs distinguish direction.
            mapping.rx_global_qid = bindings[index].global_qpair_id;
            mapping.tx_global_qid = bindings[index].global_qpair_id;
            candidate_mappings.push_back(mapping);
        end
        for (int left = 0; left < candidate_mappings.size(); left++) begin
            for (int right = left + 1;
                 right < candidate_mappings.size();
                 right++) begin
                if (candidate_mappings[right].local_pair <
                    candidate_mappings[left].local_pair) begin
                    swap = candidate_mappings[left];
                    candidate_mappings[left] = candidate_mappings[right];
                    candidate_mappings[right] = swap;
                end
            end
        end

        qpair_mappings = candidate_mappings;
        bound_device_snapshot = device_snapshot;
        bound_resource_snapshot = resource_snapshot;
        bound_service_key = service_key;
        service_binding_owned = 1;
        runtime_ready = 0;
        return 1;
    endfunction

    // 查询是否已完成 service 绑定（一次性所有权标志）。
    function bit is_bound_to_service();
        return service_binding_owned;
    endfunction

    // 返回已绑定的 qpair 映射条数（未绑定时为 0）。
    function int unsigned qpair_mapping_count();
        return qpair_mappings.size();
    endfunction

    // 导出全部 qpair 映射的拷贝（按 local_pair 升序）；调用方修改副本
    // 不影响本 client 内部状态。
    function void list_qpair_mappings(
        output virtio_qpair_mapping_t mappings[$]
    );
        mappings = qpair_mappings;
    endfunction

    // 取所绑定 device snapshot 的 DUT 能力快照；未绑定时返回 null，
    // 调用方需判空。
    function dpu_dut_caps snapshot_bound_dut_caps();
        if (!service_binding_owned)
            return null;
        return bound_device_snapshot.snapshot_dut_caps();
    endfunction

    // 声明运行时就绪（如 function 完成初始化后调用）。前置条件是已绑定
    // service，否则返回 0 并通过 why 说明。
    function bit mark_runtime_ready(output string why);
        if (!service_binding_owned) begin
            why = "virtio resource client has not been bound to a service";
            return 0;
        end
        runtime_ready = 1;
        why = "";
        return 1;
    endfunction

    // 清除运行时就绪标记（FLR/复位路径使用）；service 绑定与映射保留，
    // 未绑定时为空操作。
    function void reset_runtime_state();
        if (service_binding_owned)
            runtime_ready = 0;
    endfunction

    // 把 function 本地 virtqueue id 翻译为 DUT 全局 qpair id：
    // 依次匹配各映射的 RX/TX 本地 id，命中即输出对应 global id 并返回 1；
    // 未命中输出 0 并返回 0（调用方必须检查返回值，0 也是合法 qid）。
    function bit local_qid_to_global_qid(
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        foreach (qpair_mappings[index]) begin
            if (qpair_mappings[index].rx_virtqueue_id == local_qid) begin
                global_qid =
                    qpair_mappings[index].rx_global_qid;
                return 1;
            end
            if (qpair_mappings[index].tx_virtqueue_id == local_qid) begin
                global_qid =
                    qpair_mappings[index].tx_global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction
endclass : virtio_resource_client

`endif // VIRTIO_RESOURCE_CLIENT_SV
