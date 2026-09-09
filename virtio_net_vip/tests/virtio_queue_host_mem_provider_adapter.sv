// 所属层次：virtio_work 与 queue_work 的可选集成适配层。
// 文件职责：把 virtio_net_pkg 内按 Host 管理的 host_mem_pool 暴露为
//           queue_work 的中立 gq_host_mem_provider；不复制 Host memory
//           manager/pool，也不让 queue_work 反向依赖 virtio package。
// 主要依赖：host_mem_pkg、gq_pkg、virtio_net_pkg。
// 所有权与生命周期：适配器只借用调用方传入的 pool 和 manager 句柄；不创建、
//                     释放或重新初始化任何 Host memory 对象。

`ifndef VIRTIO_QUEUE_HOST_MEM_PROVIDER_ADAPTER_SV
`define VIRTIO_QUEUE_HOST_MEM_PROVIDER_ADAPTER_SV

import uvm_pkg::*;
import host_mem_pkg::*;
import gq_pkg::*;
import virtio_net_pkg::*;

// 设计意图：将具体 virtio host_mem_pool 隔离在项目边界内，queue_work binder
// 只接收 gq_host_mem_provider，因而不会在 $unit 重新声明 host_mem_pool。
// 生命周期：new 创建未绑定适配器，bind_pool 仅保存调用方 pool 句柄，随后由
// get_host_mem 查询；适配器不拥有 pool/manager，也没有 destroy/reset 操作。
// 重新 bind 或传入 null 不会释放旧对象，调用方必须保证查询期间 pool 仍有效。
class virtio_queue_host_mem_provider_adapter extends gq_host_mem_provider;
    `uvm_object_utils(virtio_queue_host_mem_provider_adapter)

    protected host_mem_pool memory_pool;

    // 功能：构造未绑定 pool 的适配器；构造阶段不创建 Host manager。
    function new(string name = "virtio_queue_host_mem_provider_adapter");
        super.new(name);
        memory_pool = null;
    endfunction

    // 功能：绑定调用方拥有的 Host pool。
    // 输入：pool 为 virtio 环境共享的 pool；null 会使后续查询明确失败。
    // 副作用与边界：只保存句柄，不修改 pool 内容或所有权。
    // 输入 pool 可为 null；只替换借用句柄，不创建 Host、不初始化 region，也不转移
    // 所有权。调用方应在 queue_work binder 使用前完成绑定。
    function void bind_pool(host_mem_pool pool);
        memory_pool = pool;
    endfunction

    // 功能：按 Host ID 返回 pool 中稳定的 host_mem_api 句柄。
    // 输入：host_id；输出：mem/reason；未知 Host 或空 pool 返回失败。
    // 副作用与边界：只读查询，不创建 manager、不初始化 region、不推进时间；返回
    // 的 mem 仍归 pool 所有，provider 不负责释放或改变其分配策略。
    virtual function bit get_host_mem(
        int unsigned host_id,
        output host_mem_api mem,
        output string reason
    );
        host_mem_manager concrete_mem;

        mem = null;
        reason = "";
        if (memory_pool == null) begin
            reason = "virtio Host memory provider has no bound pool";
            return 0;
        end
        if (!memory_pool.has_host(host_id)) begin
            reason = $sformatf(
                "Host %0d is not registered in the virtio host memory pool",
                host_id);
            return 0;
        end
        concrete_mem = memory_pool.get_host(host_id);
        if (concrete_mem == null) begin
            reason = $sformatf(
                "Host %0d pool lookup returned a null memory manager", host_id);
            return 0;
        end
        if (concrete_mem.get_host_id() != host_id) begin
            reason = $sformatf(
                "Host %0d pool lookup returned manager for Host %0d",
                host_id, concrete_mem.get_host_id());
            return 0;
        end
        mem = concrete_mem;
        return 1;
    endfunction
endclass : virtio_queue_host_mem_provider_adapter

`endif
