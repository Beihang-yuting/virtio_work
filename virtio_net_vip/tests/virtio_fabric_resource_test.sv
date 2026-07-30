`ifndef VIRTIO_FABRIC_RESOURCE_TEST_SV
`define VIRTIO_FABRIC_RESOURCE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

class virtio_fabric_resource_test extends uvm_test;
    `uvm_component_utils(virtio_fabric_resource_test)

    typedef struct {
        bit [63:0] base;
        bit [63:0] size;
    } bar_range_t;

    virtio_net_env_config cfg;
    virtio_net_env        env;

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
            (function_instance.transport.bar.bar_base[2] != '0) ||
            (function_instance.transport.bar.bar_size[2] != '0) ||
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
        cfg.num_vfs_per_pf[0][0] = 1;
        cfg.num_vfs_per_pf[0][1] = 2;
        cfg.num_vfs_per_pf[1][0] = 3;
        cfg.num_vfs_per_pf[1][1] = 1;

        uvm_config_db#(virtio_net_env_config)::set(this, "env", "cfg", cfg);
        env = virtio_net_env::type_id::create("env", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        int unsigned expected_vfs[];
        int unsigned global_rx_qids[$];
        bar_range_t all_bars[$];
        string why;

        phase.raise_objection(this);
        expected_vfs = new[4];
        expected_vfs[0] = 1;
        expected_vfs[1] = 2;
        expected_vfs[2] = 3;
        expected_vfs[3] = 1;

        if ((env.pf_instances.size() != 4) ||
            (env.vf_instances.size() != 7)) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected 4 PFs and 7 VFs, received %0d and %0d",
                env.pf_instances.size(), env.vf_instances.size()))
        end

        foreach (env.pf_instances[pf_index]) begin
            if (env.pf_instances[pf_index].num_vfs != expected_vfs[pf_index]) begin
                `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                    "PF %0d VF count does not match the requested topology", pf_index))
            end
            if (env.pf_instances[pf_index].pf_function.transport.is_vf) begin
                `uvm_fatal("FABRIC_RESOURCE", "PF function was modeled as a VF")
            end
            assert_bar_layout(env.pf_instances[pf_index].pf_function);
            assert_unique_bars(env.pf_instances[pf_index].pf_function, all_bars);
            assert_unique_qpair(env.pf_instances[pf_index].pf_function,
                                global_rx_qids);

            foreach (env.pf_instances[pf_index].vf_functions[vf_index]) begin
                if (!env.pf_instances[pf_index].vf_functions[vf_index].transport.is_vf) begin
                    `uvm_fatal("FABRIC_RESOURCE", "VF function lost its VF identity")
                end
                assert_bar_layout(env.pf_instances[pf_index].vf_functions[vf_index]);
                assert_unique_bars(env.pf_instances[pf_index].vf_functions[vf_index],
                                   all_bars);
                assert_unique_qpair(env.pf_instances[pf_index].vf_functions[vf_index],
                                    global_rx_qids);
            end
        end

        if (global_rx_qids.size() != 11) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "expected one global RX queue ID for 11 functions, received %0d",
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
