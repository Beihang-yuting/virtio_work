`ifndef VIRTIO_PROTOCOL_ASSERTIONS_SV
`define VIRTIO_PROTOCOL_ASSERTIONS_SV

module virtio_protocol_assertions(virtio_protocol_event_if events);
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
