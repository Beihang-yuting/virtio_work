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

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

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

    virtual function void configure_dma_range(
        input bit [63:0] lo,
        input bit [63:0] hi
    );
        dma_addr_lo = lo;
        dma_addr_hi = hi;
        dma_range_configured = (lo <= hi);
    endfunction

    virtual function void reset_protocol_state();
        last_status = DEV_STATUS_RESET;
        used_features = '0;
        verified_submission_queues.delete();
        reset_all_queue_state();
    endfunction

    // Reset helpers are called by the PCIe observer for Q_RESET and by the
    // status decoder for device reset.  They deliberately clear semantic
    // state independently of the observer's decode cache.
    virtual function void reset_queue_state(input int unsigned queue_id);
        queue_configured.delete(queue_id);
        queue_enabled.delete(queue_id);
        discard_queue_submissions(queue_id);
        if (protocol_vif != null) begin
            protocol_vif.stage_queue_state(queue_id, 0, 0);
            protocol_vif.stage_queue_reset(queue_id);
        end
    endfunction

    virtual function void reset_all_queue_state();
        queue_configured.delete();
        queue_enabled.delete();
        verified_submission_queues.delete();
        if (protocol_vif != null) begin
            protocol_vif.stage_queue_state('0, 0, 0);
            protocol_vif.stage_reset_all_queues();
        end
    endfunction

    virtual function void observe_bar_access(
        input bit [63:0] address,
        input bit is_write,
        input int unsigned size_bytes,
        input bit [63:0] data,
        input int unsigned bar_offset
    );
        virtio_transaction txn;
        bit [7:0] new_status;
        bit valid;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, address, size_bytes, is_write);
        txn.txn_type = VIO_TXN_INIT;
        txn.status_val = data[7:0];
        if (is_write && (bar_offset == VIRTIO_PCI_COMMON_STATUS)) begin
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

    virtual function void observe_queue_state(
        input int unsigned queue_id,
        input bit configured,
        input bit enabled
    );
        virtio_transaction txn;

        txn = new_monitor_txn(VIRTIO_MON_QUEUE_STATE, '0, 0, 1);
        txn.txn_type = VIO_TXN_SETUP_QUEUE;
        txn.queue_id = queue_id;
        txn.queue_size = configured ? 1 : 0;
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

    virtual function void observe_queue_notify(input int unsigned queue_id);
        virtio_transaction txn;
        virtqueue_base vq;
        bit valid;
        bit configured;
        bit enabled;

        txn = new_monitor_txn(VIRTIO_MON_BAR_ACCESS, '0, 2, 1);
        txn.txn_type = VIO_TXN_ATOMIC_OP;
        txn.atomic_op = ATOMIC_KICK;
        txn.queue_id = queue_id;
        configured = queue_configured.exists(queue_id) && queue_configured[queue_id];
        enabled = queue_enabled.exists(queue_id) && queue_enabled[queue_id];
        valid = configured && enabled;
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

    virtual function void check_status_transition(
        input bit [7:0] old_status,
        input bit [7:0] new_status
    );
        observe_status_write(old_status, new_status);
    endfunction

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

    virtual function void check_queue_access_valid(input int unsigned queue_id);
        observe_queue_notify(queue_id);
    endfunction

    virtual function void broadcast_txn(virtio_transaction txn);
        txn_ap.write(txn);
    endfunction

    virtual function void broadcast_error(virtio_transaction txn);
        txn.monitor_error = 1;
        txn_ap.write(txn);
        err_ap.write(txn);
    endfunction

    virtual function void broadcast_pkt(uvm_object pkt);
        pkt_ap.write(pkt);
    endfunction

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
        return txn;
    endfunction

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

    protected function void discard_queue_submissions(input int unsigned queue_id);
        for (int index = 0; index < verified_submission_queues.size();) begin
            if (verified_submission_queues[index] == queue_id)
                verified_submission_queues.delete(index);
            else
                index++;
        end
    endfunction

    protected function void mark_error(ref virtio_transaction txn, input string message);
        txn.monitor_error = 1;
        txn.txn_type = VIO_TXN_INJECT_ERROR;
        `uvm_error("VIRTIO_MON", message)
    endfunction

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
