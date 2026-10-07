// ============================================================================
// virtio_pci_transport.sv
//
// Top-level PCI transport wrapper that encapsulates:
//   - virtio_pci_cap_manager:       PCI capability discovery
//   - virtio_bar_accessor:          BAR MMIO register access via PCIe TLPs
//   - virtio_notification_manager:  MSI-X / INTx / polling interrupt control
//   - virtio_wait_policy:           Timeout and polling configuration
//
// Provides:
//   - Complete device initialization sequence (virtio spec Section 7.2)
//   - Device status read/write with polling
//   - 64-bit feature negotiation (two-phase select+read)
//   - Queue configuration (select, size, addresses, enable, reset)
//   - Config generation atomic read
//   - Kick with optional NOTIFICATION_DATA support
//   - MSI-X vector binding
//   - Error injection for status, feature, and queue setup errors
//
// Per virtio spec Section 4.1 (PCI Transport)
//
// 中文定位：transport 目录的顶层门面(facade)，测试/agent 侧操作 virtio-net
// function 的唯一入口，聚合 cap_mgr/bar/notify_mgr/wait_pol 四个子组件。
// 职责：设备状态机推进(reset/初始化九步)、64 位特性协商、队列发现与配置、
// 原子读 net config、kick 通知、MSI-X 绑定，以及三类协议错误注入。
// 依赖：virtio_pci_regs 的寄存器偏移常量、dpu PCIe function identity 类型、
// virtio_pcie_function_endpoint(绑定通路)、virtio_resource_client(Fabric)。
// 所有权/生命周期：uvm_object；构造时创建并拥有四个子组件且完成交叉接线，
// 与所属 function 同生命周期。PCIe sequencer/adapter 为外部借用，经
// bind_pcie_endpoint() 注入 bar；Fabric 模式下 BAR 布局由资源管理器下发，
// 本类不做 BAR sizing。
// ============================================================================

`ifndef VIRTIO_PCI_TRANSPORT_SV
`define VIRTIO_PCI_TRANSPORT_SV

