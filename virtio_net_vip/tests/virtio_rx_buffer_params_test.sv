// tests：标准 VRX 容量参数的配置到描述符验证；复用 AIP 参数测试的 override 管理。
// fixture 持有 Host memory，ops 持有 ring/buffer；每次检查后确认停止并释放全部 DMA。
// 设备仅禁用通知和写完成项，检查真实描述符、IOMMU 容量和报文，不替代真实 DUT 验证。
`include "virtio_mock_transport.sv"
`include "virtio_vq_test_kit.sv"
`include "virtio_shared_mem_fixture.sv"

class virtio_rx_buffer_params_test extends virtio_aip_params_test;
    `uvm_component_utils(virtio_rx_buffer_params_test)

    virtio_shared_mem_fixture	fixture;
    virtio_vq_test_kit		kit;
    virtio_iommu_model		iommu;
    virtio_mock_transport	transport;

    // 不在构造阶段采样参数或分配 DMA。
    extern function new(string	name, uvm_component	parent);

    // 前置条件失败立即退出，避免空对象或错误长度掩盖原始问题。
    extern function void require_true(bit	condition, string	message);

    // 独立按小端读取描述符，不使用被测打包函数生成期望值。
    extern function bit [63:0] read_le(bit [63:0]	address, int unsigned	length);

    // 外部后端实际接收最终容量，发布一个 RX 描述符并 DMA 写满，再确认完成和回收。
    extern task check_external_buffer(vio_service_requirement_t	requirement);

    // AUTO 首次投递使用实际特性，检查 10/12/20 字节头；无参数仍走原 ops 默认值。
    extern task check_auto_buffers(virtio_net_env_config	cfg);

    // 覆盖全局/Host/service 参数、缓存、显式重载、随机范围和 Custom 隔离。
    // RX_BAD_VALUE 单独触发非法值；该运行应在参数加载点退出。
    extern virtual task run_phase(uvm_phase	phase);
endclass

function virtio_rx_buffer_params_test::new(string	name, uvm_component	parent);
    super.new(name, parent);
endfunction

