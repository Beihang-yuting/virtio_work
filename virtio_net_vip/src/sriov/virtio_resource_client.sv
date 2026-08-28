`ifndef VIRTIO_RESOURCE_CLIENT_SV
`define VIRTIO_RESOURCE_CLIENT_SV

// Translates generic device QP leases into virtio RX/TX queue identifiers.
// The manager remains unaware of virtio queue direction or queue naming.
class virtio_resource_client extends uvm_object;
    `uvm_object_utils(virtio_resource_client)

    dpu_resource_manager    resource_manager;
    protected dpu_dut_caps  dut_caps;
    dpu_function_key_t      function_key;
    dpu_resource_class_id_t qpair_class_id;
    dpu_resource_lease_t    qpair_leases[$];
    virtio_qpair_mapping_t  qpair_mappings[$];
    local bit               binding_owned;
    local dpu_resource_manager    bound_resource_manager;
    local dpu_function_key_t      bound_function_key;
    local dpu_resource_class_id_t bound_qpair_class_id;
    local int unsigned      bound_local_qpair_limit;
    protected bit           device_ready;
    protected bit           qpairs_frozen;
    local dpu_device_snapshot   bound_device_snapshot;
    local dpu_resource_snapshot bound_resource_snapshot;
    local dpu_service_key_t     bound_service_key;
    local bit                   service_binding_owned;
    protected bit               runtime_ready;

    function new(string name = "virtio_resource_client");
        super.new(name);
        qpair_class_id = '0;
        binding_owned = 0;
        bound_local_qpair_limit = 0;
        device_ready = 0;
        qpairs_frozen = 0;
        bound_device_snapshot = null;
        bound_resource_snapshot = null;
        service_binding_owned = 0;
        runtime_ready = 0;
    endfunction

    // Placement-enabled VIO functions import their complete immutable mapping
    // from the exact frozen snapshot pair.  No manager or lease is retained by
    // this path.
    function bit bind_to_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        dpu_function_key_t owner;
        dpu_vio_qpair_binding_t bindings[$];
        virtio_qpair_mapping_t mapping;
        virtio_qpair_mapping_t swap;

        why = "";
        if (binding_owned) begin
            why = "manager-backed virtio resource client cannot bind a service snapshot";
            return 0;
        end
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "virtio resource client requires an exact frozen snapshot pair";
            return 0;
        end
        if ((service_key.service_kind != DPU_SERVICE_VIO_NET) ||
            !device_snapshot.get_service_owner(service_key, owner, why) ||
            !dpu_same_function_key(owner, service_key.function_key)) begin
            if (why == "")
                why = "virtio resource client service ownership is invalid";
            return 0;
        end
        resource_snapshot.list_vio_bindings_for_service(service_key, bindings);
        if (bindings.size() == 0) begin
            why = "virtio resource client service has no qpair bindings";
            return 0;
        end
        if (service_binding_owned) begin
            if ((device_snapshot == bound_device_snapshot) &&
                (resource_snapshot == bound_resource_snapshot) &&
                (dpu_service_key_name(service_key) ==
                 dpu_service_key_name(bound_service_key))) begin
                return 1;
            end
            why = "virtio resource client snapshot binding cannot be reassigned";
            return 0;
        end
        foreach (bindings[index]) begin
            if (dpu_service_key_name(bindings[index].service_key) !=
                dpu_service_key_name(service_key)) begin
                why = "resource snapshot returned a binding for another service";
                return 0;
            end
            mapping.local_pair = bindings[index].local_pair_id;
            mapping.rx_global_qid = 2 * bindings[index].global_qpair_id;
            mapping.tx_global_qid = 2 * bindings[index].global_qpair_id + 1;
            qpair_mappings.push_back(mapping);
        end
        for (int left = 0; left < qpair_mappings.size(); left++) begin
            for (int right = left + 1; right < qpair_mappings.size(); right++) begin
                if (qpair_mappings[right].local_pair <
                    qpair_mappings[left].local_pair) begin
                    swap = qpair_mappings[left];
                    qpair_mappings[left] = qpair_mappings[right];
                    qpair_mappings[right] = swap;
                end
            end
        end
        bound_device_snapshot = device_snapshot;
        bound_resource_snapshot = resource_snapshot;
        bound_service_key = service_key;
        service_binding_owned = 1;
        runtime_ready = 0;
        return 1;
    endfunction

    function bit is_bound_to_service();
        return service_binding_owned;
    endfunction

    function bit mark_runtime_ready(output string why);
        if (!service_binding_owned) begin
            why = "virtio resource client has not been bound to a service";
            return 0;
        end
        runtime_ready = 1;
        why = "";
        return 1;
    endfunction

    function void reset_runtime_state();
        if (service_binding_owned)
            runtime_ready = 0;
    endfunction

    protected function bit bind_to_manager(
        input dpu_resource_manager manager,
        input dpu_function_key_t key,
        output string why
    );
        dpu_resource_class_id_t candidate_qpair_class_id;
        dpu_dut_caps bound_dut_caps;
        int unsigned bound_qpair_limit;

        if (service_binding_owned) begin
            why = "snapshot-backed virtio resource client cannot bind a manager";
            return 0;
        end
        if (manager == null) begin
            why = "virtio resource client requires a device resource manager";
            return 0;
        end
        if (!manager.is_snapshot_seeded()) begin
            why = "virtio resource client requires a snapshot-seeded device manager";
            return 0;
        end
        if (!manager.contains_function(key)) begin
            why = "virtio resource client function is not declared by the device snapshot";
            return 0;
        end
        if (!manager.lookup_resource_class(
            "virtio.qpair", candidate_qpair_class_id, why
        )) begin
            return 0;
        end
        bound_dut_caps = manager.snapshot_dut_caps();
        if (bound_dut_caps == null) begin
            why = "virtio resource client requires device capabilities";
            return 0;
        end
        bound_qpair_limit =
            bound_dut_caps.max_vio_net_qpairs_per_device;

        if (binding_owned) begin
            if ((manager == bound_resource_manager) &&
                (key.host_id == bound_function_key.host_id) &&
                (key.pf_id == bound_function_key.pf_id) &&
                (key.kind == bound_function_key.kind) &&
                (key.vf_id == bound_function_key.vf_id) &&
                (candidate_qpair_class_id == bound_qpair_class_id) &&
                (bound_qpair_limit == bound_local_qpair_limit)) begin
                why = "";
                return 1;
            end
            why =
                "virtio resource client device binding ownership cannot be reassigned";
            return 0;
        end

        resource_manager = manager;
        function_key = key;
        qpair_class_id = candidate_qpair_class_id;
        dut_caps = bound_dut_caps;
        bound_resource_manager = manager;
        bound_function_key = key;
        bound_qpair_class_id = candidate_qpair_class_id;
        bound_local_qpair_limit = bound_qpair_limit;
        binding_owned = 1;
        device_ready = 0;
        qpairs_frozen = 0;
        why = "";
        return 1;
    endfunction

    function bit bind_to_device(
        input dpu_resource_manager manager,
        input dpu_function_key_t key,
        output string why
    );
        return bind_to_manager(manager, key, why);
    endfunction

    function bit is_bound_to_device();
        return binding_owned;
    endfunction

    function dpu_dut_caps snapshot_bound_dut_caps();
        dpu_dut_caps snapshot;

        if (service_binding_owned)
            return bound_device_snapshot.snapshot_dut_caps();
        if (dut_caps == null)
            return null;
        snapshot = dpu_dut_caps::type_id::create(
            "virtio_client_bound_dut_caps_snapshot");
        snapshot.copy_from(dut_caps);
        return snapshot;
    endfunction

    // The caller invokes this only after it programmed the Fabric BAR
    // triplet and completed its transport-visible discovery setup.
    function bit mark_device_ready(output string why);
        if (service_binding_owned)
            return mark_runtime_ready(why);
        if (bound_resource_manager == null) begin
            why = "virtio resource client has not been bound to a device";
            return 0;
        end
        if (!bound_resource_manager.mark_function_device_ready(
            bound_function_key, why
        )) begin
            return 0;
        end
        device_ready = 1;
        why = "";
        return 1;
    endfunction

    function bit reserve_qpairs(
        input int unsigned first_local_pair,
        input int unsigned count,
        output string why
    );
        dpu_resource_lease_t leases[$];
        virtio_qpair_mapping_t mapping;

        if (service_binding_owned) begin
            why = "snapshot-backed virtio resource client has immutable qpairs";
            return 0;
        end
        if ((bound_resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (qpairs_frozen) begin
            why = "frozen virtio resource client cannot reserve QP leases";
            return 0;
        end
        if (dut_caps == null) begin
            why = "virtio resource client requires DUT capabilities";
            return 0;
        end
        if (first_local_pair >= bound_local_qpair_limit) begin
            why = $sformatf(
                "VIO-net local qpair range exceeds device limit 0..%0d",
                bound_local_qpair_limit - 1
            );
            return 0;
        end
        if (count > (bound_local_qpair_limit - first_local_pair)) begin
            why = $sformatf(
                "VIO-net local qpair range exceeds device limit 0..%0d",
                bound_local_qpair_limit - 1
            );
            return 0;
        end
        if (!bound_resource_manager.acquire_leases(
            bound_function_key, bound_qpair_class_id,
            first_local_pair, count, leases, why
        )) begin
            return 0;
        end
        foreach (leases[index]) begin
            mapping.local_pair = leases[index].local_id;
            mapping.rx_global_qid = 2 * leases[index].global_id;
            mapping.tx_global_qid = 2 * leases[index].global_id + 1;
            qpair_leases.push_back(leases[index]);
            qpair_mappings.push_back(mapping);
        end
        why = "";
        return 1;
    endfunction

    function bit release_qpairs(output string why);
        if (service_binding_owned) begin
            why = "snapshot-backed virtio resource client has immutable qpairs";
            return 0;
        end
        if ((bound_resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        // Teardown, FLR, and disable own their leases even if migration left
        // them saved.  Restore makes the saved Fabric class lease set
        // releasable; it neither assigns a new global ID nor changes mappings.
        if (qpairs_frozen && !restore_qpairs(why))
            return 0;
        if (!bound_resource_manager.release_leases(
            bound_function_key, bound_qpair_class_id, why
        )) begin
            return 0;
        end
        qpair_leases.delete();
        qpair_mappings.delete();
        why = "";
        return 1;
    endfunction

    // A migration freeze needs teardown even when no local QP was allocated.
    // The function owner uses this to decide whether FLR/disable must invoke
    // release_qpairs(), which restores the Fabric manager state first.
    function bit has_pending_qpair_cleanup();
        if (service_binding_owned)
            return 0;
        return qpairs_frozen || (qpair_leases.size() != 0) ||
               (qpair_mappings.size() != 0);
    endfunction

    // Freezing preserves the generic leases and their virtio pair mapping;
    // restore simply makes that saved class lease set usable again.
    function bit freeze_qpairs(output string why);
        if (service_binding_owned) begin
            why = "snapshot-backed virtio resource client has immutable qpairs";
            return 0;
        end
        if ((bound_resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (!bound_resource_manager.freeze_function(bound_function_key, why))
            return 0;
        qpairs_frozen = 1;
        why = "";
        return 1;
    endfunction

    function bit restore_qpairs(output string why);
        if (service_binding_owned) begin
            why = "snapshot-backed virtio resource client has immutable qpairs";
            return 0;
        end
        if ((bound_resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (!bound_resource_manager.restore_function(bound_function_key, why))
            return 0;
        qpairs_frozen = 0;
        why = "";
        return 1;
    endfunction

    function bit local_qid_to_global_qid(
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        int unsigned local_pair;

        local_pair = local_qid / 2;
        foreach (qpair_mappings[index]) begin
            if (qpair_mappings[index].local_pair == local_pair) begin
                global_qid = local_qid[0] ?
                    qpair_mappings[index].tx_global_qid :
                    qpair_mappings[index].rx_global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction
endclass : virtio_resource_client

`endif // VIRTIO_RESOURCE_CLIENT_SV
