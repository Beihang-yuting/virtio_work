`ifndef VIRTIO_SCOREBOARD_CALLBACK_SV
`define VIRTIO_SCOREBOARD_CALLBACK_SV

// ============================================================================
// virtio_scoreboard_callback (callbacks)
//
// 记分板定制回调的抽象基类:custom_compare 用自定义比较整体替换标准
// do_compare(适合报文经过设备改写、字段级豁免等场景);
// custom_extract_fields 用于把 vendor 私有描述符格式解析成可读字段,
// 仅服务于调试打印,不参与判分。回调对象由测试代码创建并注册到
// virtio_scoreboard,组件只持有引用。expected/actual 用 uvm_object 传递
// (packet_item 定义在更晚的编译层),实现侧自行 $cast。
// ============================================================================

virtual class virtio_scoreboard_callback extends uvm_object;

    // 构造函数:仅透传名称,无状态可初始化。
    function new(string name = "virtio_scoreboard_callback");
        super.new(name);
    endfunction

    // Custom packet comparison (replaces standard do_compare)
    pure virtual function bit custom_compare(
        uvm_object expected,    // packet_item
        uvm_object actual       // packet_item
    );

    // Custom field extraction from raw descriptor data
    // Used for vendor-specific descriptor format debugging
    pure virtual function void custom_extract_fields(
        byte unsigned raw_desc[],
        ref string field_values[string]   // field_name -> value_string
    );

endclass

`endif
