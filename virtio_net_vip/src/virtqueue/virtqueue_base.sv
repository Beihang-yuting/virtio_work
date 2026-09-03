`ifndef VIRTQUEUE_BASE_SV
`define VIRTQUEUE_BASE_SV

// ============================================================================
// virtqueue_base
//
// Abstract base class defining the interface all virtqueue implementations
// must follow. Extends uvm_object (NOT uvm_component).
//
// Subclasses (split_virtqueue, packed_virtqueue, custom_virtqueue) must
// implement all pure virtual methods. This class provides common state,
// setup logic, and utility methods (dump_ring, leak_check).
//
// Depends on:
//   - virtio_net_types.sv (virtqueue_state_e, virtqueue_error_e, dma_dir_e,
//     virtio_sg_list, virtqueue_snapshot_t, iommu_mapping_t)
//   - host_mem_pkg (host_mem_manager)
//   - virtio_iommu_model, virtio_memory_barrier_model, virtio_wait_policy
//   - virtqueue_error_injector
// ============================================================================

virtual class virtqueue_base extends uvm_object;

    // ===== Queue identity =====
    int unsigned    queue_id;
    int unsigned    global_queue_id;
    int unsigned    queue_size;

    // ===== Memory layout (set by alloc_rings) =====
    bit [63:0]      desc_table_addr;
    bit [63:0]      driver_ring_addr;
    bit [63:0]      device_ring_addr;

    // ===== External component references (set by setup) =====
    host_mem_manager          mem;
    virtio_iommu_model        iommu;
    virtio_memory_barrier_model barrier;
    virtqueue_error_injector  err_inj;
    virtio_wait_policy        wait_pol;

    // ===== Host-qualified requester identity for IOMMU operations =====
    int unsigned    host_id;
    bit [15:0]      bdf;

    // ===== State =====
    virtqueue_state_e state = VQ_RESET;
    bit               queue_enable = 0;

    // ===== Token tracking: desc_id -> caller context =====
    protected uvm_object token_map[int unsigned];

    // ===== DMA mapping tracking =====
    protected iommu_mapping_t dma_mappings[$];
    // Migration recreates queue-owned DMA with a fresh backing allocation at
    // the saved IOVA.  Only these records own their GPA; ordinary dma_map_buf
    // callers retain ownership of the GPA they supplied.
    protected bit migration_owned_dma_iovas[bit [63:0]];

    // Queue restore preflights mappings while the atomic-ops layer still owns
    // their temporary migration records.  Commit only after that layer has
    // atomically transferred every mapping in this queue snapshot.
    protected iommu_mapping_t staged_migration_dma_mappings[$];

    // ===== Indirect descriptor table ownership =====
    // Each entry is owned by one main-ring descriptor.  The table itself is
    // device-readable DMA memory and therefore has an independent IOMMU map.
    typedef struct {
        bit [63:0] gpa;
        bit [63:0] iova;
        int unsigned byte_size;
        int unsigned entry_count;
        uvm_object token;
    } indirect_table_record_t;
    protected indirect_table_record_t indirect_table_records[int unsigned];
    protected indirect_table_record_t staged_indirect_table_records[int unsigned];

    // ===== Statistics =====
    int unsigned    total_add_buf_ops = 0;
    int unsigned    total_poll_used_ops = 0;
    int unsigned    total_kick_ops = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtqueue_base");
        super.new(name);
    endfunction

    // ------------------------------------------------------------------
    // setup -- Initialize queue with external references
    //
    // Called by virtqueue_manager after creating the queue instance.
    // Stores all references and sets the queue state to VQ_RESET.
    //
    // Parameters:
    //   qid        -- Queue ID within the device
    //   size       -- Number of descriptors in the queue
    //   m          -- Host memory manager reference
    //   io         -- IOMMU model reference
    //   b          -- Memory barrier model reference
    //   e          -- Error injector reference
    //   w          -- Wait/timeout policy reference
    //   device_bdf     -- PCI BDF for IOMMU operations
    //   device_host_id -- PCIe host/IOMMU requester domain (legacy host0)
    // ------------------------------------------------------------------
    virtual function void setup(
        int unsigned qid,
        int unsigned size,
        host_mem_manager m,
        virtio_iommu_model io,
        virtio_memory_barrier_model b,
        virtqueue_error_injector e,
        virtio_wait_policy w,
        bit [15:0] device_bdf,
        int unsigned device_host_id = 0
    );
        queue_id        = qid;
        queue_size      = size;
        mem             = m;
        iommu           = io;
        barrier         = b;
        err_inj         = e;
        wait_pol        = w;
        host_id         = device_host_id;
        bdf             = device_bdf;
        state           = VQ_RESET;

        `uvm_info("VQ_BASE",
            $sformatf("setup: queue_id=%0d size=%0d host=%0d bdf=0x%04x",
                      qid, size, device_host_id, device_bdf),
            UVM_HIGH)
    endfunction

    // =================================================================
    // Pure virtual methods -- subclass MUST implement
    // =================================================================

    // ----- Lifecycle -----
    pure virtual function void alloc_rings();
    pure virtual function void free_rings();
    pure virtual function void reset_queue();
    pure virtual function void detach_all_unused(ref uvm_object tokens[$]);

    // ----- Driver operations -----
    pure virtual function int unsigned add_buf(
        virtio_sg_list  sgs[],
        int unsigned    n_out_sgs,
        int unsigned    n_in_sgs,
        uvm_object      token,
        bit             indirect
    );
    pure virtual task kick();
    pure virtual function bit poll_used(
        ref uvm_object      token,
        ref int unsigned     len
    );

    // ----- Notification control (NAPI style) -----
    pure virtual function void disable_cb();
    pure virtual function void enable_cb();
    pure virtual function void enable_cb_delayed();
    pure virtual function bit  vq_poll(int unsigned last_used);

    // ----- Query -----
    pure virtual function int unsigned get_free_count();
    pure virtual function int unsigned get_pending_count();
    pure virtual function bit          needs_notification();

    // ----- DMA helpers -----
    pure virtual function bit [63:0] dma_map_buf(
        bit [63:0] gpa, int unsigned size, dma_dir_e dir
    );
    pure virtual function void dma_unmap_buf(bit [63:0] iova);

    // ----- Error injection -----
    pure virtual function void inject_desc_error(virtqueue_error_e err_type);

    // ----- Migration snapshot -----
    pure virtual function void save_state(ref virtqueue_snapshot_t snap);
    pure virtual function bit restore_state(virtqueue_snapshot_t snap);

    // =================================================================
    // Common methods -- base class provides implementation
    // =================================================================

    // ------------------------------------------------------------------
    // detach -- Reset and disable this queue
    // ------------------------------------------------------------------
    virtual function void detach();
        reset_queue();
        queue_enable = 0;
        state = VQ_RESET;
    endfunction

    // ------------------------------------------------------------------
    // prepare_indirect_table -- validate, allocate, map and populate one
    // standard virtq_desc-format indirect table for a main descriptor.
    // ------------------------------------------------------------------
    protected function bit prepare_indirect_table(
        virtio_sg_list sgs[],
        int unsigned n_out_sgs,
        int unsigned n_in_sgs,
        int unsigned head_id,
        uvm_object token,
        ref bit [63:0] table_iova,
        ref int unsigned table_size
    );
        int unsigned total_sgs;
        int unsigned entry_count;
        int unsigned table_entry;
        bit [63:0] table_gpa;
        indirect_table_record_t record;

        table_iova = 0;
        table_size = 0;
        if (n_out_sgs > (32'hffff_ffff - n_in_sgs)) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d indirect SG count overflow out=%0d in=%0d",
                queue_id, n_out_sgs, n_in_sgs))
            return 0;
        end
        total_sgs = n_out_sgs + n_in_sgs;
        entry_count = 0;

        if (total_sgs == 0 || total_sgs > sgs.size()) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d invalid SG list count=%0d available=%0d",
                queue_id, total_sgs, sgs.size()))
            return 0;
        end

        for (int unsigned s = 0; s < total_sgs; s++) begin
            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                if (sgs[s].entries[e].is_indirect) begin
                    `uvm_error("VQ_INDIRECT", $sformatf(
                        "queue_id=%0d nested indirect descriptor at sg=%0d entry=%0d",
                        queue_id, s, e))
                    return 0;
                end
                if (sgs[s].entries[e].addr >
                        (64'hffff_ffff_ffff_ffff - sgs[s].entries[e].len)) begin
                    `uvm_error("VQ_INDIRECT", $sformatf(
                        "queue_id=%0d invalid indirect SG range at sg=%0d entry=%0d addr=0x%016x len=%0d",
                        queue_id, s, e, sgs[s].entries[e].addr,
                        sgs[s].entries[e].len))
                    return 0;
                end
                if (entry_count == 32'hffff_ffff) begin
                    `uvm_error("VQ_INDIRECT", $sformatf(
                        "queue_id=%0d indirect descriptor count overflow", queue_id))
                    return 0;
                end
                entry_count++;
            end
        end

        if (entry_count == 0 || entry_count > (32'hffff_ffff / 16)) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d invalid indirect descriptor count=%0d",
                queue_id, entry_count))
            return 0;
        end
        table_size = entry_count * 16;
        if (table_size == 0 || (table_size / 16) != entry_count) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d indirect table size overflow", queue_id))
            return 0;
        end

        table_gpa = mem.alloc(table_size, .align(16));
        if (table_gpa == '1 || table_gpa == 0) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d failed to allocate %0d-byte indirect table",
                queue_id, table_size))
            return 0;
        end
        mem.mem_set(table_gpa, 0, table_size);

        table_iova = iommu.map_for_host(host_id, bdf, table_gpa, table_size,
                                        DMA_TO_DEVICE);
        if (table_iova == '1 || table_iova == 0) begin
            `uvm_error("VQ_INDIRECT", $sformatf(
                "queue_id=%0d failed to map indirect table GPA=0x%016x",
                queue_id, table_gpa))
            mem.free(table_gpa);
            table_iova = 0;
            table_size = 0;
            return 0;
        end

        table_entry = 0;
        for (int unsigned s = 0; s < total_sgs; s++) begin
            bit is_write = (s >= n_out_sgs);
            for (int unsigned e = 0; e < sgs[s].entries.size(); e++) begin
                bit [15:0] flags;
                bit [15:0] next;

                flags = is_write ? VIRTQ_DESC_F_WRITE : 16'h0;
                next = 0;
                if (table_entry + 1 < entry_count) begin
                    flags |= VIRTQ_DESC_F_NEXT;
                    next = table_entry + 1;
                end
                write_indirect_desc(table_gpa, table_entry,
                                    sgs[s].entries[e].addr,
                                    sgs[s].entries[e].len,
                                    flags, next);
                table_entry++;
            end
        end

        record.gpa         = table_gpa;
        record.iova        = table_iova;
        record.byte_size   = table_size;
        record.entry_count = entry_count;
        record.token       = token;
        indirect_table_records[head_id] = record;
        return 1;
    endfunction

    // Indirect tables always use the standard (split) virtq_desc layout,
    // including when their owning main descriptor is in a packed ring.
    protected function void write_indirect_desc(
        bit [63:0] table_gpa,
        int unsigned index,
        bit [63:0] addr,
        bit [31:0] len,
        bit [15:0] flags,
        bit [15:0] next
    );
        byte data[16];

        for (int i = 0; i < 8; i++) data[i]    = addr[i * 8 +: 8];
        for (int i = 0; i < 4; i++) data[8 + i] = len[i * 8 +: 8];
        for (int i = 0; i < 2; i++) data[12 + i] = flags[i * 8 +: 8];
        for (int i = 0; i < 2; i++) data[14 + i] = next[i * 8 +: 8];
        mem.write_mem(table_gpa + index * 16, data);
    endfunction

    protected function void release_indirect_table(int unsigned head_id);
        indirect_table_record_t record;

        if (!indirect_table_records.exists(head_id))
            return;

        record = indirect_table_records[head_id];
        if (iommu != null && record.iova != 0)
            iommu.unmap_for_host(host_id, bdf, record.iova);
        if (mem != null && record.gpa != 0)
            mem.free(record.gpa);
        indirect_table_records.delete(head_id);
    endfunction

    protected function void release_all_indirect_tables();
        int unsigned heads[$];

        foreach (indirect_table_records[head_id])
            heads.push_back(head_id);
        foreach (heads[i])
            release_indirect_table(heads[i]);
    endfunction

    // Queue-owned DMA normally borrows its caller's GPA, whereas a migration
    // destination owns the fresh GPA allocated by materialize_migration_mapping().
    // Keep that distinction here so dma_unmap_buf(), detach, and destroy all
    // retire exactly the resources each mapping owns.
    protected function void release_dma_mapping(int unsigned mapping_index);
        iommu_mapping_t mapping;

        mapping = dma_mappings[mapping_index];
        if (iommu != null && mapping.iova != 0)
            iommu.unmap_for_host(mapping.host_id, mapping.bdf, mapping.iova);
        if (migration_owned_dma_iovas.exists(mapping.iova)) begin
            if (mem != null && mapping.gpa != 0)
                mem.free(mapping.gpa);
            migration_owned_dma_iovas.delete(mapping.iova);
        end
        dma_mappings.delete(mapping_index);
    endfunction

    protected function void release_all_dma_mappings();
        while (dma_mappings.size() != 0)
            release_dma_mapping(dma_mappings.size() - 1);
    endfunction

    protected function void discard_staged_migration_ownership();
        staged_migration_dma_mappings.delete();
        staged_indirect_table_records.delete();
    endfunction

    // Save queue-owned request identity separately from the device-visible
    // ring image. A reset destroys the source queue objects, so raw ring bytes
    // alone cannot reconstruct completion tokens or indirect-table ownership.
    protected function void save_migration_ownership(ref virtqueue_snapshot_t snap);
        snap.pending_tokens.delete();
        snap.indirect_tables.delete();
        snap.queue_dma_mappings.delete();
        foreach (token_map[head_id]) begin
            virtqueue_token_snapshot_t token_record;

            token_record.head_id = head_id;
            token_record.token = token_map[head_id];
            snap.pending_tokens.push_back(token_record);
        end
        foreach (indirect_table_records[head_id]) begin
            indirect_table_record_t source_record;
            virtqueue_indirect_snapshot_t snapshot_record;

            source_record = indirect_table_records[head_id];
            snapshot_record.head_id = head_id;
            snapshot_record.mapping.host_id = host_id;
            snapshot_record.mapping.bdf = bdf;
            snapshot_record.mapping.gpa = source_record.gpa;
            snapshot_record.mapping.iova = source_record.iova;
            snapshot_record.mapping.size = source_record.byte_size;
            snapshot_record.mapping.dir = DMA_TO_DEVICE;
            snapshot_record.mapping.desc_id = head_id;
            snapshot_record.byte_size = source_record.byte_size;
            snapshot_record.entry_count = source_record.entry_count;
            snapshot_record.token = source_record.token;
            snap.indirect_tables.push_back(snapshot_record);
        end
        foreach (dma_mappings[i]) begin
            snap.queue_dma_mappings.push_back(dma_mappings[i]);
        end
    endfunction

    // Reattach the destination mapping GPA to the regular queue ownership
    // records. The IOVA remains the saved source value, so ring bytes need no
    // descriptor-format-specific rewriting.
    protected function bit restore_migration_ownership(virtqueue_snapshot_t snap);
        bit token_heads[int unsigned];
        bit indirect_heads[int unsigned];
        bit dma_iovas[bit [63:0]];

        if ((snap.queue_id != queue_id) ||
            (snap.pending_tokens.size() > queue_size) ||
            (snap.indirect_tables.size() > snap.pending_tokens.size())) begin
            `uvm_error("VQ_MIGRATION", $sformatf(
                "restore ownership: invalid snapshot for queue_id=%0d", snap.queue_id))
            return 0;
        end
        if ((token_map.size() != 0) || (indirect_table_records.size() != 0) ||
            (staged_indirect_table_records.size() != 0) ||
            (dma_mappings.size() != 0) ||
            (staged_migration_dma_mappings.size() != 0)) begin
            `uvm_error("VQ_MIGRATION", $sformatf(
                "restore ownership: destination queue_id=%0d is not empty", queue_id))
            return 0;
        end

        // Preflight the complete snapshot before mutating either ownership
        // map. Restore orchestration commits migration DMA only after this
        // function returns success, so a rejected queue must not retain a
        // partial indirect-table claim alongside rollback ownership.
        foreach (snap.pending_tokens[i]) begin
            int unsigned head_id;

            head_id = snap.pending_tokens[i].head_id;
            if ((head_id >= queue_size) || token_heads.exists(head_id)) begin
                `uvm_error("VQ_MIGRATION", $sformatf(
                    "restore ownership: invalid token head=%0d queue_id=%0d",
                    head_id, queue_id))
                return 0;
            end
            token_heads[head_id] = 1;
        end

        foreach (snap.indirect_tables[i]) begin
            virtqueue_indirect_snapshot_t snapshot_record;
            iommu_mapping_t destination_mapping;

            snapshot_record = snap.indirect_tables[i];
            if ((snapshot_record.head_id >= queue_size) ||
                !token_heads.exists(snapshot_record.head_id) ||
                indirect_heads.exists(snapshot_record.head_id) ||
                (snapshot_record.mapping.host_id != host_id) ||
                (snapshot_record.mapping.bdf != bdf) ||
                (snapshot_record.byte_size == 0) ||
                (snapshot_record.entry_count == 0) ||
                (snapshot_record.mapping.size != snapshot_record.byte_size) ||
                (snapshot_record.mapping.dir != DMA_TO_DEVICE) ||
                !iommu.get_live_mapping_for_host(host_id, bdf,
                                        snapshot_record.mapping.iova,
                                        destination_mapping) ||
                (destination_mapping.size != snapshot_record.byte_size) ||
                (destination_mapping.dir != DMA_TO_DEVICE)) begin
                `uvm_error("VQ_MIGRATION", $sformatf(
                    "restore ownership: invalid indirect table head=%0d queue_id=%0d",
                    snapshot_record.head_id, queue_id))
                return 0;
            end
            indirect_heads[snapshot_record.head_id] = 1;
            dma_iovas[snapshot_record.mapping.iova] = 1;
        end

        foreach (snap.queue_dma_mappings[i]) begin
            iommu_mapping_t snapshot_mapping;
            iommu_mapping_t destination_mapping;

            snapshot_mapping = snap.queue_dma_mappings[i];
            if ((snapshot_mapping.host_id != host_id) ||
                (snapshot_mapping.bdf != bdf) ||
                (snapshot_mapping.iova == 0) ||
                (snapshot_mapping.size == 0) ||
                (snapshot_mapping.desc_id != 0) ||
                dma_iovas.exists(snapshot_mapping.iova) ||
                !iommu.get_live_mapping_for_host(host_id, bdf,
                                        snapshot_mapping.iova,
                                        destination_mapping) ||
                (destination_mapping.size != snapshot_mapping.size) ||
                (destination_mapping.dir != snapshot_mapping.dir)) begin
                `uvm_error("VQ_MIGRATION", $sformatf(
                    "restore ownership: invalid queue DMA IOVA=0x%016h queue_id=%0d",
                    snapshot_mapping.iova, queue_id))
                return 0;
            end
            dma_iovas[snapshot_mapping.iova] = 1;
        end

        foreach (snap.pending_tokens[i]) begin
            token_map[snap.pending_tokens[i].head_id] = snap.pending_tokens[i].token;
        end

        foreach (snap.indirect_tables[i]) begin
            virtqueue_indirect_snapshot_t snapshot_record;
            indirect_table_record_t destination_record;
            iommu_mapping_t destination_mapping;

            snapshot_record = snap.indirect_tables[i];
            // This mapping was preflighted above and cannot change during the
            // single-threaded restore transaction.
            void'(iommu.get_live_mapping_for_host(host_id, bdf,
                                         snapshot_record.mapping.iova,
                                         destination_mapping));
            destination_record.gpa = destination_mapping.gpa;
            destination_record.iova = destination_mapping.iova;
            destination_record.byte_size = snapshot_record.byte_size;
            destination_record.entry_count = snapshot_record.entry_count;
            destination_record.token = token_map[snapshot_record.head_id];
            staged_indirect_table_records[snapshot_record.head_id] = destination_record;
        end

        foreach (snap.queue_dma_mappings[i]) begin
            iommu_mapping_t destination_mapping;

            // The complete snapshot was preflighted above.  Retain the
            // recreated GPA, but do not make the queue own it until atomic
            // ops has dropped the matching temporary migration record.
            void'(iommu.get_live_mapping_for_host(host_id, bdf,
                                         snap.queue_dma_mappings[i].iova,
                                         destination_mapping));
            staged_migration_dma_mappings.push_back(destination_mapping);
        end
        return 1;
    endfunction

    // This call has no failure path: restore_migration_ownership() and the
    // atomic-ops claim preflighted the same records, and no task yield occurs
    // between the temporary-list transfer and this queue-local commit.
    function void commit_restored_migration_ownership();
        foreach (staged_indirect_table_records[head_id]) begin
            indirect_table_records[head_id] = staged_indirect_table_records[head_id];
        end
        staged_indirect_table_records.delete();
        foreach (staged_migration_dma_mappings[i]) begin
            dma_mappings.push_back(staged_migration_dma_mappings[i]);
            migration_owned_dma_iovas[
                staged_migration_dma_mappings[i].iova] = 1;
        end
        staged_migration_dma_mappings.delete();
    endfunction

    // ------------------------------------------------------------------
    // dump_ring -- Log queue state summary
    //
    // Logs queue_id, state, size, free/pending counts at UVM_LOW.
    // If desc_table_addr != 0 and mem is valid, dumps first few
    // descriptor table entries via mem.hexdump.
    // ------------------------------------------------------------------
    virtual function void dump_ring();
        int unsigned free_cnt;
        int unsigned pending_cnt;

        free_cnt    = get_free_count();
        pending_cnt = get_pending_count();

        `uvm_info("VQ_DUMP",
            $sformatf({"queue_id=%0d state=%s size=%0d enable=%0b ",
                       "free=%0d pending=%0d ",
                       "desc_addr=0x%016x driver_addr=0x%016x device_addr=0x%016x"},
                      queue_id, state.name(), queue_size, queue_enable,
                      free_cnt, pending_cnt,
                      desc_table_addr, driver_ring_addr, device_ring_addr),
            UVM_LOW)

        if (desc_table_addr != 0 && mem != null) begin
            // Dump first 4 descriptor entries (16 bytes each = 64 bytes)
            `uvm_info("VQ_DUMP",
                $sformatf("Descriptor table hexdump (first 64 bytes at 0x%016x):",
                          desc_table_addr),
                UVM_LOW)
            mem.hexdump(desc_table_addr, 64);
        end
    endfunction

    // ------------------------------------------------------------------
    // leak_check -- Warn about outstanding tokens or DMA mappings
    //
    // Called at test end or queue teardown to detect resource leaks.
    // Warns if token_map has outstanding entries (descriptor leak).
    // Warns if dma_mappings has outstanding entries (DMA mapping leak).
    // ------------------------------------------------------------------
    virtual function void leak_check();
        if (token_map.size() > 0) begin
            `uvm_warning("VQ_LEAK",
                $sformatf("queue_id=%0d: %0d outstanding token(s) in token_map (descriptor leak)",
                          queue_id, token_map.size()))
            foreach (token_map[desc_id]) begin
                `uvm_warning("VQ_LEAK",
                    $sformatf("  desc_id=%0d token=%s",
                              desc_id,
                              (token_map[desc_id] != null) ? token_map[desc_id].get_name() : "null"))
            end
        end

        if (dma_mappings.size() > 0) begin
            `uvm_warning("VQ_LEAK",
                $sformatf("queue_id=%0d: %0d outstanding DMA mapping(s) (DMA mapping leak)",
                          queue_id, dma_mappings.size()))
            foreach (dma_mappings[i]) begin
                `uvm_warning("VQ_LEAK",
                    $sformatf("  [%0d] bdf=0x%04x gpa=0x%016x iova=0x%016x size=%0d dir=%s",
                              i, dma_mappings[i].bdf, dma_mappings[i].gpa,
                              dma_mappings[i].iova, dma_mappings[i].size,
                              dma_mappings[i].dir.name()))
            end
        end

        if (indirect_table_records.size() > 0) begin
            `uvm_warning("VQ_LEAK",
                $sformatf("queue_id=%0d: %0d outstanding indirect table(s)",
                          queue_id, indirect_table_records.size()))
        end

        if (token_map.size() == 0 && dma_mappings.size() == 0 &&
            indirect_table_records.size() == 0) begin
            `uvm_info("VQ_LEAK",
                $sformatf("queue_id=%0d: clean -- no outstanding tokens, DMA mappings, or indirect tables",
                          queue_id),
                UVM_LOW)
        end
    endfunction

    function int unsigned get_indirect_table_count();
        return indirect_table_records.size();
    endfunction

endclass : virtqueue_base

`endif // VIRTQUEUE_BASE_SV
