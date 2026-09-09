`ifndef VIRTIO_DATAPLANE_CALLBACK_SV
`define VIRTIO_DATAPLANE_CALLBACK_SV

// ============================================================================
// virtio_dataplane_callback (callbacks)
//
// 数据面定制回调的抽象基类:当用户需要非标准的描述符链组装、RX buffer
// 解析或非标准 net_hdr 布局(如 vendor 扩展头)时,派生本类并注册到
// dataplane 组件;设置 custom_cb 后,这些钩子会整体替换对应的标准实现,
// 而不是叠加在标准路径之上。五个钩子必须成套自洽:hdr_size/pack/unpack
// 描述同一种头布局,TX 组链与 RX 解析互为逆操作。
// 回调对象由测试代码创建并持有,组件只保存引用。pkt 参数用 uvm_object
// 是编译顺序取舍(packet_item 定义在更晚的 dataplane 层)。
// ============================================================================

virtual class virtio_dataplane_callback extends uvm_object;

    // 构造函数:仅透传名称,无状态可初始化。
    function new(string name = "virtio_dataplane_callback");
        super.new(name);
    endfunction

    // TX: custom descriptor chain assembly
    // Called instead of standard_tx_build_chain when custom_cb is set
    // pkt: the packet to send (from net_packet component)
    // hdr: virtio_net_hdr already built
    // sgs: output scatter-gather lists to fill
    pure virtual function void custom_tx_build_chain(
        uvm_object       pkt,          // packet_item from net_packet
        virtio_net_hdr_t hdr,
        ref virtio_sg_list sgs[$]
    );

    // RX: custom buffer parsing
    // Called instead of standard RX parse when custom_cb is set
    // raw_data: raw bytes from used buffer
    // hdr: output parsed net_hdr
    // pkt: output parsed packet
    pure virtual function void custom_rx_parse_buf(
        byte unsigned    raw_data[$],
        ref virtio_net_hdr_t hdr,
        ref uvm_object   pkt            // packet_item
    );

    // Header: custom net_hdr size (may differ from standard 10/12/20)
    pure virtual function int unsigned custom_hdr_size();

    // Header: custom pack
    pure virtual function void custom_hdr_pack(
        virtio_net_hdr_t hdr,
        ref byte unsigned data[$]
    );

    // Header: custom unpack
    pure virtual function void custom_hdr_unpack(
        byte unsigned data[$],
        ref virtio_net_hdr_t hdr
    );

endclass

`endif
