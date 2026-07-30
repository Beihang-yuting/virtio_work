`ifndef VIRTIO_RESOURCE_CLIENT_SV
`define VIRTIO_RESOURCE_CLIENT_SV

// Translates generic Fabric QP leases into virtio RX/TX queue identifiers.
// The manager remains unaware of virtio queue direction or queue naming.
class virtio_resource_client extends uvm_object;
    `uvm_object_utils(virtio_resource_client)

    dpu_resource_manager    resource_manager;
    dpu_function_key_t      function_key;
    dpu_resource_class_id_t qpair_class_id;
    dpu_resource_lease_t    qpair_leases[$];
    virtio_qpair_mapping_t  qpair_mappings[$];
    protected bit           device_ready;
    protected bit           qpairs_frozen;

    function new(string name = "virtio_resource_client");
        super.new(name);
        qpair_class_id = '0;
        device_ready = 0;
        qpairs_frozen = 0;
    endfunction

    function bit bind_to_fabric(
        input dpu_resource_manager manager,
        input dpu_function_key_t key,
        output string why
    );
        if (manager == null) begin
            why = "virtio resource client requires a Fabric resource manager";
            return 0;
        end
        if (!manager.lookup_resource_class("virtio.qpair", qpair_class_id, why))
            return 0;
        resource_manager = manager;
        function_key = key;
        device_ready = 0;
        qpairs_frozen = 0;
        why = "";
        return 1;
    endfunction

    // The caller invokes this only after it programmed the Fabric BAR
    // triplet and completed its transport-visible discovery setup.
    function bit mark_device_ready(output string why);
        if (resource_manager == null) begin
            why = "virtio resource client has not been bound to Fabric";
            return 0;
        end
        if (!resource_manager.mark_function_device_ready(function_key, why))
            return 0;
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

        if ((resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (qpairs_frozen) begin
            why = "frozen virtio resource client cannot reserve QP leases";
            return 0;
        end
        if (!resource_manager.acquire_leases(
            function_key, qpair_class_id, first_local_pair, count, leases, why
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
        if ((resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        // Teardown, FLR, and disable own their leases even if migration left
        // them saved.  Restore makes the saved Fabric class lease set
        // releasable; it neither assigns a new global ID nor changes mappings.
        if (qpairs_frozen && !restore_qpairs(why))
            return 0;
        if (!resource_manager.release_leases(function_key, qpair_class_id, why))
            return 0;
        qpair_leases.delete();
        qpair_mappings.delete();
        why = "";
        return 1;
    endfunction

    // A migration freeze needs teardown even when no local QP was allocated.
    // The function owner uses this to decide whether FLR/disable must invoke
    // release_qpairs(), which restores the Fabric manager state first.
    function bit has_pending_qpair_cleanup();
        return qpairs_frozen || (qpair_leases.size() != 0) ||
               (qpair_mappings.size() != 0);
    endfunction

    // Freezing preserves the generic leases and their virtio pair mapping;
    // restore simply makes that saved class lease set usable again.
    function bit freeze_qpairs(output string why);
        if ((resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (!resource_manager.freeze_function(function_key, why))
            return 0;
        qpairs_frozen = 1;
        why = "";
        return 1;
    endfunction

    function bit restore_qpairs(output string why);
        if ((resource_manager == null) || !device_ready) begin
            why = "virtio resource client function is not device-ready";
            return 0;
        end
        if (!resource_manager.restore_function(function_key, why))
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
