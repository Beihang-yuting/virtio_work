`ifndef VIRTIO_FAILOVER_SEQ_SV
`define VIRTIO_FAILOVER_SEQ_SV

// ============================================================================
// virtio_failover_seq (seq/scenario/migration)
//
// STANDBY/failover 场景骨架:置起 VIRTIO_NET_F_STANDBY 后,按
// primary 流量 -> 触发主链路事件 -> standby 流量 -> failback 的顺序走一遍
// 主备切换路径。说明(观察事实):"link down/failback" 均以
// ANNOUNCE 类 ctrl 命令(ANNOUNCE_ACK)近似表达,主备只是日志上的角色
// 区分,并未切换到另一个 function/sequencer——真实主备设备对的建模不在
// 本序列内。约束意图:每阶段 4..32 包,保证两侧都有可核对的流量。
// ============================================================================

class virtio_failover_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_failover_seq)

    rand int unsigned traffic_pkts;

    constraint c_defaults {
        traffic_pkts inside {[4:32]};
    }

    // 构造函数:默认每阶段 8 包。
    function new(string name = "virtio_failover_seq");
        super.new(name);
        traffic_pkts = 8;
    endfunction

    // 依次执行 primary 流量 / 链路事件 / standby 流量 / failback;
    // 切换语义的核对(流量不中断等)由上层环境完成。
    virtual task body();
        virtio_transaction req;
        virtio_tx_seq tx_s;

        // Init primary with STANDBY feature
        negotiated_features[VIRTIO_NET_F_STANDBY] = 1'b1;
        do_init();
        send_txn(VIO_TXN_START_DP);

        // Traffic on primary
        `uvm_info(get_type_name(), "Sending traffic on primary", UVM_MEDIUM)
        tx_s = virtio_tx_seq::type_id::create("tx_primary");
        tx_s.num_packets         = traffic_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Trigger link down on primary (via ctrl command)
        `uvm_info(get_type_name(), "Triggering primary link down", UVM_MEDIUM)
        req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_CTRL_CMD;
        req.ctrl_class = VIRTIO_NET_CTRL_CLS_ANNOUNCE;
        req.ctrl_cmd   = VIRTIO_NET_CTRL_ANNOUNCE_ACK;
        send_configured_txn(req);

        // Failover: standby becomes active
        `uvm_info(get_type_name(), "Failover: activating standby", UVM_MEDIUM)

        // Verify standby is active with traffic
        tx_s = virtio_tx_seq::type_id::create("tx_standby");
        tx_s.num_packets         = traffic_pkts;
        tx_s.drv_cfg             = drv_cfg;
        tx_s.negotiated_features = negotiated_features;
        tx_s.start(m_sequencer);

        // Failback
        `uvm_info(get_type_name(), "Failback: restoring primary", UVM_MEDIUM)
        req = virtio_transaction::type_id::create("req");
        req.txn_type   = VIO_TXN_CTRL_CMD;
        req.ctrl_class = VIRTIO_NET_CTRL_CLS_ANNOUNCE;
        req.ctrl_cmd   = VIRTIO_NET_CTRL_ANNOUNCE_ACK;
        send_configured_txn(req);

        `uvm_info(get_type_name(), "Failover sequence complete", UVM_LOW)
    endtask

endclass

`endif // VIRTIO_FAILOVER_SEQ_SV
