`ifndef VIRTIO_PERF_MONITOR_SV
`define VIRTIO_PERF_MONITOR_SV

// ============================================================================
// virtio_perf_monitor
//
// Performance monitor with synchronous token-bucket bandwidth limiting and
// per-VF/global latency profiling.
//
// Bandwidth limiting:
//   - Synchronous refill (no background task) -- called from can_send/on_sent
//   - Token bucket sized for configured bw_limit_mbps
//   - Refill tokens proportional to elapsed simulation time
//
// Statistics:
//   - Per-VF TX/RX byte/packet counts
//   - Global aggregate stats
//   - Per-packet latency samples with stage breakdown
//   - Report: min/max/avg/p50/p95/p99 latency per stage
//
// Depends on: virtio_net_types.sv (perf_stats_t, pkt_latency_t)
// ============================================================================

class virtio_perf_monitor extends uvm_component;
    `uvm_component_utils(virtio_perf_monitor)

    // ===== Bandwidth limiting (synchronous) =====
    bit           bw_limit_enable = 0;
    int unsigned  bw_limit_mbps = 0;
    protected int unsigned  token_bucket = 0;
    protected int unsigned  bucket_size = 0;
    protected realtime      last_refill_time;

    // ===== Per-VF stats =====
    perf_stats_t  vf_stats[int unsigned];
    perf_stats_t  global_stats;

    // ===== Latency samples =====
    pkt_latency_t latency_samples[$];

    // ========================================================================
    // Constructor
    // ========================================================================

    function new(string name, uvm_component parent);
        super.new(name, parent);
        global_stats = '{default: 0, start_time: 0, end_time: 0};
        last_refill_time = 0;
    endfunction

    // ========================================================================
    // build_phase -- Initialize token bucket
    // ========================================================================

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        if (bw_limit_enable && bw_limit_mbps > 0) begin
            // Bucket size = 1ms worth of bytes at configured rate
            // mbps -> bytes/ms = mbps * 1000 / 8 = mbps * 125
            bucket_size = bw_limit_mbps * 125;
            token_bucket = bucket_size;
            `uvm_info("PERF_MON",
                $sformatf("BW limit: %0d Mbps, bucket_size=%0d bytes",
                          bw_limit_mbps, bucket_size),
                UVM_LOW)
        end
    endfunction

    // ========================================================================
    // sync_refill -- Synchronous token refill
    //
    // Called from can_send() and on_sent(). Calculates elapsed simulation
    // time since last refill and adds proportional tokens, capped at
    // bucket_size.
    // ========================================================================

    protected function void sync_refill();
        realtime now;
        realtime elapsed_ns;
        int unsigned tokens_to_add;

        now = $realtime;
        if (last_refill_time == 0) begin
            last_refill_time = now;
            return;
        end

        elapsed_ns = now - last_refill_time;
        if (elapsed_ns <= 0) return;

        // tokens = elapsed_ns * rate_bytes_per_ns
        // rate_bytes_per_ns = bw_limit_mbps * 1e6 / 8 / 1e9 = bw_limit_mbps / 8000
        // To avoid floating point: tokens = elapsed_ns * bw_limit_mbps / 8000
        tokens_to_add = $rtoi(elapsed_ns) * bw_limit_mbps / 8000;

        if (tokens_to_add > 0) begin
            token_bucket = token_bucket + tokens_to_add;
            if (token_bucket > bucket_size)
                token_bucket = bucket_size;
            last_refill_time = now;
        end
    endfunction

    // ========================================================================
    // can_send -- Check if bandwidth budget allows sending 'bytes' bytes
    //
    // Returns 1 if sending is permitted, 0 if rate-limited.
    // Always returns 1 when bw_limit_enable is off.
    // ========================================================================

    function bit can_send(int unsigned bytes);
        if (!bw_limit_enable) return 1;
        sync_refill();
        return token_bucket >= bytes;
    endfunction

    // ========================================================================
    // on_sent -- Deduct tokens after successfully sending bytes
    // ========================================================================

    function void on_sent(int unsigned bytes);
        if (bw_limit_enable) begin
            sync_refill();
            token_bucket = (token_bucket > bytes) ? (token_bucket - bytes) : 0;
        end
    endfunction

    // ========================================================================
    // record_latency -- Record a per-packet latency sample
    // ========================================================================

    function void record_latency(pkt_latency_t sample);
        latency_samples.push_back(sample);
    endfunction

    // ========================================================================
    // update_vf_stats -- Update per-VF and global byte/packet counters
    // ========================================================================

    function void update_vf_stats(int unsigned vf_id, int unsigned tx_bytes, int unsigned rx_bytes);
        realtime now = $realtime;

        // Initialize VF stats if first access
        if (!vf_stats.exists(vf_id)) begin
            vf_stats[vf_id] = '{default: 0, start_time: now, end_time: now};
        end

        // Update VF stats
        if (tx_bytes > 0) begin
            vf_stats[vf_id].tx_packets++;
            vf_stats[vf_id].tx_bytes += tx_bytes;
        end
        if (rx_bytes > 0) begin
            vf_stats[vf_id].rx_packets++;
            vf_stats[vf_id].rx_bytes += rx_bytes;
        end
        vf_stats[vf_id].end_time = now;

        // Update global stats
        if (global_stats.start_time == 0)
            global_stats.start_time = now;
        global_stats.tx_packets += (tx_bytes > 0) ? 1 : 0;
        global_stats.tx_bytes   += tx_bytes;
        global_stats.rx_packets += (rx_bytes > 0) ? 1 : 0;
        global_stats.rx_bytes   += rx_bytes;
        global_stats.end_time    = now;
    endfunction

    // ========================================================================
    // report_phase -- Print performance summary
    // ========================================================================

    virtual function void report_phase(uvm_phase phase);
        string report;
        realtime duration_ns;

        super.report_phase(phase);

        report = "\n========== Virtio Performance Report ==========\n";

        // Global throughput
        duration_ns = global_stats.end_time - global_stats.start_time;
        report = {report, $sformatf("  Global Stats:\n")};
        report = {report, $sformatf("    TX: %0d pkts, %0d bytes\n",
                                    global_stats.tx_packets, global_stats.tx_bytes)};
        report = {report, $sformatf("    RX: %0d pkts, %0d bytes\n",
                                    global_stats.rx_packets, global_stats.rx_bytes)};
        if (duration_ns > 0) begin
            real tx_mbps, rx_mbps;
            tx_mbps = (real'(global_stats.tx_bytes) * 8.0) / (real'(duration_ns) / 1000.0);
            rx_mbps = (real'(global_stats.rx_bytes) * 8.0) / (real'(duration_ns) / 1000.0);
            report = {report, $sformatf("    TX throughput: %.2f Mbps\n", tx_mbps)};
            report = {report, $sformatf("    RX throughput: %.2f Mbps\n", rx_mbps)};
        end

        // Per-VF throughput
        foreach (vf_stats[vf_id]) begin
            realtime vf_dur;
            vf_dur = vf_stats[vf_id].end_time - vf_stats[vf_id].start_time;
            report = {report, $sformatf("  VF%0d: TX=%0d pkts/%0d bytes, RX=%0d pkts/%0d bytes",
                                        vf_id,
                                        vf_stats[vf_id].tx_packets, vf_stats[vf_id].tx_bytes,
                                        vf_stats[vf_id].rx_packets, vf_stats[vf_id].rx_bytes)};
            if (vf_dur > 0) begin
                real vf_tx_mbps;
                vf_tx_mbps = (real'(vf_stats[vf_id].tx_bytes) * 8.0) / (real'(vf_dur) / 1000.0);
                report = {report, $sformatf(" (%.2f Mbps)", vf_tx_mbps)};
            end
            report = {report, "\n"};
        end

        // Latency distribution
        if (latency_samples.size() > 0) begin
            realtime total_latencies[$];
            realtime min_lat, max_lat, avg_lat, sum_lat;

            // Compute total end-to-end latency per sample
            foreach (latency_samples[i]) begin
                realtime total;
                total = latency_samples[i].complete_time - latency_samples[i].desc_fill_time;
                total_latencies.push_back(total);
            end

            // Sort for percentiles
            total_latencies.sort();

            min_lat = total_latencies[0];
            max_lat = total_latencies[total_latencies.size() - 1];
            sum_lat = 0;
            foreach (total_latencies[i]) sum_lat += total_latencies[i];
            avg_lat = sum_lat / total_latencies.size();

            report = {report, $sformatf("  Latency (%0d samples):\n", latency_samples.size())};
            report = {report, $sformatf("    min=%.0f ns, max=%.0f ns, avg=%.0f ns\n",
                                        min_lat, max_lat, avg_lat)};

            // Percentiles
            if (total_latencies.size() >= 2) begin
                int unsigned p50_idx, p95_idx, p99_idx;
                p50_idx = total_latencies.size() / 2;
                p95_idx = (total_latencies.size() * 95) / 100;
                p99_idx = (total_latencies.size() * 99) / 100;
                if (p95_idx >= total_latencies.size()) p95_idx = total_latencies.size() - 1;
                if (p99_idx >= total_latencies.size()) p99_idx = total_latencies.size() - 1;
                report = {report, $sformatf("    p50=%.0f ns, p95=%.0f ns, p99=%.0f ns\n",
                                            total_latencies[p50_idx],
                                            total_latencies[p95_idx],
                                            total_latencies[p99_idx])};
            end
        end else begin
            report = {report, "  Latency: no samples recorded\n"};
        end

        if (bw_limit_enable)
            report = {report, $sformatf("  BW limit: %0d Mbps (enabled)\n", bw_limit_mbps)};

        report = {report, "==============================================="};

        `uvm_info("PERF_MON", report, UVM_LOW)
    endfunction

endclass : virtio_perf_monitor

`endif // VIRTIO_PERF_MONITOR_SV
