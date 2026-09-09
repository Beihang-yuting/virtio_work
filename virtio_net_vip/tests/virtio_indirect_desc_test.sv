`ifndef VIRTIO_INDIRECT_DESC_TEST_SV
`define VIRTIO_INDIRECT_DESC_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// ============================================================================
// virtio_indirect_desc_test
//
// Focused regression for virtio 1.2 indirect descriptors.  Both ring formats
// must encode three SG entries in a DMA-visible indirect table while consuming
// exactly one descriptor in their main ring.
// ============================================================================

// The nested-table request is intentionally illegal.  Catch only that
// expected validation report so an accepted request or any unrelated error
// still fails this regression.
class virtio_indirect_desc_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_indirect_desc_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_id() == "VQ_INDIRECT") && (get_severity() == UVM_ERROR)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_indirect_desc_error_catcher

class virtio_tx_indirect_feature_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_tx_indirect_feature_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_id() == "ATOMIC_OPS") && (get_severity() == UVM_ERROR)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_tx_indirect_feature_error_catcher

class virtio_dataplane_indirect_feature_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_dataplane_indirect_feature_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_id() == "TX_ENG") && (get_severity() == UVM_ERROR)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_dataplane_indirect_feature_error_catcher

class virtio_tx_queue_full_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_tx_queue_full_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_id() == "SPLIT_VQ") && (get_severity() == UVM_ERROR)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_tx_queue_full_error_catcher

