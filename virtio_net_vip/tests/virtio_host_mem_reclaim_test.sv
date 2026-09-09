`ifndef VIRTIO_HOST_MEM_RECLAIM_TEST_SV
`define VIRTIO_HOST_MEM_RECLAIM_TEST_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Dedicated ownership test.  The allocator implementation is the external
// host_mem project; this test only drives the real public alloc/free API and
// the existing virtqueue lifecycle.
class virtio_host_mem_reclaim_test extends uvm_test;
    `uvm_component_utils(virtio_host_mem_reclaim_test)

    localparam bit [63:0] HOST0_BASE = 64'h0000_0001_0000_0000;
    localparam bit [63:0] HOST0_END  = 64'h0000_0001_01FF_FFFF;
    localparam bit [63:0] HOST1_BASE = 64'h0000_0002_0000_0000;
    localparam bit [63:0] HOST1_END  = 64'h0000_0002_01FF_FFFF;
    localparam int unsigned QUEUE_SIZE = 32;
    localparam int unsigned RECLAIM_CYCLES = 8;

    virtio_shared_mem_fixture mem_fixture;
    host_mem_manager host0_mem;
    host_mem_manager host1_mem;

    function new(string name = "virtio_host_mem_reclaim_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem_fixture = virtio_shared_mem_fixture::type_id::create(
            "reclaim_mem_fixture");
        if (!mem_fixture.create_host(0, HOST0_BASE, HOST0_END,
                                     HOST_MEM_RANDOM))
            `uvm_fatal("HOST_RECLAIM", "failed to create Host 0 manager")
        if (!mem_fixture.create_host(1, HOST1_BASE, HOST1_END,
                                     HOST_MEM_RANDOM))
            `uvm_fatal("HOST_RECLAIM", "failed to create Host 1 manager")
        host0_mem = mem_fixture.get_host(0);
        host1_mem = mem_fixture.get_host(1);
        if ((host0_mem == null) || (host1_mem == null))
            `uvm_fatal("HOST_RECLAIM", "fixture returned a null Host manager")
        if (mem_fixture.get_host(0) != host0_mem ||
            mem_fixture.get_host(1) != host1_mem)
            `uvm_fatal("HOST_RECLAIM", "Host manager lookup is not stable")
        if (host0_mem == host1_mem)
            `uvm_fatal("HOST_RECLAIM", "different Hosts share one manager")
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_random_alloc_free();
        test_split_queue_reclaim();
        test_multi_host_isolation();

        host0_mem.leak_check();
        host1_mem.leak_check();
        `uvm_info("HOST_RECLAIM",
                  "shared Host memory reclamation test PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    task test_random_alloc_free();
        bit [63:0] active[$];
        int unsigned operations = 512;
        int unsigned freed = 0;

        for (int unsigned i = 0; i < operations; i++) begin
            int unsigned size;
            int unsigned align;
            bit [63:0] addr;

            size = 16 * (1 + ($urandom() % 256));
            case ($urandom() % 3)
                0: align = 16;
                1: align = 64;
                default: align = 4096;
            endcase
            addr = host0_mem.alloc(size, .align(align));
            if (addr == '1) begin
                if (active.size() == 0)
                    `uvm_fatal("HOST_RECLAIM", $sformatf(
                        "random allocation failed with no reclaim candidate at op %0d", i))
                host0_mem.free(active.pop_front());
                freed++;
                addr = host0_mem.alloc(size, .align(align));
            end
            if (addr == '1)
                `uvm_fatal("HOST_RECLAIM", $sformatf(
                    "random allocation failed after reclaim at op %0d", i))
            active.push_back(addr);

            if ((active.size() > 8) && (($urandom() % 3) == 0)) begin
                int unsigned victim = $urandom() % active.size();
                host0_mem.free(active[victim]);
                active.delete(victim);
                freed++;
            end
        end

        while (active.size() != 0) begin
            host0_mem.free(active.pop_back());
            freed++;
        end
        `uvm_info("HOST_RECLAIM", $sformatf(
            "random alloc/free completed: operations=%0d frees=%0d",
            operations, freed), UVM_LOW)
    endtask

    task write_used_entry(
        split_virtqueue vq,
        int unsigned slot,
        int unsigned desc_id,
        int unsigned used_len,
        int unsigned used_idx,
        host_mem_manager mem
    );
        byte entry[8];
        byte idx_bytes[2];
        bit [63:0] entry_addr;

        entry[0] = desc_id[7:0];
        entry[1] = desc_id[15:8];
        entry[2] = desc_id[23:16];
        entry[3] = desc_id[31:24];
        entry[4] = used_len[7:0];
        entry[5] = used_len[15:8];
        entry[6] = used_len[23:16];
        entry[7] = used_len[31:24];
        idx_bytes[0] = used_idx[7:0];
        idx_bytes[1] = used_idx[15:8];
        entry_addr = vq.device_ring_addr + 4 + slot * 8;
        mem.write_mem(entry_addr, entry);
        mem.write_mem(vq.device_ring_addr + 2, idx_bytes);
    endtask

    task test_split_queue_reclaim();
        virtio_iommu_model iommu;
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector err_inj;
        virtio_wait_policy wait_pol;
        split_virtqueue vq;

        iommu = virtio_iommu_model::type_id::create("reclaim_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("reclaim_barrier");
        err_inj = virtqueue_error_injector::type_id::create("reclaim_err_inj");
        wait_pol = virtio_wait_policy::type_id::create("reclaim_wait_pol");
        iommu.strict_permission_check = 0;

        vq = split_virtqueue::type_id::create("reclaim_vq");
        vq.setup(0, QUEUE_SIZE, host0_mem, iommu, barrier, err_inj,
                 wait_pol, 16'h0100, 0);

        for (int unsigned cycle = 0; cycle < RECLAIM_CYCLES; cycle++) begin
            int unsigned desc_ids[$];
            bit [63:0] buffers[int unsigned];
            int unsigned used_idx = 0;

            if (cycle != 0) begin
                vq.reset_queue();
                vq.setup(0, QUEUE_SIZE, host0_mem, iommu, barrier, err_inj,
                         wait_pol, 16'h0100, 0);
            end
            vq.alloc_rings();

            for (int unsigned i = 0; i < QUEUE_SIZE; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_list sg;
                virtio_sg_entry entry;
                bit [63:0] buf_addr;
                int unsigned desc_id;
                int unsigned len = 64 + ($urandom() % 1984);

                buf_addr = host0_mem.alloc(len, .align(64));
                if (buf_addr == '1)
                    `uvm_fatal("HOST_RECLAIM", $sformatf(
                        "queue cycle %0d buffer allocation failed at %0d",
                        cycle, i))
                entry.addr = buf_addr;
                entry.len = len;
                sg.entries.push_back(entry);
                sgs = new[1];
                sgs[0] = sg;
                desc_id = vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_id == '1)
                    `uvm_fatal("HOST_RECLAIM", $sformatf(
                        "queue cycle %0d add_buf failed at %0d", cycle, i))
                desc_ids.push_back(desc_id);
                buffers[desc_id] = buf_addr;
            end

            for (int unsigned i = 0; i < desc_ids.size(); i++) begin
                write_used_entry(vq, i, desc_ids[i], 64,
                                 used_idx + 1, host0_mem);
                used_idx++;
            end

            begin
                uvm_object token;
                int unsigned used_len;
                int unsigned polled = 0;
                while (vq.poll_used(token, used_len)) begin
                    polled++;
                end
                if (polled != QUEUE_SIZE)
                    `uvm_fatal("HOST_RECLAIM", $sformatf(
                        "queue cycle %0d polled %0d/%0d entries",
                        cycle, polled, QUEUE_SIZE))
            end

            foreach (buffers[desc_id])
                host0_mem.free(buffers[desc_id]);
            buffers.delete();
            desc_ids.delete();
            if (vq.get_free_count() != QUEUE_SIZE)
                `uvm_fatal("HOST_RECLAIM", $sformatf(
                    "queue cycle %0d did not reclaim descriptors", cycle))
            `uvm_info("HOST_RECLAIM", $sformatf(
                "queue cycle %0d reclaimed %0d data buffers", cycle,
                QUEUE_SIZE), UVM_LOW)
        end

        vq.free_rings();
        iommu.leak_check();
    endtask

    task test_multi_host_isolation();
        bit [63:0] host0_addr;
        bit [63:0] host1_addr;
        byte host0_data[64];
        byte host1_data[64];
        byte read_data[];

        foreach (host0_data[i]) host0_data[i] = 8'hA0 + i;
        foreach (host1_data[i]) host1_data[i] = 8'h50 + i;
        host0_addr = host0_mem.alloc(64, .align(64));
        host1_addr = host1_mem.alloc(64, .align(64));
        if ((host0_addr == '1) || (host1_addr == '1))
            `uvm_fatal("HOST_RECLAIM", "multi-Host allocation failed")
        host0_mem.write_mem(host0_addr, host0_data);
        host1_mem.write_mem(host1_addr, host1_data);
        host0_mem.read_mem(host0_addr, 64, read_data);
        foreach (host0_data[i])
            if (read_data[i] != host0_data[i])
                `uvm_fatal("HOST_RECLAIM", "Host 0 backing data mismatch")
        host0_mem.free(host0_addr);
        host1_mem.free(host1_addr);
        `uvm_info("HOST_RECLAIM",
                  "multi-Host memory isolation and reuse PASSED", UVM_LOW)
    endtask
endclass : virtio_host_mem_reclaim_test

`endif
