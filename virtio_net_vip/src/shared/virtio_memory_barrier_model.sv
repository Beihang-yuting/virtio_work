`ifndef VIRTIO_MEMORY_BARRIER_MODEL_SV
`define VIRTIO_MEMORY_BARRIER_MODEL_SV

// ============================================================================
// virtio_memory_barrier_model
//
// Models memory barriers (smp_wmb, smp_rmb, smp_mb) for the virtio driver.
//
// Barriers are no-ops in simulation from a timing perspective, but this
// class provides three important services:
//   1. Documentation -- each barrier call records intent and ordering
//      requirements at the point where the virtio spec mandates them
//   2. Statistics -- counts allow test checks for correct barrier usage
//   3. Error injection -- skip flags allow deliberate barrier omission
//      to verify that the scoreboard catches ordering violations
//
// Depends on: virtio_net_types.sv (virtqueue_error_e)
// ============================================================================

class virtio_memory_barrier_model extends uvm_object;
    `uvm_object_utils(virtio_memory_barrier_model)

    // ------------------------------------------------------------------
    // Skip flags for error injection
    // Each flag, when set, causes the corresponding barrier call to be
    // skipped silently (the skip is counted in skipped_count).
    // ------------------------------------------------------------------

    // Skip wmb after descriptor write, before avail ring update
    bit skip_wmb_before_avail = 0;

    // Skip rmb before reading the used ring
    bit skip_rmb_before_used  = 0;

    // Skip mb after avail update, before checking notification suppression
    bit skip_mb_before_kick   = 0;

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------
    int unsigned wmb_count     = 0;
    int unsigned rmb_count     = 0;
    int unsigned mb_count      = 0;
    int unsigned skipped_count = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_memory_barrier_model");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // wmb -- store/write memory barrier
    //
    // Corresponds to smp_wmb() in Linux kernel virtio driver.
    // Must be issued after writing descriptors and before updating the
    // avail ring index, to ensure the device sees descriptors before
    // the updated avail idx.
    //
    // Skippable via skip_wmb_before_avail for error injection.
    // ------------------------------------------------------------------
    function void wmb(string context_msg = "");
        if (skip_wmb_before_avail) begin
            skipped_count++;
            `uvm_info("MEM_BARRIER",
                $sformatf("wmb SKIPPED (error injection) at %0t%s",
                          $realtime,
                          (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
                UVM_MEDIUM)
            return;
        end
        wmb_count++;
        `uvm_info("MEM_BARRIER",
            $sformatf("wmb issued at %0t%s",
                      $realtime,
                      (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
            UVM_DEBUG)
    endfunction

    // ------------------------------------------------------------------
    // rmb -- load/read memory barrier
    //
    // Corresponds to smp_rmb() in Linux kernel virtio driver.
    // Must be issued before reading the used ring to ensure the driver
    // observes the device's writes to used descriptors in order.
    //
    // Skippable via skip_rmb_before_used for error injection.
    // ------------------------------------------------------------------
    function void rmb(string context_msg = "");
        if (skip_rmb_before_used) begin
            skipped_count++;
            `uvm_info("MEM_BARRIER",
                $sformatf("rmb SKIPPED (error injection) at %0t%s",
                          $realtime,
                          (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
                UVM_MEDIUM)
            return;
        end
        rmb_count++;
        `uvm_info("MEM_BARRIER",
            $sformatf("rmb issued at %0t%s",
                      $realtime,
                      (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
            UVM_DEBUG)
    endfunction

    // ------------------------------------------------------------------
    // mb -- full memory barrier
    //
    // Corresponds to smp_mb() in Linux kernel virtio driver.
    // Must be issued after updating the avail ring and before reading
    // the notification suppression flag, to ensure correct ordering of
    // the avail update and the kick decision.
    //
    // Skippable via skip_mb_before_kick for error injection.
    // ------------------------------------------------------------------
    function void mb(string context_msg = "");
        if (skip_mb_before_kick) begin
            skipped_count++;
            `uvm_info("MEM_BARRIER",
                $sformatf("mb SKIPPED (error injection) at %0t%s",
                          $realtime,
                          (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
                UVM_MEDIUM)
            return;
        end
        mb_count++;
        `uvm_info("MEM_BARRIER",
            $sformatf("mb issued at %0t%s",
                      $realtime,
                      (context_msg != "") ? $sformatf(" [%s]", context_msg) : ""),
            UVM_DEBUG)
    endfunction

    // ------------------------------------------------------------------
    // inject_barrier_skip
    //
    // Maps a virtqueue_error_e value to the appropriate skip flag.
    // Only the three barrier-skip error codes are handled; any other
    // value is ignored with an info message.
    // ------------------------------------------------------------------
    function void inject_barrier_skip(virtqueue_error_e err_type);
        case (err_type)
            VQ_ERR_SKIP_WMB_BEFORE_AVAIL: begin
                skip_wmb_before_avail = 1;
                `uvm_info("MEM_BARRIER",
                    "Error injection: skip_wmb_before_avail enabled",
                    UVM_MEDIUM)
            end
            VQ_ERR_SKIP_RMB_BEFORE_USED: begin
                skip_rmb_before_used = 1;
                `uvm_info("MEM_BARRIER",
                    "Error injection: skip_rmb_before_used enabled",
                    UVM_MEDIUM)
            end
            VQ_ERR_SKIP_MB_BEFORE_KICK: begin
                skip_mb_before_kick = 1;
                `uvm_info("MEM_BARRIER",
                    "Error injection: skip_mb_before_kick enabled",
                    UVM_MEDIUM)
            end
            default: begin
                `uvm_info("MEM_BARRIER",
                    $sformatf("inject_barrier_skip: err_type %s is not a barrier error, ignored",
                              err_type.name()),
                    UVM_MEDIUM)
            end
        endcase
    endfunction

    // ------------------------------------------------------------------
    // clear_all_skips
    //
    // Resets all skip flags to 0.  Call between test phases or after
    // error injection scenarios to restore normal barrier behavior.
    // ------------------------------------------------------------------
    function void clear_all_skips();
        skip_wmb_before_avail = 0;
        skip_rmb_before_used  = 0;
        skip_mb_before_kick   = 0;
        `uvm_info("MEM_BARRIER", "All barrier skip flags cleared", UVM_MEDIUM)
    endfunction

    // ------------------------------------------------------------------
    // print_stats
    //
    // Logs a summary of all barrier invocations and skips.  Intended for
    // end-of-test reporting or debug checkpoints.
    // ------------------------------------------------------------------
    function void print_stats();
        `uvm_info("MEM_BARRIER",
            $sformatf("Memory barrier statistics: wmb=%0d rmb=%0d mb=%0d skipped=%0d",
                      wmb_count, rmb_count, mb_count, skipped_count),
            UVM_LOW)
    endfunction

endclass

`endif // VIRTIO_MEMORY_BARRIER_MODEL_SV
