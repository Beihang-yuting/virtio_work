`ifndef VIRTIO_MONITOR_TEST_SV
`define VIRTIO_MONITOR_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// Records the exact transactions emitted by the passive monitor.  The test
// deliberately counts analysis-port traffic instead of relying on global UVM
// error totals, because the three negative checks are expected observations.
class virtio_monitor_txn_collector extends uvm_subscriber #(virtio_transaction);
    `uvm_component_utils(virtio_monitor_txn_collector)

    int unsigned count;
    virtio_transaction transactions[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void write(virtio_transaction t);
        count++;
        transactions.push_back(t);
    endfunction

    function void clear();
        count = 0;
        transactions.delete();
    endfunction
endclass : virtio_monitor_txn_collector

class virtio_monitor_expected_error_catcher extends uvm_report_catcher;
    int unsigned monitor_errors;

    function new(string name = "virtio_monitor_expected_error_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (((get_id() == "VIRTIO_MON") &&
              (uvm_is_match("Invalid status transition:*", get_message()) ||
               uvm_is_match("DMA access outside mapped range:*", get_message()) ||
               uvm_is_match("Notify for invalid or disabled queue:*", get_message()))) ||
             ((get_id() == "VQ_MGR") &&
              uvm_is_match("get_queue: queue_id=* not found", get_message())))) begin
            monitor_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_expected_error_catcher

// The production-wiring checks below are intentionally scoped to the two
// expected SVA diagnostics.  A different assertion or an unrelated UVM error
// must remain visible to the global report server.
class virtio_monitor_protocol_sva_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_monitor_protocol_sva_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "VIRTIO_PROTOCOL_SVA") &&
            (uvm_is_match("*completion observed without a pending submission*",
                          get_message()) ||
             uvm_is_match("*status write cleared a previously set bit without reset*",
                          get_message()))) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_protocol_sva_catcher

class virtio_monitor_test extends uvm_test;
    `uvm_component_utils(virtio_monitor_test)

    virtio_monitor                       mon;
    virtio_pcie_observer_adapter          observer;
    virtio_monitor_txn_collector          txn_collector;
    virtio_monitor_txn_collector          err_collector;
    virtio_monitor_expected_error_catcher expected_error_catcher;
    virtual virtio_protocol_event_if      protocol_vif;

    localparam bit [63:0] COMMON_BASE = 64'h0000_0000_8000_0000;
    localparam bit [63:0] NOTIFY_BASE = 64'h0000_0000_8000_2000;
    localparam bit [15:0] OBSERVER_BDF = 16'h0008;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mon = virtio_monitor::type_id::create("mon", this);
        observer = virtio_pcie_observer_adapter::type_id::create("observer", this);
        txn_collector = virtio_monitor_txn_collector::type_id::create(
            "txn_collector", this);
        err_collector = virtio_monitor_txn_collector::type_id::create(
            "err_collector", this);
        if (!uvm_config_db#(virtual virtio_protocol_event_if)::get(
                null, "uvm_test_top", "protocol_event_vif_0", protocol_vif)) begin
            `uvm_fatal("MON_TEST", "virtio_protocol_event_if was not configured")
        end
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        mon.txn_ap.connect(txn_collector.analysis_export);
        mon.err_ap.connect(err_collector.analysis_export);
        mon.protocol_vif = protocol_vif;
        observer.monitor = mon;
        observer.common_cfg_base = COMMON_BASE;
        observer.common_cfg_limit = COMMON_BASE + 12'hfff;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        @(posedge protocol_vif.rst_n);
        @(posedge protocol_vif.clk);

        test_illegal_decoded_events();
        test_legal_decoded_status_trace();
        test_protocol_sva_production_wiring();
        test_adapter_tlp_notify_classification();
        test_adapter_message_classification();
        test_adapter_queue_reset_correlation();
        test_adapter_q_select_read_preserves_queue_selection();

        `uvm_info("MON_TEST", "Passive monitor and SVA tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    protected function pcie_tl_mem_tlp make_status_write(bit [7:0] status);
        pcie_tl_mem_tlp tlp;
        tlp = pcie_tl_mem_tlp::type_id::create("status_write");
        tlp.kind = TLP_MEM_WR;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.addr = COMMON_BASE + VIRTIO_PCI_COMMON_STATUS;
        tlp.length = 10'd1;
        tlp.payload = new[4];
        tlp.payload[0] = status;
        tlp.payload[1] = '0;
        tlp.payload[2] = '0;
        tlp.payload[3] = '0;
        return tlp;
    endfunction

    protected function pcie_tl_mem_tlp make_common_write(
        input bit [11:0] offset,
        input bit [31:0] data
    );
        pcie_tl_mem_tlp tlp;
        tlp = pcie_tl_mem_tlp::type_id::create("common_write");
        tlp.kind = TLP_MEM_WR;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.addr = COMMON_BASE + offset;
        tlp.length = 10'd1;
        tlp.payload = new[4];
        for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
            tlp.payload[byte_index] = data[byte_index * 8 +: 8];
        return tlp;
    endfunction

    protected function pcie_tl_mem_tlp make_common_read(
        input bit [11:0] offset
    );
        pcie_tl_mem_tlp tlp;
        tlp = pcie_tl_mem_tlp::type_id::create("common_read");
        tlp.kind = TLP_MEM_RD;
        tlp.fmt = FMT_3DW_NO_DATA;
        tlp.type_f = TLP_TYPE_MEM_RD;
        tlp.addr = COMMON_BASE + offset;
        tlp.length = 10'd1;
        tlp.payload = new[0];
        return tlp;
    endfunction

    protected function pcie_tl_mem_tlp make_notify_tlp(
        input tlp_kind_e kind,
        input int unsigned queue_id
    );
        pcie_tl_mem_tlp tlp;
        tlp = pcie_tl_mem_tlp::type_id::create("notify_tlp");
        tlp.kind = kind;
        tlp.fmt = (kind == TLP_MEM_WR) ? FMT_3DW_WITH_DATA : FMT_3DW_NO_DATA;
        tlp.type_f = (kind == TLP_MEM_WR) ? TLP_TYPE_MEM_WR : TLP_TYPE_MEM_RD;
        tlp.addr = NOTIFY_BASE;
        tlp.length = 10'd1;
        if (kind == TLP_MEM_WR) begin
            tlp.payload = new[4];
            tlp.payload[0] = queue_id[7:0];
            tlp.payload[1] = queue_id[15:8];
            tlp.payload[2] = '0;
            tlp.payload[3] = '0;
        end
        else begin
            tlp.payload = new[0];
        end
        return tlp;
    endfunction

    protected function pcie_tl_mem_tlp make_msi_tlp(input int unsigned vector);
        pcie_tl_mem_tlp tlp;
        tlp = pcie_tl_mem_tlp::type_id::create("msi_tlp");
        tlp.kind = TLP_MEM_WR;
        tlp.fmt = FMT_3DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.requester_id = OBSERVER_BDF;
        tlp.addr = 64'h0000_0000_fee0_0000;
        tlp.length = 10'd1;
        tlp.payload = new[4];
        tlp.payload[0] = vector[7:0];
        tlp.payload[1] = vector[15:8];
        tlp.payload[2] = '0;
        tlp.payload[3] = '0;
        return tlp;
    endfunction

    protected function pcie_tl_msg_tlp make_message_tlp(
        input msg_code_e code,
        input tlp_kind_e kind = TLP_MSG
    );
        pcie_tl_msg_tlp tlp;
        tlp = pcie_tl_msg_tlp::type_id::create("message_tlp");
        tlp.kind = kind;
        tlp.fmt = (kind == TLP_MSGD) ? FMT_4DW_WITH_DATA : FMT_4DW_NO_DATA;
        tlp.type_f = TLP_TYPE_MSG_RC;
        tlp.requester_id = OBSERVER_BDF;
        tlp.msg_code = code;
        if (kind == TLP_MSGD) begin
            tlp.length = 10'd1;
            tlp.payload = new[4];
            tlp.payload[0] = '0;
            tlp.payload[1] = '0;
            tlp.payload[2] = '0;
            tlp.payload[3] = '0;
        end
        else begin
            tlp.length = '0;
            tlp.payload = new[0];
        end
        return tlp;
    endfunction

    protected task configure_adapter_trace(
        input interrupt_mode_e irq_mode,
        input int unsigned queue_vector_slots
    );
        mon.reset_protocol_state();
        mon.vq_mgr = virtqueue_manager::type_id::create("adapter_trace_vq_mgr");
        mon.transport = virtio_pci_transport::type_id::create("adapter_trace_transport");
        mon.transport.notify_mgr.irq_mode = irq_mode;
        mon.transport.notify_mgr.queue_vectors = new[queue_vector_slots];
        // Function-bound observers refresh these ranges on every TLP.  Model
        // the discovered BAR0 capabilities instead of relying on a temporary
        // hand-set observer window that refresh_capability_ranges() replaces.
        mon.transport.bar.bar_base[0] = COMMON_BASE;
        mon.transport.bar.bar_size[0] = 64'h0000_0000_0000_4000;
        mon.transport.cap_mgr.common_cfg_found = 1;
        mon.transport.cap_mgr.common_cfg_cap.bar = 0;
        mon.transport.cap_mgr.common_cfg_cap.offset = 32'h0000_0000;
        mon.transport.cap_mgr.common_cfg_cap.length = 32'h0000_1000;
        mon.transport.cap_mgr.notify_found = 1;
        mon.transport.cap_mgr.notify_cap.bar = 0;
        mon.transport.cap_mgr.notify_cap.offset = NOTIFY_BASE - COMMON_BASE;
        mon.transport.cap_mgr.notify_cap.length = 32'h0000_1000;
        observer.monitor = mon;
        observer.transport = mon.transport;
        observer.function_bdf = OBSERVER_BDF;
        observer.function_bound = 1;
        observer.common_cfg_base = COMMON_BASE;
        observer.common_cfg_limit = COMMON_BASE + 12'hfff;
        observer.notify_cfg_base = NOTIFY_BASE;
        observer.notify_cfg_limit = NOTIFY_BASE + 12'hfff;
        protocol_vif.assertions_enable = 0;
        repeat (4) @(negedge protocol_vif.clk);
        observer.write(make_status_write(DEV_STATUS_RESET));
        repeat (4) @(negedge protocol_vif.clk);
        protocol_vif.protocol_error_count = 0;
        protocol_vif.assertions_enable = 1;
    endtask

    protected task configure_adapter_queue(input int unsigned queue_id);
        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_SELECT, queue_id));
        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_SIZE, 32'd8));
        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_ENABLE, 32'd1));
    endtask

    protected task write_status_and_advance(bit [7:0] status);
        observer.write(make_status_write(status));
        @(posedge protocol_vif.clk);
    endtask

    // The required negative trace is intentionally decoded at the monitor
    // boundary: status BAR traffic, DMA traffic, and a queue notify are each
    // represented once and must produce exactly three monitor errors.
    protected task test_illegal_decoded_events();
        pcie_tl_mem_tlp status_tlp;

        txn_collector.clear();
        err_collector.clear();
        mon.reset_protocol_state();
        mon.configure_dma_range(64'h1000, 64'h1fff);
        protocol_vif.assertions_enable = 0;
        expected_error_catcher = new();
        uvm_report_cb::add(null, expected_error_catcher);

        observer.write(make_status_write(DEV_STATUS_DRIVER_OK));
        mon.observe_dma(64'h3000, 64, 1'b1);
        mon.observe_queue_notify(99);

        assert(expected_error_catcher.monitor_errors == 3)
            else `uvm_fatal("MON_TEST", $sformatf(
                "expected exactly three monitor errors, saw %0d",
                expected_error_catcher.monitor_errors))
        assert(err_collector.count == 3)
            else `uvm_fatal("MON_TEST", $sformatf(
                "expected three error transactions, saw %0d", err_collector.count))
        assert(txn_collector.count == 3)
            else `uvm_fatal("MON_TEST", $sformatf(
                "expected one broadcast transaction per illegal event, saw %0d",
                txn_collector.count))

        uvm_report_cb::delete(null, expected_error_catcher);
        `uvm_info("MON_TEST", "Illegal decoded events produced exactly three monitor errors", UVM_LOW)
    endtask

    // A legal reset-to-driver-ready trace must produce one populated monitor
    // transaction per decoded BAR event and never trip the protocol checker.
    protected task test_legal_decoded_status_trace();
        // Drain every staged protocol pulse emitted by the negative trace
        // while assertions remain disabled.  A staged event is intentionally
        // released at negedge and sampled at the following posedge, so one
        // posedge no longer constitutes a full flush boundary.
        repeat (4) @(negedge protocol_vif.clk);
        txn_collector.clear();
        err_collector.clear();
        mon.reset_protocol_state();
        protocol_vif.protocol_error_count = 0;
        protocol_vif.assertions_enable = 1;

        write_status_and_advance(DEV_STATUS_RESET);
        write_status_and_advance(DEV_STATUS_ACKNOWLEDGE);
        write_status_and_advance(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        write_status_and_advance(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER |
                                 DEV_STATUS_FEATURES_OK);
        write_status_and_advance(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER |
                                 DEV_STATUS_FEATURES_OK | DEV_STATUS_DRIVER_OK);

        assert(protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("MON_TEST", $sformatf(
                "legal status trace produced %0d protocol errors",
                protocol_vif.protocol_error_count))
        assert(err_collector.count == 0)
            else `uvm_fatal("MON_TEST", $sformatf(
                "legal status trace produced %0d monitor errors", err_collector.count))
        assert(txn_collector.count == 5)
            else `uvm_fatal("MON_TEST", $sformatf(
                "expected five broadcast transactions, saw %0d", txn_collector.count))
        foreach (txn_collector.transactions[i]) begin
            assert(txn_collector.transactions[i].is_monitor_event)
                else `uvm_fatal("MON_TEST", "monitor broadcast was not populated")
            assert(txn_collector.transactions[i].monitor_event == VIRTIO_MON_BAR_ACCESS)
                else `uvm_fatal("MON_TEST", "status write was not classified as BAR access")
        end
        `uvm_info("MON_TEST", "Legal decoded trace broadcast one populated transaction per event", UVM_LOW)
    endtask

    // This exercises the production monitor rather than directly poking the
    // protocol VIF.  Queue state is intentionally present in the monitor
    // while missing from vq_mgr: it is therefore a raw notify and a monitor
    // error, but it is not a submitted request that can justify a completion.
    // Config interrupts likewise remain monitor events without becoming queue
    // completions.  Finally a real queue/vector pair proves the positive path.
    protected task test_protocol_sva_production_wiring();
        virtqueue_base vq;
        int unsigned sva_errors_before;
        int unsigned monitor_errors_before;
        virtio_monitor_protocol_sva_catcher sva_catcher;

        // The last status write in the preceding lifecycle trace can still
        // be queued at its monitor boundary.  Isolate this trace before its
        // scoped catcher starts accounting for production SVA reports.
        protocol_vif.assertions_enable = 0;
        repeat (3) @(negedge protocol_vif.clk);
        protocol_vif.assertions_enable = 1;
        protocol_vif.protocol_error_count = 0;
        mon.reset_protocol_state();
        mon.vq_mgr = virtqueue_manager::type_id::create("monitor_wiring_vq_mgr");
        mon.transport = virtio_pci_transport::type_id::create("monitor_wiring_transport");
        mon.transport.notify_mgr.config_vector = 3;
        mon.transport.notify_mgr.queue_vectors = new[8];
        mon.transport.notify_mgr.queue_vectors[5] = 7;
        mon.transport.notify_mgr.queue_vectors[7] = 11;

        expected_error_catcher = new("monitor_wiring_errors");
        sva_catcher = new("monitor_wiring_sva_errors");
        uvm_report_cb::add(null, expected_error_catcher);
        uvm_report_cb::add(null, sva_catcher);

        // Clear both checker history and pulses before starting the trace.
        @(negedge protocol_vif.clk);
        mon.observe_status_write(DEV_STATUS_RESET, DEV_STATUS_RESET);
        @(negedge protocol_vif.clk);

        // A notify rejected by vq_mgr must not create a pending submission.
        // Its matching queue-vector interrupt is consequently an unmatched
        // completion and must produce exactly one scoped SVA report.
        sva_errors_before = sva_catcher.caught_count;
        monitor_errors_before = expected_error_catcher.monitor_errors;
        @(negedge protocol_vif.clk);
        mon.observe_queue_state(5, 1'b1, 1'b1);
        mon.observe_queue_notify(5);
        @(negedge protocol_vif.clk);
        mon.observe_interrupt(7);
        @(negedge protocol_vif.clk);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before + 1)
            else `uvm_error("MON_TEST", $sformatf(
                "vq_mgr-rejected notify must leave completion unmatched; SVA reports %0d -> %0d",
                sva_errors_before, sva_catcher.caught_count))
        assert(expected_error_catcher.monitor_errors == monitor_errors_before + 2)
            else `uvm_error("MON_TEST", $sformatf(
                "rejected notify must report only VQ_MGR and monitor errors; saw %0d -> %0d",
                monitor_errors_before, expected_error_catcher.monitor_errors))

        // A configuration vector is a monitor interrupt but is not a queue
        // completion.  It must not consume or require a submitted request.
        sva_errors_before = sva_catcher.caught_count;
        @(negedge protocol_vif.clk);
        mon.observe_interrupt(mon.transport.notify_mgr.config_vector);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before)
            else `uvm_error("MON_TEST", $sformatf(
                "config interrupt generated %0d unexpected completion SVA reports",
                sva_catcher.caught_count - sva_errors_before))

        // The positive path needs both monitor state and a queue manager
        // object whose queue has been enabled.  Its mapped vector completes
        // the one verified submission and leaves the counter at zero.
        vq = mon.vq_mgr.create_queue(7, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        sva_errors_before = sva_catcher.caught_count;
        @(negedge protocol_vif.clk);
        mon.observe_queue_state(7, 1'b1, 1'b1);
        mon.observe_queue_notify(7);
        @(negedge protocol_vif.clk);
        mon.observe_interrupt(11);
        @(negedge protocol_vif.clk);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before)
            else `uvm_error("MON_TEST", "valid queue notify/vector pair produced an SVA report")
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST", $sformatf(
                "valid queue completion left %0d submissions outstanding",
                protocol_vif.outstanding_submission_count))

        // INTx ISR status can report a queue completion and a config change
        // together.  Bit 0 is the queue-completion indication, so bit 1
        // must not suppress consumption of this verified submission.
        vq = mon.vq_mgr.create_queue(6, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        mon.transport.notify_mgr.irq_mode = IRQ_INTX;
        mon.transport.notify_mgr.isr_status = 8'b0000_0011;
        sva_errors_before = sva_catcher.caught_count;
        @(negedge protocol_vif.clk);
        mon.observe_queue_state(6, 1'b1, 1'b1);
        mon.observe_queue_notify(6);
        @(negedge protocol_vif.clk);
        mon.observe_interrupt(0);
        @(negedge protocol_vif.clk);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before)
            else `uvm_error("MON_TEST",
                "combined INTx queue/config ISR produced an SVA report")
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST", $sformatf(
                "combined INTx queue/config ISR left %0d verified submissions outstanding",
                protocol_vif.outstanding_submission_count))

        // A monitor callback on a sampling edge is staged for exactly the
        // following checker edge.  This guards the production NBA race while
        // retaining direct VIF driving for the protocol-only test.
        sva_errors_before = sva_catcher.caught_count;
        @(posedge protocol_vif.clk);
        mon.observe_status_write(DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER,
                                 DEV_STATUS_ACKNOWLEDGE);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before)
            else `uvm_error("MON_TEST", "posedge monitor event was sampled on its staging edge")
        @(posedge protocol_vif.clk);
        @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before + 1)
            else `uvm_error("MON_TEST", $sformatf(
                "posedge monitor status event must produce exactly one deferred SVA report; saw %0d -> %0d",
                sva_errors_before, sva_catcher.caught_count))

        uvm_report_cb::delete(null, sva_catcher);
        uvm_report_cb::delete(null, expected_error_catcher);
    endtask

    // Exercise the observer from actual Memory Request TLPs.  A notify
    // aperture read must not even stage a raw notify; a posted write becomes
    // a verified submission only after monitor and vq_mgr validation.
    protected task test_adapter_tlp_notify_classification();
        virtqueue_base vq;
        int unsigned monitor_errors_before;

        configure_adapter_trace(IRQ_MSIX_PER_QUEUE, 1);
        configure_adapter_queue(0);
        repeat (4) @(negedge protocol_vif.clk);

        observer.write(make_notify_tlp(TLP_MEM_RD, 0));
        assert(protocol_vif.staged_pulses.size() == 0)
            else `uvm_error("MON_TEST",
                "notify aperture Memory Read staged a raw protocol notify")

        expected_error_catcher = new("adapter_notify_errors");
        uvm_report_cb::add(null, expected_error_catcher);
        monitor_errors_before = expected_error_catcher.monitor_errors;
        observer.write(make_notify_tlp(TLP_MEM_WR, 0));
        repeat (3) @(negedge protocol_vif.clk);
        assert(expected_error_catcher.monitor_errors == monitor_errors_before + 2)
            else `uvm_error("MON_TEST",
                "unbacked notify write did not require final vq_mgr validation")
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST",
                "vq_mgr-rejected notify write created a verified submission")

        vq = mon.vq_mgr.create_queue(0, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        observer.write(make_notify_tlp(TLP_MEM_WR, 0));
        repeat (3) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 1)
            else `uvm_error("MON_TEST",
                "validated notify write failed to create one verified submission")
        uvm_report_cb::delete(null, expected_error_catcher);
    endtask

    // Each item is a genuine pcie_tl_msg_tlp from the bound function.  The
    // non-IRQ codes deliberately equal configured MSI-X vectors, so accepting
    // any Message TLP as an interrupt would consume these submissions.
    protected task test_adapter_message_classification();
        virtqueue_base vq;
        int unsigned queue_ids[$];
        msg_code_e non_irq_codes[$];
        bit [7:0] cleared_isr_status;
        int unsigned txn_count_before;

        configure_adapter_trace(IRQ_MSIX_PER_QUEUE, 64);
        queue_ids = {4, 5, 6, 7, 8};
        non_irq_codes = {MSG_LTR, MSG_PM_PME, MSG_ERR_COR, MSG_ERR_NONFATAL,
                         MSG_ERR_FATAL};
        foreach (queue_ids[index]) begin
            mon.transport.notify_mgr.queue_vectors[queue_ids[index]] =
                int'(non_irq_codes[index]);
            vq = mon.vq_mgr.create_queue(queue_ids[index], 8, VQ_SPLIT);
            vq.queue_enable = 1;
            configure_adapter_queue(queue_ids[index]);
            observer.write(make_notify_tlp(TLP_MEM_WR, queue_ids[index]));
        end
        repeat (10) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == queue_ids.size())
            else `uvm_fatal("MON_TEST", "message classification setup lost submissions")

        foreach (non_irq_codes[index])
            observer.write(make_message_tlp(non_irq_codes[index]));
        repeat (10) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == queue_ids.size())
            else `uvm_error("MON_TEST",
                "non-IRQ Message TLP with a queue-vector value consumed a submission")

        // A data-bearing message with an ASSERT code is not an INTx assert
        // form.  It must also remain outside the completion path.
        mon.transport.notify_mgr.queue_vectors[9] = int'(MSG_ASSERT_INTA);
        vq = mon.vq_mgr.create_queue(9, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        configure_adapter_queue(9);
        observer.write(make_notify_tlp(TLP_MEM_WR, 9));
        repeat (3) @(negedge protocol_vif.clk);
        observer.write(make_message_tlp(MSG_ASSERT_INTA, TLP_MSGD));
        repeat (3) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == queue_ids.size() + 1)
            else `uvm_error("MON_TEST",
                "data-bearing ASSERT message was accepted as an INTx assertion")

        // A no-data, RC-routed INTx assert is the one genuine Message form.
        configure_adapter_trace(IRQ_INTX, 4);
        mon.transport.notify_mgr.on_config_change_interrupt();
        vq = mon.vq_mgr.create_queue(3, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        configure_adapter_queue(3);
        observer.write(make_notify_tlp(TLP_MEM_WR, 3));
        repeat (3) @(negedge protocol_vif.clk);
        observer.write(make_message_tlp(MSG_ASSERT_INTA));
        repeat (3) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST",
                "actual INTx queue-plus-config assertion did not complete its queue")
        assert(mon.transport.notify_mgr.isr_status == 8'b0000_0011)
            else `uvm_error("MON_TEST",
                "actual INTx assertion did not establish the queue ISR state")

        // Do not preload ISR status: retain the state made by the preceding
        // real assert, submit another queue, then prove DEASSERT cannot turn
        // that stale line state into a second completion.
        vq = mon.vq_mgr.create_queue(2, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        configure_adapter_queue(2);
        observer.write(make_notify_tlp(TLP_MEM_WR, 2));
        repeat (3) @(negedge protocol_vif.clk);
        observer.write(make_message_tlp(MSG_DEASSERT_INTA));
        repeat (3) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 1)
            else `uvm_error("MON_TEST", "INTx DEASSERT completed a queue")

        // Config-only INTx state is established through the notification
        // manager, not by preloading isr_status.  A genuine Message TLP that
        // is not an INTx ASSERT must neither set ISR bit 0 nor reach the
        // monitor's interrupt-candidate path.
        mon.transport.notify_mgr.read_and_clear_isr(cleared_isr_status);
        assert(cleared_isr_status == 8'b0000_0011)
            else `uvm_error("MON_TEST", "INTx assertion did not preserve queue-plus-config ISR state")
        mon.transport.notify_mgr.on_config_change_interrupt();
        txn_count_before = txn_collector.count;
        observer.write(make_message_tlp(MSG_PM_PME));
        repeat (3) @(negedge protocol_vif.clk);
        assert(mon.transport.notify_mgr.isr_status == 8'b0000_0010)
            else `uvm_error("MON_TEST", "INTx config-only Message TLP set the queue ISR bit")
        assert(protocol_vif.outstanding_submission_count == 1)
            else `uvm_error("MON_TEST", "INTx config-only Message TLP completed a queue")
        assert(txn_collector.count == txn_count_before)
            else `uvm_error("MON_TEST", "INTx config-only Message TLP became an interrupt candidate")
    endtask

    // Q_RESET must discard only its own protocol credit.  The subsequent
    // MSI completion resolves to enabled Q6 through the adapter, so a global
    // counter would incorrectly treat the prior Q5 notify as a valid match.
    protected task test_adapter_queue_reset_correlation();
        virtqueue_base vq;
        int unsigned sva_errors_before;
        virtio_monitor_protocol_sva_catcher sva_catcher;

        configure_adapter_trace(IRQ_MSIX_PER_QUEUE, 8);
        mon.transport.notify_mgr.queue_vectors[5] = 17;
        mon.transport.notify_mgr.queue_vectors[6] = 18;
        vq = mon.vq_mgr.create_queue(5, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        configure_adapter_queue(5);
        configure_adapter_queue(6);
        observer.write(make_notify_tlp(TLP_MEM_WR, 5));
        repeat (4) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 1)
            else `uvm_fatal("MON_TEST", "Q5 setup did not create one submission")

        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_SELECT, 32'd5));
        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_RESET, 32'd1));
        repeat (4) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST", "Q_RESET did not clear Q5 protocol credit")

        sva_catcher = new("queue_reset_sva_errors");
        uvm_report_cb::add(null, sva_catcher);
        sva_errors_before = sva_catcher.caught_count;
        observer.write(make_msi_tlp(18));
        repeat (4) @(negedge protocol_vif.clk);
        assert(sva_catcher.caught_count == sva_errors_before + 1)
            else `uvm_error("MON_TEST",
                "Q6 completion was permitted by a reset Q5 submission")
        uvm_report_cb::delete(null, sva_catcher);
    endtask

    // A Q_SELECT read has no request payload.  It must not replace the
    // selected Q5 with zero before this Q_RESET is decoded.
    protected task test_adapter_q_select_read_preserves_queue_selection();
        virtqueue_base vq;

        configure_adapter_trace(IRQ_MSIX_PER_QUEUE, 8);
        vq = mon.vq_mgr.create_queue(5, 8, VQ_SPLIT);
        vq.queue_enable = 1;
        configure_adapter_queue(5);
        observer.write(make_notify_tlp(TLP_MEM_WR, 5));
        repeat (4) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 1)
            else `uvm_fatal("MON_TEST", "Q5 setup did not create one submission")

        observer.write(make_common_read(VIRTIO_PCI_COMMON_Q_SELECT));
        observer.write(make_common_write(VIRTIO_PCI_COMMON_Q_RESET, 32'd1));
        repeat (4) @(negedge protocol_vif.clk);
        assert(protocol_vif.outstanding_submission_count == 0)
            else `uvm_error("MON_TEST",
                "Q_SELECT read redirected Q5 reset to queue zero")
    endtask
endclass : virtio_monitor_test

`endif // VIRTIO_MONITOR_TEST_SV
