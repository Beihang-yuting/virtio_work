`ifndef VIRTIO_SMOKE_TEST_SV
`define VIRTIO_SMOKE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// ============================================================================
// virtio_smoke_test
//
// Maintained bounded TLM/model integration smoke. This test exercises the
// model-backed PCIe transport and does not prove behavior through a real DUT.
// ============================================================================

class virtio_smoke_test extends virtio_e2e_test;
    `uvm_component_utils(virtio_smoke_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_pci_transport xport;
        bit [7:0] status;

        phase.raise_objection(this, "virtio smoke running");
        #200ns;

        phase1_setup_transport();
        phase2_virtio_init();

        xport = virtio_env.function_instances[0].transport;
        xport.write_device_status(DEV_STATUS_RESET);
        xport.read_device_status(status);
        assert (status == DEV_STATUS_RESET)
        else
            `uvm_fatal("SMOKE_TEST", $sformatf(
                "device reset did not clear status: 0x%02h", status))

        release_e2e_allocations();
        phase4_verify();

        phase.drop_objection(this, "virtio smoke done");
    endtask

endclass : virtio_smoke_test

`endif // VIRTIO_SMOKE_TEST_SV
