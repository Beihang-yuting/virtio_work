`ifndef VIRTIO_RSS_DISTRIBUTION_SEQ_SV
`define VIRTIO_RSS_DISTRIBUTION_SEQ_SV

// ============================================================================
// virtio_rss_distribution_seq (seq/scenario/dataplane)
//
// RSS 分流场景:先用 VIO_TXN_SET_RSS 下发随机 40 字节 hash key + 128 项
// 间接表(按 i % num_queues 均匀铺开,hash_types 选 IPv4/TCP/UDP),再发
// num_flows 个单包 tx 序列模拟不同流。说明(观察事实):tx 侧统一走
// queue_id 0 且未构造差异化五元组,"不同流"的散列效果依赖设备/环境侧
// 报文生成;各队列分布是否均匀由覆盖率/记分板观察,本序列不检查。
// 约束意图:4..64 条流、2..8 个队列,保证间接表映射到多队列。
// ============================================================================

class virtio_rss_distribution_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_rss_distribution_seq)

    rand int unsigned num_flows;
    rand int unsigned num_queues;

    constraint c_defaults {
        num_flows  inside {[4:64]};
        num_queues inside {[2:8]};
    }

    // 构造函数:默认 16 条流散到 4 个队列。
    function new(string name = "virtio_rss_distribution_seq");
        super.new(name);
        num_flows  = 16;
        num_queues = 4;
    endfunction

    // init -> 配置 RSS(随机 key + 均匀间接表)-> 启动数据面 -> 逐流发
    // 单包 tx;RSS 配置失败的处理在 driver 侧。
    virtual task body();
        virtio_transaction req;

        do_init();

        // Configure RSS
        req = virtio_transaction::type_id::create("req");
        req.txn_type = VIO_TXN_SET_RSS;
        req.rss_cfg.hash_types = 32'h0000_002B; // IPv4/TCP/UDP
        req.rss_cfg.hash_key_size = 40;
        req.rss_cfg.hash_key = new[40];
        foreach (req.rss_cfg.hash_key[i])
            req.rss_cfg.hash_key[i] = $urandom_range(0, 255);
        req.rss_cfg.indirection_table = new[128];
        foreach (req.rss_cfg.indirection_table[i])
            req.rss_cfg.indirection_table[i] = i % num_queues;
        send_configured_txn(req);

        send_txn(VIO_TXN_START_DP);

        // Send packets with different flow tuples
        for (int i = 0; i < num_flows; i++) begin
            virtio_tx_seq tx_s = virtio_tx_seq::type_id::create("tx_s");
            tx_s.num_packets         = 1;
            tx_s.queue_id            = 0;
            tx_s.drv_cfg             = drv_cfg;
            tx_s.negotiated_features = negotiated_features;
            tx_s.start(m_sequencer);
        end

        `uvm_info(get_type_name(), $sformatf(
            "RSS: sent %0d flows across %0d queues", num_flows, num_queues), UVM_MEDIUM)
    endtask

endclass

`endif // VIRTIO_RSS_DISTRIBUTION_SEQ_SV
