`ifndef DPU_RESOURCE_MANAGER_SV
`define DPU_RESOURCE_MANAGER_SV

// =============================================================================
// DPU generic resource manager
//
// Snapshot-seeded managers own generic resource classes and lease state for
// functions declared by the global device snapshot.
// =============================================================================

class dpu_resource_function_state;
    dpu_function_key_t key;
    dpu_resource_lease_t leases[$];

    function new(dpu_function_key_t function_key);
        key = function_key;
    endfunction
endclass : dpu_resource_function_state


class dpu_resource_registry_authority;
endclass : dpu_resource_registry_authority


class dpu_resource_manager extends uvm_object;
    `uvm_object_utils(dpu_resource_manager)

    protected dpu_resource_function_state function_states[string];
    protected dpu_resource_class_id_t     class_id_by_name[string];
    protected dpu_resource_pool_config_t  resource_profiles_by_id[
        dpu_resource_class_id_t
    ];
    protected int unsigned                 class_allocated_count[
        dpu_resource_class_id_t
    ];
    protected bit                          active_global_ids[
        dpu_resource_class_id_t
    ][int unsigned];

    protected dpu_resource_class_id_t next_resource_class_id;
    protected bit                     resource_classes_sealed;
    protected dpu_resource_registry_authority registry_authority;
    protected bit                            registry_authority_claimed;
    protected bit                            snapshot_configured;
    protected dpu_device_snapshot            configured_snapshot;
    protected dpu_resource_snapshot          configured_resource_snapshot;
    protected dpu_resource_lease_t           service_leases_by_name[string][$];
    protected int unsigned                   service_local_to_global_qpair[
        string
    ][dpu_resource_class_id_t][int unsigned];
    protected dpu_dut_caps                  dut_caps;

    function new(string name = "dpu_resource_manager");
        super.new(name);
        dut_caps = dpu_dut_caps::type_id::create("dut_caps");
        next_resource_class_id = 0;
        resource_classes_sealed = 0;
        registry_authority = new();
        registry_authority_claimed = 0;
        snapshot_configured = 0;
        configured_snapshot = null;
        configured_resource_snapshot = null;
    endfunction

    protected function string function_key_name(
        input dpu_function_key_t key
    );
        return dpu_function_key_name(key);
    endfunction

    protected function bit validate_function_key(
        input dpu_function_key_t key,
        output string why
    );
        why = "";

        if (key.host_id >= dut_caps.max_hosts) begin
            why = $sformatf("host_id %0d exceeds DUT max_hosts %0d",
                            key.host_id, dut_caps.max_hosts);
            return 0;
        end
        if (key.pf_id >= dut_caps.max_pfs_per_host) begin
            why = $sformatf("pf_id %0d exceeds DUT max_pfs_per_host %0d",
                            key.pf_id, dut_caps.max_pfs_per_host);
            return 0;
        end

        case (key.kind)
            DPU_FUNCTION_PF: begin
                if (key.vf_id != 0) begin
                    why = "PF function keys require vf_id == 0";
                    return 0;
                end
            end
            DPU_FUNCTION_VF: begin
                if (key.vf_id >= dut_caps.max_vfs_per_pf) begin
                    why = $sformatf("vf_id %0d exceeds DUT max_vfs_per_pf %0d",
                                    key.vf_id, dut_caps.max_vfs_per_pf);
                    return 0;
                end
            end
            default: begin
                why = "function key has an unsupported function kind";
                return 0;
            end
        endcase

        return 1;
    endfunction

    protected function bit lookup_function_state(
        input dpu_function_key_t key,
        output dpu_resource_function_state state,
        output string why
    );
        string key_name;

        state = null;
        key_name = function_key_name(key);
        if (!function_states.exists(key_name)) begin
            why = "function is not registered";
            return 0;
        end

        state = function_states[key_name];
        why = "";
        return 1;
    endfunction

    protected function int unsigned function_class_lease_count(
        input dpu_resource_function_state state,
        input dpu_resource_class_id_t class_id
    );
        int unsigned count;

        count = 0;
        for (int unsigned index = 0; index < state.leases.size(); index++) begin
            if (state.leases[index].class_id == class_id)
                count++;
        end
        return count;
    endfunction

    protected function int unsigned allocated_count(
        input dpu_resource_class_id_t class_id
    );
        if (class_allocated_count.exists(class_id))
            return class_allocated_count[class_id];
        return 0;
    endfunction

    protected function bit seed_function(
        input dpu_function_key_t key,
        output string why
    );
        string key_name;
        string parent_key_name;
        dpu_function_key_t parent_key;

        if (!validate_function_key(key, why))
            return 0;

        key_name = function_key_name(key);
        if (function_states.exists(key_name)) begin
            why = "function key is already registered";
            return 0;
        end
        if (key.kind == DPU_FUNCTION_VF) begin
            parent_key.host_id = key.host_id;
            parent_key.pf_id = key.pf_id;
            parent_key.kind = DPU_FUNCTION_PF;
            parent_key.vf_id = 0;
            parent_key_name = function_key_name(parent_key);
            if (!function_states.exists(parent_key_name)) begin
                why = "VF function requires its PF parent to be registered";
                return 0;
            end
        end
        if (function_states.num() >= dut_caps.max_functions) begin
            why = "DUT function registrations have been exhausted";
            return 0;
        end

        function_states[key_name] = new(key);
        why = "";
        return 1;
    endfunction

    function dpu_resource_registry_authority claim_registry_authority();
        if (registry_authority_claimed || (function_states.num() != 0) ||
            (class_id_by_name.num() != 0) || resource_classes_sealed)
            return null;
        registry_authority_claimed = 1;
        return registry_authority;
    endfunction

    // The resource snapshot is the VIO qpair authority. Build all imported
    // state in a private candidate so no failed import can publish state.
    function bit configure_from_snapshots(
        input dpu_resource_registry_authority authority,
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        output string why
    );
        dpu_resource_manager candidate;
        dpu_dut_caps caps;
        dpu_function_key_t function_keys[$];
        dpu_resource_pool_config_t profiles[$];
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t af_extra_bindings[$];
        int unsigned reserved_global_ids[$];
        dpu_global_id_range_t reserved_global_ranges[$];
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_class_id_t class_id;

        why = "";
        if (!registry_authority_claimed || (authority == null) ||
            (authority != registry_authority)) begin
            why = "snapshot configuration requires the device registry authority";
            return 0;
        end
        if (snapshot_configured) begin
            why = "resource manager has already been configured from snapshots";
            return 0;
        end
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen() ||
            !resource_snapshot.references_device_snapshot(device_snapshot)) begin
            why = "resource snapshot is not frozen against the supplied device snapshot";
            return 0;
        end
        caps = device_snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(why))
            return 0;

        candidate = new({get_name(), "_snapshots_candidate"});
        candidate.dut_caps.copy_from(caps);
        device_snapshot.list_functions(function_keys);
        foreach (function_keys[index]) begin
            if (!candidate.seed_function(function_keys[index], why))
                return 0;
        end
        resource_snapshot.list_resource_profiles(profiles);
        foreach (profiles[index]) begin
            if (profiles[index].name == "virtio.qpair") begin
                if (profiles[index].capacity > caps.vio_global_qpair_count) begin
                    why = $sformatf(
                        {"virtio.qpair capacity %0d exceeds snapshot ",
                         "vio_global_qpair_count %0d"},
                        profiles[index].capacity, caps.vio_global_qpair_count);
                    return 0;
                end
                if (profiles[index].max_per_function >
                    caps.max_vio_net_qpairs_per_device) begin
                    why = $sformatf(
                        {"virtio.qpair max_per_function %0d exceeds snapshot ",
                         "max_vio_net_qpairs_per_device %0d"},
                        profiles[index].max_per_function,
                        caps.max_vio_net_qpairs_per_device);
                    return 0;
                end
            end
            if (!candidate.register_imported_resource_profile(
                    profiles[index], class_id, why))
                return 0;
        end
        if (!candidate.lookup_resource_class("virtio.qpair", qpair_class_id,
                                             why)) begin
            why = "resource snapshot has VIO bindings without a virtio.qpair profile";
            return 0;
        end
        if (candidate.resource_profiles_by_id[qpair_class_id].kind !=
            DPU_RESOURCE_KIND_QUEUE) begin
            why = "virtio.qpair profile is not a queue resource class";
            return 0;
        end
        resource_snapshot.list_reserved_global_qpair_ids(reserved_global_ids);
        resource_snapshot.list_reserved_global_qpair_ranges(reserved_global_ranges);
        foreach (reserved_global_ids[index]) begin
            if (reserved_global_ids[index] >= DPU_MAX_VIO_GLOBAL_QPAIRS) begin
                why = "resource snapshot has an out-of-range reserved global qpair ID";
                return 0;
            end
            if (reserved_global_ids[index] <
                candidate.resource_profiles_by_id[qpair_class_id].capacity)
                candidate.active_global_ids[qpair_class_id][
                    reserved_global_ids[index]] = 1;
        end
        foreach (reserved_global_ranges[index]) begin
            if ((reserved_global_ranges[index].first_id >
                 reserved_global_ranges[index].last_id) ||
                (reserved_global_ranges[index].last_id >=
                 DPU_MAX_VIO_GLOBAL_QPAIRS)) begin
                why = "resource snapshot has an invalid reserved global qpair range";
                return 0;
            end
            for (int unsigned global_id = reserved_global_ranges[index].first_id;
                 global_id <= reserved_global_ranges[index].last_id;
                 global_id++) begin
                if (global_id < candidate.resource_profiles_by_id[
                        qpair_class_id].capacity)
                    candidate.active_global_ids[qpair_class_id][global_id] = 1;
            end
        end
        resource_snapshot.list_vio_bindings(bindings);
        foreach (bindings[index]) begin
            dpu_function_key_t owner_key;
            dpu_resource_function_state state;
            dpu_resource_pool_config_t profile;
            dpu_resource_lease_t lease;
            string service_name;
            int unsigned class_count;
            int unsigned function_count;

            if (bindings[index].service_key.service_kind != DPU_SERVICE_VIO_NET) begin
                why = "resource snapshot binding is not VIO-net owned";
                return 0;
            end
            if (!device_snapshot.get_service_owner(bindings[index].service_key,
                                                   owner_key, why) ||
                !dpu_same_function_key(owner_key,
                                       bindings[index].service_key.function_key)) begin
                why = {"resource snapshot binding has no matching device service: ",
                       dpu_service_key_name(bindings[index].service_key)};
                return 0;
            end
            if (!candidate.lookup_function_state(
                    bindings[index].service_key.function_key, state, why))
                return 0;
            profile = candidate.resource_profiles_by_id[qpair_class_id];
            if (bindings[index].global_qpair_id >= profile.capacity) begin
                why = "VIO qpair global ID exceeds imported profile capacity";
                return 0;
            end
            if (candidate.active_global_ids[qpair_class_id].exists(
                    bindings[index].global_qpair_id)) begin
                why = "VIO qpair global ID is duplicated in resource snapshot";
                return 0;
            end
            service_name = dpu_service_key_name(bindings[index].service_key);
            if (candidate.service_local_to_global_qpair[service_name][
                    qpair_class_id].exists(bindings[index].local_pair_id)) begin
                why = "VIO qpair local ID is duplicated for service";
                return 0;
            end
            class_count = candidate.allocated_count(qpair_class_id);
            if (class_count >= profile.capacity) begin
                why = "VIO qpair resource-class capacity is exhausted";
                return 0;
            end
            function_count = candidate.function_class_lease_count(
                state, qpair_class_id);
            if ((function_count >= profile.max_per_function) ||
                (candidate.service_leases_by_name[service_name].size() >=
                 profile.max_per_function)) begin
                why = "VIO qpair per-service or per-function quota is exhausted";
                return 0;
            end

            lease.owner.kind = DPU_RESOURCE_OWNER_SERVICE;
            lease.owner.function_key = bindings[index].service_key.function_key;
            lease.owner.service_key = bindings[index].service_key;
            lease.local_id = bindings[index].local_pair_id;
            lease.class_id = qpair_class_id;
            lease.global_id = bindings[index].global_qpair_id;
            lease.frozen = 1;
            state.leases.push_back(lease);
            candidate.service_leases_by_name[service_name].push_back(lease);
            candidate.service_local_to_global_qpair[service_name][qpair_class_id][
                lease.local_id] = lease.global_id;
            candidate.active_global_ids[qpair_class_id][lease.global_id] = 1;
            candidate.class_allocated_count[qpair_class_id] = class_count + 1;
        end
        resource_snapshot.list_af_extra_queue_bindings(af_extra_bindings);
        foreach (af_extra_bindings[index]) begin
            dpu_resource_function_state state;
            dpu_resource_pool_config_t profile;
            dpu_resource_lease_t lease;
            int unsigned class_count;
            int unsigned function_count;

            if (!candidate.lookup_function_state(
                    af_extra_bindings[index].af_function_key, state, why))
                return 0;
            profile = candidate.resource_profiles_by_id[qpair_class_id];
            if (af_extra_bindings[index].global_qpair_id >= profile.capacity) begin
                why = "AF extra queue global ID exceeds imported profile capacity";
                return 0;
            end
            if (candidate.active_global_ids[qpair_class_id].exists(
                    af_extra_bindings[index].global_qpair_id)) begin
                why = "AF extra queue global ID is duplicated in resource snapshot";
                return 0;
            end
            class_count = candidate.allocated_count(qpair_class_id);
            function_count = candidate.function_class_lease_count(
                state, qpair_class_id);
            if (class_count >= profile.capacity) begin
                why = "AF extra queue exhausted resource-class capacity";
                return 0;
            end
            if (function_count >= profile.max_per_function) begin
                why = "AF extra queue exhausted per-function qpair capacity";
                return 0;
            end
            lease.owner.kind = DPU_RESOURCE_OWNER_FUNCTION;
            lease.owner.function_key =
                af_extra_bindings[index].af_function_key;
            lease.owner.service_key.function_key =
                af_extra_bindings[index].af_function_key;
            lease.owner.service_key.service_kind = DPU_SERVICE_VIO_NET;
            lease.owner.service_key.service_instance_id = 0;
            lease.local_id = af_extra_bindings[index].local_queue_index;
            lease.class_id = qpair_class_id;
            lease.global_id = af_extra_bindings[index].global_qpair_id;
            lease.frozen = 1;
            state.leases.push_back(lease);
            candidate.active_global_ids[qpair_class_id][lease.global_id] = 1;
            candidate.class_allocated_count[qpair_class_id] = class_count + 1;
        end
        if (!candidate.seal_resource_classes_internal(why))
            return 0;

        dut_caps.copy_from(candidate.dut_caps);
        function_states = candidate.function_states;
        class_id_by_name = candidate.class_id_by_name;
        resource_profiles_by_id = candidate.resource_profiles_by_id;
        class_allocated_count = candidate.class_allocated_count;
        active_global_ids = candidate.active_global_ids;
        service_leases_by_name = candidate.service_leases_by_name;
        service_local_to_global_qpair = candidate.service_local_to_global_qpair;
        next_resource_class_id = candidate.next_resource_class_id;
        resource_classes_sealed = candidate.resource_classes_sealed;
        configured_snapshot = device_snapshot;
        configured_resource_snapshot = resource_snapshot;
        snapshot_configured = 1;
        why = "";
        return 1;
    endfunction

    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps snapshot;
        snapshot = dpu_dut_caps::type_id::create("dut_caps_snapshot");
        snapshot.copy_from(dut_caps);
        return snapshot;
    endfunction

    // Snapshot profile IDs are externally visible lease/query identities.
    // Unlike legacy registration, importing must retain them exactly.
    protected function bit register_imported_resource_profile(
        input dpu_resource_pool_config_t profile,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        class_id = profile.class_id;
        why = "";
        if (resource_classes_sealed) begin
            why = "resource-class registry is sealed";
            return 0;
        end
        if (profile.capacity == 0) begin
            why = "resource-class capacity must be nonzero";
            return 0;
        end
        if (profile.max_per_function == 0) begin
            why = "resource-class per-function quota must be nonzero";
            return 0;
        end
        if (class_id_by_name.exists(profile.name)) begin
            why = "resource snapshot has a duplicate profile name";
            return 0;
        end
        if (resource_profiles_by_id.exists(profile.class_id)) begin
            why = "resource snapshot has a duplicate profile class ID";
            return 0;
        end
        class_id_by_name[profile.name] = profile.class_id;
        resource_profiles_by_id[profile.class_id] = profile;
        class_allocated_count[profile.class_id] = 0;
        if (next_resource_class_id <= profile.class_id)
            next_resource_class_id = profile.class_id + 1;
        return 1;
    endfunction

    function bit lookup_resource_class(
        input string name,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        class_id = '0;
        if (!class_id_by_name.exists(name)) begin
            why = "resource-class name is not registered";
            return 0;
        end

        class_id = class_id_by_name[name];
        why = "";
        return 1;
    endfunction

    // Clients may bind only to functions already owned by the device
    // registry.  This is intentionally read-only: protocol environments do
    // not author topology or register functions themselves.
    function bit contains_function(input dpu_function_key_t key);
        return function_states.exists(function_key_name(key));
    endfunction

    function bit is_snapshot_seeded();
        return snapshot_configured;
    endfunction

    function bit is_seeded_from_snapshots(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot
    );
        return snapshot_configured && (device_snapshot != null) &&
               (resource_snapshot != null) &&
               (configured_snapshot == device_snapshot) &&
               (configured_resource_snapshot == resource_snapshot);
    endfunction

    function bit local_pair_to_global_qpair(
        input dpu_service_key_t service_key,
        input dpu_resource_class_id_t class_id,
        input int unsigned local_pair_id,
        output int unsigned global_qpair_id
    );
        string service_name;

        global_qpair_id = '0;
        service_name = dpu_service_key_name(service_key);
        if (!service_local_to_global_qpair.exists(service_name) ||
            !service_local_to_global_qpair[service_name].exists(class_id) ||
            !service_local_to_global_qpair[service_name][class_id].exists(
                local_pair_id))
            return 0;
        global_qpair_id = service_local_to_global_qpair[service_name][class_id][
            local_pair_id];
        return 1;
    endfunction

    function void list_service_leases(
        input dpu_service_key_t service_key,
        ref dpu_resource_lease_t leases[$]
    );
        dpu_resource_lease_t swap;
        string service_name;

        leases.delete();
        service_name = dpu_service_key_name(service_key);
        if (!service_leases_by_name.exists(service_name))
            return;
        leases = service_leases_by_name[service_name];
        for (int left = 0; left < leases.size(); left++) begin
            for (int right = left + 1; right < leases.size(); right++) begin
                if ((leases[right].local_id < leases[left].local_id) ||
                    ((leases[right].local_id == leases[left].local_id) &&
                     (leases[right].class_id < leases[left].class_id))) begin
                    swap = leases[left];
                    leases[left] = leases[right];
                    leases[right] = swap;
                end
            end
        end
    endfunction

    function void list_function_leases(
        input dpu_function_key_t function_key,
        ref dpu_resource_lease_t leases[$]
    );
        dpu_resource_function_state state;
        dpu_resource_lease_t swap;
        string why;

        leases.delete();
        if (!lookup_function_state(function_key, state, why))
            return;
        leases = state.leases;
        for (int left = 0; left < leases.size(); left++) begin
            for (int right = left + 1; right < leases.size(); right++) begin
                if ((leases[right].local_id < leases[left].local_id) ||
                    ((leases[right].local_id == leases[left].local_id) &&
                     (leases[right].owner.kind < leases[left].owner.kind))) begin
                    swap = leases[left];
                    leases[left] = leases[right];
                    leases[right] = swap;
                end
            end
        end
    endfunction

    protected function bit seal_resource_classes_internal(output string why);
        resource_classes_sealed = 1;
        why = "";
        return 1;
    endfunction

endclass : dpu_resource_manager

`endif // DPU_RESOURCE_MANAGER_SV
