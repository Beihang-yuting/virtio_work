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
    bit                activated;
    bit                device_ready;
    bit                frozen;
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

    protected function bit local_range_overlaps_existing_lease(
        input dpu_resource_function_state state,
        input dpu_resource_class_id_t class_id,
        input int unsigned first_local_id,
        input int unsigned last_local_id
    );
        for (int unsigned index = 0; index < state.leases.size(); index++) begin
            if ((state.leases[index].class_id == class_id) &&
                (state.leases[index].local_id >= first_local_id) &&
                (state.leases[index].local_id <= last_local_id))
                return 1;
        end
        return 0;
    endfunction

    protected function int unsigned allocated_count(
        input dpu_resource_class_id_t class_id
    );
        if (class_allocated_count.exists(class_id))
            return class_allocated_count[class_id];
        return 0;
    endfunction

    protected function bit allocate_global_ids(
        input dpu_resource_class_id_t class_id,
        input int unsigned capacity,
        input int unsigned count,
        ref int unsigned global_ids[$],
        output string why
    );
        global_ids.delete();
        why = "";

        for (int unsigned candidate = 0;
             candidate < capacity;
             candidate++) begin
            if (!active_global_ids[class_id].exists(candidate)) begin
                global_ids.push_back(candidate);
                if (global_ids.size() == count)
                    return 1;
            end
        end

        global_ids.delete();
        why = "resource-class active IDs are inconsistent with capacity";
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
        function_states[key_name].activated = 1;
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

    function bit configure_from_snapshot(
        input dpu_resource_registry_authority authority,
        input dpu_device_snapshot snapshot,
        input dpu_resource_pool_config_t profiles[$],
        output string why
    );
        dpu_resource_manager candidate;
        dpu_dut_caps caps;
        dpu_function_key_t function_keys[$];
        dpu_resource_class_id_t class_id;

        why = "";
        if (!registry_authority_claimed || (authority == null) ||
            (authority != registry_authority)) begin
            why = "snapshot configuration requires the device registry authority";
            return 0;
        end
        if (snapshot_configured) begin
            why = "resource manager has already been configured from a snapshot";
            return 0;
        end
        if ((snapshot == null) || !snapshot.is_frozen()) begin
            why = "device snapshot is not a frozen snapshot";
            return 0;
        end
        caps = snapshot.snapshot_dut_caps();
        if ((caps == null) || !caps.validate(why))
            return 0;

        candidate = new({get_name(), "_snapshot_candidate"});
        candidate.dut_caps.copy_from(caps);
        snapshot.list_functions(function_keys);
        foreach (function_keys[index]) begin
            if (!candidate.seed_function(function_keys[index], why))
                return 0;
        end
        foreach (profiles[index]) begin
            if (!candidate.register_resource_class_internal(
                    profiles[index].name, profiles[index].kind,
                    profiles[index].capacity, profiles[index].max_per_function,
                    class_id, why))
                return 0;
        end
        if (!candidate.seal_resource_classes_internal(why))
            return 0;

        dut_caps.copy_from(candidate.dut_caps);
        function_states = candidate.function_states;
        class_id_by_name = candidate.class_id_by_name;
        resource_profiles_by_id = candidate.resource_profiles_by_id;
        class_allocated_count = candidate.class_allocated_count;
        active_global_ids.delete();
        next_resource_class_id = candidate.next_resource_class_id;
        resource_classes_sealed = candidate.resource_classes_sealed;
        configured_snapshot = snapshot;
        snapshot_configured = 1;
        return 1;
    endfunction

    function dpu_dut_caps snapshot_dut_caps();
        dpu_dut_caps snapshot;
        snapshot = dpu_dut_caps::type_id::create("dut_caps_snapshot");
        snapshot.copy_from(dut_caps);
        return snapshot;
    endfunction

    protected function bit register_resource_class_internal(
        input string name,
        input dpu_resource_kind_e kind,
        input int unsigned capacity,
        input int unsigned max_per_function,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        dpu_resource_pool_config_t existing;

        class_id = '0;
        why = "";
        if (resource_classes_sealed) begin
            why = "resource-class registry is sealed";
            return 0;
        end
        if (capacity == 0) begin
            why = "resource-class capacity must be nonzero";
            return 0;
        end
        if (max_per_function == 0) begin
            why = "resource-class per-function quota must be nonzero";
            return 0;
        end

        if (class_id_by_name.exists(name)) begin
            class_id = class_id_by_name[name];
            existing = resource_profiles_by_id[class_id];
            if ((existing.kind != kind) ||
                (existing.capacity != capacity) ||
                (existing.max_per_function != max_per_function)) begin
                why = "resource-class name collides with a different profile";
                return 0;
            end
            return 1;
        end

        class_id = next_resource_class_id;
        next_resource_class_id++;
        class_id_by_name[name] = class_id;
        resource_profiles_by_id[class_id].name = name;
        resource_profiles_by_id[class_id].class_id = class_id;
        resource_profiles_by_id[class_id].kind = kind;
        resource_profiles_by_id[class_id].capacity = capacity;
        resource_profiles_by_id[class_id].max_per_function = max_per_function;
        class_allocated_count[class_id] = 0;
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

    function bit is_seeded_from_snapshot(input dpu_device_snapshot snapshot);
        return snapshot_configured && (snapshot != null) &&
               (configured_snapshot == snapshot);
    endfunction

    protected function bit seal_resource_classes_internal(output string why);
        resource_classes_sealed = 1;
        why = "";
        return 1;
    endfunction

    function bit mark_function_device_ready(
        input dpu_function_key_t key,
        output string why
    );
        dpu_resource_function_state state;

        if (!lookup_function_state(key, state, why))
            return 0;
        if (!state.activated) begin
            why = "function must be activated before it becomes device-ready";
            return 0;
        end
        if (state.frozen) begin
            why = "frozen function cannot become device-ready";
            return 0;
        end

        state.device_ready = 1;
        why = "";
        return 1;
    endfunction

    function bit acquire_leases(
        input dpu_function_key_t key,
        input dpu_resource_class_id_t class_id,
        input int unsigned first_local_id,
        input int unsigned count,
        ref dpu_resource_lease_t leases[$],
        output string why
    );
        dpu_resource_function_state state;
        dpu_resource_pool_config_t profile;
        dpu_resource_lease_t lease;
        int unsigned current_function_count;
        int unsigned current_class_count;
        int unsigned last_local_id;
        int unsigned global_ids[$];

        leases.delete();
        if (!lookup_function_state(key, state, why))
            return 0;
        if (!state.activated || !state.device_ready) begin
            why = "function is not device-ready";
            return 0;
        end
        if (state.frozen) begin
            why = "frozen function cannot acquire resource leases";
            return 0;
        end
        if (!resource_profiles_by_id.exists(class_id)) begin
            why = "resource-class ID is not registered";
            return 0;
        end
        if (count == 0) begin
            why = "lease count must be nonzero";
            return 0;
        end
        if (first_local_id > (32'hffff_ffff - (count - 1))) begin
            why = "local resource ID range overflows";
            return 0;
        end
        last_local_id = first_local_id + (count - 1);

        if (local_range_overlaps_existing_lease(
            state, class_id, first_local_id, last_local_id
        )) begin
            why = "local resource ID is already leased by this function";
            return 0;
        end

        profile = resource_profiles_by_id[class_id];
        current_function_count = function_class_lease_count(state, class_id);
        if ((current_function_count > profile.max_per_function) ||
            ((profile.max_per_function - current_function_count) < count)) begin
            why = "resource-class per-function quota would be exceeded";
            return 0;
        end
        current_class_count = allocated_count(class_id);
        if ((current_class_count > profile.capacity) ||
            ((profile.capacity - current_class_count) < count)) begin
            why = "resource-class capacity would be exceeded";
            return 0;
        end

        if (!allocate_global_ids(
            class_id, profile.capacity, count, global_ids, why
        )) begin
            return 0;
        end

        for (int unsigned offset = 0; offset < count; offset++) begin
            lease.owner = key;
            lease.local_id = first_local_id + offset;
            lease.class_id = class_id;
            lease.global_id = global_ids[offset];
            lease.frozen = 0;
            active_global_ids[class_id][lease.global_id] = 1;
            state.leases.push_back(lease);
            leases.push_back(lease);
        end
        class_allocated_count[class_id] = current_class_count + count;
        why = "";
        return 1;
    endfunction

    function bit release_leases(
        input dpu_function_key_t key,
        input dpu_resource_class_id_t class_id,
        output string why
    );
        dpu_resource_function_state state;
        int unsigned released_count;

        if (!lookup_function_state(key, state, why))
            return 0;
        if (state.frozen) begin
            why = "frozen function cannot release resource leases";
            return 0;
        end
        if (!resource_profiles_by_id.exists(class_id)) begin
            why = "resource-class ID is not registered";
            return 0;
        end

        released_count = 0;
        for (int index = state.leases.size(); index > 0; index--) begin
            if (state.leases[index - 1].class_id == class_id) begin
                active_global_ids[class_id].delete(
                    state.leases[index - 1].global_id
                );
                state.leases.delete(index - 1);
                released_count++;
            end
        end
        class_allocated_count[class_id] =
            allocated_count(class_id) - released_count;
        why = "";
        return 1;
    endfunction

    function bit freeze_function(
        input dpu_function_key_t key,
        output string why
    );
        dpu_resource_function_state state;

        if (!lookup_function_state(key, state, why))
            return 0;

        state.frozen = 1;
        for (int unsigned index = 0; index < state.leases.size(); index++)
            state.leases[index].frozen = 1;
        why = "";
        return 1;
    endfunction

    function bit restore_function(
        input dpu_function_key_t key,
        output string why
    );
        dpu_resource_function_state state;

        if (!lookup_function_state(key, state, why))
            return 0;

        state.frozen = 0;
        for (int unsigned index = 0; index < state.leases.size(); index++)
            state.leases[index].frozen = 0;
        why = "";
        return 1;
    endfunction

    function bit local_to_global(
        input dpu_function_key_t key,
        input dpu_resource_class_id_t class_id,
        input int unsigned local_id,
        output int unsigned global_id
    );
        dpu_resource_function_state state;
        string ignored_why;

        global_id = '0;
        if (!lookup_function_state(key, state, ignored_why))
            return 0;

        for (int unsigned index = 0; index < state.leases.size(); index++) begin
            if ((state.leases[index].class_id == class_id) &&
                (state.leases[index].local_id == local_id)) begin
                global_id = state.leases[index].global_id;
                return 1;
            end
        end
        return 0;
    endfunction
endclass : dpu_resource_manager

`endif // DPU_RESOURCE_MANAGER_SV
