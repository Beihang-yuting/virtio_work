`ifndef VIRTIO_PCIE_FUNCTION_ENDPOINT_SV
`define VIRTIO_PCIE_FUNCTION_ENDPOINT_SV

// One externally configured PCIe path for one resolved function identity.
// Multiple functions in one domain may share the same RC/monitor handles, but
// callers still register each complete {host, segment, BDF} key explicitly so
// equal numeric BDFs in independent domains can never select by BDF alone.
class virtio_pcie_function_endpoint extends uvm_object;
    `uvm_object_utils(virtio_pcie_function_endpoint)

    dpu_pcie_function_id_t             pcie_id;
    bit                                configured;
    uvm_sequencer #(pcie_tl_tlp)       rc_seqr;
    pcie_tl_base_driver                rc_driver;
    virtio_tlm_completion_adapter      completion_adapter;
    pcie_tl_base_monitor               rc_monitor;
    pcie_tl_base_monitor               ep_monitor;

    function new(string name = "virtio_pcie_function_endpoint");
        super.new(name);
        configured = 0;
    endfunction

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

    function bit matches_id(input dpu_pcie_function_id_t function_id);
        return configured &&
            dpu_same_domain_key(pcie_id.domain, function_id.domain) &&
            (pcie_id.bdf == function_id.bdf);
    endfunction

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
