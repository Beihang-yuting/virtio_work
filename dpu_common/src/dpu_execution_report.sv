`ifndef DPU_EXECUTION_REPORT_SV
`define DPU_EXECUTION_REPORT_SV

class dpu_execution_report extends uvm_object;
    `uvm_object_utils(dpu_execution_report)

    local dpu_cfg_status_e terminal_status_value;
    local string terminal_reason_text;
    local string operation_ids[$];
    local dpu_reg_op_result_e operation_results[$];

    function new(string name = "dpu_execution_report");
        super.new(name);
        terminal_status_value = DPU_CFG_STATUS_NOT_EXECUTED;
        terminal_reason_text = "";
        operation_ids.delete();
        operation_results.delete();
    endfunction

    function void set_terminal(
        input dpu_cfg_status_e new_status,
        input string new_reason
    );
        terminal_status_value = new_status;
        terminal_reason_text = new_reason;
    endfunction

    function dpu_cfg_status_e status();
        return terminal_status_value;
    endfunction

    function string reason();
        return terminal_reason_text;
    endfunction

    function void clear_results();
        operation_ids.delete();
        operation_results.delete();
    endfunction

    function void append_result(
        input string op_id,
        input dpu_reg_op_result_e result
    );
        operation_ids.push_back(op_id);
        operation_results.push_back(result);
    endfunction

    function int unsigned result_count();
        return operation_ids.size();
    endfunction

    function bit result_at(
        input int unsigned index,
        output string op_id,
        output dpu_reg_op_result_e result,
        output string why
    );
        op_id = "";
        result = DPU_REG_OP_RESULT_NOT_RUN;
        why = "";
        if ((index >= operation_ids.size()) ||
            (index >= operation_results.size())) begin
            why = $sformatf(
                "execution report result index %0d is out of range", index);
            return 0;
        end
        op_id = operation_ids[index];
        result = operation_results[index];
        return 1;
    endfunction
endclass : dpu_execution_report

`endif // DPU_EXECUTION_REPORT_SV
