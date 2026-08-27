`ifndef VIRTIO_PF_INSTANCE_SV
`define VIRTIO_PF_INSTANCE_SV

// Bridges an Admin-VQ full-reset request to the owner of the real PF
// lifecycle.  Success means normal PF queue/DMA state was invalidated after a
// verified transport reset; Admin VQ does not own or infer this lifecycle.
class virtio_pf_lifecycle_reset_owner extends virtio_admin_full_reset_owner;
    `uvm_object_utils(virtio_pf_lifecycle_reset_owner)

    virtio_function_instance pf_function;

    function new(string name = "virtio_pf_lifecycle_reset_owner");
        super.new(name);
    endfunction

    virtual task reset_pf_lifecycle(ref bit reset_complete);
        reset_complete = 0;
        if (pf_function == null) begin
            `uvm_error("PF_RESET_OWNER",
                "full PF reset owner has no bound normal PF lifecycle")
            return;
        end

        pf_function.reset_pf_lifecycle(reset_complete);
    endtask
endclass : virtio_pf_lifecycle_reset_owner

// Owns one independently addressable PF function and its subordinate VFs.
class virtio_pf_instance extends uvm_component;
    `uvm_component_utils(virtio_pf_instance)

    int unsigned                host_id;
    int unsigned                pf_id;
    dpu_function_key_t          pf_key;
    dpu_function_key_t          vf_keys[];
    virtio_function_instance    pf_function;
    virtio_vf_instance          vf_functions[];
    virtio_pf_manager           pf_manager;
    virtio_pf_lifecycle_reset_owner lifecycle_reset_owner;
    protected bit               configuration_valid;
    protected bit               services_configured;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        configuration_valid = 0;
        services_configured = 0;
    endfunction

    function bit configure_services(
        input dpu_function_key_t parent_pf_key,
        input dpu_device_snapshot snapshot,
        input dpu_service_key_t service_keys[$],
        input dpu_resource_manager manager,
        output string why
    );
        dpu_function_key_t owner;
        dpu_pcie_function_id_t pcie_id;
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_role_e required_roles[$];
        dpu_function_key_t seen_owners[$];
        dpu_function_key_t resolved_owners[$];
        dpu_resource_class_id_t qpair_class_id;
        dpu_dut_caps snapshot_caps;
        dpu_dut_caps manager_caps;
        bit owner_seen;
        int unsigned vf_count;

        why = "";
        if (services_configured) begin
            why = "PF service group is already configured";
            return 0;
        end
        if ((parent_pf_key.kind != DPU_FUNCTION_PF) ||
            (parent_pf_key.vf_id != 0)) begin
            why = "VIO service group requires a PF parent key";
            return 0;
        end
        if ((snapshot == null) || !snapshot.is_frozen()) begin
            why = "VIO service group requires a frozen device snapshot";
            return 0;
        end
        if (manager == null) begin
            why = "VIO service group requires a device resource manager";
            return 0;
        end
        if (!manager.is_snapshot_seeded()) begin
            why = "VIO service group requires a snapshot-seeded device manager";
            return 0;
        end
        if (!manager.is_seeded_from_snapshot(snapshot)) begin
            why = "VIO service group manager belongs to a different snapshot";
            return 0;
        end
        if (!manager.lookup_resource_class(
                "virtio.qpair", qpair_class_id, why)) begin
            why = {"VIO service group requires virtio.qpair: ", why};
            return 0;
        end
        snapshot_caps = snapshot.snapshot_dut_caps();
        manager_caps = manager.snapshot_dut_caps();
        if ((snapshot_caps == null) || !snapshot_caps.validate(why)) begin
            why = {"VIO service group snapshot capabilities are invalid: ", why};
            return 0;
        end
        if ((manager_caps == null) || !manager_caps.validate(why)) begin
            why = {"VIO service group manager capabilities are invalid: ", why};
            return 0;
        end
        if ((manager_caps.max_hosts != snapshot_caps.max_hosts) ||
            (manager_caps.max_pfs_per_host != snapshot_caps.max_pfs_per_host) ||
            (manager_caps.max_vfs_per_pf != snapshot_caps.max_vfs_per_pf) ||
            (manager_caps.max_functions != snapshot_caps.max_functions) ||
            (manager_caps.global_msix_vector_count !=
             snapshot_caps.global_msix_vector_count) ||
            (manager_caps.vio_global_qpair_count !=
             snapshot_caps.vio_global_qpair_count) ||
            (manager_caps.max_vio_net_qpairs_per_device !=
             snapshot_caps.max_vio_net_qpairs_per_device) ||
            (manager_caps.vio_notify_entries_per_bank !=
             snapshot_caps.vio_notify_entries_per_bank) ||
            (manager_caps.bar_profiles.size() !=
             snapshot_caps.bar_profiles.size())) begin
            why = "VIO service group manager capabilities differ from snapshot";
            return 0;
        end
        foreach (snapshot_caps.bar_profiles[index]) begin
            dpu_bar_profile_t manager_profile;
            dpu_bar_profile_t snapshot_profile;

            snapshot_profile = snapshot_caps.bar_profiles[index];
            if (!manager_caps.lookup_bar_profile(
                    snapshot_profile.kind, snapshot_profile.role,
                    manager_profile, why) ||
                (manager_profile.even_bar_id != snapshot_profile.even_bar_id) ||
                (manager_profile.size != snapshot_profile.size) ||
                (manager_profile.alignment != snapshot_profile.alignment)) begin
                why = "VIO service group manager BAR capabilities differ from snapshot";
                return 0;
            end
        end
        if (service_keys.size() == 0) begin
            why = "VIO service group is empty";
            return 0;
        end
        required_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        required_roles.push_back(DPU_BAR_MAILBOX);
        required_roles.push_back(DPU_BAR_MSIX);

        foreach (service_keys[index]) begin
            if (service_keys[index].service_kind != DPU_SERVICE_VIO_NET) begin
                why = "VIO service group contains a non-VIO service";
                return 0;
            end
            if (!snapshot.get_service_owner(service_keys[index], owner, why))
                return 0;
            if ((owner.host_id != parent_pf_key.host_id) ||
                (owner.pf_id != parent_pf_key.pf_id) ||
                ((owner.kind != DPU_FUNCTION_PF) &&
                 (owner.kind != DPU_FUNCTION_VF))) begin
                why = "VIO service owner does not belong to its PF group";
                return 0;
            end
            owner_seen = 0;
            foreach (seen_owners[seen_index]) begin
                if (dpu_same_function_key(seen_owners[seen_index], owner))
                    owner_seen = 1;
            end
            if (owner_seen) begin
                why = "VIO service group declares duplicate function ownership";
                return 0;
            end
            seen_owners.push_back(owner);
            if (!snapshot.get_pcie_id(owner, pcie_id, why))
                return 0;
            bars.delete();
            foreach (required_roles[role_index]) begin
                dpu_bar_pair_lease_t bar;

                if (!snapshot.get_bar(owner, required_roles[role_index], bar, why))
                    return 0;
                bars.push_back(bar);
            end
            if ((bars[0].role != DPU_BAR_DEVICE_MEMORY) ||
                (bars[1].role != DPU_BAR_MAILBOX) ||
                (bars[2].role != DPU_BAR_MSIX)) begin
                why = "VIO service owner BAR roles are not device-memory, mailbox, MSI-X";
                return 0;
            end
            if (!manager.contains_function(owner)) begin
                why = "snapshot-seeded manager does not contain VIO service owner";
                return 0;
            end
            resolved_owners.push_back(owner);
        end

        // No component or topology-view state is mutated before every service
        // dependency above has passed preflight.
        pf_key = parent_pf_key;
        host_id = parent_pf_key.host_id;
        pf_id = parent_pf_key.pf_id;
        vf_count = 0;
        foreach (seen_owners[index]) begin
            if (seen_owners[index].kind == DPU_FUNCTION_VF)
                vf_count++;
        end
        vf_keys = new[vf_count];
        vf_functions = new[vf_count];

        foreach (service_keys[index]) begin
            owner = resolved_owners[index];
            if (owner.kind == DPU_FUNCTION_PF) begin
                if (pf_function != null) begin
                    why = "VIO service group declares duplicate PF service";
                    return 0;
                end
                pf_function = virtio_function_instance::type_id::create(
                    "pf_function", this);
                if (!pf_function.configure_from_service(
                        snapshot, service_keys[index], manager)) begin
                    why = "could not configure resolved PF VIO function";
                    return 0;
                end
            end
            else begin
                int unsigned vf_index;

                vf_index = 0;
                while ((vf_index < vf_functions.size()) &&
                       (vf_functions[vf_index] != null))
                    vf_index++;
                vf_keys[vf_index] = owner;
                vf_functions[vf_index] = virtio_vf_instance::type_id::create(
                    $sformatf("vf_function_%0d", owner.vf_id), this);
                if (!vf_functions[vf_index].configure_from_service(
                        snapshot, service_keys[index], manager)) begin
                    why = "could not configure resolved VF VIO function";
                    return 0;
                end
            end
        end
        services_configured = 1;
        configuration_valid = 1;
        return 1;
    endfunction

    function void collect_functions(ref virtio_function_instance functions[$]);
        functions.delete();
        if (pf_function != null)
            functions.push_back(pf_function);
        foreach (vf_functions[index]) begin
            if (vf_functions[index] != null)
                functions.push_back(vf_functions[index]);
        end
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (!services_configured) begin
            `uvm_fatal("PF_INSTANCE",
                "PF instance requires snapshot-declared VIO services")
            return;
        end
        pf_manager = virtio_pf_manager::type_id::create("pf_manager");
        pf_manager.pf_index = pf_id;
        configuration_valid = 1;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        if (!configuration_valid)
            return;
        pf_manager.vf_instances = new[vf_functions.size()];
        foreach (vf_functions[vf_id])
            pf_manager.vf_instances[vf_id] = vf_functions[vf_id];
        if (pf_function != null) begin
            pf_manager.pf_transport = pf_function.transport;
            lifecycle_reset_owner = virtio_pf_lifecycle_reset_owner::type_id::create(
                "lifecycle_reset_owner"
            );
            lifecycle_reset_owner.pf_function = pf_function;
            pf_manager.configure_pf_lifecycle_reset_owner(lifecycle_reset_owner);
        end
    endfunction

endclass : virtio_pf_instance

`endif // VIRTIO_PF_INSTANCE_SV
