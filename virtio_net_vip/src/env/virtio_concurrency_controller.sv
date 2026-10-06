`ifndef VIRTIO_CONCURRENCY_CONTROLLER_SV
`define VIRTIO_CONCURRENCY_CONTROLLER_SV

// ============================================================================
// virtio_concurrency_controller
//
// Orchestrates multi-VF parallel operations for concurrency verification
// scenarios.
//
// Provides:
//   - parallel_vf_op: Execute an operation on multiple VFs concurrently
//     with per-VF timeout using named fork blocks
//   - parallel_traffic: Generate traffic on multiple VFs concurrently
//
// All fork blocks use named labels and "disable <label>" (never bare
// "disable fork"). Timeouts use wait_pol for consistent policy.
//
// Depends on:
//   - virtio_vf_instance (per-VF driver wrapper)
//   - virtio_wait_policy (timeout/polling)
//   - virtio_net_types.sv (virtio_txn_type_e)
//
// 中文说明（职责与所有权）：本类是 env 级共享组件（uvm_object，由
// virtio_net_env 创建并注入 vf_instances/wait_pol 引用，不拥有 VF 的
// 生命周期）。parallel_vf_op 直接驱动 VF 的 init/shutdown/reset；
// parallel_traffic 本身不产生报文——发包动作经 traffic_worker 钩子
// 委托给调用方（见 virtio_traffic_worker_base），actual_sent 只统计
// 钩子真实确认成功的包数，未绑定钩子时诚实返回 0 并告警，绝不以
// 目标包数冒充实际发送量。
// ============================================================================

