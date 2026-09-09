`ifndef VIRTIO_PROTOCOL_ASSERTIONS_SV
`define VIRTIO_PROTOCOL_ASSERTIONS_SV

// 文件职责：virtio 1.x 协议级 SVA 检查器。绑定到 virtio_protocol_event_if
// 上，对 monitor 分阶段（stage_*）释放的单拍脉冲做并发断言：
//   1) DRIVER_OK 前必须已见 FEATURES_OK；
//   2) status 写只能增位，唯一例外是写 0 复位；
//   3) FEATURES_OK 前必须已见 DRIVER（复位会清历史）；
//   4) notify 只允许发给已配置且已使能的队列；
//   5) completion 必须有同队列的未完成 submission 与之配对。
// 依赖：全部采样/辅助状态由 virtio_protocol_event_if 维护，本模块无状态；
// 断言失败通过 events.report_protocol_error 走 UVM 报告（可被负向用例捕获）。
// 总开关：events.assertions_enable == 0 时所有断言旁路。
module virtio_protocol_assertions(virtio_protocol_event_if events);
    // 初始化顺序检查：观察到 DRIVER_OK 脉冲时，历史上必须已出现过
    // FEATURES_OK（features_ok_seen 由接口在设备复位时清零）。
    property p_driver_ok_requires_features_ok;
        @(posedge events.clk)
            events.assertions_enable && events.driver_ok |-> events.features_ok_seen;
    endproperty

    assert property (p_driver_ok_requires_features_ok)
        else events.report_protocol_error(
            "DRIVER_OK observed before FEATURES_OK");

    // Device status is an accumulating state machine.  The all-zero write is
    // the explicit reset exception; every other write must retain all bits
    // that were already present.
    property p_status_write_is_monotonic_except_reset;
        @(posedge events.clk)
            events.assertions_enable && events.status_write &&
            (events.status_new != 8'h00) |->
                ((events.status_new & events.status_old) == events.status_old);
    endproperty

    assert property (p_status_write_is_monotonic_except_reset)
        else events.report_protocol_error(
            "status write cleared a previously set bit without reset");

    // FEATURES_OK is meaningful only after the DRIVER state was observed on
    // an earlier status write.  driver_seen is reset by an explicit device
    // reset, so stale lifecycle history cannot satisfy this property.
    property p_features_ok_requires_prior_driver;
        @(posedge events.clk)
            events.assertions_enable && events.features_ok |-> events.driver_seen;
    endproperty

    assert property (p_features_ok_requires_prior_driver)
        else events.report_protocol_error(
            "FEATURES_OK observed before DRIVER");

    // doorbell 合法性检查：notify 脉冲出现时，接口上采样到的目标队列
    // 必须同时处于 configured 且 enabled 状态（状态由 monitor staging 同步）。
    property p_notify_requires_enabled_queue;
        @(posedge events.clk)
            events.assertions_enable && events.notify |->
                (events.queue_configured && events.queue_enabled);
    endproperty

    assert property (p_notify_requires_enabled_queue)
        else events.report_protocol_error(
            "notify observed for a disabled queue");

    // One completion consumes one prior valid notification for that same
    // queue.  Credits are updated after the sampled edge, preserving the
    // required prior-event relationship.
    property p_completion_requires_pending_submission;
        @(posedge events.clk)
            events.assertions_enable && events.completion |->
                events.completion_has_pending_submission;
    endproperty

    assert property (p_completion_requires_pending_submission)
        else events.report_protocol_error(
            "completion observed without a pending submission");
endmodule : virtio_protocol_assertions

`endif // VIRTIO_PROTOCOL_ASSERTIONS_SV
