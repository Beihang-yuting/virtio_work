`ifndef VIRTIO_MIGRATION_ENGINE_SV
`define VIRTIO_MIGRATION_ENGINE_SV

// ============================================================================
// virtio_migration_engine
//
// 目录层次：src/agent；承担 virtio_auto_fsm 的热迁移计算与恢复步骤：快照校验和、
// freeze 时的 DMA/脏页采集、restore 前的完整性校验，以及复位后的映射/队列重建。
// 依赖 virtio_atomic_ops（借用，调用方传入）、IOMMU/Host memory 与快照类型。
// 引擎不持有 FSM 状态：状态迁移、数据面启停仍由 FSM 负责；失败时引擎只报告并
// 返回 ok=0，由 FSM 置 FSM_ERROR。诊断沿用 "AUTO_FSM" ID 与原消息文本，
// 既有测试的 report catcher 不需要修改。
// ============================================================================

class virtio_migration_engine extends uvm_object;
    `uvm_object_utils(virtio_migration_engine)

    localparam int unsigned MIGRATION_PAGE_SIZE = 4096;
    typedef virtio_dirty_page_snapshot_t migration_record_group_t[$];

    // 无状态对象：构造不访问任何设备或 Host memory。
    function new(string name = "virtio_migration_engine");
        super.new(name);
    endfunction

    // The checksum is calculated over one migration-owned mapping span.  It
    // is used only for migration integrity validation, not as a cryptographic
    // primitive.
    function bit [63:0] migration_page_checksum(byte page_data[]);
        bit [63:0] checksum;

        checksum = 64'hcbf2_9ce4_8422_2325;
        foreach (page_data[i]) begin
            checksum = (checksum ^ {56'h0, page_data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // FNV-1a 累积步进：把一个 64-bit 字按小端字节序逐字节混入校验和。
    // 输入当前校验和与数据字，返回更新后的校验和（纯函数，无副作用）。
    protected function bit [63:0] migration_checksum_word(
        bit [63:0] checksum, bit [63:0] value
    );
        for (int unsigned byte_index = 0; byte_index < 8; byte_index++) begin
            checksum = (checksum ^ {56'h0, value[byte_index * 8 +: 8]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // FNV-1a 累积步进：把 byte 动态数组逐字节混入校验和并返回新值。
    protected function bit [63:0] migration_checksum_bytes(
        bit [63:0] checksum, byte data[]
    );
        foreach (data[i]) begin
            checksum = (checksum ^ {56'h0, data[i]}) *
                       64'h0000_0100_0000_01b3;
        end
        return checksum;
    endfunction

    // 同 migration_checksum_bytes，但输入为 byte unsigned 数组——SV 中
    // 两种元素类型不能隐式互换，故需要单独重载而非复用。
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
    function bit [63:0] migration_snapshot_checksum(
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
                    {32'h0, indirect_snapshot.mapping.host_id});
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
                    {32'h0, queue_dma_mapping.host_id});
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
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
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
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
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
            checksum = migration_checksum_word(checksum,
                {32'h0, record.mapping.host_id});
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
    function bit migration_mapping_page_span(
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
        return (left.host_id == right.host_id) &&
               (left.bdf  == right.bdf)  &&
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
        return (left.host_id == right.host_id) &&
               (left.bdf  == right.bdf)  &&
               (left.iova == right.iova) &&
               (left.size == right.size) &&
               (left.dir  == right.dir);
    endfunction

    // Normal DMA completion is FIFO- and role-specific.  Validate every
    // ownership record against the saved queue-pair topology before reset
    // materializes any source mapping: RX queues are even, TX queues are odd,
    // and neither data path may target an optional control queue.
    protected function bit validate_normal_dma_restore_records(
        virtio_atomic_ops ops,
        int unsigned host_id,
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
                (record.mapping.host_id != host_id) ||
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
        virtio_atomic_ops ops,
        int unsigned host_id,
        virtio_device_snapshot_t snap
    );
        foreach (snap.queue_snapshots[q]) begin
            foreach (snap.queue_snapshots[q].queue_dma_mappings[i]) begin
                iommu_mapping_t mapping;
                bit found_mapping;

                mapping = snap.queue_snapshots[q].queue_dma_mappings[i];
                found_mapping = 0;
                if ((mapping.host_id != host_id) ||
                    (mapping.bdf != ops.transport.bdf) ||
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
                        if ((mapping.host_id == other_mapping.host_id) &&
                            (mapping.bdf == other_mapping.bdf) &&
                            (mapping.iova == other_mapping.iova)) begin
                            `uvm_error("AUTO_FSM", $sformatf(
                                "restore_from_migration: duplicate queue DMA IOVA=0x%016h",
                                mapping.iova))
                            return 0;
                        end
                    end
                end
                foreach (snap.normal_dma_records[n]) begin
                    if ((mapping.host_id == snap.normal_dma_records[n].mapping.host_id) &&
                        (mapping.bdf == snap.normal_dma_records[n].mapping.bdf) &&
                        (mapping.iova == snap.normal_dma_records[n].mapping.iova)) begin
                        `uvm_error("AUTO_FSM", $sformatf(
                            "restore_from_migration: queue DMA overlaps normal ownership IOVA=0x%016h",
                            mapping.iova))
                        return 0;
                    end
                end
                foreach (snap.queue_snapshots[owner_q]) begin
                    foreach (snap.queue_snapshots[owner_q].indirect_tables[t]) begin
                        if ((mapping.host_id ==
                             snap.queue_snapshots[owner_q].indirect_tables[t].mapping.host_id) &&
                            (mapping.bdf ==
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

    // Any failure after the restore reset has acknowledged must immediately
    // return all queue rings, normal FIFO records, and still-temporary
    // migration mappings to verified-reset ownership.  Releasing only the
    // temporary migration list is insufficient once a normal DMA record or
    // indirect table has been claimed by a queue FIFO.
    task rollback(virtio_atomic_ops ops);
        bit reset_complete;

        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: rollback verified device reset did not complete")
        end
    endtask

    // freeze 的采集段：调用方已开启脏页 generation 并停止数据面。输入当前队列对数
    // 与队列总数，输出完整快照与校验和；任一采集失败报告 AUTO_FSM 错误并 ok=0，
    // 快照内容此时不可用于恢复。
    task capture_snapshot(
        virtio_atomic_ops ops,
        int unsigned host_id,
        int unsigned num_pairs,
        int unsigned num_queues,
        output bit ok,
        ref virtio_device_snapshot_t snap
    );
        int unsigned queue_ids[$];
        ok = 0;
        // 3. Save negotiated features and device status
        snap.negotiated_features = ops.negotiated_features;
        begin
            bit [7:0] dev_status;
            ops.read_device_status(dev_status);
            snap.device_status = dev_status;
        end

        // 4. Read device config
        ops.read_net_config(snap.net_config);

        // 5. Save all queue states
        snap.num_queue_pairs = num_pairs;
        snap.queue_count = num_queues;
        snap.queue_snapshots = new[num_queues];

        // 槽位按实际队列号升序填充：数据队列 0..2N-1 连续，control VQ 可位于
        // 2*max_virtqueue_pairs。队列少于 num_queues 时剩余槽位保持默认值（restore 拒绝）。
        ops.vq_mgr.get_queue_ids(queue_ids);
        for (int unsigned slot = 0;
             (slot < num_queues) && (slot < queue_ids.size()); slot++) begin
            virtqueue_base vq;
            virtqueue_snapshot_t tmp_snap;
            vq = ops.vq_mgr.get_queue(queue_ids[slot]);
            vq.save_state(tmp_snap);
            snap.queue_snapshots[slot] = tmp_snap;
        end
        if (!ops.snapshot_normal_dma_ownership(snap.normal_dma_records)) begin
            `uvm_error("AUTO_FSM",
                "freeze_for_migration: unable to capture normal DMA ownership")
            return;
        end

        // 6. Atomically capture this generation.  Each completed device write
        // already saved its exact post-write mapping span in the IOMMU before
        // normal completion could unmap/free its backing allocation.
        ops.iommu.capture_dirty_generation_for_host(host_id,
                                                    snap.dirty_pages);
        snap.dirty_page_records.delete();
        foreach (snap.dirty_pages[i]) begin
            virtio_dirty_page_snapshot_t records[$];

            ops.iommu.get_dirty_page_records_for_host(
                host_id,
                snap.dirty_pages[i], records);
            if (records.size() == 0) begin
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
                    `uvm_error("AUTO_FSM", $sformatf(
                        "freeze_for_migration: dirty page 0x%016h has empty mapping span",
                        record.page_id))
                    return;
                end
                if (record.payload.size() != record.mapped_size) begin
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
        if (!ops.iommu.snapshot_live_mappings_for_host(
                host_id,
                ops.mem, ops.transport.bdf, snap.mapping_records)) begin
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
        ok = 1;
    endtask

    // restore 的复位前校验：快照校验和、队列拓扑、普通/队列 DMA 所有权、脏页与
    // 完整映射记录逐项核对。返回 0 表示拒绝；set_failed_required=1 时调用方须
    // 向设备写 FAILED（与原 FSM 行为一致：结构性错误写 FAILED，载荷错误不写）。
    function bit validate_restore_snapshot(
        virtio_atomic_ops ops,
        int unsigned host_id,
        int unsigned configured_queue_size,
        virtio_device_snapshot_t snap,
        output bit set_failed_required
    );
        set_failed_required = 0;
        if ((snap.dirty_generation == 0) ||
            (snap.integrity_checksum != migration_snapshot_checksum(snap))) begin
            `uvm_error("AUTO_FSM",
                "restore_from_migration: snapshot integrity checksum mismatch")
            set_failed_required = 1;
            return 0;
        end
        if (snap.queue_count != snap.queue_snapshots.size()) begin
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue count mismatch saved=%0d snapshots=%0d",
                snap.queue_count, snap.queue_snapshots.size()))
            set_failed_required = 1;
            return 0;
        end
        foreach (snap.queue_snapshots[q]) begin
            bit queue_id_valid;

            // 数据队列槽位与队列号一致（普通 DMA 记录按 queue_id 索引槽位）；其后槽位
            // 只能是 control VQ：队列号不小于 2*num_queue_pairs 且严格递增。
            if (q < 2 * snap.num_queue_pairs)
                queue_id_valid = (snap.queue_snapshots[q].queue_id == q);
            else
                queue_id_valid =
                    (snap.queue_snapshots[q].queue_id >= 2 * snap.num_queue_pairs) &&
                    ((q == 0) ||
                     (snap.queue_snapshots[q].queue_id > snap.queue_snapshots[q - 1].queue_id));
            if (!queue_id_valid ||
                (snap.queue_snapshots[q].queue_size == 0) ||
                ((configured_queue_size != 0) &&
                 (snap.queue_snapshots[q].queue_size != configured_queue_size))) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: invalid queue snapshot index=%0d id=%0d size=%0d",
                    q, snap.queue_snapshots[q].queue_id,
                    snap.queue_snapshots[q].queue_size))
                set_failed_required = 1;
                return 0;
            end
        end
        if (!validate_normal_dma_restore_records(ops, host_id, snap)) begin
            set_failed_required = 1;
            return 0;
        end
        if (!validate_queue_dma_restore_records(ops, host_id, snap)) begin
            set_failed_required = 1;
            return 0;
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
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has no checksum record",
                    snap.dirty_pages[p]))
                return 0;
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
            if ((record.mapping.host_id != host_id) ||
                (record.mapping.bdf != ops.transport.bdf)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty record belongs to host=%0d BDF=0x%04h, expected host=%0d BDF=0x%04h",
                    record.mapping.host_id, record.mapping.bdf,
                    host_id, ops.transport.bdf))
                return 0;
            end
            page_is_listed = 0;
            foreach (snap.dirty_pages[p]) begin
                if (snap.dirty_pages[p] == record.page_id) begin
                    page_is_listed = 1;
                    break;
                end
            end
            if (!page_is_listed) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page record %0d is not in the saved page set",
                    i))
                return 0;
            end
            if (!migration_mapping_page_span(record.page_id, record.mapping,
                                             expected_gpa, expected_size) ||
                (record.mapped_gpa != expected_gpa) ||
                (record.mapped_size != expected_size)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid mapping span",
                    record.page_id))
                return 0;
            end
            if (record.payload.size() != record.mapped_size) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h has invalid snapshot payload size",
                    record.page_id))
                return 0;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h snapshot payload checksum mismatch",
                    record.page_id))
                return 0;
            end
            if (!ops.iommu.verify_dirty_page_mapping(record.page_id,
                                                      record.mapping,
                                                      mapping_retired)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: dirty page 0x%016h IOMMU mapping mismatch",
                    record.page_id))
                return 0;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapped_gpa, record.mapped_size, page_data);
                checksum = migration_page_checksum(page_data);
                if (checksum != record.checksum) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: dirty page 0x%016h live backing checksum mismatch",
                        record.page_id))
                    return 0;
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
            if ((record.mapping.host_id != host_id) ||
                (record.mapping.bdf != ops.transport.bdf) ||
                (record.mapping.size == 0) ||
                (record.payload.size() != record.mapping.size)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h has invalid payload size",
                    record.mapping.iova))
                return 0;
            end
            checksum = migration_page_checksum(record.payload);
            if (checksum != record.checksum) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h payload checksum mismatch",
                    record.mapping.iova))
                return 0;
            end
            if (!ops.iommu.verify_mapping_identity(record.mapping,
                                                    mapping_retired)) begin
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: complete mapping IOVA=0x%016h IOMMU identity mismatch",
                    record.mapping.iova))
                return 0;
            end
            if (!mapping_retired) begin
                ops.mem.read_mem(record.mapping.gpa, record.mapping.size,
                                 live_data);
                checksum = migration_page_checksum(live_data);
                if (checksum != record.checksum) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: complete mapping IOVA=0x%016h live backing checksum mismatch",
                        record.mapping.iova))
                    return 0;
                end
            end
            foreach (snap.mapping_records[j]) begin
                if ((j > i) &&
                    (record.mapping.host_id == snap.mapping_records[j].mapping.host_id) &&
                    (record.mapping.bdf == snap.mapping_records[j].mapping.bdf) &&
                    (record.mapping.iova == snap.mapping_records[j].mapping.iova)) begin
                    `uvm_error("AUTO_FSM", $sformatf(
                        "restore_from_migration: duplicate complete mapping IOVA=0x%016h",
                        record.mapping.iova))
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    // 把没有完整映射记录、且不属于源 ring 的脏页按源映射分组，供复位后用
    // build_dirty_fallback_payload 重建；纯计算，不访问设备。
    function void collect_dirty_fallback_groups(
        virtio_device_snapshot_t snap,
        output migration_record_group_t mapping_groups[$]
    );
        mapping_groups.delete();
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
    endfunction

    // restore 的设备与 DMA 段：验证式复位、恢复原特性字、按固定 IOVA 重建完整映射
    // 和脏页回退映射、恢复普通 DMA 所有权。复位后任一步失败先回滚再报告并写 FAILED。
    task restore_device_and_dma(
        virtio_atomic_ops ops,
        virtio_device_snapshot_t snap,
        migration_record_group_t mapping_groups[$],
        output bit ok
    );
        bit feat_ok;
        bit reset_complete;
        bit [63:0] restored_features;

        ok = 0;
        // 1. Reset and re-initialize transport.  No restored ownership may be
        // materialized unless the device has positively acknowledged reset.
        ops.device_reset_verified(reset_complete);
        if (!reset_complete) begin
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
            rollback(ops);
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: negotiated feature mismatch saved=0x%016h restored=0x%016h",
                snap.negotiated_features, restored_features))
            ops.set_failed();
            return;
        end

        ops.set_features_ok(feat_ok);
        if (!feat_ok) begin
            rollback(ops);
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
                rollback(ops);
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
                rollback(ops);
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
            rollback(ops);
            `uvm_error("AUTO_FSM",
                "restore_from_migration: failed to restore normal DMA ownership")
            ops.set_failed();
            return;
        end
        ok = 1;
    endtask

    // restore 的队列段：按快照队列对数建队，校验队列所有权后逐队列覆盖 ring 状态并
    // 提交所有权。失败回滚到验证式复位并写 FAILED。
    task restore_queues(
        virtio_atomic_ops ops,
        virtio_device_snapshot_t snap,
        virtio_driver_config_t cfg,
        output bit ok
    );
        bit setup_ok;
        bit queue_restore_ok;

        ok = 0;
        // 4. Restore queues: setup fresh, then overlay snapshot data.  No
        // queue-format-specific descriptor address rewriting is needed: each
        // source DMA IOVA already resolves through its restored fixed mapping.
        ops.setup_all_queues(snap.num_queue_pairs, cfg.vq_type,
                             cfg.queue_size, setup_ok);
        if (!setup_ok || (ops.vq_mgr.get_queue_count() != snap.queue_count)) begin
            rollback(ops);
            `uvm_error("AUTO_FSM", $sformatf(
                "restore_from_migration: queue setup failed or created %0d/%0d queues",
                ops.vq_mgr.get_queue_count(), snap.queue_count))
            ops.set_failed();
            return;
        end

        // Confirm that every queue-owned indirect table and dma_map_buf()
        // mapping can be reconstructed, but defer the physical ownership
        // transfer until each queue's complete overlay has succeeded. This
        // leaves later queues rollback-owned if an earlier overlay rejects.
        if (!ops.validate_restored_queue_ownership(snap)) begin
            rollback(ops);
            `uvm_error("AUTO_FSM",
                "restore_from_migration: queue-owned DMA validation failed")
            ops.set_failed();
            return;
        end

        // Restore ring data and indices from snapshot
        for (int unsigned q = 0; q < snap.queue_count; q++) begin
            virtqueue_base vq;
            vq = ops.vq_mgr.get_queue(snap.queue_snapshots[q].queue_id);
            queue_restore_ok = (vq != null) &&
                               vq.restore_state(snap.queue_snapshots[q]);
            if (!queue_restore_ok) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d state overlay failed",
                    snap.queue_snapshots[q].queue_id))
                ops.set_failed();
                return;
            end
            if (!ops.claim_restored_queue_ownership(snap.queue_snapshots[q])) begin
                rollback(ops);
                `uvm_error("AUTO_FSM", $sformatf(
                    "restore_from_migration: queue %0d ownership commit failed",
                    snap.queue_snapshots[q].queue_id))
                ops.set_failed();
                return;
            end
            vq.commit_restored_migration_ownership();
        end
        ok = 1;
    endtask
endclass : virtio_migration_engine

`endif // VIRTIO_MIGRATION_ENGINE_SV
