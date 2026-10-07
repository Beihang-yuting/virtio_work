// 目录层次：virtio_net_vip/src/devmodel；独立设备模型的端口抽象与语义事件。
// 设备只依据端口送来的配置/MMIO 请求维护状态，经端口发 DMA 与 MSI-X。端口实现决定传输：
// vdev_uvm_ep_port（VCS 回归，pcie_tl EP driver）、vdev_cosim_port（E 阶段临时，DPI）、
// vdev_loopback_port（单元测试）。本文件不引用任何驱动侧对象。
`ifndef VDEV_PORT_SV
`define VDEV_PORT_SV

typedef class vdev_base;

typedef enum {
    VDEV_REG_WR, VDEV_REG_RD, VDEV_STATUS, VDEV_FEATURES, VDEV_QUEUE_CFG, VDEV_NOTIFY,
    VDEV_DESC_CHAIN, VDEV_PKT, VDEV_COMPLETE, VDEV_IRQ, VDEV_CTRL, VDEV_MARKER
} vdev_event_kind_e;

// 一条设备侧语义事件，字段与规范“对比方法”事件表一一对应；只填本类型用到的字段。
// to_json() 输出 vdev_diff.py 读取的单行 JSON；pkt 带帧字节 hex（"bytes"），sha1 由脚本补算。
class vdev_event extends uvm_object;
    `uvm_object_utils(vdev_event)

    vdev_event_kind_e kind;
    int unsigned      fn;            // 设备 BDF
    string            region;        // reg_wr/reg_rd
    string            field;
    int               q;             // 队列号；-1 表示与队列无关
    bit [63:0]        val;
    bit [7:0]         from_status;
    bit [7:0]         to_status;
    bit [63:0]        dev_offered;
    bit [63:0]        drv_accepted;
    int unsigned      size;          // queue_cfg
    int unsigned      vector;        // queue_cfg / irq
    bit               enable;
    string            ring_fmt;      // split / packed / priv
    int unsigned      next_idx;      // notify
    bit               wrap;
    int unsigned      seg_len[$];    // desc_chain
    bit [31:0]        seg_flags[$];
    bit               has_hdr;
    virtio_net_hdr_t  hdr;
    string            dir;           // pkt：tx / rx
    bit [7:0]         bytes[$];      // pkt：以太网帧（不含 virtio-net header）
    int unsigned      id;            // complete
    int unsigned      len;           // complete / pkt
    bit [7:0]         ctrl_class;
    bit [7:0]         ctrl_cmd;
    bit [7:0]         ctrl_data[$];
    bit [7:0]         ack;
    int unsigned      scenario;      // marker

    function new(string name = "vdev_event");
        super.new(name);
        q = -1;
        has_hdr = 0;
    endfunction

    function string to_json();
        string s;

        case (kind)
            VDEV_REG_WR, VDEV_REG_RD:
                s = $sformatf("{\"ev\":\"%s\",\"fn\":%0d,\"region\":\"%s\",\"field\":\"%s\",\"q\":%0d,\"val\":%0d}",
                              (kind == VDEV_REG_WR) ? "reg_wr" : "reg_rd", fn, region, field, q, val);
            VDEV_STATUS:
                s = $sformatf("{\"ev\":\"status\",\"from\":%0d,\"to\":%0d}", from_status, to_status);
            VDEV_FEATURES:
                s = $sformatf("{\"ev\":\"features\",\"dev_offered\":%0d,\"drv_accepted\":%0d}",
                              dev_offered, drv_accepted);
            VDEV_QUEUE_CFG:
                s = $sformatf("{\"ev\":\"queue_cfg\",\"q\":%0d,\"size\":%0d,\"vector\":%0d,\"enable\":%0d,\"ring_fmt\":\"%s\"}",
                              q, size, vector, enable, ring_fmt);
            VDEV_NOTIFY:
                s = $sformatf("{\"ev\":\"notify\",\"q\":%0d,\"next_idx\":%0d,\"wrap\":%0d}", q, next_idx, wrap);
            VDEV_DESC_CHAIN: begin
                s = $sformatf("{\"ev\":\"desc_chain\",\"q\":%0d,\"segs\":[", q);
                foreach (seg_len[i])
                    s = {s, (i == 0) ? "" : ",", $sformatf("[%0d,%0d]", seg_len[i], seg_flags[i])};
                s = {s, "],\"hdr\":"};
                if (!has_hdr)
                    s = {s, "null}"};
                else
                    s = {s, $sformatf("{\"flags\":%0d,\"gso_type\":%0d,\"hdr_len\":%0d,\"gso_size\":%0d,\"csum_start\":%0d,\"csum_offset\":%0d,\"num_buffers\":%0d}}",
                         hdr.flags, hdr.gso_type, hdr.hdr_len, hdr.gso_size, hdr.csum_start,
                         hdr.csum_offset, hdr.num_buffers)};
            end
            VDEV_PKT: begin
                s = $sformatf("{\"ev\":\"pkt\",\"dir\":\"%s\",\"q\":%0d,\"len\":%0d,\"bytes\":\"",
                              dir, q, bytes.size());
                foreach (bytes[i])
                    s = {s, $sformatf("%02x", bytes[i])};
                s = {s, "\"}"};
            end
            VDEV_COMPLETE:
                s = $sformatf("{\"ev\":\"complete\",\"q\":%0d,\"id\":%0d,\"len\":%0d}", q, id, len);
            VDEV_IRQ:
                s = $sformatf("{\"ev\":\"irq\",\"vector\":%0d}", vector);
            VDEV_CTRL: begin
                s = $sformatf("{\"ev\":\"ctrl\",\"class\":%0d,\"cmd\":%0d,\"data\":[", ctrl_class, ctrl_cmd);
                foreach (ctrl_data[i])
                    s = {s, (i == 0) ? "" : ",", $sformatf("%0d", ctrl_data[i])};
                s = {s, $sformatf("],\"ack\":%0d}", ack)};
            end
            VDEV_MARKER:
                s = $sformatf("{\"ev\":\"marker\",\"scenario\":%0d}", scenario);
        endcase
        return s;
    endfunction
endclass

// 设备端口：同一链路可挂多个 Function，按 BDF（配置）或 BAR 窗口（MMIO）分派。
virtual class vdev_port extends uvm_object;
    protected vdev_base m_devices[$];

    function new(string name = "vdev_port");
        super.new(name);
    endfunction

    // 挂接设备；设备经 port 句柄发 DMA/MSI-X。
    function void attach(vdev_base dev);
        m_devices.push_back(dev);
        dev.port = this;
    endfunction

    function vdev_base device_by_bdf(bit [15:0] target);
        foreach (m_devices[i])
            if (m_devices[i].bdf == target)
                return m_devices[i];
        return null;
    endfunction

    function vdev_base device_by_addr(bit [63:0] addr, output int unsigned bar,
                                      output bit [31:0] offset);
        bar = 0;
        offset = 0;
        foreach (m_devices[i])
            if (m_devices[i].claims(addr, bar, offset))
                return m_devices[i];
        return null;
    endfunction

    // 设备 → Host：DMA 读/写（地址为设备可见 IOVA）与 MSI-X 消息写。
    pure virtual task dma_read(bit [15:0] requester, bit [63:0] addr, int unsigned len,
                               output bit [7:0] data[], output bit ok);
    pure virtual task dma_write(bit [15:0] requester, bit [63:0] addr, bit [7:0] data[],
                                output bit ok);
    pure virtual task raise_msix(bit [15:0] requester, bit [63:0] addr, bit [31:0] data);
endclass
`endif
