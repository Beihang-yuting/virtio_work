`ifndef VIRTIO_PF_MANAGER_SV
`define VIRTIO_PF_MANAGER_SV

// ============================================================================
// virtio_pf_manager
//
// Simplified PF manager that delegates SR-IOV PCIe mechanics (BDF
// calculation, config space, BAR, VF enable/disable) to pcie_tl_vip's
// pcie_tl_func_manager. This class manages only virtio-specific concerns:
//   - Queue resource mapping (via virtio_vf_resource_pool)
//   - VF instance lifecycle (via virtio_vf_instance references)
//   - Failover coordination (via virtio_failover_manager)
//   - Admin VQ placeholder (virtio 1.2+)
//
// The pcie_tl_func_manager reference is stored as uvm_object and $cast
// at runtime to avoid compile-time package dependency. This keeps the
// virtio package independent of the PCIe TL package.
//
// pcie_tl_func_manager provides:
//   - pf_ctx[] / vf_ctx[][]: per-function contexts (bdf, cfg_mgr, bar_base[])
//   - sriov_caps[]: SR-IOV Capability per PF with get_vf_rid()
//   - enable_vfs(pf_idx, num_vfs) / disable_vfs(pf_idx)
//   - lookup_by_bdf(bdf): BDF -> func_context lookup
//
// Depends on:
//   - virtio_vf_resource_pool (queue mapping)
//   - virtio_vf_instance (per-VF driver wrapper)
//   - virtio_failover_manager (STANDBY failover)
//   - virtio_pci_transport (PF transport for config access)
//   - virtio_wait_policy (timeout/polling)
// ============================================================================

