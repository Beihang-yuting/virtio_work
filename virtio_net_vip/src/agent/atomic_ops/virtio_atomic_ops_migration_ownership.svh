    // 本文件是 virtio_atomic_ops 类体的一部分（迁移恢复与 DMA 所有权），只由
    // agent/virtio_atomic_ops.sv 在类定义内部 `include；不得单独编译或在类外包含。

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

    // 释放迁移恢复暂存列表中全部尚未被认领的 DMA 分配（unmap+free），
    // 用于恢复失败/中止路径的兜底清理。
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

    // 从迁移恢复暂存列表认领一条与期望映射（host/bdf/iova）匹配的记录：
    // 命中后还要求 IOMMU 当前活映射的 size/dir 与期望一致，否则判失败；
    // 认领成功即从暂存列表移除并经 destination 交还所有权。
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
