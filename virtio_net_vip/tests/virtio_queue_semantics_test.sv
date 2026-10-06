`ifndef VIRTIO_QUEUE_SEMANTICS_TEST_SV
`define VIRTIO_QUEUE_SEMANTICS_TEST_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Focused split/packed queue lifecycle test.  It deliberately keeps the
// device-side completion model small and deterministic while running repeated
// fill/drain cycles against one shared external host_mem manager.
class virtio_queue_semantics_test extends uvm_test;
    `uvm_component_utils(virtio_queue_semantics_test)

    localparam int unsigned QUEUE_SIZE = 8;
    localparam int unsigned CYCLES = 8;

    virtio_shared_mem_fixture mem_fixture;
    host_mem_manager mem;
    virtio_iommu_model iommu;
    virtio_vq_test_kit kit;

    function new(string name = "virtio_queue_semantics_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem_fixture = virtio_shared_mem_fixture::type_id::create(
            "queue_mem_fixture");
        if (!mem_fixture.create_host(
                0, 64'h0000_0001_3000_0000,
                64'h0000_0001_31FF_FFFF, HOST_MEM_RANDOM))
            `uvm_fatal("QUEUE_SEMANTICS", "failed to create Host-0 memory")
        mem = mem_fixture.get_host(0);
        if (mem == null)
            `uvm_fatal("QUEUE_SEMANTICS", "Host-0 memory handle is null")
        iommu = virtio_iommu_model::type_id::create("queue_iommu");
        kit = virtio_vq_test_kit::create_kit("queue", mem, iommu, 16'h0100);
        iommu.strict_permission_check = 0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_split_fill_drain_wrap();
        test_packed_fill_drain_wrap();
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("QUEUE_SEMANTICS",
                  "split/packed queue semantics test PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    task test_split_fill_drain_wrap();
        split_virtqueue vq;
        int unsigned device_used_idx = 0;

        vq = kit.make_split("semantic_split_vq", 0, QUEUE_SIZE, 16'h0100);

        for (int unsigned cycle = 0; cycle < CYCLES; cycle++) begin
            int unsigned desc_ids[$];
            bit [63:0] buffers[$];

            for (int unsigned i = 0; i < QUEUE_SIZE; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_list sg;
                virtio_sg_entry entry;
                bit [63:0] addr;
                int unsigned desc_id;

                addr = mem.alloc(128 + ($urandom() % 512), .align(64));
                if (addr == '1)
                    `uvm_fatal("QUEUE_SEMANTICS", "split data allocation failed")
                buffers.push_back(addr);
                entry.addr = addr;
                entry.len = 128;
                sg.entries.push_back(entry);
                sgs = new[1];
                sgs[0] = sg;
                desc_id = vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_id == '1)
                    `uvm_fatal("QUEUE_SEMANTICS", "split queue became full early")
                desc_ids.push_back(desc_id);
            end
            if (vq.get_free_count() != 0)
                `uvm_fatal("QUEUE_SEMANTICS", "split queue did not reach full")

            for (int unsigned i = 0; i < desc_ids.size(); i++) begin
                virtio_vq_test_kit::complete_split_at(
                    mem, vq, i, desc_ids[i], 256, device_used_idx + 1);
                device_used_idx++;
            end

            begin
                uvm_object token;
                int unsigned used_len;
                int unsigned polled = 0;
                while (vq.poll_used(token, used_len)) polled++;
                if (polled != QUEUE_SIZE)
                    `uvm_fatal("QUEUE_SEMANTICS", $sformatf(
                        "split cycle %0d polled %0d/%0d", cycle,
                        polled, QUEUE_SIZE))
            end
            foreach (buffers[i]) mem.free(buffers[i]);
            if (vq.get_free_count() != QUEUE_SIZE)
                `uvm_fatal("QUEUE_SEMANTICS", "split descriptors not recycled")
        end
        vq.free_rings();
        `uvm_info("QUEUE_SEMANTICS", $sformatf(
            "split full/drain/wrap cycles passed: %0d", CYCLES), UVM_LOW)
    endtask

    task mark_packed_used(
        packed_virtqueue vq,
        int unsigned ring_idx,
        bit used_wrap,
        int unsigned used_len
    );
        byte data[];
        bit [15:0] flags;
        byte new_data[16];

        mem.read_mem(vq.desc_table_addr + ring_idx * 16, 16, data);
        flags = {data[15], data[14]};
        flags &= ~(VIRTQ_DESC_F_AVAIL | VIRTQ_DESC_F_USED);
        if (used_wrap)
            flags |= VIRTQ_DESC_F_AVAIL | VIRTQ_DESC_F_USED;
        data[8] = used_len[7:0];
        data[9] = used_len[15:8];
        data[10] = used_len[23:16];
        data[11] = used_len[31:24];
        data[14] = flags[7:0];
        data[15] = flags[15:8];
        foreach (data[i]) new_data[i] = data[i];
        mem.write_mem(vq.desc_table_addr + ring_idx * 16, new_data);
    endtask

    task test_packed_fill_drain_wrap();
        packed_virtqueue vq;
        int unsigned device_idx = 0;
        bit device_wrap = 1;

        vq = kit.make_packed("semantic_packed_vq", 1, QUEUE_SIZE, 16'h0100);

        for (int unsigned cycle = 0; cycle < CYCLES; cycle++) begin
            bit [63:0] buffers[$];
            for (int unsigned i = 0; i < QUEUE_SIZE; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_list sg;
                virtio_sg_entry entry;
                bit [63:0] addr;
                int unsigned desc_idx;

                addr = mem.alloc(128 + ($urandom() % 512), .align(64));
                if (addr == '1)
                    `uvm_fatal("QUEUE_SEMANTICS", "packed data allocation failed")
                buffers.push_back(addr);
                entry.addr = addr;
                entry.len = 128;
                sg.entries.push_back(entry);
                sgs = new[1];
                sgs[0] = sg;
                desc_idx = vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_idx == '1)
                    `uvm_fatal("QUEUE_SEMANTICS", "packed queue became full early")
            end
            if (vq.get_free_count() != 0)
                `uvm_fatal("QUEUE_SEMANTICS", "packed queue did not reach full")

            for (int unsigned i = 0; i < QUEUE_SIZE; i++) begin
                mark_packed_used(vq, device_idx, device_wrap, 128);
                device_idx++;
                if (device_idx == QUEUE_SIZE) begin
                    device_idx = 0;
                    device_wrap = ~device_wrap;
                end
            end

            begin
                uvm_object token;
                int unsigned used_len;
                int unsigned polled = 0;
                while (vq.poll_used(token, used_len)) polled++;
                if (polled != QUEUE_SIZE)
                    `uvm_fatal("QUEUE_SEMANTICS", $sformatf(
                        "packed cycle %0d polled %0d/%0d", cycle,
                        polled, QUEUE_SIZE))
            end
            foreach (buffers[i]) mem.free(buffers[i]);
            if (vq.get_free_count() != QUEUE_SIZE)
                `uvm_fatal("QUEUE_SEMANTICS", "packed descriptors not recycled")
        end
        vq.free_rings();
        `uvm_info("QUEUE_SEMANTICS", $sformatf(
            "packed full/drain/wrap cycles passed: %0d", CYCLES), UVM_LOW)
    endtask
endclass : virtio_queue_semantics_test

`endif
