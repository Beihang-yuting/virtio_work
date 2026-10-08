`ifndef VIRTIO_UNIT_TEST_SV
`define VIRTIO_UNIT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// The completion-routing unit test calls handle_completion() directly and
// therefore does not connect a sequencer to the RC driver.  Suppress the
// inherited traffic-serving run phase while retaining the real completion
// implementation under test.
class virtio_tlm_rc_driver_test_shim extends virtio_tlm_rc_driver_shim;
    `uvm_component_utils(virtio_tlm_rc_driver_test_shim)

    function new(string name = "virtio_tlm_rc_driver_test_shim",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask

    // Set up the same private read-back state that the base send path creates
    // for a non-posted request, without needing a live sequencer or adapter.
    function void register_readback_for_test(pcie_tl_tlp req);
        req.rb_done = 0;
        req.rb_data = {};
        req.rb_status = CPL_STATUS_SC;
        rb_outstanding[req.tag] = req;
    endfunction
endclass : virtio_tlm_rc_driver_test_shim

class virtio_completion_ep_driver_test_shim extends pcie_tl_ep_driver;
    `uvm_component_utils(virtio_completion_ep_driver_test_shim)

    function new(string name = "virtio_completion_ep_driver_test_shim",
                 uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
    endtask
endclass : virtio_completion_ep_driver_test_shim

class virtio_tlm_adapter_owner_catcher extends uvm_report_catcher;
    bit caught;

    function new(string name = "virtio_tlm_adapter_owner_catcher");
        super.new(name);
        caught = 0;
    endfunction

    function action_e catch();
        if ((get_id() == "TLM_COMPLETION") && (get_severity() == UVM_FATAL)) begin
            caught = 1;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_tlm_adapter_owner_catcher

class virtio_wait_policy_timeout_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_wait_policy_timeout_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "WAIT_POLICY") &&
            uvm_is_match(
                "wait_event_or_timeout TIMEOUT after *ns at *: test_timeout",
                get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_wait_policy_timeout_catcher

class virtio_wait_policy_poll_timeout_probe_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_wait_policy_poll_timeout_probe_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "WAIT_POLICY") &&
            uvm_is_match("poll_until_flag TIMEOUT after *: test_timeout (timeout=*ns, attempts=*)",
                         get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_wait_policy_poll_timeout_probe_catcher

class virtio_expected_rc_completion_warning_catcher extends uvm_report_catcher;
    int unsigned caught_count;
    function new(string name = "virtio_expected_rc_completion_warning_catcher");
        super.new(name);
        caught_count = 0;
    endfunction
    virtual function action_e catch();
        if ((get_severity() == UVM_WARNING) &&
            (get_id() == "RC_DRV") &&
            uvm_is_match("Unexpected Completion:*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_expected_rc_completion_warning_catcher

class virtio_expected_iommu_map_error_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_expected_iommu_map_error_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_ERROR) && (get_id() == "IOMMU_MAP")) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_expected_iommu_map_error_catcher

// Absorbs exactly the transport fatal raised when a DMA host domain is
// requested from a transport that never received a frozen PCIe identity.
class virtio_unit_expected_identity_fatal_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "virtio_unit_expected_identity_fatal_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if ((get_severity() == UVM_FATAL) && (get_id() == "TRANSPORT") &&
            uvm_is_match("*has no frozen PCIe identity*", get_message())) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_unit_expected_identity_fatal_catcher

// 记录型发现策略：只统计调用与入参，验证 transport 把发现完全委托给策略对象。
class virtio_unit_recording_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_unit_recording_discovery)

    int unsigned discover_count;
    virtio_pci_transport last_transport;

    function new(string name = "virtio_unit_recording_discovery");
        super.new(name);
        discover_count = 0;
        last_transport = null;
    endfunction

    virtual function string strategy_name();
        return "unit_recording";
    endfunction

    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        discover_count++;
        last_transport = transport;
        why = "";
        ok = 1;
    endtask
endclass : virtio_unit_recording_discovery

// 记录型配置后端：验证 atomic ops 的全部设备配置副作用都经由注入的后端，
// 这是后续 AF 直配后端替换 common-config 的接入点。
class virtio_unit_recording_backend extends virtio_config_backend;
    `uvm_object_utils(virtio_unit_recording_backend)

    string calls[$];
    bit [7:0] status_reg;
    virtio_queue_program_t configured_program;
    virtio_queue_program_t disabled_program;
    virtio_net_device_config_t net_config;

    function new(string name = "virtio_unit_recording_backend");
        super.new(name);
        status_reg = 0;
        net_config = '{default: 0};
    endfunction

    virtual task reset(output bit ok);
        calls.push_back("reset");
        ok = 1;
    endtask
    virtual task read_status(output bit [7:0] status);
        calls.push_back("read_status");
        status = status_reg;
    endtask
    virtual task write_status(bit [7:0] status);
        calls.push_back("write_status");
        status_reg = status;
    endtask
    virtual task read_device_features(output bit [63:0] features);
        calls.push_back("read_device_features");
        features = 64'h3;
    endtask
    virtual task write_driver_features(bit [63:0] features);
        calls.push_back("write_driver_features");
    endtask
    virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
        calls.push_back("set_features");
        accepted = driver_caps & 64'h3;
    endtask
    virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);
        calls.push_back("query_queue_max");
        max_size = 8;
    endtask
    virtual task configure_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("configure_queue");
        configured_program = q;
        ok = 1;
    endtask
    virtual task enable_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("enable_queue");
        ok = 1;
    endtask
    virtual task disable_queue(virtio_queue_program_t q, output bit ok);
        calls.push_back("disable_queue");
        disabled_program = q;
        ok = 1;
    endtask
    virtual task reset_queue(int unsigned queue_id, output bit ok);
        calls.push_back("reset_queue");
        ok = 1;
    endtask
    virtual task set_msix(int unsigned queue_ids[$], output bit ok);
        calls.push_back("set_msix");
        ok = 1;
    endtask
    virtual task clear_msix(output bit ok);
        calls.push_back("clear_msix");
        ok = 1;
    endtask
    virtual task read_net_config(output virtio_net_device_config_t cfg);
        calls.push_back("read_net_config");
        cfg = net_config;
    endtask
endclass : virtio_unit_recording_backend

// 按 ID 与完整消息匹配一条预期 UVM_ERROR；其他报告照常抛出。
class virtio_unit_exact_error_catcher extends uvm_report_catcher;
    string expected_id;
    string expected_message;
    int unsigned caught_count;

    function new(string name, string configured_id, string configured_message);
        super.new(name);
        expected_id = configured_id;
        expected_message = configured_message;
        caught_count = 0;
    endfunction

    virtual function action_e catch();
        if (((get_severity() == UVM_ERROR) || (get_severity() == UVM_FATAL)) &&
            (get_id() == expected_id) && (get_message() == expected_message)) begin
            caught_count++;
            return CAUGHT;
        end
        return THROW;
    endfunction
endclass : virtio_unit_exact_error_catcher

// 生产 IOMMU 的映射通常不会失败；本替身只在指定的第 N 次 map 返回失败，并暴露
// live mapping 数。其余路径完全委托生产模型，用于验证真实 ring 分配/映射的回滚。
class virtio_unit_queue_recovery_iommu extends virtio_iommu_model;
    `uvm_object_utils(virtio_unit_queue_recovery_iommu)

    int unsigned map_attempts;
    int unsigned fail_on_map_attempt;

    // 构造故障注入 IOMMU；输入 name 仅用于 UVM 命名，计数器清零且默认不注入失败。
    function new(string name = "virtio_unit_queue_recovery_iommu");
        super.new(name);
        map_attempts = 0;
        fail_on_map_attempt = 0;
    endfunction

    // 为指定 Function 建立映射；命中 fail_on_map_attempt 时返回失败且不修改映射表，
    // 否则使用生产分配器。输入/返回值与基类一致。
    virtual function bit [63:0] map_for_host(
        int unsigned host_id,
        bit [15:0] bdf,
        bit [63:0] gpa,
        int unsigned size,
        dma_dir_e dir,
        string file = "",
        int line = 0
    );
        map_attempts++;
        if ((fail_on_map_attempt != 0) && (map_attempts == fail_on_map_attempt))
            return '1;
        return super.map_for_host(host_id, bdf, gpa, size, dir, file, line);
    endfunction

    // 返回当前仍有效的映射数，只供本测试断言 reset 成功释放或失败安全保留。
    function int unsigned active_mapping_count();
        return mapping_table.size();
    endfunction
endclass : virtio_unit_queue_recovery_iommu

// 暴露生产 host_mem_manager 的当前分配数，只用于把 ring 的 Host 所有权与 IOMMU
// 映射一起核对；分配/释放行为仍全部由基类实现。
class virtio_unit_queue_recovery_mem extends host_mem_manager;
    `uvm_object_utils(virtio_unit_queue_recovery_mem)

    // 构造跟踪型 Host memory；输入 name 仅用于 UVM 命名，实际区域由测试随后初始化。
    function new(string name = "virtio_unit_queue_recovery_mem");
        super.new(name);
    endfunction

    // 返回尚未释放的 Host allocation 数；不改变分配器状态。
    function int unsigned outstanding_allocations();
        return alloc_table.size();
    endfunction
endclass : virtio_unit_queue_recovery_mem

// 在 virtio_mock_transport 基础上统计 Q_SIZE 查询次数；其余行为完全复用 mock。
// 重复 qid 和 recovery 门禁测试据此确认失败请求连只读配置访问都不会发出。
class virtio_unit_counting_mock_transport extends virtio_mock_transport;
    `uvm_object_utils(virtio_unit_counting_mock_transport)

    int unsigned queue_max_read_count;

    // 构造只清零观察计数，不改变 mock transport 的默认设备状态。
    function new(string name = "virtio_unit_counting_mock_transport");
        super.new(name);
        queue_max_read_count = 0;
    endfunction

    // 记录一次 Q_SIZE 查询后委托基类返回可编程的 queue_num_max。
    virtual task read_queue_num_max(ref int unsigned max_size);
        queue_max_read_count++;
        super.read_queue_num_max(max_size);
    endtask
endclass : virtio_unit_counting_mock_transport

// 建队探针：setup_queue 只记录队列号并在 fail_qid 上失败，verified teardown 记录
// 队列号并确认停止；用于验证 setup_queue_range 的编号和窄范围回滚，不访问设备。
class virtio_unit_range_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_unit_range_ops)

    int unsigned fail_qid;
    int unsigned setup_qids[$];
    int unsigned teardown_qids[$];

    // 构造范围操作探针；默认不让任何 qid 失败，记录队列由测试拥有并清理。
    function new(string name = "virtio_unit_range_ops");
        super.new(name);
        fail_qid = '1;
    endfunction

    // 记录建队输入 queue_id，并在其等于 fail_qid 时返回 ok=0；其余输入不产生资源副作用。
    virtual task setup_queue(int unsigned queue_id, int unsigned queue_size,
                             virtqueue_type_e vq_type, output bit ok);
        setup_qids.push_back(queue_id);
        ok = (queue_id != fail_qid);
    endtask

    // 记录回滚 queue_id 并返回 stopped=1；不访问设备或释放资源。
    virtual task teardown_queue_verified(int unsigned queue_id, output bit stopped);
        teardown_qids.push_back(queue_id);
        stopped = 1;
    endtask
endclass : virtio_unit_range_ops

