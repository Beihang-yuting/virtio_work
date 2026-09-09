`ifndef VIRTIO_FEATURE_ERROR_SEQ_SV
`define VIRTIO_FEATURE_ERROR_SEQ_SV

// ============================================================================
// virtio_feature_error_seq (seq/scenario/lifecycle)
//
// Feature 协商违例场景:按 feature_error_e 枚举注入五种协商错误——只写
// 低/高 32 位、非法 select 值、使用未协商 feature、FEATURES_OK 之后改
// feature。前三种直接以 ATOMIC_SET_STATUS + 特制 features 值表达(观察
// 事实:走的是 atomic-op 通道,由 driver 侧把 features 落到寄存器);
// 后两种先正常 init 再做违例动作。设备应拒绝或容忍这些违例,判定交给
// driver 状态检查与 scoreboard。
// ============================================================================

class virtio_feature_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_feature_error_seq)

    rand feature_error_e err_type;

    // 构造函数:违例类型不给默认值,由随机化或调用方指定。
    function new(string name = "virtio_feature_error_seq");
        super.new(name);
    endfunction

    // 按 err_type 执行对应违例分支(各分支内已有英文注释说明细节);
    // 序列不检查设备反应,只保证违例激励按序发出。
    virtual task body();
        virtio_transaction req;

        `uvm_info(get_type_name(), $sformatf(
            "Injecting feature error: %s", err_type.name()), UVM_MEDIUM)

        case (err_type)
            FEAT_ERR_PARTIAL_WRITE_LO_ONLY: begin
                // Write only low 32 bits of features
                req = virtio_transaction::type_id::create("req");
                req.txn_type  = VIO_TXN_ATOMIC_OP;
                req.atomic_op = ATOMIC_SET_STATUS;
                req.features  = negotiated_features & 64'h0000_0000_FFFF_FFFF;
                send_configured_txn(req);
            end

            FEAT_ERR_PARTIAL_WRITE_HI_ONLY: begin
                // Write only high 32 bits of features
                req = virtio_transaction::type_id::create("req");
                req.txn_type  = VIO_TXN_ATOMIC_OP;
                req.atomic_op = ATOMIC_SET_STATUS;
                req.features  = negotiated_features & 64'hFFFF_FFFF_0000_0000;
                send_configured_txn(req);
            end

            FEAT_ERR_WRONG_SELECT_VALUE: begin
                // Use invalid device_feature_select value
                req = virtio_transaction::type_id::create("req");
                req.txn_type  = VIO_TXN_ATOMIC_OP;
                req.atomic_op = ATOMIC_SET_STATUS;
                req.features  = 64'hDEAD_BEEF_DEAD_BEEF;
                send_configured_txn(req);
            end

            FEAT_ERR_USE_UNNEGOTIATED_FEATURE: begin
                // Init normally, then use a feature not negotiated
                do_init();
                send_txn(VIO_TXN_START_DP);
                req = virtio_transaction::type_id::create("req");
                req.txn_type = VIO_TXN_SEND_PKTS;
                req.net_hdr.flags = VIRTIO_NET_HDR_F_NEEDS_CSUM;
                send_configured_txn(req);
            end

            FEAT_ERR_CHANGE_AFTER_FEATURES_OK: begin
                // Init normally, then try to change features
                do_init();
                req = virtio_transaction::type_id::create("req");
                req.txn_type  = VIO_TXN_ATOMIC_OP;
                req.atomic_op = ATOMIC_SET_STATUS;
                req.features  = negotiated_features ^ 64'hFF;
                send_configured_txn(req);
            end
        endcase

        `uvm_info(get_type_name(), $sformatf(
            "Feature error injection complete: %s", err_type.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_FEATURE_ERROR_SEQ_SV
