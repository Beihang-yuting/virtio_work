// transport：外部协议只持有冻结的本地通知和私有字段，不拥有设备配置权或 DMA。
// prepare_queue 是纯本地钩子；所有配置/复位入口明确拒绝，只有运行期 notify 发 MMIO。
`ifndef VIRTIO_EXTERNAL_CONFIG_BACKEND_SV
`define VIRTIO_EXTERNAL_CONFIG_BACKEND_SV
class virtio_external_config_backend extends virtio_config_backend;
    `uvm_object_utils(virtio_external_config_backend)
    local vio_external_queue_binding_t	bindings[int unsigned];
    local dpu_priv_queue_config	private_queues[int unsigned];
    local int unsigned	rx_size;

    // 构造不访问设备；bind_queue 在 prepare 阶段冻结值。
    extern function new(string name = "virtio_external_config_backend");

    // 冻结一条通知绑定和私有控制副本；重复队列拒绝。
    extern function bit bind_queue(input vio_external_queue_binding_t binding,
        input dpu_priv_driver_config private_cfg, input int unsigned rx_buf_size,
        output string why);

    // 释放本代后清除冻结通知，不清除外部设备中断/寄存器。
    extern function void clear_bindings();

    // 私有字段仅在 ring 分配前安装；Packed 保留标准 header/data 描述符。
    extern virtual function bit prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);

    // 使用冻结的地址/格式；q 的全局 qpair 不参与 doorbell 编码。
    extern virtual task notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);

    // 误入设备配置一律显式失败；禁止返回假成功以借用标准初始化。
    extern local function void forbidden(input string operation);

    // 外部协议不实现 reset；返回无效输出且保留 DMA。
    extern virtual task reset(output bit ok);

    // 外部协议不实现 read_status；返回无效输出且保留 DMA。
    extern virtual task read_status(output bit [7:0] status);

    // 外部协议不实现 write_status；返回无效输出且保留 DMA。
    extern virtual task write_status(bit [7:0] status);

    // 外部协议不实现 read_device_features；返回无效输出且保留 DMA。
    extern virtual task read_device_features(output bit [63:0] features);

    // 外部协议不实现 write_driver_features；返回无效输出且保留 DMA。
    extern virtual task write_driver_features(bit [63:0] features);

    // 外部协议不实现 set_features；返回无效输出且保留 DMA。
    extern virtual task set_features(bit [63:0] driver_caps, output bit [63:0] accepted);

    // 外部协议不实现 query_queue_max；返回无效输出且保留 DMA。
    extern virtual task query_queue_max(int unsigned queue_id, output int unsigned max_size);

    // 外部协议不实现 configure_queue；返回无效输出且保留 DMA。
    extern virtual task configure_queue(virtio_queue_program_t q, output bit ok);

    // 外部协议不实现 enable_queue；返回无效输出且保留 DMA。
    extern virtual task enable_queue(virtio_queue_program_t q, output bit ok);

    // 外部协议不实现 disable_queue；返回无效输出且保留 DMA。
    extern virtual task disable_queue(virtio_queue_program_t q, output bit ok);

    // 外部协议不实现 reset_queue；返回无效输出且保留 DMA。
    extern virtual task reset_queue(int unsigned queue_id, output bit ok);

    // 外部协议不实现 set_msix；返回无效输出且保留 DMA。
    extern virtual task set_msix(int unsigned queue_ids[$], output bit ok);

    // 外部协议不实现 clear_msix；返回无效输出且保留 DMA。
    extern virtual task clear_msix(output bit ok);

    // 外部协议不实现 read_net_config；返回无效输出且保留 DMA。
    extern virtual task read_net_config(output virtio_net_device_config_t cfg);

    // 外部协议不实现 discover；返回无效输出且保留 DMA。
    extern virtual task discover();
endclass

function virtio_external_config_backend::new(string name = "virtio_external_config_backend");
    super.new(name);
endfunction

function bit virtio_external_config_backend::bind_queue(input vio_external_queue_binding_t binding,
        input dpu_priv_driver_config private_cfg, input int unsigned rx_buf_size,
        output string why);
    why = "";
    if (bindings.exists(binding.local_qid)) begin
        why = "external queue binding duplicated";
        return 0;
    end
    bindings[binding.local_qid] = binding;
    if (private_cfg != null)
        private_queues[binding.local_qid] = private_cfg.resolve_queue(binding.local_qid);
    rx_size = rx_buf_size;
    return 1;
endfunction

function void virtio_external_config_backend::clear_bindings();
    bindings.delete();
    private_queues.delete();
endfunction

function bit virtio_external_config_backend::prepare_queue(virtqueue_base vq, ref virtio_queue_program_t q);
    custom_virtqueue	custom;
    dpu_priv_queue_config	control;

    if (!bindings.exists(q.queue_id)) return 0;
    q.local_qid = q.queue_id;
    q.notify_bar = bindings[q.queue_id].notify_bar;
    q.notify_offset = bindings[q.queue_id].notify_offset;
    q.rx_buf_size = rx_size;
    if (q.vq_type != VQ_CUSTOM) return q.vq_type == VQ_PACKED;
    if (!$cast(custom, vq) || !private_queues.exists(q.queue_id)) return 0;
    control = private_queues[q.queue_id];
    if (control == null || control.local_qid != q.queue_id) return 0;
    custom.legacy_rx_cq = 0;
    custom.local_qid = q.queue_id;
    custom.tx_mode = q.tx_mode;
    custom.dport_info = control.dport_info;
    custom.dport_id = control.dport_id;
    custom.dport_type = control.dport_type;
    custom.cpu_tx_cos = control.cpu_tx_cos;
    custom.rss_lag = control.rss_lag;
    custom.l3_cs = control.l3_cs;
    custom.l4_cs = control.l4_cs;
    custom.i_l3_cs = control.i_l3_cs;
    custom.i_l4_cs = control.i_l4_cs;
    custom.fwd = control.fwd;
    return 1;
endfunction

task virtio_external_config_backend::notify_queue(virtio_queue_program_t q, int unsigned next_idx, bit wrap);
    bit [31:0]	word_value;
    int unsigned	width;
    vio_external_queue_binding_t	binding;

    if (!bindings.exists(q.queue_id)) begin
        `uvm_error("VIO_EXTERNAL", "notify queue is not frozen")
        return;
    end
    binding = bindings[q.queue_id];
    width = (binding.notify_encoding == VIO_NOTIFY_QID16) ? 2 : 4;
    word_value = (width == 2) ? q.local_qid : {wrap, next_idx[14:0], q.local_qid[15:0]};
    transport.bar.write_reg(binding.notify_bar, binding.notify_offset, width, word_value);
