`ifndef VIRTIO_WAIT_POLICY_SV
`define VIRTIO_WAIT_POLICY_SV

// ============================================================================
// virtio_wait_policy
//
// Unified timeout and polling object for the virtio_net VIP.
// 所属层次：src/shared；依赖 UVM，可选 AIP。test/config 持有策略数值，
// env 在 build 阶段复制后供所有 Function 共用；等待线程由调用者拥有。
// ALL waits in this VIP must go through this class -- no bare #delay allowed.
//
// Rules enforced throughout:
//   - All fork blocks are named:  fork : block_name ... join*
//   - Only "disable block_name" is used, NEVER "disable fork"
//   - poll_interval_ns is clamped to minimum 1 to prevent infinite loops
//   - max_poll_attempts caps iterations as a deadlock guard
//   - Effective timeout = base_ns * timeout_multiplier
//
// 中文说明：全 VIP 统一的等待/超时策略对象——任何等待都必须经它，禁止裸
// #delay。这样做的原因：(1) 超时可用 timeout_multiplier 一处全局放大（压力
// 测试）；(2) 双保险防挂死——墙钟超时 + max_poll_attempts 迭代上限（仿真
// 时间不推进时也能退出）；(3) 所有 fork 均命名并只 disable 具名块，避免
// "disable fork" 误杀调用方的并行线程。各 *_timeout_ns 字段是场景基准值，
// 实际生效值 = 基准 × multiplier（饱和乘法防溢出）。超时统一报 uvm_error，
// 调用方凭 ref 标志判断成功/超时。
// ============================================================================

