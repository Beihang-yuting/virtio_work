// ============================================================================
// virtio_notification_manager.sv
//
// Manages MSI-X / INTx / polling / adaptive interrupt modes with NAPI-style
// control for the virtio-net VIP.
//
// Responsibilities:
//   - MSI-X table setup and vector allocation via BAR accessor
//   - Three-level IRQ fallback: per-queue MSI-X -> shared MSI-X -> INTx
//   - Per-vector mask/unmask with global function mask
//   - ISR read-and-clear for INTx mode
//   - NAPI polling mode enter/exit per queue
//   - Interrupt statistics tracking
//   - Error injection (spurious, missed, wrong-vector interrupts)
//
// Per virtio spec Section 4.1.4.7 (MSI-X) and Section 4.1.4.5 (ISR)
// ============================================================================

`ifndef VIRTIO_NOTIFICATION_MANAGER_SV
`define VIRTIO_NOTIFICATION_MANAGER_SV

class virtio_notification_manager extends uvm_object;
    `uvm_object_utils(virtio_notification_manager)

    // ===== Mode configuration =====
    interrupt_mode_e  irq_mode = IRQ_MSIX_PER_QUEUE;
    bit               event_idx_enable = 0;
    bit               coalescing_enable = 0;

    // ===== MSI-X state =====
    msix_entry_t      msix_table[];          // vector table
    int unsigned      config_vector;          // config change vector
    int unsigned      queue_vectors[];        // queue_id -> vector mapping
    bit               msix_mask[];            // per-vector mask
    bit               msix_function_mask = 0; // global function mask

    // ===== INTx state =====
    bit               intx_enabled = 0;
    bit [7:0]         isr_status = 0;        // bit0=queue, bit1=config change

    // ===== Coalescing parameters =====
    int unsigned      coal_max_packets = 0;
    int unsigned      coal_max_usecs = 0;

    // ===== NAPI per-queue callback enable =====
    bit               cb_enabled[];          // per-queue callback enable

    // ===== Statistics =====
    int unsigned      total_interrupts = 0;
    int unsigned      spurious_interrupts = 0;
    int unsigned      suppressed_notifications = 0;
    int unsigned      config_change_interrupts = 0;

    // ===== BAR accessor reference =====
    virtio_bar_accessor  bar;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_notification_manager");
        super.new(name);
        config_vector = 0;
    endfunction

    // ========================================================================
    // setup_msix
    //
    // Writes MSI-X table entries to BAR space via bar.write_reg().
    // Each MSI-X table entry is 16 bytes:
    //   Offset 0x00: Message Address (lower 32)
    //   Offset 0x04: Message Address (upper 32)
    //   Offset 0x08: Message Data (32)
    //   Offset 0x0C: Vector Control (bit 0 = mask)
    // ========================================================================

    virtual task setup_msix(int unsigned num_vectors,
                             int unsigned msix_table_bar, bit [31:0] msix_table_offset);
        if (bar == null) begin
            `uvm_fatal("NOTIFY_MGR", "bar is null; set it before calling setup_msix()")
        end

        msix_table = new[num_vectors];
        msix_mask  = new[num_vectors];

        for (int i = 0; i < num_vectors; i++) begin
            bit [31:0] entry_offset;
            entry_offset = msix_table_offset + (i * 16);

            // Initialize with default MSI-X entry values
            msix_table[i].msg_addr = 64'hFEE0_0000 + (i * 4);  // Default APIC addr
            msix_table[i].msg_data = i;                          // Vector number as data
            msix_table[i].masked   = 1;                          // Start masked
            msix_mask[i]           = 1;

            // Write Message Address (lower 32)
            bar.write_reg(msix_table_bar, entry_offset + 32'h00, 4,
                          msix_table[i].msg_addr[31:0]);

            // Write Message Address (upper 32)
            bar.write_reg(msix_table_bar, entry_offset + 32'h04, 4,
                          msix_table[i].msg_addr[63:32]);

            // Write Message Data
            bar.write_reg(msix_table_bar, entry_offset + 32'h08, 4,
                          msix_table[i].msg_data);

            // Write Vector Control (masked)
            bar.write_reg(msix_table_bar, entry_offset + 32'h0C, 4,
                          32'h0000_0001);

            `uvm_info("NOTIFY_MGR",
                $sformatf("MSI-X vector %0d: addr=0x%016h data=0x%08h masked=%0b",
                          i, msix_table[i].msg_addr, msix_table[i].msg_data,
                          msix_table[i].masked), UVM_HIGH)
        end

        `uvm_info("NOTIFY_MGR",
            $sformatf("MSI-X table setup complete: %0d vectors in BAR%0d at offset 0x%08h",
                      num_vectors, msix_table_bar, msix_table_offset), UVM_MEDIUM)
    endtask

    // ========================================================================
    // allocate_irq_vectors
    //
    // Three-level IRQ fallback:
    //   1. Per-queue MSI-X: num_queues + 1 vectors (1 config + N queues)
    //   2. Shared MSI-X:    3 vectors (1 config + 1 rx_shared + 1 tx_shared)
    //   3. INTx fallback
    //
    // The actual_mode output indicates which mode was selected.
    // ========================================================================

    virtual task allocate_irq_vectors(int unsigned num_queues, ref interrupt_mode_e actual_mode);
        int unsigned needed_per_queue;
        int unsigned available_vectors;

        needed_per_queue = num_queues + 1;  // 1 config + N queues

        // Check if MSI-X is available (msix_table must have been set up)
        if (msix_table.size() > 0) begin
            available_vectors = msix_table.size();

            // Try per-queue first
            if (available_vectors >= needed_per_queue) begin
                actual_mode = IRQ_MSIX_PER_QUEUE;
                irq_mode    = IRQ_MSIX_PER_QUEUE;

                queue_vectors = new[num_queues];
                cb_enabled    = new[num_queues];

                config_vector = 0;  // Vector 0 for config changes
                for (int i = 0; i < num_queues; i++) begin
                    queue_vectors[i] = i + 1;  // Vectors 1..N for queues
                    cb_enabled[i]    = 1;
                end

                `uvm_info("NOTIFY_MGR",
                    $sformatf("IRQ allocation: per-queue MSI-X (%0d vectors, %0d queues)",
                              needed_per_queue, num_queues), UVM_MEDIUM)
                return;
            end

            // Try shared mode (3 vectors: config, rx_shared, tx_shared)
            if (available_vectors >= 3) begin
                actual_mode = IRQ_MSIX_SHARED;
                irq_mode    = IRQ_MSIX_SHARED;

                queue_vectors = new[num_queues];
                cb_enabled    = new[num_queues];

                config_vector = 0;
                for (int i = 0; i < num_queues; i++) begin
                    // Even queues (RX) share vector 1, odd queues (TX) share vector 2
                    queue_vectors[i] = (i % 2 == 0) ? 1 : 2;
                    cb_enabled[i]    = 1;
                end

                `uvm_info("NOTIFY_MGR",
                    $sformatf("IRQ allocation: shared MSI-X (3 vectors, %0d queues)",
                              num_queues), UVM_MEDIUM)
                return;
            end
        end

        // Final fallback: INTx
        actual_mode  = IRQ_INTX;
        irq_mode     = IRQ_INTX;
        intx_enabled = 1;

        queue_vectors = new[num_queues];
        cb_enabled    = new[num_queues];
        for (int i = 0; i < num_queues; i++) begin
            queue_vectors[i] = 0;
            cb_enabled[i]    = 1;
        end

        `uvm_info("NOTIFY_MGR",
            $sformatf("IRQ allocation: INTx fallback (%0d queues)", num_queues),
            UVM_MEDIUM)
    endtask

    // ========================================================================
    // bind_queue_vector
    //
    // Records the MSI-X vector binding for a queue. The actual MMIO write to
    // Q_MSIX is done by the transport layer after selecting the queue.
    // ========================================================================

    virtual task bind_queue_vector(int unsigned queue_id, int unsigned vector);
        if (queue_id < queue_vectors.size())
            queue_vectors[queue_id] = vector;

        `uvm_info("NOTIFY_MGR",
            $sformatf("Binding queue %0d to MSI-X vector %0d", queue_id, vector),
            UVM_HIGH)
    endtask

    // ========================================================================
    // Mask / Unmask operations
    // ========================================================================

    virtual task mask_vector(int unsigned vector);
        if (vector >= msix_mask.size()) begin
            `uvm_warning("NOTIFY_MGR",
                $sformatf("mask_vector: vector %0d out of range (max %0d)",
                          vector, msix_mask.size() - 1))
            return;
        end
        msix_mask[vector] = 1;
        msix_table[vector].masked = 1;

        `uvm_info("NOTIFY_MGR",
            $sformatf("Masked MSI-X vector %0d", vector), UVM_HIGH)
    endtask

    virtual task unmask_vector(int unsigned vector);
        if (vector >= msix_mask.size()) begin
            `uvm_warning("NOTIFY_MGR",
                $sformatf("unmask_vector: vector %0d out of range (max %0d)",
                          vector, msix_mask.size() - 1))
            return;
        end
        msix_mask[vector] = 0;
        msix_table[vector].masked = 0;

        `uvm_info("NOTIFY_MGR",
            $sformatf("Unmasked MSI-X vector %0d", vector), UVM_HIGH)
    endtask

    virtual task mask_all();
        msix_function_mask = 1;
        for (int i = 0; i < msix_mask.size(); i++) begin
            msix_mask[i] = 1;
            msix_table[i].masked = 1;
        end
        `uvm_info("NOTIFY_MGR", "All MSI-X vectors masked (function mask)", UVM_MEDIUM)
    endtask

    virtual task unmask_all();
        msix_function_mask = 0;
        for (int i = 0; i < msix_mask.size(); i++) begin
            msix_mask[i] = 0;
            msix_table[i].masked = 0;
        end
        `uvm_info("NOTIFY_MGR", "All MSI-X vectors unmasked", UVM_MEDIUM)
    endtask

    // ========================================================================
    // ISR operations (INTx mode)
    //
    // Reads the ISR status register and clears it (read-to-clear semantics).
    // ISR bit 0: queue interrupt, bit 1: config change interrupt.
    // ========================================================================

    virtual task read_and_clear_isr(ref bit [7:0] status);
        status     = isr_status;
        isr_status = 8'h00;

        `uvm_info("NOTIFY_MGR",
            $sformatf("ISR read-and-clear: status=0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // Interrupt handlers
    // ========================================================================

    virtual function void on_interrupt_received(int unsigned vector);
        total_interrupts++;

        // Check if vector is valid
        if (vector >= msix_mask.size()) begin
            spurious_interrupts++;
            `uvm_warning("NOTIFY_MGR",
                $sformatf("Interrupt on invalid vector %0d (spurious)", vector))
            return;
        end

        // Check if vector is masked
        if (msix_mask[vector] || msix_function_mask) begin
            suppressed_notifications++;
            `uvm_info("NOTIFY_MGR",
                $sformatf("Interrupt on masked vector %0d (suppressed)", vector),
                UVM_HIGH)
            return;
        end

        // Check if it is the config change vector
        if (vector == config_vector) begin
            on_config_change_interrupt();
            return;
        end

        `uvm_info("NOTIFY_MGR",
            $sformatf("Interrupt received on vector %0d", vector), UVM_HIGH)
    endfunction

    virtual function void on_config_change_interrupt();
        config_change_interrupts++;
        total_interrupts++;
        isr_status[1] = 1;

        `uvm_info("NOTIFY_MGR",
            "Config change interrupt received", UVM_MEDIUM)
    endfunction

    virtual function void on_intx_interrupt();
        total_interrupts++;
        isr_status[0] = 1;

        `uvm_info("NOTIFY_MGR", "INTx interrupt received", UVM_HIGH)
    endfunction

    // ========================================================================
    // NAPI polling mode control
    //
    // enter_polling_mode disables the callback for the given queue.
    // exit_polling_mode re-enables it after the polling budget is consumed.
    // ========================================================================

    virtual function void enter_polling_mode(int unsigned queue_id);
        if (queue_id >= cb_enabled.size()) begin
            `uvm_warning("NOTIFY_MGR",
                $sformatf("enter_polling_mode: queue_id %0d out of range", queue_id))
            return;
        end
        cb_enabled[queue_id] = 0;

        `uvm_info("NOTIFY_MGR",
            $sformatf("Queue %0d entered polling mode (NAPI)", queue_id), UVM_HIGH)
    endfunction

    virtual function void exit_polling_mode(int unsigned queue_id);
        if (queue_id >= cb_enabled.size()) begin
            `uvm_warning("NOTIFY_MGR",
                $sformatf("exit_polling_mode: queue_id %0d out of range", queue_id))
            return;
        end
        cb_enabled[queue_id] = 1;

        `uvm_info("NOTIFY_MGR",
            $sformatf("Queue %0d exited polling mode (NAPI)", queue_id), UVM_HIGH)
    endfunction

    // ========================================================================
    // Error injection
    // ========================================================================

    virtual task inject_spurious_interrupt(int unsigned vector);
        `uvm_info("NOTIFY_MGR",
            $sformatf("Injecting spurious interrupt on vector %0d", vector), UVM_LOW)
        spurious_interrupts++;
        total_interrupts++;
        on_interrupt_received(vector);
    endtask

    virtual task inject_missed_interrupt(int unsigned queue_id);
        `uvm_info("NOTIFY_MGR",
            $sformatf("Injecting missed interrupt for queue %0d", queue_id), UVM_LOW)
        // Suppress the notification for the queue without delivering it
        suppressed_notifications++;
    endtask

    virtual task inject_wrong_vector(int unsigned queue_id);
        int unsigned wrong_vector;
        if (queue_id < queue_vectors.size()) begin
            // Deliver on a different vector than expected
            wrong_vector = queue_vectors[queue_id] ^ 1;
            `uvm_info("NOTIFY_MGR",
                $sformatf("Injecting wrong vector for queue %0d: expected=%0d, delivering=%0d",
                          queue_id, queue_vectors[queue_id], wrong_vector), UVM_LOW)
            on_interrupt_received(wrong_vector);
        end else begin
            `uvm_warning("NOTIFY_MGR",
                $sformatf("inject_wrong_vector: queue_id %0d out of range", queue_id))
        end
    endtask

endclass : virtio_notification_manager

`endif // VIRTIO_NOTIFICATION_MANAGER_SV
