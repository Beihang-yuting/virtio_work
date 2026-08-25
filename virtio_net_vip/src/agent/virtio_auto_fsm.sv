`ifndef VIRTIO_AUTO_FSM_SV
`define VIRTIO_AUTO_FSM_SV

// ============================================================================
// virtio_auto_fsm
//
// Complete lifecycle state machine for the virtio-net driver VIP.
// Orchestrates device initialization, data plane operation, reconfiguration,
// live migration, and error recovery using virtio_atomic_ops.
//
// Critical implementation rules enforced:
//   1. Named fork blocks only: fork : block_name ... join*; disable block_name;
//   2. No bare #delay -- all waits use wait_pol or named fork with #(ns * 1ns)
//   3. All background tasks check their run epoch after every wait
//   4. start_dataplane uses fork : dataplane_tasks ... join_none
//   5. stop_dataplane waits for an explicit completion acknowledgement from
//      every background task before any caller may reset queue/DMA ownership
//
// Depends on:
//   - virtio_atomic_ops (low-level driver operations)
//   - virtio_net_types.sv (fsm_state_e, virtio_driver_config_t, etc.)
//   - virtio_wait_policy (timeout/polling)
// ============================================================================

class virtio_auto_fsm extends uvm_report_object;
    `uvm_object_utils(virtio_auto_fsm)

    localparam int unsigned MIGRATION_PAGE_SIZE = 4096;
    typedef virtio_dirty_page_snapshot_t migration_record_group_t[$];

    // ===== State =====
    fsm_state_e   state = FSM_IDLE;

    // ===== References =====
    virtio_atomic_ops       ops;
    virtio_driver_config_t  drv_cfg;

    // ===== Background task control =====
    protected bit   dataplane_running = 0;
    protected event stop_event;
    protected int unsigned dataplane_epoch = 0;
    protected bit          dataplane_stop_requested = 0;
    protected int unsigned dataplane_workers_expected = 0;
    protected int unsigned dataplane_workers_completed = 0;
    protected int unsigned dataplane_workers_stopped_epoch = 0;
    protected int unsigned recovery_requested_epoch = 0;

    // ===== Events for inter-task signaling =====
    uvm_event  used_ring_updated_event;   // fired when used ring has new entries
    uvm_event  packet_completed_event;    // fired on each TX/RX completion
    uvm_event  config_change_event;       // fired on device config change
    uvm_event  interrupt_event;           // fired on interrupt received

    // ===== Internal state =====
    protected int unsigned  num_total_queues;
    protected int unsigned  active_num_pairs;
    local int unsigned      max_vio_net_qpairs_per_device;
    local bit               mq_pair_limit_bound;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_auto_fsm");
        super.new(name);
        used_ring_updated_event = new("used_ring_updated_event");
        packet_completed_event  = new("packet_completed_event");
        config_change_event     = new("config_change_event");
        interrupt_event         = new("interrupt_event");
        num_total_queues        = 0;
        active_num_pairs        = 1;
        max_vio_net_qpairs_per_device = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        mq_pair_limit_bound = 0;
    endfunction

    // Snapshot the function's effective MQ limit.  Zero is the compatibility
    // encoding used by standalone/legacy driver configs created before this
    // field existed.  Repeated binds are idempotent, but a different value is
    // rejected so a live FSM cannot diverge from its configured queue state.
    function bit bind_mq_pair_limit(
        input int unsigned configured_limit,
        output string why
    );
        int unsigned effective_limit;

        if ($isunknown(configured_limit) || (configured_limit == 0))
            effective_limit = DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE;
        else
            effective_limit = configured_limit;
        if (effective_limit > DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE) begin
            why = $sformatf(
                "FSM MQ pair limit %0d exceeds model ceiling %0d",
                effective_limit, DPU_VIO_NET_MAX_QPAIRS_PER_DEVICE);
            return 0;
        end
        if (!mq_pair_limit_bound) begin
            max_vio_net_qpairs_per_device = effective_limit;
            mq_pair_limit_bound = 1;
            why = "";
            return 1;
        end
        if (effective_limit == max_vio_net_qpairs_per_device) begin
            why = "";
            return 1;
        end
        why = $sformatf(
            "FSM MQ pair limit is already bound to %0d; cannot rebind to %0d",
            max_vio_net_qpairs_per_device, effective_limit);
        return 0;
    endfunction

    function int unsigned max_supported_mq_pairs();
        return max_vio_net_qpairs_per_device;
    endfunction

    // The checksum is calculated over one migration-owned mapping span.  It
    // is used only for migration integrity validation, not as a cryptographic
    // primitive.
    protected function bit [63:0] migration_page_checksum(byte page_data[]);
        bit [63:0] checksum;

        checksum = 64'hcbf2_9ce4_8422_2325;
        foreach (page_data[i]) begin
            checksum = (checksum ^ {56'h0, page_data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    protected function bit [63:0] migration_checksum_word(
        bit [63:0] checksum, bit [63:0] value
    );
        for (int unsigned byte_index = 0; byte_index < 8; byte_index++) begin
            checksum = (checksum ^ {56'h0, value[byte_index * 8 +: 8]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    protected function bit [63:0] migration_checksum_bytes(
        bit [63:0] checksum, byte data[]
    );
        foreach (data[i]) begin
            checksum = (checksum ^ {56'h0, data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    protected function bit [63:0] migration_checksum_unsigned_bytes(
        bit [63:0] checksum, byte unsigned data[]
    );
        foreach (data[i]) begin
            checksum = (checksum ^ {56'h0, data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // Bind every field consumed by restore into one snapshot checksum.  Dirty
    // payloads also retain their per-record checksums so corruption can be
    // diagnosed precisely; this wider checksum catches metadata and queue
    // bytes before queue/device state is reconstructed.
    protected function bit [63:0] migration_snapshot_checksum(
        virtio_device_snapshot_t snap
    );
        bit [63:0] checksum;

        checksum = 64'hcbf2_9ce4_8422_2325;
        checksum = migration_checksum_word(checksum, 64'h5649_5254_4d49_4731);
        checksum = migration_checksum_word(checksum, snap.negotiated_features);
        checksum = migration_checksum_word(checksum, {56'h0, snap.device_status});
        checksum = migration_checksum_word(checksum, snap.net_config.mac);
        checksum = migration_checksum_word(checksum, {48'h0, snap.net_config.status});
        checksum = migration_checksum_word(checksum,
            {48'h0, snap.net_config.max_virtqueue_pairs});
        checksum = migration_checksum_word(checksum, {48'h0, snap.net_config.mtu});
        checksum = migration_checksum_word(checksum, {32'h0, snap.net_config.speed});
        checksum = migration_checksum_word(checksum, {56'h0, snap.net_config.duplex});
        checksum = migration_checksum_word(checksum,
            {56'h0, snap.net_config.rss_max_key_size});
        checksum = migration_checksum_word(checksum,
            {48'h0, snap.net_config.rss_max_indirection_table_length});
        checksum = migration_checksum_word(checksum,
            {32'h0, snap.net_config.supported_hash_types});
        checksum = migration_checksum_word(checksum, {32'h0, snap.num_queue_pairs});
        checksum = migration_checksum_word(checksum, {32'h0, snap.queue_count});
        checksum = migration_checksum_word(checksum, snap.dirty_generation);

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.queue_snapshots.size()});
        foreach (snap.queue_snapshots[q]) begin
            virtqueue_snapshot_t queue_snapshot;

            queue_snapshot = snap.queue_snapshots[q];
            checksum = migration_checksum_word(checksum, {32'h0, queue_snapshot.queue_id});
            checksum = migration_checksum_word(checksum, {32'h0, queue_snapshot.queue_size});
            checksum = migration_checksum_word(checksum, queue_snapshot.desc_addr);
            checksum = migration_checksum_word(checksum, queue_snapshot.driver_addr);
            checksum = migration_checksum_word(checksum, queue_snapshot.device_addr);
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.last_avail_idx});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.last_used_idx});
            checksum = migration_checksum_word(checksum,
                {63'h0, queue_snapshot.avail_wrap});
            checksum = migration_checksum_word(checksum,
                {63'h0, queue_snapshot.used_wrap});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.ring_data.size()});
            checksum = migration_checksum_unsigned_bytes(checksum,
                                                         queue_snapshot.ring_data);
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.pending_tokens.size()});
            foreach (queue_snapshot.pending_tokens[t]) begin
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_snapshot.pending_tokens[t].head_id});
                checksum = migration_checksum_word(checksum,
                    (queue_snapshot.pending_tokens[t].token == null) ? 0 : 1);
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.indirect_tables.size()});
            foreach (queue_snapshot.indirect_tables[t]) begin
                virtqueue_indirect_snapshot_t indirect_snapshot;

                indirect_snapshot = queue_snapshot.indirect_tables[t];
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.head_id});
                checksum = migration_checksum_word(checksum,
                    {48'h0, indirect_snapshot.mapping.bdf});
                checksum = migration_checksum_word(checksum,
                    indirect_snapshot.mapping.gpa);
                checksum = migration_checksum_word(checksum,
                    indirect_snapshot.mapping.iova);
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.mapping.size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, int'(indirect_snapshot.mapping.dir)});
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.byte_size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, indirect_snapshot.entry_count});
                checksum = migration_checksum_word(checksum,
                    (indirect_snapshot.token == null) ? 0 : 1);
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.queue_dma_mappings.size()});
            foreach (queue_snapshot.queue_dma_mappings[m]) begin
                iommu_mapping_t queue_dma_mapping;

                queue_dma_mapping = queue_snapshot.queue_dma_mappings[m];
                checksum = migration_checksum_word(checksum,
                    {48'h0, queue_dma_mapping.bdf});
                checksum = migration_checksum_word(checksum,
                    queue_dma_mapping.gpa);
                checksum = migration_checksum_word(checksum,
                    queue_dma_mapping.iova);
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_dma_mapping.size});
                checksum = migration_checksum_word(checksum,
                    {32'h0, int'(queue_dma_mapping.dir)});
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_dma_mapping.desc_id});
            end
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.split_free_head});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.split_num_free});
            checksum = migration_checksum_word(checksum,
                {32'h0, queue_snapshot.packed_free_ids.size()});
            foreach (queue_snapshot.packed_free_ids[i])
                checksum = migration_checksum_word(checksum,
                    {32'h0, queue_snapshot.packed_free_ids[i]});
        end

        checksum = migration_checksum_word(checksum, {32'h0, snap.dirty_pages.size()});
        foreach (snap.dirty_pages[p])
            checksum = migration_checksum_word(checksum, snap.dirty_pages[p]);

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.dirty_page_records.size()});
        foreach (snap.dirty_page_records[r]) begin
            virtio_dirty_page_snapshot_t record;

            record = snap.dirty_page_records[r];
            checksum = migration_checksum_word(checksum, record.page_id);
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.desc_id});
            checksum = migration_checksum_word(checksum, record.mapped_gpa);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapped_size});
            checksum = migration_checksum_word(checksum, record.checksum);
            checksum = migration_checksum_word(checksum,
                {32'h0, record.payload.size()});
            checksum = migration_checksum_bytes(checksum, record.payload);
        end

        checksum = migration_checksum_word(checksum,
            {32'h0, snap.mapping_records.size()});
        foreach (snap.mapping_records[r]) begin
            virtio_mapping_snapshot_t record;

            record = snap.mapping_records[r];
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.desc_id});
            checksum = migration_checksum_word(checksum, record.checksum);
            checksum = migration_checksum_word(checksum,
                {32'h0, record.payload.size()});
            checksum = migration_checksum_bytes(checksum, record.payload);
        end
        checksum = migration_checksum_word(checksum,
            {32'h0, snap.normal_dma_records.size()});
        foreach (snap.normal_dma_records[r]) begin
            virtio_normal_dma_snapshot_t record;

            record = snap.normal_dma_records[r];
            checksum = migration_checksum_word(checksum, {32'h0, record.queue_id});
            checksum = migration_checksum_word(checksum, {63'h0, record.is_tx});
            checksum = migration_checksum_word(checksum, {48'h0, record.mapping.bdf});
            checksum = migration_checksum_word(checksum, record.mapping.gpa);
            checksum = migration_checksum_word(checksum, record.mapping.iova);
            checksum = migration_checksum_word(checksum, {32'h0, record.mapping.size});
            checksum = migration_checksum_word(checksum,
                {32'h0, int'(record.mapping.dir)});
        end
        return checksum;
    endfunction

    // Return the portion of an IOMMU mapping that belongs to one 4 KiB dirty
    // page.  The host-memory allocation need only cover this span; the rest
    // of the page is not implicitly owned by the mapping being validated.
    protected function bit migration_mapping_page_span(
        bit [63:0] page_id,
        iommu_mapping_t mapping,
        ref bit [63:0] span_gpa,
        ref int unsigned span_size
    );
        bit [63:0] page_base;
        bit [63:0] page_end;
        bit [63:0] mapping_end;
        bit [63:0] span_end;

        page_base = page_id << 12;
        page_end = page_base + MIGRATION_PAGE_SIZE;
        mapping_end = mapping.gpa + mapping.size;
        span_gpa = (mapping.gpa > page_base) ? mapping.gpa : page_base;
        span_end = (mapping_end < page_end) ? mapping_end : page_end;
        span_size = 0;
        if (span_end <= span_gpa)
            return 0;
        span_size = span_end - span_gpa;
        return 1;
    endfunction

    // Source identity identifies one mapping at freeze.  It includes GPA so
    // separate source allocations cannot be silently coalesced.
    protected function bit same_migration_source_mapping(
        iommu_mapping_t left,
        iommu_mapping_t right
    );
        return (left.bdf  == right.bdf)  &&
               (left.gpa  == right.gpa)  &&
               (left.iova == right.iova) &&
               (left.size == right.size) &&
               (left.dir  == right.dir);
    endfunction

    // A restored mapping intentionally receives fresh host memory.  Layout
    // comparison therefore proves the stable DMA view without requiring its
    // new destination GPA to equal the source GPA.
    protected function bit same_restored_migration_layout(
        iommu_mapping_t left,
        iommu_mapping_t right
    );
        return (left.bdf  == right.bdf)  &&
               (left.iova == right.iova) &&
               (left.size == right.size) &&
               (left.dir  == right.dir);
    endfunction

    // Normal DMA completion is FIFO- and role-specific.  Validate every
    // ownership record against the saved queue-pair topology before reset
    // materializes any source mapping: RX queues are even, TX queues are odd,
    // and neither data path may target an optional control queue.
    protected function bit validate_normal_dma_restore_records(
        virtio_device_snapshot_t snap
    );
        int unsigned control_queue_count;
        int unsigned expected_queue_count;

        // Legacy synthetic snapshots may omit a full queue-pair topology when
        // they do not transfer any normal FIFO ownership.  Once normal DMA is
        // present, though, every FIFO record depends on this exact topology:
        // pairs provide consecutive RX/TX queues and CTRL_VQ, if negotiated,
        // contributes precisely one trailing control queue.
        if (snap.normal_dma_records.size() != 0) begin
            control_queue_count =
                snap.negotiated_features[VIRTIO_NET_F_CTRL_VQ] ? 1 : 0;
            if (snap.num_queue_pairs >
                ((32'hffff_ffff - control_queue_count) / 2)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA queue-pair count %0d overflows queue topology",
                    snap.num_queue_pairs))
                return 0;
            end
            expected_queue_count = (snap.num_queue_pairs << 1) +
                                   control_queue_count;
            if (snap.queue_count != expected_queue_count) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA topology mismatch pairs=%0d ctrl=%0d queues=%0d expected=%0d",
                    snap.num_queue_pairs, control_queue_count,
                    snap.queue_count, expected_queue_count))
                return 0;
            end
        end

        foreach (snap.normal_dma_records[i]) begin
            virtio_normal_dma_snapshot_t record;
            bit expected_is_tx;
            dma_dir_e expected_dir;
            bit found_mapping;

            record = snap.normal_dma_records[i];
            expected_is_tx = ((record.queue_id % 2) != 0);
            expected_dir = expected_is_tx ? DMA_TO_DEVICE : DMA_FROM_DEVICE;
            found_mapping = 0;

            // queue_id / 2 avoids overflowing a malformed num_queue_pairs * 2
            // expression and also excludes the control queue from normal DMA.
            if ((record.queue_id >= snap.queue_count) ||
                (record.queue_id >= snap.queue_snapshots.size()) ||
                ((record.queue_id / 2) >= snap.num_queue_pairs) ||
                (snap.queue_snapshots[record.queue_id].queue_id !=
                 record.queue_id) ||
                (record.is_tx != expected_is_tx) ||
                (record.mapping.bdf != ops.transport.bdf) ||
                (record.mapping.size == 0) ||
                (record.mapping.dir != expected_dir)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA record %0d has invalid queue/role topology qid=%0d is_tx=%0d",
                    i, record.queue_id, record.is_tx))
                return 0;
            end

            // Every normal ownership record must refer to exactly one complete
            // saved mapping, so later FIFO ownership transfer cannot consume a
            // missing or duplicated temporary migration allocation.
            foreach (snap.mapping_records[m]) begin
                if (same_migration_source_mapping(record.mapping,
                                                  snap.mapping_records[m].mapping)) begin
                    found_mapping = 1;
                    break;
                end
            end
            if (!found_mapping) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: normal DMA record %0d has no complete mapping IOVA=0x%016h",
                    i, record.mapping.iova))
                return 0;
            end
            foreach (snap.normal_dma_records[j]) begin
                if ((j < i) &&
                    same_migration_source_mapping(record.mapping,
                                                  snap.normal_dma_records[j].mapping)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: duplicate normal DMA ownership IOVA=0x%016h",
                        record.mapping.iova))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // Explicit dma_map_buf() ownership is neither a TX/RX completion FIFO nor
    // an indirect table.  It must nevertheless name one complete source
    // mapping, be unique across all queue ownership classes, and remain
    // queue-local before reset materializes a destination allocation.
    protected function bit validate_queue_dma_restore_records(
        virtio_device_snapshot_t snap
    );
        foreach (snap.queue_snapshots[q]) begin
            foreach (snap.queue_snapshots[q].queue_dma_mappings[i]) begin
                iommu_mapping_t mapping;
                bit found_mapping;

                mapping = snap.queue_snapshots[q].queue_dma_mappings[i];
                found_mapping = 0;
                if ((mapping.bdf != ops.transport.bdf) ||
                    (mapping.iova == 0) ||
                    (mapping.size == 0) ||
                    (mapping.desc_id != 0)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: invalid queue DMA IOVA=0x%016h queue_id=%0d",
                        mapping.iova, snap.queue_snapshots[q].queue_id))
                    return 0;
                end
                foreach (snap.mapping_records[m]) begin
                    if (same_migration_source_mapping(
                        mapping, snap.mapping_records[m].mapping)) begin
                        found_mapping = 1;
                        break;
                    end
                end
                if (!found_mapping) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: queue DMA IOVA=0x%016h has no complete mapping",
                        mapping.iova))
                    return 0;
                end
                foreach (snap.queue_snapshots[other_q]) begin
                    foreach (snap.queue_snapshots[other_q].queue_dma_mappings[j]) begin
                        iommu_mapping_t other_mapping;

                        if ((other_q > q) || ((other_q == q) && (j >= i)))
                            continue;
                        other_mapping =
                            snap.queue_snapshots[other_q].queue_dma_mappings[j];
                        if ((mapping.bdf == other_mapping.bdf) &&
                            (mapping.iova == other_mapping.iova)) begin
                            `uvm_error("AUTO_FSM", $sformatf(
                                "restore_from_migration: duplicate queue DMA IOVA=0x%016h",
                                mapping.iova))
                            return 0;
                        end
                    end
                end
                foreach (snap.normal_dma_records[n]) begin
                    if ((mapping.bdf == snap.normal_dma_records[n].mapping.bdf) &&
                        (mapping.iova == snap.normal_dma_records[n].mapping.iova)) begin
                        `uvm_error("AUTO_FSM", $sformatf(
                            "restore_from_migration: queue DMA overlaps normal ownership IOVA=0x%016h",
                            mapping.iova))
                        return 0;
                    end
                end
                foreach (snap.queue_snapshots[owner_q]) begin
                    foreach (snap.queue_snapshots[owner_q].indirect_tables[t]) begin
                        if ((mapping.bdf ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.bdf) &&
                            (mapping.iova ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.iova)) begin
                            `uvm_error("AUTO_FSM", $sformatf(
                                "restore_from_migration: queue DMA overlaps indirect ownership IOVA=0x%016h",
                                mapping.iova))
                            return 0;
                        end
                    end
                end
            end
        end
        return 1;
    endfunction

    // Any failure after the restore reset has acknowledged must immediately
    // return all queue rings, normal FIFO records, and still-temporary
    // migration mappings to verified-reset ownership.  Releasing only the
    // temporary migration list is insufficient once a normal DMA record or
    // indirect table has been claimed by a queue FIFO.
    protected task rollback_migration_restore();
        bit reset_complete;

        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: rollback verified device reset did not complete")
        end
    endtask

    // Queue rings have a destination ownership path distinct from ordinary
    // DMA: setup_all_queues() allocates, maps, and programs fresh rings
    // before restore_state() overlays their contents.  Use the saved source
    // addresses, not a destination queue instance, so this predicate applies
    // equally while filtering complete records and dirty fallback groups.
    protected function bit is_source_queue_ring_mapping(
        iommu_mapping_t mapping,
        virtio_device_snapshot_t snap
    );
        foreach (snap.queue_snapshots[q]) begin
            if (((snap.queue_snapshots[q].desc_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].desc_addr)) ||
                ((snap.queue_snapshots[q].driver_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].driver_addr)) ||
                ((snap.queue_snapshots[q].device_addr != 0) &&
                 (mapping.gpa == snap.queue_snapshots[q].device_addr)))
                return 1;
        end
        return 0;
    endfunction

    // Dirty records are a loss-safe fallback for mappings that completed and
    // retired during the drain.  They contain only the mapping/page spans
    // captured at completed-write boundaries, so all other bytes remain zero.
    protected function bit build_dirty_fallback_payload(
        migration_record_group_t source_records,
        ref iommu_mapping_t source_mapping,
        ref byte source_payload[]
    );
        source_mapping = '{default: 0};
        source_payload.delete();
        if (source_records.size() == 0) begin
            `uvm_error("AUTO_FSM",
                "build_dirty_fallback_payload: no dirty records supplied")
            return 0;
        end
        source_mapping = source_records[0].mapping;
        if (source_mapping.size == 0) begin
            `uvm_error("AUTO_FSM",
                "build_dirty_fallback_payload: zero-size source mapping")
            return 0;
        end
        source_payload = new[source_mapping.size];
        foreach (source_payload[i])
            source_payload[i] = 0;
        foreach (source_records[i]) begin
            bit [63:0] span_offset;

            if (!same_migration_source_mapping(source_records[i].mapping,
                                               source_mapping) ||
                (source_records[i].mapped_size == 0) ||
                (source_records[i].payload.size() !=
                 source_records[i].mapped_size) ||
                (source_records[i].mapped_gpa < source_mapping.gpa)) begin
                `uvm_error("AUTO_FSM",
                    "build_dirty_fallback_payload: inconsistent source record")
                return 0;
            end
            span_offset = source_records[i].mapped_gpa - source_mapping.gpa;
            if ((span_offset >= source_mapping.size) ||
                (source_records[i].mapped_size >
                 (source_mapping.size - span_offset))) begin
                `uvm_error("AUTO_FSM",
                    "build_dirty_fallback_payload: source span exceeds mapping")
                return 0;
            end
            for (int unsigned byte_index = 0;
                 byte_index < source_records[i].mapped_size; byte_index++) begin
                source_payload[span_offset + byte_index] =
                    source_records[i].payload[byte_index];
            end
        end
        return 1;
    endfunction

    // A worker belongs to precisely one start_dataplane() generation.  The
    // epoch check prevents a worker that missed a transient event from doing
    // work again after a later start flips dataplane_running back to one.
    protected function bit dataplane_worker_may_run(int unsigned worker_epoch);
        return dataplane_running && !dataplane_stop_requested &&
               (worker_epoch == dataplane_epoch);
    endfunction

    protected function void complete_dataplane_worker(int unsigned worker_epoch);
        if ((worker_epoch != dataplane_epoch) ||
            (dataplane_workers_expected == 0) ||
            (dataplane_workers_completed >= dataplane_workers_expected))
            return;
        dataplane_workers_completed++;
        if (dataplane_workers_completed == dataplane_workers_expected) begin
            dataplane_workers_stopped_epoch = worker_epoch;
        end
    endfunction

    protected task request_dataplane_stop(int unsigned worker_epoch);
        if (worker_epoch != dataplane_epoch)
            return;
        dataplane_running = 0;
        dataplane_stop_requested = 1;
        -> stop_event;
    endtask

    // ========================================================================
    // Complete Initialization
    //
    // FSM_IDLE -> FSM_DISCOVERING -> FSM_NEGOTIATING -> FSM_QUEUE_SETUP
    //          -> FSM_MSIX_SETUP -> FSM_READY
    // ========================================================================

    task full_init();
        if ($isunknown(drv_cfg.num_queue_pairs) ||
            (drv_cfg.num_queue_pairs == 0) ||
            (drv_cfg.num_queue_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                {"full_init: configured queue-pair count %0d is outside ",
                 "supported range 1..%0d"},
                drv_cfg.num_queue_pairs,
                max_vio_net_qpairs_per_device))
            return;
        end
        do_full_init();
    endtask

    protected virtual task do_full_init();
        bit [63:0] negotiated;
        bit        feat_ok;
        bit        setup_ok;
        int unsigned total_queues;

        `uvm_info("AUTO_FSM", "full_init: starting initialization sequence", UVM_LOW)

        // ---- Step 1: BAR discovery ----
        state = FSM_DISCOVERING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- discovering BARs", state.name()), UVM_MEDIUM)
        if (ops.transport.is_fabric_managed())
            ops.transport.discover_fabric_preconfigured_bars();
        else
            ops.transport.discover_and_init_bars();

        // ---- Step 2: Feature negotiation ----
        state = FSM_NEGOTIATING;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- negotiating features", state.name()), UVM_MEDIUM)

        ops.device_reset();

        ops.set_acknowledge();
        ops.set_driver();

        ops.negotiate_features(drv_cfg.driver_features, negotiated);

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "full_init: device rejected features")
            ops.set_failed();
            return;
        end

        // ---- Step 3: Queue setup ----
        state = FSM_QUEUE_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up queues", state.name()), UVM_MEDIUM)

        active_num_pairs = drv_cfg.num_queue_pairs;
        total_queues = 2 * active_num_pairs;
        if (negotiated[VIRTIO_NET_F_CTRL_VQ])
            total_queues = total_queues + 1;
        num_total_queues = total_queues;

        ops.setup_all_queues(active_num_pairs, drv_cfg.vq_type,
                             drv_cfg.queue_size, setup_ok);
        if (!setup_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "full_init: queue setup failed")
            ops.set_failed();
            return;
        end

        // ---- Step 4: MSI-X setup ----
        state = FSM_MSIX_SETUP;
        `uvm_info("AUTO_FSM",
            $sformatf("full_init: state=%s -- setting up MSI-X", state.name()), UVM_MEDIUM)

        ops.setup_msix(num_total_queues);

        // ---- Step 5: DRIVER_OK ----
        ops.set_driver_ok();
        state = FSM_READY;

        `uvm_info("AUTO_FSM",
            $sformatf("full_init: complete, state=%s, %0d queues, features=0x%016h",
                      state.name(), num_total_queues, negotiated), UVM_LOW)
    endtask

    // ========================================================================
    // Data Plane Control
    // ========================================================================

    // ------------------------------------------------------------------------
    // start_dataplane -- FSM_READY -> FSM_RUNNING
    //
    // Pre-fills RX buffers and forks all background tasks in a named block.
    // ------------------------------------------------------------------------
    virtual task start_dataplane();
        int unsigned run_epoch;

        if (state != FSM_READY) begin
            `uvm_error("AUTO_FSM",
                $sformatf("start_dataplane: invalid state %s (expected FSM_READY)", state.name()))
            return;
        end
        if ((dataplane_workers_expected != 0) &&
            (dataplane_workers_completed != dataplane_workers_expected)) begin
            `uvm_error("AUTO_FSM",
                "start_dataplane: previous dataplane workers have not stopped")
            return;
        end

        `uvm_info("AUTO_FSM", "start_dataplane: starting data plane", UVM_MEDIUM)

        dataplane_epoch++;
        dataplane_stop_requested = 0;
        dataplane_workers_expected = 5;
        dataplane_workers_completed = 0;
        dataplane_running = 1;
        run_epoch = dataplane_epoch;
        state = FSM_RUNNING;

        // Pre-fill RX buffers for all receive queues (even-numbered queues)
        for (int unsigned i = 0; i < active_num_pairs; i++) begin
            int unsigned rx_qid = i * 2;
            ops.rx_refill(rx_qid, drv_cfg.queue_size);
        end

        // Fork all background tasks in a named block
        fork : dataplane_tasks
            begin : rx_refill_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned rx_qid = i * 2;
                    fork
                        rx_refill_loop(rx_qid, run_epoch);
                    join_none
                end
                wait fork;
                complete_dataplane_worker(run_epoch);
            end

            begin : tx_complete_loops
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    automatic int unsigned tx_qid = i * 2 + 1;
                    fork
                        tx_complete_loop(tx_qid, run_epoch);
                    join_none
                end
                wait fork;
                complete_dataplane_worker(run_epoch);
            end

            begin
                interrupt_handler_loop(run_epoch);
                complete_dataplane_worker(run_epoch);
            end

            begin : adaptive_irq_check
                if (drv_cfg.irq_mode == IRQ_POLLING) begin
                    adaptive_irq_loop(run_epoch);
                end
                complete_dataplane_worker(run_epoch);
            end

            begin
                config_change_handler(run_epoch);
                complete_dataplane_worker(run_epoch);
            end
        join_none

        // DEVICE_NEEDS_RESET may be detected by config_change_handler(), one
        // of the workers above.  Keep recovery outside that worker set so it
        // can wait for the complete acknowledgement without self-deadlock.
        fork : dataplane_recovery_watch
            dataplane_recovery_supervisor(run_epoch);
        join_none

        `uvm_info("AUTO_FSM", "start_dataplane: background tasks forked", UVM_MEDIUM)
    endtask

    // ------------------------------------------------------------------------
    // stop_dataplane -- FSM_RUNNING -> FSM_READY
    //
    // Signals all background tasks to exit, then waits for their explicit
    // acknowledgement.  Returning before that acknowledgement would let a PF
    // reset detach queues while a worker still owns a VQ/DMA operation.
    // ------------------------------------------------------------------------
    virtual task stop_dataplane();
        if (state != FSM_RUNNING) begin
            `uvm_warning("AUTO_FSM",
                $sformatf("stop_dataplane: state is %s, not FSM_RUNNING", state.name()))
        end

        `uvm_info("AUTO_FSM", "stop_dataplane: stopping data plane", UVM_MEDIUM)

        if ((dataplane_workers_expected != 0) &&
            (dataplane_workers_completed != dataplane_workers_expected)) begin
            int unsigned stop_epoch = dataplane_epoch;
            request_dataplane_stop(stop_epoch);
            wait (dataplane_workers_stopped_epoch == stop_epoch);
        end else begin
            dataplane_running = 0;
            dataplane_stop_requested = 1;
        end

        state = FSM_READY;

        `uvm_info("AUTO_FSM", "stop_dataplane: data plane stopped", UVM_MEDIUM)
    endtask

    // ========================================================================
    // High-Level Data Operations
    // ========================================================================

    // ------------------------------------------------------------------------
    // send_packets -- Submit packets for transmission
    //
    // Builds a default virtio_net_hdr per packet and submits via tx_submit.
    // queue_id is treated as a pair index if < active_num_pairs.
    // ------------------------------------------------------------------------
    virtual task send_packets(uvm_object pkts[$], int unsigned queue_id = 0);
        int unsigned tx_qid;
        int unsigned desc_id;

        // Transmit queues are odd-numbered: pair_index*2+1
        if (queue_id < active_num_pairs)
            tx_qid = queue_id * 2 + 1;
        else
            tx_qid = queue_id;

        `uvm_info("AUTO_FSM",
            $sformatf("send_packets: count=%0d queue_id=%0d", pkts.size(), tx_qid), UVM_MEDIUM)

        foreach (pkts[i]) begin
            virtio_net_hdr_t hdr;

            // Build default virtio_net_hdr
            hdr.flags       = 8'h00;
            hdr.gso_type    = VIRTIO_NET_HDR_GSO_NONE;
            hdr.hdr_len     = 16'h0000;
            hdr.gso_size    = 16'h0000;
            hdr.csum_start  = 16'h0000;
            hdr.csum_offset = 16'h0000;
            hdr.num_buffers = 16'h0000;
            hdr.hash_value  = 32'h00000000;
            hdr.hash_report = 16'h0000;

            // If CSUM offload is negotiated, set NEEDS_CSUM flag
            if (ops.negotiated_features[VIRTIO_NET_F_CSUM]) begin
                hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
            end

            ops.tx_submit(tx_qid, hdr, pkts[i], 0, desc_id);
        end
    endtask

    // ------------------------------------------------------------------------
    // wait_packets -- Wait for packets to arrive on receive queues
    //
    // Uses mixed event + polling approach (no bare #delay).
    // Loop until count >= expected or timeout, using named fork blocks.
    // ------------------------------------------------------------------------
    virtual task wait_packets(
        int unsigned expected_count,
        ref uvm_object received[$],
        int unsigned timeout_ns
    );
        int unsigned   count = 0;
        realtime       start_time;
        int unsigned   interval;
        int unsigned   budget;
        int unsigned   eff_timeout;

        interval    = ops.wait_pol.default_poll_interval_ns;
        budget      = drv_cfg.napi_budget;
        if (budget == 0) budget = 64;
        eff_timeout = ops.wait_pol.effective_timeout(timeout_ns);
        start_time  = $realtime;

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: expecting %0d, timeout=%0dns", expected_count, eff_timeout),
            UVM_MEDIUM)

        while (count < expected_count) begin
            realtime elapsed_ns;
            elapsed_ns = ($realtime - start_time) / 1ns;

            if (elapsed_ns >= eff_timeout) begin
                `uvm_warning("AUTO_FSM",
                    $sformatf("wait_packets: timeout after %0dns, received %0d/%0d",
                              eff_timeout, count, expected_count))
                return;
            end

            if (!dataplane_running) begin
                `uvm_info("AUTO_FSM",
                    "wait_packets: dataplane stopped, exiting wait", UVM_MEDIUM)
                return;
            end

            // Wait for used ring event or poll interval (named fork)
            fork : pkt_wait_blk
                begin : pkt_wait_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : pkt_wait_timeout_arm
                    #(interval * 1ns);
                end
                begin : pkt_wait_stop_arm
                    @stop_event;
                end
            join_any
            disable pkt_wait_blk;

            if (!dataplane_running)
                return;

            // Poll all receive queues for new packets
            for (int unsigned i = 0; i < active_num_pairs; i++) begin
                int unsigned rx_qid = i * 2;
                uvm_object   rx_pkts[$];

                ops.rx_receive(rx_qid, rx_pkts, budget);

                foreach (rx_pkts[j]) begin
                    received.push_back(rx_pkts[j]);
                    count++;
                    packet_completed_event.trigger();
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("wait_packets: received %0d/%0d", count, expected_count), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Reconfiguration
    // ========================================================================

    // ------------------------------------------------------------------------
    // configure_mq -- Change the number of active queue pairs
    // ------------------------------------------------------------------------
    task configure_mq(int unsigned num_pairs);
        if ($isunknown(num_pairs) || (num_pairs == 0) ||
            (num_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                "configure_mq: requested %0d pairs is outside supported range 1..%0d",
                num_pairs, max_vio_net_qpairs_per_device))
            return;
        end
        do_configure_mq(num_pairs);
    endtask

    protected virtual task do_configure_mq(int unsigned num_pairs);
        bit success;
        bit setup_ok;

        `uvm_info("AUTO_FSM",
            $sformatf("configure_mq: changing from %0d to %0d pairs",
                      active_num_pairs, num_pairs), UVM_MEDIUM)

        ops.ctrl_set_mq_pairs(num_pairs, success);

        if (success) begin
            // Teardown queues that are no longer needed
            if (num_pairs < active_num_pairs) begin
                for (int unsigned i = num_pairs; i < active_num_pairs; i++) begin
                    ops.teardown_queue(i * 2);      // receiveq
                    ops.teardown_queue(i * 2 + 1);  // transmitq
                end
            end

            // Setup new queues if expanding
            if (num_pairs > active_num_pairs) begin
                for (int unsigned i = active_num_pairs; i < num_pairs; i++) begin
                    ops.setup_queue(i * 2, drv_cfg.queue_size, drv_cfg.vq_type,
                                    setup_ok);
                    if (!setup_ok) begin
                        state = FSM_ERROR;
                        `uvm_error("AUTO_FSM", $sformatf(
                            "configure_mq: failed to setup RX queue %0d", i * 2))
                        return;
                    end
                    ops.setup_queue(i * 2 + 1, drv_cfg.queue_size, drv_cfg.vq_type,
                                    setup_ok);
                    if (!setup_ok) begin
                        ops.teardown_queue(i * 2);
                        state = FSM_ERROR;
                        `uvm_error("AUTO_FSM", $sformatf(
                            "configure_mq: failed to setup TX queue %0d", i * 2 + 1))
                        return;
                    end
                end
            end

            active_num_pairs = num_pairs;
        end else begin
            `uvm_error("AUTO_FSM",
                $sformatf("configure_mq: device rejected MQ change to %0d pairs", num_pairs))
        end
    endtask

    // ------------------------------------------------------------------------
    // configure_rss -- Update RSS configuration via control VQ
    // ------------------------------------------------------------------------
    virtual task configure_rss(virtio_rss_config_t cfg);
        bit success;

        `uvm_info("AUTO_FSM", "configure_rss: updating RSS configuration", UVM_MEDIUM)
        ops.ctrl_set_rss(cfg, success);

        if (!success) begin
            `uvm_error("AUTO_FSM", "configure_rss: device rejected RSS configuration")
        end
    endtask

    // ========================================================================
    // Migration
    // ========================================================================

    // ------------------------------------------------------------------------
    // freeze_for_migration -- FSM_RUNNING -> FSM_SUSPENDING -> FSM_FROZEN
    //
    // Stops the data plane and snapshots all device state.
    // ------------------------------------------------------------------------
    virtual task freeze_for_migration(ref virtio_device_snapshot_t snap);
        `uvm_info("AUTO_FSM", "freeze_for_migration: starting freeze", UVM_LOW)

        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: missing IOMMU or host-memory context")
            return;
        end

        // 1. Enable a new generation before requesting dataplane quiesce.
        // Any in-flight device write observed while workers drain belongs to
        // this snapshot, and no older dirty bitmap can leak into it.
        snap.dirty_generation = ops.iommu.begin_dirty_generation();

        // 2. Stop data plane
        if (state == FSM_RUNNING) begin
            state = FSM_SUSPENDING;
            stop_dataplane();
            // Override state since stop_dataplane sets FSM_READY
            state = FSM_SUSPENDING;
        end

        // 3. Save negotiated features and device status
        snap.negotiated_features = ops.negotiated_features;
        begin
            bit [7:0] dev_status;
            ops.transport.read_device_status(dev_status);
            snap.device_status = dev_status;
        end

        // 4. Read device config
        ops.transport.read_net_config(snap.net_config);

        // 5. Save all queue states
        snap.num_queue_pairs = active_num_pairs;
        snap.queue_count = num_total_queues;
        snap.queue_snapshots = new[num_total_queues];

        for (int unsigned q = 0; q < num_total_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            if (vq != null) begin
                virtqueue_snapshot_t tmp_snap;
                vq.save_state(tmp_snap);
                snap.queue_snapshots[q] = tmp_snap;
            end
        end
        if (!ops.snapshot_normal_dma_ownership(snap.normal_dma_records)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: unable to capture normal DMA ownership")
            return;
        end

        // 6. Atomically capture this generation.  Each completed device write
        // already saved its exact post-write mapping span in the IOMMU before
        // normal completion could unmap/free its backing allocation.
        ops.iommu.capture_dirty_generation(snap.dirty_pages);
        snap.dirty_page_records.delete();
        foreach (snap.dirty_pages[i]) begin
            virtio_dirty_page_snapshot_t records[$];

            ops.iommu.get_dirty_page_records(snap.dirty_pages[i], records);
            if (records.size() == 0) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "freeze_for_migration: dirty page 0x%016h has no generation mapping",
                    snap.dirty_pages[i]))
                return;
            end
            foreach (records[m]) begin
                virtio_dirty_page_snapshot_t record;

                record = records[m];
                if (!migration_mapping_page_span(record.page_id, record.mapping,
                                                 record.mapped_gpa,
                                                 record.mapped_size)) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: dirty page 0x%016h has empty mapping span",
                        record.page_id))
                    return;
                end
                if (record.payload.size() != record.mapped_size) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: dirty page 0x%016h has invalid captured payload",
                        record.page_id))
                    return;
                end
                record.checksum = migration_page_checksum(record.payload);
                snap.dirty_page_records.push_back(record);
            end
        end

        // Dirty records protect completed device writes.  Capture the whole
        // payload of every mapping still live after quiesce as well, because
        // queue snapshots can retain clean DMA_TO_DEVICE or indirect IOVAs.
        if (!ops.iommu.snapshot_live_mappings(ops.mem, ops.transport.bdf,
                                              snap.mapping_records)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: unable to capture live mapping payloads")
            return;
        end
        begin
            virtio_mapping_snapshot_t dma_records[$];

            foreach (snap.mapping_records[i]) begin
                virtio_mapping_snapshot_t record;

                record = snap.mapping_records[i];
                if (is_source_queue_ring_mapping(record.mapping, snap))
                    continue;
                if ((record.mapping.size == 0) ||
                    (record.payload.size() != record.mapping.size)) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: live mapping IOVA=0x%016h has invalid payload",
                        record.mapping.iova))
                    return;
                end
                record.checksum = migration_page_checksum(record.payload);
                dma_records.push_back(record);
            end
            snap.mapping_records = dma_records;
        end
        snap.integrity_checksum = migration_snapshot_checksum(snap);

        state = FSM_FROZEN;

        `uvm_info("AUTO_FSM",
            $sformatf("freeze_for_migration: frozen, %0d queues, %0d dirty pages, and %0d live mappings saved",
                      num_total_queues, snap.dirty_pages.size(),
                      snap.mapping_records.size()), UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // restore_from_migration -- FSM_IDLE -> FSM_FROZEN -> FSM_READY -> FSM_RUNNING
    //
    // Restores device state from a snapshot and restarts data plane.
    // ------------------------------------------------------------------------
    task restore_from_migration(virtio_device_snapshot_t snap,
                                output bit ok);
        ok = 0;
        if ($isunknown(snap.num_queue_pairs) ||
            (snap.num_queue_pairs == 0) ||
            (snap.num_queue_pairs > max_vio_net_qpairs_per_device)) begin
            `uvm_error("AUTO_FSM", $sformatf(
                {"restore_from_migration: snapshot queue-pair count %0d is ",
                 "outside supported range 1..%0d"},
                snap.num_queue_pairs,
                max_vio_net_qpairs_per_device))
            return;
        end
        do_restore_from_migration(snap, ok);
    endtask

    protected virtual task do_restore_from_migration(
        virtio_device_snapshot_t snap,
        output bit ok
    );
        bit feat_ok;
        bit reset_complete;
        bit setup_ok;
        bit queue_restore_ok;
        bit [63:0] restored_features;
        migration_record_group_t mapping_groups[$];

        ok = 0;

        `uvm_info("AUTO_FSM", "restore_from_migration: starting restore", UVM_LOW)

        state = FSM_FROZEN;

        // Verify all saved backing pages before reset, queue reconstruction,
        // or dataplane restart.  Keeping the pre-freeze mapping alive here
        // lets migration reject unmap/remap changes deterministically.
        if ((ops == null) || (ops.iommu == null) || (ops.mem == null) ||
            (ops.transport == null) || (ops.vq_mgr == null)) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: incomplete transport, queue, IOMMU, or host-memory context")
            return;
        end
        if ((snap.dirty_generation == 0) ||
            (snap.integrity_checksum != migration_snapshot_checksum(snap))) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: snapshot integrity checksum mismatch")
            ops.set_failed();
            return;
        end
        if (snap.queue_count != snap.queue_snapshots.size()) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue count mismatch saved=%0d snapshots=%0d",
                snap.queue_count, snap.queue_snapshots.size()))
            ops.set_failed();
            return;
        end
        foreach (snap.queue_snapshots[q]) begin
            if ((snap.queue_snapshots[q].queue_id != q) ||
                (snap.queue_snapshots[q].queue_size == 0) ||
                ((drv_cfg.queue_size != 0) &&
                 (snap.queue_snapshots[q].queue_size != drv_cfg.queue_size))) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: invalid queue snapshot index=%0d id=%0d size=%0d",
                    q, snap.queue_snapshots[q].queue_id,
                    snap.queue_snapshots[q].queue_size))
                ops.set_failed();
                return;
            end
        end
        if (!validate_normal_dma_restore_records(snap)) begin
            state = FSM_ERROR;
            ops.set_failed();
            return;
        end
        if (!validate_queue_dma_restore_records(snap)) begin
            state = FSM_ERROR;
            ops.set_failed();
            return;
        end
        foreach (snap.dirty_pages[p]) begin
            bit page_has_record;
            page_has_record = 0;
            foreach (snap.dirty_page_records[r]) begin
                if (snap.dirty_page_records[r].page_id == snap.dirty_pages[p]) begin
                    page_has_record = 1;
                    break;
                end
            end
            if (!page_has_record) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has no checksum record",
                    snap.dirty_pages[p]))
                return;
            end
        end
        foreach (snap.dirty_page_records[i]) begin
            virtio_dirty_page_snapshot_t record;
            byte page_data[];
            bit [63:0] expected_gpa;
            int unsigned expected_size;
            bit [63:0] checksum;
            bit page_is_listed;
            bit mapping_retired;

            record = snap.dirty_page_records[i];
            page_is_listed = 0;
            foreach (snap.dirty_pages[p]) begin
                if (snap.dirty_pages[p] == record.page_id) begin
                    page_is_listed = 1;
                    break;
                end
            end
            if (!page_is_listed) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page record %0d is not in the saved page set",
                    i))
                return;
            end
            if (!migration_mapping_page_span(record.page_id, record.mapping,
                                             expected_gpa, expected_size) ||
                (record.mapped_gpa != expected_gpa) ||
                (record.mapped_size != expected_size)) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid mapping span",
                    record.page_id))
                return;
            end
            if (record.payload.size() != record.mapped_size) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid snapshot payload size",
                    record.page_id))
                return;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h snapshot payload checksum mismatch",
                    record.page_id))
                return;
            end
            if (!ops.iommu.verify_dirty_page_mapping(record.page_id,
                                                      record.mapping,
                                                      mapping_retired)) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h IOMMU mapping mismatch",
                    record.page_id))
                return;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapped_gpa, record.mapped_size, page_data);
                checksum = migration_page_checksum(page_data);
                if (checksum != record.checksum) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: dirty page 0x%016h live backing checksum mismatch",
                        record.page_id))
                    return;
                end
            end
        end

        // Complete records are captured only while their source mappings are
        // live.  At restore the mapping may still be live (so compare its
        // backing bytes) or may have retired through the ordinary reset path
        // (so consume only the snapshot-owned payload).
        foreach (snap.mapping_records[i]) begin
            virtio_mapping_snapshot_t record;
            byte live_data[];
            bit [63:0] checksum;
            bit mapping_retired;

            record = snap.mapping_records[i];
            if ((record.mapping.size == 0) ||
                (record.payload.size() != record.mapping.size)) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h has invalid payload size",
                    record.mapping.iova))
                return;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h payload checksum mismatch",
                    record.mapping.iova))
                return;
            end
            if (!ops.iommu.verify_mapping_identity(record.mapping,
                                                    mapping_retired)) begin
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h IOMMU identity mismatch",
                    record.mapping.iova))
                return;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapping.gpa, record.mapping.size,
                                 live_data);
                checksum = migration_page_checksum(live_data);
                if (checksum != record.checksum) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: complete mapping IOVA=0x%016h live backing checksum mismatch",
                        record.mapping.iova))
                    return;
                end
            end
            foreach (snap.mapping_records[j]) begin
                if ((j > i) &&
                    (record.mapping.bdf == snap.mapping_records[j].mapping.bdf) &&
                    (record.mapping.iova == snap.mapping_records[j].mapping.iova)) begin
                    state = FSM_ERROR;
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: duplicate complete mapping IOVA=0x%016h",
                        record.mapping.iova))
                    return;
                end
            end
        end

        // Group only non-ring dirty spans with no complete live-mapping
        // record.  Ring dirty records remain checksum-validated above, but
        // the queue snapshot overlays their saved bytes on setup-owned
        // destination rings rather than materializing source-ring DMA.
        foreach (snap.dirty_page_records[i]) begin
            int matching_group;
            bit complete_mapping_exists;

            if (is_source_queue_ring_mapping(
                    snap.dirty_page_records[i].mapping, snap))
                continue;
            complete_mapping_exists = 0;
            foreach (snap.mapping_records[r]) begin
                if (same_migration_source_mapping(
                    snap.dirty_page_records[i].mapping,
                    snap.mapping_records[r].mapping)) begin
                    complete_mapping_exists = 1;
                    break;
                end
            end
            if (complete_mapping_exists)
                continue;
            matching_group = -1;
            foreach (mapping_groups[group_index]) begin
                if ((mapping_groups[group_index].size() != 0) &&
                    same_migration_source_mapping(
                        mapping_groups[group_index][0].mapping,
                        snap.dirty_page_records[i].mapping)) begin
                    matching_group = group_index;
                    break;
                end
            end
            if (matching_group >= 0) begin
                mapping_groups[matching_group].push_back(
                    snap.dirty_page_records[i]);
            end else begin
                migration_record_group_t new_group;

                new_group.push_back(snap.dirty_page_records[i]);
                mapping_groups.push_back(new_group);
            end
        end

        // 1. Reset and re-initialize transport.  No restored ownership may be
        // materialized unless the device has positively acknowledged reset.
        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: verified device reset did not complete")
            ops.set_failed();
            return;
        end
        ops.set_acknowledge();
        ops.set_driver();

        // 2. Restore the exact negotiated feature word.  A different result
        // changes queue semantics and makes all saved ring state unsafe.
        ops.negotiate_features(snap.negotiated_features, restored_features);
        if (restored_features != snap.negotiated_features) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: negotiated feature mismatch saved=0x%016h restored=0x%016h",
                snap.negotiated_features, restored_features))
            ops.set_failed();
            return;
        end

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", "restore_from_migration: feature negotiation failed")
            ops.set_failed();
            return;
        end

        // 3. Restore all complete records first, before queue setup consumes
        // new IOVAs.  This preserves every live source mapping at its stable
        // descriptor-visible address without descriptor-format parsing.
        foreach (snap.mapping_records[i]) begin
            iommu_mapping_t destination;

            if (!ops.materialize_migration_mapping(
                    snap.mapping_records[i].mapping,
                    snap.mapping_records[i].payload, destination) ||
                !same_restored_migration_layout(
                    destination, snap.mapping_records[i].mapping)) begin
                rollback_migration_restore();
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: failed to materialize complete source IOVA 0x%016h",
                    snap.mapping_records[i].mapping.iova))
                ops.set_failed();
                return;
            end
        end

        // A non-ring mapping that retired during drain cannot have a complete
        // source capture.  Materialize its dirty spans through the same
        // payload path so it receives ordinary reset ownership exactly once.
        foreach (mapping_groups[group_index]) begin
            iommu_mapping_t destination;
            iommu_mapping_t source_mapping;
            byte source_payload[];

            if (!build_dirty_fallback_payload(mapping_groups[group_index],
                                              source_mapping, source_payload) ||
                !ops.materialize_migration_mapping(source_mapping,
                                                   source_payload, destination) ||
                !same_restored_migration_layout(destination, source_mapping)) begin
                rollback_migration_restore();
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: failed to materialize source IOVA 0x%016h",
                    source_mapping.iova))
                ops.set_failed();
                return;
            end
        end

        // Normal data DMA is consumed FIFO-by-FIFO by tx_complete() and
        // rx_receive().  Reconnect it before queues are exposed again.
        if (!ops.restore_normal_dma_ownership(snap.normal_dma_records)) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: failed to restore normal DMA ownership")
            ops.set_failed();
            return;
        end

        // 4. Restore queues: setup fresh, then overlay snapshot data.  No
        // queue-format-specific descriptor address rewriting is needed: each
        // source DMA IOVA already resolves through its restored fixed mapping.
        active_num_pairs = snap.num_queue_pairs;
        num_total_queues = snap.queue_count;

        ops.setup_all_queues(active_num_pairs, drv_cfg.vq_type,
                             drv_cfg.queue_size, setup_ok);
        if (!setup_ok || (ops.vq_mgr.get_queue_count() != num_total_queues)) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue setup failed or created %0d/%0d queues",
                ops.vq_mgr.get_queue_count(), num_total_queues))
            ops.set_failed();
            return;
        end

        // Confirm that every queue-owned indirect table and dma_map_buf()
        // mapping can be reconstructed, but defer the physical ownership
        // transfer until each queue's complete overlay has succeeded. This
        // leaves later queues rollback-owned if an earlier overlay rejects.
        if (!ops.validate_restored_queue_ownership(snap)) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: queue-owned DMA validation failed")
            ops.set_failed();
            return;
        end

        // Restore ring data and indices from snapshot
        for (int unsigned q = 0; q < num_total_queues; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(q);
            queue_restore_ok = (vq != null) &&
                               vq.restore_state(snap.queue_snapshots[q]);
            if (!queue_restore_ok) begin
                rollback_migration_restore();
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d state overlay failed", q))
                ops.set_failed();
                return;
            end
            if (!ops.claim_restored_queue_ownership(snap.queue_snapshots[q])) begin
                rollback_migration_restore();
                state = FSM_ERROR;
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d ownership commit failed", q))
                ops.set_failed();
                return;
            end
            vq.commit_restored_migration_ownership();
        end

        // 5. Restore MSI-X
        ops.setup_msix(num_total_queues);

        // 6. DRIVER_OK
        ops.set_driver_ok();
        state = FSM_READY;

        // 7. Restart data plane
        start_dataplane();
        if (state != FSM_RUNNING) begin
            rollback_migration_restore();
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM",
                "restore_from_migration: data plane did not restart")
            ops.set_failed();
            return;
        end

        ok = 1;

        `uvm_info("AUTO_FSM", "restore_from_migration: restore complete, data plane running", UVM_LOW)
    endtask

    // ========================================================================
    // Error Recovery
    // ========================================================================

    protected task complete_device_recovery();
        state = FSM_RECOVERING;

        // Full device reset and re-initialization happens only after the
        // dataplane worker set has acknowledged its exit.
        ops.device_reset();

        state = FSM_IDLE;
        full_init();

        if (state == FSM_READY)
            start_dataplane();
    endtask

    protected task dataplane_recovery_supervisor(int unsigned worker_epoch);
        wait (dataplane_workers_stopped_epoch == worker_epoch);
        if (recovery_requested_epoch != worker_epoch)
            return;

        recovery_requested_epoch = 0;
        `uvm_info("AUTO_FSM",
            "dataplane recovery supervisor: all workers stopped", UVM_LOW)
        state = FSM_ERROR;
        complete_device_recovery();
    endtask

    // ------------------------------------------------------------------------
    // handle_device_needs_reset -- Full device recovery cycle
    //
    // FSM_RUNNING -> FSM_ERROR -> FSM_RECOVERING -> full_init -> start_dataplane
    // ------------------------------------------------------------------------
    virtual task handle_device_needs_reset();
        `uvm_info("AUTO_FSM", "handle_device_needs_reset: starting recovery", UVM_LOW)

        state = FSM_ERROR;

        if (dataplane_running)
            stop_dataplane();

        complete_device_recovery();

        `uvm_info("AUTO_FSM",
            $sformatf("handle_device_needs_reset: recovery complete, state=%s", state.name()),
            UVM_LOW)
    endtask

    // ------------------------------------------------------------------------
    // reset_single_queue -- Reset and re-setup a single queue
    //
    // Does not change overall FSM state. If the queue is a receive queue,
    // refills RX buffers after re-setup.
    // ------------------------------------------------------------------------
    virtual task reset_single_queue(int unsigned queue_id);
        bit setup_ok;
        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d", queue_id), UVM_MEDIUM)

        // Teardown the queue
        ops.teardown_queue(queue_id);

        // Reset via transport (writes Q_RESET, polls until complete)
        ops.reset_queue(queue_id);

        // Re-setup the queue
        ops.setup_queue(queue_id, drv_cfg.queue_size, drv_cfg.vq_type, setup_ok);
        if (!setup_ok) begin
            state = FSM_ERROR;
            `uvm_error("AUTO_FSM", $sformatf(
                "reset_single_queue: failed to setup queue %0d", queue_id))
            return;
        end

        // If this is a receive queue (even-numbered), refill RX buffers
        if (queue_id % 2 == 0 && queue_id < active_num_pairs * 2) begin
            ops.rx_refill(queue_id, drv_cfg.queue_size);
        end

        `uvm_info("AUTO_FSM",
            $sformatf("reset_single_queue: queue_id=%0d complete", queue_id), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Background Tasks
    //
    // ALL background tasks must:
    //   - Loop with dataplane_worker_may_run(worker_epoch)
    //   - Use named fork blocks for internal waits
    //   - Check the run epoch after every wait and shared operation
    //   - Exit gracefully on stop_event
    // ========================================================================

    // ------------------------------------------------------------------------
    // rx_refill_loop -- Periodically refill RX buffers for a queue
    // ------------------------------------------------------------------------
    protected virtual task rx_refill_loop(
        int unsigned queue_id, int unsigned worker_epoch
    );
        int unsigned interval;
        int unsigned threshold;

        interval  = ops.wait_pol.default_poll_interval_ns;
        threshold = drv_cfg.rx_refill_threshold;
        if (threshold == 0)
            threshold = drv_cfg.queue_size / 4;

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d started, threshold=%0d",
                      queue_id, threshold), UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            virtqueue_base vq;

            // Wait for event or poll interval (named fork)
            fork : rx_refill_wait_blk
                begin : rx_refill_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : rx_refill_timeout_arm
                    #(interval * 1ns);
                end
                begin : rx_refill_stop_arm
                    @stop_event;
                end
            join_any
            disable rx_refill_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Check if refill is needed
            vq = ops.vq_mgr.get_queue(queue_id);
            if (vq != null) begin
                int unsigned free_count = vq.get_free_count();
                if (free_count >= threshold) begin
                    ops.rx_refill(queue_id, free_count);
                end
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("rx_refill_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // tx_complete_loop -- Periodically poll for TX completions
    // ------------------------------------------------------------------------
    protected virtual task tx_complete_loop(
        int unsigned queue_id, int unsigned worker_epoch
    );
        int unsigned interval;
        int unsigned budget;

        interval = ops.wait_pol.default_poll_interval_ns;
        budget   = drv_cfg.napi_budget;
        if (budget == 0)
            budget = 64;

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d started, budget=%0d",
                      queue_id, budget), UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            uvm_object completed[$];

            // Wait for event or poll interval (named fork)
            fork : tx_complete_wait_blk
                begin : tx_complete_evt_arm
                    used_ring_updated_event.wait_trigger();
                end
                begin : tx_complete_timeout_arm
                    #(interval * 1ns);
                end
                begin : tx_complete_stop_arm
                    @stop_event;
                end
            join_any
            disable tx_complete_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            ops.tx_complete(queue_id, completed, budget);

            if (completed.size() > 0) begin
                packet_completed_event.trigger();
            end
        end

        `uvm_info("AUTO_FSM",
            $sformatf("tx_complete_loop: queue_id=%0d exiting", queue_id), UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // interrupt_handler_loop -- Dispatch incoming interrupts
    // ------------------------------------------------------------------------
    protected virtual task interrupt_handler_loop(int unsigned worker_epoch);
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns;

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            // Wait for interrupt event or poll interval (named fork)
            fork : irq_handler_wait_blk
                begin : irq_handler_evt_arm
                    interrupt_event.wait_trigger();
                end
                begin : irq_handler_timeout_arm
                    #(interval * 1ns);
                end
                begin : irq_handler_stop_arm
                    @stop_event;
                end
            join_any
            disable irq_handler_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Signal that used ring may have new entries
            used_ring_updated_event.trigger();
        end

        `uvm_info("AUTO_FSM", "interrupt_handler_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // adaptive_irq_loop -- Switch between MSI-X and polling based on rate
    //
    // Monitors packet completion rate over a window. If rate exceeds a
    // threshold, switches to polling mode. If rate drops, switches back
    // to interrupt-driven mode.
    // ------------------------------------------------------------------------
    protected virtual task adaptive_irq_loop(int unsigned worker_epoch);
        int unsigned interval;
        int unsigned pkt_count_window = 0;
        int unsigned high_rate_threshold;
        int unsigned low_rate_threshold;
        bit          currently_polling = 0;

        interval = ops.wait_pol.default_poll_interval_ns * 10;  // Longer measurement window
        high_rate_threshold = drv_cfg.coal_max_packets;
        if (high_rate_threshold == 0)
            high_rate_threshold = 256;
        low_rate_threshold = high_rate_threshold / 4;

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            pkt_count_window = 0;

            // Count packet completions over one measurement window (named fork)
            fork : adaptive_irq_wait_blk
                begin : adaptive_irq_evt_arm
                    while (dataplane_worker_may_run(worker_epoch)) begin
                        packet_completed_event.wait_trigger();
                        pkt_count_window++;
                    end
                end
                begin : adaptive_irq_timeout_arm
                    #(interval * 1ns);
                end
                begin : adaptive_irq_stop_arm
                    @stop_event;
                end
            join_any
            disable adaptive_irq_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Evaluate rate and switch mode if needed
            if (!currently_polling && pkt_count_window > high_rate_threshold) begin
                // High rate: switch to polling
                currently_polling = 1;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.disable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.disable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to POLLING (rate=%0d > %0d)",
                              pkt_count_window, high_rate_threshold), UVM_MEDIUM)
            end else if (currently_polling && pkt_count_window < low_rate_threshold) begin
                // Low rate: switch back to MSI-X interrupts
                currently_polling = 0;
                for (int unsigned i = 0; i < active_num_pairs; i++) begin
                    virtqueue_base vq;
                    vq = ops.vq_mgr.get_queue(i * 2);
                    if (vq != null) vq.enable_cb();
                    vq = ops.vq_mgr.get_queue(i * 2 + 1);
                    if (vq != null) vq.enable_cb();
                end
                `uvm_info("AUTO_FSM",
                    $sformatf("adaptive_irq: switching to MSI-X (rate=%0d < %0d)",
                              pkt_count_window, low_rate_threshold), UVM_MEDIUM)
            end
        end

        `uvm_info("AUTO_FSM", "adaptive_irq_loop: exiting", UVM_HIGH)
    endtask

    // ------------------------------------------------------------------------
    // config_change_handler -- Monitor device configuration changes
    //
    // Periodically checks for device config changes (link status,
    // GUEST_ANNOUNCE, DEVICE_NEEDS_RESET).
    // ------------------------------------------------------------------------
    protected virtual task config_change_handler(int unsigned worker_epoch);
        int unsigned interval;

        interval = ops.wait_pol.default_poll_interval_ns * 5;

        `uvm_info("AUTO_FSM", "config_change_handler: started", UVM_HIGH)

        while (dataplane_worker_may_run(worker_epoch)) begin
            // Wait for config change event or poll interval (named fork)
            fork : cfg_change_wait_blk
                begin : cfg_change_evt_arm
                    config_change_event.wait_trigger();
                end
                begin : cfg_change_timeout_arm
                    #(interval * 1ns);
                end
                begin : cfg_change_stop_arm
                    @stop_event;
                end
            join_any
            disable cfg_change_wait_blk;

            if (!dataplane_worker_may_run(worker_epoch)) return;

            // Re-read device configuration and handle changes
            begin
                virtio_net_device_config_t cfg;
                ops.transport.read_net_config(cfg);

                // Check link status if STATUS feature is negotiated
                if (ops.negotiated_features[VIRTIO_NET_F_STATUS]) begin
                    if (cfg.status & 16'h0001) begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is UP", UVM_MEDIUM)
                    end else begin
                        `uvm_info("AUTO_FSM",
                            "config_change_handler: link is DOWN", UVM_MEDIUM)
                    end
                end

                // Check GUEST_ANNOUNCE request
                if (ops.negotiated_features[VIRTIO_NET_F_GUEST_ANNOUNCE]) begin
                    if (cfg.status & 16'h0002) begin
                        bit announce_ok;
                        ops.ctrl_announce_ack(announce_ok);
                        `uvm_info("AUTO_FSM",
                            $sformatf("config_change_handler: guest announce ack=%0b",
                                      announce_ok), UVM_MEDIUM)
                    end
                end

                // Check DEVICE_NEEDS_RESET
                begin
                    bit [7:0] dev_status;
                    ops.transport.read_device_status(dev_status);
                    if (dev_status & DEV_STATUS_DEVICE_NEEDS_RESET) begin
                        `uvm_warning("AUTO_FSM",
                            "config_change_handler: DEVICE_NEEDS_RESET detected")
                        recovery_requested_epoch = worker_epoch;
                        request_dataplane_stop(worker_epoch);
                        return;
                    end
                end
            end
        end

        `uvm_info("AUTO_FSM", "config_change_handler: exiting", UVM_HIGH)
    endtask

endclass : virtio_auto_fsm

`endif // VIRTIO_AUTO_FSM_SV
