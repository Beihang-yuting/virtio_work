`ifndef VIRTIO_IOMMU_MODEL_SV
`define VIRTIO_IOMMU_MODEL_SV

// ============================================================================
// virtio_iommu_model
//
// Models IOMMU address translation for DMA operations in the virtio-net VIP.
//
// Provides:
//   - map/unmap of guest physical addresses (GPA) to I/O virtual addresses
//     (IOVA) with a bump allocator
//   - translate() for DMA address resolution with permission and range checks
//   - Fault injection via configurable rules
//   - Use-after-unmap detection
//   - Dirty page tracking (4KB granularity)
//   - Leak checking at test end
//   - Translation statistics
//
// Depends on: virtio_net_types.sv (dma_dir_e, iommu_fault_e,
//             iommu_mapping_entry_t, iommu_fault_rule_t)
// ============================================================================

class virtio_iommu_model extends uvm_object;
    `uvm_object_utils(virtio_iommu_model)

    // ------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------
    localparam bit [63:0] DEFAULT_IOVA_BASE  = 64'h8000_0000;
    localparam bit [63:0] DEFAULT_IOVA_LIMIT = 64'hffff_ffff_ffff_f000;
    localparam int unsigned PAGE_SIZE     = 4096;
    localparam int unsigned PAGE_SHIFT    = 12;

    // ------------------------------------------------------------------
    // Bump allocator state
    // ------------------------------------------------------------------
    protected bit [63:0] next_iova = DEFAULT_IOVA_BASE;
    // IOVA spaces are independent per host/IOMMU requester domain.  Keep the
    // legacy host0 cursor as an alias for compatibility with existing tests.
    protected bit [63:0] next_iova_by_host[int unsigned];

    // ------------------------------------------------------------------
    // Mapping table: keyed by {host_id[31:0], bdf[15:0], iova[63:0]}
    // ------------------------------------------------------------------
    // Mapping identity is {host-id, BDF, IOVA}; equal numeric BDFs and IOVAs
    // are legal when they belong to different host domains.
    protected iommu_mapping_entry_t mapping_table[bit [111:0]];

    // ------------------------------------------------------------------
    // Unmap history for use-after-unmap detection
    // ------------------------------------------------------------------
    protected iommu_mapping_entry_t unmap_history[$];

    // ------------------------------------------------------------------
    // Fault injection rules
    // ------------------------------------------------------------------
    protected iommu_fault_rule_t fault_rules[$];

    // ------------------------------------------------------------------
    // Dirty page tracking
    // ------------------------------------------------------------------
    bit dirty_tracking_enable = 0;
    protected bit dirty_bitmap[int unsigned][bit [63:0]];
    // page ID -> mapping key -> completed device-write snapshot.  A device
    // write is not dirty until its bytes have reached host memory; retaining
    // this full post-write span before completion cleanup protects migration
    // from the following unmap/free pair.
    protected virtio_dirty_page_snapshot_t dirty_page_snapshot[
        int unsigned
    ][bit [63:0]][bit [111:0]];
    protected bit [63:0] dirty_generation_counter = 0;
    protected bit [63:0] active_dirty_generation = 0;
    protected bit [63:0] dirty_generation_counter_by_host[int unsigned];
    protected bit [63:0] active_dirty_generation_by_host[int unsigned];
    protected bit dirty_tracking_enable_by_host[int unsigned];

    // ------------------------------------------------------------------
    // Configuration
    // ------------------------------------------------------------------
    bit strict_permission_check = 1;
    // IOVA is a device-visible address space, independent from Host GPA and
    // BAR apertures.  The default policy deliberately exercises random
    // placement; callers can configure a smaller aperture or FIRST_FIT for
    // reproducible characterization without adding another seed source.
    bit [63:0] iova_base = DEFAULT_IOVA_BASE;
    bit [63:0] iova_limit = DEFAULT_IOVA_LIMIT; // exclusive upper bound
    iommu_iova_alloc_policy_e iova_alloc_policy = IOMMU_IOVA_RANDOM;

    // ------------------------------------------------------------------
    // Statistics
    // ------------------------------------------------------------------
    int unsigned total_maps       = 0;
    int unsigned total_unmaps     = 0;
    int unsigned total_translates = 0;
    int unsigned total_faults     = 0;

    // ------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------
    function new(string name = "virtio_iommu_model");
        super.new(name);
    endfunction

    function bit configure_iova_aperture(
        input bit [63:0] base,
        input bit [63:0] limit,
        input iommu_iova_alloc_policy_e policy,
        output string why
    );
        why = "";
        if (mapping_table.size() != 0) begin
            why = "cannot reconfigure IOVA aperture with live mappings";
            return 0;
        end
        // IOVA 0 is reserved by the public map() return convention (0 means
        // allocation failure) and is also conventionally treated as an
        // invalid DMA address by virtio devices.
        if (base == 0 || (base & (PAGE_SIZE - 1)) != 0 ||
            (limit & (PAGE_SIZE - 1)) != 0 || limit <= base) begin
            why = $sformatf(
                "IOVA aperture must be page aligned and nonempty: [0x%016x,0x%016x)",
                base, limit);
            return 0;
        end
        iova_base = base;
        iova_limit = limit;
        iova_alloc_policy = policy;
        next_iova = base;
        next_iova_by_host.delete();
        return 1;
    endfunction

    function void set_iova_alloc_policy(input iommu_iova_alloc_policy_e policy);
        iova_alloc_policy = policy;
    endfunction

    function iommu_iova_alloc_policy_e get_iova_alloc_policy();
        return iova_alloc_policy;
    endfunction

    protected function bit validate_iova_aperture(output string why);
        why = "";
        if (iova_base == 0 || (iova_base & (PAGE_SIZE - 1)) != 0 ||
            (iova_limit & (PAGE_SIZE - 1)) != 0 ||
            (iova_limit <= iova_base)) begin
            why = $sformatf(
                "IOVA aperture is invalid: [0x%016x,0x%016x)",
                iova_base, iova_limit);
            return 0;
        end
        return 1;
    endfunction

    // ------------------------------------------------------------------
    // map -- Allocate IOVA and create a mapping entry
    //
    // Allocates a page-aligned IOVA region via bump allocator and stores
    // the mapping in the associative array keyed by {host_id, bdf, iova}.
    // Returns the allocated IOVA.
    // ------------------------------------------------------------------
    virtual function bit [63:0] map(bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        return map_in_domain(0, bdf, gpa, size, dir, file, line);
    endfunction

    // Map a GPA in one explicit host/IOMMU requester domain.  Each host owns
    // an independent IOVA namespace, so the returned IOVA may equal an IOVA
    // allocated by another host without aliasing its mapping.
    virtual function bit [63:0] map_for_host(int unsigned host_id,
                            bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        // Preserve factory/test subtypes that override the original host0
        // virtual method.  Nonzero hosts use the explicit domain primitive.
        if (host_id == 0)
            return map(bdf, gpa, size, dir, file, line);
        return map_in_domain(host_id, bdf, gpa, size, dir, file, line);
    endfunction

    protected function bit [63:0] map_in_domain(int unsigned host_id,
                            bit [15:0] bdf,
                            bit [63:0] gpa,
                            int unsigned size,
                            dma_dir_e dir,
                            string file = "",
                            int line = 0);
        bit [63:0] iova;
        bit [111:0] mapping_key;
        iommu_mapping_entry_t entry;
        bit [63:0] aligned_size;
        bit [63:0] allocation_end;
        string allocation_why;

        // Keep the legacy bump allocator subject to the same range and
        // collision rules as map_fixed().  In particular, do not let the
        // 32-bit caller size overflow while it is rounded to a page span.
        if (size == 0) begin
            `uvm_error("IOMMU_MAP", "map: zero-size mapping is invalid")
            return '1;
        end
        if (!validate_iova_aperture(allocation_why)) begin
            `uvm_error("IOMMU_MAP", allocation_why)
            return '1;
        end
        aligned_size = ({32'd0, size} + PAGE_SIZE - 1) / PAGE_SIZE;
        aligned_size = aligned_size * PAGE_SIZE;
        if (!allocate_iova_for_mapping(host_id, bdf, aligned_size,
                                       iova, allocation_why)) begin
            `uvm_error("IOMMU_MAP", $sformatf(
                "map: %s (size=%0d)", allocation_why, size))
            return '1;
        end

        allocation_end = iova + aligned_size;

        set_next_iova(host_id, allocation_end);

        // Build mapping entry
        entry.host_id     = host_id;
        entry.bdf         = bdf;
        entry.gpa         = gpa;
        entry.iova        = iova;
        entry.size        = size;
        entry.dir         = dir;
        entry.valid       = 1;
        entry.map_time    = $realtime;
        entry.caller_file = file;
        entry.caller_line = line;

        // Store in table with 112-bit key: {host_id, bdf, iova}
        mapping_key = make_mapping_key(host_id, bdf, iova);
        mapping_table[mapping_key] = entry;

        total_maps++;

        `uvm_info("IOMMU_MAP",
            $sformatf("host=%0d BDF=0x%04x GPA=0x%016x -> IOVA=0x%016x size=%0d dir=%s [%s:%0d]",
                      host_id, bdf, gpa, iova, size, dir.name(), file, line),
            UVM_HIGH)

        return iova;
    endfunction

    // ------------------------------------------------------------------
    // map_fixed -- Create a mapping at a previously assigned stable IOVA
    //
    // Migration uses this to recreate a retired source mapping without
    // rewriting every possible descriptor format that may retain its IOVA.
    // A fixed range must be page aligned, lie in the model IOVA range, not
    // wrap, and not overlap a live range in the same requester domain.
    // Retired history deliberately does not reserve an IOVA: a restored
    // mapping is allowed to reuse the source address after reset.
    // ------------------------------------------------------------------
    virtual function bit [63:0] map_fixed(bit [15:0] bdf,
                                          bit [63:0] gpa,
                                          int unsigned size,
                                          dma_dir_e dir,
                                          bit [63:0] requested_iova,
                                          string file = "",
                                          int line = 0);
        return map_fixed_in_domain(0, bdf, gpa, size, dir, requested_iova,
                                   file, line);
    endfunction

    virtual function bit [63:0] map_fixed_for_host(int unsigned host_id,
                                          bit [15:0] bdf,
                                          bit [63:0] gpa,
                                          int unsigned size,
                                          dma_dir_e dir,
                                          bit [63:0] requested_iova,
                                          string file = "",
                                          int line = 0);
        if (host_id == 0)
            return map_fixed(bdf, gpa, size, dir, requested_iova, file, line);
        return map_fixed_in_domain(host_id, bdf, gpa, size, dir,
                                   requested_iova, file, line);
    endfunction

    protected function bit [63:0] map_fixed_in_domain(int unsigned host_id,
                                          bit [15:0] bdf,
                                          bit [63:0] gpa,
                                          int unsigned size,
                                          dma_dir_e dir,
                                          bit [63:0] requested_iova,
                                          string file = "",
                                          int line = 0);
        bit [111:0] key;
        iommu_mapping_entry_t entry;
        bit [63:0] aligned_size;
        bit [63:0] requested_end;
        string aperture_why;

        if (size == 0) begin
            `uvm_error("IOMMU_MAP", "map_fixed: zero-size mapping is invalid")
            return '1;
        end
        if (!validate_iova_aperture(aperture_why)) begin
            `uvm_error("IOMMU_MAP", {"map_fixed: ", aperture_why})
            return '1;
        end
        aligned_size = ({32'd0, size} + PAGE_SIZE - 1) / PAGE_SIZE;
        aligned_size = aligned_size * PAGE_SIZE;
        if ((aligned_size > (iova_limit - iova_base)) ||
            (requested_iova < iova_base) ||
            ((requested_iova & (PAGE_SIZE - 1)) != 0) ||
            (requested_iova > (iova_limit - aligned_size))) begin
            `uvm_error("IOMMU_MAP", $sformatf(
                "map_fixed: invalid IOVA range start=0x%016x size=%0d",
                requested_iova, size))
            return '1;
        end
        requested_end = requested_iova + aligned_size;
        foreach (mapping_table[live_key]) begin
            iommu_mapping_entry_t live_entry;
            bit [63:0] live_aligned_size;
            bit [63:0] live_end;

            live_entry = mapping_table[live_key];
            if ((live_entry.host_id != host_id) ||
                (live_entry.bdf != bdf) || !live_entry.valid)
                continue;
            live_aligned_size = ({32'd0, live_entry.size} + PAGE_SIZE - 1) /
                                PAGE_SIZE;
            live_aligned_size = live_aligned_size * PAGE_SIZE;
            live_end = live_entry.iova + live_aligned_size;
            if ((requested_iova < live_end) && (live_entry.iova < requested_end)) begin
                `uvm_error("IOMMU_MAP", $sformatf(
                    "map_fixed: IOVA collision host=%0d BDF=0x%04x requested=[0x%016x..0x%016x) live=[0x%016x..0x%016x)",
                    host_id, bdf, requested_iova, requested_end,
                    live_entry.iova, live_end))
                return '1;
            end
        end

        entry.host_id     = host_id;
        entry.bdf         = bdf;
        entry.gpa         = gpa;
        entry.iova        = requested_iova;
        entry.size        = size;
        entry.dir         = dir;
        entry.valid       = 1;
        entry.map_time    = $realtime;
        entry.caller_file = file;
        entry.caller_line = line;
        key = make_mapping_key(host_id, bdf, requested_iova);
        mapping_table[key] = entry;
        if (requested_end > get_next_iova(host_id))
            set_next_iova(host_id, requested_end);
        total_maps++;

        `uvm_info("IOMMU_MAP", $sformatf(
            "Fixed host=%0d BDF=0x%04x GPA=0x%016x -> IOVA=0x%016x size=%0d dir=%s [%s:%0d]",
            host_id, bdf, gpa, requested_iova, size, dir.name(), file, line), UVM_HIGH)
        return requested_iova;
    endfunction

    // ------------------------------------------------------------------
    // unmap -- Remove a mapping from the table
    //
    // Moves the entry to unmap_history for use-after-unmap detection.
    // Reports an error if the mapping is not found.
    // ------------------------------------------------------------------
    virtual function void unmap(bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        unmap_in_domain(0, bdf, iova, file, line);
    endfunction

    virtual function void unmap_for_host(int unsigned host_id,
                        bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        if (host_id == 0) begin
            unmap(bdf, iova, file, line);
            return;
        end
        unmap_in_domain(host_id, bdf, iova, file, line);
    endfunction

    protected function void unmap_in_domain(int unsigned host_id,
                        bit [15:0] bdf,
                        bit [63:0] iova,
                        string file = "",
                        int line = 0);
        bit [111:0] key;

        key = make_mapping_key(host_id, bdf, iova);

        if (!mapping_table.exists(key)) begin
            `uvm_error("IOMMU_UNMAP",
                $sformatf("Mapping not found: host=%0d BDF=0x%04x IOVA=0x%016x [%s:%0d]",
                          host_id, bdf, iova, file, line))
            return;
        end

        // Save to history before removing
        mapping_table[key].valid = 0;
        unmap_history.push_back(mapping_table[key]);
        mapping_table.delete(key);

        total_unmaps++;

        `uvm_info("IOMMU_UNMAP",
            $sformatf("host=%0d BDF=0x%04x IOVA=0x%016x [%s:%0d]",
                      host_id, bdf, iova, file, line),
            UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // translate -- Resolve IOVA to GPA with full checking
    //
    // Returns 1 on success (gpa set), 0 on fault (fault set).
    // Device-to-guest writes must use write_from_device() so post-write dirty
    // capture cannot be bypassed.  This public API is therefore limited to
    // device reads (DMA_TO_DEVICE); write_from_device() calls the protected
    // translation primitive below after it has committed to the write path.
    //
    // Check order for allowed translations: fault injection -> mapping lookup
    // -> use-after-unmap -> range check -> permission check -> compute GPA.
    //   -> range check -> permission check -> compute GPA.
    // ------------------------------------------------------------------
    function bit translate(bit [15:0] bdf,
                           bit [63:0] iova,
                           int unsigned size,
                           dma_dir_e access_dir,
                           ref bit [63:0] gpa,
                           ref iommu_fault_e fault);
        return translate_for_host(0, bdf, iova, size, access_dir, gpa, fault);
    endfunction

    function bit translate_for_host(int unsigned host_id,
                           bit [15:0] bdf,
                           bit [63:0] iova,
                           int unsigned size,
                           dma_dir_e access_dir,
                           ref bit [63:0] gpa,
                           ref iommu_fault_e fault);
        if ((access_dir == DMA_FROM_DEVICE) ||
            (access_dir == DMA_BIDIRECTIONAL)) begin
            total_translates++;
            total_faults++;
            fault = IOMMU_FAULT_PERMISSION;
            `uvm_error("IOMMU_DMA_WRITE", $sformatf(
                "translate: DMA write translation is forbidden; use write_from_device() (host=%0d BDF=0x%04x IOVA=0x%016x)",
                host_id, bdf, iova))
            return 0;
        end
        return translate_internal(host_id, bdf, iova, size, access_dir,
                                  gpa, fault);
    endfunction

    // Validate a device-to-Host access without mutating Host memory.  The
    // normal translate_for_host() API intentionally rejects FROM_DEVICE so
    // callers cannot bypass write_from_device() dirty tracking.  PCIe-TL
    // responders need the same permission/range check before issuing an EP
    // Memory Write; the PCIe RC backend performs the actual write after this
    // preflight succeeds.
    function bit validate_for_host(int unsigned host_id,
                           bit [15:0] bdf,
                           bit [63:0] iova,
                           int unsigned size,
                           dma_dir_e access_dir,
                           ref bit [63:0] gpa,
                           ref iommu_fault_e fault);
        return translate_internal(host_id, bdf, iova, size, access_dir,
                                  gpa, fault);
    endfunction

    // write_from_device() is the sole device-write boundary.  Keeping this
    // primitive protected prevents callers from translating a writable DMA
    // range and updating host memory without producing a dirty record.
    protected function bit translate_internal(int unsigned host_id,
                                              bit [15:0] bdf,
                                              bit [63:0] iova,
                                              int unsigned size,
                                              dma_dir_e access_dir,
                                              ref bit [63:0] gpa,
                                              ref iommu_fault_e fault);
        bit [111:0] key;
        iommu_mapping_entry_t entry;

        total_translates++;
        fault = IOMMU_NO_FAULT;

        // 1. Check fault injection rules first
        if (check_fault_rules(host_id, bdf, iova, access_dir, fault)) begin
            total_faults++;
            `uvm_info("IOMMU_FAULT_INJ",
                $sformatf("Injected fault %s: host=%0d BDF=0x%04x IOVA=0x%016x dir=%s",
                          fault.name(), host_id, bdf, iova, access_dir.name()),
                UVM_MEDIUM)
            return 0;
        end

        // 2. Find a live mapping before considering retired history.  A
        // fixed restore mapping is allowed to reuse a source IOVA that was
        // intentionally placed in unmap_history by the prior reset.
        key = find_mapping_for_iova(host_id, bdf, iova);
        if (key == '1) begin
            if (check_use_after_unmap(host_id, bdf, iova)) begin
                fault = IOMMU_FAULT_UNMAPPED;
                total_faults++;
                return 0;
            end
            fault = IOMMU_FAULT_UNMAPPED;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("No mapping found: host=%0d BDF=0x%04x IOVA=0x%016x size=%0d",
                          host_id, bdf, iova, size),
                UVM_MEDIUM)
            return 0;
        end

        entry = mapping_table[key];

        // 3. Range check: (iova + size) <= (entry.iova + entry.size).
        // Check the addition before evaluating it: a 64-bit wrap could turn
        // an out-of-range request into a numerically small end address.
        if ((size != 0) &&
            (iova > (64'hffff_ffff_ffff_ffff - size))) begin
            fault = IOMMU_FAULT_OUT_OF_RANGE;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("Out of range: IOVA end wraps 64-bit space (host=%0d BDF=0x%04x IOVA=0x%016x+%0d)",
                          host_id, bdf, iova, size), UVM_MEDIUM)
            return 0;
        end
        if ((iova + size) > (entry.iova + entry.size)) begin
            fault = IOMMU_FAULT_OUT_OF_RANGE;
            total_faults++;
            `uvm_info("IOMMU_FAULT",
                $sformatf("Out of range: BDF=0x%04x IOVA=0x%016x+%0d exceeds mapping [0x%016x..0x%016x)",
                          bdf, iova, size, entry.iova, entry.iova + entry.size),
                UVM_MEDIUM)
            return 0;
        end

        // 4. Permission check
        if (strict_permission_check) begin
            if (!check_permission(entry.dir, access_dir)) begin
                fault = IOMMU_FAULT_PERMISSION;
                total_faults++;
                `uvm_info("IOMMU_FAULT",
                    $sformatf("Permission denied: BDF=0x%04x IOVA=0x%016x mapped=%s access=%s",
                              bdf, iova, entry.dir.name(), access_dir.name()),
                    UVM_MEDIUM)
                return 0;
            end
        end

        // 5. Compute GPA
        gpa = entry.gpa + (iova - entry.iova);

        return 1;
    endfunction

    // ------------------------------------------------------------------
    // Fault injection
    // ------------------------------------------------------------------

    // Add a fault injection rule. First matching rule wins during translate.
    function void add_fault_rule(iommu_fault_rule_t rule);
        fault_rules.push_back(rule);
        `uvm_info("IOMMU_FAULT_RULE",
            $sformatf("Added rule: host=%s bdf_mask=0x%04x iova=[0x%016x..0x%016x] dir=%s fault=%s count=%0d",
                      (rule.host_id_valid === 1'b1) ?
                          $sformatf("%0d", rule.host_id) : "*",
                      rule.bdf_mask, rule.iova_start, rule.iova_end,
                      rule.dir.name(), rule.fault_type.name(), rule.trigger_count),
            UVM_HIGH)
    endfunction

    // Clear all fault injection rules.
    function void clear_fault_rules();
        fault_rules.delete();
        `uvm_info("IOMMU_FAULT_RULE", "All fault rules cleared", UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // check_fault_rules -- Check if any fault rule matches
    //
    // Returns 1 if a matching active rule is found (fault is set).
    // First matching rule wins. Rules with trigger_count > 0 are
    // exhausted after triggered >= trigger_count.
    // ------------------------------------------------------------------
    protected function bit check_fault_rules(int unsigned host_id,
                                             bit [15:0] bdf,
                                             bit [63:0] iova,
                                             dma_dir_e access_dir,
                                             ref iommu_fault_e fault);
        for (int i = 0; i < fault_rules.size(); i++) begin
            iommu_fault_rule_t rule = fault_rules[i];

            // Skip exhausted rules
            if (rule.trigger_count > 0 && rule.triggered >= rule.trigger_count)
                continue;

            // host_id_valid=0 is a compatibility wildcard; a valid host ID
            // scopes the fault rule to one requester domain.
            if ((rule.host_id_valid === 1'b1) &&
                (rule.host_id != host_id))
                continue;

            // BDF match: 0xFFFF = wildcard, otherwise exact match
            if (rule.bdf_mask != 16'hFFFF && rule.bdf_mask != bdf)
                continue;

            // IOVA range match
            if (iova < rule.iova_start || iova > rule.iova_end)
                continue;

            // Direction match
            if (rule.dir != DMA_BIDIRECTIONAL && rule.dir != access_dir)
                continue;

            // Rule matches -- increment triggered count
            fault_rules[i].triggered++;
            fault = rule.fault_type;
            return 1;
        end

        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Use-after-unmap detection
    // ------------------------------------------------------------------

    // Check if the given IOVA was previously unmapped. Logs uvm_error
    // if a matching entry is found in unmap_history.
    function bit check_use_after_unmap(int unsigned host_id,
                                       bit [15:0] bdf,
                                       bit [63:0] iova);
        foreach (unmap_history[i]) begin
            if (unmap_history[i].host_id == host_id &&
                unmap_history[i].bdf == bdf &&
                iova >= unmap_history[i].iova &&
                iova < (unmap_history[i].iova + unmap_history[i].size)) begin
                `uvm_error("IOMMU_USE_AFTER_UNMAP",
                    $sformatf("Access to unmapped IOVA: host=%0d BDF=0x%04x IOVA=0x%016x was mapped at [%s:%0d]",
                              host_id, bdf, iova, unmap_history[i].caller_file, unmap_history[i].caller_line))
                return 1;
            end
        end
        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Dirty page tracking
    // ------------------------------------------------------------------

    // Start a fresh migration generation.  The bitmap is discarded before
    // tracking is enabled, so a subsequent capture can contain only writes
    // performed after this call.
    function bit [63:0] begin_dirty_generation();
        return begin_dirty_generation_for_host(0);
    endfunction

    function bit [63:0] begin_dirty_generation_for_host(
        int unsigned host_id
    );
        bit [63:0] next_generation;

        next_generation = get_dirty_generation_counter(host_id) + 1;
        // Generation zero is reserved as the uninitialized snapshot value.
        if (next_generation == 0)
            next_generation = 1;
        set_dirty_generation_counter(host_id, next_generation);
        active_dirty_generation_by_host[host_id] = next_generation;
        if (host_id == 0)
            active_dirty_generation = next_generation;
        if (dirty_bitmap.exists(host_id))
            dirty_bitmap[host_id].delete();
        if (dirty_page_snapshot.exists(host_id))
            dirty_page_snapshot[host_id].delete();
        set_dirty_tracking_enable(host_id, 1);
        return next_generation;
    endfunction

    // Atomically return the dirty set belonging to the active generation and
    // stop collecting it.  SystemVerilog functions execute without advancing
    // simulation time, so a writer cannot interleave with the copy/clear.
    function void capture_dirty_generation(ref bit [63:0] dirty_pages[$]);
        capture_dirty_generation_for_host(0, dirty_pages);
    endfunction

    function void capture_dirty_generation_for_host(
        int unsigned host_id, ref bit [63:0] dirty_pages[$]
    );
        dirty_pages.delete();
        if (!get_dirty_tracking_enable(host_id))
            return;
        foreach (dirty_bitmap[host_id][page]) begin
            dirty_pages.push_back(page);
        end
        if (dirty_bitmap.exists(host_id))
            dirty_bitmap[host_id].delete();
        set_dirty_tracking_enable(host_id, 0);
    endfunction

    // Snapshot every live mapping belonging to one requester.  Dirty-page
    // tracking intentionally records only completed device writes; migration
    // also needs the complete bytes of clean live mappings still reachable
    // from raw queue state, such as outstanding TX or indirect descriptors.
    // Copy them while the source allocation is known to be live.
    function bit snapshot_live_mappings(
        host_mem_manager mem,
        bit [15:0] bdf,
        ref virtio_mapping_snapshot_t records[$]
    );
        return snapshot_live_mappings_for_host(0, mem, bdf, records);
    endfunction

    function bit snapshot_live_mappings_for_host(
        int unsigned host_id,
        host_mem_manager mem,
        bit [15:0] bdf,
        ref virtio_mapping_snapshot_t records[$]
    );
        records.delete();
        if (mem == null) begin
            `uvm_error("IOMMU_MIGRATION",
                "snapshot_live_mappings: missing host memory")
            return 0;
        end
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            virtio_mapping_snapshot_t record;

            entry = mapping_table[key];
            if (!entry.valid || (entry.host_id != host_id) ||
                (entry.bdf != bdf))
                continue;
            if (entry.size == 0) begin
                records.delete();
                `uvm_error("IOMMU_MIGRATION", $sformatf(
                    "snapshot_live_mappings: zero-size mapping BDF=0x%04x IOVA=0x%016h",
                    bdf, entry.iova))
                return 0;
            end
            record.mapping.host_id = entry.host_id;
            record.mapping.bdf = entry.bdf;
            record.mapping.gpa = entry.gpa;
            record.mapping.iova = entry.iova;
            record.mapping.size = entry.size;
            record.mapping.dir = entry.dir;
            record.mapping.desc_id = 0;
            record.checksum = '0;
            mem.read_mem(entry.gpa, entry.size, record.payload);
            if (record.payload.size() != entry.size) begin
                records.delete();
                `uvm_error("IOMMU_MIGRATION", $sformatf(
                    "snapshot_live_mappings: unable to capture %0d bytes at GPA=0x%016h",
                    entry.size, entry.gpa))
                return 0;
            end
            records.push_back(record);
        end
        return 1;
    endfunction

    // The one production boundary for a device-to-guest DMA write.  A caller
    // must use this instead of translate()+host_mem.write_mem(): translation
    // alone happens before the write and cannot preserve bytes once a
    // completion unmaps and frees the buffer.  The completed mapping span is
    // copied while it remains allocated, then normal cleanup may proceed.
    function bit write_from_device(
        host_mem_manager mem,
        bit [15:0] bdf,
        bit [63:0] iova,
        byte data[],
        ref iommu_fault_e fault
    );
        return write_from_device_for_host(0, mem, bdf, iova, data, fault);
    endfunction

    function bit write_from_device_for_host(
        int unsigned host_id,
        host_mem_manager mem,
        bit [15:0] bdf,
        bit [63:0] iova,
        byte data[],
        ref iommu_fault_e fault
    );
        bit [63:0] gpa;
        bit [111:0] mapping_key;
        iommu_mapping_entry_t mapping_entry;

        fault = IOMMU_NO_FAULT;
        if (mem == null) begin
            `uvm_error("IOMMU_DIRTY", "write_from_device: missing host memory")
            return 0;
        end
        if (data.size() == 0)
            return 1;
        if (!translate_internal(host_id, bdf, iova, data.size(), DMA_FROM_DEVICE,
                                gpa, fault))
            return 0;

        // write_mem performs the actual guest-memory mutation before dirty
        // capture.  The mapping remains live until this function returns.
        mem.write_mem(gpa, data);
        if (!get_dirty_tracking_enable(host_id))
            return 1;
        mapping_key = find_mapping_for_iova(host_id, bdf, iova);
        if (mapping_key == '1) begin
            `uvm_error("IOMMU_DIRTY",
                "write_from_device: successful translation lost its mapping")
            return 0;
        end
        mapping_entry = mapping_table[mapping_key];
        snapshot_completed_dma_write(mem, gpa, data.size(), mapping_key,
                                     mapping_entry);
        return 1;
    endfunction

    // Capture every exact mapping/page intersection touched by a completed
    // device write.  A subsequent write to the same mapping updates the
    // stored span with the latest post-write host-memory contents.
    protected function void snapshot_completed_dma_write(
        host_mem_manager mem,
        bit [63:0] write_gpa,
        int unsigned write_size,
        bit [111:0] mapping_key,
        iommu_mapping_entry_t mapping_entry
    );
        bit [63:0] page_start;
        bit [63:0] page_end;
        iommu_mapping_t mapping;

        if (!get_dirty_tracking_enable(mapping_entry.host_id) ||
            (write_size == 0))
            return;
        page_start = write_gpa >> PAGE_SHIFT;
        page_end   = (write_gpa + write_size - 1) >> PAGE_SHIFT;
        mapping = '{default: 0};
        mapping.host_id = mapping_entry.host_id;
        mapping.bdf = mapping_entry.bdf;
        mapping.gpa = mapping_entry.gpa;
        mapping.iova = mapping_entry.iova;
        mapping.size = mapping_entry.size;
        mapping.dir = mapping_entry.dir;

        for (bit [63:0] p = page_start; ; p++) begin
            virtio_dirty_page_snapshot_t record;
            bit [63:0] page_base;
            bit [63:0] page_end_gpa;
            bit [63:0] mapping_end;
            bit [63:0] span_end;

            page_base = p << PAGE_SHIFT;
            page_end_gpa = page_base + PAGE_SIZE;
            mapping_end = mapping.gpa + mapping.size;
            record.page_id = p;
            record.mapping = mapping;
            record.mapped_gpa = (mapping.gpa > page_base) ?
                                mapping.gpa : page_base;
            span_end = (mapping_end < page_end_gpa) ? mapping_end : page_end_gpa;
            if (span_end <= record.mapped_gpa) begin
                `uvm_error("IOMMU_DIRTY", $sformatf(
                    "write_from_device: empty mapping span for dirty page 0x%016h", p))
                return;
            end
            record.mapped_size = span_end - record.mapped_gpa;
            mem.read_mem(record.mapped_gpa, record.mapped_size, record.payload);
            if (record.payload.size() != record.mapped_size) begin
                `uvm_error("IOMMU_DIRTY", $sformatf(
                    "write_from_device: unable to snapshot %0d bytes at 0x%016h",
                    record.mapped_size, record.mapped_gpa))
                return;
            end
            dirty_bitmap[mapping_entry.host_id][p] = 1;
            dirty_page_snapshot[mapping_entry.host_id][p][mapping_key] = record;
            if (p == page_end)
                break;
        end
    endfunction

    // Backwards-compatible legacy helper.  New migration code must use the
    // explicit begin/capture generation pair above.
    function void get_and_clear_dirty(ref bit [63:0] dirty_pages[$]);
        dirty_pages.delete();
        foreach (dirty_bitmap[0][page]) begin
            dirty_pages.push_back(page);
        end
        if (dirty_bitmap.exists(0))
            dirty_bitmap[0].delete();
    endfunction

    // Return the mapping identity that covered a captured page.  A dirty page
    // may be produced by a sub-page mapping, so overlap (not full-page
    // coverage) identifies the mapping that observed the write.
    function bit get_dirty_page_mapping(
        bit [63:0] page_id, ref iommu_mapping_t mapping
    );
        return get_dirty_page_mapping_for_host(0, page_id, mapping);
    endfunction

    function bit get_dirty_page_mapping_for_host(
        int unsigned host_id,
        bit [63:0] page_id, ref iommu_mapping_t mapping
    );
        bit [63:0] page_base;
        bit [63:0] page_end;

        mapping = '{default: 0};
        page_base = page_id << PAGE_SHIFT;
        page_end = page_base + PAGE_SIZE;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            entry = mapping_table[key];
            if (entry.valid && (entry.host_id == host_id) &&
                (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                mapping.host_id = entry.host_id;
                mapping.bdf = entry.bdf;
                mapping.gpa = entry.gpa;
                mapping.iova = entry.iova;
                mapping.size = entry.size;
                mapping.dir = entry.dir;
                mapping.desc_id = 0;
                return 1;
            end
        end
        return 0;
    endfunction

    // Return completed dirty records, including the exact post-write payload
    // captured while the mapping/allocation was still live.
    function void get_dirty_page_records(
        bit [63:0] page_id, ref virtio_dirty_page_snapshot_t records[$]
    );
        get_dirty_page_records_for_host(0, page_id, records);
    endfunction

    function void get_dirty_page_records_for_host(
        int unsigned host_id,
        bit [63:0] page_id, ref virtio_dirty_page_snapshot_t records[$]
    );
        records.delete();
        if (!dirty_page_snapshot.exists(host_id) ||
            !dirty_page_snapshot[host_id].exists(page_id))
            return;
        foreach (dirty_page_snapshot[host_id][page_id][key]) begin
            records.push_back(dirty_page_snapshot[host_id][page_id][key]);
        end
    endfunction

    // Compatibility projection for callers that need only identities.
    function void get_dirty_page_mappings(
        bit [63:0] page_id, ref iommu_mapping_t mappings[$]
    );
        get_dirty_page_mappings_for_host(0, page_id, mappings);
    endfunction

    function void get_dirty_page_mappings_for_host(
        int unsigned host_id,
        bit [63:0] page_id, ref iommu_mapping_t mappings[$]
    );
        mappings.delete();
        if (!dirty_page_snapshot.exists(host_id) ||
            !dirty_page_snapshot[host_id].exists(page_id))
            return;
        foreach (dirty_page_snapshot[host_id][page_id][key]) begin
            mappings.push_back(
                dirty_page_snapshot[host_id][page_id][key].mapping);
        end
    endfunction

    // Confirm that a complete mapping snapshot still names one exact live
    // mapping, or one exact mapping retired since freeze.  Retired backing
    // memory is never dereferenced; the snapshot itself owns those bytes.
    function bit verify_mapping_identity(
        iommu_mapping_t expected, output bit retired
    );
        retired = 0;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;

            entry = mapping_table[key];
            if (entry.valid && (entry.host_id == expected.host_id) &&
                (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir)) begin
                return 1;
            end
        end
        foreach (unmap_history[i]) begin
            iommu_mapping_entry_t entry;

            entry = unmap_history[i];
            if ((entry.host_id == expected.host_id) &&
                (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir)) begin
                retired = 1;
                return 1;
            end
        end
        return 0;
    endfunction

    // Return one exact live mapping after migration has recreated a stable
    // source IOVA. Queue ownership restoration uses the destination GPA while
    // retaining the descriptor-visible IOVA from the snapshot.
    function bit get_live_mapping(bit [15:0] bdf, bit [63:0] iova,
                                  ref iommu_mapping_t mapping);
        return get_live_mapping_for_host(0, bdf, iova, mapping);
    endfunction

    function bit get_live_mapping_for_host(int unsigned host_id,
                                  bit [15:0] bdf, bit [63:0] iova,
                                  ref iommu_mapping_t mapping);
        bit [111:0] key;

        mapping = '{default: 0};
        key = make_mapping_key(host_id, bdf, iova);
        if (!mapping_table.exists(key) || !mapping_table[key].valid)
            return 0;
        mapping.host_id = mapping_table[key].host_id;
        mapping.bdf = mapping_table[key].bdf;
        mapping.gpa = mapping_table[key].gpa;
        mapping.iova = mapping_table[key].iova;
        mapping.size = mapping_table[key].size;
        mapping.dir = mapping_table[key].dir;
        mapping.desc_id = 0;
        return 1;
    endfunction

    // Confirm that a saved page is backed by the exact live mapping, or by an
    // exact mapping retired into unmap_history after freeze.  A caller may use
    // a retired identity only after it has validated snapshot-owned payload;
    // it must never dereference the retired host allocation.
    function bit verify_dirty_page_mapping(
        bit [63:0] page_id, iommu_mapping_t expected, output bit retired
    );
        bit [63:0] page_base;
        bit [63:0] page_end;

        retired = 0;
        page_base = page_id << PAGE_SHIFT;
        page_end = page_base + PAGE_SIZE;
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t entry;
            entry = mapping_table[key];
            if (entry.valid && (entry.host_id == expected.host_id) &&
                (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir) &&
                (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                return 1;
            end
        end
        foreach (unmap_history[i]) begin
            iommu_mapping_entry_t entry;

            entry = unmap_history[i];
            if ((entry.host_id == expected.host_id) &&
                (entry.bdf == expected.bdf) &&
                (entry.gpa == expected.gpa) &&
                (entry.iova == expected.iova) &&
                (entry.size == expected.size) &&
                (entry.dir == expected.dir) &&
                (entry.gpa < page_end) &&
                ((entry.gpa + entry.size) > page_base)) begin
                retired = 1;
                return 1;
            end
        end
        return 0;
    endfunction

    // ------------------------------------------------------------------
    // Leak check -- warn about outstanding mappings at test end
    // ------------------------------------------------------------------
    function void leak_check();
        if (mapping_table.size() == 0) begin
            `uvm_info("IOMMU_LEAK", "No outstanding mappings -- clean shutdown", UVM_LOW)
            return;
        end

        `uvm_warning("IOMMU_LEAK",
            $sformatf("%0d outstanding mapping(s) at test end:", mapping_table.size()))

        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t e = mapping_table[key];
            `uvm_warning("IOMMU_LEAK",
                    $sformatf("  host=%0d BDF=0x%04x IOVA=0x%016x GPA=0x%016x size=%0d dir=%s [%s:%0d]",
                          e.host_id, e.bdf, e.iova, e.gpa, e.size, e.dir.name(),
                          e.caller_file, e.caller_line))
        end
    endfunction

    // ------------------------------------------------------------------
    // find_mapping_for_iova -- Helper to find a mapping covering iova
    //
    // Iterates mapping_table to find an entry whose [iova, iova+size)
    // range covers the requested IOVA. Returns the 112-bit key if found,
    // '1 (all-ones) if not found.
    // ------------------------------------------------------------------
    protected function bit [111:0] find_mapping_for_iova(
        int unsigned host_id, bit [15:0] bdf, bit [63:0] iova);
        foreach (mapping_table[key]) begin
            iommu_mapping_entry_t e = mapping_table[key];
            if (e.host_id == host_id && e.bdf == bdf &&
                e.valid &&
                iova >= e.iova &&
                iova < (e.iova + e.size)) begin
                return key;
            end
        end
        return '1;
    endfunction

    // ------------------------------------------------------------------
    // check_permission -- Verify DMA direction compatibility
    //
    // DMA_BIDIRECTIONAL allows both read and write.
    // DMA_TO_DEVICE mapping cannot be read as DMA_FROM_DEVICE.
    // DMA_FROM_DEVICE mapping cannot be written as DMA_TO_DEVICE.
    // ------------------------------------------------------------------
    protected function bit check_permission(dma_dir_e mapped_dir,
                                            dma_dir_e access_dir);
        if (mapped_dir == DMA_BIDIRECTIONAL || access_dir == DMA_BIDIRECTIONAL)
            return 1;
        return (mapped_dir == access_dir);
    endfunction

    protected function bit [111:0] make_mapping_key(
        int unsigned host_id, bit [15:0] bdf, bit [63:0] iova
    );
        return {host_id[31:0], bdf, iova};
    endfunction

    protected function bit [63:0] random_u64();
        return {$urandom(), $urandom()};
    endfunction

    protected function bit [63:0] random_bounded_u64(
        input bit [63:0] upper_exclusive
    );
        bit [63:0] candidate;
        bit [63:0] cutoff;
        bit [63:0] max_value;

        if (upper_exclusive <= 1)
            return '0;
        max_value = {64{1'b1}};
        cutoff = (max_value / upper_exclusive) * upper_exclusive;
        do candidate = random_u64();
        while (candidate >= cutoff);
        return candidate % upper_exclusive;
    endfunction

    protected function bit iova_range_available(
        input int unsigned host_id,
        input bit [15:0] bdf,
        input bit [63:0] start,
        input bit [63:0] size
    );
        bit [63:0] end_addr;

        if (size == 0 || start < iova_base ||
            start > (iova_limit - size))
            return 0;
        end_addr = start + size;
        foreach (mapping_table[live_key]) begin
            iommu_mapping_entry_t live_entry;
            bit [63:0] live_size;
            bit [63:0] live_end;

            live_entry = mapping_table[live_key];
            if ((live_entry.host_id != host_id) ||
                (live_entry.bdf != bdf) || !live_entry.valid)
                continue;
            live_size = ({32'd0, live_entry.size} + PAGE_SIZE - 1) /
                        PAGE_SIZE;
            live_size = live_size * PAGE_SIZE;
            live_end = live_entry.iova + live_size;
            if ((start < live_end) && (live_entry.iova < end_addr))
                return 0;
        end
        return 1;
    endfunction

    protected function bit allocate_iova_for_mapping(
        input int unsigned host_id,
        input bit [15:0] bdf,
        input bit [63:0] aligned_size,
        output bit [63:0] allocated_iova,
        output string why
    );
        bit [63:0] span;
        bit [63:0] slot_count;
        bit [63:0] max_start;
        bit [63:0] candidate;
        bit [63:0] candidate_end;
        bit [63:0] next_candidate;

        allocated_iova = '1;
        why = "";
        if (aligned_size == 0 || iova_limit <= iova_base ||
            aligned_size > (iova_limit - iova_base)) begin
            why = $sformatf(
                "IOVA aperture cannot fit aligned mapping size %0d", aligned_size);
            return 0;
        end
        span = iova_limit - iova_base;
        max_start = iova_limit - aligned_size;

        if (iova_alloc_policy == IOMMU_IOVA_RANDOM) begin
            slot_count = ((span - aligned_size) / PAGE_SIZE) + 1;
            for (int attempt = 0; attempt < 64; attempt++) begin
                candidate = iova_base +
                    random_bounded_u64(slot_count) * PAGE_SIZE;
                if (iova_range_available(host_id, bdf, candidate,
                                         aligned_size)) begin
                    allocated_iova = candidate;
                    return 1;
                end
            end
        end

        // Deterministic fallback also handles a nearly full randomized
        // aperture without probabilistic allocation failure.
        candidate = iova_base;
        while (candidate <= max_start) begin
            if (iova_range_available(host_id, bdf, candidate, aligned_size)) begin
                allocated_iova = candidate;
                return 1;
            end
            // Avoid wrapping a 64-bit page cursor when the aperture reaches
            // the top of the IOVA address space.  The last aligned candidate
            // has been checked, so no successor exists in the aperture.
            if (candidate >= max_start)
                break;
            candidate_end = candidate + aligned_size;
            next_candidate = candidate + PAGE_SIZE;
            foreach (mapping_table[live_key]) begin
                iommu_mapping_entry_t live_entry;
                bit [63:0] live_size;
                bit [63:0] live_end;

                live_entry = mapping_table[live_key];
                if ((live_entry.host_id != host_id) ||
                    (live_entry.bdf != bdf) || !live_entry.valid)
                    continue;
                live_size = ({32'd0, live_entry.size} + PAGE_SIZE - 1) /
                            PAGE_SIZE;
                live_size = live_size * PAGE_SIZE;
                live_end = live_entry.iova + live_size;
                if ((candidate < live_end) &&
                    (live_entry.iova < candidate_end) &&
                    (live_end > next_candidate))
                    next_candidate = live_end;
            end
            if (next_candidate <= candidate)
                break;
            candidate = next_candidate;
            if ((candidate & (PAGE_SIZE - 1)) != 0)
                candidate = ((candidate + PAGE_SIZE - 1) / PAGE_SIZE) * PAGE_SIZE;
        end
        why = $sformatf(
            "IOVA aperture exhausted for host=%0d BDF=0x%04x size=%0d",
            host_id, bdf, aligned_size);
        return 0;
    endfunction

    protected function bit [63:0] get_next_iova(int unsigned host_id);
        if (host_id == 0)
            return next_iova;
        if (!next_iova_by_host.exists(host_id))
            return iova_base;
        return next_iova_by_host[host_id];
    endfunction

    protected function void set_next_iova(
        int unsigned host_id, bit [63:0] value
    );
        if (host_id == 0)
            next_iova = value;
        next_iova_by_host[host_id] = value;
    endfunction

    protected function bit [63:0] get_dirty_generation_counter(
        int unsigned host_id
    );
        if (host_id == 0)
            return dirty_generation_counter;
        if (!dirty_generation_counter_by_host.exists(host_id))
            return 0;
        return dirty_generation_counter_by_host[host_id];
    endfunction

    protected function void set_dirty_generation_counter(
        int unsigned host_id, bit [63:0] value
    );
        if (host_id == 0)
            dirty_generation_counter = value;
        dirty_generation_counter_by_host[host_id] = value;
    endfunction

    protected function bit get_dirty_tracking_enable(int unsigned host_id);
        if (host_id == 0)
            return dirty_tracking_enable;
        return dirty_tracking_enable_by_host.exists(host_id) &&
               dirty_tracking_enable_by_host[host_id];
    endfunction

    protected function void set_dirty_tracking_enable(
        int unsigned host_id, bit enable
    );
        if (host_id == 0)
            dirty_tracking_enable = enable;
        dirty_tracking_enable_by_host[host_id] = enable;
    endfunction

    // ------------------------------------------------------------------
    // reset -- Clear all state (for device reset)
    // ------------------------------------------------------------------
    function void reset();
        mapping_table.delete();
        unmap_history.delete();
        fault_rules.delete();
        dirty_bitmap.delete();
        dirty_page_snapshot.delete();
        dirty_tracking_enable = 0;
        dirty_generation_counter = 0;
        active_dirty_generation = 0;
        dirty_generation_counter_by_host.delete();
        active_dirty_generation_by_host.delete();
        dirty_tracking_enable_by_host.delete();
        next_iova_by_host.delete();
        next_iova          = iova_base;
        total_maps         = 0;
        total_unmaps       = 0;
        total_translates   = 0;
        total_faults       = 0;
        `uvm_info("IOMMU_RESET", "IOMMU model reset", UVM_HIGH)
    endfunction

    // ------------------------------------------------------------------
    // print_stats -- Display summary statistics
    // ------------------------------------------------------------------
    function void print_stats();
        `uvm_info("IOMMU_STATS",
            $sformatf("Maps=%0d Unmaps=%0d Translates=%0d Faults=%0d Active=%0d History=%0d",
                      total_maps, total_unmaps, total_translates, total_faults,
                      mapping_table.size(), unmap_history.size()),
            UVM_LOW)
    endfunction

endclass : virtio_iommu_model

`endif // VIRTIO_IOMMU_MODEL_SV