endtask

function void virtio_external_config_backend::forbidden(input string operation);
    `uvm_error("VIO_EXTERNAL", {operation, ": device configuration belongs to caller"})
endfunction

task virtio_external_config_backend::reset(output bit ok);
    ok = 0;
    forbidden("reset");
endtask

task virtio_external_config_backend::read_status(output bit [7:0] status);
    status = '0;
    forbidden("read_status");
endtask

task virtio_external_config_backend::write_status(bit [7:0] status);

    forbidden("write_status");
endtask

task virtio_external_config_backend::read_device_features(output bit [63:0] features);
    features = '0;
    forbidden("read_device_features");
endtask

task virtio_external_config_backend::write_driver_features(bit [63:0] features);

    forbidden("write_driver_features");
endtask

task virtio_external_config_backend::set_features(bit [63:0] driver_caps, output bit [63:0] accepted);
    accepted = '0;
    forbidden("set_features");
endtask

task virtio_external_config_backend::query_queue_max(int unsigned queue_id, output int unsigned max_size);
    max_size = 0;
    forbidden("query_queue_max");
endtask

task virtio_external_config_backend::configure_queue(virtio_queue_program_t q, output bit ok);
    ok = 0;
    forbidden("configure_queue");
endtask

task virtio_external_config_backend::enable_queue(virtio_queue_program_t q, output bit ok);
    ok = 0;
    forbidden("enable_queue");
endtask

task virtio_external_config_backend::disable_queue(virtio_queue_program_t q, output bit ok);
    ok = 0;
    forbidden("disable_queue");
endtask

task virtio_external_config_backend::reset_queue(int unsigned queue_id, output bit ok);
    ok = 0;
    forbidden("reset_queue");
endtask

task virtio_external_config_backend::set_msix(int unsigned queue_ids[$], output bit ok);
    ok = 0;
    forbidden("set_msix");
endtask

task virtio_external_config_backend::clear_msix(output bit ok);
    ok = 0;
    forbidden("clear_msix");
endtask

task virtio_external_config_backend::read_net_config(output virtio_net_device_config_t cfg);
    cfg = '{default:0};
    forbidden("read_net_config");
endtask

task virtio_external_config_backend::discover();

    forbidden("discover");
endtask

`endif
