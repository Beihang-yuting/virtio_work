`ifndef DPU_DEVICE_BOOTSTRAP_PLAN_TEST_SV
`define DPU_DEVICE_BOOTSTRAP_PLAN_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_bootstrap_state_spy extends dpu_spy_reg_executor;
    `uvm_object_utils(dpu_bootstrap_state_spy)

    protected dpu_device_env observed_env;
    dpu_device_state_e state_during_execute;
    bit execute_seen;

    function new(string name = "dpu_bootstrap_state_spy");
        super.new(name);
        observed_env = null;
        state_during_execute = DPU_DEVICE_UNRESOLVED;
        execute_seen = 0;
    endfunction

    function void observe(input dpu_device_env env);
        observed_env = env;
    endfunction

    virtual task execute(
        dpu_reg_plan plan,
        output dpu_cfg_status_e status
    );
        execute_seen = 1;
        if (observed_env != null)
            state_during_execute = observed_env.get_state();
        super.execute(plan, status);
    endtask
endclass : dpu_bootstrap_state_spy


class dpu_device_bootstrap_plan_test extends uvm_test;
    `uvm_component_utils(dpu_device_bootstrap_plan_test)

    dpu_device_env success_env;
    dpu_device_env no_executor_env;
    dpu_device_env preflight_env;
    dpu_device_env failure_env;
    dpu_bootstrap_state_spy success_spy;
    dpu_spy_reg_executor preflight_spy;
    dpu_spy_reg_executor failure_spy;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic bit contains(
        input string text,
        input string expected
    );
        int index;

        if (expected.len() == 0)
            return 1;
        if (text.len() < expected.len())
            return 0;
        for (index = 0; index <= text.len() - expected.len(); index++) begin
            if (text.substr(index, index + expected.len() - 1) == expected)
                return 1;
        end
        return 0;
    endfunction

    function automatic dpu_host_cfg make_host(
        input int unsigned host_id,
        input int unsigned segment_id
    );
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_bdf_range_t bdf_range;
        dpu_mmio_window_cfg window;

        host = dpu_host_cfg::type_id::create(
            $sformatf("bootstrap_host_%0d", host_id));
        host.host_id = host_id;
        domain = dpu_pcie_domain_cfg::type_id::create(
            $sformatf("bootstrap_domain_%0d", host_id));
        domain.key.host_id = host_id;
        domain.key.segment_id = segment_id;
        bdf_range.first_bdf = 16'h0040;
        bdf_range.last_bdf = 16'h004f;
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create(
            $sformatf("bootstrap_window_%0d", host_id));
        window.base = 64'h0000_0001_0000_0000;
        window.limit = 64'h0000_0001_4000_0000;
        window.allowed_roles.push_back(DPU_BAR_DEVICE_MEMORY);
        window.allowed_roles.push_back(DPU_BAR_MAILBOX);
        window.allowed_roles.push_back(DPU_BAR_MSIX);
        domain.mmio_windows.push_back(window);
        host.pcie_domains.push_back(domain);
        return host;
    endfunction

    function automatic dpu_bar_request make_bar(
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] size,
        input bit [63:0] alignment,
        input bit [63:0] base
    );
        dpu_bar_request request;

        request = dpu_bar_request::type_id::create(
            $sformatf("bootstrap_bar_%0d", role));
        request.role = role;
        request.even_bar_id = even_bar_id;
        request.size = size;
        request.alignment = alignment;
        request.placement = DPU_ALLOC_PINNED;
        request.pinned_base = base;
        return request;
    endfunction

    function automatic dpu_device_cfg make_device_cfg();
        dpu_device_cfg cfg;
        dpu_function_cfg selected_pf;

        cfg = dpu_device_cfg::type_id::create("bootstrap_device_cfg");
        cfg.hosts.push_back(make_host(0, 3));
        cfg.hosts.push_back(make_host(1, 7));
        selected_pf = dpu_function_cfg::type_id::create("selected_host1_pf0");
        selected_pf.key.host_id = 1;
        selected_pf.key.pf_id = 0;
        selected_pf.key.kind = DPU_FUNCTION_PF;
        selected_pf.key.vf_id = 0;
        selected_pf.domain_key.host_id = 1;
        selected_pf.domain_key.segment_id = 7;
        selected_pf.bdf_mode = DPU_ALLOC_PINNED;
        selected_pf.pinned_bdf = 16'h0042;
        selected_pf.bars.push_back(make_bar(
            DPU_BAR_DEVICE_MEMORY, 0,
            64'h0000_0000_0200_0000, 64'h0000_0000_0200_0000,
            64'h0000_0001_2000_0000));
        selected_pf.bars.push_back(make_bar(
            DPU_BAR_MAILBOX, 2,
            64'h0000_0000_0001_0000, 64'h0000_0000_0001_0000,
            64'h0000_0001_2200_0000));
        selected_pf.bars.push_back(make_bar(
            DPU_BAR_MSIX, 4,
            64'h0000_0000_0001_0000, 64'h0000_0000_0001_0000,
            64'h0000_0001_2201_0000));
        cfg.functions.push_back(selected_pf);
        cfg.af_request.mode = DPU_AF_SELECTED;
        cfg.af_request.requester = selected_pf.key;
        return cfg;
    endfunction

    function automatic dpu_device_env_config make_env_cfg(
        input string name,
        input dpu_reg_executor executor
    );
        dpu_device_env_config cfg;
        dpu_resource_pool_config_t profile;

        cfg = dpu_device_env_config::type_id::create(name);
        cfg.device_cfg = make_device_cfg();
        cfg.executor = executor;
        profile.name = "virtio.qpair";
        profile.class_id = '0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 64;
        profile.max_per_function = 32;
        cfg.placement_cfg.profiles.push_back(profile);
        return cfg;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_env_config cfg;

        super.build_phase(phase);
        success_spy = dpu_bootstrap_state_spy::type_id::create("success_spy");
        preflight_spy = dpu_spy_reg_executor::type_id::create("preflight_spy");
        preflight_spy.fail_preflight("injected unroutable bootstrap target");
        failure_spy = dpu_spy_reg_executor::type_id::create("failure_spy");
        failure_spy.fail_operation("af.winner.read");

        cfg = make_env_cfg("success_cfg", success_spy);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "success_env", "cfg", cfg);
        success_env = dpu_device_env::type_id::create("success_env", this);

        cfg = make_env_cfg("no_executor_cfg", null);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "no_executor_env", "cfg", cfg);
        no_executor_env = dpu_device_env::type_id::create(
            "no_executor_env", this);

        cfg = make_env_cfg("preflight_cfg", preflight_spy);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "preflight_env", "cfg", cfg);
        preflight_env = dpu_device_env::type_id::create("preflight_env", this);

        cfg = make_env_cfg("failure_cfg", failure_spy);
        uvm_config_db#(dpu_device_env_config)::set(
            this, "failure_env", "cfg", cfg);
        failure_env = dpu_device_env::type_id::create("failure_env", this);
    endfunction

    function automatic void expect_target_op(
        input dpu_reg_op op,
        input string expected_id,
        input string expected_dependency,
        input dpu_reg_op_kind_e expected_kind,
        input dpu_reg_target_space_e expected_space,
        input int unsigned expected_bar,
        input bit [63:0] expected_address,
        input bit [63:0] expected_payload,
        input bit [63:0] expected_write_mask,
        input bit [63:0] expected_value,
        input bit [63:0] expected_read_mask,
        input string expected_block
    );
        if ((op == null) || (op.op_id != expected_id) ||
            (op.owner != "dpu.bootstrap") ||
            (op.kind != expected_kind) ||
            (op.target_space != expected_space) ||
            (op.target_scope != DPU_REG_SCOPE_SINGLE) ||
            (op.phase != DPU_REG_PHASE_BOOTSTRAP) ||
            (op.host_id != 1) || (op.segment_id != 7) ||
            !op.bdf_valid || (op.bdf != 16'h0042) ||
            (op.bar_id != expected_bar) ||
            (op.target_block != expected_block) ||
            (op.address != expected_address) || (op.width_bytes != 4) ||
            (op.payload != expected_payload) ||
            (op.write_mask != expected_write_mask) ||
            (op.expected_value != expected_value) ||
            (op.read_mask != expected_read_mask) ||
            (op.max_attempts != 0) || (op.retry_interval !== 0) ||
            (op.commit_group != "")) begin
            `uvm_fatal("BOOTSTRAP_TEST",
                {"operation fields mismatch for ", expected_id})
        end
        if (expected_dependency == "") begin
            if (op.dependencies.size() != 0)
                `uvm_fatal("BOOTSTRAP_TEST",
                    {"unexpected dependency on ", expected_id})
        end else if ((op.dependencies.size() != 1) ||
                     (op.dependencies[0] != expected_dependency)) begin
            `uvm_fatal("BOOTSTRAP_TEST",
                {"dependency mismatch for ", expected_id})
        end
    endfunction

    function automatic void expect_barrier(input dpu_reg_op op);
        if ((op == null) || (op.op_id != "bootstrap.final_barrier") ||
            (op.owner != "dpu.bootstrap") ||
            (op.kind != DPU_REG_OP_BARRIER) ||
            (op.target_space != DPU_REG_TARGET_NONE) ||
            (op.target_scope != DPU_REG_SCOPE_SINGLE) ||
            (op.phase != DPU_REG_PHASE_BOOTSTRAP) ||
            (op.host_id != 1) || (op.segment_id != 7) ||
            op.bdf_valid || (op.bdf != '0) || (op.bar_id != 0) ||
            (op.target_block != "") || (op.address != '0) ||
            (op.width_bytes != 0) || (op.payload != '0) ||
            (op.write_mask != '0) || (op.expected_value != '0) ||
            (op.read_mask != '0) || (op.max_attempts != 0) ||
            (op.retry_interval !== 0) || (op.commit_group != "") ||
            (op.dependencies.size() != 1) ||
            (op.dependencies[0] != "af.host_id.readback")) begin
            `uvm_fatal("BOOTSTRAP_TEST", "final barrier fields/dependency mismatch")
        end
    endfunction

    function automatic void expect_exact_plan(input dpu_reg_plan plan);
        dpu_reg_op ordered[$];
        string why;

        if (plan == null)
            `uvm_fatal("BOOTSTRAP_TEST", "bootstrap builder returned null plan")
        if (plan.operation_count() != 12)
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf("expected 12 operations, got %0d",
                          plan.operation_count()))
        if (!plan.freeze(why))
            `uvm_fatal("BOOTSTRAP_TEST", {"exact plan did not freeze: ", why})
        if (!plan.ordered_operations(ordered, why) || (ordered.size() != 12))
            `uvm_fatal("BOOTSTRAP_TEST", {"exact plan order failed: ", why})

        expect_target_op(ordered[0],
            "pci.h1.s7.b0042.bar0.low", "", DPU_REG_OP_PCI_CFG_WRITE,
            DPU_REG_TARGET_PCI_CONFIG, 0, 64'h10,
            64'h2000_0004, 64'hffff_ffff, 64'h0, 64'h0, "pci_config");
        expect_target_op(ordered[1],
            "pci.h1.s7.b0042.bar0.high", "pci.h1.s7.b0042.bar0.low",
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG, 0,
            64'h14, 64'h1, 64'hffff_ffff, 64'h0, 64'h0, "pci_config");
        expect_target_op(ordered[2],
            "pci.h1.s7.b0042.bar2.low", "pci.h1.s7.b0042.bar0.high",
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG, 2,
            64'h18, 64'h2200_0004, 64'hffff_ffff, 64'h0, 64'h0,
            "pci_config");
        expect_target_op(ordered[3],
            "pci.h1.s7.b0042.bar2.high", "pci.h1.s7.b0042.bar2.low",
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG, 2,
            64'h1c, 64'h1, 64'hffff_ffff, 64'h0, 64'h0, "pci_config");
        expect_target_op(ordered[4],
            "pci.h1.s7.b0042.bar4.low", "pci.h1.s7.b0042.bar2.high",
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG, 4,
            64'h20, 64'h2201_0004, 64'hffff_ffff, 64'h0, 64'h0,
            "pci_config");
        expect_target_op(ordered[5],
            "pci.h1.s7.b0042.bar4.high", "pci.h1.s7.b0042.bar4.low",
            DPU_REG_OP_PCI_CFG_WRITE, DPU_REG_TARGET_PCI_CONFIG, 4,
            64'h24, 64'h1, 64'hffff_ffff, 64'h0, 64'h0, "pci_config");
        expect_target_op(ordered[6],
            "af.valid.pre_read", "pci.h1.s7.b0042.bar4.high",
            DPU_REG_OP_READ_VERIFY, DPU_REG_TARGET_AF_BAR0, 0,
            64'h1010, 64'h0, 64'h0, 64'h0, 64'h8, "af_bar0");
        expect_target_op(ordered[7],
            "af.declare.write", "af.valid.pre_read", DPU_REG_OP_MMIO_WRITE,
            DPU_REG_TARGET_AF_BAR0, 0, 64'h1010,
            64'h5555_aaaa, 64'hffff_ffff, 64'h0, 64'h0, "af_bar0");
        expect_target_op(ordered[8],
            "af.winner.read", "af.declare.write", DPU_REG_OP_READ_VERIFY,
            DPU_REG_TARGET_AF_BAR0, 0, 64'h1010,
            64'h0, 64'h0, 64'h9, 64'hf, "af_bar0");
        expect_target_op(ordered[9],
            "af.host_id.write", "af.winner.read", DPU_REG_OP_MMIO_WRITE,
            DPU_REG_TARGET_AF_BAR0, 0, 64'h60040,
            64'h9, 64'hffff_ffff, 64'h0, 64'h0, "af_bar0");
        expect_target_op(ordered[10],
            "af.host_id.readback", "af.host_id.write",
            DPU_REG_OP_READ_VERIFY, DPU_REG_TARGET_AF_BAR0, 0,
            64'h60040, 64'h0, 64'h0, 64'h9, 64'hf, "af_bar0");
        expect_barrier(ordered[11]);
    endfunction

    function automatic void expect_terminal(
        input dpu_execution_report report,
        input dpu_cfg_status_e expected_status,
        input string expected_reason
    );
        if (report == null)
            `uvm_fatal("BOOTSTRAP_TEST", "orchestrator returned null report")
        if (report.status() != expected_status)
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf("report status mismatch: expected %0d got %0d",
                          expected_status, report.status()))
        if ((expected_reason == "") && (report.reason() != ""))
            `uvm_fatal("BOOTSTRAP_TEST", "successful report retained a reason")
        if ((expected_reason != "") &&
            !contains(report.reason(), expected_reason))
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf("report reason '%s' lacks '%s'",
                          report.reason(), expected_reason))
    endfunction

    function automatic void expect_result(
        input dpu_execution_report report,
        input int unsigned index,
        input string expected_id,
        input dpu_reg_op_result_e expected_result
    );
        string op_id;
        string why;
        dpu_reg_op_result_e result;

        if (!report.result_at(index, op_id, result, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"missing report result: ", why})
        if ((op_id != expected_id) || (result != expected_result))
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf("report result %0d mismatch", index))
    endfunction

    function automatic void capture_selected_identity(
        input dpu_device_snapshot snapshot,
        output dpu_pcie_function_id_t pcie_id,
        output dpu_bar_pair_lease_t bar0
    );
        dpu_function_key_t selected;
        dpu_function_key_t af_key;
        string why;

        selected.host_id = 1;
        selected.pf_id = 0;
        selected.kind = DPU_FUNCTION_PF;
        selected.vf_id = 0;
        if (!snapshot.get_pcie_id(selected, pcie_id, why) ||
            !snapshot.get_expected_af(af_key, bar0, why) ||
            !dpu_same_function_key(af_key, selected))
            `uvm_fatal("BOOTSTRAP_TEST", {"snapshot identity lookup failed: ", why})
    endfunction

    task automatic test_reused_spy_success_exports_latest_attempt();
        dpu_config_orchestrator orchestrator;
        dpu_spy_reg_executor spy;
        dpu_reg_plan plan;
        dpu_execution_report first_report;
        dpu_execution_report second_report;
        string why;

        if (!no_executor_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"reuse plan build failed: ", why})
        orchestrator = dpu_config_orchestrator::type_id::create(
            "reuse_success_orchestrator");
        spy = dpu_spy_reg_executor::type_id::create("reuse_success_spy");
        orchestrator.set_executor(spy);

        orchestrator.apply_with_report(plan, first_report);
        expect_terminal(first_report, DPU_CFG_STATUS_SUCCEEDED, "");
        if ((first_report.result_count() != 12) ||
            (spy.record_count() != 12))
            `uvm_fatal("BOOTSTRAP_TEST", "first reuse apply result/history mismatch")

        orchestrator.apply_with_report(plan, second_report);
        expect_terminal(second_report, DPU_CFG_STATUS_SUCCEEDED, "");
        if ((second_report.result_count() != 12) ||
            (spy.record_count() != 24)) begin
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf(
                    "second reuse report/history mismatch: report=%0d history=%0d",
                    second_report.result_count(), spy.record_count()))
        end
        expect_result(second_report, 0, "pci.h1.s7.b0042.bar0.low",
                      DPU_REG_OP_RESULT_SUCCEEDED);
        expect_result(second_report, 11, "bootstrap.final_barrier",
                      DPU_REG_OP_RESULT_SUCCEEDED);
    endtask

    task automatic test_reused_spy_preflight_failure_exports_no_results();
        dpu_config_orchestrator orchestrator;
        dpu_spy_reg_executor spy;
        dpu_reg_plan plan;
        dpu_execution_report first_report;
        dpu_execution_report second_report;
        string why;

        if (!no_executor_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"reuse plan build failed: ", why})
        orchestrator = dpu_config_orchestrator::type_id::create(
            "reuse_preflight_orchestrator");
        spy = dpu_spy_reg_executor::type_id::create("reuse_preflight_spy");
        orchestrator.set_executor(spy);

        orchestrator.apply_with_report(plan, first_report);
        expect_terminal(first_report, DPU_CFG_STATUS_SUCCEEDED, "");
        if ((first_report.result_count() != 12) ||
            (spy.record_count() != 12))
            `uvm_fatal("BOOTSTRAP_TEST", "reuse preflight setup apply mismatch")

        spy.fail_preflight("reuse injected preflight failure");
        orchestrator.apply_with_report(plan, second_report);
        expect_terminal(second_report, DPU_CFG_STATUS_PREFLIGHT_FAILED,
                        "reuse injected preflight failure");
        if ((second_report.result_count() != 0) ||
            (spy.record_count() != 12) ||
            spy.preflight_history_was_empty()) begin
            `uvm_fatal("BOOTSTRAP_TEST",
                $sformatf(
                    "reused preflight report/history mismatch: report=%0d history=%0d",
                    second_report.result_count(), spy.record_count()))
        end
    endtask

    task automatic test_success_and_report_copy();
        dpu_reg_plan plan;
        dpu_execution_report report;
        dpu_reg_op_result_e result;
        string op_id;
        string why;

        success_spy.observe(success_env);
        if (!success_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"success plan build failed: ", why})
        if ((success_spy.record_count() != 0) || plan.is_frozen())
            `uvm_fatal("BOOTSTRAP_TEST",
                "plan construction wrote or prematurely froze the plan")
        expect_exact_plan(plan);
        success_env.apply_bootstrap(plan, report);
        expect_terminal(report, DPU_CFG_STATUS_SUCCEEDED, "");
        if (!success_spy.execute_seen ||
            (success_spy.state_during_execute != DPU_DEVICE_APPLYING) ||
            (success_env.get_state() != DPU_DEVICE_ACTIVE) ||
            (report.result_count() != 12) ||
            (success_spy.record_count() != 12))
            `uvm_fatal("BOOTSTRAP_TEST", "successful apply/report state mismatch")
        expect_result(report, 0, "pci.h1.s7.b0042.bar0.low",
                      DPU_REG_OP_RESULT_SUCCEEDED);
        expect_result(report, 11, "bootstrap.final_barrier",
                      DPU_REG_OP_RESULT_SUCCEEDED);

        if (!report.result_at(0, op_id, result, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"report copy lookup failed: ", why})
        op_id = "mutated.result.id";
        success_spy.reset_history();
        expect_result(report, 0, "pci.h1.s7.b0042.bar0.low",
                      DPU_REG_OP_RESULT_SUCCEEDED);
        if (success_env.build_bootstrap_plan(plan, why) || (plan != null) ||
            !contains(why, "RESOLVED"))
            `uvm_fatal("BOOTSTRAP_TEST", "ACTIVE environment rebuilt bootstrap plan")
    endtask

    task automatic test_no_executor();
        dpu_reg_plan plan;
        dpu_execution_report report;
        string why;

        if (!no_executor_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"plan-only build failed: ", why})
        no_executor_env.apply_bootstrap(plan, report);
        expect_terminal(report, DPU_CFG_STATUS_NOT_EXECUTED, "no executor");
        if ((report.result_count() != 0) ||
            (no_executor_env.get_state() != DPU_DEVICE_RESOLVED))
            `uvm_fatal("BOOTSTRAP_TEST", "no-executor apply changed device state/results")
    endtask

    task automatic test_preflight_failure();
        dpu_reg_plan plan;
        dpu_execution_report report;
        string why;

        if (!preflight_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"preflight plan build failed: ", why})
        if (preflight_spy.record_count() != 0)
            `uvm_fatal("BOOTSTRAP_TEST", "preflight spy was dirty before apply")
        preflight_env.apply_bootstrap(plan, report);
        expect_terminal(report, DPU_CFG_STATUS_PREFLIGHT_FAILED,
                        "injected unroutable bootstrap target");
        if (!preflight_spy.preflight_history_was_empty() ||
            (preflight_spy.record_count() != 0) ||
            (report.result_count() != 0) ||
            (preflight_env.get_state() != DPU_DEVICE_RESOLVED))
            `uvm_fatal("BOOTSTRAP_TEST",
                "preflight failure executed operations or changed state")
        if (!preflight_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", "preflight failure left RESOLVED state")
    endtask

    task automatic test_execution_failure_preserves_snapshot();
        dpu_device_snapshot before_snapshot;
        dpu_device_snapshot after_snapshot;
        dpu_pcie_function_id_t before_id;
        dpu_pcie_function_id_t after_id;
        dpu_bar_pair_lease_t before_bar0;
        dpu_bar_pair_lease_t after_bar0;
        dpu_reg_plan plan;
        dpu_execution_report report;
        string why;

        before_snapshot = failure_env.get_snapshot();
        capture_selected_identity(before_snapshot, before_id, before_bar0);
        if (!failure_env.build_bootstrap_plan(plan, why))
            `uvm_fatal("BOOTSTRAP_TEST", {"failure plan build failed: ", why})
        failure_env.apply_bootstrap(plan, report);
        expect_terminal(report, DPU_CFG_STATUS_EXECUTION_FAILED,
                        "injected execution failure at operation af.winner.read");
        if ((failure_env.get_state() != DPU_DEVICE_FAILED) ||
            (failure_spy.record_count() != 9) ||
            (report.result_count() != 9))
            `uvm_fatal("BOOTSTRAP_TEST", "execution failure prefix/state mismatch")
        expect_result(report, 7, "af.declare.write",
                      DPU_REG_OP_RESULT_SUCCEEDED);
        expect_result(report, 8, "af.winner.read",
                      DPU_REG_OP_RESULT_FAILED);
        failure_spy.reset_history();
        expect_result(report, 8, "af.winner.read",
                      DPU_REG_OP_RESULT_FAILED);

        after_snapshot = failure_env.get_snapshot();
        capture_selected_identity(after_snapshot, after_id, after_bar0);
        if ((after_snapshot != before_snapshot) || !after_snapshot.is_frozen() ||
            (after_id.domain.host_id != before_id.domain.host_id) ||
            (after_id.domain.segment_id != before_id.domain.segment_id) ||
            (after_id.bdf != before_id.bdf) ||
            (after_bar0.role != before_bar0.role) ||
            (after_bar0.even_bar_id != before_bar0.even_bar_id) ||
            (after_bar0.base != before_bar0.base) ||
            (after_bar0.size != before_bar0.size))
            `uvm_fatal("BOOTSTRAP_TEST", "failed apply mutated/replaced snapshot")
        if (failure_env.build_bootstrap_plan(plan, why) || (plan != null) ||
            !contains(why, "RESOLVED"))
            `uvm_fatal("BOOTSTRAP_TEST", "FAILED environment rebuilt bootstrap plan")
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_reused_spy_preflight_failure_exports_no_results();
        test_reused_spy_success_exports_latest_attempt();
        test_success_and_report_copy();
        test_no_executor();
        test_preflight_failure();
        test_execution_failure_preserves_snapshot();
        phase.drop_objection(this);
    endtask
endclass : dpu_device_bootstrap_plan_test

`endif // DPU_DEVICE_BOOTSTRAP_PLAN_TEST_SV
