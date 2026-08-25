`ifndef VIRTIO_DUT_CAPS_TEST_SV
`define VIRTIO_DUT_CAPS_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

class virtio_dut_caps_expected_build_failure extends uvm_report_catcher;
    uvm_report_object expected_env_client;
    int unsigned cfg_error_count;
    int unsigned env_fatal_count;
    string last_cfg_message;
    string last_env_message;

    function new(
        string name,
        uvm_report_object configured_env_client
    );
        super.new(name);
        expected_env_client = configured_env_client;
        cfg_error_count = 0;
        env_fatal_count = 0;
        last_cfg_message = "";
        last_env_message = "";
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "ENV_CFG") &&
            (get_client() == uvm_top) &&
            (get_message() ==
             "default_num_pairs=33 exceeds VIO-net device limit 32")) begin
            cfg_error_count++;
            last_cfg_message = get_message();
            set_severity(UVM_INFO);
        end
        else if ((get_severity() == UVM_FATAL) &&
                 (get_id() == "VIRTIO_ENV") &&
                 (get_client() == expected_env_client) &&
                 (get_message() ==
                  "Invalid virtio-net configuration; refusing to build environment")) begin
            env_fatal_count++;
            last_env_message = get_message();
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_cfg_error extends uvm_report_catcher;
    string expected_message;
    int unsigned caught_count;
    string last_message;

    function new(
        string name,
        string configured_expected_message
    );
        super.new(name);
        expected_message = configured_expected_message;
        caught_count = 0;
        last_message = "";
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "ENV_CFG") &&
            (get_client() == uvm_top) &&
            (get_message() == expected_message)) begin
            caught_count++;
            last_message = get_message();
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_bind_fatal extends uvm_report_catcher;
    uvm_report_object expected_env_client;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_env_client
    );
        super.new(name);
        expected_env_client = configured_env_client;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_FATAL) &&
            (get_id() == "VIRTIO_ENV") &&
            (get_client() == expected_env_client) &&
            (get_message() ==
             "bind_pcie() received a null PCIe RC sequencer")) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_resize_error extends uvm_report_catcher;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        string configured_expected_message
    );
        super.new(name);
        expected_message = configured_expected_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "DYN_RECONFIG") &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_snapshot_mutator extends virtio_resource_client;
    `uvm_object_utils(virtio_dut_caps_snapshot_mutator)

    function new(string name = "virtio_dut_caps_snapshot_mutator");
        super.new(name);
    endfunction

    function void mutate_snapshot_qpair_limit(input int unsigned limit);
        if (dut_caps != null)
            dut_caps.max_vio_net_qpairs_per_device = limit;
    endfunction
endclass

class virtio_dut_caps_reconfig_snapshot_mutator extends virtio_dynamic_reconfig;
    `uvm_object_utils(virtio_dut_caps_reconfig_snapshot_mutator)

    function new(string name = "virtio_dut_caps_reconfig_snapshot_mutator");
        super.new(name);
    endfunction

    function void mutate_snapshot_qpair_limit(input int unsigned limit);
        if (dut_caps != null)
            dut_caps.max_vio_net_qpairs_per_device = limit;
    endfunction

    function int unsigned snapshot_qpair_limit();
        if (dut_caps == null)
            return 0;
        return dut_caps.max_vio_net_qpairs_per_device;
    endfunction
endclass

