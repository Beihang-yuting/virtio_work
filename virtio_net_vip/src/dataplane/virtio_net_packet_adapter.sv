`ifndef VIRTIO_NET_PACKET_ADAPTER_SV
`define VIRTIO_NET_PACKET_ADAPTER_SV

// 中文说明：net_packet 适配层只负责 packet_item 与线速字节流之间的转换。
// packet_item.do_pack() 是 UVM 序列化格式，包含 32-bit 长度字段；virtio
// descriptor 中必须放 packet.pkt.raw_data，因此这里明确绕过 UVM framing。
// 主要依赖：UVM uvm_object 与项目外 net_packet 的 packet_item/packet payload。
// 所有权：不接管调用方 packet 或字节队列；pack 会清空并重新填充调用方 raw_data，
//         unpack 会创建新的 packet_item。生命周期：纯静态无状态转换，无需 teardown。
class virtio_net_packet_adapter extends uvm_object;
    `uvm_object_utils(virtio_net_packet_adapter)

    // 创建无状态工具对象，不分配 packet 或 payload。
    function new(string name = "virtio_net_packet_adapter");
        super.new(name);
    endfunction

    // 接口契约：输入 pkt 必须可转换为 packet_item；输出 raw_data 先清空再写入
    // packet.pkt.raw_data。null/类型错误/空 payload 返回 0；空 raw_data 时可能调用
    // pkt.do_pack()，因此会有修改输入 packet 缓存的副作用，但不包含 UVM framing。
    // 将 net_packet packet_item 转换为真实 Ethernet 线速字节流。
    static function bit pack(
        input uvm_object pkt,
        ref byte unsigned raw_data[$]
    );
        packet_item item;

        raw_data.delete();
        if ((pkt == null) || !$cast(item, pkt) || (item.pkt == null))
            return 0;
        if (item.pkt.raw_data.size() == 0)
            item.pkt.do_pack();
        foreach (item.pkt.raw_data[i])
            raw_data.push_back(item.pkt.raw_data[i]);
        return raw_data.size() != 0;
    endfunction

    // 接口契约：输入 raw_data 为空时返回 0 且不保证 item 被初始化；成功时创建新的
    // packet_item/pkt 并复制线速 bytes，item 由调用方接管。unpack 尺寸不一致时返回 0。
    // 从设备写回的真实线速字节流解析出 net_packet packet_item。
    static function bit unpack(
        input byte unsigned raw_data[$],
        ref packet_item item
    );
        if (raw_data.size() == 0)
            return 0;
        item = packet_item::type_id::create("net_packet_rx_item");
        item.pkt = new();
        item.pkt.unpack(raw_data);
        return item.pkt.raw_data.size() == raw_data.size();
    endfunction

    // 接口契约：按 pack 后的 raw_data 长度和每字节内容比较；null、无法 pack 或尺寸
    // 不同返回 0。调用 pack 可能触发输入 packet 的 do_pack()，本函数不改变 payload
    // 所有权，也不使用 packet_item.do_compare()。
    // 比较线速字节流，避免 packet_item.do_compare() 丢失 payload/raw_data。
    static function bit compare(
        input uvm_object expected,
        input uvm_object actual
    );
        byte unsigned expected_data[$];
        byte unsigned actual_data[$];

        if (!pack(expected, expected_data) || !pack(actual, actual_data))
            return 0;
        if (expected_data.size() != actual_data.size())
            return 0;
        foreach (expected_data[i]) begin
            if (expected_data[i] != actual_data[i])
                return 0;
        end
        return 1;
    endfunction
endclass : virtio_net_packet_adapter

`endif
