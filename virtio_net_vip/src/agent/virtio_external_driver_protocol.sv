// agent：外部配置协议保留通用数据 DMA，实现独立于 Packed/Custom 格式的配置所有权。
// Function 选择协议，env.prepare 提供冻结通知；本类不导入任何 project 类型，不持有 ring。
`ifndef VIRTIO_EXTERNAL_DRIVER_PROTOCOL_SV
`define VIRTIO_EXTERNAL_DRIVER_PROTOCOL_SV
class virtio_external_driver_protocol extends virtio_standard_driver_protocol;
    `uvm_object_utils(virtio_external_driver_protocol)

    // 构造仅命名；格式与功能声明由已冻结的 service 行为决定。
    extern function new(string name = "virtio_external_driver_protocol");

    // 标记外部生命周期，使标准初始化/状态轮询和自动复位被明确拒绝。
    extern virtual function bit is_external_configuration();

    // 日志中的协议名不依赖数据环格式。
    extern virtual function string protocol_name();

    // 平台拥有 status，MANUAL 入口不能直接访问。
    extern virtual function bit allows_status_access();

    // 误入普通 shutdown/reset 时必须失败并保留资源，不能未经 quiescence 回收。
    extern virtual function bit requires_verified_reset();

    // 本轮外部协议没有 control VQ。
    extern virtual function bit has_ctrl_vq();

    // 队列需求冻结后不能自动改 MQ。
    extern virtual function bit supports_mq();

    // 外部平台未提供迁移协议，显式拒绝。
    extern virtual function bit supports_migration();

    // bind 只安装无设备配置权的后端；环和通知在显式 prepare 时建立。
    extern virtual function bit bind_ops(virtio_atomic_ops ops,
        virtio_config_backend backend, virtio_driver_config_t behavior, output string why);

    // MANUAL poll 仍经过 ops 门禁和 DMA 回收；不能绕过 MSI-X 完成许可。
    extern virtual task poll_used(virtio_atomic_ops ops, virtio_transaction req);

    // 用户必须走 env.release_external_resources 并报告 quiescence；不自动复位设备。
    extern virtual task reset(virtio_atomic_ops ops, virtio_auto_fsm fsm, virtio_transaction req);
endclass

function virtio_external_driver_protocol::new(string name = "virtio_external_driver_protocol");
    super.new(name);
endfunction

function bit virtio_external_driver_protocol::is_external_configuration();
    return 1;
endfunction

function string virtio_external_driver_protocol::protocol_name();
    return "external";
endfunction

function bit virtio_external_driver_protocol::allows_status_access();
    return 0;
endfunction

function bit virtio_external_driver_protocol::requires_verified_reset();
    return 1;
endfunction

function bit virtio_external_driver_protocol::has_ctrl_vq();
    return 0;
endfunction

function bit virtio_external_driver_protocol::supports_mq();
    return 0;
endfunction

function bit virtio_external_driver_protocol::supports_migration();
    return 0;
endfunction

function bit virtio_external_driver_protocol::bind_ops(virtio_atomic_ops ops,
        virtio_config_backend backend, virtio_driver_config_t behavior, output string why);
    virtio_external_config_backend	external_backend;

    why = "";
    if (ops == null || ops.has_active_queues() ||
        !$cast(external_backend, backend) || external_backend == null ||
        !(behavior.vq_type inside {VQ_PACKED, VQ_CUSTOM})) begin
        why = "external protocol requires unused ops, external backend and Packed/Custom format";
        return 0;
    end
    ops.config_backend = backend;
    ops.protocol = this;
    ops.negotiated_features = behavior.driver_features;
    return 1;
endfunction

task virtio_external_driver_protocol::poll_used(virtio_atomic_ops ops, virtio_transaction req);
    if (req.queue_id[0]) ops.tx_complete(req.queue_id, req.completed_pkts, 1);
    else ops.rx_receive(req.queue_id, req.received_pkts, 1);
endtask

task virtio_external_driver_protocol::reset(virtio_atomic_ops ops, virtio_auto_fsm fsm, virtio_transaction req);
    req.success = 0;
    `uvm_error("VIO_EXTERNAL", "reset belongs to platform; stop DMA then release external resources")
endtask

`endif
