`ifndef VIRTIO_COVERAGE_CALLBACK_SV
`define VIRTIO_COVERAGE_CALLBACK_SV

// ============================================================================
// virtio_coverage_callback (callbacks)
//
// 覆盖率扩展点的抽象基类:用户派生并实现 custom_sample,即可在 VIP 内置
// covergroup 之外补充自己的采样逻辑。回调对象由测试代码创建并注册到
// virtio_coverage 组件;组件只持有引用、在每个事务完成时调用,不负责
// 创建或销毁回调。参数用 uvm_object 而非具体事务类型,是为了让本文件在
// 编译顺序上先于 virtio_transaction——实现侧需自行 $cast。
// ============================================================================

virtual class virtio_coverage_callback extends uvm_object;

    // 构造函数:仅透传名称,无状态可初始化。
    function new(string name = "virtio_coverage_callback");
        super.new(name);
    endfunction

    // Called on each transaction completion for custom covergroup sampling
    // txn is a virtio_transaction (forward reference, cast at runtime)
    pure virtual function void custom_sample(uvm_object txn);

endclass

`endif
