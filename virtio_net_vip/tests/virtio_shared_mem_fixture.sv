`ifndef VIRTIO_SHARED_MEM_FIXTURE_SV
`define VIRTIO_SHARED_MEM_FIXTURE_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Test-level owner for the external host_mem project.  This class does not
// implement allocation; it only creates one host_mem_pool and returns the
// pool-owned manager for a Host ID.  Business tests must retain the returned
// handle instead of creating another manager in an individual task.
class virtio_shared_mem_fixture extends uvm_object;
    `uvm_object_utils(virtio_shared_mem_fixture)

    host_mem_pool pool;

    function new(string name = "virtio_shared_mem_fixture");
        super.new(name);
        pool = host_mem_pool::type_id::create({name, "_pool"});
    endfunction

    function bit create_host(
        input int unsigned host_id,
        input bit [63:0] base_addr,
        input bit [63:0] end_addr,
        input host_mem_alloc_policy_e policy = HOST_MEM_RANDOM,
        input alloc_mode_e mode = MODE_BUDDY,
        input int unsigned granule = DEFAULT_MIN_GRANULE
    );
        if (pool.has_host(host_id))
            return 1;
        return pool.create_host(host_id, base_addr, end_addr,
                                mode, granule, policy);
    endfunction

    function host_mem_manager get_host(input int unsigned host_id);
        return pool.get_host(host_id);
    endfunction

    function bit has_host(input int unsigned host_id);
        return pool.has_host(host_id);
    endfunction

    function void leak_check();
        for (int unsigned host_id = 0; host_id < 32; host_id++) begin
            if (pool.has_host(host_id))
                pool.get_host(host_id).leak_check();
        end
    endfunction
endclass : virtio_shared_mem_fixture

`endif
