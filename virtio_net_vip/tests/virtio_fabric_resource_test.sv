`ifndef VIRTIO_FABRIC_RESOURCE_TEST_SV
`define VIRTIO_FABRIC_RESOURCE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

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

    function new(string name = "virtio_fabric_cfg_stub_accessor");
        super.new(name);
        config_write_count = 0;
        discovery_started_before_bar_programming = 0;
    endfunction

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
            12'h054: data = 32'h0000_0000;
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
endclass : virtio_fabric_cfg_stub_accessor

// This deliberately small UVM driver observes requests issued through the
// base accessor's real config_write() path.  Unlike the config-space stub
// above, it cannot be reached by overriding config_write(), so it catches a
// regression that makes BAR programming in-memory-only or drops TLP payload.
class virtio_fabric_cfg_tlp_capture_driver extends uvm_driver #(pcie_tl_tlp);
    `uvm_component_utils(virtio_fabric_cfg_tlp_capture_driver)

    pcie_tl_tlp captured_tlps[$];

    function new(string name, uvm_component parent = null);
        super.new(name, parent);
    endfunction

    function void clear();
        captured_tlps.delete();
    endfunction

    virtual task run_phase(uvm_phase phase);
        pcie_tl_tlp tlp;

        forever begin
            seq_item_port.get_next_item(tlp);
            captured_tlps.push_back(tlp);
            seq_item_port.item_done();
        end
    endtask
endclass : virtio_fabric_cfg_tlp_capture_driver

// Temporarily demotes only the deliberate reserved-BAR negative access.  It
// is registered immediately around that access and then removed, so discovery
// cannot be made green by a persistent global report override.
class virtio_expected_bar_reserved_catcher extends uvm_report_catcher;
    int unsigned caught_count;

    function new(string name = "expected_bar_reserved_catcher");
        super.new(name);
        caught_count = 0;
    endfunction

    function action_e catch();
        if ((get_id() == "BAR_RESERVED") && (get_severity() == UVM_ERROR)) begin
            caught_count++;
            set_severity(UVM_INFO);
        end
        return THROW;
    endfunction
endclass : virtio_expected_bar_reserved_catcher

// Scoped negative-path catcher.  Production failures remain fatal outside
// these narrow test calls; each helper also verifies that its expected report
// was actually produced.
class virtio_expected_bar_report_catcher extends uvm_report_catcher;
    string expected_id;
    uvm_severity expected_severity;
    int unsigned caught_count;
    string last_message;

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
        bit [63:0] base;
        bit [63:0] size;
    } bar_range_t;

    virtio_net_env_config cfg;
    virtio_net_env        env;
    virtio_vf_instance    compatibility_vf;
    uvm_sequencer #(pcie_tl_tlp) fabric_cfg_tlp_seqr;
    virtio_fabric_cfg_tlp_capture_driver fabric_cfg_tlp_capture;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    protected function bit ranges_overlap(
        input bit [63:0] lhs_base,
        input bit [63:0] lhs_size,
        input bit [63:0] rhs_base,
        input bit [63:0] rhs_size
    );
        return (lhs_base < (rhs_base + rhs_size)) &&
               (rhs_base < (lhs_base + lhs_size));
    endfunction

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
            DPU_BAR_FUNCTION_DEVICE, 0, 64'h0001_0000_1000_0000,
            64'h0000_0000_0010_0000));
        bars.push_back(make_fabric_bar_pair(
            DPU_BAR_RESERVED, 2, 64'h0001_0000_2000_0000,
            64'h0000_0000_0001_0000));
    endfunction

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
            DPU_BAR_RESERVED, 6, 64'h0001_0000_4000_0000,
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

    task assert_bar_layout(input virtio_function_instance function_instance);
        dpu_bar_pair_lease_t bars[$];
        bit [63:0] device_size;
        bit [63:0] reserved_size;
        bit [63:0] msix_size;

        bars = function_instance.bar_pairs;
        if (function_instance.function_kind == DPU_FUNCTION_PF) begin
            device_size = 64'h0000_0000_0200_0000;
            reserved_size = 64'h0000_0000_0001_0000;
            msix_size = 64'h0000_0000_0001_0000;
        end
        else begin
            device_size = 64'h0000_0000_0000_4000;
            reserved_size = 64'h0000_0000_0000_4000;
            msix_size = 64'h0000_0000_0000_8000;
        end

        if ((bars.size() != 3) ||
            (bars[0].role != DPU_BAR_FUNCTION_DEVICE) ||
            (bars[0].even_bar_id != 0) || (bars[0].size != device_size) ||
            (bars[1].role != DPU_BAR_RESERVED) ||
            (bars[1].even_bar_id != 2) || (bars[1].size != reserved_size) ||
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
            // BAR2/3 is programmed as a Fabric reservation, but the accessor
            // must reject functional use of it.
            (function_instance.transport.bar.bar_base[2] != bars[1].base) ||
            (function_instance.transport.bar.bar_size[2] != bars[1].size) ||
            (function_instance.transport.bar.bar_base[3] != '0) ||
            (function_instance.transport.bar.bar_size[3] != '0) ||
            (function_instance.transport.bar.bar_base[4] != bars[2].base) ||
            (function_instance.transport.bar.bar_size[4] != bars[2].size) ||
            !function_instance.is_reserved_bar(2) ||
            !function_instance.is_reserved_bar(3)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "BAR roles were not reflected in the transport binding")
        end
    endtask

    task assert_unique_bars(
        input virtio_function_instance function_instance,
        ref bar_range_t all_bars[$]
    );
        bar_range_t current;

        foreach (function_instance.bar_pairs[index]) begin
            current.base = function_instance.bar_pairs[index].base;
            current.size = function_instance.bar_pairs[index].size;
            foreach (all_bars[prior]) begin
                if (ranges_overlap(current.base, current.size,
                                   all_bars[prior].base, all_bars[prior].size)) begin
                    `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                        "BAR%0d overlaps an already active function BAR",
                        function_instance.bar_pairs[index].even_bar_id))
                end
            end
            all_bars.push_back(current);
        end
    endtask

    task assert_unique_qpair(
        input virtio_function_instance function_instance,
        ref int unsigned global_rx_qids[$]
    );
        int unsigned global_rx_qid;
        string why;

        if (!function_instance.resource_client.reserve_qpairs(0, 1, why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not reserve Fabric QP lease: %s", why))
        end
        if (!function_instance.resource_client.local_qid_to_global_qid(
            0, global_rx_qid
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", "local RX queue ID did not map globally")
        end
        foreach (global_rx_qids[index]) begin
            if (global_rx_qids[index] == global_rx_qid) begin
                `uvm_fatal("FABRIC_RESOURCE",
                    "distinct functions share a global RX queue ID")
            end
        end
        global_rx_qids.push_back(global_rx_qid);
    endtask

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

    task discover_fabric_function(input virtio_function_instance function_instance);
        virtio_fabric_cfg_stub_accessor config_stub;
        virtio_expected_bar_reserved_catcher expected_bar_error;
        bit [31:0] reserved_data;
        int unsigned reserved_errors;

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

        reserved_errors = config_stub.get_reserved_bar_access_error_count();
        if (reserved_errors != 0) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "Fabric discovery made %0d functional access(es) to BAR2/3",
                reserved_errors))
        end
        // Demote only the deliberate negative access.  A discovery-time
        // BAR2/3 access above remains visible and fatal.
        expected_bar_error = new($sformatf("expected_bar_error_%0d_%0d_%0d_%0d",
            function_instance.function_key.host_id,
            function_instance.function_key.pf_id,
            function_instance.function_key.kind,
            function_instance.function_key.vf_id));
        uvm_report_cb::add(null, expected_bar_error);
        config_stub.read_reg(2, 32'h0, 4, reserved_data);
        uvm_report_cb::delete(null, expected_bar_error);
        if ((reserved_data != '0) ||
            (expected_bar_error.caught_count != 1) ||
            (config_stub.get_reserved_bar_access_error_count() !=
             (reserved_errors + 1))) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "BAR2/3 access did not produce a reserved-BAR monitor error")
        end
    endtask

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);

        cfg = virtio_net_env_config::type_id::create("cfg");
        cfg.num_hosts = 2;
        cfg.num_pfs_per_host = new[cfg.num_hosts];
        cfg.num_pfs_per_host[0] = 2;
        cfg.num_pfs_per_host[1] = 2;
        cfg.num_vfs_per_pf = new[cfg.num_hosts];
        foreach (cfg.num_vfs_per_pf[host_id]) begin
            cfg.num_vfs_per_pf[host_id] = new[cfg.num_pfs_per_host[host_id]];
        end
        cfg.num_vfs_per_pf[0][0] = DPU_MAX_VFS_PER_PF;
        cfg.num_vfs_per_pf[0][1] = 2;
        cfg.num_vfs_per_pf[1][0] = 3;
        cfg.num_vfs_per_pf[1][1] = 1;

        uvm_config_db#(virtio_net_env_config)::set(this, "env", "cfg", cfg);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "env.*.driver_agent", "is_active", UVM_PASSIVE);
        uvm_config_db#(uvm_active_passive_enum)::set(
            this, "compatibility_vf.driver_agent", "is_active", UVM_PASSIVE);
        env = virtio_net_env::type_id::create("env", this);
        compatibility_vf = virtio_vf_instance::type_id::create(
            "compatibility_vf", this
        );
        fabric_cfg_tlp_seqr = new("fabric_cfg_tlp_seqr", this);
        fabric_cfg_tlp_capture = virtio_fabric_cfg_tlp_capture_driver::type_id::create(
            "fabric_cfg_tlp_capture", this
        );
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        fabric_cfg_tlp_capture.seq_item_port.connect(
            fabric_cfg_tlp_seqr.seq_item_export
        );
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned expected_vfs[];
        int unsigned global_rx_qids[$];
        bit [15:0] all_bdfs[$];
        bar_range_t all_bars[$];
        int unsigned stale_global_rx_qid;
        string why;
        virtio_function_instance function_view;
        dpu_function_key_t compatibility_vf_key;
        dpu_function_key_t invalid_pf_key;
        dpu_bar_pair_lease_t no_bars[$];

        phase.raise_objection(this);

        // Run the BAR hardening cases before topology traffic.  The first
        // group validates rejected Fabric input without issuing config I/O;
        // the second proves the actual base accessor serializes all six
        // payload-carrying Config Write Type-0 transactions.
        assert_fabric_bar_hardening_rejections();
        assert_fabric_bar_config_tlp_serialization();

        // A legacy VF wrapper must remain substitutable for a generic
        // function while retaining immutable VF identity.  The assignment is
        // intentionally compile-time coverage for the inheritance direction.
        function_view = compatibility_vf;
        if (function_view.function_kind != DPU_FUNCTION_VF) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "compatibility virtio_vf_instance did not force VF identity")
        end

        // A severity override used by a negative-path test must not let the
        // VF wrapper fall through and reconfigure itself as a PF.
        compatibility_vf_key.host_id = 0;
        compatibility_vf_key.pf_id = 0;
        compatibility_vf_key.kind = DPU_FUNCTION_VF;
        compatibility_vf_key.vf_id = 0;
        compatibility_vf.configure_function(
            DPU_FUNCTION_VF, compatibility_vf_key, 16'h0400, no_bars
        );
        invalid_pf_key = compatibility_vf_key;
        invalid_pf_key.kind = DPU_FUNCTION_PF;
        invalid_pf_key.vf_id = 0;
        compatibility_vf.set_report_severity_id_override(
            UVM_FATAL, "VF_INSTANCE", UVM_INFO
        );
        compatibility_vf.configure_function(
            DPU_FUNCTION_PF, invalid_pf_key, 16'h0401, no_bars
        );
        if ((compatibility_vf.function_kind != DPU_FUNCTION_VF) ||
            !compatibility_vf.transport.is_vf ||
            (compatibility_vf.function_key.kind != DPU_FUNCTION_VF)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "compatibility VF accepted a PF function configuration")
        end

        expected_vfs = new[4];
        expected_vfs[0] = DPU_MAX_VFS_PER_PF;
        expected_vfs[1] = 2;
        expected_vfs[2] = 3;
        expected_vfs[3] = 1;

        if ((env.pf_instances.size() != 4) ||
            (env.vf_instances.size() != 22)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected 4 PFs and 22 VFs, received %0d and %0d",
                env.pf_instances.size(), env.vf_instances.size()))
        end

        // A generic function must not be able to take its transport role
        // from one kind while Fabric ownership comes from a different key.
        // Override the expected rejection so the test can verify state was
        // left unchanged without ending this negative-path regression.
        function_view = env.pf_instances[0].pf_function;
        function_view.set_report_severity_id_override(
            UVM_ERROR, "FUNCTION_INSTANCE", UVM_INFO
        );
        function_view.configure_function(
            DPU_FUNCTION_VF, function_view.function_key, function_view.bdf,
            function_view.bar_pairs, function_view.resource_manager
        );
        if ((function_view.function_kind != DPU_FUNCTION_PF) ||
            function_view.transport.is_vf ||
            (function_view.function_key.kind != DPU_FUNCTION_PF)) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "function accepted a transport kind that disagrees with its Fabric key")
        end

        foreach (env.pf_instances[pf_index]) begin
            if ((env.pf_instances[pf_index].host_id != (pf_index / 2)) ||
                (env.pf_instances[pf_index].pf_id != (pf_index % 2))) begin
                `uvm_fatal("FABRIC_RESOURCE",
                    "flattened PF array lost its host/PF coordinates")
            end
            if (env.pf_instances[pf_index].num_vfs != expected_vfs[pf_index]) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "PF %0d VF count does not match the requested topology", pf_index))
            end
            if (env.pf_instances[pf_index].pf_function.transport.is_vf) begin
                `uvm_fatal("FABRIC_RESOURCE", "PF function was modeled as a VF")
            end
            foreach (all_bdfs[known_bdf]) begin
                if (all_bdfs[known_bdf] == env.pf_instances[pf_index].pf_bdf)
                    `uvm_fatal("FABRIC_RESOURCE", "PF BDF is not unique")
            end
            all_bdfs.push_back(env.pf_instances[pf_index].pf_bdf);
            assert_bar_layout(env.pf_instances[pf_index].pf_function);
            assert_unique_bars(env.pf_instances[pf_index].pf_function, all_bars);
            if (env.pf_instances[pf_index].pf_function.resource_client.reserve_qpairs(
                0, 1, why
            )) begin
                `uvm_fatal("FABRIC_RESOURCE",
                    "Fabric QP lease was accepted before capability discovery")
            end
            discover_fabric_function(env.pf_instances[pf_index].pf_function);
            assert_unique_qpair(env.pf_instances[pf_index].pf_function, global_rx_qids);

            foreach (env.pf_instances[pf_index].vf_functions[vf_index]) begin
                if (!env.pf_instances[pf_index].vf_functions[vf_index].transport.is_vf) begin
                    `uvm_fatal("FABRIC_RESOURCE", "VF function lost its VF identity")
                end
                foreach (all_bdfs[known_bdf]) begin
                    if (all_bdfs[known_bdf] ==
                        env.pf_instances[pf_index].vf_bdfs[vf_index]) begin
                        `uvm_fatal("FABRIC_RESOURCE", "VF BDF is not unique")
                    end
                end
                all_bdfs.push_back(env.pf_instances[pf_index].vf_bdfs[vf_index]);
                assert_bar_layout(env.pf_instances[pf_index].vf_functions[vf_index]);
                assert_unique_bars(env.pf_instances[pf_index].vf_functions[vf_index],
                                   all_bars);
                if (env.pf_instances[pf_index].vf_functions[vf_index].resource_client.reserve_qpairs(
                    0, 1, why
                )) begin
                    `uvm_fatal("FABRIC_RESOURCE",
                        "Fabric QP lease was accepted before capability discovery")
                end
                discover_fabric_function(env.pf_instances[pf_index].vf_functions[vf_index]);
                assert_unique_qpair(env.pf_instances[pf_index].vf_functions[vf_index],
                                    global_rx_qids);
            end
        end

        if ((env.pf_instances[0].vf_bdfs[DPU_MAX_VFS_PER_PF - 1] >=
             env.pf_instances[1].pf_bdf) ||
            (env.pf_instances[1].pf_bdf !=
             (env.pf_instances[0].pf_bdf + DPU_MAX_VFS_PER_PF + 1))) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "maximum VF BDF range overlaps the adjacent PF BDF block")
        end

        if (global_rx_qids.size() != 26) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected one global RX queue ID for 26 functions, received %0d",
                global_rx_qids.size()))
        end

        // A frozen lease remains saved and mapped, but no new lease can be
        // acquired until it is restored.
        if (!env.pf_instances[0].pf_function.resource_client.freeze_qpairs(why) ||
            env.pf_instances[0].pf_function.resource_client.reserve_qpairs(1, 1, why) ||
            !env.pf_instances[0].pf_function.resource_client.restore_qpairs(why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "QP freeze/restore lifecycle was not enforced: %s", why))
        end

        // Function reset owns lease cleanup.  Call the public FLR path rather
        // than releasing through the client so a reset cannot leak Fabric QPs.
        env.pf_instances[0].pf_function.on_flr();
        if ((env.pf_instances[0].pf_function.resource_client.qpair_leases.size() != 0) ||
            (env.pf_instances[0].pf_function.resource_client.qpair_mappings.size() != 0) ||
            env.pf_instances[0].pf_function.resource_client.local_qid_to_global_qid(
                0, stale_global_rx_qid
            )) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "FLR did not release the function's Fabric QP leases")
        end

        // A migration freeze is stateful even when this function has no local
        // QP leases.  FLR teardown must still restore it, so a later QP
        // reservation is not rejected as frozen.
        if (!env.pf_instances[0].pf_function.resource_client.freeze_qpairs(why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not freeze zero-lease function before FLR: %s", why))
        end
        env.pf_instances[0].pf_function.on_flr();
        if (!env.pf_instances[0].pf_function.resource_client.reserve_qpairs(
            0, 1, why
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "zero-lease frozen FLR left Fabric QP state frozen: %s", why))
        end

        // Return to a zero-lease state so disabled-function teardown covers
        // the same migration edge case independently of FLR.
        if (!env.pf_instances[0].pf_function.resource_client.release_qpairs(why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not clear QP lease before zero-lease shutdown: %s", why))
        end
        if (!env.pf_instances[0].pf_function.resource_client.freeze_qpairs(why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not freeze zero-lease function before shutdown: %s", why))
        end
        env.pf_instances[0].pf_function.shutdown();
        if (!env.pf_instances[0].pf_function.resource_client.reserve_qpairs(
            0, 1, why
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "zero-lease frozen shutdown left Fabric QP state frozen: %s", why))
        end

        // Shutdown is the disabled-function teardown path and must release
        // the same Fabric-owned QP leases even when migration left them saved.
        if (!env.pf_instances[0].vf_functions[0].resource_client.freeze_qpairs(why)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not freeze VF QP lease before shutdown: %s", why))
        end
        env.pf_instances[0].vf_functions[0].shutdown();
        if ((env.pf_instances[0].vf_functions[0].resource_client.qpair_leases.size() != 0) ||
            (env.pf_instances[0].vf_functions[0].resource_client.qpair_mappings.size() != 0) ||
            env.pf_instances[0].vf_functions[0].resource_client.local_qid_to_global_qid(
                0, stale_global_rx_qid
            )) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "function shutdown did not release Fabric QP leases")
        end

        foreach (env.pf_instances[pf_index]) begin
            if (!env.pf_instances[pf_index].pf_function.resource_client.release_qpairs(why))
                `uvm_fatal("FABRIC_RESOURCE", $sformatf("PF QP release failed: %s", why))
            foreach (env.pf_instances[pf_index].vf_functions[vf_index]) begin
                if (!env.pf_instances[pf_index].vf_functions[vf_index].resource_client.release_qpairs(why)) begin
                    `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                        "VF QP release failed: %s", why))
                end
            end
        end

        phase.drop_objection(this);
    endtask
endclass : virtio_fabric_resource_test

`endif // VIRTIO_FABRIC_RESOURCE_TEST_SV
