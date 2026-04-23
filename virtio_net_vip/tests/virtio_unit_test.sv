`ifndef VIRTIO_UNIT_TEST_SV
`define VIRTIO_UNIT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

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

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_host_mem();
        test_iommu();
        test_split_virtqueue();
        test_wait_policy();

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
        bit [63:0] iova, gpa;
        iommu_fault_e fault;
        bit ok;

        // Map
        iova = iommu.map(16'h0100, 64'hDEAD_0000, 4096, DMA_TO_DEVICE);
        assert(iova != 0) else `uvm_fatal("TEST", "map failed")

        // Translate
        ok = iommu.translate(16'h0100, iova, 64, DMA_TO_DEVICE, gpa, fault);
        assert(ok) else `uvm_fatal("TEST", $sformatf("translate failed, fault=%s", fault.name()))
        assert(gpa == 64'hDEAD_0000) else `uvm_fatal("TEST", $sformatf("gpa mismatch: %h", gpa))

        // Permission violation
        ok = iommu.translate(16'h0100, iova, 64, DMA_FROM_DEVICE, gpa, fault);
        assert(!ok && fault == IOMMU_FAULT_PERMISSION)
            else `uvm_error("TEST", "expected permission fault")

        // Unmap
        iommu.unmap(16'h0100, iova);

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

        // Test timeout (should timeout quickly)
        wp.wait_event_or_timeout("test_timeout", evt, 100, triggered);
        assert(!triggered) else `uvm_error("TEST", "should have timed out")

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

endclass

`endif // VIRTIO_UNIT_TEST_SV
