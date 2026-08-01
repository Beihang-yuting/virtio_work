`ifndef VIRTIO_COVERAGE_TEST_SV
`define VIRTIO_COVERAGE_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

class virtio_coverage_test extends uvm_test;
    `uvm_component_utils(virtio_coverage_test)

    virtio_coverage cov;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        cov = virtio_coverage::type_id::create("cov", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        virtio_transaction traffic;
        virtio_transaction injected_error;
        virtio_transaction lifecycle;

        phase.raise_objection(this);
        cov.enable_all();

        traffic = virtio_transaction::type_id::create("coverage_traffic");
        traffic.txn_type = VIO_TXN_SEND_PKTS;
        traffic.queue_id = 1;
        traffic.queue_size = 64;
        traffic.vq_type = VQ_SPLIT;
        traffic.features = '0;
        traffic.features[VIRTIO_NET_F_CSUM] = 1;
        traffic.features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        traffic.monitor_length = 512;
        traffic.net_hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
        traffic.net_hdr.gso_type = VIRTIO_NET_HDR_GSO_TCPV4;
        traffic.net_hdr.gso_size = 1460;
        traffic.irq_mode = IRQ_MSIX_PER_QUEUE;
        traffic.num_vfs = 1;
        cov.write(traffic);

        injected_error = virtio_transaction::type_id::create("coverage_error");
        injected_error.txn_type = VIO_TXN_INJECT_ERROR;
        injected_error.queue_id = 2;
        injected_error.queue_size = 128;
        injected_error.vq_type = VQ_PACKED;
        injected_error.vq_error_type = VQ_ERR_KICK_BEFORE_ENABLE;
        injected_error.irq_mode = IRQ_MSIX_SHARED;
        injected_error.num_vfs = 2;
        cov.write(injected_error);

        lifecycle = virtio_transaction::type_id::create("coverage_lifecycle");
        lifecycle.txn_type = VIO_TXN_INIT;
        lifecycle.status_val = DEV_STATUS_DRIVER_OK;
        lifecycle.queue_size = 32;
        lifecycle.vq_type = VQ_CUSTOM;
        lifecycle.irq_mode = IRQ_INTX;
        lifecycle.num_vfs = 9;
        cov.write(lifecycle);

        phase.drop_objection(this);
    endtask

    virtual function void report_phase(uvm_phase phase);
        super.report_phase(phase);
        assert(cov.cg_features.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "features covergroup stayed at zero")
        assert(cov.cg_queue_ops.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "queue_ops covergroup stayed at zero")
        assert(cov.cg_dataplane.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "dataplane covergroup stayed at zero")
        assert(cov.cg_offload.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "offload covergroup stayed at zero")
        assert(cov.cg_notification.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "notification covergroup stayed at zero")
        assert(cov.cg_errors.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "errors covergroup stayed at zero")
        assert(cov.cg_lifecycle.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "lifecycle covergroup stayed at zero")
        assert(cov.cg_sriov.get_inst_coverage() > 0.0)
            else `uvm_fatal("COV_TEST", "sriov covergroup stayed at zero")
        `uvm_info("COV_TEST", "All eight covergroups have nonzero instance coverage", UVM_NONE)
    endfunction
endclass : virtio_coverage_test

`endif // VIRTIO_COVERAGE_TEST_SV
