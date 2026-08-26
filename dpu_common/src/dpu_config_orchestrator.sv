`ifndef DPU_CONFIG_ORCHESTRATOR_SV
`define DPU_CONFIG_ORCHESTRATOR_SV

class dpu_config_orchestrator extends uvm_object;
    `uvm_object_utils(dpu_config_orchestrator)

    protected dpu_reg_executor executor;

    function new(string name = "dpu_config_orchestrator");
        super.new(name);
        executor = null;
    endfunction

    function void set_executor(input dpu_reg_executor new_executor);
        executor = new_executor;
    endfunction

    function void clear_executor();
        executor = null;
    endfunction

    function bit has_executor();
        return executor != null;
    endfunction

    task apply(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status,
        output string why
    );
        status = DPU_CFG_STATUS_PLAN_INVALID;
        why = "";
        if (plan == null) begin
            why = "configuration orchestrator received a null register plan";
            return;
        end
        if (!plan.freeze(why))
            return;

        if (executor == null) begin
            status = DPU_CFG_STATUS_NOT_EXECUTED;
            why = {"validated register plan was not executed because no ",
                   "executor is installed"};
            return;
        end
        if (!executor.preflight(plan, why)) begin
            status = DPU_CFG_STATUS_PREFLIGHT_FAILED;
            if (why == "")
                why = executor.last_error();
            if (why == "") begin
                why =
                    "register executor preflight failed without an error message";
            end
            return;
        end

        executor.execute(plan, status);
        case (status)
            DPU_CFG_STATUS_SUCCEEDED: why = "";
            DPU_CFG_STATUS_EXECUTION_FAILED: begin
                why = executor.last_error();
                if (why == "") begin
                    why = "register executor failed without an error message";
                end
            end
            default: begin
                status = DPU_CFG_STATUS_EXECUTION_FAILED;
                why = "register executor returned an invalid terminal status";
            end
        endcase
    endtask
endclass : dpu_config_orchestrator

`endif // DPU_CONFIG_ORCHESTRATOR_SV
