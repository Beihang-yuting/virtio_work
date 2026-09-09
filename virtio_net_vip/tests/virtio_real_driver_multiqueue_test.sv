`ifndef VIRTIO_REAL_DRIVER_MULTI_QUEUE_TEST_SV
`define VIRTIO_REAL_DRIVER_MULTI_QUEUE_TEST_SV

import uvm_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Real-driver multi-queue contract.  All queue/ring/payload work is routed
// through virtio_real_driver_flow_fixture; the test never writes Host memory
// or used-ring entries directly.
class virtio_real_driver_multiqueue_test extends uvm_test;
  `uvm_component_utils(virtio_real_driver_multiqueue_test)

  virtio_real_driver_flow_fixture flow;

  function new(string name, uvm_component parent);
    super.new(name, parent);
  endfunction

  function void build_phase(uvm_phase phase);
    super.build_phase(phase);
    flow = virtio_real_driver_flow_fixture::type_id::create("flow", this);
  endfunction

  task run_phase(uvm_phase phase);
    bit ok;
    string why;
    bit is_model;
    virtio_monitor monitor;
    int unsigned notify_before;
    int unsigned dma_before;
    int unsigned interrupt_before;
    virtio_net_hdr_t hdr;
    int unsigned tx_qids[2];
    int unsigned rx_qids[2];
    int unsigned packets_per_queue = 4;

    phase.raise_objection(this);
    if (!flow.build_flow(why))
      `uvm_fatal("REAL_MQ", why)

    is_model = (flow.execution_mode() == VIRTIO_EXEC_MODEL);

    for (int unsigned pair = 0; pair < 2; pair++) begin
      if (!flow.tx_queue_id_for_pair(pair, tx_qids[pair], why) ||
          !flow.rx_queue_id_for_pair(pair, rx_qids[pair], why))
        `uvm_fatal("REAL_MQ", {"could not resolve queue mapping: ", why})
    end

    flow.start_driver_flow(ok);
    if (!ok)
      `uvm_fatal("REAL_MQ", "driver initialization failed")

    // Configure the exact frozen local IDs; direction is part of the service
    // binding and must not be reconstructed from positional arithmetic.
    for (int unsigned pair = 0; pair < 2; pair++) begin
      flow.setup_queue(rx_qids[pair], 256, VQ_SPLIT, ok);
      if (!ok)
        `uvm_fatal("REAL_MQ", $sformatf(
            "production setup failed for RX queue %0d", rx_qids[pair]))
      flow.setup_queue(tx_qids[pair], 256, VQ_SPLIT, ok);
      if (!ok)
        `uvm_fatal("REAL_MQ", $sformatf(
            "production setup failed for TX queue %0d", tx_qids[pair]))
    end

    if (is_model) begin
      if (flow.dut_responder() == null)
        `uvm_fatal("REAL_MQ", "MODEL fixture did not expose DUT responder")
      flow.dut_responder().start();
      if (!flow.dut_responder().running())
        `uvm_fatal("REAL_MQ", "MODEL DUT responder did not start")
    end else begin
      if (!flow.real_dut_link_ready())
        `uvm_fatal("REAL_DUT_UNAVAILABLE",
                  "REAL_DUT multi-queue flow has no bound PCIe link")
      monitor = flow.function_monitor();
      if (monitor == null)
        `uvm_fatal("REAL_DUT_UNAVAILABLE",
                  "REAL_DUT multi-queue function monitor is unavailable")
      notify_before = monitor.bar_event_fifo.used();
      dma_before = monitor.dma_event_fifo.used();
      interrupt_before = monitor.interrupt_event_fifo.used();
    end

    hdr = '{default: 0};
    for (int unsigned qsel = 0; qsel < 2; qsel++) begin
      int unsigned qid = tx_qids[qsel];
      for (int unsigned i = 0; i < packets_per_queue; i++) begin
        packet_item pkt;
        int unsigned desc_id;
        pkt = packet_item::type_id::create($sformatf(
            "q%0d_packet_%0d", qid, i));
        if (!pkt.pkt.randomize() with {
              pkt_kind == ETH_IPV4_TCP;
              pkt_len inside {[128:512]};
            })
          `uvm_fatal("REAL_MQ", "net_packet randomization failed")
        pkt.pkt.do_pack();
        flow.submit_tx(qid, hdr, pkt, 1'b0, desc_id, ok);
        if (!ok || desc_id == '1)
          `uvm_fatal("REAL_MQ", $sformatf(
              "TX submit failed queue=%0d packet=%0d", qid, i))
      end
    end

    for (int unsigned qsel = 0; qsel < 2; qsel++) begin
      uvm_object completed[$];
      int unsigned completed_count;
      flow.complete_tx(tx_qids[qsel], completed, packets_per_queue,
                       completed_count, ok);
      if (!ok || completed_count != packets_per_queue)
        `uvm_fatal("REAL_MQ", $sformatf(
            "TX reclaim mismatch queue=%0d count=%0d", tx_qids[qsel],
            completed_count))
    end

    if (is_model) begin
      if (flow.dut_responder().notify_count() < packets_per_queue * 2 ||
          flow.dut_responder().dma_read_count() == 0 ||
          flow.dut_responder().dma_write_count() == 0 ||
          flow.dut_responder().interrupt_count() < packets_per_queue * 2)
        `uvm_fatal("REAL_MQ", "multi-queue MODEL flow missed notify/DMA/interrupt")
      flow.dut_responder().stop();
      flow.dut_responder().wait_stopped();
    end else begin
      if (monitor.bar_event_fifo.used() <= notify_before ||
          monitor.dma_event_fifo.used() <= dma_before ||
          monitor.interrupt_event_fifo.used() <= interrupt_before)
        `uvm_fatal("REAL_MQ",
                   "REAL_DUT multi-queue trace missed notify/DMA/interrupt")
    end
    flow.reset_and_teardown(ok);
    if (!ok)
      `uvm_fatal("REAL_MQ", "multi-queue reset/teardown failed")
    `uvm_info("REAL_MQ", "real-driver net_packet multi-queue TX PASSED",
              UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

`endif
