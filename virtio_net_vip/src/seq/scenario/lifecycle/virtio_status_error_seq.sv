`ifndef VIRTIO_STATUS_ERROR_SEQ_SV
`define VIRTIO_STATUS_ERROR_SEQ_SV

// ============================================================================
// virtio_status_error_seq (seq/scenario/lifecycle)
//
// 设备状态机违例场景:virtio 规范要求 status 按 ACKNOWLEDGE -> DRIVER ->
// FEATURES_OK -> DRIVER_OK 单调推进;本序列按 status_error_e 枚举刻意
// 打乱顺序(跳步、乱序、FAILED 之后继续写),每步用 ATOMIC_SET_STATUS
// 直接写 status 寄存器,绕开 driver 的自动初始化状态机——这正是选择
// atomic-op 通道的原因。设备应拒绝非法迁移或进入 NEEDS_RESET,判定由
// driver 状态检查/scoreboard 完成。
// ============================================================================

class virtio_status_error_seq extends virtio_base_seq;
    `uvm_object_utils(virtio_status_error_seq)

    rand status_error_e err_type;

    // 构造函数:违例类型不给默认值,由随机化或调用方指定。
    function new(string name = "virtio_status_error_seq");
        super.new(name);
    endfunction

    // 按 err_type 逐步写出对应的非法 status 迁移序列(各分支内英文注释
    // 标出跳过/乱序点);不做本地判定。
    virtual task body();
        virtio_transaction req;

        `uvm_info(get_type_name(), $sformatf(
            "Injecting status error: %s", err_type.name()), UVM_MEDIUM)

        case (err_type)
            STATUS_ERR_SKIP_ACKNOWLEDGE: begin
                // Write DRIVER without ACKNOWLEDGE
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
            end

            STATUS_ERR_SKIP_DRIVER: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                // Skip DRIVER, go to FEATURES_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_FEATURES_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_SKIP_FEATURES_OK: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
                // Skip FEATURES_OK, go to DRIVER_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_DRIVER_OK_BEFORE_FEATURES_OK: begin
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_ACKNOWLEDGE;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER;
                send_configured_txn(req);
                // DRIVER_OK before FEATURES_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end

            STATUS_ERR_WRITE_AFTER_FAILED: begin
                // Set FAILED then try DRIVER_OK
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_FAILED;
                send_configured_txn(req);
                req = virtio_transaction::type_id::create("req");
                req.txn_type   = VIO_TXN_ATOMIC_OP;
                req.atomic_op  = ATOMIC_SET_STATUS;
                req.status_val = DEV_STATUS_DRIVER_OK;
                send_configured_txn(req);
            end
        endcase

        `uvm_info(get_type_name(), $sformatf(
            "Status error injection complete: %s", err_type.name()), UVM_LOW)
    endtask

endclass

`endif // VIRTIO_STATUS_ERROR_SEQ_SV
