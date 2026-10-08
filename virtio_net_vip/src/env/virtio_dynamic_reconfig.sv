`ifndef VIRTIO_DYNAMIC_RECONFIG_SV
`define VIRTIO_DYNAMIC_RECONFIG_SV

// ============================================================================
// 目录层次：src/env；面向 virtio-net VF 的运行期重配置协调器。
//
// 职责：校验冻结 DUT/placement 给出的队列上限、调用方声明的旧队列数和数据面状态，
// 再把 MQ 变更委托给该 VF 唯一的 virtio_auto_fsm。FSM 是 control VQ、队列资源和
// worker 启停的唯一编排者；本对象只在 FSM 确认目标队列数生效后更新 VF 配置镜像，
// 避免环境配置与实际队列拓扑分叉。
//
// 所有权与生命周期：本对象借用 VF、driver agent 和 FSM，不拥有队列/DMA；冻结的
// device snapshot 一次性绑定且不可改绑。设备拒绝或 FSM 进入恢复状态时，配置镜像
// 保持原值，后续恢复由 Function 生命周期处理。
// ============================================================================

class virtio_dynamic_reconfig extends uvm_report_object;
    `uvm_object_utils(virtio_dynamic_reconfig)

    protected dpu_dut_caps dut_caps;
    local dpu_device_snapshot bound_device_snapshot;
    local int unsigned     enforced_max_vio_net_qpairs_per_device;
    local bit              dut_caps_bound;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_dynamic_reconfig");
        super.new(name);
        dut_caps = null;
        bound_device_snapshot = null;
        enforced_max_vio_net_qpairs_per_device =
            DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        dut_caps_bound = 0;
    endfunction

    // 把动态重配组件绑定到冻结 device snapshot：校验 snapshot 非空、已冻结、
    // DUT 能力存在且自检通过后，缓存能力对象并把 MQ 上限收紧为快照声明值。
    // 一次性所有权：重复绑定同一 snapshot 幂等成功，改绑/清绑均被拒绝
    //（why 说明原因），保证运行期上限不随外部输入漂移。
    function bit bind_device_snapshot(
        input dpu_device_snapshot snapshot,
        output string why
    );
        dpu_dut_caps snapshot_caps;
        string caps_why;

        if (dut_caps_bound) begin
            if (snapshot == null) begin
                why = "dynamic reconfig device snapshot ownership cannot be cleared";
                return 0;
            end
            if (snapshot == bound_device_snapshot) begin
                why = "";
                return 1;
            end
            why = "dynamic reconfig device snapshot ownership cannot be reassigned";
            return 0;
        end
        if (snapshot == null) begin
            why = "dynamic reconfig device snapshot is null";
            return 0;
        end
        if (!snapshot.is_frozen()) begin
            why = "dynamic reconfig device snapshot is not frozen";
            return 0;
        end
        snapshot_caps = snapshot.snapshot_dut_caps();
        if (snapshot_caps == null) begin
            why = "dynamic reconfig device snapshot has no DUT capabilities";
            return 0;
        end
        if (!snapshot_caps.validate(caps_why)) begin
            why = $sformatf("invalid device snapshot DUT capabilities: %s",
                            caps_why);
            return 0;
        end

        dut_caps = snapshot_caps;
        enforced_max_vio_net_qpairs_per_device =
            snapshot_caps.max_vio_net_qpairs_per_device;
        bound_device_snapshot = snapshot;
        dut_caps_bound = 1;
        why = "";
        return 1;
    endfunction

    // 查询设备级 MQ 队列对上限（绑定 snapshot 前为模型缺省上限）。
    function int unsigned max_supported_qpairs();
        return enforced_max_vio_net_qpairs_per_device;
    endfunction

    // Placement is the resource authority for a concrete function.  The
    // device capability is only a ceiling; a function may be assigned fewer
    // pairs by the frozen resource snapshot.  Keep the null-VF form for
    // standalone callers that only have a device-level capability.
    function int unsigned max_supported_qpairs_for_vf(
        input virtio_vf_instance vf = null
    );
        int unsigned allocated_qpairs;

        if ((vf == null) || (vf.resource_client == null) ||
            !vf.resource_client.is_bound_to_service())
            return enforced_max_vio_net_qpairs_per_device;
        allocated_qpairs = vf.resource_client.qpair_mapping_count();
        if ((allocated_qpairs == 0) ||
            (allocated_qpairs >= enforced_max_vio_net_qpairs_per_device))
            return enforced_max_vio_net_qpairs_per_device;
        return allocated_qpairs;
    endfunction

    // 判定目标队列对数是否合法：非零且不超过该 VF 的有效上限
    //（vf==null 时退化为设备级上限）。
    function bit qpair_count_supported(
        input int unsigned count,
        input virtio_vf_instance vf = null
    );
        return (count != 0) &&
               (count <= max_supported_qpairs_for_vf(vf));
    endfunction

    // 请求 VF 改变活动队列对数。old_pairs 是调用方观察值，new_pairs 是目标值，
    // traffic_active=1 表示调用方要求验证真正的运行态路径。外层只做与具体 VF 资源
    // 上限有关且不可被派生类绕过的校验；失败无设备或配置副作用。
    task live_mq_resize(
        virtio_vf_instance vf,
        int unsigned old_pairs,
        int unsigned new_pairs,
        bit traffic_active
    );
        int unsigned max_pairs;

        max_pairs = max_supported_qpairs_for_vf(vf);
        if ($isunknown(new_pairs) || (new_pairs == 0)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                "live_mq_resize: %0d pairs is outside supported range 1..%0d",
                new_pairs,
                max_pairs))
            return;
        end
        if (!qpair_count_supported(new_pairs, vf)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                "live_mq_resize: %0d pairs exceeds device limit %0d",
                new_pairs, max_pairs))
            return;
        end
        do_live_mq_resize(vf, old_pairs, new_pairs, traffic_active);
    endtask

    // live_mq_resize 的实现体（目标值已通过上限校验）：先校验 VF/FSM 接线、FSM 的
    // 实际活动对数与 old_pairs 一致，以及 traffic_active 请求确实从 RUNNING 进入。
    // 随后统一调用 FSM.configure_mq；FSM 负责同值 no-op、control 命令、建拆队和
    // worker 停启。本 task 只在 accessor 确认 new_pairs 已生效、且运行态请求已经
    // 恢复 RUNNING 后更新 vf.drv_cfg。任一失败均保留原配置镜像。
    protected virtual task do_live_mq_resize(
        virtio_vf_instance vf,
        int unsigned old_pairs,
        int unsigned new_pairs,
        bit traffic_active
    );
        virtio_auto_fsm fsm;
        fsm_state_e     entry_state;
        int unsigned    observed_pairs;

        if (vf == null) begin
            `uvm_error("DYN_RECONFIG", "live_mq_resize: VF is null")
            return;
        end
        if ((vf.driver_agent == null) || (vf.driver_agent.fsm == null) ||
            (vf.driver_agent.fsm.ops == null)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                "live_mq_resize: VF%0d FSM/ops not available", vf.vf_index))
            return;
        end

        fsm = vf.driver_agent.fsm;
        entry_state = fsm.state;
        observed_pairs = fsm.active_queue_pair_count();

        `uvm_info("DYN_RECONFIG",
            $sformatf("live_mq_resize: VF%0d, %0d -> %0d pairs, traffic_active=%0b",
                      vf.vf_index, old_pairs, new_pairs, traffic_active),
            UVM_LOW)

        if (observed_pairs != old_pairs) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                {"live_mq_resize: VF%0d old_pairs=%0d does not match ",
                 "FSM active pairs=%0d"},
                vf.vf_index, old_pairs, observed_pairs))
            return;
        end
        if ((entry_state != FSM_READY) && (entry_state != FSM_RUNNING)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                {"live_mq_resize: VF%0d requires FSM_READY or FSM_RUNNING, ",
                 "got %s"},
                vf.vf_index, entry_state.name()))
            return;
        end
        if (traffic_active && (entry_state != FSM_RUNNING)) begin
            `uvm_error("DYN_RECONFIG",
                $sformatf({"live_mq_resize: VF%0d traffic_active requires ",
                           "FSM_RUNNING, got %s"},
                          vf.vf_index, entry_state.name()))
            return;
        end

        fsm.configure_mq(new_pairs);

        if (fsm.active_queue_pair_count() != new_pairs) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                {"live_mq_resize: VF%0d MQ resize to %0d pairs did not ",
                 "complete; active pairs=%0d state=%s"},
                vf.vf_index, new_pairs, fsm.active_queue_pair_count(),
                fsm.state.name()))
            return;
        end
        if (traffic_active && (fsm.state != FSM_RUNNING)) begin
            `uvm_error("DYN_RECONFIG", $sformatf(
                {"live_mq_resize: VF%0d resized to %0d pairs but dataplane ",
                 "did not resume; state=%s"},
                vf.vf_index, new_pairs, fsm.state.name()))
            return;
        end

        vf.drv_cfg.num_queue_pairs = new_pairs;
        `uvm_info("DYN_RECONFIG",
            $sformatf("live_mq_resize: VF%0d MQ resize to %0d pairs completed",
                      vf.vf_index, new_pairs), UVM_MEDIUM)
    endtask

endclass : virtio_dynamic_reconfig

`endif // VIRTIO_DYNAMIC_RECONFIG_SV
