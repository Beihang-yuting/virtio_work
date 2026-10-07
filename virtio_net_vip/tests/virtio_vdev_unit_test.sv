// 目录层次：virtio_net_vip/tests；独立设备模型单元测试（无 PCIe）。测试只经 vdev_loopback_port 的
// 配置/MMIO 前门驱动设备，设备 DMA 经 IOMMU 读写共享 Host memory。D1 覆盖底座：配置空间、能力链、
// 调试 marker、MSI-X 表/PBA/屏蔽语义与 worker DMA；D2/D3/D4/D5 追加标准与私有设备用例。
`ifndef VIRTIO_VDEV_UNIT_TEST_SV
`define VIRTIO_VDEV_UNIT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// 底座测试设备：BAR0+0 为 scratch 寄存器；BAR0+4 写入任意值触发一次服务：
// 从 echo_iova 读 4 字节、加一写回 echo_iova+4，然后发向量 0。
class vdev_unit_echo_device extends vdev_base;
    `uvm_component_utils(vdev_unit_echo_device)

    bit [31:0] scratch;
    bit [63:0] echo_iova;

    function new(string name = "vdev_unit_echo_device", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void init();
        bit [63:0] sizes[3];

        sizes[0] = 64'h1000;
        sizes[1] = 64'h1000;
        sizes[2] = 64'h1_0000;
        init_header(16'h1234, 16'h5678, 24'h020000, 8'h01, sizes);
        add_msix(4, 32'h0, 32'h8000, 4);
        scratch = 0;
    endfunction

    virtual function bit [31:0] region_read(int unsigned bar, bit [31:0] off, int unsigned size);
        return ((bar == 0) && (off == 0)) ? scratch : 32'h0;
    endfunction

    virtual function void region_write(int unsigned bar, bit [31:0] off, int unsigned size,
                                       bit [31:0] data);
        if ((bar == 0) && (off == 0))
            scratch = data;
        if ((bar == 0) && (off == 4))
            schedule(0);
    endfunction

    virtual task service_queue(int unsigned q);
        bit [7:0] d[];
        bit [31:0] v;
        bit ok;

        dma_rd(echo_iova, 4, d, ok);
        if (!ok)
            return;
        v = {d[3], d[2], d[1], d[0]} + 1;
        foreach (d[i])
            d[i] = v[8*i +: 8];
        dma_wr(echo_iova + 4, d, ok);
        raise_irq(0);
    endtask
endclass

class virtio_vdev_unit_test extends uvm_test;
    `uvm_component_utils(virtio_vdev_unit_test)

    localparam bit [15:0] ECHO_BDF  = 16'h0300;
    localparam bit [63:0] ECHO_BAR0 = 64'h0000_0040_0000_0000;
    localparam bit [63:0] ECHO_BAR2 = 64'h0000_0040_0001_0000;
    localparam bit [63:0] ECHO_BAR4 = 64'h0000_0040_0002_0000;

    host_mem_manager      mem;
    virtio_iommu_model    iommu;
    virtio_vq_test_kit    kit;
    vdev_loopback_port    port;
    vdev_unit_echo_device echo;
    vdev_event_log        echo_log;

    function new(string name = "virtio_vdev_unit_test", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void build_phase(uvm_phase phase);
        super.build_phase(phase);
        mem = host_mem_manager::type_id::create("vdev_unit_mem");
        mem.set_host_id(0);
        mem.init_region(64'h0000_0001_0000_0000, 64'h0000_0001_00ff_ffff, MODE_BUDDY);
        iommu = virtio_iommu_model::type_id::create("vdev_unit_iommu");
        kit = virtio_vq_test_kit::create_kit("vdev_unit", mem, iommu, ECHO_BDF);
        port = vdev_loopback_port::type_id::create("vdev_unit_port");
        port.mem = mem;
        port.iommu = iommu;
        port.host_id = 0;
        echo = vdev_unit_echo_device::type_id::create("echo", this);
        echo_log = vdev_event_log::type_id::create("echo_log", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        echo.event_ap.connect(echo_log.analysis_export);
    endfunction

    // 把三对 64 位 BAR 写进设备配置空间（等价平台枚举）。
    protected function void program_bars(bit [15:0] target, bit [63:0] b0, bit [63:0] b2,
                                         bit [63:0] b4);
        bit [63:0] bases[3];

        bases[0] = b0;
        bases[1] = b2;
        bases[2] = b4;
        for (int unsigned i = 0; i < 3; i++) begin
            port.host_cfg_write(target, 12'h010 + 8*i, bases[i][31:0]);
            port.host_cfg_write(target, 12'h014 + 8*i, bases[i][63:32]);
        end
    endfunction

    // 分配并按方向映射一块 Host 内存，返回 IOVA；gpa 输出供测试直接读写字节。
    protected function bit [63:0] map_buffer(bit [15:0] target, int unsigned size, dma_dir_e dir,
                                             output bit [63:0] gpa);
        gpa = mem.alloc(size, 4096);
        if (gpa == '1)
            `uvm_fatal("VDEV_UNIT", "Host memory allocation failed")
        return iommu.map_for_host(0, target, gpa, size, dir);
    endfunction

    // 等设备 worker 处理完。
    protected task settle();
        #1us;
    endtask

    // 配置头、BAR 尺寸探测与能力链：PCIe(0x10) → MSI-X(0x11) → 结束；扩展空间 0x100 为调试 VSEC。
    task test_base_config_space();
        bit [31:0] v;
        bit [7:0] ptr;
        bit [7:0] ids[$];

        if (port.host_cfg_read(ECHO_BDF, 12'h000) != 32'h5678_1234)
            `uvm_fatal("VDEV_UNIT", "vendor/device ID mismatch")
        port.host_cfg_write(ECHO_BDF, 12'h010, 32'hffff_ffff);
        port.host_cfg_write(ECHO_BDF, 12'h014, 32'hffff_ffff);
        if ((port.host_cfg_read(ECHO_BDF, 12'h010) != 32'hffff_f004) ||
            (port.host_cfg_read(ECHO_BDF, 12'h014) != 32'hffff_ffff))
            `uvm_fatal("VDEV_UNIT", "BAR0 sizing readback does not encode a 4 KiB 64-bit BAR")
        program_bars(ECHO_BDF, ECHO_BAR0, ECHO_BAR2, ECHO_BAR4);
        port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0006, 4'h3);
        v = port.host_cfg_read(ECHO_BDF, 12'h004);
        if ((v[15:0] != 16'h0006) || !v[20])
            `uvm_fatal("VDEV_UNIT", $sformatf("command/status readback 0x%08h", v))
        v = port.host_cfg_read(ECHO_BDF, 12'h034);
        ptr = v[7:0];
        while (ptr != 0) begin
            v = port.host_cfg_read(ECHO_BDF, {4'h0, ptr});
            ids.push_back(v[7:0]);
            if ((v[7:0] == 8'h11) &&
                ((v[26:16] != 3) ||
                 (port.host_cfg_read(ECHO_BDF, {4'h0, ptr} + 4) != 32'h0000_0004) ||
                 (port.host_cfg_read(ECHO_BDF, {4'h0, ptr} + 8) != 32'h0000_8004)))
                `uvm_fatal("VDEV_UNIT", "MSI-X capability table size/BIR/offset mismatch")
            ptr = v[15:8];
        end
        if ((ids.size() != 2) || (ids[0] != 8'h10) || (ids[1] != 8'h11))
            `uvm_fatal("VDEV_UNIT", "capability chain is not PCIe -> MSI-X")
        if ((port.host_cfg_read(ECHO_BDF, 12'h100) != 32'h0001_000b) ||
            (port.host_cfg_read(ECHO_BDF, 12'h104) != 32'h00c0_5644))
            `uvm_fatal("VDEV_UNIT", "debug VSEC header mismatch")
        if ((port.host_read(ECHO_BAR0, 4) != 0) || (port.host_read(ECHO_BAR0 - 4, 4) != 32'hffff_ffff))
            `uvm_fatal("VDEV_UNIT", "BAR0 window decode is wrong")
        port.host_write(ECHO_BAR0, 4, 32'hcafe_f00d);
        if (port.host_read(ECHO_BAR0, 4) != 32'hcafe_f00d)
            `uvm_fatal("VDEV_UNIT", "scratch register did not retain the MMIO write")
        `uvm_info("VDEV_UNIT", "test_base_config_space PASSED", UVM_LOW)
    endtask

    // marker 写只产生 marker 事件（不记 reg_wr），值可读回；JSON 形如 vdev_diff.py 输入。
    task test_base_marker();
        vdev_event ev[$];

        echo_log.events.delete();
        port.host_cfg_write(ECHO_BDF, 12'h108, 32'd7);
        echo_log.select(VDEV_MARKER, ev);
        if ((ev.size() != 1) || (ev[0].scenario != 7) || (ev[0].fn != ECHO_BDF) ||
            (ev[0].to_json() != "{\"ev\":\"marker\",\"scenario\":7}") ||
            (port.host_cfg_read(ECHO_BDF, 12'h108) != 32'd7))
            `uvm_fatal("VDEV_UNIT", "marker write did not emit exactly one marker event")
        echo_log.select(VDEV_REG_WR, ev);
        if (ev.size() != 0)
            `uvm_fatal("VDEV_UNIT", "marker write must not be recorded as reg_wr")
        `uvm_info("VDEV_UNIT", "test_base_marker PASSED", UVM_LOW)
    endtask

    // MSI-X：未使能不发；使能但向量屏蔽时挂 PBA；解除屏蔽后补发；worker 的 DMA 经 IOMMU。
    task test_base_msix_and_dma();
        bit [63:0] gpa;
        byte data[];
        byte word[];
        bit [31:0] v;
        vdev_event ev[$];

        echo.echo_iova = map_buffer(ECHO_BDF, 4096, DMA_BIDIRECTIONAL, gpa);
        word = new[4];
        word[0] = 8'h44;
        word[1] = 8'h33;
        word[2] = 8'h22;
        word[3] = 8'h11;
        mem.write_mem(gpa, word);
        // 未使能 MSI-X：DMA 发生、中断不发。
        port.host_write(ECHO_BAR0 + 4, 4, 1);
        settle();
        mem.read_mem(gpa + 4, 4, data);
        if ((data[0] != 8'h45) || (data[3] != 8'h11) || (port.msix_addr.size() != 0) ||
            (echo.dma_read_count() != 1) || (echo.dma_write_count() != 1))
            `uvm_fatal("VDEV_UNIT", "worker DMA or MSI-X disable gating failed")
        // 编程向量 0（复位时 vector control=1 屏蔽），再使能 MSI-X（能力在 0x7c：PCIe 能力 60 字节之后）。
        port.host_write(ECHO_BAR4 + 0, 4, 32'hfee0_0000);
        port.host_write(ECHO_BAR4 + 4, 4, 32'h0);
        port.host_write(ECHO_BAR4 + 8, 4, 32'h0300_0000);
        if (port.host_read(ECHO_BAR4 + 12, 4) != 1)
            `uvm_fatal("VDEV_UNIT", "MSI-X vector control reset value must be masked")
        v = port.host_cfg_read(ECHO_BDF, 12'h07c);
        if (v[7:0] != 8'h11)
            `uvm_fatal("VDEV_UNIT", "MSI-X capability is not at 0x7c")
        port.host_cfg_write(ECHO_BDF, 12'h07c, 32'h8000_0000, 4'hc);
        port.host_write(ECHO_BAR0 + 4, 4, 1);
        settle();
        if ((port.msix_addr.size() != 0) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 1))
            `uvm_fatal("VDEV_UNIT", "masked vector did not set its PBA bit")
        port.host_write(ECHO_BAR4 + 12, 4, 0);
        settle();
        echo_log.select(VDEV_IRQ, ev);
        if ((port.msix_addr.size() != 1) || (port.msix_addr[0] != 64'hfee0_0000) ||
            (port.msix_data[0] != 32'h0300_0000) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 0) ||
            (ev.size() != 1) || (ev[0].vector != 0) || (echo.interrupt_count() != 1))
            `uvm_fatal("VDEV_UNIT", "unmasking a pending vector did not deliver exactly one MSI-X")
        iommu.unmap_for_host(0, ECHO_BDF, echo.echo_iova);
        mem.free(gpa);
        `uvm_info("VDEV_UNIT", "test_base_msix_and_dma PASSED", UVM_LOW)
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        echo.bdf = ECHO_BDF;
        echo.init();
        port.attach(echo);
        test_base_config_space();
        test_base_marker();
        test_base_msix_and_dma();
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("VDEV_UNIT", "virtio_vdev_unit_test PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass
`endif
