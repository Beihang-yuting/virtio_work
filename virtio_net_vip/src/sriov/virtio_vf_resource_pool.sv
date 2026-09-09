`ifndef VIRTIO_VF_RESOURCE_POOL_SV
`define VIRTIO_VF_RESOURCE_POOL_SV

// Read-only service-keyed naming and lookup view over frozen qpair bindings.
// Control/Admin-VQ identity is intentionally outside this snapshot view.
// 中文文件头：
// 职责——维护整台设备的"service+local_qid ↔ global_qid ↔ 队列名"三向映射表
//   （每条 qpair 绑定展开为 RX/TX 两条方向性条目），供 PF manager 做
//   local/global 队列号互译与命名；Control/Admin VQ 刻意不在此视图内。
// 依赖——映射只能从冻结的 dpu_resource_snapshot 导入
//   （list_vio_bindings_for_service），本类不自造队列号。
// 所有权——首次导入即钉住 resource snapshot，不允许换绑其他 snapshot；
//   同一 service 的完全相同重导入幂等成功，任何差异导入在改动池前被拒绝。
typedef struct {
    dpu_service_key_t service_key;
    int unsigned      virtio_pair_index;
    int unsigned      local_pair_id;
    int unsigned      local_qid;
    int unsigned      global_qid;
    string            queue_name;
} virtio_local_queue_mapping_t;

