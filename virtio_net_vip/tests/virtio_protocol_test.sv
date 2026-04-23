`ifndef VIRTIO_PROTOCOL_TEST_SV
`define VIRTIO_PROTOCOL_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// ============================================================================
// virtio_protocol_test
//
// Protocol-level correctness tests without PCIe infrastructure. Tests:
//   - virtio_net_hdr pack/unpack round-trip (10/12/20-byte variants)
//   - virtio_csum_engine ethertype/protocol/offset detection
//   - virtio_tso_engine needs_tso and header length
//   - virtio_rss_engine hash and queue selection
//   - virtio_offload_engine GSO type detection
// ============================================================================

class virtio_protocol_test extends uvm_test;
    `uvm_component_utils(virtio_protocol_test)

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_net_hdr_pack_unpack();
        test_csum_engine();
        test_tso_engine();
        test_rss_engine();
        test_offload_gso_detection();

        `uvm_info("PROTO_TEST", "All protocol tests PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask

    // Test virtio_net_hdr pack/unpack round-trip
    task test_net_hdr_pack_unpack();
        virtio_net_hdr_t hdr_in, hdr_out;
        byte unsigned packed_data[$];
        bit [63:0] features;

        // Basic header (10 bytes)
        features = 0;
        features[VIRTIO_F_VERSION_1] = 1;

        hdr_in.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
        hdr_in.gso_type = VIRTIO_NET_HDR_GSO_TCPV4;
        hdr_in.hdr_len = 16'd54;
        hdr_in.gso_size = 16'd1460;
        hdr_in.csum_start = 16'd34;
        hdr_in.csum_offset = 16'd16;
        hdr_in.num_buffers = 0;
        hdr_in.hash_value = 0;
        hdr_in.hash_report = 0;

        assert(virtio_net_hdr_util::get_hdr_size(features) == 10)
            else `uvm_error("TEST", "basic hdr size should be 10")

        virtio_net_hdr_util::pack_hdr(hdr_in, features, packed_data);
        assert(packed_data.size() == 10)
            else `uvm_error("TEST", $sformatf("packed size %0d != 10", packed_data.size()))

        virtio_net_hdr_util::unpack_hdr(packed_data, features, hdr_out);
        assert(hdr_out.flags == hdr_in.flags) else `uvm_error("TEST", "flags mismatch")
        assert(hdr_out.gso_type == hdr_in.gso_type) else `uvm_error("TEST", "gso_type mismatch")
        assert(hdr_out.hdr_len == hdr_in.hdr_len) else `uvm_error("TEST", "hdr_len mismatch")
        assert(hdr_out.gso_size == hdr_in.gso_size) else `uvm_error("TEST", "gso_size mismatch")
        assert(hdr_out.csum_start == hdr_in.csum_start) else `uvm_error("TEST", "csum_start mismatch")
        assert(hdr_out.csum_offset == hdr_in.csum_offset) else `uvm_error("TEST", "csum_offset mismatch")

        // MRG_RXBUF header (12 bytes)
        packed_data = {};  // clear queue
        features[VIRTIO_NET_F_MRG_RXBUF] = 1;
        hdr_in.num_buffers = 16'd3;

        assert(virtio_net_hdr_util::get_hdr_size(features) == 12)
            else `uvm_error("TEST", "mrg_rxbuf hdr size should be 12")

        virtio_net_hdr_util::pack_hdr(hdr_in, features, packed_data);
        assert(packed_data.size() == 12)
            else `uvm_error("TEST", $sformatf("mrg packed size %0d != 12", packed_data.size()))

        virtio_net_hdr_util::unpack_hdr(packed_data, features, hdr_out);
        assert(hdr_out.num_buffers == 3) else `uvm_error("TEST", "num_buffers mismatch")

        // HASH_REPORT header (20 bytes)
        packed_data = {};  // clear queue
        features[VIRTIO_NET_F_HASH_REPORT] = 1;
        hdr_in.hash_value = 32'hDEADBEEF;
        hdr_in.hash_report = 16'h0003;

        assert(virtio_net_hdr_util::get_hdr_size(features) == 20)
            else `uvm_error("TEST", "hash_report hdr size should be 20")

        virtio_net_hdr_util::pack_hdr(hdr_in, features, packed_data);
        virtio_net_hdr_util::unpack_hdr(packed_data, features, hdr_out);
        assert(hdr_out.hash_value == 32'hDEADBEEF) else `uvm_error("TEST", "hash_value mismatch")
        assert(hdr_out.hash_report == 16'h0003) else `uvm_error("TEST", "hash_report mismatch")

        `uvm_info("PROTO_TEST", "test_net_hdr_pack_unpack PASSED", UVM_LOW)
    endtask

    // Test checksum engine
    task test_csum_engine();
        virtio_csum_engine csum = virtio_csum_engine::type_id::create("csum");
        byte unsigned pkt_data[$];
        int unsigned offset;

        // Create a minimal IPv4/TCP packet (ETH+IPv4+TCP)
        // ETH: 14 bytes, IPv4: 20 bytes, TCP: 20 bytes = 54 bytes total
        pkt_data = {};
        for (int i = 0; i < 54; i++) pkt_data.push_back(8'h00);

        // ETH header: ethertype = IPv4
        pkt_data[12] = 8'h08; pkt_data[13] = 8'h00;

        // IPv4 header: version=4, IHL=5
        pkt_data[14] = 8'h45;
        // protocol = TCP
        pkt_data[23] = 8'h06;

        // Verify ethertype detection
        assert(csum.get_ethertype(pkt_data) == 16'h0800)
            else `uvm_error("TEST", "ethertype should be 0x0800")

        // Verify L4 protocol
        assert(csum.get_l4_proto(pkt_data) == 8'h06)
            else `uvm_error("TEST", "L4 proto should be TCP (6)")

        // Verify csum_start = 34 (ETH 14 + IPv4 20)
        offset = csum.calc_csum_start(pkt_data);
        assert(offset == 34)
            else `uvm_error("TEST", $sformatf("csum_start should be 34, got %0d", offset))

        // Verify csum_offset = 16 (TCP checksum field offset within TCP header)
        offset = csum.calc_csum_offset(pkt_data);
        assert(offset == 16)
            else `uvm_error("TEST", $sformatf("csum_offset should be 16, got %0d", offset))

        `uvm_info("PROTO_TEST", "test_csum_engine PASSED", UVM_LOW)
    endtask

    // Test TSO engine
    task test_tso_engine();
        virtio_tso_engine tso = virtio_tso_engine::type_id::create("tso");
        byte unsigned pkt_data[$];
        int unsigned mss = 100;
        int unsigned total_payload = 300;
        int unsigned hdr_len;

        // Create ETH(14) + IPv4(20) + TCP(20) + payload(300) = 354 bytes
        pkt_data = {};
        for (int i = 0; i < 54 + total_payload; i++) pkt_data.push_back(8'h00);

        pkt_data[12] = 8'h08; pkt_data[13] = 8'h00;  // IPv4
        pkt_data[14] = 8'h45;  // IHL=5
        pkt_data[23] = 8'h06;  // TCP
        pkt_data[46] = 8'h50;  // TCP data offset = 5 (20 bytes)

        // Set IP total length
        begin
            int unsigned ip_total = 20 + 20 + total_payload;
            pkt_data[16] = ip_total[15:8];
            pkt_data[17] = ip_total[7:0];
        end

        // Fill payload with pattern
        for (int i = 54; i < pkt_data.size(); i++)
            pkt_data[i] = i[7:0];

        // Should need TSO (300 > 100)
        assert(tso.needs_tso(pkt_data, mss))
            else `uvm_error("TEST", "should need TSO")

        // Should not need TSO with large MSS
        assert(!tso.needs_tso(pkt_data, 1460))
            else `uvm_error("TEST", "should not need TSO with mss=1460")

        hdr_len = tso.get_all_hdr_len(pkt_data);
        assert(hdr_len == 54) else `uvm_error("TEST", $sformatf("hdr_len should be 54, got %0d", hdr_len))

        `uvm_info("PROTO_TEST", "test_tso_engine PASSED", UVM_LOW)
    endtask

    // Test RSS engine
    task test_rss_engine();
        virtio_rss_engine rss = virtio_rss_engine::type_id::create("rss");
        int unsigned q1, q2;
        byte unsigned pkt1[$], pkt2[$];

        // Init default key
        rss.init_default_key();

        // Setup indirection table: 4 queues
        rss.indirection_table = new[128];
        foreach (rss.indirection_table[i])
            rss.indirection_table[i] = i % 4;
        rss.hash_types = '1;

        // Create two packets with different flows
        // Packet 1: ETH + IPv4(src=10.0.0.1, dst=10.0.0.2) + TCP(src=1000, dst=80)
        pkt1 = {};
        for (int i = 0; i < 54; i++) pkt1.push_back(8'h00);
        pkt1[12] = 8'h08; pkt1[13] = 8'h00;
        pkt1[14] = 8'h45; pkt1[23] = 8'h06;
        // src IP: 10.0.0.1
        pkt1[26] = 10; pkt1[27] = 0; pkt1[28] = 0; pkt1[29] = 1;
        // dst IP: 10.0.0.2
        pkt1[30] = 10; pkt1[31] = 0; pkt1[32] = 0; pkt1[33] = 2;
        // src port: 1000
        pkt1[34] = 8'h03; pkt1[35] = 8'hE8;
        // dst port: 80
        pkt1[36] = 8'h00; pkt1[37] = 8'h50;

        // Packet 2: different flow
        pkt2 = {};
        for (int i = 0; i < 54; i++) pkt2.push_back(8'h00);
        pkt2[12] = 8'h08; pkt2[13] = 8'h00;
        pkt2[14] = 8'h45; pkt2[23] = 8'h06;
        pkt2[26] = 192; pkt2[27] = 168; pkt2[28] = 1; pkt2[29] = 100;
        pkt2[30] = 172; pkt2[31] = 16; pkt2[32] = 0; pkt2[33] = 1;
        pkt2[34] = 8'h13; pkt2[35] = 8'h88;
        pkt2[36] = 8'h00; pkt2[37] = 8'h50;

        q1 = rss.select_queue(pkt1, 4);
        q2 = rss.select_queue(pkt2, 4);

        `uvm_info("PROTO_TEST", $sformatf("RSS: pkt1->queue %0d, pkt2->queue %0d", q1, q2), UVM_LOW)

        // Same packet should always hash to same queue (deterministic)
        assert(rss.select_queue(pkt1, 4) == q1)
            else `uvm_error("TEST", "RSS should be deterministic")

        `uvm_info("PROTO_TEST", "test_rss_engine PASSED", UVM_LOW)
    endtask

    // Test offload GSO type detection
    task test_offload_gso_detection();
        virtio_offload_engine offload = virtio_offload_engine::type_id::create("offload");
        byte unsigned tcp4_pkt[$];
        int unsigned pkt_size;

        offload.negotiated_features = '1;
        offload.mss = 1460;

        // TCP/IPv4 packet > MSS: ETH(14) + IP(20) + TCP(20) + payload(1946) = 2000 bytes
        pkt_size = 2000;
        tcp4_pkt = {};
        for (int i = 0; i < pkt_size; i++) tcp4_pkt.push_back(8'h00);
        tcp4_pkt[12] = 8'h08; tcp4_pkt[13] = 8'h00;  // IPv4
        tcp4_pkt[14] = 8'h45; tcp4_pkt[23] = 8'h06;  // TCP
        tcp4_pkt[16] = (pkt_size - 14) >> 8; tcp4_pkt[17] = (pkt_size - 14) & 8'hFF;
        tcp4_pkt[46] = 8'h50;  // TCP data offset = 5

        assert(offload.needs_tso(tcp4_pkt)) else `uvm_error("TEST", "should need TSO")
        assert(offload.get_gso_type(tcp4_pkt) == VIRTIO_NET_HDR_GSO_TCPV4)
            else `uvm_error("TEST", "GSO type should be TCPV4")

        // Small packet shouldn't need GSO
        tcp4_pkt = {};
        for (int i = 0; i < 100; i++) tcp4_pkt.push_back(8'h00);
        tcp4_pkt[12] = 8'h08; tcp4_pkt[13] = 8'h00;
        tcp4_pkt[14] = 8'h45; tcp4_pkt[23] = 8'h06;
        tcp4_pkt[16] = (100 - 14) >> 8; tcp4_pkt[17] = (100 - 14) & 8'hFF;

        assert(!offload.needs_gso(tcp4_pkt)) else `uvm_error("TEST", "small pkt shouldn't need GSO")

        `uvm_info("PROTO_TEST", "test_offload_gso_detection PASSED", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_PROTOCOL_TEST_SV
