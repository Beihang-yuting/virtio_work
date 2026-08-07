`ifndef VIRTIO_MONITOR_ROUTING_TEST_SV
`define VIRTIO_MONITOR_ROUTING_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// Captures the semantic events emitted by an individual virtio function.
// Keeping one collector per function makes the routing contract observable:
// a shared PCIe monitor stream must reach exactly its addressed function.
class virtio_monitor_routing_collector extends uvm_subscriber #(virtio_transaction);
    `uvm_component_utils(virtio_monitor_routing_collector)

    int unsigned count;
    virtio_transaction transactions[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void write(virtio_transaction t);
        count++;
        transactions.push_back(t);
    endfunction
endclass : virtio_monitor_routing_collector

// Queue-reset rejection is a required negative observation.  Catch only the
// expected semantic monitor reports so the regression can prove both resets
// reject a subsequent notification without leaving an unhandled UVM_ERROR.
class virtio_monitor_routing_error_catcher extends uvm_report_catcher;
    int unsigned monitor_errors;

    function new(string name = "virtio_monitor_routing_error_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_id() == "VIRTIO_MON") && (get_severity() == UVM_ERROR)) begin
            monitor_errors++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_error_catcher

// The PF/VF isolation trace deliberately violates only the VF DRIVER_OK
// dependency.  Keep that expected SVA diagnostic scoped to the injection so
// any other protocol error remains visible to the global report server.
class virtio_monitor_routing_protocol_sva_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_monitor_routing_protocol_sva_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "VIRTIO_PROTOCOL_SVA") &&
            (get_message() == "DRIVER_OK observed before FEATURES_OK")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_protocol_sva_catcher

// Queue-reset negative traffic intentionally generates only the disabled
// queue-notify SVA.  Keep that expected diagnostic scoped to this subtest.
class virtio_monitor_routing_disabled_notify_sva_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_monitor_routing_disabled_notify_sva_catcher");
        super.new(name);
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "VIRTIO_PROTOCOL_SVA") &&
            (get_message() == "notify observed for a disabled queue")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_monitor_routing_disabled_notify_sva_catcher

// Exercises the public virtio_net_env PCIe binding with two Fabric functions.
// A TLP emitted on the external endpoint monitor is addressed only by the PF
// BAR range; the VF must neither observe it nor classify it as DMA.
class virtio_monitor_routing_test extends uvm_test;
    `uvm_component_utils(virtio_monitor_routing_test)

    pcie_tl_env                    pcie_env;
    virtio_net_env                 virtio_env;
    pcie_tl_env_config             pcie_cfg;
    virtio_net_env_config          virtio_cfg;
    virtio_monitor_routing_collector pf_collector;
    virtio_monitor_routing_collector vf_collector;

    localparam bit [63:0] PF_BAR0_BASE = 64'h0000_0000_C100_0000;
    localparam bit [63:0] VF_BAR0_BASE = 64'h0000_0000_C200_0000;
    localparam bit [63:0] BAR0_SIZE    = 64'h0000_0000_0001_0000;
    localparam bit [31:0] COMMON_OFF   = 32'h0000_0100;
    localparam bit [31:0] COMMON_LEN   = 32'h0000_0040;
    localparam bit [31:0] NOTIFY_OFF   = 32'h0000_0200;
    localparam bit [31:0] NOTIFY_LEN   = 32'h0000_0040;
    localparam bit [63:0] PF_MSIX_ADDR = 64'h0000_0000_FEE0_0450;
    localparam bit [31:0] PF_MSIX_DATA = 32'h0000_0045;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        pcie_cfg = pcie_tl_env_config::type_id::create("pcie_cfg");
        pcie_cfg.if_mode = TLM_MODE;
        pcie_cfg.rc_agent_enable = 1;
        pcie_cfg.ep_agent_enable = 1;
        pcie_cfg.rc_is_active = UVM_ACTIVE;
        pcie_cfg.ep_is_active = UVM_ACTIVE;
        pcie_cfg.ep_auto_response = 1;
        pcie_cfg.infinite_credit = 1;
        pcie_cfg.scb_enable = 0;
        pcie_cfg.cov_enable = 0;
        uvm_config_db#(pcie_tl_env_config)::set(this, "pcie_env", "cfg", pcie_cfg);
        pcie_env = pcie_tl_env::type_id::create("pcie_env", this);

        virtio_cfg = virtio_net_env_config::type_id::create("virtio_cfg");
        virtio_cfg.num_hosts = 1;
        virtio_cfg.num_pfs_per_host = new[1];
        virtio_cfg.num_pfs_per_host[0] = 1;
        virtio_cfg.num_vfs_per_pf = new[1];
        virtio_cfg.num_vfs_per_pf[0] = new[1];
        virtio_cfg.num_vfs_per_pf[0][0] = 1;
        virtio_cfg.pf_bdf = 16'h0100;
        virtio_cfg.scb_enable = 1;
        virtio_cfg.cov_enable = 1;
        uvm_config_db#(virtio_net_env_config)::set(
            this, "virtio_env", "cfg", virtio_cfg);
        virtio_env = virtio_net_env::type_id::create("virtio_env", this);

        pf_collector = virtio_monitor_routing_collector::type_id::create(
            "pf_collector", this);
        vf_collector = virtio_monitor_routing_collector::type_id::create(
            "vf_collector", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);

        // Public binding is responsible for configuring every PF/VF observer
        // and wiring both directions of the external PCIe monitor stream.
        virtio_env.bind_pcie(pcie_env.rc_agent.sequencer, null,
            pcie_env.rc_agent.monitor, pcie_env.ep_agent.monitor);

        virtio_env.pf_instances[0].pf_function.driver_agent.monitor.txn_ap.connect(
            pf_collector.analysis_export);
        virtio_env.pf_instances[0].vf_functions[0].driver_agent.monitor.txn_ap.connect(
            vf_collector.analysis_export);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_function_instance pf;
        virtio_function_instance vf;
        pcie_tl_mem_tlp tlp;

        phase.raise_objection(this);
        @(posedge virtio_tb_top.rst_n);
        @(posedge virtio_tb_top.clk);

        pf = virtio_env.pf_instances[0].pf_function;
        vf = virtio_env.pf_instances[0].vf_functions[0];
        if ($test$plusargs("ROUTING_BIND_ONLY")) begin
            assert((pf.driver_agent.ops != null) &&
                   (pf.driver_agent.fsm != null) &&
                   (vf.driver_agent.ops != null) &&
                   (vf.driver_agent.fsm != null))
                else `uvm_fatal("ROUTING_TEST",
                    "no-adapter binding left an active function unbound")
            phase.drop_objection(this);
            return;
        end
        configure_function_ranges(pf, PF_BAR0_BASE);
        configure_function_ranges(vf, VF_BAR0_BASE);
        virtio_env.cov.enable_all();

        tlp = make_pf_status_write(pf);
        // This is the production observation boundary, not a direct call into
        // a virtio adapter: the public bind_pcie() connection must carry it.
        pcie_env.ep_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == 1)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "PF should observe exactly one addressed BAR event, saw %0d",
                pf_collector.count))
        assert(pf_collector.transactions[0].is_monitor_event &&
               pf_collector.transactions[0].monitor_event == VIRTIO_MON_BAR_ACCESS)
            else `uvm_fatal("ROUTING_TEST", "PF event was not a populated BAR access")
        assert(pf_collector.transactions[0].monitor_addr == tlp.addr)
            else `uvm_fatal("ROUTING_TEST", "PF event address differs from monitor TLP")
        assert(vf_collector.count == 0)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "VF observed another function's MMIO (%0d events)", vf_collector.count))
        assert(virtio_env.scb.monitor_event_count == 1)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "shared scoreboard should receive exactly one monitor event, saw %0d",
                virtio_env.scb.monitor_event_count))
        assert(virtio_env.cov.cg_lifecycle.get_inst_coverage() > 0.0)
            else `uvm_fatal("ROUTING_TEST",
                "shared coverage did not receive the routed lifecycle event")

        test_default_msix_memory_write(pf, vf);
        test_real_msix_memory_write(pf, vf);
        test_protocol_vif_isolation(pf, vf);
        test_queue_and_device_resets(pf);

        `uvm_info("ROUTING_TEST", "External PCIe monitor routing PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    protected function void configure_function_ranges(
        input virtio_function_instance function_instance,
        input bit [63:0] bar_base
    );
        function_instance.transport.bar.bar_base[0] = bar_base;
        function_instance.transport.bar.bar_size[0] = BAR0_SIZE;
        function_instance.transport.cap_mgr.common_cfg_found = 1;
        function_instance.transport.cap_mgr.common_cfg_cap.bar = 0;
        function_instance.transport.cap_mgr.common_cfg_cap.offset = COMMON_OFF;
        function_instance.transport.cap_mgr.common_cfg_cap.length = COMMON_LEN;
        function_instance.transport.cap_mgr.notify_found = 1;
        function_instance.transport.cap_mgr.notify_cap.bar = 0;
        function_instance.transport.cap_mgr.notify_cap.offset = NOTIFY_OFF;
        function_instance.transport.cap_mgr.notify_cap.length = NOTIFY_LEN;
    endfunction

    // MSI/MSI-X delivery is an endpoint Memory Write to a host APIC address,
    // not necessarily a PCIe Message TLP.  requester_id is deliberately zero
    // here because monitor implementations commonly omit it for this path.
    // Normal MSI-X setup must reserve a distinct address/data identity per
    // Fabric function; otherwise an APIC write for one function broadcasts to
    // every observer with the same default table entry.
    protected task test_default_msix_memory_write(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        pcie_tl_mem_tlp tlp;
        int unsigned pf_count_before;
        int unsigned vf_count_before;

        pf.transport.notify_mgr.setup_msix(1, 4, 32'h0);
        vf.transport.notify_mgr.setup_msix(1, 4, 32'h0);
        assert((pf.transport.notify_mgr.msix_table[0].msg_addr !=
                vf.transport.notify_mgr.msix_table[0].msg_addr) ||
               (pf.transport.notify_mgr.msix_table[0].msg_data !=
                vf.transport.notify_mgr.msix_table[0].msg_data))
            else `uvm_fatal("ROUTING_TEST",
                "normal PF/VF MSI-X setup produced an ambiguous default entry")

        pf_count_before = pf_collector.count;
        vf_count_before = vf_collector.count;
        tlp = make_mem_write(pf.transport.notify_mgr.msix_table[0].msg_addr,
            pf.transport.notify_mgr.msix_table[0].msg_data, 16'h0000);
        pcie_env.rc_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == (pf_count_before + 1))
            else `uvm_fatal("ROUTING_TEST",
                "default zero-requester MSI-X write did not reach its PF owner")
        assert(pf_collector.transactions[$].monitor_event == VIRTIO_MON_INTERRUPT)
            else `uvm_fatal("ROUTING_TEST",
                "default PF MSI-X write was not decoded as an interrupt")
        assert(vf_collector.count == vf_count_before)
            else `uvm_fatal("ROUTING_TEST",
                "default PF MSI-X write was broadcast to the VF observer")
    endtask

    // Explicitly provisioned MSI-X entries remain a supported routing case.
    protected task test_real_msix_memory_write(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        pcie_tl_mem_tlp tlp;
        int unsigned pf_count_before;
        int unsigned vf_count_before;

        pf.transport.notify_mgr.msix_table = new[1];
        pf.transport.notify_mgr.msix_table[0].msg_addr = PF_MSIX_ADDR;
        pf.transport.notify_mgr.msix_table[0].msg_data = PF_MSIX_DATA;
        pf.transport.notify_mgr.msix_table[0].masked = 0;
        vf.transport.notify_mgr.msix_table = new[1];
        vf.transport.notify_mgr.msix_table[0].msg_addr = PF_MSIX_ADDR + 4;
        vf.transport.notify_mgr.msix_table[0].msg_data = PF_MSIX_DATA + 1;
        vf.transport.notify_mgr.msix_table[0].masked = 0;
        pf_count_before = pf_collector.count;
        vf_count_before = vf_collector.count;

        tlp = make_mem_write(PF_MSIX_ADDR, PF_MSIX_DATA, 16'h0000);
        pcie_env.rc_agent.monitor.tlp_ap.write(tlp);

        assert(pf_collector.count == (pf_count_before + 1))
            else `uvm_fatal("ROUTING_TEST",
                "zero-requester MSI-X memory write did not reach the PF monitor")
        assert(pf_collector.transactions[$].monitor_event == VIRTIO_MON_INTERRUPT)
            else `uvm_fatal("ROUTING_TEST",
                "APIC memory write was not decoded as a virtio interrupt")
        assert(pf_collector.transactions[$].interrupt_vector == PF_MSIX_DATA)
            else `uvm_fatal("ROUTING_TEST", "MSI-X vector data was not preserved")
        assert(vf_collector.count == vf_count_before)
            else `uvm_fatal("ROUTING_TEST",
                "MSI-X write reached a function with a different MSI-X entry")
    endtask

    // The protocol checker maintains history (FEATURES_OK seen) inside its
    // event interface.  PF and VF traffic must therefore be driven through
    // distinct interfaces: a PF FEATURES_OK must never make a VF DRIVER_OK
    // trace look legal.
    protected task test_protocol_vif_isolation(
        input virtio_function_instance pf,
        input virtio_function_instance vf
    );
        virtual virtio_protocol_event_if pf_protocol_vif;
        virtual virtio_protocol_event_if vf_protocol_vif;
        virtio_monitor_routing_protocol_sva_catcher sva_catcher;

        pf_protocol_vif = pf.driver_agent.monitor.protocol_vif;
        vf_protocol_vif = vf.driver_agent.monitor.protocol_vif;
        assert((pf_protocol_vif != null) && (vf_protocol_vif != null))
            else `uvm_fatal("ROUTING_TEST",
                "each bound function requires a protocol event interface")
        assert(pf_protocol_vif != vf_protocol_vif)
            else `uvm_fatal("ROUTING_TEST",
                "PF and VF share protocol event state")

        pf.driver_agent.monitor.chk_status_transition = 0;
        vf.driver_agent.monitor.chk_status_transition = 0;
        pf_protocol_vif.assertions_enable = 0;
        vf_protocol_vif.assertions_enable = 0;
        pf.driver_agent.monitor.reset_protocol_state();
        vf.driver_agent.monitor.reset_protocol_state();

        // The routed PF reset and reset_protocol_state() pulses are staged.
        // MSI-X observations only add a pulse for queue completions, so drain
        // the actual PF/VF queue contents rather than assuming a fixed depth.
        drain_staged_protocol_pulses(pf_protocol_vif, vf_protocol_vif);
        pf_protocol_vif.protocol_error_count = 0;
        vf_protocol_vif.protocol_error_count = 0;
        pf_protocol_vif.assertions_enable = 1;
        vf_protocol_vif.assertions_enable = 1;

        // PF establishes DRIVER before FEATURES_OK.  The VF's DRIVER_OK is
        // intentionally illegal and must trip only the VF assertion state.
        emit_status_and_advance(pf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        emit_status_and_advance(pf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        sva_catcher = new();
        uvm_report_cb::add(null, sva_catcher);
        emit_status_and_advance(vf,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_DRIVER_OK);
        assert(pf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST",
                "PF protocol checker observed another function's illegal trace")
        assert(vf_protocol_vif.protocol_error_count == 1)
            else `uvm_fatal("ROUTING_TEST",
                "VF DRIVER_OK without VF FEATURES_OK did not trip its SVA")
        assert(sva_catcher.caught_count == 1)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected one scoped VF DRIVER_OK SVA report, saw %0d",
                sva_catcher.caught_count))
        uvm_report_cb::delete(null, sva_catcher);

        // Reset both checker histories, then prove that independent legal
        // traces pass without cross-function contamination.
        emit_status_and_advance(pf, DEV_STATUS_RESET);
        emit_status_and_advance(vf, DEV_STATUS_RESET);
        pf_protocol_vif.protocol_error_count = 0;
        vf_protocol_vif.protocol_error_count = 0;
        drive_legal_status_trace(pf);
        drive_legal_status_trace(vf);
        assert(pf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST", "legal PF trace tripped its SVA")
        assert(vf_protocol_vif.protocol_error_count == 0)
            else `uvm_fatal("ROUTING_TEST", "legal VF trace tripped its SVA")
    endtask

    // Configure and enable the same queue twice.  Q_RESET and device-status
    // reset must each clear both adapter and semantic-monitor queue state, so
    // the following notify is rejected in both cases.
    protected task test_queue_and_device_resets(
        input virtio_function_instance pf
    );
        virtio_monitor_routing_error_catcher error_catcher;
        virtio_monitor_routing_disabled_notify_sva_catcher sva_catcher;
        virtual virtio_protocol_event_if protocol_vif;
        int unsigned protocol_errors_before;

        // Do not let an uninstantiated functional virtqueue reject the notify
        // for us; this test isolates observer/monitor reset state.
        pf.driver_agent.monitor.vq_mgr = null;
        protocol_vif = pf.driver_agent.monitor.protocol_vif;
        assert(protocol_vif != null)
            else `uvm_fatal("ROUTING_TEST",
                "queue-reset test requires a protocol event interface")
        protocol_vif.assertions_enable = 1;
        error_catcher = new();
        sva_catcher = new();
        protocol_errors_before = protocol_vif.protocol_error_count;
        uvm_report_cb::add(null, error_catcher);
        uvm_report_cb::add(null, sva_catcher);

        configure_and_enable_queue(pf, 3);
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_RESET, 32'h1);
        emit_notify(pf, 3);
        assert(error_catcher.monitor_errors == 1)
            else `uvm_fatal("ROUTING_TEST",
                "notify after Q_RESET was not rejected")
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_ENABLE, 32'h1);
        assert(error_catcher.monitor_errors == 2)
            else `uvm_fatal("ROUTING_TEST",
                "adapter kept queue configuration after Q_RESET")

        configure_and_enable_queue(pf, 3);
        emit_common_write(pf, VIRTIO_PCI_COMMON_STATUS, DEV_STATUS_RESET);
        emit_notify(pf, 3);
        assert(error_catcher.monitor_errors == 3)
            else `uvm_fatal("ROUTING_TEST",
                "notify after device reset was not rejected")
        emit_common_write(pf, VIRTIO_PCI_COMMON_Q_ENABLE, 32'h1);
        assert(error_catcher.monitor_errors == 4)
            else `uvm_fatal("ROUTING_TEST",
                "adapter kept queue configuration after device reset")

        drain_staged_protocol_pulses(protocol_vif, null);
        assert(sva_catcher.caught_count == 2)
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected two scoped disabled-notify SVA reports, saw %0d",
                sva_catcher.caught_count))
        assert(protocol_vif.protocol_error_count == (protocol_errors_before + 2))
            else `uvm_fatal("ROUTING_TEST", $sformatf(
                "expected two disabled-notify protocol errors, saw %0d -> %0d",
                protocol_errors_before, protocol_vif.protocol_error_count))

        uvm_report_cb::delete(null, sva_catcher);
        uvm_report_cb::delete(null, error_catcher);
    endtask

    // Each interface releases at most one staged pulse on a negedge.  Capture
    // the exact pending depth first, then fail rather than spinning if a new
    // callback prevents these known pre-baseline events from draining.
    protected task drain_staged_protocol_pulses(
        input virtual virtio_protocol_event_if pf_protocol_vif,
        input virtual virtio_protocol_event_if vf_protocol_vif
    );
        int unsigned pending_pulses;
        int unsigned release_count;

        pending_pulses = pf_protocol_vif.staged_pulses.size();
        if (vf_protocol_vif != null)
            pending_pulses += vf_protocol_vif.staged_pulses.size();
        while ((pf_protocol_vif.staged_pulses.size() != 0) ||
               ((vf_protocol_vif != null) &&
                (vf_protocol_vif.staged_pulses.size() != 0))) begin
            assert(release_count < pending_pulses)
                else `uvm_fatal("ROUTING_TEST", $sformatf(
                    "staged protocol pulses grew while draining (%0d releases, %0d initial)",
                    release_count, pending_pulses))
            @(negedge virtio_tb_top.clk);
            @(posedge virtio_tb_top.clk);
            #1step;
            release_count++;
        end
    endtask

    protected task configure_and_enable_queue(
        input virtio_function_instance function_instance,
        input int unsigned queue_id
    );
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_SELECT, queue_id);
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_SIZE, 32'd64);
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_Q_ENABLE, 32'd1);
    endtask

    protected task drive_legal_status_trace(
        input virtio_function_instance function_instance
    );
        emit_status_and_advance(function_instance, DEV_STATUS_ACKNOWLEDGE);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK);
        emit_status_and_advance(function_instance,
            DEV_STATUS_ACKNOWLEDGE | DEV_STATUS_DRIVER | DEV_STATUS_FEATURES_OK |
            DEV_STATUS_DRIVER_OK);
    endtask

    protected task emit_status_and_advance(
        input virtio_function_instance function_instance,
        input bit [7:0] status
    );
        emit_common_write(function_instance, VIRTIO_PCI_COMMON_STATUS, status);
        // The callback can enqueue on the same negedge at which the interface
        // drains its queue.  Cross the next release edge and then the following
        // SVA sample; #1step leaves the observed/reactive regions before checking.
        @(posedge virtio_tb_top.clk);
        @(negedge virtio_tb_top.clk);
        @(posedge virtio_tb_top.clk);
        #1step;
    endtask

    protected task emit_common_write(
        input virtio_function_instance function_instance,
        input bit [11:0] offset,
        input bit [31:0] data
    );
        pcie_env.ep_agent.monitor.tlp_ap.write(make_mem_write(
            function_instance.transport.bar.bar_base[0] + COMMON_OFF + offset,
            data, 16'h0000));
    endtask

    protected task emit_notify(
        input virtio_function_instance function_instance,
        input int unsigned queue_id
    );
        pcie_env.ep_agent.monitor.tlp_ap.write(make_mem_write(
            function_instance.transport.bar.bar_base[0] + NOTIFY_OFF,
            queue_id, 16'h0000));
    endtask

    protected function pcie_tl_mem_tlp make_pf_status_write(
        input virtio_function_instance pf
    );
        return make_mem_write(
            pf.transport.bar.bar_base[0] + COMMON_OFF + VIRTIO_PCI_COMMON_STATUS,
            DEV_STATUS_RESET, 16'h0000);
    endfunction

    protected function pcie_tl_mem_tlp make_mem_write(
        input bit [63:0] address,
        input bit [31:0] data,
        input bit [15:0] requester_id
    );
        pcie_tl_mem_tlp tlp;

        tlp = pcie_tl_mem_tlp::type_id::create("monitor_mem_write");
        tlp.kind = TLP_MEM_WR;
        tlp.fmt = FMT_4DW_WITH_DATA;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.is_64bit = 1;
        tlp.requester_id = requester_id;
        tlp.addr = address;
        tlp.length = 10'd1;
        tlp.first_be = 4'hF;
        tlp.last_be = 4'h0;
        tlp.payload = new[4];
        tlp.payload[0] = data[7:0];
        tlp.payload[1] = data[15:8];
        tlp.payload[2] = data[23:16];
        tlp.payload[3] = data[31:24];
        return tlp;
    endfunction
endclass : virtio_monitor_routing_test

`endif // VIRTIO_MONITOR_ROUTING_TEST_SV
