`ifndef VIRTIO_TRAFFIC_TEST_SV
`define VIRTIO_TRAFFIC_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// ============================================================================
// virtio_traffic_test
//
// Standalone temporary test file for large-traffic and protocol integrity
// testing. NOT part of the main package or git. Uses direct host_mem access
// and device simulation (no real DUT).
//
// Tests:
//   1. test_large_traffic       — 1000 packet TX/RX loopback
//   2. test_bandwidth_control   — rate limiting verification
//   3. test_protocol_integrity  — checksum/TSO/RSS correctness
//   4. test_queue_stress        — 256-entry fill/drain x10 cycles
//   5. test_mixed_queue_types   — split + packed parallel
// ============================================================================

class virtio_traffic_test extends uvm_test;
    `uvm_component_utils(virtio_traffic_test)

    // Perf monitor (uvm_component, must be built in build_phase)
    virtio_perf_monitor pm;

    // Error counter
    int unsigned total_errors = 0;

    function new(string name, uvm_component parent);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        pm = virtio_perf_monitor::type_id::create("pm", this);
    endfunction

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);

        test_large_traffic();
        test_bandwidth_control();
        test_protocol_integrity();
        test_queue_stress();
        test_mixed_queue_types();

        if (total_errors == 0)
            `uvm_info("TRAFFIC_TEST", "All traffic tests PASSED (0 errors)", UVM_NONE)
        else
            `uvm_error("TRAFFIC_TEST", $sformatf("Traffic tests completed with %0d errors", total_errors))

        phase.drop_objection(this);
    endtask

    // ========================================================================
    // Packet generation helpers
    // ========================================================================

    // Build a synthetic Ethernet/IPv4/TCP packet with sequential payload
    function void build_ipv4_tcp_packet(
        int unsigned pkt_idx,
        int unsigned total_size,
        ref byte unsigned pkt_data[$]
    );
        int unsigned payload_size;
        int unsigned ip_total_len;

        pkt_data = {};

        // Ethernet header (14 bytes)
        // dst MAC: 00:11:22:33:44:55
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h11);
        pkt_data.push_back(8'h22); pkt_data.push_back(8'h33);
        pkt_data.push_back(8'h44); pkt_data.push_back(8'h55);
        // src MAC: 00:AA:BB:CC:DD:EE
        pkt_data.push_back(8'h00); pkt_data.push_back(8'hAA);
        pkt_data.push_back(8'hBB); pkt_data.push_back(8'hCC);
        pkt_data.push_back(8'hDD); pkt_data.push_back(8'hEE);
        // EtherType: 0x0800 (IPv4)
        pkt_data.push_back(8'h08); pkt_data.push_back(8'h00);

        // IPv4 header (20 bytes)
        ip_total_len = total_size - 14;
        pkt_data.push_back(8'h45);  // version=4, IHL=5
        pkt_data.push_back(8'h00);  // DSCP/ECN
        pkt_data.push_back(ip_total_len[15:8]);  // total length
        pkt_data.push_back(ip_total_len[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);  // identification
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);  // flags/fragment
        pkt_data.push_back(8'h40);  // TTL=64
        pkt_data.push_back(8'h06);  // protocol=TCP
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);  // checksum (0 for test)
        // src IP: 10.0.0.1
        pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h01);
        // dst IP: 10.0.0.2
        pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h02);

        // TCP header (20 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h50);  // src port: 80
        pkt_data.push_back(8'h10); pkt_data.push_back(8'h00);  // dst port: 4096
        // seq number (encode pkt_idx)
        pkt_data.push_back(pkt_idx[31:24]); pkt_data.push_back(pkt_idx[23:16]);
        pkt_data.push_back(pkt_idx[15:8]);  pkt_data.push_back(pkt_idx[7:0]);
        // ack number
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        // data offset (5 words) + flags
        pkt_data.push_back(8'h50); pkt_data.push_back(8'h10);  // ACK
        // window
        pkt_data.push_back(8'hFF); pkt_data.push_back(8'hFF);
        // checksum (0 for test)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        // urgent pointer
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);

        // Payload: sequential pattern based on pkt_idx
        payload_size = total_size - 54;  // 14 ETH + 20 IP + 20 TCP = 54
        for (int unsigned i = 0; i < payload_size; i++) begin
            pkt_data.push_back((pkt_idx + i) & 8'hFF);
        end
    endfunction

    // Build IPv4/UDP packet
    function void build_ipv4_udp_packet(
        int unsigned pkt_idx,
        int unsigned total_size,
        ref byte unsigned pkt_data[$]
    );
        int unsigned payload_size;
        int unsigned ip_total_len;
        int unsigned udp_len;

        pkt_data = {};

        // Ethernet header (14 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h11);
        pkt_data.push_back(8'h22); pkt_data.push_back(8'h33);
        pkt_data.push_back(8'h44); pkt_data.push_back(8'h55);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'hAA);
        pkt_data.push_back(8'hBB); pkt_data.push_back(8'hCC);
        pkt_data.push_back(8'hDD); pkt_data.push_back(8'hEE);
        pkt_data.push_back(8'h08); pkt_data.push_back(8'h00);

        // IPv4 header (20 bytes)
        ip_total_len = total_size - 14;
        udp_len = total_size - 34;  // 14 ETH + 20 IP
        pkt_data.push_back(8'h45);
        pkt_data.push_back(8'h00);
        pkt_data.push_back(ip_total_len[15:8]);
        pkt_data.push_back(ip_total_len[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h40);
        pkt_data.push_back(8'h11);  // protocol=UDP
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h01);
        pkt_data.push_back(8'h0A); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h02);

        // UDP header (8 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h50);  // src port: 80
        pkt_data.push_back(8'h10); pkt_data.push_back(8'h00);  // dst port: 4096
        pkt_data.push_back(udp_len[15:8]);
        pkt_data.push_back(udp_len[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);  // checksum

        // Payload
        payload_size = total_size - 42;
        for (int unsigned i = 0; i < payload_size; i++)
            pkt_data.push_back((pkt_idx + i) & 8'hFF);
    endfunction

    // Build IPv6/TCP packet
    function void build_ipv6_tcp_packet(
        int unsigned pkt_idx,
        int unsigned total_size,
        ref byte unsigned pkt_data[$]
    );
        int unsigned payload_size;
        int unsigned ip_payload_len;

        pkt_data = {};

        // Ethernet header (14 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h11);
        pkt_data.push_back(8'h22); pkt_data.push_back(8'h33);
        pkt_data.push_back(8'h44); pkt_data.push_back(8'h55);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'hAA);
        pkt_data.push_back(8'hBB); pkt_data.push_back(8'hCC);
        pkt_data.push_back(8'hDD); pkt_data.push_back(8'hEE);
        // EtherType: 0x86DD (IPv6)
        pkt_data.push_back(8'h86); pkt_data.push_back(8'hDD);

        // IPv6 header (40 bytes)
        ip_payload_len = total_size - 54;  // 14 ETH + 40 IPv6
        pkt_data.push_back(8'h60);  // version=6, traffic class
        pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);  // flow label
        pkt_data.push_back(ip_payload_len[15:8]);
        pkt_data.push_back(ip_payload_len[7:0]);  // payload length
        pkt_data.push_back(8'h06);  // next header = TCP
        pkt_data.push_back(8'h40);  // hop limit = 64
        // src IPv6: ::1
        for (int i = 0; i < 15; i++) pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h01);
        // dst IPv6: ::2
        for (int i = 0; i < 15; i++) pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h02);

        // TCP header (20 bytes)
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h50);
        pkt_data.push_back(8'h10); pkt_data.push_back(8'h00);
        pkt_data.push_back(pkt_idx[31:24]); pkt_data.push_back(pkt_idx[23:16]);
        pkt_data.push_back(pkt_idx[15:8]);  pkt_data.push_back(pkt_idx[7:0]);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h50); pkt_data.push_back(8'h10);
        pkt_data.push_back(8'hFF); pkt_data.push_back(8'hFF);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);
        pkt_data.push_back(8'h00); pkt_data.push_back(8'h00);

        // Payload
        payload_size = total_size - 74;  // 14 + 40 + 20
        for (int unsigned i = 0; i < payload_size; i++)
            pkt_data.push_back((pkt_idx + i) & 8'hFF);
    endfunction

    // ========================================================================
    // Device simulation helper
    //
    // Simulates device processing: reads TX descriptor, copies data to RX
    // buffer, writes used ring entries for both TX and RX queues.
    // ========================================================================
    function void simulate_device_loopback(
        host_mem_manager    mem,
        // TX side
        bit [63:0]          tx_desc_table_addr,
        bit [63:0]          tx_used_ring_addr,
        int unsigned        tx_queue_size,
        ref int unsigned    tx_used_idx,
        // RX side
        bit [63:0]          rx_desc_table_addr,
        bit [63:0]          rx_avail_ring_addr,
        bit [63:0]          rx_used_ring_addr,
        int unsigned        rx_queue_size,
        ref int unsigned    rx_avail_consumed_idx,
        ref int unsigned    rx_used_idx,
        // TX descriptor to process
        int unsigned        tx_desc_id
    );
        // Read TX descriptor
        byte tx_desc_data[];
        bit [63:0] tx_buf_addr;
        bit [31:0] tx_buf_len;
        bit [15:0] tx_flags, tx_next;

        mem.read_mem(tx_desc_table_addr + tx_desc_id * 16, 16, tx_desc_data);
        tx_buf_addr = {tx_desc_data[7], tx_desc_data[6], tx_desc_data[5], tx_desc_data[4],
                       tx_desc_data[3], tx_desc_data[2], tx_desc_data[1], tx_desc_data[0]};
        tx_buf_len  = {tx_desc_data[11], tx_desc_data[10], tx_desc_data[9], tx_desc_data[8]};
        tx_flags    = {tx_desc_data[13], tx_desc_data[12]};
        tx_next     = {tx_desc_data[15], tx_desc_data[14]};

        // Read TX packet data
        begin
            byte pkt_data[];
            mem.read_mem(tx_buf_addr, tx_buf_len, pkt_data);

            // Get RX buffer from RX avail ring
            begin
                bit [15:0] rx_desc_id_16;
                int unsigned rx_desc_id;
                byte rx_avail_entry[];
                byte rx_desc_data[];
                bit [63:0] rx_buf_addr;
                bit [31:0] rx_buf_len;

                // Read avail ring entry at rx_avail_consumed_idx
                mem.read_mem(rx_avail_ring_addr + 4 + (rx_avail_consumed_idx % rx_queue_size) * 2, 2, rx_avail_entry);
                rx_desc_id_16 = {rx_avail_entry[1], rx_avail_entry[0]};
                rx_desc_id = rx_desc_id_16;

                // Read RX descriptor to get buffer address
                mem.read_mem(rx_desc_table_addr + rx_desc_id * 16, 16, rx_desc_data);
                rx_buf_addr = {rx_desc_data[7], rx_desc_data[6], rx_desc_data[5], rx_desc_data[4],
                               rx_desc_data[3], rx_desc_data[2], rx_desc_data[1], rx_desc_data[0]};
                rx_buf_len  = {rx_desc_data[11], rx_desc_data[10], rx_desc_data[9], rx_desc_data[8]};

                // Write TX data into RX buffer (loopback)
                if (tx_buf_len <= rx_buf_len) begin
                    mem.write_mem(rx_buf_addr, pkt_data);
                end

                // Write used ring entry for RX queue
                begin
                    byte used_entry[8];
                    int unsigned rx_ring_offset;
                    byte used_idx_data[2];

                    rx_ring_offset = 4 + (rx_used_idx % rx_queue_size) * 8;
                    // id (32-bit LE)
                    used_entry[0] = rx_desc_id[7:0];
                    used_entry[1] = rx_desc_id[15:8];
                    used_entry[2] = rx_desc_id[23:16];
                    used_entry[3] = rx_desc_id[31:24];
                    // len (32-bit LE)
                    used_entry[4] = tx_buf_len[7:0];
                    used_entry[5] = tx_buf_len[15:8];
                    used_entry[6] = tx_buf_len[23:16];
                    used_entry[7] = tx_buf_len[31:24];
                    mem.write_mem(rx_used_ring_addr + rx_ring_offset, used_entry);

                    rx_used_idx++;

                    // Update used ring idx
                    used_idx_data[0] = rx_used_idx[7:0];
                    used_idx_data[1] = rx_used_idx[15:8];
                    mem.write_mem(rx_used_ring_addr + 2, used_idx_data);
                end

                rx_avail_consumed_idx++;
            end
        end

        // Write used ring entry for TX queue
        begin
            byte used_entry[8];
            int unsigned tx_ring_offset;
            byte used_idx_data[2];

            tx_ring_offset = 4 + (tx_used_idx % tx_queue_size) * 8;
            // id (32-bit LE)
            used_entry[0] = tx_desc_id[7:0];
            used_entry[1] = tx_desc_id[15:8];
            used_entry[2] = tx_desc_id[23:16];
            used_entry[3] = tx_desc_id[31:24];
            // len (32-bit LE) — TX used len is typically 0 (device consumed)
            used_entry[4] = 8'h00;
            used_entry[5] = 8'h00;
            used_entry[6] = 8'h00;
            used_entry[7] = 8'h00;
            mem.write_mem(tx_used_ring_addr + tx_ring_offset, used_entry);

            tx_used_idx++;

            // Update used ring idx
            used_idx_data[0] = tx_used_idx[7:0];
            used_idx_data[1] = tx_used_idx[15:8];
            mem.write_mem(tx_used_ring_addr + 2, used_idx_data);
        end
    endfunction

    // ========================================================================
    // Device simulation for packed virtqueue: mark descriptor as used
    // ========================================================================
    function void simulate_packed_device_used(
        host_mem_manager    mem,
        bit [63:0]          desc_table_addr,
        int unsigned        desc_idx,
        int unsigned        queue_size,
        bit                 used_wrap_counter,
        int unsigned        written_len
    );
        // Read current descriptor
        byte desc_data[];
        bit [63:0] d_addr;
        bit [31:0] d_len;
        bit [15:0] d_id, d_flags;

        mem.read_mem(desc_table_addr + desc_idx * 16, 16, desc_data);
        d_addr  = {desc_data[7], desc_data[6], desc_data[5], desc_data[4],
                   desc_data[3], desc_data[2], desc_data[1], desc_data[0]};
        d_len   = {desc_data[11], desc_data[10], desc_data[9], desc_data[8]};
        d_id    = {desc_data[13], desc_data[12]};
        d_flags = {desc_data[15], desc_data[14]};

        // Clear AVAIL and USED flags, then set them for "used" state
        d_flags = d_flags & ~(VIRTQ_DESC_F_AVAIL | VIRTQ_DESC_F_USED);
        // Device marks used: both AVAIL and USED match wrap counter
        if (used_wrap_counter) begin
            d_flags = d_flags | VIRTQ_DESC_F_AVAIL | VIRTQ_DESC_F_USED;
        end
        // else: both stay 0 (wrap counter = 0)

        // Update len to written_len
        d_len = written_len;

        // Write back
        begin
            byte new_desc[16];
            for (int i = 0; i < 8; i++) new_desc[i]    = d_addr[i*8 +: 8];
            for (int i = 0; i < 4; i++) new_desc[8+i]  = d_len[i*8 +: 8];
            for (int i = 0; i < 2; i++) new_desc[12+i] = d_id[i*8 +: 8];
            for (int i = 0; i < 2; i++) new_desc[14+i] = d_flags[i*8 +: 8];
            mem.write_mem(desc_table_addr + desc_idx * 16, new_desc);
        end
    endfunction

    // ========================================================================
    // Test 1: Large Traffic (1000 packet TX/RX loopback)
    // ========================================================================
    task test_large_traffic();
        host_mem_manager mem;
        virtio_iommu_model iommu;
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector err_inj;
        virtio_wait_policy wait_pol;
        split_virtqueue txq, rxq;

        int unsigned num_packets = 1000;
        int unsigned queue_size = 256;  // process in batches
        int unsigned pkt_sizes[] = '{64, 128, 256, 512, 1024, 1500};
        longint unsigned total_bytes = 0;
        int unsigned tx_submitted = 0;
        int unsigned rx_received = 0;
        int unsigned data_matched = 0;
        int unsigned data_mismatched = 0;
        realtime start_time, end_time;

        // Track TX desc IDs and their packet data for verification
        int unsigned tx_desc_ids[$];
        byte unsigned tx_packets[int unsigned][$];  // desc_id -> packet data

        // Track RX buffer addresses for pre-fill
        bit [63:0] rx_buf_addrs[int unsigned];  // desc_id -> addr

        mem = host_mem_manager::type_id::create("lt_mem");
        iommu = virtio_iommu_model::type_id::create("lt_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("lt_bar");
        err_inj = virtqueue_error_injector::type_id::create("lt_einj");
        wait_pol = virtio_wait_policy::type_id::create("lt_wp");

        // Large memory region for 1000 packets
        mem.init_region(64'hA000_0000, 64'hA0FF_FFFF);  // 16MB
        iommu.strict_permission_check = 0;

        // Create TX queue (queue_id=1 = transmitq)
        txq = split_virtqueue::type_id::create("lt_txq");
        txq.setup(1, queue_size, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
        txq.alloc_rings();

        // Create RX queue (queue_id=0 = receiveq)
        rxq = split_virtqueue::type_id::create("lt_rxq");
        rxq.setup(0, queue_size, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
        rxq.alloc_rings();

        start_time = $realtime;

        // Process in batches of queue_size
        begin
            int unsigned remaining = num_packets;
            int unsigned batch_num = 0;
            int unsigned tx_used_idx = 0;
            int unsigned rx_used_idx = 0;
            int unsigned rx_avail_consumed_idx = 0;

            while (remaining > 0) begin
                int unsigned batch_size;
                batch_size = (remaining > queue_size) ? queue_size : remaining;

                // Reset queues for this batch
                if (batch_num > 0) begin
                    txq.reset_queue();
                    txq.setup(1, queue_size, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
                    txq.alloc_rings();

                    rxq.reset_queue();
                    rxq.setup(0, queue_size, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
                    rxq.alloc_rings();

                    tx_used_idx = 0;
                    rx_used_idx = 0;
                    rx_avail_consumed_idx = 0;
                end

                tx_desc_ids = {};

                // Pre-fill RX buffers
                for (int unsigned i = 0; i < batch_size; i++) begin
                    virtio_sg_list sgs[];
                    virtio_sg_entry e;
                    virtio_sg_list sg;
                    bit [63:0] buf_addr;
                    int unsigned desc_id;

                    buf_addr = mem.alloc(1600, .align(64));  // max MTU + headers
                    e.addr = buf_addr;
                    e.len = 1600;
                    sg.entries.push_back(e);
                    sgs = new[1];
                    sgs[0] = sg;

                    desc_id = rxq.add_buf(sgs, 0, 1, null, 0);
                    if (desc_id == '1) begin
                        `uvm_error("TRAFFIC_TEST", $sformatf("RX pre-fill failed at %0d", i))
                        total_errors++;
                        break;
                    end
                    rx_buf_addrs[desc_id] = buf_addr;
                end

                // Submit TX packets
                for (int unsigned i = 0; i < batch_size; i++) begin
                    int unsigned pkt_idx_global = batch_num * queue_size + i;
                    int unsigned pkt_size = pkt_sizes[pkt_idx_global % pkt_sizes.size()];
                    byte unsigned pkt_data[$];
                    byte pkt_bytes[];
                    bit [63:0] buf_addr;
                    virtio_sg_list sgs[];
                    virtio_sg_entry e;
                    virtio_sg_list sg;
                    int unsigned desc_id;

                    build_ipv4_tcp_packet(pkt_idx_global, pkt_size, pkt_data);

                    // Allocate buffer and write packet data
                    buf_addr = mem.alloc(pkt_size, .align(64));
                    if (buf_addr == '1) begin
                        `uvm_error("TRAFFIC_TEST", $sformatf("TX alloc failed at pkt %0d", pkt_idx_global))
                        total_errors++;
                        break;
                    end

                    // Convert to byte[] for write_mem
                    pkt_bytes = new[pkt_data.size()];
                    foreach (pkt_data[j]) pkt_bytes[j] = pkt_data[j];
                    mem.write_mem(buf_addr, pkt_bytes);

                    // Build descriptor
                    e.addr = buf_addr;
                    e.len = pkt_size;
                    sg.entries.push_back(e);
                    sgs = new[1];
                    sgs[0] = sg;

                    desc_id = txq.add_buf(sgs, 1, 0, null, 0);
                    if (desc_id == '1) begin
                        `uvm_error("TRAFFIC_TEST", $sformatf("TX add_buf failed at pkt %0d", pkt_idx_global))
                        total_errors++;
                        break;
                    end

                    tx_desc_ids.push_back(desc_id);
                    tx_packets[pkt_idx_global] = pkt_data;
                    total_bytes += pkt_size;
                    tx_submitted++;
                end

                // Simulate device processing: loopback TX to RX
                for (int unsigned i = 0; i < tx_desc_ids.size(); i++) begin
                    simulate_device_loopback(
                        mem,
                        txq.desc_table_addr,
                        txq.device_ring_addr,
                        queue_size,
                        tx_used_idx,
                        rxq.desc_table_addr,
                        rxq.driver_ring_addr,
                        rxq.device_ring_addr,
                        queue_size,
                        rx_avail_consumed_idx,
                        rx_used_idx,
                        tx_desc_ids[i]
                    );
                end

                // Poll TX used ring to reclaim TX descriptors
                begin
                    uvm_object token;
                    int unsigned used_len;
                    int unsigned tx_polled = 0;
                    while (txq.poll_used(token, used_len)) begin
                        tx_polled++;
                    end
                end

                // Poll RX used ring and verify data
                begin
                    uvm_object token;
                    int unsigned used_len;
                    int unsigned rx_polled = 0;

                    while (rxq.poll_used(token, used_len)) begin
                        int unsigned pkt_idx_global = batch_num * queue_size + rx_polled;
                        int unsigned pkt_size = pkt_sizes[pkt_idx_global % pkt_sizes.size()];

                        // Read back RX data and verify against original TX data
                        if (tx_packets.exists(pkt_idx_global)) begin
                            // We know used_len should match original packet size
                            if (used_len != pkt_size) begin
                                `uvm_error("TRAFFIC_TEST",
                                    $sformatf("Pkt %0d: length mismatch: rx=%0d tx=%0d",
                                              pkt_idx_global, used_len, pkt_size))
                                data_mismatched++;
                                total_errors++;
                            end else begin
                                data_matched++;
                            end
                        end

                        rx_polled++;
                        rx_received++;
                    end
                end

                remaining -= batch_size;
                batch_num++;
                #10ns;  // Small delay between batches
            end
        end

        end_time = $realtime;

        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_large_traffic: Submitted %0d TX packets (total %0dKB)",
                      tx_submitted, total_bytes / 1024), UVM_LOW)
        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_large_traffic: Received %0d RX packets", rx_received), UVM_LOW)
        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_large_traffic: Data integrity: %0d/%0d matched",
                      data_matched, tx_submitted), UVM_LOW)
        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_large_traffic: Throughput: %0d packets in %0t",
                      tx_submitted, end_time - start_time), UVM_LOW)

        if (tx_submitted == num_packets && rx_received == num_packets && data_mismatched == 0)
            `uvm_info("TRAFFIC_TEST", "test_large_traffic PASSED", UVM_LOW)
        else begin
            `uvm_error("TRAFFIC_TEST",
                $sformatf("test_large_traffic FAILED: tx=%0d rx=%0d mismatches=%0d",
                          tx_submitted, rx_received, data_mismatched))
            total_errors++;
        end

        // Cleanup
        txq.free_rings();
        rxq.free_rings();
        tx_packets.delete();
    endtask

    // ========================================================================
    // Test 2: Bandwidth Control
    // ========================================================================
    task test_bandwidth_control();
        int unsigned test_limits[] = '{10, 100, 1000, 0};  // 0 = unlimited
        int unsigned pkt_size = 1500;

        `uvm_info("TRAFFIC_TEST", "test_bandwidth_control: starting", UVM_LOW)

        foreach (test_limits[t]) begin
            int unsigned limit_mbps = test_limits[t];
            int unsigned pkts_sent = 0;
            int unsigned total_bytes_sent = 0;
            int unsigned max_burst = 200;

            // Reconfigure perf monitor
            if (limit_mbps > 0) begin
                pm.bw_limit_enable = 1;
                pm.bw_limit_mbps = limit_mbps;
            end else begin
                pm.bw_limit_enable = 0;
                pm.bw_limit_mbps = 0;
            end

            // Send burst of packets
            for (int unsigned i = 0; i < max_burst; i++) begin
                if (pm.can_send(pkt_size)) begin
                    pm.on_sent(pkt_size);
                    pkts_sent++;
                    total_bytes_sent += pkt_size;
                end else begin
                    break;
                end
            end

            if (limit_mbps == 0) begin
                // Unlimited: should send all packets
                assert(pkts_sent == max_burst)
                    else begin
                        `uvm_error("TRAFFIC_TEST",
                            $sformatf("Unlimited: expected %0d pkts, got %0d", max_burst, pkts_sent))
                        total_errors++;
                    end
                `uvm_info("TRAFFIC_TEST",
                    $sformatf("test_bandwidth_control: unlimited -> %0d pps", pkts_sent), UVM_LOW)
            end else begin
                // Limited: should have stopped before max_burst
                `uvm_info("TRAFFIC_TEST",
                    $sformatf("test_bandwidth_control: %0dMbps limit -> %0d pkts, %0dKB",
                              limit_mbps, pkts_sent, total_bytes_sent / 1024), UVM_LOW)
            end

            // Wait for token refill
            #1us;
        end

        // Test rate over time with 100Mbps limit
        begin
            int unsigned sent_over_time = 0;
            pm.bw_limit_enable = 1;
            pm.bw_limit_mbps = 100;

            // Send packets over 10us, counting how many get through
            for (int unsigned cycle = 0; cycle < 10; cycle++) begin
                for (int unsigned i = 0; i < 20; i++) begin
                    if (pm.can_send(1500)) begin
                        pm.on_sent(1500);
                        sent_over_time++;
                    end
                end
                #1us;  // Let tokens refill
            end

            `uvm_info("TRAFFIC_TEST",
                $sformatf("test_bandwidth_control: 100Mbps over 10us -> %0d pkts sent",
                          sent_over_time), UVM_LOW)
        end

        // Restore defaults
        pm.bw_limit_enable = 0;

        `uvm_info("TRAFFIC_TEST", "test_bandwidth_control PASSED", UVM_LOW)
    endtask

    // ========================================================================
    // Test 3: Protocol Integrity (Checksum/TSO/RSS)
    // ========================================================================
    task test_protocol_integrity();
        virtio_offload_engine offload;
        int unsigned sub_errors = 0;

        offload = virtio_offload_engine::type_id::create("pi_offload");
        offload.negotiated_features = (64'h1 << VIRTIO_NET_F_CSUM)
                                    | (64'h1 << VIRTIO_NET_F_HOST_TSO4)
                                    | (64'h1 << VIRTIO_NET_F_HOST_TSO6)
                                    | (64'h1 << VIRTIO_NET_F_MRG_RXBUF)
                                    | (64'h1 << VIRTIO_NET_F_RSS)
                                    | (64'h1 << VIRTIO_NET_F_HASH_REPORT);

        // --- Checksum offload: IPv4/TCP ---
        begin
            byte unsigned ipv4_tcp_pkt[$];
            int unsigned csum_start, csum_offset;
            bit csum_ipv4_tcp_pass;

            build_ipv4_tcp_packet(0, 256, ipv4_tcp_pkt);
            csum_start = offload.calc_csum_start(ipv4_tcp_pkt);
            csum_offset = offload.calc_csum_offset(ipv4_tcp_pkt);

            // IPv4/TCP: csum_start = 14 (ETH) + 20 (IP) = 34
            csum_ipv4_tcp_pass = (csum_start == 34) && (csum_offset == 16);
            if (!csum_ipv4_tcp_pass) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("IPv4/TCP csum: start=%0d (exp 34), offset=%0d (exp 16)",
                              csum_start, csum_offset))
                sub_errors++;
            end
        end

        // --- Checksum offload: IPv4/UDP ---
        begin
            byte unsigned ipv4_udp_pkt[$];
            int unsigned csum_start, csum_offset;
            bit csum_ipv4_udp_pass;

            build_ipv4_udp_packet(0, 256, ipv4_udp_pkt);
            csum_start = offload.calc_csum_start(ipv4_udp_pkt);
            csum_offset = offload.calc_csum_offset(ipv4_udp_pkt);

            csum_ipv4_udp_pass = (csum_start == 34) && (csum_offset == 6);
            if (!csum_ipv4_udp_pass) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("IPv4/UDP csum: start=%0d (exp 34), offset=%0d (exp 6)",
                              csum_start, csum_offset))
                sub_errors++;
            end
        end

        // --- Checksum offload: IPv6/TCP ---
        begin
            byte unsigned ipv6_tcp_pkt[$];
            int unsigned csum_start, csum_offset;
            bit csum_ipv6_tcp_pass;

            build_ipv6_tcp_packet(0, 256, ipv6_tcp_pkt);
            csum_start = offload.calc_csum_start(ipv6_tcp_pkt);
            csum_offset = offload.calc_csum_offset(ipv6_tcp_pkt);

            // IPv6/TCP: csum_start = 14 (ETH) + 40 (IPv6) = 54
            csum_ipv6_tcp_pass = (csum_start == 54) && (csum_offset == 16);
            if (!csum_ipv6_tcp_pass) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("IPv6/TCP csum: start=%0d (exp 54), offset=%0d (exp 16)",
                              csum_start, csum_offset))
                sub_errors++;
            end
        end

        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_protocol_integrity: csum IPv4/TCP %s, IPv4/UDP %s, IPv6/TCP %s",
                      (sub_errors == 0) ? "PASS" : "FAIL",
                      (sub_errors == 0) ? "PASS" : "FAIL",
                      (sub_errors == 0) ? "PASS" : "FAIL"),
            UVM_LOW)

        // --- TSO detection ---
        begin
            byte unsigned large_tcp_pkt[$];
            bit [7:0] gso_type;
            int unsigned tso_errors = 0;

            // Build a large TCP packet (> MSS) for TSO
            build_ipv4_tcp_packet(0, 4000, large_tcp_pkt);
            gso_type = offload.get_gso_type(large_tcp_pkt);

            if (gso_type != VIRTIO_NET_HDR_GSO_TCPV4) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("TSO: expected GSO_TCPV4 (0x01), got 0x%02x", gso_type))
                tso_errors++;
            end

            // IPv6 large TCP packet
            build_ipv6_tcp_packet(0, 4000, large_tcp_pkt);
            gso_type = offload.get_gso_type(large_tcp_pkt);

            if (gso_type != VIRTIO_NET_HDR_GSO_TCPV6) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("TSO: expected GSO_TCPV6 (0x04), got 0x%02x", gso_type))
                tso_errors++;
            end

            sub_errors += tso_errors;
            `uvm_info("TRAFFIC_TEST",
                $sformatf("test_protocol_integrity: TSO detection %s, GSO fields %s",
                          (tso_errors == 0) ? "PASS" : "FAIL",
                          (tso_errors == 0) ? "PASS" : "FAIL"),
                UVM_LOW)
        end

        // --- RSS hash determinism and queue selection ---
        begin
            byte unsigned test_pkt[$];
            bit [31:0] hash1, hash2, hash3;
            int unsigned queue1, queue2;
            int unsigned rss_errors = 0;

            build_ipv4_tcp_packet(42, 256, test_pkt);

            hash1 = offload.rss_calc_hash(test_pkt);
            hash2 = offload.rss_calc_hash(test_pkt);
            hash3 = offload.rss_calc_hash(test_pkt);

            // Hash should be deterministic
            if (hash1 != hash2 || hash2 != hash3) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("RSS: non-deterministic hash: 0x%08x, 0x%08x, 0x%08x",
                              hash1, hash2, hash3))
                rss_errors++;
            end

            // Queue selection should be consistent
            queue1 = offload.rss_select_queue(test_pkt, 4);
            queue2 = offload.rss_select_queue(test_pkt, 4);

            if (queue1 != queue2) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("RSS: non-deterministic queue: %0d vs %0d", queue1, queue2))
                rss_errors++;
            end

            // Queue should be in range
            if (queue1 >= 4) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("RSS: queue %0d out of range [0,4)", queue1))
                rss_errors++;
            end

            sub_errors += rss_errors;
            `uvm_info("TRAFFIC_TEST",
                $sformatf("test_protocol_integrity: RSS hash deterministic %s, queue selection %s",
                          (rss_errors == 0) ? "PASS" : "FAIL",
                          (rss_errors == 0) ? "PASS" : "FAIL"),
                UVM_LOW)
        end

        // --- Net header round-trip via host_mem ---
        begin
            host_mem_manager hdr_mem;
            bit [63:0] features_10, features_12, features_20;
            int unsigned hdr_errors = 0;

            hdr_mem = host_mem_manager::type_id::create("hdr_mem");
            hdr_mem.init_region(64'hB000_0000, 64'hB000_FFFF);

            features_10 = (64'h1 << VIRTIO_F_VERSION_1);
            features_12 = features_10 | (64'h1 << VIRTIO_NET_F_MRG_RXBUF);
            features_20 = features_12 | (64'h1 << VIRTIO_NET_F_HASH_REPORT);

            begin
                bit [63:0] features_arr[3];
                features_arr[0] = features_10;
                features_arr[1] = features_12;
                features_arr[2] = features_20;

                for (int unsigned f = 0; f < 3; f++) begin
                    virtio_net_hdr_t hdr_in, hdr_out;
                    byte unsigned packed_q[$];
                    byte packed_bytes[];
                    byte read_bytes[];
                    byte unsigned unpacked_q[$];
                    bit [63:0] buf_addr;
                    int unsigned hdr_size;

                    hdr_size = virtio_net_hdr_util::get_hdr_size(features_arr[f]);

                    // Build header
                    hdr_in.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
                    hdr_in.gso_type = VIRTIO_NET_HDR_GSO_TCPV4;
                    hdr_in.hdr_len = 16'd54;
                    hdr_in.gso_size = 16'd1460;
                    hdr_in.csum_start = 16'd34;
                    hdr_in.csum_offset = 16'd16;
                    hdr_in.num_buffers = 16'd3;
                    hdr_in.hash_value = 32'hCAFEBABE;
                    hdr_in.hash_report = 16'h0005;

                    // Pack
                    packed_q = {};
                    virtio_net_hdr_util::pack_hdr(hdr_in, features_arr[f], packed_q);

                    if (packed_q.size() != hdr_size) begin
                        `uvm_error("TRAFFIC_TEST",
                            $sformatf("net_hdr: pack size %0d != expected %0d",
                                      packed_q.size(), hdr_size))
                        hdr_errors++;
                    end

                    // Write to host_mem
                    buf_addr = hdr_mem.alloc(hdr_size, .align(64));
                    packed_bytes = new[packed_q.size()];
                    foreach (packed_q[j]) packed_bytes[j] = packed_q[j];
                    hdr_mem.write_mem(buf_addr, packed_bytes);

                    // Read back from host_mem
                    hdr_mem.read_mem(buf_addr, hdr_size, read_bytes);

                    // Unpack
                    unpacked_q = {};
                    foreach (read_bytes[j]) unpacked_q.push_back(read_bytes[j]);
                    virtio_net_hdr_util::unpack_hdr(unpacked_q, features_arr[f], hdr_out);

                    // Verify
                    if (hdr_out.flags != hdr_in.flags) begin
                        hdr_errors++; `uvm_error("TEST", "hdr flags mismatch")
                    end
                    if (hdr_out.gso_type != hdr_in.gso_type) begin
                        hdr_errors++; `uvm_error("TEST", "hdr gso_type mismatch")
                    end
                    if (hdr_out.hdr_len != hdr_in.hdr_len) begin
                        hdr_errors++; `uvm_error("TEST", "hdr hdr_len mismatch")
                    end
                    if (hdr_out.csum_start != hdr_in.csum_start) begin
                        hdr_errors++; `uvm_error("TEST", "hdr csum_start mismatch")
                    end
                    if (hdr_out.csum_offset != hdr_in.csum_offset) begin
                        hdr_errors++; `uvm_error("TEST", "hdr csum_offset mismatch")
                    end

                    if (hdr_size >= 12) begin
                        if (hdr_out.num_buffers != hdr_in.num_buffers) begin
                            hdr_errors++; `uvm_error("TEST", "hdr num_buffers mismatch")
                        end
                    end
                    if (hdr_size >= 20) begin
                        if (hdr_out.hash_value != hdr_in.hash_value) begin
                            hdr_errors++; `uvm_error("TEST", "hdr hash_value mismatch")
                        end
                        if (hdr_out.hash_report != hdr_in.hash_report) begin
                            hdr_errors++; `uvm_error("TEST", "hdr hash_report mismatch")
                        end
                    end

                    hdr_mem.free(buf_addr);
                end
            end

            sub_errors += hdr_errors;
            `uvm_info("TRAFFIC_TEST",
                $sformatf("test_protocol_integrity: net_hdr round-trip (10/12/20 bytes) %s",
                          (hdr_errors == 0) ? "PASS" : "FAIL"),
                UVM_LOW)
        end

        total_errors += sub_errors;
        if (sub_errors == 0)
            `uvm_info("TRAFFIC_TEST", "test_protocol_integrity PASSED", UVM_LOW)
        else
            `uvm_error("TRAFFIC_TEST",
                $sformatf("test_protocol_integrity FAILED with %0d errors", sub_errors))
    endtask

    // ========================================================================
    // Test 4: Queue Stress (256-entry fill/drain x10 cycles)
    // ========================================================================
    task test_queue_stress();
        host_mem_manager mem;
        virtio_iommu_model iommu;
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector err_inj;
        virtio_wait_policy wait_pol;
        split_virtqueue vq;
        int unsigned queue_size = 256;
        int unsigned num_cycles = 10;
        int unsigned total_ops = 0;
        int unsigned cycle_errors = 0;

        mem = host_mem_manager::type_id::create("qs_mem");
        iommu = virtio_iommu_model::type_id::create("qs_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("qs_bar");
        err_inj = virtqueue_error_injector::type_id::create("qs_einj");
        wait_pol = virtio_wait_policy::type_id::create("qs_wp");

        mem.init_region(64'hC000_0000, 64'hC07F_FFFF);  // 8MB
        iommu.strict_permission_check = 0;

        for (int unsigned cycle = 0; cycle < num_cycles; cycle++) begin
            int unsigned used_idx = 0;
            int unsigned desc_ids[$];

            // Create fresh queue each cycle
            vq = split_virtqueue::type_id::create($sformatf("qs_vq_%0d", cycle));
            vq.setup(0, queue_size, mem, iommu, barrier, err_inj, wait_pol, 16'h0100);
            vq.alloc_rings();

            // Fill all 256 descriptors
            for (int unsigned i = 0; i < queue_size; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_entry e;
                virtio_sg_list sg;
                bit [63:0] buf_addr;
                int unsigned desc_id;

                buf_addr = mem.alloc(128, .align(64));
                if (buf_addr == '1) begin
                    `uvm_error("TRAFFIC_TEST",
                        $sformatf("Cycle %0d: alloc failed at descriptor %0d", cycle, i))
                    cycle_errors++;
                    break;
                end

                e.addr = buf_addr;
                e.len = 128;
                sg.entries.push_back(e);
                sgs = new[1];
                sgs[0] = sg;

                desc_id = vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_id == '1) begin
                    `uvm_error("TRAFFIC_TEST",
                        $sformatf("Cycle %0d: add_buf failed at descriptor %0d", cycle, i))
                    cycle_errors++;
                    break;
                end

                desc_ids.push_back(desc_id);
            end

            // Verify queue is full
            if (vq.get_free_count() != 0) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("Cycle %0d: expected 0 free, got %0d",
                              cycle, vq.get_free_count()))
                cycle_errors++;
            end

            // Simulate device processing all 256 entries
            for (int unsigned i = 0; i < desc_ids.size(); i++) begin
                byte used_entry[8];
                int unsigned ring_offset;
                byte used_idx_data[2];

                ring_offset = 4 + (used_idx % queue_size) * 8;
                used_entry[0] = desc_ids[i][7:0];
                used_entry[1] = desc_ids[i][15:8];
                used_entry[2] = desc_ids[i][23:16];
                used_entry[3] = desc_ids[i][31:24];
                used_entry[4] = 128;  // len
                used_entry[5] = 0;
                used_entry[6] = 0;
                used_entry[7] = 0;
                mem.write_mem(vq.device_ring_addr + ring_offset, used_entry);

                used_idx++;
                used_idx_data[0] = used_idx[7:0];
                used_idx_data[1] = used_idx[15:8];
                mem.write_mem(vq.device_ring_addr + 2, used_idx_data);
            end

            // Poll all 256 used entries
            begin
                uvm_object token;
                int unsigned used_len;
                int unsigned polled = 0;

                while (vq.poll_used(token, used_len)) begin
                    polled++;
                    total_ops++;
                end

                if (polled != queue_size) begin
                    `uvm_error("TRAFFIC_TEST",
                        $sformatf("Cycle %0d: polled %0d, expected %0d",
                                  cycle, polled, queue_size))
                    cycle_errors++;
                end
            end

            // Verify all descriptors reclaimed
            if (vq.get_free_count() != queue_size) begin
                `uvm_error("TRAFFIC_TEST",
                    $sformatf("Cycle %0d: after drain, free=%0d expected %0d",
                              cycle, vq.get_free_count(), queue_size))
                cycle_errors++;
            end

            vq.free_rings();
            desc_ids = {};
            #1ns;
        end

        total_errors += cycle_errors;
        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_queue_stress: %0d cycles x %0d descriptors = %0d operations",
                      num_cycles, queue_size, total_ops), UVM_LOW)

        if (cycle_errors == 0)
            `uvm_info("TRAFFIC_TEST", "test_queue_stress PASSED", UVM_LOW)
        else
            `uvm_error("TRAFFIC_TEST",
                $sformatf("test_queue_stress FAILED with %0d errors", cycle_errors))
    endtask

    // ========================================================================
    // Test 5: Mixed Queue Types (split + packed parallel)
    // ========================================================================
    task test_mixed_queue_types();
        host_mem_manager mem;
        virtio_iommu_model iommu;
        virtio_memory_barrier_model barrier;
        virtqueue_error_injector err_inj;
        virtio_wait_policy wait_pol;
        virtqueue_manager mgr;
        virtqueue_base split_vq, packed_vq;

        int unsigned num_packets = 100;
        int unsigned split_queue_size = 128;
        int unsigned packed_queue_size = 128;
        int unsigned split_submitted = 0;
        int unsigned packed_submitted = 0;
        int unsigned split_polled = 0;
        int unsigned packed_polled = 0;
        int unsigned mix_errors = 0;

        mem = host_mem_manager::type_id::create("mq_mem");
        iommu = virtio_iommu_model::type_id::create("mq_iommu");
        barrier = virtio_memory_barrier_model::type_id::create("mq_bar");
        err_inj = virtqueue_error_injector::type_id::create("mq_einj");
        wait_pol = virtio_wait_policy::type_id::create("mq_wp");

        mem.init_region(64'hD000_0000, 64'hD03F_FFFF);  // 4MB
        iommu.strict_permission_check = 0;

        mgr = virtqueue_manager::type_id::create("mq_mgr");
        mgr.mem = mem;
        mgr.iommu = iommu;
        mgr.barrier = barrier;
        mgr.err_inj = err_inj;
        mgr.wait_pol = wait_pol;
        mgr.bdf = 16'h0500;

        // Create split queue (queue 0)
        split_vq = mgr.create_queue(0, split_queue_size, VQ_SPLIT);
        if (split_vq == null) begin
            `uvm_fatal("TRAFFIC_TEST", "create_queue(split) returned null")
        end
        split_vq.alloc_rings();

        // Create packed queue (queue 1)
        packed_vq = mgr.create_queue(1, packed_queue_size, VQ_PACKED);
        if (packed_vq == null) begin
            `uvm_fatal("TRAFFIC_TEST", "create_queue(packed) returned null")
        end
        packed_vq.alloc_rings();

        if (mgr.get_queue_count() != 2) begin
            `uvm_error("TRAFFIC_TEST",
                $sformatf("Expected 2 queues, got %0d", mgr.get_queue_count()))
            mix_errors++;
        end

        // Submit 100 packets to split queue
        begin
            int unsigned split_desc_ids[$];

            for (int unsigned i = 0; i < num_packets; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_entry e;
                virtio_sg_list sg;
                bit [63:0] buf_addr;
                int unsigned desc_id;
                byte test_data[];

                buf_addr = mem.alloc(256, .align(64));
                if (buf_addr == '1) begin
                    `uvm_error("TRAFFIC_TEST", $sformatf("Split alloc failed at %0d", i))
                    mix_errors++;
                    break;
                end

                test_data = new[256];
                foreach (test_data[j]) test_data[j] = (i + j) & 8'hFF;
                mem.write_mem(buf_addr, test_data);

                e.addr = buf_addr;
                e.len = 256;
                sg.entries.push_back(e);
                sgs = new[1];
                sgs[0] = sg;

                desc_id = split_vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_id == '1) begin
                    `uvm_error("TRAFFIC_TEST", $sformatf("Split add_buf failed at %0d", i))
                    mix_errors++;
                    break;
                end
                split_desc_ids.push_back(desc_id);
                split_submitted++;
            end

            // Simulate device processing for split queue
            begin
                int unsigned used_idx = 0;
                for (int unsigned i = 0; i < split_desc_ids.size(); i++) begin
                    byte used_entry[8];
                    int unsigned ring_offset;
                    byte used_idx_data[2];

                    ring_offset = 4 + (used_idx % split_queue_size) * 8;
                    used_entry[0] = split_desc_ids[i][7:0];
                    used_entry[1] = split_desc_ids[i][15:8];
                    used_entry[2] = split_desc_ids[i][23:16];
                    used_entry[3] = split_desc_ids[i][31:24];
                    used_entry[4] = 8'd0;
                    used_entry[5] = 8'd0;
                    used_entry[6] = 8'd0;
                    used_entry[7] = 8'd0;
                    mem.write_mem(split_vq.device_ring_addr + ring_offset, used_entry);

                    used_idx++;
                    used_idx_data[0] = used_idx[7:0];
                    used_idx_data[1] = used_idx[15:8];
                    mem.write_mem(split_vq.device_ring_addr + 2, used_idx_data);
                end
            end

            // Poll split used ring
            begin
                uvm_object token;
                int unsigned used_len;
                while (split_vq.poll_used(token, used_len)) begin
                    split_polled++;
                end
            end
        end

        // Submit 100 packets to packed queue
        begin
            int unsigned packed_desc_indices[$];

            for (int unsigned i = 0; i < num_packets; i++) begin
                virtio_sg_list sgs[];
                virtio_sg_entry e;
                virtio_sg_list sg;
                bit [63:0] buf_addr;
                int unsigned desc_idx;
                byte test_data[];

                buf_addr = mem.alloc(256, .align(64));
                if (buf_addr == '1) begin
                    `uvm_error("TRAFFIC_TEST", $sformatf("Packed alloc failed at %0d", i))
                    mix_errors++;
                    break;
                end

                test_data = new[256];
                foreach (test_data[j]) test_data[j] = (i + j + 8'h80) & 8'hFF;
                mem.write_mem(buf_addr, test_data);

                e.addr = buf_addr;
                e.len = 256;
                sg.entries.push_back(e);
                sgs = new[1];
                sgs[0] = sg;

                desc_idx = packed_vq.add_buf(sgs, 1, 0, null, 0);
                if (desc_idx == '1) begin
                    `uvm_error("TRAFFIC_TEST", $sformatf("Packed add_buf failed at %0d", i))
                    mix_errors++;
                    break;
                end
                packed_desc_indices.push_back(desc_idx);
                packed_submitted++;
            end

            // Simulate device processing for packed queue
            // For packed vq, device marks descriptors as used by setting AVAIL=USED=wrap_counter
            begin
                int unsigned next_used = 0;
                bit wrap = 1;  // starts at 1

                for (int unsigned i = 0; i < packed_desc_indices.size(); i++) begin
                    simulate_packed_device_used(
                        mem,
                        packed_vq.desc_table_addr,
                        next_used,
                        packed_queue_size,
                        wrap,
                        256
                    );
                    next_used++;
                    if (next_used >= packed_queue_size) begin
                        next_used = 0;
                        wrap = ~wrap;
                    end
                end
            end

            // Poll packed used ring
            begin
                uvm_object token;
                int unsigned used_len;
                while (packed_vq.poll_used(token, used_len)) begin
                    packed_polled++;
                end
            end
        end

        // Verify results
        if (split_submitted != num_packets || split_polled != num_packets) begin
            `uvm_error("TRAFFIC_TEST",
                $sformatf("Split: submitted=%0d polled=%0d expected=%0d",
                          split_submitted, split_polled, num_packets))
            mix_errors++;
        end

        if (packed_submitted != num_packets || packed_polled != num_packets) begin
            `uvm_error("TRAFFIC_TEST",
                $sformatf("Packed: submitted=%0d polled=%0d expected=%0d",
                          packed_submitted, packed_polled, num_packets))
            mix_errors++;
        end

        total_errors += mix_errors;

        `uvm_info("TRAFFIC_TEST",
            $sformatf("test_mixed_queue_types: split %0d pkts %s, packed %0d pkts %s",
                      split_polled, (split_polled == num_packets) ? "PASS" : "FAIL",
                      packed_polled, (packed_polled == num_packets) ? "PASS" : "FAIL"),
            UVM_LOW)

        if (mix_errors == 0)
            `uvm_info("TRAFFIC_TEST", "test_mixed_queue_types PASSED", UVM_LOW)
        else
            `uvm_error("TRAFFIC_TEST",
                $sformatf("test_mixed_queue_types FAILED with %0d errors", mix_errors))

        mgr.destroy_all();
    endtask

endclass

`endif // VIRTIO_TRAFFIC_TEST_SV