// The dataplane TX API derives payload bytes from do_pack().  Keep the packet
// minimal and real so the feature-gate test reaches the public submit path.
class virtio_dataplane_indirect_test_packet extends uvm_object;
    `uvm_object_utils(virtio_dataplane_indirect_test_packet)

    byte unsigned data[$];

    function new(string name = "virtio_dataplane_indirect_test_packet");
        super.new(name);
        data = '{8'h11, 8'h22, 8'h33, 8'h44, 8'h55, 8'h66, 8'h77, 8'h88};
    endfunction

    virtual function void do_pack(uvm_packer packer);
        super.do_pack(packer);
        foreach (data[i])
            packer.pack_field_int(data[i], 8);
        // submit_packet() calls do_pack() directly, so make the emitted byte
        // count visible through the same public UVM packer API it queries.
        packer.set_packed_size();
    endfunction
endclass : virtio_dataplane_indirect_test_packet

// TX feature-gate testing needs the atomic submission path but no PCIe side
// effects.  Keep the transport real enough for tx_submit while suppressing
// its final notification write.
class virtio_indirect_desc_test_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_indirect_desc_test_transport)

    int unsigned kick_count;

    function new(string name = "virtio_indirect_desc_test_transport");
        super.new(name);
        kick_count = 0;
    endfunction

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx, bit wrap_counter);
        kick_count++;
    endtask
endclass : virtio_indirect_desc_test_transport

class virtio_indirect_desc_test extends uvm_test;
    `uvm_component_utils(virtio_indirect_desc_test)

    // All indirect-descriptor subtests share one Host-0 manager owned by the
    // external host_mem project.  This makes leaked SG/data buffers visible at
    // the end of the complete descriptor regression.
    virtio_shared_mem_fixture mem_fixture;
    host_mem_manager shared_mem;
    bit [63:0] owned_sg_buffers[$];

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem_fixture = virtio_shared_mem_fixture::type_id::create(
            "indirect_mem_fixture");
        if (!mem_fixture.create_host(
                0, 64'h0000_0001_4000_0000,
                64'h0000_0001_41FF_FFFF, HOST_MEM_RANDOM))
            `uvm_fatal("INDIRECT_TEST", "failed to create Host-0 memory")
        shared_mem = mem_fixture.get_host(0);
        if (shared_mem == null)
            `uvm_fatal("INDIRECT_TEST", "Host-0 memory handle is null")
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_split_indirect_descriptor();
        test_packed_indirect_descriptor();
        test_tx_indirect_feature_gate();
        test_dataplane_tx_indirect_feature_gate();
        test_dataplane_tx_queue_full_cleanup();
        test_atomic_tx_queue_full_cleanup();

        shared_mem.leak_check();

        `uvm_info("INDIRECT_TEST", "All indirect descriptor tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // Allocate three one-entry SG lists: one device-readable followed by two
    // device-writable entries.  This makes the expected table flags explicit.
    function void build_three_sg(host_mem_manager mem, ref virtio_sg_list sgs[]);
        int unsigned lengths[3] = '{32, 48, 64};

        sgs = new[3];
        for (int unsigned i = 0; i < 3; i++) begin
            virtio_sg_entry entry;
            bit [63:0] buf_addr;

            buf_addr = mem.alloc(lengths[i], .align(16));
            assert(buf_addr != '1)
                else `uvm_fatal("INDIRECT_TEST", "failed to allocate SG buffer")
            entry.addr = buf_addr;
            entry.len  = lengths[i];
            sgs[i].entries.push_back(entry);
            owned_sg_buffers.push_back(buf_addr);
        end
    endfunction

    function void release_owned_sg_buffers();
        foreach (owned_sg_buffers[i])
            shared_mem.free(owned_sg_buffers[i]);
        owned_sg_buffers.delete();
    endfunction

    function void read_desc(host_mem_manager mem,
                            bit [63:0] base,
                            int unsigned index,
                            ref bit [63:0] addr,
                            ref bit [31:0] len,
                            ref bit [15:0] flags,
                            ref bit [15:0] next);
        byte data[];

        mem.read_mem(base + index * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        flags = {data[13], data[12]};
        next  = {data[15], data[14]};
    endfunction

    function void read_packed_desc(host_mem_manager mem,
                                   bit [63:0] base,
                                   int unsigned index,
                                   ref bit [63:0] addr,
                                   ref bit [31:0] len,
                                   ref bit [15:0] id,
                                   ref bit [15:0] flags);
        byte data[];

        mem.read_mem(base + index * 16, 16, data);
        addr  = {data[7], data[6], data[5], data[4], data[3], data[2], data[1], data[0]};
        len   = {data[11], data[10], data[9], data[8]};
        id    = {data[13], data[12]};
        flags = {data[15], data[14]};
    endfunction

    function void check_indirect_table(virtqueue_base vq,
                                        host_mem_manager mem,
                                        virtio_iommu_model iommu,
                                        int unsigned head,
                                        virtio_sg_list sgs[],
                                        bit is_packed);
        bit [63:0] main_addr;
        bit [31:0] main_len;
        bit [15:0] main_flags;
        bit [15:0] main_next;
        bit [63:0] table_gpa;
        iommu_fault_e fault;
        bit translated;

        if (is_packed)
            read_packed_desc(mem, vq.desc_table_addr, head,
                             main_addr, main_len, main_next, main_flags);
        else
            read_desc(mem, vq.desc_table_addr, head,
                      main_addr, main_len, main_flags, main_next);
        assert((main_flags & VIRTQ_DESC_F_INDIRECT) != 0)
            else `uvm_fatal("INDIRECT_TEST", "main descriptor lacks INDIRECT flag")
        assert((main_flags & (VIRTQ_DESC_F_NEXT | VIRTQ_DESC_F_WRITE)) == 0)
            else `uvm_fatal("INDIRECT_TEST", "main descriptor carries NEXT or WRITE")
        assert(main_len == 3 * 16)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "indirect table length=%0d, expected 48", main_len))

        translated = iommu.translate(vq.bdf, main_addr, main_len,
                                     DMA_TO_DEVICE, table_gpa, fault);
        assert(translated)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "main descriptor does not map its table (fault=%s)", fault.name()))
        assert((table_gpa & 64'hf) == 0)
            else `uvm_fatal("INDIRECT_TEST", "indirect table GPA is not 16-byte aligned")

        for (int unsigned i = 0; i < 3; i++) begin
            bit [63:0] table_addr;
            bit [31:0] table_len;
            bit [15:0] table_flags;
            bit [15:0] table_next;
            bit [15:0] expected_flags;

            read_desc(mem, table_gpa, i,
                      table_addr, table_len, table_flags, table_next);
            expected_flags = (i < 2) ? VIRTQ_DESC_F_NEXT : 16'h0;
            if (i >= 1)
                expected_flags |= VIRTQ_DESC_F_WRITE;

            assert(table_addr == sgs[i].entries[0].addr)
                else `uvm_fatal("INDIRECT_TEST", $sformatf(
                    "table descriptor %0d address mismatch", i))
            assert(table_len == sgs[i].entries[0].len)
                else `uvm_fatal("INDIRECT_TEST", $sformatf(
                    "table descriptor %0d length mismatch", i))
            assert(table_flags == expected_flags)
                else `uvm_fatal("INDIRECT_TEST", $sformatf(
                    "table descriptor %0d flags=0x%04h expected=0x%04h",
                    i, table_flags, expected_flags))
            assert(table_next == ((i < 2) ? i + 1 : 0))
                else `uvm_fatal("INDIRECT_TEST", $sformatf(
                    "table descriptor %0d next=%0d", i, table_next))
        end
    endfunction

    function void complete_split(host_mem_manager mem,
                                 split_virtqueue vq,
                                 int unsigned head,
                                 int unsigned used_len);
        byte used_entry[];
        byte used_idx[];

        used_entry = new[8];
        for (int unsigned i = 0; i < 4; i++) begin
            used_entry[i]   = head[i * 8 +: 8];
            used_entry[i+4] = used_len[i * 8 +: 8];
        end
        used_idx = new[2];
        used_idx[0] = 8'h01;
        used_idx[1] = 8'h00;
        mem.write_mem(vq.device_ring_addr + 4, used_entry);
        mem.write_mem(vq.device_ring_addr + 2, used_idx);
    endfunction

    function void complete_packed(host_mem_manager mem,
                                  packed_virtqueue vq,
                                  int unsigned head);
        byte flags[];
        bit [15:0] value;

        mem.read_mem(vq.desc_table_addr + head * 16 + 14, 2, flags);
        value = {flags[1], flags[0]} | VIRTQ_DESC_F_USED;
        flags[0] = value[7:0];
        flags[1] = value[15:8];
        mem.write_mem(vq.desc_table_addr + head * 16 + 14, flags);
    endfunction

    task test_split_indirect_descriptor();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("split_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("split_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("split_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("split_wait_pol");
        split_virtqueue vq;
        virtio_sg_list sgs[];
        uvm_event token;
        uvm_object completed_token;
        int unsigned completed_len;
        int unsigned head;
        bit used;
        uvm_object detached_tokens[$];
        virtio_indirect_desc_error_catcher nested_error;
        virtio_indirect_desc_error_catcher overflow_error;
        int unsigned maps_before;
        int unsigned unmaps_before;
        bit [63:0] saved_addr;
        bit [31:0] saved_len;
        bit [63:0] extra_iova;

        mem = shared_mem;
        vq = split_virtqueue::type_id::create("split_vq");
        vq.setup(0, 16, mem, iommu, barrier, err_inj, wait_pol, 16'h0700);
        vq.alloc_rings();
        build_three_sg(mem, sgs);
        token = new("split_token");

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "split indirect submit failed")
        assert(vq.get_free_count() == 15)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "split main ring consumed %0d descriptors, expected 1", 16 - vq.get_free_count()))
        assert(vq.get_indirect_table_count() == 1)
            else `uvm_fatal("INDIRECT_TEST", "split table record missing")
        check_indirect_table(vq, mem, iommu, head, sgs, 1'b0);

        complete_split(mem, vq, head, 144);
        used = vq.poll_used(completed_token, completed_len);
        assert(used) else `uvm_fatal("INDIRECT_TEST", "split indirect completion not consumed")
        assert(completed_token == token && completed_len == 144)
            else `uvm_fatal("INDIRECT_TEST", "split completion token or length mismatch")
        assert(vq.get_free_count() == 16)
            else `uvm_fatal("INDIRECT_TEST", "split completion did not reclaim main descriptor")
        assert(vq.get_indirect_table_count() == 0 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "split completion leaked table or IOMMU mapping")

        sgs[0].entries[0].is_indirect = 1'b1;
        nested_error = new("split_nested_error");
        uvm_report_cb::add(null, nested_error);
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        uvm_report_cb::delete(null, nested_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 && nested_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "split accepted nested indirect descriptor")
        sgs[0].entries[0].is_indirect = 1'b0;

        // The count sum must be checked before it wraps to a value that makes
        // the pre-scan access a fourth list when only three exist.
        overflow_error = new("split_overflow_error");
        uvm_report_cb::add(null, overflow_error);
        maps_before = iommu.total_maps;
        unmaps_before = iommu.total_unmaps;
        head = vq.add_buf(sgs, 32'hffff_ffff, 5, token, 1'b1);
        uvm_report_cb::delete(null, overflow_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == maps_before && iommu.total_unmaps == unmaps_before &&
               overflow_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "split accepted overflowing indirect SG count")

        saved_addr = sgs[0].entries[0].addr;
        saved_len  = sgs[0].entries[0].len;
        sgs[0].entries[0].addr = 64'hffff_ffff_ffff_fff0;
        sgs[0].entries[0].len  = 32;
        overflow_error = new("split_addr_range_error");
        uvm_report_cb::add(null, overflow_error);
        maps_before = iommu.total_maps;
        unmaps_before = iommu.total_unmaps;
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        uvm_report_cb::delete(null, overflow_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == maps_before && iommu.total_unmaps == unmaps_before &&
               overflow_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "split accepted wrapping indirect SG range")
        sgs[0].entries[0].addr = saved_addr;
        sgs[0].entries[0].len  = saved_len;

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "split free_rings setup failed")
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "split second free_rings setup failed")
        extra_iova = vq.dma_map_buf(sgs[0].entries[0].addr,
                                    sgs[0].entries[0].len, DMA_TO_DEVICE);
        vq.free_rings();
        assert(vq.get_indirect_table_count() == 0 && vq.get_pending_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "split free_rings leaked indirect table resources")

        vq.alloc_rings();
        assert(vq.get_free_count() == 16 && vq.get_pending_count() == 0)
            else `uvm_fatal("INDIRECT_TEST", "split realloc retained stale descriptor state")
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "split detach setup failed")
        vq.detach_all_unused(detached_tokens);
        assert(detached_tokens.size() == 1 && vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "split detach leaked indirect table resources")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "split indirect descriptor test PASSED", UVM_LOW)
        release_owned_sg_buffers();
    endtask

    task test_packed_indirect_descriptor();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("packed_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("packed_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("packed_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("packed_wait_pol");
        packed_virtqueue vq;
        virtio_sg_list sgs[];
        uvm_event token;
        uvm_object completed_token;
        int unsigned completed_len;
        int unsigned head;
        bit used;
        uvm_object detached_tokens[$];
        virtio_indirect_desc_error_catcher nested_error;
        virtio_indirect_desc_error_catcher overflow_error;
        int unsigned maps_before;
        int unsigned unmaps_before;
        bit [63:0] saved_addr;
        bit [31:0] saved_len;
        bit [63:0] extra_iova;

        mem = shared_mem;
        vq = packed_virtqueue::type_id::create("packed_vq");
        vq.setup(1, 16, mem, iommu, barrier, err_inj, wait_pol, 16'h0701);
        vq.alloc_rings();
        build_three_sg(mem, sgs);
        token = new("packed_token");

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "packed indirect submit failed")
        assert(vq.get_free_count() == 15)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "packed main ring consumed %0d descriptors, expected 1", 16 - vq.get_free_count()))
        assert(vq.get_indirect_table_count() == 1)
            else `uvm_fatal("INDIRECT_TEST", "packed table record missing")
        check_indirect_table(vq, mem, iommu, head, sgs, 1'b1);

        complete_packed(mem, vq, head);
        used = vq.poll_used(completed_token, completed_len);
        assert(used) else `uvm_fatal("INDIRECT_TEST", "packed indirect completion not consumed")
        assert(completed_token == token && completed_len == 3 * 16)
            else `uvm_fatal("INDIRECT_TEST", "packed completion token or length mismatch")
        assert(vq.get_free_count() == 16)
            else `uvm_fatal("INDIRECT_TEST", "packed completion did not reclaim main descriptor")
        assert(vq.get_indirect_table_count() == 0 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "packed completion leaked table or IOMMU mapping")

        sgs[2].entries[0].is_indirect = 1'b1;
        nested_error = new("packed_nested_error");
        uvm_report_cb::add(null, nested_error);
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        uvm_report_cb::delete(null, nested_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 && nested_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "packed accepted nested indirect descriptor")
        sgs[2].entries[0].is_indirect = 1'b0;

        // This deliberately wraps to four.  Validation must reject the
        // original count before scanning sgs[3], which does not exist.
        overflow_error = new("packed_overflow_error");
        uvm_report_cb::add(null, overflow_error);
        maps_before = iommu.total_maps;
        unmaps_before = iommu.total_unmaps;
        head = vq.add_buf(sgs, 32'hffff_ffff, 5, token, 1'b1);
        uvm_report_cb::delete(null, overflow_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == maps_before && iommu.total_unmaps == unmaps_before &&
               overflow_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "packed accepted overflowing indirect SG count")

        saved_addr = sgs[0].entries[0].addr;
        saved_len  = sgs[0].entries[0].len;
        sgs[0].entries[0].addr = 64'hffff_ffff_ffff_fff0;
        sgs[0].entries[0].len  = 32;
        overflow_error = new("packed_addr_range_error");
        uvm_report_cb::add(null, overflow_error);
        maps_before = iommu.total_maps;
        unmaps_before = iommu.total_unmaps;
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        uvm_report_cb::delete(null, overflow_error);
        assert(head == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == maps_before && iommu.total_unmaps == unmaps_before &&
               overflow_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "packed accepted wrapping indirect SG range")
        sgs[0].entries[0].addr = saved_addr;
        sgs[0].entries[0].len  = saved_len;

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "packed free_rings setup failed")
        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "packed second free_rings setup failed")
        extra_iova = vq.dma_map_buf(sgs[0].entries[0].addr,
                                    sgs[0].entries[0].len, DMA_TO_DEVICE);
        vq.free_rings();
        assert(vq.get_indirect_table_count() == 0 && vq.get_pending_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "packed free_rings leaked indirect table resources")

        vq.alloc_rings();
        assert(vq.get_free_count() == 16 && vq.get_pending_count() == 0)
            else `uvm_fatal("INDIRECT_TEST", "packed realloc retained stale descriptor state")

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "packed detach setup failed")
        vq.detach_all_unused(detached_tokens);
        assert(detached_tokens.size() == 1 && vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "packed detach leaked indirect table resources")

        head = vq.add_buf(sgs, 1, 2, token, 1'b1);
        assert(head != '1) else `uvm_fatal("INDIRECT_TEST", "packed reset setup failed")
        vq.reset_queue();
        assert(vq.get_indirect_table_count() == 0 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "packed reset leaked indirect table resources")

        `uvm_info("INDIRECT_TEST", "packed indirect descriptor test PASSED", UVM_LOW)
        release_owned_sg_buffers();
    endtask

    task test_tx_indirect_feature_gate();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("tx_gate_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("tx_gate_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("tx_gate_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("tx_gate_wait_pol");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("tx_gate_vq_mgr");
        virtio_indirect_desc_test_transport transport =
            virtio_indirect_desc_test_transport::type_id::create("tx_gate_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("tx_gate_ops");
        virtqueue_base base_vq;
        split_virtqueue vq;
        virtio_net_hdr_t net_hdr;
        uvm_event token;
        uvm_object completed[$];
        int unsigned desc_id;
        int unsigned budget;
        virtio_tx_indirect_feature_error_catcher feature_error;

        mem = shared_mem;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0702;
        base_vq = vq_mgr.create_queue(0, 16, VQ_SPLIT);
        assert($cast(vq, base_vq))
            else `uvm_fatal("INDIRECT_TEST", "failed to create TX split queue")
        vq.alloc_rings();

        transport.bdf = 16'h0702;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        token = new("tx_gate_token");
        net_hdr = '{default: 0};

        desc_id = '1;
        feature_error = new("tx_indirect_not_negotiated_error");
        uvm_report_cb::add(null, feature_error);
        ops.tx_submit(0, net_hdr, token, 1'b1, desc_id);
        uvm_report_cb::delete(null, feature_error);
        assert(desc_id == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 && iommu.total_maps == 0 &&
               feature_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST", "tx_submit accepted unnegotiated indirect descriptors")

        ops.negotiated_features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;
        desc_id = '1;
        ops.tx_submit(0, net_hdr, token, 1'b1, desc_id);
        assert(desc_id != '1 && vq.get_free_count() == 15 &&
               vq.get_indirect_table_count() == 1)
            else `uvm_fatal("INDIRECT_TEST", "tx_submit rejected negotiated indirect descriptors")

        complete_split(mem, vq, desc_id, 0);
        budget = 1;
        ops.tx_complete(0, completed, budget);
        assert(completed.size() == 1 && completed[0] == token &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "negotiated indirect TX completion leaked resources")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "TX indirect feature-gate test PASSED", UVM_LOW)
    endtask

    task test_dataplane_tx_indirect_feature_gate();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("dataplane_gate_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("dataplane_gate_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("dataplane_gate_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("dataplane_gate_wait_pol");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("dataplane_gate_vq_mgr");
        virtio_net_dataplane dataplane =
            virtio_net_dataplane::type_id::create("dataplane_gate");
        virtqueue_base base_vq;
        split_virtqueue vq;
        virtio_dataplane_indirect_test_packet token;
        uvm_object completed[$];
        bit [63:0] features;
        int unsigned desc_id;
        virtio_dataplane_indirect_feature_error_catcher feature_error;

        mem = shared_mem;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0703;
        base_vq = vq_mgr.create_queue(0, 16, VQ_SPLIT);
        assert($cast(vq, base_vq))
            else `uvm_fatal("INDIRECT_TEST", "failed to create dataplane TX split queue")
        vq.alloc_rings();

        features = '0;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            vq_mgr, mem, iommu, 16'h0703);
        token = virtio_dataplane_indirect_test_packet::type_id::create("dataplane_gate_token");

        desc_id = '1;
        feature_error = new("dataplane_tx_indirect_not_negotiated_error");
        uvm_report_cb::add(null, feature_error);
        dataplane.tx_engine.submit_packet(0, token, 1'b1, desc_id);
        uvm_report_cb::delete(null, feature_error);
        assert(desc_id == '1 && vq.get_free_count() == 16 &&
               vq.get_indirect_table_count() == 0 && iommu.total_maps == 0 &&
               dataplane.tx_engine.total_tx_packets == 0 &&
               feature_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST",
                "dataplane TX accepted unnegotiated indirect descriptors")

        features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            vq_mgr, mem, iommu, 16'h0703);
        desc_id = '1;
        dataplane.tx_engine.submit_packet(0, token, 1'b1, desc_id);
        assert(desc_id != '1 && vq.get_free_count() == 15 &&
               vq.get_indirect_table_count() == 1)
            else `uvm_fatal("INDIRECT_TEST",
                "dataplane TX rejected negotiated indirect descriptors")

        complete_split(mem, vq, desc_id, 0);
        dataplane.tx_engine.complete_tx(0, 1, completed);
        assert(completed.size() == 1 && completed[0] == token &&
               vq.get_indirect_table_count() == 0 &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST",
                "negotiated dataplane TX completion leaked resources")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "dataplane TX indirect feature-gate test PASSED", UVM_LOW)
    endtask

    // A full two-entry split queue rejects a second normal TX chain.  The
    // rejected atomic submission must leave only the first submission's maps,
    // token, add count, and notification visible.
    task test_atomic_tx_queue_full_cleanup();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("atomic_full_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("atomic_full_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("atomic_full_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("atomic_full_wait_pol");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("atomic_full_vq_mgr");
        virtio_indirect_desc_test_transport transport =
            virtio_indirect_desc_test_transport::type_id::create("atomic_full_transport");
        virtio_atomic_ops ops = virtio_atomic_ops::type_id::create("atomic_full_ops");
        virtqueue_base base_vq;
        split_virtqueue vq;
        virtio_net_hdr_t net_hdr;
        uvm_event filler_token;
        uvm_event rejected_token;
        uvm_object completed[$];
        int unsigned filler_desc;
        int unsigned desc_id;
        int unsigned budget;
        int unsigned active_maps_before;
        int unsigned pending_before;
        int unsigned add_ops_before;
        int unsigned kicks_before;
        virtio_tx_queue_full_error_catcher queue_full_error;

        mem = shared_mem;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0704;
        base_vq = vq_mgr.create_queue(0, 2, VQ_SPLIT);
        assert($cast(vq, base_vq))
            else `uvm_fatal("INDIRECT_TEST", "failed to create atomic queue-full split queue")
        vq.alloc_rings();

        transport.bdf = 16'h0704;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.mem = mem;
        ops.iommu = iommu;
        ops.wait_pol = wait_pol;
        net_hdr = '{default: 0};
        filler_token = new("atomic_full_filler");
        rejected_token = new("atomic_full_rejected");

        ops.tx_submit(0, net_hdr, filler_token, 1'b0, filler_desc);
        assert(filler_desc != '1 && vq.get_free_count() == 0)
            else `uvm_fatal("INDIRECT_TEST", "atomic queue-full setup submission failed")

        active_maps_before = iommu.total_maps - iommu.total_unmaps;
        pending_before = vq.get_pending_count();
        add_ops_before = vq.total_add_buf_ops;
        kicks_before = transport.kick_count;
        desc_id = '1;
        queue_full_error = new("atomic_tx_queue_full_error");
        uvm_report_cb::add(null, queue_full_error);
        ops.tx_submit(0, net_hdr, rejected_token, 1'b0, desc_id);
        uvm_report_cb::delete(null, queue_full_error);
        assert(desc_id == '1 &&
               (iommu.total_maps - iommu.total_unmaps) == active_maps_before &&
               vq.get_pending_count() == pending_before &&
               vq.total_add_buf_ops == add_ops_before &&
               transport.kick_count == kicks_before &&
               queue_full_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST",
                "atomic TX queue-full failure retained maps, submission state, or kick")

        complete_split(mem, vq, filler_desc, 0);
        budget = 1;
        ops.tx_complete(0, completed, budget);
        assert(completed.size() == 1 && completed[0] == filler_token &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "atomic queue-full cleanup disturbed the prior TX")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "atomic TX queue-full cleanup test PASSED", UVM_LOW)
    endtask

    // The dataplane API allocates both TX buffers before it reaches add_buf().
    // A second direct submission to a full queue must release those temporary
    // buffers and must not create another tracked packet or success statistic.
    task test_dataplane_tx_queue_full_cleanup();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("dataplane_full_iommu");
        virtio_memory_barrier_model barrier =
            virtio_memory_barrier_model::type_id::create("dataplane_full_barrier");
        virtqueue_error_injector err_inj =
            virtqueue_error_injector::type_id::create("dataplane_full_err_inj");
        virtio_wait_policy wait_pol = virtio_wait_policy::type_id::create("dataplane_full_wait_pol");
        virtqueue_manager vq_mgr = virtqueue_manager::type_id::create("dataplane_full_vq_mgr");
        virtio_net_dataplane dataplane =
            virtio_net_dataplane::type_id::create("dataplane_full");
        virtqueue_base base_vq;
        split_virtqueue vq;
        virtio_dataplane_indirect_test_packet filler_token;
        virtio_dataplane_indirect_test_packet rejected_token;
        uvm_object completed[$];
        bit [63:0] features;
        int unsigned filler_desc;
        int unsigned desc_id;
        int unsigned active_maps_before;
        int unsigned pending_before;
        int unsigned add_ops_before;
        longint unsigned packets_before;
        longint unsigned bytes_before;
        longint unsigned sg_count_before;
        longint unsigned errors_before;
        virtio_tx_queue_full_error_catcher queue_full_error;

        mem = shared_mem;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = 16'h0705;
        base_vq = vq_mgr.create_queue(0, 2, VQ_SPLIT);
        assert($cast(vq, base_vq))
            else `uvm_fatal("INDIRECT_TEST", "failed to create dataplane queue-full split queue")
        vq.alloc_rings();

        features = '0;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            vq_mgr, mem, iommu, 16'h0705);
        filler_token = virtio_dataplane_indirect_test_packet::type_id::create(
            "dataplane_full_filler");
        rejected_token = virtio_dataplane_indirect_test_packet::type_id::create(
            "dataplane_full_rejected");

        dataplane.tx_engine.submit_packet(0, filler_token, 1'b0, filler_desc);
        assert(filler_desc != '1 && vq.get_free_count() == 0)
            else `uvm_fatal("INDIRECT_TEST", "dataplane queue-full setup submission failed")

        active_maps_before = iommu.total_maps - iommu.total_unmaps;
        pending_before = vq.get_pending_count();
        add_ops_before = vq.total_add_buf_ops;
        packets_before = dataplane.tx_engine.total_tx_packets;
        bytes_before = dataplane.tx_engine.total_tx_bytes;
        sg_count_before = dataplane.tx_engine.total_tx_sg_count;
        errors_before = dataplane.tx_engine.total_tx_errors;
        desc_id = '1;
        queue_full_error = new("dataplane_tx_queue_full_error");
        uvm_report_cb::add(null, queue_full_error);
        dataplane.tx_engine.submit_packet(0, rejected_token, 1'b0, desc_id);
        uvm_report_cb::delete(null, queue_full_error);
        assert(desc_id == '1 &&
               (iommu.total_maps - iommu.total_unmaps) == active_maps_before &&
               vq.get_pending_count() == pending_before &&
               vq.total_add_buf_ops == add_ops_before &&
               dataplane.tx_engine.total_tx_packets == packets_before &&
               dataplane.tx_engine.total_tx_bytes == bytes_before &&
               dataplane.tx_engine.total_tx_sg_count == sg_count_before &&
               dataplane.tx_engine.total_tx_errors == errors_before &&
               queue_full_error.caught_count == 1)
            else `uvm_fatal("INDIRECT_TEST",
                "dataplane TX queue-full failure retained maps, token, or statistics")

        complete_split(mem, vq, filler_desc, 0);
        dataplane.tx_engine.complete_tx(0, 1, completed);
        assert(completed.size() == 1 && completed[0] == filler_token &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "dataplane queue-full cleanup disturbed the prior TX")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "dataplane TX queue-full cleanup test PASSED", UVM_LOW)
    endtask

endclass : virtio_indirect_desc_test

`endif // VIRTIO_INDIRECT_DESC_TEST_SV
