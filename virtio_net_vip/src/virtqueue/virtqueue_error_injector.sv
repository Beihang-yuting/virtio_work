`ifndef VIRTQUEUE_ERROR_INJECTOR_SV
`define VIRTQUEUE_ERROR_INJECTOR_SV

// ============================================================================
// virtqueue_error_injector
//
// Controls error injection into virtqueue operations. Used by all virtqueue
// implementations (split, packed, custom) to inject faults at configurable
// points in the descriptor/ring operations.
//
// Features:
//   - Inject after N operations (countdown)
//   - Target a specific queue or any queue (target_queue_id = '1)
//   - Probabilistic injection (0-100%)
//   - Full injection history with timestamps
//
// Depends on: virtio_net_types.sv (virtqueue_error_e)
// ============================================================================

class virtqueue_error_injector extends uvm_object;
    `uvm_object_utils(virtqueue_error_injector)

    // ------------------------------------------------------------------
    // Injection control
    // ------------------------------------------------------------------
    bit                    inject_enable = 0;
    virtqueue_error_e      err_type;
    int unsigned           inject_after_n_ops = 0;   // inject after N-th operation
    int unsigned           target_queue_id = 0;      // target queue (use '1 for any)
    int unsigned           inject_probability = 100; // 0-100 percent

    // ------------------------------------------------------------------
    // Internal counter
    // ------------------------------------------------------------------
    protected int unsigned op_count = 0;

    // ------------------------------------------------------------------
    // History of injections
    // ------------------------------------------------------------------
    typedef struct {
        virtqueue_error_e err;
        int unsigned      queue_id;
        int unsigned      op_count;
        realtime          timestamp;
    } injection_record_t;

    protected injection_record_t history[$];

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtqueue_error_injector");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // configure -- Set up an error injection scenario
    //
    // Enables injection and stores all parameters. Resets the internal
    // operation counter so that inject_after_n_ops is relative to this
    // configure call.
    //
    // Parameters:
    //   err          -- The error type to inject
    //   after_n_ops  -- Number of operations to let pass before injecting
    //   queue_id     -- Target queue ID ('1 = any queue)
    //   probability  -- Injection probability 0-100%
    // ------------------------------------------------------------------
    function void configure(
        virtqueue_error_e  err,
        int unsigned       after_n_ops = 0,
        int unsigned       queue_id = 0,
        int unsigned       probability = 100
    );
        inject_enable       = 1;
        err_type            = err;
        inject_after_n_ops  = after_n_ops;
        target_queue_id     = queue_id;
        inject_probability  = (probability > 100) ? 100 : probability;
        op_count            = 0;

        `uvm_info("VQ_ERR_INJ",
            $sformatf("Configured: err=%s after_n_ops=%0d queue_id=%s probability=%0d%%",
                      err.name(), after_n_ops,
                      (queue_id == '1) ? "ANY" : $sformatf("%0d", queue_id),
                      inject_probability),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // disable_injection -- Turn off error injection
    // ------------------------------------------------------------------
    function void disable_injection();
        inject_enable = 0;
        `uvm_info("VQ_ERR_INJ", "Error injection disabled", UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // should_inject -- Check if an error should be injected now
    //
    // Called by virtqueue operations at injection points. Returns 1 if
    // the error should be injected for this operation, 0 otherwise.
    //
    // Decision logic:
    //   1. Return 0 if injection is not enabled
    //   2. Return 0 if target_queue_id doesn't match (unless '1 = any)
    //   3. Increment op_count; return 0 if op_count <= inject_after_n_ops
    //   4. If probability < 100, use $urandom_range to decide
    //   5. On inject: record in history, log, return 1
    // ------------------------------------------------------------------
    function bit should_inject(int unsigned current_queue_id);
        int unsigned rand_val;
        injection_record_t record;

        // 1. Check enable
        if (!inject_enable)
            return 0;

        // 2. Check queue match ('1 means any queue)
        if (target_queue_id != '1 && target_queue_id != current_queue_id)
            return 0;

        // 3. Increment and check countdown
        op_count++;
        if (op_count <= inject_after_n_ops)
            return 0;

        // 4. Probabilistic decision
        if (inject_probability < 100) begin
            rand_val = $urandom_range(0, 99);
            if (rand_val >= inject_probability)
                return 0;
        end

        // 5. Inject: record history and log
        record.err       = err_type;
        record.queue_id  = current_queue_id;
        record.op_count  = op_count;
        record.timestamp = $realtime;
        history.push_back(record);

        `uvm_info("VQ_ERR_INJ",
            $sformatf("INJECTING err=%s on queue=%0d op_count=%0d at %0t",
                      err_type.name(), current_queue_id, op_count, $realtime),
            UVM_MEDIUM)

        return 1;
    endfunction

    // ------------------------------------------------------------------
    // reset_counter -- Reset the operation counter without changing config
    // ------------------------------------------------------------------
    function void reset_counter();
        op_count = 0;
        `uvm_info("VQ_ERR_INJ", "Operation counter reset", UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // print_history -- Display all recorded injection events
    // ------------------------------------------------------------------
    function void print_history();
        if (history.size() == 0) begin
            `uvm_info("VQ_ERR_INJ", "No injections recorded", UVM_LOW)
            return;
        end

        `uvm_info("VQ_ERR_INJ",
            $sformatf("Injection history (%0d entries):", history.size()),
            UVM_LOW)

        foreach (history[i]) begin
            `uvm_info("VQ_ERR_INJ",
                $sformatf("  [%0d] err=%s queue=%0d op_count=%0d time=%0t",
                          i, history[i].err.name(), history[i].queue_id,
                          history[i].op_count, history[i].timestamp),
                UVM_LOW)
        end
    endfunction

endclass : virtqueue_error_injector

`endif // VIRTQUEUE_ERROR_INJECTOR_SV