class virtio_wait_policy extends uvm_object;
    `uvm_object_utils(virtio_wait_policy)

    // 等待一轮统一轮询间隔，不超过调用者的剩余预算；不足1ns的预算仍精确保留。
    // 不报告超时，由外层持有具体条件和整体截止时间，避免重复报错。
    extern task wait_poll_interval(realtime	remaining_ns);

    // ------------------------------------------------------------------
    // Timeout configuration (all values in nanoseconds)
    // ------------------------------------------------------------------
    int unsigned default_poll_interval_ns  = 10;
    int unsigned default_timeout_ns        = 10000;   // 10 us
    int unsigned flr_timeout_ns            = 10000;   // 10 us
    int unsigned reset_timeout_ns          = 5000;    // 5  us
    int unsigned queue_reset_timeout_ns    = 5000;    // 5  us
    int unsigned vf_ready_timeout_ns       = 10000;   // 10 us
    int unsigned cpl_timeout_ns            = 5000;    // 5  us
    int unsigned status_change_timeout_ns  = 5000;    // 5  us
    int unsigned rx_wait_timeout_ns        = 50000;   // 50 us

    // Global multiplier -- set >1 in stress tests to scale all timeouts
    int unsigned timeout_multiplier        = 1;

    // Absolute iteration cap -- prevents deadlock if time does not advance
    int unsigned max_poll_attempts         = 10000;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    // 构造函数：各超时字段用声明处默认值；测试可在 build 阶段直接改写字段。
    function new(string name = "virtio_wait_policy");
        super.new(name);
    endfunction

    // 参数归属：vio.wait.*；只开放有生产消费点的字段，所有时间单位为 ns。
    // 在 build 前读取一次；缺省保留当前值，先检查范围再提交，非法值立即 fatal。
    // AIP 未编译时为空操作；运行中的等待不会因 Tcl set_param 自动改变。
    function void	load_params(string	path = "vio.wait");
`ifdef AIP_CMDLINE_SV
        longint unsigned	poll_ns;
        longint unsigned	timeout_ns;
        longint unsigned	reset_ns;
        longint unsigned	queue_reset_ns;
        longint unsigned	vf_ready_ns;
        longint unsigned	flr_ns;
        longint unsigned	multiplier;
        longint unsigned	max_polls;

        `DPU_AIP_UINT(path, longint unsigned, poll_ns, default_poll_interval_ns);
        `DPU_AIP_UINT(path, longint unsigned, timeout_ns, default_timeout_ns);
        `DPU_AIP_UINT(path, longint unsigned, reset_ns, reset_timeout_ns);
        `DPU_AIP_UINT(path, longint unsigned, queue_reset_ns, queue_reset_timeout_ns);
        `DPU_AIP_UINT(path, longint unsigned, vf_ready_ns, vf_ready_timeout_ns);
        `DPU_AIP_UINT(path, longint unsigned, flr_ns, flr_timeout_ns);
        `DPU_AIP_UINT(path, longint unsigned, multiplier, timeout_multiplier);
        `DPU_AIP_UINT(path, longint unsigned, max_polls, max_poll_attempts);

        if ((poll_ns == 0) || (poll_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".poll_ns 必须为 1..2^32-1"})
            return;
        end
        if ((timeout_ns == 0) || (timeout_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".timeout_ns 必须为 1..2^32-1"})
            return;
        end
        if ((reset_ns == 0) || (reset_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".reset_ns 必须为 1..2^32-1"})
            return;
        end
        if ((queue_reset_ns == 0) || (queue_reset_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".queue_reset_ns 必须为 1..2^32-1"})
            return;
        end
        if ((vf_ready_ns == 0) || (vf_ready_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".vf_ready_ns 必须为 1..2^32-1"})
            return;
        end
        if ((flr_ns == 0) || (flr_ns > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".flr_ns 必须为 1..2^32-1"})
            return;
        end
        if ((multiplier == 0) || (multiplier > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".multiplier 必须为 1..2^32-1"})
            return;
        end
        if ((max_polls == 0) || (max_polls > 64'hffff_ffff)) begin
            `uvm_fatal("VIO_PARAM", {path, ".max_polls 必须为 1..2^32-1"})
            return;
        end
        default_poll_interval_ns = int'(poll_ns);
        default_timeout_ns = int'(timeout_ns);
        reset_timeout_ns = int'(reset_ns);
        queue_reset_timeout_ns = int'(queue_reset_ns);
        vf_ready_timeout_ns = int'(vf_ready_ns);
        flr_timeout_ns = int'(flr_ns);
        timeout_multiplier = int'(multiplier);
        max_poll_attempts = int'(max_polls);
`endif
    endfunction

    // 复制策略数值供每个 Host 独立持有，避免全局模板与实例共享可修改对象。
    // 不复制等待线程或事件；不兼容对象报告错误并保留当前字段。
    virtual function void	do_copy(uvm_object	rhs);
        virtio_wait_policy	typed_rhs;

        if (!$cast(typed_rhs, rhs)) begin
            `uvm_error("VIO_PARAM", "wait policy copy 类型不兼容")
            return;
        end
        super.do_copy(rhs);
        default_poll_interval_ns = typed_rhs.default_poll_interval_ns;
        default_timeout_ns = typed_rhs.default_timeout_ns;
        reset_timeout_ns = typed_rhs.reset_timeout_ns;
        queue_reset_timeout_ns = typed_rhs.queue_reset_timeout_ns;
        vf_ready_timeout_ns = typed_rhs.vf_ready_timeout_ns;
        flr_timeout_ns = typed_rhs.flr_timeout_ns;
        timeout_multiplier = typed_rhs.timeout_multiplier;
        max_poll_attempts = typed_rhs.max_poll_attempts;
        cpl_timeout_ns = typed_rhs.cpl_timeout_ns;
        status_change_timeout_ns = typed_rhs.status_change_timeout_ns;
        rx_wait_timeout_ns = typed_rhs.rx_wait_timeout_ns;
    endfunction

    // 返回基准超时乘以倍率，超过32位时饱和；程序化旧配置的0倍率按1处理。
    // 只计算数值、不推进时间；load_params 对显式输入则要求正倍率。
    function int unsigned effective_timeout(int unsigned base_ns);
        int unsigned mult;
        mult = (timeout_multiplier == 0) ? 1 : timeout_multiplier;
        // Saturating multiply: if result would overflow, return max value
        if (base_ns > (32'hFFFF_FFFF / mult))
            return 32'hFFFF_FFFF;
        return base_ns * mult;
    endfunction

    // ------------------------------------------------------------------
    // poll_until_flag
    //
    // Generic polling loop.  The caller is responsible for updating
    // success_flag inside whatever mechanism drives the condition (e.g.
    // a parallel thread reading a register).  This task wakes every
    // poll_interval_ns to check the flag.
    //
    // Parameters:
    //   description      -- human-readable label for log messages
    //   timeout_ns       -- base timeout before multiplier is applied
    //   poll_interval_ns -- interval between checks (clamped to >= 1)
    //   success_flag     -- ref bit; caller sets to 1 when done
    //   timed_out        -- ref bit; set to 1 here on timeout
    //
    // Dual protection:
    //   1. Wall-clock limit via effective_timeout
    //   2. max_poll_attempts iteration cap
    // ------------------------------------------------------------------
    task poll_until_flag(
        string       description,
        int unsigned timeout_ns,
        int unsigned poll_interval_ns,
        ref bit      success_flag,
        ref bit      timed_out
    );
        int unsigned eff_timeout;
        int unsigned interval;
        int unsigned attempts;
        realtime     start_time;

        eff_timeout = effective_timeout(timeout_ns);
        interval    = (poll_interval_ns < 1) ? 1 : poll_interval_ns;
        attempts    = 0;
        start_time  = $realtime;
        timed_out   = 0;

        while (!success_flag) begin
            realtime elapsed_ns;
            elapsed_ns = ($realtime - start_time) / 1ns;

            if (elapsed_ns >= eff_timeout) begin
                timed_out = 1;
                `uvm_error("WAIT_POLICY",
                    $sformatf("poll_until_flag TIMEOUT after %0t: %s (timeout=%0dns, attempts=%0d)",
                              $realtime, description, eff_timeout, attempts))
                return;
            end

            if (attempts >= max_poll_attempts) begin
                timed_out = 1;
                `uvm_error("WAIT_POLICY",
                    $sformatf("poll_until_flag MAX_ATTEMPTS (%0d) exceeded at %0t: %s",
                              max_poll_attempts, $realtime, description))
                return;
            end

            #(interval * 1ns);
            attempts++;
        end

        `uvm_info("WAIT_POLICY",
            $sformatf("poll_until_flag SUCCESS at %0t: %s (attempts=%0d)",
                      $realtime, description, attempts),
            UVM_HIGH)
    endtask

    // ------------------------------------------------------------------
    // wait_event_or_timeout
    //
    // Waits for a UVM event to be triggered or for a timeout to expire,
    // whichever comes first.  Uses a named fork block so that only this
    // specific fork can be disabled -- never "disable fork".
    //
    // Parameters:
    //   description -- human-readable label for log messages
    //   evt         -- UVM event to wait on
    //   timeout_ns  -- base timeout before multiplier is applied
    //   triggered   -- ref bit; 1 if event fired, 0 if timed out
    // ------------------------------------------------------------------
    task wait_event_or_timeout(
        string       description,
        uvm_event    evt,
        int unsigned timeout_ns,
        ref bit      triggered
    );
        int unsigned eff_timeout;
        bit          event_triggered;
        eff_timeout = effective_timeout(timeout_ns);
        event_triggered = 0;

        fork : wait_evt_blk
            begin : evt_arm
                evt.wait_trigger();
                event_triggered = 1;
            end
            begin : timeout_arm
                #(eff_timeout * 1ns);
            end
        join_any
        disable wait_evt_blk;
        triggered = event_triggered;

        if (!triggered) begin
            `uvm_error("WAIT_POLICY",
                $sformatf("wait_event_or_timeout TIMEOUT after %0dns at %0t: %s",
                          eff_timeout, $realtime, description))
        end else begin
            `uvm_info("WAIT_POLICY",
                $sformatf("wait_event_or_timeout SUCCESS at %0t: %s",
                          $realtime, description),
                UVM_HIGH)
        end
    endtask

    // ------------------------------------------------------------------
    // wait_event_or_poll
    //
    // Combines UVM event waiting with a polling fallback.  Useful when
    // an event might be missed (e.g. fired before this task starts) or
    // when the condition must be re-checked after wakeup.
    //
    // Each loop iteration waits up to poll_interval_ns for the event,
    // then checks whether the overall timeout has expired.  A named fork
    // block is used inside each iteration for the short event wait.
    //
    // Parameters:
    //   description      -- human-readable label for log messages
    //   evt              -- UVM event to wait on (may already be triggered)
    //   timeout_ns       -- base timeout before multiplier is applied
    //   poll_interval_ns -- max wait per iteration (clamped to >= 1)
    //   triggered        -- ref bit; set to 1 when event is observed
    // ------------------------------------------------------------------
    task wait_event_or_poll(
        string       description,
        uvm_event    evt,
        int unsigned timeout_ns,
        int unsigned poll_interval_ns,
        ref bit      triggered
    );
        int unsigned eff_timeout;
        int unsigned interval;
        int unsigned attempts;
        realtime     start_time;
        bit          local_hit;

        eff_timeout = effective_timeout(timeout_ns);
        interval    = (poll_interval_ns < 1) ? 1 : poll_interval_ns;
        attempts    = 0;
        start_time  = $realtime;
        triggered   = 0;

        // Check if event was already triggered before we entered
        if (evt.is_on()) begin
            triggered = 1;
            `uvm_info("WAIT_POLICY",
                $sformatf("wait_event_or_poll: event already on at %0t: %s",
                          $realtime, description),
                UVM_HIGH)
            return;
        end

        while (!triggered) begin
            realtime elapsed_ns;
            elapsed_ns = ($realtime - start_time) / 1ns;

            if (elapsed_ns >= eff_timeout) begin
                `uvm_error("WAIT_POLICY",
                    $sformatf("wait_event_or_poll TIMEOUT after %0dns at %0t: %s (attempts=%0d)",
                              eff_timeout, $realtime, description, attempts))
                return;
            end

            if (attempts >= max_poll_attempts) begin
                `uvm_error("WAIT_POLICY",
                    $sformatf("wait_event_or_poll MAX_ATTEMPTS (%0d) exceeded at %0t: %s",
                              max_poll_attempts, $realtime, description))
                return;
            end

            local_hit = 0;

            fork : poll_evt_iter_blk
                begin : poll_evt_arm
                    evt.wait_trigger();
                    local_hit = 1;
                end
                begin : poll_timeout_arm
                    #(interval * 1ns);
                end
            join_any
            disable poll_evt_iter_blk;

            attempts++;

            if (local_hit || evt.is_on()) begin
                triggered = 1;
                `uvm_info("WAIT_POLICY",
                    $sformatf("wait_event_or_poll SUCCESS at %0t: %s (attempts=%0d)",
                              $realtime, description, attempts),
                    UVM_HIGH)
            end
        end
    endtask

endclass

// 单次延时总为正且有上界；零/负预算直接返回，外层据此结束等待。
task virtio_wait_policy::wait_poll_interval(realtime	remaining_ns);
    realtime	interval_ns;

    if (remaining_ns <= 0) return;
    interval_ns = (default_poll_interval_ns == 0) ? 1 : default_poll_interval_ns;
    if (interval_ns > remaining_ns) interval_ns = remaining_ns;
    #(interval_ns * 1ns);
endtask

`endif // VIRTIO_WAIT_POLICY_SV
