// 中文说明：queue_work 是项目外独立 checkout。GQ 只接收
// gq_host_mem_provider，不拥有 Host memory；virtio_work 通过 provider
// adapter 把按 host-id 共享的 pool 注入 binder，避免重复定义 pool。
// 调用方可设置 QUEUE_WORK_ROOT；默认由 scripts/vcs.sh 解析为同级目录。
+incdir+$QUEUE_WORK_ROOT/src/gq
+incdir+$QUEUE_WORK_ROOT/integration
$QUEUE_WORK_ROOT/src/gq/gq_pkg.sv
$QUEUE_WORK_ROOT/integration/dpu_queue_resource_binder.sv
$QUEUE_WORK_ROOT/integration/dpu_queue_resource_binder_compile_test.sv
