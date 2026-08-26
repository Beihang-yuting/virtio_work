`ifndef DPU_REG_PLAN_SV
`define DPU_REG_PLAN_SV

class dpu_reg_plan extends uvm_object;
    `uvm_object_utils(dpu_reg_plan)

    local dpu_reg_op operations_by_id[string];
    local string ordered_ids[$];
    local bit frozen;

    typedef bit dpu_reg_string_set_t[string];
    typedef dpu_reg_string_set_t dpu_reg_string_set_map_t[string];
    typedef int unsigned dpu_reg_indegree_map_t[string];
    typedef string dpu_reg_string_map_t[string];
    typedef dpu_reg_string_set_t dpu_reg_ready_map_t[int unsigned];

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

    // Dynamic operation subtypes are preserved through copy_op(). A subtype
    // that owns object-handle extension fields must deep-copy those fields in
    // do_copy(); the plan can only invoke the dynamic clone and verify its ID.
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
                "failed to copy register operation %s", expected_id);
            return 0;
        end

        copied = source.copy_op(expected_id);
        if (copied == null) begin
            why = $sformatf(
                "failed to copy register operation %s", expected_id);
            return 0;
        end
        if (copied.op_id != expected_id) begin
            why = $sformatf(
                "register operation copy ID %s does not match expected ID %s",
                copied.op_id, expected_id);
            copied = null;
            return 0;
        end
        return 1;
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

        if (!copy_operation(operation, operation.op_id, copied, why))
            return 0;
        operations_by_id[operation.op_id] = copied;
        return 1;
    endfunction

    function bit find_operation(
        input string op_id,
        output dpu_reg_op operation
    );
        string ignored_why;

        operation = null;
        if (!operations_by_id.exists(op_id))
            return 0;
        return copy_operation(
            operations_by_id[op_id], op_id, operation, ignored_why);
    endfunction

    local function bit analyze_plan(
        ref dpu_reg_indegree_map_t indegree,
        ref dpu_reg_string_set_map_t outgoing_edges,
        ref dpu_reg_string_set_map_t dependency_edges,
        ref dpu_reg_string_set_map_t producers_by_group,
        ref dpu_reg_string_map_t commit_id_by_group,
        output string why
    );
        dpu_reg_string_set_t seen_dependencies;
        bit dependency_found;
        string op_id;
        string dependency_id;
        string producer_id;
        string group_id;

        indegree.delete();
        outgoing_edges.delete();
        dependency_edges.delete();
        producers_by_group.delete();
        commit_id_by_group.delete();
        why = "";
        if (!operations_by_id.first(op_id)) begin
            why = "register plan contains no operations";
            return 0;
        end

        // String-index associative arrays traverse lexically with first/next,
        // so validation error selection is deterministic without sorting.
        do begin
            if (!operations_by_id[op_id].validate(why))
                return 0;

            indegree[op_id] = 0;
            seen_dependencies.delete();
            foreach (operations_by_id[op_id].dependencies[index]) begin
                dependency_id = operations_by_id[op_id].dependencies[index];
                if (dependency_id == op_id) begin
                    why = $sformatf(
                        "operation %s depends on itself", op_id);
                    return 0;
                end
                if (seen_dependencies.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s repeats dependency %s",
                        op_id, dependency_id);
                    return 0;
                end
                seen_dependencies[dependency_id] = 1;
                if (!operations_by_id.exists(dependency_id)) begin
                    why = $sformatf(
                        "operation %s depends on unknown operation %s",
                        op_id, dependency_id);
                    return 0;
                end
                dependency_edges[op_id][dependency_id] = 1;
                outgoing_edges[dependency_id][op_id] = 1;
                indegree[op_id]++;
            end

            group_id = operations_by_id[op_id].commit_group;
            if ((group_id != "") &&
                (operations_by_id[op_id].phase == DPU_REG_PHASE_TABLE) &&
                (operations_by_id[op_id].kind == DPU_REG_OP_MMIO_WRITE)) begin
                producers_by_group[group_id][op_id] = 1;
            end

            if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                if (group_id == "") begin
                    why = $sformatf(
                        "operation %s commit group must not be empty", op_id);
                    return 0;
                end

                // A commit group identifies one atomic producer batch/epoch,
                // not a permanent hardware block. Later builders must assign
                // a unique group for every commit operation they generate.
                if (commit_id_by_group.exists(group_id)) begin
                    why = $sformatf(
                        {"commit group %s is used by multiple commit ",
                         "operations %s and %s"},
                        group_id, commit_id_by_group[group_id], op_id);
                    return 0;
                end
                commit_id_by_group[group_id] = op_id;
            end
        end while (operations_by_id.next(op_id));

        // Every nonempty producer epoch must terminate in its unique commit.
        // Traverse group and producer string indexes lexically so the missing
        // commit diagnostic is deterministic without adding quadratic work.
        if (producers_by_group.first(group_id)) begin
            do begin
                if (!commit_id_by_group.exists(group_id)) begin
                    if (!producers_by_group[group_id].first(producer_id)) begin
                        why = "register plan producer traversal failed";
                        return 0;
                    end
                    why = $sformatf(
                        {"commit group %s has producer %s but no commit ",
                         "operation"}, group_id, producer_id);
                    return 0;
                end
            end while (producers_by_group.next(group_id));
        end

        // Commit coverage is indexed by batch ID and direct dependency edge.
        // Unique commit groups make the aggregate traversal O(V + E).
        if (operations_by_id.first(op_id)) begin
            do begin
                if (operations_by_id[op_id].kind == DPU_REG_OP_COMMIT) begin
                    group_id = operations_by_id[op_id].commit_group;
                    if (!producers_by_group.exists(group_id)) begin
                        why = $sformatf(
                            {"operation %s has no table producer in commit ",
                             "group %s"}, op_id, group_id);
                        return 0;
                    end
                    if (!producers_by_group[group_id].first(producer_id)) begin
                        why = $sformatf(
                            {"operation %s has no table producer in commit ",
                             "group %s"}, op_id, group_id);
                        return 0;
                    end

                    do begin
                        dependency_found = 0;
                        if (dependency_edges.exists(op_id)) begin
                            dependency_found =
                                dependency_edges[op_id].exists(producer_id);
                        end
                        if (!dependency_found) begin
                            why = $sformatf(
                                {"operation %s does not depend on commit-group ",
                                 "producer %s"}, op_id, producer_id);
                            return 0;
                        end
                    end while (
                        producers_by_group[group_id].next(producer_id));
                end
            end while (operations_by_id.next(op_id));
        end
        return 1;
    endfunction

    local function bit build_topological_order(
        ref string result[$],
        ref dpu_reg_indegree_map_t indegree,
        ref dpu_reg_string_set_map_t outgoing_edges,
        output string why
    );
        dpu_reg_ready_map_t ready_by_phase;
        int unsigned ready_phase;
        string op_id;
        string candidate_id;
        string dependent_id;

        result.delete();
        ready_by_phase.delete();
        why = "";

        if (operations_by_id.first(op_id)) begin
            do begin
                if (indegree[op_id] == 0) begin
                    ready_phase = operations_by_id[op_id].phase;
                    ready_by_phase[ready_phase][op_id] = 1;
                end
            end while (operations_by_id.next(op_id));
        end

        while (result.size() < operations_by_id.num()) begin
            if (!ready_by_phase.first(ready_phase)) begin
                result.delete();
                why = "register plan contains a dependency cycle";
                return 0;
            end
            if (!ready_by_phase[ready_phase].first(candidate_id)) begin
                result.delete();
                why = "register plan ready-set traversal failed";
                return 0;
            end

            ready_by_phase[ready_phase].delete(candidate_id);
            if (ready_by_phase[ready_phase].num() == 0)
                ready_by_phase.delete(ready_phase);
            result.push_back(candidate_id);

            if (outgoing_edges.exists(candidate_id)) begin
                if (outgoing_edges[candidate_id].first(dependent_id)) begin
                    do begin
                        indegree[dependent_id]--;
                        if (indegree[dependent_id] == 0) begin
                            ready_phase =
                                operations_by_id[dependent_id].phase;
                            ready_by_phase[ready_phase][dependent_id] = 1;
                        end
                    end while (
                        outgoing_edges[candidate_id].next(dependent_id));
                end
            end
        end
        return 1;
    endfunction

    local function bit analyze_and_order(
        ref string result[$],
        output string why
    );
        dpu_reg_indegree_map_t indegree;
        dpu_reg_string_set_map_t outgoing_edges;
        dpu_reg_string_set_map_t dependency_edges;
        dpu_reg_string_set_map_t producers_by_group;
        dpu_reg_string_map_t commit_id_by_group;

        if (!analyze_plan(
            indegree, outgoing_edges, dependency_edges,
            producers_by_group, commit_id_by_group, why)) begin
            result.delete();
            return 0;
        end
        return build_topological_order(
            result, indegree, outgoing_edges, why);
    endfunction

    function bit validate(output string why);
        string validation_order[$];

        return analyze_and_order(validation_order, why);
    endfunction

    function bit freeze(output string why);
        string new_order[$];

        why = "";
        if (frozen)
            return 1;
        if (!analyze_and_order(new_order, why))
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
            if (!copy_operation(
                operations_by_id[ordered_ids[index]], ordered_ids[index],
                copied, why)) begin
                operations.delete();
                return 0;
            end
            operations.push_back(copied);
        end
        return 1;
    endfunction
endclass : dpu_reg_plan

`endif // DPU_REG_PLAN_SV
