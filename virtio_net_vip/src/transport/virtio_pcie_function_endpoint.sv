`ifndef VIRTIO_PCIE_FUNCTION_ENDPOINT_SV
`define VIRTIO_PCIE_FUNCTION_ENDPOINT_SV

// One externally configured PCIe path for one resolved function identity.
// Multiple functions in one domain may share the same RC/monitor handles, but
// callers still register each complete {host, segment, BDF} key explicitly so
// equal numeric BDFs in independent domains can never select by BDF alone.
//
// 中文定位：transport 目录内的"单 function PCIe 通路"打包对象，由多 domain
// 环境按完整 {host, segment, BDF} 键显式注册/查找。
// 职责：集中保存一个已解析 function 的 RC sequencer / RC driver /
// completion adapter / RC 与 EP monitor 引用，并提供 matches_id/validate
// 两个查询，供 virtio_pci_transport::bind_pcie_endpoint 绑定前校验。
// 依赖：dpu_pcie_function_id_t 及其 domain key 比较/命名工具、pcie_tl_vip
// 组件类型、virtio_tlm_completion_adapter。
// 所有权/生命周期：uvm_object，由注册方创建并持有；内部全部为借用引用，
// 不拥有任何组件也不负责断开；configure() 可整体覆盖旧配置。
class virtio_pcie_function_endpoint extends uvm_object;
    `uvm_object_utils(virtio_pcie_function_endpoint)

    dpu_pcie_function_id_t             pcie_id;
    bit                                configured;
    uvm_sequencer #(pcie_tl_tlp)       rc_seqr;
    pcie_tl_base_driver                rc_driver;
    virtio_tlm_completion_adapter      completion_adapter;
    pcie_tl_base_monitor               rc_monitor;
    pcie_tl_base_monitor               ep_monitor;

    // 构造即为"未配置"状态；所有句柄留默认空值，必须经 configure() 才可用。
    function new(string name = "virtio_pcie_function_endpoint");
        super.new(name);
        configured = 0;
    endfunction

    // 一次性登记该 function 的全部 PCIe 通路引用：只有 rc_seqr 语义上必填，
    // 其余默认 null 表示该角色缺席(是否成立由 validate() 事后判定)。
    // 重复调用会整体覆盖旧配置并保持 configured=1。
    function void configure(
        input dpu_pcie_function_id_t function_id,
        input uvm_sequencer #(pcie_tl_tlp) endpoint_rc_seqr,
        input pcie_tl_base_driver endpoint_rc_driver = null,
        input virtio_tlm_completion_adapter endpoint_completion_adapter = null,
        input pcie_tl_base_monitor endpoint_rc_monitor = null,
        input pcie_tl_base_monitor endpoint_ep_monitor = null
    );
        pcie_id = function_id;
        rc_seqr = endpoint_rc_seqr;
        rc_driver = endpoint_rc_driver;
        completion_adapter = endpoint_completion_adapter;
        rc_monitor = endpoint_rc_monitor;
        ep_monitor = endpoint_ep_monitor;
        configured = 1;
    endfunction

    // 判断给定 function id 是否命中本 endpoint：要求已配置、domain key 完全
    // 一致且 BDF 相等——独立 domain 中数值相同的 BDF 不会误命中。纯查询。
    function bit matches_id(input dpu_pcie_function_id_t function_id);
        return configured &&
            dpu_same_domain_key(pcie_id.domain, function_id.domain) &&
            (pcie_id.bdf == function_id.bdf);
    endfunction

    // 结构一致性校验(无副作用)：未配置、缺 RC sequencer、monitor 存在但其
    // analysis port 为空、或配了 completion adapter 却没有 RC driver 均判
    // 失败，why 带回可读原因。只检查空指针组合，不验证组件是否真正连线。
    function bit validate(output string why);
        why = "";
        if (!configured) begin
            why = "PCIe function endpoint is not configured";
            return 0;
        end
        if (rc_seqr == null) begin
            why = {"PCIe function endpoint has a null RC sequencer for ",
                   dpu_pcie_function_id_name(pcie_id)};
            return 0;
        end
        if ((rc_monitor != null) && (rc_monitor.tlp_ap == null)) begin
            why = {"PCIe function endpoint has a null RC monitor analysis port for ",
                   dpu_pcie_function_id_name(pcie_id)};
            return 0;
        end
        if ((ep_monitor != null) && (ep_monitor.tlp_ap == null)) begin
            why = {"PCIe function endpoint has a null EP monitor analysis port for ",
                   dpu_pcie_function_id_name(pcie_id)};
            return 0;
        end
        if ((completion_adapter != null) && (rc_driver == null)) begin
            why = {"PCIe function endpoint completion adapter has no RC driver for ",
                   dpu_pcie_function_id_name(pcie_id)};
            return 0;
        end
        return 1;
    endfunction
endclass : virtio_pcie_function_endpoint

`endif // VIRTIO_PCIE_FUNCTION_ENDPOINT_SV