class virtio_pci_transport extends uvm_object;
    `uvm_object_utils(virtio_pci_transport)

    // ===== Sub-components =====
    virtio_pci_cap_manager       cap_mgr;
    virtio_bar_accessor          bar;
    virtio_notification_manager  notify_mgr;
    virtio_wait_policy           wait_pol;

    // ===== Identity =====
    bit [15:0]    bdf;
    dpu_pcie_function_id_t pcie_id;
    bit                     pcie_id_valid;
    bit           is_vf = 0;
    int unsigned  vf_index = 0;

    // ===== Device info (populated after discovery) =====
    int unsigned  num_queues;
    int unsigned  queue_notify_off[];    // per-queue notify offset (read from device)
    bit [63:0]    device_features;
    bit [63:0]    driver_features;
    bit           notification_data_enable = 0;
    bit [7:0]     current_status = DEV_STATUS_RESET;

    // Fabric functions receive immutable BAR placements from the DPU
    // resource manager.  Discovery scans capabilities only; it never runs
    // PCI BAR sizing or assigns a local address.
    bit                     fabric_managed = 0;
    bit                     fabric_capability_discovered = 0;
    virtio_resource_client  fabric_resource_client;

    // 当前 BAR/capability 发现策略：构造时即为 fabric_preconfigured（未经
    // configure_fabric_managed() 的 transport 发现时由该策略 fatal）；后续设计经
    // set_discovery_strategy() 注入 verify_snapshot。
    virtio_discovery_strategy discovery_strategy;

    // ========================================================================
    // 构造：创建并拥有四个子组件，随即完成交叉接线(cap_mgr.bar_ref 与
    // notify_mgr.bar 都指向同一个 bar 实例)。此时 BDF/identity 均未配置，
    // PCIe sequencer 也未注入，不能直接发起访问。
    // ========================================================================

    function new(string name = "virtio_pci_transport");
        super.new(name);
        cap_mgr    = virtio_pci_cap_manager::type_id::create("cap_mgr");
        bar        = virtio_bar_accessor::type_id::create("bar");
        notify_mgr = virtio_notification_manager::type_id::create("notify_mgr");
        wait_pol   = virtio_wait_policy::type_id::create("wait_pol");

        // Cross-wire references
        cap_mgr.bar_ref    = bar;
        notify_mgr.bar     = bar;

        num_queues      = 0;
        device_features = '0;
        driver_features = '0;
        bdf             = 16'h0;
        pcie_id_valid   = 0;
        discovery_strategy = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
    endfunction

    // 冻结本 function 的完整 PCIe identity({host, segment, BDF})，并同步
    // 下发给 bar(请求生成方)与 notify_mgr(MSI-X 默认表命名空间)。副作用：
    // 覆盖旧 bdf；应在任何 PCIe 访问之前调用。
    function void configure_pcie_identity(
        input dpu_pcie_function_id_t function_pcie_id
    );
        pcie_id = function_pcie_id;
        pcie_id_valid = 1;
        bdf = function_pcie_id.bdf;
        bar.configure_pcie_identity(function_pcie_id);
        notify_mgr.set_function_bdf(function_pcie_id.bdf);
    endfunction

    // Canonical DMA requester-domain projection.  The host comes only from
    // the frozen PCIe identity; a transport without one has no DMA domain.
    function int unsigned iommu_host_id();
        if (!pcie_id_valid) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "transport BDF=0x%04h has no frozen PCIe identity; DMA host domain is undefined",
                bdf))
            return 0;
        end
        return pcie_id.domain.host_id;
    endfunction

    // 把外部已配置的 PCIe 通路(endpoint)绑到本 transport：要求先完成
    // configure_pcie_identity 且 endpoint 身份与之完全匹配(含 domain key)，
    // 否则 fatal 并返回 0。成功后 bar 获得 RC sequencer 与 completion
    // adapter；endpoint 仅被借用，不转移所有权。
    function bit bind_pcie_endpoint(
        input virtio_pcie_function_endpoint endpoint
    );
        if (endpoint == null) begin
            `uvm_fatal("TRANSPORT", "PCIe endpoint bind received null")
            return 0;
        end
        if (!pcie_id_valid || !endpoint.matches_id(pcie_id)) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "PCIe endpoint %s does not match transport identity %s",
                dpu_pcie_function_id_name(endpoint.pcie_id),
                pcie_id_valid ? dpu_pcie_function_id_name(pcie_id) :
                    "<unconfigured>"))
            return 0;
        end
        bar.bind_pcie_path(
            pcie_id, endpoint.rc_seqr, endpoint.completion_adapter);
        return 1;
    endfunction

    // 切换到 Fabric 托管模式：BAR 布局由 DPU 资源管理器下发、发现策略切换为
    // fabric_preconfigured。会清掉能力发现完成标志；
    // resource_client 为借用引用，负责 device-ready 生命周期上报。
    virtual function void configure_fabric_managed(
        input virtio_resource_client resource_client
    );
        fabric_managed = 1;
        fabric_capability_discovered = 0;
        fabric_resource_client = resource_client;
        discovery_strategy = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
    endfunction

    // 查询是否处于 Fabric 托管模式；纯查询，无副作用。
    function bit is_fabric_managed();
        return fabric_managed;
    endfunction

    // 替换发现策略（例如核对 snapshot 的 verify_snapshot）；null 被拒绝并保持原策略。
    function void set_discovery_strategy(virtio_discovery_strategy strategy);
        if (strategy == null) begin
            `uvm_error("TRANSPORT", "set_discovery_strategy received null")
            return;
        end
        discovery_strategy = strategy;
    endfunction

    // 当前发现策略名；纯查询。
    function string discovery_strategy_name();
        return discovery_strategy.strategy_name();
    endfunction

    // ========================================================================
    // common config 读辅助：把寄存器相对偏移换算成 "common_cfg 能力所在
    // BAR + 能力内偏移" 后走 bar.read_reg。前提是能力发现已完成，否则
    // cap_mgr 返回的 BAR/offset 无意义。
    // ========================================================================

    protected task cc_read(bit [31:0] offset, int unsigned size, ref bit [31:0] data);
        bar.read_reg(cap_mgr.get_common_cfg_bar(),
                     cap_mgr.get_common_cfg_bar_offset() + offset,
                     size, data);
    endtask

    // ========================================================================
    // common config 写辅助：与 cc_read 对称，换算 BAR/偏移后走 bar.write_reg
    // 发 posted Memory Write；本层不等待也感知不到写是否被 EP 接受。
    // ========================================================================

    protected task cc_write(bit [31:0] offset, int unsigned size, bit [31:0] data);
        bar.write_reg(cap_mgr.get_common_cfg_bar(),
                      cap_mgr.get_common_cfg_bar_offset() + offset,
                      size, data);
    endtask

    // ========================================================================
    // 设备状态寄存器访问：读为单字节直读；写会同步更新本地 current_status
    // 影子值(供初始化流程按位累加)，影子值与设备实际状态可能短暂不一致。
    // ========================================================================

    // 读 STATUS 寄存器低 8 位；不更新 current_status 影子值。
    virtual task read_device_status(ref bit [7:0] status);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_STATUS, 1, data);
        status = data[7:0];
    endtask

    // 写 STATUS 并把写入值记为 current_status 影子值；posted 写不确认结果。
    virtual task write_device_status(bit [7:0] status);
        cc_write(VIRTIO_PCI_COMMON_STATUS, 1, {24'h0, status});
        current_status = status;

        `uvm_info("TRANSPORT",
            $sformatf("Device status written: 0x%02h", status), UVM_HIGH)
    endtask

    // ========================================================================
    // reset_device
    //
    // Write status=0, then poll until status reads back as 0.
    // Uses wait_policy: loop reading status register with poll interval.
    // Timeout: wait_pol.reset_timeout_ns
    // ========================================================================

    // The verified form lets DMA owners wait for hardware confirmation.
    // reset_device() remains the backwards-compatible void wrapper.
    virtual task reset_device_verified(ref bit reset_complete);
        bit [31:0] read_val;
        int unsigned elapsed = 0;
        int unsigned eff_timeout = wait_pol.effective_timeout(wait_pol.reset_timeout_ns);
        int unsigned interval = wait_pol.default_poll_interval_ns;
        int unsigned attempts = 0;
        int unsigned max_att;
        longint unsigned quotient;

        reset_complete = 0;
        if (interval == 0)
            interval = 1;
        quotient = longint'(eff_timeout) / interval;
        if (quotient >= wait_pol.max_poll_attempts)
            max_att = wait_pol.max_poll_attempts;
        else
            max_att = quotient + 1;

        // Write 0 to trigger reset
        cc_write(VIRTIO_PCI_COMMON_STATUS, 1, 32'h0);
        current_status = DEV_STATUS_RESET;

        // Poll until status reads 0
        while (attempts < max_att) begin
            cc_read(VIRTIO_PCI_COMMON_STATUS, 1, read_val);
            if (read_val[7:0] == 8'h0) begin
                reset_complete = 1;
                break;
            end
            #(interval * 1ns);
            elapsed += interval;
            attempts++;
        end

        if (!reset_complete)
            `uvm_error("TRANSPORT",
                $sformatf("Device reset timeout after %0dns", elapsed))
        else
            `uvm_info("TRANSPORT", "Device reset complete", UVM_HIGH)
    endtask

    virtual task reset_device();
        bit reset_complete;
        reset_device_verified(reset_complete);
    endtask

    // ========================================================================
    // 特性协商：64 位特性通过 select(0/1)+读写 32 位窗口分两次搬运，
    // 顺序固定为先低后高。
    // ========================================================================

    // 两阶段读取设备 64 位特性(DFSELECT=0 读低 32 位、=1 读高 32 位)；
    // 只读取，不更新 device_features 成员(由 negotiate_features 负责)。
    virtual task read_device_features(ref bit [63:0] features);
        bit [31:0] lo, hi;

        // Select low 32 bits (select=0)
        cc_write(VIRTIO_PCI_COMMON_DFSELECT, 4, 32'h0);
        cc_read(VIRTIO_PCI_COMMON_DF, 4, lo);

        // Select high 32 bits (select=1)
        cc_write(VIRTIO_PCI_COMMON_DFSELECT, 4, 32'h1);
        cc_read(VIRTIO_PCI_COMMON_DF, 4, hi);

        features = {hi, lo};

        `uvm_info("TRANSPORT",
            $sformatf("Device features read: 0x%016h", features), UVM_MEDIUM)
    endtask

    // 两阶段写入驱动侧特性(GFSELECT=0 写低 32 位、=1 写高 32 位)；
    // 不做任何合法性过滤，错误注入路径会直接用它写非法组合。
    virtual task write_driver_features(bit [63:0] features);
        // Select low 32 bits (select=0)
        cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h0);
        cc_write(VIRTIO_PCI_COMMON_GF, 4, features[31:0]);

        // Select high 32 bits (select=1)
        cc_write(VIRTIO_PCI_COMMON_GFSELECT, 4, 32'h1);
        cc_write(VIRTIO_PCI_COMMON_GF, 4, features[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Driver features written: 0x%016h", features), UVM_MEDIUM)
    endtask

    // 完整协商：读设备特性、与 driver_supported 取交集、写回。副作用：更新
    // device_features/driver_features 缓存，并据 NOTIFICATION_DATA 位设置
    // notification_data_enable(影响后续 kick 的数据格式)。
    virtual task negotiate_features(bit [63:0] driver_supported, ref bit [63:0] negotiated);
        bit [63:0] dev_feat;

        read_device_features(dev_feat);
        device_features = dev_feat;

        negotiated      = dev_feat & driver_supported;
        driver_features = negotiated;

        // Check for NOTIFICATION_DATA feature
        notification_data_enable = negotiated[VIRTIO_F_NOTIFICATION_DATA];

        write_driver_features(negotiated);

        `uvm_info("TRANSPORT",
            $sformatf("Feature negotiation: device=0x%016h driver_supported=0x%016h negotiated=0x%016h",
                      dev_feat, driver_supported, negotiated), UVM_MEDIUM)
    endtask

    // ========================================================================
    // 读 config generation 计数：设备每次改动 device config 都会递增该值，
    // read_net_config_atomic 用前后两次读来判定一次多寄存器读取是否原子。
    // ========================================================================

    virtual task read_config_generation(ref bit [7:0] gen);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_CFGGENERATION, 1, data);
        gen = data[7:0];
    endtask

    // ========================================================================
    // read_net_config_atomic
    //
    // Atomically reads the device-specific net config by bracketing the read
    // with config generation checks. Retries if the generation changed.
    // ========================================================================

    virtual task read_net_config_atomic(ref virtio_net_device_config_t cfg);
        bit [7:0]  gen_before, gen_after;
        bit [31:0] data;
        int unsigned retry_count = 0;
        int unsigned max_retries = 16;
        int unsigned dev_cfg_bar;
        bit [31:0]  dev_cfg_off;

        dev_cfg_bar = cap_mgr.get_device_cfg_bar();
        dev_cfg_off = cap_mgr.get_device_cfg_bar_offset();

        forever begin
            if (retry_count >= max_retries) begin
                `uvm_error("TRANSPORT",
                    $sformatf("read_net_config_atomic: exceeded %0d retries", max_retries))
                return;
            end

            // Read generation before
            read_config_generation(gen_before);

            // Read MAC address (6 bytes: 4 + 2)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h00, 4, data);
            cfg.mac[47:16] = {data[7:0], data[15:8], data[23:16], data[31:24]};
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h04, 2, data);
            cfg.mac[15:0] = {data[7:0], data[15:8]};

            // Read status (2 bytes at offset 6)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h06, 2, data);
            cfg.status = data[15:0];

            // Read max_virtqueue_pairs (2 bytes at offset 8)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h08, 2, data);
            cfg.max_virtqueue_pairs = data[15:0];

            // Read MTU (2 bytes at offset 10)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h0A, 2, data);
            cfg.mtu = data[15:0];

            // Read speed (4 bytes at offset 12)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h0C, 4, data);
            cfg.speed = data;

            // Read duplex (1 byte at offset 16)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h10, 1, data);
            cfg.duplex = data[7:0];

            // Read rss_max_key_size (1 byte at offset 17)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h11, 1, data);
            cfg.rss_max_key_size = data[7:0];

            // Read rss_max_indirection_table_length (2 bytes at offset 18)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h12, 2, data);
            cfg.rss_max_indirection_table_length = data[15:0];

            // Read supported_hash_types (4 bytes at offset 20)
            bar.read_reg(dev_cfg_bar, dev_cfg_off + 32'h14, 4, data);
            cfg.supported_hash_types = data;

            // Read generation after
            read_config_generation(gen_after);

            if (gen_before == gen_after) begin
                `uvm_info("TRANSPORT",
                    $sformatf("Net config read atomically (gen=%0d)", gen_before),
                    UVM_HIGH)
                return;
            end

            retry_count++;
            `uvm_info("TRANSPORT",
                $sformatf("Config generation changed (%0d -> %0d), retrying (%0d)",
                          gen_before, gen_after, retry_count), UVM_MEDIUM)
        end
    endtask

    // ========================================================================
    // 队列配置：以下寄存器操作全部作用于"当前选中队列"，因此任何 Q_* 访问前
    // 必须先 select_queue；多线程并发选择会互相踩踏，调用方需自行串行化。
    // ========================================================================

    // 写 Q_SELECT 选中队列；后续 Q_* 寄存器都指向该队列。
    virtual task select_queue(int unsigned queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_SELECT, 2, queue_id);

        `uvm_info("TRANSPORT",
            $sformatf("Queue selected: %0d", queue_id), UVM_HIGH)
    endtask

    // 读当前队列的设备最大深度(Q_SIZE 读语义)；0 表示队列不可用。
    virtual task read_queue_num_max(ref int unsigned max_size);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_SIZE, 2, data);
        max_size = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("Queue num_max: %0d", max_size), UVM_HIGH)
    endtask

    // 写当前队列的实际使用深度；不校验是否超过设备 max(留给错误注入用)。
    virtual task write_queue_size(int unsigned size);
        cc_write(VIRTIO_PCI_COMMON_Q_SIZE, 2, size[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue size written: %0d", size), UVM_HIGH)
    endtask

    // 读当前队列的 notify 偏移序号；kick 时与 notify_off_multiplier 相乘
    // 得到通知地址。
    virtual task read_queue_notify_off(ref int unsigned off);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_NOFF, 2, data);
        off = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("Queue notify_off: %0d", off), UVM_HIGH)
    endtask

    // 以下三个写地址接口均按低 32 位/高 32 位两次写入 Guest 物理地址；
    // 描述符表(desc)地址。
    virtual task write_queue_desc_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_DESCLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_DESCHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue desc addr: 0x%016h", addr), UVM_HIGH)
    endtask

    // driver 区(split ring 的 avail ring)地址。
    virtual task write_queue_driver_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_AVAILLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_AVAILHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue driver (avail) addr: 0x%016h", addr), UVM_HIGH)
    endtask

    // device 区(split ring 的 used ring)地址。
    virtual task write_queue_device_addr(bit [63:0] addr);
        cc_write(VIRTIO_PCI_COMMON_Q_USEDLO, 4, addr[31:0]);
        cc_write(VIRTIO_PCI_COMMON_Q_USEDHI, 4, addr[63:32]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue device (used) addr: 0x%016h", addr), UVM_HIGH)
    endtask

    // 写当前队列使能位；须在地址等全部就绪后置 1(乱序属错误注入场景)。
    virtual task write_queue_enable(bit enable);
        cc_write(VIRTIO_PCI_COMMON_Q_ENABLE, 2, {31'h0, enable});

        `uvm_info("TRANSPORT",
            $sformatf("Queue enable: %0b", enable), UVM_HIGH)
    endtask

    // 回读当前队列使能位(仅 bit0)。
    virtual task read_queue_enable(ref bit enable);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_Q_ENABLE, 2, data);
        enable = data[0];
    endtask

    // 读设备支持的队列总数(NUMQ)；与选中队列无关，可随时读。
    virtual task read_num_queues(ref int unsigned num);
        bit [31:0] data;
        cc_read(VIRTIO_PCI_COMMON_NUMQ, 2, data);
        num = data[15:0];

        `uvm_info("TRANSPORT",
            $sformatf("num_queues: %0d", num), UVM_MEDIUM)
    endtask

    // ========================================================================
    // Queue Reset (virtio 1.2+)
    //
    // Select queue, write 1 to Q_RESET, then poll until Q_RESET reads back 0.
    // ========================================================================

    // The verified form is required before a caller may release queue DMA.
    // write_queue_reset() remains the backwards-compatible void wrapper.
    virtual task write_queue_reset_verified(int unsigned queue_id,
                                            ref bit reset_complete);
        bit [31:0] read_val;
        int unsigned elapsed = 0;
        int unsigned eff_timeout = wait_pol.effective_timeout(wait_pol.queue_reset_timeout_ns);
        int unsigned interval = wait_pol.default_poll_interval_ns;
        int unsigned attempts = 0;
        int unsigned max_att;
        longint unsigned quotient;

        reset_complete = 0;
        if (interval == 0)
            interval = 1;
        quotient = longint'(eff_timeout) / interval;
        if (quotient >= wait_pol.max_poll_attempts)
            max_att = wait_pol.max_poll_attempts;
        else
            max_att = quotient + 1;

        // Select queue and write reset
        select_queue(queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_RESET, 2, 32'h1);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d reset initiated", queue_id), UVM_MEDIUM)

        // Poll until Q_RESET reads back 0
        while (attempts < max_att) begin
            cc_read(VIRTIO_PCI_COMMON_Q_RESET, 2, read_val);
            if (read_val[15:0] == 16'h0) begin
                reset_complete = 1;
                break;
            end
            #(interval * 1ns);
            elapsed += interval;
            attempts++;
        end

        if (!reset_complete)
            `uvm_error("TRANSPORT",
                $sformatf("Queue %0d reset timeout after %0dns", queue_id, elapsed))
        else
            `uvm_info("TRANSPORT",
                $sformatf("Queue %0d reset complete", queue_id), UVM_HIGH)
    endtask

    virtual task write_queue_reset(int unsigned queue_id);
        bit reset_complete;
        write_queue_reset_verified(queue_id, reset_complete);
    endtask

    // ========================================================================
    // MSI-X 向量绑定：把 config-change/队列中断映射到 MSI-X 向量号；
    // 只写 common config 寄存器，向量表本身由 notify_mgr.setup_msix 填写。
    // ========================================================================

    // 绑定 config change 中断的 MSI-X 向量(写 COMMON_MSIX)。
    virtual task write_config_msix_vector(int unsigned vector);
        cc_write(VIRTIO_PCI_COMMON_MSIX, 2, vector[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Config MSI-X vector: %0d", vector), UVM_HIGH)
    endtask

    // 绑定指定队列的 MSI-X 向量：内部先 select_queue，会改变当前选中队列。
    virtual task write_queue_msix_vector(int unsigned queue_id, int unsigned vector);
        select_queue(queue_id);
        cc_write(VIRTIO_PCI_COMMON_Q_MSIX, 2, vector[15:0]);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d MSI-X vector: %0d", queue_id, vector), UVM_HIGH)
    endtask

    // ========================================================================
    // 读设备专属 net config：仅是 read_net_config_atomic 的兼容别名，
    // 始终带 generation 一致性检查。
    // ========================================================================

    virtual task read_net_config(ref virtio_net_device_config_t cfg);
        read_net_config_atomic(cfg);
    endtask

    // ========================================================================
    // kick
    //
    // Notifies the device that new buffers are available in the specified queue.
    //
    // The notification capability selects the BAR and base offset.  The
    // queue-specific notify_off value scales by notify_off_multiplier.
    // ========================================================================

    virtual task kick(int unsigned queue_id, int unsigned next_avail_idx, bit wrap_counter);
        bit [31:0] notify_data;
        bit is_packed;
        int unsigned notify_bar;
        bit [63:0] notify_offset;
        int unsigned notify_size;

        if (queue_id >= queue_notify_off.size()) begin
            `uvm_error("TRANSPORT",
                $sformatf("kick: queue_id %0d out of range (max %0d)",
                          queue_id, queue_notify_off.size() - 1))
            return;
        end

        if (notification_data_enable) begin
            is_packed = driver_features[VIRTIO_F_RING_PACKED];
            if (is_packed) begin
                // Packed: {wrap_counter[31], next_avail_idx[30:16], queue_id[15:0]}
                notify_data = {wrap_counter, next_avail_idx[14:0], queue_id[15:0]};
            end else begin
                // Split: {next_avail_idx[31:16], queue_id[15:0]}
                notify_data = {next_avail_idx[15:0], queue_id[15:0]};
            end
            notify_size = 4;
        end else begin
            notify_data = {16'h0, queue_id[15:0]};
            notify_size = 2;
        end

        notify_bar = cap_mgr.get_notify_bar();
        notify_offset = cap_mgr.get_notify_bar_offset(queue_notify_off[queue_id]);
        bar.write_reg(notify_bar, notify_offset[31:0], notify_size, notify_data);

        `uvm_info("TRANSPORT",
            $sformatf("kick: queue=%0d notify_addr=0x%016h size=%0d data=0x%08h",
                      queue_id, bar.bar_base[notify_bar] + notify_offset,
                      notify_size, notify_data), UVM_HIGH)
    endtask

    // ========================================================================
    // setup_single_queue
    //
    // Per-queue setup helper for use after ring allocation:
    //   select_queue -> write_queue_size -> write desc/driver/device addr ->
    //   write_queue_msix_vector -> read_queue_notify_off -> write_queue_enable(1)
    // ========================================================================

    virtual task setup_single_queue(
        int unsigned queue_id,
        int unsigned queue_size,
        bit [63:0]   desc_addr,
        bit [63:0]   driver_addr,
        bit [63:0]   device_addr,
        int unsigned msix_vector
    );
        int unsigned q_noff;

        select_queue(queue_id);
        write_queue_size(queue_size);
        write_queue_desc_addr(desc_addr);
        write_queue_driver_addr(driver_addr);
        write_queue_device_addr(device_addr);

        // Bind MSI-X vector
        cc_write(VIRTIO_PCI_COMMON_Q_MSIX, 2, msix_vector[15:0]);
        notify_mgr.bind_queue_vector(queue_id, msix_vector);

        // Read and store notify offset
        read_queue_notify_off(q_noff);
        if (queue_id < queue_notify_off.size()) begin
            queue_notify_off[queue_id] = q_noff;
        end else begin
            // Expand array if needed
            int unsigned old_size = queue_notify_off.size();
            int unsigned new_size = queue_id + 1;
            int unsigned temp_arr[];
            temp_arr = new[new_size];
            for (int i = 0; i < old_size; i++)
                temp_arr[i] = queue_notify_off[i];
            temp_arr[queue_id] = q_noff;
            queue_notify_off = temp_arr;
        end

        // Enable the queue
        write_queue_enable(1);

        `uvm_info("TRANSPORT",
            $sformatf("Queue %0d setup complete: size=%0d, desc=0x%016h, driver=0x%016h, device=0x%016h, msix=%0d, noff=%0d",
                      queue_id, queue_size, desc_addr, driver_addr, device_addr,
                      msix_vector, q_noff), UVM_MEDIUM)
    endtask

    // ========================================================================
    // discover_and_init_bars
    //
    // 唯一的发现入口：委托当前 discovery_strategy（fabric_preconfigured /
    // 后续 verify_snapshot）。策略失败时 fatal，因为后续所有寄存器访问都依赖它。
    // ========================================================================

    virtual task discover_and_init_bars();
        bit ok;
        string why;

        discovery_strategy.discover(this, ok, why);
        if (!ok)
            `uvm_fatal("TRANSPORT", {"BAR/capability discovery failed: ", why})
    endtask

    // Fabric 预配置发现的显式入口（virtio_fabric_resource_test 直接调用）；与
    // configure_fabric_managed() 安装的策略为同一实现，不经 discovery_strategy 分派。
    virtual task discover_fabric_preconfigured_bars();
        virtio_fabric_preconfigured_discovery fabric_discovery;
        bit ok;
        string why;

        fabric_discovery = virtio_fabric_preconfigured_discovery::type_id::create(
            "fabric_preconfigured_discovery");
        fabric_discovery.discover(this, ok, why);
        if (!ok)
            `uvm_fatal("TRANSPORT", {"Fabric discovery failed: ", why})
    endtask

endclass : virtio_pci_transport

`endif // VIRTIO_PCI_TRANSPORT_SV
