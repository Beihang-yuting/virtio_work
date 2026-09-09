`ifndef VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV
`define VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV

// ============================================================================
// virtio_concurrent_vf_traffic_seq (seq/scenario/concurrency)
//
// 多 VF 并发流量场景:置起 SR-IOV feature 后,对 num_vfs 个"VF"同时发起
// TX 流量,验证并发下的队列仲裁与隔离。注意本序列跑在单一 sequencer 上,
// 用 queue_id = vf_id*2 区分各 VF 的队列,并发性来自 fork 的多个
// virtio_tx_seq 同时竞争 sequencer(真正跨 sequencer 的多 VF 场景见
// seq/virtual/virtio_multi_vf_vseq)。
// 结构说明(观察事实):内层线程 join_none 挂起,外层 join 只等 for 循环
// 展开完毕,不等各 VF 流量真正结束。
// 约束意图:2..8 个 VF、每 VF 4..32 包,规模适中避免仿真过长。
// ============================================================================

class virtio_concurrent_vf_traffic_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_concurrent_vf_traffic_seq)

    rand int unsigned num_vfs;
    rand int unsigned pkts_per_vf;

    constraint c_defaults {
        num_vfs    inside {[2:8]};
        pkts_per_vf inside {[4:32]};
    }

    // 构造函数:默认 4 VF、每 VF 8 包。
    function new(string name = "virtio_concurrent_vf_traffic_seq");
        super.new(name);
        num_vfs    = 4;
        pkts_per_vf = 8;
    endfunction

    // init + 启动数据面后,fork 出每 VF 一个 tx 子序列并发发包;
    // 并发正确性(不串包、不互扰)由 scoreboard 核对。
    virtual task body();
        negotiated_features[VIRTIO_F_SR_IOV] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        `uvm_info(get_type_name(), $sformatf(
            "Starting concurrent traffic: %0d VFs, %0d pkts each",
            num_vfs, pkts_per_vf), UVM_MEDIUM)

        // All VFs send traffic simultaneously
        fork
            for (int i = 0; i < num_vfs; i++) begin
                automatic int vf_id = i;
                fork
                    begin
                        virtio_tx_seq tx_s = virtio_tx_seq::type_id::create(
                            $sformatf("tx_vf%0d", vf_id));
                        tx_s.num_packets         = pkts_per_vf;
                        tx_s.queue_id            = vf_id * 2;
                        tx_s.drv_cfg             = drv_cfg;
                        tx_s.negotiated_features = negotiated_features;
                        tx_s.start(m_sequencer);
                    end
                join_none
            end
        join

        `uvm_info(get_type_name(), $sformatf(
            "Concurrent VF traffic complete: %0d VFs", num_vfs), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_CONCURRENT_VF_TRAFFIC_SEQ_SV
