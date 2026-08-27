`ifndef DPU_SPY_REG_EXECUTOR_SV
`define DPU_SPY_REG_EXECUTOR_SV

class dpu_spy_reg_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_spy_reg_executor)

    protected dpu_reg_op recorded_operations[$];
    protected dpu_reg_op_result_e recorded_results[$];
    protected string failed_operation_id;
    protected string authorized_failed_operation_id;
    protected string preflight_failure_text;
    protected bit preflight_called;
    protected bit preflight_empty_history;
    protected bit preflight_succeeded;
    protected dpu_reg_plan preflight_plan;
    protected bit execute_authorization_consumed;

    function new(string name = "dpu_spy_reg_executor");
        super.new(name);
        recorded_operations.delete();
        recorded_results.delete();
        failed_operation_id = "";
        authorized_failed_operation_id = "";
        preflight_failure_text = "";
        preflight_called = 0;
        preflight_empty_history = 0;
        preflight_succeeded = 0;
        preflight_plan = null;
        execute_authorization_consumed = 0;
    endfunction

    local function bit copy_operation(
        input dpu_reg_op source,
        input string expected_id,
        output dpu_reg_op copied,
        output string why
    );
        copied = null;
        why = "";
        if (source == null) begin
            why = $sformatf(
                "failed to copy spy operation %s", expected_id);
            return 0;
        end

        copied = source.copy_op(expected_id);
        if (copied == null) begin
            why = $sformatf(
                "failed to copy spy operation %s", expected_id);
            return 0;
        end
        if (copied.op_id != expected_id) begin
            why = $sformatf(
                "spy operation copy ID %s does not match expected ID %s",
                copied.op_id, expected_id);
            copied = null;
            return 0;
        end
        return 1;
    endfunction

    function void reset_history();
        recorded_operations.delete();
        recorded_results.delete();
        preflight_called = 0;
        preflight_empty_history = 0;
        preflight_succeeded = 0;
        preflight_plan = null;
        execute_authorization_consumed = 0;
        failed_operation_id = "";
        authorized_failed_operation_id = "";
        preflight_failure_text = "";
        set_last_error("");
    endfunction

    function void fail_operation(input string op_id);
        failed_operation_id = op_id;
    endfunction

    function void fail_preflight(input string why);
        preflight_failure_text = why;
    endfunction

    function int unsigned record_count();
        return recorded_operations.size();
    endfunction

    function bit preflight_history_was_empty();
        return preflight_empty_history;
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        dpu_reg_op injected_failure_operation;

        preflight_called = 1;
        preflight_empty_history =
            (recorded_operations.size() == 0) &&
            (recorded_results.size() == 0);
        preflight_succeeded = 0;
        preflight_plan = null;
        authorized_failed_operation_id = "";
        execute_authorization_consumed = 0;
        why = "";
        set_last_error("");
        if (plan == null) begin
            why = "spy executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "spy executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        if (preflight_failure_text != "") begin
            why = preflight_failure_text;
            set_last_error(why);
            return 0;
        end
        if ((failed_operation_id != "") &&
            !plan.find_operation(
                failed_operation_id, injected_failure_operation)) begin
            why = $sformatf(
                "spy failure operation %s is not in the register plan",
                failed_operation_id);
            set_last_error(why);
            return 0;
        end
        preflight_succeeded = 1;
        preflight_plan = plan;
        authorized_failed_operation_id = failed_operation_id;
        return 1;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op ordered[$];
        dpu_reg_op recorded_copy;
        dpu_reg_op staged_operations[$];
        dpu_reg_op_result_e staged_results[$];
        dpu_reg_plan execution_plan;
        string execution_failed_operation_id;
        string why;

        status = DPU_CFG_STATUS_EXECUTION_FAILED;
        if (!preflight_called) begin
            set_last_error("spy executor execute called before preflight");
            return;
        end
        if (execute_authorization_consumed) begin
            set_last_error(
                "spy executor execute authorization was already consumed");
            return;
        end
        if (!preflight_succeeded) begin
            set_last_error(
                "spy executor execute called without successful preflight");
            return;
        end
        execution_plan = preflight_plan;
        execution_failed_operation_id = authorized_failed_operation_id;
        execute_authorization_consumed = 1;
        preflight_succeeded = 0;
        preflight_plan = null;
        authorized_failed_operation_id = "";
        if (plan != execution_plan) begin
            set_last_error(
                "spy executor execute plan does not match preflight plan");
            return;
        end
        if (!plan.ordered_operations(ordered, why)) begin
            set_last_error(why);
            return;
        end

        // History is cumulative until reset_history(). Copies and results for
        // one execute call remain local until either the whole run succeeds or
        // an injected functional failure establishes an executed prefix.
        foreach (ordered[index]) begin
            if (!copy_operation(
                ordered[index], ordered[index].op_id,
                recorded_copy, why)) begin
                set_last_error(why);
                return;
            end
            staged_operations.push_back(recorded_copy);
            if (ordered[index].op_id == execution_failed_operation_id) begin
                staged_results.push_back(DPU_REG_OP_RESULT_FAILED);
                recorded_operations = {
                    recorded_operations, staged_operations
                };
                recorded_results = {recorded_results, staged_results};
                set_last_error($sformatf(
                    "injected execution failure at operation %s",
                    ordered[index].op_id));
                return;
            end
            staged_results.push_back(DPU_REG_OP_RESULT_SUCCEEDED);
        end
        recorded_operations = {recorded_operations, staged_operations};
        recorded_results = {recorded_results, staged_results};
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask

    function bit record_at(
        input int unsigned index,
        output dpu_reg_op operation,
        output dpu_reg_op_result_e result,
        output string why
    );
        operation = null;
        result = DPU_REG_OP_RESULT_NOT_RUN;
        why = "";
        if ((index >= recorded_operations.size()) ||
            (index >= recorded_results.size())) begin
            why = $sformatf(
                "spy record index %0d is out of range", index);
            return 0;
        end
        if (!copy_operation(
            recorded_operations[index], recorded_operations[index].op_id,
            operation, why)) begin
            operation = null;
            return 0;
        end
        result = recorded_results[index];
        return 1;
    endfunction

    virtual function void export_results(input dpu_execution_report report);
        if (report == null)
            return;
        report.clear_results();
        foreach (recorded_operations[index]) begin
            report.append_result(
                recorded_operations[index].op_id, recorded_results[index]);
        end
    endfunction
endclass : dpu_spy_reg_executor

`endif // DPU_SPY_REG_EXECUTOR_SV
