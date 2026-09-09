`ifndef VIRTIO_PCIE_MODEL_DMA_ADAPTER_SV
`define VIRTIO_PCIE_MODEL_DMA_ADAPTER_SV

// MODEL 专用的设备侧 DMA 适配器。
//
// 真实 DUT 模式不会创建本对象；真实 DUT 自己通过 PCIe 链路产生 TLP。
// 本对象只使用 pcie_work VIP 的公开 send_tlp() 和 read-back 字段，把行为
// 模型的 DMA 请求转换成合法的 EP-originated PCIe MemRd/MemWr。
// 主要依赖：pcie_tl_pkg 的 EP driver/TLP 类型。所有权：借用调用方 EP driver，
// 不创建、不释放 driver 或 Host memory。生命周期：connect_ep 后可反复 read/write，
// 由调用方保证 driver 在所有异步传输完成前保持有效；本适配器不负责停止 driver。
class virtio_pcie_model_dma_adapter extends uvm_object;
    `uvm_object_utils(virtio_pcie_model_dma_adapter)

    protected pcie_tl_ep_driver m_ep_driver;
    protected bit [15:0]        m_requester;
    protected bit               m_bound;
    protected int unsigned      m_timeout_ns;

    // 接口契约：创建未绑定适配器，requester 清零、超时采用默认值，不发起 TLP。
    function new(string name = "virtio_pcie_model_dma_adapter");
        super.new(name);
        m_ep_driver = null;
        m_requester = '0;
        m_bound = 1'b0;
        m_timeout_ns = 100000;
    endfunction

    // 接口契约：输入 EP driver 和 requester BDF，why 返回失败原因；成功保存借用
    // 句柄并覆盖旧绑定，null driver 时返回 0 且不发送事务。调用方负责 driver 生命周期。
    // "bind" is a SystemVerilog keyword, so keep the public API explicit.
    function bit connect_ep(
        input pcie_tl_ep_driver ep_driver,
        input bit [15:0] requester,
        output string why
    );
        why = "";
        if (ep_driver == null) begin
            why = "MODEL DMA adapter received a null EP driver";
            return 1'b0;
        end
        m_ep_driver = ep_driver;
        m_requester = requester;
        m_bound = 1'b1;
        return 1'b1;
    endfunction

    // 只读查询绑定状态，不改变适配器或 PCIe 环境。
    function bit bound(); return m_bound; endfunction

    // Byte Enable 辅助：根据 DWORD 内首字节和长度生成 first_be；调用者必须保证
    // byte_offset 在 0..3，超出时数组写入不应被请求。
    protected function automatic bit [3:0] first_be(
        input int unsigned size,
        input int unsigned byte_offset
    );
        bit [3:0] be;
        int unsigned count;

        be = '0;
        count = (size < (4 - byte_offset)) ? size : (4 - byte_offset);
        for (int unsigned i = 0; i < count; i++)
            be[byte_offset + i] = 1'b1;
        return be;
    endfunction

    // Byte Enable 辅助：为多 DWORD 传输生成末 DWORD 的 last_be；单 DWORD 返回空
    // mask，由 PCIe 语义使用 first_be。仅计算 mask，不产生副作用。
    protected function automatic bit [3:0] last_be(
        input int unsigned size,
        input int unsigned byte_offset,
        input int unsigned dw_count
    );
        bit [3:0] be;
        int unsigned last_bytes;

        be = '0;
        if (dw_count <= 1)
            return be;
        last_bytes = (byte_offset + size) & 3;
        if (last_bytes == 0)
            return 4'hF;
        for (int unsigned i = 0; i < last_bytes; i++)
            be[i] = 1'b1;
        return be;
    endfunction

    // 传输校验：输出 DWORD 数、首字节偏移和对齐地址。当前约束为 1..4096 字节、
    // 最多 1024 DW、单次请求不得跨 4 KiB 页；失败时返回 0 并将输出清零/对齐值置好。
    protected function bit valid_transfer(
        input bit [63:0] addr,
        input int unsigned size,
        output int unsigned dw_count,
        output int unsigned byte_offset,
        output bit [63:0] aligned_addr
    );
        valid_transfer = 1'b0;
        dw_count = 0;
        byte_offset = addr[1:0];
        aligned_addr = {addr[63:2], 2'b00};
        if ((size == 0) || (size > 4096))
            return 1'b0;
        dw_count = (size + byte_offset + 3) / 4;
        if ((dw_count == 0) || (dw_count > 1024))
            return 1'b0;
        if ((aligned_addr[11:0] + dw_count * 4) > 4096)
            return 1'b0;
        return 1'b1;
    endfunction

    // 接口契约：输入设备可见地址和长度，输出精确字节数组。成功发送一条
    // EP-originated MemRd，等待 bounded Completion 后去除首 DWORD 偏移；未绑定、
    // 非法跨页、超时、非成功 Completion 或 payload 太短时只报 UVM_ERROR 并返回空数组。
    // 不直接访问 Host memory，也不返回协议错误码；TLP/driver 由调用方拥有。
    virtual task read(
        input bit [63:0] addr,
        input int unsigned size,
        output bit [7:0] data[]
    );
        pcie_tl_mem_tlp tlp;
        int unsigned dw_count;
        int unsigned byte_offset;
        bit [63:0] aligned_addr;

        data = new[0];
        if (!m_bound || !valid_transfer(addr, size, dw_count,
                                        byte_offset, aligned_addr)) begin
            `uvm_error("MODEL_DMA", $sformatf(
                "invalid/unbound MODEL DMA read addr=0x%016h size=%0d",
                addr, size))
            return;
        end
        tlp = pcie_tl_mem_tlp::type_id::create("model_dma_read");
        tlp.kind = TLP_MEM_RD;
        tlp.type_f = TLP_TYPE_MEM_RD;
        tlp.addr = aligned_addr;
        tlp.is_64bit = (aligned_addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_NO_DATA : FMT_3DW_NO_DATA;
        tlp.length = (dw_count == 1024) ? 10'd0 : dw_count[9:0];
        tlp.first_be = first_be(size, byte_offset);
        tlp.last_be = last_be(size, byte_offset, dw_count);
        tlp.requester_id = m_requester;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        m_ep_driver.send_tlp(tlp);

        fork : model_dma_read_wait
            begin
                wait (tlp.rb_done);
            end
            begin
                #(m_timeout_ns * 1ns);
            end
        join_any
        disable model_dma_read_wait;

        if (!tlp.rb_done || (tlp.rb_status != CPL_STATUS_SC)) begin
            `uvm_error("MODEL_DMA", $sformatf(
                "MODEL DMA read Completion failed addr=0x%016h size=%0d status=%s",
                addr, size, tlp.rb_status.name()))
            return;
        end
        if (tlp.rb_data.size() < byte_offset + size) begin
            `uvm_error("MODEL_DMA", $sformatf(
                "MODEL DMA read payload too short addr=0x%016h got=%0d expected=%0d",
                addr, tlp.rb_data.size(), byte_offset + size))
            return;
        end
        data = new[size];
        foreach (data[index])
            data[index] = tlp.rb_data[index + byte_offset];
    endtask

    // 接口契约：输入设备可见地址和待写字节，异步/posted 发送一条 EP-originated
    // MemWr 后立即返回，不等待 Completion 且无成功返回值。未绑定或非法传输只报
    // UVM_ERROR 并丢弃；payload 补齐 DWORD，Byte Enable 保证未覆盖字节不被改写。
    virtual task write(
        input bit [63:0] addr,
        input bit [7:0] data[]
    );
        pcie_tl_mem_tlp tlp;
        int unsigned dw_count;
        int unsigned byte_offset;
        bit [63:0] aligned_addr;

        if (!m_bound || !valid_transfer(addr, data.size(), dw_count,
                                        byte_offset, aligned_addr)) begin
            `uvm_error("MODEL_DMA", $sformatf(
                "invalid/unbound MODEL DMA write addr=0x%016h size=%0d",
                addr, data.size()))
            return;
        end
        tlp = pcie_tl_mem_tlp::type_id::create("model_dma_write");
        tlp.kind = TLP_MEM_WR;
        tlp.type_f = TLP_TYPE_MEM_WR;
        tlp.addr = aligned_addr;
        tlp.is_64bit = (aligned_addr[63:32] != 0);
        tlp.fmt = tlp.is_64bit ? FMT_4DW_WITH_DATA : FMT_3DW_WITH_DATA;
        tlp.length = (dw_count == 1024) ? 10'd0 : dw_count[9:0];
        tlp.first_be = first_be(data.size(), byte_offset);
        tlp.last_be = last_be(data.size(), byte_offset, dw_count);
        tlp.payload = new[dw_count * 4];
        foreach (tlp.payload[index])
            tlp.payload[index] = 8'h00;
        foreach (data[index])
            tlp.payload[byte_offset + index] = data[index];
        tlp.requester_id = m_requester;
        tlp.constraint_mode_sel = CONSTRAINT_LEGAL;
        m_ep_driver.send_tlp(tlp);
    endtask
endclass

`endif
