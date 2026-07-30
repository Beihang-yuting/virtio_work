`ifndef VIRTIO_FABRIC_RESOURCE_TEST_SV
`define VIRTIO_FABRIC_RESOURCE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import dpu_resource_pkg::*;
import virtio_net_pkg::*;

// =============================================================================
// virtio_fabric_resource_test
//
// The public environment topology is a hierarchy of PF containers and their
// VF functions, rather than one flat list of VF-like instances.  This test
// deliberately uses the public hierarchy so clients cannot accidentally
// collapse PF and VF identity again.
// =============================================================================
class virtio_fabric_resource_test extends uvm_test;
    `uvm_component_utils(virtio_fabric_resource_test)

    virtio_net_env_config cfg;
    virtio_net_env        env;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    task assert_bar_layout(
        input dpu_bar_pair_lease_t bars[$],
        input dpu_function_kind_e kind
    );
        bit [63:0] device_size;
        bit [63:0] reserved_size;
        bit [63:0] msix_size;

        if (kind == DPU_FUNCTION_PF) begin
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
        int unsigned pf_rx_qid;
        int unsigned vf_rx_qid;
        string why;

        phase.raise_objection(this);

        if (env.pf_instances.size() != 4) begin
            `uvm_fatal("FABRIC_RESOURCE",
                $sformatf("expected 4 PF instances, received %0d",
                          env.pf_instances.size()))
        end
        if (env.pf_instances[0].pf_function.transport.is_vf) begin
            `uvm_fatal("FABRIC_RESOURCE", "PF function was modeled as a VF")
        end
        if (!env.pf_instances[0].vf_functions[0].transport.is_vf) begin
            `uvm_fatal("FABRIC_RESOURCE", "VF function lost its VF identity")
        end
        assert_bar_layout(env.pf_instances[0].pf_function.bar_pairs,
                          DPU_FUNCTION_PF);
        assert_bar_layout(env.pf_instances[0].vf_functions[0].bar_pairs,
                          DPU_FUNCTION_VF);
        if (env.pf_instances[0].pf_function.bar_pairs[0].base ==
            env.pf_instances[0].vf_functions[0].bar_pairs[0].base) begin
            `uvm_fatal("FABRIC_RESOURCE", "PF and VF share one BAR0/1 aperture")
        end
        if (!env.pf_instances[0].pf_function.resource_manager.mark_function_device_ready(
            env.pf_instances[0].pf_function.function_key, why
        ) || !env.pf_instances[0].vf_functions[0].resource_manager.mark_function_device_ready(
            env.pf_instances[0].vf_functions[0].function_key, why
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not mark Fabric functions device-ready: %s", why))
        end
        if (!env.pf_instances[0].pf_function.resource_client.reserve_qpairs(
            0, 1, why
        ) || !env.pf_instances[0].vf_functions[0].resource_client.reserve_qpairs(
            0, 1, why
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", $sformatf(
                "could not reserve Fabric QP leases: %s", why))
        end
        if (!env.pf_instances[0].pf_function.resource_client.local_qid_to_global_qid(
            0, pf_rx_qid
        ) || !env.pf_instances[0].vf_functions[0].resource_client.local_qid_to_global_qid(
            0, vf_rx_qid
        )) begin
            `uvm_fatal("FABRIC_RESOURCE", "local QP IDs did not map globally")
        end
        if (pf_rx_qid == vf_rx_qid) begin
            `uvm_fatal("FABRIC_RESOURCE", "PF and VF share a global RX queue ID")
        end

        phase.drop_objection(this);
    endtask
endclass : virtio_fabric_resource_test

`endif // VIRTIO_FABRIC_RESOURCE_TEST_SV
