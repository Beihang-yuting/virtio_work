`ifndef DPU_FABRIC_ENV_SV
`define DPU_FABRIC_ENV_SV

// =============================================================================
// DPU Fabric environment
//
// The Fabric environment is the configuration-time owner of resource-class
// registration.  Consumers receive its manager from config_db and only look
// up opaque class IDs before requesting leases.
// =============================================================================

class dpu_fabric_env_config extends uvm_object;
    `uvm_object_utils(dpu_fabric_env_config)

    dpu_resource_pool_config_t resource_profiles[$];

    function new(string name = "dpu_fabric_env_config");
        super.new(name);
    endfunction
endclass : dpu_fabric_env_config


class dpu_fabric_env extends uvm_env;
    `uvm_component_utils(dpu_fabric_env)

    protected dpu_resource_manager resource_manager;
    protected dpu_resource_fabric_authority registry_authority;
    protected bit                  resource_profiles_applied;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        resource_profiles_applied = 0;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        resource_manager = dpu_resource_manager::type_id::create(
            "dpu_resource_manager"
        );
        registry_authority = resource_manager.claim_fabric_registry_authority();
        if (registry_authority == null)
            `uvm_fatal("DPU_RESOURCE", "DPU Fabric could not claim registry authority")
        uvm_config_db#(dpu_resource_manager)::set(
            this, "", "dpu_resource_manager", resource_manager
        );
        uvm_config_db#(dpu_resource_manager)::set(
            this, "*", "dpu_resource_manager", resource_manager
        );
    endfunction

    function bit apply_resource_profiles(
        input dpu_fabric_env_config cfg,
        output string why
    );
        dpu_resource_class_id_t class_id;

        why = "";
        if (resource_manager == null) begin
            why = "DPU Fabric manager has not been created";
            return 0;
        end
        if (resource_profiles_applied) begin
            why = "DPU Fabric resource profiles have already been applied";
            return 0;
        end
        if (cfg == null) begin
            why = "DPU Fabric resource profile configuration is null";
            return 0;
        end
        if (resource_manager.has_activated_functions()) begin
            why = "DPU Fabric resource profiles cannot be applied after activation";
            return 0;
        end

        for (int unsigned index = 0;
             index < cfg.resource_profiles.size(); index++) begin
            if (!resource_manager.fabric_register_resource_class(
                registry_authority,
                cfg.resource_profiles[index].name,
                cfg.resource_profiles[index].kind,
                cfg.resource_profiles[index].capacity,
                cfg.resource_profiles[index].max_per_function,
                class_id,
                why
            ))
                return 0;
        end
        if (!resource_manager.fabric_seal_resource_classes(registry_authority, why))
            return 0;

        resource_profiles_applied = 1;
        return 1;
    endfunction

    function bit lookup_resource_class(
        input string name,
        output dpu_resource_class_id_t class_id,
        output string why
    );
        if (resource_manager == null) begin
            class_id = '0;
            why = "DPU Fabric manager has not been created";
            return 0;
        end
        return resource_manager.lookup_resource_class(name, class_id, why);
    endfunction
endclass : dpu_fabric_env

`endif // DPU_FABRIC_ENV_SV
