`ifndef VIRTIO_PF_INSTANCE_SV
`define VIRTIO_PF_INSTANCE_SV

// Owns one independently addressable PF function and its subordinate VFs.
class virtio_pf_instance extends uvm_component;
    `uvm_component_utils(virtio_pf_instance)

    int unsigned                host_id;
    int unsigned                pf_id;
    int unsigned                num_vfs;
    bit [15:0]                  pf_bdf;
    bit [15:0]                  vf_bdfs[];
    dpu_function_key_t          pf_key;
    dpu_function_key_t          vf_keys[];
    virtio_function_instance    pf_function;
    virtio_function_instance    vf_functions[];
    virtio_pf_manager           pf_manager;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    function void configure_topology(
        input int unsigned configured_host_id,
        input int unsigned configured_pf_id,
        input int unsigned configured_num_vfs,
        input bit [15:0] configured_pf_bdf
    );
        host_id = configured_host_id;
        pf_id = configured_pf_id;
        num_vfs = configured_num_vfs;
        pf_bdf = configured_pf_bdf;
        vf_bdfs = new[num_vfs];
        vf_keys = new[num_vfs];
        for (int unsigned vf_id = 0; vf_id < num_vfs; vf_id++) begin
            vf_bdfs[vf_id] = pf_bdf + vf_id + 1;
            vf_keys[vf_id].host_id = host_id;
            vf_keys[vf_id].pf_id = pf_id;
            vf_keys[vf_id].kind = DPU_FUNCTION_VF;
            vf_keys[vf_id].vf_id = vf_id;
        end
        pf_key.host_id = host_id;
        pf_key.pf_id = pf_id;
        pf_key.kind = DPU_FUNCTION_PF;
        pf_key.vf_id = 0;
    endfunction

    virtual function void build_phase(uvm_phase phase);
        dpu_bar_pair_lease_t no_bars[$];

        super.build_phase(phase);
        pf_function = virtio_function_instance::type_id::create(
            "pf_function", this
        );
        pf_function.configure_function(
            DPU_FUNCTION_PF, pf_key, pf_bdf, no_bars
        );

        vf_functions = new[num_vfs];
        foreach (vf_functions[vf_id]) begin
            vf_functions[vf_id] = virtio_function_instance::type_id::create(
                $sformatf("vf_function_%0d", vf_id), this
            );
            vf_functions[vf_id].configure_function(
                DPU_FUNCTION_VF, vf_keys[vf_id], vf_bdfs[vf_id], no_bars
            );
        end
        pf_manager = virtio_pf_manager::type_id::create("pf_manager");
        pf_manager.pf_index = pf_id;
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        pf_manager.vf_instances = new[vf_functions.size()];
        foreach (vf_functions[vf_id])
            pf_manager.vf_instances[vf_id] = vf_functions[vf_id];
        pf_manager.pf_transport = pf_function.transport;
    endfunction

    function void configure_fabric_resources(
        input dpu_resource_manager manager
    );
        dpu_bar_pair_lease_t bars[$];
        string why;

        if (!manager.activate_function(pf_key, bars, why)) begin
            `uvm_fatal("PF_INSTANCE", $sformatf(
                "PF activation failed for host %0d PF %0d: %s",
                host_id, pf_id, why))
        end
        pf_function.configure_function(
            DPU_FUNCTION_PF, pf_key, pf_bdf, bars, manager
        );

        foreach (vf_functions[vf_id]) begin
            if (!manager.activate_function(vf_keys[vf_id], bars, why)) begin
                `uvm_fatal("PF_INSTANCE", $sformatf(
                    "VF activation failed for host %0d PF %0d VF %0d: %s",
                    host_id, pf_id, vf_id, why))
            end
            vf_functions[vf_id].configure_function(
                DPU_FUNCTION_VF, vf_keys[vf_id], vf_bdfs[vf_id], bars, manager
            );
        end
    endfunction
endclass : virtio_pf_instance

`endif // VIRTIO_PF_INSTANCE_SV
