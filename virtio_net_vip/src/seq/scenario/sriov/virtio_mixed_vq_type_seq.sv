`ifndef VIRTIO_MIXED_VQ_TYPE_SEQ_SV
`define VIRTIO_MIXED_VQ_TYPE_SEQ_SV

// ============================================================================
// virtio_mixed_vq_type_seq (seq/scenario/sriov)
//
// 混合 virtqueue 类型场景:置起 SR-IOV + RING_PACKED,给 3 个"VF"分别按
// split/packed/custom 三种 ring 类型配队列(queue_id = i*2),然后并行发
// 流量,验证不同 ring 实现共存时互不干扰。与 concurrency 场景同属单
// sequencer 上的伪并发(见文件内 fork/join_none 结构:外层 join 只等
// for 循环展开,不等各 VF 流量结束)。
// 约束意图:每 VF 2..16 包;VF 数固定 3 以一一对应三种 ring 类型。
// ============================================================================

class virtio_mixed_vq_type_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_mixed_vq_type_seq)

    rand int unsigned pkts_per_vf;

    constraint c_defaults {
        pkts_per_vf inside {[2:16]};
    }

    // 构造函数:默认每 VF 4 包。
    function new(string name = "virtio_mixed_vq_type_seq");
        super.new(name);
        pkts_per_vf = 4;
    endfunction

    // 三个队列按三种 ring 类型 setup -> init -> 并行流量;类型间隔离由
    // scoreboard 核对。
    virtual task body();
        virtqueue_type_e vf_types[3] = '{VQ_SPLIT, VQ_PACKED, VQ_CUSTOM};

        negotiated_features[VIRTIO_F_SR_IOV]      = 1'b1;
        negotiated_features[VIRTIO_F_RING_PACKED]  = 1'b1;

        // Setup each VF with a different virtqueue type
        for (int i = 0; i < 3; i++) begin
            virtio_queue_setup_seq qs = virtio_queue_setup_seq::type_id::create(
                $sformatf("qs_vf%0d", i));
            qs.queue_id            = i * 2;
            qs.queue_size          = 256;
            qs.vq_type             = vf_types[i];
            qs.drv_cfg             = drv_cfg;
            qs.negotiated_features = negotiated_features;
            qs.start(m_sequencer);
        end

        do_init();
        send_txn(VIO_TXN_START_DP);

        // Parallel traffic on all VFs
        fork
            for (int i = 0; i < 3; i++) begin
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
            "Mixed VQ: split/packed/custom, %0d pkts each", pkts_per_vf), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_MIXED_VQ_TYPE_SEQ_SV