class virtio_vf_resource_pool extends uvm_object;
    `uvm_object_utils(virtio_vf_resource_pool)

    protected virtio_local_queue_mapping_t queue_map[$];
    protected dpu_resource_snapshot bound_resource_snapshot;

    // 构造函数：初始为空映射、未钉住任何 snapshot。
    function new(string name = "virtio_vf_resource_pool");
        super.new(name);
        bound_resource_snapshot = null;
    endfunction

    // 比较两个 service key 是否同一 service（用规范名比较，避免结构体
    // 逐字段比较遗漏编码差异）。
    protected function bit same_service(
        input dpu_service_key_t lhs,
        input dpu_service_key_t rhs
    );
        return dpu_service_key_name(lhs) == dpu_service_key_name(rhs);
    endfunction

    // One real-DUT global qid identifies an RX/TX pair.  The two directional
    // entries are therefore allowed to share a global qid only when they
    // belong to the same service and the same local pair.
    // 中文：判定两条映射是否是同一队列对的 RX/TX 两个方向——同 service、
    // 同 pair 索引、local_qid 不同且仅末位相异（偶=RX、奇=TX 的配对约定）。
    protected function bit same_pair_directions(
        input virtio_local_queue_mapping_t lhs,
        input virtio_local_queue_mapping_t rhs
    );
        return same_service(lhs.service_key, rhs.service_key) &&
               (lhs.virtio_pair_index == rhs.virtio_pair_index) &&
               (lhs.local_pair_id == rhs.local_pair_id) &&
               (lhs.local_qid != rhs.local_qid) &&
               ((lhs.local_qid ^ rhs.local_qid) == 1);
    endfunction

    // 把一个 service 的 qpair 绑定导入映射池。流程：
    //   1) snapshot 必须冻结，且与已钉住的 snapshot 一致（不允许换绑）；
    //   2) 每条绑定展开为 receiveq/transmitq 两条命名条目（共享 global qid，
    //      方向由 local_qid 区分）；
    //   3) 若该 service 已有映射：逐条比对，完全一致则幂等返回 1，
    //      任何差异在改池前拒绝；
    //   4) 新导入需通过自洽+与现有池的冲突检查（global qid 只允许同对
    //      RX/TX 复用、service/local_qid 唯一、队列名唯一）后才整体入池。
    // 失败时池不被改动，why 给出原因。
    function bit import_service_bindings(
        input dpu_service_key_t service_key,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_vio_qpair_binding_t bindings[$];
        virtio_local_queue_mapping_t imported[$];
        virtio_local_queue_mapping_t mapping;
        int unsigned existing_count;

        why = "";
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "queue view requires a frozen resource snapshot";
            return 0;
        end
        if ((bound_resource_snapshot != null) &&
            (bound_resource_snapshot != resource_snapshot)) begin
            why = "queue view cannot be rebound to a different resource snapshot";
            return 0;
        end
        resource_snapshot.list_vio_bindings_for_service(service_key, bindings);
        if (bindings.size() == 0) begin
            why = "queue view service has no qpair bindings";
            return 0;
        end
        foreach (bindings[index]) begin
            if (dpu_service_key_name(bindings[index].service_key) !=
                dpu_service_key_name(service_key)) begin
                why = "queue view received a binding for another service";
                return 0;
            end
            mapping.service_key = service_key;
            mapping.virtio_pair_index = bindings[index].virtio_pair_index;
            mapping.local_pair_id = bindings[index].local_pair_id;
            mapping.local_qid = bindings[index].rx_local_virtqueue_id;
            // A tx/rx pair is one hardware queue resource.  The driver uses
            // the same global queue index for VTX and VRX; local_qid remains
            // directional (even=RX, odd=TX).
            mapping.global_qid = bindings[index].global_qpair_id;
            mapping.queue_name = $sformatf("%s_receiveq_%0d",
                dpu_service_key_name(service_key),
                bindings[index].local_pair_id);
            imported.push_back(mapping);
            mapping.local_qid = bindings[index].tx_local_virtqueue_id;
            mapping.global_qid = bindings[index].global_qpair_id;
            mapping.queue_name = $sformatf("%s_transmitq_%0d",
                dpu_service_key_name(service_key),
                bindings[index].local_pair_id);
            imported.push_back(mapping);
        end

        // An exact reimport from the pinned snapshot is idempotent. Any
        // differing mapping for an existing service is rejected before the
        // pool is mutated.
        existing_count = 0;
        foreach (queue_map[index]) begin
            if (!same_service(queue_map[index].service_key, service_key))
                continue;
            if ((existing_count >= imported.size()) ||
                (queue_map[index].local_qid != imported[existing_count].local_qid) ||
                (queue_map[index].global_qid != imported[existing_count].global_qid) ||
                (queue_map[index].queue_name != imported[existing_count].queue_name)) begin
                why = "queue view service mapping cannot be reassigned";
                return 0;
            end
            existing_count++;
        end
        if (existing_count != 0) begin
            if (existing_count != imported.size()) begin
                why = "queue view service mapping cannot be reassigned";
                return 0;
            end
            return 1;
        end

        // Validate the complete candidate against itself and the existing
        // pool before committing any queue. A global qid may occur twice in
        // one service only for the RX/TX entries of one local pair; it must
        // remain unique across services and local pairs.
        foreach (imported[left]) begin
            for (int right = left + 1; right < imported.size(); right++) begin
                if ((imported[left].global_qid == imported[right].global_qid) &&
                    !same_pair_directions(imported[left], imported[right])) begin
                    why = "queue view has an ambiguous global reverse mapping";
                    return 0;
                end
                if (same_service(imported[left].service_key,
                                 imported[right].service_key) &&
                    (imported[left].local_qid == imported[right].local_qid)) begin
                    why = "queue view has a duplicate service/local mapping";
                    return 0;
                end
                if (imported[left].queue_name == imported[right].queue_name) begin
                    why = "queue view has a duplicate queue name";
                    return 0;
                end
            end
            foreach (queue_map[existing_index]) begin
                if (imported[left].global_qid ==
                    queue_map[existing_index].global_qid) begin
                    why = "queue view global qid makes reverse lookup ambiguous";
                    return 0;
                end
                if (same_service(imported[left].service_key,
                                 queue_map[existing_index].service_key) &&
                    (imported[left].local_qid ==
                     queue_map[existing_index].local_qid)) begin
                    why = "queue view has a duplicate service/local mapping";
                    return 0;
                end
                if (imported[left].queue_name ==
                    queue_map[existing_index].queue_name) begin
                    why = "queue view has a duplicate queue name";
                    return 0;
                end
            end
        end
        foreach (imported[index])
            queue_map.push_back(imported[index]);
        if (bound_resource_snapshot == null)
            bound_resource_snapshot = resource_snapshot;
        return 1;
    endfunction

    // 正向查询：service + 本地 virtqueue id → 全局 qid。
    // 未命中输出 0 并返回 0（0 也是合法 qid，必须检查返回值）。
    function bit local_to_global_for_service(
        input dpu_service_key_t service_key,
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        foreach (queue_map[index]) begin
            if (same_service(queue_map[index].service_key, service_key) &&
                (queue_map[index].local_qid == local_qid)) begin
                global_qid = queue_map[index].global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction

    // 反向查询：全局 qid → 归属 service 与本地 virtqueue id。
    // global qid 标识一个队列对，故命中时返回该对的 RX 条目（需要 TX 的
    // 调用方应查配对条目而非自行算术推导）；未命中时输出确定的默认
    // service key（host0/PF0/VIO_NET/instance0）与 local_qid=0 并返回 0。
    function bit global_to_service_local(
        input int unsigned global_qid,
        output dpu_service_key_t service_key,
        output int unsigned local_qid
    );
        foreach (queue_map[index]) begin
            if (queue_map[index].global_qid == global_qid) begin
                service_key = queue_map[index].service_key;
                // A global qid identifies a pair, so reverse lookup exposes
                // the resolved RX virtqueue ID.  Callers that need TX can
                // query the paired entry instead of deriving it arithmetically.
                local_qid = queue_map[index].local_qid;
                return 1;
            end
        end
        service_key.function_key.host_id = 0;
        service_key.function_key.pf_id = 0;
        service_key.function_key.kind = DPU_FUNCTION_PF;
        service_key.function_key.vf_id = 0;
        service_key.service_kind = DPU_SERVICE_VIO_NET;
        service_key.service_instance_id = 0;
        local_qid = '0;
        return 0;
    endfunction

    // 查询 service + 本地 virtqueue id 对应的队列名（如 xxx_receiveq_0）；
    // 未命中返回空串。
    function string get_queue_name(
        input dpu_service_key_t service_key,
        input int unsigned local_qid
    );
        foreach (queue_map[index]) begin
            if (same_service(queue_map[index].service_key, service_key) &&
                (queue_map[index].local_qid == local_qid))
                return queue_map[index].queue_name;
        end
        return "";
    endfunction

    // 返回池中方向性队列条目总数（每个 qpair 计 RX/TX 两条）。
    function int unsigned get_total_queues();
        return queue_map.size();
    endfunction

    // 调试辅助：以 UVM_LOW 打印完整映射表（service/local/global/队列名）。
    function void print_map();
        foreach (queue_map[index]) begin
            `uvm_info("VF_RES_POOL", $sformatf(
                "service=%s local_qid=%0d global_qid=%0d %s",
                dpu_service_key_name(queue_map[index].service_key),
                queue_map[index].local_qid, queue_map[index].global_qid,
                queue_map[index].queue_name), UVM_LOW)
        end
    endfunction
endclass : virtio_vf_resource_pool

`endif // VIRTIO_VF_RESOURCE_POOL_SV
