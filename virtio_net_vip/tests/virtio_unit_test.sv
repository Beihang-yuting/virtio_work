`ifndef VIRTIO_UNIT_TEST_SV
`define VIRTIO_UNIT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// The completion-routing unit test calls handle_completion() directly and
// therefore does not connect a sequencer to the RC driver.  Suppress the
// inherited traffic-serving run phase while retaining the real completion
// implementation under test.
class virtio_tlm_rc_driver_test_shim extends virtio_tlm_rc_driver_shim;
    `uvm_component_utils(virtio_tlm_rc_driver_test_shim)

    function new(string name = "virtio_tlm_rc_driver_test_shim",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask

    // Set up the same private read-back state that the base send path creates
    // for a non-posted request, without needing a live sequencer or adapter.
    function void register_readback_for_test(pcie_tl_tlp req);
        req.rb_done = 0;
        req.rb_data = {};
        req.rb_status = CPL_STATUS_SC;
        rb_outstanding[req.tag] = req;
    endfunction
endclass : virtio_tlm_rc_driver_test_shim

class virtio_tlm_adapter_owner_catcher extends uvm_report_catcher;
    bit caught;

    function new(string name = "virtio_tlm_adapter_owner_catcher");
        super.new(name);
        caught = 0;
    endfunction

    function action_e catch();
        if ((get_id() == "TLM_COMPLETION") && (get_severity() == UVM_FATAL)) begin
            caught = 1;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_tlm_adapter_owner_catcher

class virtio_wait_policy_timeout_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_wait_policy_timeout_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "WAIT_POLICY") &&
            uvm_is_match(
                "wait_event_or_timeout TIMEOUT after *ns at *: test_timeout",
                get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_wait_policy_timeout_catcher

class virtio_wait_policy_poll_timeout_probe_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_wait_policy_poll_timeout_probe_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "WAIT_POLICY") &&
            uvm_is_match("poll_until_flag TIMEOUT after *: test_timeout (timeout=*ns, attempts=*)",
                         get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_wait_policy_poll_timeout_probe_catcher

// ============================================================================
// virtio_unit_test
//
// Standalone unit test that exercises core VIP components without needing
// PCIe infrastructure or the full environment. Tests:
//   - host_mem_manager: alloc/write/read/free
//   - virtio_iommu_model: map/translate/unmap
//   - split_virtqueue: alloc_rings/add_buf/free_rings
//   - virtio_wait_policy: timeout and event mechanisms
// ============================================================================

class virtio_unit_test extends uvm_test;
    `uvm_component_utils(virtio_unit_test)

    pcie_tl_scoreboard be_scb;
    virtio_tlm_rc_driver_shim completion_shim;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        be_scb = pcie_tl_scoreboard::type_id::create("be_scb", this);
        completion_shim = virtio_tlm_rc_driver_test_shim::type_id::create(
            "completion_shim", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_host_mem();
        test_iommu();
        test_split_virtqueue();
        test_wait_policy();
        test_pcie_scoreboard_byte_enables();
        test_tlm_completion_reject_filter();
        test_tlm_completion_matcher();
        test_tlm_config_write_completion_lifecycle();
        test_tlm_completion_factory_owner();

        `uvm_info("UNIT_TEST", "All unit tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // Test 1: host_mem alloc/write/read/free
    task test_host_mem();
        host_mem_manager mem = host_mem_manager::type_id::create("mem");
        bit [63:0] addr;
        byte wdata[];
        byte rdata[];

        mem.init_region(64'h1000_0000, 64'h1000_FFFF);

        addr = mem.alloc(256, .align(64));
        assert(addr != '1) else `uvm_fatal("TEST", "alloc failed")

        wdata = new[16];
        foreach (wdata[i]) wdata[i] = i;
        mem.write_mem(addr, wdata);

        mem.read_mem(addr, 16, rdata);
        foreach (rdata[i])
            assert(rdata[i] == i) else `uvm_error("TEST", $sformatf("data mismatch at %0d: got %0d expected %0d", i, rdata[i], i))

        mem.free(addr);

        `uvm_info("UNIT_TEST", "test_host_mem PASSED", UVM_LOW)
    endtask

    // Test 2: IOMMU map/translate/unmap
    task test_iommu();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("iommu");
        bit [63:0] iova, write_iova, gpa;
        iommu_fault_e fault;
        bit ok;

        // Map
        iova = iommu.map(16'h0100, 64'hDEAD_0000, 4096, DMA_TO_DEVICE);
        assert(iova != 0) else `uvm_fatal("TEST", "map failed")

        // Translate
        ok = iommu.translate(16'h0100, iova, 64, DMA_TO_DEVICE, gpa, fault);
        assert(ok) else `uvm_fatal("TEST", $sformatf("translate failed, fault=%s", fault.name()))
        assert(gpa == 64'hDEAD_0000) else `uvm_fatal("TEST", $sformatf("gpa mismatch: %h", gpa))

        // Permission violation on the public device-read translation path.
        // Device-to-guest writes are intentionally rejected before mapping
        // lookup and must use write_from_device().
        write_iova = iommu.map(16'h0100, 64'hBEEF_0000, 4096,
                               DMA_FROM_DEVICE);
        ok = iommu.translate(16'h0100, write_iova, 64, DMA_TO_DEVICE,
                             gpa, fault);
        assert(!ok && fault == IOMMU_FAULT_PERMISSION)
            else `uvm_error("TEST", "expected permission fault")

        // Unmap
        iommu.unmap(16'h0100, iova);
        iommu.unmap(16'h0100, write_iova);

        // Leak check
        iommu.leak_check();

        `uvm_info("UNIT_TEST", "test_iommu PASSED", UVM_LOW)
    endtask

    // Test 3: Split virtqueue alloc/add_buf/free
    task test_split_virtqueue();
        host_mem_manager mem = host_mem_manager::type_id::create("sq_mem");
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("sq_iommu");
        virtio_memory_barrier_model barrier = virtio_memory_barrier_model::type_id::create("barrier");
        virtqueue_error_injector err_inj = virtqueue_error_injector::type_id::create("err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("wait_pol");
        split_virtqueue vq;

        mem.init_region(64'h2000_0000, 64'h2000_FFFF);
        iommu.strict_permission_check = 0;  // relax for unit test

        vq = split_virtqueue::type_id::create("vq");
        vq.setup(0, 16, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
        vq.alloc_rings();

        assert(vq.get_free_count() == 16)
            else `uvm_error("TEST", $sformatf("expected 16 free, got %0d", vq.get_free_count()))

        // Add a buffer
        begin
            virtio_sg_list sgs[];
            virtio_sg_entry e;
            virtio_sg_list sg;
            bit [63:0] buf_addr;
            int unsigned desc_id;
            byte test_data[];

            // Allocate a data buffer
            test_data = new[64];
            foreach (test_data[i]) test_data[i] = i + 8'hA0;
            buf_addr = mem.alloc(64, .align(64));
            mem.write_mem(buf_addr, test_data);

            e.addr = buf_addr;
            e.len = 64;
            sg.entries.push_back(e);
            sgs = new[1];
            sgs[0] = sg;

            desc_id = vq.add_buf(sgs, 1, 0, null, 0);
            assert(desc_id != '1) else `uvm_fatal("TEST", "add_buf failed")
            assert(vq.get_free_count() == 15)
                else `uvm_error("TEST", $sformatf("expected 15 free, got %0d", vq.get_free_count()))
        end

        vq.dump_ring();
        vq.free_rings();

        `uvm_info("UNIT_TEST", "test_split_virtqueue PASSED", UVM_LOW)
    endtask

    // Test 4: Wait policy
    task test_wait_policy();
        virtio_wait_policy wp = virtio_wait_policy::type_id::create("wp");
        uvm_event evt = new("test_evt");
        bit triggered;
        bit poll_success;
        bit poll_timed_out;
        int error_count_before;
        int error_count_after;
        virtio_wait_policy_timeout_catcher timeout_catcher;
        virtio_wait_policy_poll_timeout_probe_catcher poll_timeout_probe_catcher;

        // The generic catcher is deliberately registered before the narrow
        // poll probe.  UVM processes report catchers in registration order,
        // so a broad generic match would incorrectly prevent the probe from
        // seeing its own poll_until_flag timeout.
        error_count_before = uvm_report_server::get_server().get_severity_count(UVM_ERROR);
        timeout_catcher = new();
        poll_timeout_probe_catcher = new();
        uvm_report_cb::add(null, timeout_catcher);
        uvm_report_cb::add(null, poll_timeout_probe_catcher);

        // Test wait_event_or_timeout timeout (should timeout quickly).
        wp.wait_event_or_timeout("test_timeout", evt, 100, triggered);

        // Probe a similarly named poll_until_flag timeout.  Its dedicated
        // catcher must receive this report rather than the primary catcher.
        poll_success = 0;
        wp.poll_until_flag("test_timeout", 100, 10, poll_success, poll_timed_out);

        uvm_report_cb::delete(null, poll_timeout_probe_catcher);
        uvm_report_cb::delete(null, timeout_catcher);

        assert(!triggered) else `uvm_error("TEST", "should have timed out")
        assert(poll_timed_out) else
            `uvm_error("TEST", "poll_until_flag probe should have timed out")
        error_count_after = uvm_report_server::get_server().get_severity_count(UVM_ERROR);
        assert(error_count_after == error_count_before) else
            `uvm_error("TEST", $sformatf("expected caught timeouts to leave UVM_ERROR count at %0d, got %0d",
                                         error_count_before, error_count_after))
        assert((timeout_catcher.caught_count == 1) &&
               (poll_timeout_probe_catcher.caught_count == 1)) else
            `uvm_error("TEST", $sformatf(
                "primary catcher must catch only wait_event_or_timeout (primary=%0d, poll_probe=%0d)",
                timeout_catcher.caught_count, poll_timeout_probe_catcher.caught_count))

        // Reset event for next test
        evt.reset();

        // Test event trigger
        fork : trigger_blk
            begin
                #50ns;
                evt.trigger();
            end
        join_none
        wp.wait_event_or_timeout("test_event", evt, 1000, triggered);
        disable trigger_blk;
        assert(triggered) else `uvm_error("TEST", "event should have triggered")

        `uvm_info("UNIT_TEST", "test_wait_policy PASSED", UVM_LOW)
    endtask

    // A partial multi-DWord Memory Write must constrain only bytes selected by
    // first_be and last_be.  The completion deliberately differs in the two
    // disabled final-DWord lanes; all six enabled bytes must still compare.
    task test_pcie_scoreboard_byte_enables();
        pcie_tl_scoreboard scb;
        pcie_tl_mem_tlp write_tlp;
        pcie_tl_mem_tlp read_tlp;
        pcie_tl_cpl_tlp cpl;

        scb = be_scb;
        scb.ordering_check_enable = 0;

        write_tlp = pcie_tl_mem_tlp::type_id::create("partial_write");
        write_tlp.kind = TLP_MEM_WR;
        write_tlp.fmt = FMT_3DW_WITH_DATA;
        write_tlp.type_f = TLP_TYPE_MEM_WR;
        write_tlp.requester_id = 16'h0100;
        write_tlp.addr = 64'h0000_0000_C000_001C;
        write_tlp.length = 10'h2;
        write_tlp.first_be = 4'hF;
        write_tlp.last_be = 4'h3;
        write_tlp.payload = new[8];
        write_tlp.payload[0] = 8'h10;
        write_tlp.payload[1] = 8'h11;
        write_tlp.payload[2] = 8'h12;
        write_tlp.payload[3] = 8'h13;
        write_tlp.payload[4] = 8'h20;
        write_tlp.payload[5] = 8'h21;
        write_tlp.payload[6] = 8'h22;  // last_be masks this lane
        write_tlp.payload[7] = 8'h23;  // last_be masks this lane
        scb.write_ep(write_tlp);

        read_tlp = pcie_tl_mem_tlp::type_id::create("notify_read");
        read_tlp.kind = TLP_MEM_RD;
        read_tlp.fmt = FMT_3DW_NO_DATA;
        read_tlp.type_f = TLP_TYPE_MEM_RD;
        read_tlp.requester_id = 16'h0100;
        read_tlp.tag = 10'h023;
        read_tlp.addr = 64'h0000_0000_C000_001C;
        read_tlp.length = 10'h2;
        read_tlp.first_be = 4'hF;
        read_tlp.last_be = 4'hF;
        scb.register_pending(read_tlp);

        cpl = pcie_tl_cpl_tlp::type_id::create("notify_completion");
        cpl.kind = TLP_CPLD;
        cpl.fmt = FMT_3DW_WITH_DATA;
        cpl.type_f = TLP_TYPE_CPL;
        cpl.requester_id = read_tlp.requester_id;
        cpl.completer_id = 16'h0000;
        cpl.tag = read_tlp.tag;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.byte_count = 12'd8;
        cpl.lower_addr = read_tlp.addr[6:0];
        cpl.payload = new[8];
        cpl.payload[0] = 8'h10;
        cpl.payload[1] = 8'h11;
        cpl.payload[2] = 8'h12;
        cpl.payload[3] = 8'h13;
        cpl.payload[4] = 8'h20;
        cpl.payload[5] = 8'h21;
        cpl.payload[6] = 8'hDE;  // differs only in last_be-masked lane
        cpl.payload[7] = 8'hAD;  // differs only in last_be-masked lane
        scb.write_rc(cpl);

        assert(scb.mismatched == 0)
            else `uvm_error("TEST", $sformatf(
                "scoreboard treated last_be-masked bytes as written (%0d mismatches)",
                scb.mismatched))
        assert(scb.matched == 1)
            else `uvm_error("TEST", $sformatf(
                "scoreboard did not complete the partial-last-DWord request (%0d matches)",
                scb.matched))

        `uvm_info("UNIT_TEST", "test_pcie_scoreboard_byte_enables PASSED", UVM_LOW)
    endtask

    // The TLM shim must preserve the RC driver's authoritative completion
    // decision: a completion whose requester ID does not match its outstanding
    // request must never be made visible to a BAR sequence waiter.
    task test_tlm_completion_reject_filter();
        virtio_tlm_completion_adapter adapter;
        virtio_tlm_rc_driver_shim shim;
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp rejected_cpl;
        pcie_tl_cpl_tlp matched_cpl;
        pcie_tl_cpl_tlp observed_cpl;
        bit accepted;
        bit ok;

        adapter = virtio_tlm_completion_adapter::type_id::create(
            "reject_filter_adapter");
        shim = completion_shim;
        shim.adapter = adapter;
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create(
            "reject_filter_tag_mgr");

        req = pcie_tl_mem_tlp::type_id::create("reject_filter_req");
        req.kind = TLP_MEM_RD;
        req.requester_id = 16'h0100;
        req.tag = 10'h021;
        req.length = 10'h1;
        shim.tag_mgr.register_outstanding(req.tag, req);

        rejected_cpl = pcie_tl_cpl_tlp::type_id::create(
            "reject_filter_bad_cpl");
        rejected_cpl.kind = TLP_CPLD;
        rejected_cpl.requester_id = 16'h0101;
        rejected_cpl.tag = req.tag;
        rejected_cpl.cpl_status = CPL_STATUS_SC;
        rejected_cpl.payload = new[4];

        accepted = shim.handle_completion(rejected_cpl);
        assert(!accepted)
            else `uvm_error("TEST", "RC shim accepted a mismatched completion")
        assert(adapter.completions_received == 0)
            else `uvm_error("TEST", "RC-rejected completion was queued for BAR waiters")

        matched_cpl = pcie_tl_cpl_tlp::type_id::create(
            "reject_filter_good_cpl");
        matched_cpl.kind = TLP_CPLD;
        matched_cpl.requester_id = req.requester_id;
        matched_cpl.tag = req.tag;
        matched_cpl.cpl_status = CPL_STATUS_SC;
        matched_cpl.payload = new[4];
        matched_cpl.payload[0] = 8'hA5;

        accepted = shim.handle_completion(matched_cpl);
        assert(accepted)
            else `uvm_error("TEST", "RC shim rejected a matching completion")
        assert(adapter.completions_received == 1)
            else `uvm_error("TEST", "matching completion was not queued")

        adapter.wait_matching_completion(
            100, req.tag, req.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == matched_cpl)
            else `uvm_error("TEST", "matching completion was not returned to waiter")

        `uvm_info("UNIT_TEST", "test_tlm_completion_reject_filter PASSED", UVM_LOW)
    endtask

    // Two reads may be outstanding at once.  When B completes before A, the
    // A waiter must retain B and receive only its own {tag, requester_id}
    // completion; B must remain available for its true waiter afterwards.
    task test_tlm_completion_matcher();
        virtio_tlm_completion_adapter adapter;
        virtio_tlm_rc_driver_shim shim;
        pcie_tl_mem_tlp req_a;
        pcie_tl_mem_tlp req_b;
        pcie_tl_cpl_tlp cpl_a;
        pcie_tl_cpl_tlp cpl_b;
        pcie_tl_cpl_tlp observed_cpl;
        bit accepted;
        bit ok;

        adapter = virtio_tlm_completion_adapter::type_id::create(
            "matcher_adapter");
        shim = completion_shim;
        shim.adapter = adapter;
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create("matcher_tag_mgr");

        req_a = pcie_tl_mem_tlp::type_id::create("matcher_req_a");
        req_a.kind = TLP_MEM_RD;
        req_a.requester_id = 16'h0100;
        req_a.tag = 10'h022;
        req_a.length = 10'h1;
        shim.tag_mgr.register_outstanding(req_a.tag, req_a);

        req_b = pcie_tl_mem_tlp::type_id::create("matcher_req_b");
        req_b.kind = TLP_MEM_RD;
        req_b.requester_id = 16'h0108;
        req_b.tag = 10'h023;
        req_b.length = 10'h1;
        shim.tag_mgr.register_outstanding(req_b.tag, req_b);

        cpl_b = pcie_tl_cpl_tlp::type_id::create("matcher_cpl_b");
        cpl_b.kind = TLP_CPLD;
        cpl_b.requester_id = req_b.requester_id;
        cpl_b.tag = req_b.tag;
        cpl_b.cpl_status = CPL_STATUS_SC;
        cpl_b.payload = new[4];
        cpl_b.payload[0] = 8'hB0;

        cpl_a = pcie_tl_cpl_tlp::type_id::create("matcher_cpl_a");
        cpl_a.kind = TLP_CPLD;
        cpl_a.requester_id = req_a.requester_id;
        cpl_a.tag = req_a.tag;
        cpl_a.cpl_status = CPL_STATUS_SC;
        cpl_a.payload = new[4];
        cpl_a.payload[0] = 8'hA0;

        accepted = shim.handle_completion(cpl_b);
        assert(accepted) else `uvm_error("TEST", "completion B was rejected")
        accepted = shim.handle_completion(cpl_a);
        assert(accepted) else `uvm_error("TEST", "completion A was rejected")
        assert(adapter.completions_received == 2)
            else `uvm_error("TEST", "both accepted completions were not retained")

        adapter.wait_matching_completion(
            100, req_a.tag, req_a.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == cpl_a)
            else `uvm_error("TEST", "A waiter consumed B's out-of-order completion")

        adapter.wait_matching_completion(
            100, req_b.tag, req_b.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == cpl_b)
            else `uvm_error("TEST", "B completion was not retained for B waiter")
        assert(adapter.completions_consumed == 2)
            else `uvm_error("TEST", "both matching completions were not consumed")

        `uvm_info("UNIT_TEST", "test_tlm_completion_matcher PASSED", UVM_LOW)
    endtask

    // Configuration writes are non-posted requests, but their successful
    // PCIe completion is a data-less TLP_CPL.  It must therefore retire the
    // RC driver's pending/tag/read-back state rather than wait for length*4
    // bytes that will never arrive.
    task test_tlm_config_write_completion_lifecycle();
        virtio_tlm_rc_driver_test_shim shim;
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;
        bit accepted;

        $cast(shim, completion_shim);
        assert(shim != null)
            else `uvm_fatal("TEST", "completion shim does not expose test setup")
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create("cfg_wr_tag_mgr");

        req = pcie_tl_cfg_tlp::type_id::create("cfg_wr_req");
        req.kind = TLP_CFG_WR0;
        req.requester_id = 16'h0100;
        req.tag = 10'h024;
        req.length = 10'h1;
        shim.tag_mgr.register_outstanding(req.tag, req);
        shim.pending_cpl[req.tag] = req;
        shim.register_readback_for_test(req);

        cpl = pcie_tl_cpl_tlp::type_id::create("cfg_wr_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.length = 0;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.payload = new[0];

        accepted = shim.handle_completion(cpl);
        assert(accepted)
            else `uvm_error("TEST", "RC shim rejected a matching config-write completion")
        assert(shim.get_pending_count() == 0)
            else `uvm_error("TEST", "data-less config-write completion left the request pending")
        assert(!shim.tag_mgr.is_duplicate(req.tag))
            else `uvm_error("TEST", "data-less config-write completion did not free its tag")
        assert(req.rb_done)
            else `uvm_error("TEST", "data-less config-write completion did not finish read-back")

        `uvm_info("UNIT_TEST", "test_tlm_config_write_completion_lifecycle PASSED", UVM_LOW)
    endtask

    // Factory overrides use static sequence hooks.  A second live adapter
    // must fail instead of silently redirecting all completion waiters to it.
    task test_tlm_completion_factory_owner();
        virtio_tlm_completion_adapter owner_a;
        virtio_tlm_completion_adapter owner_b;
        virtio_tlm_adapter_owner_catcher catcher;

        owner_a = virtio_tlm_completion_adapter::type_id::create("owner_a");
        owner_b = virtio_tlm_completion_adapter::type_id::create("owner_b");
        owner_a.install_factory_overrides();

        catcher = new("adapter_owner_catcher");
        uvm_report_cb::add(null, catcher);
        owner_b.install_factory_overrides();
        uvm_report_cb::delete(null, catcher);

        assert(catcher.caught)
            else `uvm_error("TEST", "second adapter replaced factory owner without fatal")
        assert(virtio_tlm_bar_mem_rd_seq::adapter == owner_a)
            else `uvm_error("TEST", "memory-read factory adapter was replaced")
        assert(virtio_tlm_bar_cfg_rd_seq::adapter == owner_a)
            else `uvm_error("TEST", "config-read factory adapter was replaced")
        assert(virtio_tlm_bar_cfg_wr_seq::adapter == owner_a)
            else `uvm_error("TEST", "config-write factory adapter was replaced")

        `uvm_info("UNIT_TEST", "test_tlm_completion_factory_owner PASSED", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_UNIT_TEST_SV
