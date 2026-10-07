// 目录层次：virtio_net_vip/tests；独立设备模型单元测试（无 PCIe）。测试只经 vdev_loopback_port 的
// 配置/MMIO 前门驱动设备，设备 DMA 经 IOMMU 读写共享 Host memory。D1 覆盖底座：配置空间、能力链、
// 调试 marker、MSI-X 表/PBA/屏蔽语义与 worker DMA；D2/D3/D4/D5 追加标准与私有设备用例。
`ifndef VIRTIO_VDEV_UNIT_TEST_SV
`define VIRTIO_VDEV_UNIT_TEST_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

// 最小 token：只用于核对完成返回的对象身份。
class vdev_unit_token extends uvm_object;
    `uvm_object_utils(vdev_unit_token)
    function new(string name = "vdev_unit_token");
        super.new(name);
    endfunction
endclass

// 底座测试设备：BAR0+0 为 scratch 寄存器；BAR0+4 写入任意值触发一次服务：
// 从 echo_iova 读 4 字节、加一写回 echo_iova+4，然后发向量 0；BAR0+8 写入任意值只发向量 0。
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
        if ((bar == 0) && (off == 8))
            schedule(1);
    endfunction

    virtual task service_queue(int unsigned q);
        bit [7:0] d[];
        bit [31:0] v;
        bit ok;

        if (q == 1) begin
            raise_irq(0);
            return;
        end
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
    localparam bit [15:0] STD_BDF   = 16'h0400;
    localparam bit [63:0] STD_BAR0  = 64'h0000_0041_0000_0000;
    localparam bit [63:0] STD_BAR2  = 64'h0000_0041_0001_0000;
    localparam bit [63:0] STD_BAR4  = 64'h0000_0041_0002_0000;

    host_mem_manager      mem;
    virtio_iommu_model    iommu;
    virtio_vq_test_kit    kit;
    vdev_loopback_port    port;
    vdev_unit_echo_device echo;
    vdev_event_log        echo_log;
    vdev_virtio_pci       std;
    vdev_event_log        std_log;
    virtio_vq_test_kit    std_kit;
    int unsigned          irq_base;   // 本子测试开始时的 interrupt_count

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
        std_kit = virtio_vq_test_kit::create_kit("vdev_std", mem, iommu, STD_BDF);
        std = vdev_virtio_pci::type_id::create("std", this);
        std_log = vdev_event_log::type_id::create("std_log", this);
    endfunction

    virtual function void connect_phase(uvm_phase phase);
        super.connect_phase(phase);
        echo.event_ap.connect(echo_log.analysis_export);
        std.event_ap.connect(std_log.analysis_export);
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

    // 新发一次向量 0 中断（不经 DMA），等 worker 处理。
    protected task fire_irq();
        port.host_write(ECHO_BAR0 + 8, 4, 1);
        settle();
    endtask

    // 断言自 base 以来恰好新投递 n 条 MSI-X（端口记录、irq 事件与计数一致），且 PBA 已清。
    protected function void expect_delivered(int unsigned base, int unsigned n, string what);
        vdev_event ev[$];

        echo_log.select(VDEV_IRQ, ev);
        if ((port.msix_addr.size() != base + n) || (ev.size() != base + n) ||
            (echo.interrupt_count() != irq_base + base + n) ||
            (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 0))
            `uvm_fatal("VDEV_UNIT", $sformatf("%s: expected %0d new MSI-X, port=%0d events=%0d count=%0d",
                                              what, n, port.msix_addr.size() - base, ev.size() - base,
                                              echo.interrupt_count() - irq_base - base))
    endfunction

    // 挂起补发只投递一次：同一挂起向量的多次补发请求（重复解除屏蔽、解除屏蔽后再写
    // Message Control、Function Mask 清除）合计只产生一条 MSI-X。前置：MSI-X 已使能、向量 0 已编程。
    task test_base_msix_replay();
        echo_log.events.delete();
        port.msix_addr.delete();
        port.msix_data.delete();
        irq_base = echo.interrupt_count();
        // (a) 挂起后连续两次写向量控制=0。
        port.host_write(ECHO_BAR4 + 12, 4, 1);
        fire_irq();
        if ((port.msix_addr.size() != 0) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 1))
            `uvm_fatal("VDEV_UNIT", "masked vector did not become pending")
        port.host_write(ECHO_BAR4 + 12, 4, 0);
        port.host_write(ECHO_BAR4 + 12, 4, 0);
        settle();
        expect_delivered(0, 1, "double unmask");
        // (b) 挂起后解除向量屏蔽，再写 Message Control（Enable 保持）。
        port.host_write(ECHO_BAR4 + 12, 4, 1);
        fire_irq();
        port.host_write(ECHO_BAR4 + 12, 4, 0);
        port.host_cfg_write(ECHO_BDF, 12'h07c, 32'h8000_0000, 4'hc);
        settle();
        expect_delivered(1, 1, "unmask then Message Control write");
        // (c) Function Mask 置位时中断挂起，清除 Function Mask 经 flush_pending 补发一次。
        port.host_cfg_write(ECHO_BDF, 12'h07c, 32'hc000_0000, 4'hc);
        fire_irq();
        if ((port.msix_addr.size() != 2) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 1))
            `uvm_fatal("VDEV_UNIT", "function-masked interrupt did not become pending")
        port.host_cfg_write(ECHO_BDF, 12'h07c, 32'h8000_0000, 4'hc);
        settle();
        expect_delivered(2, 1, "function mask clear");
        // 未挂起时的新中断照常投递。
        fire_irq();
        expect_delivered(3, 1, "new interrupt after replays");
        `uvm_info("VDEV_UNIT", "test_base_msix_replay PASSED", UVM_LOW)
    endtask

    // Command 门控：MSE=0 时设备不认领 MMIO；BME=0 时 DMA 失败（不碰内存、报 VDEV_BME 警告）、
    // 中断转挂起，置回 BME 后补发一次；恢复 0x6 后正向路径照常。前置：MSI-X 已使能、向量 0 未屏蔽。
    task test_base_command_gating();
        bit [63:0] gpa;
        byte word[];
        byte data[];
        int unsigned rd0;
        int unsigned wr0;
        vdev_expect_catcher catcher;

        echo_log.events.delete();
        port.msix_addr.delete();
        port.msix_data.delete();
        irq_base = echo.interrupt_count();
        // MSE=0：读返回全 1（未认领），写不落到寄存器。
        port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0004, 4'h3);
        if (port.host_read(ECHO_BAR0, 4) != 32'hffff_ffff)
            `uvm_fatal("VDEV_UNIT", "MMIO claimed while Memory Space Enable is clear")
        port.host_write(ECHO_BAR0, 4, 32'h1111_2222);
        port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0006, 4'h3);
        if (port.host_read(ECHO_BAR0, 4) != 32'hcafe_f00d)
            `uvm_fatal("VDEV_UNIT", "MMIO write reached the device while Memory Space Enable is clear")
        // BME=0：DMA 失败且不访问内存；中断挂起不投递。
        echo.echo_iova = map_buffer(ECHO_BDF, 4096, DMA_BIDIRECTIONAL, gpa);
        word = new[8];
        foreach (word[i])
            word[i] = i;
        mem.write_mem(gpa, word);
        rd0 = echo.dma_read_count();
        wr0 = echo.dma_write_count();
        port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0002, 4'h3);
        catcher = new("vdev_bme_catcher");
        catcher.id = "VDEV_BME";
        catcher.text = "Bus Master Enable";
        uvm_report_cb::add(null, catcher);
        port.host_write(ECHO_BAR0 + 4, 4, 1);
        settle();
        uvm_report_cb::delete(null, catcher);
        mem.read_mem(gpa + 4, 4, data);
        if ((catcher.caught != 1) || (data[0] != 8'h04) || (data[3] != 8'h07) ||
            (echo.dma_read_count() != rd0) || (echo.dma_write_count() != wr0))
            `uvm_fatal("VDEV_UNIT", "DMA was not blocked while Bus Master Enable is clear")
        fire_irq();
        if ((port.msix_addr.size() != 0) || (port.host_read(ECHO_BAR4 + 32'h8000, 4) != 1))
            `uvm_fatal("VDEV_UNIT", "interrupt with Bus Master Enable clear did not become pending")
        // 置回 BME：挂起向量补发一次；随后 DMA 正向路径照常。
        port.host_cfg_write(ECHO_BDF, 12'h004, 32'h0000_0006, 4'h3);
        settle();
        expect_delivered(0, 1, "BME set replay");
        port.host_write(ECHO_BAR0 + 4, 4, 1);
        settle();
        mem.read_mem(gpa + 4, 4, data);
        if ((data[0] != 8'h01) || (data[1] != 8'h01) || (data[2] != 8'h02) || (data[3] != 8'h03) ||
            (echo.dma_read_count() != rd0 + 1) || (echo.dma_write_count() != wr0 + 1))
            `uvm_fatal("VDEV_UNIT", "DMA did not resume after Bus Master Enable was set")
        expect_delivered(0, 2, "DMA completion interrupt");
        iommu.unmap_for_host(0, ECHO_BDF, echo.echo_iova);
        mem.free(gpa);
        `uvm_info("VDEV_UNIT", "test_base_command_gating PASSED", UVM_LOW)
    endtask

    protected function void std_wr(bit [31:0] off, int unsigned size, bit [31:0] data);
        port.host_write(STD_BAR0 + off, size, data);
    endfunction

    protected function bit [31:0] std_rd(bit [31:0] off, int unsigned size);
        return port.host_read(STD_BAR0 + off, size);
    endfunction

    // 沿能力链找第一个 id（vendor cap 再按 cfg_type 区分）；未找到返回 0。
    protected function bit [7:0] find_cap(bit [15:0] target, bit [7:0] id, bit [7:0] cfg_type = 0);
        bit [31:0] v;
        bit [7:0] ptr;

        v = port.host_cfg_read(target, 12'h034);
        ptr = v[7:0];
        while (ptr != 0) begin
            v = port.host_cfg_read(target, {4'h0, ptr});
            if ((v[7:0] == id) && ((id != 8'h09) || (v[31:24] == cfg_type)))
                return ptr;
            ptr = v[15:8];
        end
        return 0;
    endfunction

    // 标准初始化到 FEATURES_OK（不写 DRIVER_OK）；返回读回的 status。
    protected function bit [7:0] std_negotiate(bit [63:0] drv);
        std_wr(32'h14, 1, 0);
        std_wr(32'h14, 1, 8'h03);
        std_wr(32'h08, 4, 0);
        std_wr(32'h0c, 4, drv[31:0]);
        std_wr(32'h08, 4, 1);
        std_wr(32'h0c, 4, drv[63:32]);
        std_wr(32'h14, 1, 8'h0b);
        return std_rd(32'h14, 1);
    endfunction

    // MSI-X：向量 v → 地址 0xFEE0_0000+4v、数据 v，全部解除屏蔽，再使能。
    protected function void std_msix_on();
        bit [7:0] cap;

        for (int unsigned v = 0; v < 6; v++) begin
            port.host_write(STD_BAR4 + 16*v, 4, 32'hfee0_0000 + 4*v);
            port.host_write(STD_BAR4 + 16*v + 4, 4, 0);
            port.host_write(STD_BAR4 + 16*v + 8, 4, v);
            port.host_write(STD_BAR4 + 16*v + 12, 4, 0);
        end
        cap = find_cap(STD_BDF, 8'h11);
        port.host_cfg_write(STD_BDF, {4'h0, cap}, 32'h8000_0000, 4'hc);
    endfunction

    // 把队列 q 的 ring 映射进 IOMMU 并编程（缺 skip_driver 时故意不写 driver 地址）；返回 ring IOVA。
    protected function void std_program_queue(int unsigned q, virtqueue_base vq, bit enable,
                                              bit skip_driver, ref bit [63:0] iovas[$]);
        bit [63:0] gpas[$];
        int unsigned sizes[$];

        vq.get_ring_regions(gpas, sizes);
        iovas.delete();
        foreach (gpas[i])
            iovas.push_back(iommu.map_for_host(0, STD_BDF, gpas[i], sizes[i], DMA_BIDIRECTIONAL));
        std_wr(32'h16, 2, q);
        std_wr(32'h18, 2, vq.queue_size);
        std_wr(32'h1a, 2, q + 1);
        std_wr(32'h20, 4, iovas[0][31:0]);
        std_wr(32'h24, 4, iovas[0][63:32]);
        if (!skip_driver) begin
            std_wr(32'h28, 4, iovas[1][31:0]);
            std_wr(32'h2c, 4, iovas[1][63:32]);
        end
        std_wr(32'h30, 4, iovas[2][31:0]);
        std_wr(32'h34, 4, iovas[2][63:32]);
        if (enable)
            std_wr(32'h1c, 2, 1);
    endfunction

    protected function void std_release(virtqueue_base vq, bit [63:0] iovas[$]);
        foreach (iovas[i])
            iommu.unmap_for_host(0, STD_BDF, iovas[i]);
        vq.free_rings();
    endfunction

    // 一个单 SG 的 buffer：分配、写入 data、按方向映射；返回 SG 列表（地址为 IOVA）。
    protected function void std_buffer(byte unsigned data[$], int unsigned size, dma_dir_e dir,
                                       output bit [63:0] gpa, output bit [63:0] iova,
                                       output virtio_sg_list sg);
        byte raw[];

        gpa = mem.alloc(size, 64);
        raw = new[size];
        foreach (raw[i])
            raw[i] = (i < data.size()) ? data[i] : 8'h00;
        mem.write_mem(gpa, raw);
        iova = iommu.map_for_host(0, STD_BDF, gpa, size, dir);
        sg.entries.delete();
        sg.entries.push_back('{addr: iova, len: size, is_indirect: 0});
    endfunction

    protected task wait_used(virtqueue_base vq, output uvm_object tok, output int unsigned len);
        uvm_object t;
        int unsigned l;

        tok = null;
        len = 0;
        for (int i = 0; i < 200; i++) begin
            if (vq.poll_used(t, l)) begin
                tok = t;
                len = l;
                return;
            end
            #10ns;
        end
        `uvm_fatal("VDEV_UNIT", $sformatf("queue %0d produced no used entry", vq.queue_id))
    endtask

    // 配置空间与特性：四个 virtio cap 的 BAR 角色、DFSELECT 窗口、FEATURES_OK 拒绝与 features 事件。
    task test_std_config_and_features();
        bit [31:0] v;
        bit [7:0] cap;
        vdev_event ev[$];

        std.bdf = STD_BDF;
        std.max_pairs = 2;
        std.device_features = 64'h0000_0001_0000_0000;
        std.device_features[VIRTIO_NET_F_MAC] = 1;
        std.device_features[VIRTIO_NET_F_CTRL_VQ] = 1;
        std.device_features[VIRTIO_NET_F_MQ] = 1;
        std.device_features[VIRTIO_F_RING_PACKED] = 1;
        std.init();
        port.attach(std);
        program_bars(STD_BDF, STD_BAR0, STD_BAR2, STD_BAR4);
        port.host_cfg_write(STD_BDF, 12'h004, 32'h0000_0006, 4'h3);   // MSE + BME
        if (port.host_cfg_read(STD_BDF, 12'h000) != 32'h1041_1af4)
            `uvm_fatal("VDEV_UNIT", "standard device ID mismatch")
        cap = find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_NOTIFY_CFG);
        v = port.host_cfg_read(STD_BDF, {4'h0, cap} + 4);
        if ((cap == 0) || (v[7:0] != 2) ||
            (port.host_cfg_read(STD_BDF, {4'h0, cap} + 16) != 4) ||
            (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_COMMON_CFG) == 0) ||
            (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_ISR_CFG) == 0) ||
            (find_cap(STD_BDF, 8'h09, VIRTIO_PCI_CAP_DEVICE_CFG) == 0))
            `uvm_fatal("VDEV_UNIT", "virtio capabilities or notify BAR/multiplier mismatch")
        if ((std_rd(32'h12, 2) != 5) || (std_rd(32'h2008, 2) != 2))
            `uvm_fatal("VDEV_UNIT", "num_queues/max_virtqueue_pairs mismatch")
        std_wr(32'h00, 4, 0);
        v = std_rd(32'h04, 4);
        std_wr(32'h00, 4, 1);
        if ((v != std.device_features[31:0]) || (std_rd(32'h04, 4) != std.device_features[63:32]))
            `uvm_fatal("VDEV_UNIT", "DFSELECT window did not select the feature word")
        std_log.events.delete();
        v = std_negotiate(64'h0000_0001_0000_0001);     // 设备未提供 CSUM
        std_log.select(VDEV_FEATURES, ev);
        if ((v & DEV_STATUS_FEATURES_OK) || (ev.size() != 1) ||
            (ev[0].drv_accepted != 64'h0000_0001_0000_0001))
            `uvm_fatal("VDEV_UNIT", "device accepted a feature it never offered")
        v = std_negotiate(std.device_features & ~(64'h1 << VIRTIO_F_RING_PACKED));
        if (!(v & DEV_STATUS_FEATURES_OK))
            `uvm_fatal("VDEV_UNIT", "device rejected a valid feature subset")
        std_log.select(VDEV_STATUS, ev);
        if ((ev.size() == 0) || (ev[ev.size() - 1].to_status != 8'h0b))
            `uvm_fatal("VDEV_UNIT", "status transition event missing")
        `uvm_info("VDEV_UNIT", "test_std_config_and_features PASSED", UVM_LOW)
    endtask

    // 规范 Review Focus 2：缺写 queue_driver 时 enable 被拒，补写后 enable 成功并发 queue_cfg。
    task test_std_enable_requires_all_addresses();
        split_virtqueue vq;
        bit [63:0] iovas[$];
        vdev_event ev[$];
        vdev_expect_catcher catcher;

        vq = std_kit.make_split("enable_rx", 0, 8, STD_BDF);
        std_log.events.delete();
        catcher = new("enable_catcher");
        catcher.id = "VDEV_QUEUE";
        catcher.text = "queue_driver not written";
        uvm_report_cb::add(null, catcher);
        std_program_queue(0, vq, 1, 1, iovas);
        uvm_report_cb::delete(null, catcher);
        std_log.select(VDEV_QUEUE_CFG, ev);
        if ((catcher.caught != 1) || (std_rd(32'h1c, 2) != 0) || (ev.size() != 0))
            `uvm_fatal("VDEV_UNIT", "enable without queue_driver was not rejected")
        std_wr(32'h28, 4, iovas[1][31:0]);
        std_wr(32'h2c, 4, iovas[1][63:32]);
        std_wr(32'h1c, 2, 1);
        std_log.select(VDEV_QUEUE_CFG, ev);
        if ((std_rd(32'h1c, 2) != 1) || (ev.size() != 1) || (ev[0].q != 0) || (ev[0].size != 8) ||
            (ev[0].vector != 1) || (ev[0].ring_fmt != "split"))
            `uvm_fatal("VDEV_UNIT", "complete queue programming did not enable the queue")
        std_wr(32'h1c, 2, 0);
        std_release(vq, iovas);
        `uvm_info("VDEV_UNIT", "test_std_enable_requires_all_addresses PASSED", UVM_LOW)
    endtask

    // split：TX 帧（含 12B header）回环到 RX；校验 RX buffer 字节、事件与 MSI-X。
    task test_std_split_tx_loopback_rx();
        split_virtqueue rxq, txq;
        bit [63:0] rx_iovas[$], tx_iovas[$];
        bit [63:0] rx_gpa, rx_iova, tx_gpa, tx_iova;
        virtio_sg_list sgs[];
        byte unsigned tx_bytes[$];
        byte unsigned none[$];
        byte got[];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token rx_tok, tx_tok;
        vdev_event ev[$];

        void'(std_negotiate(64'h0000_0001_0000_0000));
        rxq = std_kit.make_split("split_rx", 0, 8, STD_BDF);
        txq = std_kit.make_split("split_tx", 1, 8, STD_BDF);
        std_program_queue(0, rxq, 1, 0, rx_iovas);
        std_program_queue(1, txq, 1, 0, tx_iovas);
        std_msix_on();
        std_wr(32'h14, 1, 8'h0f);
        tx_bytes = '{8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00, 8'h00,
                     8'hde, 8'had, 8'hbe, 8'hef, 8'h01, 8'h02, 8'h03, 8'h04};
        sgs = new[1];
        std_buffer(none, 64, DMA_FROM_DEVICE, rx_gpa, rx_iova, sgs[0]);
        rx_tok = new("rx_tok");
        void'(rxq.add_buf(sgs, 0, 1, rx_tok, 0));
        port.host_write(STD_BAR2 + 0, 2, 0);
        std_buffer(tx_bytes, tx_bytes.size(), DMA_TO_DEVICE, tx_gpa, tx_iova, sgs[0]);
        tx_tok = new("tx_tok");
        std_log.events.delete();
        void'(txq.add_buf(sgs, 1, 0, tx_tok, 0));
        port.host_write(STD_BAR2 + 4, 2, 1);
        wait_used(txq, tok, len);
        if ((tok != tx_tok) || (len != 0))
            `uvm_fatal("VDEV_UNIT", "TX used entry token/len mismatch")
        wait_used(rxq, tok, len);
        mem.read_mem(rx_gpa, 20, got);
        if ((tok != rx_tok) || (len != 20) || (got[10] != 8'h01) || (got[12] != 8'hde) ||
            (got[19] != 8'h04))
            `uvm_fatal("VDEV_UNIT", "RX buffer does not hold header(num_buffers=1)+looped frame")
        std_log.select(VDEV_PKT, ev);
        if ((ev.size() != 2) || (ev[0].dir != "tx") || (ev[1].dir != "rx") ||
            (ev[0].bytes != ev[1].bytes) || (ev[0].bytes.size() != 8))
            `uvm_fatal("VDEV_UNIT", "pkt events do not show the same 8-byte frame on TX and RX")
        std_log.select(VDEV_IRQ, ev);
        if ((ev.size() != 2) || (port.msix_data[port.msix_data.size() - 1] != 1))
            `uvm_fatal("VDEV_UNIT", "queue completions did not raise their MSI-X vectors")
        iommu.unmap_for_host(0, STD_BDF, rx_iova);
        iommu.unmap_for_host(0, STD_BDF, tx_iova);
        mem.free(rx_gpa);
        mem.free(tx_gpa);
        std_wr(32'h14, 1, 0);
        std_release(rxq, rx_iovas);
        std_release(txq, tx_iovas);
        `uvm_info("VDEV_UNIT", "test_std_split_tx_loopback_rx PASSED", UVM_LOW)
    endtask

    // packed：TX 完成写回 head 槽的 id/len/flags（AVAIL=USED=wrap），驱动 poll_used 认领。
    task test_std_packed_tx();
        packed_virtqueue txq;
        bit [63:0] iovas[$];
        bit [63:0] gpa, iova;
        virtio_sg_list sgs[];
        byte unsigned bytes[$];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token t;
        vdev_event ev[$];

        void'(std_negotiate(64'h0000_0001_0000_0000 | (64'h1 << VIRTIO_F_RING_PACKED)));
        txq = std_kit.make_packed("packed_tx", 1, 8, STD_BDF);
        std_program_queue(1, txq, 1, 0, iovas);
        std_wr(32'h14, 1, 8'h0f);
        for (int i = 0; i < 16; i++)
            bytes.push_back(i);
        sgs = new[1];
        std_buffer(bytes, 16, DMA_TO_DEVICE, gpa, iova, sgs[0]);
        t = new("packed_tok");
        std_log.events.delete();
        void'(txq.add_buf(sgs, 1, 0, t, 0));
        port.host_write(STD_BAR2 + 4, 2, 1);
        wait_used(txq, tok, len);
        std_log.select(VDEV_QUEUE_CFG, ev);
        if (ev.size() != 0)
            `uvm_fatal("VDEV_UNIT", "packed TX datapath produced queue_cfg events")
        if (tok != t)
            `uvm_fatal("VDEV_UNIT", "packed used descriptor returned the wrong token")
        std_log.select(VDEV_PKT, ev);
        if ((ev.size() != 1) || (ev[0].bytes.size() != 4))
            `uvm_fatal("VDEV_UNIT", "packed TX frame (16B minus 12B header) not observed")
        iommu.unmap_for_host(0, STD_BDF, iova);
        mem.free(gpa);
        std_wr(32'h14, 1, 0);
        std_release(txq, iovas);
        `uvm_info("VDEV_UNIT", "test_std_packed_tx PASSED", UVM_LOW)
    endtask

    // ctrl VQ：MQ VQ_PAIRS_SET 2 → ACK_OK；5（超过 max_pairs）→ ACK_ERR；ctrl 事件记录 class/cmd/data/ack。
    task test_std_ctrl_mq();
        split_virtqueue cq, txq;
        bit [63:0] iovas[$], tx_iovas[$];
        vdev_expect_catcher catcher;
        bit [63:0] hdr_gpa, hdr_iova, data_gpa, data_iova, ack_gpa, ack_iova;
        virtio_sg_list sgs[];
        byte unsigned hdr_b[$], data_b[$], none[$];
        byte got[];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token t;
        vdev_event ev[$];
        bit [63:0] drv;

        drv = 64'h0000_0001_0000_0000;
        drv[VIRTIO_NET_F_CTRL_VQ] = 1;
        drv[VIRTIO_NET_F_MQ] = 1;
        void'(std_negotiate(drv));
        cq = std_kit.make_split("ctrl_q", 4, 8, STD_BDF);
        std_program_queue(4, cq, 1, 0, iovas);
        txq = std_kit.make_split("pair1_tx", 3, 8, STD_BDF);
        std_program_queue(3, txq, 1, 0, tx_iovas);
        std_wr(32'h14, 1, 8'h0f);
        // virtio 1.2 §5.1.6.5.5：VQ_PAIRS_SET 之前只有第 0 对可用，队列 3 的通知被忽略并告警。
        catcher = new("pair1_catcher");
        catcher.id = "VDEV_QUEUE";
        catcher.text = "beyond the active queue pairs";
        uvm_report_cb::add(null, catcher);
        port.host_write(STD_BAR2 + 12, 2, 3);
        if (catcher.caught != 1)
            `uvm_fatal("VDEV_UNIT", "notify on pair 1 before VQ_PAIRS_SET was not rejected")
        std_log.events.delete();
        for (int round = 0; round < 2; round++) begin
            hdr_b = '{VIRTIO_NET_CTRL_MQ, VIRTIO_NET_CTRL_MQ_VQ_PAIRS_SET};
            data_b = '{(round == 0) ? 8'd2 : 8'd5, 8'd0};
            sgs = new[3];
            std_buffer(hdr_b, 2, DMA_TO_DEVICE, hdr_gpa, hdr_iova, sgs[0]);
            std_buffer(data_b, 2, DMA_TO_DEVICE, data_gpa, data_iova, sgs[1]);
            std_buffer(none, 1, DMA_FROM_DEVICE, ack_gpa, ack_iova, sgs[2]);
            t = new("ctrl_tok");
            void'(cq.add_buf(sgs, 2, 1, t, 0));
            port.host_write(STD_BAR2 + 16, 2, 4);
            wait_used(cq, tok, len);
            mem.read_mem(ack_gpa, 1, got);
            if ((tok != t) || (len != 1) || (got[0] != ((round == 0) ? 0 : 1)))
                `uvm_fatal("VDEV_UNIT", $sformatf("MQ VQ_PAIRS_SET round %0d ack=%0d", round, got[0]))
            iommu.unmap_for_host(0, STD_BDF, hdr_iova);
            iommu.unmap_for_host(0, STD_BDF, data_iova);
            iommu.unmap_for_host(0, STD_BDF, ack_iova);
            mem.free(hdr_gpa);
            mem.free(data_gpa);
            mem.free(ack_gpa);
        end
        // VQ_PAIRS_SET=2 已生效（第二次 5 被拒、不改变当前对数）：队列 3 的通知不再告警。
        port.host_write(STD_BAR2 + 12, 2, 3);
        settle();
        uvm_report_cb::delete(null, catcher);
        if (catcher.caught != 1)
            `uvm_fatal("VDEV_UNIT", "notify on pair 1 was rejected after VQ_PAIRS_SET=2")
        std_log.select(VDEV_CTRL, ev);
        if ((ev.size() != 2) || (ev[0].ctrl_class != VIRTIO_NET_CTRL_MQ) || (ev[0].ack != 0) ||
            (ev[0].ctrl_data.size() != 2) || (ev[0].ctrl_data[0] != 2) || (ev[1].ack != 1))
            `uvm_fatal("VDEV_UNIT", "ctrl events do not record the MQ command sequence")
        std_wr(32'h14, 1, 0);
        std_release(cq, iovas);
        std_release(txq, tx_iovas);
        `uvm_info("VDEV_UNIT", "test_std_ctrl_mq PASSED", UVM_LOW)
    endtask

    // 设备侧故障点：PRE_DEVICE_READ 把 TX 首描述符长度置零 → 设备拒绝链、置 DEVICE_NEEDS_RESET
    // 并发配置中断；随后写 status=0 复位，status 与 queue_enable 读回 0。
    task test_std_device_fault_and_reset();
        split_virtqueue txq;
        bit [63:0] iovas[$];
        bit [63:0] gpa, iova;
        virtio_sg_list sgs[];
        byte unsigned bytes[$];
        vdev_unit_token t;
        vdev_expect_catcher catcher;
        int unsigned irq_before;

        void'(std_negotiate(64'h0000_0001_0000_0000));
        txq = std_kit.make_split("fault_tx", 1, 8, STD_BDF);
        std_program_queue(1, txq, 1, 0, iovas);
        std_wr(32'h10, 2, 0);                       // config 向量 0
        std_wr(32'h14, 1, 8'h0f);
        std.err_inj = std_kit.err_inj;
        std_kit.err_inj.configure(VQ_ERR_ZERO_LEN_BUF, 0, 1, 100, VQ_FAULT_PRE_DEVICE_READ);
        for (int i = 0; i < 32; i++)
            bytes.push_back(i);
        sgs = new[1];
        std_buffer(bytes, 32, DMA_TO_DEVICE, gpa, iova, sgs[0]);
        t = new("fault_tok");
        irq_before = port.msix_addr.size();
        catcher = new("fault_catcher");
        catcher.id = "VDEV_RING";
        catcher.text = "zero length";
        uvm_report_cb::add(null, catcher);
        void'(txq.add_buf(sgs, 1, 0, t, 0));
        port.host_write(STD_BAR2 + 4, 2, 1);
        settle();
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught != 1) || !(std_rd(32'h14, 1) & DEV_STATUS_DEVICE_NEEDS_RESET) ||
            (port.msix_addr.size() != irq_before + 1) || (port.msix_data[irq_before] != 0) ||
            (std_kit.err_inj.injection_count() != 1))
            `uvm_fatal("VDEV_UNIT", "device-side zero-length fault was not reported as DEVICE_NEEDS_RESET")
        std_kit.err_inj.disable_injection();
        std.err_inj = null;
        std_wr(32'h14, 1, 0);
        std_wr(32'h16, 2, 1);
        if ((std_rd(32'h14, 1) != 0) || (std_rd(32'h1c, 2) != 0))
            `uvm_fatal("VDEV_UNIT", "device reset did not clear status/queue_enable")
        iommu.unmap_for_host(0, STD_BDF, iova);
        mem.free(gpa);
        std_release(txq, iovas);
        `uvm_info("VDEV_UNIT", "test_std_device_fault_and_reset PASSED", UVM_LOW)
    endtask

    // EVENT_IDX：环取空后设备发布 avail_event=last_avail（驱动据此决定是否 kick）；
    // RING_RESET：queue_reset 后读回 1、queue_enable 读回 0，须重写三个地址再使能，使能后读回 0。
    task test_std_event_idx_and_queue_reset();
        split_virtqueue txq;
        bit [63:0] iovas[$];
        bit [63:0] gpa, iova;
        virtio_sg_list sgs[];
        byte unsigned bytes[$];
        byte got[];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token t;
        bit [63:0] saved;
        bit [63:0] drv;
        vdev_expect_catcher catcher;

        saved = std.device_features;
        std.device_features[VIRTIO_F_RING_EVENT_IDX] = 1;
        std.device_features[VIRTIO_F_RING_RESET] = 1;
        drv = 64'h0000_0001_0000_0000;
        drv[VIRTIO_F_RING_EVENT_IDX] = 1;
        drv[VIRTIO_F_RING_RESET] = 1;
        if (!(std_negotiate(drv) & DEV_STATUS_FEATURES_OK))
            `uvm_fatal("VDEV_UNIT", "EVENT_IDX/RING_RESET negotiation rejected")
        txq = std_kit.make_split("evidx_tx", 1, 8, STD_BDF);
        std_program_queue(1, txq, 1, 0, iovas);
        std_wr(32'h14, 1, 8'h0f);
        for (int i = 0; i < 16; i++)
            bytes.push_back(i);
        sgs = new[1];
        std_buffer(bytes, 16, DMA_TO_DEVICE, gpa, iova, sgs[0]);
        t = new("evidx_tok");
        void'(txq.add_buf(sgs, 1, 0, t, 0));
        port.host_write(STD_BAR2 + 4, 2, 1);
        wait_used(txq, tok, len);
        settle();
        mem.read_mem(txq.device_ring_addr + 4 + 8 * 8, 2, got);
        if ((tok != t) || (got[0] != 1) || (got[1] != 0))
            `uvm_fatal("VDEV_UNIT", "device did not publish avail_event after draining the ring")
        std_wr(32'h16, 2, 1);
        std_wr(32'h3a, 2, 1);
        if ((std_rd(32'h3a, 2) != 1) || (std_rd(32'h1c, 2) != 0))
            `uvm_fatal("VDEV_UNIT", "queue_reset did not read back 1 with queue_enable 0")
        catcher = new("reset_catcher");
        catcher.id = "VDEV_QUEUE";
        catcher.text = "queue_desc not written";
        uvm_report_cb::add(null, catcher);
        std_wr(32'h1c, 2, 1);
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught != 1) || (std_rd(32'h1c, 2) != 0))
            `uvm_fatal("VDEV_UNIT", "queue re-enabled after queue_reset without reprogrammed addresses")
        std_release(txq, iovas);
        txq = std_kit.make_split("evidx_tx2", 1, 8, STD_BDF);
        std_program_queue(1, txq, 1, 0, iovas);
        if ((std_rd(32'h1c, 2) != 1) || (std_rd(32'h3a, 2) != 0))
            `uvm_fatal("VDEV_UNIT", "queue re-enable after queue_reset did not clear queue_reset")
        iommu.unmap_for_host(0, STD_BDF, iova);
        mem.free(gpa);
        std_wr(32'h14, 1, 0);
        std_release(txq, iovas);
        std.device_features = saved;
        `uvm_info("VDEV_UNIT", "test_std_event_idx_and_queue_reset PASSED", UVM_LOW)
    endtask

    // virtio 1.2 §5.1.2：未协商 MQ 时 N=1，ctrl VQ 为队列 2（不是 2*max_pairs）；
    // 超出已协商队列集合的队列 queue_size 读 0。CTRL_RX PROMISC 应答 OK 且不置 NEEDS_RESET。
    task test_std_ctrl_without_mq();
        split_virtqueue cq;
        bit [63:0] iovas[$];
        bit [63:0] hdr_gpa, hdr_iova, data_gpa, data_iova, ack_gpa, ack_iova;
        virtio_sg_list sgs[];
        byte unsigned hdr_b[$], data_b[$], none[$];
        byte got[];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token t;
        vdev_event ev[$];
        bit [63:0] saved;
        bit [63:0] drv;

        saved = std.device_features;
        std.device_features[VIRTIO_NET_F_CTRL_RX] = 1;
        drv = 64'h0000_0001_0000_0000;
        drv[VIRTIO_NET_F_CTRL_VQ] = 1;
        drv[VIRTIO_NET_F_CTRL_RX] = 1;
        if (!(std_negotiate(drv) & DEV_STATUS_FEATURES_OK))
            `uvm_fatal("VDEV_UNIT", "CTRL_VQ without MQ negotiation rejected")
        std_wr(32'h16, 2, 3);
        if (std_rd(32'h18, 2) != 0)
            `uvm_fatal("VDEV_UNIT", "queue 3 outside the negotiated set (no MQ) reports a non-zero queue_size")
        cq = std_kit.make_split("ctrl_nomq", 2, 8, STD_BDF);
        std_program_queue(2, cq, 1, 0, iovas);
        std_wr(32'h14, 1, 8'h0f);
        std_log.events.delete();
        hdr_b = '{VIRTIO_NET_CTRL_RX, 8'd0};
        data_b = '{8'd1};
        sgs = new[3];
        std_buffer(hdr_b, 2, DMA_TO_DEVICE, hdr_gpa, hdr_iova, sgs[0]);
        std_buffer(data_b, 1, DMA_TO_DEVICE, data_gpa, data_iova, sgs[1]);
        std_buffer(none, 1, DMA_FROM_DEVICE, ack_gpa, ack_iova, sgs[2]);
        got = new[1];
        got[0] = 8'hff;
        mem.write_mem(ack_gpa, got);
        t = new("ctrl_nomq_tok");
        void'(cq.add_buf(sgs, 2, 1, t, 0));
        port.host_write(STD_BAR2 + 8, 2, 2);
        wait_used(cq, tok, len);
        mem.read_mem(ack_gpa, 1, got);
        std_log.select(VDEV_CTRL, ev);
        if ((tok != t) || (len != 1) || (got[0] != 0) || (ev.size() != 1) ||
            (ev[0].ctrl_class != VIRTIO_NET_CTRL_RX) || (std_rd(32'h14, 1) & DEV_STATUS_DEVICE_NEEDS_RESET))
            `uvm_fatal("VDEV_UNIT", "ctrl VQ at index 2 (MQ not negotiated) was not served as the control queue")
        iommu.unmap_for_host(0, STD_BDF, hdr_iova);
        iommu.unmap_for_host(0, STD_BDF, data_iova);
        iommu.unmap_for_host(0, STD_BDF, ack_iova);
        mem.free(hdr_gpa);
        mem.free(data_gpa);
        mem.free(ack_gpa);
        std_wr(32'h14, 1, 0);
        std_release(cq, iovas);
        std.device_features = saved;
        `uvm_info("VDEV_UNIT", "test_std_ctrl_without_mq PASSED", UVM_LOW)
    endtask

    // split INDIRECT：合法间接表（header SG + 帧 SG）展开成两段链并回环出原帧；
    // 间接表内 next 越界 → 设备判链非法、置 DEVICE_NEEDS_RESET。
    task test_std_split_indirect();
        split_virtqueue txq;
        bit [63:0] iovas[$];
        bit [63:0] h_gpa, h_iova, f_gpa, f_iova, tbl_gpa;
        virtio_sg_list sgs[];
        byte unsigned hdr_b[$], frame_b[$];
        byte raw[];
        uvm_object tok;
        int unsigned len;
        int unsigned head;
        vdev_unit_token t;
        vdev_event ev[$];
        vdev_expect_catcher catcher;
        iommu_fault_e fault;
        bit [63:0] tbl_iova;
        bit [63:0] saved;
        bit [63:0] drv;

        saved = std.device_features;
        std.device_features[VIRTIO_F_RING_INDIRECT_DESC] = 1;
        drv = 64'h0000_0001_0000_0000;
        drv[VIRTIO_F_RING_INDIRECT_DESC] = 1;
        if (!(std_negotiate(drv) & DEV_STATUS_FEATURES_OK))
            `uvm_fatal("VDEV_UNIT", "INDIRECT_DESC negotiation rejected")
        txq = std_kit.make_split("ind_tx", 1, 8, STD_BDF);
        std_program_queue(1, txq, 1, 0, iovas);
        std_wr(32'h14, 1, 8'h0f);
        for (int i = 0; i < 12; i++)
            hdr_b.push_back(0);
        frame_b = '{8'hca, 8'hfe, 8'hba, 8'hbe, 8'h55, 8'haa};
        sgs = new[2];
        std_buffer(hdr_b, 12, DMA_TO_DEVICE, h_gpa, h_iova, sgs[0]);
        std_buffer(frame_b, 6, DMA_TO_DEVICE, f_gpa, f_iova, sgs[1]);
        t = new("ind_tok");
        std_log.events.delete();
        void'(txq.add_buf(sgs, 2, 0, t, 1));
        port.host_write(STD_BAR2 + 4, 2, 1);
        wait_used(txq, tok, len);
        std_log.select(VDEV_DESC_CHAIN, ev);
        if ((tok != t) || (ev.size() != 1) || (ev[0].seg_len.size() != 2) || (ev[0].seg_len[1] != 6))
            `uvm_fatal("VDEV_UNIT", "split indirect table was not expanded into its two segments")
        std_log.select(VDEV_PKT, ev);
        if ((ev.size() != 1) || (ev[0].bytes.size() != 6) || (ev[0].bytes[0] != 8'hca) || (ev[0].bytes[5] != 8'haa))
            `uvm_fatal("VDEV_UNIT", "split indirect TX frame bytes mismatch")
        // 第二条：发布后、通知前把间接表第 0 项的 next 改成 5（表只有 2 项）。
        head = txq.add_buf(sgs, 2, 0, t, 1);
        mem.read_mem(txq.desc_table_addr + 16 * head, 8, raw);
        foreach (raw[i])
            tbl_iova[8*i +: 8] = raw[i];
        if (!iommu.translate_for_host(0, STD_BDF, tbl_iova, 32, DMA_TO_DEVICE, tbl_gpa, fault))
            `uvm_fatal("VDEV_UNIT", "indirect table IOVA does not translate")
        raw = new[2];
        raw[0] = 8'h05;
        raw[1] = 8'h00;
        mem.write_mem(tbl_gpa + 14, raw);
        catcher = new("ind_catcher");
        catcher.id = "VDEV_RING";
        catcher.text = "malformed descriptor chain";
        uvm_report_cb::add(null, catcher);
        port.host_write(STD_BAR2 + 4, 2, 1);
        settle();
        uvm_report_cb::delete(null, catcher);
        if ((catcher.caught != 1) || !(std_rd(32'h14, 1) & DEV_STATUS_DEVICE_NEEDS_RESET))
            `uvm_fatal("VDEV_UNIT", "out-of-range next inside an indirect table did not raise DEVICE_NEEDS_RESET")
        iommu.unmap_for_host(0, STD_BDF, h_iova);
        iommu.unmap_for_host(0, STD_BDF, f_iova);
        mem.free(h_gpa);
        mem.free(f_gpa);
        std_wr(32'h14, 1, 0);
        std_release(txq, iovas);
        std.device_features = saved;
        `uvm_info("VDEV_UNIT", "test_std_split_indirect PASSED", UVM_LOW)
    endtask

    // VIP 缺陷：packed 环的间接表必须按 pvirtq_desc 布局（addr、len、id、flags；顺序排列、
    // 不置 NEXT，virtio 1.1 §2.8.19）。TX 与 RX 都用两段间接链经设备回环：设备看到的 TX 段
    // flags 全 0，RX 段全为 WRITE，回环帧原样落进 RX 第二段。
    task test_std_packed_indirect_loopback();
        packed_virtqueue rxq, txq;
        bit [63:0] rx_iovas[$], tx_iovas[$];
        bit [63:0] h_gpa, h_iova, f_gpa, f_iova, rh_gpa, rh_iova, rf_gpa, rf_iova;
        virtio_sg_list sgs[];
        byte unsigned hdr_b[$], frame_b[$], none[$];
        byte got[];
        uvm_object tok;
        int unsigned len;
        vdev_unit_token rx_tok, tx_tok;
        vdev_event ev[$];
        bit [63:0] saved;
        bit [63:0] drv;

        saved = std.device_features;
        std.device_features[VIRTIO_F_RING_INDIRECT_DESC] = 1;
        drv = 64'h0000_0001_0000_0000;
        drv[VIRTIO_F_RING_PACKED] = 1;
        drv[VIRTIO_F_RING_INDIRECT_DESC] = 1;
        if (!(std_negotiate(drv) & DEV_STATUS_FEATURES_OK))
            `uvm_fatal("VDEV_UNIT", "packed INDIRECT_DESC negotiation rejected")
        rxq = std_kit.make_packed("pind_rx", 0, 8, STD_BDF);
        txq = std_kit.make_packed("pind_tx", 1, 8, STD_BDF);
        std_program_queue(0, rxq, 1, 0, rx_iovas);
        std_program_queue(1, txq, 1, 0, tx_iovas);
        std_wr(32'h14, 1, 8'h0f);
        for (int i = 0; i < 12; i++)
            hdr_b.push_back(0);
        frame_b = '{8'h5a, 8'h11, 8'h22, 8'h33, 8'h44, 8'ha5};
        sgs = new[2];
        std_buffer(none, 12, DMA_FROM_DEVICE, rh_gpa, rh_iova, sgs[0]);
        std_buffer(none, 64, DMA_FROM_DEVICE, rf_gpa, rf_iova, sgs[1]);
        rx_tok = new("pind_rx_tok");
        void'(rxq.add_buf(sgs, 0, 2, rx_tok, 1));
        port.host_write(STD_BAR2 + 0, 2, 0);
        std_buffer(hdr_b, 12, DMA_TO_DEVICE, h_gpa, h_iova, sgs[0]);
        std_buffer(frame_b, 6, DMA_TO_DEVICE, f_gpa, f_iova, sgs[1]);
        tx_tok = new("pind_tx_tok");
        std_log.events.delete();
        void'(txq.add_buf(sgs, 2, 0, tx_tok, 1));
        port.host_write(STD_BAR2 + 4, 2, 1);
        wait_used(txq, tok, len);
        if (tok != tx_tok)
            `uvm_fatal("VDEV_UNIT", "packed indirect TX returned the wrong token")
        wait_used(rxq, tok, len);
        if ((tok != rx_tok) || (len != 18))
            `uvm_fatal("VDEV_UNIT", $sformatf("packed indirect RX token/len mismatch (len=%0d)", len))
        std_log.select(VDEV_DESC_CHAIN, ev);
        if ((ev.size() != 2) || (ev[0].seg_flags.size() != 2) || (ev[0].seg_flags[0] != 0) ||
            (ev[0].seg_flags[1] != 0) || (ev[1].seg_flags.size() != 2) ||
            (ev[1].seg_flags[0] != VIRTQ_DESC_F_WRITE) || (ev[1].seg_flags[1] != VIRTQ_DESC_F_WRITE))
            `uvm_fatal("VDEV_UNIT", "packed indirect tables were not read as pvirtq_desc entries")
        mem.read_mem(rf_gpa, 6, got);
        foreach (frame_b[i])
            if (got[i] != frame_b[i])
                `uvm_fatal("VDEV_UNIT", "packed indirect looped frame is not intact in the RX buffer")
        std_log.select(VDEV_PKT, ev);
        if ((ev.size() != 2) || (ev[0].bytes != ev[1].bytes) || (ev[0].bytes.size() != 6))
            `uvm_fatal("VDEV_UNIT", "pkt events do not show the same 6-byte frame on TX and RX")
        iommu.unmap_for_host(0, STD_BDF, h_iova);
        iommu.unmap_for_host(0, STD_BDF, f_iova);
        iommu.unmap_for_host(0, STD_BDF, rh_iova);
        iommu.unmap_for_host(0, STD_BDF, rf_iova);
        mem.free(h_gpa);
        mem.free(f_gpa);
        mem.free(rh_gpa);
        mem.free(rf_gpa);
        std_wr(32'h14, 1, 0);
        std_release(rxq, rx_iovas);
        std_release(txq, tx_iovas);
        std.device_features = saved;
        `uvm_info("VDEV_UNIT", "test_std_packed_indirect_loopback PASSED", UVM_LOW)
    endtask

    // 独立设备暴露的 VIP 缺陷：common-config 后端 set_msix 必须在设备上打开 MSI-X（Enable=1、
    // Function Mask=0）并清掉所用向量的 Vector Control；clear_msix 屏蔽向量并清 Enable（同
    // pci_disable_msix）。Message Control 与 Vector Control 都按读改写更新，保留其余位。
    task test_vip_msix_enables_device();
        virtio_pci_transport t;
        vdev_loopback_bar_accessor acc;
        virtio_common_cfg_backend be;
        int unsigned qids[$];
        bit [31:0] v;
        bit [7:0] cap;
        bit ok;
        vdev_event ev[$];
        bit [31:0] mc_writes[$];

        t = virtio_pci_transport::type_id::create("vip_msix_transport");
        t.configure_pcie_identity(virtio_vq_test_kit::host0_pcie_id(STD_BDF));
        acc = vdev_loopback_bar_accessor::type_id::create("vip_msix_bar");
        acc.port = port;
        acc.target_bdf = STD_BDF;
        acc.bar_base[0] = STD_BAR0;
        acc.bar_base[2] = STD_BAR2;
        acc.bar_base[4] = STD_BAR4;
        t.bar = acc;
        t.cap_mgr.bar_ref = acc;
        t.notify_mgr.bar = acc;
        t.cap_mgr.discover_capabilities();
        cap = find_cap(STD_BDF, 8'h11);
        // 关闭使能、置 Function Mask；向量全部屏蔽，Vector Control 另带保留位 bit8。
        port.host_cfg_write(STD_BDF, {4'h0, cap}, 32'h4000_0000, 4'hc);
        for (int unsigned i = 0; i < 6; i++)
            port.host_write(STD_BAR4 + 16*i + 12, 4, 32'h0000_0101);
        std_log.events.delete();
        be = virtio_common_cfg_backend::type_id::create("vip_msix_backend");
        be.bind_transport(t);
        qids.push_back(0);
        qids.push_back(1);
        be.set_msix(qids, ok);
        v = port.host_cfg_read(STD_BDF, {4'h0, cap});
        if (!ok || !v[31] || v[30])
            `uvm_fatal("VDEV_UNIT", $sformatf(
                "set_msix left device MSI-X disabled or function-masked (ctrl=0x%04h)", v[31:16]))
        for (int unsigned i = 0; i < 3; i++)
            if (port.host_read(STD_BAR4 + 16*i + 12, 4) != 32'h0000_0100)
                `uvm_fatal("VDEV_UNIT", $sformatf(
                    "set_msix left vector %0d masked or dropped its other Vector Control bits", i))
        be.clear_msix(ok);
        v = port.host_cfg_read(STD_BDF, {4'h0, cap});
        if (!ok || v[31] || v[30] || (port.host_read(STD_BAR4 + 12, 4) != 32'h0000_0101))
            `uvm_fatal("VDEV_UNIT", $sformatf(
                "clear_msix must mask the vectors and clear only MSI-X Enable (ctrl=0x%04h)", v[31:16]))
        // 每次 Message Control 写都带回读到的只读位（Table Size = 6 个向量 - 1）。
        std_log.select(VDEV_REG_WR, ev);
        foreach (ev[i])
            if ((ev[i].region == "cfg") && (ev[i].field == $sformatf("0x%03h", {4'h0, cap})))
                mc_writes.push_back(ev[i].val);
        if (mc_writes.size() != 2)
            `uvm_fatal("VDEV_UNIT", $sformatf("expected 2 Message Control writes, saw %0d", mc_writes.size()))
        foreach (mc_writes[i])
            if (mc_writes[i][26:16] != 11'd5)
                `uvm_fatal("VDEV_UNIT", $sformatf(
                    "Message Control write 0x%08h did not preserve the read-only Table Size", mc_writes[i]))
        `uvm_info("VDEV_UNIT", "test_vip_msix_enables_device PASSED", UVM_LOW)
    endtask

    virtual task run_phase(uvm_phase phase);
        phase.raise_objection(this);
        echo.bdf = ECHO_BDF;
        echo.init();
        port.attach(echo);
        test_base_config_space();
        test_base_marker();
        test_base_msix_and_dma();
        test_base_msix_replay();
        test_base_command_gating();
        test_std_config_and_features();
        test_std_enable_requires_all_addresses();
        test_std_split_tx_loopback_rx();
        test_std_packed_tx();
        test_std_ctrl_mq();
        test_std_device_fault_and_reset();
        test_std_event_idx_and_queue_reset();
        test_std_ctrl_without_mq();
        test_std_split_indirect();
        test_std_packed_indirect_loopback();
        test_vip_msix_enables_device();
        mem.leak_check();
        iommu.leak_check();
        `uvm_info("VDEV_UNIT", "virtio_vdev_unit_test PASSED", UVM_NONE)
        phase.drop_objection(this);
    endtask
endclass
`endif
