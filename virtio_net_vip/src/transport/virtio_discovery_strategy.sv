`ifndef VIRTIO_DISCOVERY_STRATEGY_SV
`define VIRTIO_DISCOVERY_STRATEGY_SV

// ============================================================================
// virtio_discovery_strategy
//
// 目录层次：src/transport；BAR/capability 发现策略。transport 只持有当前策略并在
// discover_and_init_bars() 中调用；策略借用 transport 的 bar/cap_mgr/notify_mgr，
// 不拥有它们，也不保存跨调用状态。
//   enumerate            : PCI BAR sizing + 本地地址分配，仅用于非 Fabric function。
//   fabric_preconfigured : 按冻结 snapshot 的 BAR 租约写配置空间，只扫描 capability，
//                          再经 resource client 进入 device-ready。
// 后续 verify_snapshot 策略在 fabric_preconfigured 之前读硬件身份并与 snapshot 核对。
// 本文件在 virtio_pci_transport 之前编译，经 types 中的前向 typedef 引用 transport。
// ============================================================================

virtual class virtio_discovery_strategy extends uvm_object;
    // 无状态；构造不访问设备。
    function new(string name = "virtio_discovery_strategy");
        super.new(name);
    endfunction

    // 策略名，供配置回显与测试断言。
    pure virtual function string strategy_name();
    // 发现并初始化 transport 的 BAR/capability 视图；ok=0 时 why 给出原因，
    // 调用方负责报告。实现可对不可恢复的配置错误直接 fatal。
    pure virtual task discover(virtio_pci_transport transport, output bit ok,
                               output string why);
endclass

// 传统 PCI 枚举：sizing 全部 BAR、按本地窗口分配地址，再扫描 virtio capability。
class virtio_enumerate_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_enumerate_discovery)

    // 无状态；构造不访问设备。
    function new(string name = "virtio_enumerate_discovery");
        super.new(name);
    endfunction

    virtual function string strategy_name();
        return "enumerate";
    endfunction

    //   1. bar.enumerate_bars()
    //   2. cap_mgr.bar_ref = bar
    //   3. cap_mgr.discover_capabilities()
    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        why = "";
        `uvm_info("TRANSPORT", "Starting BAR discovery and capability enumeration", UVM_MEDIUM)

        // Set BDF on bar accessor
        transport.bar.requester_id = transport.bdf;

        // Step 1: Enumerate BARs
        transport.bar.enumerate_bars();

        // Step 2: Wire bar reference into cap manager
        transport.cap_mgr.bar_ref = transport.bar;

        // Step 3: Discover virtio PCI capabilities
        transport.cap_mgr.discover_capabilities();

        `uvm_info("TRANSPORT", "BAR discovery and capability enumeration complete", UVM_MEDIUM)
        ok = 1;
    endtask
endclass

// Fabric owns BAR placement, but the root complex still must program all
// three 64-bit BAR pairs through PCI config space before discovery.  This
// path then scans capabilities and lets the virtio resource client mark
// the function device-ready.
class virtio_fabric_preconfigured_discovery extends virtio_discovery_strategy;
    `uvm_object_utils(virtio_fabric_preconfigured_discovery)

    // 无状态；构造不访问设备。
    function new(string name = "virtio_fabric_preconfigured_discovery");
        super.new(name);
    endfunction

    virtual function string strategy_name();
        return "fabric_preconfigured";
    endfunction

    // Fabric 专用校验(无副作用)：确认发现到的 virtio 能力落在 Fabric 约定的
    // BAR 角色窗口内——common/ISR/device/pci cfg 在 BAR0、notify 在 BAR2
    // (mailbox)、MSI-X 在 BAR4；任何偏离都拒绝并经 why 说明原因，
    // 防止把错误的 BAR 角色布局当成合法 DUT profile。
    protected function bit capabilities_use_fabric_windows(
        virtio_pci_transport transport,
        output string why
    );
        why = "";
        if (!transport.cap_mgr.common_cfg_found || !transport.cap_mgr.notify_found ||
            !transport.cap_mgr.isr_found) begin
            why = "mandatory virtio capabilities were not discovered";
            return 0;
        end
        // The Fabric profile has a split functional layout: BAR0/1 carries
        // common/ISR/device configuration, while BAR2/3 is the mailbox and
        // therefore owns the virtio notification capability.  Do not force
        // notify into BAR0; doing so rejects the real-DUT profile even though
        // the discovered BAR role and notify address are correct.
        if ((transport.cap_mgr.common_cfg_cap.bar != 0) ||
            (transport.cap_mgr.notify_cap.bar != 2) ||
            (transport.cap_mgr.isr_cap.bar != 0) ||
            (transport.cap_mgr.device_cfg_found &&
             (transport.cap_mgr.device_cfg_cap.bar != 0)) ||
            (transport.cap_mgr.pci_cfg_found &&
             (transport.cap_mgr.pci_cfg_cap.bar != 0))) begin
            why = "virtio functional capability did not resolve to Fabric BAR0/1";
            return 0;
        end
        if (transport.cap_mgr.msix_found &&
            (transport.cap_mgr.msix_table_bir != 4)) begin
            why = "MSI-X capability did not resolve to Fabric BAR4/5";
            return 0;
        end
        return 1;
    endfunction

    // 只对 Fabric 托管 function 生效：编程三对 BAR、扫描 capability、核对 BAR 角色窗口，
    // 最后由 resource client 标记 device-ready。配置错误直接 fatal（与原 transport 行为一致）。
    virtual task discover(virtio_pci_transport transport, output bit ok,
                          output string why);
        string check_why;

        ok = 0;
        why = "";
        if (!transport.is_fabric_managed()) begin
            `uvm_fatal("TRANSPORT",
                "Fabric preconfigured discovery requested for a non-Fabric function")
        end
        if (!transport.bar.fabric_bar_layout_is_active()) begin
            `uvm_fatal("TRANSPORT",
                "Fabric function has no preconfigured BAR role layout")
        end
        if (transport.fabric_resource_client == null) begin
            `uvm_fatal("TRANSPORT",
                "Fabric function has no resource client for device-ready lifecycle")
        end

        transport.bar.requester_id = transport.bdf;
        transport.cap_mgr.bar_ref = transport.bar;
        transport.notify_mgr.bar = transport.bar;
        transport.bar.program_fabric_bar_pairs();
        transport.cap_mgr.discover_capabilities();
        if (!capabilities_use_fabric_windows(transport, check_why)) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "Fabric capability discovery rejected BAR roles: %s", check_why))
        end
        transport.fabric_capability_discovered = 1;
        if (!transport.fabric_resource_client.mark_runtime_ready(check_why)) begin
            `uvm_fatal("TRANSPORT", $sformatf(
                "Fabric device-ready transition failed after discovery: %s", check_why))
        end
        `uvm_info("TRANSPORT",
            "Fabric BAR configuration and capability discovery complete without BAR enumeration",
            UVM_MEDIUM)
        ok = 1;
    endtask
endclass

`endif // VIRTIO_DISCOVERY_STRATEGY_SV
