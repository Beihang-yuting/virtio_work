`ifndef VIRTIO_RESOURCE_CLIENT_SV
`define VIRTIO_RESOURCE_CLIENT_SV

// Read-only VIO view of one service's placement-owned qpair bindings.
class virtio_resource_client extends uvm_object;
    `uvm_object_utils(virtio_resource_client)

    protected virtio_qpair_mapping_t qpair_mappings[$];
    local dpu_device_snapshot   bound_device_snapshot;
    local dpu_resource_snapshot bound_resource_snapshot;
    local dpu_service_key_t     bound_service_key;
    local bit                   service_binding_owned;
    protected bit               runtime_ready;

    function new(string name = "virtio_resource_client");
        super.new(name);
        bound_device_snapshot = null;
        bound_resource_snapshot = null;
        service_binding_owned = 0;
        runtime_ready = 0;
    endfunction

    function bit bind_to_service(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_service_key_t service_key,
        output string why
    );
        dpu_function_key_t owner;
        dpu_vio_qpair_binding_t bindings[$];
        virtio_qpair_mapping_t candidate_mappings[$];
        virtio_qpair_mapping_t mapping;
        virtio_qpair_mapping_t swap;

        why = "";
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
            mapping.virtio_pair_index = bindings[index].virtio_pair_index;
            mapping.local_pair = bindings[index].local_pair_id;
            mapping.rx_virtqueue_id = bindings[index].rx_local_virtqueue_id;
            mapping.tx_virtqueue_id = bindings[index].tx_local_virtqueue_id;
            // The real DUT allocates one txrx queue resource per VIO pair.
            // VTX and VRX both consume that same global queue index; only
            // the local virtqueue IDs distinguish direction.
            mapping.rx_global_qid = bindings[index].global_qpair_id;
            mapping.tx_global_qid = bindings[index].global_qpair_id;
            candidate_mappings.push_back(mapping);
        end
        for (int left = 0; left < candidate_mappings.size(); left++) begin
            for (int right = left + 1;
                 right < candidate_mappings.size();
                 right++) begin
                if (candidate_mappings[right].local_pair <
                    candidate_mappings[left].local_pair) begin
                    swap = candidate_mappings[left];
                    candidate_mappings[left] = candidate_mappings[right];
                    candidate_mappings[right] = swap;
                end
            end
        end

        qpair_mappings = candidate_mappings;
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

    function int unsigned qpair_mapping_count();
        return qpair_mappings.size();
    endfunction

    function void list_qpair_mappings(
        output virtio_qpair_mapping_t mappings[$]
    );
        mappings = qpair_mappings;
    endfunction

    function dpu_dut_caps snapshot_bound_dut_caps();
        if (!service_binding_owned)
            return null;
        return bound_device_snapshot.snapshot_dut_caps();
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

    function bit local_qid_to_global_qid(
        input int unsigned local_qid,
        output int unsigned global_qid
    );
        foreach (qpair_mappings[index]) begin
            if (qpair_mappings[index].rx_virtqueue_id == local_qid) begin
                global_qid =
                    qpair_mappings[index].rx_global_qid;
                return 1;
            end
            if (qpair_mappings[index].tx_virtqueue_id == local_qid) begin
                global_qid =
                    qpair_mappings[index].tx_global_qid;
                return 1;
            end
        end
        global_qid = '0;
        return 0;
    endfunction
endclass : virtio_resource_client

`endif // VIRTIO_RESOURCE_CLIENT_SV
