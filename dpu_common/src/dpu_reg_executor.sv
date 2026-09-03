`ifndef DPU_REG_EXECUTOR_SV
`define DPU_REG_EXECUTOR_SV

virtual class dpu_reg_executor extends uvm_object;
    protected string last_error_text;

    function new(string name = "dpu_reg_executor");
        super.new(name);
        last_error_text = "";
    endfunction

    protected function void set_last_error(input string why);
        last_error_text = why;
    endfunction

    function string last_error();
        return last_error_text;
    endfunction

    // Optional topology hand-off performed by dpu_device_env after resolving
    // the frozen snapshot.  Generic executors ignore it; concrete PCIe
    // executors use it to translate BAR-relative register offsets at the
    // final execution boundary.
    virtual function void bind_topology(input uvm_object topology);
    endfunction

    pure virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );

    pure virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );

    virtual function void export_results(input dpu_execution_report report);
        if (report != null)
            report.clear_results();
    endfunction
endclass : dpu_reg_executor

`endif // DPU_REG_EXECUTOR_SV
