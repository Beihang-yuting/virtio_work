# examples/aip/cases：从 UCLI 启动 AIP 桥，在已构建的模型环境发送报文。
# 构建参数由 simv plusargs 提供；这里的 set_param 仅控制下一次运行命令。
# 本例检查命令/生命周期返回，业务完成条件应由平台的 monitor/scoreboard 添加。
set ::env(AIP_CORE) $::env(AIP_CORE_ROOT)
source [file join $::env(AIP_CORE_ROOT) src tcl aip_cmd.tcl]
set_param vio.target h0.pf0.i0
set_param vio.tx.kind ETH_IPV4_UDP
set_param vio.tx.len 128
set_param vio.tx.gap_ns 100
set_param vio.tx.hdr.eth.dst_mac 0x001122334455
vio_init
vio_start
vio_tx count=4
vio_stop
vio_reset
end_test
run
