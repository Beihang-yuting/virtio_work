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
    uvm_report_object expected_client;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_expected_client,
        string configured_expected_message
    );
        super.new(name);
        expected_client = configured_expected_client;
        expected_message = configured_expected_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "DYN_RECONFIG") &&
            (get_client() == expected_client) &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_fsm_mq_error extends uvm_report_catcher;
    uvm_report_object expected_client;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_expected_client,
        string configured_expected_message
    );
        super.new(name);
        expected_client = configured_expected_client;
        expected_message = configured_expected_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_id() == "AUTO_FSM") &&
            (get_client() == expected_client) &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_exact_error extends uvm_report_catcher;
    uvm_report_object expected_client;
    string expected_id;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_client,
        string configured_id,
        string configured_message
    );
        super.new(name);
        expected_client = configured_client;
        expected_id = configured_id;
        expected_message = configured_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) &&
            (get_client() == expected_client) &&
            (get_id() == expected_id) &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_mq_bind_fatal extends uvm_report_catcher;
    uvm_report_object expected_client;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_expected_client,
        string configured_expected_message
    );
        super.new(name);
        expected_client = configured_expected_client;
        expected_message = configured_expected_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_FATAL) &&
            (get_id() == "FUNCTION_BIND") &&
            (get_client() == expected_client) &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_expected_exact_fatal extends uvm_report_catcher;
    uvm_report_object expected_client;
    string expected_id;
    string expected_message;
    int unsigned caught_count;

    function new(
        string name,
        uvm_report_object configured_client,
        string configured_id,
        string configured_message
    );
        super.new(name);
        expected_client = configured_client;
        expected_id = configured_id;
        expected_message = configured_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_FATAL) &&
            (get_client() == expected_client) &&
            (get_id() == expected_id) &&
            (get_message() == expected_message)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass

class virtio_dut_caps_transport_config_spy extends virtio_pci_transport;
    `uvm_object_utils(virtio_dut_caps_transport_config_spy)

    int unsigned configure_fabric_count;

    function new(string name = "virtio_dut_caps_transport_config_spy");
        super.new(name);
        configure_fabric_count = 0;
    endfunction

    virtual function void configure_fabric_managed(
        input virtio_resource_client resource_client
    );
        configure_fabric_count++;
        super.configure_fabric_managed(resource_client);
    endfunction
endclass

class virtio_dut_caps_mq_ops_spy extends virtio_atomic_ops;
    `uvm_object_utils(virtio_dut_caps_mq_ops_spy)

    int unsigned ctrl_mq_count;
    int unsigned setup_count;
    int unsigned teardown_count;

    function new(string name = "virtio_dut_caps_mq_ops_spy");
        super.new(name);
        reset_counts();
    endfunction

    function void reset_counts();
        ctrl_mq_count = 0;
        setup_count = 0;
        teardown_count = 0;
    endfunction

    virtual task ctrl_set_mq_pairs(
        int unsigned num_pairs,
        ref bit success
    );
        ctrl_mq_count++;
        success = 1;
    endtask

    virtual task setup_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        virtqueue_type_e vq_type,
        output bit ok
    );
        setup_count++;
        ok = 1;
    endtask

    virtual task teardown_queue(int unsigned queue_id);
        teardown_count++;
    endtask
endclass

class virtio_dut_caps_mq_fsm_probe extends virtio_auto_fsm;
    `uvm_object_utils(virtio_dut_caps_mq_fsm_probe)

    function new(string name = "virtio_dut_caps_mq_fsm_probe");
        super.new(name);
    endfunction

    function int unsigned observed_active_num_pairs();
        return active_num_pairs;
    endfunction

    function int unsigned observed_max_supported_qpairs();
        return max_supported_mq_pairs();
    endfunction
endclass

// These subclasses deliberately redeclare the public capability-sensitive
// entry points.  Calls in the tests below are made through base-class handles,
// matching the production driver/helper dispatch paths.  The public methods
// must therefore remain unreachable while the protected do_* hooks stay
// available for legal factory customization.
class virtio_dut_caps_malicious_fsm extends virtio_dut_caps_mq_fsm_probe;
    `uvm_object_utils(virtio_dut_caps_malicious_fsm)

    int unsigned public_configure_count;
    int unsigned public_full_init_count;
    int unsigned public_restore_count;
    int unsigned do_configure_count;
    int unsigned do_full_init_count;
    int unsigned do_restore_count;

    function new(string name = "virtio_dut_caps_malicious_fsm");
        super.new(name);
        public_configure_count = 0;
        public_full_init_count = 0;
        public_restore_count = 0;
        do_configure_count = 0;
        do_full_init_count = 0;
        do_restore_count = 0;
    endfunction

    virtual task configure_mq(int unsigned num_pairs);
        public_configure_count++;
    endtask

    virtual task full_init();
        public_full_init_count++;
    endtask

    virtual task restore_from_migration(
        virtio_device_snapshot_t snap,
        output bit ok
    );
        public_restore_count++;
        ok = 1;
    endtask

    protected virtual task do_configure_mq(int unsigned num_pairs);
        do_configure_count++;
    endtask

    protected virtual task do_full_init();
        do_full_init_count++;
    endtask

    protected virtual task do_restore_from_migration(
        virtio_device_snapshot_t snap,
        output bit ok
    );
        do_restore_count++;
        ok = 1;
    endtask
endclass

class virtio_dut_caps_malicious_reconfig extends virtio_dynamic_reconfig;
    `uvm_object_utils(virtio_dut_caps_malicious_reconfig)

    int unsigned public_resize_count;
    int unsigned do_resize_count;

    function new(string name = "virtio_dut_caps_malicious_reconfig");
        super.new(name);
        public_resize_count = 0;
        do_resize_count = 0;
    endfunction

    virtual task live_mq_resize(
        virtio_vf_instance vf,
        int unsigned old_pairs,
        int unsigned new_pairs,
        bit traffic_active
    );
        public_resize_count++;
    endtask

    protected virtual task do_live_mq_resize(
        virtio_vf_instance vf,
        int unsigned old_pairs,
        int unsigned new_pairs,
        bit traffic_active
    );
        do_resize_count++;
    endtask
endclass

class virtio_dut_caps_malicious_function extends virtio_function_instance;
    `uvm_component_utils(virtio_dut_caps_malicious_function)

    int unsigned public_bind_count;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        public_bind_count = 0;
    endfunction

    virtual function void bind_pcie_components(
        input string function_name,
        input virtio_pci_transport transport_ref,
        input virtqueue_manager vq_mgr_ref,
        input virtio_driver_agent driver_agent_ref,
        input host_mem_manager hmem,
        input virtio_iommu_model iommu_mdl,
        input virtio_memory_barrier_model bar_mdl,
        input virtqueue_error_injector einj,
        input virtio_wait_policy wpol,
        input virtio_driver_config_t driver_cfg,
        input uvm_sequencer #(pcie_tl_tlp) pcie_rc_seqr,
        ref virtio_atomic_ops ops,
        ref virtio_auto_fsm fsm
    );
        public_bind_count++;
    endfunction
endclass

class virtio_dut_caps_driver_probe extends virtio_driver;
    `uvm_component_utils(virtio_dut_caps_driver_probe)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask

    task dispatch_transaction(virtio_transaction req);
        process_transaction(req);
    endtask
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

// Deliberately mutate the public source capability in the phase window after
// virtio_net_env::build_phase() and before its connect-time Fabric/driver
// configuration.  The environment must continue to use one build-time
// snapshot at every capability-dependent boundary.
class virtio_dut_caps_phase_window_env extends virtio_net_env;
    `uvm_component_utils(virtio_dut_caps_phase_window_env)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        cfg.dut_caps.max_vio_net_qpairs_per_device = 2;
        super.connect_phase(phase);
    endfunction
endclass