// 只暴露受保护的 cfg_backend()，验证未下发后端时 ops 不再自建。
class virtio_unit_backend_probe_ops extends virtio_atomic_ops;
    `uvm_object_utils(virtio_unit_backend_probe_ops)

    function new(string name = "virtio_unit_backend_probe_ops");
        super.new(name);
    endfunction

    function virtio_config_backend probe_backend();
        return cfg_backend();
    endfunction
endclass : virtio_unit_backend_probe_ops

// ============================================================================
// virtio_unit_test
//
// Standalone unit test that exercises core VIP components without needing
// PCIe infrastructure or the full environment. Tests:
//   - host_mem_manager: alloc/write/read/free
//   - virtio_iommu_model: map/translate/unmap
//   - split_virtqueue: alloc_rings/add_buf/free_rings
//   - virtio_wait_policy: timeout and event mechanisms
// ============================================================================

class virtio_unit_test extends uvm_test;
    `uvm_component_utils(virtio_unit_test)

    pcie_tl_scoreboard be_scb;
    virtio_completion_ep_driver_test_shim completion_ep_driver;
    virtio_tlm_rc_driver_shim completion_shim;
    virtio_driver_agent late_binding_agent;
    virtio_atomic_ops late_binding_ops;
    virtio_auto_fsm late_binding_fsm;
    virtio_driver_protocol late_binding_protocol;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        be_scb = pcie_tl_scoreboard::type_id::create("be_scb", this);
        completion_ep_driver = virtio_completion_ep_driver_test_shim::type_id::create(
            "completion_ep_driver", this);
        completion_shim = virtio_tlm_rc_driver_test_shim::type_id::create(
            "completion_shim", this);
        late_binding_ops = virtio_atomic_ops::type_id::create(
            "late_binding_ops");
        late_binding_fsm = virtio_auto_fsm::type_id::create(
            "late_binding_fsm");
        late_binding_protocol = dpu_priv_driver_protocol::type_id::create(
            "late_binding_protocol");
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "late_binding_agent", "is_active", UVM_ACTIVE);
        late_binding_agent = virtio_driver_agent::type_id::create(
            "late_binding_agent", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        late_binding_agent.ops = late_binding_ops;
        late_binding_agent.fsm = late_binding_fsm;
        late_binding_agent.protocol = late_binding_protocol;
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_host_mem();
        test_iommu();
        test_iommu_host_domains();
        test_iommu_random_aperture();
        test_iommu_translation_overflow();
        test_transport_requires_frozen_identity();
        test_split_virtqueue();
        test_wait_policy();
        test_pcie_scoreboard_byte_enables();
        test_ep_config_read_completion_metadata();
        test_tlm_completion_reject_filter();
        test_tlm_completion_matcher();
        test_tlm_completion_same_timestep_wakeup();
        test_tlm_config_write_completion_lifecycle();
        test_tlm_completion_factory_owner();
        test_late_driver_agent_binding();
        test_discovery_strategy_selection();
        test_injected_discovery_survives_fabric_config();
        test_config_backend_injection();
        test_config_reads_use_backend();
        test_ops_requires_selected_backend();
        test_common_backend_queue_reset_result();
        test_setup_queue_rejects_host_mismatch();
        test_driver_protocol_selection();
        test_driver_protocol_capabilities();
        test_private_capability_gates();
        test_setup_queue_maps_format_regions();
        test_standard_manual_kick_notifies();
        test_fabric_bar_layout_roles();
        test_setup_queue_range_rollback();
        test_setup_queue_range_verified_recovery();
        test_failed_reset_and_duplicate_queue_gates();
        test_dma_buffer_set();

        `uvm_info("UNIT_TEST", "All unit tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // A request that starts inside a valid mapping but wraps the 64-bit IOVA
    // end address must fail range checking instead of appearing smaller than
    // the mapped end after unsigned addition overflow.
    // A transport without a frozen PCIe identity has no DMA host domain; it
    // must not silently fall back to host0.
    task test_transport_requires_frozen_identity();
        virtio_pci_transport transport =
            virtio_pci_transport::type_id::create("identityless_transport");
        virtio_unit_expected_identity_fatal_catcher catcher;
        int unsigned host_id;

        catcher = new("identity_fatal_catcher");
        uvm_report_cb::add(null, catcher);
        host_id = transport.iommu_host_id();
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count != 1)
            `uvm_fatal("TEST", $sformatf(
                "identityless transport resolved DMA host %0d without a fatal",
                host_id))
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0042));
        if (transport.iommu_host_id() != 0)
            `uvm_fatal("TEST", "host0 identity did not resolve DMA host 0")
        `uvm_info("UNIT_TEST", "test_transport_requires_frozen_identity PASSED", UVM_LOW)
    endtask

    task test_iommu_translation_overflow();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "overflow_iommu");
        bit [63:0] fixed_iova;
        bit [63:0] gpa;
        iommu_fault_e fault;
        string why;
        bit ok;

        if (!iommu.configure_iova_aperture(
                64'hffff_ffff_ffff_d000,
                64'hffff_ffff_ffff_f000,
                IOMMU_IOVA_FIRST_FIT, why))
            `uvm_fatal("TEST", {"could not configure top IOVA aperture: ", why})
        fixed_iova = 64'hffff_ffff_ffff_e000;
        if (iommu.map_fixed_for_host(0, 16'h0124, 64'h0000_0000_7000_0000,
                                     4096, DMA_TO_DEVICE, fixed_iova) != fixed_iova)
            `uvm_fatal("TEST", "could not create top-of-address-space IOVA map")

        // Keep the request inside the mapped start address but make its end
        // wrap the 64-bit address space.  A range check that performs
        // unsigned ``iova + size`` without an overflow guard would otherwise
        // see the wrapped end (0x0000_0000_0000_dfff) and incorrectly accept
        // this translation.
        ok = iommu.translate_for_host(0, 16'h0124, fixed_iova, 32'hffff_ffff,
                                      DMA_TO_DEVICE, gpa, fault);
        if (ok || (fault != IOMMU_FAULT_OUT_OF_RANGE))
            `uvm_fatal("TEST", $sformatf(
                "wrapping IOVA translation was not rejected: ok=%0b fault=%s gpa=0x%016h",
                ok, fault.name(), gpa))
        iommu.unmap_for_host(0, 16'h0124, fixed_iova);
        `uvm_info("UNIT_TEST", "test_iommu_translation_overflow PASSED", UVM_LOW)
    endtask

    task test_late_driver_agent_binding();
        assert(late_binding_agent.driver.ops == late_binding_ops)
            else `uvm_error("TEST", "late-bound ops did not reach active driver")
        assert(late_binding_agent.driver.fsm == late_binding_fsm)
            else `uvm_error("TEST", "late-bound fsm did not reach active driver")
        assert(late_binding_agent.driver.protocol == late_binding_protocol)
            else `uvm_error("TEST", "late-bound protocol did not reach active driver")
        `uvm_info("UNIT_TEST", "test_late_driver_agent_binding PASSED", UVM_LOW)
    endtask

    // virtio_dma_buffer_set：alloc→write/fill→map→失败回滚、disown 与隔离转出
    // 的所有权约定。单页 IOVA aperture 让第二次映射必然失败。
    task test_dma_buffer_set();
        host_mem_manager mem = host_mem_manager::type_id::create("dma_set_mem");
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("dma_set_iommu");
        virtio_dma_buffer_set dma_set = new("dma_set");
        virtio_expected_iommu_map_error_catcher map_error;
        bit [63:0] q_iovas[$];
        bit [63:0] q_gpas[$];
        bit [63:0] kept_gpa;
        bit [63:0] kept_iova;
        byte wdata[];
        byte rdata[];
        int first_idx;
        int second_idx;
        string why;

        mem.init_region(64'h2000_0000, 64'h2000_FFFF);
        assert(iommu.configure_iova_aperture(64'h0000_0001_0000_0000,
                                             64'h0000_0001_0000_1000,
                                             IOMMU_IOVA_FIRST_FIT, why))
            else `uvm_fatal("TEST", why)
        dma_set.bind_domain(mem, iommu, 0, 16'h0100);

        // 1. alloc + write/fill：按索引写入各自 GPA
        first_idx = dma_set.alloc(64);
        second_idx = dma_set.alloc(32);
        assert(first_idx == 0 && second_idx == 1 && dma_set.count() == 2)
            else `uvm_fatal("TEST", "dma_set alloc did not register two buffers")
        wdata = new[4];
        foreach (wdata[i]) wdata[i] = 8'h10 + i;
        dma_set.write(first_idx, wdata);
        dma_set.fill(second_idx, 8'hFF);
        mem.read_mem(dma_set.get_gpa(first_idx), 4, rdata);
        assert(rdata[0] == 8'h10 && rdata[3] == 8'h13)
            else `uvm_fatal("TEST", "dma_set write landed at the wrong GPA")
        mem.read_mem(dma_set.get_gpa(second_idx), 32, rdata);
        assert($unsigned(rdata[31]) == 8'hFF)
            else `uvm_fatal("TEST", "dma_set fill did not cover the whole buffer")

        // 2. 第二次映射失败：release_all 解除已映射项并释放全部 GPA
        assert(dma_set.map(first_idx, DMA_TO_DEVICE) && dma_set.get_iova(first_idx) != 0)
            else `uvm_fatal("TEST", "dma_set first map failed")
        map_error = new("dma_set_map_error");
        uvm_report_cb::add(null, map_error);
        assert(!dma_set.map(second_idx, DMA_FROM_DEVICE))
            else `uvm_fatal("TEST", "dma_set map succeeded beyond the IOVA aperture")
        uvm_report_cb::delete(null, map_error);
        dma_set.release_all();
        assert(map_error.caught_count == 1 && dma_set.count() == 0 &&
               iommu.total_maps == 1 && iommu.total_unmaps == 1)
            else `uvm_fatal("TEST", "dma_set rollback left mappings or registrations")

        // 3. disown：所有权已转交，release_all 不得再触碰资源
        first_idx = dma_set.alloc(16);
        assert(first_idx == 0 && dma_set.map(first_idx, DMA_TO_DEVICE))
            else `uvm_fatal("TEST", "dma_set remap after rollback failed")
        kept_gpa = dma_set.get_gpa(first_idx);
        kept_iova = dma_set.get_iova(first_idx);
        dma_set.disown();
        dma_set.release_all();
        assert(dma_set.count() == 0 && iommu.total_unmaps == 1)
            else `uvm_fatal("TEST", "dma_set released resources it had disowned")
        iommu.unmap_for_host(0, 16'h0100, kept_iova);
        mem.free(kept_gpa);

        // 4. quarantine：已映射 IOVA 与全部 GPA 按添加顺序转出
        first_idx = dma_set.alloc(8);
        second_idx = dma_set.alloc(8);
        assert(dma_set.map(first_idx, DMA_TO_DEVICE))
            else `uvm_fatal("TEST", "dma_set quarantine setup map failed")
        kept_gpa = dma_set.get_gpa(first_idx);
        kept_iova = dma_set.get_iova(first_idx);
        dma_set.quarantine_into(q_iovas, q_gpas);
        assert(dma_set.count() == 0 && q_iovas.size() == 1 && q_gpas.size() == 2 &&
               q_iovas[0] == kept_iova && q_gpas[0] == kept_gpa)
            else `uvm_fatal("TEST", "dma_set quarantine did not transfer ownership in order")
        iommu.unmap_for_host(0, 16'h0100, q_iovas[0]);
        foreach (q_gpas[i]) mem.free(q_gpas[i]);

        mem.leak_check();
        iommu.leak_check();
        `uvm_info("UNIT_TEST", "test_dma_buffer_set PASSED", UVM_LOW)
    endtask

    // Test 1: host_mem alloc/write/read/free
    task test_host_mem();
        host_mem_manager mem = host_mem_manager::type_id::create("mem");
        bit [63:0] addr;
        byte wdata[];
        byte rdata[];

        mem.init_region(64'h1000_0000, 64'h1000_FFFF);

        addr = mem.alloc(256, .align(64));
        assert(addr != '1) else `uvm_fatal("TEST", "alloc failed")

        wdata = new[16];
        foreach (wdata[i]) wdata[i] = i;
        mem.write_mem(addr, wdata);

        mem.read_mem(addr, 16, rdata);
        foreach (rdata[i])
            assert(rdata[i] == i) else `uvm_error("TEST", $sformatf("data mismatch at %0d: got %0d expected %0d", i, rdata[i], i))

        mem.free(addr);

        `uvm_info("UNIT_TEST", "test_host_mem PASSED", UVM_LOW)
    endtask

    // Test 2: IOMMU map/translate/unmap
    task test_iommu();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("iommu");
        bit [63:0] iova, write_iova, gpa;
        iommu_fault_e fault;
        bit ok;

        // Map
        iova = iommu.map_for_host(0, 16'h0100, 64'hDEAD_0000, 4096, DMA_TO_DEVICE);
        assert(iova != 0) else `uvm_fatal("TEST", "map failed")

        // Translate
        ok = iommu.translate_for_host(0, 16'h0100, iova, 64, DMA_TO_DEVICE, gpa, fault);
        assert(ok) else `uvm_fatal("TEST", $sformatf("translate failed, fault=%s", fault.name()))
        assert(gpa == 64'hDEAD_0000) else `uvm_fatal("TEST", $sformatf("gpa mismatch: %h", gpa))

        // Permission violation on the public device-read translation path.
        // Device-to-guest writes are intentionally rejected before mapping
        // lookup and must use write_from_device().
        write_iova = iommu.map_for_host(0, 16'h0100, 64'hBEEF_0000, 4096,
                                        DMA_FROM_DEVICE);
        ok = iommu.translate_for_host(0, 16'h0100, write_iova, 64, DMA_TO_DEVICE,
                                      gpa, fault);
        assert(!ok && fault == IOMMU_FAULT_PERMISSION)
            else `uvm_error("TEST", "expected permission fault")

        // Unmap
        iommu.unmap_for_host(0, 16'h0100, iova);
        iommu.unmap_for_host(0, 16'h0100, write_iova);

        // Leak check
        iommu.leak_check();

        `uvm_info("UNIT_TEST", "test_iommu PASSED", UVM_LOW)
    endtask

    // A numeric BDF is only unique inside one host/IOMMU requester domain.
    // Two hosts must be able to expose the same BDF and IOVA without one
    // mapping shadowing or invalidating the other.
    task test_iommu_host_domains();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "host_domain_iommu");
        bit [63:0] host0_iova, host1_iova;
        bit [63:0] host0_gpa, host1_gpa;
        bit [63:0] host0_write_iova, host1_write_iova;
        bit [63:0] host0_write_gpa, host1_write_gpa;
        bit [63:0] fixed_iova;
        bit [63:0] dirty_pages0[$], dirty_pages1[$];
        byte host0_data[], host1_data[], readback[];
        virtio_dirty_page_snapshot_t dirty_records[$];
        iommu_fault_rule_t rule;
        host_mem_manager mem = host_mem_manager::type_id::create(
            "host_domain_mem");
        virtio_pci_transport transport =
            virtio_pci_transport::type_id::create("host1_transport");
        virtio_atomic_ops ops =
            virtio_atomic_ops::type_id::create("host1_ops");
        virtqueue_manager vq_mgr =
            virtqueue_manager::type_id::create("host1_vq_mgr");
        virtqueue_base host1_vq;
        dpu_pcie_function_id_t pcie_id;
        iommu_fault_e fault;
        bit ok;

        // This test checks host-domain independence using the historical
        // deterministic allocator.  Random placement is covered separately
        // by test_iommu_random_aperture(); keeping this test first-fit makes
        // the equal numeric IOVA assertion intentional and reproducible.
        iommu.set_iova_alloc_policy(IOMMU_IOVA_FIRST_FIT);

        host0_iova = iommu.map_for_host(0, 16'h0042, 64'h1000_0000,
                                        4096, DMA_TO_DEVICE);
        host1_iova = iommu.map_for_host(1, 16'h0042, 64'h2000_0000,
                                        4096, DMA_TO_DEVICE);
        assert(host0_iova != 0 && host1_iova != 0)
            else `uvm_fatal("TEST", "host-domain map failed");
        assert(host0_iova == host1_iova)
            else `uvm_fatal("TEST", "host domains should have independent IOVA spaces");

        ok = iommu.translate_for_host(0, 16'h0042, host0_iova, 64,
                                      DMA_TO_DEVICE, host0_gpa, fault);
        assert(ok && host0_gpa == 64'h1000_0000)
            else `uvm_fatal("TEST", "host0 translation mismatch");
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(ok && host1_gpa == 64'h2000_0000)
            else `uvm_fatal("TEST", "host1 translation mismatch");

        // Fault injection is scoped by the same host-qualified requester key.
        rule = '{host_id: 0, host_id_valid: 0, bdf_mask: '0,
                 iova_start: '0, iova_end: '0, dir: DMA_TO_DEVICE,
                 fault_type: IOMMU_NO_FAULT, trigger_count: 0,
                 triggered: 0};
        rule.host_id = 1;
        rule.host_id_valid = 1;
        rule.bdf_mask = 16'h0042;
        rule.iova_start = host1_iova;
        rule.iova_end = host1_iova + 4095;
        rule.dir = DMA_TO_DEVICE;
        rule.fault_type = IOMMU_FAULT_DEVICE_ABORT;
        rule.trigger_count = 1;
        iommu.add_fault_rule(rule);
        ok = iommu.translate_for_host(0, 16'h0042, host0_iova, 64,
                                      DMA_TO_DEVICE, host0_gpa, fault);
        assert(ok) else `uvm_fatal("TEST", "host1 fault rule affected host0");
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(!ok && fault == IOMMU_FAULT_DEVICE_ABORT)
            else `uvm_fatal("TEST", "host-scoped fault rule did not fire");
        iommu.clear_fault_rules();

        // Fixed IOVAs may also repeat across hosts.
        fixed_iova = 64'h9000_0000;
        assert(iommu.map_fixed_for_host(0, 16'h0043, 64'h3000_0000,
                   4096, DMA_TO_DEVICE, fixed_iova) == fixed_iova)
            else `uvm_fatal("TEST", "host0 fixed map failed");
        assert(iommu.map_fixed_for_host(1, 16'h0043, 64'h4000_0000,
                   4096, DMA_TO_DEVICE, fixed_iova) == fixed_iova)
            else `uvm_fatal("TEST", "host1 equal fixed map failed");
        iommu.unmap_for_host(0, 16'h0043, fixed_iova);
        iommu.unmap_for_host(1, 16'h0043, fixed_iova);

        // Exercise the production atomic-write boundary and host-scoped dirty
        // snapshots, not only the direct IOMMU translate API.
        mem.init_region(64'h5000_0000, 64'h5001_FFFF);
        host0_write_gpa = mem.alloc(4096, .align(4096));
        host1_write_gpa = mem.alloc(4096, .align(4096));
        host0_write_iova = iommu.map_for_host(0, 16'h0042, host0_write_gpa,
                                              4096, DMA_FROM_DEVICE);
        host1_write_iova = iommu.map_for_host(1, 16'h0042, host1_write_gpa,
                                              4096, DMA_FROM_DEVICE);
        assert(host0_write_iova == host1_write_iova)
            else `uvm_fatal("TEST", "write IOVA spaces are not host-local");
        void'(iommu.begin_dirty_generation_for_host(0));
        void'(iommu.begin_dirty_generation_for_host(1));
        host0_data = new[1];
        host0_data[0] = 8'hA0;
        assert(iommu.write_from_device_for_host(0, mem, 16'h0042,
                   host0_write_iova, host0_data, fault))
            else `uvm_fatal("TEST", "host0 device write failed");
        pcie_id = '{domain: '{host_id: 1, segment_id: 0}, bdf: 16'h0042};
        transport.configure_pcie_identity(pcie_id);
        vq_mgr.host_id = 1;
        vq_mgr.bdf = 16'h0042;
        host1_vq = vq_mgr.create_queue(7, 8, VQ_SPLIT);
        assert(host1_vq != null && host1_vq.host_id == 1 &&
               host1_vq.bdf == 16'h0042)
            else `uvm_fatal("TEST", "virtqueue manager lost host identity");
        ops.transport = transport;
        ops.iommu = iommu;
        ops.mem = mem;
        host1_data = new[1];
        host1_data[0] = 8'hB1;
        assert(ops.device_dma_write(host1_write_iova, host1_data, fault))
            else `uvm_fatal("TEST", "atomic ops did not use host1 domain");
        iommu.capture_dirty_generation_for_host(0, dirty_pages0);
        iommu.capture_dirty_generation_for_host(1, dirty_pages1);
        assert(dirty_pages0.size() == 1 && dirty_pages1.size() == 1)
            else `uvm_fatal("TEST", "dirty generations are not host-scoped");
        iommu.get_dirty_page_records_for_host(1, dirty_pages1[0],
                                              dirty_records);
        assert(dirty_records.size() == 1 &&
               dirty_records[0].mapping.host_id == 1 &&
               dirty_records[0].payload[0] == 8'hB1)
            else `uvm_fatal("TEST", "host1 dirty snapshot mismatch");
        mem.read_mem(host0_write_gpa, 1, readback);
        assert(readback[0] == 8'hA0)
            else `uvm_fatal("TEST", "host1 write mutated host0 backing");
        iommu.unmap_for_host(0, 16'h0042, host0_write_iova);
        iommu.unmap_for_host(1, 16'h0042, host1_write_iova);
        mem.free(host0_write_gpa);
        mem.free(host1_write_gpa);

        iommu.unmap_for_host(0, 16'h0042, host0_iova);
        ok = iommu.translate_for_host(1, 16'h0042, host1_iova, 64,
                                      DMA_TO_DEVICE, host1_gpa, fault);
        assert(ok && host1_gpa == 64'h2000_0000)
            else `uvm_fatal("TEST", "host0 unmap affected host1 mapping");
        iommu.unmap_for_host(1, 16'h0042, host1_iova);

        `uvm_info("UNIT_TEST", "test_iommu_host_domains PASSED", UVM_LOW)
    endtask

    // Random IOVA placement is constrained by a configurable page-aligned
    // aperture and must never overlap live mappings for one requester.
    task test_iommu_random_aperture();
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create(
            "random_iommu");
        bit [63:0] iovas[$];
        bit [63:0] iova;
        bit [63:0] gpa;
        iommu_fault_e fault;
        string why;
        bit ok;
        virtio_expected_iommu_map_error_catcher invalid_map_catcher;
        bit saw_non_linear_random_slot;

        saw_non_linear_random_slot = 0;

        if (!iommu.configure_iova_aperture(
                64'h0000_0000_4000_0000,
                64'h0000_0000_4002_0000,
                IOMMU_IOVA_RANDOM, why))
            `uvm_fatal("TEST", {"could not configure IOVA aperture: ", why})
        for (int index = 0; index < 12; index++) begin
            iova = iommu.map_for_host(0, 16'h0123, 64'h6000_0000 + index * 4096,
                                      4096, DMA_TO_DEVICE);
            if ((iova == 0) || (iova == '1) ||
                (iova < 64'h0000_0000_4000_0000) ||
                (iova + 4096 > 64'h0000_0000_4002_0000))
                `uvm_fatal("TEST", "random IOVA escaped configured aperture")
            foreach (iovas[previous]) begin
                if (iova == iovas[previous])
                    `uvm_fatal("TEST", "random IOVA allocation collided")
            end
            if ((index != 0) && (iova != iovas[0] + index * 4096))
                saw_non_linear_random_slot = 1;
            iovas.push_back(iova);
            ok = iommu.translate_for_host(0, 16'h0123, iova, 4096,
                                          DMA_TO_DEVICE, gpa, fault);
            if (!ok || (gpa != 64'h6000_0000 + index * 4096))
                `uvm_fatal("TEST", "random IOVA translation mismatch")
        end
        invalid_map_catcher = new("invalid_map_catcher");
        uvm_report_cb::add(null, invalid_map_catcher);
        if (iommu.map_fixed_for_host(0, 16'h0123, 64'h7000_0000, 4096,
                                     DMA_TO_DEVICE, 64'h4000_0000) != '1)
            `uvm_fatal("TEST", "fixed IOVA outside aperture was accepted")
        uvm_report_cb::delete(null, invalid_map_catcher);
        if (invalid_map_catcher.caught_count != 1)
            `uvm_fatal("TEST", "invalid fixed IOVA was not rejected")
        if (!saw_non_linear_random_slot)
            `uvm_fatal("TEST", "random IOVA policy produced only linear slots")
        foreach (iovas[index])
            iommu.unmap_for_host(0, 16'h0123, iovas[index]);
        `uvm_info("UNIT_TEST", "test_iommu_random_aperture PASSED", UVM_LOW)
    endtask

    // Test 3: Split virtqueue alloc/add_buf/free
    task test_split_virtqueue();
        host_mem_manager mem = host_mem_manager::type_id::create("sq_mem");
        virtio_iommu_model iommu = virtio_iommu_model::type_id::create("sq_iommu");
        virtio_vq_test_kit kit;
        split_virtqueue vq;

        mem.init_region(64'h2000_0000, 64'h2000_FFFF);
        iommu.strict_permission_check = 0;  // relax for unit test

        kit = virtio_vq_test_kit::create_kit("sq", mem, iommu, 16'h0100);
        vq = kit.make_split("vq", 0, 16, 16'h0100);

        assert(vq.get_free_count() == 16)
            else `uvm_error("TEST", $sformatf("expected 16 free, got %0d", vq.get_free_count()))

        // Add a buffer
        begin
            virtio_sg_list sgs[];
            virtio_sg_entry e;
            virtio_sg_list sg;
            bit [63:0] buf_addr;
            int unsigned desc_id;
            byte test_data[];

            // Allocate a data buffer
            test_data = new[64];
            foreach (test_data[i]) test_data[i] = i + 8'hA0;
            buf_addr = mem.alloc(64, .align(64));
            mem.write_mem(buf_addr, test_data);

            e.addr = buf_addr;
            e.len = 64;
            sg.entries.push_back(e);
            sgs = new[1];
            sgs[0] = sg;

            desc_id = vq.add_buf(sgs, 1, 0, null, 0);
            assert(desc_id != '1) else `uvm_fatal("TEST", "add_buf failed")
            assert(vq.get_free_count() == 15)
                else `uvm_error("TEST", $sformatf("expected 15 free, got %0d", vq.get_free_count()))
        end

        vq.dump_ring();
        vq.free_rings();

        `uvm_info("UNIT_TEST", "test_split_virtqueue PASSED", UVM_LOW)
    endtask

    // Test 4: Wait policy
    task test_wait_policy();
        virtio_wait_policy wp = virtio_wait_policy::type_id::create("wp");
        uvm_event evt = new("test_evt");
        bit triggered;
        bit poll_success;
        bit poll_timed_out;
        int error_count_before;
        int error_count_after;
        virtio_wait_policy_timeout_catcher timeout_catcher;
        virtio_wait_policy_poll_timeout_probe_catcher poll_timeout_probe_catcher;

        // The generic catcher is deliberately registered before the narrow
        // poll probe.  UVM processes report catchers in registration order,
        // so a broad generic match would incorrectly prevent the probe from
        // seeing its own poll_until_flag timeout.
        error_count_before = uvm_report_server::get_server().get_severity_count(UVM_ERROR);
        timeout_catcher = new();
        poll_timeout_probe_catcher = new();
        uvm_report_cb::add(null, timeout_catcher);
        uvm_report_cb::add(null, poll_timeout_probe_catcher);

        // Test wait_event_or_timeout timeout (should timeout quickly).
        wp.wait_event_or_timeout("test_timeout", evt, 100, triggered);

        // Probe a similarly named poll_until_flag timeout.  Its dedicated
        // catcher must receive this report rather than the primary catcher.
        poll_success = 0;
        wp.poll_until_flag("test_timeout", 100, 10, poll_success, poll_timed_out);

        uvm_report_cb::delete(null, poll_timeout_probe_catcher);
        uvm_report_cb::delete(null, timeout_catcher);

        assert(!triggered) else `uvm_error("TEST", "should have timed out")
        assert(poll_timed_out) else
            `uvm_error("TEST", "poll_until_flag probe should have timed out")
        error_count_after = uvm_report_server::get_server().get_severity_count(UVM_ERROR);
        assert(error_count_after == error_count_before) else
            `uvm_error("TEST", $sformatf("expected caught timeouts to leave UVM_ERROR count at %0d, got %0d",
                                         error_count_before, error_count_after))
        assert((timeout_catcher.caught_count == 1) &&
               (poll_timeout_probe_catcher.caught_count == 1)) else
            `uvm_error("TEST", $sformatf(
                "primary catcher must catch only wait_event_or_timeout (primary=%0d, poll_probe=%0d)",
                timeout_catcher.caught_count, poll_timeout_probe_catcher.caught_count))

        // Reset event for next test
        evt.reset();

        // Test event trigger
        fork : trigger_blk
            begin
                #50ns;
                evt.trigger();
            end
        join_none
        wp.wait_event_or_timeout("test_event", evt, 1000, triggered);
        disable trigger_blk;
        assert(triggered) else `uvm_error("TEST", "event should have triggered")

        `uvm_info("UNIT_TEST", "test_wait_policy PASSED", UVM_LOW)
    endtask

    // A partial multi-DWord Memory Write must constrain only bytes selected by
    // first_be and last_be.  The completion deliberately differs in the two
    // disabled final-DWord lanes; all six enabled bytes must still compare.
    task test_pcie_scoreboard_byte_enables();
        pcie_tl_scoreboard scb;
        pcie_tl_mem_tlp write_tlp;
        pcie_tl_mem_tlp read_tlp;
        pcie_tl_cpl_tlp cpl;

        scb = be_scb;
        scb.ordering_check_enable = 0;

        write_tlp = pcie_tl_mem_tlp::type_id::create("partial_write");
        write_tlp.kind = TLP_MEM_WR;
        write_tlp.fmt = FMT_3DW_WITH_DATA;
        write_tlp.type_f = TLP_TYPE_MEM_WR;
        write_tlp.requester_id = 16'h0100;
        write_tlp.addr = 64'h0000_0000_C000_001C;
        write_tlp.length = 10'h2;
        write_tlp.first_be = 4'hF;
        write_tlp.last_be = 4'h3;
        write_tlp.payload = new[8];
        write_tlp.payload[0] = 8'h10;
        write_tlp.payload[1] = 8'h11;
        write_tlp.payload[2] = 8'h12;
        write_tlp.payload[3] = 8'h13;
        write_tlp.payload[4] = 8'h20;
        write_tlp.payload[5] = 8'h21;
        write_tlp.payload[6] = 8'h22;  // last_be masks this lane
        write_tlp.payload[7] = 8'h23;  // last_be masks this lane
        scb.write_ep(write_tlp);

        read_tlp = pcie_tl_mem_tlp::type_id::create("notify_read");
        read_tlp.kind = TLP_MEM_RD;
        read_tlp.fmt = FMT_3DW_NO_DATA;
        read_tlp.type_f = TLP_TYPE_MEM_RD;
        read_tlp.requester_id = 16'h0100;
        read_tlp.tag = 10'h023;
        read_tlp.addr = 64'h0000_0000_C000_001C;
        read_tlp.length = 10'h2;
        read_tlp.first_be = 4'hF;
        read_tlp.last_be = 4'hF;
        scb.register_pending(read_tlp);

        cpl = pcie_tl_cpl_tlp::type_id::create("notify_completion");
        cpl.kind = TLP_CPLD;
        cpl.fmt = FMT_3DW_WITH_DATA;
        cpl.type_f = TLP_TYPE_CPL;
        cpl.requester_id = read_tlp.requester_id;
        cpl.completer_id = 16'h0000;
        cpl.tag = read_tlp.tag;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.byte_count = 12'd8;
        cpl.lower_addr = read_tlp.addr[6:0];
        cpl.payload = new[8];
        cpl.payload[0] = 8'h10;
        cpl.payload[1] = 8'h11;
        cpl.payload[2] = 8'h12;
        cpl.payload[3] = 8'h13;
        cpl.payload[4] = 8'h20;
        cpl.payload[5] = 8'h21;
        cpl.payload[6] = 8'hDE;  // differs only in last_be-masked lane
        cpl.payload[7] = 8'hAD;  // differs only in last_be-masked lane
        scb.write_rc(cpl);

        assert(scb.mismatched == 0)
            else `uvm_error("TEST", $sformatf(
                "scoreboard treated last_be-masked bytes as written (%0d mismatches)",
                scb.mismatched))
        assert(scb.matched == 1)
            else `uvm_error("TEST", $sformatf(
                "scoreboard did not complete the partial-last-DWord request (%0d matches)",
                scb.matched))

        `uvm_info("UNIT_TEST", "test_pcie_scoreboard_byte_enables PASSED", UVM_LOW)
    endtask

    task test_ep_config_read_completion_metadata();
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;

        req = pcie_tl_cfg_tlp::type_id::create("config_read_req");
        req.kind = TLP_CFG_RD0;
        req.fmt = FMT_3DW_NO_DATA;
        req.type_f = TLP_TYPE_CFG_RD0;
        req.length = 10'd1;
        req.requester_id = 16'h0100;
        req.tag = 10'h055;
        req.first_be = 4'hF;

        cpl = completion_ep_driver.generate_completion(req, CPL_STATUS_SC);

        assert(cpl.byte_count == 12'd4)
            else `uvm_error("TEST", $sformatf(
                "config-read completion byte_count expected 4 got %0d",
                cpl.byte_count))

        `uvm_info("UNIT_TEST", "test_ep_config_read_completion_metadata PASSED", UVM_LOW)
    endtask

    // The TLM shim must preserve the RC driver's authoritative completion
    // decision: a completion whose requester ID does not match its outstanding
    // request must never be made visible to a BAR sequence waiter.
    task test_tlm_completion_reject_filter();
        virtio_tlm_completion_adapter adapter;
        virtio_tlm_rc_driver_shim shim;
        virtio_expected_rc_completion_warning_catcher catcher;
        pcie_tl_mem_tlp req;
        pcie_tl_cpl_tlp rejected_cpl;
        pcie_tl_cpl_tlp matched_cpl;
        pcie_tl_cpl_tlp observed_cpl;
        bit accepted;
        bit ok;

        adapter = virtio_tlm_completion_adapter::type_id::create(
            "reject_filter_adapter");
        shim = completion_shim;
        shim.adapter = adapter;
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create(
            "reject_filter_tag_mgr");

        req = pcie_tl_mem_tlp::type_id::create("reject_filter_req");
        req.kind = TLP_MEM_RD;
        req.requester_id = 16'h0100;
        req.tag = 10'h021;
        req.length = 10'h1;
        shim.tag_mgr.register_outstanding(req.tag, req);

        rejected_cpl = pcie_tl_cpl_tlp::type_id::create(
            "reject_filter_bad_cpl");
        rejected_cpl.kind = TLP_CPLD;
        rejected_cpl.requester_id = 16'h0101;
        rejected_cpl.tag = req.tag;
        rejected_cpl.cpl_status = CPL_STATUS_SC;
        rejected_cpl.payload = new[4];

        catcher = new();
        uvm_report_cb::add(null, catcher);
        accepted = shim.handle_completion(rejected_cpl);
        uvm_report_cb::delete(null, catcher);
        assert(catcher.caught_count == 1)
            else `uvm_error("TEST", "expected exactly one rejected completion warning")
        assert(!accepted)
            else `uvm_error("TEST", "RC shim accepted a mismatched completion")
        assert(adapter.completions_received == 0)
            else `uvm_error("TEST", "RC-rejected completion was queued for BAR waiters")

        matched_cpl = pcie_tl_cpl_tlp::type_id::create(
            "reject_filter_good_cpl");
        matched_cpl.kind = TLP_CPLD;
        matched_cpl.requester_id = req.requester_id;
        matched_cpl.tag = req.tag;
        matched_cpl.cpl_status = CPL_STATUS_SC;
        matched_cpl.payload = new[4];
        matched_cpl.payload[0] = 8'hA5;

        accepted = shim.handle_completion(matched_cpl);
        assert(accepted)
            else `uvm_error("TEST", "RC shim rejected a matching completion")
        assert(adapter.completions_received == 1)
            else `uvm_error("TEST", "matching completion was not queued")

        adapter.wait_matching_completion(
            100, req.tag, req.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == matched_cpl)
            else `uvm_error("TEST", "matching completion was not returned to waiter")

        `uvm_info("UNIT_TEST", "test_tlm_completion_reject_filter PASSED", UVM_LOW)
    endtask

    // Two reads may be outstanding at once.  When B completes before A, the
    // A waiter must retain B and receive only its own {tag, requester_id}
    // completion; B must remain available for its true waiter afterwards.
    task test_tlm_completion_matcher();
        virtio_tlm_completion_adapter adapter;
        virtio_tlm_rc_driver_shim shim;
        pcie_tl_mem_tlp req_a;
        pcie_tl_mem_tlp req_b;
        pcie_tl_cpl_tlp cpl_a;
        pcie_tl_cpl_tlp cpl_b;
        pcie_tl_cpl_tlp observed_cpl;
        bit accepted;
        bit ok;

        adapter = virtio_tlm_completion_adapter::type_id::create(
            "matcher_adapter");
        shim = completion_shim;
        shim.adapter = adapter;
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create("matcher_tag_mgr");

        req_a = pcie_tl_mem_tlp::type_id::create("matcher_req_a");
        req_a.kind = TLP_MEM_RD;
        req_a.requester_id = 16'h0100;
        req_a.tag = 10'h022;
        req_a.length = 10'h1;
        shim.tag_mgr.register_outstanding(req_a.tag, req_a);

        req_b = pcie_tl_mem_tlp::type_id::create("matcher_req_b");
        req_b.kind = TLP_MEM_RD;
        req_b.requester_id = 16'h0108;
        req_b.tag = 10'h023;
        req_b.length = 10'h1;
        shim.tag_mgr.register_outstanding(req_b.tag, req_b);

        cpl_b = pcie_tl_cpl_tlp::type_id::create("matcher_cpl_b");
        cpl_b.kind = TLP_CPLD;
        cpl_b.requester_id = req_b.requester_id;
        cpl_b.tag = req_b.tag;
        cpl_b.cpl_status = CPL_STATUS_SC;
        cpl_b.payload = new[4];
        cpl_b.payload[0] = 8'hB0;

        cpl_a = pcie_tl_cpl_tlp::type_id::create("matcher_cpl_a");
        cpl_a.kind = TLP_CPLD;
        cpl_a.requester_id = req_a.requester_id;
        cpl_a.tag = req_a.tag;
        cpl_a.cpl_status = CPL_STATUS_SC;
        cpl_a.payload = new[4];
        cpl_a.payload[0] = 8'hA0;

        accepted = shim.handle_completion(cpl_b);
        assert(accepted) else `uvm_error("TEST", "completion B was rejected")
        accepted = shim.handle_completion(cpl_a);
        assert(accepted) else `uvm_error("TEST", "completion A was rejected")
        assert(adapter.completions_received == 2)
            else `uvm_error("TEST", "both accepted completions were not retained")

        adapter.wait_matching_completion(
            100, req_a.tag, req_a.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == cpl_a)
            else `uvm_error("TEST", "A waiter consumed B's out-of-order completion")

        adapter.wait_matching_completion(
            100, req_b.tag, req_b.requester_id, observed_cpl, ok);
        assert(ok && observed_cpl == cpl_b)
            else `uvm_error("TEST", "B completion was not retained for B waiter")
        assert(adapter.completions_consumed == 2)
            else `uvm_error("TEST", "both matching completions were not consumed")

        `uvm_info("UNIT_TEST", "test_tlm_completion_matcher PASSED", UVM_LOW)
    endtask

    // completion 在等待者开始等待的同一时刻入队（等待者已扫描暂存队列、尚未进入等待）：
    // 等待者必须在同一时刻认领返回，不能睡到超时。
    task test_tlm_completion_same_timestep_wakeup();
        virtio_tlm_completion_adapter adapter;
        pcie_tl_cpl_tlp cpl;
        pcie_tl_cpl_tlp observed_cpl;
        time start;
        bit ok;

        adapter = virtio_tlm_completion_adapter::type_id::create("same_ts_adapter");
        cpl = pcie_tl_cpl_tlp::type_id::create("same_ts_cpl");
        cpl.kind = TLP_CPLD;
        cpl.requester_id = 16'h0100;
        cpl.tag = 10'h031;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.payload = new[4];
        start = $time;
        ok = 0;
        fork
            adapter.wait_matching_completion(50000, cpl.tag, cpl.requester_id, observed_cpl, ok);
            adapter.put_completion(cpl);
        join
        assert(ok && (observed_cpl == cpl) && ($time == start))
            else `uvm_error("TEST", $sformatf(
                "same-timestep completion was not claimed immediately (ok=%0b waited=%0t)",
                ok, $time - start))
        `uvm_info("UNIT_TEST", "test_tlm_completion_same_timestep_wakeup PASSED", UVM_LOW)
    endtask

    // Configuration writes are non-posted requests, but their successful
    // PCIe completion is a data-less TLP_CPL.  It must therefore retire the
    // RC driver's pending/tag/read-back state rather than wait for length*4
    // bytes that will never arrive.
    task test_tlm_config_write_completion_lifecycle();
        virtio_tlm_rc_driver_test_shim shim;
        pcie_tl_cfg_tlp req;
        pcie_tl_cpl_tlp cpl;
        bit accepted;

        $cast(shim, completion_shim);
        assert(shim != null)
            else `uvm_fatal("TEST", "completion shim does not expose test setup")
        shim.tag_mgr = pcie_tl_tag_manager::type_id::create("cfg_wr_tag_mgr");

        req = pcie_tl_cfg_tlp::type_id::create("cfg_wr_req");
        req.kind = TLP_CFG_WR0;
        req.requester_id = 16'h0100;
        req.tag = 10'h024;
        req.length = 10'h1;
        shim.tag_mgr.register_outstanding(req.tag, req);
        shim.pending_cpl[req.tag] = req;
        shim.register_readback_for_test(req);

        cpl = pcie_tl_cpl_tlp::type_id::create("cfg_wr_cpl");
        cpl.kind = TLP_CPL;
        cpl.fmt = FMT_3DW_NO_DATA;
        cpl.length = 0;
        cpl.requester_id = req.requester_id;
        cpl.tag = req.tag;
        cpl.cpl_status = CPL_STATUS_SC;
        cpl.payload = new[0];

        accepted = shim.handle_completion(cpl);
        assert(accepted)
            else `uvm_error("TEST", "RC shim rejected a matching config-write completion")
        assert(shim.get_pending_count() == 0)
            else `uvm_error("TEST", "data-less config-write completion left the request pending")
        assert(!shim.tag_mgr.is_duplicate(req.tag))
            else `uvm_error("TEST", "data-less config-write completion did not free its tag")
        assert(req.rb_done)
            else `uvm_error("TEST", "data-less config-write completion did not finish read-back")

        `uvm_info("UNIT_TEST", "test_tlm_config_write_completion_lifecycle PASSED", UVM_LOW)
    endtask

    // Factory overrides use static sequence hooks.  A second live adapter
    // must fail instead of silently redirecting all completion waiters to it.
    task test_tlm_completion_factory_owner();
        virtio_tlm_completion_adapter owner_a;
        virtio_tlm_completion_adapter owner_b;
        virtio_tlm_adapter_owner_catcher catcher;

        owner_a = virtio_tlm_completion_adapter::type_id::create("owner_a");
        owner_b = virtio_tlm_completion_adapter::type_id::create("owner_b");
        owner_a.install_factory_overrides();

        catcher = new("adapter_owner_catcher");
        uvm_report_cb::add(null, catcher);
        owner_b.install_factory_overrides();
        uvm_report_cb::delete(null, catcher);

        assert(catcher.caught)
            else `uvm_error("TEST", "second adapter replaced factory owner without fatal")
        assert(virtio_tlm_bar_mem_rd_seq::adapter == owner_a)
            else `uvm_error("TEST", "memory-read factory adapter was replaced")
        assert(virtio_tlm_bar_cfg_rd_seq::adapter == owner_a)
            else `uvm_error("TEST", "config-read factory adapter was replaced")
        assert(virtio_tlm_bar_cfg_wr_seq::adapter == owner_a)
            else `uvm_error("TEST", "config-write factory adapter was replaced")

        `uvm_info("UNIT_TEST", "test_tlm_completion_factory_owner PASSED", UVM_LOW)
    endtask

    // transport 的发现路径只由策略对象决定：缺省即 fabric_preconfigured（非 Fabric
    // 托管的 transport 发现时由该策略 fatal），外部可注入新策略（verify_snapshot）。
    task test_discovery_strategy_selection();
        virtio_pci_transport transport;
        virtio_unit_recording_discovery recorder;
        virtio_resource_client client;

        transport = virtio_pci_transport::type_id::create("discovery_transport");
        if (transport.discovery_strategy_name() != "fabric_preconfigured")
            `uvm_error("TEST", {"default discovery strategy is ",
                                transport.discovery_strategy_name()})
        client = virtio_resource_client::type_id::create("discovery_client");
        transport.configure_fabric_managed(client);
        if (transport.discovery_strategy_name() != "fabric_preconfigured")
            `uvm_error("TEST", {"Fabric-managed transport selected ",
                                transport.discovery_strategy_name()})
        recorder = virtio_unit_recording_discovery::type_id::create(
            "discovery_recorder");
        transport.set_discovery_strategy(recorder);
        transport.discover_and_init_bars();
        if ((recorder.discover_count != 1) || (recorder.last_transport != transport))
            `uvm_error("TEST", $sformatf(
                "discover_and_init_bars did not delegate exactly once (count=%0d)",
                recorder.discover_count))
        `uvm_info("UNIT_TEST", "test_discovery_strategy_selection PASSED", UVM_LOW)
    endtask

    // 先注入策略（后续 verify_snapshot 的接入方式）、再走 function 提交路径的
    // configure_fabric_managed()，发现仍必须委托给注入的策略而不是被覆盖回 fabric。
    task test_injected_discovery_survives_fabric_config();
        virtio_pci_transport transport;
        virtio_unit_recording_discovery recorder;
        virtio_resource_client client;

        transport = virtio_pci_transport::type_id::create("injected_discovery_transport");
        recorder = virtio_unit_recording_discovery::type_id::create(
            "injected_discovery_recorder");
        transport.set_discovery_strategy(recorder);
        client = virtio_resource_client::type_id::create("injected_discovery_client");
        transport.configure_fabric_managed(client);
        if (transport.discovery_strategy_name() != "unit_recording")
            `uvm_error("TEST", {"configure_fabric_managed replaced injected strategy with ",
                                transport.discovery_strategy_name()})
        transport.discover_and_init_bars();
        if ((recorder.discover_count != 1) || (recorder.last_transport != transport))
            `uvm_error("TEST", $sformatf(
                "injected strategy not used after configure_fabric_managed (count=%0d)",
                recorder.discover_count))
        `uvm_info("UNIT_TEST", "test_injected_discovery_survives_fabric_config PASSED", UVM_LOW)
    endtask

    // atomic ops 的 status/feature/queue/MSI-X/复位副作用全部经注入后端，且队列
    // 编程参数（host/BDF/IOVA/大小/环类型）完整交给后端并在拆除时原样交回。
    task test_config_backend_injection();
        virtio_atomic_ops ops;
        virtio_unit_recording_backend backend;
        virtio_pci_transport transport;
        virtqueue_manager vq_mgr;
        virtio_iommu_model iommu;
        host_mem_manager mem;
        bit [63:0] result;
        bit [63:0] negotiated;
        bit ok;
        string expected[$];

        ops = virtio_atomic_ops::type_id::create("backend_ops");
        backend = virtio_unit_recording_backend::type_id::create("recording_backend");
        transport = virtio_pci_transport::type_id::create("backend_transport");
        vq_mgr = virtqueue_manager::type_id::create("backend_vq_mgr");
        iommu = virtio_iommu_model::type_id::create("backend_iommu");
        mem = host_mem_manager::type_id::create("backend_mem");
        mem.init_region(64'h7600_0000, 64'h7600_FFFF);
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0131));
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.config_backend = backend;

        ops.set_acknowledge();
        ops.negotiate_features(64'h5, result);
        // device_reset_verified 会清零 negotiated_features，先保存协商结果。
        negotiated = ops.negotiated_features;
        ops.setup_queue(0, 4, VQ_SPLIT, ok);
        if (!ok)
            `uvm_error("TEST", "setup_queue failed with recording backend")
        ops.teardown_queue(0);
        ops.reset_queue(0);
        ops.setup_msix(1);
        ops.device_reset_verified(ok);

        expected = '{"write_status", "set_features", "query_queue_max",
                     "configure_queue", "enable_queue", "disable_queue",
                     "reset_queue", "set_msix", "reset"};
        if (backend.calls != expected)
            `uvm_error("TEST", $sformatf("unexpected backend call sequence %p", backend.calls))
        if ((result != 64'h1) || (negotiated != 64'h1) ||
            (backend.status_reg != DEV_STATUS_ACKNOWLEDGE) || !ok ||
            (backend.bound_transport() != transport))
            `uvm_error("TEST", "backend results were not propagated to ops")
        if ((backend.configured_program.queue_id != 0) ||
            (backend.configured_program.queue_size != 4) ||
            (backend.configured_program.vq_type != VQ_SPLIT) ||
            (backend.configured_program.bdf != 16'h0131) ||
            (backend.configured_program.desc_iova == 0) ||
            (backend.configured_program.driver_iova == 0) ||
            (backend.configured_program.device_iova == 0) ||
            (backend.disabled_program.desc_iova !=
             backend.configured_program.desc_iova) ||
            (vq_mgr.get_queue_count() != 0))
            `uvm_error("TEST", "queue program was not passed through the backend")
        `uvm_info("UNIT_TEST", "test_config_backend_injection PASSED", UVM_LOW)
    endtask

    // common-config 后端的 reset_queue 必须返回 Q_RESET 轮询的真实结果；超时时
    // ops.reset_queue 进入错误分支（调用方据此保留 ring/DMA）。
    task test_common_backend_queue_reset_result();
        virtio_mock_transport transport;
        virtio_common_cfg_backend backend;
        virtio_atomic_ops ops;
        virtio_unit_exact_error_catcher catcher;
        bit ok;

        transport = virtio_mock_transport::type_id::create("queue_reset_transport");
        backend = virtio_common_cfg_backend::type_id::create("queue_reset_backend");
        backend.bind_transport(transport);

        transport.queue_reset_complete = 1;
        backend.reset_queue(3, ok);
        if (!ok || (transport.queue_reset_count != 1) || (transport.last_reset_queue_id != 3))
            `uvm_error("TEST", "completed queue reset was not reported as ok")

        transport.queue_reset_complete = 0;
        backend.reset_queue(3, ok);
        if (ok)
            `uvm_error("TEST", "timed-out queue reset was reported as ok")

        ops = virtio_atomic_ops::type_id::create("queue_reset_ops");
        ops.transport = transport;
        ops.config_backend = backend;
        catcher = new("queue_reset_catcher", "ATOMIC_OPS",
                      "reset_queue: config backend did not confirm queue_id=3 reset");
        uvm_report_cb::add(null, catcher);
        ops.reset_queue(3);
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught_count != 1)
            `uvm_error("TEST", "ops.reset_queue did not report the unconfirmed queue reset")
        `uvm_info("UNIT_TEST", "test_common_backend_queue_reset_result PASSED", UVM_LOW)
    endtask

    // vq_mgr 的 DMA host 与 transport 冻结 identity 不一致时，setup_queue 必须报错
    // 并回滚（不建 ring、不映射、不编程设备），不得静默用 host0 做 ring DMA。
    task test_setup_queue_rejects_host_mismatch();
        virtio_atomic_ops ops;
        virtio_unit_recording_backend backend;
        virtio_pci_transport transport;
        virtqueue_manager vq_mgr;
        virtio_iommu_model iommu;
        host_mem_manager mem;
        dpu_pcie_function_id_t pcie_id;
        virtio_unit_exact_error_catcher catcher;
        string expected[$];
        bit ok;

        ops = virtio_atomic_ops::type_id::create("host_mismatch_ops");
        backend = virtio_unit_recording_backend::type_id::create("host_mismatch_backend");
        transport = virtio_pci_transport::type_id::create("host_mismatch_transport");
        vq_mgr = virtqueue_manager::type_id::create("host_mismatch_vq_mgr");
        iommu = virtio_iommu_model::type_id::create("host_mismatch_iommu");
        mem = host_mem_manager::type_id::create("host_mismatch_mem");
        mem.init_region(64'h7700_0000, 64'h7700_FFFF);
        pcie_id = virtio_vq_test_kit::host0_pcie_id(16'h0132);
        pcie_id.domain.host_id = 1;
        transport.configure_pcie_identity(pcie_id);
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        vq_mgr.host_id = 0;
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.config_backend = backend;

        catcher = new("host_mismatch_catcher", "ATOMIC_OPS",
                      "setup_queue: queue_id=0 vq host_id=0 does not match transport DMA host 1");
        uvm_report_cb::add(null, catcher);
        ops.setup_queue(0, 4, VQ_SPLIT, ok);
        uvm_report_cb::delete(null, catcher);
        expected = '{"query_queue_max"};
        if (ok || (catcher.caught_count != 1) || (vq_mgr.get_queue_count() != 0) ||
            (backend.calls != expected))
            `uvm_error("TEST", $sformatf(
                "host-mismatched setup_queue was not rejected and rolled back (ok=%0d caught=%0d queues=%0d calls=%p)",
                ok, catcher.caught_count, vq_mgr.get_queue_count(), backend.calls))
        `uvm_info("UNIT_TEST", "test_setup_queue_rejects_host_mismatch PASSED", UVM_LOW)
    endtask

    // 协议能力是通用 ops/FSM 区分标准与私有 Function 的唯一依据；bind_ops 把协议
    // 绑定进 ops，供 ops 内的能力查询使用。
    task test_driver_protocol_capabilities();
        virtio_standard_driver_protocol standard;
        dpu_priv_driver_protocol private_protocol;
        virtio_atomic_ops ops;
        virtio_common_cfg_backend std_be;
        virtio_driver_config_t behavior;
        string why;

        standard = virtio_standard_driver_protocol::type_id::create("cap_standard_protocol");
        private_protocol = dpu_priv_driver_protocol::type_id::create("cap_private_protocol");
        if (!standard.has_ctrl_vq() || !standard.supports_mq() ||
            !standard.supports_migration() ||
            (standard.queue_format(VQ_SPLIT) != VQ_SPLIT) ||
            (standard.queue_format(VQ_PACKED) != VQ_PACKED))
            `uvm_error("TEST", "standard protocol capabilities differ from virtio-net")
        if (private_protocol.has_ctrl_vq() || private_protocol.supports_mq() ||
            private_protocol.supports_migration() ||
            (private_protocol.queue_format(VQ_SPLIT) != VQ_CUSTOM) ||
            (private_protocol.queue_format(VQ_PACKED) != VQ_CUSTOM))
            `uvm_error("TEST", "private protocol capabilities differ from the DPU private ring")

        ops = virtio_atomic_ops::type_id::create("cap_ops");
        std_be = virtio_common_cfg_backend::type_id::create("cap_std_backend");
        behavior.num_queue_pairs = 1;
        if (!standard.bind_ops(ops, std_be, behavior, why) || (ops.protocol != standard))
            `uvm_error("TEST", "standard bind_ops did not bind the protocol into ops")
        `uvm_info("UNIT_TEST", "test_driver_protocol_capabilities PASSED", UVM_LOW)
    endtask

    // 私有协议没有 control VQ、动态 MQ 与迁移：通用 ops/FSM 必须在访问队列或设备前
    // 拒绝，且不改变 FSM 状态。ops 只有协议、没有 transport/队列，任何越过门控的
    // 访问都会以空句柄失败。
    task test_private_capability_gates();
        dpu_priv_driver_protocol private_protocol;
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;
        virtio_unit_exact_error_catcher catcher;
        virtio_device_snapshot_t snap;
        virtio_ctrl_ack_e ack;
        byte unsigned data[];
        string why;
        bit ok;

        private_protocol = dpu_priv_driver_protocol::type_id::create("gate_private_protocol");
        ops = virtio_atomic_ops::type_id::create("gate_ops");
        ops.protocol = private_protocol;
        fsm = virtio_auto_fsm::type_id::create("gate_fsm");
        fsm.ops = ops;
        if (!fsm.bind_mq_pair_limit(2, why))
            `uvm_fatal("TEST", why)

        data = new[2];
        data[0] = 8'h01;
        data[1] = 8'h00;
        ack = VIRTIO_NET_CTRL_ACK_OK;
        catcher = new("gate_ctrl_catcher", "ATOMIC_OPS",
                      "ctrl_send: driver protocol has no control VQ");
        uvm_report_cb::add(null, catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET, data, ack);
        uvm_report_cb::delete(null, catcher);
        if ((ack != VIRTIO_NET_CTRL_ACK_ERR) || (catcher.caught_count != 1))
            `uvm_error("TEST", "private ctrl_send was not rejected before touching a queue")

        catcher = new("gate_mq_catcher", "AUTO_FSM",
                      "configure_mq: driver protocol does not support dynamic MQ");
        uvm_report_cb::add(null, catcher);
        fsm.configure_mq(1);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
            `uvm_error("TEST", "private configure_mq was not rejected by capability")

        catcher = new("gate_freeze_catcher", "AUTO_FSM",
                      "freeze_for_migration: driver protocol does not support migration");
        uvm_report_cb::add(null, catcher);
        fsm.freeze_for_migration(snap);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
            `uvm_error("TEST", "private freeze was not rejected by capability")

        snap.num_queue_pairs = 1;
        ok = 1;
        catcher = new("gate_restore_catcher", "AUTO_FSM",
                      "restore_from_migration: driver protocol does not support migration");
        uvm_report_cb::add(null, catcher);
        fsm.restore_from_migration(snap, ok);
        uvm_report_cb::delete(null, catcher);
        if (ok || (catcher.caught_count != 1) || (fsm.state != FSM_IDLE))
            `uvm_error("TEST", "private restore was not rejected by capability")

        // 运行中的私有 Function 不得重初始化：ops 没有 transport/队列，任何越过拒绝的
        // 发现/复位都会以空句柄失败；状态保持 FSM_RUNNING。
        fsm.drv_cfg.num_queue_pairs = 1;
        fsm.state = FSM_RUNNING;
        catcher = new("gate_running_init_catcher", "AUTO_FSM",
                      "full_init: dataplane is running; stop it before re-initialization");
        uvm_report_cb::add(null, catcher);
        fsm.full_init();
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught_count != 1) || (fsm.state != FSM_RUNNING) ||
            (ops.config_backend != null))
            `uvm_error("TEST", "private full_init ran while the dataplane was running")
        fsm.state = FSM_IDLE;
        `uvm_info("UNIT_TEST", "test_private_capability_gates PASSED", UVM_LOW)
    endtask

    // 通用 setup_queue 按队列格式声明的 ring 区映射：私有环整块 desc+CQ 只映射一次，
    // CQ 的 IOVA 是同一映射内的偏移，没有 driver 区；拆除只解除这一条映射。
    task test_setup_queue_maps_format_regions();
        virtio_atomic_ops ops;
        virtio_unit_recording_backend backend;
        virtio_pci_transport transport;
        virtqueue_manager vq_mgr;
        virtio_iommu_model iommu;
        host_mem_manager mem;
        virtio_queue_program_t q;
        int unsigned maps_before;
        int unsigned unmaps_before;
        bit ok;

        ops = virtio_atomic_ops::type_id::create("regions_ops");
        backend = virtio_unit_recording_backend::type_id::create("regions_backend");
        transport = virtio_pci_transport::type_id::create("regions_transport");
        vq_mgr = virtqueue_manager::type_id::create("regions_vq_mgr");
        iommu = virtio_iommu_model::type_id::create("regions_iommu");
        mem = host_mem_manager::type_id::create("regions_mem");
        mem.init_region(64'h7800_0000, 64'h7801_FFFF);
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0133));
        vq_mgr.mem = mem;
        vq_mgr.iommu = iommu;
        vq_mgr.bdf = transport.bdf;
        vq_mgr.host_id = transport.iommu_host_id();
        ops.transport = transport;
        ops.vq_mgr = vq_mgr;
        ops.iommu = iommu;
        ops.mem = mem;
        ops.config_backend = backend;

        maps_before = iommu.total_maps;
        unmaps_before = iommu.total_unmaps;
        ops.setup_queue(1, 8, VQ_CUSTOM, ok);
        q = backend.configured_program;
        if (!ok || (iommu.total_maps != maps_before + 1) || (q.ring_bytes != 4096) ||
            (q.desc_iova == 0) || (q.driver_iova != 0) ||
            (q.device_iova != q.desc_iova + 8*16))
            `uvm_error("TEST", $sformatf(
                "private ring regions mapped wrongly (ok=%0d maps=%0d bytes=%0d desc=0x%0h driver=0x%0h device=0x%0h)",
                ok, iommu.total_maps - maps_before, q.ring_bytes,
                q.desc_iova, q.driver_iova, q.device_iova))
        ops.teardown_queue(1);
        if ((iommu.total_unmaps != unmaps_before + 1) || (vq_mgr.get_queue_count() != 0))
            `uvm_error("TEST", "private ring teardown did not release its single mapping")
        mem.leak_check();
        `uvm_info("UNIT_TEST", "test_setup_queue_maps_format_regions PASSED", UVM_LOW)
    endtask

    // 驱动协议决定 status 访问权限、关机复位语义与私有配置冻结；两种协议都创建通用
    // ops/FSM。私有协议只接受私有配置后端，并把协议绑定进 ops；标准协议只接受
    // common-config 后端。
    task test_driver_protocol_selection();
        virtio_standard_driver_protocol standard;
        dpu_priv_driver_protocol private_protocol;
        dpu_priv_driver_config private_cfg;
        virtio_atomic_ops ops;
        virtio_auto_fsm fsm;
        virtio_driver_config_t behavior;
        virtio_common_cfg_backend std_backend;
        dpu_priv_config_backend priv_backend;
        string why;

        behavior.num_queue_pairs = 1;
        std_backend = virtio_common_cfg_backend::type_id::create("unit_standard_backend");
        priv_backend = dpu_priv_config_backend::type_id::create("unit_private_backend");
        standard = virtio_standard_driver_protocol::type_id::create(
            "unit_standard_protocol");
        ops = null;
        fsm = null;
        if (!standard.allows_status_access() || standard.requires_verified_reset() ||
            !standard.prepare_candidates("unit_standard", null, behavior, ops, fsm) ||
            (ops == null) || (fsm == null))
            `uvm_error("TEST", "standard driver protocol did not create generic ops/FSM")

        // 下发私有后端：标准协议必须拒绝，且不改动 ops（不绑后端、不绑协议）。
        if (standard.bind_ops(ops, priv_backend, behavior, why) ||
            (why != "标准协议要求 virtio_common_cfg_backend") ||
            (ops.config_backend != null) || (ops.protocol != null))
            `uvm_error("TEST", {"standard protocol accepted a private config backend: ", why})

        if (!standard.bind_ops(ops, std_backend, behavior, why) ||
            (ops.config_backend != std_backend) || (ops.protocol != standard))
            `uvm_error("TEST", "standard driver protocol did not select standard ops/FSM")

        private_cfg = dpu_priv_driver_config::type_id::create("unit_private_cfg");
        private_protocol = dpu_priv_driver_protocol::type_id::create(
            "unit_private_protocol");
        private_protocol.private_cfg = private_cfg;
        behavior.irq_mode = IRQ_POLLING;
        ops = null;
        fsm = null;
        if (private_protocol.allows_status_access() ||
            !private_protocol.requires_verified_reset() ||
            !private_protocol.prepare_candidates("unit_private", null, behavior, ops, fsm) ||
            (ops == null) || (fsm == null))
            `uvm_error("TEST", "private driver protocol did not create generic ops/FSM")

        // 下发标准后端：私有协议必须拒绝冻结，且不改动 ops（不绑后端、不绑协议）。
        if (private_protocol.bind_ops(ops, std_backend, behavior, why) ||
            (why != "私有协议要求 dpu_priv_config_backend") ||
            (ops.config_backend != null) || (ops.protocol != null))
            `uvm_error("TEST", {"private protocol accepted a standard config backend: ", why})

        if (!private_protocol.bind_ops(ops, priv_backend, behavior, why) ||
            (ops.config_backend != priv_backend) ||
            (ops.protocol != private_protocol))
            `uvm_error("TEST", {"private protocol did not bind its backend: ", why})
        `uvm_info("UNIT_TEST", "test_driver_protocol_selection PASSED", UVM_LOW)
    endtask

    // BAR 角色只由 snapshot 租约构造的布局对象回答；非法租约给出与 bar accessor
    // 相同的上下文消息且不产生布局。
    task test_fabric_bar_layout_roles();
        dpu_bar_pair_lease_t bars[$];
        dpu_bar_pair_lease_t lease;
        fabric_bar_layout layout;
        dpu_bar_role_e role;
        string why;

        lease.role = DPU_BAR_MAILBOX;
        lease.even_bar_id = 2;
        lease.base = 64'h0001_0000_2000_0000;
        lease.size = 64'h0000_0000_0001_0000;
        bars.push_back(lease);
        lease.role = DPU_BAR_MSIX;
        lease.even_bar_id = 4;
        lease.base = 64'h0001_0000_3000_0000;
        lease.size = 64'h0000_0000_0001_0000;
        bars.push_back(lease);
        lease.role = DPU_BAR_DEVICE_MEMORY;
        lease.even_bar_id = 0;
        lease.base = 64'h0001_0000_1000_0000;
        lease.size = 64'h0000_0000_0010_0000;
        bars.push_back(lease);
        if (!fabric_bar_layout::build(bars, layout, why) || (layout == null) ||
            (layout.even_bar_for(DPU_BAR_DEVICE_MEMORY) != 0) ||
            (layout.even_bar_for(DPU_BAR_MAILBOX) != 2) ||
            (layout.even_bar_for(DPU_BAR_MSIX) != 4) ||
            !layout.role_of(5, role) || (role != DPU_BAR_MSIX) ||
            !layout.has_role(1, DPU_BAR_DEVICE_MEMORY) ||
            layout.has_role(2, DPU_BAR_MSIX))
            `uvm_error("TEST", {"valid Fabric BAR leases produced a wrong layout: ", why})

        bars[0].even_bar_id = 4;
        if (fabric_bar_layout::build(bars, layout, why) || (layout != null) ||
            (why != "Fabric BAR lease 0 has invalid role 1 for even BAR4; expected BAR0=device-memory, BAR2=mailbox, or BAR4=MSI-X"))
            `uvm_error("TEST", {"misplaced mailbox lease was not rejected: ", why})

        bars.delete();
        if (fabric_bar_layout::build(bars, layout, why) ||
            (why != "Fabric BAR lease set must contain exactly three unique pairs; got 0"))
            `uvm_error("TEST", {"empty Fabric BAR lease set was not rejected: ", why})
        `uvm_info("UNIT_TEST", "test_fabric_bar_layout_roles PASSED", UVM_LOW)
    endtask

    // 范围建队按 RX=2i/TX=2i+1 编号；失败时只拆除本次已建队列。
    task test_setup_queue_range_rollback();
        virtio_unit_range_ops ops;
        bit ok;
        int unsigned expected_setup[$];
        int unsigned expected_teardown[$];

        ops = virtio_unit_range_ops::type_id::create("range_ops");
        ops.setup_queue_range(1, 2, VQ_SPLIT, 8, ok);
        expected_setup = '{2, 3, 4, 5};
        if (!ok || (ops.setup_qids != expected_setup) || (ops.teardown_qids.size() != 0))
            `uvm_error("TEST", $sformatf("range setup created %p torn down %p",
                                         ops.setup_qids, ops.teardown_qids))

        ops.setup_qids.delete();
        ops.fail_qid = 5;
        ops.setup_queue_range(1, 2, VQ_SPLIT, 8, ok);
        expected_teardown = '{2, 3, 4};
        if (ok || (ops.setup_qids != expected_setup) ||
            (ops.teardown_qids != expected_teardown))
            `uvm_error("TEST", $sformatf("range rollback created %p torn down %p",
                                         ops.setup_qids, ops.teardown_qids))
        `uvm_info("UNIT_TEST", "test_setup_queue_range_rollback PASSED", UVM_LOW)
    endtask

    // 使用生产 common-config 后端、virtqueue、Host memory 与 IOMMU 验证批量建队的
    // 失败闭环。第二条队列映射失败后，未协商 RING_RESET 的第一条队列无法单独停下，
    // 必须升级为 verified Function reset：成功时零泄漏，失败时保留仍可能被 DMA 的
    // 三个 ring 和显式 recovery 状态；随后成功复位才允许清理并解除恢复门禁。
    task test_setup_queue_range_verified_recovery();
        virtio_unit_queue_recovery_mem success_mem;
        virtio_unit_queue_recovery_iommu success_iommu;
        virtio_mock_transport success_transport;
        virtio_vq_test_kit success_kit;
        virtio_atomic_ops success_ops;
        virtio_unit_exact_error_catcher success_map_catcher;
        virtio_unit_exact_error_catcher success_stop_catcher;
        virtio_unit_queue_recovery_mem failed_mem;
        virtio_unit_queue_recovery_iommu failed_iommu;
        virtio_mock_transport failed_transport;
        virtio_vq_test_kit failed_kit;
        virtio_atomic_ops failed_ops;
        virtio_unit_exact_error_catcher failed_map_catcher;
        virtio_unit_exact_error_catcher failed_stop_catcher;
        virtio_unit_exact_error_catcher failed_reset_catcher;
        virtio_unit_exact_error_catcher failed_recovery_catcher;
        virtio_unit_exact_error_catcher blocked_setup_catcher;
        bit ok;
        bit reset_ok;

        // reset 成功：q0 的三个 split-ring 映射与 Host allocation 全部由整设备复位回收。
        success_mem = virtio_unit_queue_recovery_mem::type_id::create("range_recovery_success_mem");
        success_mem.init_region(64'h7a00_0000, 64'h7a03_ffff);
        success_iommu = virtio_unit_queue_recovery_iommu::type_id::create(
            "range_recovery_success_iommu");
        success_iommu.fail_on_map_attempt = 4;
        success_transport = virtio_mock_transport::type_id::create(
            "range_recovery_success_transport");
        success_transport.configure_pcie_identity(
            virtio_vq_test_kit::host0_pcie_id(16'h0136));
        success_kit = virtio_vq_test_kit::create_kit(
            "range_recovery_success", success_mem, success_iommu, 16'h0136);
        success_ops = success_kit.make_ops(
            success_transport, "range_recovery_success_ops");
        success_map_catcher = new(
            "range_recovery_success_map_catcher", "ATOMIC_OPS",
            "setup_queue: failed to map queue_id=1 rings");
        success_stop_catcher = new(
            "range_recovery_success_stop_catcher", "ATOMIC_OPS",
            {"teardown_queue: config backend did not confirm queue_id=0 stopped; ",
             "retaining queue DMA"});
        uvm_report_cb::add(null, success_map_catcher);
        uvm_report_cb::add(null, success_stop_catcher);
        success_ops.setup_queue_range(0, 1, VQ_SPLIT, 8, ok);
        uvm_report_cb::delete(null, success_stop_catcher);
        uvm_report_cb::delete(null, success_map_catcher);
        if (ok || (success_map_catcher.caught_count != 1) ||
            (success_stop_catcher.caught_count != 1) ||
            (success_transport.device_reset_count != 1) ||
            !success_ops.queue_rollback_used_function_reset() ||
            success_ops.queues_require_recovery() ||
            (success_kit.vq_mgr.get_queue_count() != 0) ||
            (success_iommu.active_mapping_count() != 0) ||
            (success_mem.outstanding_allocations() != 0)) begin
            `uvm_error("TEST", $sformatf(
                {"successful rollback reset left state: ok=%0b errors=%0d/%0d reset=%0d ",
                 "recovery=%0b queues=%0d maps=%0d allocs=%0d"},
                ok, success_map_catcher.caught_count,
                success_stop_catcher.caught_count,
                success_transport.device_reset_count,
                success_ops.queues_require_recovery(),
                success_kit.vq_mgr.get_queue_count(),
                success_iommu.active_mapping_count(),
                success_mem.outstanding_allocations()))
        end

        // reset 失败：q0 仍可能被设备访问，三个 ring 的映射和 Host allocation 必须
        // 原样保留，且任何新建队尝试在访问后端之前被 recovery 门禁拒绝。
        failed_mem = virtio_unit_queue_recovery_mem::type_id::create(
            "range_recovery_failed_mem");
        failed_mem.init_region(64'h7a10_0000, 64'h7a13_ffff);
        failed_iommu = virtio_unit_queue_recovery_iommu::type_id::create(
            "range_recovery_failed_iommu");
        failed_iommu.fail_on_map_attempt = 4;
        failed_transport = virtio_mock_transport::type_id::create(
            "range_recovery_failed_transport");
        failed_transport.configure_pcie_identity(
            virtio_vq_test_kit::host0_pcie_id(16'h0137));
        failed_transport.device_reset_complete = 0;
        failed_kit = virtio_vq_test_kit::create_kit(
            "range_recovery_failed", failed_mem, failed_iommu, 16'h0137);
        failed_ops = failed_kit.make_ops(
            failed_transport, "range_recovery_failed_ops");
        failed_map_catcher = new(
            "range_recovery_failed_map_catcher", "ATOMIC_OPS",
            "setup_queue: failed to map queue_id=1 rings");
        failed_stop_catcher = new(
            "range_recovery_failed_stop_catcher", "ATOMIC_OPS",
            {"teardown_queue: config backend did not confirm queue_id=0 stopped; ",
             "retaining queue DMA"});
        failed_reset_catcher = new(
            "range_recovery_failed_reset_catcher", "ATOMIC_OPS",
            "device_reset: transport reset did not complete; retaining PF DMA");
        failed_recovery_catcher = new(
            "range_recovery_failed_recovery_catcher", "ATOMIC_OPS",
            {"rollback_created_queues: verified Function reset failed; ",
             "retaining queue DMA and requiring recovery"});
        uvm_report_cb::add(null, failed_map_catcher);
        uvm_report_cb::add(null, failed_stop_catcher);
        uvm_report_cb::add(null, failed_reset_catcher);
        uvm_report_cb::add(null, failed_recovery_catcher);
        failed_ops.setup_queue_range(0, 1, VQ_SPLIT, 8, ok);
        uvm_report_cb::delete(null, failed_recovery_catcher);
        uvm_report_cb::delete(null, failed_reset_catcher);
        uvm_report_cb::delete(null, failed_stop_catcher);
        uvm_report_cb::delete(null, failed_map_catcher);
        if (ok || (failed_map_catcher.caught_count != 1) ||
            (failed_stop_catcher.caught_count != 1) ||
            (failed_reset_catcher.caught_count != 1) ||
            (failed_recovery_catcher.caught_count != 1) ||
            (failed_transport.device_reset_count != 1) ||
            !failed_ops.queue_rollback_used_function_reset() ||
            !failed_ops.queues_require_recovery() ||
            (failed_kit.vq_mgr.get_queue_count() != 1) ||
            (failed_iommu.active_mapping_count() != 3) ||
            (failed_mem.outstanding_allocations() != 3)) begin
            `uvm_error("TEST", $sformatf(
                {"failed rollback reset did not retain ownership: ok=%0b errors=%0d/%0d/%0d/%0d ",
                 "reset=%0d recovery=%0b queues=%0d maps=%0d allocs=%0d"},
                ok, failed_map_catcher.caught_count,
                failed_stop_catcher.caught_count,
                failed_reset_catcher.caught_count,
                failed_recovery_catcher.caught_count,
                failed_transport.device_reset_count,
                failed_ops.queues_require_recovery(),
                failed_kit.vq_mgr.get_queue_count(),
                failed_iommu.active_mapping_count(),
                failed_mem.outstanding_allocations()))
        end

        blocked_setup_catcher = new(
            "range_recovery_blocked_setup_catcher", "ATOMIC_OPS",
            "setup_queue: verified Function reset required before creating another queue");
        uvm_report_cb::add(null, blocked_setup_catcher);
        failed_ops.setup_queue(2, 8, VQ_SPLIT, ok);
        uvm_report_cb::delete(null, blocked_setup_catcher);
        if (ok || (blocked_setup_catcher.caught_count != 1) ||
            (failed_kit.vq_mgr.get_queue_count() != 1) ||
            (failed_iommu.active_mapping_count() != 3) ||
            (failed_mem.outstanding_allocations() != 3))
            `uvm_error("TEST", "queue recovery gate did not preserve retained DMA ownership")

        failed_transport.device_reset_complete = 1;
        failed_ops.device_reset_verified(reset_ok);
        if (!reset_ok || failed_ops.queues_require_recovery() ||
            (failed_transport.device_reset_count != 2) ||
            (failed_kit.vq_mgr.get_queue_count() != 0) ||
            (failed_iommu.active_mapping_count() != 0) ||
            (failed_mem.outstanding_allocations() != 0))
            `uvm_error("TEST", "successful recovery reset did not release retained queue ownership")

        `uvm_info("UNIT_TEST", "test_setup_queue_range_verified_recovery PASSED", UVM_LOW)
    endtask

    // 未确认完成的 Function reset 必须保留全部旧 ring，并同时关闭普通建队与
    // control VQ 提交入口。普通的重复 qid 请求也必须在重新分配 ring 或编程设备前
    // 失败。后续 verified reset 成功后释放旧所有权并重新开放新生命周期入口。
    task test_failed_reset_and_duplicate_queue_gates();
        virtio_unit_queue_recovery_mem mem;
        virtio_unit_queue_recovery_iommu iommu;
        virtio_unit_counting_mock_transport transport;
        virtio_vq_test_kit kit;
        virtio_atomic_ops ops;
        virtio_unit_exact_error_catcher duplicate_catcher;
        virtio_unit_exact_error_catcher reset_catcher;
        virtio_unit_exact_error_catcher setup_gate_catcher;
        virtio_unit_exact_error_catcher ctrl_gate_catcher;
        byte unsigned ctrl_data[];
        virtio_ctrl_ack_e ack;
        int unsigned maps_before;
        int unsigned allocs_before;
        int unsigned programs_before;
        int unsigned queries_before;
        bit ok;
        bit reset_ok;

        mem = virtio_unit_queue_recovery_mem::type_id::create(
            "failed_reset_gate_mem");
        mem.init_region(64'h7a20_0000, 64'h7a23_ffff);
        iommu = virtio_unit_queue_recovery_iommu::type_id::create(
            "failed_reset_gate_iommu");
        transport = virtio_unit_counting_mock_transport::type_id::create(
            "failed_reset_gate_transport");
        transport.configure_pcie_identity(
            virtio_vq_test_kit::host0_pcie_id(16'h0138));
        kit = virtio_vq_test_kit::create_kit(
            "failed_reset_gate", mem, iommu, 16'h0138);
        ops = kit.make_ops(transport, "failed_reset_gate_ops");

        ops.setup_queue(0, 8, VQ_SPLIT, ok);
        if (!ok || (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != 3) ||
            (mem.outstanding_allocations() != 3))
            `uvm_fatal("TEST", "failed-reset gate fixture could not create queue 0")

        maps_before = iommu.active_mapping_count();
        allocs_before = mem.outstanding_allocations();
        programs_before = transport.programmed_qids.size();
        queries_before = transport.queue_max_read_count;

        // 重复 qid 在查询、分配、映射和设备编程前拒绝，旧队列生命周期及全部
        // 资源计数必须保持原样。
        duplicate_catcher = new(
            "duplicate_queue_catcher", "ATOMIC_OPS",
            "setup_queue: queue_id=0 already exists");
        uvm_report_cb::add(null, duplicate_catcher);
        ops.setup_queue(0, 8, VQ_SPLIT, ok);
        uvm_report_cb::delete(null, duplicate_catcher);
        if (ok || (duplicate_catcher.caught_count != 1) ||
            (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != maps_before) ||
            (mem.outstanding_allocations() != allocs_before) ||
            (transport.queue_max_read_count != queries_before) ||
            (transport.programmed_qids.size() != programs_before))
            `uvm_error("TEST", "duplicate queue setup changed existing ownership")

        // 直接 Function reset 失败时，即使此前没有批量回滚置位恢复状态，也必须
        // 保留 q0 并关闭两个公开入口。
        transport.device_reset_complete = 0;
        reset_catcher = new(
            "direct_failed_reset_catcher", "ATOMIC_OPS",
            "device_reset: transport reset did not complete; retaining PF DMA");
        uvm_report_cb::add(null, reset_catcher);
        ops.device_reset_verified(reset_ok);
        uvm_report_cb::delete(null, reset_catcher);
        if (reset_ok || (reset_catcher.caught_count != 1) ||
            !ops.queues_require_recovery() ||
            !ops.control_vq_requires_recovery() ||
            (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != maps_before) ||
            (mem.outstanding_allocations() != allocs_before) ||
            (transport.queue_max_read_count != queries_before) ||
            (transport.programmed_qids.size() != programs_before))
            `uvm_error("TEST", "failed direct reset did not retain and gate queue ownership")

        setup_gate_catcher = new(
            "failed_reset_setup_gate_catcher", "ATOMIC_OPS",
            "setup_queue: verified Function reset required before creating another queue");
        uvm_report_cb::add(null, setup_gate_catcher);
        ops.setup_queue(2, 8, VQ_SPLIT, ok);
        uvm_report_cb::delete(null, setup_gate_catcher);
        if (ok || (setup_gate_catcher.caught_count != 1) ||
            (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != maps_before) ||
            (mem.outstanding_allocations() != allocs_before) ||
            (transport.queue_max_read_count != queries_before) ||
            (transport.programmed_qids.size() != programs_before))
            `uvm_error("TEST", "failed-reset queue gate had a side effect")

        ctrl_data = new[0];
        ctrl_gate_catcher = new(
            "failed_reset_ctrl_gate_catcher", "ATOMIC_OPS",
            "ctrl_send: control VQ recovery is pending; verified device reset required");
        uvm_report_cb::add(null, ctrl_gate_catcher);
        ops.ctrl_send(VIRTIO_NET_CTRL_CLS_MQ,
                      VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET,
                      ctrl_data, ack);
        uvm_report_cb::delete(null, ctrl_gate_catcher);
        if ((ack != VIRTIO_NET_CTRL_ACK_ERR) ||
            (ctrl_gate_catcher.caught_count != 1) ||
            (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != maps_before) ||
            (mem.outstanding_allocations() != allocs_before) ||
            (transport.queue_max_read_count != queries_before))
            `uvm_error("TEST", "failed-reset control gate had a side effect")

        // 只有成功的 reset 重试可以释放 q0 并重新开放两个入口。随后成功建立新 q2，
        // 证明建队能力已恢复而不是被永久锁死。
        transport.device_reset_complete = 1;
        ops.device_reset_verified(reset_ok);
        if (!reset_ok || ops.queues_require_recovery() ||
            ops.control_vq_requires_recovery() ||
            (transport.device_reset_count != 2) ||
            (kit.vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("TEST", "successful reset retry did not reopen the Function lifecycle")

        ops.setup_queue(2, 8, VQ_SPLIT, ok);
        if (!ok || (kit.vq_mgr.get_queue_count() != 1) ||
            (iommu.active_mapping_count() != 3) ||
            (mem.outstanding_allocations() != 3) ||
            (transport.queue_max_read_count != queries_before + 1))
            `uvm_error("TEST", "queue setup remained blocked after verified reset retry")
        ops.device_reset_verified(reset_ok);
        if (!reset_ok || (kit.vq_mgr.get_queue_count() != 0) ||
            (iommu.active_mapping_count() != 0) ||
            (mem.outstanding_allocations() != 0))
            `uvm_error("TEST", "failed-reset gate test leaked queue ownership")

        `uvm_info("UNIT_TEST",
                  "test_failed_reset_and_duplicate_queue_gates PASSED", UVM_LOW)
    endtask

    // 标准协议 MANUAL ATOMIC_KICK 必须经 ops 向设备发 doorbell（携带 ring 游标），不能只在
    // 软件队列上计数；队列不存在时报错且不通知。
    task test_standard_manual_kick_notifies();
        virtio_standard_driver_protocol proto;
        virtio_mock_transport transport;
        virtio_vq_test_kit kit;
        virtio_atomic_ops ops;
        host_mem_manager mem;
        virtio_iommu_model iommu;
        split_virtqueue vq;
        virtio_unit_exact_error_catcher catcher;

        mem = host_mem_manager::type_id::create("manual_kick_mem");
        mem.init_region(64'h7900_0000, 64'h7900_FFFF);
        iommu = virtio_iommu_model::type_id::create("manual_kick_iommu");
        transport = virtio_mock_transport::type_id::create("manual_kick_transport");
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0134));
        kit = virtio_vq_test_kit::create_kit("manual_kick", mem, iommu, 16'h0134);
        ops = kit.make_ops(transport, "manual_kick_ops");
        vq = kit.add_split(0, 8);
        proto = virtio_standard_driver_protocol::type_id::create("manual_kick_protocol");

        proto.kick(ops, 0);
        catcher = new("manual_kick_missing_catcher", "ATOMIC_OPS",
                      "kick_queue: queue 5 not found");
        uvm_report_cb::add(null, catcher);
        proto.kick(ops, 5);
        uvm_report_cb::delete(null, catcher);
        if ((transport.kick_count != 1) || (transport.last_kick_queue_id != 0) ||
            (transport.last_kick_next_avail_idx != vq.get_notify_next_idx()) ||
            (catcher.caught_count != 1))
            `uvm_error("TEST", $sformatf(
                "standard MANUAL ATOMIC_KICK did not notify the device (kicks=%0d caught=%0d)",
                transport.kick_count, catcher.caught_count))
        kit.vq_mgr.destroy_all();
        `uvm_info("UNIT_TEST", "test_standard_manual_kick_notifies PASSED", UVM_LOW)
    endtask

    // 队列片段（control VQ 定位）与迁移采集读取的 net config / status 必须经注入的
    // 后端，transport 的 net config 寄存器不得被直接读取。
    task test_config_reads_use_backend();
        virtio_mock_transport transport;
        virtio_unit_recording_backend backend;
        virtio_vq_test_kit kit;
        virtio_atomic_ops ops;
        virtio_migration_engine migration;
        virtio_device_snapshot_t snap;
        host_mem_manager mem;
        virtio_iommu_model iommu;
        int unsigned net_config_calls;
        int unsigned status_calls;
        bit ctrl_at_4;
        bit reset_ok;
        bit ok;

        mem = host_mem_manager::type_id::create("cfg_read_mem");
        mem.init_region(64'h7800_0000, 64'h7800_FFFF);
        iommu = virtio_iommu_model::type_id::create("cfg_read_iommu");
        transport = virtio_mock_transport::type_id::create("cfg_read_transport");
        transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h0135));
        kit = virtio_vq_test_kit::create_kit("cfg_read", mem, iommu, 16'h0135);
        ops = kit.make_ops(transport, "cfg_read_ops");
        backend = virtio_unit_recording_backend::type_id::create("cfg_read_backend");
        backend.net_config.max_virtqueue_pairs = 2;
        ops.config_backend = backend;
        ops.negotiated_features[VIRTIO_NET_F_CTRL_VQ] = 1'b1;
        ops.negotiated_features[VIRTIO_NET_F_MQ] = 1'b1;

        // 后端报告 max_virtqueue_pairs=2，control VQ 必须是 4（mock transport 报告 1）。
        ops.setup_all_queues(1, VQ_SPLIT, 4, ok);
        ctrl_at_4 = ok && kit.vq_mgr.has_queue(4);
        ops.device_reset_verified(reset_ok);

        migration = virtio_migration_engine::type_id::create("cfg_read_migration");
        migration.capture_snapshot(ops, 0, 0, 0, ok, snap);
        net_config_calls = 0;
        status_calls = 0;
        foreach (backend.calls[i]) begin
            if (backend.calls[i] == "read_net_config")
                net_config_calls++;
            if (backend.calls[i] == "read_status")
                status_calls++;
        end
        if (!ctrl_at_4 || !reset_ok || !ok || (net_config_calls != 2) ||
            (status_calls != 1) || (transport.net_config_reads != 0) ||
            (snap.net_config.max_virtqueue_pairs != 2))
            `uvm_error("TEST", $sformatf(
                "status/net config reads bypassed the config backend (ctrl_at_4=%0b ok=%0b net_cfg=%0d status=%0d direct_net_cfg=%0d)",
                ctrl_at_4, ok, net_config_calls, status_calls, transport.net_config_reads))
        `uvm_info("UNIT_TEST", "test_config_reads_use_backend PASSED", UVM_LOW)
    endtask

    // 后端由 Function 在提交时选择并下发；ops 未获下发时是接线错误，不得自建后端。
    task test_ops_requires_selected_backend();
        virtio_unit_backend_probe_ops ops;
        virtio_unit_exact_error_catcher catcher;
        virtio_config_backend backend;

        ops = virtio_unit_backend_probe_ops::type_id::create("backendless_ops");
        ops.transport = virtio_mock_transport::type_id::create("backendless_transport");
        catcher = new("backendless_catcher", "ATOMIC_OPS",
            "no config backend selected; virtio_function_instance hands one down at commit");
        uvm_report_cb::add(null, catcher);
        backend = ops.probe_backend();
        uvm_report_cb::delete(null, catcher);
        if ((backend != null) || (ops.config_backend != null) || (catcher.caught_count != 1))
            `uvm_error("TEST", $sformatf(
                "ops without a selected backend created one (backend=%0b caught=%0d)",
                backend != null, catcher.caught_count))
        `uvm_info("UNIT_TEST", "test_ops_requires_selected_backend PASSED", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_UNIT_TEST_SV
