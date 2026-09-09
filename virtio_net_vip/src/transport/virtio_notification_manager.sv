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
//
// 中文定位：transport 目录内中断路径的模型层，管理 MSI-X 表/INTx/轮询三种
// 通知方式及其统计。
// 职责：经 bar.write_msix_reg 真实写 MSI-X 表(受 Fabric BAR4 守卫约束)、
// 三级降级分配向量、维护 per-vector 与 function 级 mask 的本地影子、INTx
// 的 ISR 读清语义、NAPI 回调开关，以及三种中断错误注入。注意 mask/unmask
// 只改本地影子状态，不回写设备端 Vector Control。
// 依赖：virtio_bar_accessor(唯一 MMIO 通道)、msix_entry_t/interrupt_mode_e
// 类型定义。
// 所有权/生命周期：uvm_object，由 virtio_pci_transport 构造时创建持有；
// bar 为借用引用(transport 交叉接线注入)。msix_table/queue_vectors 等在
// setup_msix/allocate_irq_vectors 时重建，重跑初始化会整体覆盖。
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
    // Stable namespace used only for model-generated default table entries.
    // Explicit table entries retain their caller-provided address/data.
    bit [15:0]        function_bdf;

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
    // 构造：仅置零 config_vector/function_bdf；bar 引用与各动态数组留待
    // transport 接线和 setup_msix/allocate_irq_vectors 建立。
    // ========================================================================

    function new(string name = "virtio_notification_manager");
        super.new(name);
        config_vector = 0;
        function_bdf = '0;
    endfunction

    // A transport function assigns this when its Fabric/PCIe identity is
    // configured.  Its BDF makes otherwise identical default MSI-X entries
    // unambiguous to a shared passive PCIe observer.
    virtual function void set_function_bdf(input bit [15:0] device_bdf);
        function_bdf = device_bdf;
    endfunction

    // ========================================================================
    // setup_msix
    //
    // Writes MSI-X table entries through the dedicated BAR accessor path.
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

            // The APIC destination address is shared by default.  Preserve
            // the vector number in the low half of message data while using
            // the upper half as a stable per-function BDF namespace.  The
            // complete address/data pair is thus unique across PFs/VFs even
            // when monitor traffic omits requester_id.
            msix_table[i].msg_addr = 64'hFEE0_0000 + (i * 4);
            msix_table[i].msg_data = {function_bdf, i[15:0]};
            msix_table[i].masked   = 1;                          // Start masked
            msix_mask[i]           = 1;

            // Write Message Address (lower 32)
            bar.write_msix_reg(msix_table_bar, entry_offset + 32'h00, 4,
                               msix_table[i].msg_addr[31:0]);

            // Write Message Address (upper 32)
            bar.write_msix_reg(msix_table_bar, entry_offset + 32'h04, 4,
                               msix_table[i].msg_addr[63:32]);

            // Write Message Data
            bar.write_msix_reg(msix_table_bar, entry_offset + 32'h08, 4,
                               msix_table[i].msg_data);

            // Write Vector Control (masked)
            bar.write_msix_reg(msix_table_bar, entry_offset + 32'h0C, 4,
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
    // mask/unmask：只更新本地 msix_mask/msix_table.masked 影子位，供
    // on_interrupt_received 判定是否压制；不回写设备端 Vector Control 寄存器。
    // ========================================================================

    // 屏蔽单个向量；越界仅告警不生效。
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

    // 解除单个向量的屏蔽；越界仅告警不生效。
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

    // 置 function 级全局屏蔽并同时屏蔽所有向量(建模 MSI-X function mask)。
    virtual task mask_all();
        msix_function_mask = 1;
        for (int i = 0; i < msix_mask.size(); i++) begin
            msix_mask[i] = 1;
            msix_table[i].masked = 1;
        end
        `uvm_info("NOTIFY_MGR", "All MSI-X vectors masked (function mask)", UVM_MEDIUM)
    endtask

    // 清 function 级屏蔽并解除全部向量屏蔽；初始化流程在向量绑定完成后调用。
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
    // 中断到达回调：由 observer/注入路径调用，按 影子mask -> config vector
    // 的顺序分类计数；不驱动任何总线行为。
    // ========================================================================

    // MSI-X 中断入口：无效向量计 spurious、被屏蔽计 suppressed、config
    // vector 转交 on_config_change_interrupt，其余只计数并打印。
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

    // config change 中断：递增专属计数并置 ISR bit1(供 INTx 读清路径观察)。
    // 注意经 on_interrupt_received 转入时 total_interrupts 会累加两次，
    // 保守观察：这是现状行为，统计口径以实现为准。
    virtual function void on_config_change_interrupt();
        config_change_interrupts++;
        total_interrupts++;
        isr_status[1] = 1;

        `uvm_info("NOTIFY_MGR",
            "Config change interrupt received", UVM_MEDIUM)
    endfunction

    // INTx 中断：置 ISR bit0(队列中断)，等待 read_and_clear_isr 读清；
    // 由 observer 在识别 ASSERT_INTx 消息后调用。
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
    // 错误注入：直接操纵本地中断模型(不发真实 TLP)，用于验证上层对异常
    // 中断行为的统计与容错。
    // ========================================================================

    // 注入伪中断：预先累加 spurious/total 计数后走正常入口再分类一次。
    virtual task inject_spurious_interrupt(int unsigned vector);
        `uvm_info("NOTIFY_MGR",
            $sformatf("Injecting spurious interrupt on vector %0d", vector), UVM_LOW)
        spurious_interrupts++;
        total_interrupts++;
        on_interrupt_received(vector);
    endtask

    // 注入漏中断：只累加 suppressed 计数、不投递任何回调，模拟通知丢失。
    virtual task inject_missed_interrupt(int unsigned queue_id);
        `uvm_info("NOTIFY_MGR",
            $sformatf("Injecting missed interrupt for queue %0d", queue_id), UVM_LOW)
        // Suppress the notification for the queue without delivering it
        suppressed_notifications++;
    endtask

    // 注入错向量中断：把队列期望向量最低位取反后投递(如 1->0、2->3)，
    // 验证向量错配时的分类行为；队列越界仅告警。
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
