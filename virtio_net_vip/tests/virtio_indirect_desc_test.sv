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
        test_atomic_notify_cursor();
        test_atomic_rx_num_buffers_without_mrg();
        test_dataplane_engine_notifies_device();

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

        translated = iommu.translate_for_host(0, vq.bdf, main_addr, main_len,
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

    task test_split_indirect_descriptor();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("split_iommu");
        virtio_vq_test_kit kit;
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
        kit = virtio_vq_test_kit::create_kit("split", mem, iommu, 16'h0700);
        vq = kit.make_split("split_vq", 0, 16, 16'h0700);
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

        virtio_vq_test_kit::complete_split_at(mem, vq, 0, head, 144, 1);
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
        virtio_vq_test_kit kit;
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
        kit = virtio_vq_test_kit::create_kit("packed", mem, iommu, 16'h0701);
        vq = kit.make_packed("packed_vq", 1, 16, 16'h0701);
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

        virtio_vq_test_kit::complete_packed(mem, vq, head);
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
        virtio_vq_test_kit kit;
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("tx_gate_transport");
        virtio_atomic_ops ops;
        split_virtqueue vq;
        virtio_net_hdr_t net_hdr;
        uvm_event token;
        uvm_object completed[$];
        int unsigned desc_id;
        int unsigned budget;
        virtio_tx_indirect_feature_error_catcher feature_error;

        mem = shared_mem;
        kit = virtio_vq_test_kit::create_kit("tx_gate", mem, iommu, 16'h0702);
        vq = kit.add_split(0, 16);

        transport.bdf = 16'h0702;
        ops = kit.make_ops(transport, "tx_gate_ops");
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

        virtio_vq_test_kit::complete_split_at(mem, vq, 0, desc_id, 0, 1);
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
        virtio_vq_test_kit kit;
        virtio_net_dataplane dataplane =
            virtio_net_dataplane::type_id::create("dataplane_gate");
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("dataplane_gate_transport");
        virtio_atomic_ops ops;
        split_virtqueue vq;
        virtio_dataplane_indirect_test_packet token;
        uvm_object completed[$];
        bit [63:0] features;
        int unsigned desc_id;
        virtio_dataplane_indirect_feature_error_catcher feature_error;

        mem = shared_mem;
        kit = virtio_vq_test_kit::create_kit("dataplane_gate", mem, iommu, 16'h0703);
        vq = kit.add_split(0, 16);

        features = '0;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            16'h0703);
        transport.bdf = 16'h0703;
        ops = kit.make_ops(transport, "dataplane_gate_ops");
        ops.negotiated_features = features;
        dataplane.bind_ops(ops);
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
                            16'h0703);
        ops.negotiated_features = features;
        desc_id = '1;
        dataplane.tx_engine.submit_packet(0, token, 1'b1, desc_id);
        assert(desc_id != '1 && vq.get_free_count() == 15 &&
               vq.get_indirect_table_count() == 1)
            else `uvm_fatal("INDIRECT_TEST",
                "dataplane TX rejected negotiated indirect descriptors")

        virtio_vq_test_kit::complete_split_at(mem, vq, 0, desc_id, 0, 1);
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
        virtio_vq_test_kit kit;
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("atomic_full_transport");
        virtio_atomic_ops ops;
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
        kit = virtio_vq_test_kit::create_kit("atomic_full", mem, iommu, 16'h0704);
        vq = kit.add_split(0, 2);

        transport.bdf = 16'h0704;
        ops = kit.make_ops(transport, "atomic_full_ops");
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

        virtio_vq_test_kit::complete_split_at(mem, vq, 0, filler_desc, 0, 1);
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
        virtio_vq_test_kit kit;
        virtio_net_dataplane dataplane =
            virtio_net_dataplane::type_id::create("dataplane_full");
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("dataplane_full_transport");
        virtio_atomic_ops ops;
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
        kit = virtio_vq_test_kit::create_kit("dataplane_full", mem, iommu, 16'h0705);
        vq = kit.add_split(0, 2);

        features = '0;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 16,
                            16'h0705);
        transport.bdf = 16'h0705;
        ops = kit.make_ops(transport, "dataplane_full_ops");
        ops.negotiated_features = features;
        dataplane.bind_ops(ops);
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

        virtio_vq_test_kit::complete_split_at(mem, vq, 0, filler_desc, 0, 1);
        dataplane.tx_engine.complete_tx(0, 1, completed);
        assert(completed.size() == 1 && completed[0] == filler_token &&
               iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "dataplane queue-full cleanup disturbed the prior TX")
        vq.free_rings();

        `uvm_info("INDIRECT_TEST", "dataplane TX queue-full cleanup test PASSED", UVM_LOW)
    endtask

    // Production atomic TX must notify with the ring cursor, not the number
    // of submitted chains: split passes avail_idx, packed passes the next
    // descriptor slot plus the driver wrap counter.  It also checks that the
    // modern (VERSION_1) header descriptor is 12 bytes.
    task test_atomic_notify_cursor();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("cursor_iommu");
        virtio_vq_test_kit kit;
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("cursor_transport");
        virtio_atomic_ops ops;
        split_virtqueue split_vq;
        packed_virtqueue packed_vq;
        virtio_net_hdr_t net_hdr;
        uvm_event token0, token1, token2;
        uvm_object completed[$];
        int unsigned desc_id0, desc_id1, split_desc;
        int unsigned budget;
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] id;
        bit [15:0] flags;

        mem = shared_mem;
        kit = virtio_vq_test_kit::create_kit("cursor", mem, iommu, 16'h0704);
        split_vq = kit.add_split(0, 16);
        packed_vq = kit.add_packed(1, 4);

        transport.bdf = 16'h0704;
        ops = kit.make_ops(transport, "cursor_ops");
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;
        token0 = new("cursor_token0");
        token1 = new("cursor_token1");
        token2 = new("cursor_token2");
        net_hdr = '{default: 0};

        // Split: one header+payload chain publishes avail_idx 1.
        ops.tx_submit(0, net_hdr, token0, 1'b0, split_desc);
        assert(split_desc != '1 && transport.last_kick_queue_id == 0 &&
               transport.last_kick_next_avail_idx == 1 &&
               transport.last_kick_wrap_counter == 1'b0)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "split notify cursor next=%0d wrap=%0b, expected 1/0",
                transport.last_kick_next_avail_idx, transport.last_kick_wrap_counter))
        read_desc(mem, split_vq.desc_table_addr, split_desc, addr, len, flags, id);
        assert(len == 12)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "VERSION_1 TX header descriptor len=%0d, expected 12", len))

        // Packed size 4: first two-descriptor chain stops at slot 2 in the
        // initial wrap (1); the second fills the ring and wraps to 0/0.
        ops.tx_submit(1, net_hdr, token1, 1'b0, desc_id0);
        assert(desc_id0 != '1 && transport.last_kick_queue_id == 1 &&
               transport.last_kick_next_avail_idx == 2 &&
               transport.last_kick_wrap_counter == 1'b1)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "packed notify cursor next=%0d wrap=%0b, expected 2/1",
                transport.last_kick_next_avail_idx, transport.last_kick_wrap_counter))
        read_packed_desc(mem, packed_vq.desc_table_addr, 0, addr, len, id, flags);
        assert(len == 12)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "VERSION_1 packed TX header descriptor len=%0d, expected 12", len))
        ops.tx_submit(1, net_hdr, token2, 1'b0, desc_id1);
        assert(desc_id1 != '1 &&
               transport.last_kick_next_avail_idx == 0 &&
               transport.last_kick_wrap_counter == 1'b0)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "packed wrapped notify cursor next=%0d wrap=%0b, expected 0/0",
                transport.last_kick_next_avail_idx, transport.last_kick_wrap_counter))

        virtio_vq_test_kit::complete_split_at(mem, split_vq, 0, split_desc, 0, 1);
        budget = 1;
        ops.tx_complete(0, completed, budget);
        virtio_vq_test_kit::complete_packed(mem, packed_vq, 0);
        virtio_vq_test_kit::complete_packed(mem, packed_vq, 2);
        budget = 2;
        ops.tx_complete(1, completed, budget);
        assert(completed.size() == 3 && iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "notify cursor TX completion left %0d packets, maps=%0d unmaps=%0d",
                completed.size(), iommu.total_maps, iommu.total_unmaps))
        split_vq.free_rings();
        packed_vq.free_rings();

        `uvm_info("INDIRECT_TEST", "atomic notify cursor test PASSED", UVM_LOW)
    endtask

    // VERSION_1 without MRG_RXBUF carries num_buffers in the 12-byte header,
    // but only MRG_RXBUF gives it meaning.  A non-1 value must not make the
    // driver consume extra used entries as continuation buffers.
    task test_atomic_rx_num_buffers_without_mrg();
        host_mem_manager mem;
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("rx_nomrg_iommu");
        virtio_vq_test_kit kit;
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("rx_nomrg_transport");
        virtio_atomic_ops ops;
        split_virtqueue vq;
        uvm_object received[$];
        byte frame[];
        iommu_fault_e fault;
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        int unsigned budget;

        mem = shared_mem;
        kit = virtio_vq_test_kit::create_kit("rx_nomrg", mem, iommu, 16'h0705);
        vq = kit.add_split(0, 16);

        transport.bdf = 16'h0705;
        ops = kit.make_ops(transport, "rx_nomrg_ops");
        ops.negotiated_features[VIRTIO_F_VERSION_1] = 1'b1;

        ops.rx_refill(0, 2);
        assert(vq.get_pending_count() == 2)
            else `uvm_fatal("INDIRECT_TEST", "RX refill did not post two buffers")

        // Device writes a 12-byte header with num_buffers=2 and a 64-byte
        // frame into buffer 0, then completes only that buffer.
        read_desc(mem, vq.desc_table_addr, 0, addr, len, flags, next);
        frame = new[12 + 64];
        foreach (frame[i]) frame[i] = 8'h00;
        frame[10] = 8'h02;
        for (int unsigned i = 12; i < frame.size(); i++) frame[i] = i[7:0];
        assert(iommu.write_from_device_for_host(0, mem, 16'h0705, addr, frame, fault))
            else `uvm_fatal("INDIRECT_TEST", "device RX write failed")
        virtio_vq_test_kit::complete_split_at(mem, vq, 0, 0, frame.size(), 1);

        budget = 4;
        ops.rx_receive(0, received, budget);
        assert(received.size() == 1 && vq.get_pending_count() == 1)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "RX without MRG_RXBUF received=%0d pending=%0d, expected 1/1",
                received.size(), vq.get_pending_count()))

        // Complete the second buffer as used entry 1 so its DMA retires
        // through the normal receive path.
        begin
            read_desc(mem, vq.desc_table_addr, 1, addr, len, flags, next);
            frame[10] = 8'h01;
            assert(iommu.write_from_device_for_host(0, mem, 16'h0705, addr, frame, fault))
                else `uvm_fatal("INDIRECT_TEST", "device RX write failed")
            virtio_vq_test_kit::complete_split_at(mem, vq, 1, 1, frame.size(), 2);
        end
        budget = 4;
        ops.rx_receive(0, received, budget);
        assert(received.size() == 2 && vq.get_pending_count() == 0)
            else `uvm_fatal("INDIRECT_TEST", "second RX buffer was not received")
        vq.free_rings();
        assert(iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "RX num_buffers test leaked mappings")

        `uvm_info("INDIRECT_TEST", "atomic RX num_buffers without MRG_RXBUF test PASSED", UVM_LOW)
    endtask

    // dataplane 引擎是 atomic ops 的薄适配：TX 提交必须经 transport 发出真实
    // notify（修复前引擎只 add_buf，从不通知设备）。
    task test_dataplane_engine_notifies_device();
        host_mem_manager mem;
        virtio_iommu_model iommu =
            virtio_iommu_model::type_id::create("dataplane_notify_iommu");
        virtio_vq_test_kit kit;
        virtio_mock_transport transport =
            virtio_mock_transport::type_id::create("dataplane_notify_transport");
        virtio_atomic_ops ops;
        virtio_net_dataplane dataplane =
            virtio_net_dataplane::type_id::create("dataplane_notify");
        split_virtqueue tx_vq;
        split_virtqueue rx_vq;
        virtio_dataplane_indirect_test_packet token;
        uvm_object completed[$];
        uvm_object received[$];
        byte frame[];
        iommu_fault_e fault;
        bit [63:0] addr;
        bit [31:0] len;
        bit [15:0] flags;
        bit [15:0] next;
        bit [63:0] features;
        int unsigned desc_id;

        mem = shared_mem;
        kit = virtio_vq_test_kit::create_kit("dataplane_notify", mem, iommu, 16'h0706);
        tx_vq = kit.add_split(1, 8);
        rx_vq = kit.add_split(0, 8);

        transport.bdf = 16'h0706;
        ops = kit.make_ops(transport, "dataplane_notify_ops");
        features = '0;
        ops.negotiated_features = features;
        dataplane.configure(features, 1500, 1460, RX_MODE_MERGEABLE, 1526, 0,
                            16'h0706);
        dataplane.bind_ops(ops);
        token = virtio_dataplane_indirect_test_packet::type_id::create(
            "dataplane_notify_token");

        desc_id = '1;
        dataplane.tx_engine.submit_packet(1, token, 1'b0, desc_id);
        assert((desc_id != '1) && (transport.kick_count == 1) &&
               (transport.last_kick_queue_id == 1) &&
               (transport.last_kick_next_avail_idx == 1))
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "dataplane TX did not notify the device (desc=%0d kicks=%0d)",
                desc_id, transport.kick_count))

        virtio_vq_test_kit::complete_split_at(mem, tx_vq, 0, desc_id, 0, 1);
        dataplane.tx_engine.complete_tx(1, 1, completed);
        assert((completed.size() == 1) && (completed[0] == token))
            else `uvm_fatal("INDIRECT_TEST", "dataplane TX completion did not return the token")

        // RX 补充同样必须经 transport 通知；修复前引擎只调 virtqueue::kick()。
        dataplane.rx_engine.refill_buffers(0, 1);
        assert((transport.kick_count == 2) && (transport.last_kick_queue_id == 0) &&
               (rx_vq.get_pending_count() == 1))
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "dataplane RX refill did not notify the device (kicks=%0d pending=%0d)",
                transport.kick_count, rx_vq.get_pending_count()))

        read_desc(mem, rx_vq.desc_table_addr, 0, addr, len, flags, next);
        assert(len == 1526)
            else `uvm_fatal("INDIRECT_TEST", $sformatf(
                "dataplane RX buffer length %0d, expected engine buf_size 1526", len))
        frame = new[10 + 64];
        for (int unsigned i = 0; i < 10; i++) frame[i] = 8'h00;
        for (int unsigned i = 10; i < frame.size(); i++) frame[i] = i[7:0];
        assert(iommu.write_from_device_for_host(0, mem, 16'h0706, addr, frame, fault))
            else `uvm_fatal("INDIRECT_TEST", "device RX write failed")
        virtio_vq_test_kit::complete_split_at(mem, rx_vq, 0, 0, frame.size(), 1);
        dataplane.rx_engine.receive_packets(0, 1, received);
        assert((received.size() == 1) && (rx_vq.get_pending_count() == 0) &&
               (dataplane.rx_engine.total_rx_packets == 1))
            else `uvm_fatal("INDIRECT_TEST", "dataplane RX did not return the completed frame")
        rx_vq.free_rings();
        tx_vq.free_rings();
        assert(iommu.total_maps == iommu.total_unmaps)
            else `uvm_fatal("INDIRECT_TEST", "dataplane notify test leaked mappings")

        `uvm_info("INDIRECT_TEST", "dataplane engine notify test PASSED", UVM_LOW)
    endtask

endclass : virtio_indirect_desc_test

`endif // VIRTIO_INDIRECT_DESC_TEST_SV
