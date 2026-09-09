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
    // 默认在通知前触发，保持旧 configure(err) 调用的单次语义。
    virtqueue_error_phase_e inject_phase = VQ_FAULT_PRE_NOTIFY;
    int unsigned           inject_after_n_ops = 0;   // inject after N-th operation
    int unsigned           target_queue_id = 0;      // target queue (use '1 for any)
    int unsigned           inject_probability = 100; // 0-100 percent

    // ------------------------------------------------------------------
    // Internal counter
    // ------------------------------------------------------------------
    protected int unsigned op_count = 0;

    // VQ_FAULT_ANY may be observed at two boundaries of one operation (for
    // example PRE_NOTIFY and POST_NOTIFY).  Keep a small operation window so
    // the same configured fault is consumed at most once in that window while
    // preserving the normal repeated-injection behavior across operations.
    // 中文说明：同一次 kick/设备完成可能经过两个阶段；ANY 只消费一次，下一次
    // 操作重新按 countdown/probability 判定，避免把同一故障重复写入描述符。
    protected bit          any_operation_active = 0;
    protected bit          any_operation_counted = 0;
    protected bit          any_operation_consumed = 0;
    protected int unsigned any_operation_queue = '1;

    // ------------------------------------------------------------------
    // History of injections
    // ------------------------------------------------------------------
    typedef struct {
        virtqueue_error_e err;
        virtqueue_error_phase_e phase;
        int unsigned      queue_id;
        int unsigned      op_count;
        realtime          timestamp;
    } injection_record_t;

    protected injection_record_t history[$];

    // A separate history is kept for byte-level mutations.  A semantic error
    // request (virtqueue_error_e) and the actual descriptor field changed are
    // different facts, so conflating them would make coverage claim an
    // injection that never reached Host memory.
    typedef struct {
        int unsigned                     queue_id;
        virtqueue_type_e                 ring_type;
        int unsigned                     descriptor_index;
        virtio_desc_corruption_field_e   field;
        bit [63:0]                        value;
        realtime                          timestamp;
    } descriptor_corruption_record_t;
    protected descriptor_corruption_record_t corruption_history[$];

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
    //   fault_phase  -- Queue/responder boundary at which to consume it
    // ------------------------------------------------------------------
    function void configure(
        virtqueue_error_e  err,
        int unsigned       after_n_ops = 0,
        int unsigned       queue_id = 0,
        int unsigned       probability = 100,
        virtqueue_error_phase_e fault_phase = VQ_FAULT_PRE_NOTIFY
    );
        inject_enable       = 1;
        err_type            = err;
        inject_phase        = fault_phase;
        inject_after_n_ops  = after_n_ops;
        target_queue_id     = queue_id;
        inject_probability  = (probability > 100) ? 100 : probability;
        op_count            = 0;
        any_operation_active = 0;
        any_operation_counted = 0;
        any_operation_consumed = 0;
        any_operation_queue = '1;

        `uvm_info("VQ_ERR_INJ",
            $sformatf("Configured: err=%s phase=%s after_n_ops=%0d queue_id=%s probability=%0d%%",
                      err.name(), fault_phase.name(), after_n_ops,
                      (queue_id == '1) ? "ANY" : $sformatf("%0d", queue_id),
                      inject_probability),
            UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // disable_injection -- Turn off error injection
    // ------------------------------------------------------------------
    function void disable_injection();
        inject_enable = 0;
        any_operation_active = 0;
        any_operation_counted = 0;
        any_operation_consumed = 0;
        any_operation_queue = '1;
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
    function bit should_inject(
        int unsigned current_queue_id,
        virtqueue_error_phase_e current_phase = VQ_FAULT_PRE_NOTIFY
    );
        int unsigned rand_val;
        injection_record_t record;

        // 1. Check enable
        if (!inject_enable)
            return 0;

        // 2. Check queue match ('1 means any queue)
        if (target_queue_id != '1 && target_queue_id != current_queue_id)
            return 0;

        // A phase mismatch is deliberately side-effect free: it must not
        // consume inject_after_n_ops or alter probability/count history.
        if (inject_phase != VQ_FAULT_ANY && inject_phase != current_phase)
            return 0;

        // 中文说明：ANY 是边界选择器，不是每个阶段都重复改写 descriptor 的命令。
        // VQ_FAULT_ANY is a boundary selector, not an instruction to mutate
        // the descriptor once at every phase callback.  A PRE_* phase starts
        // a new queue/responder operation; a POST_* phase closes it.  Direct
        // callers that only provide a terminal phase get an implicit one-phase
        // operation.  Countdown and probability are consumed once per such
        // operation, rather than once per phase.
        if (inject_phase == VQ_FAULT_ANY) begin
            if (current_phase inside {VQ_FAULT_PRE_NOTIFY,
                                      VQ_FAULT_PRE_DEVICE_READ}) begin
                any_operation_active = 1;
                any_operation_counted = 0;
                any_operation_consumed = 0;
                any_operation_queue = current_queue_id;
            end else if (!any_operation_active ||
                         (any_operation_queue != current_queue_id)) begin
                any_operation_active = 1;
                any_operation_counted = 0;
                any_operation_consumed = 0;
                any_operation_queue = current_queue_id;
            end

            if (any_operation_consumed) begin
                if (current_phase inside {VQ_FAULT_POST_NOTIFY,
                                          VQ_FAULT_BEFORE_USED})
                    any_operation_active = 0;
                return 0;
            end

            if (any_operation_counted) begin
                // The first matching phase already made the countdown and
                // probability decision.  Do not make a second decision for
                // the same operation; close a terminal phase below.
                if (current_phase inside {VQ_FAULT_POST_NOTIFY,
                                          VQ_FAULT_BEFORE_USED})
                    any_operation_active = 0;
                return 0;
            end

            any_operation_counted = 1;
            op_count++;
            if (op_count <= inject_after_n_ops) begin
                if (current_phase inside {VQ_FAULT_POST_NOTIFY,
                                          VQ_FAULT_BEFORE_USED})
                    any_operation_active = 0;
                return 0;
            end

            if (inject_probability < 100) begin
                rand_val = $urandom_range(0, 99);
                if (rand_val >= inject_probability) begin
                    if (current_phase inside {VQ_FAULT_POST_NOTIFY,
                                              VQ_FAULT_BEFORE_USED})
                        any_operation_active = 0;
                    return 0;
                end
            end
        end else begin
            // 3. Increment and check countdown for a phase-specific rule.
            op_count++;
            if (op_count <= inject_after_n_ops)
                return 0;

            // 4. Probabilistic decision for a phase-specific rule.
            if (inject_probability < 100) begin
                rand_val = $urandom_range(0, 99);
                if (rand_val >= inject_probability)
                    return 0;
            end
        end

        // 5. Inject: record history and log
        record.err       = err_type;
        record.phase     = current_phase;
        record.queue_id  = current_queue_id;
        record.op_count  = op_count;
        record.timestamp = $realtime;
        history.push_back(record);
        if (inject_phase == VQ_FAULT_ANY) begin
            any_operation_consumed = 1;
            if (current_phase inside {VQ_FAULT_POST_NOTIFY,
                                      VQ_FAULT_BEFORE_USED})
                any_operation_active = 0;
        end

        `uvm_info("VQ_ERR_INJ",
            $sformatf("INJECTING err=%s phase=%s on queue=%0d op_count=%0d at %0t",
                      err_type.name(), current_phase.name(), current_queue_id,
                      op_count, $realtime),
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

    // Return the phase of the most recent semantic injection.  ANY is used
    // when no injection has happened yet so callers can distinguish an armed
    // injector from a consumed fault without peeking into protected history.
    function virtqueue_error_phase_e last_injection_phase();
        if (history.size() == 0)
            return VQ_FAULT_ANY;
        return history[history.size() - 1].phase;
    endfunction

    function int unsigned injection_count();
        return history.size();
    endfunction

    // ------------------------------------------------------------------
    // corrupt_descriptor -- Explicit post-publication Host-memory mutation
    //
    // This is intentionally an explicit, one-shot API.  It is called by a
    // fault hook after the production driver has published a descriptor and
    // before the DUT/responder consumes it.  It does not alter normal queue
    // allocation semantics and therefore cannot make a passing test appear to
    // exercise an error merely because configure() was called.
    //
    // Split descriptor layout: addr[0:7], len[8:11], flags[12:13], next[14:15]
    // Packed descriptor layout: addr[0:7], len[8:11], id[12:13], flags[14:15]
    // ------------------------------------------------------------------
    function bit corrupt_descriptor(
        input host_mem_api mem,
        input bit [63:0] desc_base,
        input virtqueue_type_e ring_type,
        input int unsigned queue_size,
        input int unsigned descriptor_index,
        input virtio_desc_corruption_field_e field,
        input bit [63:0] value,
        output string why
    );
        bit [63:0] desc_addr;
        int unsigned field_offset;
        int unsigned field_size;
        byte bytes[];
        byte encoded[];
        descriptor_corruption_record_t record;

        why = "";
        if (mem == null) begin
            why = "Host-memory handle is null";
            return 0;
        end
        if (ring_type == VQ_CUSTOM) begin
            why = "custom virtqueue descriptor layout is not known";
            return 0;
        end
        if (queue_size == 0 || descriptor_index >= queue_size) begin
            why = $sformatf("descriptor index %0d is outside queue size %0d",
                            descriptor_index, queue_size);
            return 0;
        end
        if ((desc_base & 64'hf) != 0) begin
            why = $sformatf("descriptor table base 0x%016h is not 16-byte aligned",
                            desc_base);
            return 0;
        end
        // Reject arithmetic wrap before computing the target address.  The
        // complete 16-byte descriptor (not only its first byte) must fit.
        if (desc_base > (64'hffff_ffff_ffff_ffff - 64'd15) ||
            descriptor_index >
                ((64'hffff_ffff_ffff_ffff - 64'd15 - desc_base) / 64'd16)) begin
            why = "descriptor table address arithmetic overflow";
            return 0;
        end
        // Widen before multiplication; descriptor_index is a 32-bit SV
        // integer and would otherwise wrap before it is assigned to 64 bits.
        desc_addr = desc_base +
                    ((64'h0 + descriptor_index) * 64'd16);

        field_offset = 0;
        field_size = 0;
        case (field)
            VQ_DESC_FIELD_ADDR: begin field_offset = 0;  field_size = 8; end
            VQ_DESC_FIELD_LEN:  begin field_offset = 8;  field_size = 4; end
            VQ_DESC_FIELD_FLAGS: begin
                field_offset = (ring_type == VQ_SPLIT) ? 12 : 14;
                field_size = 2;
            end
            VQ_DESC_FIELD_NEXT: begin
                if (ring_type != VQ_SPLIT) begin
                    why = "packed descriptors do not contain a NEXT field";
                    return 0;
                end
                field_offset = 14;
                field_size = 2;
            end
            VQ_DESC_FIELD_ID: begin
                if (ring_type != VQ_PACKED) begin
                    why = "split descriptors do not contain an ID field";
                    return 0;
                end
                field_offset = 12;
                field_size = 2;
            end
            default: begin
                why = "unsupported descriptor corruption field";
                return 0;
            end
        endcase

        if ((field_size < 8) && ((value >> (field_size * 8)) != 0)) begin
            why = $sformatf("value 0x%016h does not fit %0d-byte field",
                            value, field_size);
            return 0;
        end

        // Read/write the complete descriptor to preserve bytes not targeted by
        // the fault.  host_mem_api performs the same aperture/allocation checks
        // as every normal DMA operation.
        mem.read_mem(desc_addr, 16, bytes, `__FILE__, `__LINE__);
        if (bytes.size() != 16) begin
            why = $sformatf("could not read descriptor at 0x%016h", desc_addr);
            return 0;
        end
        encoded = new[field_size];
        for (int unsigned i = 0; i < field_size; i++)
            encoded[i] = value[i*8 +: 8];
        for (int unsigned i = 0; i < field_size; i++)
            bytes[field_offset + i] = encoded[i];
        mem.write_mem(desc_addr, bytes, `__FILE__, `__LINE__);

        record.queue_id = '1;
        record.ring_type = ring_type;
        record.descriptor_index = descriptor_index;
        record.field = field;
        record.value = value;
        record.timestamp = $realtime;
        corruption_history.push_back(record);
        `uvm_info("VQ_DESC_CORRUPT", $sformatf(
            "mutated %s descriptor[%0d] field=%s value=0x%016h at 0x%016h",
            ring_type.name(), descriptor_index, field.name(), value, desc_addr),
            UVM_MEDIUM)
        return 1;
    endfunction

    function int unsigned descriptor_corruption_count();
        return corruption_history.size();
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
                $sformatf("  [%0d] err=%s phase=%s queue=%0d op_count=%0d time=%0t",
                          i, history[i].err.name(), history[i].phase.name(),
                          history[i].queue_id,
                          history[i].op_count, history[i].timestamp),
                UVM_LOW)
        end
    endfunction

endclass : virtqueue_error_injector

`endif // VIRTQUEUE_ERROR_INJECTOR_SV
