`ifndef VIRTIO_MIGRATION_DIRTY_TEST_SV
`define VIRTIO_MIGRATION_DIRTY_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// Migration state capture does not need PCIe TLP traffic in this focused
// regression.  Keep the transport behaviour visible while exercising the
// production FSM freeze/restore entry points.
class virtio_migration_dirty_test_transport extends virtio_pci_transport;
    `uvm_object_utils(virtio_migration_dirty_test_transport)

    bit [7:0] device_status;
    bit       device_reset_complete;
    int unsigned queue_num_max;
    bit          programmed_queue_valid[int unsigned];
    bit [63:0]   programmed_queue_desc[int unsigned];
    bit [63:0]   programmed_queue_driver[int unsigned];
    bit [63:0]   programmed_queue_device[int unsigned];
    int unsigned programmed_queue_size[int unsigned];

    function new(string name = "virtio_migration_dirty_test_transport");
        super.new(name);
        device_status = DEV_STATUS_DRIVER_OK;
        device_reset_complete = 1;
        queue_num_max = 8;
    endfunction

    virtual task read_device_status(ref bit [7:0] status);
        status = device_status;
    endtask

    virtual task write_device_status(bit [7:0] status);
        device_status = status;
    endtask

    virtual task reset_device_verified(ref bit reset_complete);
        device_status = '0;
        reset_complete = device_reset_complete;
    endtask

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        cfg = '{default: 0};
    endtask

    // Queue setup remains production code.  This focused transport replaces
    // only PCIe register traffic with an observable register model so the
    // test can prove that the programmed IOVAs resolve to the live rings.
    virtual task select_queue(int unsigned queue_id);
    endtask

    virtual task read_queue_num_max(ref int unsigned max_size);
        max_size = queue_num_max;
    endtask

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        programmed_queue_valid[queue_id]  = 1;
        programmed_queue_desc[queue_id]   = desc_addr;
        programmed_queue_driver[queue_id] = driver_addr;
        programmed_queue_device[queue_id] = device_addr;
        programmed_queue_size[queue_id]   = queue_size;
    endtask

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx,
                      bit wrap_counter);
    endtask

    function bit get_programmed_queue(
        int unsigned queue_id,
        ref bit [63:0] desc_addr,
        ref bit [63:0] driver_addr,
        ref bit [63:0] device_addr,
        ref int unsigned queue_size
    );
        desc_addr = '0;
        driver_addr = '0;
        device_addr = '0;
        queue_size = 0;
        if (!programmed_queue_valid.exists(queue_id) ||
            !programmed_queue_valid[queue_id])
            return 0;
        desc_addr = programmed_queue_desc[queue_id];
        driver_addr = programmed_queue_driver[queue_id];
        device_addr = programmed_queue_device[queue_id];
        queue_size = programmed_queue_size[queue_id];
        return 1;
    endfunction
endclass : virtio_migration_dirty_test_transport

// The FSM contract, rather than PCIe transport sequencing, is the subject of
// this test.  These overrides leave dirty-page validation and all associated
// host-memory/IOMMU operations to the production FSM implementation.
class virtio_migration_dirty_test_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_migration_dirty_test_ops)

    int unsigned driver_ok_count;

    function new(string name = "virtio_migration_dirty_test_ops");
        super.new(name);
        driver_ok_count = 0;
    endfunction

    virtual task device_reset();
    endtask

    virtual task set_acknowledge();
    endtask

    virtual task set_driver();
    endtask

    virtual task negotiate_features(bit [63:0] driver_caps,
                                    ref bit [63:0] result);
        result = driver_caps;
        negotiated_features = result;
    endtask

    virtual task set_features_ok(ref bit ok);
        ok = 1;
    endtask

    virtual task setup_all_queues(int unsigned num_pairs,
                                  virtqueue_type_e vq_type,
                                  int unsigned queue_size,
                                  output bit ok);
        ok = 1;
    endtask

    virtual task setup_msix(int unsigned num_queues);
    endtask

    virtual task set_driver_ok();
        driver_ok_count++;
    endtask
endclass : virtio_migration_dirty_test_ops

// This helper retains fixture-only DMA just long enough for the production
// reset path to retire it.  Those mappings are intentionally not normal
// queue FIFO ownership.  Queue setup always uses the production setup_queue()
// path; legacy one-queue snapshots select a single setup_queue while the
// production regression restores the whole queue pair.
class virtio_migration_dirty_real_reset_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_migration_dirty_real_reset_ops)

    int unsigned driver_ok_count;
    int unsigned verified_reset_count;
    int unsigned migration_materialize_count;
    int unsigned normal_dma_restore_count;
    bit use_full_queue_pair_setup;
    bit force_feature_mismatch;
    // Fixture-only mappings are not attached to a real queue FIFO.  They
    // exercise fixed-IOVA migration materialization and reset cleanup, so
    // keep them out of normal_dma_records, whose qid/is_tx metadata must be
    // production-valid.
    protected normal_dma_record_t auxiliary_dma[$];

    function new(string name = "virtio_migration_dirty_real_reset_ops");
        super.new(name);
        driver_ok_count = 0;
        verified_reset_count = 0;
        migration_materialize_count = 0;
        normal_dma_restore_count = 0;
        use_full_queue_pair_setup = 0;
        force_feature_mismatch = 0;
    endfunction

    function void register_auxiliary_dma(bit [63:0] gpa, bit [63:0] iova);
        auxiliary_dma.push_back(
            '{bdf: transport.bdf, gpa: gpa, iova: iova});
    endfunction

    virtual task device_reset_verified(ref bit reset_complete);
        verified_reset_count++;
        super.device_reset_verified(reset_complete);
        if (reset_complete)
            retire_normal_dma_records(auxiliary_dma);
    endtask

    virtual function bit materialize_migration_mapping(
        iommu_mapping_t source_mapping,
        byte source_payload[],
        ref iommu_mapping_t destination
    );
        migration_materialize_count++;
        return super.materialize_migration_mapping(source_mapping,
                                                   source_payload,
                                                   destination);
    endfunction

    virtual function bit restore_normal_dma_ownership(
        virtio_normal_dma_snapshot_t records[$]
    );
        normal_dma_restore_count++;
        return super.restore_normal_dma_ownership(records);
    endfunction

    function int unsigned pending_migration_restore_count();
        return migration_restore_dma.size();
    endfunction

    virtual task set_acknowledge();
    endtask

    virtual task set_driver();
    endtask

    virtual task negotiate_features(bit [63:0] driver_caps,
                                    ref bit [63:0] result);
        result = force_feature_mismatch ? (driver_caps ^ 64'h1) : driver_caps;
        negotiated_features = result;
    endtask

    virtual task set_features_ok(ref bit ok);
        ok = 1;
    endtask

    virtual task setup_all_queues(int unsigned num_pairs,
                                  virtqueue_type_e vq_type,
                                  int unsigned queue_size,
                                  output bit ok);
        bit setup_ok;

        if (use_full_queue_pair_setup)
            super.setup_all_queues(num_pairs, vq_type, queue_size, setup_ok);
        else
            super.setup_queue(0, queue_size, vq_type, setup_ok);
        ok = setup_ok;
    endtask

    virtual task setup_msix(int unsigned num_queues);
    endtask

    virtual task set_driver_ok();
        driver_ok_count++;
    endtask
endclass : virtio_migration_dirty_real_reset_ops

// These test-only views prove that the ordinary reset released ownership;
// they do not alter host-memory or IOMMU cleanup behavior.
class virtio_migration_dirty_tracking_mem extends host_mem_manager;
    `uvm_object_utils(virtio_migration_dirty_tracking_mem)

    function new(string name = "virtio_migration_dirty_tracking_mem");
        super.new(name);
    endfunction

    function int unsigned outstanding_allocations();
        return alloc_table.size();
    endfunction
endclass : virtio_migration_dirty_tracking_mem

