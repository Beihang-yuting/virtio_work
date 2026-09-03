`ifndef DPU_DEVICE_ENV_SV
`define DPU_DEVICE_ENV_SV

class dpu_device_env_config extends uvm_object;
    `uvm_object_utils(dpu_device_env_config)

    dpu_device_cfg device_cfg;
    dpu_resource_placement_cfg placement_cfg;
    dpu_reg_executor executor;
    dpu_vio_register_plan_policy vio_policy;
    dpu_vio_dataplane_plan_extension vio_dataplane_extension;
    // Protocol-neutral ownership hook.  The DPU package does not depend on
    // Virtio Host-memory classes; consumers may publish a typed pool object
    // here and bind it after the snapshot is resolved.
    uvm_object host_mem_pool_ref;

    function new(string name = "dpu_device_env_config");
        super.new(name);
        device_cfg = dpu_device_cfg::type_id::create({name, "_device_cfg"});
        placement_cfg = dpu_resource_placement_cfg::type_id::create(
            {name, "_placement_cfg"});
        executor = null;
        vio_policy = dpu_vio_register_plan_policy::type_id::create(
            {name, "_vio_policy"});
        vio_dataplane_extension = null;
        host_mem_pool_ref = null;
    endfunction
endclass : dpu_device_env_config


class dpu_device_env extends uvm_env;
    `uvm_component_utils(dpu_device_env)

    protected dpu_device_snapshot snapshot;
    protected dpu_resource_snapshot resource_snapshot;
    protected dpu_resource_manager resource_manager;
    protected dpu_config_orchestrator orchestrator;
    protected dpu_vio_register_plan_policy vio_policy;
    protected dpu_vio_dataplane_plan_extension vio_dataplane_extension;
    protected int unsigned active_vio_notify_bank;
    protected dpu_device_state_e state;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        snapshot = null;
        resource_snapshot = null;
        resource_manager = null;
        orchestrator = null;
        vio_policy = null;
        vio_dataplane_extension = null;
        active_vio_notify_bank = 0;
        state = DPU_DEVICE_UNRESOLVED;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_env_config cfg;
        dpu_configuration_resolver configuration_resolver;
        dpu_device_snapshot candidate_snapshot;
        dpu_resource_snapshot candidate_resource_snapshot;
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
        candidate_manager = dpu_resource_manager::type_id::create(
            "dpu_resource_manager"
        );
        authority = candidate_manager.claim_registry_authority();
        if (authority == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "resource manager authority claim failed")
            return;
        end
        if (cfg.placement_cfg == null) begin
            `uvm_fatal("DPU_DEVICE_ENV", "device environment placement configuration is null")
            return;
        end
        begin
            dpu_placement_diagnostic diagnostic;

            configuration_resolver = dpu_configuration_resolver::type_id::create(
                "dpu_configuration_resolver");
            if (!configuration_resolver.resolve(
                    cfg.device_cfg, cfg.placement_cfg, candidate_snapshot,
                    candidate_resource_snapshot, diagnostic)) begin
                `uvm_fatal("DPU_DEVICE_ENV", {"configuration resolution failed: ",
                           diagnostic.message})
                return;
            end
            if (!candidate_manager.configure_from_snapshots(
                    authority, candidate_snapshot, candidate_resource_snapshot, why)) begin
                `uvm_fatal("DPU_DEVICE_ENV", {"resource manager seeding failed: ", why})
                return;
            end
        end
        candidate_orchestrator = dpu_config_orchestrator::type_id::create(
            "dpu_config_orchestrator");
        if (cfg.executor != null)
            candidate_orchestrator.set_executor(cfg.executor);

        snapshot = candidate_snapshot;
        resource_snapshot = candidate_resource_snapshot;
        resource_manager = candidate_manager;
        orchestrator = candidate_orchestrator;
        if (cfg.executor != null)
            cfg.executor.bind_topology(candidate_snapshot);
        if (cfg.vio_policy == null)
            vio_policy = dpu_vio_register_plan_policy::type_id::create(
                "dpu_device_env_vio_policy");
        else
            vio_policy = cfg.vio_policy;
        active_vio_notify_bank = vio_policy.active_notify_bank;
        vio_dataplane_extension = cfg.vio_dataplane_extension;
        state = DPU_DEVICE_RESOLVED;
        uvm_config_db#(dpu_device_snapshot)::set(
            this, "*", "dpu_device_snapshot", snapshot
        );
        uvm_config_db#(dpu_resource_snapshot)::set(
            this, "*", "dpu_resource_snapshot", resource_snapshot
        );
        uvm_config_db#(dpu_resource_manager)::set(
            this, "*", "dpu_resource_manager", resource_manager
        );
        if (cfg.host_mem_pool_ref != null)
            uvm_config_db#(uvm_object)::set(
                this, "*", "dpu_host_mem_pool", cfg.host_mem_pool_ref
            );
    endfunction

    function dpu_device_snapshot get_snapshot();
        return snapshot;
    endfunction

    function dpu_resource_manager get_resource_manager();
        return resource_manager;
    endfunction

    function dpu_resource_snapshot get_resource_snapshot();
        return resource_snapshot;
    endfunction

    function dpu_device_state_e get_state();
        return state;
    endfunction

    protected function bit find_vio_notify_commit_bank(
        input dpu_reg_plan plan,
        input bit teardown,
        output int unsigned bank
    );
        dpu_reg_op bank0_op;
        dpu_reg_op bank1_op;
        bit has_bank0;
        bit has_bank1;

        bank = 0;
        if (plan == null)
            return 0;
        if (teardown) begin
            has_bank0 = plan.find_operation(
                "vio.teardown.notify.commit.bank0", bank0_op);
            has_bank1 = plan.find_operation(
                "vio.teardown.notify.commit.bank1", bank1_op);
        end else begin
            has_bank0 = plan.find_operation(
                "vio.notify.commit.bank0", bank0_op);
            has_bank1 = plan.find_operation(
                "vio.notify.commit.bank1", bank1_op);
        end
        if (has_bank0 == has_bank1)
            return 0;
        bank = has_bank1 ? 1 : 0;
        return 1;
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

    function bit build_vio_register_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_vio_register_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_RESOLVED) begin
            why = $sformatf(
                "VIO register plan build requires RESOLVED state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_vio_register_plan_builder::type_id::create(
            "dpu_vio_register_plan_builder");
        vio_policy.active_notify_bank = active_vio_notify_bank;
        builder.set_policy(vio_policy);
        builder.set_dataplane_extension(vio_dataplane_extension);
        return builder.build(snapshot, resource_snapshot, plan, why);
    endfunction

    task apply_vio_register_plan(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_RESOLVED) begin
            report = dpu_execution_report::type_id::create(
                "rejected_vio_register_plan_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "VIO register plan apply requires RESOLVED state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_vio_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED: begin
                int unsigned committed_bank;
                if (find_vio_notify_commit_bank(
                        plan, 0, committed_bank)) begin
                    active_vio_notify_bank = committed_bank;
                    vio_policy.active_notify_bank = committed_bank;
                end
                state = DPU_DEVICE_ACTIVE;
            end
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_RESOLVED;
        endcase
    endtask

    function bit build_vio_teardown_plan(
        output dpu_reg_plan plan,
        output string why
    );
        dpu_vio_register_plan_builder builder;

        plan = null;
        why = "";
        if (state != DPU_DEVICE_ACTIVE) begin
            why = $sformatf(
                "VIO teardown plan build requires ACTIVE state, current state is %0d",
                state);
            return 0;
        end
        builder = dpu_vio_register_plan_builder::type_id::create(
            "dpu_vio_teardown_plan_builder");
        vio_policy.active_notify_bank = active_vio_notify_bank;
        builder.set_policy(vio_policy);
        return builder.build_teardown(
            snapshot, resource_snapshot, plan, why);
    endfunction

    task apply_vio_teardown_plan(
        input dpu_reg_plan plan,
        output dpu_execution_report report
    );
        if (state != DPU_DEVICE_ACTIVE) begin
            report = dpu_execution_report::type_id::create(
                "rejected_vio_teardown_plan_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                $sformatf(
                    "VIO teardown plan apply requires ACTIVE state, current state is %0d",
                    state));
            return;
        end
        if (orchestrator == null) begin
            report = dpu_execution_report::type_id::create(
                "missing_vio_teardown_orchestrator_report");
            report.set_terminal(
                DPU_CFG_STATUS_PLAN_INVALID,
                "device environment has no configuration orchestrator");
            return;
        end

        state = DPU_DEVICE_APPLYING;
        orchestrator.apply_with_report(plan, report);
        case (report.status())
            DPU_CFG_STATUS_SUCCEEDED: begin
                int unsigned committed_bank;
                if (find_vio_notify_commit_bank(
                        plan, 1, committed_bank)) begin
                    active_vio_notify_bank = committed_bank;
                    vio_policy.active_notify_bank = committed_bank;
                end
                state = DPU_DEVICE_RESOLVED;
            end
            DPU_CFG_STATUS_EXECUTION_FAILED:
                state = DPU_DEVICE_FAILED;
            default:
                state = DPU_DEVICE_ACTIVE;
        endcase
    endtask
endclass : dpu_device_env

`endif // DPU_DEVICE_ENV_SV
