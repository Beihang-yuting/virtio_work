// 可选完整编译入口：AIP 必须先编译，使后续原类 load_params 与 net_packet 生效。
// 调用方提供四个外部依赖根；若已有统一 filelist，应保持各 package 仅编译一次。
+incdir+$AIP_CORE_ROOT/src/sv
$AIP_CORE_ROOT/src/sv/aip_core_pkg.sv
-f filelists/dpu_common.f
-f filelists/virtio_net.f
integration/aip/virtio_aip_pkg.sv
