`ifndef VIRTIO_ATOMIC_OPS_SV
`define VIRTIO_ATOMIC_OPS_SV

// ============================================================================
// virtio_atomic_ops
//
// Low-level atomic operations library for the virtio-net driver VIP.
// One method per real Linux virtio-net driver operation.
//
// Used by:
//   - virtio_auto_fsm (AUTO mode): full lifecycle orchestration
//   - Sequences directly (MANUAL mode): fine-grained control
//
// Depends on:
//   - virtio_pci_transport (PCI register access, kick, feature negotiation)
//   - virtqueue_manager (queue create/destroy/get)
//   - host_mem_manager (buffer allocation)
//   - virtio_iommu_model (DMA address translation)
//   - virtio_wait_policy (timeout/polling)
//   - virtio_net_types.sv (all type/struct definitions)
//   - virtio_net_hdr.sv (header pack/unpack)
// ============================================================================

class virtio_atomic_ops extends uvm_object;
    `uvm_object_utils(virtio_atomic_ops)

    // ===== External component references (set by agent) =====
    virtio_pci_transport       transport;
    virtqueue_manager          vq_mgr;
    host_mem_manager           mem;
    virtio_iommu_model         iommu;
    virtio_wait_policy         wait_pol;

    // ===== Negotiated state =====
    bit [63:0]                 negotiated_features;

    // ===== Internal tracking =====
    // Normal data DMA owns both sides of a mapping.  Retaining only the IOVA
    // made reset/teardown able to unmap (at best) while leaking the host
    // buffer that backs it.  Keep the ownership pair together until one
    // completion or a verified device reset retires it.
    typedef struct {
        int unsigned host_id;
        bit [15:0] bdf;
        bit [63:0] gpa;
        bit [63:0] iova;
    } normal_dma_record_t;
    protected normal_dma_record_t tx_dma_map[int unsigned][$];
    protected normal_dma_record_t rx_dma_map[int unsigned][$];
    // Migration payloads are recreated after reset rather than being tied to
    // a pre-freeze queue.  They still have normal DMA ownership and must be
    // retired by every later ordinary device reset.
    protected normal_dma_record_t migration_restore_dma[$];
    protected bit [63:0]         ring_iovas[int unsigned][$];  // queue_id -> ring IOVAs (desc, avail, used)

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_atomic_ops");
        super.new(name);
        negotiated_features = '0;
    endfunction

    // A numeric BDF is scoped by the PCIe host domain.  Standalone transports
    // without a frozen identity retain the legacy host0 behavior.
    protected function int unsigned get_iommu_host_id(
        virtio_pci_transport t
    );
        if (t != null)
            return t.iommu_host_id();
        return 0;
    endfunction

    // Retire one ordinary data-DMA ownership record.  This is deliberately
    // separate from ring/indirect-table ownership, which remains owned by
    // the virtqueue implementation.
    protected function void retire_normal_dma_record(
        normal_dma_record_t record
    );
        iommu.unmap_for_host(record.host_id, record.bdf, record.iova);
        mem.free(record.gpa);
    endfunction

    protected function void retire_normal_dma_records(
        ref normal_dma_record_t records[$]
    );
        foreach (records[i]) begin
            retire_normal_dma_record(records[i]);
        end
        records.delete();
    endfunction

    protected function bit has_pending_normal_dma();
        foreach (tx_dma_map[qid]) begin
            if (tx_dma_map[qid].size() != 0)
                return 1;
        end
        foreach (rx_dma_map[qid]) begin
            if (rx_dma_map[qid].size() != 0)
                return 1;
        end
        return (migration_restore_dma.size() != 0);
    endfunction

    // Device-side writers must use this completed-write boundary instead of
    // calling IOMMU translate() followed by host_mem.write_mem().  It commits
    // bytes first and lets the IOMMU preserve a migration generation payload
    // before a completion path may unmap/free this DMA allocation.
    virtual function bit device_dma_write(bit [63:0] iova, byte data[],
                                          ref iommu_fault_e fault);
        if ((transport == null) || (iommu == null) || (mem == null)) begin
            fault = IOMMU_FAULT_UNMAPPED;
            `uvm_error("ATOMIC_OPS", "device_dma_write: incomplete DMA context")
            return 0;
        end
        return iommu.write_from_device_for_host(get_iommu_host_id(transport),
                                                mem, transport.bdf, iova,
                                                data, fault);
    endfunction

    // Materialize one complete saved mapping after reset.  The destination
    // retains the original IOVA layout so saved descriptors (including raw
    // split, packed, and indirect forms) keep resolving without rewriting.
    // Callers that only have retired dirty-page spans assemble a zero-filled
    // complete payload before calling this common ownership boundary.
    virtual function bit materialize_migration_mapping(
        iommu_mapping_t source_mapping,
        byte source_payload[],
        ref iommu_mapping_t destination
    );
        bit [63:0] destination_gpa;
        bit [63:0] destination_iova;
        normal_dma_record_t ownership;

        destination.host_id = '0;
        destination.bdf = '0;
        destination.gpa = '0;
        destination.iova = '0;
        destination.size = 0;
        destination.dir = DMA_TO_DEVICE;
        destination.desc_id = 0;
        if ((transport == null) || (iommu == null) || (mem == null)) begin
            `uvm_error("ATOMIC_OPS",
                "materialize_migration_mapping: incomplete DMA context")
            return 0;
        end
        if (source_mapping.size == 0) begin
            `uvm_error("ATOMIC_OPS",
                "materialize_migration_mapping: zero-size source mapping")
            return 0;
        end
        if (source_payload.size() != source_mapping.size) begin
            `uvm_error("ATOMIC_OPS",
                "materialize_migration_mapping: source payload size mismatch")
            return 0;
        end

        destination_gpa = mem.alloc(source_mapping.size, .align(1));
        if (destination_gpa == '1) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "materialize_migration_mapping: allocation failed for %0d bytes",
                source_mapping.size))
            return 0;
        end
        mem.write_mem(destination_gpa, source_payload);
        destination_iova = iommu.map_fixed_for_host(source_mapping.host_id,
                                           source_mapping.bdf, destination_gpa,
                                           source_mapping.size, source_mapping.dir,
                                           source_mapping.iova);
        if ((destination_iova == '1) || (destination_iova == 0)) begin
            mem.free(destination_gpa);
            `uvm_error("ATOMIC_OPS",
                "materialize_migration_mapping: fixed destination DMA map failed")
            return 0;
        end

        destination.host_id = source_mapping.host_id;
        destination.bdf = source_mapping.bdf;
        destination.gpa = destination_gpa;
        destination.iova = destination_iova;
        destination.size = source_mapping.size;
        destination.dir = source_mapping.dir;
        destination.desc_id = source_mapping.desc_id;
        ownership.host_id = source_mapping.host_id;
        ownership.bdf = source_mapping.bdf;
        ownership.gpa = destination_gpa;
        ownership.iova = destination_iova;
        migration_restore_dma.push_back(ownership);
        return 1;
    endfunction

    function void release_migration_restore_payloads();
        retire_normal_dma_records(migration_restore_dma);
    endfunction

    // Snapshot normal data DMA in the exact FIFO order consumed by TX/RX
    // completion. Raw ring bytes retain only IOVAs; they do not identify the
    // allocation that completion must retire.
    virtual function bit snapshot_normal_dma_ownership(
        ref virtio_normal_dma_snapshot_t records[$]
    );
        records.delete();
        if (iommu == null) begin
            `uvm_error("ATOMIC_OPS", "snapshot normal DMA: missing IOMMU")
            return 0;
        end
        foreach (tx_dma_map[queue_id]) begin
            foreach (tx_dma_map[queue_id][i]) begin
                iommu_mapping_t mapping;
                virtio_normal_dma_snapshot_t snapshot_record;

                if (!iommu.get_live_mapping_for_host(
                                            tx_dma_map[queue_id][i].host_id,
                                            tx_dma_map[queue_id][i].bdf,
                                            tx_dma_map[queue_id][i].iova,
                                            mapping)) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "snapshot normal DMA: TX mapping missing queue_id=%0d IOVA=0x%016h",
                        queue_id, tx_dma_map[queue_id][i].iova))
                    records.delete();
                    return 0;
                end
                snapshot_record.queue_id = queue_id;
                snapshot_record.is_tx = 1;
                snapshot_record.mapping = mapping;
                records.push_back(snapshot_record);
            end
        end
        foreach (rx_dma_map[queue_id]) begin
            foreach (rx_dma_map[queue_id][i]) begin
                iommu_mapping_t mapping;
                virtio_normal_dma_snapshot_t snapshot_record;

                if (!iommu.get_live_mapping_for_host(
                                            rx_dma_map[queue_id][i].host_id,
                                            rx_dma_map[queue_id][i].bdf,
                                            rx_dma_map[queue_id][i].iova,
                                            mapping)) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "snapshot normal DMA: RX mapping missing queue_id=%0d IOVA=0x%016h",
                        queue_id, rx_dma_map[queue_id][i].iova))
                    records.delete();
                    return 0;
                end
                snapshot_record.queue_id = queue_id;
                snapshot_record.is_tx = 0;
                snapshot_record.mapping = mapping;
                records.push_back(snapshot_record);
            end
        end
        return 1;
    endfunction

    protected function bit claim_migration_restore_dma(
        iommu_mapping_t expected, ref normal_dma_record_t destination
    );
        destination = '{default: 0};
        foreach (migration_restore_dma[i]) begin
            iommu_mapping_t live_mapping;

            if ((migration_restore_dma[i].host_id != expected.host_id) ||
                (migration_restore_dma[i].bdf != expected.bdf) ||
                (migration_restore_dma[i].iova != expected.iova))
                continue;
            if (!iommu.get_live_mapping_for_host(expected.host_id,
                                        expected.bdf, expected.iova,
                                        live_mapping) ||
                (live_mapping.size != expected.size) ||
                (live_mapping.dir != expected.dir))
                return 0;
            destination = migration_restore_dma[i];
            migration_restore_dma.delete(i);
            return 1;
        end
        return 0;
    endfunction

    // Move restored destination allocations from the temporary migration
    // ownership list back into the same TX/RX queues that completion and
    // verified reset already understand.
    virtual function bit restore_normal_dma_ownership(
        virtio_normal_dma_snapshot_t records[$]
    );
        foreach (records[i]) begin
            normal_dma_record_t destination;

            if (!claim_migration_restore_dma(records[i].mapping, destination)) begin
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "restore normal DMA: source IOVA 0x%016h was not materialized",
                    records[i].mapping.iova))
                return 0;
            end
            if (records[i].is_tx) begin
                if (!tx_dma_map.exists(records[i].queue_id))
                    tx_dma_map[records[i].queue_id] = {};
                tx_dma_map[records[i].queue_id].push_back(destination);
            end else begin
                if (!rx_dma_map.exists(records[i].queue_id))
                    rx_dma_map[records[i].queue_id] = {};
                rx_dma_map[records[i].queue_id].push_back(destination);
            end
        end
        return 1;
    endfunction

    // Queue-owned migration DMA includes indirect descriptor tables and
    // explicit dma_map_buf() mappings.  Both begin in migration_restore_dma
    // after materialization and must be claimed as one queue transaction.
    protected function void collect_restored_queue_mappings(
        virtqueue_snapshot_t queue_snapshot,
        ref iommu_mapping_t expected_mappings[$]
    );
        expected_mappings.delete();
        foreach (queue_snapshot.indirect_tables[i])
            expected_mappings.push_back(queue_snapshot.indirect_tables[i].mapping);
        foreach (queue_snapshot.queue_dma_mappings[i])
            expected_mappings.push_back(queue_snapshot.queue_dma_mappings[i]);
    endfunction

    // Locate every temporary record before deleting any of them.  This makes
    // the handoff all-or-nothing: a bad queue snapshot remains entirely in
    // migration_restore_dma for the restore rollback reset to retire.
    protected function bit collect_migration_restore_claim_indices(
        iommu_mapping_t expected_mappings[$],
        ref int unsigned claim_indices[$]
    );
        claim_indices.delete();
        foreach (expected_mappings[i]) begin
            int found_index;
            iommu_mapping_t live_mapping;

            found_index = -1;
            if ((expected_mappings[i].host_id != get_iommu_host_id(transport)) ||
                (expected_mappings[i].bdf != transport.bdf) ||
                (expected_mappings[i].iova == 0) ||
                (expected_mappings[i].size == 0)) begin
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "restore queue ownership: invalid source IOVA 0x%016h",
                    expected_mappings[i].iova))
                return 0;
            end
            foreach (migration_restore_dma[m]) begin
                bit already_claimed;

                already_claimed = 0;
                foreach (claim_indices[c]) begin
                    if (claim_indices[c] == m) begin
                        already_claimed = 1;
                        break;
                    end
                end
                if (already_claimed ||
                    (migration_restore_dma[m].host_id != expected_mappings[i].host_id) ||
                    (migration_restore_dma[m].bdf != expected_mappings[i].bdf) ||
                    (migration_restore_dma[m].iova != expected_mappings[i].iova))
                    continue;
                if (!iommu.get_live_mapping_for_host(
                                            expected_mappings[i].host_id,
                                            expected_mappings[i].bdf,
                                            expected_mappings[i].iova,
                                            live_mapping) ||
                    (live_mapping.size != expected_mappings[i].size) ||
                    (live_mapping.dir != expected_mappings[i].dir)) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "restore queue ownership: materialized IOVA 0x%016h has invalid layout",
                        expected_mappings[i].iova))
                    return 0;
                end
                found_index = m;
                break;
            end
            if (found_index < 0) begin
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "restore queue ownership: source IOVA 0x%016h was not materialized",
                    expected_mappings[i].iova))
                return 0;
            end
            claim_indices.push_back(found_index);
        end
        return 1;
    endfunction

    // Validate every queue-owned mapping before the first queue overlay. The
    // temporary migration list remains the sole physical owner at this stage,
    // so an early overlay failure is cleaned by the ordinary rollback reset.
    virtual function bit validate_restored_queue_ownership(
        virtio_device_snapshot_t snap
    );
        iommu_mapping_t expected_mappings[$];
        int unsigned claim_indices[$];

        foreach (snap.queue_snapshots[q]) begin
            iommu_mapping_t queue_expected_mappings[$];

            collect_restored_queue_mappings(snap.queue_snapshots[q],
                                            queue_expected_mappings);
            foreach (queue_expected_mappings[i])
                expected_mappings.push_back(queue_expected_mappings[i]);
        end
        return collect_migration_restore_claim_indices(expected_mappings,
                                                       claim_indices);
    endfunction

    // A queue takes ownership only after restore_state() has fully staged its
    // state. All expected records are preflighted before any temporary record
    // is removed, so later rollback has exactly one owner per mapping.
    virtual function bit claim_restored_queue_ownership(
        virtqueue_snapshot_t queue_snapshot
    );
        iommu_mapping_t expected_mappings[$];
        int unsigned claim_indices[$];

        collect_restored_queue_mappings(queue_snapshot, expected_mappings);
        if (!collect_migration_restore_claim_indices(expected_mappings,
                                                     claim_indices))
            return 0;
        // collect_restored_queue_mappings() groups indirect tables before
        // explicit dma_map_buf() records, whereas materialization preserves
        // source IOVA order. Remove the numeric positions from highest to
        // lowest so deleting one temporary record cannot shift another
        // claimed record before it is removed.
        if (claim_indices.size() > 1)
            claim_indices.sort();
        for (int i = claim_indices.size(); i > 0; i--)
            migration_restore_dma.delete(claim_indices[i - 1]);
        return 1;
    endfunction

    // Compatibility name for callers that restore only indirect tables.
    virtual function bit validate_restored_indirect_ownership(
        virtio_device_snapshot_t snap
    );
        return validate_restored_queue_ownership(snap);
    endfunction

    virtual function bit claim_restored_indirect_ownership(
        virtqueue_snapshot_t queue_snapshot
    );
        return claim_restored_queue_ownership(queue_snapshot);
    endfunction

    // ========================================================================
    // Device Lifecycle
    // ========================================================================

    // ------------------------------------------------------------------------
    // device_reset -- Write status=0 and clean up all queue/DMA state
    // ------------------------------------------------------------------------
    virtual task device_reset_verified(ref bit reset_complete);
        int unsigned tx_qids[$];
        int unsigned rx_qids[$];

        `uvm_info("ATOMIC_OPS", "device_reset: starting", UVM_MEDIUM)

        reset_complete = 0;
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            ((mem == null) && has_pending_normal_dma())) begin
            `uvm_error("ATOMIC_OPS", "device_reset: incomplete PF lifecycle context")
            return;
        end
        transport.reset_device_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("ATOMIC_OPS", "device_reset: transport reset did not complete; retaining PF DMA")
            return;
        end

        // Detach all queues if any exist
        if (vq_mgr.get_queue_count() > 0) begin
            vq_mgr.detach_all_queues();
        end

        // Clear all tracked IOMMU mappings for rings
        foreach (ring_iovas[qid]) begin
            foreach (ring_iovas[qid][i]) begin
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, ring_iovas[qid][i]);
            end
        end
        ring_iovas.delete();
        foreach (tx_dma_map[qid]) begin
            tx_qids.push_back(qid);
        end
        foreach (tx_qids[i]) begin
            retire_normal_dma_records(tx_dma_map[tx_qids[i]]);
            tx_dma_map.delete(tx_qids[i]);
        end
        foreach (rx_dma_map[qid]) begin
            rx_qids.push_back(qid);
        end
        foreach (rx_qids[i]) begin
            retire_normal_dma_records(rx_dma_map[rx_qids[i]]);
            rx_dma_map.delete(rx_qids[i]);
        end
        release_migration_restore_payloads();

        // detach_all_queues() releases descriptor ownership only.  After a
        // verified device reset, free every queue's rings and remove its
        // manager entry before the PF can be reinitialized.
        vq_mgr.destroy_all();

        negotiated_features = '0;

        `uvm_info("ATOMIC_OPS", "device_reset: complete", UVM_MEDIUM)
    endtask

    virtual task device_reset();
        bit reset_complete;

        device_reset_verified(reset_complete);
    endtask

    // ------------------------------------------------------------------------
    // set_acknowledge -- Set ACKNOWLEDGE bit in device status
    // ------------------------------------------------------------------------
    virtual task set_acknowledge();
        transport.write_device_status(DEV_STATUS_ACKNOWLEDGE);
        `uvm_info("ATOMIC_OPS", "set_acknowledge: done", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver -- OR current status with DRIVER bit and write back
    // ------------------------------------------------------------------------
    virtual task set_driver();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_DRIVER;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_features_ok -- Set FEATURES_OK and verify device accepted it
    // ------------------------------------------------------------------------
    virtual task set_features_ok(ref bit ok);
        bit [7:0] status;
        bit [7:0] readback;

        transport.read_device_status(status);
        status = status | DEV_STATUS_FEATURES_OK;
        transport.write_device_status(status);

        // Poll to confirm FEATURES_OK is still set
        transport.read_device_status(readback);
        ok = (readback & DEV_STATUS_FEATURES_OK) ? 1 : 0;

        if (!ok) begin
            `uvm_error("ATOMIC_OPS",
                "set_features_ok: device rejected features (FEATURES_OK not set)")
        end else begin
            `uvm_info("ATOMIC_OPS",
                $sformatf("set_features_ok: confirmed, status=0x%02h", readback), UVM_HIGH)
        end
    endtask

    // ------------------------------------------------------------------------
    // verify_features_ok -- Re-read status and check FEATURES_OK bit
    // ------------------------------------------------------------------------
    virtual task verify_features_ok(ref bit ok);
        bit [7:0] status;
        transport.read_device_status(status);
        ok = (status & DEV_STATUS_FEATURES_OK) ? 1 : 0;
        `uvm_info("ATOMIC_OPS",
            $sformatf("verify_features_ok: status=0x%02h ok=%0b", status, ok), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_driver_ok -- OR current status with DRIVER_OK bit
    // ------------------------------------------------------------------------
    virtual task set_driver_ok();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_DRIVER_OK;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_driver_ok: status=0x%02h", status), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // set_failed -- OR current status with FAILED bit
    // ------------------------------------------------------------------------
    virtual task set_failed();
        bit [7:0] status;
        transport.read_device_status(status);
        status = status | DEV_STATUS_FAILED;
        transport.write_device_status(status);
        `uvm_info("ATOMIC_OPS",
            $sformatf("set_failed: status=0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // Feature Negotiation
    // ========================================================================

    // ------------------------------------------------------------------------
    // read_device_features -- Read device-offered feature bits
    // ------------------------------------------------------------------------
    virtual task read_device_features(ref bit [63:0] features);
        transport.read_device_features(features);
    endtask

    // ------------------------------------------------------------------------
    // write_driver_features -- Write driver-selected feature bits
    // ------------------------------------------------------------------------
    virtual task write_driver_features(bit [63:0] features);
        transport.write_driver_features(features);
    endtask

    // ------------------------------------------------------------------------
    // negotiate_features -- AND device features with driver caps, write result
    // ------------------------------------------------------------------------
    virtual task negotiate_features(bit [63:0] driver_caps, ref bit [63:0] result);
        transport.negotiate_features(driver_caps, result);
        negotiated_features = result;
        `uvm_info("ATOMIC_OPS",
            $sformatf("negotiate_features: result=0x%016h", result), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Queue Management
    // ========================================================================

    // ------------------------------------------------------------------------
    // setup_queue -- Full queue setup: create, alloc rings, map IOMMU, enable
    // ------------------------------------------------------------------------
    virtual task setup_queue(
        int unsigned       queue_id,
        int unsigned       queue_size,
        virtqueue_type_e   vq_type,
        output bit          ok
    );
        virtqueue_base     vq;
        int unsigned       max_size;
        int unsigned       eff_size;
        int unsigned       desc_size;
        int unsigned       avail_size;
        int unsigned       used_size;
        bit [63:0]         desc_iova;
        bit [63:0]         avail_iova;
        bit [63:0]         used_iova;
        int unsigned       msix_vector;

        ok = 0;
        if ((transport == null) || (vq_mgr == null) || (iommu == null) ||
            (mem == null)) begin
            `uvm_error("ATOMIC_OPS", "setup_queue: incomplete queue context")
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d size=%0d type=%s",
                      queue_id, queue_size, vq_type.name()), UVM_MEDIUM)

        // 1. Select queue on transport
        transport.select_queue(queue_id);

        // 2. Read device-advertised max queue size
        transport.read_queue_num_max(max_size);

        // 3. Determine effective size
        if (queue_size == 0)
            eff_size = max_size;
        else if (queue_size > max_size) begin
            `uvm_warning("ATOMIC_OPS",
                $sformatf("setup_queue: requested size %0d exceeds max %0d, using max",
                          queue_size, max_size))
            eff_size = max_size;
        end else
            eff_size = queue_size;

        if (eff_size == 0) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: device reported zero-sized queue %0d", queue_id))
            return;
        end

        // 4. Create queue via manager
        vq = vq_mgr.create_queue(queue_id, eff_size, vq_type);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("setup_queue: failed to create queue %0d", queue_id))
            return;
        end

        // 5. Allocate ring memory
        vq.alloc_rings();

        // 6. Compute ring region sizes for IOMMU mapping
        case (vq_type)
            VQ_SPLIT: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
            VQ_PACKED: begin
                desc_size  = 16 * eff_size;
                // Packed rings place two independent 4-byte event
                // suppression structures after the descriptor table.  Map
                // each structure at its own programmed GPA; mapping 8 bytes
                // from device_event_addr would run past the contiguous ring.
                avail_size = 4;
                used_size  = 4;
            end
            default: begin
                desc_size  = 16 * eff_size;
                avail_size = 6 + 2 * eff_size;
                used_size  = 6 + 8 * eff_size;
            end
        endcase

        // 7. Map ring addresses through IOMMU
        desc_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.desc_table_addr, desc_size, DMA_BIDIRECTIONAL);
        avail_iova = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.driver_ring_addr, avail_size, DMA_BIDIRECTIONAL);
        used_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, vq.device_ring_addr, used_size, DMA_BIDIRECTIONAL);
        if ((desc_iova == '1) || (desc_iova == 0) ||
            (avail_iova == '1) || (avail_iova == 0) ||
            (used_iova == '1) || (used_iova == 0)) begin
            if ((desc_iova != '1) && (desc_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, desc_iova);
            if ((avail_iova != '1) && (avail_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, avail_iova);
            if ((used_iova != '1) && (used_iova != 0))
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, used_iova);
            vq_mgr.destroy_queue(queue_id);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "setup_queue: failed to map queue_id=%0d rings", queue_id))
            return;
        end

        // Track ring IOVAs for cleanup
        ring_iovas[queue_id] = '{desc_iova, avail_iova, used_iova};

        // 8. Determine MSI-X vector for this queue
        if (transport.notify_mgr.queue_vectors.size() > queue_id)
            msix_vector = transport.notify_mgr.queue_vectors[queue_id];
        else
            msix_vector = 0;

        // 9. Setup queue on transport (writes addresses, size, enables)
        transport.setup_single_queue(queue_id, eff_size,
                                     desc_iova, avail_iova, used_iova,
                                     msix_vector);

        // 10. Mark queue as enabled
        vq.state = VQ_ENABLED;
        vq.queue_enable = 1;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_queue: queue_id=%0d complete, desc_iova=0x%016h avail_iova=0x%016h used_iova=0x%016h",
                      queue_id, desc_iova, avail_iova, used_iova), UVM_MEDIUM)
        ok = 1;
    endtask

    // ------------------------------------------------------------------------
    // teardown_queue -- Disable, detach, unmap, and destroy a queue
    // ------------------------------------------------------------------------
    virtual task teardown_queue(int unsigned queue_id);
        virtqueue_base vq;
        uvm_object tokens[$];

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // 1. Disable queue on transport
        transport.select_queue(queue_id);
        transport.write_queue_enable(0);

        // 2. Detach all unused buffers
        vq = vq_mgr.get_queue(queue_id);
        if (vq != null)
            vq.detach_all_unused(tokens);

        // 3. Unmap ring IOVAs
        if (ring_iovas.exists(queue_id)) begin
            foreach (ring_iovas[queue_id][i]) begin
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, ring_iovas[queue_id][i]);
            end
            ring_iovas.delete(queue_id);
        end

        // 4. Retire every still-owned normal data-DMA pair before forgetting
        // the queue.  Completion paths pop the same records first, so this
        // only releases buffers that remain pending at teardown.
        if (tx_dma_map.exists(queue_id)) begin
            retire_normal_dma_records(tx_dma_map[queue_id]);
            tx_dma_map.delete(queue_id);
        end
        if (rx_dma_map.exists(queue_id)) begin
            retire_normal_dma_records(rx_dma_map[queue_id]);
            rx_dma_map.delete(queue_id);
        end

        // 5. Destroy queue
        vq_mgr.destroy_queue(queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("teardown_queue: queue_id=%0d complete, detached %0d tokens",
                      queue_id, tokens.size()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // reset_queue -- Per-queue reset using virtio 1.2 queue reset mechanism
    // ------------------------------------------------------------------------
    virtual task reset_queue(int unsigned queue_id);
        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Write Q_RESET and poll until complete
        transport.write_queue_reset(queue_id);

        `uvm_info("ATOMIC_OPS",
            $sformatf("reset_queue: queue_id=%0d reset complete", queue_id), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // setup_all_queues -- Create all queue pairs + control queue
    // ------------------------------------------------------------------------
    virtual task setup_all_queues(
        int unsigned     num_pairs,
        virtqueue_type_e vq_type,
        int unsigned     queue_size,
        output bit        ok
    );
        int unsigned ctrl_qid;
        int unsigned created_qids[$];
        bit queue_ok;

        ok = 0;

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: num_pairs=%0d type=%s size=%0d",
                      num_pairs, vq_type.name(), queue_size), UVM_MEDIUM)

        // Setup receive and transmit queue pairs
        for (int unsigned i = 0; i < num_pairs; i++) begin
            setup_queue(i * 2, queue_size, vq_type, queue_ok);  // receiveq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2);
            setup_queue(i * 2 + 1, queue_size, vq_type, queue_ok);  // transmitq_i
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
            created_qids.push_back(i * 2 + 1);
        end

        // Setup control queue if CTRL_VQ negotiated
        if (negotiated_features[VIRTIO_NET_F_CTRL_VQ]) begin
            ctrl_qid = num_pairs * 2;
            setup_queue(ctrl_qid, queue_size, vq_type, queue_ok);
            if (!queue_ok) begin
                foreach (created_qids[j])
                    teardown_queue(created_qids[j]);
                return;
            end
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_all_queues: complete, total queues=%0d",
                      vq_mgr.get_queue_count()), UVM_MEDIUM)
        ok = 1;
    endtask

    // ========================================================================
    // TX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // tx_submit -- Submit a packet for transmission
    //
    // Steps:
    //   1. Pack virtio_net_hdr to bytes
    //   2. Get raw packet data via do_pack
    //   3. Allocate host_mem for hdr + data buffers
    //   4. Write hdr and data to host_mem
    //   5. Map through IOMMU (DMA_TO_DEVICE)
    //   6. Build scatter-gather lists
    //   7. add_buf to virtqueue
    //   8. Kick if needed
    //   9. Return desc_id
    // ------------------------------------------------------------------------
    virtual task tx_submit(
        int unsigned     queue_id,
        virtio_net_hdr_t net_hdr,
        uvm_object       pkt,
        bit              use_indirect,
        ref int unsigned desc_id
    );
        virtqueue_base   vq;
        byte unsigned    hdr_bytes[$];
        byte unsigned    pkt_bytes[];
        int unsigned     hdr_size;
        int unsigned     hdr_dma_size;
        int unsigned     pkt_size;
        int unsigned     pkt_dma_size;
        bit [63:0]       hdr_gpa;
        bit [63:0]       pkt_gpa;
        bit [63:0]       hdr_iova;
        bit [63:0]       pkt_iova;
        virtio_sg_list   sgs[2];
        virtio_sg_entry  hdr_entry;
        virtio_sg_entry  pkt_entry;
        int unsigned     result;
        byte             hdr_data[];
        byte             pkt_data[];
        normal_dma_record_t dma_record;

        desc_id = '1;
        if (use_indirect &&
            !negotiated_features[VIRTIO_F_RING_INDIRECT_DESC]) begin
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: queue %0d requested indirect descriptors without negotiating VIRTIO_F_RING_INDIRECT_DESC",
                queue_id))
            return;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d", queue_id), UVM_HIGH)

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: queue %0d not found", queue_id))
            return;
        end

        // 1. Pack net_hdr to bytes
        virtio_net_hdr_util::pack_hdr(net_hdr, negotiated_features, hdr_bytes);
        hdr_size = hdr_bytes.size();
        // PCIe Memory Read completions are DWORD based.  Keep the descriptor
        // length byte-accurate, but give the model/RC responder a DWORD-padded
        // backing allocation so a final partial DWORD never crosses an exact
        // host_mem block boundary.
        hdr_dma_size = (hdr_size + 3) & ~3;

        // 2. Get raw packet data from pkt via do_pack
        begin
            uvm_packer packer;
            packer = new();
            pkt.do_pack(packer);
            packer.get_bytes(pkt_bytes);
        end
        pkt_size = pkt_bytes.size();

        // If packet has no data from do_pack, use minimum Ethernet frame size
        if (pkt_size == 0)
            pkt_size = 64;
        // Keep the backing allocation DWORD padded after the minimum-size
        // fallback as well; otherwise an empty packet would request a
        // zero-byte host_mem allocation even though the descriptor carries
        // the 64-byte minimum frame.
        pkt_dma_size = (pkt_size + 3) & ~3;

        // 3. Allocate host_mem for hdr + data buffers
        hdr_gpa = mem.alloc(hdr_dma_size, .align(1));
        if (hdr_gpa == '1) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
            return;
        end
        pkt_gpa = mem.alloc(pkt_dma_size, .align(1));
        if (pkt_gpa == '1) begin
            // No DMA mapping or descriptor owns the header yet, so rollback
            // the sole successful allocation exactly once.
            mem.free(hdr_gpa);
            `uvm_error("ATOMIC_OPS",
                $sformatf("tx_submit: host_mem alloc failed for queue %0d", queue_id))
            return;
        end

        // 4. Write hdr and data to host_mem
        hdr_data = new[hdr_size];
        foreach (hdr_bytes[i]) hdr_data[i] = hdr_bytes[i];
        mem.write_mem(hdr_gpa, hdr_data);

        if (pkt_bytes.size() > 0) begin
            pkt_data = new[pkt_size];
            foreach (pkt_bytes[i]) pkt_data[i] = pkt_bytes[i];
            mem.write_mem(pkt_gpa, pkt_data);
        end

        // 5. Map through IOMMU (DMA_TO_DEVICE -- device reads these buffers)
        hdr_iova = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, hdr_gpa, hdr_dma_size, DMA_TO_DEVICE);
        if ((hdr_iova == '1) || (hdr_iova == 0)) begin
            mem.free(hdr_gpa);
            mem.free(pkt_gpa);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map header for queue %0d", queue_id))
            return;
        end
        pkt_iova = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, pkt_gpa, pkt_dma_size, DMA_TO_DEVICE);
        if ((pkt_iova == '1) || (pkt_iova == 0)) begin
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                 hdr_iova);
            mem.free(hdr_gpa);
            mem.free(pkt_gpa);
            `uvm_error("ATOMIC_OPS", $sformatf(
                "tx_submit: failed to map payload for queue %0d", queue_id))
            return;
        end

        // Track the complete DMA ownership pairs for completion/reset.
        if (!tx_dma_map.exists(queue_id))
            tx_dma_map[queue_id] = {};
        dma_record.host_id = get_iommu_host_id(transport);
        dma_record.bdf = transport.bdf;
        dma_record.gpa = hdr_gpa;
        dma_record.iova = hdr_iova;
        tx_dma_map[queue_id].push_back(dma_record);
        dma_record.host_id = get_iommu_host_id(transport);
        dma_record.bdf = transport.bdf;
        dma_record.gpa = pkt_gpa;
        dma_record.iova = pkt_iova;
        tx_dma_map[queue_id].push_back(dma_record);

        // 6. Build scatter-gather lists: [hdr_sg(out)] [data_sg(out)]
        hdr_entry.addr = hdr_iova;
        hdr_entry.len  = hdr_size;
        sgs[0].entries.push_back(hdr_entry);

        pkt_entry.addr = pkt_iova;
        pkt_entry.len  = pkt_size;
        sgs[1].entries.push_back(pkt_entry);

        // 7. Add buffers to virtqueue (n_out=2, n_in=0)
        result = vq.add_buf(sgs, 2, 0, pkt, use_indirect);
        desc_id = result;

        // The data buffers belong to this operation, not to add_buf().  A
        // rejected chain must not remain in the completion map or reach the
        // notification path.
        if (result == '1) begin
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                 hdr_iova);
            iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                                 pkt_iova);
            mem.free(hdr_gpa);
            mem.free(pkt_gpa);
            tx_dma_map[queue_id].pop_back();
            tx_dma_map[queue_id].pop_back();
            if (tx_dma_map[queue_id].size() == 0)
                tx_dma_map.delete(queue_id);
            return;
        end

        // 8. Kick if device needs notification
        if (vq.needs_notification()) begin
            // The production atomic path owns the PCIe notify, so it does
            // not call virtqueue::kick().  Keep the queue fault boundary
            // around the real transport write; otherwise configured
            // descriptor corruption is consumed only by legacy callers that
            // invoke kick() directly and never reaches normal TX flows.
            void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(queue_id, vq.total_add_buf_ops, 0);
            void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("tx_submit: queue_id=%0d desc_id=%0d hdr_iova=0x%016h pkt_iova=0x%016h",
                      queue_id, desc_id, hdr_iova, pkt_iova), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // tx_complete -- Poll used ring for completed TX buffers
    // ------------------------------------------------------------------------
    virtual task tx_complete(
        int unsigned     queue_id,
        ref uvm_object   completed_pkts[$],
        int unsigned     max_budget
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        while (count < max_budget) begin
            if (vq.poll_used(token, len)) begin
                completed_pkts.push_back(token);
                count++;
            end else begin
                break;
            end
        end

        // Clean up IOMMU mappings for completed TX buffers
        // (Each TX uses 2 IOVAs: hdr + data)
        if (tx_dma_map.exists(queue_id)) begin
            int unsigned iovas_to_free = count * 2;
            for (int unsigned i = 0; i < iovas_to_free && tx_dma_map[queue_id].size() > 0; i++) begin
                normal_dma_record_t record = tx_dma_map[queue_id].pop_front();
                retire_normal_dma_record(record);
            end
            if (tx_dma_map[queue_id].size() == 0)
                tx_dma_map.delete(queue_id);
        end

        if (count > 0)
            `uvm_info("ATOMIC_OPS",
                $sformatf("tx_complete: queue_id=%0d completed=%0d", queue_id, count), UVM_HIGH)
    endtask

    // ========================================================================
    // RX Data Path
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill -- Pre-fill receive queue with empty buffers
    // ------------------------------------------------------------------------
    virtual task rx_refill(
        int unsigned     queue_id,
        int unsigned     num_bufs
    );
        virtqueue_base   vq;
        int unsigned     buf_size;
        int unsigned     buf_dma_size;
        int unsigned     hdr_size;
        int unsigned     filled = 0;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        // Determine buffer size based on header size + typical MTU
        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        // Use reasonable default: header + 1514 (standard Ethernet MTU)
        buf_size = hdr_size + 1514;
        buf_dma_size = (buf_size + 3) & ~3;

        while (filled < num_bufs && vq.get_free_count() > 0) begin
            bit [63:0]       buf_gpa;
            bit [63:0]       buf_iova;
            virtio_sg_list   sgs[1];
            virtio_sg_entry  buf_entry;
            int unsigned     result;
            normal_dma_record_t dma_record;

            // Allocate RX buffer from host memory
            buf_gpa = mem.alloc(buf_dma_size, .align(1));
            if (buf_gpa == '1) begin
                `uvm_warning("ATOMIC_OPS",
                    $sformatf("rx_refill: host_mem alloc failed at buffer %0d", filled))
                break;
            end

            // Zero-fill the buffer
            mem.mem_set(buf_gpa, 0, buf_dma_size);

            // Map through IOMMU (DMA_FROM_DEVICE -- device writes to this buffer)
            buf_iova = iommu.map_for_host(get_iommu_host_id(transport),
                transport.bdf, buf_gpa, buf_dma_size, DMA_FROM_DEVICE);
            if ((buf_iova == '1) || (buf_iova == 0)) begin
                mem.free(buf_gpa);
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "rx_refill: failed to map buffer %0d for queue %0d",
                    filled, queue_id))
                break;
            end

            // Track the complete DMA ownership pair for completion/reset.
            if (!rx_dma_map.exists(queue_id))
                rx_dma_map[queue_id] = {};
            dma_record.host_id = get_iommu_host_id(transport);
            dma_record.bdf = transport.bdf;
            dma_record.gpa = buf_gpa;
            dma_record.iova = buf_iova;
            rx_dma_map[queue_id].push_back(dma_record);

            // Build sg: single device-writable buffer (n_out=0, n_in=1)
            buf_entry.addr = buf_iova;
            buf_entry.len  = buf_size;
            sgs[0].entries.push_back(buf_entry);

            result = vq.add_buf(sgs, 0, 1, null, 0);
            if (result == '1) begin
                iommu.unmap_for_host(get_iommu_host_id(transport),
                                     transport.bdf, buf_iova);
                mem.free(buf_gpa);
                rx_dma_map[queue_id].pop_back();
                if (rx_dma_map[queue_id].size() == 0)
                    rx_dma_map.delete(queue_id);
                break;
            end
            filled++;
        end

        // Kick if device needs notification
        if (filled > 0 && vq.needs_notification()) begin
            // Mirror tx_submit(): rx_refill also bypasses virtqueue::kick()
            // and emits the notify through the PCI transport directly.
            void'(vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(queue_id, vq.total_add_buf_ops, 0);
            void'(vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("rx_refill: queue_id=%0d filled=%0d/%0d", queue_id, filled, num_bufs),
            UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // rx_receive -- Poll used ring for received packets
    // ------------------------------------------------------------------------
    virtual task rx_receive(
        int unsigned     queue_id,
        ref uvm_object   received_pkts[$],
        int unsigned     max_budget
    );
        virtqueue_base   vq;
        uvm_object       token;
        int unsigned     len;
        int unsigned     count = 0;
        int unsigned     hdr_size;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) return;

        hdr_size = virtio_net_hdr_util::get_hdr_size(negotiated_features);

        while (count < max_budget) begin
            if (vq.poll_used(token, len)) begin
                normal_dma_record_t record;
                byte buf_data[];
                byte unsigned payload[$];
                byte unsigned first_bytes[$];
                virtio_net_hdr_t net_hdr;
                packet_item parsed_item;
                int unsigned num_buffers;

                if (!rx_dma_map.exists(queue_id) ||
                    (rx_dma_map[queue_id].size() == 0)) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "rx_receive: used entry has no DMA ownership queue=%0d",
                        queue_id))
                    break;
                end
                record = rx_dma_map[queue_id].pop_front();
                mem.read_mem(record.gpa, len, buf_data);
                foreach (buf_data[i]) first_bytes.push_back(buf_data[i]);
                if (buf_data.size() < hdr_size) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "rx_receive: buffer shorter than virtio header queue=%0d len=%0d hdr=%0d",
                        queue_id, buf_data.size(), hdr_size))
                    retire_normal_dma_record(record);
                    break;
                end
                virtio_net_hdr_util::unpack_hdr(first_bytes,
                                                negotiated_features, net_hdr);
                for (int unsigned i = hdr_size; i < buf_data.size(); i++)
                    payload.push_back(buf_data[i]);
                num_buffers = (net_hdr.num_buffers == 0) ? 1 :
                              net_hdr.num_buffers;
                retire_normal_dma_record(record);

                // Merge continuation buffers exactly as the production RX
                // engine does.  Every consumed descriptor retires its own
                // IOVA/GPA ownership only after its bytes are copied.
                for (int unsigned merge = 1; merge < num_buffers; merge++) begin
                    normal_dma_record_t merge_record;
                    byte merge_data[];
                    uvm_object merge_token;
                    int unsigned merge_len;
                    if (!vq.poll_used(merge_token, merge_len) ||
                        !rx_dma_map.exists(queue_id) ||
                        (rx_dma_map[queue_id].size() == 0)) begin
                        `uvm_error("ATOMIC_OPS", $sformatf(
                            "rx_receive: missing merged buffer queue=%0d expected=%0d got=%0d",
                            queue_id, num_buffers, merge))
                        break;
                    end
                    merge_record = rx_dma_map[queue_id].pop_front();
                    mem.read_mem(merge_record.gpa, merge_len, merge_data);
                    foreach (merge_data[i]) payload.push_back(merge_data[i]);
                    retire_normal_dma_record(merge_record);
                end

                if (virtio_net_packet_adapter::unpack(payload, parsed_item))
                    received_pkts.push_back(parsed_item);
                else if (token != null)
                    received_pkts.push_back(token);
                count++;
            end else begin
                break;
            end
        end

        if (rx_dma_map.exists(queue_id) &&
            (rx_dma_map[queue_id].size() == 0))
            rx_dma_map.delete(queue_id);

        if (count > 0)
            `uvm_info("ATOMIC_OPS",
                $sformatf("rx_receive: queue_id=%0d received=%0d", queue_id, count), UVM_HIGH)
    endtask

    // ========================================================================
    // Control VQ
    // ========================================================================

    // ------------------------------------------------------------------------
    // admin_vq_submit -- Submit one PF Admin-VQ request and consume response
    //
    // The PF manager owns feature/lease/target validation.  This helper owns
    // only the DMA, descriptor, notification, completion and cleanup
    // lifecycle of a validated, independently configured Admin VQ.
    // ------------------------------------------------------------------------
    virtual task admin_vq_submit(
        virtio_admin_vq_context admin_context,
        byte unsigned           cmd_data[],
        ref byte unsigned       result[],
        ref bit                 ok,
        input bit               lock_already_held = 0
    );
        bit [63:0]       request_gpa;
        bit [63:0]       response_gpa;
        bit [63:0]       request_iova;
        bit [63:0]       response_iova;
        bit              request_allocated;
        bit              response_allocated;
        bit              request_mapped;
        bit              response_mapped;
        bit              submitted;
        bit              completion_seen;
        bit              reset_required;
        bit              reset_complete;
        bit              release_safe;
        int unsigned     desc_id;
        int unsigned     used_len;
        int unsigned     max_polls;
        int unsigned     poll_count;
        int unsigned     poll_interval;
        int unsigned     effective_timeout;
        int unsigned     response_len;
        longint unsigned poll_quotient;
        uvm_object       completed_token;
        uvm_object       detached_tokens[$];
        virtio_sg_list   sgs[];
        virtio_sg_entry  entry;
        byte             write_buf[];
        byte             response_buf[];

        ok = 0;
        result = new[0];
        request_gpa = '0;
        response_gpa = '0;
        request_iova = '0;
        response_iova = '0;
        request_allocated = 0;
        response_allocated = 0;
        request_mapped = 0;
        response_mapped = 0;
        submitted = 0;
        completion_seen = 0;
        reset_required = 0;
        reset_complete = 0;
        release_safe = 1;

        if (admin_context == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: null Admin VQ context")
            return;
        end
        if (admin_context.submit_lock == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ context has no submission lock")
            return;
        end

        if (!lock_already_held)
            admin_context.submit_lock.get(1);
        begin : admin_vq_submit_locked
        do begin
        // The PF manager validates before calling this helper.  Repeat the
        // context checks while holding the shared-VQ lock: a prior command
        // may have performed recovery while this caller waited for ownership.
        if ((admin_context.vq == null) ||
            (admin_context.transport == null) || (admin_context.mem == null) ||
            (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
            (admin_context.response_capacity == 0) || !admin_context.configured ||
            !admin_context.special_vq_lease_valid || admin_context.special_vq_lease.frozen ||
            !admin_context.negotiated_features[VIRTIO_F_ADMIN_VQ]) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: incomplete Admin VQ context")
            break;
        end
        // This public helper may be called without virtio_pf_manager.  Once
        // it owns the submission lock, confirm that descriptors, DMA, and
        // notification still address one VQ/requester/memory/IOMMU binding.
        // Reject before allocation or any queue/device-visible side effect.
        if ((admin_context.queue_id != admin_context.vq.queue_id) ||
            (admin_context.vq.host_id !=
                admin_context.transport.iommu_host_id()) ||
            (admin_context.vq.bdf != admin_context.transport.bdf) ||
            (admin_context.vq.mem != admin_context.mem) ||
            (admin_context.vq.iommu != admin_context.iommu)) begin
            `uvm_error("ATOMIC_OPS",
                "admin_vq_submit: Admin VQ binding is inconsistent")
            break;
        end
        if (admin_context.full_reset_owner == null) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ has no PF lifecycle reset owner")
            break;
        end
        if (admin_context.recovery_required || admin_context.dma_quarantined) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: Admin VQ requires verified recovery")
            break;
        end
        if (cmd_data.size() == 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: empty Admin VQ request")
            break;
        end

        request_gpa = admin_context.mem.alloc(cmd_data.size(), .align(1));
        if (request_gpa == '1) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request allocation failed")
            break;
        end
        request_allocated = 1;

        response_gpa = admin_context.mem.alloc(admin_context.response_capacity, .align(1));
        if (response_gpa == '1) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: response allocation failed")
            break;
        end
        response_allocated = 1;

        write_buf = new[cmd_data.size()];
        foreach (cmd_data[index])
            write_buf[index] = cmd_data[index];
        admin_context.mem.write_mem(request_gpa, write_buf);
        admin_context.mem.mem_set(response_gpa, 8'hFF, admin_context.response_capacity);

        request_iova = admin_context.iommu.map_for_host(
            get_iommu_host_id(admin_context.transport),
            admin_context.transport.bdf, request_gpa, cmd_data.size(), DMA_TO_DEVICE
        );
        if (request_iova == '1 || request_iova == 0) begin
            `uvm_error("ATOMIC_OPS", "admin_vq_submit: request DMA map failed")
        end else begin
            request_mapped = 1;
            response_iova = admin_context.iommu.map_for_host(
                get_iommu_host_id(admin_context.transport),
                admin_context.transport.bdf, response_gpa, admin_context.response_capacity,
                DMA_FROM_DEVICE
            );
            if (response_iova == '1 || response_iova == 0) begin
                `uvm_error("ATOMIC_OPS", "admin_vq_submit: response DMA map failed")
            end else begin
                response_mapped = 1;
                sgs = new[2];
                entry.addr = request_iova;
                entry.len = cmd_data.size();
                entry.is_indirect = 0;
                sgs[0].entries.push_back(entry);
                entry.addr = response_iova;
                entry.len = admin_context.response_capacity;
                entry.is_indirect = 0;
                sgs[1].entries.push_back(entry);

                desc_id = admin_context.vq.add_buf(sgs, 1, 1, null, 0);
                if (desc_id == '1) begin
                    `uvm_error("ATOMIC_OPS", $sformatf(
                        "admin_vq_submit: queue %0d rejected Admin VQ descriptor chain",
                        admin_context.queue_id))
                end else begin
                    submitted = 1;
                    void'(admin_context.vq.process_error_injection(
                        VQ_FAULT_PRE_NOTIFY));
                    admin_context.transport.kick(admin_context.queue_id,
                                                 admin_context.vq.total_add_buf_ops, 0);
                    void'(admin_context.vq.process_error_injection(
                        VQ_FAULT_POST_NOTIFY));

                    // Both timeout and interval derive from the shared wait policy;
                    // there is no operation-specific arbitrary delay here.
                    effective_timeout = admin_context.wait_pol.effective_timeout(
                        admin_context.wait_pol.default_timeout_ns
                    );
                    poll_interval = admin_context.wait_pol.default_poll_interval_ns;
                    if (poll_interval == 0)
                        poll_interval = 1;
                    // Cap the widened quotient before adding one.  A
                    // saturated UINT_MAX timeout with interval one must not
                    // wrap its poll count to zero.
                    poll_quotient = effective_timeout / poll_interval;
                    if (poll_quotient >= admin_context.wait_pol.max_poll_attempts)
                        max_polls = admin_context.wait_pol.max_poll_attempts;
                    else
                        max_polls = poll_quotient + 1;
                    poll_count = 0;

                    while (poll_count < max_polls) begin
                        if (admin_context.vq.poll_used(completed_token, used_len)) begin
                            completion_seen = 1;
                            break;
                        end
                        poll_count++;
                        if (poll_count < max_polls)
                            #(poll_interval * 1ns);
                    end

                    if (!completion_seen) begin
                        `uvm_error("ATOMIC_OPS", $sformatf(
                            "admin_vq_submit: timeout waiting for Admin VQ %0d completion after %0dns",
                            admin_context.queue_id, effective_timeout))
                        reset_required = 1;
                    end else if ((used_len == 0) || (used_len > admin_context.response_capacity)) begin
                        `uvm_error("ATOMIC_OPS", $sformatf(
                            "admin_vq_submit: invalid Admin VQ response length %0d (capacity=%0d)",
                            used_len, admin_context.response_capacity))
                        reset_required = 1;
                    end else begin
                        response_len = used_len - 1;
                        admin_context.mem.read_mem(response_gpa, used_len, response_buf);
                        result = new[response_len];
                        foreach (result[index])
                            result[index] = response_buf[index + 1];
                        if (response_buf[0] != VIRTIO_NET_OK) begin
                            `uvm_error("ATOMIC_OPS", $sformatf(
                                "admin_vq_submit: device rejected Admin VQ request with status 0x%02h",
                                response_buf[0]))
                        end else begin
                            ok = 1;
                        end
                    end
                end
            end
        end
        end while (0);

        // A rejected add_buf() owns no descriptor.  For an accepted request
        // that timed out or returned malformed completion data, reset before
        // releasing its software ownership or DMA buffers: a late completion
        // must not DMA into memory we are about to free.  Q_RESET is valid
        // only when VIRTIO_F_RING_RESET was negotiated; Admin VQ alone does
        // not imply that feature, so otherwise reset the whole device.
        if (submitted && reset_required) begin
            release_safe = 0;
            if (admin_context.negotiated_features[VIRTIO_F_RING_RESET])
                admin_context.transport.write_queue_reset_verified(
                    admin_context.queue_id, reset_complete
                );
            else
                admin_context.full_reset_owner.reset_pf_lifecycle(reset_complete);
            admin_context.configured = 0;
            admin_context.recovery_required = 1;
            if (reset_complete) begin
                admin_context.vq.detach_all_unused(detached_tokens);
                admin_context.vq.reset_queue();
                admin_context.vq.alloc_rings();
                release_safe = 1;
            end else begin
                admin_context.dma_quarantined = 1;
                if (response_mapped)
                    admin_context.quarantined_iovas.push_back(response_iova);
                if (request_mapped)
                    admin_context.quarantined_iovas.push_back(request_iova);
                if (response_allocated)
                    admin_context.quarantined_gpas.push_back(response_gpa);
                if (request_allocated)
                    admin_context.quarantined_gpas.push_back(request_gpa);
                `uvm_error("ATOMIC_OPS", $sformatf(
                    "admin_vq_submit: Admin VQ %0d reset did not complete; DMA is quarantined",
                    admin_context.queue_id))
            end
        end

        if (release_safe && response_mapped)
            admin_context.iommu.unmap_for_host(
                get_iommu_host_id(admin_context.transport),
                admin_context.transport.bdf, response_iova);
        if (release_safe && request_mapped)
            admin_context.iommu.unmap_for_host(
                get_iommu_host_id(admin_context.transport),
                admin_context.transport.bdf, request_iova);
        if (release_safe && response_allocated)
            admin_context.mem.free(response_gpa);
        if (release_safe && request_allocated)
            admin_context.mem.free(request_gpa);
        end : admin_vq_submit_locked
        if (!lock_already_held)
            admin_context.submit_lock.put(1);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_send -- Send a control command and wait for ACK
    //
    // Steps:
    //   1. Build ctrl header: {class[7:0], cmd[7:0]}
    //   2. Build data buffer
    //   3. Build ack buffer (1 byte, device-writable)
    //   4. sgs: [hdr_sg(out)] [data_sg(out)] [ack_sg(in)]
    //   5. add_buf to control queue
    //   6. Kick control queue
    //   7. Poll used ring until ack buffer filled
    //   8. Read ack status from host_mem
    // ------------------------------------------------------------------------
    virtual task ctrl_send(
        virtio_ctrl_class_e  ctrl_class,
        bit [7:0]            cmd,
        byte unsigned        data[],
        ref virtio_ctrl_ack_e ack
    );
        virtqueue_base   ctrl_vq;
        int unsigned     ctrl_qid;
        byte unsigned    hdr_buf[2];
        bit [63:0]       hdr_gpa, data_gpa, ack_gpa;
        bit [63:0]       hdr_iova, data_iova, ack_iova;
        virtio_sg_list   sgs[3];
        virtio_sg_entry  entry;
        int unsigned     result;
        uvm_object       token;
        int unsigned     used_len;
        byte             ack_readback[];
        byte             write_buf[];
        bit              got_used;
        int unsigned     data_alloc_size;

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h data_len=%0d",
                      ctrl_class.name(), cmd, data.size()), UVM_MEDIUM)

        // Find control queue (highest queue ID among managed queues)
        ctrl_qid = 0;
        begin
            int unsigned max_qid = 0;
            foreach (ring_iovas[qid]) begin
                if (qid > max_qid) max_qid = qid;
            end
            ctrl_qid = max_qid;
        end

        ctrl_vq = vq_mgr.get_queue(ctrl_qid);
        if (ctrl_vq == null) begin
            `uvm_error("ATOMIC_OPS",
                $sformatf("ctrl_send: control queue %0d not found", ctrl_qid))
            ack = VIRTIO_NET_CTRL_ACK_ERR;
            return;
        end

        // 1. Build ctrl header: {class[7:0], cmd[7:0]}
        hdr_buf[0] = ctrl_class;
        hdr_buf[1] = cmd;

        // 2. Allocate host_mem for hdr, data, and ack
        hdr_gpa = mem.alloc(2, .align(1));
        ack_gpa = mem.alloc(1, .align(1));

        write_buf = new[2];
        write_buf[0] = hdr_buf[0];
        write_buf[1] = hdr_buf[1];
        mem.write_mem(hdr_gpa, write_buf);

        data_alloc_size = (data.size() > 0) ? data.size() : 1;
        data_gpa = mem.alloc(data_alloc_size, .align(1));

        if (data.size() > 0) begin
            write_buf = new[data.size()];
            foreach (data[i]) write_buf[i] = data[i];
            mem.write_mem(data_gpa, write_buf);
        end

        // Initialize ack to 0xFF (invalid)
        write_buf = new[1];
        write_buf[0] = 8'hFF;
        mem.write_mem(ack_gpa, write_buf);

        // 3. Map through IOMMU
        hdr_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, hdr_gpa, 2, DMA_TO_DEVICE);
        data_iova = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, data_gpa, data_alloc_size, DMA_TO_DEVICE);
        ack_iova  = iommu.map_for_host(get_iommu_host_id(transport),
            transport.bdf, ack_gpa, 1, DMA_FROM_DEVICE);

        // 4. Build scatter-gather: [hdr(out)] [data(out)] [ack(in)]
        entry.addr = hdr_iova;
        entry.len  = 2;
        sgs[0].entries.push_back(entry);

        entry.addr = data_iova;
        entry.len  = data_alloc_size;
        sgs[1].entries.push_back(entry);

        entry.addr = ack_iova;
        entry.len  = 1;
        sgs[2].entries.push_back(entry);

        // 5. Add to control queue (n_out=2, n_in=1)
        result = ctrl_vq.add_buf(sgs, 2, 1, null, 0);

        // 6. Kick control queue
        if (ctrl_vq.needs_notification()) begin
            void'(ctrl_vq.process_error_injection(VQ_FAULT_PRE_NOTIFY));
            transport.kick(ctrl_qid, ctrl_vq.total_add_buf_ops, 0);
            void'(ctrl_vq.process_error_injection(VQ_FAULT_POST_NOTIFY));
        end

        // 7. Poll used ring until ack buffer is filled
        got_used = 0;
        begin
            int unsigned poll_count = 0;
            int unsigned max_polls;
            int unsigned interval = wait_pol.default_poll_interval_ns;

            max_polls = wait_pol.effective_timeout(wait_pol.default_timeout_ns) /
                        ((interval > 0) ? interval : 1) + 1;
            if (max_polls > wait_pol.max_poll_attempts)
                max_polls = wait_pol.max_poll_attempts;

            while (poll_count < max_polls) begin
                if (ctrl_vq.poll_used(token, used_len)) begin
                    got_used = 1;
                    break;
                end
                #(interval * 1ns);
                poll_count++;
            end
        end

        if (!got_used) begin
            `uvm_error("ATOMIC_OPS", "ctrl_send: timeout waiting for control VQ completion")
            ack = VIRTIO_NET_CTRL_ACK_ERR;
        end else begin
            // 8. Read ack status from host_mem
            mem.read_mem(ack_gpa, 1, ack_readback);
            if (ack_readback[0] == VIRTIO_NET_OK)
                ack = VIRTIO_NET_CTRL_ACK_OK;
            else
                ack = VIRTIO_NET_CTRL_ACK_ERR;
        end

        // Cleanup IOMMU mappings
        iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                             hdr_iova);
        iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                             data_iova);
        iommu.unmap_for_host(get_iommu_host_id(transport), transport.bdf,
                             ack_iova);

        // Free host memory
        mem.free(hdr_gpa);
        mem.free(data_gpa);
        mem.free(ack_gpa);

        `uvm_info("ATOMIC_OPS",
            $sformatf("ctrl_send: class=%s cmd=0x%02h ack=%s",
                      ctrl_class.name(), cmd, ack.name()), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Control VQ Convenience Wrappers
    // ========================================================================

    // ------------------------------------------------------------------------
    // ctrl_set_mac -- Set device MAC address via CTRL_MAC_ADDR_SET
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mac(bit [47:0] mac, ref bit success);
        byte unsigned data[6];
        virtio_ctrl_ack_e ack;

        data[0] = mac[47:40];
        data[1] = mac[39:32];
        data[2] = mac[31:24];
        data[3] = mac[23:16];
        data[4] = mac[15:8];
        data[5] = mac[7:0];

        ctrl_send(VIRTIO_NET_CTRL_CLS_MAC, VIRTIO_NET_CTRL_MAC_ADDR_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_promisc -- Enable/disable promiscuous mode
    // ------------------------------------------------------------------------
    virtual task ctrl_set_promisc(bit enable, ref bit success);
        byte unsigned data[1];
        virtio_ctrl_ack_e ack;

        data[0] = enable;
        ctrl_send(VIRTIO_NET_CTRL_CLS_RX, VIRTIO_NET_CTRL_RX_PROMISC, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_allmulti -- Enable/disable all-multicast mode
    // ------------------------------------------------------------------------
    virtual task ctrl_set_allmulti(bit enable, ref bit success);
        byte unsigned data[1];
        virtio_ctrl_ack_e ack;

        data[0] = enable;
        ctrl_send(VIRTIO_NET_CTRL_CLS_RX, VIRTIO_NET_CTRL_RX_ALLMULTI, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_mac_table -- Set unicast/multicast MAC filter tables
    // Format: {uni_count[4], uni_macs[6*n], multi_count[4], multi_macs[6*m]}
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mac_table(
        bit [47:0] unicast_macs[$],
        bit [47:0] multicast_macs[$],
        ref bit success
    );
        byte unsigned data[];
        virtio_ctrl_ack_e ack;
        int unsigned offset;
        int unsigned total_size;
        int unsigned uc_count;
        int unsigned mc_count;

        uc_count = unicast_macs.size();
        mc_count = multicast_macs.size();
        total_size = 4 + uc_count * 6 + 4 + mc_count * 6;
        data = new[total_size];

        // Unicast count (32-bit LE)
        offset = 0;
        data[offset]   = uc_count[7:0];
        data[offset+1] = uc_count[15:8];
        data[offset+2] = uc_count[23:16];
        data[offset+3] = uc_count[31:24];
        offset += 4;

        // Unicast MACs
        foreach (unicast_macs[i]) begin
            data[offset]   = unicast_macs[i][47:40];
            data[offset+1] = unicast_macs[i][39:32];
            data[offset+2] = unicast_macs[i][31:24];
            data[offset+3] = unicast_macs[i][23:16];
            data[offset+4] = unicast_macs[i][15:8];
            data[offset+5] = unicast_macs[i][7:0];
            offset += 6;
        end

        // Multicast count (32-bit LE)
        data[offset]   = mc_count[7:0];
        data[offset+1] = mc_count[15:8];
        data[offset+2] = mc_count[23:16];
        data[offset+3] = mc_count[31:24];
        offset += 4;

        // Multicast MACs
        foreach (multicast_macs[i]) begin
            data[offset]   = multicast_macs[i][47:40];
            data[offset+1] = multicast_macs[i][39:32];
            data[offset+2] = multicast_macs[i][31:24];
            data[offset+3] = multicast_macs[i][23:16];
            data[offset+4] = multicast_macs[i][15:8];
            data[offset+5] = multicast_macs[i][7:0];
            offset += 6;
        end

        ctrl_send(VIRTIO_NET_CTRL_CLS_MAC, VIRTIO_NET_CTRL_MAC_TABLE_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_vlan_filter -- Add or remove a VLAN filter entry
    // ------------------------------------------------------------------------
    virtual task ctrl_set_vlan_filter(bit [11:0] vlan_id, bit add, ref bit success);
        byte unsigned data[2];
        virtio_ctrl_ack_e ack;
        bit [7:0] cmd;

        data[0] = vlan_id[7:0];
        data[1] = {4'h0, vlan_id[11:8]};

        cmd = add ? VIRTIO_NET_CTRL_VLAN_ADD : VIRTIO_NET_CTRL_VLAN_DEL;
        ctrl_send(VIRTIO_NET_CTRL_CLS_VLAN, cmd, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_mq_pairs -- Set the number of active queue pairs (MQ)
    // ------------------------------------------------------------------------
    virtual task ctrl_set_mq_pairs(int unsigned num_pairs, ref bit success);
        byte unsigned data[2];
        virtio_ctrl_ack_e ack;

        data[0] = num_pairs[7:0];
        data[1] = num_pairs[15:8];

        ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_set_rss -- Configure RSS via control VQ
    // ------------------------------------------------------------------------
    virtual task ctrl_set_rss(virtio_rss_config_t rss_cfg, ref bit success);
        byte unsigned data[];
        virtio_ctrl_ack_e ack;
        int unsigned offset;
        int unsigned total_size;

        // Format: hash_types(4) + indirection_table_mask(2) + unclassified_queue(2) +
        //         indirection_table(2*N) + max_tx_vq(2) + hash_key_length(1) + hash_key(K)
        total_size = 4 + 2 + 2 + rss_cfg.indirection_table.size() * 2 + 2 + 1 +
                     rss_cfg.hash_key.size();
        data = new[total_size];
        offset = 0;

        // hash_types (32-bit LE)
        data[offset]   = rss_cfg.hash_types[7:0];
        data[offset+1] = rss_cfg.hash_types[15:8];
        data[offset+2] = rss_cfg.hash_types[23:16];
        data[offset+3] = rss_cfg.hash_types[31:24];
        offset += 4;

        // indirection_table_mask (16-bit LE)
        begin
            int unsigned tbl_mask = rss_cfg.indirection_table.size() - 1;
            data[offset]   = tbl_mask[7:0];
            data[offset+1] = tbl_mask[15:8];
        end
        offset += 2;

        // unclassified_queue (16-bit LE) -- default queue 0
        data[offset]   = 8'h00;
        data[offset+1] = 8'h00;
        offset += 2;

        // indirection_table entries (16-bit LE each)
        foreach (rss_cfg.indirection_table[i]) begin
            data[offset]   = rss_cfg.indirection_table[i][7:0];
            data[offset+1] = rss_cfg.indirection_table[i][15:8];
            offset += 2;
        end

        // max_tx_vq (16-bit LE) -- 0 = all
        data[offset]   = 8'h00;
        data[offset+1] = 8'h00;
        offset += 2;

        // hash_key_length (1 byte)
        data[offset] = rss_cfg.hash_key_size[7:0];
        offset += 1;

        // hash_key
        foreach (rss_cfg.hash_key[i]) begin
            data[offset] = rss_cfg.hash_key[i];
            offset++;
        end

        ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, 8'h01, data, ack);  // RSS cmd = 0x01
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ------------------------------------------------------------------------
    // ctrl_announce_ack -- Acknowledge a gratuitous ARP/ND announcement
    // ------------------------------------------------------------------------
    virtual task ctrl_announce_ack(ref bit success);
        byte unsigned data[];
        virtio_ctrl_ack_e ack;

        ctrl_send(VIRTIO_NET_CTRL_CLS_ANNOUNCE, VIRTIO_NET_CTRL_ANNOUNCE_ACK, data, ack);
        success = (ack == VIRTIO_NET_CTRL_ACK_OK);
    endtask

    // ========================================================================
    // Interrupt Handling
    // ========================================================================

    // ------------------------------------------------------------------------
    // handle_interrupt -- Dispatch an interrupt by MSI-X vector
    // ------------------------------------------------------------------------
    virtual task handle_interrupt(int unsigned vector);
        transport.notify_mgr.on_interrupt_received(vector);
    endtask

    // ------------------------------------------------------------------------
    // napi_poll -- NAPI-style polling loop for a queue
    //
    // Enters polling mode, drains up to budget completions, then re-enables
    // interrupts if budget was not exhausted.
    // ------------------------------------------------------------------------
    virtual task napi_poll(int unsigned queue_id, int unsigned budget, ref int unsigned work_done);
        virtqueue_base vq;
        uvm_object     token;
        int unsigned   len;

        vq = vq_mgr.get_queue(queue_id);
        if (vq == null) begin
            work_done = 0;
            return;
        end

        // Enter polling mode (disable interrupts for this queue)
        transport.notify_mgr.enter_polling_mode(queue_id);
        vq.disable_cb();

        work_done = 0;
        while (work_done < budget) begin
            if (vq.poll_used(token, len)) begin
                work_done++;
            end else begin
                break;
            end
        end

        // If budget not exhausted, exit polling mode and re-enable interrupts
        if (work_done < budget) begin
            vq.enable_cb();
            transport.notify_mgr.exit_polling_mode(queue_id);
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("napi_poll: queue_id=%0d work_done=%0d/%0d",
                      queue_id, work_done, budget), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // setup_msix -- Configure MSI-X vectors for all queues
    // ------------------------------------------------------------------------
    virtual task setup_msix(int unsigned num_queues);
        interrupt_mode_e actual_mode;

        if (transport.cap_mgr.has_msix()) begin
            transport.notify_mgr.setup_msix(
                transport.cap_mgr.get_msix_table_size(),
                transport.cap_mgr.msix_table_bir,
                transport.cap_mgr.msix_table_offset
            );
            transport.notify_mgr.allocate_irq_vectors(num_queues, actual_mode);

            // Bind config change vector
            transport.write_config_msix_vector(transport.notify_mgr.config_vector);

            // Bind per-queue vectors
            for (int unsigned q = 0; q < num_queues; q++) begin
                transport.write_queue_msix_vector(q, transport.notify_mgr.queue_vectors[q]);
            end

            // Unmask all vectors
            transport.notify_mgr.unmask_all();
        end else begin
            transport.notify_mgr.irq_mode = IRQ_INTX;
            transport.notify_mgr.intx_enabled = 1;
        end

        `uvm_info("ATOMIC_OPS",
            $sformatf("setup_msix: num_queues=%0d mode=%s",
                      num_queues, transport.notify_mgr.irq_mode.name()), UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // teardown_msix -- Mask and release all MSI-X vectors
    // ------------------------------------------------------------------------
    virtual task teardown_msix();
        transport.notify_mgr.mask_all();
        `uvm_info("ATOMIC_OPS", "teardown_msix: all vectors masked", UVM_MEDIUM)
    endtask

endclass : virtio_atomic_ops

`endif // VIRTIO_ATOMIC_OPS_SV
