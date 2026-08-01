`ifndef VIRTIO_PROTOCOL_EVENT_IF_SV
`define VIRTIO_PROTOCOL_EVENT_IF_SV

import uvm_pkg::*;

// Clocked observation boundary shared by the passive monitor and the SVA
// checker.  Monitor callbacks stage decoded events here; the interface emits
// their one-clock pulses at negedge so the checker samples them deterministically
// at the following posedge.  Direct VIF driving remains supported for the
// protocol-only testbench.
interface virtio_protocol_event_if(input logic clk, input logic rst_n);
    logic        status_write;
    logic        features_ok;
    logic        driver_ok;
    logic        queue_configured;
    logic        queue_enabled;
    logic        notify;
    logic        verified_submission;
    logic        completion;
    logic        queue_reset;
    logic        reset_all_queues;

    logic [7:0]  status_old;
    logic [7:0]  status_new;
    logic [15:0] queue_id;
    logic [15:0] completion_queue_id;
    logic [15:0] interrupt_vector;
    logic [63:0] dma_addr;
    logic [31:0] dma_length;

    logic        features_ok_seen;
    logic        driver_seen;
    logic        assertions_enable;
    int unsigned protocol_error_count;
    // A legal queue notify is the production submission boundary.  Retain
    // credits by queue so a completion cannot consume a different queue's
    // submission.  The aggregate remains available for debug/backcompat.
    int unsigned outstanding_submission_count;
    int unsigned outstanding_submission_count_by_queue[int unsigned];
    // Keep the associative lookup outside the concurrent assertion.  This is
    // explicitly refreshed when a completion is released or lifecycle state
    // changes, avoiding tool-specific dynamic-array sensitivity behaviour.
    logic completion_has_pending_submission;

    typedef enum logic [2:0] {
        STAGED_STATUS,
        STAGED_NOTIFY,
        STAGED_COMPLETION,
        STAGED_QUEUE_RESET,
        STAGED_RESET_ALL_QUEUES
    } staged_pulse_kind_e;

    typedef struct {
        staged_pulse_kind_e kind;
        logic [7:0]         status_old;
        logic [7:0]         status_new;
        logic [15:0]        queue_id;
        logic [15:0]        interrupt_vector;
        logic               queue_configured;
        logic               queue_enabled;
        logic               verified_submission;
    } staged_pulse_t;

    // Status/notify/completion are protocol pulses and must retain their
    // original monitor order if several callbacks arrive in one clock half.
    staged_pulse_t staged_pulses[$];

    // Queue, DMA, and raw interrupt fields are level metadata.  Coalescing
    // their latest value is intentional because they do not themselves drive
    // an SVA sample.
    logic        staged_queue_state_pending;
    logic [15:0] staged_queue_id;
    logic        staged_queue_configured;
    logic        staged_queue_enabled;
    logic        staged_dma_pending;
    logic [63:0] staged_dma_addr;
    logic [31:0] staged_dma_length;
    logic        staged_interrupt_pending;
    logic [15:0] staged_interrupt_vector;

    initial begin
        status_write = 0;
        features_ok = 0;
        driver_ok = 0;
        queue_configured = 0;
        queue_enabled = 0;
        notify = 0;
        verified_submission = 0;
        completion = 0;
        queue_reset = 0;
        reset_all_queues = 0;
        completion_has_pending_submission = 0;
        status_old = '0;
        status_new = '0;
        queue_id = '0;
        completion_queue_id = '0;
        interrupt_vector = '0;
        dma_addr = '0;
        dma_length = '0;
        features_ok_seen = 0;
        driver_seen = 0;
        assertions_enable = 1;
        protocol_error_count = 0;
        outstanding_submission_count = 0;
        staged_queue_state_pending = 0;
        staged_dma_pending = 0;
        staged_interrupt_pending = 0;
    end

    // Monitor functions cannot call tasks, so their decoded events are
    // retained in the interface and released just before a checker edge.
    // The queue preserves order across status, notify and completion pulses;
    // a same-half-cycle notify followed by completion therefore remains a
    // prior submission rather than an ambiguous simultaneous pair.
    always @(negedge clk or negedge rst_n) begin
        staged_pulse_t staged;

        if (!rst_n) begin
            staged_pulses.delete();
            staged_queue_state_pending = 0;
            staged_dma_pending = 0;
            staged_interrupt_pending = 0;
        end
        else begin
            if (staged_queue_state_pending) begin
                queue_id <= staged_queue_id;
                queue_configured <= staged_queue_configured;
                queue_enabled <= staged_queue_enabled;
                staged_queue_state_pending = 0;
            end
            if (staged_dma_pending) begin
                dma_addr <= staged_dma_addr;
                dma_length <= staged_dma_length;
                staged_dma_pending = 0;
            end
            if (staged_interrupt_pending) begin
                interrupt_vector <= staged_interrupt_vector;
                staged_interrupt_pending = 0;
            end
            if (staged_pulses.size() != 0) begin
                staged = staged_pulses.pop_front();
                case (staged.kind)
                    STAGED_STATUS: begin
                        status_old <= staged.status_old;
                        status_new <= staged.status_new;
                        status_write <= 1;
                        features_ok <= ((staged.status_new & 8'h08) != 0);
                        driver_ok <= ((staged.status_new & 8'h04) != 0);
                    end
                    STAGED_NOTIFY: begin
                        queue_id <= staged.queue_id;
                        queue_configured <= staged.queue_configured;
                        queue_enabled <= staged.queue_enabled;
                        notify <= 1;
                        verified_submission <= staged.verified_submission;
                    end
                    STAGED_COMPLETION: begin
                        interrupt_vector <= staged.interrupt_vector;
                        completion_queue_id <= staged.queue_id;
                        completion_has_pending_submission <=
                            (outstanding_submissions_for_queue(staged.queue_id) != 0);
                        completion <= 1;
                    end
                    STAGED_QUEUE_RESET: begin
                        queue_id <= staged.queue_id;
                        queue_reset <= 1;
                    end
                    STAGED_RESET_ALL_QUEUES: reset_all_queues <= 1;
                    default: ;
                endcase
            end
        end
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            status_write <= 0;
            features_ok <= 0;
            driver_ok <= 0;
            notify <= 0;
            verified_submission <= 0;
            completion <= 0;
            queue_reset <= 0;
            reset_all_queues <= 0;
            queue_configured <= 0;
            queue_enabled <= 0;
            features_ok_seen <= 0;
            driver_seen <= 0;
            protocol_error_count <= 0;
            outstanding_submission_count <= 0;
            outstanding_submission_count_by_queue.delete();
            completion_has_pending_submission <= 0;
        end
        else begin
            // A device reset cancels protocol history and all in-flight
            // queue work.  It deliberately does not erase the error counter:
            // a test can therefore account for a complete negative trace.
            if (status_write && (status_new == 8'h00)) begin
                features_ok_seen <= 0;
                driver_seen <= 0;
                outstanding_submission_count <= 0;
                outstanding_submission_count_by_queue.delete();
                completion_has_pending_submission <= 0;
            end
            else if (reset_all_queues) begin
                outstanding_submission_count <= 0;
                outstanding_submission_count_by_queue.delete();
                completion_has_pending_submission <= 0;
            end
            else begin
                if (features_ok)
                    features_ok_seen <= 1;
                if (status_write && ((status_new & 8'h02) != 0))
                    driver_seen <= 1;

                // Raw notify remains available to the queue-enable assertion,
                // but only a monitor-verified notify may create a pending
                // request.  Queue reset discards only that queue's credit.
                if (queue_reset) begin
                    if (outstanding_submission_count_by_queue.exists(queue_id)) begin
                        if (outstanding_submission_count >=
                            outstanding_submission_count_by_queue[queue_id])
                            outstanding_submission_count <=
                                outstanding_submission_count -
                                outstanding_submission_count_by_queue[queue_id];
                        else
                            outstanding_submission_count <= 0;
                    end
                    outstanding_submission_count_by_queue.delete(queue_id);
                    if (queue_id == completion_queue_id)
                        completion_has_pending_submission <= 0;
                end
                case ({verified_submission, completion})
                    2'b10: begin
                        outstanding_submission_count_by_queue[queue_id] <=
                            outstanding_submission_count_by_queue.exists(queue_id) ?
                            outstanding_submission_count_by_queue[queue_id] + 1 : 1;
                        outstanding_submission_count <= outstanding_submission_count + 1;
                        if (queue_id == completion_queue_id)
                            completion_has_pending_submission <= 1;
                    end
                    2'b01: if (outstanding_submission_count_by_queue.exists(
                                     completion_queue_id) &&
                                 (outstanding_submission_count_by_queue[
                                     completion_queue_id] != 0)) begin
                        outstanding_submission_count_by_queue[completion_queue_id] <=
                            outstanding_submission_count_by_queue[completion_queue_id] - 1;
                        if (outstanding_submission_count != 0)
                            outstanding_submission_count <=
                                outstanding_submission_count - 1;
                        if (outstanding_submission_count_by_queue[
                                completion_queue_id] == 1)
                            completion_has_pending_submission <= 0;
                    end
                    // Production emits one staged pulse per edge, so this is
                    // only a compatibility rule for direct VIF drivers.
                    2'b11: begin
                        if (queue_id == completion_queue_id) begin
                            outstanding_submission_count_by_queue[queue_id] <=
                                outstanding_submission_count_by_queue.exists(queue_id) ?
                                outstanding_submission_count_by_queue[queue_id] : 1;
                            if (!outstanding_submission_count_by_queue.exists(queue_id) ||
                                (outstanding_submission_count_by_queue[queue_id] == 0))
                                outstanding_submission_count <=
                                    outstanding_submission_count + 1;
                            completion_has_pending_submission <= 1;
                        end
                        else begin
                            outstanding_submission_count_by_queue[queue_id] <=
                                outstanding_submission_count_by_queue.exists(queue_id) ?
                                outstanding_submission_count_by_queue[queue_id] + 1 : 1;
                            if (outstanding_submission_count_by_queue.exists(
                                    completion_queue_id) &&
                                (outstanding_submission_count_by_queue[
                                    completion_queue_id] != 0)) begin
                                outstanding_submission_count_by_queue[
                                    completion_queue_id] <=
                                    outstanding_submission_count_by_queue[
                                        completion_queue_id] - 1;
                            end
                            else begin
                                outstanding_submission_count <=
                                    outstanding_submission_count + 1;
                            end
                            if (outstanding_submission_count_by_queue.exists(
                                    completion_queue_id) &&
                                (outstanding_submission_count_by_queue[
                                    completion_queue_id] == 1))
                                completion_has_pending_submission <= 0;
                        end
                    end
                    default: ;
                endcase
            end

            status_write <= 0;
            features_ok <= 0;
            driver_ok <= 0;
            notify <= 0;
            verified_submission <= 0;
            completion <= 0;
            queue_reset <= 0;
            reset_all_queues <= 0;
        end
    end

    function void stage_status_write(
        input logic [7:0] old_status,
        input logic [7:0] new_status
    );
        staged_pulse_t staged;
        staged.kind = STAGED_STATUS;
        staged.status_old = old_status;
        staged.status_new = new_status;
        staged_pulses.push_back(staged);
    endfunction

    function void stage_queue_state(
        input logic [15:0] id,
        input logic configured,
        input logic enabled
    );
        staged_queue_id = id;
        staged_queue_configured = configured;
        staged_queue_enabled = enabled;
        staged_queue_state_pending = 1;
    endfunction

    function void stage_notify(
        input logic [15:0] id,
        input logic configured,
        input logic enabled,
        input logic verified
    );
        staged_pulse_t staged;
        staged.kind = STAGED_NOTIFY;
        staged.queue_id = id;
        staged.queue_configured = configured;
        staged.queue_enabled = enabled;
        staged.verified_submission = verified;
        staged_pulses.push_back(staged);
    endfunction

    function void stage_interrupt(
        input logic [15:0] vector,
        input logic queue_completion,
        input logic [15:0] completion_id = '0
    );
        staged_pulse_t staged;
        staged_interrupt_vector = vector;
        staged_interrupt_pending = 1;
        if (queue_completion) begin
            staged.kind = STAGED_COMPLETION;
            staged.queue_id = completion_id;
            staged.interrupt_vector = vector;
            staged_pulses.push_back(staged);
        end
    endfunction

    function void stage_queue_reset(input logic [15:0] id);
        staged_pulse_t staged;
        staged.kind = STAGED_QUEUE_RESET;
        staged.queue_id = id;
        staged_pulses.push_back(staged);
    endfunction

    function void stage_reset_all_queues();
        staged_pulse_t staged;
        staged.kind = STAGED_RESET_ALL_QUEUES;
        staged_pulses.push_back(staged);
    endfunction

    // Direct protocol tests drive pulse fields without monitor staging.  They
    // use this public helper to bind the upcoming completion to its queue and
    // sample the same per-queue lifecycle state as a staged completion.
    function void set_direct_completion_queue(input logic [15:0] id);
        completion_queue_id = id;
        completion_has_pending_submission =
            (outstanding_submissions_for_queue(id) != 0);
    endfunction

    function int unsigned outstanding_submissions_for_queue(
        input logic [15:0] id
    );
        if (outstanding_submission_count_by_queue.exists(id))
            return outstanding_submission_count_by_queue[id];
        return 0;
    endfunction

    function void stage_dma(
        input logic [63:0] address,
        input logic [31:0] length
    );
        staged_dma_addr = address;
        staged_dma_length = length;
        staged_dma_pending = 1;
    endfunction

    // Assertion action blocks report through UVM rather than raw $error so
    // direct negative tests can catch only their expected diagnostics while
    // leaving unrelated reports visible to the global UVM summary.
    function void report_protocol_error(input string message);
        protocol_error_count++;
        uvm_report_error("VIRTIO_PROTOCOL_SVA", message);
    endfunction
endinterface : virtio_protocol_event_if

`endif // VIRTIO_PROTOCOL_EVENT_IF_SV