class virtio_dut_caps_test extends uvm_test;
    `uvm_component_utils(virtio_dut_caps_test)

    dpu_fabric_env fabric;
    dpu_fabric_env_config fabric_cfg;
    dpu_resource_manager manager;
    dpu_function_key_t valid_pf;
    dpu_function_key_t valid_vf;
    virtio_net_env invalid_legacy_env;
    virtio_net_env_config invalid_legacy_cfg;
    virtio_dut_caps_expected_build_failure expected_build_failure;
    virtio_net_env propagated_caps_env;
    virtio_net_env_config propagated_caps_cfg;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function automatic dpu_function_key_t make_key(
        int unsigned host_id,
        int unsigned pf_id,
        dpu_function_kind_e kind,
        int unsigned vf_id
    );
        dpu_function_key_t key;
        key.host_id = host_id;
        key.pf_id = pf_id;
        key.kind = kind;
        key.vf_id = vf_id;
        return key;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        fabric_cfg = dpu_fabric_env_config::type_id::create("fabric_cfg");
        fabric = dpu_fabric_env::type_id::create("fabric", this);

        invalid_legacy_cfg = virtio_net_env_config::type_id::create(
            "invalid_legacy_cfg");
        invalid_legacy_cfg.default_num_pairs = 33;
        invalid_legacy_env = virtio_net_env::type_id::create(
            "invalid_legacy_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "invalid_legacy_env", "cfg", invalid_legacy_cfg);
        expected_build_failure = new(
            "expected_build_failure", invalid_legacy_env);
        uvm_report_cb::add(null, expected_build_failure);

        propagated_caps_cfg = virtio_net_env_config::type_id::create(
            "propagated_caps_cfg");
        propagated_caps_cfg.dut_caps.max_hosts = 1;
        propagated_caps_cfg.dut_caps.max_pfs_per_host = 3;
        propagated_caps_cfg.dut_caps.max_functions = 3;
        propagated_caps_cfg.dut_caps.vio_global_qpair_count = 2;
        propagated_caps_cfg.dut_caps.max_vio_net_qpairs_per_device = 1;
        propagated_caps_cfg.num_hosts = 1;
        propagated_caps_cfg.num_pfs_per_host = new[1];
        propagated_caps_cfg.num_pfs_per_host[0] = 3;
        propagated_caps_cfg.num_vfs_per_pf = new[1];
        propagated_caps_cfg.num_vfs_per_pf[0] = new[3];
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "propagated_caps_env.*.driver_agent", "is_active",
            UVM_PASSIVE);
        propagated_caps_env = virtio_net_env::type_id::create(
            "propagated_caps_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "propagated_caps_env", "cfg", propagated_caps_cfg);
    endfunction

    task assert_invalid_legacy_config_hard_fails();
        virtio_dut_caps_expected_bind_fatal bind_catcher;

        uvm_report_cb::delete(null, expected_build_failure);
        if ((expected_build_failure.cfg_error_count != 1) ||
            (expected_build_failure.env_fatal_count != 1)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "invalid legacy build reported ENV_CFG=%0d VIRTIO_ENV_FATAL=%0d; expected 1/1",
                expected_build_failure.cfg_error_count,
                expected_build_failure.env_fatal_count))
        end
        if ((expected_build_failure.last_cfg_message !=
             "default_num_pairs=33 exceeds VIO-net device limit 32") ||
            (expected_build_failure.last_env_message !=
             "Invalid virtio-net configuration; refusing to build environment")) begin
            `uvm_fatal("DUT_CAPS",
                "invalid legacy build reports did not preserve exact context")
        end
        if (invalid_legacy_env.host_mem != null) begin
            `uvm_fatal("DUT_CAPS",
                "invalid legacy configuration continued normal environment construction")
        end

        bind_catcher = new("invalid_legacy_bind_catcher", invalid_legacy_env);
        invalid_legacy_env.v_seqr = propagated_caps_env.v_seqr;
        uvm_report_cb::add(null, bind_catcher);
        invalid_legacy_env.bind_pcie(null);
        uvm_report_cb::delete(null, bind_catcher);
        invalid_legacy_env.v_seqr = null;
        if (bind_catcher.caught_count != 0) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "invalid legacy bind reported %0d null-sequencer fatal(s); expected silent return",
                bind_catcher.caught_count))
        end
    endtask

    task assert_real_dut_capability_defaults();
        dpu_dut_caps invalid_caps;
        dpu_dut_caps zero_caps;
        string why;

        if ((fabric_cfg.dut_caps.max_hosts != 2) ||
            (fabric_cfg.dut_caps.max_pfs_per_host != 4) ||
            (fabric_cfg.dut_caps.max_vfs_per_pf != 16) ||
            (fabric_cfg.dut_caps.vio_global_qpair_count != 2048) ||
            (fabric_cfg.dut_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS", "default real-DUT capability profile is incorrect")
        end

        invalid_caps = dpu_dut_caps::type_id::create("invalid_caps");
        invalid_caps.max_vio_net_qpairs_per_device = 33;
        if (invalid_caps.validate(why)) begin
            `uvm_fatal("DUT_CAPS", "capability profile accepted 33 VIO qpairs/device")
        end

        zero_caps = dpu_dut_caps::type_id::create("zero_caps");
        zero_caps.max_hosts = 0;
        if (zero_caps.validate(why)) begin
            `uvm_fatal("DUT_CAPS", "capability profile accepted zero hosts")
        end
        if (why != "DUT host capability must be nonzero") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "zero host capability returned an inaccurate reason: %s", why))
        end
    endtask

    task assert_config_rejected_once(
        input virtio_net_env_config cfg,
        input string expected_message,
        input string accepted_fatal_message,
        ref int unsigned total_caught
    );
        virtio_dut_caps_expected_cfg_error catcher;

        catcher = new({cfg.get_name(), "_catcher"}, expected_message);
        uvm_report_cb::add(null, catcher);
        if (cfg.validate())
            `uvm_fatal("DUT_CAPS", accepted_fatal_message)
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) ||
            (catcher.last_message != expected_message)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "%s produced %0d matching ENV_CFG reports; expected exactly one: %s",
                cfg.get_name(), catcher.caught_count, expected_message))
        end
        total_caught += catcher.caught_count;
    endtask

    task assert_virtio_config_uses_dut_caps();
        virtio_net_env_config cfg;
        virtio_dut_caps_expected_cfg_error catcher;
        int unsigned total_caught;

        total_caught = 0;

        catcher = new("valid_32_qpair_catcher",
            "default_num_pairs=33 exceeds VIO-net device limit 32");
        uvm_report_cb::add(null, catcher);

        cfg = virtio_net_env_config::type_id::create("valid_32_qpair_cfg");
        cfg.default_num_pairs = 32;
        if (!cfg.validate())
            `uvm_fatal("DUT_CAPS", "32-qpair default configuration was rejected")
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count != 0)
            `uvm_fatal("DUT_CAPS", "valid 32-qpair configuration reported ENV_CFG")

        cfg = virtio_net_env_config::type_id::create("invalid_33_qpair_cfg");
        cfg.default_num_pairs = 33;
        assert_config_rejected_once(cfg,
            "default_num_pairs=33 exceeds VIO-net device limit 32",
            "33-qpair default configuration was accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_vf_qpair_cfg");
        cfg.vf_configs = new[1];
        cfg.vf_configs[0] = cfg.get_default_driver_config();
        cfg.vf_configs[0].num_queue_pairs = 33;
        assert_config_rejected_once(cfg,
            "VF0 num_queue_pairs=33 exceeds VIO-net device limit 32",
            "VF configuration accepted 33 qpairs", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_zero_host_cfg");
        cfg.num_hosts = 0;
        cfg.num_pfs_per_host = new[1];
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[0];
        assert_config_rejected_once(cfg,
            "num_hosts=0 must be nonzero",
            "zero-host topology was accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_host_cfg");
        cfg.num_hosts = 3;
        cfg.num_pfs_per_host = new[3];
        cfg.num_vfs_per_pf = new[3];
        foreach (cfg.num_pfs_per_host[host_id]) begin
            cfg.num_pfs_per_host[host_id] = 1;
            cfg.num_vfs_per_pf[host_id] = new[1];
        end
        assert_config_rejected_once(cfg,
            "num_hosts=3 exceeds DUT limit 2",
            "three-host topology exceeded real-DUT caps", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_zero_pf_cfg");
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 0;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[0];
        assert_config_rejected_once(cfg,
            "host 0 PF count 0 must be nonzero",
            "zero-PF topology was accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_pf_cfg");
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 5;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[5];
        assert_config_rejected_once(cfg,
            "host 0 PF count 5 exceeds DUT limit 4",
            "five-PF topology exceeded real-DUT caps", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_vf_cfg");
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 1;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[1];
        cfg.num_vfs_per_pf[0][0] = 17;
        assert_config_rejected_once(cfg,
            "host 0 PF 0 VF count 17 exceeds DUT limit 16",
            "17-VF topology exceeded real-DUT caps", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_zero_default_cfg");
        cfg.default_num_pairs = 0;
        assert_config_rejected_once(cfg,
            "default_num_pairs=0 must be nonzero",
            "zero-qpair default configuration was accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_zero_vf_cfg");
        cfg.vf_configs = new[1];
        cfg.vf_configs[0] = cfg.get_default_driver_config();
        cfg.vf_configs[0].num_queue_pairs = 0;
        assert_config_rejected_once(cfg,
            "VF0 num_queue_pairs=0 must be nonzero",
            "VF configuration accepted zero qpairs", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_null_caps_cfg");
        cfg.dut_caps = null;
        assert_config_rejected_once(cfg,
            "invalid DUT capabilities: null capability object",
            "null DUT capabilities were accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create("invalid_caps_root_cfg");
        cfg.dut_caps.max_hosts = 0;
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 1;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[1];
        cfg.num_vfs_per_pf[0][0] = 0;
        assert_config_rejected_once(cfg,
            "invalid DUT capabilities: DUT host capability must be nonzero",
            "invalid DUT capabilities were accepted", total_caught);

        cfg = virtio_net_env_config::type_id::create(
            "invalid_function_count_cfg");
        cfg.dut_caps.max_functions = 1;
        cfg.num_hosts = 1;
        cfg.num_pfs_per_host = new[1];
        cfg.num_pfs_per_host[0] = 1;
        cfg.num_vfs_per_pf = new[1];
        cfg.num_vfs_per_pf[0] = new[1];
        cfg.num_vfs_per_pf[0][0] = 1;
        assert_config_rejected_once(cfg,
            "requested 2 functions exceeds DUT limit 1",
            "DUT function-count limit was not enforced", total_caught);

        if (total_caught != 12)
            `uvm_fatal("DUT_CAPS", $sformatf(
                "caught %0d expected invalid configurations; expected exactly 12",
                total_caught))
    endtask

    task assert_env_propagates_caps_to_fabric();
        dpu_resource_manager propagated_manager;
        dpu_dut_caps snapshot;
        virtio_resource_client clients[3];
        string why;

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "propagated_caps_env.fabric", "dpu_resource_manager",
            propagated_manager
        )) begin
            `uvm_fatal("DUT_CAPS",
                "capability-driven virtio env did not publish its Fabric manager")
        end

        snapshot = propagated_manager.snapshot_dut_caps();
        if ((snapshot.max_hosts != 1) ||
            (snapshot.max_pfs_per_host != 3) ||
            (snapshot.max_functions != 3) ||
            (snapshot.vio_global_qpair_count != 2) ||
            (snapshot.max_vio_net_qpairs_per_device != 1)) begin
            `uvm_fatal("DUT_CAPS",
                "virtio env did not copy its non-default DUT caps into Fabric")
        end

        if (propagated_caps_env.pf_instances.size() != 3)
            `uvm_fatal("DUT_CAPS", "capability test env did not build three PFs")

        foreach (clients[index]) begin
            clients[index] = propagated_caps_env.pf_instances[index].
                pf_function.resource_client;
            if (clients[index] == null)
                `uvm_fatal("DUT_CAPS", $sformatf(
                    "PF%0d did not receive a Fabric resource client", index))
            if (!clients[index].mark_device_ready(why))
                `uvm_fatal("DUT_CAPS", $sformatf(
                    "PF%0d could not become device-ready: %s", index, why))
        end

        if (clients[0].reserve_qpairs(0, 2, why))
            `uvm_fatal("DUT_CAPS",
                "single PF exceeded the propagated one-qpair device limit")
        if (why != "VIO-net local qpair range exceeds device limit 0..0")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "per-device qpair rejection used wrong reason: %s", why))

        if (!clients[0].reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "first PF could not reserve one qpair: %s", why))
        if (!clients[1].reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "second PF could not reserve one qpair: %s", why))
        if (clients[2].reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS",
                "third PF exceeded the propagated global qpair capacity")
        if (why != "resource-class capacity would be exceeded")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "global qpair rejection used wrong reason: %s", why))
        if (!clients[0].release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "first PF could not release its propagated qpair: %s", why))
        if (!clients[1].release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "second PF could not release its propagated qpair: %s", why))
        if (!clients[2].reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "third PF could not reserve after capacity recovery: %s", why))
        if (!clients[2].release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "third PF could not release its recovered qpair: %s", why))
    endtask

    task assert_dynamic_resize_limit();
        virtio_dut_caps_reconfig_snapshot_mutator reconfig;
        virtio_dut_caps_expected_resize_error default_catcher;
        virtio_dut_caps_expected_resize_error propagated_catcher;
        virtio_dut_caps_expected_resize_error zero_catcher;
        dpu_dut_caps custom_caps;
        dpu_dut_caps invalid_caps;
        dpu_dut_caps rebind_caps;
        string why;

        reconfig = virtio_dut_caps_reconfig_snapshot_mutator::type_id::create(
            "reconfig");
        if (reconfig.max_supported_qpairs() != 32)
            `uvm_fatal("DUT_CAPS",
                "standalone dynamic reconfig did not default to 32 qpairs")
        if (!reconfig.qpair_count_supported(32))
            `uvm_fatal("DUT_CAPS", "dynamic resize rejected 32 qpairs")
        if (reconfig.qpair_count_supported(33))
            `uvm_fatal("DUT_CAPS", "dynamic resize accepted 33 qpairs")
        if (reconfig.qpair_count_supported(0))
            `uvm_fatal("DUT_CAPS", "dynamic resize accepted zero qpairs")

        zero_catcher = new("zero_resize_catcher",
            "live_mq_resize: 0 pairs is outside supported range 1..32");
        uvm_report_cb::add(null, zero_catcher);
        reconfig.live_mq_resize(null, 1, 0, 0);
        uvm_report_cb::delete(null, zero_catcher);
        if (zero_catcher.caught_count != 1)
            `uvm_fatal("DUT_CAPS",
                "zero resize did not use the supported-range diagnostic")

        default_catcher = new("default_resize_catcher",
            "live_mq_resize: 33 pairs exceeds device limit 32");
        uvm_report_cb::add(null, default_catcher);
        reconfig.live_mq_resize(null, 1, 33, 0);
        uvm_report_cb::delete(null, default_catcher);
        if (default_catcher.caught_count != 1)
            `uvm_fatal("DUT_CAPS",
                "invalid default-cap resize did not return before VF access")

        if (reconfig.bind_dut_caps(null, why))
            `uvm_fatal("DUT_CAPS",
                "standalone dynamic reconfig accepted null DUT capabilities")
        if (why != "dynamic reconfig DUT capabilities are null")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "null dynamic capability bind used wrong reason: %s", why))
        if ((reconfig.max_supported_qpairs() != 32) ||
            !reconfig.qpair_count_supported(32) ||
            reconfig.qpair_count_supported(33)) begin
            `uvm_fatal("DUT_CAPS",
                "null dynamic capability bind changed standalone enforcement")
        end

        invalid_caps = dpu_dut_caps::type_id::create(
            "invalid_dynamic_reconfig_caps");
        invalid_caps.max_hosts = 0;
        if (reconfig.bind_dut_caps(invalid_caps, why))
            `uvm_fatal("DUT_CAPS",
                "standalone dynamic reconfig accepted invalid DUT capabilities")
        if (why !=
            "invalid DUT capabilities: DUT host capability must be nonzero") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "invalid dynamic capability bind used wrong reason: %s", why))
        end
        if ((reconfig.max_supported_qpairs() != 32) ||
            (reconfig.snapshot_qpair_limit() != 0)) begin
            `uvm_fatal("DUT_CAPS",
                "invalid dynamic capability bind changed standalone state")
        end

        custom_caps = dpu_dut_caps::type_id::create(
            "custom_dynamic_reconfig_caps");
        custom_caps.max_vio_net_qpairs_per_device = 1;
        if (!reconfig.bind_dut_caps(custom_caps, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "valid dynamic capability bind failed: %s", why))
        if ((reconfig.max_supported_qpairs() != 1) ||
            (reconfig.snapshot_qpair_limit() != 1) ||
            !reconfig.qpair_count_supported(1) ||
            reconfig.qpair_count_supported(2)) begin
            `uvm_fatal("DUT_CAPS",
                "valid dynamic capability bind did not enforce custom limit 1")
        end

        custom_caps.max_vio_net_qpairs_per_device = 2;
        if ((reconfig.max_supported_qpairs() != 1) ||
            (reconfig.snapshot_qpair_limit() != 1) ||
            reconfig.qpair_count_supported(2)) begin
            `uvm_fatal("DUT_CAPS",
                "source DUT capability mutation relaxed dynamic enforcement")
        end

        rebind_caps = dpu_dut_caps::type_id::create(
            "dynamic_reconfig_rebind_caps");
        rebind_caps.max_vio_net_qpairs_per_device = 2;
        if (reconfig.bind_dut_caps(rebind_caps, why))
            `uvm_fatal("DUT_CAPS",
                "dynamic reconfig accepted a second DUT capability bind")
        if (why != "dynamic reconfig DUT capabilities are already bound")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "dynamic capability rebind used wrong reason: %s", why))
        if ((reconfig.max_supported_qpairs() != 1) ||
            (reconfig.snapshot_qpair_limit() != 1) ||
            reconfig.qpair_count_supported(2)) begin
            `uvm_fatal("DUT_CAPS",
                "failed dynamic capability rebind relaxed custom limit 1")
        end

        reconfig.mutate_snapshot_qpair_limit(2);
        if ((reconfig.max_supported_qpairs() != 1) ||
            reconfig.qpair_count_supported(2)) begin
            `uvm_fatal("DUT_CAPS",
                "protected dynamic capability mutation relaxed custom limit 1")
        end

        if (propagated_caps_env.dyn_reconfig == null)
            `uvm_fatal("DUT_CAPS",
                "capability-driven virtio env did not build dynamic reconfig")
        if (propagated_caps_env.dyn_reconfig.max_supported_qpairs() != 1) begin
            `uvm_fatal("DUT_CAPS",
                "dynamic reconfig did not receive the non-default device limit")
        end
        if (!propagated_caps_env.dyn_reconfig.qpair_count_supported(1))
            `uvm_fatal("DUT_CAPS", "dynamic resize rejected custom-cap qpair 1")
        if (propagated_caps_env.dyn_reconfig.qpair_count_supported(2))
            `uvm_fatal("DUT_CAPS", "dynamic resize accepted custom-cap qpair 2")

        propagated_caps_cfg.dut_caps.max_vio_net_qpairs_per_device = 2;
        if ((propagated_caps_env.dyn_reconfig.max_supported_qpairs() != 1) ||
            propagated_caps_env.dyn_reconfig.qpair_count_supported(2)) begin
            `uvm_fatal("DUT_CAPS",
                "env source capability mutation relaxed custom qpair limit 1")
        end
        propagated_caps_cfg.dut_caps.max_vio_net_qpairs_per_device = 1;

        propagated_catcher = new("propagated_resize_catcher",
            "live_mq_resize: 2 pairs exceeds device limit 1");
        uvm_report_cb::add(null, propagated_catcher);
        propagated_caps_env.dyn_reconfig.live_mq_resize(null, 1, 2, 0);
        uvm_report_cb::delete(null, propagated_catcher);
        if (propagated_catcher.caught_count != 1)
            `uvm_fatal("DUT_CAPS",
                "invalid custom-cap resize did not return before VF access")
    endtask

    task configure_fabric();
        dpu_resource_pool_config_t unused_profile;
        dpu_resource_pool_config_t qpair_profile;
        string why;

        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0100_0000_0000;
        unused_profile.name = "test.unused";
        unused_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        unused_profile.capacity = 1;
        unused_profile.max_per_function = 1;
        fabric_cfg.resource_profiles.push_back(unused_profile);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = fabric_cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            fabric_cfg.dut_caps.max_vio_net_qpairs_per_device;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf("Fabric configuration failed: %s", why))
        end
        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "fabric", "dpu_resource_manager", manager
        )) begin
            `uvm_fatal("DUT_CAPS", "Fabric did not publish its resource manager")
        end
    endtask

    task assert_manager_topology_limits();
        dpu_function_key_t invalid_key;
        string why;

        valid_pf = make_key(0, 0, DPU_FUNCTION_PF, 0);
        if (!manager.register_function(valid_pf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid PF rejected: %s", why))

        invalid_key = make_key(2, 0, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "host_id 2 exceeded the real-DUT capability")

        invalid_key = make_key(0, 4, DPU_FUNCTION_PF, 0);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "pf_id 4 exceeded the real-DUT capability")

        valid_vf = make_key(0, 0, DPU_FUNCTION_VF, 15);
        if (!manager.register_function(valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid VF15 rejected: %s", why))

        invalid_key = make_key(0, 0, DPU_FUNCTION_VF, 16);
        if (manager.register_function(invalid_key, why))
            `uvm_fatal("DUT_CAPS", "vf_id 16 exceeded the real-DUT capability")
    endtask

    task assert_vio_local_qpair_limit();
        dpu_bar_pair_lease_t bars[$];
        dpu_resource_manager original_manager;
        dpu_resource_manager missing_class_manager;
        dpu_function_key_t original_key;
        dpu_function_key_t failed_rebind_key;
        dpu_resource_class_id_t original_class_id;
        dpu_dut_caps original_caps;
        dpu_dut_caps observed_caps;
        virtio_resource_client pf_client;
        virtio_resource_client vf_client;
        virtio_dut_caps_snapshot_mutator mutable_vf_client;
        string why;

        if (!manager.activate_function(valid_pf, bars, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid PF activation failed: %s", why))
        if (!manager.activate_function(valid_vf, bars, why))
            `uvm_fatal("DUT_CAPS", $sformatf("valid VF activation failed: %s", why))

        pf_client = virtio_resource_client::type_id::create("pf_client");
        mutable_vf_client = virtio_dut_caps_snapshot_mutator::type_id::create(
            "vf_client");
        vf_client = mutable_vf_client;
        if (vf_client.snapshot_bound_dut_caps() != null)
            `uvm_fatal("DUT_CAPS",
                "unbound VF client exposed a DUT capability snapshot")
        if (!pf_client.bind_to_fabric(manager, valid_pf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("PF client bind failed: %s", why))
        if (!vf_client.bind_to_fabric(manager, valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf("VF client bind failed: %s", why))
        if (!pf_client.mark_device_ready(why))
            `uvm_fatal("DUT_CAPS", $sformatf("PF client ready failed: %s", why))
        if (!vf_client.mark_device_ready(why))
            `uvm_fatal("DUT_CAPS", $sformatf("VF client ready failed: %s", why))

        observed_caps = vf_client.snapshot_bound_dut_caps();
        if ((observed_caps == null) ||
            (observed_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS",
                "VF client did not expose its bound DUT capability snapshot")
        end
        observed_caps.max_vio_net_qpairs_per_device = 33;
        observed_caps = vf_client.snapshot_bound_dut_caps();
        if ((observed_caps == null) ||
            (observed_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS",
                "mutating the observed VF caps changed the bound snapshot")
        end
        if (vf_client.reserve_qpairs(32, 1, why))
            `uvm_fatal("DUT_CAPS",
                "mutated observed VF caps allowed local pair 32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "observed caps mutation rejection used wrong reason: %s", why))

        mutable_vf_client.mutate_snapshot_qpair_limit(33);
        if (vf_client.reserve_qpairs(32, 1, why))
            `uvm_fatal("DUT_CAPS",
                "mutable VF client snapshot allowed local pair 32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "mutated snapshot rejection used wrong reason: %s", why))

        original_manager = vf_client.resource_manager;
        original_key = vf_client.function_key;
        original_class_id = vf_client.qpair_class_id;
        original_caps = vf_client.snapshot_bound_dut_caps();
        if (original_class_id == '0)
            `uvm_fatal("DUT_CAPS",
                "failed rebind guard requires a nonzero virtio.qpair class ID")
        failed_rebind_key = make_key(1, 3, DPU_FUNCTION_VF, 14);
        missing_class_manager = dpu_resource_manager::type_id::create(
            "missing_class_manager");
        if (vf_client.bind_to_fabric(
            missing_class_manager, failed_rebind_key, why
        )) begin
            `uvm_fatal("DUT_CAPS",
                "VF client rebound to a manager without virtio.qpair")
        end
        if (why != "resource-class name is not registered")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "failed rebind used wrong reason: %s", why))
        if ((vf_client.resource_manager != original_manager) ||
            (vf_client.function_key.host_id != original_key.host_id) ||
            (vf_client.function_key.pf_id != original_key.pf_id) ||
            (vf_client.function_key.kind != original_key.kind) ||
            (vf_client.function_key.vf_id != original_key.vf_id) ||
            (vf_client.qpair_class_id != original_class_id)) begin
            `uvm_fatal("DUT_CAPS",
                "failed rebind partially replaced the old VF binding")
        end
        observed_caps = vf_client.snapshot_bound_dut_caps();
        if ((observed_caps == null) || (original_caps == null) ||
            (observed_caps.max_hosts != original_caps.max_hosts) ||
            (observed_caps.max_pfs_per_host !=
             original_caps.max_pfs_per_host) ||
            (observed_caps.max_vfs_per_pf != original_caps.max_vfs_per_pf) ||
            (observed_caps.max_functions != original_caps.max_functions) ||
            (observed_caps.global_msix_vector_count !=
             original_caps.global_msix_vector_count) ||
            (observed_caps.vio_global_qpair_count !=
             original_caps.vio_global_qpair_count) ||
            (observed_caps.max_vio_net_qpairs_per_device !=
             original_caps.max_vio_net_qpairs_per_device) ||
            (observed_caps.vio_notify_entries_per_bank !=
             original_caps.vio_notify_entries_per_bank)) begin
            `uvm_fatal("DUT_CAPS",
                "failed rebind replaced the bound VF capability snapshot")
        end
        if (!vf_client.reserve_qpairs(1, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "old VF binding was unusable after failed rebind: %s", why))
        if (!vf_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "old VF binding could not release its rebind probe: %s", why))

        if (!pf_client.reserve_qpairs(0, 32, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "PF rejected valid local pairs 0..31: %s", why))

        if (vf_client.reserve_qpairs(0, 0, why))
            `uvm_fatal("DUT_CAPS", "VF accepted zero local pairs")
        if (why != "lease count must be nonzero")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "zero-count rejection used wrong reason: %s", why))

        if (vf_client.reserve_qpairs(32, 0, why))
            `uvm_fatal("DUT_CAPS", "VF accepted out-of-range zero-count request")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "out-of-range zero-count rejection used wrong reason: %s", why))

        if (vf_client.reserve_qpairs(0, 32'hffff_ffff, why))
            `uvm_fatal("DUT_CAPS", "VF accepted oversized local pair count")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "oversized local pair count rejection used wrong reason: %s", why))

        if (vf_client.reserve_qpairs(32, 1, why))
            `uvm_fatal("DUT_CAPS", "VF accepted local pair 32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "local pair 32 rejection used wrong reason: %s", why))

        if (vf_client.reserve_qpairs(31, 2, why))
            `uvm_fatal("DUT_CAPS", "VF accepted local pair range 31..32")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "local pair range 31..32 rejection used wrong reason: %s", why))

        if (vf_client.reserve_qpairs(32'hffff_ffff, 2, why))
            `uvm_fatal("DUT_CAPS", "VF accepted overflowing local pair range")
        if (why != "VIO-net local qpair range exceeds device limit 0..31")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "overflowing local pair rejection used wrong reason: %s", why))

        if (!vf_client.reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "VF could not independently reserve local pair 0: %s", why))
        if (!vf_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "VF could not release its local qpair lease: %s", why))
        if (!pf_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "PF could not release its local qpair leases: %s", why))
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        assert_invalid_legacy_config_hard_fails();
        assert_real_dut_capability_defaults();
        assert_virtio_config_uses_dut_caps();
        assert_env_propagates_caps_to_fabric();
        assert_dynamic_resize_limit();
        configure_fabric();
        assert_manager_topology_limits();
        assert_vio_local_qpair_limit();
        phase.drop_objection(this);
    endtask
endclass : virtio_dut_caps_test

`endif // VIRTIO_DUT_CAPS_TEST_SV
