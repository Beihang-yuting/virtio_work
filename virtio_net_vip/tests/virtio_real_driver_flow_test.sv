`ifndef VIRTIO_REAL_DRIVER_FLOW_TEST_SV
`define VIRTIO_REAL_DRIVER_FLOW_TEST_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Real-driver TX payload used by the golden flow.  The production atomic
// operation consumes a uvm_object through do_pack(), exactly as the dataplane
// driver does; this is intentionally not a direct host-memory write from the
// test.
class virtio_real_driver_flow_packet extends uvm_object;
  `uvm_object_utils(virtio_real_driver_flow_packet)
  byte unsigned data[$];

  function new(string name = "virtio_real_driver_flow_packet");
    super.new(name);
    data = '{8'hde, 8'had, 8'hbe, 8'hef,
             8'h01, 8'h23, 8'h45, 8'h67,
             8'h89, 8'hab, 8'hcd, 8'hef,
             8'h10, 8'h20, 8'h30, 8'h40};
  endfunction

  virtual function void do_pack(uvm_packer packer);
    super.do_pack(packer);
    foreach (data[i])
      packer.pack_field_int(data[i], 8);
    packer.set_packed_size();
  endfunction
endclass

class virtio_real_driver_flow_test extends uvm_test;
  `uvm_component_utils(virtio_real_driver_flow_test)
  virtio_real_driver_flow_fixture flow;
  function new(string name, uvm_component parent); super.new(name, parent); endfunction
  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
  endfunction
    task run_phase(uvm_phase phase);
        string why;
        bit ok;
        bit is_model;
        virtio_monitor monitor;
        int unsigned notify_before;
        int unsigned dma_before;
        int unsigned interrupt_before;
        int unsigned tx_queue_id;
        phase.raise_objection(this);
    if (flow.build_flow(why) == 0)
      `uvm_fatal("REAL_FLOW", why)
    if (!flow.snapshot_is_frozen())
      `uvm_error("REAL_FLOW", "flow snapshot is not frozen")
    if (flow.function_bdf() == 16'h0)
      `uvm_error("REAL_FLOW", "flow did not resolve a function BDF")
    if (flow.bar_count() != 3)
      `uvm_error("REAL_FLOW", "flow did not resolve three BAR pairs")
    if (flow.host_mem() == null)
      `uvm_error("REAL_FLOW", "flow did not expose shared Host memory")
    if (flow.virtio_env() == null || flow.pcie_env() == null)
      `uvm_error("REAL_FLOW", "flow did not expose bound transport environments")
        if (flow.device_snapshot() == null || flow.resource_snapshot() == null ||
        !flow.snapshot_is_frozen())
      `uvm_error("REAL_FLOW", "flow did not expose frozen snapshot pair")

    is_model = (flow.execution_mode() == VIRTIO_EXEC_MODEL);
    if (!flow.tx_queue_id_for_pair(0, tx_queue_id, why))
      `uvm_fatal("REAL_FLOW", {"could not resolve TX queue: ", why})

    // The golden lifecycle contract continues through one production TX
    // submission and device-side used-ring completion; the test never writes
    // descriptor or ring bytes directly.
    flow.start_driver_flow(ok);
    if (!ok)
      `uvm_error("REAL_FLOW", "driver initialization flow failed")

    // Virtio-net uses even queues for RX and odd queues for TX.  Keep the
    // single-packet golden flow on TX queue 1 so MODEL and REAL_DUT exercise
    // the same direction-specific queue contract as the multi-queue test.
    flow.setup_queue(tx_queue_id, 256, VQ_SPLIT, ok);
    if (!ok)
      `uvm_error("REAL_FLOW", "production queue setup failed")

    if (is_model) begin
      if (flow.dut_responder() == null) begin
        `uvm_error("REAL_FLOW", "MODEL fixture did not expose DUT responder")
      end else begin
      flow.dut_responder().start();
    if (!flow.dut_responder().running())
        `uvm_error("REAL_FLOW", "DUT responder did not enter running state")
      else begin
        virtio_real_driver_flow_packet pkt;
        virtio_net_hdr_t hdr;
        uvm_object completed[$];
        int unsigned desc_id;
        int unsigned completed_count;
        int unsigned notify_before;
        int unsigned reads_before;
        int unsigned writes_before;
        int unsigned completions_before;
        int unsigned interrupts_before;

        pkt = virtio_real_driver_flow_packet::type_id::create("tx_packet");
        hdr = '{default: 0};
        notify_before = flow.dut_responder().notify_count();
        reads_before = flow.dut_responder().dma_read_count();
        writes_before = flow.dut_responder().dma_write_count();
        completions_before = flow.dut_responder().completion_count();
        interrupts_before = flow.dut_responder().interrupt_count();

        // Submit through the production atomic TX operation.  The test does
        // not write descriptors or ring indices directly.
        flow.submit_tx(tx_queue_id, hdr, pkt, 1'b0, desc_id, ok);
        if (!ok || desc_id == '1)
          `uvm_error("REAL_FLOW", "production TX submission failed")

        flow.complete_tx(tx_queue_id, completed, 1, completed_count, ok);
        if (!ok || completed_count != 1 || completed.size() != 1)
          `uvm_error("REAL_FLOW", $sformatf(
              "TX completion failed count=%0d objects=%0d",
              completed_count, completed.size()))
        if (flow.dut_responder().notify_count() <= notify_before ||
            flow.dut_responder().dma_read_count() <= reads_before ||
            flow.dut_responder().dma_write_count() <= writes_before ||
            flow.dut_responder().completion_count() <= completions_before ||
            flow.dut_responder().interrupt_count() <= interrupts_before)
          `uvm_error("REAL_FLOW", "TX did not traverse notify/DMA/used/interrupt path")

        flow.dut_responder().stop();
        flow.dut_responder().wait_stopped();
        if (flow.dut_responder().running())
          `uvm_error("REAL_FLOW", "DUT responder did not stop cleanly")
      end
      end
    end else begin
      // REAL_DUT has no local device responder.  The only valid evidence is
      // passive traffic decoded by the bound virtio monitor (and, when the
      // plain pcie_work path is used, the explicit RC Host-memory responder).
      if (!flow.real_dut_link_ready())
        `uvm_fatal("REAL_DUT_UNAVAILABLE",
                  "REAL_DUT flow was not bound to two PCIe directions")
      monitor = flow.function_monitor();
      if (monitor == null)
        `uvm_fatal("REAL_DUT_UNAVAILABLE",
                  "REAL_DUT function has no semantic PCIe monitor")
      notify_before = monitor.bar_event_fifo.used();
      dma_before = monitor.dma_event_fifo.used();
      interrupt_before = monitor.interrupt_event_fifo.used();

      begin
        virtio_real_driver_flow_packet pkt;
        virtio_net_hdr_t hdr;
        uvm_object completed[$];
        int unsigned desc_id;
        int unsigned completed_count;
        pkt = virtio_real_driver_flow_packet::type_id::create("real_tx_packet");
        hdr = '{default: 0};
        flow.submit_tx(tx_queue_id, hdr, pkt, 1'b0, desc_id, ok);
        if (!ok || desc_id == '1)
          `uvm_error("REAL_FLOW", "REAL_DUT TX submission failed")
        flow.complete_tx(tx_queue_id, completed, 1, completed_count, ok);
        if (!ok || completed_count != 1 || completed.size() != 1)
          `uvm_error("REAL_FLOW", $sformatf(
              "REAL_DUT TX completion failed count=%0d objects=%0d",
              completed_count, completed.size()))
      end
      if (monitor.bar_event_fifo.used() <= notify_before ||
          monitor.dma_event_fifo.used() <= dma_before ||
          monitor.interrupt_event_fifo.used() <= interrupt_before)
        `uvm_error("REAL_FLOW",
                   "REAL_DUT trace missed notify/DMA/interrupt traffic")
    end

    flow.reset_and_teardown(ok);
    if (!ok)
      `uvm_error("REAL_FLOW", "driver flow reset/teardown failed")
    phase.drop_objection(this);
  endtask
endclass

`endif
