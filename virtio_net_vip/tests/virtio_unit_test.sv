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

class virtio_completion_ep_driver_test_shim extends pcie_tl_ep_driver;
    `uvm_component_utils(virtio_completion_ep_driver_test_shim)

    function new(string name = "virtio_completion_ep_driver_test_shim",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask
endclass : virtio_completion_ep_driver_test_shim

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

class virtio_expected_rc_completion_warning_catcher extends uvm_report_catcher;
    int unsigned caught_count;
    function new(string name = "virtio_expected_rc_completion_warning_catcher");
        super.new(name);
        caught_count = 0;
    endfunction
    virtual function action_e catch();
        if ((get_severity() == UVM_WARNING) &&
            (get_id() == "RC_DRV") &&
            uvm_is_match("Unexpected Completion:*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_expected_rc_completion_warning_catcher

class virtio_expected_iommu_map_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_expected_iommu_map_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "IOMMU_MAP")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_expected_iommu_map_error_catcher

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
    virtio_completion_ep_driver_test_shim completion_ep_driver;
    virtio_tlm_rc_driver_shim completion_shim;
    virtio_driver_agent late_binding_agent;
    virtio_atomic_ops late_binding_ops;
    virtio_auto_fsm late_binding_fsm;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        be_scb = pcie_tl_scoreboard::type_id::create("be_scb", this);
        completion_ep_driver = virtio_completion_ep_driver_test_shim::type_id::create(
            "completion_ep_driver", this);
        completion_shim = virtio_tlm_rc_driver_test_shim::type_id::create(
            "completion_shim", this);
        late_binding_ops = virtio_atomic_ops::type_id::create(
            "late_binding_ops");
        late_binding_fsm = virtio_auto_fsm::type_id::create(
            "late_binding_fsm");
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "late_binding_agent", "is_active", UVM_ACTIVE);
        late_binding_agent = virtio_driver_agent::type_id::create(
            "late_binding_agent", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        late_binding_agent.ops = late_binding_ops;
        late_binding_agent.fsm = late_binding_fsm;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_host_mem();
        test_iommu();
        test_iommu_host_domains();
        test_iommu_random_aperture();
        test_iommu_translation_overflow();
        test_split_virtqueue();
        test_wait_policy();
        test_pcie_scoreboard_byte_enables();
        test_ep_config_read_completion_metadata();
        test_tlm_completion_reject_filter();
        test_tlm_completion_matcher();
        test_tlm_config_write_completion_lifecycle();
        test_tlm_completion_factory_owner();
        test_late_driver_agent_binding();

        `uvm_info("UNIT_TEST", "All unit tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // A request that starts inside a valid mapping but wraps the 64-bit IOVA
    // end address must fail range checking instead of appearing smaller than
    // the mapped end after unsigned addition overflow.
    task test_iommu_translation_overflow();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "overflow_iommu");
        bit [63:0] fixed_iova;
        bit [63:0] gpa;
        iommu_fault_e fault;
        string why;
        bit ok;

        if (!iommu.configure_iova_aperture(
                64'hffff_ffff_ffff_d000,
                64'hffff_ffff_ffff_f000,
                IOMMU_IOVA_FIRST_FIT, why))
            `uvm_fatal("TEST", {"could not configure top IOVA aperture: ", why})
        fixed_iova = 64'hffff_ffff_ffff_e000;
        if (iommu.map_fixed(16'h0124, 64'h0000_0000_7000_0000,
                            4096, DMA_TO_DEVICE, fixed_iova) != fixed_iova)
            `uvm_fatal("TEST", "could not create top-of-address-space IOVA map")

        // Keep the request inside the mapped start address but make its end
        // wrap the 64-bit address space.  A range check that performs
        // unsigned ``iova + size`` without an overflow guard would otherwise
        // see the wrapped end (0x0000_0000_0000_dfff) and incorrectly accept
        // this translation.
        ok = iommu.translate(16'h0124, fixed_iova, 32'hffff_ffff,
                             DMA_TO_DEVICE, gpa, fault);
        if (ok || (fault != IOMMU_FAULT_OUT_OF_RANGE))
            `uvm_fatal("TEST", $sformatf(
                "wrapping IOVA translation was not rejected: ok=%0b fault=%s gpa=0x%016h",
                ok, fault.name(), gpa))
        iommu.unmap(16'h0124, fixed_iova);
        `uvm_info("UNIT_TEST", "test_iommu_translation_overflow PASSED", UVM_LOW)
    endtask

    task test_late_driver_agent_binding();
        assert(late_binding_agent.driver.ops == late_binding_ops)
            else `uvm_error("TEST", "late-bound ops did not reach active driver")
        assert(late_binding_agent.driver.fsm == late_binding_fsm)
            else `uvm_error("TEST", "late-bound fsm did not reach active driver")
        `uvm_info("UNIT_TEST", "test_late_driver_agent_binding PASSED", UVM_LOW)
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

    // A numeric BDF is only unique inside one host/IOMMU requester domain.
    // Two hosts must be able to expose the same BDF and IOVA without one
    // mapping shadowing or invalidating the other.
    task test_iommu_host_domains();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "host_domain_iommu");
        bit [63:0] host0_iova, host1_iova;
        bit [63:0] host0_gpa, host1_gpa;
        bit [63:0] host0_write_iova, host1_write_iova;
        bit [63:0] host0_write_gpa, host1_write_gpa;
        bit [63:0] fixed_iova;
        bit [63:0] dirty_pages0[$], dirty_pages1[$];
        byte host0_data[], host1_data[], readback[];
        virtio_dirty_page_snapshot_t dirty_records[$];
        iommu_fault_rule_t rule;
        host_mem_manager mem = host_mem_manager::type_id::create(
            "host_domain_mem");
        virtio_pci_transport transport =
            virtio_pci_transport::type_id::create("host1_transport");
        virtio_atomic_ops ops =
            virtio_atomic_ops::type_id::create("host1_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("host1_vq_mgr");
        virtqueue_base host1_vq;
        dpu_pcie_function_id_t pcie_id;
        iommu_fault_e fault;
        bit ok;

        // This test checks host-domain independence using the historical
        // deterministic allocator.  Random placement is covered separately
        // by test_iommu_random_aperture(); keeping this test first-fit makes
        // the equal numeric IOVA assertion intentional and reproducible.
        iommu.set_iova_alloc_policy(IOMMU_IOVA_FIRST_FIT);

        host0_iova = iommu.map_for_host(0, 16'h0042, 64'h1000_0000,
                                        4096, DMA_TO_DEVICE);
        host1_iova = iommu.map_for_host(1, 16'h0042, 64'h2000_0000,
                                        4096, DMA_TO_DEVICE);
        assert(host0_iova != 0 && host1_iova != 0)
            else `uvm_fatal("TEST", "host-domain map failed");
        assert(host0_iova == host1_iova)
            else `uvm_fatal("TEST", "host domains should have independent IOVA spaces");

        ok = iommu.translate_for_host(0, 16'h0042, host0_iova, 64,
                                      DMA_TO_DEVICE, host0_gpa, fault);
        assert(ok && host0_gpa == 64'h1000_0000)
            else `uvm_fatal("TEST", "host0 translation mismatch");
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(ok && host1_gpa == 64'h2000_0000)
            else `uvm_fatal("TEST", "host1 translation mismatch");

        // Fault injection is scoped by the same host-qualified requester key.
        rule = '{host_id: 0, host_id_valid: 0, bdf_mask: '0,
                 iova_start: '0, iova_end: '0, dir: DMA_TO_DEVICE,
                 fault_type: IOMMU_NO_FAULT, trigger_count: 0,
                 triggered: 0};
        rule.host_id = 1;
        rule.host_id_valid = 1;
        rule.bdf_mask = 16'h0042;
        rule.iova_start = host1_iova;
        rule.iova_end = host1_iova + 4095;
        rule.dir = DMA_TO_DEVICE;
        rule.fault_type = IOMMU_FAULT_DEVICE_ABORT;
        rule.trigger_count = 1;
        iommu.add_fault_rule(rule);
        ok = iommu.translate_for_host(0, 16'h0042, host0_iova, 64,
                                      DMA_TO_DEVICE, host0_gpa, fault);
        assert(ok) else `uvm_fatal("TEST", "host1 fault rule affected host0");
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(!ok && fault == IOMMU_FAULT_DEVICE_ABORT)
            else `uvm_fatal("TEST", "host-scoped fault rule did not fire");
        iommu.clear_fault_rules();

        // Fixed IOVAs may also repeat across hosts.
        fixed_iova = 64'h9000_0000;
        assert(iommu.map_fixed_for_host(0, 16'h0043, 64'h3000_0000,
                   4096, DMA_TO_DEVICE, fixed_iova) == fixed_iova)
            else `uvm_fatal("TEST", "host0 fixed map failed");
        assert(iommu.map_fixed_for_host(1, 16'h0043, 64'h4000_0000,
                   4096, DMA_TO_DEVICE, fixed_iova) == fixed_iova)
            else `uvm_fatal("TEST", "host1 equal fixed map failed");
        iommu.unmap_for_host(0, 16'h0043, fixed_iova);
        iommu.unmap_for_host(1, 16'h0043, fixed_iova);

        // Exercise the production atomic-write boundary and host-scoped dirty
        // snapshots, not only the direct IOMMU translate API.
        mem.init_region(64'h5000_0000, 64'h5001_FFFF);
        host0_write_gpa = mem.alloc(4096, .align(4096));
        host1_write_gpa = mem.alloc(4096, .align(4096));
        host0_write_iova = iommu.map_for_host(0, 16'h0042, host0_write_gpa,
                                              4096, DMA_FROM_DEVICE);
        host1_write_iova = iommu.map_for_host(1, 16'h0042, host1_write_gpa,
                                              4096, DMA_FROM_DEVICE);
        assert(host0_write_iova == host1_write_iova)
            else `uvm_fatal("TEST", "write IOVA spaces are not host-local");
        void'(iommu.begin_dirty_generation_for_host(0));
        void'(iommu.begin_dirty_generation_for_host(1));
        host0_data = new[1];
        host0_data[0] = 8'hA0;
        assert(iommu.write_from_device_for_host(0, mem, 16'h0042,
                   host0_write_iova, host0_data, fault))
            else `uvm_fatal("TEST", "host0 device write failed");
        pcie_id = '{domain: '{host_id: 1, segment_id: 0}, bdf: 16'h0042};
        transport.configure_pcie_identity(pcie_id);
        vq_mgr.host_id = 1;
        vq_mgr.bdf = 16'h0042;
        host1_vq = vq_mgr.create_queue(7, 8, VQ_SPLIT);
        assert(host1_vq != null && host1_vq.host_id == 1 &&
               host1_vq.bdf == 16'h0042)
            else `uvm_fatal("TEST", "virtqueue manager lost host identity");
        ops.transport = transport;
        ops.iommu = iommu;
        ops.mem = mem;
        host1_data = new[1];
        host1_data[0] = 8'hB1;
        assert(ops.device_dma_write(host1_write_iova, host1_data, fault))
            else `uvm_fatal("TEST", "atomic ops did not use host1 domain");
        iommu.capture_dirty_generation_for_host(0, dirty_pages0);
        iommu.capture_dirty_generation_for_host(1, dirty_pages1);
        assert(dirty_pages0.size() == 1 && dirty_pages1.size() == 1)
            else `uvm_fatal("TEST", "dirty generations are not host-scoped");
        iommu.get_dirty_page_records_for_host(1, dirty_pages1[0],
                                              dirty_records);
        assert(dirty_records.size() == 1 &&
               dirty_records[0].mapping.host_id == 1 &&
               dirty_records[0].payload[0] == 8'hB1)
            else `uvm_fatal("TEST", "host1 dirty snapshot mismatch");
        mem.read_mem(host0_write_gpa, 1, readback);
        assert(readback[0] == 8'hA0)
            else `uvm_fatal("TEST", "host1 write mutated host0 backing");
        iommu.unmap_for_host(0, 16'h0042, host0_write_iova);
        iommu.unmap_for_host(1, 16'h0042, host1_write_iova);
        mem.free(host0_write_gpa);
        mem.free(host1_write_gpa);

        iommu.unmap_for_host(0, 16'h0042, host0_iova);
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(ok && host1_gpa == 64'h2000_0000)
            else `uvm_fatal("TEST", "host0 unmap affected host1 mapping");
        iommu.unmap_for_host(1, 16'h0042, host1_iova);

        `uvm_info("UNIT_TEST", "test_iommu_host_domains PASSED", UVM_LOW)
    endtask

    // Random IOVA placement is constrained by a configurable page-aligned
    // aperture and must never overlap live mappings for one requester.
    task test_iommu_random_aperture();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "random_iommu");
        bit [63:0] iovas[$];
        bit [63:0] iova;
        bit [63:0] gpa;
        iommu_fault_e fault;
        string why;
        bit ok;
        virtio_expected_iommu_map_error_catcher invalid_map_catcher;
        bit saw_non_linear_random_slot;

        saw_non_linear_random_slot = 0;

        if (!iommu.configure_iova_aperture(
                64'h0000_0000_4000_0000,
                64'h0000_0000_4002_0000,
                IOMMU_IOVA_RANDOM, why))
            `uvm_fatal("TEST", {"could not configure IOVA aperture: ", why})
        for (int index = 0; index < 12; index++) begin
            iova = iommu.map(16'h0123, 64'h6000_0000 + index * 4096,
                             4096, DMA_TO_DEVICE);
            if ((iova == 0) || (iova == '1) ||
                (iova < 64'h0000_0000_4000_0000) ||
                (iova + 4096 > 64'h0000_0000_4002_0000))
                `uvm_fatal("TEST", "random IOVA escaped configured aperture")
            foreach (iovas[previous]) begin
                if (iova == iovas[previous])
                    `uvm_fatal("TEST", "random IOVA allocation collided")
            end
            if ((index != 0) && (iova != iovas[0] + index * 4096))
                saw_non_linear_random_slot = 1;
            iovas.push_back(iova);
            ok = iommu.translate(16'h0123, iova, 4096,
                                 DMA_TO_DEVICE, gpa, fault);
            if (!ok || (gpa != 64'h6000_0000 + index * 4096))
                `uvm_fatal("TEST", "random IOVA translation mismatch")
        end
        invalid_map_catcher = new("invalid_map_catcher");
        uvm_report_cb::add(null, invalid_map_catcher);
        if (iommu.map_fixed(16'h0123, 64'h7000_0000, 4096,
                            DMA_TO_DEVICE, 64'h4000_0000) != '1)
            `uvm_fatal("TEST", "fixed IOVA outside aperture was accepted")
        uvm_report_cb::delete(null, invalid_map_catcher);
        if (invalid_map_catcher.caught_count != 1)
            `uvm_fatal("TEST", "invalid fixed IOVA was not rejected")
        if (!saw_non_linear_random_slot)
            `uvm_fatal("TEST", "random IOVA policy produced only linear slots")
        foreach (iovas[index])
            iommu.unmap(16'h0123, iovas[index]);
        `uvm_info("UNIT_TEST", "test_iommu_random_aperture PASSED", UVM_LOW)
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

    task test_ep_config_read_completion_metadata();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_cfg_tlp::type_id::create("config_read_req");
        req.kind = TLP_CFG_RD0;
        req.fmt = FMT_3DW_NO_DATA;
        req.type_f = TLP_TYPE_CFG_RD0;
        req.length = 10'd1;
        req.requester_id = 16'h0100;
        req.tag = 10'h055;
        req.first_be = 4'hF;

        cpl = completion_ep_driver.generate_completion(req, CPL_STATUS_SC);

        assert(cpl.byte_count == 12'd4)
            else `uvm_error("TEST", $sformatf(
                "config-read completion byte_count expected 4 got %0d",
                cpl.byte_count))

        `uvm_info("UNIT_TEST", "test_ep_config_read_completion_metadata PASSED", UVM_LOW)
    endtask

    // The TLM shim must preserve the RC driver's authoritative completion
    // decision: a completion whose requester ID does not match its outstanding
    // request must never be made visible to a BAR sequence waiter.
    task test_tlm_completion_reject_filter();
        virtio_tlm_completion_adapter adapter;
        virtio_tlm_rc_driver_shim shim;
        virtio_expected_rc_completion_warning_catcher catcher;
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

        catcher = new();
        uvm_report_cb::add(null, catcher);
        accepted = shim.handle_completion(rejected_cpl);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count == 1)
            else `uvm_error("TEST", "expected exactly one rejected completion warning")
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
