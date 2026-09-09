`ifndef VIRTIO_DESC_CORRUPTION_TEST_SV
`define VIRTIO_DESC_CORRUPTION_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// Focused, explicit post-publication descriptor corruption test.  The test
// deliberately mutates the shared Host memory image after add_buf() has
// published a descriptor, which is the same address path a passive REAL_DUT
// fault injector will use later.
class virtio_desc_corruption_test extends uvm_test;
    `uvm_component_utils(virtio_desc_corruption_test)

    host_mem_manager              mem;
    virtio_iommu_model            iommu;
    virtio_memory_barrier_model   barrier;
    virtqueue_error_injector     err_inj;
    virtio_wait_policy             wait_pol;

    function new(string name = "virtio_desc_corruption_test",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem = host_mem_manager::type_id::create("corruption_mem");
        mem.init_region(64'h0000_0001_5000_0000,
                        64'h0000_0001_500F_FFFF);
        iommu = virtio_iommu_model::type_id::create("corruption_iommu");
        barrier = virtio_memory_barrier_model::type_id::create(
            "corruption_barrier");
        err_inj = virtqueue_error_injector::type_id::create(
            "corruption_err_inj");
        wait_pol = virtio_wait_policy::type_id::create("corruption_wait_pol");
        iommu.strict_permission_check = 0;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_split_fields();
        test_packed_fields();
        test_timed_injection();
        test_any_phase_is_one_shot_per_operation();
        test_rejects_invalid_target();
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("DESC_CORRUPTION",
                  "explicit descriptor corruption tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // VQ_FAULT_ANY matches the first applicable boundary of one queue
    // operation.  A kick/complete path may call both a pre and post hook, but
    // one configured fault must not mutate the same descriptor twice merely
    // because two phases were observed.  A subsequent operation may consume
    // the configured rule again according to its normal countdown/probability.
    task test_any_phase_is_one_shot_per_operation();
        split_virtqueue vq;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        virtio_sg_list sg;
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        byte data[];
        int unsigned head;
        int unsigned semantic_before;
        int unsigned corruption_before;
        string why;

        vq = split_virtqueue::type_id::create("any_phase_split_vq");
        vq.setup(3, 4, mem, iommu, barrier, err_inj, wait_pol, 16'h1503, 0);
        vq.alloc_rings();
        addr = mem.alloc(64, .align(16));
        if (addr == '1)
            `uvm_fatal("DESC_CORRUPTION", "ANY-phase data allocation failed")
        entry.addr = addr;
        entry.len = 64;
        sg.entries.push_back(entry);
        sgs = new[1];
        sgs[0] = sg;
        head = vq.add_buf(sgs, 1, 0, null, 0);
        if (head == '1)
            `uvm_fatal("DESC_CORRUPTION", "ANY-phase descriptor publication failed")

        err_inj.configure(VQ_ERR_ZERO_LEN_BUF, 0, 3, 100, VQ_FAULT_ANY);
        semantic_before = err_inj.injection_count();
        corruption_before = err_inj.descriptor_corruption_count();
        if (!vq.process_error_injection(VQ_FAULT_PRE_NOTIFY) ||
            vq.process_error_injection(VQ_FAULT_POST_NOTIFY))
            `uvm_fatal("DESC_CORRUPTION",
                       "VQ_FAULT_ANY did not stop after the first phase")
        if (err_inj.injection_count() != semantic_before + 1 ||
            err_inj.descriptor_corruption_count() != corruption_before + 1)
            `uvm_fatal("DESC_CORRUPTION",
                       "VQ_FAULT_ANY recorded more than one mutation per operation")

        // A new PRE_NOTIFY starts a new operation and can consume the same
        // configured rule again.
        if (!vq.process_error_injection(VQ_FAULT_PRE_NOTIFY))
            `uvm_fatal("DESC_CORRUPTION",
                       "VQ_FAULT_ANY did not re-arm for a new operation")
        if (err_inj.injection_count() != semantic_before + 2 ||
            err_inj.descriptor_corruption_count() != corruption_before + 2)
            `uvm_fatal("DESC_CORRUPTION",
                       "VQ_FAULT_ANY new-operation accounting is incorrect")

        vq.corrupt_published_descriptor(head, VQ_DESC_FIELD_LEN, 64, why);
        mem.read_mem(vq.desc_table_addr + head * 16 + 8, 4, data);
        len = {data[3], data[2], data[1], data[0]};
        if (len != 64)
            `uvm_fatal("DESC_CORRUPTION", "descriptor cleanup mutation failed")
        mem.free(addr);
        vq.free_rings();
    endtask

    function void read_desc(bit [63:0] base, int unsigned index,
                            ref bit [63:0] addr, ref bit [31:0] len,
                            ref bit [15:0] flags, ref bit [15:0] tail);
        byte data[];
        mem.read_mem(base + index * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4],
                 data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        flags = {data[13], data[12]};
        tail  = {data[15], data[14]};
    endfunction

    function void make_one_sg(ref virtio_sg_list sgs[],
                              input int unsigned length = 64);
        virtio_sg_entry entry;
        virtio_sg_list sg;
        entry.addr = mem.alloc(length, .align(16));
        entry.len = length;
        if (entry.addr == '1)
            `uvm_fatal("DESC_CORRUPTION", "data allocation failed")
        sg.entries.push_back(entry);
        sgs = new[1];
        sgs[0] = sg;
    endfunction

    task test_split_fields();
        split_virtqueue vq;
        virtio_sg_list sgs[];
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        bit [63:0] original_addr;
        string why;
        int unsigned head;

        vq = split_virtqueue::type_id::create("corruption_split_vq");
        vq.setup(0, 8, mem, iommu, barrier, err_inj, wait_pol, 16'h1500, 0);
        vq.alloc_rings();
        make_one_sg(sgs, 64);
        original_addr = sgs[0].entries[0].addr;
        head = vq.add_buf(sgs, 1, 0, null, 1'b0);
        if (head == '1)
            `uvm_fatal("DESC_CORRUPTION", "split descriptor publication failed")

        // The queue-facing wrapper derives the ring address/format from the
        // published queue object; fixtures do not need to expose raw BAR/GPA
        // addresses.  The injector-direct calls below retain coverage of the
        // low-level API used by specialized fault hooks.
        if (!vq.corrupt_published_descriptor(
                head, VQ_DESC_FIELD_LEN, 0, why))
            `uvm_fatal("DESC_CORRUPTION", {"LEN mutation failed: ", why})
        read_desc(vq.desc_table_addr, head, addr, len, flags, next);
        if (len != 0)
            `uvm_fatal("DESC_CORRUPTION", "split LEN mutation was not visible")

        if (!err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_SPLIT, vq.queue_size, head,
                VQ_DESC_FIELD_ADDR, 64'h0000_0000_DEAD_0000, why))
            `uvm_fatal("DESC_CORRUPTION", {"ADDR mutation failed: ", why})
        read_desc(vq.desc_table_addr, head, addr, len, flags, next);
        if (addr != 64'h0000_0000_DEAD_0000)
            `uvm_fatal("DESC_CORRUPTION", "split ADDR mutation was not visible")

        if (!err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_SPLIT, vq.queue_size, head,
                VQ_DESC_FIELD_FLAGS, VIRTQ_DESC_F_NEXT, why))
            `uvm_fatal("DESC_CORRUPTION", {"FLAGS mutation failed: ", why})
        read_desc(vq.desc_table_addr, head, addr, len, flags, next);
        if (flags != VIRTQ_DESC_F_NEXT)
            `uvm_fatal("DESC_CORRUPTION", "split FLAGS mutation was not visible")

        if (!err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_SPLIT, vq.queue_size, head,
                VQ_DESC_FIELD_NEXT, vq.queue_size, why))
            `uvm_fatal("DESC_CORRUPTION", {"NEXT mutation failed: ", why})
        read_desc(vq.desc_table_addr, head, addr, len, flags, next);
        if (next != vq.queue_size[15:0])
            `uvm_fatal("DESC_CORRUPTION", "split NEXT mutation was not visible")

        // ID is not encoded in a split descriptor; the helper must reject it.
        if (err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_SPLIT, vq.queue_size, head,
                VQ_DESC_FIELD_ID, 7, why))
            `uvm_fatal("DESC_CORRUPTION", "split ID corruption was accepted")

        mem.free(original_addr);
        vq.free_rings();
    endtask

    task test_packed_fields();
        packed_virtqueue vq;
        virtio_sg_list sgs[];
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] id;
        bit [15:0] flags;
        string why;
        int unsigned head;

        vq = packed_virtqueue::type_id::create("corruption_packed_vq");
        vq.setup(1, 8, mem, iommu, barrier, err_inj, wait_pol, 16'h1501, 0);
        vq.alloc_rings();
        make_one_sg(sgs, 64);
        head = vq.add_buf(sgs, 1, 0, null, 1'b0);
        if (head == '1)
            `uvm_fatal("DESC_CORRUPTION", "packed descriptor publication failed")

        if (!vq.corrupt_published_descriptor(
                head, VQ_DESC_FIELD_ID, 7, why))
            `uvm_fatal("DESC_CORRUPTION", {"ID mutation failed: ", why})
        begin
            byte data[];
            mem.read_mem(vq.desc_table_addr + head * 16, 16, data);
            addr = {data[7], data[6], data[5], data[4],
                    data[3], data[2], data[1], data[0]};
            len = {data[11], data[10], data[9], data[8]};
            id = {data[13], data[12]};
            flags = {data[15], data[14]};
        end
        if (id != 16'd7)
            `uvm_fatal("DESC_CORRUPTION", "packed ID mutation was not visible")

        if (!err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_PACKED, vq.queue_size, head,
                VQ_DESC_FIELD_FLAGS, 16'h0080, why))
            `uvm_fatal("DESC_CORRUPTION", {"packed FLAGS mutation failed: ", why})
        begin
            byte data[];
            mem.read_mem(vq.desc_table_addr + head * 16 + 14, 2, data);
            flags = {data[1], data[0]};
        end
        if (flags != 16'h0080)
            `uvm_fatal("DESC_CORRUPTION", "packed FLAGS mutation was not visible")

        // Packed rings have no serialized NEXT field; reject it explicitly.
        if (err_inj.corrupt_descriptor(
                mem, vq.desc_table_addr, VQ_PACKED, vq.queue_size, head,
                VQ_DESC_FIELD_NEXT, 1, why))
            `uvm_fatal("DESC_CORRUPTION", "packed NEXT corruption was accepted")

        mem.free(sgs[0].entries[0].addr);
        vq.free_rings();
    endtask

    task test_rejects_invalid_target();
        string why;
        bit ok;
        ok = err_inj.corrupt_descriptor(
            mem, 64'h0000_0001_5000_0000, VQ_SPLIT, 4, 4,
            VQ_DESC_FIELD_LEN, 1, why);
        if (ok)
            `uvm_fatal("DESC_CORRUPTION", "out-of-range descriptor index accepted")
        ok = err_inj.corrupt_descriptor(
            mem, 64'h0000_0001_5000_0000, VQ_CUSTOM, 4, 0,
            VQ_DESC_FIELD_LEN, 1, why);
        if (ok)
            `uvm_fatal("DESC_CORRUPTION", "custom ring corruption was accepted")
        ok = err_inj.corrupt_descriptor(
            mem, 64'hffff_ffff_ffff_fff0, VQ_SPLIT, 2, 1,
            VQ_DESC_FIELD_LEN, 1, why);
        if (ok)
            `uvm_fatal("DESC_CORRUPTION", "descriptor address wrap was accepted")
    endtask

    // Error injection configured through inject_desc_error() is consumed at
    // the queue notification boundary.  This keeps descriptor publication
    // normal and makes the fault observable by a model responder or a
    // passive REAL_DUT memory hook only after the driver kicks the queue.
    task test_timed_injection();
        split_virtqueue vq;
        virtio_sg_list sgs[];
        virtio_sg_entry entry;
        virtio_sg_list sg;
        bit [63:0] addr;
        byte data[];
        int unsigned head;
        int unsigned corruption_before;
        int unsigned semantic_before;

        vq = split_virtqueue::type_id::create("timed_split_vq");
        vq.setup(2, 4, mem, iommu, barrier, err_inj, wait_pol, 16'h1502, 0);
        vq.alloc_rings();
        addr = mem.alloc(64, .align(16));
        if (addr == '1)
            `uvm_fatal("DESC_CORRUPTION", "timed data allocation failed")
        entry.addr = addr;
        entry.len = 64;
        sg.entries.push_back(entry);
        sgs = new[1];
        sgs[0] = sg;
        head = vq.add_buf(sgs, 1, 0, null, 0);
        if (head == '1)
            `uvm_fatal("DESC_CORRUPTION", "timed descriptor publication failed")

        // A phase mismatch must not consume the operation countdown.
        err_inj.configure(VQ_ERR_ZERO_LEN_BUF, 0, 2, 100,
                          VQ_FAULT_POST_NOTIFY);
        // The phase filter itself must not consume the operation.
        corruption_before = err_inj.descriptor_corruption_count();
        if (err_inj.should_inject(2, VQ_FAULT_PRE_NOTIFY))
            `uvm_fatal("DESC_CORRUPTION", "POST_NOTIFY fault fired at PRE_NOTIFY")
        if (err_inj.descriptor_corruption_count() != corruption_before)
            `uvm_fatal("DESC_CORRUPTION", "phase mismatch consumed an injection")
        vq.kick();
        mem.read_mem(vq.desc_table_addr + head * 16 + 8, 4, data);
        if ({data[3], data[2], data[1], data[0]} != 0)
            `uvm_fatal("DESC_CORRUPTION", "POST_NOTIFY descriptor mutation missing")
        if (err_inj.last_injection_phase() != VQ_FAULT_POST_NOTIFY)
            `uvm_fatal("DESC_CORRUPTION", "wrong timing phase recorded")
        // The same configured fault is consumed exactly once by the kick.
        if (err_inj.descriptor_corruption_count() != corruption_before + 1)
            `uvm_fatal("DESC_CORRUPTION",
                       $sformatf("expected one timed corruption, got %0d",
                                 err_inj.descriptor_corruption_count()))

        // Semantic faults owned by a dedicated ring/interrupt hook must not
        // be falsely counted as descriptor corruption just because a queue
        // kick occurred.
        err_inj.configure(VQ_ERR_SPURIOUS_INTERRUPT, 0, 2, 100,
                          VQ_FAULT_POST_NOTIFY);
        corruption_before = err_inj.descriptor_corruption_count();
        semantic_before = err_inj.injection_count();
        vq.kick();
        if (err_inj.injection_count() != semantic_before ||
            err_inj.descriptor_corruption_count() != corruption_before)
            `uvm_fatal("DESC_CORRUPTION",
                       "unsupported semantic fault was falsely consumed")

        mem.free(addr);
        vq.free_rings();
    endtask
endclass : virtio_desc_corruption_test

`endif