// ----------------------------------------------------------------------------
// virtio_traffic_worker_base — parallel_traffic 的发包委托钩子。
//
// 为什么需要这一层：并发控制器只负责"多 VF 并行 + 超时 + 汇总"这个
// 框架，具体一包怎么发（走 dataplane、atomic_ops 还是测试桩）属于
// 调用方的策略。调用方派生本类实现 send_one() 并绑到
// controller.traffic_worker；send_one 返回 ok=1 才计入 actual_sent。
// 基类默认 ok=0（不发包），保证未实现的派生类不会虚报计数。
// ----------------------------------------------------------------------------
class virtio_traffic_worker_base extends uvm_object;
    `uvm_object_utils(virtio_traffic_worker_base)

    function new(string name = "virtio_traffic_worker_base");
        super.new(name);
    endfunction

    // 发送一个报文。vf_id 为目标 VF 序号，seq_no 为该 VF 内的包序号；
    // ok=1 表示报文确实提交成功（计入统计），ok=0 表示失败（该 VF
    // 停止继续发送）。副作用由派生类定义。
    virtual task send_one(int unsigned vf_id, int unsigned seq_no,
                          output bit ok);
        ok = 1'b0;
    endtask
endclass

class virtio_concurrency_controller extends uvm_object;
    `uvm_object_utils(virtio_concurrency_controller)

    // ===== VF instances (references, set by env) =====
    virtio_vf_instance vf_instances[];

    // ===== Wait policy =====
    virtio_wait_policy wait_pol;

    // ===== 发包委托钩子（可选，由调用方绑定；见类头说明）=====
    virtio_traffic_worker_base traffic_worker;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_concurrency_controller");
        super.new(name);
    endfunction

    // ========================================================================
    // parallel_vf_op
    //
    // Execute an operation on multiple VFs concurrently. Each VF operation
    // runs in a named fork block with a per-VF timeout.
    //
    // Parameters:
    //   vf_ids      -- list of VF indices to operate on
    //   op          -- transaction type to execute
    //   timeout_ns  -- per-VF timeout in nanoseconds
    //   results     -- output: per-VF success/failure flags
    // ========================================================================

    virtual task parallel_vf_op(
        int unsigned vf_ids[$],
        virtio_txn_type_e op,
        int unsigned timeout_ns,
        ref bit results[]
    );
        int unsigned num_vfs = vf_ids.size();
        bit worker_results[];
        worker_results = new[num_vfs];

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_vf_op: op=%s, num_vfs=%0d, timeout=%0dns",
                      op.name(), num_vfs, timeout_ns),
            UVM_MEDIUM)

        fork : parallel_vf_op_wait
            begin : completion_arm
                foreach (vf_ids[i]) begin
                    automatic int unsigned idx = i;
                    automatic int unsigned vf_id = vf_ids[i];

                    fork : parallel_vf_op_block
                        begin
                            if (vf_id < vf_instances.size() && vf_instances[vf_id] != null) begin
                                case (op)
                                    VIO_TXN_INIT: begin
                                        vf_instances[vf_id].init(vf_instances[vf_id].drv_cfg);
                                        worker_results[idx] = 1;
                                    end
                                    VIO_TXN_SHUTDOWN: begin
                                        vf_instances[vf_id].shutdown();
                                        worker_results[idx] = 1;
                                    end
                                    VIO_TXN_RESET: begin
                                        if (vf_instances[vf_id].driver_agent.ops != null) begin
                                            vf_instances[vf_id].driver_agent.ops.device_reset();
                                            worker_results[idx] = 1;
                                        end
                                    end
                                    default: begin
                                        `uvm_warning("CONC_CTRL",
                                            $sformatf("parallel_vf_op: unsupported op=%s for VF%0d",
                                                      op.name(), vf_id))
                                        worker_results[idx] = 0;
                                    end
                                endcase
                            end else begin
                                `uvm_warning("CONC_CTRL",
                                    $sformatf("parallel_vf_op: VF%0d not available", vf_id))
                                worker_results[idx] = 0;
                            end
                        end
                    join_none
                end
                wait fork;
            end : completion_arm
            begin : timeout_arm
                #(timeout_ns * 1ns);
                `uvm_warning("CONC_CTRL",
                    $sformatf("parallel_vf_op: timeout after %0dns", timeout_ns))
            end : timeout_arm
        join_any
        disable parallel_vf_op_wait;
        results = worker_results;

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_vf_op: complete, op=%s", op.name()),
            UVM_MEDIUM)
    endtask

    // ========================================================================
    // parallel_traffic
    //
    // 并发流量框架：对每个 VF 起一个命名 fork worker，逐包调用
    // traffic_worker.send_one() 委托发包，带整体超时。
    //
    // 输入：vf_ids（VF 序号列表）、pkts_per_vf（每 VF 目标包数）。
    // 输出：actual_sent[i] = 该 VF 经钩子确认成功的包数（真实计数，
    //       不是目标值）。失败/超时/未绑定钩子时对应项可小于目标，
    //       未绑定钩子恒为 0 并每 VF 告警一次。
    // 边界：vf_id 越界或实例为空时该 worker 计 0 并告警；整体超时到
    //       达时未完成的 worker 被 disable，已计入的包数保留。
    // ========================================================================

    virtual task parallel_traffic(
        int unsigned vf_ids[$],
        int unsigned pkts_per_vf,
        ref int unsigned actual_sent[]
    );
        int unsigned num_vfs = vf_ids.size();
        int unsigned timeout_ns;
        int unsigned worker_actual_sent[];
        worker_actual_sent = new[num_vfs];

        if (wait_pol != null)
            timeout_ns = wait_pol.effective_timeout(wait_pol.default_timeout_ns) * pkts_per_vf;
        else
            timeout_ns = 50000 * pkts_per_vf;

        `uvm_info("CONC_CTRL",
            $sformatf("parallel_traffic: %0d VFs, %0d pkts each", num_vfs, pkts_per_vf),
            UVM_LOW)

        fork : parallel_traffic_wait
            begin : completion_arm
                foreach (vf_ids[i]) begin
                    automatic int unsigned idx = i;
                    automatic int unsigned vf_id = vf_ids[i];
                    automatic int unsigned target_pkts = pkts_per_vf;

                    fork : parallel_traffic_block
                        begin
                            worker_actual_sent[idx] = 0;

                            if (vf_id < vf_instances.size() && vf_instances[vf_id] != null) begin
                                `uvm_info("CONC_CTRL",
                                    $sformatf("parallel_traffic: VF%0d starting %0d pkts",
                                              vf_id, target_pkts),
                                    UVM_HIGH)
                                if (traffic_worker == null) begin
                                    // 诚实语义：没有绑定发包钩子就没有报文
                                    // 被发送，计数保持 0，绝不以目标值冒充。
                                    `uvm_warning("CONC_CTRL",
                                        $sformatf({"parallel_traffic: no traffic_worker",
                                                   " bound, VF%0d sends nothing"}, vf_id))
                                end
                                else begin
                                    for (int unsigned p = 0; p < target_pkts; p++) begin
                                        bit send_ok;
                                        traffic_worker.send_one(vf_id, p, send_ok);
                                        if (!send_ok) begin
                                            `uvm_warning("CONC_CTRL",
                                                $sformatf({"parallel_traffic: VF%0d",
                                                           " send %0d failed, stop"},
                                                          vf_id, p))
                                            break;
                                        end
                                        worker_actual_sent[idx]++;
                                    end
                                end
                            end
                        end
                    join_none
                end
                wait fork;
            end : completion_arm
            begin : timeout_arm
                #(timeout_ns * 1ns);
                `uvm_warning("CONC_CTRL",
                    $sformatf("parallel_traffic: timeout after %0dns", timeout_ns))
            end : timeout_arm
        join_any
        disable parallel_traffic_wait;
        actual_sent = worker_actual_sent;

        `uvm_info("CONC_CTRL", "parallel_traffic: complete", UVM_LOW)
    endtask

endclass : virtio_concurrency_controller

`endif // VIRTIO_CONCURRENCY_CONTROLLER_SV
