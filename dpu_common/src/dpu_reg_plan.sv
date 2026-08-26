`ifndef DPU_REG_PLAN_SV
`define DPU_REG_PLAN_SV

class dpu_reg_plan extends uvm_object;
    `uvm_object_utils(dpu_reg_plan)

    local dpu_reg_op operations_by_id[string];
    local string ordered_ids[$];
    local bit frozen;

    function new(string name = "dpu_reg_plan");
        super.new(name);
        ordered_ids.delete();
        frozen = 0;
    endfunction

    function int unsigned operation_count();
        return operations_by_id.num();
    endfunction

    function bit is_frozen();
        return frozen;
    endfunction

    function bit add_operation(
        input dpu_reg_op operation,
        output string why
    );
        dpu_reg_op copied;

        why = "";
        if (frozen) begin
            why = "register plan is frozen";
            return 0;
        end
        if (operation == null) begin
            why = "cannot add a null register operation";
            return 0;
        end
        if (operation.op_id == "") begin
            why = "register operation ID must not be empty";
            return 0;
        end
        if (operations_by_id.exists(operation.op_id)) begin
            why = $sformatf(
                "duplicate register operation ID %s", operation.op_id);
            return 0;
        end

        copied = operation.copy_op(operation.op_id);
        if (copied == null) begin
            why = $sformatf(
                "failed to copy register operation %s", operation.op_id);
            return 0;
        end
        operations_by_id[operation.op_id] = copied;
        return 1;
    endfunction

    function bit find_operation(
        input string op_id,
        output dpu_reg_op operation
    );
        operation = null;
        if (!operations_by_id.exists(op_id))
            return 0;
        operation = operations_by_id[op_id].copy_op(op_id);
        return (operation != null);
    endfunction

    local function bit next_operation_id(
        ref bit selected[string],
        output string selected_id
    );
        selected_id = "";
        foreach (operations_by_id[op_id]) begin
            if (!selected.exists(op_id)) begin
                if (selected_id == "")
                    selected_id = op_id;
                else if (op_id.compare(selected_id) < 0)
                    selected_id = op_id;
            end
        end
        return (selected_id != "");
    endfunction

    local function bit validate_operations(output string why);
        bit selected[string];
        bit seen_dependency[string];
        bit producer_found;
        string op_id;
        string dependency_id;
        string missing_producer_id;

        why = "";
        if (operations_by_id.num() == 0) begin
            why = "register plan contains no operations";
            return 0;
        end

        while (selected.num() < operations_by_id.num()) begin
            if (!next_operation_id(selected, op_id)) begin
                why = "register plan operation traversal failed";
                return 0;
            end
            selected[op_id] = 1;

            if (!operations_by_id[op_id].validate(why))
                return 0;

            seen_dependency.delete();
            foreach (operations_by_id[op_id].dependencies[index]) begin
                dependency_id = operations_by_id[op_id].dependencies[index];
                if (seen_dependency.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s repeats dependency %s",
                        op_id, dependency_id);
                    return 0;
                end
                seen_dependency[dependency_id] = 1;
                if (!operations_by_id.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s depends on unknown operation %s",
                        op_id, dependency_id);
                    return 0;
                end
            end

            if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                if (operations_by_id[op_id].commit_group == "") begin
                    why = $sformatf(
                        "operation %s commit group must not be empty", op_id);
                    return 0;
                end

                producer_found = 0;
                missing_producer_id = "";
                foreach (operations_by_id[producer_id]) begin
                    if ((operations_by_id[producer_id].phase ==
                         DPU_REG_PHASE_TABLE) &&
                        (operations_by_id[producer_id].kind ==
                         DPU_REG_OP_MMIO_WRITE) &&
                        (operations_by_id[producer_id].commit_group ==
                         operations_by_id[op_id].commit_group)) begin
                        producer_found = 1;
                        if (!seen_dependency.exists(producer_id)) begin
                            if (missing_producer_id == "")
                                missing_producer_id = producer_id;
                            else if (producer_id.compare(
                                missing_producer_id) < 0)
                                missing_producer_id = producer_id;
                        end
                    end
                end

                if (!producer_found) begin
                    why = $sformatf(
                        "operation %s has no table producer in commit group %s",
                        op_id, operations_by_id[op_id].commit_group);
                    return 0;
                end
                if (missing_producer_id != "") begin
                    why = $sformatf(
                        "operation %s does not depend on commit-group producer %s",
                        op_id, missing_producer_id);
                    return 0;
                end
            end
        end
        return 1;
    endfunction

    local function bit build_topological_order(
        ref string result[$],
        output string why
    );
        int unsigned indegree[string];
        bit emitted[string];
        string candidate_id;
        string dependency_id;

        result.delete();
        why = "";
        foreach (operations_by_id[op_id]) begin
            indegree[op_id] = operations_by_id[op_id].dependencies.size();
            emitted[op_id] = 0;
        end

        while (result.size() < operations_by_id.num()) begin
            candidate_id = "";
            foreach (operations_by_id[op_id]) begin
                if (!emitted[op_id] && (indegree[op_id] == 0)) begin
                    if (candidate_id == "") begin
                        candidate_id = op_id;
                    end
                    else if ((operations_by_id[op_id].phase <
                              operations_by_id[candidate_id].phase) ||
                             ((operations_by_id[op_id].phase ==
                               operations_by_id[candidate_id].phase) &&
                              (op_id.compare(candidate_id) < 0))) begin
                        candidate_id = op_id;
                    end
                end
            end

            if (candidate_id == "") begin
                result.delete();
                why = "register plan contains a dependency cycle";
                return 0;
            end

            emitted[candidate_id] = 1;
            result.push_back(candidate_id);
            foreach (operations_by_id[op_id]) begin
                if (!emitted[op_id]) begin
                    foreach (operations_by_id[op_id].dependencies[index]) begin
                        dependency_id =
                            operations_by_id[op_id].dependencies[index];
                        if (dependency_id == candidate_id)
                            indegree[op_id]--;
                    end
                end
            end
        end
        return 1;
    endfunction

    function bit validate(output string why);
        string validation_order[$];

        if (!validate_operations(why))
            return 0;
        return build_topological_order(validation_order, why);
    endfunction

    function bit freeze(output string why);
        string new_order[$];

        why = "";
        if (frozen)
            return 1;
        if (!validate_operations(why))
            return 0;
        if (!build_topological_order(new_order, why))
            return 0;

        ordered_ids = new_order;
        frozen = 1;
        return 1;
    endfunction

    function bit ordered_operations(
        ref dpu_reg_op operations[$],
        output string why
    );
        dpu_reg_op copied;

        operations.delete();
        why = "";
        if (!frozen) begin
            why = "register plan must be frozen before retrieving order";
            return 0;
        end

        foreach (ordered_ids[index]) begin
            copied = operations_by_id[ordered_ids[index]].copy_op(
                ordered_ids[index]);
            if (copied == null) begin
                operations.delete();
                why = $sformatf(
                    "failed to copy register operation %s", ordered_ids[index]);
                return 0;
            end
            operations.push_back(copied);
        end
        return 1;
    endfunction
endclass : dpu_reg_plan

`endif // DPU_REG_PLAN_SV
