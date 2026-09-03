`ifndef DPU_VIO_REG_PLAN_TEST_SV
`define DPU_VIO_REG_PLAN_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;

class dpu_vio_dataplane_plan_extension_spy extends
    dpu_vio_dataplane_plan_extension;

    int unsigned qsch_calls;
    int unsigned vtx_calls;
    int unsigned vrx_calls;

    function new(string name = "dpu_vio_dataplane_plan_extension_spy");
        super.new(name);
        qsch_calls = 0;
        vtx_calls = 0;
        vrx_calls = 0;
    endfunction

    protected function bit check_inputs(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        dpu_af_extra_queue_binding_t extra_bindings[$];
        dpu_reg_op commit_op;

        why = "";
        if ((device_snapshot == null) || !device_snapshot.is_frozen() ||
            (resource_snapshot == null) || !resource_snapshot.is_frozen()) begin
            why = "dataplane extension did not receive frozen snapshots";
            return 0;
        end
        resource_snapshot.list_af_extra_queue_bindings(extra_bindings);
        if (extra_bindings.size() != 11) begin
            why = "dataplane extension did not receive the AF extra bindings";
            return 0;
        end
        if ((plan == null) ||
            (!plan.find_operation("vio.notify.commit.bank0", commit_op) &&
             !plan.find_operation("vio.notify.commit.bank1", commit_op))) begin
            why = "dataplane extension ran before the core notify plan was complete";
            return 0;
        end
        return 1;
    endfunction

    virtual function bit contribute_qsch(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        if (!check_inputs(device_snapshot, resource_snapshot, plan, why))
            return 0;
        qsch_calls++;
        return 1;
    endfunction

    virtual function bit contribute_vtx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        if ((qsch_calls != 1) ||
            !check_inputs(device_snapshot, resource_snapshot, plan, why)) begin
            if (why == "")
                why = "VTX contribution did not follow QSCH";
            return 0;
        end
        vtx_calls++;
        return 1;
    endfunction

    virtual function bit contribute_vrx(
        input dpu_device_snapshot device_snapshot,
        input dpu_resource_snapshot resource_snapshot,
        input dpu_reg_plan plan,
        output string why
    );
        if ((vtx_calls != 1) ||
            !check_inputs(device_snapshot, resource_snapshot, plan, why)) begin
            if (why == "")
                why = "VRX contribution did not follow VTX";
            return 0;
        end
        vrx_calls++;
        return 1;
    endfunction
endclass : dpu_vio_dataplane_plan_extension_spy

class dpu_vio_reg_plan_test extends uvm_test;
    `uvm_component_utils(dpu_vio_reg_plan_test)

    dpu_device_env device_env;
    dpu_spy_reg_executor executor_spy;
    dpu_vio_dataplane_plan_extension_spy dataplane_extension_spy;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_device_env_config env_cfg;

        super.build_phase(phase);
        executor_spy = dpu_spy_reg_executor::type_id::create("vio_plan_spy");
        dataplane_extension_spy = new("vio_plan_dataplane_extension_spy");
        env_cfg = dpu_device_env_config::type_id::create("vio_plan_env_cfg");
        env_cfg.device_cfg = make_device_cfg();
        env_cfg.placement_cfg = make_placement('{host_id: 0, pf_id: 0,
                                                 kind: DPU_FUNCTION_PF,
                                                 vf_id: 0});
        env_cfg.executor = executor_spy;
        env_cfg.vio_dataplane_extension = dataplane_extension_spy;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", env_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
    endfunction

    function automatic dpu_bar_request make_bar(
        input dpu_bar_role_e role,
        input int unsigned bar_id,
        input bit [63:0] size
    );
        dpu_bar_request bar;
        bar = dpu_bar_request::type_id::create("vio_plan_bar");
        bar.role = role;
        bar.even_bar_id = bar_id;
        bar.size = size;
        bar.alignment = size;
        bar.placement = DPU_ALLOC_AUTO;
        return bar;
    endfunction

    function automatic dpu_device_cfg make_device_cfg();
        dpu_device_cfg cfg;
        dpu_host_cfg host;
        dpu_pcie_domain_cfg domain;
        dpu_mmio_window_cfg window;
        dpu_bdf_range_t bdf_range;
        dpu_function_cfg function_cfg;

        cfg = dpu_device_cfg::type_id::create("vio_plan_device_cfg");
        host = dpu_host_cfg::type_id::create("vio_plan_host");
        host.host_id = 0;
        domain = dpu_pcie_domain_cfg::type_id::create("vio_plan_domain");
        domain.key.host_id = 0;
        domain.key.segment_id = 0;
        bdf_range.first_bdf = 16'h0040;
        bdf_range.last_bdf = 16'h004f;
        domain.bdf_ranges.push_back(bdf_range);
        window = dpu_mmio_window_cfg::type_id::create("vio_plan_window");
        window.base = 64'h0000_0001_0000_0000;
        window.limit = 64'h0000_0002_0000_0000;
        window.allowed_roles = '{DPU_BAR_DEVICE_MEMORY,
                                 DPU_BAR_MAILBOX, DPU_BAR_MSIX};
        domain.mmio_windows.push_back(window);
        host.pcie_domains.push_back(domain);
        cfg.hosts.push_back(host);

        function_cfg = dpu_function_cfg::type_id::create("vio_plan_pf0");
        function_cfg.key.host_id = 0;
        function_cfg.key.pf_id = 0;
        function_cfg.key.kind = DPU_FUNCTION_PF;
        function_cfg.key.vf_id = 0;
        function_cfg.domain_key = domain.key;
        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        function_cfg.bars.push_back(make_bar(
            DPU_BAR_DEVICE_MEMORY, 0, 64'h0200_0000));
        function_cfg.bars.push_back(make_bar(
            DPU_BAR_MAILBOX, 2, 64'h0001_0000));
        function_cfg.bars.push_back(make_bar(
            DPU_BAR_MSIX, 4, 64'h0001_0000));
        cfg.functions.push_back(function_cfg);
        cfg.af_request.requester = function_cfg.key;
        return cfg;
    endfunction

    function automatic dpu_vio_qpair_override make_override(
        input int unsigned pair_index,
        input int unsigned local_id,
        input int unsigned global_id,
        input dpu_function_key_t owner
    );
        dpu_vio_qpair_override override;
        override = dpu_vio_qpair_override::type_id::create("vio_plan_override");
        override.request_pair_index = pair_index;
        override.owner_mode = DPU_ASSIGN_PINNED;
        override.requested_owner = owner;
        override.local_mode = DPU_ASSIGN_PINNED;
        override.requested_local_pair_id = local_id;
        override.global_mode = DPU_ASSIGN_PINNED;
        override.requested_global_qpair_id = global_id;
        return override;
    endfunction

    function automatic dpu_resource_placement_cfg make_placement(
        input dpu_function_key_t owner
    );
        dpu_resource_placement_cfg placement;
        dpu_resource_pool_config_t profile;
        dpu_vio_placement_request request;

        placement = dpu_resource_placement_cfg::type_id::create(
            "vio_plan_placement");
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        placement.profiles.push_back(profile);
        request = dpu_vio_placement_request::type_id::create(
            "vio_plan_request");
        request.request_id = 11;
        request.total_qpairs = 2;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(owner);
        request.qpair_overrides.push_back(make_override(0, 5, 7, owner));
        request.qpair_overrides.push_back(make_override(1, 1, 100, owner));
        placement.vio_requests.push_back(request);
        return placement;
    endfunction

    // Multi-function fixture used by the QSCH topology tests.  PF0 remains
    // the AF, while PF1 and VF0 share the same host/PCIe domain and each own
    // ordinary VIO qpairs.  The VF is materialized from the PF1 pool only
    // when the placement request selects it.
    function automatic dpu_device_cfg make_multi_function_device_cfg();
        dpu_device_cfg cfg;
        dpu_function_cfg pf1;
        dpu_vf_pool_cfg vf_pool;
        dpu_vf_template_cfg vf0;
        dpu_function_key_t pf1_key;

        cfg = make_device_cfg();
        pf1_key = '{host_id: 0, pf_id: 1,
                    kind: DPU_FUNCTION_PF, vf_id: 0};

        pf1 = dpu_function_cfg::type_id::create("vio_plan_pf1");
        pf1.copy_from(cfg.functions[0]);
        pf1.key = pf1_key;
        pf1.services.delete();
        cfg.functions.push_back(pf1);

        vf_pool = dpu_vf_pool_cfg::type_id::create("vio_plan_pf1_vf_pool");
        vf_pool.parent_pf = pf1_key;
        vf0 = dpu_vf_template_cfg::type_id::create("vio_plan_pf1_vf0");
        vf0.vf_id = 0;
        vf0.domain_key = cfg.functions[0].domain_key;
        vf0.bdf_mode = DPU_ALLOC_AUTO;
        vf0.bars.push_back(make_bar(
            DPU_BAR_DEVICE_MEMORY, 0, 64'h0000_0000_0000_4000));
        vf0.bars.push_back(make_bar(
            DPU_BAR_MAILBOX, 2, 64'h0000_0000_0000_4000));
        vf0.bars.push_back(make_bar(
            DPU_BAR_MSIX, 4, 64'h0000_0000_0000_8000));
        vf0.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        vf_pool.vf_templates.push_back(vf0);
        cfg.vf_pools.push_back(vf_pool);
        cfg.af_request.requester =
            '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        return cfg;
    endfunction

    function automatic dpu_resource_placement_cfg
        make_multi_function_placement();
        dpu_resource_placement_cfg placement;
        dpu_resource_pool_config_t profile;
        dpu_vio_placement_request request;
        dpu_function_key_t pf0;
        dpu_function_key_t pf1;
        dpu_function_key_t vf0;

        pf0 = '{host_id: 0, pf_id: 0,
                kind: DPU_FUNCTION_PF, vf_id: 0};
        pf1 = '{host_id: 0, pf_id: 1,
                kind: DPU_FUNCTION_PF, vf_id: 0};
        vf0 = '{host_id: 0, pf_id: 1,
                kind: DPU_FUNCTION_VF, vf_id: 0};
        placement = dpu_resource_placement_cfg::type_id::create(
            "vio_plan_multi_function_placement");
        profile.name = "virtio.qpair";
        profile.class_id = 0;
        profile.kind = DPU_RESOURCE_KIND_QUEUE;
        profile.capacity = 128;
        profile.max_per_function = 32;
        placement.profiles.push_back(profile);
        request = dpu_vio_placement_request::type_id::create(
            "vio_plan_multi_function_request");
        request.request_id = 31;
        request.total_qpairs = 6;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(pf0);
        request.fixed_devices.push_back(pf1);
        request.fixed_devices.push_back(vf0);
        request.qpair_overrides.push_back(make_override(0, 0, 20, pf0));
        request.qpair_overrides.push_back(make_override(1, 1, 21, pf0));
        request.qpair_overrides.push_back(make_override(2, 0, 40, pf1));
        request.qpair_overrides.push_back(make_override(3, 1, 41, pf1));
        request.qpair_overrides.push_back(make_override(4, 0, 60, vf0));
        request.qpair_overrides.push_back(make_override(5, 1, 61, vf0));
        placement.vio_requests.push_back(request);
        return placement;
    endfunction

    function void test_packers();
        dpu_vio_notify_entry_cfg_t notify_cfg;
        dpu_vio_msix_linear_cfg_t linear_cfg;
        dpu_vio_msix_info_cfg_t info_cfg;
        dpu_vio_bdf_cfg_t bdf_cfg;
        bit [9:0] pfvf_id;
        bit [31:0] payload;
        bit [63:0] low_word;
        bit [63:0] high_word;
        string why;

        notify_cfg.local_qid_net = 1;
        notify_cfg.local_qid = 17;
        notify_cfg.local_qid_blk = 0;
        notify_cfg.notify_address = 64'h0000_0001_2345_6000;
        notify_cfg.host_id = 3;
        notify_cfg.global_qid = 1001;
        notify_cfg.notify_type = 2;
        if (!dpu_vio_pack_notify_entry(
                notify_cfg, low_word, high_word, why) ||
            (low_word[0] != 1) || (low_word[5:1] != 5'd17) ||
            (low_word[31:7] != notify_cfg.notify_address[31:7]) ||
            (low_word[60:32] != notify_cfg.notify_address[60:32]) ||
            (low_word[63:61] != 3'd3) ||
            (high_word[10:0] != 11'd1001) ||
            (high_word[12:11] != 2'd2))
            `uvm_fatal("VIO_PLAN", {"notify pack mismatch: ", why})
        notify_cfg.notify_address[0] = 1'b1;
        if (dpu_vio_pack_notify_entry(
                notify_cfg, low_word, high_word, why))
            `uvm_fatal("VIO_PLAN", "unaligned notify address was accepted")

        if (!dpu_vio_pack_invalid_notify_entry(low_word, high_word, why) ||
            (low_word != 64'hffff_ffff_ffff_ffff) ||
            (high_word != 64'h0000_0000_0000_07ff))
            `uvm_fatal("VIO_PLAN", {"invalid notify entry mismatch: ", why})

        bdf_cfg.bdf = 16'h0042;
        bdf_cfg.valid = 1;
        if (!dpu_vio_pack_bdf_entry(bdf_cfg, payload, why) ||
            (payload != 32'h0001_0042))
            `uvm_fatal("VIO_PLAN", "BDF entry pack mismatch")
        linear_cfg.global_msix_idx = 77;
        linear_cfg.valid = 1;
        if (!dpu_vio_pack_msix_linear_entry(linear_cfg, payload, why) ||
            (payload != 32'h0000_084d))
            `uvm_fatal("VIO_PLAN", "MSI-X linear entry pack mismatch")
        info_cfg.function_id = 9;
        info_cfg.host_id = 3;
        info_cfg.self_mask = 1;
        info_cfg.valid = 1;
        if (!dpu_vio_pack_msix_info_entry(info_cfg, payload, why) ||
            (payload != 32'h0000_1b09))
            `uvm_fatal("VIO_PLAN", $sformatf(
                "MSI-X info entry pack mismatch payload=0x%08h why=%s",
                payload, why))

        begin
            dpu_function_key_t key;
            int unsigned srcid;
            key.host_id = 1;
            key.pf_id = 2;
            key.kind = DPU_FUNCTION_VF;
            key.vf_id = 3;
            if (!dpu_vio_pack_source_id(key, pfvf_id, why) ||
                (pfvf_id != 10'd39) ||
                !dpu_vio_compute_srcid(key, srcid, why) ||
                (srcid != 1063))
                `uvm_fatal("VIO_PLAN", {"source ID pack mismatch: ", why})
        end

        begin
            int unsigned tc_weight[8];
            tc_weight[0] = 1;
            tc_weight[1] = 2;
            tc_weight[2] = 3;
            tc_weight[3] = 4;
            tc_weight[4] = 5;
            tc_weight[5] = 6;
            tc_weight[6] = 7;
            tc_weight[7] = 8;
            if (!dpu_vio_pack_qsch_tc_weight(tc_weight, payload, why) ||
                (payload != 32'h8765_4321))
                `uvm_fatal("VIO_PLAN", {"QSCH TC weight pack mismatch: ", why})
            tc_weight[6] = 16;
        if (dpu_vio_pack_qsch_tc_weight(tc_weight, payload, why))
                `uvm_fatal("VIO_PLAN",
                           "out-of-range QSCH TC weight was accepted")
        end

        if (!dpu_vio_pack_qsch_g2p(1, 0, 1, payload, why) ||
            (payload != 32'h8000_0001) ||
            dpu_vio_pack_qsch_g2p(2, 0, 1, payload, why))
            `uvm_fatal("VIO_PLAN", {"QSCH G2P source field mismatch: ", why})
    endfunction

    function void test_default_notify_full_shadow();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_vio_register_plan_builder builder;
        dpu_function_key_t owner;
        string why;

        owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        resolver = dpu_configuration_resolver::type_id::create(
            "default_notify_shadow_resolver");
        if (!resolver.resolve(make_device_cfg(), make_placement(owner),
                              device_snapshot, resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"default notify resolver failed: ",
                       diagnostic.message})
        builder = dpu_vio_register_plan_builder::type_id::create(
            "default_notify_shadow_builder");
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"default notify builder failed: ", why})
        if (!plan.find_operation(
                "vio.notify.bank1.entry127.clear.low", op) ||
            (op.payload != 64'hffff_ffff_ffff_ffff) ||
            !plan.find_operation(
                "vio.notify.bank1.entry127.clear.high", op) ||
            (op.payload != 64'h0000_0000_0000_07ff) ||
            !plan.find_operation("vio.notify.commit.bank1", op) ||
            (op.payload[1:0] != 2'b11))
            `uvm_fatal("VIO_PLAN",
                "default real-DUT plan did not emit the complete 128-entry notify shadow")
        if (plan.find_operation("vio.notify.bank1.entry128.clear.low", op))
            `uvm_fatal("VIO_PLAN",
                "default real-DUT notify shadow exceeded 128 entries")
    endfunction

    function void test_notify_write_verification();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op low_verify;
        dpu_reg_op high_verify;
        dpu_reg_op commit_op;
        dpu_vio_register_plan_builder builder;
        dpu_function_key_t owner;
        bit commit_depends_on_high_verify;
        string why;

        owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        resolver = dpu_configuration_resolver::type_id::create(
            "notify_verify_resolver");
        if (!resolver.resolve(make_device_cfg(), make_placement(owner),
                              device_snapshot, resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"notify verify resolver failed: ",
                       diagnostic.message})
        builder = dpu_vio_register_plan_builder::type_id::create(
            "notify_verify_builder");
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"notify verify builder failed: ", why})
        if (!plan.find_operation(
                "vio.h0.s0.b0040.q0.g7.notify.low.verify", low_verify) ||
            (low_verify.kind != DPU_REG_OP_POLL_UNTIL) ||
            (low_verify.expected_value != 64'h0000_0001_0000_0001) ||
            (low_verify.read_mask != 64'hffff_ffff_ffff_ffff) ||
            (low_verify.max_attempts != 5) ||
            (low_verify.retry_interval != 5us) ||
            (low_verify.dependencies.size() != 1) ||
            (low_verify.dependencies[0] !=
             "vio.h0.s0.b0040.q0.g7.notify.high"))
            `uvm_fatal("VIO_PLAN",
                "valid notify low write is not followed by driver-compatible readback verification")
        if (!plan.find_operation(
                "vio.h0.s0.b0040.q0.g7.notify.high.verify", high_verify) ||
            (high_verify.kind != DPU_REG_OP_POLL_UNTIL) ||
            (high_verify.expected_value != 64'h0000_0000_0000_0007) ||
            (high_verify.read_mask != 64'hffff_ffff_ffff_ffff) ||
            (high_verify.max_attempts != 5) ||
            (high_verify.retry_interval != 5us) ||
            (high_verify.dependencies.size() != 1) ||
            (high_verify.dependencies[0] != low_verify.op_id))
            `uvm_fatal("VIO_PLAN",
                "valid notify high write is not followed by driver-compatible readback verification")
        if (!plan.find_operation("vio.notify.commit.bank1", commit_op))
            `uvm_fatal("VIO_PLAN", "notify verification plan has no commit")
        commit_depends_on_high_verify = 0;
        foreach (commit_op.dependencies[index]) begin
            if (commit_op.dependencies[index] == high_verify.op_id)
                commit_depends_on_high_verify = 1;
        end
        if (!commit_depends_on_high_verify)
            `uvm_fatal("VIO_PLAN",
                "notify commit does not depend on successful readback verification")
    endfunction

    function void test_teardown_plan_clears_only_owned_control_entries();
        dpu_configuration_resolver resolver;
        dpu_device_cfg cfg;
        dpu_function_cfg unused_function;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op commit_op;
        dpu_reg_op info_op;
        dpu_reg_op linear_op;
        dpu_reg_op bdf_op;
        dpu_reg_op operations[$];
        dpu_vio_register_plan_builder builder;
        dpu_function_key_t owner;
        dpu_function_key_t unused_owner;
        string why;

        owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        unused_owner =
            '{host_id: 0, pf_id: 1, kind: DPU_FUNCTION_PF, vf_id: 0};
        cfg = make_device_cfg();
        unused_function = dpu_function_cfg::type_id::create(
            "teardown_unused_pf1");
        unused_function.copy_from(cfg.functions[0]);
        unused_function.key = unused_owner;
        cfg.functions.push_back(unused_function);
        resolver = dpu_configuration_resolver::type_id::create(
            "teardown_resolver");
        if (!resolver.resolve(cfg, make_placement(owner), device_snapshot,
                              resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"teardown resolver failed: ",
                       diagnostic.message})
        builder = dpu_vio_register_plan_builder::type_id::create(
            "teardown_builder");
        if (!builder.build(
                device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"owned BDF setup builder failed: ", why})
        if (plan.find_operation("vio.h0.s0.b0041.f1.bdf", op))
            `uvm_fatal("VIO_PLAN",
                "VIO setup programmed a function with no VIO-owned queue")
        if (!builder.build_teardown(
                device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"teardown builder failed: ", why})

        if (!plan.find_operation(
                "vio.teardown.notify.bank1.entry0.clear.low", op) ||
            (op.payload != 64'hffff_ffff_ffff_ffff) ||
            !plan.find_operation(
                "vio.teardown.notify.bank1.entry127.clear.high", op) ||
            (op.payload != 64'h0000_0000_0000_07ff) ||
            !plan.find_operation(
                "vio.teardown.notify.commit.bank1", commit_op) ||
            (commit_op.payload != DPU_VIO_NOTIFY_COMMIT_SEL_MASK))
            `uvm_fatal("VIO_PLAN",
                "teardown did not commit a complete invalid notify shadow")
        if (!plan.find_operation(
                "vio.teardown.h0.s0.b0040.lv0.gv0.msix_info.invalidate",
                info_op) ||
            (info_op.payload != 0) ||
            (info_op.dependencies.size() != 1) ||
            (info_op.dependencies[0] != commit_op.op_id) ||
            !plan.find_operation(
                "vio.teardown.h0.s0.b0040.lv0.gv0.msix_linear.invalidate",
                linear_op) ||
            (linear_op.payload != 0) ||
            (linear_op.dependencies.size() != 1) ||
            (linear_op.dependencies[0] != info_op.op_id) ||
            !plan.find_operation(
                "vio.teardown.h0.s0.b0040.f0.bdf.invalidate", bdf_op) ||
            (bdf_op.payload != 0))
            `uvm_fatal("VIO_PLAN",
                "teardown MSI-X/BDF invalidation order or payload is incorrect")
        if (plan.find_operation(
                "vio.teardown.h0.s0.b0041.f1.bdf.invalidate", op))
            `uvm_fatal("VIO_PLAN",
                "VIO teardown invalidated a function with no VIO-owned queue")
        if (!plan.list_operations(operations, why))
            `uvm_fatal("VIO_PLAN", {"cannot inspect teardown plan: ", why})
        foreach (operations[index]) begin
            if ((operations[index].target_block == "msix_table") ||
                (operations[index].target_block == "msix_pba") ||
                (operations[index].target_block == "msix_interval"))
                `uvm_fatal("VIO_PLAN",
                    "teardown wrote Host-owned MSI-X/PBA or stale interval state")
        end
        if (!plan.freeze(why))
            `uvm_fatal("VIO_PLAN", {"teardown plan did not freeze: ", why})
    endfunction

    function void test_builder();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_reg_op high_op;
        dpu_vio_register_plan_builder builder;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_af_extra_queue_binding_t extra_bindings[$];
        dpu_function_key_t owner;
        dpu_resource_placement_cfg placement;
        string why;
        int unsigned count;

        owner.host_id = 0;
        owner.pf_id = 0;
        owner.kind = DPU_FUNCTION_PF;
        owner.vf_id = 0;
        resolver = dpu_configuration_resolver::type_id::create("vio_plan_resolver");
        placement = make_placement(owner);
        if (!resolver.resolve(make_device_cfg(), placement, device_snapshot,
                              resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"resolver failed: ", diagnostic.message})
        builder = dpu_vio_register_plan_builder::type_id::create(
            "vio_plan_builder");
        builder.policy.select_inactive_notify_bank = 0;
        builder.policy.notify_bank = 0;
        builder.policy.emit_full_notify_bank = 0;
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"builder failed: ", why})
        resource_snapshot.list_vio_bindings(bindings);
        resource_snapshot.list_af_extra_queue_bindings(extra_bindings);
        if ((bindings.size() != 2) ||
            (bindings[0].global_msix_vector_id != 0) ||
            (bindings[1].global_msix_vector_id != 1))
            `uvm_fatal("VIO_PLAN", "resource resolver did not provide explicit MSI-X bindings")
        if ((extra_bindings.size() != 11) ||
            (extra_bindings[0].kind != DPU_AF_EXTRA_QUEUE_FORWARD) ||
            (extra_bindings[0].extra_queue_offset != 0) ||
            (extra_bindings[0].local_queue_index != 2) ||
            (extra_bindings[0].global_qpair_id != 0) ||
            (extra_bindings[0].local_msix_vector_id != 2) ||
            (extra_bindings[0].global_msix_vector_id != 2) ||
            (extra_bindings[1].kind != DPU_AF_EXTRA_QUEUE_BPDU) ||
            (extra_bindings[2].kind != DPU_AF_EXTRA_QUEUE_ETH_PORT_NETDEV) ||
            (extra_bindings[2].eth_port_id != 0) ||
            (extra_bindings[2].eth_queue_id != 0) ||
            (extra_bindings[6].eth_port_id != 1) ||
            (extra_bindings[6].eth_queue_id != 0) ||
            (extra_bindings[10].kind != DPU_AF_EXTRA_QUEUE_PTP) ||
            (extra_bindings[10].global_qpair_id != 11))
            `uvm_fatal("VIO_PLAN", "AF extra queue bindings do not match the real driver layout")
        if ((plan == null) || (plan.operation_count() != 105) ||
            !plan.find_operation("vio.h0.s0.b0040.q0.g7.notify.low", op) ||
            (op.payload[0] != 1) || (op.payload[5:1] != 5'd0) ||
            (op.target_space != DPU_REG_TARGET_AF_BAR0) ||
            (op.host_id != 0) || (op.segment_id != 0) ||
            (op.bdf != 16'h0040))
            `uvm_fatal("VIO_PLAN", "sparse qpair notify operation mismatch")
        if (!plan.find_operation("vio.h0.s0.b0040.q0.g7.notify.high", high_op) ||
            (high_op.payload[10:0] != 11'd7))
            `uvm_fatal("VIO_PLAN", "explicit global qpair was not packed")
        if (!plan.find_operation("vio.h0.s0.b0040.afq0.g0.notify.low", op) ||
            (op.payload[5:1] != 5'd2) || (op.payload[6] != 1'b0) ||
            !plan.find_operation("vio.h0.s0.b0040.afq0.g0.notify.high", high_op) ||
            (high_op.payload[10:0] != 11'd0) ||
            !plan.find_operation("vio.h0.s0.b0040.afq0.g0.msix_linear", op) ||
            (op.payload[10:0] != 11'd2))
            `uvm_fatal("VIO_PLAN", "AF extra queue notify/MSI-X lowering mismatch")
        if (!plan.find_operation("vio.notify.commit.bank0", op) ||
            (op.kind != DPU_REG_OP_COMMIT) ||
            (op.dependencies.size() != 39))
            `uvm_fatal("VIO_PLAN", "notify commit dependency mismatch")
        if (!plan.freeze(why)) begin
            dpu_reg_op all_ops[$];
            string ids;
            ids = "";
            plan.list_operations(all_ops, ids);
            foreach (all_ops[index])
                ids = {ids, " [", all_ops[index].op_id, "]"};
            `uvm_fatal("VIO_PLAN", {"plan freeze failed: ", why,
                       " IDs:", ids})
        end
        count = 0;
        begin
            dpu_reg_op ordered[$];
            if (!plan.ordered_operations(ordered, why))
                `uvm_fatal("VIO_PLAN", {"ordered plan failed: ", why})
            foreach (ordered[index]) begin
                if (ordered[index].kind == DPU_REG_OP_COMMIT)
                    count = index;
            end
        end
        if (count == 0)
            `uvm_fatal("VIO_PLAN", "notify commit was not ordered after table writes")

        builder.policy.select_inactive_notify_bank = 1;
        builder.policy.active_notify_bank = 0;
        if (!builder.build(device_snapshot, resource_snapshot, plan, why) ||
            !plan.find_operation("vio.notify.commit.bank1", op) ||
            (op.payload[1:0] != 2'b11))
            `uvm_fatal("VIO_PLAN", {"inactive notify bank selection failed: ", why})

        builder.policy.select_inactive_notify_bank = 0;
        builder.policy.emit_full_notify_bank = 1;
        if (!builder.build(device_snapshot, resource_snapshot, plan, why) ||
            !plan.find_operation("vio.notify.bank0.entry127.clear.low", op) ||
            (op.payload != 64'hffff_ffff_ffff_ffff) ||
            !plan.find_operation("vio.notify.bank0.entry127.clear.high", op) ||
            (op.payload != 64'h0000_0000_0000_07ff))
            `uvm_fatal("VIO_PLAN", {"full notify shadow image failed: ", why})
        if (plan.find_operation("vio.notify.bank0.entry128.clear.low", op))
            `uvm_fatal("VIO_PLAN", "full notify shadow image exceeded the driver table")
        builder.policy.emit_full_notify_bank = 0;

        builder.policy.notify_address_offset = 64'h1000;
        if (builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", "notify offset escaped the driver's VIO aperture")
        builder.policy.notify_address_offset = 0;
    endfunction

    function void test_shared_msix_vector();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_vio_qpair_binding_t bindings[$];
        dpu_resource_placement_cfg placement;
        dpu_function_key_t owner;
        dpu_vio_register_plan_builder builder;
        string why;
        int unsigned linear_count;
        int unsigned info_count;
        int unsigned interval_count;

        owner.host_id = 0;
        owner.pf_id = 0;
        owner.kind = DPU_FUNCTION_PF;
        owner.vf_id = 0;
        placement = make_placement(owner);
        // The real driver uses min(online_cpus, rxq) LAN vectors.  One
        // vector for two qpairs is therefore legal and must be represented
        // as an explicit shared binding rather than rejected as a conflict.
        placement.vio_requests[0].lan_msix_vectors = 1;
        resolver = dpu_configuration_resolver::type_id::create(
            "shared_msix_resolver");
        if (!resolver.resolve(make_device_cfg(), placement, device_snapshot,
                              resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"shared MSI-X resolver failed: ",
                       diagnostic.message})
        resource_snapshot.list_vio_bindings(bindings);
        if ((bindings.size() != 2) ||
            (bindings[0].local_msix_vector_id != 0) ||
            (bindings[1].local_msix_vector_id != 0) ||
            (bindings[0].global_msix_vector_id !=
             bindings[1].global_msix_vector_id))
            `uvm_fatal("VIO_PLAN", "shared MSI-X binding was not preserved")
        builder = dpu_vio_register_plan_builder::type_id::create(
            "shared_msix_builder");
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"shared MSI-X builder failed: ", why})
        linear_count = 0;
        info_count = 0;
        interval_count = 0;
        begin
            dpu_reg_op ops[$];
            if (!plan.list_operations(ops, why))
                `uvm_fatal("VIO_PLAN", {"cannot list shared MSI-X plan: ", why})
            foreach (ops[index]) begin
                if (ops[index].target_block == "msix_linear")
                    linear_count++;
                if (ops[index].target_block == "msix_info")
                    info_count++;
                if (ops[index].target_block == "msix_interval")
                    interval_count++;
            end
        end
        // Two ordinary qpairs share one LAN vector; the eleven AF-owned
        // extra queues retain one vector each.
        if ((linear_count != 12) || (info_count != 12) ||
            (interval_count != 12))
            `uvm_fatal("VIO_PLAN", $sformatf(
                "shared MSI-X writes were not deduplicated: linear=%0d info=%0d interval=%0d",
                linear_count, info_count, interval_count))
        if (!plan.find_operation("vio.h0.s0.b0040.q1.g100.notify.low", op) ||
            (op.dependencies.size() < 3))
            `uvm_fatal("VIO_PLAN", "shared qpair notify dependency is missing")
    endfunction

    function void test_af_qpair_limit_includes_extra_queues();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_resource_placement_cfg placement;
        dpu_function_key_t owner;

        owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        placement = make_placement(owner);
        placement.vio_requests[0].total_qpairs = 22;
        placement.vio_requests[0].qpair_overrides.delete();
        resolver = dpu_configuration_resolver::type_id::create(
            "af_qpair_limit_resolver");
        if (resolver.resolve(make_device_cfg(), placement, device_snapshot,
                             resource_snapshot, diagnostic) ||
            (diagnostic.error_code !=
             DPU_PLACE_ERR_DEVICE_CAPACITY_EXHAUSTED))
            `uvm_fatal("VIO_PLAN", "AF accepted more than 21 ordinary qpairs plus 11 extras")
    endfunction

    function void test_notify_sorting();
        dpu_configuration_resolver resolver;
        dpu_device_cfg cfg;
        dpu_function_cfg second_function;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_resource_placement_cfg placement;
        dpu_vio_placement_request request;
        dpu_function_key_t pf0;
        dpu_function_key_t pf1;
        dpu_reg_plan plan;
        dpu_reg_op low_first;
        dpu_reg_op low_second;
        dpu_vio_register_plan_builder builder;
        string why;

        pf0 = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        pf1 = '{host_id: 0, pf_id: 1, kind: DPU_FUNCTION_PF, vf_id: 0};
        cfg = make_device_cfg();
        // Force the BAR/address order to be opposite the request/pair order.
        // The driver inserts notify blocks by host + masked notify address,
        // so the lower BAR must occupy notify entry zero even when requested
        // second.
        cfg.functions[0].bars[0].placement = DPU_ALLOC_PINNED;
        cfg.functions[0].bars[0].pinned_base = 64'h0000_0001_8000_0000;
        second_function = dpu_function_cfg::type_id::create("vio_plan_pf1");
        second_function.copy_from(cfg.functions[0]);
        second_function.key = pf1;
        second_function.bars[0].pinned_base = 64'h0000_0001_0000_0000;
        cfg.functions.push_back(second_function);

        placement = dpu_resource_placement_cfg::type_id::create(
            "notify_sort_placement");
        begin
            dpu_resource_pool_config_t profile;
            profile.name = "virtio.qpair";
            profile.class_id = 0;
            profile.kind = DPU_RESOURCE_KIND_QUEUE;
            profile.capacity = 128;
            profile.max_per_function = 32;
            placement.profiles.push_back(profile);
        end
        request = dpu_vio_placement_request::type_id::create(
            "notify_sort_request");
        request.request_id = 1;
        request.total_qpairs = 2;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_ONLY;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        request.fixed_devices.push_back(pf1);
        request.fixed_devices.push_back(pf0);
        request.qpair_overrides.push_back(make_override(0, 0, 11, pf1));
        request.qpair_overrides.push_back(make_override(1, 0, 12, pf0));
        placement.vio_requests.push_back(request);

        resolver = dpu_configuration_resolver::type_id::create(
            "notify_sort_resolver");
        if (!resolver.resolve(cfg, placement, device_snapshot, resource_snapshot,
                              diagnostic))
            `uvm_fatal("VIO_PLAN", {"notify sort resolver failed: ",
                       diagnostic.message})
        builder = dpu_vio_register_plan_builder::type_id::create(
            "notify_sort_builder");
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"notify sort builder failed: ", why})
        if (!plan.find_operation("vio.h0.s0.b0040.q0.g11.notify.low", low_first) ||
            !plan.find_operation("vio.h0.s0.b0040.q1.g12.notify.low", low_second) ||
            (low_first.address >= low_second.address))
            `uvm_fatal("VIO_PLAN", "notify entries were not sorted by driver match key")
    endfunction

    function void test_bar_aperture_reject();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_vio_register_plan_builder builder;
        dpu_resource_placement_cfg placement;
        dpu_function_key_t owner;
        string why;

        owner.host_id = 0;
        owner.pf_id = 0;
        owner.kind = DPU_FUNCTION_PF;
        owner.vf_id = 0;
        resolver = dpu_configuration_resolver::type_id::create("small_bar_resolver");
        begin
            dpu_device_cfg cfg;
            cfg = make_device_cfg();
            cfg.functions[0].bars[0].size = 64'h0008_0000;
            cfg.functions[0].bars[0].alignment = 64'h0008_0000;
            cfg.dut_caps.bar_profiles[0].size = 64'h0008_0000;
            cfg.dut_caps.bar_profiles[0].alignment = 64'h0008_0000;
            placement = make_placement(owner);
            if (!resolver.resolve(cfg, placement, device_snapshot,
                                  resource_snapshot, diagnostic))
                `uvm_fatal("VIO_PLAN", {"small BAR resolver failed: ", diagnostic.message})
        end
        builder = dpu_vio_register_plan_builder::type_id::create("small_bar_builder");
        if (builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", "builder accepted AF BAR0 that does not cover internal tables")
    endfunction

    // The driver configures QSCH first, then writes VTX/VRX queue parameter
    // RAMs through their content/config registers.  This test checks the
    // evidence-based lowering and its dependency order.
    function void test_driver_dataplane_lowering();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_vio_register_plan_builder builder;
        dpu_vio_driver_dataplane_extension extension;
        dpu_vio_qsch_function_cfg_t qsch_function_cfg;
        dpu_vio_vtx_queue_cfg_t vtx_cfg;
        dpu_vio_vrx_queue_cfg_t vrx_cfg;
        dpu_function_key_t owner;
        string why;
        dpu_reg_op ordered[$];
        int init_index;
        int notify_index;
        int qsch_index;
        int n2g_index;
        int g2p_index;
        int vtx_content_index;
        int vtx_commit_index;
        int vrx_content_index;
        int vrx_commit_index;

        owner = '{host_id: 0, pf_id: 0, kind: DPU_FUNCTION_PF, vf_id: 0};
        resolver = dpu_configuration_resolver::type_id::create(
            "driver_dataplane_resolver");
        if (!resolver.resolve(make_device_cfg(), make_placement(owner),
                              device_snapshot, resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"driver dataplane resolver failed: ",
                       diagnostic.message})

        extension = dpu_vio_driver_dataplane_extension::type_id::create(
            "driver_dataplane_extension");
        extension.default_qsch_cos = 0;
        extension.default_qsch_dst_port = 0;
        extension.default_qsch_spwrr = 8'h00;

        qsch_function_cfg.function_key = owner;
        // register.h declares src_port as one bit; the compiled dpu_snd1.ko
        // consequently exposes host0 as encoded value 0.
        qsch_function_cfg.src_port = 0;
        qsch_function_cfg.dst_port = 0;
        qsch_function_cfg.spwrr = 8'h00;
        qsch_function_cfg.valid = 1;
        qsch_function_cfg.weight_valid = 1;
        qsch_function_cfg.tc_weight[0] = 4'h1;
        qsch_function_cfg.tc_weight[1] = 4'h2;
        qsch_function_cfg.tc_weight[2] = 4'h3;
        qsch_function_cfg.tc_weight[3] = 4'h4;
        qsch_function_cfg.tc_weight[4] = 4'h5;
        qsch_function_cfg.tc_weight[5] = 4'h6;
        qsch_function_cfg.tc_weight[6] = 4'h7;
        qsch_function_cfg.tc_weight[7] = 4'h8;
        extension.qsch_functions.push_back(qsch_function_cfg);

        vtx_cfg.global_qpair_id = 7;
        vtx_cfg.desc_addr = 64'h0000_0001_1111_0000;
        vtx_cfg.q_depth = 7;
        vtx_cfg.queue_en = 0;
        vtx_cfg.virtio_mode = 1;
        vtx_cfg.interl_seg_en = 0;
        vtx_cfg.seg_en = 0;
        vtx_cfg.inorder = 0;
        vtx_cfg.redraw_en = 0;
        vtx_cfg.tail_buf_id_dis = 0;
        vtx_cfg.queue_stop = 0;
        extension.vtx_queues.push_back(vtx_cfg);

        vrx_cfg.global_qpair_id = 7;
        vrx_cfg.desc_addr = 64'h0000_0001_2222_0000;
        vrx_cfg.q_depth = 7;
        vrx_cfg.queue_en = 1;
        vrx_cfg.virtio_mode = 1;
        extension.vrx_queues.push_back(vrx_cfg);

        builder = dpu_vio_register_plan_builder::type_id::create(
            "driver_dataplane_builder");
        builder.set_dataplane_extension(extension);
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"driver dataplane builder failed: ", why})

        // qid 7 is written as Q2TC at DSCH_QSCH_BASE + 0x10000 + 4*7.
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.q7.q2tc", op) ||
            (op.address != 64'h00b1_001c) ||
            (op.payload != 64'h8000_0000))
            `uvm_fatal("VIO_PLAN", "QSCH Q2TC lowering mismatch")
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.n2g", op) ||
            (op.address != 64'h00b1_1000) ||
            (op.payload != 64'h8000_0000))
            `uvm_fatal("VIO_PLAN", "QSCH N2G lowering mismatch")
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.g2p", op) ||
            (op.address != 64'h00b1_2000) ||
            (op.payload != 64'h8000_0000))
            `uvm_fatal("VIO_PLAN", "QSCH G2P lowering mismatch")
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.spwrr", op) ||
            (op.address != 64'h00b1_3000) ||
            (op.payload != 64'h0000_0000))
            `uvm_fatal("VIO_PLAN", "QSCH SP/WRR lowering mismatch")
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.tc_weight", op) ||
            (op.address != 64'h00b1_4000) ||
            (op.payload != 64'h8765_4321))
            `uvm_fatal("VIO_PLAN", "QSCH TC weight lowering mismatch")

        if (!plan.find_operation("vio.dataplane.vtx.q7.content0", op) ||
            (op.address != 64'h0088_0134) ||
            (op.payload != 64'h1111_0000) ||
            !plan.find_operation("vio.dataplane.vtx.q7.content1", op) ||
            (op.payload != 64'h0000_0001) ||
            !plan.find_operation("vio.dataplane.vtx.q7.ram_prepare", op) ||
            (op.address != 64'h0088_0130) ||
            (op.payload != 64'h0000_2007))
            `uvm_fatal("VIO_PLAN", "VTX RAM lowering mismatch")
        if (!plan.find_operation("vio.dataplane.vtx.q7.ram_enable", op) ||
            (op.address != 64'h0088_0130) ||
            (op.payload != 64'h0000_6007))
            `uvm_fatal("VIO_PLAN", "VTX RAM enable lowering mismatch")

        if (!plan.find_operation("vio.dataplane.vrx.q7.content0", op) ||
            (op.address != 64'h0090_0204) ||
            (op.payload != 64'h2222_0000) ||
            !plan.find_operation("vio.dataplane.vrx.q7.content1", op) ||
            (op.payload != 64'h0000_0001) ||
            !plan.find_operation("vio.dataplane.vrx.q7.ram_enable", op) ||
            (op.address != 64'h0090_0200) ||
            (op.payload != 64'h0001_0007))
            `uvm_fatal("VIO_PLAN", "VRX RAM lowering mismatch")

        if (!plan.freeze(why) || !plan.ordered_operations(ordered, why))
            `uvm_fatal("VIO_PLAN", {"driver dataplane plan order failed: ", why})
        init_index = -1;
        notify_index = -1;
        qsch_index = -1;
        n2g_index = -1;
        g2p_index = -1;
        vtx_content_index = -1;
        vtx_commit_index = -1;
        vrx_content_index = -1;
        vrx_commit_index = -1;
        foreach (ordered[index]) begin
            if (ordered[index].op_id == "vio.dataplane.qsch.init")
                init_index = index;
            if (ordered[index].op_id == "vio.notify.commit.bank1")
                notify_index = index;
            if (ordered[index].op_id ==
                "vio.dataplane.qsch.h0.pf0.k0.vf0.q7.q2tc")
                qsch_index = index;
            if (ordered[index].op_id ==
                "vio.dataplane.qsch.h0.pf0.k0.vf0.n2g")
                n2g_index = index;
            if (ordered[index].op_id ==
                "vio.dataplane.qsch.h0.pf0.k0.vf0.g2p")
                g2p_index = index;
            if (ordered[index].op_id == "vio.dataplane.vtx.q7.content3")
                vtx_content_index = index;
            if (ordered[index].op_id == "vio.dataplane.vtx.q7.ram_enable")
                vtx_commit_index = index;
            if (ordered[index].op_id == "vio.dataplane.vrx.q7.content2")
                vrx_content_index = index;
            if (ordered[index].op_id == "vio.dataplane.vrx.q7.ram_enable")
                vrx_commit_index = index;
        end
        if ((init_index < 0) || (notify_index < 0) || (qsch_index < 0) ||
            (vtx_content_index < 0) || (vtx_commit_index < 0) ||
            (vrx_content_index < 0) || (vrx_commit_index < 0) ||
            (init_index > g2p_index) ||
            (notify_index > g2p_index) ||
            (g2p_index > n2g_index) ||
            (n2g_index > qsch_index) ||
            (vtx_content_index > vtx_commit_index) ||
            (vrx_content_index > vrx_commit_index))
            `uvm_fatal("VIO_PLAN", $sformatf(
                "driver dataplane dependency order mismatch init=%0d g2p=%0d n2g=%0d q2tc=%0d vtx=%0d/%0d vrx=%0d/%0d",
                init_index, g2p_index, n2g_index, qsch_index,
                vtx_content_index, vtx_commit_index,
                vrx_content_index, vrx_commit_index))
    endfunction

    // The logical QSCH topology is generated before register lowering.  The
    // generator must discover all resource-owned nets, keep net IDs tied to
    // global function IDs, and produce a legal queue->TC/net->group->port
    // graph.
    function void test_random_qsch_topology();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_qsch_topology_cfg topology;
        dpu_qsch_topology_generator generator;
        dpu_vio_driver_dataplane_extension extension;
        dpu_vio_register_plan_builder builder;
        dpu_reg_plan plan;
        dpu_reg_op op;
        string why;

        resolver = dpu_configuration_resolver::type_id::create(
            "random_qsch_topology_resolver");
        if (!resolver.resolve(make_device_cfg(),
                              make_placement('{host_id: 0, pf_id: 0,
                                              kind: DPU_FUNCTION_PF,
                                              vf_id: 0}),
                              device_snapshot, resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"random topology resolver failed: ",
                       diagnostic.message})

        generator = dpu_qsch_topology_generator::type_id::create(
            "random_qsch_topology_generator");
        generator.mode = DPU_QSCH_TOPOLOGY_RANDOM_VALID;
        if (!generator.build_random(device_snapshot, resource_snapshot,
                                    topology, why) ||
            (topology == null) ||
            !topology.validate(device_snapshot, resource_snapshot, why))
            `uvm_fatal("VIO_PLAN", {"random QSCH topology failed: ", why})
        if (topology.nets.size() != 1 || topology.groups.size() == 0 ||
            topology.ports.size() == 0 || topology.traffic_classes.size() == 0 ||
            topology.queues.size() != 2)
            `uvm_fatal("VIO_PLAN", "random QSCH topology cardinality mismatch")

        // The same generated graph is then imported by the driver extension;
        // lowering must preserve the generated net/group and qpair/TC edges.
        extension = dpu_vio_driver_dataplane_extension::type_id::create(
            "random_qsch_topology_extension");
        extension.emit_vtx = 0;
        extension.emit_vrx = 0;
        extension.set_qsch_topology(topology);
        builder = dpu_vio_register_plan_builder::type_id::create(
            "random_qsch_topology_builder");
        builder.set_dataplane_extension(extension);
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"random topology lowering failed: ", why})
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.q7.q2tc", op) ||
            (op.payload[8:3] != topology.nets[0].net_id[5:0]) ||
            (op.payload[2:0] != topology.queues[0].tc_id[2:0]))
            `uvm_fatal("VIO_PLAN", "random topology Q2TC lowering mismatch")
        if (!plan.find_operation(
                "vio.dataplane.qsch.h0.pf0.k0.vf0.n2g", op) ||
            (op.payload[4:0] != topology.nets[0].group_id[4:0]))
            `uvm_fatal("VIO_PLAN", "random topology N2G lowering mismatch")
    endfunction

    function void test_multi_function_shared_group_topology();
        dpu_configuration_resolver resolver;
        dpu_device_snapshot device_snapshot;
        dpu_resource_snapshot resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_qsch_topology_cfg topology;
        dpu_qsch_topology_generator generator;
        dpu_vio_driver_dataplane_extension extension;
        dpu_vio_register_plan_builder builder;
        dpu_reg_plan plan;
        dpu_reg_op op;
        dpu_vio_qpair_binding_t bindings[$];
        int group_use[int unsigned];
        bit shared_group_seen;
        string why;
        string op_id;
        int unsigned function_id;

        resolver = dpu_configuration_resolver::type_id::create(
            "multi_function_qsch_resolver");
        if (!resolver.resolve(make_multi_function_device_cfg(),
                              make_multi_function_placement(), device_snapshot,
                              resource_snapshot, diagnostic))
            `uvm_fatal("VIO_PLAN", {"multi-function resolver failed: ",
                       diagnostic.message})
        resource_snapshot.list_vio_bindings(bindings);
        if (bindings.size() != 6)
            `uvm_fatal("VIO_PLAN", "multi-function fixture did not resolve six qpairs")

        generator = dpu_qsch_topology_generator::type_id::create(
            "multi_function_qsch_generator");
        generator.mode = DPU_QSCH_TOPOLOGY_RANDOM_VALID;
        generator.max_group_nodes = 8;
        // This property intentionally belongs to the generator API: random
        // attachments remain unconstrained except that at least one group is
        // shared when the scenario asks for it.
        generator.require_shared_group = 1;
        if (!generator.build_random(device_snapshot, resource_snapshot,
                                    topology, why) ||
            (topology == null) ||
            !topology.validate(device_snapshot, resource_snapshot, why))
            `uvm_fatal("VIO_PLAN", {"multi-function topology failed: ", why})
        if ((topology.nets.size() != 3) ||
            (topology.queues.size() != bindings.size()) ||
            (topology.groups.size() >= topology.nets.size()))
            `uvm_fatal("VIO_PLAN", "multi-function topology cardinality is not shared-group capable")

        foreach (topology.nets[index]) begin
            if (topology.nets[index].valid)
                group_use[topology.nets[index].group_id]++;
        end
        shared_group_seen = 0;
        foreach (group_use[group_id]) begin
            if (group_use[group_id] > 1)
                shared_group_seen = 1;
        end
        if (!shared_group_seen)
            `uvm_fatal("VIO_PLAN", "random multi-function topology did not share a group")

        // A global qpair ID is not an arbitrary alias: its resource binding
        // fixes the owning PF/VF.  Ensure validation rejects a topology that
        // tries to move a qpair to another Function's net.
        begin
            dpu_function_key_t saved_owner;
            saved_owner = topology.queues[0].owner_function_key;
            topology.queues[0].owner_function_key =
                topology.nets[1].function_key;
            if (topology.validate(device_snapshot, resource_snapshot, why))
                `uvm_fatal("VIO_PLAN", "topology accepted a qpair owner alias")
            topology.queues[0].owner_function_key = saved_owner;
        end

        foreach (topology.nets[index]) begin
            if (!device_snapshot.get_global_function_id(
                    topology.nets[index].function_key, function_id, why))
                `uvm_fatal("VIO_PLAN", {"multi-function net lookup failed: ", why})
            if (topology.nets[index].net_id != function_id)
                `uvm_fatal("VIO_PLAN", "multi-function net ID lost function identity")
        end

        extension = dpu_vio_driver_dataplane_extension::type_id::create(
            "multi_function_qsch_extension");
        extension.emit_vtx = 0;
        extension.emit_vrx = 0;
        extension.set_qsch_topology(topology);
        builder = dpu_vio_register_plan_builder::type_id::create(
            "multi_function_qsch_builder");
        builder.set_dataplane_extension(extension);
        if (!builder.build(device_snapshot, resource_snapshot, plan, why))
            `uvm_fatal("VIO_PLAN", {"multi-function topology lowering failed: ", why})

        foreach (topology.nets[index]) begin
            op_id = {"vio.dataplane.qsch.",
                     dpu_function_key_name(topology.nets[index].function_key),
                     ".n2g"};
            if (!plan.find_operation(op_id, op) ||
                (op.payload[4:0] != topology.nets[index].group_id[4:0]))
                `uvm_fatal("VIO_PLAN", "multi-function N2G lowering mismatch")
            op_id = {"vio.dataplane.qsch.",
                     dpu_function_key_name(topology.nets[index].function_key),
                     ".g2p"};
            if (!plan.find_operation(op_id, op) ||
                (op.payload[17:16] != topology.nets[index].dst_port[1:0]))
                `uvm_fatal("VIO_PLAN", "multi-function G2P lowering mismatch")
        end
        foreach (topology.queues[index]) begin
            op_id = {"vio.dataplane.qsch.",
                     dpu_function_key_name(
                         topology.queues[index].owner_function_key),
                     $sformatf(".q%0d.q2tc",
                               topology.queues[index].global_qpair_id)};
            if (!plan.find_operation(op_id, op) ||
                (op.payload[8:3] != topology.queues[index].net_id[5:0]) ||
                (op.payload[2:0] != topology.queues[index].tc_id[2:0]))
                `uvm_fatal("VIO_PLAN", "multi-function Q2TC lowering mismatch")
        end
    endfunction

    task automatic test_env_wrapper();
        dpu_reg_plan plan;
        dpu_reg_plan teardown_plan;
        dpu_reg_op notify_commit_op;
        dpu_execution_report report;
        string why;
        int unsigned expected_operation_count;

        if (!device_env.build_vio_register_plan(plan, why))
            `uvm_fatal("VIO_PLAN", {"environment builder failed: ", why})
        if ((executor_spy.record_count() != 0) || (plan == null) ||
            (dataplane_extension_spy.qsch_calls != 1) ||
            (dataplane_extension_spy.vtx_calls != 1) ||
            (dataplane_extension_spy.vrx_calls != 1))
            `uvm_fatal("VIO_PLAN", "plan build performed an executor write")
        if (!plan.find_operation(
                "vio.notify.commit.bank1", notify_commit_op))
            `uvm_fatal("VIO_PLAN",
                "environment setup did not select the default inactive notify bank")
        expected_operation_count = plan.operation_count();
        device_env.apply_vio_register_plan(plan, report);
        if ((report == null) ||
            (report.status() != DPU_CFG_STATUS_SUCCEEDED) ||
            (executor_spy.record_count() != expected_operation_count) ||
            (device_env.get_state() != DPU_DEVICE_ACTIVE))
            `uvm_fatal("VIO_PLAN", "environment wrapper did not apply the plan")

        executor_spy.reset_history();
        if (!device_env.build_vio_teardown_plan(teardown_plan, why) ||
            (teardown_plan == null) || (executor_spy.record_count() != 0))
            `uvm_fatal("VIO_PLAN", {"environment teardown build failed: ", why})
        if (!teardown_plan.find_operation(
                "vio.teardown.notify.commit.bank0", notify_commit_op) ||
            teardown_plan.find_operation(
                "vio.teardown.notify.commit.bank1", notify_commit_op))
            `uvm_fatal("VIO_PLAN",
                "environment teardown did not select the bank opposite successful setup")
        expected_operation_count = teardown_plan.operation_count();
        device_env.apply_vio_teardown_plan(teardown_plan, report);
        if ((report == null) ||
            (report.status() != DPU_CFG_STATUS_SUCCEEDED) ||
            (executor_spy.record_count() != expected_operation_count) ||
            (device_env.get_state() != DPU_DEVICE_RESOLVED))
            `uvm_fatal("VIO_PLAN",
                "environment wrapper did not apply the teardown plan")
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        test_packers();
        test_default_notify_full_shadow();
        test_notify_write_verification();
        test_teardown_plan_clears_only_owned_control_entries();
        test_builder();
        test_af_qpair_limit_includes_extra_queues();
        test_shared_msix_vector();
        test_notify_sorting();
        test_bar_aperture_reject();
        test_driver_dataplane_lowering();
        test_random_qsch_topology();
        test_multi_function_shared_group_topology();
        test_env_wrapper();
        phase.drop_objection(this);
    endtask
endclass : dpu_vio_reg_plan_test

`endif // DPU_VIO_REG_PLAN_TEST_SV
