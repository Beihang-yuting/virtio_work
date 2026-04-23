`ifndef VIRTIO_SMOKE_TEST_SV
`define VIRTIO_SMOKE_TEST_SV

// ============================================================================
// virtio_smoke_test
//
// Smoke test: runs the virtio_smoke_vseq virtual sequence for a minimal
// end-to-end init -> traffic -> reset flow on VF 0 (or PF in pure PF mode).
//
// Depends on:
//   - virtio_base_test
//   - virtio_smoke_vseq
// ============================================================================

class virtio_smoke_test extends virtio_base_test;
    `uvm_component_utils(virtio_smoke_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_smoke_vseq vseq = virtio_smoke_vseq::type_id::create("vseq");
        phase.raise_objection(this);

        vseq.vf_seqr = env.vf_instances[0].driver_agent.sequencer;
        vseq.start(env.v_seqr);

        phase.drop_objection(this);
    endtask

endclass : virtio_smoke_test

`endif // VIRTIO_SMOKE_TEST_SV
