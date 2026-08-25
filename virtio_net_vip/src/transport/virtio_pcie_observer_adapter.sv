`ifndef VIRTIO_PCIE_OBSERVER_ADAPTER_SV
`define VIRTIO_PCIE_OBSERVER_ADAPTER_SV

// Passive bridge from pcie_tl_vip monitor traffic to semantic virtio monitor
// events.  It can be connected directly to pcie_tl_base_monitor::tlp_ap via
// its inherited analysis_export.
class virtio_pcie_observer_adapter extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(virtio_pcie_observer_adapter)

    virtio_monitor monitor;

    // A shared PCIe monitor has no implicit per-function affinity.  Each
    // adapter is explicitly bound to one function, then filters the common
    // stream using its BDF and current BAR/capability placement.
    bit [15:0] function_bdf;
    bit        function_bound;
    virtio_pci_transport transport;

    bit [63:0] common_cfg_base;
    bit [63:0] common_cfg_limit;
    bit [63:0] notify_cfg_base;
    bit [63:0] notify_cfg_limit;
    int unsigned selected_queue;
    protected bit queue_configured[int unsigned];
    protected bit queue_enabled[int unsigned];

    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_bdf = '0;
        function_bound = 0;
        transport = null;
        // No capability range is valid until it is either explicitly supplied
        // by a unit test or refreshed from a bound transport.
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
    endfunction

    // Side-effect-free validation for the environment's mandatory function
    // bind.  Keeping this nonvirtual prevents a factory subtype from bypassing
    // the base adapter endpoints that the mandatory commit relies on.
    function bit preflight_mandatory_function_binding(
        input virtio_pci_transport transport_ref,
        output string why
    );
        why = "";
        if (transport_ref == null) begin
            why = "transport_ref is null";
            return 0;
        end
        if (monitor == null) begin
            why = "observer monitor is null";
            return 0;
        end
        if (analysis_export == null) begin
            why = "observer analysis_export is null";
            return 0;
        end
        return 1;
    endfunction

    // Commit only the validated base-class binding state.  The environment
    // calls this nonvirtual mandatory path after every fallible preflight has
    // passed.  Capability discovery remains lazy in write(), so this commit
    // invokes no virtual hook and performs no fallible object dereference.
    function void commit_mandatory_function_binding(
        input bit [15:0] device_bdf,
        input virtio_pci_transport transport_ref
    );
        function_bdf = device_bdf;
        transport = transport_ref;
        function_bound = (transport_ref != null);
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
    endfunction

    // Compatibility entry point for callers outside virtio_net_env.  It
    // remains virtual, while mandatory environment binding uses the
    // nonvirtual preflight/commit pair above.  BAR placement and capability
    // discovery may complete after this call, so write() also refreshes the
    // derived ranges before it makes any routing choice.
    virtual function void configure_function(
        input bit [15:0] device_bdf,
        input virtio_pci_transport transport_ref
    );
        commit_mandatory_function_binding(device_bdf, transport_ref);
        refresh_capability_ranges();
    endfunction

    virtual function void write(pcie_tl_tlp t);
        pcie_tl_mem_tlp mem;
        pcie_tl_msg_tlp msg;
        bit [63:0] data;
        int unsigned size_bytes;
        int unsigned offset;
        int unsigned interrupt_vector;

        if (monitor == null) begin
            `uvm_warning("VIRTIO_OBSERVER", "Dropped PCIe monitor transaction without a virtio monitor")
            return;
        end

        if ($cast(mem, t)) begin
            if (function_bound)
                refresh_capability_ranges();
            size_bytes = mem.payload.size();
            if (size_bytes == 0)
                size_bytes = (mem.length == 0) ? 4096 : (mem.length * 4);
            data = payload_to_data(mem.payload);

            if (function_bound && decode_msi_memory_write(
                    mem, data, interrupt_vector)) begin
                monitor.observe_interrupt(interrupt_vector);
            end
            else if ((mem.addr >= common_cfg_base) && (mem.addr <= common_cfg_limit)) begin
                offset = mem.addr - common_cfg_base;
                decode_common_access(mem, offset, size_bytes, data);
            end
            else if ((mem.kind == TLP_MEM_WR) &&
                     (mem.addr >= notify_cfg_base) && (mem.addr <= notify_cfg_limit)) begin
                monitor.observe_queue_notify(data[15:0]);
            end
            else if (function_bound && address_in_owned_bar(mem.addr)) begin
                // Other owned BAR regions (ISR, device configuration, MSI-X,
                // vendor extensions) are still function MMIO, never DMA.
                monitor.observe_bar_access(mem.addr, mem.kind == TLP_MEM_WR,
                    size_bytes, data, owned_bar_offset(mem.addr));
            end
            else if (function_bound && (mem.requester_id == function_bdf)) begin
                // EP-to-RC memory requests carry the function requester BDF.
                // This is the sole generic DMA acceptance path, and it is
                // deliberately evaluated only after all own MMIO regions.
                monitor.observe_dma(mem.addr, size_bytes, mem.kind == TLP_MEM_WR);
            end
        end
        else if ($cast(msg, t)) begin
            // Legacy INTx is encoded as a no-data, RC-routed Message TLP
            // carrying one of the ASSERT_INTx codes.  LTR, PME, error, and
            // deassert Messages are not virtio completions merely because a
            // numeric message code happens to equal an MSI-X vector.
            if (function_bound && (msg.requester_id == function_bdf) &&
                is_intx_assert_message(msg)) begin
                transport.notify_mgr.on_intx_interrupt();
                monitor.observe_interrupt(int'(msg.msg_code));
            end
        end
    endfunction

    protected virtual function bit is_intx_assert_message(
        input pcie_tl_msg_tlp msg
    );
        if ((transport == null) || (transport.notify_mgr == null) ||
            (transport.notify_mgr.irq_mode != IRQ_INTX))
            return 0;
        if ((msg.kind != TLP_MSG) || (msg.fmt != FMT_4DW_NO_DATA) ||
            (msg.type_f != TLP_TYPE_MSG_RC))
            return 0;
        return msg.msg_code inside {MSG_ASSERT_INTA, MSG_ASSERT_INTB,
                                    MSG_ASSERT_INTC, MSG_ASSERT_INTD};
    endfunction

    // MSI and MSI-X are posted Memory Writes to the local APIC window.  Some
    // PCIe monitors leave requester_id at zero for this path, so a configured
    // MSI-X message address/data pair owns the routing decision.  Plain MSI
    // has no table entry; its function BDF remains the safe fallback.
    protected virtual function bit decode_msi_memory_write(
        input pcie_tl_mem_tlp mem,
        input bit [63:0] data,
        output int unsigned interrupt_vector
    );
        interrupt_vector = 0;
        if ((mem.kind != TLP_MEM_WR) || !is_msi_address(mem.addr))
            return 0;
        if (transport != null) begin
            foreach (transport.notify_mgr.msix_table[vector]) begin
                if ((transport.notify_mgr.msix_table[vector].msg_addr == mem.addr) &&
                    (transport.notify_mgr.msix_table[vector].msg_data == data[31:0])) begin
                    interrupt_vector = int'(data[15:0]);
                    return 1;
                end
            end
        end
        if (mem.requester_id == function_bdf) begin
            interrupt_vector = int'(data[15:0]);
            return 1;
        end
        return 0;
    endfunction

    protected virtual function bit is_msi_address(input bit [63:0] address);
        return (address >= 64'h0000_0000_FEE0_0000) &&
               (address <= 64'h0000_0000_FEEF_FFFF);
    endfunction

    // Derive capability windows from the currently assigned BAR map.  A
    // malformed/unassigned capability is treated as absent; accepting it
    // would make a shared monitor route arbitrary address space as virtio.
    protected virtual function void refresh_capability_ranges();
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
        if (transport == null)
            return;

        if (transport.cap_mgr.common_cfg_found)
            set_capability_range(transport.cap_mgr.common_cfg_cap.bar,
                transport.cap_mgr.common_cfg_cap.offset,
                transport.cap_mgr.common_cfg_cap.length,
                common_cfg_base, common_cfg_limit);
        if (transport.cap_mgr.notify_found)
            set_capability_range(transport.cap_mgr.notify_cap.bar,
                transport.cap_mgr.notify_cap.offset,
                transport.cap_mgr.notify_cap.length,
                notify_cfg_base, notify_cfg_limit);
    endfunction

    protected virtual function void set_capability_range(
        input int unsigned bar_id,
        input bit [31:0] cap_offset,
        input bit [31:0] cap_length,
        output bit [63:0] range_base,
        output bit [63:0] range_limit
    );
        bit [63:0] bar_base;
        bit [63:0] bar_size;
        bit [63:0] candidate_base;
        bit [63:0] candidate_limit;
        bit [63:0] bar_limit;

        range_base = '1;
        range_limit = '0;
        if ((transport == null) || (bar_id >= 6) || (cap_length == 0))
            return;
        bar_base = transport.bar.bar_base[bar_id];
        bar_size = transport.bar.bar_size[bar_id];
        if (bar_size == 0)
            return;
        candidate_base = bar_base + cap_offset;
        candidate_limit = candidate_base + cap_length - 1;
        bar_limit = bar_base + bar_size - 1;
        if ((candidate_base < bar_base) || (candidate_limit < candidate_base) ||
            (bar_limit < bar_base) || (candidate_base < bar_base) ||
            (candidate_limit > bar_limit))
            return;
        range_base = candidate_base;
        range_limit = candidate_limit;
    endfunction

    protected virtual function bit address_in_owned_bar(input bit [63:0] address);
        bit [63:0] bar_base;
        bit [63:0] bar_size;
        bit [63:0] bar_limit;

        if (transport == null)
            return 0;
        for (int unsigned bar_id = 0; bar_id < 6; bar_id++) begin
            bar_base = transport.bar.bar_base[bar_id];
            bar_size = transport.bar.bar_size[bar_id];
            if (bar_size == 0)
                continue;
            bar_limit = bar_base + bar_size - 1;
            if ((bar_limit >= bar_base) && (address >= bar_base) &&
                (address <= bar_limit))
                return 1;
        end
        return 0;
    endfunction

    protected virtual function int unsigned owned_bar_offset(
        input bit [63:0] address
    );
        bit [63:0] bar_base;
        bit [63:0] bar_size;
        bit [63:0] bar_limit;

        if (transport == null)
            return 0;
        for (int unsigned bar_id = 0; bar_id < 6; bar_id++) begin
            bar_base = transport.bar.bar_base[bar_id];
            bar_size = transport.bar.bar_size[bar_id];
            if (bar_size == 0)
                continue;
            bar_limit = bar_base + bar_size - 1;
            if ((bar_limit >= bar_base) && (address >= bar_base) &&
                (address <= bar_limit))
                return int'(address - bar_base);
        end
        return 0;
    endfunction

    protected virtual function void decode_common_access(
        input pcie_tl_mem_tlp mem,
        input int unsigned offset,
        input int unsigned size_bytes,
        input bit [63:0] data
    );
        bit is_write;

        is_write = (mem.kind == TLP_MEM_WR);
        case (offset)
            VIRTIO_PCI_COMMON_STATUS: begin
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data, offset);
                if (is_write && (data[7:0] == DEV_STATUS_RESET))
                    reset_all_queue_state();
            end
            VIRTIO_PCI_COMMON_Q_SELECT: begin
                // Reads have no request payload and must not change selection.
                if (is_write)
                    selected_queue = data[15:0];
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data, offset);
            end
            VIRTIO_PCI_COMMON_Q_SIZE,
            VIRTIO_PCI_COMMON_Q_DESCLO,
            VIRTIO_PCI_COMMON_Q_DESCHI,
            VIRTIO_PCI_COMMON_Q_AVAILLO,
            VIRTIO_PCI_COMMON_Q_AVAILHI,
            VIRTIO_PCI_COMMON_Q_USEDLO,
            VIRTIO_PCI_COMMON_Q_USEDHI: begin
                if (is_write)
                    queue_configured[selected_queue] = 1;
                monitor.observe_queue_state(selected_queue,
                    queue_configured.exists(selected_queue) && queue_configured[selected_queue],
                    queue_enabled.exists(selected_queue) && queue_enabled[selected_queue]);
            end
            VIRTIO_PCI_COMMON_Q_ENABLE: begin
                if (is_write)
                    queue_enabled[selected_queue] = (data[0] != 0);
                monitor.observe_queue_state(selected_queue,
                    queue_configured.exists(selected_queue) && queue_configured[selected_queue],
                    queue_enabled.exists(selected_queue) && queue_enabled[selected_queue]);
            end
            VIRTIO_PCI_COMMON_Q_RESET: begin
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data, offset);
                if (is_write && data[0])
                    reset_queue_state(selected_queue);
            end
            default: monitor.observe_bar_access(mem.addr, is_write, size_bytes, data, offset);
        endcase
    endfunction

    protected virtual function void reset_queue_state(input int unsigned queue_id);
        queue_configured.delete(queue_id);
        queue_enabled.delete(queue_id);
        monitor.reset_queue_state(queue_id);
    endfunction

    protected virtual function void reset_all_queue_state();
        queue_configured.delete();
        queue_enabled.delete();
        selected_queue = 0;
        monitor.reset_all_queue_state();
    endfunction

    protected function bit [63:0] payload_to_data(input bit [7:0] payload[]);
        bit [63:0] data;
        data = '0;
        for (int unsigned i = 0; (i < payload.size()) && (i < 8); i++)
            data[i * 8 +: 8] = payload[i];
        return data;
    endfunction
endclass : virtio_pcie_observer_adapter

`endif // VIRTIO_PCIE_OBSERVER_ADAPTER_SV
