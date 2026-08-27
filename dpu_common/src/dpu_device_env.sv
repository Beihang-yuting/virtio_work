`ifndef DPU_DEVICE_ENV_SV
`define DPU_DEVICE_ENV_SV

class dpu_device_env_config extends uvm_object;
    `uvm_object_utils(dpu_device_env_config)

    dpu_device_cfg device_cfg;
    dpu_resource_pool_config_t resource_profiles[$];
    dpu_reg_executor executor;

    function new(string name = "dpu_device_env_config");
        super.new(name);
        device_cfg = dpu_device_cfg::type_id::create({name, "_device_cfg"});
        executor = null;
    endfunction
endclass : dpu_device_env_config


class dpu_device_env extends uvm_env;
    `uvm_component_utils(dpu_device_env)

    protected dpu_device_snapshot snapshot;
    protected dpu_resource_manager resource_manager;
    protected dpu_config_orchestrator orchestrator;
    protected dpu_device_state_e state;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        snapshot = null;
        resource_manager = null;
        orchestrator = null;
        state = DPU_DEVICE_UNRESOLVED;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_env_config cfg;
        dpu_device_resolver resolver;
        dpu_device_snapshot candidate_snapshot;
        dpu_resource_manager candidate_manager;
        dpu_resource_registry_authority authority;
        dpu_config_orchestrator candidate_orchestrator;
        string why;

        super.build_phase(phase);
        if (!uvm_config_db#(dpu_device_env_config)::get(this, "", "cfg", cfg)) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment configuration 'cfg' is missing")
            return;
        end
        if (cfg == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment configuration is null")
            return;
        end
        resolver = dpu_device_resolver::type_id::create("dpu_device_resolver");
        if (!resolver.resolve(cfg.device_cfg, candidate_snapshot, why)) begin
            `uvm_fatal("DPU_DEVICE_ENV", {"device resolution failed: ", why})
            return;
        end
        candidate_manager = dpu_resource_manager::type_id::create(
            "dpu_resource_manager"
        );
        authority = candidate_manager.claim_registry_authority();
        if (authority == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "resource manager authority claim failed")
            return;
        end
        if (!candidate_manager.configure_from_snapshot(
                authority, candidate_snapshot, cfg.resource_profiles, why)) begin
            `uvm_fatal("DPU_DEVICE_ENV", {"resource manager seeding failed: ", why})
            return;
        end
        candidate_orchestrator = dpu_config_orchestrator::type_id::create(
            "dpu_config_orchestrator");
        if (cfg.executor != null)
            candidate_orchestrator.set_executor(cfg.executor);

        snapshot = candidate_snapshot;
        resource_manager = candidate_manager;
        orchestrator = candidate_orchestrator;
        state = DPU_DEVICE_RESOLVED;
        uvm_config_db#(dpu_device_snapshot)::set(
            this, "*", "dpu_device_snapshot", snapshot
        );
        uvm_config_db#(dpu_resource_manager)::set(
            this, "*", "dpu_resource_manager", resource_manager
        );
    endfunction

    function dpu_device_snapshot get_snapshot();
        return snapshot;
    endfunction

    function dpu_resource_manager get_resource_manager();
        return resource_manager;
    endfunction

    function dpu_device_state_e get_state();
        return state;
    endfunction

    function bit build_bootstrap_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_device_bootstrap_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_RESOLVED) begin
            why = $sformatf(
                "bootstrap plan build requires RESOLVED state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_device_bootstrap_plan_builder::type_id::create(
            "dpu_device_bootstrap_plan_builder");
        return builder.build(snapshot, plan, why);
    endfunction

    task apply_bootstrap(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_RESOLVED) begin
            report = dpu_execution_report::type_id::create(
                "rejected_bootstrap_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "bootstrap apply requires RESOLVED state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED:
                state = DPU_DEVICE_ACTIVE;
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_RESOLVED;
        endcase
    endtask
endclass : dpu_device_env

`endif // DPU_DEVICE_ENV_SV
