`ifndef VIRTIO_MONITOR_SV
`define VIRTIO_MONITOR_SV

// Passive semantic monitor.  PCIe traffic enters through
// virtio_pcie_observer_adapter; each decoded event is retained in its own
// analysis FIFO, signals its matching uvm_event, and is broadcast exactly
// once on txn_ap (and also on err_ap when it represents a protocol error).
class virtio_monitor extends uvm_monitor;
    `uvm_component_utils(virtio_monitor)

    uvm_analysis_port #(virtio_transaction) txn_ap;
    uvm_analysis_port #(virtio_transaction) err_ap;
    uvm_analysis_port #(uvm_object)         pkt_ap;

    uvm_tlm_analysis_fifo #(virtio_transaction) bar_event_fifo;
    uvm_tlm_analysis_fifo #(virtio_transaction) dma_event_fifo;
    uvm_tlm_analysis_fifo #(virtio_transaction) interrupt_event_fifo;
    uvm_tlm_analysis_fifo #(virtio_transaction) queue_event_fifo;
    uvm_event bar_access_event;
    uvm_event dma_event;
    uvm_event interrupt_event;
    uvm_event queue_state_event;

    virtio_pci_transport   transport;
    virtqueue_manager      vq_mgr;
    bit [63:0]             negotiated_features;
    virtual virtio_protocol_event_if protocol_vif;

    bit chk_status_transition = 1;
    bit chk_feature_usage = 1;
    bit chk_queue_protocol = 1;
    bit chk_notification = 1;
    bit chk_descriptor_chain = 1;
    bit chk_dma_boundary = 1;

    protected bit [7:0] last_status = DEV_STATUS_RESET;
    protected bit [63:0] used_features = '0;
    protected bit [63:0] dma_addr_lo;
    protected bit [63:0] dma_addr_hi;
    protected bit dma_range_configured;
    protected bit queue_configured[int unsigned];
    protected bit queue_enabled[int unsigned];
    // A completion may only be emitted for an accepted notify.  Retain queue
    // IDs independently of the SVA counter so the monitor can correlate an
    // interrupt vector before it stages the completion pulse.
    protected int unsigned verified_submission_queues[$];

    // 构造函数：仅完成 UVM 注册；端口/FIFO 延迟到 build_phase 创建，
    // transport/vq_mgr/protocol_vif 由 env 在 connect 阶段注入。
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 创建三个分析端口（txn/err/pkt）、四类事件 FIFO 及对应 uvm_event。
    // 副作用：FIFO 作为子组件挂在本 monitor 下，事件对象为本地 new。
    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        txn_ap = new("txn_ap", this);
        err_ap = new("err_ap", this);
        pkt_ap = new("pkt_ap", this);
        bar_event_fifo = new("bar_event_fifo", this);
        dma_event_fifo = new("dma_event_fifo", this);
        interrupt_event_fifo = new("interrupt_event_fifo", this);
        queue_event_fifo = new("queue_event_fifo", this);
        bar_access_event = new("bar_access_event");
        dma_event = new("dma_event");
        interrupt_event = new("interrupt_event");
        queue_state_event = new("queue_state_event");
    endfunction

    // 配置合法 DMA 地址窗口 [lo, hi]（闭区间）。lo > hi 视为未配置，
    // 此时 observe_dma 的越界检查被跳过——这是刻意的失效保护而非报错。
    virtual function void configure_dma_range(
        input bit [63:0] lo,
        input bit [63:0] hi
    );
        dma_addr_lo = lo;
        dma_addr_hi = hi;
        dma_range_configured = (lo <= hi);
    endfunction

    // 复位全部协议语义状态：设备状态回 RESET、清 feature 使用记录、
    // 丢弃已验证的 notify 队列并清空所有队列配置/使能标记。
    // 用于设备级复位（FLR、status=0），不触碰 DMA 窗口配置。
    virtual function void reset_protocol_state();
        last_status = DEV_STATUS_RESET;
        used_features = '0;
        verified_submission_queues.delete();
        reset_all_queue_state();
    endfunction

    // Reset helpers are called by the PCIe observer for Q_RESET and by the
    // status decoder for device reset.  They deliberately clear semantic
    // state independently of the observer's decode cache.
    // 中文：单队列复位——删除该队列的配置/使能标记、丢弃其待完成 notify，
    // 并把队列状态与复位事件转发给 SVA 接口（vif 未接入时静默跳过）。
    virtual function void reset_queue_state(input int unsigned queue_id);
        queue_configured.delete(queue_id);
        queue_enabled.delete(queue_id);
        discard_queue_submissions(queue_id);
        if (protocol_vif != null) begin
            protocol_vif.stage_queue_state(queue_id, 0, 0);
            protocol_vif.stage_queue_reset(queue_id);
        end
    endfunction

    // 全队列复位：清空所有队列的配置/使能表及待完成 notify 队列，
    // 并通知 SVA 接口复位全部队列跟踪状态。由 status=0 写入时自动调用。
    virtual function void reset_all_queue_state();
        queue_configured.delete();
        queue_enabled.delete();
        verified_submission_queues.delete();
        if (protocol_vif != null) begin
            protocol_vif.stage_queue_state('0, 0, 0);
            protocol_vif.stage_reset_all_queues();
        end
    endfunction

    // 观察一次 BAR 读写并发布 VIRTIO_MON_BAR_ACCESS 事件。
    // 若写目标是 common config 的 status 寄存器（且 bar_id 匹配 common cfg
    // 所在 BAR，或调用方/transport 未提供 BAR 信息则放宽匹配），则做状态机
    // 转换合法性检查；非法转换标记错误，写 0 触发全队列复位。
    // 副作用：更新 last_status，并向 protocol_vif 驱动 status 事件。
    virtual function void observe_bar_access(
        input bit [63:0] address,
        input bit is_write,
        input int unsigned size_bytes,
        input bit [63:0] data,
        input int unsigned bar_offset,
        input int unsigned bar_id = 32'hffff_ffff
    );
        virtio_transaction txn;
        bit [7:0] new_status;
        bit valid;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, address, size_bytes, is_write);
        txn.monitor_data = data;
        txn.monitor_bar_offset = bar_offset;
        txn.monitor_bar_id = bar_id;
        txn.txn_type = VIO_TXN_INIT;
        txn.status_val = data[7:0];
        if (is_write && (bar_offset == VIRTIO_PCI_COMMON_STATUS) &&
            ((bar_id == 32'hffff_ffff) || (transport == null) ||
             (transport.cap_mgr == null) || !transport.cap_mgr.common_cfg_found ||
             (bar_id == transport.cap_mgr.common_cfg_cap.bar))) begin
            new_status = data[7:0];
            txn.status_old = last_status;
            valid = status_transition_valid(last_status, new_status);
            drive_status_event(last_status, new_status);
            if (!valid)
                mark_error(txn, $sformatf("Invalid status transition: 0x%02h -> 0x%02h",
                                          last_status, new_status));
            last_status = new_status;
            if (new_status == DEV_STATUS_RESET)
                reset_all_queue_state();
        end
        publish_event(txn);
    endfunction

    // 观察一次已解码的 status 写（调用方直接给出新旧值，不经过 BAR 解码）。
    // 与 observe_bar_access 的 status 分支逻辑一致：校验转换合法性、
    // 更新 last_status、status=0 时复位全部队列状态，最后发布事件。
    virtual function void observe_status_write(
        input bit [7:0] old_status,
        input bit [7:0] new_status
    );
        virtio_transaction txn;
        bit valid;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, '0, 1, 1);
        txn.txn_type = VIO_TXN_INIT;
        txn.status_old = old_status;
        txn.status_val = new_status;
        valid = status_transition_valid(old_status, new_status);
        drive_status_event(old_status, new_status);
        if (!valid)
            mark_error(txn, $sformatf("Invalid status transition: 0x%02h -> 0x%02h",
                                      old_status, new_status));
        last_status = new_status;
        if (new_status == DEV_STATUS_RESET)
            reset_all_queue_state();
        publish_event(txn);
    endfunction

    // 观察一次设备侧 DMA 访问。当越界检查使能且 DMA 窗口已配置时，
    // 校验 [address, address+size-1] 完全落在窗口内；size==0 或地址回绕
    // （last_byte < address）同样判为越界。事件同时转发给 SVA 接口。
    virtual function void observe_dma(
        input bit [63:0] address,
        input int unsigned size_bytes,
        input bit is_write
    );
        virtio_transaction txn;
        bit [63:0] last_byte;

        txn = new_monitor_txn(VIRTIO_MON_DMA, address, size_bytes, is_write);
        txn.txn_type = VIO_TXN_ATOMIC_OP;
        txn.atomic_op = ATOMIC_POLL_USED;
        if (chk_dma_boundary && dma_range_configured) begin
            last_byte = address + size_bytes - 1;
            if ((size_bytes == 0) || (address < dma_addr_lo) ||
                (last_byte > dma_addr_hi) || (last_byte < address)) begin
                mark_error(txn, $sformatf(
                    "DMA access outside mapped range: addr=0x%016h bytes=%0d range=[0x%016h:0x%016h]",
                    address, size_bytes, dma_addr_lo, dma_addr_hi));
            end
        end
        if (protocol_vif != null) begin
            protocol_vif.stage_dma(address, size_bytes);
        end
        publish_event(txn);
    endfunction

    // 观察一次中断（MSI-X 向量号或 INTx）。通过 take_queue_completion 判定
    // 该向量是否对应某个已验证 notify 的队列完成，并把判定结果连同队列号
    // 一起转发给 SVA 接口；irq_mode 取自 transport（未接入时默认 per-queue MSI-X）。
    virtual function void observe_interrupt(input int unsigned vector);
        virtio_transaction txn;
        int unsigned queue_id;
        bit queue_completion;

        txn = new_monitor_txn(VIRTIO_MON_INTERRUPT, '0, 0, 0);
        txn.txn_type = VIO_TXN_ATOMIC_OP;
        txn.atomic_op = ATOMIC_POLL_USED;
        txn.interrupt_vector = vector;
        txn.irq_mode = (transport == null) ? IRQ_MSIX_PER_QUEUE :
                       transport.notify_mgr.irq_mode;
        queue_completion = take_queue_completion(vector, queue_id);
        if (protocol_vif != null) begin
            protocol_vif.stage_interrupt(vector, queue_completion, queue_id);
        end
        publish_event(txn);
    endfunction

    // 观察队列配置/使能状态变化并更新本地跟踪表。
    // 协议规则：队列必须先 configured 再 enabled，违反即标记错误。
    // bar_offset/data/is_write 为可选的原始访问上下文，仅用于事件记录。
    virtual function void observe_queue_state(
        input int unsigned queue_id,
        input bit configured,
        input bit enabled,
        input int unsigned bar_offset = 0,
        input bit [63:0] data = '0,
        input bit is_write = 1'b1
    );
        virtio_transaction txn;

        txn = new_monitor_txn(VIRTIO_MON_QUEUE_STATE, '0, 0, 1);
        txn.txn_type = VIO_TXN_SETUP_QUEUE;
        txn.queue_id = queue_id;
        txn.queue_size = configured ? 1 : 0;
        txn.monitor_bar_offset = bar_offset;
        txn.monitor_data = data;
        txn.monitor_is_write = is_write;
        if (enabled && !configured) begin
            mark_error(txn, $sformatf("Queue %0d enabled before configuration", queue_id));
        end
        queue_configured[queue_id] = configured;
        queue_enabled[queue_id] = enabled;
        if (protocol_vif != null) begin
            protocol_vif.stage_queue_state(queue_id, configured, enabled);
        end
        publish_event(txn);
    endfunction

    // 观察一次队列 doorbell（kick）。合法性依次要求：队列已 configured 且
    // enabled；若提供了 notify 地址且 discovery 已填充 queue_notify_off，
    // 还必须命中该队列专属的 doorbell 偏移；vq_mgr 存在时进一步核对
    // 队列对象的 queue_enable。合法的 notify 入队 verified_submission_queues
    // 供后续中断关联；非法 kick 标记 VQ_ERR_KICK_BEFORE_ENABLE 错误。
    virtual function void observe_queue_notify(
        input int unsigned queue_id,
        input bit [15:0] notify_payload = '0,
        input int unsigned notify_offset = 0,
        input bit [63:0] notify_address = '0
    );
        virtio_transaction txn;
        virtqueue_base vq;
        bit valid;
        bit configured;
        bit enabled;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, '0, 2, 1);
        txn.txn_type = VIO_TXN_ATOMIC_OP;
        txn.atomic_op = ATOMIC_KICK;
        txn.queue_id = queue_id;
        txn.monitor_data = notify_payload;
        txn.monitor_bar_offset = notify_offset;
        txn.monitor_addr = notify_address;
        configured = queue_configured.exists(queue_id) && queue_configured[queue_id];
        enabled = queue_enabled.exists(queue_id) && queue_enabled[queue_id];
        valid = configured && enabled;
        // The queue number in the notify payload is not sufficient: a real
        // virtio-pci device also decodes the queue-specific notify offset.
        // When discovery has populated queue_notify_off, reject a kick sent
        // to another queue's doorbell even if its payload names an enabled
        // queue.  Unit callers that do not provide an address retain the
        // legacy semantic-only check.
        if (valid && (notify_address != 0) && (transport != null) &&
            (transport.cap_mgr != null) && transport.cap_mgr.notify_found &&
            (queue_id < transport.queue_notify_off.size())) begin
            bit [63:0] expected_offset;
            // notify_offset is relative to the notify capability base (the
            // observer subtracts BAR+cap_offset), so compare only the
            // queue-specific multiplier portion here.
            expected_offset = transport.queue_notify_off[queue_id] *
                              transport.cap_mgr.notify_off_multiplier;
            if (notify_offset != expected_offset) begin
                valid = 0;
                txn.vq_error_type = VQ_ERR_KICK_BEFORE_ENABLE;
                mark_error(txn, $sformatf(
                    "Notify offset mismatch queue=%0d actual=0x%0h expected=0x%0h",
                    queue_id, notify_offset, expected_offset));
            end
        end
        if ((vq_mgr != null) && valid) begin
            vq = vq_mgr.get_queue(queue_id);
            valid = (vq != null) && vq.queue_enable;
        end
        if (chk_queue_protocol && !valid) begin
            txn.vq_error_type = VQ_ERR_KICK_BEFORE_ENABLE;
            mark_error(txn, $sformatf("Notify for invalid or disabled queue: %0d", queue_id));
        end
        if (valid)
            verified_submission_queues.push_back(queue_id);
        if (protocol_vif != null) begin
            protocol_vif.stage_notify(queue_id, configured, enabled, valid);
        end
        publish_event(txn);
    endfunction

    // 兼容旧接口：直接委托 observe_status_write 做状态转换检查。
    virtual function void check_status_transition(
        input bit [7:0] old_status,
        input bit [7:0] new_status
    );
        observe_status_write(old_status, new_status);
    endfunction

    // 检查 feature 使用是否越权：attempted_use 中未在 negotiated 出现的位
    // 即为 unauthorized，非零则报违例（错误 txn 的 features 字段只留越权位）。
    // 副作用：把 attempted_use 累加进 used_features 供覆盖率/后续分析。
    virtual function void check_feature_dependency(
        input bit [63:0] negotiated,
        input bit [63:0] attempted_use
    );
        virtio_transaction txn;
        bit [63:0] unauthorized;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, '0, 0, 1);
        txn.txn_type = VIO_TXN_INIT;
        txn.features = attempted_use;
        unauthorized = attempted_use & ~negotiated;
        if (chk_feature_usage && (unauthorized != 0)) begin
            txn.features = unauthorized;
            mark_error(txn, $sformatf(
                "Feature dependency violation: used=0x%016h negotiated=0x%016h unauthorized=0x%016h",
                attempted_use, negotiated, unauthorized));
        end
        used_features |= attempted_use;
        publish_event(txn);
    endfunction

    // 兼容旧接口：按"无地址信息的 kick"语义委托 observe_queue_notify。
    virtual function void check_queue_access_valid(input int unsigned queue_id);
        observe_queue_notify(queue_id);
    endfunction

    // 外部组件（如 driver 回调）直接广播一笔事务到 txn_ap，不走事件 FIFO。
    virtual function void broadcast_txn(virtio_transaction txn);
        txn_ap.write(txn);
    endfunction

    // 把事务标记为错误后同时广播到 txn_ap 和 err_ap（副作用：置 monitor_error）。
    virtual function void broadcast_error(virtio_transaction txn);
        txn.monitor_error = 1;
        txn_ap.write(txn);
        err_ap.write(txn);
    endfunction

    // 广播一个数据面报文对象（收发包路径）到 pkt_ap，供 scoreboard 比对。
    virtual function void broadcast_pkt(uvm_object pkt);
        pkt_ap.write(pkt);
    endfunction

    // 构造一笔 monitor 事件事务：填入事件类型、地址/长度/读写方向，
    // 并从 transport 快照 BDF、IOMMU host id 与 PCIe segment id（transport
    // 未接入时全部取 0），保证下游 scoreboard 能按 function 维度归类。
    protected function virtio_transaction new_monitor_txn(
        input virtio_monitor_event_e event_kind,
        input bit [63:0] address,
        input int unsigned size_bytes,
        input bit is_write
    );
        virtio_transaction txn;
        txn = virtio_transaction::type_id::create("monitor_txn");
        txn.is_monitor_event = 1;
        txn.monitor_event = event_kind;
        txn.monitor_addr = address;
        txn.monitor_length = size_bytes;
        txn.monitor_is_write = is_write;
        txn.monitor_bdf = (transport == null) ? '0 : transport.bdf;
        txn.monitor_host_id = (transport == null) ? 0 : transport.iommu_host_id();
        txn.monitor_segment_id = (transport == null || !transport.pcie_id_valid) ?
                                 0 : transport.pcie_id.domain.segment_id;
        return txn;
    endfunction

    // 判定 status 寄存器转换是否符合 virtio 1.x 状态机：
    // - 写 0（复位）和置 FAILED 任何时候都合法；
    // - 其余转换只能增位不能丢位（new & old == old）；
    // - DRIVER_OK 需要 FEATURES_OK，FEATURES_OK 需要 DRIVER，
    //   DRIVER 需要 ACKNOWLEDGE（逐级依赖）。
    // chk_status_transition==0 时旁路所有检查恒返回 1。
    protected function bit status_transition_valid(
        input bit [7:0] old_status,
        input bit [7:0] new_status
    );
        bit valid;

        valid = 1;
        if (!chk_status_transition)
            return 1;
        if ((new_status == DEV_STATUS_RESET) || (new_status & DEV_STATUS_FAILED))
            return 1;
        if ((new_status & old_status) != old_status)
            valid = 0;
        if ((new_status & DEV_STATUS_DRIVER_OK) &&
            !(new_status & DEV_STATUS_FEATURES_OK))
            valid = 0;
        if ((new_status & DEV_STATUS_FEATURES_OK) &&
            !(new_status & DEV_STATUS_DRIVER))
            valid = 0;
        if ((new_status & DEV_STATUS_DRIVER) &&
            !(new_status & DEV_STATUS_ACKNOWLEDGE))
            valid = 0;
        return valid;
    endfunction

    // 把 status 写事件转发给 SVA 接口；protocol_vif 未接入时为无害空操作。
    protected function void drive_status_event(
        input bit [7:0] old_status,
        input bit [7:0] new_status
    );
        if (protocol_vif == null)
            return;
        protocol_vif.stage_status_write(old_status, new_status);
    endfunction

    // MSI-X config and nonqueue vectors remain observable monitor interrupts,
    // but only a vector mapped to an enabled monitor queue is a protocol
    // completion.  A verified notify selects the queue for a shared vector
    // and is consumed when present; without one, the completion is still
    // emitted so the SVA can report an unmatched queue completion.  INTx
    // additionally requires the ISR queue bit; a simultaneous config-change
    // bit does not suppress that queue completion.
    // 中文：判定中断向量是否是队列完成。优先消费匹配的已验证 notify
    //（INTx 或向量号命中该队列 vector）；没有匹配 notify 时退化为在
    // 已配置且已使能的队列里找一个向量匹配者（不消费，用于报告未匹配
    // 完成）。返回 1 时通过 queue_id 输出命中的队列号。
    protected function bit take_queue_completion(
        input int unsigned vector,
        output int unsigned queue_id
    );
        queue_id = '0;
        if ((transport == null) || (transport.notify_mgr == null))
            return 0;
        if (transport.notify_mgr.irq_mode == IRQ_INTX) begin
            if (!transport.notify_mgr.isr_status[0])
                return 0;
        end
        else begin
            if (vector == transport.notify_mgr.config_vector)
                return 0;
        end
        foreach (verified_submission_queues[index]) begin
            int unsigned pending_queue_id;
            pending_queue_id = verified_submission_queues[index];
            if (pending_queue_id >= transport.notify_mgr.queue_vectors.size())
                continue;
            if ((transport.notify_mgr.irq_mode == IRQ_INTX) ||
                (transport.notify_mgr.queue_vectors[pending_queue_id] == vector)) begin
                queue_id = pending_queue_id;
                verified_submission_queues.delete(index);
                return 1;
            end
        end
        foreach (queue_configured[candidate_queue_id]) begin
            if (!queue_configured[candidate_queue_id] ||
                !queue_enabled.exists(candidate_queue_id) ||
                !queue_enabled[candidate_queue_id] ||
                (candidate_queue_id >= transport.notify_mgr.queue_vectors.size()))
                continue;
            if ((transport.notify_mgr.irq_mode == IRQ_INTX) ||
                (transport.notify_mgr.queue_vectors[candidate_queue_id] == vector)) begin
                queue_id = candidate_queue_id;
                return 1;
            end
        end
        return 0;
    endfunction

    // 从待完成 notify 队列里剔除指定队列的所有条目（队列复位时防止
    // 复位前的 kick 被复位后的中断错误关联）。
    protected function void discard_queue_submissions(input int unsigned queue_id);
        for (int index = 0; index < verified_submission_queues.size();) begin
            if (verified_submission_queues[index] == queue_id)
                verified_submission_queues.delete(index);
            else
                index++;
        end
    endfunction

    // 把事务标记为协议错误（置 monitor_error、txn_type 改为 INJECT_ERROR）
    // 并上报 uvm_error；实际的 err_ap 广播由 publish_event 统一完成。
    protected function void mark_error(ref virtio_transaction txn, input string message);
        txn.monitor_error = 1;
        txn.txn_type = VIO_TXN_INJECT_ERROR;
        `uvm_error("VIRTIO_MON", message)
    endfunction

    // 统一出口：按事件类型写入对应 FIFO 并触发 uvm_event，然后恰好一次
    // 广播到 txn_ap；带错误标记的事务额外复制到 err_ap。
    // 所有 observe_*/check_* 路径都必须经由此函数发布，避免重复广播。
    protected function void publish_event(virtio_transaction txn);
        case (txn.monitor_event)
            VIRTIO_MON_BAR_ACCESS: begin
                bar_event_fifo.write(txn);
                bar_access_event.trigger();
            end
            VIRTIO_MON_DMA: begin
                dma_event_fifo.write(txn);
                dma_event.trigger();
            end
            VIRTIO_MON_INTERRUPT: begin
                interrupt_event_fifo.write(txn);
                interrupt_event.trigger();
            end
            VIRTIO_MON_QUEUE_STATE: begin
                queue_event_fifo.write(txn);
                queue_state_event.trigger();
            end
            default: ;
        endcase
        txn_ap.write(txn);
        if (txn.monitor_error)
            err_ap.write(txn);
    endfunction
endclass : virtio_monitor

`endif // VIRTIO_MONITOR_SV
