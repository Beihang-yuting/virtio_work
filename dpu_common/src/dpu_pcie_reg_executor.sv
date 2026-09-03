`ifndef DPU_PCIE_REG_EXECUTOR_SV
`define DPU_PCIE_REG_EXECUTOR_SV

// Platform-neutral PCIe register access boundary.  A production adapter can
// implement these three callbacks with PCIe config/MMIO TLPs, an RTL BFM, or a
// user-owned platform API without changing dpu-common plan builders.
virtual class dpu_pcie_reg_backend extends uvm_object;
    function new(string name = "dpu_pcie_reg_backend");
        super.new(name);
    endfunction

    virtual function void bind_topology(input uvm_object topology);
    endfunction

    pure virtual task write(input dpu_reg_op operation,
                            output bit ok, output string why);
    pure virtual task read(input dpu_reg_op operation,
                           output bit [63:0] value,
                           output bit ok, output string why);
    pure virtual task barrier(input dpu_reg_op operation,
                              output bit ok, output string why);
endclass : dpu_pcie_reg_backend

class dpu_pcie_reg_executor extends dpu_reg_executor;
    `uvm_object_utils(dpu_pcie_reg_executor)

    protected dpu_pcie_reg_backend backend;
    protected dpu_reg_plan preflight_plan;
    protected bit preflight_called;
    protected bit preflight_succeeded;
    protected bit execute_authorization_consumed;
    protected string latest_operation_ids[$];
    protected dpu_reg_op_result_e latest_operation_results[$];

    function new(string name = "dpu_pcie_reg_executor");
        super.new(name);
        backend = null;
        reset_backend_state();
    endfunction

    function void set_backend(input dpu_pcie_reg_backend new_backend);
        backend = new_backend;
        reset_backend_state();
    endfunction

    function void clear_backend();
        backend = null;
        reset_backend_state();
    endfunction

    function bit has_backend();
        return backend != null;
    endfunction

    virtual function void bind_topology(input uvm_object topology);
        if (backend != null)
            backend.bind_topology(topology);
    endfunction

    // Clears only the one-shot preflight authorization and result staging;
    // backend configuration itself remains installed.
    function void reset_backend_state();
        preflight_plan = null;
        preflight_called = 0;
        preflight_succeeded = 0;
        execute_authorization_consumed = 0;
        latest_operation_ids.delete();
        latest_operation_results.delete();
        set_last_error("");
    endfunction

    virtual function bit preflight(
        dpu_reg_plan plan,
        output string why
    );
        why = "";
        reset_backend_state();
        preflight_called = 1;
        if (backend == null) begin
            why = "PCIe register executor has no backend installed";
            set_last_error(why);
            return 0;
        end
        if (plan == null) begin
            why = "PCIe register executor received a null register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.is_frozen()) begin
            why = "PCIe register executor requires a frozen register plan";
            set_last_error(why);
            return 0;
        end
        if (!plan.validate(why)) begin
            set_last_error(why);
            return 0;
        end
        preflight_plan = plan;
        preflight_succeeded = 1;
        return 1;
    endfunction

    protected function void stage_result(input dpu_reg_op operation,
                                         input dpu_reg_op_result_e result);
        latest_operation_ids.push_back(operation.op_id);
        latest_operation_results.push_back(result);
    endfunction

    protected function bit verify_read_value(input dpu_reg_op operation,
                                             input bit [63:0] value,
                                             output string why);
        why = "";
        if ((value & operation.read_mask) !=
            (operation.expected_value & operation.read_mask)) begin
            why = $sformatf(
                "PCIe readback mismatch at %s: got=0x%016x expected=0x%016x mask=0x%016x",
                operation.op_id, value, operation.expected_value,
                operation.read_mask);
            return 0;
        end
        return 1;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        dpu_reg_op operations[$];
        bit ok;
        bit [63:0] value;
        string why;
        string operation_why;

        status = DPU_CFG_STATUS_EXECUTION_FAILED;
        latest_operation_ids.delete();
        latest_operation_results.delete();
        if (!preflight_called || !preflight_succeeded ||
            (preflight_plan == null)) begin
            set_last_error("PCIe register executor execute called before preflight");
            return;
        end
        if (execute_authorization_consumed) begin
            set_last_error(
                "PCIe register executor execute authorization was already consumed");
            return;
        end
        execute_authorization_consumed = 1;
        preflight_succeeded = 0;
        if (plan != preflight_plan) begin
            set_last_error(
                "PCIe register executor execute plan does not match preflight plan");
            return;
        end
        if (!plan.ordered_operations(operations, why)) begin
            set_last_error(why);
            return;
        end

        foreach (operations[index]) begin
            dpu_reg_op operation;
            operation = operations[index];
            operation_why = "";
            ok = 0;
            value = '0;
            case (operation.kind)
                DPU_REG_OP_PCI_CFG_WRITE,
                DPU_REG_OP_MMIO_WRITE,
                DPU_REG_OP_COMMIT: begin
                    backend.write(operation, ok, operation_why);
                end
                DPU_REG_OP_READ_VERIFY: begin
                    backend.read(operation, value, ok, operation_why);
                    if (ok)
                        ok = verify_read_value(operation, value, operation_why);
                end
                DPU_REG_OP_POLL_UNTIL: begin
                    ok = 0;
                    for (int unsigned attempt = 0;
                         attempt < operation.max_attempts; attempt++) begin
                        backend.read(operation, value, ok, operation_why);
                        if (ok && verify_read_value(operation, value,
                                                     operation_why)) begin
                            ok = 1;
                            break;
                        end
                        if (attempt + 1 < operation.max_attempts &&
                            operation.retry_interval != 0)
                            #(operation.retry_interval);
                    end
                    if (!ok && operation_why == "")
                        operation_why = $sformatf(
                            "PCIe poll %s exhausted %0d attempts",
                            operation.op_id, operation.max_attempts);
                end
                DPU_REG_OP_BARRIER: begin
                    backend.barrier(operation, ok, operation_why);
                end
                default: begin
                    operation_why = $sformatf(
                        "PCIe executor received unsupported operation %s",
                        operation.op_id);
                end
            endcase
            if (!ok) begin
                stage_result(operation, DPU_REG_OP_RESULT_FAILED);
                if (operation_why == "")
                    operation_why = $sformatf(
                        "PCIe backend failed operation %s", operation.op_id);
                set_last_error(operation_why);
                return;
            end
            stage_result(operation, DPU_REG_OP_RESULT_SUCCEEDED);
        end
        set_last_error("");
        status = DPU_CFG_STATUS_SUCCEEDED;
    endtask

    virtual function void export_results(input dpu_execution_report report);
        if (report == null)
            return;
        report.clear_results();
        foreach (latest_operation_ids[index])
            report.append_result(latest_operation_ids[index],
                                 latest_operation_results[index]);
    endfunction
endclass : dpu_pcie_reg_executor

`endif // DPU_PCIE_REG_EXECUTOR_SV
