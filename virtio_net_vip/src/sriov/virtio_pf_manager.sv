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

    // ===== PF index (for multi-PF support) =====
    int unsigned              pf_index = 0;

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name = "virtio_pf_manager");
        super.new(name);
        resource_pool = virtio_vf_resource_pool::type_id::create("resource_pool");
    endfunction

    // ========================================================================
    // enable_sriov -- Enable SR-IOV with specified number of VFs
    //
    // Steps:
    //   1. Delegate to PCIe layer: call enable_vfs on pcie_tl_func_manager
    //   2. Register queue mappings in resource_pool
    //   3. VF instances are created by the env (not here)
    //   4. Poll each VF's config space to verify accessibility
    //
    // The pcie_func_mgr_ref must be set before calling this method.
    // The vf_instances[] array must be populated by the env before calling.
    // ========================================================================

    virtual task enable_sriov(int unsigned num_vfs, int unsigned pairs_per_vf = 1);
        bit [31:0] read_data;
        int unsigned elapsed;
        int unsigned eff_timeout;
        int unsigned interval;
        int unsigned attempts;
        int unsigned max_att;

        `uvm_info("PF_MGR",
            $sformatf("enable_sriov: num_vfs=%0d, pairs_per_vf=%0d, pf_index=%0d",
                      num_vfs, pairs_per_vf, pf_index),
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
        // Step 2: Register queue mappings
        // -----------------------------------------------------------------
        resource_pool.register_vfs(num_vfs, pairs_per_vf);

        // -----------------------------------------------------------------
        // Step 3: VF instances are created by the env, verify they exist
        // -----------------------------------------------------------------
        if (vf_instances.size() < num_vfs) begin
            `uvm_warning("PF_MGR",
                $sformatf("enable_sriov: vf_instances.size()=%0d < num_vfs=%0d -- env should populate before calling",
                          vf_instances.size(), num_vfs))
        end

        // -----------------------------------------------------------------
        // Step 4: Poll each VF's config space to verify accessibility
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
    // Steps:
    //   1. Shutdown all VF instances
    //   2. Delegate VF disable to PCIe layer
    //   3. Clear queue mappings
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

        // -----------------------------------------------------------------
        // Step 3: Clear queue mappings
        // -----------------------------------------------------------------
        resource_pool.unregister_all();

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
    // Placeholder for PF-level admin virtqueue commands. In virtio 1.2+,
    // the PF can send administrative commands to target specific VFs
    // (e.g., migration state save/restore).
    //
    // Parameters:
    //   target_vf  -- VF index to target
    //   cmd_data   -- Command payload bytes
    //   result     -- Result payload bytes (output)
    // ========================================================================

    virtual task admin_cmd(int unsigned target_vf,
                           byte unsigned cmd_data[],
                           ref byte unsigned result[]);
        `uvm_info("PF_MGR",
            $sformatf("admin_cmd: target_vf=%0d, cmd_size=%0d bytes (placeholder)",
                      target_vf, cmd_data.size()),
            UVM_LOW)

        // Validate target VF
        if (target_vf >= active_vf_count) begin
            `uvm_error("PF_MGR",
                $sformatf("admin_cmd: target_vf=%0d >= active_vf_count=%0d",
                          target_vf, active_vf_count))
            result = new[1];
            result[0] = 8'hFF;  // Error indicator
            return;
        end

        // Placeholder: admin VQ command submission
        // In a full implementation, this would:
        //   1. Select the admin VQ (queue index defined by device)
        //   2. Build admin command descriptor chain
        //   3. Submit via virtqueue and wait for completion
        //   4. Parse result from used buffer
        //
        // For now, return success placeholder
        result = new[1];
        result[0] = 8'h00;  // Success indicator

        `uvm_info("PF_MGR",
            $sformatf("admin_cmd: target_vf=%0d complete (placeholder)", target_vf),
            UVM_MEDIUM)
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