class virtio_pf_manager extends uvm_object;
    `uvm_object_utils(virtio_pf_manager)

    // ===== PCIe layer delegation =====
    // Stored as uvm_object, $cast to pcie_tl_func_manager at runtime
    uvm_object  pcie_func_mgr_ref;

    // ===== Virtio-specific =====
    virtio_vf_resource_pool   resource_pool;
    virtio_failover_manager   failover_mgr;

    // ===== VF instances (references, owned by env) =====
    virtio_vf_instance        vf_instances[];
    int unsigned              active_vf_count = 0;

    // ===== PF transport =====
    virtio_pci_transport      pf_transport;

    // ===== Wait policy =====
    virtio_wait_policy        wait_pol;

    // ===== PF-owned Admin VQ context =====
    // This is independent from the PF dataplane/control queue managers.  It
    // is configured only after Admin-VQ feature negotiation and after the
    // caller/Fabric has supplied a special-VQ lease.
    virtio_admin_vq_context   admin_vq;
    virtio_atomic_ops         admin_ops;
    // Serializes Admin-VQ context replacement/teardown against a command
    // taking ownership of the context's submission lock.
    semaphore                 admin_vq_config_lock;
    // Set only by the authoritative PF lifecycle owner.  The callback owns
    // normal PF queues/state for full reset; Admin VQ merely requests it.
    virtio_admin_full_reset_owner pf_lifecycle_reset_owner;

    // ===== PF index (for multi-PF support) =====
    int unsigned              pf_index = 0;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_pf_manager");
        super.new(name);
        resource_pool = virtio_vf_resource_pool::type_id::create("resource_pool");
        admin_vq = virtio_admin_vq_context::type_id::create("admin_vq");
        admin_ops = virtio_atomic_ops::type_id::create("admin_ops");
        admin_vq_config_lock = new(1);
    endfunction

    // Admin descriptors are owned by ctx.vq, while DMA and notification use
    // the context fields.  They must describe the same queue, requester, and
    // memory/IOMMU domains before any lifecycle operation can touch them.
    protected function bit admin_vq_bindings_are_consistent(
        virtio_admin_vq_context admin_context,
        string                  operation
    );
        if ((admin_context == null) || (admin_context.vq == null) ||
            (admin_context.transport == null) || (admin_context.mem == null) ||
            (admin_context.iommu == null) ||
            (admin_context.queue_id != admin_context.vq.queue_id) ||
            (admin_context.vq.host_id !=
                admin_context.transport.iommu_host_id()) ||
            (admin_context.vq.bdf != admin_context.transport.bdf) ||
            (admin_context.vq.mem != admin_context.mem) ||
            (admin_context.vq.iommu != admin_context.iommu)) begin
            `uvm_error("PF_MGR", $sformatf(
                "%s: Admin VQ binding is inconsistent", operation))
            return 0;
        end
        return 1;
    endfunction

    virtual task configure_admin_vq(virtio_admin_vq_context admin_context);
        virtio_admin_vq_context current_context;
        bit                     current_locked;

        if (admin_context == null) begin
            `uvm_error("PF_MGR", "configure_admin_vq: null Admin VQ context")
            return;
        end
        if (admin_vq_config_lock == null) begin
            `uvm_error("PF_MGR", "configure_admin_vq: Admin VQ config lock is null")
            return;
        end

        current_locked = 0;
        admin_vq_config_lock.get(1);
        do begin
            if (pf_transport == null) begin
                `uvm_error("PF_MGR", "configure_admin_vq: PF transport is not configured")
                break;
            end
            if ((admin_context.transport == null) ||
                (admin_context.transport != pf_transport)) begin
                `uvm_error("PF_MGR",
                    "configure_admin_vq: Admin VQ transport does not match PF transport")
                break;
            end
            if (admin_context.submit_lock == null) begin
                `uvm_error("PF_MGR", "configure_admin_vq: Admin VQ has no submission lock")
                break;
            end
            if (!admin_vq_bindings_are_consistent(
                admin_context, "configure_admin_vq")) begin
                break;
            end

            // A replacement must wait for any in-flight command and must not
            // overwrite the only quarantine ownership record.
            current_context = admin_vq;
            if (current_context != null) begin
                if (current_context.submit_lock == null) begin
                    `uvm_error("PF_MGR",
                        "configure_admin_vq: current Admin VQ has no submission lock")
                    break;
                end
                current_context.submit_lock.get(1);
                current_locked = 1;
                if (current_context.dma_quarantined ||
                    (current_context.quarantined_iovas.size() != 0) ||
                    (current_context.quarantined_gpas.size() != 0)) begin
                    `uvm_error("PF_MGR",
                        "configure_admin_vq: current Admin VQ has quarantined DMA")
                    break;
                end
            end

            admin_vq = admin_context;
            if (pf_lifecycle_reset_owner != null)
                admin_vq.full_reset_owner = pf_lifecycle_reset_owner;
        end while (0);
        if (current_locked)
            current_context.submit_lock.put(1);
        admin_vq_config_lock.put(1);
    endtask

    virtual function void configure_pf_lifecycle_reset_owner(
        virtio_admin_full_reset_owner reset_owner
    );
        if (reset_owner == null) begin
            `uvm_error("PF_MGR", "configure_pf_lifecycle_reset_owner: null reset owner")
            return;
        end
        pf_lifecycle_reset_owner = reset_owner;
        if (admin_vq != null)
            admin_vq.full_reset_owner = reset_owner;
    endfunction

    virtual task clear_admin_vq();
        virtio_admin_vq_context admin_context;

        if (admin_vq_config_lock == null) begin
            `uvm_error("PF_MGR", "clear_admin_vq: Admin VQ config lock is null")
            return;
        end

        admin_vq_config_lock.get(1);
        admin_context = admin_vq;
        if (admin_context == null) begin
            `uvm_error("PF_MGR", "clear_admin_vq: Admin VQ context is null")
        end else if (admin_context.submit_lock == null) begin
            `uvm_error("PF_MGR", "clear_admin_vq: Admin VQ has no submission lock")
        end else begin
            admin_context.submit_lock.get(1);
            if (admin_context.dma_quarantined ||
                (admin_context.quarantined_iovas.size() != 0) ||
                (admin_context.quarantined_gpas.size() != 0)) begin
                `uvm_error("PF_MGR", "clear_admin_vq: Admin VQ has quarantined DMA")
            end else begin
                admin_vq = virtio_admin_vq_context::type_id::create("admin_vq");
                admin_vq.full_reset_owner = pf_lifecycle_reset_owner;
            end
            admin_context.submit_lock.put(1);
        end
        admin_vq_config_lock.put(1);
    endtask

    // ========================================================================
    // recover_admin_vq -- Retire Admin DMA only after a verified full PF reset
    //
    // A failed Q_RESET leaves request/response memory reachable by the device.
    // This is the sole release path for that quarantine record: it serializes
    // context handoff, verifies the PF identity, asks the PF owner to reset,
    // then releases DMA and leaves the Admin VQ unconfigured.
    // ========================================================================
    virtual task recover_admin_vq(ref bit recovery_complete);
        virtio_admin_vq_context admin_context;
        uvm_object              detached_tokens[$];

        recovery_complete = 0;
        if (admin_vq_config_lock == null) begin
            `uvm_error("PF_MGR", "recover_admin_vq: Admin VQ config lock is null")
            return;
        end

        admin_vq_config_lock.get(1);
        admin_context = admin_vq;
        if (admin_context == null) begin
            `uvm_error("PF_MGR", "recover_admin_vq: Admin VQ context is null")
        end else if (admin_context.submit_lock == null) begin
            `uvm_error("PF_MGR", "recover_admin_vq: Admin VQ has no submission lock")
        end else begin
            admin_context.submit_lock.get(1);
            do begin
                if (!admin_context.dma_quarantined ||
                    !admin_context.recovery_required ||
                    (admin_context.quarantined_iovas.size() == 0) ||
                    (admin_context.quarantined_gpas.size() == 0)) begin
                    `uvm_error("PF_MGR", "recover_admin_vq: Admin VQ has no quarantined DMA")
                    break;
                end
                if (pf_transport == null) begin
                    `uvm_error("PF_MGR", "recover_admin_vq: PF transport is not configured")
                    break;
                end
                if ((admin_context.transport == null) ||
                    (admin_context.transport != pf_transport)) begin
                    `uvm_error("PF_MGR",
                        "recover_admin_vq: Admin VQ transport does not match PF transport")
                    break;
                end
                if ((admin_context.vq == null) || (admin_context.mem == null) ||
                    (admin_context.iommu == null) ||
                    (admin_context.full_reset_owner == null)) begin
                    `uvm_error("PF_MGR", "recover_admin_vq: incomplete Admin VQ context")
                    break;
                end
                if (!admin_vq_bindings_are_consistent(
                    admin_context, "recover_admin_vq")) begin
                    break;
                end

                admin_context.full_reset_owner.reset_pf_lifecycle(recovery_complete);
                if (!recovery_complete) begin
                    `uvm_error("PF_MGR",
                        "recover_admin_vq: PF lifecycle reset did not complete")
                    break;
                end

                admin_context.vq.detach_all_unused(detached_tokens);
                admin_context.vq.reset_queue();
                admin_context.vq.alloc_rings();
                foreach (admin_context.quarantined_iovas[index])
                    admin_context.iommu.unmap_for_host(
                        admin_context.transport.iommu_host_id(),
                        admin_context.transport.bdf,
                        admin_context.quarantined_iovas[index]
                    );
                foreach (admin_context.quarantined_gpas[index])
                    admin_context.mem.free(admin_context.quarantined_gpas[index]);
                admin_context.quarantined_iovas.delete();
                admin_context.quarantined_gpas.delete();
                admin_context.dma_quarantined = 0;
                admin_context.recovery_required = 0;
                admin_context.configured = 0;
            end while (0);
            admin_context.submit_lock.put(1);
        end
        admin_vq_config_lock.put(1);
    endtask

    // ========================================================================
    // enable_sriov -- Enable SR-IOV with specified number of VFs
    //
    // Runtime lifecycle steps:
    //   1. Verify the environment supplied its PCIe function-manager handle
    //   2. Check that environment-owned VF instances are available
    //   3. Poll each VF's config space to verify runtime accessibility
    //   4. Publish the runtime-active VF count
    //
    // The pcie_func_mgr_ref must be set before calling this method.
    // The vf_instances[] array must be populated by the env before calling.
    // ========================================================================

    virtual task enable_sriov(int unsigned num_vfs);
        int unsigned elapsed;
        int unsigned eff_timeout;
        int unsigned interval;
        int unsigned attempts;
        int unsigned max_att;

        `uvm_info("PF_MGR",
            $sformatf("enable_sriov: num_vfs=%0d, pf_index=%0d",
                      num_vfs, pf_index),
            UVM_LOW)

        // -----------------------------------------------------------------
        // Step 1: Delegate VF enable to PCIe layer
        // The env is responsible for $casting pcie_func_mgr_ref to
        // pcie_tl_func_manager and calling enable_vfs(pf_index, num_vfs).
        // Here we verify the reference is set.
        // -----------------------------------------------------------------
        if (pcie_func_mgr_ref == null) begin
            `uvm_error("PF_MGR",
                "enable_sriov: pcie_func_mgr_ref is null -- PCIe func_manager not set")
            return;
        end

        // -----------------------------------------------------------------
        // Step 2: VF instances are created by the env, verify they exist
        // -----------------------------------------------------------------
        if (vf_instances.size() < num_vfs) begin
            `uvm_warning("PF_MGR",
                $sformatf("enable_sriov: vf_instances.size()=%0d < num_vfs=%0d -- env should populate before calling",
                          vf_instances.size(), num_vfs))
        end

        // -----------------------------------------------------------------
        // Step 3: Poll each VF's config space to verify accessibility
        // Use wait_pol for polling, not bare #delay
        // -----------------------------------------------------------------
        if (wait_pol == null) begin
            `uvm_warning("PF_MGR",
                "enable_sriov: wait_pol is null, skipping VF accessibility check")
        end else if (pf_transport != null) begin
            eff_timeout = wait_pol.effective_timeout(wait_pol.vf_ready_timeout_ns);
            interval    = wait_pol.default_poll_interval_ns;
            if (interval == 0) interval = 1;
            max_att     = eff_timeout / interval + 1;
            if (max_att > wait_pol.max_poll_attempts)
                max_att = wait_pol.max_poll_attempts;

            for (int unsigned vf = 0; vf < num_vfs; vf++) begin
                bit vf_accessible = 0;
                elapsed  = 0;
                attempts = 0;

                // Poll VF config space (vendor ID) until readable
                while (attempts < max_att) begin : vf_poll_loop
                    // Try reading vendor ID from VF's config space
                    // On success the read returns a valid vendor ID (non-FFFF)
                    if (vf < vf_instances.size() && vf_instances[vf] != null &&
                        vf_instances[vf].transport != null) begin
                        bit [31:0] vendor_data;
                        vf_instances[vf].transport.bar.read_reg(0, 32'h0, 4, vendor_data);
                        if (vendor_data != 32'hFFFF_FFFF && vendor_data != 32'h0) begin
                            vf_accessible = 1;
                            break;
                        end
                    end else begin
                        // VF instance not yet available, assume accessible
                        vf_accessible = 1;
                        break;
                    end
                    #(interval * 1ns);
                    elapsed += interval;
                    attempts++;
                end : vf_poll_loop

                if (!vf_accessible) begin
                    `uvm_warning("PF_MGR",
                        $sformatf("enable_sriov: VF%0d not accessible after %0dns",
                                  vf, elapsed))
                end else begin
                    `uvm_info("PF_MGR",
                        $sformatf("enable_sriov: VF%0d accessible", vf),
                        UVM_HIGH)
                end
            end
        end

        active_vf_count = num_vfs;

        `uvm_info("PF_MGR",
            $sformatf("enable_sriov: complete, active_vf_count=%0d, total_queues=%0d",
                      active_vf_count, resource_pool.get_total_queues()),
            UVM_LOW)
    endtask

    // ========================================================================
    // disable_sriov -- Disable SR-IOV, shutdown all VFs
    //
    // Runtime lifecycle steps:
    //   1. Shutdown all VF instances
    //   2. Verify the PCIe disable delegate is available to the environment
    //   3. Reset the runtime-active VF count
    // ========================================================================

    virtual task disable_sriov();
        `uvm_info("PF_MGR",
            $sformatf("disable_sriov: shutting down %0d VF(s)", active_vf_count),
            UVM_LOW)

        // -----------------------------------------------------------------
        // Step 1: Shutdown all VF instances
        // -----------------------------------------------------------------
        foreach (vf_instances[i]) begin
            if (vf_instances[i] != null) begin
                `uvm_info("PF_MGR",
                    $sformatf("disable_sriov: shutting down VF%0d", i),
                    UVM_MEDIUM)
                vf_instances[i].shutdown();
            end
        end

        // -----------------------------------------------------------------
        // Step 2: Delegate VF disable to PCIe layer
        // The env is responsible for $casting pcie_func_mgr_ref to
        // pcie_tl_func_manager and calling disable_vfs(pf_index).
        // -----------------------------------------------------------------
        if (pcie_func_mgr_ref == null) begin
            `uvm_warning("PF_MGR",
                "disable_sriov: pcie_func_mgr_ref is null -- PCIe disable skipped")
        end

        active_vf_count = 0;

        `uvm_info("PF_MGR", "disable_sriov: complete", UVM_LOW)
    endtask

    // ========================================================================
    // vf_flr -- Initiate Function Level Reset for a specific VF
    //
    // Steps:
    //   1. Virtio cleanup via vf_instance.on_flr()
    //   2. PCIe FLR: write FLR bit to VF's Device Control register
    //   3. Poll VF config space until accessible again
    //
    // Uses wait_pol for polling with named fork (no bare #delay).
    // Timeout: wait_pol.flr_timeout_ns
    // ========================================================================

    virtual task vf_flr(int unsigned vf_index);
        int unsigned elapsed = 0;
        int unsigned eff_timeout;
        int unsigned interval;
        int unsigned attempts = 0;
        int unsigned max_att;
        bit flr_complete = 0;

        `uvm_info("PF_MGR",
            $sformatf("vf_flr: initiating FLR for VF%0d", vf_index),
            UVM_LOW)

        // Validate VF index
        if (vf_index >= vf_instances.size() || vf_instances[vf_index] == null) begin
            `uvm_error("PF_MGR",
                $sformatf("vf_flr: VF%0d not found or null (vf_instances.size=%0d)",
                          vf_index, vf_instances.size()))
            return;
        end

        // -----------------------------------------------------------------
        // Step 1: Virtio cleanup
        // -----------------------------------------------------------------
        vf_instances[vf_index].on_flr();

        // -----------------------------------------------------------------
        // Step 2: PCIe FLR
        // Write FLR bit (bit 15) to VF's PCI Express Device Control register
        // Device Control register is at offset 0x08 within the PCIe
        // capability structure. We use the PF transport to issue the write.
        // -----------------------------------------------------------------
        if (pf_transport != null) begin
            // PCIe Device Control register: bit 15 = Initiate FLR
            pf_transport.bar.write_reg(0, 32'h08, 4, 32'h0000_8000);

            `uvm_info("PF_MGR",
                $sformatf("vf_flr: FLR bit written for VF%0d", vf_index),
                UVM_MEDIUM)
        end else begin
            `uvm_warning("PF_MGR",
                "vf_flr: pf_transport is null -- PCIe FLR write skipped")
        end

        // -----------------------------------------------------------------
        // Step 3: Poll VF config space until accessible again
        // -----------------------------------------------------------------
        if (wait_pol == null) begin
            `uvm_warning("PF_MGR",
                "vf_flr: wait_pol is null, skipping FLR completion poll")
            return;
        end

        eff_timeout = wait_pol.effective_timeout(wait_pol.flr_timeout_ns);
        interval    = wait_pol.default_poll_interval_ns;
        if (interval == 0) interval = 1;
        max_att     = eff_timeout / interval + 1;
        if (max_att > wait_pol.max_poll_attempts)
            max_att = wait_pol.max_poll_attempts;

        while (attempts < max_att) begin : flr_poll_loop
            if (vf_instances[vf_index].transport != null) begin
                bit [31:0] vendor_data;
                vf_instances[vf_index].transport.bar.read_reg(0, 32'h0, 4, vendor_data);
                if (vendor_data != 32'hFFFF_FFFF && vendor_data != 32'h0) begin
                    flr_complete = 1;
                    break;
                end
            end else begin
                // No transport, assume FLR completes immediately
                flr_complete = 1;
                break;
            end
            #(interval * 1ns);
            elapsed += interval;
            attempts++;
        end : flr_poll_loop

        if (!flr_complete) begin
            `uvm_error("PF_MGR",
                $sformatf("vf_flr: VF%0d FLR timeout after %0dns", vf_index, elapsed))
        end else begin
            `uvm_info("PF_MGR",
                $sformatf("vf_flr: VF%0d FLR complete after %0dns", vf_index, elapsed),
                UVM_MEDIUM)
        end
    endtask

    // ========================================================================
    // get_vf_context -- Returns pcie_tl_func_context for a VF
    //
    // The returned uvm_object can be $cast to pcie_tl_func_context by
    // the caller. Returns null if the VF index is out of range or the
    // VF instance has no PCIe context.
    // ========================================================================

    virtual function uvm_object get_vf_context(int unsigned vf_index);
        if (vf_index >= vf_instances.size() || vf_instances[vf_index] == null) begin
            `uvm_warning("PF_MGR",
                $sformatf("get_vf_context: VF%0d not found", vf_index))
            return null;
        end
        return vf_instances[vf_index].pcie_ctx_ref;
    endfunction

    // ========================================================================
    // get_vf_instance -- Returns the VF instance for a given index
    // ========================================================================

    virtual function virtio_vf_instance get_vf_instance(int unsigned vf_index);
        if (vf_index >= vf_instances.size()) begin
            `uvm_warning("PF_MGR",
                $sformatf("get_vf_instance: VF%0d out of range (size=%0d)",
                          vf_index, vf_instances.size()))
            return null;
        end
        return vf_instances[vf_index];
    endfunction

    // ========================================================================
    // get_active_vf_count -- Return number of active VFs
    // ========================================================================

    virtual function int unsigned get_active_vf_count();
        return active_vf_count;
    endfunction

    // ========================================================================
    // admin_cmd -- Admin VQ (virtio 1.2+)
    //
    // The PF can send administrative commands to an active target VF only
    // through its independently configured Admin VQ.  result excludes the
    // device status byte; ok reports the full request lifecycle outcome.
    // ========================================================================

    virtual task admin_cmd(int unsigned target_vf,
                           byte unsigned cmd_data[],
                           ref byte unsigned result[],
                           ref bit ok);
        bit [7:0]                device_status;
        virtio_admin_vq_context  admin_context;

        ok = 0;
        result = new[0];

        // Serialize the context handoff with configure/clear/recovery, then
        // retain the selected context's lock through submission and cleanup.
        // A queued caller must not retain an obsolete context after teardown.
        if (admin_vq_config_lock == null) begin
            `uvm_error("PF_MGR", "admin_cmd: Admin VQ config lock is null")
            return;
        end
        admin_vq_config_lock.get(1);
        admin_context = admin_vq;
        if (admin_context == null) begin
            `uvm_error("PF_MGR", "admin_cmd: Admin VQ is not configured")
            admin_vq_config_lock.put(1);
            return;
        end
        if (admin_context.submit_lock == null) begin
            `uvm_error("PF_MGR", "admin_cmd: Admin VQ has no submission lock")
            admin_vq_config_lock.put(1);
            return;
        end

        admin_context.submit_lock.get(1);
        admin_vq_config_lock.put(1);
        begin : admin_cmd_locked
        do begin
            // The full-PF reset owner is attached to pf_transport.  Refuse a
            // context that names a different device before DMA, descriptors,
            // notification, status read, or recovery can touch either one.
            if (pf_transport == null) begin
                `uvm_error("PF_MGR", "admin_cmd: PF transport is not configured")
                break;
            end
            if ((admin_context.transport == null) ||
                (admin_context.transport != pf_transport)) begin
                `uvm_error("PF_MGR",
                    "admin_cmd: Admin VQ transport does not match PF transport")
                break;
            end

            // Active-count is only a capacity summary; validate the actual VF
            // object and state so an FLR/disabled VF cannot receive Admin work.
            if ((target_vf >= active_vf_count) ||
                (target_vf >= vf_instances.size()) ||
                (vf_instances[target_vf] == null) ||
                (vf_instances[target_vf].get_state() != VF_ACTIVE)) begin
                `uvm_error("PF_MGR",
                    $sformatf("admin_cmd: target VF%0d is not active", target_vf))
                break;
            end

            if (!admin_context.negotiated_features[VIRTIO_F_ADMIN_VQ]) begin
                `uvm_error("PF_MGR", "admin_cmd: VIRTIO_F_ADMIN_VQ is not negotiated")
                break;
            end
            if (!admin_context.configured || (admin_context.vq == null) ||
                (admin_context.transport == null) || (admin_context.mem == null) ||
                (admin_context.iommu == null) || (admin_context.wait_pol == null) ||
                (admin_context.response_capacity == 0)) begin
                    `uvm_error("PF_MGR", "admin_cmd: Admin VQ is not configured")
                break;
            end
            if (!admin_vq_bindings_are_consistent(
                admin_context, "admin_cmd")) begin
                break;
            end
            if (!admin_context.special_vq_lease_valid ||
                admin_context.special_vq_lease.frozen) begin
                `uvm_error("PF_MGR", "admin_cmd: Admin VQ has no usable special-VQ lease")
                break;
            end
            if (admin_context.full_reset_owner == null) begin
                `uvm_error("PF_MGR", "admin_cmd: Admin VQ has no PF lifecycle reset owner")
                break;
            end
            if (admin_context.recovery_required || admin_context.dma_quarantined) begin
                `uvm_error("PF_MGR", "admin_cmd: Admin VQ requires verified recovery")
                break;
            end

            // Use the transport API rather than a cached status field, so the
            // decision always follows the same device-visible status source.
            admin_context.transport.read_device_status(device_status);
            if (device_status & (DEV_STATUS_FAILED | DEV_STATUS_DEVICE_NEEDS_RESET)) begin
                `uvm_error("PF_MGR", "admin_cmd: device is FAILED or needs reset")
                break;
            end

            if (admin_ops == null)
                admin_ops = virtio_atomic_ops::type_id::create("admin_ops");
            admin_ops.admin_vq_submit(admin_context, cmd_data, result, ok, 1'b1);
        end while (0);
        end : admin_cmd_locked
        admin_context.submit_lock.put(1);
    endtask

    // ========================================================================
    // print_status -- Print PF manager status summary
    // ========================================================================

    virtual function void print_status();
        `uvm_info("PF_MGR",
            $sformatf("PF Manager Status: pf_index=%0d, active_vfs=%0d, total_queues=%0d",
                      pf_index, active_vf_count, resource_pool.get_total_queues()),
            UVM_LOW)

        resource_pool.print_map();

        if (failover_mgr != null) begin
            `uvm_info("PF_MGR", failover_mgr.get_status_string(), UVM_LOW)
        end
    endfunction

endclass : virtio_pf_manager

`endif // VIRTIO_PF_MANAGER_SV