function void virtio_rx_buffer_params_test::require_true(bit	condition, string	message);
    if (!condition)
        `uvm_fatal("RX_BUFFER_TEST", message)
endfunction

function bit [63:0] virtio_rx_buffer_params_test::read_le(
    bit [63:0]	address,
    int unsigned	length
);
    byte	data[];
    bit [63:0]	value;

    kit.mem.read_mem(address, length, data);
    foreach (data[i]) value[i * 8 +: 8] = data[i];
    return value;
endfunction

task virtio_rx_buffer_params_test::check_external_buffer(
    vio_service_requirement_t	requirement
);
    virtio_atomic_ops			ops;
    virtio_external_driver_protocol	protocol;
    virtio_external_config_backend	backend;
    virtio_queue_program_t		program_value;
    vio_external_queue_binding_t	binding;
    virtqueue_base			vq;
    iommu_mapping_t			mapping;
    iommu_fault_e			fault;
    virtio_rx_frame_t			frames[$];
    int unsigned			qids[$];
    int unsigned			capacity;
    bit [63:0]				address;
    byte				no_notify[2] = '{1, 0};
    byte				data[];
    bit					ok;
    string				why;

    ops = kit.make_ops(transport, "external_rx");
    protocol = new("external_protocol");
    backend = new("external_backend");
    require_true(protocol.bind_ops(ops, backend, requirement.behavior, why), why);
    require_true(ops.begin_external_session(this, 1, requirement, why), why);

    binding.local_qid = 0;
    binding.notify_encoding = VIO_NOTIFY_DPU32;
    capacity = requirement.behavior.rx_buf_size;
    require_true(backend.bind_queue(binding, null, capacity, why), why);
    program_value = virtio_empty_queue_program();
    program_value.queue_size = 4;
    program_value.vq_type = VQ_PACKED;
    ops.prepare_local_queue(program_value, ok);
    require_true(ok, "external RX queue preparation");
    qids.push_back(0);
    require_true(ops.confirm_external_session(this, 1, qids, why), why);
    vq = kit.vq_mgr.get_queue(0);
    kit.mem.write_mem(vq.device_ring_addr + 2, no_notify);

    ops.rx_refill(0, 1);
    check_param(read_le(vq.desc_table_addr + 8, 4) == capacity,
        "external descriptor must carry the final header-inclusive capacity");
    address = read_le(vq.desc_table_addr, 8);
    require_true(iommu.get_live_mapping_for_host(0, 16'h1, address, mapping),
        "posted RX buffer has a live mapping");
    check_param(mapping.size == ((capacity + 3) & ~3),
        "DMA alignment must not change descriptor length");

    data = new[capacity];
    foreach (data[i]) data[i] = (i < 12) ? 0 : byte'(i);
    data[10] = 1;
    require_true(iommu.write_from_device_for_host(0, kit.mem, 16'h1, address, data, fault),
        "device may write the complete advertised capacity");
    virtio_vq_test_kit::complete_packed(kit.mem, vq, 0);
    ops.rx_receive_frames(0, 1, frames);
    require_true(frames.size() == 1, "one completed RX frame");
    check_param(frames[0].payload.size() == capacity - 12,
        "RX result removes exactly one modern Virtio header");
    foreach (frames[0].payload[i]) begin
        require_true(frames[0].payload[i] == byte'(i + 12),
            "full-capacity RX payload is preserved");
    end
    require_true(ops.release_external_session(this, 1, why), why);
    check_param(iommu.total_maps == iommu.total_unmaps, "external RX DMA was reclaimed");
endtask

task virtio_rx_buffer_params_test::check_auto_buffers(virtio_net_env_config	cfg);
    virtio_atomic_ops	ops;
    virtio_auto_fsm	fsm;
    virtqueue_base	vq;
    int unsigned	header_sizes[3] = '{10, 12, 20};
    bit			ok;

    for (int unsigned	mode = 0; mode < 4; mode++) begin
        ops = kit.make_ops(transport, "auto_rx");
        ops.negotiated_features = 0;
        if (mode == 1) ops.negotiated_features[VIRTIO_F_VERSION_1] = 1;
        if (mode == 2) ops.negotiated_features[VIRTIO_NET_F_HASH_REPORT] = 1;
        vq = kit.add_packed(0, 4);
        fsm = new("auto_fsm");
        fsm.ops = ops;
        fsm.drv_cfg = cfg.make_default_driver_config(1);
        fsm.drv_cfg.queue_size = 4;
        fsm.drv_cfg.vq_type = VQ_PACKED;
        fsm.drv_cfg.irq_mode = IRQ_MSIX_SHARED;
        if (mode == 3)
            fsm.drv_cfg.rx_packet_size = 0;
        fsm.state = FSM_READY;
        fsm.start_dataplane();
        fsm.stop_dataplane();

        for (int unsigned	i = 0; i < 4; i++) begin
            check_param(read_le(vq.desc_table_addr + i * 16 + 8, 4) ==
                ((mode == 3) ? 1524 : cfg.default_rx_packet_size + header_sizes[mode]),
                "AUTO RX uses final features and preserves the existing fallback without a parameter");
        end
        ops.device_reset_verified(ok);
        require_true(ok, "AUTO fixture reset confirmation");
        check_param(iommu.total_maps == iommu.total_unmaps, "AUTO RX DMA was reclaimed");
    end
endtask

task virtio_rx_buffer_params_test::run_phase(uvm_phase	phase);
    virtio_net_env_config	root_cfg;
    virtio_net_env_config	host_cfg;
    virtio_net_env_config	candidate;
    virtio_net_env_config	custom_cfg;
    vio_service_requirement_t	first_value;
    vio_service_requirement_t	again;
    dpu_service_key_t		key;
    string			why;
    string			bad_value;

    phase.raise_objection(this);
    root_cfg = new("rx_root");
    if ($value$plusargs("RX_BAD_VALUE=%s", bad_value)) begin
        put("rx_bad.rx_buf_size", bad_value);
        root_cfg.load_params("rx_bad");
        `uvm_fatal("RX_BAD_MISSED", "illegal RX capacity was accepted")
    end

    fixture = new("rx_memory");
    require_true(fixture.create_host(0, 64'h100000000, 64'h100ffffff), "Host memory");
    iommu = new("rx_iommu");
    kit = virtio_vq_test_kit::create_kit("rx_size", fixture.get_host(0), iommu, 16'h1);
    transport = new("rx_transport");
    transport.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(16'h1));

    key.function_key = '{host_id:0, pf_id:0, kind:DPU_FUNCTION_PF, vf_id:0};
    key.service_kind = DPU_SERVICE_VIO_NET;
    key.service_instance_id = 0;
    root_cfg.external_configuration = 1;
    root_cfg.default_vq_type = VQ_PACKED;
    root_cfg.completion_mode = VIRTIO_COMPLETION_POLLING;
    root_cfg.load_params("rx_absent");
    check_param(root_cfg.default_rx_buf_size == 1526 && root_cfg.default_rx_packet_size == 0,
        "absent RX capacity preserves the existing default");
    candidate = new("legacy_rx");
    candidate.copy_defaults_from(root_cfg);
    candidate.default_rx_buf_size = 2048;
    require_true(candidate.resolve_final_service_requirement(key, again, why), why);
    check_param(again.behavior.rx_buf_size == 2048,
        "legacy SV total capacity must not receive an extra header");
    check_external_buffer(again);

    put("rx_size.rx_buf_size", "2048");
    root_cfg.load_params("rx_size");
    check_param(root_cfg.default_rx_packet_size == 2048, "root RX packet capacity");
    check_auto_buffers(root_cfg);

    host_cfg = new("rx_host");
    host_cfg.copy_defaults_from(root_cfg);
    put("rx_size.h0.rx_buf_size", "3073");
    host_cfg.load_params("rx_size.h0");
    check_param(host_cfg.default_rx_packet_size == 3073 && root_cfg.default_rx_packet_size == 2048,
        "Host RX capacity override is independent");
    put("rx_size.h0.pf0.i0.rx_buf_size", "4097");
    host_cfg.enable_service_params("rx_size");
    require_true(host_cfg.resolve_final_service_requirement(key, first_value, why), why);
    check_param(first_value.behavior.rx_packet_size == 4097 && first_value.behavior.rx_buf_size == 4109,
        "Packed capacity includes 12 bytes after features are finalized");
    check_external_buffer(first_value);

    put("rx_size.h0.pf0.i0.rx_buf_size", "9000");
    require_true(host_cfg.resolve_final_service_requirement(key, again, why), why);
    check_param(again.behavior.rx_buf_size == 4109, "published configuration remains cached");
    require_true(host_cfg.make_runtime_candidate(null, "rx_size.h0", candidate, why), why);
    require_true(host_cfg.validate_runtime_service(candidate, key, why), why);
    host_cfg.apply_runtime_candidate(candidate);
    require_true(host_cfg.resolve_final_service_requirement(key, again, why), why);
    check_param(again.behavior.rx_packet_size == 9000 && again.behavior.rx_buf_size == 9012,
        "explicit reload changes packet capacity without adding the header twice");
    check_external_buffer(again);

    custom_cfg = new("custom_rx");
    custom_cfg.copy_defaults_from(root_cfg);
    custom_cfg.default_vq_type = VQ_CUSTOM;
    put("rx_custom.private.rx_buf_size", "1024");
    custom_cfg.enable_service_params("rx_custom");
    require_true(custom_cfg.resolve_final_service_requirement(key, again, why), why);
    check_param(again.behavior.rx_buf_size == 1024, "Custom keeps its private buffer capacity without a header");

    put("rx_random.rx_buf_size", "[256:4096]");
    for (int unsigned	i = 0; i < 32; i++) begin
        candidate = new("random_rx");
        candidate.copy_defaults_from(root_cfg);
        candidate.load_params("rx_random");
        require_true(candidate.resolve_final_service_requirement(key, again, why), why);
        check_param(again.behavior.rx_packet_size inside {[256:4096]} &&
            again.behavior.rx_buf_size == again.behavior.rx_packet_size + 12,
            "AIP range is sampled as packet capacity before adding the header");
        check_external_buffer(again);
    end

    candidate = new("cli_rx");
    candidate.copy_defaults_from(root_cfg);
    candidate.load_params("rx_cli");
    require_true(candidate.resolve_final_service_requirement(key, again, why), why);
    if ($test$plusargs("RX_CLI_CHECK"))
        check_param(again.behavior.rx_buf_size == 2060, "CLI RX packet capacity 2048 includes a 12-byte header");
    check_external_buffer(again);

    restore_overrides();
    fixture.leak_check();
    `uvm_info("RX_BUFFER_PASS", $sformatf("completed %0d RX capacity checks", checks), UVM_NONE)
    phase.drop_objection(this);
endtask