class virtio_migration_dirty_tracking_iommu extends virtio_iommu_model;
    `uvm_object_utils(virtio_migration_dirty_tracking_iommu)

    function new(string name = "virtio_migration_dirty_tracking_iommu");
        super.new(name);
    endfunction

    function int unsigned active_mapping_count();
        return mapping_table.size();
    endfunction

    function bit get_only_active_mapping(ref iommu_mapping_t mapping);
        mapping = '{default: 0};
        if (mapping_table.size() != 1)
            return 0;
        foreach (mapping_table[key]) begin
            mapping.bdf = mapping_table[key].bdf;
            mapping.gpa = mapping_table[key].gpa;
            mapping.iova = mapping_table[key].iova;
            mapping.size = mapping_table[key].size;
            mapping.dir = mapping_table[key].dir;
            mapping.desc_id = 0;
            return mapping_table[key].valid;
        end
        return 0;
    endfunction

    function bit get_active_mapping(bit [15:0] bdf, bit [63:0] iova,
                                    ref iommu_mapping_t mapping);
        bit [79:0] key;

        mapping = '{default: 0};
        key = {bdf, iova};
        if (!mapping_table.exists(key) || !mapping_table[key].valid)
            return 0;
        mapping.bdf = mapping_table[key].bdf;
        mapping.gpa = mapping_table[key].gpa;
        mapping.iova = mapping_table[key].iova;
        mapping.size = mapping_table[key].size;
        mapping.dir = mapping_table[key].dir;
        mapping.desc_id = 0;
        return 1;
    endfunction
endclass : virtio_migration_dirty_tracking_iommu

// The write is deliberately performed from stop_dataplane(), which is called
// only after freeze_for_migration() has started the generation and before it
// captures that generation.  The IOMMU translation is a DMA_FROM_DEVICE
// (device-to-guest) write and therefore must identify both 4 KiB pages.
class virtio_migration_dirty_test_fsm extends virtio_auto_fsm;
    `uvm_object_utils(virtio_migration_dirty_test_fsm)

    host_mem_manager       mem;
    virtio_iommu_model     iommu;
    bit [15:0]             bdf;
    bit [63:0]             write_iova;
    bit [63:0]             mapped_iova;
    bit [63:0]             mapped_gpa;
    int unsigned           start_count;
    bit                    inject_write_on_stop;
    bit                    unmap_write_on_stop;
    bit                    free_write_on_stop;
    bit                    inject_saved_dma_descriptor;
    bit                    inject_clean_tx_descriptor;
    bit [63:0]             clean_tx_iova;
    int unsigned           stop_write_size;

    function new(string name = "virtio_migration_dirty_test_fsm");
        super.new(name);
        start_count = 0;
        inject_write_on_stop = 1;
        unmap_write_on_stop = 0;
        free_write_on_stop = 0;
        inject_saved_dma_descriptor = 0;
        inject_clean_tx_descriptor = 0;
        clean_tx_iova = '0;
        stop_write_size = 16;
    endfunction

    function void configure_snapshot_queue_count(int unsigned num_pairs,
                                                 int unsigned num_queues);
        active_num_pairs = num_pairs;
        num_total_queues = num_queues;
    endfunction

    function void refresh_snapshot_integrity(ref virtio_device_snapshot_t snap);
        snap.integrity_checksum = migration_snapshot_checksum(snap);
    endfunction

    virtual task stop_dataplane();
        iommu_fault_e fault;
        byte write_data[];

        if (inject_write_on_stop) begin
            write_data = new[stop_write_size];
            foreach (write_data[i])
                write_data[i] = byte'(8'hA0 + i);

            // Exercise the production post-write DMA boundary.  It snapshots
            // completed device bytes before the completion below releases the
            // mapping/allocation pair.
            assert(ops.device_dma_write(write_iova, write_data, fault))
                else `uvm_fatal("MIGRATION",
                $sformatf("cross-page DMA write translation failed: %s",
                              fault.name()))
            if (unmap_write_on_stop)
                iommu.unmap(bdf, mapped_iova);
            if (free_write_on_stop)
                mem.free(mapped_gpa);
        end
        state = FSM_READY;
    endtask

    // Inject the exact split-ring descriptor bytes that a saved queue would
    // carry.  Restore must preserve the source IOVA, not rewrite this image.
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        virtqueue_snapshot_t queue_snapshot;

        super.freeze_for_migration(snap);
        if (!inject_saved_dma_descriptor || (state != FSM_FROZEN))
            return;
        queue_snapshot.queue_id = 0;
        queue_snapshot.queue_size = inject_clean_tx_descriptor ? 2 : 1;
        queue_snapshot.desc_addr = '0;
        queue_snapshot.driver_addr = '0;
        queue_snapshot.device_addr = '0;
        queue_snapshot.last_avail_idx = 0;
        queue_snapshot.last_used_idx = 0;
        queue_snapshot.avail_wrap = 0;
        queue_snapshot.used_wrap = 0;
        // split: descriptor table + avail + used.  The optional second
        // descriptor is an outstanding clean DMA_TO_DEVICE TX payload, which
        // must survive reset without relying on device-write dirty tracking.
        queue_snapshot.ring_data = new[inject_clean_tx_descriptor ? 64 : 38];
        foreach (queue_snapshot.ring_data[i])
            queue_snapshot.ring_data[i] = 0;
        for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
            queue_snapshot.ring_data[byte_index] =
                mapped_iova[byte_index * 8 +: 8];
        queue_snapshot.ring_data[8] = 8'h10;
        queue_snapshot.ring_data[12] = VIRTQ_DESC_F_WRITE[7:0];
        queue_snapshot.ring_data[13] = VIRTQ_DESC_F_WRITE[15:8];
        if (inject_clean_tx_descriptor) begin
            for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
                queue_snapshot.ring_data[16 + byte_index] =
                    clean_tx_iova[byte_index * 8 +: 8];
            queue_snapshot.ring_data[24] = 8'h10;
            // avail.idx = 2 and avail.ring = {0, 1}: both descriptor heads
            // are outstanding in the saved split queue state.
            queue_snapshot.ring_data[34] = 8'h02;
            queue_snapshot.ring_data[36] = 8'h00;
            queue_snapshot.ring_data[38] = 8'h01;
            queue_snapshot.last_avail_idx = 2;
        end
        snap.queue_snapshots = new[1];
        snap.queue_snapshots[0] = queue_snapshot;
        snap.queue_count = 1;
        snap.integrity_checksum = migration_snapshot_checksum(snap);
    endtask

    virtual task start_dataplane();
        start_count++;
        state = FSM_RUNNING;
    endtask
endclass : virtio_migration_dirty_test_fsm

// The corruption case is intentionally expected to report an error.  Catch
// only this diagnostic so an unrelated UVM error remains a regression failure.
class virtio_migration_dirty_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_migration_dirty_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        // The pre-fix implementation reads a buffer after the test completion
        // has released it.  Catch just that expected failure so the focused
        // RED run can report the independent restore-ownership failure too.
        if ((get_severity() == UVM_FATAL) && (get_id() == "HOST_MEM") &&
            uvm_is_match("*unallocated*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        if ((get_severity() == UVM_ERROR) && (get_id() == "AUTO_FSM") &&
            (uvm_is_match("*dirty page*", get_message()) ||
             uvm_is_match("*snapshot integrity*", get_message()))) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_migration_dirty_error_catcher

class virtio_migration_dirty_iommu_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_migration_dirty_iommu_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "IOMMU_DMA_WRITE") &&
            uvm_is_match("*write_from_device*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_migration_dirty_iommu_error_catcher

// Restore-rejection coverage deliberately drives malformed recovery inputs.
// Catch only the diagnostics expected from those inputs so a separate UVM
// error still fails the regression.
class virtio_migration_dirty_restore_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_migration_dirty_restore_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if (get_severity() != UVM_ERROR)
            return THROW;
        if (((get_id() == "ATOMIC_OPS") &&
             uvm_is_match("*reset did not complete*", get_message())) ||
            ((get_id() == "AUTO_FSM") &&
             (uvm_is_match("*verified device reset*", get_message()) ||
              uvm_is_match("*feature negotiation*", get_message()) ||
              uvm_is_match("*feature mismatch*", get_message()) ||
              uvm_is_match("*migration restore*", get_message()) ||
              uvm_is_match("*normal DMA*", get_message()) ||
              uvm_is_match("*queue DMA*", get_message()) ||
              uvm_is_match("*queue count mismatch*", get_message()) ||
              uvm_is_match("*queue snapshot*", get_message()) ||
              uvm_is_match("*queue setup*", get_message()) ||
              uvm_is_match("*queue overlay*", get_message()) ||
              uvm_is_match("*state overlay failed*", get_message()))) ||
            (((get_id() == "SPLIT_VQ") || (get_id() == "PACKED_VQ")) &&
             uvm_is_match("*restore_state: missing or incompatible*", get_message())) ||
            ((get_id() == "IOMMU_MAP") &&
             uvm_is_match("*IOVA collision*", get_message()))) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_migration_dirty_restore_error_catcher

class virtio_migration_dirty_test extends uvm_test;
    `uvm_component_utils(virtio_migration_dirty_test)

    localparam int unsigned PAGE_SIZE = 4096;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_direct_device_write_bypass_is_rejected();
        test_cross_page_dirty_snapshot_and_restore_validation();
        test_subpage_dirty_snapshot_and_restore_validation();
        test_retired_and_freed_mapping_payload_is_captured_at_freeze();
        test_real_reset_restore_uses_snapshot_payload();
        test_clean_outstanding_tx_mapping_survives_restore();
        test_production_split_ring_restore_uses_setup_rings();
        test_production_packed_ring_restore_uses_setup_rings();
        test_production_split_used_ring_drain_write_uses_setup_rings();
        test_production_packed_event_ring_drain_write_uses_setup_rings();
        test_split_outstanding_ownership_survives_restore();
        test_packed_outstanding_ownership_survives_restore();
        test_split_queue_dma_mapping_survives_restore();
        test_packed_queue_dma_mapping_survives_restore();
        test_split_queue_dma_precedes_indirect_restore();
        test_packed_queue_dma_precedes_indirect_restore();
        test_restore_rejects_failed_verified_reset();
        test_restore_rejects_feature_mismatch();
        test_restore_rejects_missing_snapshot_queue();
        test_restore_rejects_incompatible_snapshot_queue();
        test_restore_rejects_queue_overlay_failure();
        test_restore_overlay_failure_releases_unclaimed_queue_mappings();
        test_restore_rejects_tampered_queue_dma_ownership();
        test_restore_rejects_tampered_normal_dma_ownership();

        `uvm_info("MIGRATION", "Migration dirty-page tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // A successful translate does not mean a device write completed.  Direct
    // DMA_FROM_DEVICE translation must be rejected so callers cannot bypass
    // the post-write snapshot boundary and silently lose migration bytes.
    task test_direct_device_write_bypass_is_rejected();
        virtio_iommu_model                         iommu;
        host_mem_manager                           mem;
        virtio_migration_dirty_iommu_error_catcher catcher;
        bit [63:0]                                 gpa;
        bit [63:0]                                 iova;
        bit [63:0]                                 bidir_iova;
        iommu_fault_e                              fault;
        bit                                        translated;
        bit                                        bidir_translated;
        bit [63:0]                                 dirty_pages[$];

        iommu = virtio_iommu_model::type_id::create("bypass_iommu");
        mem = host_mem_manager::type_id::create("bypass_mem");
        mem.init_region(64'h7100_0000, 64'h7100_FFFF);
        gpa = mem.alloc(64, 64);
        assert(gpa != '1)
            else `uvm_fatal("MIGRATION", "failed to allocate DMA bypass backing")
        iova = iommu.map(16'h0900, gpa, 64, DMA_FROM_DEVICE);
        bidir_iova = iommu.map(16'h0900, gpa, 64, DMA_BIDIRECTIONAL);
        assert((iova != '1) && (bidir_iova != '1) &&
               (iova != 0) && (bidir_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map DMA bypass backing")
        iommu.begin_dirty_generation();

        catcher = new("direct_dma_bypass_catcher");
        uvm_report_cb::add(null, catcher);
        translated = iommu.translate(16'h0900, iova, 16, DMA_FROM_DEVICE,
                                     gpa, fault);
        bidir_translated = iommu.translate(16'h0900, bidir_iova, 16,
                                            DMA_BIDIRECTIONAL, gpa, fault);
        uvm_report_cb::delete(null, catcher);
        iommu.capture_dirty_generation(dirty_pages);

        assert(!translated && !bidir_translated &&
               (fault == IOMMU_FAULT_PERMISSION) &&
               (catcher.caught_count == 2) && (dirty_pages.size() == 0))
            else `uvm_error("MIGRATION",
                "direct writable-DMA translation bypass was accepted")

        iommu.unmap(16'h0900, bidir_iova);
        iommu.unmap(16'h0900, iova);
        mem.free(gpa);
    endtask

    task test_cross_page_dirty_snapshot_and_restore_validation();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_test_ops       ops;
        virtio_migration_dirty_test_fsm       fsm;
        virtio_iommu_model                    iommu;
        host_mem_manager                      mem;
        virtqueue_manager                     vq_mgr;
        virtio_driver_config_t                cfg;
        virtio_device_snapshot_t              snapshot;
        virtio_migration_dirty_error_catcher  catcher;
        bit [63:0]                            backing_gpa;
        bit [63:0]                            backing_iova;
        bit [63:0]                            first_page;
        bit [63:0]                            second_page;
        byte                                  corrupted_byte[];
        bit                                   restore_ok;
        int unsigned                          starts_before_corruption;

        transport = virtio_migration_dirty_test_transport::type_id::create(
            "migration_transport");
        ops = virtio_migration_dirty_test_ops::type_id::create("migration_ops");
        fsm = virtio_migration_dirty_test_fsm::type_id::create("migration_fsm");
        iommu = virtio_iommu_model::type_id::create("migration_iommu");
        mem = host_mem_manager::type_id::create("migration_mem");
        vq_mgr = virtqueue_manager::type_id::create("migration_vq_mgr");

        mem.init_region(64'h7200_0000, 64'h7200_FFFF);
        backing_gpa = mem.alloc(PAGE_SIZE * 2, PAGE_SIZE);
        assert(backing_gpa != '1)
            else `uvm_fatal("MIGRATION", "failed to allocate two-page migration backing")
        backing_iova = iommu.map(16'h0901, backing_gpa, PAGE_SIZE * 2,
                                  DMA_FROM_DEVICE);
        assert((backing_iova != '1) && (backing_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map migration backing")

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = VQ_SPLIT;
        transport.bdf = 16'h0901;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h0000_0000_0000_0001;
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = 16'h0901;
        // Eight bytes before and eight bytes after the 4 KiB boundary.
        fsm.write_iova = backing_iova + PAGE_SIZE - 8;
        fsm.mapped_iova = backing_iova;
        fsm.mapped_gpa = backing_gpa;
        fsm.state = FSM_RUNNING;

        fsm.freeze_for_migration(snapshot);

        first_page = backing_gpa >> 12;
        second_page = first_page + 1;
        assert(snapshot.dirty_pages.size() == 2)
            else `uvm_error("MIGRATION",
                "cross-page dirty set was not saved")
        assert((snapshot.dirty_pages[0] == first_page ||
                snapshot.dirty_pages[1] == first_page) &&
               (snapshot.dirty_pages[0] == second_page ||
                snapshot.dirty_pages[1] == second_page))
            else `uvm_error("MIGRATION",
                "cross-page dirty set did not preserve both guest page IDs")

        // Dirty generation is part of the saved migration state.  Its
        // integrity must be checked before reset, queue restore, or a new
        // dataplane start can make a corrupted snapshot observable.
        snapshot.dirty_generation ^= 64'h1;
        starts_before_corruption = fsm.start_count;
        catcher = new("migration_generation_catcher");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);
        assert(!restore_ok && catcher.caught_count == 1 &&
               fsm.start_count == starts_before_corruption)
            else `uvm_error("MIGRATION",
                "corrupted dirty generation was accepted or restarted the data plane")
        snapshot.dirty_generation ^= 64'h1;

        corrupted_byte = new[1];
        corrupted_byte[0] = 8'h5A;
        mem.write_mem(backing_gpa + 1, corrupted_byte);
        starts_before_corruption = fsm.start_count;
        catcher = new("migration_checksum_catcher");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);

        assert(!restore_ok && catcher.caught_count == 1 &&
               fsm.start_count == starts_before_corruption)
            else `uvm_error("MIGRATION",
                "corrupted dirty page was accepted or restarted the data plane")

        // The successful path models the ordinary reset boundary: the source
        // mapping/allocation is gone before the snapshot is materialized at
        // its original IOVA.  Keep corruption checks above this point, while
        // their live source bytes are still deliberately available.
        iommu.unmap(16'h0901, backing_iova);
        mem.free(backing_gpa);
        fsm.inject_write_on_stop = 0;
        fsm.restore_from_migration(snapshot, restore_ok);
        assert(restore_ok && fsm.start_count == 1)
            else `uvm_error("MIGRATION",
                "restore rejected a reset-safe dirty-page snapshot")
        ops.release_migration_restore_payloads();
    endtask

    // A legal 64-byte DMA mapping does not grant host_mem read_mem() access
    // to the rest of its 4 KiB page.  Migration must capture and validate the
    // mapped dirty bytes without assuming one full page is one allocation.
    task test_subpage_dirty_snapshot_and_restore_validation();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_test_ops       ops;
        virtio_migration_dirty_test_fsm       fsm;
        virtio_iommu_model                    iommu;
        host_mem_manager                      mem;
        virtqueue_manager                     vq_mgr;
        virtio_driver_config_t                cfg;
        virtio_device_snapshot_t              snapshot;
        virtio_migration_dirty_error_catcher  catcher;
        bit [63:0]                            backing_gpa;
        bit [63:0]                            backing_iova;
        byte                                  corrupted_byte[];
        byte                                  untracked_byte[];
        bit                                   restore_ok;
        int unsigned                          starts_before_corruption;

        transport = virtio_migration_dirty_test_transport::type_id::create(
            "subpage_migration_transport");
        ops = virtio_migration_dirty_test_ops::type_id::create(
            "subpage_migration_ops");
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            "subpage_migration_fsm");
        iommu = virtio_iommu_model::type_id::create("subpage_migration_iommu");
        mem = host_mem_manager::type_id::create("subpage_migration_mem");
        vq_mgr = virtqueue_manager::type_id::create("subpage_migration_vq_mgr");

        mem.init_region(64'h7300_0000, 64'h7300_FFFF);
        // The allocation is larger than the DMA mapping.  Its second half is
        // intentionally not migration-owned by this dirty mapping.
        backing_gpa = mem.alloc(128, 64);
        assert(backing_gpa != '1)
            else `uvm_fatal("MIGRATION", "failed to allocate sub-page migration backing")
        backing_iova = iommu.map(16'h0902, backing_gpa, 64, DMA_FROM_DEVICE);
        assert((backing_iova != '1) && (backing_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map sub-page migration backing")

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = VQ_SPLIT;
        transport.bdf = 16'h0902;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h0000_0000_0000_0001;
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = 16'h0902;
        fsm.write_iova = backing_iova + 16;
        fsm.mapped_iova = backing_iova;
        fsm.mapped_gpa = backing_gpa;
        fsm.state = FSM_RUNNING;

        fsm.freeze_for_migration(snapshot);

        assert(snapshot.dirty_pages.size() == 1 &&
               snapshot.dirty_pages[0] == (backing_gpa >> 12))
            else `uvm_error("MIGRATION",
                "sub-page DMA write was not captured as one dirty page")

        // A changed allocation tail outside the 64-byte dirty mapping must
        // not invalidate this page's mapping-span checksum.
        untracked_byte = new[1];
        untracked_byte[0] = 8'hC3;
        mem.write_mem(backing_gpa + 96, untracked_byte);

        corrupted_byte = new[1];
        corrupted_byte[0] = 8'h3C;
        mem.write_mem(backing_gpa + 17, corrupted_byte);
        starts_before_corruption = fsm.start_count;
        catcher = new("subpage_migration_checksum_catcher");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);

        assert(!restore_ok && catcher.caught_count == 1 &&
               fsm.start_count == starts_before_corruption)
            else `uvm_error("MIGRATION",
                "corrupted sub-page dirty backing was accepted or restarted")

        iommu.unmap(16'h0902, backing_iova);
        mem.free(backing_gpa);
        fsm.inject_write_on_stop = 0;
        fsm.restore_from_migration(snapshot, restore_ok);
        assert(restore_ok && fsm.start_count == 1)
            else `uvm_error("MIGRATION",
                "restore rejected a reset-safe sub-page dirty snapshot")
        ops.release_migration_restore_payloads();
    endtask

    // A real completion releases both sides of ordinary DMA ownership.  The
    // post-write bytes must be captured before that unmap/free pair, not read
    // later by freeze from a now-invalid allocation.  Restore must then use
    // the dirty fallback (not a complete live-mapping record) to recreate
    // the stable source IOVA with normal reset ownership.
    task test_retired_and_freed_mapping_payload_is_captured_at_freeze();
        virtio_migration_dirty_test_transport       transport;
        virtio_migration_dirty_real_reset_ops       ops;
        virtio_migration_dirty_test_fsm             fsm;
        virtio_migration_dirty_tracking_iommu       iommu;
        virtio_migration_dirty_tracking_mem         mem;
        virtqueue_manager                           vq_mgr;
        virtio_driver_config_t                      cfg;
        virtio_device_snapshot_t                    snapshot;
        bit [63:0]                                  backing_gpa;
        bit [63:0]                                  backing_iova;
        bit                                         restore_ok;
        iommu_mapping_t                             restored_mapping;
        byte                                        restored_data[];

        transport = virtio_migration_dirty_test_transport::type_id::create(
            "retired_mapping_transport");
        ops = virtio_migration_dirty_real_reset_ops::type_id::create(
            "retired_mapping_ops");
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            "retired_mapping_fsm");
        iommu = virtio_migration_dirty_tracking_iommu::type_id::create(
            "retired_mapping_iommu");
        mem = virtio_migration_dirty_tracking_mem::type_id::create(
            "retired_mapping_mem");
        vq_mgr = virtqueue_manager::type_id::create("retired_mapping_vq_mgr");

        mem.init_region(64'h7400_0000, 64'h7400_FFFF);
        backing_gpa = mem.alloc(64, 64);
        assert(backing_gpa != '1)
            else `uvm_fatal("MIGRATION", "failed to allocate retired mapping backing")
        backing_iova = iommu.map(16'h0903, backing_gpa, 64, DMA_FROM_DEVICE);
        assert((backing_iova != '1) && (backing_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map retired mapping backing")

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = VQ_SPLIT;
        transport.bdf = 16'h0903;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h1;
        // The retired non-ring path has no queue snapshot to restore.  Keep
        // queue setup production-real but empty so only the dirty fallback
        // can account for the destination mapping/allocation.
        ops.use_full_queue_pair_setup = 1;
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = 16'h0903;
        fsm.write_iova = backing_iova;
        fsm.mapped_iova = backing_iova;
        fsm.mapped_gpa = backing_gpa;
        fsm.unmap_write_on_stop = 1;
        fsm.free_write_on_stop = 1;
        fsm.configure_snapshot_queue_count(0, 0);
        fsm.state = FSM_RUNNING;

        fsm.freeze_for_migration(snapshot);

        assert(fsm.state == FSM_FROZEN && snapshot.dirty_pages.size() == 1 &&
               snapshot.dirty_page_records.size() == 1 &&
               snapshot.dirty_page_records[0].mapping.iova == backing_iova &&
               snapshot.dirty_page_records[0].payload.size() == 64 &&
               snapshot.dirty_page_records[0].payload[0] == 8'hA0 &&
               snapshot.dirty_page_records[0].payload[15] == 8'hAF &&
               snapshot.mapping_records.size() == 0)
            else `uvm_error("MIGRATION",
                "freeze did not retain a fallback-only post-write payload")

        // The completed write already retired and freed its source backing.
        // The ordinary reset must see that baseline before restore creates
        // exactly one destination mapping/allocation through the fallback.
        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_fatal("MIGRATION",
                "ordinary reset retained a retired source DMA resource")

        fsm.inject_write_on_stop = 0;
        fsm.restore_from_migration(snapshot, restore_ok);
        assert(restore_ok && (fsm.start_count == 1) &&
               (iommu.active_mapping_count() == 1) &&
               (mem.outstanding_allocations() == 1) &&
               (vq_mgr.get_queue_count() == 0) &&
               iommu.get_active_mapping(transport.bdf, backing_iova,
                                        restored_mapping))
            else `uvm_error("MIGRATION",
                "dirty fallback did not materialize exactly one stable-I/O virtual mapping")
        if (iommu.get_active_mapping(transport.bdf, backing_iova,
                                    restored_mapping)) begin
            mem.read_mem(restored_mapping.gpa, restored_mapping.size,
                         restored_data);
            assert((restored_mapping.iova == backing_iova) &&
                   (restored_mapping.dir == DMA_FROM_DEVICE) &&
                   (restored_data.size() == 64) &&
                   (restored_data[0] == 8'hA0) &&
                   (restored_data[15] == 8'hAF))
                else `uvm_error("MIGRATION",
                    "dirty fallback restored the wrong mapping identity or payload")
        end

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION",
                "ordinary reset retained dirty-fallback destination ownership")
    endtask

    // Normal migration intentionally performs ordinary reset cleanup before
    // restore.  The snapshot must remain self-validating after that cleanup,
    // while snapshot corruption must still prevent dataplane restart.
    task test_real_reset_restore_uses_snapshot_payload();
        virtio_migration_dirty_test_transport       transport;
        virtio_migration_dirty_real_reset_ops       ops;
        virtio_migration_dirty_test_fsm             fsm;
        virtio_migration_dirty_tracking_iommu       iommu;
        virtio_migration_dirty_tracking_mem         mem;
        virtqueue_manager                           vq_mgr;
        virtio_driver_config_t                      cfg;
        virtio_device_snapshot_t                    snapshot;
        virtio_migration_dirty_error_catcher        catcher;
        bit [63:0]                                  backing_gpa;
        bit [63:0]                                  backing_iova;
        bit                                         restore_ok;
        int unsigned                                starts_before_corruption;
        iommu_mapping_t                              restored_mapping;
        byte                                        restored_data[];
        bit [63:0]                                   restored_descriptor_iova;
        virtqueue_base                               restored_vq;
        byte                                        restored_descriptor[];

        transport = virtio_migration_dirty_test_transport::type_id::create(
            "real_reset_migration_transport");
        ops = virtio_migration_dirty_real_reset_ops::type_id::create(
            "real_reset_migration_ops");
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            "real_reset_migration_fsm");
        iommu = virtio_migration_dirty_tracking_iommu::type_id::create(
            "real_reset_migration_iommu");
        mem = virtio_migration_dirty_tracking_mem::type_id::create(
            "real_reset_migration_mem");
        vq_mgr = virtqueue_manager::type_id::create("real_reset_migration_vq_mgr");

        mem.init_region(64'h7500_0000, 64'h7500_FFFF);
        backing_gpa = mem.alloc(64, 64);
        assert(backing_gpa != '1)
            else `uvm_fatal("MIGRATION", "failed to allocate real-reset backing")
        backing_iova = iommu.map(16'h0904, backing_gpa, 64, DMA_FROM_DEVICE);
        assert((backing_iova != '1) && (backing_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map real-reset backing")

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 1;
        cfg.vq_type = VQ_SPLIT;
        transport.bdf = 16'h0904;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h1;
        ops.register_auxiliary_dma(backing_gpa, backing_iova);
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = transport.bdf;
        fsm.write_iova = backing_iova;
        fsm.mapped_iova = backing_iova;
        fsm.mapped_gpa = backing_gpa;
        fsm.configure_snapshot_queue_count(1, 0);
        fsm.inject_saved_dma_descriptor = 1;
        fsm.state = FSM_RUNNING;

        fsm.freeze_for_migration(snapshot);
        ops.device_reset();
        assert(iommu.active_mapping_count() == 0 &&
               mem.outstanding_allocations() == 0)
            else `uvm_fatal("MIGRATION",
                "ordinary reset retained migration test DMA resources")

        fsm.inject_write_on_stop = 0;
        fsm.restore_from_migration(snapshot, restore_ok);
        assert(restore_ok && fsm.start_count == 1 &&
               iommu.active_mapping_count() == 4 &&
               iommu.get_active_mapping(transport.bdf, backing_iova,
                                        restored_mapping))
            else `uvm_error("MIGRATION",
                "restore did not materialize a tracked destination DMA span")
        if (iommu.get_active_mapping(transport.bdf, backing_iova,
                                    restored_mapping)) begin
            mem.read_mem(restored_mapping.gpa, restored_mapping.size, restored_data);
            assert(restored_mapping.dir == DMA_FROM_DEVICE &&
                   restored_data.size() == snapshot.dirty_page_records[0].payload.size() &&
                   restored_data[0] == snapshot.dirty_page_records[0].payload[0] &&
                   restored_data[15] == snapshot.dirty_page_records[0].payload[15])
                else `uvm_error("MIGRATION",
                    "restore did not materialize the saved dirty payload bytes")
        end
        restored_descriptor_iova = '0;
        restored_vq = null;
        restored_descriptor.delete();
        if (vq_mgr.get_queue_count() == 1) begin
            restored_vq = vq_mgr.get_queue(0);
            if (restored_vq != null)
                mem.read_mem(restored_vq.desc_table_addr, 16, restored_descriptor);
        end
        if (restored_descriptor.size() == 16) begin
            for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
                restored_descriptor_iova[byte_index * 8 +: 8] =
                    restored_descriptor[byte_index];
        end
        assert((restored_vq != null) &&
               (restored_descriptor_iova == backing_iova) &&
               (restored_mapping.iova == backing_iova))
            else `uvm_error("MIGRATION",
                "saved descriptor IOVA does not resolve to restored DMA")

        // Destination spans are normal owned DMA, so a subsequent ordinary
        // reset must retire both their allocation and their IOMMU mapping.
        ops.device_reset();
        assert(iommu.active_mapping_count() == 0 &&
               mem.outstanding_allocations() == 0)
            else `uvm_error("MIGRATION",
                "ordinary reset retained restored migration DMA resources")

        snapshot.dirty_page_records[0].checksum ^= 64'h1;
        starts_before_corruption = fsm.start_count;
        catcher = new("real_reset_snapshot_corruption_catcher");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);

        assert(!restore_ok && catcher.caught_count == 1 &&
               fsm.start_count == starts_before_corruption)
            else `uvm_error("MIGRATION",
                "corrupt reset-safe snapshot was accepted or restarted the data plane")
    endtask

    // A clean outstanding TX descriptor has no post-freeze device write, so
    // it produces no dirty page record.  Migration must still snapshot its
    // live DMA mapping, restore the source IOVA, and return the new ownership
    // to the next ordinary device reset.
    task test_clean_outstanding_tx_mapping_survives_restore();
        virtio_migration_dirty_test_transport       transport;
        virtio_migration_dirty_real_reset_ops       ops;
        virtio_migration_dirty_test_fsm             fsm;
        virtio_migration_dirty_tracking_iommu       iommu;
        virtio_migration_dirty_tracking_mem         mem;
        virtqueue_manager                           vq_mgr;
        virtio_driver_config_t                      cfg;
        virtio_device_snapshot_t                    snapshot;
        bit [63:0]                                  dirty_gpa;
        bit [63:0]                                  dirty_iova;
        bit [63:0]                                  tx_gpa;
        bit [63:0]                                  tx_iova;
        bit [63:0]                                  restored_tx_gpa;
        iommu_fault_e                               fault;
        bit                                         restored;
        byte                                        tx_payload[];
        byte                                        restored_payload[];
        byte                                        restored_desc[];
        bit [63:0]                                  restored_desc_tx_iova;
        virtqueue_base                               restored_vq;

        transport = virtio_migration_dirty_test_transport::type_id::create(
            "clean_tx_migration_transport");
        ops = virtio_migration_dirty_real_reset_ops::type_id::create(
            "clean_tx_migration_ops");
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            "clean_tx_migration_fsm");
        iommu = virtio_migration_dirty_tracking_iommu::type_id::create(
            "clean_tx_migration_iommu");
        mem = virtio_migration_dirty_tracking_mem::type_id::create(
            "clean_tx_migration_mem");
        vq_mgr = virtqueue_manager::type_id::create("clean_tx_migration_vq_mgr");

        mem.init_region(64'h7600_0000, 64'h7600_FFFF);
        dirty_gpa = mem.alloc(64, 64);
        tx_gpa = mem.alloc(64, 64);
        assert((dirty_gpa != '1) && (tx_gpa != '1))
            else `uvm_fatal("MIGRATION", "failed to allocate clean-TX migration DMA")
        dirty_iova = iommu.map(16'h0905, dirty_gpa, 64, DMA_FROM_DEVICE);
        tx_iova = iommu.map(16'h0905, tx_gpa, 64, DMA_TO_DEVICE);
        assert((dirty_iova != '1) && (tx_iova != '1) &&
               (dirty_iova != 0) && (tx_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map clean-TX migration DMA")
        tx_payload = new[16];
        foreach (tx_payload[i])
            tx_payload[i] = byte'(8'hC0 + i);
        mem.write_mem(tx_gpa, tx_payload);

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 2;
        cfg.vq_type = VQ_SPLIT;
        transport.bdf = 16'h0905;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h1;
        ops.register_auxiliary_dma(dirty_gpa, dirty_iova);
        ops.register_auxiliary_dma(tx_gpa, tx_iova);
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = transport.bdf;
        fsm.write_iova = dirty_iova;
        fsm.mapped_iova = dirty_iova;
        fsm.mapped_gpa = dirty_gpa;
        fsm.configure_snapshot_queue_count(1, 0);
        fsm.inject_saved_dma_descriptor = 1;
        fsm.inject_clean_tx_descriptor = 1;
        fsm.clean_tx_iova = tx_iova;
        fsm.state = FSM_RUNNING;

        fsm.freeze_for_migration(snapshot);
        assert(snapshot.dirty_page_records.size() == 1)
            else `uvm_error("MIGRATION",
                "clean TX mapping unexpectedly entered post-write dirty records")
        ops.device_reset();
        fsm.inject_write_on_stop = 0;
        fsm.restore_from_migration(snapshot, restored);

        restored_desc_tx_iova = '0;
        restored_vq = vq_mgr.get_queue(0);
        if (restored_vq != null) begin
            mem.read_mem(restored_vq.desc_table_addr, 32, restored_desc);
            if (restored_desc.size() == 32) begin
                for (int unsigned byte_index = 0; byte_index < 8; byte_index++)
                    restored_desc_tx_iova[byte_index * 8 +: 8] =
                        restored_desc[16 + byte_index];
            end
        end
        if (iommu.translate(transport.bdf, tx_iova, tx_payload.size(),
                            DMA_TO_DEVICE, restored_tx_gpa, fault))
            mem.read_mem(restored_tx_gpa, tx_payload.size(), restored_payload);

        assert(restored && (restored_desc_tx_iova == tx_iova) &&
               (fault == IOMMU_NO_FAULT) &&
               (restored_payload.size() == tx_payload.size()) &&
               (restored_payload[0] == tx_payload[0]) &&
               (restored_payload[15] == tx_payload[15]) &&
               (iommu.active_mapping_count() == 5))
            else `uvm_error("MIGRATION",
                "clean outstanding TX descriptor IOVA does not resolve to restored bytes")

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_error("MIGRATION",
                "ordinary reset retained restored clean-TX DMA ownership")
    endtask

    // The migration destination must retain the ring allocation and IOMMU
    // addresses that production setup_all_queues() programs into transport.
    // Queue restore may copy state and indices into those allocations, but it
    // must not materialize the source rings as generic DMA or allocate a
    // replacement ring after transport programming.
    task test_production_split_ring_restore_uses_setup_rings();
        run_production_ring_restore_uses_setup_rings(VQ_SPLIT);
    endtask

    task test_production_packed_ring_restore_uses_setup_rings();
        run_production_ring_restore_uses_setup_rings(VQ_PACKED);
    endtask

    // A device completion can update a ring after freeze begins but before
    // the data plane has drained.  That dirty record remains checksum
    // validated, but destination queue setup owns the ring allocation.
    task test_production_split_used_ring_drain_write_uses_setup_rings();
        run_production_ring_restore_uses_setup_rings(VQ_SPLIT, 1);
    endtask

    task test_production_packed_event_ring_drain_write_uses_setup_rings();
        run_production_ring_restore_uses_setup_rings(VQ_PACKED, 1);
    endtask

    function bit migration_bytes_equal(byte expected[], byte actual[]);
        if (expected.size() != actual.size())
            return 0;
        foreach (expected[i]) begin
            if (expected[i] !== actual[i])
                return 0;
        end
        return 1;
    endfunction

    function bit migration_snapshot_ring_bytes_equal(
        virtqueue_snapshot_t snapshot,
        byte actual[]
    );
        if (snapshot.ring_data.size() != actual.size())
            return 0;
        foreach (snapshot.ring_data[i]) begin
            if (snapshot.ring_data[i] !== actual[i])
                return 0;
        end
        return 1;
    endfunction

    task run_production_ring_restore_uses_setup_rings(
        virtqueue_type_e vq_type,
        bit inject_ring_write_on_stop = 0
    );
        virtio_migration_dirty_test_transport       transport;
        virtio_migration_dirty_real_reset_ops       ops;
        virtio_migration_dirty_test_fsm             fsm;
        virtio_migration_dirty_tracking_iommu       iommu;
        virtio_migration_dirty_tracking_mem         mem;
        virtqueue_manager                           vq_mgr;
        virtio_memory_barrier_model                 barrier;
        virtio_driver_config_t                      cfg;
        virtio_device_snapshot_t                    snapshot;
        virtqueue_base                              source_vq;
        virtqueue_base                              restored_vq;
        virtio_sg_list                              sgs[];
        virtio_sg_entry                             entry;
        bit [63:0]                                  payload_gpa;
        bit [63:0]                                  payload_iova;
        bit [63:0]                                  restored_payload_gpa;
        bit [63:0]                                  programmed_desc_iova;
        bit [63:0]                                  programmed_driver_iova;
        bit [63:0]                                  programmed_device_iova;
        bit [63:0]                                  source_device_iova;
        int unsigned                                programmed_queue_size;
        int unsigned                                desc_size;
        int unsigned                                driver_size;
        int unsigned                                device_size;
        int unsigned                                expected_allocations;
        int unsigned                                desc_id;
        iommu_mapping_t                             desc_mapping;
        iommu_mapping_t                             driver_mapping;
        iommu_mapping_t                             device_mapping;
        iommu_mapping_t                             source_iova_mapping;
        iommu_fault_e                               fault;
        bit                                         restored;
        bit                                         payload_translated;
        bit                                         captured_ring_dirty_record;
        bit                                         saved_ring_write_matches;
        bit                                         source_iova_is_setup_ring;
        bit                                         setup_ok;
        int unsigned                                ring_write_offset;
        byte                                        payload[];
        byte                                        restored_payload[];
        byte                                        restored_ring[];
        byte                                        restored_event_bytes[];
        byte                                        region[];

        transport = virtio_migration_dirty_test_transport::type_id::create(
            $sformatf("production_%s_transport", vq_type.name()));
        ops = virtio_migration_dirty_real_reset_ops::type_id::create(
            $sformatf("production_%s_ops", vq_type.name()));
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            $sformatf("production_%s_fsm", vq_type.name()));
        iommu = virtio_migration_dirty_tracking_iommu::type_id::create(
            $sformatf("production_%s_iommu", vq_type.name()));
        mem = virtio_migration_dirty_tracking_mem::type_id::create(
            $sformatf("production_%s_mem", vq_type.name()));
        vq_mgr = virtqueue_manager::type_id::create(
            $sformatf("production_%s_vq_mgr", vq_type.name()));
        barrier = virtio_memory_barrier_model::type_id::create(
            $sformatf("production_%s_barrier", vq_type.name()));

        mem.init_region((vq_type == VQ_SPLIT) ? 64'h7700_0000 : 64'h7800_0000,
                        (vq_type == VQ_SPLIT) ? 64'h7700_FFFF : 64'h7800_FFFF);
        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 4;
        cfg.vq_type = vq_type;
        transport.bdf = (vq_type == VQ_SPLIT) ? 16'h0906 : 16'h0907;
        transport.queue_num_max = cfg.queue_size;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.negotiated_features = 64'h1;
        ops.use_full_queue_pair_setup = 1;
        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = transport.bdf;
        fsm.configure_snapshot_queue_count(cfg.num_queue_pairs, 2);
        fsm.inject_write_on_stop = 0;
        fsm.state = FSM_RUNNING;

        // This is an ordinary, live descriptor rather than an injected raw
        // image.  Its source DMA IOVA must remain valid after migration while
        // the ring itself moves only through the setup-time destination.
        ops.setup_all_queues(cfg.num_queue_pairs, cfg.vq_type, cfg.queue_size,
                             setup_ok);
        assert(setup_ok)
            else `uvm_fatal("MIGRATION", "production source queue setup failed")
        source_vq = vq_mgr.get_queue(0);
        source_device_iova = '0;
        if (inject_ring_write_on_stop) begin
            assert(transport.get_programmed_queue(0, programmed_desc_iova,
                                                  programmed_driver_iova,
                                                  source_device_iova,
                                                  programmed_queue_size) &&
                   (programmed_queue_size == cfg.queue_size))
                else `uvm_fatal("MIGRATION",
                    $sformatf("%s source setup did not program queue 0", vq_type.name()))
            fsm.write_iova = source_device_iova;
            fsm.stop_write_size = 4;
            fsm.inject_write_on_stop = 1;
        end
        payload_gpa = mem.alloc(16, 16);
        payload_iova = iommu.map(transport.bdf, payload_gpa, 16, DMA_TO_DEVICE);
        assert((source_vq != null) && (payload_gpa != '1) &&
               (payload_iova != '1) && (payload_iova != 0))
            else `uvm_fatal("MIGRATION",
                $sformatf("%s production setup did not create active DMA", vq_type.name()))
        payload = new[16];
        foreach (payload[i])
            payload[i] = byte'(8'hD0 + i);
        mem.write_mem(payload_gpa, payload);
        ops.register_auxiliary_dma(payload_gpa, payload_iova);
        sgs = new[1];
        entry.addr = payload_iova;
        entry.len = payload.size();
        entry.is_indirect = 0;
        sgs[0].entries.push_back(entry);
        desc_id = source_vq.add_buf(sgs, 1, 0, null, 0);
        assert(desc_id != '1 && source_vq.total_add_buf_ops == 1)
            else `uvm_fatal("MIGRATION",
                $sformatf("%s production setup did not submit an active descriptor", vq_type.name()))

        fsm.freeze_for_migration(snapshot);
        assert((snapshot.queue_snapshots.size() == 2) &&
               (snapshot.mapping_records.size() == 1) &&
               (snapshot.mapping_records[0].mapping.iova == payload_iova))
            else `uvm_error("MIGRATION",
                $sformatf("%s source ring mappings leaked into generic migration DMA", vq_type.name()))
        if (inject_ring_write_on_stop) begin
            captured_ring_dirty_record = 0;
            foreach (snapshot.dirty_page_records[i]) begin
                if (snapshot.dirty_page_records[i].mapping.iova == source_device_iova)
                    captured_ring_dirty_record = 1;
            end
            if (vq_type == VQ_SPLIT)
                ring_write_offset = 16 * cfg.queue_size + 6 + 2 * cfg.queue_size;
            else
                ring_write_offset = 16 * cfg.queue_size + 4;
            saved_ring_write_matches =
                (snapshot.queue_snapshots[0].ring_data.size() >=
                 (ring_write_offset + fsm.stop_write_size));
            for (int unsigned byte_index = 0;
                 byte_index < fsm.stop_write_size;
                 byte_index++) begin
                if (snapshot.queue_snapshots[0].ring_data[
                        ring_write_offset + byte_index] != byte'(8'hA0 + byte_index))
                    saved_ring_write_matches = 0;
            end
            assert(captured_ring_dirty_record && saved_ring_write_matches)
                else `uvm_error("MIGRATION",
                    $sformatf("%s drain-time ring write was not retained in the queue snapshot",
                              vq_type.name()))
        end

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION",
                $sformatf("%s reset retained source ring or DMA resources", vq_type.name()))

        fsm.restore_from_migration(snapshot, restored);
        restored_vq = vq_mgr.get_queue(0);
        programmed_desc_iova = '0;
        programmed_driver_iova = '0;
        programmed_device_iova = '0;
        programmed_queue_size = 0;
        assert(restored && (restored_vq != null) &&
               transport.get_programmed_queue(0, programmed_desc_iova,
                                              programmed_driver_iova,
                                              programmed_device_iova,
                                              programmed_queue_size))
            else `uvm_error("MIGRATION",
                $sformatf("%s restore did not configure queue 0 through production setup", vq_type.name()))

        assert((programmed_queue_size == cfg.queue_size) &&
               iommu.get_active_mapping(transport.bdf, programmed_desc_iova,
                                        desc_mapping) &&
               iommu.get_active_mapping(transport.bdf, programmed_driver_iova,
                                        driver_mapping) &&
               iommu.get_active_mapping(transport.bdf, programmed_device_iova,
                                        device_mapping) &&
               (desc_mapping.gpa == restored_vq.desc_table_addr) &&
               (driver_mapping.gpa == restored_vq.driver_ring_addr) &&
               (device_mapping.gpa == restored_vq.device_ring_addr))
            else `uvm_error("MIGRATION",
                $sformatf("%s transport-programmed IOVAs do not resolve to live restored rings",
                          vq_type.name()))
        if (inject_ring_write_on_stop) begin
            source_iova_is_setup_ring = iommu.get_active_mapping(
                transport.bdf, source_device_iova, source_iova_mapping);
            assert(!source_iova_is_setup_ring ||
                   ((source_device_iova == programmed_device_iova) &&
                    (source_iova_mapping.gpa == restored_vq.device_ring_addr)))
                else `uvm_error("MIGRATION",
                    $sformatf("%s restore retained an old-ring generic DMA mapping", vq_type.name()))
        end

        if (vq_type == VQ_SPLIT) begin
            desc_size = 16 * cfg.queue_size;
            driver_size = 6 + 2 * cfg.queue_size;
            device_size = 6 + 8 * cfg.queue_size;
            restored_ring = new[desc_size + driver_size + device_size];
            mem.read_mem(restored_vq.desc_table_addr, desc_size, region);
            foreach (region[i]) restored_ring[i] = region[i];
            mem.read_mem(restored_vq.driver_ring_addr, driver_size, region);
            foreach (region[i]) restored_ring[desc_size + i] = region[i];
            mem.read_mem(restored_vq.device_ring_addr, device_size, region);
            foreach (region[i]) restored_ring[desc_size + driver_size + i] = region[i];
            expected_allocations = 7; // payload + three rings for each queue
        end else begin
            mem.read_mem(restored_vq.desc_table_addr,
                         snapshot.queue_snapshots[0].ring_data.size(), restored_ring);
            expected_allocations = 3; // payload + one contiguous ring per queue
        end
        assert(migration_snapshot_ring_bytes_equal(snapshot.queue_snapshots[0],
                                                  restored_ring))
            else `uvm_error("MIGRATION",
                $sformatf("%s programmed destination rings lost saved state",
                          vq_type.name()))
        if (inject_ring_write_on_stop) begin
            mem.read_mem(restored_vq.device_ring_addr, fsm.stop_write_size,
                         restored_event_bytes);
            saved_ring_write_matches =
                (restored_event_bytes.size() == fsm.stop_write_size);
            foreach (restored_event_bytes[i]) begin
                if (restored_event_bytes[i] != byte'(8'hA0 + i))
                    saved_ring_write_matches = 0;
            end
            assert(saved_ring_write_matches)
                else `uvm_error("MIGRATION",
                    $sformatf("%s setup-time destination ring lost drain-time write",
                              vq_type.name()))
        end

        payload_translated = iommu.translate(transport.bdf, payload_iova,
                                             payload.size(), DMA_TO_DEVICE,
                                             restored_payload_gpa, fault);
        if (payload_translated)
            mem.read_mem(restored_payload_gpa, payload.size(), restored_payload);
        assert(payload_translated && (fault == IOMMU_NO_FAULT) &&
               migration_bytes_equal(payload, restored_payload))
            else `uvm_error("MIGRATION",
                $sformatf("%s saved descriptor DMA IOVA did not resolve after restore", vq_type.name()))

        assert((iommu.active_mapping_count() == 7) &&
               (mem.outstanding_allocations() == expected_allocations) &&
               (vq_mgr.get_queue_count() == 2))
            else `uvm_error("MIGRATION",
                $sformatf("%s restore left an orphan mapping or ring allocation", vq_type.name()))

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION",
                $sformatf("%s post-restore reset retained ring or DMA resources", vq_type.name()))
    endtask

    // Create a real two-queue dataplane through the production queue setup
    // path. PCIe register accesses are represented by the focused transport,
    // while reset, allocation, IOMMU mapping, queue setup, and migration use
    // production implementations.
    task setup_outstanding_ownership_context(
        string                                      context_name,
        virtqueue_type_e                            vq_type,
        ref virtio_migration_dirty_test_transport   transport,
        ref virtio_migration_dirty_real_reset_ops   ops,
        ref virtio_migration_dirty_test_fsm         fsm,
        ref virtio_migration_dirty_tracking_iommu   iommu,
        ref virtio_migration_dirty_tracking_mem     mem,
        ref virtqueue_manager                       vq_mgr,
        ref virtio_driver_config_t                  cfg
    );
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector   err_inj;
        virtio_wait_policy         wait_pol;
        bit                        setup_ok;

        transport = virtio_migration_dirty_test_transport::type_id::create(
            $sformatf("%s_transport", context_name));
        ops = virtio_migration_dirty_real_reset_ops::type_id::create(
            $sformatf("%s_ops", context_name));
        fsm = virtio_migration_dirty_test_fsm::type_id::create(
            $sformatf("%s_fsm", context_name));
        iommu = virtio_migration_dirty_tracking_iommu::type_id::create(
            $sformatf("%s_iommu", context_name));
        mem = virtio_migration_dirty_tracking_mem::type_id::create(
            $sformatf("%s_mem", context_name));
        vq_mgr = virtqueue_manager::type_id::create(
            $sformatf("%s_vq_mgr", context_name));
        barrier = virtio_memory_barrier_model::type_id::create(
            $sformatf("%s_barrier", context_name));
        err_inj = virtqueue_error_injector::type_id::create(
            $sformatf("%s_err_inj", context_name));
        wait_pol = virtio_wait_policy::type_id::create(
            $sformatf("%s_wait_pol", context_name));

        mem.init_region(64'h7900_0000, 64'h7903_FFFF);
        transport.bdf = 16'h0910;
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.barrier = barrier;
        vq_mgr.err_inj = err_inj;
        vq_mgr.wait_pol = wait_pol;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.wait_pol = wait_pol;
        ops.use_full_queue_pair_setup = 1;
        ops.negotiated_features = '0;
        ops.negotiated_features[VIRTIO_F_RING_INDIRECT_DESC] = 1'b1;

        cfg = '{default: 0};
        cfg.num_queue_pairs = 1;
        cfg.queue_size = 8;
        cfg.vq_type = vq_type;
        cfg.driver_features = ops.negotiated_features;
        ops.setup_all_queues(cfg.num_queue_pairs, cfg.vq_type, cfg.queue_size,
                             setup_ok);
        assert(setup_ok)
            else `uvm_fatal("MIGRATION", "outstanding-ownership source queue setup failed")

        fsm.ops = ops;
        fsm.drv_cfg = cfg;
        fsm.mem = mem;
        fsm.iommu = iommu;
        fsm.bdf = transport.bdf;
        fsm.inject_write_on_stop = 0;
        fsm.configure_snapshot_queue_count(cfg.num_queue_pairs, 2);
        fsm.state = FSM_RUNNING;
    endtask

    task publish_split_tx_completion(
        host_mem_manager mem,
        virtqueue_base   vq,
        int unsigned     used_idx,
        int unsigned     head_id
    );
        byte entry[];
        byte idx_bytes[];

        entry = new[8];
        foreach (entry[i])
            entry[i] = 0;
        for (int unsigned byte_index = 0; byte_index < 4; byte_index++)
            entry[byte_index] = head_id[byte_index * 8 +: 8];
        mem.write_mem(vq.device_ring_addr + 4 + (used_idx - 1) * 8, entry);
        idx_bytes = new[2];
        idx_bytes[0] = used_idx[7:0];
        idx_bytes[1] = used_idx[15:8];
        mem.write_mem(vq.device_ring_addr + 2, idx_bytes);
    endtask

    task publish_packed_tx_completion(
        host_mem_manager mem,
        virtqueue_base   vq,
        int unsigned     descriptor_index
    );
        byte descriptor[];

        mem.read_mem(vq.desc_table_addr + descriptor_index * 16, 16,
                     descriptor);
        descriptor[15] = descriptor[15] | 8'h80;
        mem.write_mem(vq.desc_table_addr + descriptor_index * 16, descriptor);
    endtask

    task publish_tx_completion(
        virtqueue_type_e vq_type,
        host_mem_manager mem,
        virtqueue_base   vq,
        int unsigned     completion_index,
        int unsigned     descriptor_or_head
    );
        if (vq_type == VQ_SPLIT)
            publish_split_tx_completion(mem, vq, completion_index,
                                        descriptor_or_head);
        else
            publish_packed_tx_completion(mem, vq, descriptor_or_head);
    endtask

    // A direct TX owns two normal DMA mappings and an indirect TX additionally
    // owns a queue indirect table. Both completions must use ordinary queue
    // and atomic-op ownership after restore, never migration-only cleanup.
    task exercise_outstanding_ownership_restore(virtqueue_type_e vq_type);
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtqueue_base restored_tx_vq;
        virtio_net_hdr_t net_hdr;
        uvm_event direct_token;
        uvm_event indirect_token;
        uvm_event new_token;
        uvm_object completed[$];
        int unsigned direct_head;
        int unsigned indirect_head;
        int unsigned new_head;
        int unsigned ring_mapping_baseline;
        int unsigned ring_allocation_baseline;
        int unsigned completion_budget;
        bit restore_ok;

        setup_outstanding_ownership_context(
            $sformatf("%s_ownership", vq_type.name()), vq_type, transport,
            ops, fsm, iommu, mem, vq_mgr, cfg);
        ring_mapping_baseline = iommu.active_mapping_count();
        ring_allocation_baseline = mem.outstanding_allocations();
        net_hdr = '{default: 0};
        direct_token = new($sformatf("%s_direct", vq_type.name()));
        indirect_token = new($sformatf("%s_indirect", vq_type.name()));

        direct_head = '1;
        indirect_head = '1;
        ops.tx_submit(1, net_hdr, direct_token, 1'b0, direct_head);
        ops.tx_submit(1, net_hdr, indirect_token, 1'b1, indirect_head);
        assert((direct_head != '1) && (indirect_head != '1))
            else `uvm_fatal("MIGRATION",
                $sformatf("%s failed to submit direct and indirect pre-freeze TX", vq_type.name()))

        fsm.freeze_for_migration(snapshot);
        assert((fsm.state == FSM_FROZEN) &&
               (snapshot.queue_snapshots.size() == 2) &&
               (snapshot.mapping_records.size() == 5))
            else `uvm_fatal("MIGRATION",
                $sformatf("%s freeze did not capture direct/indirect DMA", vq_type.name()))

        fsm.restore_from_migration(snapshot, restore_ok);
        restored_tx_vq = vq_mgr.get_queue(1);
        assert(restore_ok && (restored_tx_vq != null) &&
               (ops.driver_ok_count == 1) && (fsm.start_count == 1))
            else `uvm_error("MIGRATION",
                $sformatf("%s restore did not restart the verified dataplane", vq_type.name()))

        publish_tx_completion(vq_type, mem, restored_tx_vq, 1, direct_head);
        completion_budget = 1;
        ops.tx_complete(1, completed, completion_budget);
        assert((completed.size() == 1) && (completed[0] == direct_token))
            else `uvm_error("MIGRATION",
                $sformatf("%s direct completion lost its pre-freeze token", vq_type.name()))

        publish_tx_completion(vq_type, mem, restored_tx_vq, 2, indirect_head);
        completion_budget = 1;
        ops.tx_complete(1, completed, completion_budget);
        assert((completed.size() == 2) && (completed[1] == indirect_token) &&
               (restored_tx_vq.get_indirect_table_count() == 0) &&
               (iommu.active_mapping_count() == ring_mapping_baseline) &&
               (mem.outstanding_allocations() == ring_allocation_baseline))
            else `uvm_error("MIGRATION",
                $sformatf("%s completion did not retire DMA/indirect ownership exactly once",
                          vq_type.name()))

        new_token = new($sformatf("%s_post_restore", vq_type.name()));
        new_head = '1;
        ops.tx_submit(1, net_hdr, new_token, 1'b0, new_head);
        assert(new_head != '1)
            else `uvm_error("MIGRATION",
                $sformatf("%s allocator rejected a new submission after completion", vq_type.name()))
        publish_tx_completion(vq_type, mem, restored_tx_vq, 3, new_head);
        completion_budget = 1;
        ops.tx_complete(1, completed, completion_budget);
        assert((completed.size() == 3) && (completed[2] == new_token) &&
               (iommu.active_mapping_count() == ring_mapping_baseline) &&
               (mem.outstanding_allocations() == ring_allocation_baseline))
            else `uvm_error("MIGRATION",
                $sformatf("%s post-restore submission did not complete cleanly", vq_type.name()))

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION",
                $sformatf("%s reset retained restored request ownership", vq_type.name()))
    endtask

    task test_split_outstanding_ownership_survives_restore();
        exercise_outstanding_ownership_restore(VQ_SPLIT);
    endtask

    task test_packed_outstanding_ownership_survives_restore();
        exercise_outstanding_ownership_restore(VQ_PACKED);
    endtask

    // A queue can own a DMA mapping independently of a submitted request.
    // The mapping must keep its original IOVA after migration, become owned
    // by the restored queue rather than the temporary migration list, and
    // release the destination allocation through the normal dma_unmap_buf()
    // path.
    task exercise_queue_dma_mapping_restore(virtqueue_type_e vq_type);
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtqueue_base source_vq;
        virtqueue_base restored_vq;
        bit [63:0] source_gpa;
        bit [63:0] stable_iova;
        int unsigned mapping_baseline;
        int unsigned allocation_baseline;
        bit restore_ok;
        virtio_migration_dirty_restore_error_catcher catcher;

        setup_outstanding_ownership_context(
            $sformatf("%s_queue_dma", vq_type.name()), vq_type, transport,
            ops, fsm, iommu, mem, vq_mgr, cfg);
        mapping_baseline = iommu.active_mapping_count();
        allocation_baseline = mem.outstanding_allocations();
        source_vq = vq_mgr.get_queue(1);
        source_gpa = mem.alloc(64, .align(1));
        assert((source_vq != null) && (source_gpa != '1))
            else `uvm_fatal("MIGRATION", "failed to allocate queue-owned DMA fixture")
        stable_iova = source_vq.dma_map_buf(source_gpa, 64, DMA_TO_DEVICE);
        assert((stable_iova != 0) &&
               (iommu.active_mapping_count() == (mapping_baseline + 1)) &&
               (mem.outstanding_allocations() == (allocation_baseline + 1)))
            else `uvm_fatal("MIGRATION", "failed to create queue-owned DMA fixture")

        fsm.freeze_for_migration(snapshot);
        ops.device_reset();
        mem.free(source_gpa);
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("MIGRATION",
                "source reset retained queue-owned DMA fixture")

        fsm.restore_from_migration(snapshot, restore_ok);
        restored_vq = vq_mgr.get_queue(1);
        assert(restore_ok && (restored_vq != null) &&
               (iommu.active_mapping_count() == (mapping_baseline + 1)) &&
               (mem.outstanding_allocations() == (allocation_baseline + 1)) &&
               (ops.pending_migration_restore_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s queue DMA mapping was not transferred to restored queue ownership",
                vq_type.name()))

        catcher = new($sformatf("%s_queue_dma_unmap", vq_type.name()));
        uvm_report_cb::add(null, catcher);
        restored_vq.dma_unmap_buf(stable_iova);
        uvm_report_cb::delete(null, catcher);
        assert((catcher.caught_count == 0) &&
               (iommu.active_mapping_count() == mapping_baseline) &&
               (mem.outstanding_allocations() == allocation_baseline) &&
               (ops.pending_migration_restore_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s dma_unmap_buf did not release restored queue DMA ownership",
                vq_type.name()))

        ops.device_reset();
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s queue DMA post-restore reset retained resources", vq_type.name()))
    endtask

    task test_split_queue_dma_mapping_survives_restore();
        exercise_queue_dma_mapping_restore(VQ_SPLIT);
    endtask

    task test_packed_queue_dma_mapping_survives_restore();
        exercise_queue_dma_mapping_restore(VQ_PACKED);
    endtask

    // Queue ownership claims are collected as indirect tables followed by
    // dma_map_buf() entries, which need not match materialization order.  Put
    // the explicit mapping first so its temporary-list index is lower than
    // the indirect table's index, then prove both queue-owned records are
    // transferred exactly once.
    task exercise_queue_dma_precedes_indirect_restore(virtqueue_type_e vq_type);
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtqueue_base source_vq;
        virtqueue_base restored_vq;
        virtio_net_hdr_t net_hdr;
        uvm_event indirect_token;
        uvm_object completed[$];
        bit [63:0] source_gpa;
        bit [63:0] stable_iova;
        int unsigned indirect_head;
        int unsigned mapping_baseline;
        int unsigned allocation_baseline;
        int unsigned completion_budget;
        int queue_dma_mapping_index;
        int indirect_mapping_index;
        bit restore_ok;
        virtio_migration_dirty_restore_error_catcher catcher;

        setup_outstanding_ownership_context(
            $sformatf("%s_queue_dma_before_indirect", vq_type.name()), vq_type,
            transport, ops, fsm, iommu, mem, vq_mgr, cfg);
        mapping_baseline = iommu.active_mapping_count();
        allocation_baseline = mem.outstanding_allocations();
        source_vq = vq_mgr.get_queue(1);
        source_gpa = mem.alloc(64, .align(1));
        assert((source_vq != null) && (source_gpa != '1))
            else `uvm_fatal("MIGRATION",
                "failed to allocate queue DMA before indirect fixture")
        stable_iova = source_vq.dma_map_buf(source_gpa, 64, DMA_TO_DEVICE);
        assert((stable_iova != '1) && (stable_iova != 0))
            else `uvm_fatal("MIGRATION",
                "failed to map queue DMA before indirect fixture")

        net_hdr = '{default: 0};
        indirect_token = new($sformatf("%s_queue_dma_before_indirect",
                                        vq_type.name()));
        indirect_head = '1;
        ops.tx_submit(1, net_hdr, indirect_token, 1'b1, indirect_head);
        assert(indirect_head != '1)
            else `uvm_fatal("MIGRATION", $sformatf(
                "%s failed to submit indirect TX after queue DMA map", vq_type.name()))

        fsm.freeze_for_migration(snapshot);
        queue_dma_mapping_index = -1;
        indirect_mapping_index = -1;
        if (snapshot.queue_snapshots[1].indirect_tables.size() == 1) begin
            foreach (snapshot.mapping_records[i]) begin
                if (snapshot.mapping_records[i].mapping.iova == stable_iova)
                    queue_dma_mapping_index = i;
                if (snapshot.mapping_records[i].mapping.iova ==
                    snapshot.queue_snapshots[1].indirect_tables[0].mapping.iova)
                    indirect_mapping_index = i;
            end
        end
        assert((snapshot.queue_snapshots[1].queue_dma_mappings.size() == 1) &&
               (snapshot.queue_snapshots[1].indirect_tables.size() == 1) &&
               (queue_dma_mapping_index >= 0) &&
               (indirect_mapping_index >= 0) &&
               (queue_dma_mapping_index < indirect_mapping_index))
            else `uvm_fatal("MIGRATION", $sformatf(
                "%s freeze did not retain reverse-order queue ownership", vq_type.name()))

        ops.device_reset();
        mem.free(source_gpa);
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0))
            else `uvm_fatal("MIGRATION", $sformatf(
                "%s source reset retained queue DMA before indirect fixture", vq_type.name()))

        fsm.restore_from_migration(snapshot, restore_ok);
        restored_vq = vq_mgr.get_queue(1);
        assert(restore_ok && (restored_vq != null) &&
               (restored_vq.get_indirect_table_count() == 1) &&
               (ops.pending_migration_restore_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s reverse-order queue ownership was not fully claimed", vq_type.name()))

        publish_tx_completion(vq_type, mem, restored_vq, 1, indirect_head);
        completion_budget = 1;
        ops.tx_complete(1, completed, completion_budget);
        assert((completed.size() == 1) && (completed[0] == indirect_token) &&
               (restored_vq.get_indirect_table_count() == 0) &&
               (ops.pending_migration_restore_count() == 0) &&
               (iommu.active_mapping_count() == (mapping_baseline + 1)) &&
               (mem.outstanding_allocations() == (allocation_baseline + 1)))
            else `uvm_error("MIGRATION", $sformatf(
                "%s indirect completion did not retire reverse-order ownership", vq_type.name()))

        catcher = new($sformatf("%s_queue_dma_before_indirect_unmap",
                                 vq_type.name()));
        uvm_report_cb::add(null, catcher);
        restored_vq.dma_unmap_buf(stable_iova);
        uvm_report_cb::delete(null, catcher);
        assert((catcher.caught_count == 0) &&
               (ops.pending_migration_restore_count() == 0) &&
               (iommu.active_mapping_count() == mapping_baseline) &&
               (mem.outstanding_allocations() == allocation_baseline))
            else `uvm_error("MIGRATION", $sformatf(
                "%s dma_unmap_buf did not retire reverse-order queue DMA", vq_type.name()))

        catcher = new($sformatf("%s_queue_dma_before_indirect_reset",
                                 vq_type.name()));
        uvm_report_cb::add(null, catcher);
        ops.device_reset();
        uvm_report_cb::delete(null, catcher);
        assert((catcher.caught_count == 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s reset leaked or double-freed reverse-order ownership", vq_type.name()))
    endtask

    task test_split_queue_dma_precedes_indirect_restore();
        exercise_queue_dma_precedes_indirect_restore(VQ_SPLIT);
    endtask

    task test_packed_queue_dma_precedes_indirect_restore();
        exercise_queue_dma_precedes_indirect_restore(VQ_PACKED);
    endtask

    task prepare_restore_rejection_snapshot(
        string                                      context_name,
        ref virtio_migration_dirty_test_transport   transport,
        ref virtio_migration_dirty_real_reset_ops   ops,
        ref virtio_migration_dirty_test_fsm         fsm,
        ref virtio_migration_dirty_tracking_iommu   iommu,
        ref virtio_migration_dirty_tracking_mem     mem,
        ref virtqueue_manager                       vq_mgr,
        ref virtio_driver_config_t                  cfg,
        ref virtio_device_snapshot_t                snapshot
    );
        setup_outstanding_ownership_context(context_name, VQ_SPLIT, transport,
                                            ops, fsm, iommu, mem, vq_mgr, cfg);
        fsm.freeze_for_migration(snapshot);
        assert((fsm.state == FSM_FROZEN) && (snapshot.queue_snapshots.size() == 2))
            else `uvm_fatal("MIGRATION", "failed to create restore-rejection snapshot")
    endtask

    task assert_restore_rejected_without_start(
        string                                      scenario,
        virtio_migration_dirty_real_reset_ops       ops,
        virtio_migration_dirty_test_fsm             fsm,
        virtio_device_snapshot_t                    snapshot
    );
        bit restore_ok;

        fsm.restore_from_migration(snapshot, restore_ok);
        assert(!restore_ok && (ops.driver_ok_count == 0) &&
               (fsm.start_count == 0) && (fsm.state != FSM_RUNNING))
            else `uvm_error("MIGRATION",
                $sformatf("%s restored DRIVER_OK or started dataplane after rejection", scenario))
    endtask

    task test_restore_rejects_failed_verified_reset();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtio_migration_dirty_restore_error_catcher catcher;

        prepare_restore_rejection_snapshot("failed_verified_reset", transport, ops,
                                          fsm, iommu, mem, vq_mgr, cfg, snapshot);
        transport.device_reset_complete = 0;
        catcher = new("failed_verified_reset_catcher");
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("failed verified reset", ops, fsm, snapshot);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count != 0)
            else `uvm_error("MIGRATION", "failed verified reset did not report rejection")
    endtask

    task test_restore_rejects_feature_mismatch();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtio_migration_dirty_restore_error_catcher catcher;

        prepare_restore_rejection_snapshot("feature_mismatch", transport, ops,
                                          fsm, iommu, mem, vq_mgr, cfg, snapshot);
        ops.force_feature_mismatch = 1;
        catcher = new("feature_mismatch_catcher");
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("feature mismatch", ops, fsm, snapshot);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count != 0)
            else `uvm_error("MIGRATION", "feature mismatch did not report rejection")
    endtask

    task test_restore_rejects_missing_snapshot_queue();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtqueue_snapshot_t first_queue;
        virtio_migration_dirty_restore_error_catcher catcher;

        prepare_restore_rejection_snapshot("missing_snapshot_queue", transport, ops,
                                          fsm, iommu, mem, vq_mgr, cfg, snapshot);
        first_queue = snapshot.queue_snapshots[0];
        snapshot.queue_snapshots = new[1];
        snapshot.queue_snapshots[0] = first_queue;
        fsm.refresh_snapshot_integrity(snapshot);
        catcher = new("missing_snapshot_queue_catcher");
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("missing snapshot queue", ops, fsm, snapshot);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count != 0)
            else `uvm_error("MIGRATION", "missing snapshot queue did not report rejection")
    endtask

    task test_restore_rejects_incompatible_snapshot_queue();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtio_migration_dirty_restore_error_catcher catcher;

        prepare_restore_rejection_snapshot("incompatible_snapshot_queue", transport,
                                          ops, fsm, iommu, mem, vq_mgr, cfg, snapshot);
        snapshot.queue_snapshots[1].queue_size = cfg.queue_size - 1;
        fsm.refresh_snapshot_integrity(snapshot);
        catcher = new("incompatible_snapshot_queue_catcher");
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("incompatible snapshot queue", ops, fsm,
                                              snapshot);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count != 0)
            else `uvm_error("MIGRATION", "incompatible snapshot queue did not report rejection")
    endtask

    task test_restore_rejects_queue_overlay_failure();
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        byte unsigned shortened_ring[];
        virtio_migration_dirty_restore_error_catcher catcher;

        prepare_restore_rejection_snapshot("queue_overlay_failure", transport, ops,
                                          fsm, iommu, mem, vq_mgr, cfg, snapshot);
        shortened_ring = new[snapshot.queue_snapshots[0].ring_data.size() - 1];
        foreach (shortened_ring[i])
            shortened_ring[i] = snapshot.queue_snapshots[0].ring_data[i];
        snapshot.queue_snapshots[0].ring_data = shortened_ring;
        fsm.refresh_snapshot_integrity(snapshot);
        catcher = new("queue_overlay_failure_catcher");
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("queue overlay failure", ops, fsm, snapshot);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count != 0)
            else `uvm_error("MIGRATION", "queue overlay failure did not report rejection")
    endtask

    // The indirect table and dma_map_buf() record belong to TX queue 1, while
    // the deliberately bad RX queue-0 image fails before TX can restore. A
    // failed overlay must leave both records in rollback ownership so the
    // restore path's immediate verified reset retires them exactly once.
    task exercise_restore_overlay_failure_releases_unclaimed_queue_mappings(
        virtqueue_type_e vq_type
    );
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtio_net_hdr_t net_hdr;
        uvm_event indirect_token;
        virtqueue_base source_vq;
        bit [63:0] queue_dma_gpa;
        bit [63:0] queue_dma_iova;
        byte unsigned shortened_ring[];
        int unsigned indirect_head;
        bit restore_ok;
        virtio_migration_dirty_restore_error_catcher catcher;

        setup_outstanding_ownership_context(
                                            $sformatf("%s_overlay_queue_rollback",
                                                      vq_type.name()),
                                            vq_type, transport, ops, fsm,
                                            iommu, mem, vq_mgr, cfg);
        net_hdr = '{default: 0};
        indirect_token = new("overlay_indirect_token");
        indirect_head = '1;
        ops.tx_submit(1, net_hdr, indirect_token, 1'b1, indirect_head);
        assert(indirect_head != '1)
            else `uvm_fatal("MIGRATION",
                "failed to submit indirect request for overlay rollback")
        source_vq = vq_mgr.get_queue(1);
        queue_dma_gpa = mem.alloc(64, .align(1));
        assert((source_vq != null) && (queue_dma_gpa != '1))
            else `uvm_fatal("MIGRATION",
                "failed to allocate queue DMA for overlay rollback")
        queue_dma_iova = source_vq.dma_map_buf(queue_dma_gpa, 64,
                                                DMA_TO_DEVICE);
        assert(queue_dma_iova != 0)
            else `uvm_fatal("MIGRATION",
                "failed to map queue DMA for overlay rollback")
        fsm.freeze_for_migration(snapshot);
        assert((snapshot.queue_snapshots[1].indirect_tables.size() == 1) &&
               (snapshot.queue_snapshots[1].queue_dma_mappings.size() == 1) &&
               (snapshot.mapping_records.size() == 4))
            else `uvm_fatal("MIGRATION",
                "freeze did not retain indirect-table ownership")

        // Retire the source before restore so this regression observes only
        // destination ownership. The snapshot payload supplies the bytes and
        // fixed IOVA for both the indirect table and queue dma_map_buf entry.
        ops.device_reset();
        mem.free(queue_dma_gpa);
        assert((iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_fatal("MIGRATION",
                "source reset retained overlay rollback ownership")

        shortened_ring = new[snapshot.queue_snapshots[0].ring_data.size() - 1];
        foreach (shortened_ring[i])
            shortened_ring[i] = snapshot.queue_snapshots[0].ring_data[i];
        snapshot.queue_snapshots[0].ring_data = shortened_ring;
        fsm.refresh_snapshot_integrity(snapshot);

        catcher = new($sformatf("%s_overlay_queue_rollback_catcher",
                                vq_type.name()));
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snapshot, restore_ok);
        uvm_report_cb::delete(null, catcher);
        assert(!restore_ok && (fsm.start_count == 0) &&
               (catcher.caught_count != 0) &&
               (iommu.active_mapping_count() == 0) &&
               (mem.outstanding_allocations() == 0) &&
               (vq_mgr.get_queue_count() == 0))
            else `uvm_error("MIGRATION",
                "overlay failure did not immediately release restored ownership")
    endtask

    task test_restore_overlay_failure_releases_unclaimed_queue_mappings();
        exercise_restore_overlay_failure_releases_unclaimed_queue_mappings(
            VQ_SPLIT);
        exercise_restore_overlay_failure_releases_unclaimed_queue_mappings(
            VQ_PACKED);
    endtask

    // queue_dma_mappings participates in the device snapshot checksum. Even
    // after a test deliberately refreshes that checksum, malformed ownership
    // metadata must be rejected before reset materializes any destination
    // allocation or transfers temporary migration ownership.
    task exercise_tampered_queue_dma_ownership_rejection(virtqueue_type_e vq_type);
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtqueue_base source_vq;
        bit [63:0] source_gpa;
        bit [63:0] stable_iova;
        virtio_migration_dirty_restore_error_catcher catcher;

        setup_outstanding_ownership_context(
            $sformatf("%s_tampered_queue_dma", vq_type.name()), vq_type,
            transport, ops, fsm, iommu, mem, vq_mgr, cfg);
        source_vq = vq_mgr.get_queue(1);
        source_gpa = mem.alloc(64, .align(1));
        assert((source_vq != null) && (source_gpa != '1))
            else `uvm_fatal("MIGRATION", "failed to allocate queue DMA tamper fixture")
        stable_iova = source_vq.dma_map_buf(source_gpa, 64, DMA_TO_DEVICE);
        assert((stable_iova != '1) && (stable_iova != 0))
            else `uvm_fatal("MIGRATION", "failed to map queue DMA tamper fixture")

        fsm.freeze_for_migration(snapshot);
        assert(snapshot.queue_snapshots[1].queue_dma_mappings.size() == 1)
            else `uvm_fatal("MIGRATION", "freeze did not capture queue DMA tamper fixture")

        // desc_id is invalid for dma_map_buf(), yet it is covered by the
        // refreshed checksum. This proves structural validation remains in
        // force after trusted-snapshot integrity has been recomputed.
        snapshot.queue_snapshots[1].queue_dma_mappings[0].desc_id = 1;
        fsm.refresh_snapshot_integrity(snapshot);
        catcher = new($sformatf("%s_tampered_queue_dma_catcher", vq_type.name()));
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start("tampered queue DMA", ops, fsm,
                                              snapshot);
        uvm_report_cb::delete(null, catcher);
        assert((catcher.caught_count != 0) &&
               (ops.verified_reset_count == 0) &&
               (ops.migration_materialize_count == 0) &&
               (ops.pending_migration_restore_count() == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s did not reject tampered queue DMA before reset/materialization",
                vq_type.name()))

        // Validation fails before reset, so the source caller still owns its
        // explicit GPA and must release it after ordinary queue teardown.
        ops.device_reset();
        mem.free(source_gpa);
    endtask

    task test_restore_rejects_tampered_queue_dma_ownership();
        exercise_tampered_queue_dma_ownership_rejection(VQ_SPLIT);
        exercise_tampered_queue_dma_ownership_rejection(VQ_PACKED);
    endtask

    // Normal DMA ownership is consumed by a queue-specific FIFO.  A snapshot
    // with a refreshed integrity checksum must still reject an ownership
    // record that names a queue outside the saved topology, reverses the
    // TX/RX role of an otherwise valid data queue, changes DMA direction, or
    // makes the pair/count topology inconsistent before reset can begin.
    task exercise_tampered_normal_dma_ownership_rejection(
        string       scenario,
        int unsigned corruption_kind
    );
        virtio_migration_dirty_test_transport transport;
        virtio_migration_dirty_real_reset_ops ops;
        virtio_migration_dirty_test_fsm fsm;
        virtio_migration_dirty_tracking_iommu iommu;
        virtio_migration_dirty_tracking_mem mem;
        virtqueue_manager vq_mgr;
        virtio_driver_config_t cfg;
        virtio_device_snapshot_t snapshot;
        virtio_net_hdr_t net_hdr;
        uvm_event tx_token;
        int unsigned tx_head;
        virtio_migration_dirty_restore_error_catcher catcher;

        setup_outstanding_ownership_context(
            scenario, VQ_SPLIT, transport, ops, fsm, iommu, mem, vq_mgr, cfg);
        net_hdr = '{default: 0};
        tx_token = new({scenario, "_token"});
        tx_head = '1;
        ops.tx_submit(1, net_hdr, tx_token, 1'b0, tx_head);
        assert(tx_head != '1)
            else `uvm_fatal("MIGRATION", $sformatf(
                "%s failed to submit outstanding TX DMA", scenario))

        fsm.freeze_for_migration(snapshot);
        assert(snapshot.normal_dma_records.size() == 2)
            else `uvm_fatal("MIGRATION", $sformatf(
                "%s freeze did not capture outstanding normal TX DMA", scenario))

        case (corruption_kind)
            0: snapshot.normal_dma_records[0].queue_id = snapshot.queue_count;
            1: snapshot.normal_dma_records[0].is_tx = 0;
            2: snapshot.normal_dma_records[0].mapping.dir = DMA_FROM_DEVICE;
            3: snapshot.num_queue_pairs++;
            default: `uvm_fatal("MIGRATION", "unknown normal-DMA corruption kind")
        endcase
        fsm.refresh_snapshot_integrity(snapshot);

        catcher = new({scenario, "_catcher"});
        uvm_report_cb::add(null, catcher);
        assert_restore_rejected_without_start(scenario, ops, fsm, snapshot);
        uvm_report_cb::delete(null, catcher);
        assert((catcher.caught_count != 0) &&
               (ops.verified_reset_count == 0) &&
               (ops.migration_materialize_count == 0) &&
               (ops.normal_dma_restore_count == 0))
            else `uvm_error("MIGRATION", $sformatf(
                "%s did not reject normal DMA before reset/materialization/ownership transfer",
                scenario))
    endtask

    task test_restore_rejects_tampered_normal_dma_ownership();
        exercise_tampered_normal_dma_ownership_rejection(
            "normal_dma_invalid_queue_id", 0);
        exercise_tampered_normal_dma_ownership_rejection(
            "normal_dma_tx_rx_role_mismatch", 1);
        exercise_tampered_normal_dma_ownership_rejection(
            "normal_dma_direction_mismatch", 2);
        exercise_tampered_normal_dma_ownership_rejection(
            "normal_dma_incomplete_queue_topology", 3);
    endtask
endclass : virtio_migration_dirty_test

`endif // VIRTIO_MIGRATION_DIRTY_TEST_SV