class virtio_dut_caps_fatal_probe_env extends virtio_net_env;
    `uvm_component_utils(virtio_dut_caps_fatal_probe_env)

    bit drive_connect_failure;
    int unsigned connect_fatal_count;
    bit connect_configuration_valid;

    function new(string name, uvm_component parent);
        super.new(name, parent);
        drive_connect_failure = 0;
        connect_fatal_count = 0;
        connect_configuration_valid = 0;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        virtio_dut_caps_expected_exact_fatal catcher;

        if (!drive_connect_failure)
            return;
        prime_fabric_profiles();
        catcher = new({get_name(), "_connect_catcher"}, this,
            "VIRTIO_ENV",
            {"Fabric QP profile registration failed: ",
             "DPU Fabric resource profiles have already been applied"});
        uvm_report_cb::add(null, catcher);
        super.connect_phase(phase);
        uvm_report_cb::delete(null, catcher);
        connect_fatal_count = catcher.caught_count;
        connect_configuration_valid = configuration_valid;
    endfunction

    function bit invoke_fabric_configuration();
        return configure_fabric_resources();
    endfunction

    function void prime_fabric_profiles();
        dpu_fabric_env_config fabric_cfg;
        dpu_resource_pool_config_t qpair_profile;
        string why;

        fabric_cfg = dpu_fabric_env_config::type_id::create(
            {get_name(), "_prime_cfg"});
        fabric_cfg.mmio_aperture_base = 64'h0001_0000_0000_0000;
        fabric_cfg.mmio_aperture_limit = 64'h0001_0100_0000_0000;
        fabric_cfg.dut_caps.copy_from(cfg.dut_caps);
        qpair_profile.name = "virtio.qpair";
        qpair_profile.kind = DPU_RESOURCE_KIND_QUEUE;
        qpair_profile.capacity = cfg.dut_caps.vio_global_qpair_count;
        qpair_profile.max_per_function =
            cfg.dut_caps.max_vio_net_qpairs_per_device;
        fabric_cfg.resource_profiles.push_back(qpair_profile);
        if (!fabric.apply_resource_profiles(fabric_cfg, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "fatal probe profile priming failed: %s", why))
    endfunction
endclass

class virtio_dut_caps_get_fatal_probe_env extends
    virtio_dut_caps_fatal_probe_env;
    `uvm_component_utils(virtio_dut_caps_get_fatal_probe_env)

    dpu_fabric_env detached_fabric;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        detached_fabric = dpu_fabric_env::type_id::create(
            "detached_fabric", this);
        fabric = detached_fabric;
        pf_instances = new[1];
        pf_instances[0] = virtio_pf_instance::type_id::create(
            "get_probe_pf", this);
        pf_instances[0].configure_topology(0, 0, 0, cfg.pf_bdf);
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
    virtio_dut_caps_phase_window_env phase_window_env;
    virtio_net_env_config phase_window_cfg;
    uvm_sequencer #(pcie_tl_tlp) phase_window_pcie_seqr;
    virtio_dut_caps_fatal_probe_env apply_fatal_env;
    virtio_dut_caps_fatal_probe_env pf_fatal_env;
    virtio_dut_caps_fatal_probe_env vf_fatal_env;
    virtio_dut_caps_get_fatal_probe_env get_fatal_env;
    virtio_net_env_config apply_fatal_cfg;
    virtio_net_env_config pf_fatal_cfg;
    virtio_net_env_config vf_fatal_cfg;
    virtio_net_env_config get_fatal_cfg;
    virtio_function_instance fatal_binding_function;
    virtio_function_instance mq_binding_function;
    virtio_dut_caps_malicious_function malicious_binding_function;
    virtio_dut_caps_driver_probe mq_driver;
    uvm_sequencer #(pcie_tl_tlp) mq_pcie_seqr;

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

    function virtio_net_env_config make_fatal_probe_cfg(
        input string name,
        input int unsigned num_vfs
    );
        virtio_net_env_config probe_cfg;

        probe_cfg = virtio_net_env_config::type_id::create(name);
        probe_cfg.num_hosts = 1;
        probe_cfg.num_pfs_per_host = new[1];
        probe_cfg.num_pfs_per_host[0] = 1;
        probe_cfg.num_vfs_per_pf = new[1];
        probe_cfg.num_vfs_per_pf[0] = new[1];
        probe_cfg.num_vfs_per_pf[0][0] = num_vfs;
        probe_cfg.scb_enable = 0;
        probe_cfg.cov_enable = 0;
        return probe_cfg;
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

        phase_window_cfg = virtio_net_env_config::type_id::create(
            "phase_window_cfg");
        phase_window_cfg.dut_caps.max_vio_net_qpairs_per_device = 1;
        phase_window_cfg.dut_caps.vio_global_qpair_count = 4;
        phase_window_cfg.num_hosts = 1;
        phase_window_cfg.num_pfs_per_host = new[1];
        phase_window_cfg.num_pfs_per_host[0] = 1;
        phase_window_cfg.num_vfs_per_pf = new[1];
        phase_window_cfg.num_vfs_per_pf[0] = new[1];
        phase_window_cfg.num_vfs_per_pf[0][0] = 1;
        phase_window_cfg.scb_enable = 0;
        phase_window_cfg.cov_enable = 0;
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "phase_window_env.*.driver_agent", "is_active",
            UVM_PASSIVE);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "phase_window_env", "cfg", phase_window_cfg);
        phase_window_env = virtio_dut_caps_phase_window_env::type_id::create(
            "phase_window_env", this);
        phase_window_pcie_seqr = new("phase_window_pcie_seqr", this);

        apply_fatal_cfg = make_fatal_probe_cfg("apply_fatal_cfg", 0);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "apply_fatal_env", "cfg", apply_fatal_cfg);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "apply_fatal_env.*.driver_agent", "is_active", UVM_PASSIVE);
        apply_fatal_env = virtio_dut_caps_fatal_probe_env::type_id::create(
            "apply_fatal_env", this);
        apply_fatal_env.drive_connect_failure = 1;

        pf_fatal_cfg = make_fatal_probe_cfg("pf_fatal_cfg", 0);
        vf_fatal_cfg = make_fatal_probe_cfg("vf_fatal_cfg", 2);
        get_fatal_cfg = virtio_net_env_config::type_id::create(
            "get_fatal_cfg");
        get_fatal_cfg.scb_enable = 0;
        get_fatal_cfg.cov_enable = 0;
        uvm_config_db#(virtio_net_env_config)::set(
            this, "pf_fatal_env", "cfg", pf_fatal_cfg);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "vf_fatal_env", "cfg", vf_fatal_cfg);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "get_fatal_env", "cfg", get_fatal_cfg);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "pf_fatal_env.*.driver_agent", "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "vf_fatal_env.*.driver_agent", "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "get_fatal_env.*.driver_agent", "is_active", UVM_PASSIVE);
        pf_fatal_env = virtio_dut_caps_fatal_probe_env::type_id::create(
            "pf_fatal_env", this);
        vf_fatal_env = virtio_dut_caps_fatal_probe_env::type_id::create(
            "vf_fatal_env", this);
        get_fatal_env = virtio_dut_caps_get_fatal_probe_env::type_id::create(
            "get_fatal_env", this);

        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "mq_binding_function.driver_agent", "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "malicious_binding_function.driver_agent", "is_active",
            UVM_PASSIVE);
        mq_binding_function = virtio_function_instance::type_id::create(
            "mq_binding_function", this);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "fatal_binding_function.driver_agent", "is_active",
            UVM_PASSIVE);
        fatal_binding_function = virtio_function_instance::type_id::create(
            "fatal_binding_function", this);
        malicious_binding_function =
            virtio_dut_caps_malicious_function::type_id::create(
                "malicious_binding_function", this);
        mq_driver = virtio_dut_caps_driver_probe::type_id::create(
            "mq_driver", this);
        mq_pcie_seqr = new("mq_pcie_seqr", this);
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

    task assert_env_capability_phase_snapshot();
        dpu_resource_manager phase_manager;
        dpu_dut_caps fabric_caps;
        dpu_dut_caps client_caps;
        dpu_dut_caps env_caps;
        dpu_resource_class_id_t qpair_class_id;
        dpu_resource_lease_t leases[$];
        string why;
        bit profile_accepted_two;
        int unsigned dyn_limit;
        int unsigned fabric_limit;
        int unsigned client_limit;
        int unsigned pf_driver_limit;
        int unsigned vf_driver_limit;
        int unsigned pf_fsm_limit;
        int unsigned vf_fsm_limit;

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "phase_window_env.fabric", "dpu_resource_manager",
            phase_manager
        )) begin
            `uvm_fatal("DUT_CAPS",
                "phase-window environment did not publish its Fabric manager")
        end

        phase_window_env.bind_pcie(phase_window_pcie_seqr);
        if (!phase_window_env.pf_instances[0].pf_function.resource_client.
            mark_device_ready(why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "phase-window PF could not become device-ready: %s", why))
        end
        if (!phase_manager.lookup_resource_class(
            "virtio.qpair", qpair_class_id, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "phase-window qpair profile lookup failed: %s", why))
        end

        dyn_limit = phase_window_env.dyn_reconfig.max_supported_qpairs();
        env_caps = phase_window_env.snapshot_effective_dut_caps();
        if ((env_caps == null) ||
            (env_caps.max_vio_net_qpairs_per_device != 1)) begin
            `uvm_fatal("DUT_CAPS",
                "environment did not expose its build-time capability snapshot")
        end
        env_caps.max_vio_net_qpairs_per_device = 2;
        env_caps = phase_window_env.snapshot_effective_dut_caps();
        if ((env_caps == null) ||
            (env_caps.max_vio_net_qpairs_per_device != 1)) begin
            `uvm_fatal("DUT_CAPS",
                "environment capability accessor aliased its private snapshot")
        end
        fabric_caps = phase_manager.snapshot_dut_caps();
        fabric_limit = fabric_caps.max_vio_net_qpairs_per_device;
        client_caps = phase_window_env.pf_instances[0].pf_function.
            resource_client.snapshot_bound_dut_caps();
        client_limit = client_caps.max_vio_net_qpairs_per_device;
        pf_driver_limit = phase_window_env.pf_instances[0].pf_function.
            drv_cfg.max_vio_net_qpairs_per_device;
        vf_driver_limit = phase_window_env.pf_instances[0].vf_functions[0].
            drv_cfg.max_vio_net_qpairs_per_device;
        pf_fsm_limit = phase_window_env.pf_instances[0].pf_function.
            driver_agent.fsm.max_supported_mq_pairs();
        vf_fsm_limit = phase_window_env.pf_instances[0].vf_functions[0].
            driver_agent.fsm.max_supported_mq_pairs();
        profile_accepted_two = phase_manager.acquire_leases(
            phase_window_env.pf_instances[0].pf_key, qpair_class_id,
            0, 2, leases, why);

        if ((dyn_limit == 1) && (fabric_limit == 2) &&
            (client_limit == 2) && (pf_driver_limit == 2) &&
            (vf_driver_limit == 2) && (pf_fsm_limit == 2) &&
            (vf_fsm_limit == 2) && profile_accepted_two) begin
            `uvm_fatal("DUT_CAPS",
                {"env capability phase split: dyn=1 while Fabric/profile/",
                 "resource-client/PF+VF-driver/FSM limits changed to 2"})
        end

        if ((dyn_limit != 1) || (fabric_limit != 1) ||
            (client_limit != 1) || (pf_driver_limit != 1) ||
            (vf_driver_limit != 1) || (pf_fsm_limit != 1) ||
            (vf_fsm_limit != 1) || profile_accepted_two ||
            (why != "resource-class per-function quota would be exceeded")) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"env capability snapshot mismatch: dyn=%0d Fabric=%0d ",
                 "client=%0d PFdrv=%0d VFdrv=%0d PFfsm=%0d VFfsm=%0d ",
                 "profile_accepted_two=%0d why=%s"},
                dyn_limit, fabric_limit, client_limit, pf_driver_limit,
                vf_driver_limit, pf_fsm_limit, vf_fsm_limit,
                profile_accepted_two, why))
        end
        if (phase_window_cfg.dut_caps.max_vio_net_qpairs_per_device != 2)
            `uvm_fatal("DUT_CAPS",
                "phase-window source capability mutation was unexpectedly restored")
    endtask

    function dpu_resource_manager make_fatal_bind_manager(input string name);
        dpu_resource_manager bind_manager;
        dpu_resource_fabric_authority authority;
        dpu_dut_caps caps;
        dpu_resource_class_id_t class_id;
        string why;

        bind_manager = dpu_resource_manager::type_id::create(name);
        authority = bind_manager.claim_fabric_registry_authority();
        caps = dpu_dut_caps::type_id::create({name, "_caps"});
        if ((authority == null) ||
            !bind_manager.fabric_configure_dut_caps(authority, caps, why) ||
            !bind_manager.fabric_configure_mmio_aperture(
                authority, 64'h0002_0000_0000_0000,
                64'h0002_0100_0000_0000, why) ||
            !bind_manager.fabric_register_resource_class(
                authority, "virtio.qpair", DPU_RESOURCE_KIND_QUEUE,
                caps.vio_global_qpair_count,
                caps.max_vio_net_qpairs_per_device, class_id, why) ||
            !bind_manager.fabric_seal_resource_classes(authority, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "fatal bind manager setup failed: %s", why))
        end
        return bind_manager;
    endfunction

    task assert_function_bind_fatal_returns();
        dpu_resource_manager manager_a;
        dpu_resource_manager manager_b;
        dpu_function_key_t key_a;
        dpu_function_key_t key_b;
        dpu_bar_pair_lease_t no_bars[$];
        virtio_dut_caps_transport_config_spy transport_spy;
        virtio_dut_caps_expected_exact_fatal catcher;
        string expected_message;

        manager_a = make_fatal_bind_manager("fatal_bind_manager_a");
        manager_b = make_fatal_bind_manager("fatal_bind_manager_b");
        key_a = make_key(0, 0, DPU_FUNCTION_PF, 0);
        key_b = make_key(1, 0, DPU_FUNCTION_PF, 0);
        transport_spy = virtio_dut_caps_transport_config_spy::type_id::create(
            "fatal_bind_transport_spy");
        fatal_binding_function.transport = transport_spy;
        fatal_binding_function.configure_function(
            DPU_FUNCTION_PF, key_a, 16'h0500, no_bars, manager_a);
        if ((transport_spy.configure_fabric_count != 1) ||
            (fatal_binding_function.resource_client.resource_manager !=
             manager_a)) begin
            `uvm_fatal("DUT_CAPS",
                "function fatal-return probe could not establish binding A")
        end

        expected_message =
            {"could not bind Fabric resources for 1:0:0:0: ",
             "virtio resource client binding ownership cannot be reassigned"};
        catcher = new("function_bind_return_catcher",
            fatal_binding_function, "FUNCTION_INSTANCE", expected_message);
        uvm_report_cb::add(null, catcher);
        fatal_binding_function.configure_function(
            DPU_FUNCTION_PF, key_b, 16'h0501, no_bars, manager_b);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) ||
            (transport_spy.configure_fabric_count != 1) ||
            (transport_spy.fabric_resource_client !=
             fatal_binding_function.resource_client) ||
            (transport_spy.fabric_resource_client.resource_manager !=
             manager_a) ||
            (fatal_binding_function.resource_client.resource_manager !=
             manager_a) ||
            (fatal_binding_function.resource_manager != manager_a) ||
            (fatal_binding_function.function_kind != DPU_FUNCTION_PF) ||
            (fatal_binding_function.function_key.host_id != key_a.host_id) ||
            (fatal_binding_function.function_key.pf_id != key_a.pf_id) ||
            (fatal_binding_function.function_key.kind != key_a.kind) ||
            (fatal_binding_function.function_key.vf_id != key_a.vf_id) ||
            (fatal_binding_function.bdf != 16'h0500) ||
            (transport_spy.bdf != 16'h0500) ||
            (transport_spy.notify_mgr.function_bdf != 16'h0500) ||
            (transport_spy.bar.requester_id != 16'h0500) ||
            (fatal_binding_function.vq_mgr.bdf != 16'h0500)) begin
            `uvm_fatal("DUT_CAPS",
                {"demoted function bind fatal changed owner/transport ",
                 "identity, authority, or Fabric configuration"})
        end
    endtask

    task assert_env_apply_fatal_returns();
        dpu_resource_manager probe_manager;
        dpu_function_key_t key;
        string why;

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "apply_fatal_env.fabric", "dpu_resource_manager",
            probe_manager)) begin
            `uvm_fatal("DUT_CAPS", "apply-fatal probe manager is unavailable")
        end

        key = make_key(0, 0, DPU_FUNCTION_PF, 0);
        if ((apply_fatal_env.connect_fatal_count != 1) ||
            apply_fatal_env.connect_configuration_valid ||
            (apply_fatal_env.pf_mgr != null) ||
            (apply_fatal_env.pf_instances[0].pf_function.drv_cfg.
             max_vio_net_qpairs_per_device != 0) ||
            apply_fatal_env.pf_instances[0].pf_function.transport.
                is_fabric_managed() ||
            !probe_manager.register_function(key, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"demoted Fabric profile fatal continued through helper/",
                 "connect: reports=%0d valid=%0d why=%s"},
                apply_fatal_env.connect_fatal_count,
                apply_fatal_env.connect_configuration_valid, why))
        end
    endtask

    task assert_env_get_fatal_returns();
        virtio_dut_caps_expected_exact_fatal catcher;
        bit configuration_succeeded;

        catcher = new("env_get_return_catcher", get_fatal_env,
            "VIRTIO_ENV", "Fabric did not publish a resource manager");
        uvm_report_cb::add(null, catcher);
        configuration_succeeded =
            get_fatal_env.invoke_fabric_configuration();
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) || configuration_succeeded ||
            get_fatal_env.pf_instances[0].pf_function.transport.
                is_fabric_managed()) begin
            `uvm_fatal("DUT_CAPS",
                "demoted Fabric-manager lookup fatal continued configuration")
        end
    endtask

    task assert_env_pf_registration_fatal_returns();
        dpu_resource_manager probe_manager;
        dpu_function_key_t valid_key;
        virtio_dut_caps_expected_exact_fatal register_catcher;
        virtio_dut_caps_expected_exact_fatal continuation_catcher;
        string why;
        bit configuration_succeeded;

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "pf_fatal_env.fabric", "dpu_resource_manager",
            probe_manager)) begin
            `uvm_fatal("DUT_CAPS", "PF-fatal probe manager is unavailable")
        end
        pf_fatal_env.pf_instances[0].pf_key.host_id = 2;
        register_catcher = new("env_pf_register_return_catcher", pf_fatal_env,
            "VIRTIO_ENV",
            {"PF registration failed for topology entry 0: ",
             "host_id 2 exceeds DUT max_hosts 2"});
        continuation_catcher = new("env_pf_activate_continuation_catcher",
            pf_fatal_env.pf_instances[0], "PF_INSTANCE",
            {"PF activation failed for host 0 PF 0: ",
             "host_id 2 exceeds DUT max_hosts 2"});
        uvm_report_cb::add(null, register_catcher);
        uvm_report_cb::add(null, continuation_catcher);
        configuration_succeeded =
            pf_fatal_env.invoke_fabric_configuration();
        uvm_report_cb::delete(null, continuation_catcher);
        uvm_report_cb::delete(null, register_catcher);

        valid_key = make_key(0, 0, DPU_FUNCTION_PF, 0);
        if ((register_catcher.caught_count != 1) || configuration_succeeded ||
            (continuation_catcher.caught_count != 0) ||
            pf_fatal_env.pf_instances[0].pf_function.transport.
                is_fabric_managed() ||
            !probe_manager.register_function(valid_key, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"demoted PF registration fatal continued: reports=%0d/",
                 "%0d success=%0d why=%s"}, register_catcher.caught_count,
                continuation_catcher.caught_count, configuration_succeeded,
                why))
        end
    endtask

    task assert_env_vf_registration_fatal_returns();
        dpu_resource_manager probe_manager;
        dpu_function_key_t later_vf_key;
        virtio_dut_caps_expected_exact_fatal register_catcher;
        virtio_dut_caps_expected_exact_fatal continuation_catcher;
        string why;
        bit configuration_succeeded;

        if (!uvm_config_db#(dpu_resource_manager)::get(
            this, "vf_fatal_env.fabric", "dpu_resource_manager",
            probe_manager)) begin
            `uvm_fatal("DUT_CAPS", "VF-fatal probe manager is unavailable")
        end
        vf_fatal_env.pf_instances[0].vf_keys[0].vf_id = 16;
        register_catcher = new("env_vf_register_return_catcher", vf_fatal_env,
            "VIRTIO_ENV",
            {"VF registration failed for topology entry 0 VF 0: ",
             "vf_id 16 exceeds DUT max_vfs_per_pf 16"});
        continuation_catcher = new("env_vf_activate_continuation_catcher",
            vf_fatal_env.pf_instances[0], "PF_INSTANCE",
            {"VF activation failed for host 0 PF 0 VF 0: ",
             "vf_id 16 exceeds DUT max_vfs_per_pf 16"});
        uvm_report_cb::add(null, register_catcher);
        uvm_report_cb::add(null, continuation_catcher);
        configuration_succeeded =
            vf_fatal_env.invoke_fabric_configuration();
        uvm_report_cb::delete(null, continuation_catcher);
        uvm_report_cb::delete(null, register_catcher);

        later_vf_key = make_key(0, 0, DPU_FUNCTION_VF, 1);
        if ((register_catcher.caught_count != 1) || configuration_succeeded ||
            (continuation_catcher.caught_count != 0) ||
            vf_fatal_env.pf_instances[0].pf_function.transport.
                is_fabric_managed() ||
            !probe_manager.register_function(later_vf_key, why)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"demoted VF registration fatal continued: reports=%0d/",
                 "%0d success=%0d why=%s"}, register_catcher.caught_count,
                continuation_catcher.caught_count, configuration_succeeded,
                why))
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

    task assert_expected_error_catchers_match_client();
        virtio_dynamic_reconfig target_reconfig;
        virtio_dynamic_reconfig other_reconfig;
        virtio_dut_caps_mq_fsm_probe target_fsm;
        virtio_dut_caps_mq_fsm_probe other_fsm;
        virtio_dut_caps_expected_resize_error resize_catcher;
        virtio_dut_caps_expected_fsm_mq_error fsm_catcher;
        virtio_dut_caps_expected_exact_error other_resize_catcher;
        virtio_dut_caps_expected_exact_error other_fsm_catcher;
        string resize_message;
        string fsm_message;

        target_reconfig = virtio_dynamic_reconfig::type_id::create(
            "catcher_target_reconfig");
        other_reconfig = virtio_dynamic_reconfig::type_id::create(
            "catcher_other_reconfig");
        resize_message =
            "live_mq_resize: 0 pairs is outside supported range 1..32";
        resize_catcher = new(
            "client_exact_resize_catcher", target_reconfig, resize_message);
        other_resize_catcher = new(
            "other_exact_resize_catcher", other_reconfig,
            "DYN_RECONFIG", resize_message);
        uvm_report_cb::add(null, resize_catcher, UVM_APPEND);
        uvm_report_cb::add(null, other_resize_catcher, UVM_APPEND);
        target_reconfig.live_mq_resize(null, 1, 0, 0);
        other_reconfig.live_mq_resize(null, 1, 0, 0);
        uvm_report_cb::delete(null, other_resize_catcher);
        uvm_report_cb::delete(null, resize_catcher);
        if ((resize_catcher.caught_count != 1) ||
            (other_resize_catcher.caught_count != 1)) begin
            `uvm_error("DUT_CAPS", $sformatf(
                {"resize catcher did not isolate identical reports by client: ",
                 "target=%0d other=%0d"},
                resize_catcher.caught_count,
                other_resize_catcher.caught_count))
        end

        target_fsm = virtio_dut_caps_mq_fsm_probe::type_id::create(
            "catcher_target_fsm");
        other_fsm = virtio_dut_caps_mq_fsm_probe::type_id::create(
            "catcher_other_fsm");
        fsm_message =
            "configure_mq: requested 0 pairs is outside supported range 1..32";
        fsm_catcher = new(
            "client_exact_fsm_catcher", target_fsm, fsm_message);
        other_fsm_catcher = new(
            "other_exact_fsm_catcher", other_fsm, "AUTO_FSM", fsm_message);
        uvm_report_cb::add(null, fsm_catcher, UVM_APPEND);
        uvm_report_cb::add(null, other_fsm_catcher, UVM_APPEND);
        target_fsm.configure_mq(0);
        other_fsm.configure_mq(0);
        uvm_report_cb::delete(null, other_fsm_catcher);
        uvm_report_cb::delete(null, fsm_catcher);
        if ((fsm_catcher.caught_count != 1) ||
            (other_fsm_catcher.caught_count != 1)) begin
            `uvm_error("DUT_CAPS", $sformatf(
                {"FSM catcher did not isolate identical reports by client: ",
                 "target=%0d other=%0d"},
                fsm_catcher.caught_count, other_fsm_catcher.caught_count))
        end
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

        zero_catcher = new("zero_resize_catcher", reconfig,
            "live_mq_resize: 0 pairs is outside supported range 1..32");
        uvm_report_cb::add(null, zero_catcher);
        reconfig.live_mq_resize(null, 1, 0, 0);
        uvm_report_cb::delete(null, zero_catcher);
        if (zero_catcher.caught_count != 1)
            `uvm_fatal("DUT_CAPS",
                "zero resize did not use the supported-range diagnostic")

        default_catcher = new("default_resize_catcher", reconfig,
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

        propagated_catcher = new(
            "propagated_resize_catcher", propagated_caps_env.dyn_reconfig,
            "live_mq_resize: 2 pairs exceeds device limit 1");
        uvm_report_cb::add(null, propagated_catcher);
        propagated_caps_env.dyn_reconfig.live_mq_resize(null, 1, 2, 0);
        uvm_report_cb::delete(null, propagated_catcher);
        if (propagated_catcher.caught_count != 1)
            `uvm_fatal("DUT_CAPS",
                "invalid custom-cap resize did not return before VF access")
    endtask

    task assert_driver_mq_dispatch_uses_dut_cap();
        virtio_net_env_config custom_cfg;
        virtio_driver_config_t driver_cfg;
        virtio_pci_transport transport;
        virtio_pci_transport rebind_transport;
        virtqueue_manager vq_mgr;
        virtqueue_manager rebind_vq_mgr;
        virtio_dut_caps_mq_ops_spy ops_spy;
        virtio_dut_caps_mq_fsm_probe fsm_probe;
        virtio_dut_caps_mq_fsm_probe standalone_fsm_probe;
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;
        virtio_transaction req;
        virtio_dut_caps_expected_fsm_mq_error over_cap_catcher;
        virtio_dut_caps_expected_fsm_mq_error zero_catcher;
        virtio_dut_caps_expected_mq_bind_fatal rebind_catcher;
        string why;

        standalone_fsm_probe = virtio_dut_caps_mq_fsm_probe::type_id::create(
            "standalone_mq_fsm_probe");
        if (standalone_fsm_probe.observed_max_supported_qpairs() != 32)
            `uvm_fatal("DUT_CAPS",
                "standalone FSM did not retain the compatibility limit 32")
        if (!standalone_fsm_probe.bind_mq_pair_limit(0, why) ||
            (standalone_fsm_probe.observed_max_supported_qpairs() != 32)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "legacy zero-valued qpair-limit bind was not compatible: %s",
                why))
        end

        custom_cfg = virtio_net_env_config::type_id::create(
            "mq_custom_cap_cfg");
        custom_cfg.dut_caps.max_vio_net_qpairs_per_device = 1;
        custom_cfg.default_num_pairs = 1;
        driver_cfg = custom_cfg.get_default_driver_config();
        if (driver_cfg.max_vio_net_qpairs_per_device != 1)
            `uvm_fatal("DUT_CAPS",
                "default PF driver config did not receive the env DUT capability")
        custom_cfg.vf_configs = new[1];
        custom_cfg.vf_configs[0] = driver_cfg;
        custom_cfg.vf_configs[0].max_vio_net_qpairs_per_device = 32;
        driver_cfg = custom_cfg.get_vf_config(0);
        if (driver_cfg.max_vio_net_qpairs_per_device != 1)
            `uvm_fatal("DUT_CAPS",
                "explicit VF driver config bypassed the env DUT capability")

        transport = virtio_pci_transport::type_id::create("mq_transport");
        vq_mgr = virtqueue_manager::type_id::create("mq_vq_mgr");
        ops_spy = virtio_dut_caps_mq_ops_spy::type_id::create("mq_ops_spy");
        fsm_probe = virtio_dut_caps_mq_fsm_probe::type_id::create(
            "mq_fsm_probe");
        ops = ops_spy;
        fsm = fsm_probe;
        mq_binding_function.bind_pcie_components(
            "mq_cap_function", transport, vq_mgr, null, null, null, null,
            null, null, driver_cfg, mq_pcie_seqr, ops, fsm);
        mq_driver.ops = ops;
        mq_driver.fsm = fsm;
        fsm_probe.state = FSM_RUNNING;
        if (fsm_probe.observed_max_supported_qpairs() != 1)
            `uvm_fatal("DUT_CAPS",
                "FSM did not snapshot the custom per-function qpair limit")
        if (!fsm_probe.bind_mq_pair_limit(1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "idempotent FSM qpair-limit bind failed: %s", why))
        if (fsm_probe.bind_mq_pair_limit(2, why))
            `uvm_fatal("DUT_CAPS",
                "FSM qpair-limit rebind relaxed custom limit 1")
        if (why !=
            "FSM MQ pair limit is already bound to 1; cannot rebind to 2") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "FSM qpair-limit rebind used wrong reason: %s", why))
        end
        rebind_transport = virtio_pci_transport::type_id::create(
            "mq_rebind_transport");
        rebind_vq_mgr = virtqueue_manager::type_id::create(
            "mq_rebind_vq_mgr");
        driver_cfg.max_vio_net_qpairs_per_device = 2;
        rebind_catcher = new(
            "mq_bind_rebind_catcher", mq_binding_function,
            {"mq_cap_function_rebind could not bind its MQ pair limit: ",
             "FSM MQ pair limit is already bound to 1; cannot rebind to 2"});
        uvm_report_cb::add(null, rebind_catcher);
        mq_binding_function.bind_pcie_components(
            "mq_cap_function_rebind", rebind_transport, rebind_vq_mgr, null,
            null, null, null, null, null, driver_cfg, mq_pcie_seqr, ops, fsm);
        uvm_report_cb::delete(null, rebind_catcher);
        if ((rebind_catcher.caught_count != 1) ||
            (ops != ops_spy) || (fsm != fsm_probe) ||
            (ops_spy.transport != transport) || (ops_spy.vq_mgr != vq_mgr)) begin
            `uvm_fatal("DUT_CAPS",
                "failed MQ-limit rebind partially replaced function bindings")
        end
        custom_cfg.dut_caps.max_vio_net_qpairs_per_device = 2;
        if (fsm_probe.observed_max_supported_qpairs() != 1)
            `uvm_fatal("DUT_CAPS",
                "source DUT capability mutation relaxed the FSM qpair limit")
        driver_cfg.max_vio_net_qpairs_per_device = 32;
        if (fsm_probe.observed_max_supported_qpairs() != 1)
            `uvm_fatal("DUT_CAPS",
                "source driver config mutation relaxed the FSM qpair limit")
        fsm_probe.drv_cfg.max_vio_net_qpairs_per_device = 2;
        if (fsm_probe.observed_max_supported_qpairs() != 1)
            `uvm_fatal("DUT_CAPS",
                "public driver config mutation relaxed the FSM qpair limit")

        req = virtio_transaction::type_id::create("mq_over_cap_req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = 2;
        over_cap_catcher = new(
            "mq_over_cap_catcher", fsm_probe,
            "configure_mq: requested 2 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, over_cap_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, over_cap_catcher);
        if ((over_cap_catcher.caught_count != 1) ||
            (ops_spy.ctrl_mq_count != 0) ||
            (ops_spy.setup_count != 0) ||
            (ops_spy.teardown_count != 0) ||
            (fsm_probe.observed_active_num_pairs() != 1) ||
            (fsm_probe.state != FSM_RUNNING)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"custom-cap VIO_TXN_SET_MQ dispatch escaped its pre-side-effect guard: ",
                 "caught=%0d ctrl_mq=%0d setup=%0d teardown=%0d active=%0d state=%s"},
                over_cap_catcher.caught_count, ops_spy.ctrl_mq_count,
                ops_spy.setup_count, ops_spy.teardown_count,
                fsm_probe.observed_active_num_pairs(), fsm_probe.state.name()))
        end

        req = virtio_transaction::type_id::create("mq_zero_req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = 0;
        zero_catcher = new(
            "mq_zero_catcher", fsm_probe,
            "configure_mq: requested 0 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, zero_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, zero_catcher);
        if ((zero_catcher.caught_count != 1) ||
            (ops_spy.ctrl_mq_count != 0) ||
            (ops_spy.setup_count != 0) ||
            (ops_spy.teardown_count != 0) ||
            (fsm_probe.observed_active_num_pairs() != 1) ||
            (fsm_probe.state != FSM_RUNNING)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"zero-pair VIO_TXN_SET_MQ dispatch escaped its pre-side-effect guard: ",
                 "caught=%0d ctrl_mq=%0d setup=%0d teardown=%0d active=%0d state=%s"},
                zero_catcher.caught_count, ops_spy.ctrl_mq_count,
                ops_spy.setup_count, ops_spy.teardown_count,
                fsm_probe.observed_active_num_pairs(), fsm_probe.state.name()))
        end

        req = virtio_transaction::type_id::create("mq_valid_req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = 1;
        mq_driver.dispatch_transaction(req);
        if ((ops_spy.ctrl_mq_count != 1) ||
            (ops_spy.setup_count != 0) ||
            (ops_spy.teardown_count != 0) ||
            (fsm_probe.observed_active_num_pairs() != 1) ||
            (fsm_probe.state != FSM_RUNNING)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"valid custom-cap VIO_TXN_SET_MQ dispatch was not preserved: ",
                 "ctrl_mq=%0d setup=%0d teardown=%0d active=%0d state=%s"},
                ops_spy.ctrl_mq_count, ops_spy.setup_count,
                ops_spy.teardown_count,
                fsm_probe.observed_active_num_pairs(), fsm_probe.state.name()))
        end
    endtask

    task assert_mandatory_fsm_guards_cannot_be_overridden();
        virtio_dut_caps_malicious_fsm malicious_fsm;
        virtio_dut_caps_mq_ops_spy ops_spy;
        virtio_auto_fsm base_fsm;
        virtio_transaction req;
        virtio_dut_caps_expected_fsm_mq_error set_mq_over_catcher;
        virtio_dut_caps_expected_fsm_mq_error set_mq_unknown_catcher;
        virtio_dut_caps_expected_fsm_mq_error full_over_catcher;
        virtio_dut_caps_expected_fsm_mq_error full_zero_catcher;
        virtio_dut_caps_expected_fsm_mq_error full_unknown_catcher;
        virtio_dut_caps_expected_fsm_mq_error restore_over_catcher;
        virtio_dut_caps_expected_fsm_mq_error restore_zero_catcher;
        virtio_dut_caps_expected_fsm_mq_error restore_unknown_catcher;
        bit restore_over_success;
        bit restore_zero_success;
        bit restore_unknown_success;
        string why;

        malicious_fsm = virtio_dut_caps_malicious_fsm::type_id::create(
            "malicious_fsm");
        ops_spy = virtio_dut_caps_mq_ops_spy::type_id::create(
            "malicious_fsm_ops_spy");
        base_fsm = malicious_fsm;
        base_fsm.ops = ops_spy;
        base_fsm.state = FSM_RUNNING;
        if (!base_fsm.bind_mq_pair_limit(1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "malicious FSM limit bind failed: %s", why))
        mq_driver.fsm = base_fsm;

        req = virtio_transaction::type_id::create("malicious_set_mq_over_req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = 2;
        set_mq_over_catcher = new(
            "malicious_set_mq_over_catcher", malicious_fsm,
            "configure_mq: requested 2 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, set_mq_over_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, set_mq_over_catcher);

        // These public counts are int unsigned; VCS normalizes injected X to
        // zero at this boundary.  Keep the separate stimulus to lock down the
        // normalization plus the same pre-side-effect rejection behavior.
        req.num_pairs = 'x;
        set_mq_unknown_catcher = new(
            "malicious_set_mq_unknown_catcher", malicious_fsm,
            "configure_mq: requested 0 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, set_mq_unknown_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, set_mq_unknown_catcher);

        req = virtio_transaction::type_id::create("malicious_full_over_req");
        req.txn_type = VIO_TXN_INIT;
        malicious_fsm.drv_cfg.num_queue_pairs = 2;
        full_over_catcher = new(
            "malicious_full_over_catcher", malicious_fsm,
            {"full_init: configured queue-pair count 2 is outside supported ",
             "range 1..1"});
        uvm_report_cb::add(null, full_over_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, full_over_catcher);

        malicious_fsm.drv_cfg.num_queue_pairs = 0;
        full_zero_catcher = new(
            "malicious_full_zero_catcher", malicious_fsm,
            {"full_init: configured queue-pair count 0 is outside supported ",
             "range 1..1"});
        uvm_report_cb::add(null, full_zero_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, full_zero_catcher);

        malicious_fsm.drv_cfg.num_queue_pairs = 'x;
        full_unknown_catcher = new(
            "malicious_full_unknown_catcher", malicious_fsm,
            {"full_init: configured queue-pair count 0 is outside supported ",
             "range 1..1"});
        uvm_report_cb::add(null, full_unknown_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, full_unknown_catcher);

        req = virtio_transaction::type_id::create("malicious_restore_over_req");
        req.txn_type = VIO_TXN_RESTORE;
        req.snapshot.num_queue_pairs = 2;
        req.success = 1;
        restore_over_catcher = new(
            "malicious_restore_over_catcher", malicious_fsm,
            {"restore_from_migration: snapshot queue-pair count 2 is outside ",
             "supported range 1..1"});
        uvm_report_cb::add(null, restore_over_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, restore_over_catcher);
        restore_over_success = req.success;
        req.snapshot.num_queue_pairs = 0;
        req.success = 1;
        restore_zero_catcher = new(
            "malicious_restore_zero_catcher", malicious_fsm,
            {"restore_from_migration: snapshot queue-pair count 0 is outside ",
             "supported range 1..1"});
        uvm_report_cb::add(null, restore_zero_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, restore_zero_catcher);
        restore_zero_success = req.success;

        req.snapshot.num_queue_pairs = 'x;
        req.success = 1;
        restore_unknown_catcher = new(
            "malicious_restore_unknown_catcher", malicious_fsm,
            {"restore_from_migration: snapshot queue-pair count 0 is outside ",
             "supported range 1..1"});
        uvm_report_cb::add(null, restore_unknown_catcher);
        mq_driver.dispatch_transaction(req);
        uvm_report_cb::delete(null, restore_unknown_catcher);
        restore_unknown_success = req.success;
        req = virtio_transaction::type_id::create("malicious_set_mq_valid_req");
        req.txn_type = VIO_TXN_SET_MQ;
        req.num_pairs = 1;
        mq_driver.dispatch_transaction(req);

        req = virtio_transaction::type_id::create("malicious_full_valid_req");
        req.txn_type = VIO_TXN_INIT;
        malicious_fsm.drv_cfg.num_queue_pairs = 1;
        mq_driver.dispatch_transaction(req);

        req = virtio_transaction::type_id::create("malicious_restore_valid_req");
        req.txn_type = VIO_TXN_RESTORE;
        req.snapshot.num_queue_pairs = 1;
        req.success = 0;
        mq_driver.dispatch_transaction(req);

        if ((set_mq_over_catcher.caught_count != 1) ||
            (set_mq_unknown_catcher.caught_count != 1) ||
            (full_over_catcher.caught_count != 1) ||
            (full_zero_catcher.caught_count != 1) ||
            (full_unknown_catcher.caught_count != 1) ||
            (restore_over_catcher.caught_count != 1) ||
            (restore_zero_catcher.caught_count != 1) ||
            (restore_unknown_catcher.caught_count != 1) ||
            restore_over_success || restore_zero_success ||
            restore_unknown_success ||
            (malicious_fsm.public_configure_count != 0) ||
            (malicious_fsm.public_full_init_count != 0) ||
            (malicious_fsm.public_restore_count != 0) ||
            (malicious_fsm.do_configure_count != 1) ||
            (malicious_fsm.do_full_init_count != 1) ||
            (malicious_fsm.do_restore_count != 1) ||
            (req.success != 1) ||
            (ops_spy.ctrl_mq_count != 0) ||
            (ops_spy.setup_count != 0) ||
            (ops_spy.teardown_count != 0) ||
            (malicious_fsm.observed_active_num_pairs() != 1) ||
            (malicious_fsm.state != FSM_RUNNING)) begin
            `uvm_error("DUT_CAPS", $sformatf(
                {"base-typed driver dispatch bypassed mandatory FSM guards: ",
                 "reports=%0d/%0d/%0d/%0d/%0d/%0d/%0d/%0d ",
                 "public=%0d/%0d/%0d ",
                 "do=%0d/%0d/%0d restore_ok=%0b/%0b/%0b/%0b ",
                 "ops=%0d/%0d/%0d ",
                 "active=%0d state=%s"},
                set_mq_over_catcher.caught_count,
                set_mq_unknown_catcher.caught_count,
                full_over_catcher.caught_count,
                full_zero_catcher.caught_count,
                full_unknown_catcher.caught_count,
                restore_over_catcher.caught_count,
                restore_zero_catcher.caught_count,
                restore_unknown_catcher.caught_count,
                malicious_fsm.public_configure_count,
                malicious_fsm.public_full_init_count,
                malicious_fsm.public_restore_count,
                malicious_fsm.do_configure_count,
                malicious_fsm.do_full_init_count,
                malicious_fsm.do_restore_count,
                restore_over_success, restore_zero_success,
                restore_unknown_success, req.success,
                ops_spy.ctrl_mq_count, ops_spy.setup_count,
                ops_spy.teardown_count,
                malicious_fsm.observed_active_num_pairs(),
                malicious_fsm.state.name()))
        end
    endtask

    task assert_dynamic_resize_guard_cannot_be_overridden();
        dpu_dut_caps caps;
        virtio_dut_caps_malicious_reconfig malicious_reconfig;
        virtio_dynamic_reconfig base_reconfig;
        virtio_dut_caps_expected_resize_error over_catcher;
        virtio_dut_caps_expected_resize_error zero_catcher;
        virtio_dut_caps_expected_resize_error unknown_catcher;
        string why;

        caps = dpu_dut_caps::type_id::create("malicious_reconfig_caps");
        caps.max_vio_net_qpairs_per_device = 1;
        malicious_reconfig =
            virtio_dut_caps_malicious_reconfig::type_id::create(
                "malicious_reconfig");
        base_reconfig = malicious_reconfig;
        if (!base_reconfig.bind_dut_caps(caps, why))
            `uvm_error("DUT_CAPS", $sformatf(
                "malicious dynamic reconfig capability bind failed: %s", why))

        over_catcher = new(
            "malicious_resize_over_catcher", malicious_reconfig,
            "live_mq_resize: 2 pairs exceeds device limit 1");
        uvm_report_cb::add(null, over_catcher);
        base_reconfig.live_mq_resize(null, 1, 2, 0);
        uvm_report_cb::delete(null, over_catcher);

        zero_catcher = new(
            "malicious_resize_zero_catcher", malicious_reconfig,
            "live_mq_resize: 0 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, zero_catcher);
        base_reconfig.live_mq_resize(null, 1, 0, 0);
        uvm_report_cb::delete(null, zero_catcher);

        unknown_catcher = new(
            "malicious_resize_unknown_catcher", malicious_reconfig,
            "live_mq_resize: 0 pairs is outside supported range 1..1");
        uvm_report_cb::add(null, unknown_catcher);
        base_reconfig.live_mq_resize(null, 1, 'x, 0);
        uvm_report_cb::delete(null, unknown_catcher);

        base_reconfig.live_mq_resize(null, 1, 1, 0);

        if ((over_catcher.caught_count != 1) ||
            (zero_catcher.caught_count != 1) ||
            (unknown_catcher.caught_count != 1) ||
            (malicious_reconfig.public_resize_count != 0) ||
            (malicious_reconfig.do_resize_count != 1)) begin
            `uvm_error("DUT_CAPS", $sformatf(
                {"base-typed dynamic resize bypassed mandatory guard: ",
                 "reports=%0d/%0d/%0d public=%0d do=%0d"},
                over_catcher.caught_count, zero_catcher.caught_count,
                unknown_catcher.caught_count,
                malicious_reconfig.public_resize_count,
                malicious_reconfig.do_resize_count))
        end
    endtask

    task assert_function_bind_guard_cannot_be_overridden();
        virtio_function_instance base_function;
        virtio_pci_transport transport;
        virtqueue_manager vq_mgr;
        virtio_dut_caps_mq_ops_spy ops_spy;
        virtio_dut_caps_mq_fsm_probe fsm_probe;
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;
        virtio_driver_config_t driver_cfg;
        virtio_dut_caps_expected_mq_bind_fatal catcher;

        base_function = malicious_binding_function;
        transport = virtio_pci_transport::type_id::create(
            "malicious_binding_transport");
        vq_mgr = virtqueue_manager::type_id::create(
            "malicious_binding_vq_mgr");
        ops_spy = virtio_dut_caps_mq_ops_spy::type_id::create(
            "malicious_binding_ops");
        fsm_probe = virtio_dut_caps_mq_fsm_probe::type_id::create(
            "malicious_binding_fsm");
        ops = ops_spy;
        fsm = fsm_probe;
        driver_cfg.max_vio_net_qpairs_per_device = 33;
        catcher = new(
            "malicious_binding_catcher", base_function,
            {"malicious_function could not bind its MQ pair limit: ",
             "FSM MQ pair limit 33 exceeds model ceiling 32"});
        uvm_report_cb::add(null, catcher);
        base_function.bind_pcie_components(
            "malicious_function", transport, vq_mgr, null, null, null, null,
            null, null, driver_cfg, mq_pcie_seqr, ops, fsm);
        uvm_report_cb::delete(null, catcher);

        if ((catcher.caught_count != 1) ||
            (malicious_binding_function.public_bind_count != 0) ||
            (ops != ops_spy) || (fsm != fsm_probe) ||
            (ops_spy.transport != null) || (ops_spy.vq_mgr != null) ||
            (fsm_probe.ops != null) ||
            (fsm_probe.observed_max_supported_qpairs() != 32)) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                {"base-typed function bind bypassed mandatory MQ guard: ",
                 "reports=%0d public=%0d max=%0d"},
                catcher.caught_count,
                malicious_binding_function.public_bind_count,
                fsm_probe.observed_max_supported_qpairs()))
        end
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

    task assert_vio_binding_ownership();
        dpu_resource_manager secondary_manager;
        dpu_resource_fabric_authority secondary_authority;
        dpu_dut_caps secondary_caps;
        dpu_bar_pair_lease_t bars[$];
        dpu_function_key_t secondary_key;
        dpu_resource_class_id_t unused_class_id;
        dpu_resource_class_id_t secondary_qpair_class_id;
        virtio_resource_client owner_client;
        virtio_resource_client secondary_client;
        virtio_resource_client limit_identity_client;
        dpu_resource_manager original_manager_view;
        dpu_function_key_t original_key_view;
        dpu_resource_class_id_t original_class_view;
        int unsigned original_global_qid;
        int unsigned observed_global_qid;
        dpu_dut_caps observed_caps;
        string why;

        secondary_manager = dpu_resource_manager::type_id::create(
            "secondary_binding_manager");
        secondary_authority =
            secondary_manager.claim_fabric_registry_authority();
        if (secondary_authority == null)
            `uvm_fatal("DUT_CAPS",
                "secondary manager did not provide Fabric authority")
        secondary_caps = dpu_dut_caps::type_id::create(
            "secondary_binding_caps");
        if (!secondary_manager.fabric_configure_dut_caps(
            secondary_authority, secondary_caps, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager DUT caps failed: %s", why))
        end
        if (!secondary_manager.fabric_configure_mmio_aperture(
            secondary_authority,
            64'h0002_0000_0000_0000,
            64'h0002_0100_0000_0000,
            why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager MMIO aperture failed: %s", why))
        end
        if (!secondary_manager.fabric_register_resource_class(
            secondary_authority, "test.unused", DPU_RESOURCE_KIND_QUEUE,
            1, 1, unused_class_id, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager unused profile failed: %s", why))
        end
        if (!secondary_manager.fabric_register_resource_class(
            secondary_authority, "virtio.qpair", DPU_RESOURCE_KIND_QUEUE,
            1, 1, secondary_qpair_class_id, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager qpair profile failed: %s", why))
        end
        if (!secondary_manager.fabric_seal_resource_classes(
            secondary_authority, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager profile sealing failed: %s", why))
        end

        secondary_key = make_key(1, 1, DPU_FUNCTION_PF, 0);
        limit_identity_client = virtio_resource_client::type_id::create(
            "limit_identity_client");
        if (!limit_identity_client.bind_to_fabric(
            secondary_manager, secondary_key, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "limit identity client bind failed: %s", why))
        end
        secondary_caps.max_vio_net_qpairs_per_device = 31;
        if (!secondary_manager.fabric_configure_dut_caps(
            secondary_authority, secondary_caps, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager limit change failed: %s", why))
        end
        if (limit_identity_client.bind_to_fabric(
            secondary_manager, secondary_key, why
        )) begin
            `uvm_fatal("DUT_CAPS",
                "effective-limit rebind escaped binding ownership")
        end
        if (why !=
            "virtio resource client binding ownership cannot be reassigned") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "effective-limit rebind used wrong reason: %s", why))
        end
        observed_caps = limit_identity_client.snapshot_bound_dut_caps();
        if ((observed_caps == null) ||
            (observed_caps.max_vio_net_qpairs_per_device != 32)) begin
            `uvm_fatal("DUT_CAPS",
                "effective-limit rejection changed the bound snapshot")
        end
        secondary_caps.max_vio_net_qpairs_per_device = 32;
        if (!secondary_manager.fabric_configure_dut_caps(
            secondary_authority, secondary_caps, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager limit restore failed: %s", why))
        end
        if (!secondary_manager.register_function(secondary_key, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary Fabric PF registration failed: %s", why))
        if (!secondary_manager.activate_function(secondary_key, bars, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary Fabric PF activation failed: %s", why))
        if (!secondary_manager.mark_function_device_ready(secondary_key, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary Fabric PF readiness failed: %s", why))
        owner_client = virtio_resource_client::type_id::create(
            "binding_owner_client");
        if (!owner_client.bind_to_fabric(manager, valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "binding owner client bind failed: %s", why))
        original_manager_view = owner_client.resource_manager;
        original_key_view = owner_client.function_key;
        original_class_view = owner_client.qpair_class_id;
        if (!owner_client.mark_device_ready(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "binding owner client readiness failed: %s", why))
        if (!owner_client.reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "binding owner client reserve failed: %s", why))
        if (!owner_client.local_qid_to_global_qid(0, original_global_qid))
            `uvm_fatal("DUT_CAPS",
                "binding owner client did not publish its qpair mapping")
        if (!owner_client.freeze_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "binding owner client freeze failed: %s", why))

        if (owner_client.bind_to_fabric(
            secondary_manager, secondary_key, why
        )) begin
            `uvm_fatal("DUT_CAPS",
                {"valid cross-manager rebind escaped virtio client ",
                 "binding ownership"})
        end
        if (why !=
            "virtio resource client binding ownership cannot be reassigned") begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "cross-manager rebind rejection used wrong reason: %s", why))
        end
        if ((owner_client.resource_manager != manager) ||
            (owner_client.function_key.host_id != valid_vf.host_id) ||
            (owner_client.function_key.pf_id != valid_vf.pf_id) ||
            (owner_client.function_key.kind != valid_vf.kind) ||
            (owner_client.function_key.vf_id != valid_vf.vf_id)) begin
            `uvm_fatal("DUT_CAPS",
                "rejected cross-manager rebind replaced the old binding")
        end
        if ((owner_client.qpair_leases.size() != 1) ||
            (owner_client.qpair_mappings.size() != 1) ||
            !owner_client.local_qid_to_global_qid(0, observed_global_qid) ||
            (observed_global_qid != original_global_qid)) begin
            `uvm_fatal("DUT_CAPS",
                "rejected cross-manager rebind changed the old lease mapping")
        end
        if (owner_client.reserve_qpairs(1, 1, why))
            `uvm_fatal("DUT_CAPS",
                "rejected cross-manager rebind cleared the frozen state")
        if (why != "frozen virtio resource client cannot reserve QP leases")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "post-rebind frozen rejection used wrong reason: %s", why))
        if (secondary_manager.local_to_global(
            secondary_key, secondary_qpair_class_id, 0, observed_global_qid
        )) begin
            `uvm_fatal("DUT_CAPS",
                "rejected cross-manager rebind polluted the new manager")
        end

        if (!owner_client.bind_to_fabric(manager, valid_vf, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "same-target idempotent bind failed: %s", why))
        if ((owner_client.qpair_leases.size() != 1) ||
            (owner_client.qpair_mappings.size() != 1) ||
            !owner_client.local_qid_to_global_qid(0, observed_global_qid) ||
            (observed_global_qid != original_global_qid)) begin
            `uvm_fatal("DUT_CAPS",
                "same-target idempotent bind changed the old lease mapping")
        end
        if (owner_client.reserve_qpairs(1, 1, why))
            `uvm_fatal("DUT_CAPS",
                "same-target idempotent bind cleared the frozen state")
        if (why != "frozen virtio resource client cannot reserve QP leases")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "post-idempotent frozen rejection used wrong reason: %s", why))

        owner_client.resource_manager = secondary_manager;
        owner_client.function_key = secondary_key;
        owner_client.qpair_class_id = unused_class_id;
        if (owner_client.reserve_qpairs(1, 1, why))
            `uvm_fatal("DUT_CAPS",
                "public binding mirrors bypassed the private frozen state")
        if (why != "frozen virtio resource client cannot reserve QP leases")
            `uvm_fatal("DUT_CAPS", $sformatf(
                "mirror-tamper frozen rejection used wrong reason: %s", why))
        if (!owner_client.restore_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "private binding could not restore its frozen lease: %s", why))
        if (!owner_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "private binding could not release its restored lease: %s", why))
        owner_client.resource_manager = original_manager_view;
        owner_client.function_key = original_key_view;
        owner_client.qpair_class_id = original_class_view;
        if (manager.local_to_global(
            valid_vf, original_class_view, 0, observed_global_qid
        )) begin
            `uvm_fatal("DUT_CAPS",
                "public binding mirrors redirected old-manager cleanup")
        end
        if (secondary_manager.local_to_global(
            secondary_key, secondary_qpair_class_id, 0, observed_global_qid
        )) begin
            `uvm_fatal("DUT_CAPS",
                "public binding mirrors polluted new-manager cleanup")
        end
        if (!owner_client.reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "old manager capacity was not reusable after release: %s", why))
        if (!owner_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "old manager could not release its reused capacity: %s", why))

        secondary_client = virtio_resource_client::type_id::create(
            "secondary_binding_client");
        if (!secondary_client.bind_to_fabric(
            secondary_manager, secondary_key, why
        )) begin
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary client bind failed: %s", why))
        end
        if (!secondary_client.mark_device_ready(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary client readiness failed: %s", why))
        if (!secondary_client.reserve_qpairs(0, 1, why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager capacity was polluted: %s", why))
        if (!secondary_client.release_qpairs(why))
            `uvm_fatal("DUT_CAPS", $sformatf(
                "secondary manager capacity could not be released: %s", why))
    endtask

    virtual task run_phase(uvm_phase phase);
        string fatal_continuation_case;

        phase.raise_objection(this);
        if ($value$plusargs(
            "FATAL_CONTINUATION_CASE=%s", fatal_continuation_case
        )) begin
            if (fatal_continuation_case == "function")
                assert_function_bind_fatal_returns();
            else if (fatal_continuation_case == "env_apply")
                assert_env_apply_fatal_returns();
            else if (fatal_continuation_case == "env_get")
                assert_env_get_fatal_returns();
            else if (fatal_continuation_case == "env_pf")
                assert_env_pf_registration_fatal_returns();
            else if (fatal_continuation_case == "env_vf")
                assert_env_vf_registration_fatal_returns();
            else
                `uvm_fatal("DUT_CAPS", $sformatf(
                    "unknown fatal continuation case: %s",
                    fatal_continuation_case))
            phase.drop_objection(this);
            return;
        end
        assert_invalid_legacy_config_hard_fails();
        assert_env_capability_phase_snapshot();
        assert_function_bind_fatal_returns();
        assert_env_apply_fatal_returns();
        assert_env_get_fatal_returns();
        assert_env_pf_registration_fatal_returns();
        assert_env_vf_registration_fatal_returns();
        assert_real_dut_capability_defaults();
        assert_virtio_config_uses_dut_caps();
        assert_env_propagates_caps_to_fabric();
        assert_expected_error_catchers_match_client();
        assert_dynamic_resize_limit();
        assert_driver_mq_dispatch_uses_dut_cap();
        assert_mandatory_fsm_guards_cannot_be_overridden();
        assert_dynamic_resize_guard_cannot_be_overridden();
        assert_function_bind_guard_cannot_be_overridden();
        configure_fabric();
        assert_manager_topology_limits();
        assert_vio_local_qpair_limit();
        assert_vio_binding_ownership();
        phase.drop_objection(this);
    endtask
endclass : virtio_dut_caps_test

`endif // VIRTIO_DUT_CAPS_TEST_SV
