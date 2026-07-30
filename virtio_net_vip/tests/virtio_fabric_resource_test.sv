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

    int unsigned config_write_count;

    function new(string name = "virtio_fabric_cfg_stub_accessor");
        super.new(name);
        config_write_count = 0;
    endfunction

    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
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
        config_write_count++;
    endtask
endclass : virtio_fabric_cfg_stub_accessor

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

class virtio_fabric_resource_test extends uvm_test;
    `uvm_component_utils(virtio_fabric_resource_test)

    typedef struct {
        bit [63:0] base;
        bit [63:0] size;
    } bar_range_t;

    virtio_net_env_config cfg;
    virtio_net_env        env;
    virtio_vf_instance    compatibility_vf;

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
        if ((config_stub.config_write_count != 0) ||
            !function_instance.transport.fabric_capability_discovered) begin
            `uvm_fatal("FABRIC_RESOURCE",
                "Fabric discovery enumerated or rewrote a Fabric BAR")
        end
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
        env = virtio_net_env::type_id::create("env", this);
        compatibility_vf = virtio_vf_instance::type_id::create(
            "compatibility_vf", this
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
