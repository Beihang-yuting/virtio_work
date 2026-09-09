`ifndef VIRTIO_MULTI_VF_INIT_SEQ_SV
`define VIRTIO_MULTI_VF_INIT_SEQ_SV

// ============================================================================
// virtio_multi_vf_init_seq (seq/scenario/sriov)
//
// 多 VF 并行初始化场景:置起 SR-IOV feature,先经 do_init 初始化 PF,再
// 对 num_vfs 个 VF 并行发 VIO_TXN_INIT(以 queue_id 携带 vf_id 区分)。
// 目标是覆盖多个 function 同时走初始化状态机时的竞争。说明(观察事实):
// 单 sequencer 上的并发,且内层线程 join_none 挂起、外层 join 只等 for
// 循环展开;跨 sequencer 的真实多 VF 初始化见 seq/virtual/
// virtio_multi_vf_vseq。约束意图:2..8 个 VF、每 VF 1 对 split 队列。
// ============================================================================

class virtio_multi_vf_init_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_multi_vf_init_seq)

    rand int unsigned num_vfs;

    constraint c_defaults {
        num_vfs inside {[2:8]};
    }

    // 构造函数:默认 4 个 VF。
    function new(string name = "virtio_multi_vf_init_seq");
        super.new(name);
        num_vfs = 4;
    endfunction

    // PF init 后并行下发各 VF 的 INIT 事务;初始化结果核对(队列映射等)
    // 由 driver/环境完成,本序列只打日志。
    virtual task body();
        // Enable SR-IOV feature
        negotiated_features[VIRTIO_F_SR_IOV] = 1'b1;

        // Init PF
        do_init();

        // Init each VF in parallel (fork-join)
        `uvm_info(get_type_name(), $sformatf(
            "Initializing %0d VFs in parallel", num_vfs), UVM_MEDIUM)

        fork
            for (int i = 0; i < num_vfs; i++) begin
                automatic int vf_id = i;
                fork
                    begin
                        virtio_transaction req = virtio_transaction::type_id::create(
                            $sformatf("vf_init_%0d", vf_id));
                        req.txn_type  = VIO_TXN_INIT;
                        req.queue_id  = vf_id;
                        req.num_pairs = 1;
                        req.vq_type   = VQ_SPLIT;
                        req.features  = negotiated_features;
                        send_configured_txn(req);
                    end
                join_none
            end
        join

        // Verify all queues mapped
        `uvm_info(get_type_name(), $sformatf(
            "Multi-VF init: %0d VFs initialized", num_vfs), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_MULTI_VF_INIT_SEQ_SV
