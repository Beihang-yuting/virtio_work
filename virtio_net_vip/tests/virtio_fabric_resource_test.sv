`ifndef VIRTIO_FABRIC_RESOURCE_TEST_SV
`define VIRTIO_FABRIC_RESOURCE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import gq_pkg::*;
import pcie_tl_pkg::*;
import virtio_net_pkg::*;

// 中文说明：本测试验证冻结 DPU 拓扑、PF/VF/BAR/qpair 资源以及 queue_work
// binder 的 Host/PCIe domain 隔离关系；测试只消费快照和共享 Host memory 接口，
// 不在业务环境内重新分配设备身份，也不把两个 Host 的 backing storage 混用。
// A config-space-only endpoint model lets the focused Fabric test exercise
// real virtio capability discovery without taking ownership of PCIe binding.
class virtio_fabric_cfg_stub_accessor extends virtio_bar_accessor;
    `uvm_object_utils(virtio_fabric_cfg_stub_accessor)

    typedef struct {
        bit [11:0] addr;
        bit [31:0] data;
        bit [3:0]  be;
    } config_write_t;

    int unsigned config_write_count;
    config_write_t config_writes[$];
    bit discovery_started_before_bar_programming;

    // 创建配置空间 stub 并清零写入计数；不创建真实 PCIe endpoint。
    function new(string name = "virtio_fabric_cfg_stub_accessor");
        super.new(name);
        config_write_count = 0;
        discovery_started_before_bar_programming = 0;
    endfunction

    // 按测试所需 capability 表返回配置读数据，并记录 BAR 编程前的非法访问。
    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
        if (config_write_count != 6)
            discovery_started_before_bar_programming = 1;
        data = '0;
        case (addr)
            12'h034: data = 32'h0000_0040;
            12'h040: data = {8'd1, 8'd20, 8'h50, PCI_CAP_ID_VENDOR};
            12'h044: data = 32'h0000_0000;
            12'h048: data = 32'h0000_0000;
            12'h04c: data = 32'h0000_0100;
            12'h050: data = {8'd2, 8'd20, 8'h64, PCI_CAP_ID_VENDOR};
            // Fabric profile places the virtio notification capability in
            // BAR2/3 (mailbox); BAR0/1 remains common/ISR/device config.
            12'h054: data = 32'h0000_0002;
            12'h058: data = 32'h0000_0100;
            12'h05c: data = 32'h0000_0100;
            12'h060: data = 32'h0000_0004;
            12'h064: data = {8'd3, 8'd16, 8'h74, PCI_CAP_ID_VENDOR};
            12'h068: data = 32'h0000_0000;
            12'h06c: data = 32'h0000_0200;
            12'h070: data = 32'h0000_0001;
            12'h074: data = {8'd4, 8'd16, 8'h00, PCI_CAP_ID_VENDOR};
            12'h078: data = 32'h0000_0000;
            12'h07c: data = 32'h0000_0300;
            12'h080: data = 32'h0000_0100;
            default: ;
        endcase
    endtask

    // 记录配置写地址、payload 和 byte-enable，供后续断言 BAR 编程序列。
    virtual task config_write(
        bit [11:0] addr, bit [31:0] data, bit [3:0] be
    );
        config_write_t write;

        config_write_count++;
        write.addr = addr;
        write.data = data;
        write.be = be;
        config_writes.push_back(write);
    endtask

    // 向测试暴露受保护的 functional BAR 访问策略；只读查询，不改变 accessor 状态。
    // Exposes the accessor's protected functional-access policy to this
    // focused test without changing the production API.
    function bit probe_functional_bar_access(input int unsigned bar_id);
        return allow_functional_bar_access(bar_id);
    endfunction
endclass : virtio_fabric_cfg_stub_accessor

// This deliberately small UVM driver observes requests issued through the
// base accessor's real config_write() path.  Unlike the config-space stub
// above, it cannot be reached by overriding config_write(), so it catches a
// regression that makes BAR programming in-memory-only or drops TLP payload.
class virtio_fabric_cfg_tlp_capture_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(virtio_fabric_cfg_tlp_capture_driver)

    pcie_tl_tlp captured_tlps[$];

    // 构造 TLP 捕获 driver；parent 为空时仍可被工厂创建为独立组件。
    function new(string name, uvm_component parent = null);
        super.new(name, parent);
    endfunction

    // 清空已捕获 TLP，供多个负向/正向子场景复用同一 driver。
    function void clear();
        captured_tlps.delete();
    endfunction

    // 持续接收 sequencer item 并保存到 captured_tlps；phase 结束由 UVM 回收线程。
    virtual task run_phase(uvm_phase phase);
        pcie_tl_tlp tlp;

        forever begin
            seq_item_port.get_next_item(tlp);
            captured_tlps.push_back(tlp);
            seq_item_port.item_done();
        end
    endtask
endclass : virtio_fabric_cfg_tlp_capture_driver

// Scoped negative-path catcher.  Production failures remain fatal outside
// these narrow test calls; each helper also verifies that its expected report
// was actually produced.
class virtio_expected_bar_report_catcher extends uvm_report_catcher;
    string expected_id;
    uvm_severity expected_severity;
    int unsigned caught_count;
    string last_message;

    // 创建限定一次报告的 catcher；输入期望 ID/严重级别，命中后降为 INFO 保持测试继续。
    function new(
        string name,
        string expected_report_id,
        uvm_severity expected_report_severity
    );
        super.new(name);
        expected_id = expected_report_id;
        expected_severity = expected_report_severity;
        caught_count = 0;
        last_message = "";
    endfunction

    // 检查当前报告是否是预期负向路径，记录次数/消息并返回 THROW 交回 UVM。
    function action_e catch();
        if ((get_id() == expected_id) &&
            (get_severity() == expected_severity)) begin
            caught_count++;
            last_message = get_message();
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass : virtio_expected_bar_report_catcher

class virtio_fabric_resource_test extends uvm_test;
    `uvm_component_utils(virtio_fabric_resource_test)

    typedef struct {
        dpu_pcie_domain_key_t domain;
        bit [63:0] base;
        bit [63:0] size;
    } bar_range_t;

    virtio_test_device_builder device_builder;
    dpu_device_env_config      device_cfg;
    dpu_device_env             device_env;
    dpu_device_snapshot        device_snapshot;
    dpu_resource_snapshot      resource_snapshot;
    // binder_pool 只供本测试验证 queue_work 的 Host 资源绑定，不替代
    // virtio_net_env 内部已经验证过的设备内存管理器。
    host_mem_pool              binder_pool;
    dpu_queue_resource_binder queue_binder;
    virtio_queue_host_mem_provider_adapter binder_mem_provider;
    virtio_net_env_config      cfg;
    virtio_net_env             env;
    uvm_sequencer #(pcie_tl_tlp) fabric_cfg_tlp_seqr;
    virtio_fabric_cfg_tlp_capture_driver fabric_cfg_tlp_capture;

    // 初始化 Fabric 资源测试；真正的 device/resource snapshot 在 build_phase 生成。
    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    // 给 builder 增加真实 DUT BAR 描述和 VIO service 能力，返回可继续编辑的配置。
    protected function dpu_function_cfg author_vio_function(
        input dpu_function_cfg function_cfg
    );
        device_builder.add_real_dut_bars(function_cfg);
        function_cfg.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        return function_cfg;
    endfunction

    // 构造带稀疏 local/global qid 的 placement request，验证 resolver 到 snapshot 的映射。
    protected function void author_snapshot_qpair_placement(
        input dpu_function_key_t sparse_owner
    );
        dpu_vio_placement_request request;
        dpu_vio_device_constraint count_rule;
        dpu_vio_qpair_override override;
        int unsigned sparse_locals[3] = '{0, 3, 17};
        int unsigned sparse_globals[3] = '{100, 103, 117};

        request = dpu_vio_placement_request::type_id::create(
            "fabric_snapshot_qpair_request");
        request.request_id = 1000;
        request.total_qpairs = device_cfg.device_cfg.functions.size() + 2;
        request.candidate_kind = DPU_VIO_CANDIDATE_PF_AND_VF;
        request.device_policy = DPU_VIO_DEVICE_FIXED;
        foreach (device_cfg.device_cfg.functions[index]) begin
            request.fixed_devices.push_back(
                device_cfg.device_cfg.functions[index].key);
            count_rule = dpu_vio_device_constraint::type_id::create(
                $sformatf("fabric_exact_qpairs_%0d", index));
            count_rule.function_key = device_cfg.device_cfg.functions[index].key;
            count_rule.mode = DPU_COUNT_EXACT;
            count_rule.qpair_count = dpu_same_function_key(
                count_rule.function_key, sparse_owner) ? 3 : 1;
            request.device_constraints.push_back(count_rule);
        end
        foreach (sparse_locals[index]) begin
            override = dpu_vio_qpair_override::type_id::create(
                $sformatf("fabric_sparse_qpair_%0d", index));
            override.request_pair_index = index;
            override.owner_mode = DPU_ASSIGN_PINNED;
            override.requested_owner = sparse_owner;
            override.local_mode = DPU_ASSIGN_PINNED;
            override.requested_local_pair_id = sparse_locals[index];
            override.global_mode = DPU_ASSIGN_PINNED;
            override.requested_global_qpair_id = sparse_globals[index];
            request.qpair_overrides.push_back(override);
        end
        device_cfg.placement_cfg.vio_requests.push_back(request);
    endfunction

    // 将 Function 的三个真实 DUT BAR 固定到指定地址，供冲突和 PCIe 编程测试复用。
    protected function void pin_real_dut_bars(
        input virtio_test_device_builder builder,
        input dpu_function_cfg function_cfg,
        input bit [63:0] device_base,
        input bit [63:0] mailbox_base,
        input bit [63:0] msix_base
    );
        bit [63:0] bases[3];

        bases[0] = device_base;
        bases[1] = mailbox_base;
        bases[2] = msix_base;
        builder.add_real_dut_bars(function_cfg);
        foreach (function_cfg.bars[index]) begin
            function_cfg.bars[index].placement = DPU_ALLOC_PINNED;
            function_cfg.bars[index].pinned_base = bases[index];
        end
    endfunction

    // 组装 Host/PF/VF 身份键；该纯函数不分配资源、不修改调用者状态。
    protected function automatic dpu_function_key_t make_function_key(
        input int unsigned host_id,
        input int unsigned parent_id,
        input dpu_function_kind_e kind,
        input int unsigned child_id
    );
        dpu_function_key_t key;

        key.host_id = host_id;
        key.pf_id = parent_id;
        key.kind = kind;
        key.vf_id = child_id;
        return key;
    endfunction

    // 同步追加期望 Function key 与 BDF，供 snapshot 顺序和反查断言使用。
    protected function void append_expected_function(
        ref dpu_function_key_t keys[$],
        ref bit [15:0] bdfs[$],
        input int unsigned host_id,
        input int unsigned parent_id,
        input dpu_function_kind_e kind,
        input int unsigned child_id,
        input bit [15:0] bdf
    );
        keys.push_back(make_function_key(
            host_id, parent_id, kind, child_id));
        bdfs.push_back(bdf);
    endfunction

    // 判断两个半开地址区间是否重叠；size 为零或溢出由调用方负责规避。
    protected function bit ranges_overlap(
        input bit [63:0] lhs_base,
        input bit [63:0] lhs_size,
        input bit [63:0] rhs_base,
        input bit [63:0] rhs_size
    );
        return (lhs_base < (rhs_base + rhs_size)) &&
               (rhs_base < (lhs_base + lhs_size));
    endfunction

    // 创建一个带 role/even-BAR/base/size 的 Fabric lease 值对象，不注册到 accessor。
    protected function automatic dpu_bar_pair_lease_t make_fabric_bar_pair(
        input dpu_bar_role_e role,
        input int unsigned even_bar_id,
        input bit [63:0] base,
        input bit [63:0] size
    );
        dpu_bar_pair_lease_t pair;

        pair.role = role;
        pair.even_bar_id = even_bar_id;
        pair.base = base;
        pair.size = size;
        return pair;
    endfunction

    // 判断 haystack 是否包含 needle，空 needle 视为匹配，供错误上下文断言使用。
    protected function bit string_contains(
        input string haystack,
        input string needle
    );
        if (needle.len() == 0)
            return 1;
        if (haystack.len() < needle.len())
            return 0;
        for (int offset = 0;
             offset <= (haystack.len() - needle.len());
             offset++) begin
            if (haystack.substr(offset, offset + needle.len() - 1) == needle)
                return 1;
        end
        return 0;
    endfunction

    // 生成乱序但合法的三类 Fabric BAR lease，验证 accessor 按 role/id 而非数组位置识别。
    // Deliberately return the valid leases out of BAR order.  The accessor
    // must recognize the required {role, even-BAR} set rather than treating
    // the input queue position as configuration.
    protected function void make_valid_fabric_bar_pairs(
        ref dpu_bar_pair_lease_t bars[$]
    );
        bars.delete();
        bars.push_back(make_fabric_bar_pair(
            DPU_BAR_MSIX, 4, 64'h0001_0000_3000_0000, 64'h0000_0000_0001_0000));
        bars.push_back(make_fabric_bar_pair(
            DPU_BAR_DEVICE_MEMORY, 0, 64'h0001_0000_1000_0000,
            64'h0000_0000_0010_0000));
        bars.push_back(make_fabric_bar_pair(
            DPU_BAR_MAILBOX, 2, 64'h0001_0000_2000_0000,
            64'h0000_0000_0001_0000));
    endfunction

    // 断言非法 lease 集合产生带上下文的 UVM_ERROR 且不会激活布局；失败立即 fatal。
    task assert_fabric_lease_set_rejected(
        input string case_name,
        input dpu_bar_pair_lease_t bars[$],
        input string expected_context
    );
        virtio_bar_accessor accessor;
        virtio_expected_bar_report_catcher expected_error;

        accessor = virtio_bar_accessor::type_id::create(
            {"invalid_fabric_bar_accessor_", case_name});
        expected_error = new(
            {"invalid_fabric_bar_catcher_", case_name},
            "BAR_ACCESSOR", UVM_ERROR);
        uvm_report_cb::add(null, expected_error);
        accessor.configure_fabric_bar_pairs(bars);
        uvm_report_cb::delete(null, expected_error);

        if (expected_error.caught_count != 1) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s did not report one contextual Fabric BAR lease rejection (got %0d)",
                case_name, expected_error.caught_count))
        end
        if (!string_contains(expected_error.last_message, expected_context)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s rejection lacked context '%s': %s",
                case_name, expected_context, expected_error.last_message))
        end
        if (accessor.fabric_bar_layout_is_active()) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s activated a rejected Fabric BAR lease set", case_name))
        end
    endtask

    // 断言非法 BAR 编程输入产生 UVM_FATAL，并验证配置空间访问没有继续执行。
    task assert_fabric_bar_programming_rejected(
        input string case_name,
        input dpu_bar_pair_lease_t bars[$],
        input string expected_context
    );
        virtio_fabric_cfg_stub_accessor config_stub;
        virtio_expected_bar_report_catcher expected_fatal;

        config_stub = virtio_fabric_cfg_stub_accessor::type_id::create(
            {"malformed_fabric_bar_stub_", case_name});
        config_stub.requester_id = 16'h02a8;
        config_stub.configure_fabric_bar_pairs(bars);
        expected_fatal = new(
            {"malformed_fabric_bar_catcher_", case_name},
            "BAR_FABRIC_PROGRAM", UVM_FATAL);
        uvm_report_cb::add(null, expected_fatal);
        config_stub.program_fabric_bar_pairs();
        uvm_report_cb::delete(null, expected_fatal);

        if (expected_fatal.caught_count != 1) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s did not report one contextual Fabric BAR programming rejection (got %0d)",
                case_name, expected_fatal.caught_count))
        end
        if (!string_contains(expected_fatal.last_message, expected_context)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s rejection lacked context '%s': %s",
                case_name, expected_context, expected_fatal.last_message))
        end
        if (config_stub.config_write_count != 0) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s issued %0d config write(s) before rejecting the Fabric BAR lease",
                case_name, config_stub.config_write_count))
        end
    endtask

    // 通过真实 base config_write() 路径检查六个 Type-0 TLP 的地址、BDF、BE 和 payload。
    // Verify the base config_write() sequence reaches a sequencer/driver and
    // emits complete Config Write Type-0 TLPs.  Recording a virtual override
    // alone cannot establish this transport serialization contract.
    task assert_fabric_bar_config_tlp_serialization();
        dpu_bar_pair_lease_t bars[$];
        virtio_bar_accessor accessor;
        bit [15:0] function_bdf;
        bit [11:0] expected_addr[6];
        bit [31:0] expected_data[6];

        make_valid_fabric_bar_pairs(bars);
        function_bdf = 16'h02b0;
        accessor = virtio_bar_accessor::type_id::create(
            "fabric_bar_base_config_accessor");
        accessor.requester_id = function_bdf;
        accessor.pcie_rc_seqr = fabric_cfg_tlp_seqr;
        accessor.configure_fabric_bar_pairs(bars);
        if (!accessor.fabric_bar_layout_is_active()) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "valid Fabric BAR leases were rejected before TLP serialization")
        end

        expected_addr[0] = PCI_CFG_BAR0;
        expected_addr[1] = PCI_CFG_BAR1;
        expected_addr[2] = PCI_CFG_BAR2;
        expected_addr[3] = PCI_CFG_BAR3;
        expected_addr[4] = PCI_CFG_BAR4;
        expected_addr[5] = PCI_CFG_BAR5;
        foreach (bars[pair_index]) begin
            int unsigned low_bar_id;
            bit [63:0] base;

            low_bar_id = bars[pair_index].even_bar_id;
            base = bars[pair_index].base;
            expected_data[low_bar_id] =
                (base[31:0] & 32'hffff_fff0) | 32'h0000_0004;
            expected_data[low_bar_id + 1] = base[63:32];
        end

        fabric_cfg_tlp_capture.clear();
        accessor.program_fabric_bar_pairs();
        if (fabric_cfg_tlp_capture.captured_tlps.size() != 6) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "base config_write path emitted %0d TLPs, expected exactly six",
                fabric_cfg_tlp_capture.captured_tlps.size()))
        end

        foreach (expected_addr[write_index]) begin
            pcie_tl_cfg_tlp cfg_tlp;
            bit [31:0] payload_dword;

            if (!$cast(cfg_tlp,
                       fabric_cfg_tlp_capture.captured_tlps[write_index])) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "base config_write item %0d was not a PCIe config TLP",
                    write_index))
            end
            if ((cfg_tlp.kind != TLP_CFG_WR0) ||
                (cfg_tlp.completer_id != function_bdf) ||
                (cfg_tlp.reg_num != expected_addr[write_index][11:2]) ||
                (cfg_tlp.first_be != 4'hf)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "BAR config TLP %0d header mismatch: kind=%0d target=0x%04h reg=%0d be=0x%01h expected Type0 BDF=0x%04h offset=0x%03h be=0xf",
                    write_index, cfg_tlp.kind, cfg_tlp.completer_id,
                    cfg_tlp.reg_num, cfg_tlp.first_be, function_bdf,
                    expected_addr[write_index]))
            end
            if (cfg_tlp.payload.size() != 4) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "BAR config TLP %0d payload length is %0d, expected four bytes",
                    write_index, cfg_tlp.payload.size()))
            end
            payload_dword = {cfg_tlp.payload[3], cfg_tlp.payload[2],
                             cfg_tlp.payload[1], cfg_tlp.payload[0]};
            if (payload_dword != expected_data[write_index]) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "BAR config TLP %0d payload mismatch: got 0x%08h expected 0x%08h",
                    write_index, payload_dword, expected_data[write_index]))
            end
        end
    endtask

    // 依次覆盖缺失、重复、额外、role/id 错配及非法 size/base，确认拒绝发生在配置 I/O 前。
    task assert_fabric_bar_hardening_rejections();
        dpu_bar_pair_lease_t bars[$];

        // Exact lease-set validation rejects absence, a repeated identical
        // pair, an extra pair, and a role/ID mismatch before state activation.
        bars.delete();
        assert_fabric_lease_set_rejected("zero_leases", bars, "exactly three");

        make_valid_fabric_bar_pairs(bars);
        bars[2] = bars[1];
        assert_fabric_lease_set_rejected(
            "duplicate_identical_lease", bars, "duplicates");

        make_valid_fabric_bar_pairs(bars);
        bars.push_back(make_fabric_bar_pair(
            DPU_BAR_MAILBOX, 6, 64'h0001_0000_4000_0000,
            64'h0000_0000_0001_0000));
        assert_fabric_lease_set_rejected("extra_lease", bars, "exactly three");

        make_valid_fabric_bar_pairs(bars);
        bars[1].even_bar_id = 2;
        assert_fabric_lease_set_rejected(
            "wrong_function_role_bar_id", bars, "invalid role");

        // A sub-16-byte power-of-two lease is not representable as a BAR
        // pair.  Its aligned base must still be rejected before config I/O.
        make_valid_fabric_bar_pairs(bars);
        bars[1].size = 64'h8;
        assert_fabric_bar_programming_rejected(
            "sub_16_byte_size", bars, "at least 0x10");

        // This base is aligned to its malformed 8-byte lease, so an
        // implementation that masks base[3:0] instead of rejecting it would
        // silently serialize a different BAR base.
        make_valid_fabric_bar_pairs(bars);
        bars[1].base = 64'h0001_0000_1000_0008;
        bars[1].size = 64'h8;
        assert_fabric_bar_programming_rejected(
            "low_nibble_base", bars, "low address nibble");
    endtask

    // 校验 Function 的三组 BAR role/id/size/alignment，并确认 transport 已导入 lease。
    task assert_bar_layout(input virtio_function_instance function_instance);
        dpu_bar_pair_lease_t bars[$];
        bit [63:0] device_size;
        bit [63:0] mailbox_size;
        bit [63:0] msix_size;

        bars = function_instance.bar_pairs;
        if (function_instance.function_kind == DPU_FUNCTION_PF) begin
            device_size = 64'h0000_0000_0200_0000;
            mailbox_size = 64'h0000_0000_0001_0000;
            msix_size = 64'h0000_0000_0001_0000;
        end
        else begin
            device_size = 64'h0000_0000_0000_4000;
            mailbox_size = 64'h0000_0000_0000_4000;
            msix_size = 64'h0000_0000_0000_8000;
        end

        if ((bars.size() != 3) ||
            (bars[0].role != DPU_BAR_DEVICE_MEMORY) ||
            (bars[0].even_bar_id != 0) || (bars[0].size != device_size) ||
            (bars[1].role != DPU_BAR_MAILBOX) ||
            (bars[1].even_bar_id != 2) || (bars[1].size != mailbox_size) ||
            (bars[2].role != DPU_BAR_MSIX) ||
            (bars[2].even_bar_id != 4) || (bars[2].size != msix_size)) begin
            `uvm_fatal("FABRIC_RESOURCE", "function BAR pair layout is incorrect")
        end
        foreach (bars[index]) begin
            if ((bars[index].base & (bars[index].size - 1)) != 0) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "BAR%0d is not aligned to its size", bars[index].even_bar_id))
            end
        end

        if ((function_instance.transport.bar.bar_base[0] != bars[0].base) ||
            (function_instance.transport.bar.bar_size[0] != bars[0].size) ||
            // BAR2/3 is the Fabric-owned mailbox pair.
            (function_instance.transport.bar.bar_base[2] != bars[1].base) ||
            (function_instance.transport.bar.bar_size[2] != bars[1].size) ||
            (function_instance.transport.bar.bar_base[3] != '0) ||
            (function_instance.transport.bar.bar_size[3] != '0) ||
            (function_instance.transport.bar.bar_base[4] != bars[2].base) ||
            (function_instance.transport.bar.bar_size[4] != bars[2].size)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "BAR roles were not reflected in the transport binding")
        end
    endtask

    // 在相同 PCIe domain 内检查当前 Function BAR 与已收集区间不重叠，跨 domain 允许复用数值。
    task assert_unique_bars(
        input virtio_function_instance function_instance,
        ref bar_range_t all_bars[$]
    );
        bar_range_t current;
        dpu_pcie_function_id_t pcie_id;
        string why;

        if (!device_snapshot.get_pcie_id(
                function_instance.function_key, pcie_id, why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not resolve function domain for BAR uniqueness: %s", why))
        end

        foreach (function_instance.bar_pairs[index]) begin
            current.domain = pcie_id.domain;
            current.base = function_instance.bar_pairs[index].base;
            current.size = function_instance.bar_pairs[index].size;
            foreach (all_bars[prior]) begin
                if (dpu_same_domain_key(current.domain, all_bars[prior].domain) &&
                    ranges_overlap(current.base, current.size,
                                   all_bars[prior].base, all_bars[prior].size)) begin
                    `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                        "BAR%0d overlaps an already active function BAR",
                        function_instance.bar_pairs[index].even_bar_id))
                end
            end
            all_bars.push_back(current);
        end
    endtask

    // 将 Function 的 local qpair 解析为 global qpair，断言不同 Function 不共享全局编号。
    task assert_unique_qpair(
        input virtio_function_instance function_instance,
        ref int unsigned global_qpair_ids[$]
    );
        int unsigned global_qpair_id;

        if (!function_instance.resource_client.local_qid_to_global_qid(
            0, global_qpair_id
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", "local RX queue ID did not map to a global qpair")
        end
        foreach (global_qpair_ids[index]) begin
            if (global_qpair_ids[index] == global_qpair_id) begin
                `uvm_fatal("FABRIC_RESOURCE",
                    "distinct functions share a global qpair ID")
            end
        end
        global_qpair_ids.push_back(global_qpair_id);
    endtask

    // 检查稀疏 local/global qid 映射来自 resource snapshot，且 TX/RX 共享同一 pair global id。
    task assert_sparse_snapshot_mapping(
        input virtio_function_instance function_instance,
        input string lifecycle
    );
        int unsigned observed_rx;
        int unsigned observed_tx;

        if (!function_instance.resource_client.is_bound_to_service() ||
            (function_instance.resource_client.qpair_mapping_count() != 3)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s snapshot client did not retain exactly three immutable mappings",
                lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                0, observed_rx) || (observed_rx != 100)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s RX mapping did not come from snapshot", lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                1, observed_tx) || (observed_tx != observed_rx)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s TX queue did not share its pair's global qid", lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                2, observed_rx) || (observed_rx != 103)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s software pair 1 was replaced by a derived control queue",
                lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                3, observed_tx) || (observed_tx != observed_rx)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s software pair 1 TX mapping did not share global qid",
                lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                4, observed_rx) || (observed_rx != 117)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s software pair 2 mapping did not come from snapshot",
                lifecycle))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
                5, observed_tx) || (observed_tx != observed_rx)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s software pair 2 TX mapping did not share global qid",
                lifecycle))
        end
        if (function_instance.resource_client.local_qid_to_global_qid(
                6, observed_rx)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "%s incorrectly exposed a queue ID derived from DUT local pair 3",
                lifecycle))
        end
    endtask

    // 对 discovery 产生的六次 BAR 配置写逐项检查地址、payload、BE 及编程顺序。
    task assert_fabric_bar_config_writes(
        input virtio_function_instance function_instance,
        input virtio_fabric_cfg_stub_accessor config_stub
    );
        bit [11:0] expected_addr[6];
        bit [31:0] expected_data[6];

        expected_addr[0] = PCI_CFG_BAR0;
        expected_addr[1] = PCI_CFG_BAR1;
        expected_addr[2] = PCI_CFG_BAR2;
        expected_addr[3] = PCI_CFG_BAR3;
        expected_addr[4] = PCI_CFG_BAR4;
        expected_addr[5] = PCI_CFG_BAR5;
        foreach (function_instance.bar_pairs[pair_index]) begin
            int unsigned low_bar_id;
            bit [63:0] base;

            low_bar_id = function_instance.bar_pairs[pair_index].even_bar_id;
            base = function_instance.bar_pairs[pair_index].base;
            expected_data[low_bar_id] =
                (base[31:0] & 32'hffff_fff0) | 32'h0000_0004;
            expected_data[low_bar_id + 1] = base[63:32];
        end

        if (config_stub.discovery_started_before_bar_programming) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "Fabric capability discovery started before all BAR slots were programmed for host %0d PF %0d kind %0d VF %0d",
                function_instance.function_key.host_id,
                function_instance.function_key.pf_id,
                function_instance.function_key.kind,
                function_instance.function_key.vf_id))
        end
        if (config_stub.config_write_count != 6) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected six Fabric BAR config writes for host %0d PF %0d kind %0d VF %0d, got %0d",
                function_instance.function_key.host_id,
                function_instance.function_key.pf_id,
                function_instance.function_key.kind,
                function_instance.function_key.vf_id,
                config_stub.config_write_count))
        end
        foreach (expected_addr[write_index]) begin
            if ((config_stub.config_writes[write_index].addr !=
                 expected_addr[write_index]) ||
                (config_stub.config_writes[write_index].data !=
                 expected_data[write_index]) ||
                (config_stub.config_writes[write_index].be != 4'hf)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "Fabric BAR config write %0d mismatch: addr=0x%03h data=0x%08h be=0x%01h expected addr=0x%03h data=0x%08h be=0xf",
                    write_index,
                    config_stub.config_writes[write_index].addr,
                    config_stub.config_writes[write_index].data,
                    config_stub.config_writes[write_index].be,
                    expected_addr[write_index], expected_data[write_index]))
            end
        end
    endtask

    // 为指定 Function 接入配置空间 stub，执行真实 capability discovery 并检查 BAR 访问策略。
    task discover_fabric_function(input virtio_function_instance function_instance);
        virtio_fabric_cfg_stub_accessor config_stub;
        virtio_expected_bar_report_catcher msix_only_error;
        bit mailbox_access_allowed;
        bit msix_functional_access_allowed;
        int unsigned msix_bar_ids[2];
        string expected_report_ids[2];

        msix_bar_ids[0] = 4;
        msix_bar_ids[1] = 5;
        expected_report_ids[0] = "BAR_MSIX_ONLY";
        expected_report_ids[1] = "BAR_FUNCTION_WINDOW";

        config_stub = virtio_fabric_cfg_stub_accessor::type_id::create(
            $sformatf("cfg_stub_%0d_%0d_%0d_%0d",
                function_instance.function_key.host_id,
                function_instance.function_key.pf_id,
                function_instance.function_key.kind,
                function_instance.function_key.vf_id)
        );
        config_stub.configure_fabric_bar_pairs(function_instance.bar_pairs);
        function_instance.transport.bar = config_stub;
        function_instance.transport.notify_mgr.bar = config_stub;
        function_instance.transport.cap_mgr.bar_ref = config_stub;

        function_instance.transport.discover_fabric_preconfigured_bars();
        if (!function_instance.transport.fabric_capability_discovered) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "Fabric capability discovery did not complete")
        end
        assert_fabric_bar_config_writes(function_instance, config_stub);
        assert_bar_layout(function_instance);

        mailbox_access_allowed = config_stub.probe_functional_bar_access(2);
        if (!mailbox_access_allowed) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "configured BAR2 mailbox was not functionally accessible")
        end

        foreach (msix_bar_ids[index]) begin
            msix_only_error = new($sformatf(
                "msix_only_error_%0d_%0d_%0d_%0d_bar%0d",
                function_instance.function_key.host_id,
                function_instance.function_key.pf_id,
                function_instance.function_key.kind,
                function_instance.function_key.vf_id,
                msix_bar_ids[index]), expected_report_ids[index], UVM_ERROR);
            uvm_report_cb::add(null, msix_only_error);
            msix_functional_access_allowed =
                config_stub.probe_functional_bar_access(msix_bar_ids[index]);
            uvm_report_cb::delete(null, msix_only_error);
            if (msix_functional_access_allowed ||
                (msix_only_error.caught_count != 1)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "BAR%0d functional access was not rejected",
                    msix_bar_ids[index]))
            end
        end
    endtask

    // 构造同 domain 的重复 BDF 和 BAR overlap，验证 resolver 原子拒绝而不发布 snapshot。
    task assert_same_domain_collisions_rejected();
        virtio_test_device_builder collision_builder;
        dpu_function_cfg first_function;
        dpu_function_cfg clone_function;
        dpu_device_resolver resolver;
        dpu_device_snapshot rejected_snapshot;
        string why;

        collision_builder = virtio_test_device_builder::type_id::create(
            "same_bdf_collision_builder");
        void'(collision_builder.add_host_domain(
            0, 0, 16'h0200, 16'h02ff,
            64'h0000_0004_0000_0000, 64'h0000_0005_0000_0000));
        first_function = collision_builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, 16'h0220);
        clone_function = collision_builder.add_pf(
            0, 1, 0, DPU_ALLOC_PINNED, 16'h0220);
        pin_real_dut_bars(collision_builder, first_function,
            64'h0000_0004_0000_0000, 64'h0000_0004_0200_0000,
            64'h0000_0004_0201_0000);
        pin_real_dut_bars(collision_builder, clone_function,
            64'h0000_0004_0000_0000, 64'h0000_0004_0200_0000,
            64'h0000_0004_0201_0000);
        collision_builder.select_af(first_function);
        resolver = dpu_device_resolver::type_id::create(
            "same_bdf_collision_resolver");
        if (resolver.resolve(
                collision_builder.device_cfg, rejected_snapshot, why) ||
            (rejected_snapshot != null) ||
            !string_contains(why, "same-domain duplicate BDF")) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "same-domain BDF clone was not rejected atomically: %s", why))
        end

        collision_builder = virtio_test_device_builder::type_id::create(
            "same_bar_collision_builder");
        void'(collision_builder.add_host_domain(
            0, 0, 16'h0200, 16'h02ff,
            64'h0000_0004_0000_0000, 64'h0000_0005_0000_0000));
        first_function = collision_builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, 16'h0220);
        clone_function = collision_builder.add_pf(
            0, 1, 0, DPU_ALLOC_PINNED, 16'h0221);
        pin_real_dut_bars(collision_builder, first_function,
            64'h0000_0004_0000_0000, 64'h0000_0004_0200_0000,
            64'h0000_0004_0201_0000);
        pin_real_dut_bars(collision_builder, clone_function,
            64'h0000_0004_0000_0000, 64'h0000_0004_0200_0000,
            64'h0000_0004_0201_0000);
        collision_builder.select_af(first_function);
        resolver = dpu_device_resolver::type_id::create(
            "same_bar_collision_resolver");
        rejected_snapshot = null;
        why = "";
        if (resolver.resolve(
                collision_builder.device_cfg, rejected_snapshot, why) ||
            (rejected_snapshot != null) ||
            !string_contains(why, "same-domain BAR overlap")) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "same-domain BAR clone was not rejected atomically: %s", why))
        end
    endtask

    // 验证 snapshot 的 canonical Function 顺序、BDF 正向/反向查询、DMA identity 和 BAR 反查。
    task assert_snapshot_order_and_reverse_lookup();
        dpu_function_key_t expected_keys[$];
        dpu_function_key_t actual_keys[$];
        bit [15:0] expected_bdfs[$];
        dpu_pcie_function_id_t pcie_id;
        dpu_function_key_t reverse_key;
        dpu_bar_pair_lease_t bar;
        dpu_bar_pair_lease_t instance_bar;
        dpu_bar_address_match_t match;
        string why;

        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_PF, 0, 16'h0100);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 0, 16'h0101);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 1, 16'h0102);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 2, 16'h0103);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 3, 16'h0104);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 4, 16'h0105);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 5, 16'h0106);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 6, 16'h0107);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 7, 16'h0108);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 8, 16'h0109);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 9, 16'h010a);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 10, 16'h010b);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 11, 16'h010c);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 12, 16'h010d);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 13, 16'h010e);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 14, 16'h010f);
        append_expected_function(expected_keys, expected_bdfs, 0, 0, DPU_FUNCTION_VF, 15, 16'h0110);
        append_expected_function(expected_keys, expected_bdfs, 0, 1, DPU_FUNCTION_PF, 0, 16'h0111);
        append_expected_function(expected_keys, expected_bdfs, 0, 1, DPU_FUNCTION_VF, 0, 16'h0112);
        append_expected_function(expected_keys, expected_bdfs, 0, 1, DPU_FUNCTION_VF, 1, 16'h0113);
        append_expected_function(expected_keys, expected_bdfs, 1, 0, DPU_FUNCTION_PF, 0, 16'h0100);
        append_expected_function(expected_keys, expected_bdfs, 1, 0, DPU_FUNCTION_VF, 0, 16'h0101);
        append_expected_function(expected_keys, expected_bdfs, 1, 0, DPU_FUNCTION_VF, 1, 16'h0102);
        append_expected_function(expected_keys, expected_bdfs, 1, 0, DPU_FUNCTION_VF, 2, 16'h0103);
        append_expected_function(expected_keys, expected_bdfs, 1, 1, DPU_FUNCTION_PF, 0, 16'h0104);
        append_expected_function(expected_keys, expected_bdfs, 1, 1, DPU_FUNCTION_VF, 0, 16'h0105);

        device_snapshot.list_functions(actual_keys);
        if (actual_keys.size() != expected_keys.size()) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "snapshot listed %0d functions, expected %0d",
                actual_keys.size(), expected_keys.size()))
        end
        foreach (expected_keys[index]) begin
            if (!dpu_same_function_key(actual_keys[index], expected_keys[index])) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "canonical function order mismatch at index %0d: actual=%s expected=%s",
                    index, dpu_function_key_name(actual_keys[index]),
                    dpu_function_key_name(expected_keys[index])))
            end
            if (!device_snapshot.get_pcie_id(expected_keys[index], pcie_id, why)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "AUTO mapping missing at canonical index %0d: %s", index, why))
            end
            if (pcie_id.bdf != expected_bdfs[index]) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "AUTO BDF mismatch at index %0d: actual=0x%04h expected=0x%04h",
                    index, pcie_id.bdf, expected_bdfs[index]))
            end
            if (!device_snapshot.find_function(pcie_id, reverse_key, why)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "reverse BDF lookup missing at canonical index %0d: %s",
                    index, why))
            end
            if (!dpu_same_function_key(reverse_key, expected_keys[index])) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "reverse BDF lookup mismatch at index %0d: actual=%s expected=%s",
                    index, dpu_function_key_name(reverse_key),
                    dpu_function_key_name(expected_keys[index])))
            end
            foreach (env.function_instances[function_index]) begin
                if (dpu_same_function_key(
                        env.function_instances[function_index].function_key,
                        expected_keys[index]) &&
                    ((env.function_instances[function_index].bdf != pcie_id.bdf) ||
                     !env.function_instances[function_index].pcie_id_valid ||
                     !dpu_same_domain_key(
                         env.function_instances[function_index].pcie_id.domain,
                         pcie_id.domain) ||
                     (env.function_instances[function_index].vq_mgr.host_id !=
                         pcie_id.domain.host_id) ||
                     (env.function_instances[function_index].vq_mgr.bdf !=
                         pcie_id.bdf) ||
                     (env.function_instances[function_index].dataplane.tx_engine.host_id !=
                         pcie_id.domain.host_id) ||
                     (env.function_instances[function_index].dataplane.rx_engine.host_id !=
                         pcie_id.domain.host_id))) begin
                    `uvm_fatal("FABRIC_RESOURCE",
                        "VIO function DMA identity differs from frozen snapshot")
                end
            end
            foreach (env.function_instances[function_index]) begin
                if (!dpu_same_function_key(
                        env.function_instances[function_index].function_key,
                        expected_keys[index]))
                    continue;
                foreach (env.function_instances[function_index].bar_pairs[bar_index]) begin
                    instance_bar =
                        env.function_instances[function_index].bar_pairs[bar_index];
                    if (!device_snapshot.get_bar(
                            expected_keys[index], instance_bar.role, bar, why) ||
                        (bar.role != instance_bar.role) ||
                        (bar.even_bar_id != instance_bar.even_bar_id) ||
                        (bar.base != instance_bar.base) ||
                        (bar.size != instance_bar.size) ||
                        !device_snapshot.resolve_bar_address(
                            pcie_id.domain, bar.base + 64'h20, match, why) ||
                        !dpu_same_function_key(match.function_key,
                                               expected_keys[index]) ||
                        (match.role != bar.role) ||
                        (match.bar_base != bar.base) ||
                        (match.bar_size != bar.size) ||
                        (match.offset != 64'h20)) begin
                        `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                            "snapshot BAR forward/reverse mismatch at index %0d: %s",
                            index, why))
                    end
                end
            end
        end
    endtask

    // 验证不同 Host/domain 可以复用数值 BDF/BAR，同时 resolve 仍路由到各自 Function。
    task assert_independent_domain_numeric_reuse();
        dpu_function_key_t host0_key;
        dpu_function_key_t host1_key;
        dpu_pcie_function_id_t host0_pcie;
        dpu_pcie_function_id_t host1_pcie;
        dpu_bar_pair_lease_t host0_bar;
        dpu_bar_pair_lease_t host1_bar;
        dpu_bar_address_match_t match;
        dpu_bar_role_e roles[3];
        string why;

        roles[0] = DPU_BAR_DEVICE_MEMORY;
        roles[1] = DPU_BAR_MAILBOX;
        roles[2] = DPU_BAR_MSIX;
        host0_key = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        host1_key = make_function_key(1, 0, DPU_FUNCTION_PF, 0);
        if (!device_snapshot.get_pcie_id(host0_key, host0_pcie, why) ||
            !device_snapshot.get_pcie_id(host1_key, host1_pcie, why) ||
            (host0_pcie.bdf != host1_pcie.bdf) ||
            dpu_same_domain_key(host0_pcie.domain, host1_pcie.domain)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "independent domains did not reuse the same numeric BDF: %s", why))
        end
        foreach (roles[index]) begin
            if (!device_snapshot.get_bar(
                    host0_key, roles[index], host0_bar, why) ||
                !device_snapshot.get_bar(
                    host1_key, roles[index], host1_bar, why) ||
                (host0_bar.base != host1_bar.base) ||
                (host0_bar.size != host1_bar.size) ||
                !device_snapshot.resolve_bar_address(
                    host0_pcie.domain, host0_bar.base, match, why) ||
                !dpu_same_function_key(match.function_key, host0_key) ||
                (match.role != roles[index]) ||
                (match.bar_base != host0_bar.base) ||
                (match.bar_size != host0_bar.size) ||
                !device_snapshot.resolve_bar_address(
                    host1_pcie.domain, host1_bar.base, match, why) ||
                !dpu_same_function_key(match.function_key, host1_key) ||
                (match.role != roles[index]) ||
                (match.bar_base != host1_bar.base) ||
                (match.bar_size != host1_bar.size)) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    {"independent domains did not reuse and route BAR role ",
                     "%0d: %s"}, roles[index], why))
            end
        end
    endtask

    // 验证已绑定 Function 拒绝第二份 snapshot/service，且原有 BDF/BAR/transport 不被改变。
    // Break caught: a function already owned by one frozen device snapshot
    // accepts the same service identity from a second snapshot and silently
    // replaces its BDF/BAR transport placement.
    task assert_snapshot_function_binding_is_immutable();
        virtio_test_device_builder forged_builder;
        dpu_function_cfg forged_pf;
        dpu_configuration_resolver resolver;
        dpu_device_snapshot forged_snapshot;
        dpu_resource_snapshot forged_resource_snapshot;
        dpu_placement_diagnostic diagnostic;
        dpu_function_key_t forged_devices[$];
        virtio_function_instance function_view;
        virtio_expected_bar_report_catcher catcher;
        dpu_bar_pair_lease_t original_bars[$];
        bit [15:0] original_bdf;
        bit configuration_succeeded;
        bit bars_preserved;
        string why;

        function_view = env.pf_instances[0].pf_function;
        original_bdf = function_view.bdf;
        original_bars = function_view.bar_pairs;
        if (!function_view.configure_from_service(
                device_snapshot, resource_snapshot,
                function_view.service_key, function_view.resource_manager)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "idempotent snapshot/service function binding was rejected")
        end

        forged_builder = virtio_test_device_builder::type_id::create(
            "forged_function_binding_builder");
        void'(forged_builder.add_host_domain(
            0, 0, 16'h0300, 16'h03ff,
            64'h0000_0006_0000_0000, 64'h0000_0007_0000_0000));
        forged_pf = forged_builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, 16'h0330);
        pin_real_dut_bars(forged_builder, forged_pf,
            64'h0000_0006_0000_0000, 64'h0000_0006_0200_0000,
            64'h0000_0006_0201_0000);
        void'(forged_builder.allow_vio_service(forged_pf));
        forged_devices.push_back(forged_pf.key);
        void'(forged_builder.add_fixed_vio_request(
            0, forged_devices, 1));
        forged_builder.select_af(forged_pf);
        resolver = dpu_configuration_resolver::type_id::create(
            "forged_function_binding_resolver");
        if (!resolver.resolve(
                forged_builder.device_cfg, forged_builder.placement_cfg,
                forged_snapshot, forged_resource_snapshot, diagnostic)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not resolve forged function snapshot: %s",
                diagnostic.message))
        end

        catcher = new("snapshot_function_reassignment_catcher",
            "FUNCTION_INSTANCE", UVM_FATAL);
        uvm_report_cb::add(null, catcher);
        configuration_succeeded = function_view.configure_from_service(
            forged_snapshot, forged_resource_snapshot,
            function_view.service_key,
            function_view.resource_manager);
        uvm_report_cb::delete(null, catcher);

        bars_preserved =
            (function_view.bar_pairs.size() == original_bars.size());
        if (bars_preserved) begin
            foreach (original_bars[index]) begin
                if ((function_view.bar_pairs[index].role !=
                     original_bars[index].role) ||
                    (function_view.bar_pairs[index].even_bar_id !=
                     original_bars[index].even_bar_id) ||
                    (function_view.bar_pairs[index].base !=
                     original_bars[index].base) ||
                    (function_view.bar_pairs[index].size !=
                     original_bars[index].size)) begin
                    bars_preserved = 0;
                end
            end
        end
        if (configuration_succeeded || (catcher.caught_count != 1) ||
            (catcher.last_message !=
             {"function configuration ownership cannot be reassigned to a ",
              "different device snapshot"}) ||
            (function_view.bdf != original_bdf) || !bars_preserved ||
            (function_view.transport.bdf != original_bdf) ||
            (function_view.transport.notify_mgr.function_bdf != original_bdf) ||
            (function_view.transport.bar.requester_id != original_bdf) ||
            (function_view.vq_mgr.bdf != original_bdf)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "rejected snapshot reassignment changed function placement")
        end
    endtask

    // 设计意图：顶层快照已经同时包含 Host 0/1 的 segment 0；这里直接调用
    // queue_work 的真实 binder，证明相同 segment 数值不会把两个 Host 折叠成
    // 同一个 PCIe Root，同时证明 ring 所需 Host memory 句柄不会跨 Host 复用。
    // 功能：验证 binder 的配置、PF/VF owner 映射、Host memory 映射及负向查询。
    // 输入：build_phase/run_phase 产生的冻结 device/resource snapshot；无显式参数。
    // 输出：断言全部通过时无返回值；任一身份、Root、memory 或错误路径不符合
    // 约定即通过 UVM_FATAL 终止测试。
    // 副作用与边界：仅创建两个独立 Host memory manager 并读取快照；不写 PCIe
    // 寄存器、不启动 queue engine，也不修改已有 virtio 环境的资源所有权。
    task assert_queue_binder_mapping();
        dpu_service_key_t services[$];
        dpu_function_key_t host0_pf0;
        dpu_function_key_t host1_pf0;
        dpu_function_key_t host0_vf0;
        dpu_function_key_t host1_vf0;
        string host0_service_name;
        string host1_service_name;
        string host0_vf_service_name;
        string host1_vf_service_name;
        gq_queue_owner_t host0_owner;
        gq_queue_owner_t host1_owner;
        gq_queue_owner_t host0_vf_owner;
        gq_queue_owner_t host1_vf_owner;
        host_mem_api host0_mem_api;
        host_mem_api host1_mem_api;
        string why;

        host0_pf0 = make_function_key(0, 0, DPU_FUNCTION_PF, 0);
        host1_pf0 = make_function_key(1, 0, DPU_FUNCTION_PF, 0);
        host0_vf0 = make_function_key(0, 0, DPU_FUNCTION_VF, 0);
        host1_vf0 = make_function_key(1, 0, DPU_FUNCTION_VF, 0);
        device_snapshot.list_services(DPU_SERVICE_VIO_NET, services);
        foreach (services[index]) begin
            if (dpu_same_function_key(services[index].function_key,
                                       host0_pf0))
                host0_service_name = dpu_service_key_name(services[index]);
            if (dpu_same_function_key(services[index].function_key,
                                       host1_pf0))
                host1_service_name = dpu_service_key_name(services[index]);
            if (dpu_same_function_key(services[index].function_key,
                                       host0_vf0))
                host0_vf_service_name = dpu_service_key_name(services[index]);
            if (dpu_same_function_key(services[index].function_key,
                                       host1_vf0))
                host1_vf_service_name = dpu_service_key_name(services[index]);
        end
        if ((host0_service_name.len() == 0) ||
            (host1_service_name.len() == 0) ||
            (host0_vf_service_name.len() == 0) ||
            (host1_vf_service_name.len() == 0)) begin
            `uvm_fatal("QUEUE_BINDER", $sformatf(
                "frozen snapshot lacks Host 0/1 PF0/VF0 VIO services: %0d services",
                services.size()))
        end

        binder_pool = host_mem_pool::type_id::create("binder_host_pool");
        if (!binder_pool.create_host(
                0, 64'h0000_1000_0000_0000,
                64'h0000_1000_001f_ffff) ||
            !binder_pool.create_host(
                1, 64'h0000_1000_0000_0000,
                64'h0000_1000_001f_ffff)) begin
            `uvm_fatal("QUEUE_BINDER",
                "could not construct independent Host 0/1 binder memory managers")
        end

        binder_mem_provider = virtio_queue_host_mem_provider_adapter::type_id::create(
            "queue_resource_mem_provider");
        binder_mem_provider.bind_pool(binder_pool);

        queue_binder = dpu_queue_resource_binder::type_id::create(
            "queue_resource_binder");
        if (!queue_binder.configure(
                device_snapshot, resource_snapshot, binder_mem_provider, why)) begin
            `uvm_fatal("QUEUE_BINDER", {"binder configure failed: ", why})
        end
        if (!queue_binder.resolve_queue_owner(
                host0_service_name, 0, host0_owner, why)) begin
            `uvm_fatal("QUEUE_BINDER", {"Host 0 owner resolution failed: ", why})
        end
        if (!queue_binder.resolve_queue_owner(
                host1_service_name, 0, host1_owner, why)) begin
            `uvm_fatal("QUEUE_BINDER", {"Host 1 owner resolution failed: ", why})
        end
        if (!queue_binder.resolve_queue_owner(
                host0_vf_service_name, 0, host0_vf_owner, why) ||
            !queue_binder.resolve_queue_owner(
                host1_vf_service_name, 0, host1_vf_owner, why)) begin
            `uvm_fatal("QUEUE_BINDER", {"VF owner resolution failed: ", why})
        end
        if (!host0_owner.valid || !host1_owner.valid ||
            (host0_owner.service_key.function_key.host_id != 0) ||
            (host1_owner.service_key.function_key.host_id != 1) ||
            (host0_owner.pcie_segment_id != 0) ||
            (host1_owner.pcie_segment_id != 0) ||
            (host0_owner.pcie_root_index == host1_owner.pcie_root_index) ||
            (host0_owner.bdf != host1_owner.bdf)) begin
            `uvm_fatal("QUEUE_BINDER", $sformatf(
                "same-segment multi-Host owner collision: h0 root=%0d bdf=0x%04h, h1 root=%0d bdf=0x%04h",
                host0_owner.pcie_root_index, host0_owner.bdf,
                host1_owner.pcie_root_index, host1_owner.bdf))
        end
        if (!host0_vf_owner.valid || !host1_vf_owner.valid ||
            (host0_vf_owner.service_key.function_key.kind != GQ_FUNCTION_VF) ||
            (host1_vf_owner.service_key.function_key.kind != GQ_FUNCTION_VF) ||
            (host0_vf_owner.service_key.function_key.vf_id != 0) ||
            (host1_vf_owner.service_key.function_key.vf_id != 0) ||
            (host0_vf_owner.pcie_root_index != host0_owner.pcie_root_index) ||
            (host1_vf_owner.pcie_root_index != host1_owner.pcie_root_index)) begin
            `uvm_fatal("QUEUE_BINDER", $sformatf(
                "VF owner identity/root mismatch: h0 kind=%0d vf=%0d root=%0d, h1 kind=%0d vf=%0d root=%0d",
                host0_vf_owner.service_key.function_key.kind,
                host0_vf_owner.service_key.function_key.vf_id,
                host0_vf_owner.pcie_root_index,
                host1_vf_owner.service_key.function_key.kind,
                host1_vf_owner.service_key.function_key.vf_id,
                host1_vf_owner.pcie_root_index))
        end
        if (!queue_binder.get_host_mem(0, host0_mem_api, why) ||
            !queue_binder.get_host_mem(1, host1_mem_api, why) ||
            (host0_mem_api == null) || (host1_mem_api == null) ||
            (host0_mem_api == host1_mem_api) ||
            (host0_mem_api.get_host_id() != 0) ||
            (host1_mem_api.get_host_id() != 1)) begin
            `uvm_fatal("QUEUE_BINDER",
                "binder returned an aliased or misidentified Host memory manager")
        end

        if (queue_binder.resolve_queue_owner(
                host0_service_name, 999, host0_owner, why) ||
            (why.len() == 0)) begin
            `uvm_fatal("QUEUE_BINDER",
                "unknown local qpair was accepted by binder")
        end
        if (queue_binder.resolve_queue_owner(
                "h99.pf0.k0.vf0.svc0.i0", 0, host0_owner, why) ||
            (why.len() == 0)) begin
            `uvm_fatal("QUEUE_BINDER",
                "unknown service was accepted by binder")
        end
    endtask

    // 创建双 Host、多 PF/VF 的 authoring 配置，发布 device/resource snapshot 及业务 env。
    virtual function void build_phase(uvm_phase phase);
        dpu_function_cfg selected_af;
        dpu_function_cfg reused_domain_pf;

        super.build_phase(phase);
        device_builder = virtio_test_device_builder::type_id::create(
            "device_builder");
        void'(device_builder.add_host_domain(
            0, 0, 16'h0100, 16'h01ff,
            64'h0000_0002_0000_0000, 64'h0000_0003_0000_0000));
        void'(device_builder.add_host_domain(
            1, 0, 16'h0100, 16'h01ff,
            64'h0000_0002_0000_0000, 64'h0000_0003_0000_0000));

        selected_af = device_builder.add_pf(
            0, 0, 0, DPU_ALLOC_PINNED, 16'h0100);
        pin_real_dut_bars(device_builder, selected_af,
            64'h0000_0002_0000_0000, 64'h0000_0002_0200_0000,
            64'h0000_0002_0201_0000);
        selected_af.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        void'(author_vio_function(device_builder.add_vf(0, 0, 0, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 1, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 2, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 3, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 4, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 5, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 6, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 7, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 8, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 9, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 10, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 11, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 12, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 13, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 14, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 0, 15, 0)));
        void'(author_vio_function(device_builder.add_pf(0, 1, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 1, 0, 0)));
        void'(author_vio_function(device_builder.add_vf(0, 1, 1, 0)));
        reused_domain_pf = device_builder.add_pf(
            1, 0, 0, DPU_ALLOC_PINNED, 16'h0100);
        pin_real_dut_bars(device_builder, reused_domain_pf,
            64'h0000_0002_0000_0000, 64'h0000_0002_0200_0000,
            64'h0000_0002_0201_0000);
        reused_domain_pf.eligible_service_kinds.push_back(DPU_SERVICE_VIO_NET);
        void'(author_vio_function(device_builder.add_vf(1, 0, 0, 0)));
        void'(author_vio_function(device_builder.add_vf(1, 0, 1, 0)));
        void'(author_vio_function(device_builder.add_vf(1, 0, 2, 0)));
        void'(author_vio_function(device_builder.add_pf(1, 1, 0)));
        void'(author_vio_function(device_builder.add_vf(1, 1, 0, 0)));
        device_builder.select_af(selected_af);

        device_cfg = device_builder.make_env_config();
        author_snapshot_qpair_placement(selected_af.key);
        cfg = virtio_net_env_config::type_id::create("cfg");
        cfg.default_num_pairs = 1;
        uvm_config_db#(dpu_device_env_config)::set(
            this, "device_env", "cfg", device_cfg);
        device_env = dpu_device_env::type_id::create("device_env", this);
        uvm_config_db#(virtio_net_env_config)::set(
            this, "device_env.env", "cfg", cfg);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "device_env.env.*.driver_agent", "is_active", UVM_PASSIVE);
        env = virtio_net_env::type_id::create("env", device_env);
        fabric_cfg_tlp_seqr = new("fabric_cfg_tlp_seqr", this);
        fabric_cfg_tlp_capture = virtio_fabric_cfg_tlp_capture_driver::type_id::create(
            "fabric_cfg_tlp_capture", this);
    endfunction

    // 将 TLP capture driver 接到配置 sequencer；无 PCIe 业务数据面连接副作用。
    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        fabric_cfg_tlp_capture.seq_item_port.connect(
            fabric_cfg_tlp_seqr.seq_item_export
        );
    endfunction

    // 按“非法输入→真实 TLP→冻结 snapshot→binder”顺序执行全部 Fabric/Host 隔离断言。
    virtual task run_phase(uvm_phase phase);
        int unsigned global_qpair_ids[$];
        bar_range_t all_bars[$];

        phase.raise_objection(this);

        // Run the BAR hardening cases before topology traffic.  The first
        // group validates rejected Fabric input without issuing config I/O;
        // the second proves the actual base accessor serializes all six
        // payload-carrying Config Write Type-0 transactions.
        assert_fabric_bar_hardening_rejections();
        assert_fabric_bar_config_tlp_serialization();

        device_snapshot = device_env.get_snapshot();
        if ((device_snapshot == null) || !device_snapshot.is_frozen())
            `uvm_fatal("FABRIC_RESOURCE", "device environment did not publish a frozen snapshot")
        resource_snapshot = device_env.get_resource_snapshot();
        if ((resource_snapshot == null) || !resource_snapshot.is_frozen())
            `uvm_fatal("FABRIC_RESOURCE", "device environment did not publish a frozen resource snapshot")
        assert_same_domain_collisions_rejected();
        assert_snapshot_order_and_reverse_lookup();
        assert_independent_domain_numeric_reuse();
        assert_snapshot_function_binding_is_immutable();
        assert_queue_binder_mapping();

        if ((env.pf_instances.size() != 4) ||
            (env.vf_instances.size() != 22)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected 4 PFs and 22 VFs, received %0d and %0d",
                env.pf_instances.size(), env.vf_instances.size()))
        end

        assert_sparse_snapshot_mapping(
            env.pf_instances[0].pf_function, "immediate configuration");

        foreach (env.pf_instances[pf_index]) begin
            if (env.pf_instances[pf_index].pf_function.transport.is_vf) begin
                `uvm_fatal("FABRIC_RESOURCE", "PF function was modeled as a VF")
            end
            assert_bar_layout(env.pf_instances[pf_index].pf_function);
            assert_unique_bars(env.pf_instances[pf_index].pf_function, all_bars);
            assert_unique_qpair(env.pf_instances[pf_index].pf_function,
                                global_qpair_ids);
            discover_fabric_function(env.pf_instances[pf_index].pf_function);
            if (pf_index == 0)
                assert_sparse_snapshot_mapping(
                    env.pf_instances[pf_index].pf_function,
                    "capability discovery");

            foreach (env.pf_instances[pf_index].vf_functions[vf_index]) begin
                if (!env.pf_instances[pf_index].vf_functions[vf_index].transport.is_vf) begin
                    `uvm_fatal("FABRIC_RESOURCE", "VF function lost its VF identity")
                end
                assert_bar_layout(env.pf_instances[pf_index].vf_functions[vf_index]);
                assert_unique_bars(env.pf_instances[pf_index].vf_functions[vf_index],
                                   all_bars);
                assert_unique_qpair(env.pf_instances[pf_index].vf_functions[vf_index],
                                    global_qpair_ids);
                discover_fabric_function(env.pf_instances[pf_index].vf_functions[vf_index]);
            end
        end

        if (global_qpair_ids.size() != 26) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected one global qpair ID for 26 functions, received %0d",
                global_qpair_ids.size()))
        end

        // FLR owns runtime cleanup only; immutable placement survives reset.
        env.pf_instances[0].pf_function.on_flr();
        assert_sparse_snapshot_mapping(
            env.pf_instances[0].pf_function, "FLR");
        env.pf_instances[0].pf_function.reinit_after_flr(
            env.pf_instances[0].pf_function.drv_cfg);
        assert_sparse_snapshot_mapping(
            env.pf_instances[0].pf_function, "reinit_after_flr");
        discover_fabric_function(env.pf_instances[0].pf_function);
        assert_sparse_snapshot_mapping(
            env.pf_instances[0].pf_function, "reinitialization");

        // Shutdown is also runtime-only and cannot unregister placement.
        env.pf_instances[0].pf_function.shutdown();
        assert_sparse_snapshot_mapping(
            env.pf_instances[0].pf_function, "shutdown");

        phase.drop_objection(this);
    endtask
endclass : virtio_fabric_resource_test

`endif // VIRTIO_FABRIC_RESOURCE_TEST_SV
