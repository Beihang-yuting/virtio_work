// 目录层次：virtio_net_vip/tests；设备模型测试件（不进 src）。
// vdev_loopback_port：无 PCIe 链路的设备端口。Host 侧前门把配置/MMIO 直接交给设备；设备 DMA
// 经严格 IOMMU 翻译读写共享 Host memory（写走 write_from_device_for_host，保留权限与脏页记录）；
// MSI-X 只记录地址/数据。vdev_event_log：订阅 event_ap，按发生顺序保存事件。
// 所有权：端口借用 mem/iommu，不分配、不释放；设备由测试创建。
`ifndef VDEV_LOOPBACK_PORT_SV
`define VDEV_LOOPBACK_PORT_SV

import uvm_pkg::*;
`include "uvm_macros.svh"
import virtio_net_pkg::*;

class vdev_loopback_port extends vdev_port;
    `uvm_object_utils(vdev_loopback_port)

    host_mem_manager   mem;
    virtio_iommu_model iommu;
    int unsigned       host_id;
    bit [63:0]         msix_addr[$];
    bit [31:0]         msix_data[$];

    function new(string name = "vdev_loopback_port");
        super.new(name);
        host_id = 0;
    endfunction

    // 配置读写按目标 BDF 分派；无设备时读返回全 1（UR）。
    function bit [31:0] host_cfg_read(bit [15:0] target, bit [11:0] addr);
        vdev_base dev;

        dev = device_by_bdf(target);
        return (dev == null) ? 32'hffff_ffff : dev.cfg_read(addr);
    endfunction

    function void host_cfg_write(bit [15:0] target, bit [11:0] addr, bit [31:0] data,
                                 bit [3:0] be = 4'hf);
        vdev_base dev;

        dev = device_by_bdf(target);
        if (dev != null)
            dev.cfg_write(addr, data, be);
    endfunction

    // MMIO 按设备已编程的 BAR 窗口分派；size 为 1/2/4，返回值右对齐。
    function bit [31:0] host_read(bit [63:0] addr, int unsigned size);
        vdev_base dev;
        int unsigned bar;
        bit [31:0] off;

        dev = device_by_addr(addr, bar, off);
        return (dev == null) ? 32'hffff_ffff : dev.mmio_read(bar, off, size);
    endfunction

    function void host_write(bit [63:0] addr, int unsigned size, bit [31:0] data);
        vdev_base dev;
        int unsigned bar;
        bit [31:0] off;

        dev = device_by_addr(addr, bar, off);
        if (dev != null)
            dev.mmio_write(bar, off, size, data);
    endfunction

    virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                          output bit [7:0] data[], output bit ok);
        bit [63:0] gpa;
        iommu_fault_e fault;
        byte raw[];

        data = new[0];
        ok = iommu.translate_for_host(host_id, requester, addr, len, DMA_TO_DEVICE, gpa, fault);
        if (!ok)
            return;
        mem.read_mem(gpa, len, raw);
        data = new[raw.size()];
        foreach (raw[i])
            data[i] = raw[i];
        ok = (data.size() == len);
    endtask

    virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                           output bit ok);
        iommu_fault_e fault;
        byte raw[];

        raw = new[data.size()];
        foreach (data[i])
            raw[i] = data[i];
        ok = iommu.write_from_device_for_host(host_id, mem, requester, addr, raw, fault);
    endtask

    virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
        msix_addr.push_back(addr);
        msix_data.push_back(data);
    endtask
endclass

// 回环 BAR accessor：把 VIP transport 的 MMIO/配置访问直接交给 vdev_loopback_port（无 PCIe）。
// 保留基类的 BAR 角色守卫；bar_base 由测试设置（Fabric 布局存在时由 Function 绑定写入）。
class vdev_loopback_bar_accessor extends virtio_bar_accessor;
    `uvm_object_utils(vdev_loopback_bar_accessor)

    vdev_loopback_port port;
    bit [15:0]         target_bdf;

    function new(string name = "vdev_loopback_bar_accessor");
        super.new(name);
    endfunction

    virtual task read_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                          ref bit [31:0] data);
        if ((bar_id > 5) || !allow_functional_bar_access(bar_id)) begin
            data = '0;
            return;
        end
        data = port.host_read(bar_base[bar_id] + offset, size);
    endtask

    virtual task write_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                           bit [31:0] data);
        if ((bar_id > 5) || !allow_functional_bar_access(bar_id))
            return;
        port.host_write(bar_base[bar_id] + offset, size, data);
    endtask

    virtual task read_msix_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                               ref bit [31:0] data);
        if ((bar_id > 5) || !allow_msix_bar_access(bar_id)) begin
            data = '0;
            return;
        end
        data = port.host_read(bar_base[bar_id] + offset, size);
    endtask

    virtual task write_msix_reg(int unsigned bar_id, bit [31:0] offset, int unsigned size,
                                bit [31:0] data);
        if ((bar_id > 5) || !allow_msix_bar_access(bar_id))
            return;
        port.host_write(bar_base[bar_id] + offset, size, data);
    endtask

    virtual task config_read(bit [11:0] addr, ref bit [31:0] data);
        data = port.host_cfg_read(target_bdf, addr);
    endtask

    virtual task config_write(bit [11:0] addr, bit [31:0] data, bit [3:0] be);
        port.host_cfg_write(target_bdf, addr, data, be);
    endtask
endclass

class vdev_event_log extends uvm_subscriber #(vdev_event);
    `uvm_component_utils(vdev_event_log)

    vdev_event events[$];

    function new(string name = "vdev_event_log", uvm_component parent = null);
        super.new(name, parent);
    endfunction

    virtual function void write(vdev_event t);
        events.push_back(t);
    endfunction

    // 按类型筛选（保持顺序）。
    function void select(vdev_event_kind_e kind, ref vdev_event out[$]);
        out.delete();
        foreach (events[i])
            if (events[i].kind == kind)
                out.push_back(events[i]);
    endfunction

    // 寄存器访问序列 "W|R region field 0xval"（不含配置空间），供私有驱动序列断言。
    function void reg_trace(ref string out[$]);
        out.delete();
        foreach (events[i])
            if ((events[i].kind inside {VDEV_REG_WR, VDEV_REG_RD}) && (events[i].region != "cfg"))
                out.push_back($sformatf("%s %s %s 0x%0h",
                    (events[i].kind == VDEV_REG_WR) ? "W" : "R",
                    events[i].region, events[i].field, events[i].val));
    endfunction
endclass

// 吞掉匹配 ID 且消息含给定子串的 WARNING/ERROR，并计数；其它报告照常抛出。
class vdev_expect_catcher extends uvm_report_catcher;
    string       id;
    string       text;
    int unsigned caught;

    function new(string name = "vdev_expect_catcher");
        super.new(name);
        caught = 0;
    endfunction

    virtual function action_e catch();
        string msg;

        msg = get_message();
        if ((get_id() == id) && (get_severity() inside {UVM_WARNING, UVM_ERROR})) begin
            for (int i = 0; i + text.len() <= msg.len(); i++)
                if (msg.substr(i, i + text.len() - 1) == text) begin
                    caught++;
                    return CAUGHT;
                end
        end
        return THROW;
    endfunction
endclass
`endif
