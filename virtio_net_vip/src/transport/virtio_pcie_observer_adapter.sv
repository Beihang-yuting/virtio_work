`ifndef VIRTIO_PCIE_OBSERVER_ADAPTER_SV
`define VIRTIO_PCIE_OBSERVER_ADAPTER_SV

// Passive bridge from pcie_tl_vip monitor traffic to semantic virtio monitor
// events.  It can be connected directly to pcie_tl_base_monitor::tlp_ap via
// its inherited analysis_export.
// 中文契约：本适配器只借用 PCIe monitor、virtio monitor 和可选 transport，不拥有
// TLP、driver 或 BAR backing；生命周期为构造后 preflight/commit 绑定，能力窗口在
// write() 中按需刷新。未完成 function identity/capability 绑定时，地址路由保持保守，
// 不把未知地址误判为 virtio MMIO 或 DMA。
class virtio_pcie_observer_adapter extends uvm_subscriber #(pcie_tl_tlp);
    `uvm_component_utils(virtio_pcie_observer_adapter)

    virtio_monitor monitor;

    // A shared PCIe monitor has no implicit per-function affinity.  Each
    // adapter is explicitly bound to one function, then filters the common
    // stream using its BDF and current BAR/capability placement.
    bit [15:0] function_bdf;
    dpu_pcie_function_id_t function_pcie_id;
    bit                    function_pcie_id_valid;
    bit        function_bound;
    virtio_pci_transport transport;

    bit [63:0] common_cfg_base;
    bit [63:0] common_cfg_limit;
    bit [63:0] notify_cfg_base;
    bit [63:0] notify_cfg_limit;
    int unsigned selected_queue;
    protected bit queue_configured[int unsigned];
    protected bit queue_enabled[int unsigned];

    // 创建未绑定 observer；初始 capability range 为无效哨兵，不连接外部对象。
    function new(string name, uvm_component parent);
        super.new(name, parent);
        function_bdf = '0;
        function_pcie_id_valid = 0;
        function_bound = 0;
        transport = null;
        // No capability range is valid until it is either explicitly supplied
        // by a unit test or refreshed from a bound transport.
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
    endfunction

    // 接口契约：输入待绑定 transport_ref，why 返回前置检查失败原因；函数无副作用，
    // 只检查 transport、monitor 和 analysis_export 非空，失败时不得继续 commit。
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

    // 接口契约：提交 BDF-only 兼容绑定或 transport identity 绑定；会覆盖旧身份并
    // 清空已派生 capability range，等待后续 lazy refresh。调用方应先通过 preflight；
    // 本函数无返回值，不能单独作为绑定成功证明。
    // Commit only the validated base-class binding state.  The environment
    // calls this nonvirtual mandatory path after every fallible preflight has
    // passed.  Capability discovery remains lazy in write(), so this commit
    // invokes no virtual hook and performs no fallible object dereference.
    function void commit_mandatory_function_binding(
        input bit [15:0] device_bdf,
        input virtio_pci_transport transport_ref
    );
        if ((transport_ref != null) && transport_ref.pcie_id_valid) begin
            commit_mandatory_function_identity_binding(
                transport_ref.pcie_id, transport_ref);
            return;
        end
        function_bdf = device_bdf;
        function_pcie_id_valid = 0;
        transport = transport_ref;
        function_bound = (transport_ref != null);
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
    endfunction

    // 接口契约：提交完整 dpu PCIe function identity（含 BDF/Host/segment 等字段），
    // 借用 transport_ref，不转移所有权；同样会重置 capability range。
    function void commit_mandatory_function_identity_binding(
        input dpu_pcie_function_id_t device_pcie_id,
        input virtio_pci_transport transport_ref
    );
        function_pcie_id = device_pcie_id;
        function_pcie_id_valid = 1;
        function_bdf = device_pcie_id.bdf;
        transport = transport_ref;
        function_bound = (transport_ref != null);
        common_cfg_base = '1;
        common_cfg_limit = '0;
        notify_cfg_base = '1;
        notify_cfg_limit = '0;
    endfunction

    // 接口契约：外部兼容入口，输入 BDF 和 transport，立即提交并尝试刷新能力窗口；
    // 无返回值，null transport 只留下未绑定/无效窗口状态，调用方仍需自行检查。
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

    // 接口契约：被动接收 monitor TLP。空对象、未匹配的 Mem/Msg、未绑定 function 或
    // 不属于本 function 的 requester/BAR 会被丢弃；匹配事务可能调用 virtio monitor
    // 的 MMIO/notify/DMA/interrupt 回调并更新 queue state。处理顺序固定为 MSI/MSI-X、
    // common config、notify、已拥有 BAR、最后才是 requester-qualified DMA。
    virtual function void write(pcie_tl_tlp t);
        pcie_tl_mem_tlp mem;
        pcie_tl_msg_tlp msg;
        bit [63:0] data;
        int unsigned size_bytes;
        int unsigned offset;
        int unsigned common_bar_id;
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
                // PCIe memory TLP addresses are naturally DWord aligned; the
                // first byte-enable selects the actual register lane (for
                // example Q_SELECT at +0x16 is sent as address +0x14 with
                // first_be=4'b1100).  Decode the effective byte offset or a
                // queue-select write would be mistaken for STATUS at +0x14.
                offset = (mem.addr - common_cfg_base) +
                         first_enabled_byte(mem.first_be);
                // 中文说明：纯 monitor 单元测试可以只提供地址窗口而不构造
                // transport。此时仍应完成语义解码，BAR 编号使用未知哨兵，
                // 不能因为观测器缺少可选 transport 而触发空句柄访问。
                common_bar_id = 32'hffff_ffff;
                if ((transport != null) && (transport.cap_mgr != null))
                    common_bar_id = transport.cap_mgr.common_cfg_cap.bar;
                decode_common_access(mem, offset, size_bytes, data,
                    common_bar_id);
            end
            else if ((mem.kind == TLP_MEM_WR) &&
                     (mem.addr >= notify_cfg_base) && (mem.addr <= notify_cfg_limit)) begin
                monitor.observe_queue_notify(
                    data[15:0],
                    int'((mem.addr - notify_cfg_base) +
                         first_enabled_byte(mem.first_be)), mem.addr);
            end
            else if (function_bound && address_in_owned_bar(mem.addr)) begin
                // Other owned BAR regions (ISR, device configuration, MSI-X,
                // vendor extensions) are still function MMIO, never DMA.
                monitor.observe_bar_access(mem.addr, mem.kind == TLP_MEM_WR,
                    size_bytes, data,
                    owned_bar_offset(mem.addr) + first_enabled_byte(mem.first_be),
                    owned_bar_id(mem.addr));
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

    // 仅识别当前 IRQ_INTX 模式下合法的 ASSERT_INTA..D 消息；其它 Message 或模式
    // 返回 0，不产生中断副作用。
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

    // MSI/MSI-X 辅助：输出匹配的 vector；地址/数据与已配置 MSI-X 表或 requester
    // 不匹配时返回 0。成功时 write() 会调用 notify_mgr sideband，不生成 Host memory 写。
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

    // 检查地址是否处于架构 MSI APIC aperture；纯判断，无副作用。
    protected virtual function bit is_msi_address(input bit [63:0] address);
        return (address >= 64'h0000_0000_FEE0_0000) &&
               (address <= 64'h0000_0000_FEEF_FFFF);
    endfunction

    // 根据当前 BAR/capability 派生绝对地址窗口；未绑定、长度为零或越界时留下无效
    // 哨兵。只更新 adapter 缓存，不写 PCIe 配置空间。
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

    // 将 BAR、cap offset/length 转成地址范围；输出无效哨兵表示 BAR 未分配、参数越界
    // 或算术溢出。函数只计算，不触发 monitor 回调。
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

    // 以下三个 BAR helper 只查询当前 transport 的 BAR 表：命中返回 true/offset/id，
    // 未命中返回 false/0/ffff_ffff；不改变路由状态。
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

    protected virtual function int unsigned owned_bar_id(
        input bit [63:0] address
    );
        bit [63:0] bar_base;
        bit [63:0] bar_size;
        bit [63:0] bar_limit;

        if (transport == null)
            return 32'hffff_ffff;
        for (int unsigned bar_id = 0; bar_id < 6; bar_id++) begin
            bar_base = transport.bar.bar_base[bar_id];
            bar_size = transport.bar.bar_size[bar_id];
            if (bar_size == 0)
                continue;
            bar_limit = bar_base + bar_size - 1;
            if ((bar_limit >= bar_base) && (address >= bar_base) &&
                (address <= bar_limit))
                return bar_id;
        end
        return 32'hffff_ffff;
    endfunction

    // 返回首个 byte-enable 对应的 DWORD 内偏移；全零 BE 按兼容约定返回 0。
    protected function int unsigned first_enabled_byte(input bit [3:0] be);
        if (be[0]) return 0;
        if (be[1]) return 1;
        if (be[2]) return 2;
        if (be[3]) return 3;
        return 0;
    endfunction

    // 解码 common config 事务并更新 selected_queue、queue_configured/enabled；非法
    // 或非写事务只做观测，不改变选择，实际回调均经 virtio monitor 转发。
    protected virtual function void decode_common_access(
        input pcie_tl_mem_tlp mem,
        input int unsigned offset,
        input int unsigned size_bytes,
        input bit [63:0] data,
        input int unsigned common_bar_id
    );
        bit is_write;

        is_write = (mem.kind == TLP_MEM_WR);
        case (offset)
            VIRTIO_PCI_COMMON_STATUS: begin
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data,
                    offset, common_bar_id);
                if (is_write && (data[7:0] == DEV_STATUS_RESET))
                    reset_all_queue_state();
            end
            VIRTIO_PCI_COMMON_Q_SELECT: begin
                // Reads have no request payload and must not change selection.
                if (is_write) begin
                    // Q_SELECT is a 16-bit register at +0x16.  PCIe carries
                    // the write in the addressed byte lanes of the aligned
                    // DWORD (normally data[31:16] with first_be=1100), not
                    // necessarily in data[15:0].
                    // Unit-level callers may model the naturally addressed
                    // half-word directly and leave BE at zero; retain that
                    // legacy representation instead of interpreting an
                    // unqualified payload as the upper half.
                    if ((mem.first_be[3:2] != 2'b00) &&
                        (mem.first_be[1:0] == 2'b00))
                        selected_queue = data[31:16];
                    else
                        selected_queue = data[15:0];
                end
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data,
                    offset, common_bar_id);
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
                    queue_enabled.exists(selected_queue) && queue_enabled[selected_queue],
                    offset, data, is_write);
            end
            VIRTIO_PCI_COMMON_Q_ENABLE: begin
                if (is_write)
                    queue_enabled[selected_queue] = (data[0] != 0);
                monitor.observe_queue_state(selected_queue,
                    queue_configured.exists(selected_queue) && queue_configured[selected_queue],
                    queue_enabled.exists(selected_queue) && queue_enabled[selected_queue],
                    offset, data, is_write);
            end
            VIRTIO_PCI_COMMON_Q_RESET: begin
                monitor.observe_bar_access(mem.addr, is_write, size_bytes, data,
                    offset, common_bar_id);
                if (is_write && data[0])
                    reset_queue_state(selected_queue);
            end
            default: monitor.observe_bar_access(mem.addr, is_write, size_bytes, data,
                offset, common_bar_id);
        endcase
    endfunction

    // 清除单队列路由缓存并通知 monitor；不释放 virtqueue 或 Host memory。
    protected virtual function void reset_queue_state(input int unsigned queue_id);
        queue_configured.delete(queue_id);
        queue_enabled.delete(queue_id);
        monitor.reset_queue_state(queue_id);
    endfunction

    // 清除全部队列选择/使能缓存并通知 monitor；不改变 function identity/BAR。
    protected virtual function void reset_all_queue_state();
        queue_configured.delete();
        queue_enabled.delete();
        selected_queue = 0;
        monitor.reset_all_queue_state();
    endfunction

    // 将 TLP payload 的最多前 8 字节按 little-endian 拼成解码数据；短 payload
    // 其余字节补零，超出部分截断，不修改原 payload。
    protected function bit [63:0] payload_to_data(input bit [7:0] payload[]);
        bit [63:0] data;
        data = '0;
        for (int unsigned i = 0; (i < payload.size()) && (i < 8); i++)
            data[i * 8 +: 8] = payload[i];
        return data;
    endfunction
endclass : virtio_pcie_observer_adapter

`endif // VIRTIO_PCIE_OBSERVER_ADAPTER_SV
