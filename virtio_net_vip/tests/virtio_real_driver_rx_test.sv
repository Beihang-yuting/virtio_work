// tests/：经 DUT responder 边界验证真实 driver RX；依赖 net_packet_pkg 的
// packet_item 和报文模板，以及 virtio_net_pkg 的共享 fixture。测试持有期望
// 报文句柄，fixture 持有内存与队列资源；UVM 在仿真结束回收测试组件。
`ifndef VIRTIO_REAL_DRIVER_RX_TEST_SV
`define VIRTIO_REAL_DRIVER_RX_TEST_SV

import uvm_pkg::*;
import net_packet_pkg::*;
import virtio_net_pkg::*;
`include "uvm_macros.svh"

// Real-driver RX contract.  The test injects packets only through the DUT
// responder boundary; it never writes an RX buffer or used ring directly.
class virtio_real_driver_rx_test extends uvm_test;
  `uvm_component_utils(virtio_real_driver_rx_test)

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
    virtio_net_hdr_t hdr;
    packet_item expected[$];
    uvm_object received[$];
    int unsigned received_count;
    int unsigned packet_count = 4;
    int unsigned notify_before;
    int unsigned writes_before;
    int unsigned completions_before;
    int unsigned interrupts_before;
    int unsigned rx_queue_id;

    phase.raise_objection(this);
    if (!flow.build_flow(why))
      `uvm_fatal("REAL_RX", why)

    // The frozen DPU resource binding is authoritative.  Do not reconstruct
    // RX local-qid from pair arithmetic: a scenario may deliberately place
    // the first RX queue at any valid local queue ID.
    if (!flow.rx_queue_id_for_pair(0, rx_queue_id, why))
      `uvm_fatal("REAL_RX", {"could not resolve RX queue: ", why})

    // RX ingress is not synthesized by the REAL_DUT Host-memory responder:
    // that component only answers EP-originated DMA.  A platform-specific
    // net_packet/physical ingress callback is therefore required before this
    // test can be run against RTL.  Do not silently fall back to the MODEL
    // responder, because that would make a REAL_DUT run a false pass.
    if (flow.execution_mode() == VIRTIO_EXEC_REAL_DUT)
      `uvm_fatal("REAL_DUT_RX_SOURCE_UNAVAILABLE",
                {"virtio_real_driver_rx_test requires a platform RX ingress ",
                 "callback; inject_rx() is MODEL-only"})

    flow.start_driver_flow(ok);
    if (!ok)
      `uvm_fatal("REAL_RX", "driver initialization failed")

    flow.setup_queue(rx_queue_id, 256, VQ_SPLIT, ok);
    if (!ok)
      `uvm_fatal("REAL_RX", "RX queue setup failed")

    if (flow.dut_responder() == null)
      `uvm_fatal("REAL_RX", "fixture did not expose DUT responder")
    flow.dut_responder().start();
    if (!flow.dut_responder().running())
      `uvm_fatal("REAL_RX", "DUT responder did not start")

    hdr = '{default: 0};
    notify_before = flow.dut_responder().notify_count();
    writes_before = flow.dut_responder().dma_write_count();
    completions_before = flow.dut_responder().completion_count();
    interrupts_before = flow.dut_responder().interrupt_count();

    // Queue packet arrivals before RX refill.  The responder must wait for a
    // writable descriptor and then perform the real EP-originated DMA write.
    for (int unsigned i = 0; i < packet_count; i++) begin
      packet_item pkt;
      pkt = packet_item::type_id::create($sformatf("rx_packet_%0d", i));
      if (!pkt.pkt.randomize() with {
            pkt_kind == ETH_IPV4_UDP;
            pkt_len inside {[128:512]};
          })
        `uvm_fatal("REAL_RX", "net_packet randomization failed")
      pkt.pkt.do_pack();
      expected.push_back(pkt);
      flow.inject_rx(rx_queue_id, hdr, pkt, ok);
      if (!ok)
        `uvm_fatal("REAL_RX", $sformatf(
            "responder rejected RX packet %0d", i))
    end

    // Refill is the production operation: allocation, mapping, descriptor
    // construction and notify all come from virtio_atomic_ops.rx_refill().
    flow.refill_rx(rx_queue_id, packet_count, ok);
    if (!ok)
      `uvm_fatal("REAL_RX", "production RX refill failed")

    flow.receive_rx(rx_queue_id, packet_count, received, received_count, ok);
    if (!ok || received_count != packet_count || received.size() != packet_count)
      `uvm_fatal("REAL_RX", $sformatf(
          "RX receive mismatch count=%0d objects=%0d", received_count,
          received.size()))

    foreach (received[i]) begin
      packet_item actual;
      if (!$cast(actual, received[i]) ||
          !virtio_net_packet_adapter::compare(expected[i], actual))
        `uvm_fatal("REAL_RX", $sformatf(
            "RX packet %0d payload mismatch", i))
    end

    if (flow.dut_responder().notify_count() <= notify_before ||
        flow.dut_responder().dma_write_count() <= writes_before ||
        flow.dut_responder().completion_count() <= completions_before ||
        flow.dut_responder().interrupt_count() <= interrupts_before)
      `uvm_fatal("REAL_RX", "RX missed notify/DMA/used/interrupt path")

    flow.dut_responder().stop();
    flow.dut_responder().wait_stopped();
    flow.reset_and_teardown(ok);
    if (!ok)
      `uvm_fatal("REAL_RX", "RX reset/teardown failed")

    `uvm_info("REAL_RX", "real-driver net_packet RX PASSED", UVM_NONE)
    phase.drop_objection(this);
  endtask
endclass

`endif
