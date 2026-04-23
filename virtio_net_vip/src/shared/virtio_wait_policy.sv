`ifndef VIRTIO_WAIT_POLICY_SV
`define VIRTIO_WAIT_POLICY_SV

// ============================================================================
// virtio_wait_policy
//
// Unified timeout and polling object for the virtio_net VIP.
// ALL waits in this VIP must go through this class -- no bare #delay allowed.
//
// Rules enforced throughout:
//   - All fork blocks are named:  fork : block_name ... join*
//   - Only "disable block_name" is used, NEVER "disable fork"
//   - poll_interval_ns is clamped to minimum 1 to prevent infinite loops
//   - max_poll_attempts caps iterations as a deadlock guard
//   - Effective timeout = base_ns * timeout_multiplier
// ============================================================================

class virtio_wait_policy extends uvm_object;
    `uvm_object_utils(virtio_wait_policy)

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
    function new(string name = "virtio_wait_policy");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // effective_timeout
    //
    // Returns base_ns * timeout_multiplier, saturating at 32-bit max to
    // avoid overflow.  A multiplier of 0 is treated as 1 so that stress
    // tests cannot accidentally reduce timeouts to zero.
    // ------------------------------------------------------------------
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
        eff_timeout = effective_timeout(timeout_ns);
        triggered   = 0;

        fork : wait_evt_blk
            begin : evt_arm
                evt.wait_trigger();
                triggered = 1;
            end
            begin : timeout_arm
                #(eff_timeout * 1ns);
            end
        join_any
        disable wait_evt_blk;

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

`endif // VIRTIO_WAIT_POLICY_SV
