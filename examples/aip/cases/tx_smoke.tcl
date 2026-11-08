# examples/aip/cases：从 UCLI 启动 AIP 桥，在已构建的模型环境发送报文。
# 构建参数由 simv plusargs 提供；这里的 set_param 仅控制下一次运行命令。
# 单条参数使用 path= 与 value= 命名字段，由 AIP 命令桥解析。
# 本例检查命令/生命周期返回，业务完成条件应由平台的 monitor/scoreboard 添加。
set ::env(AIP_CORE) $::env(AIP_CORE_ROOT)
source [file join $::env(AIP_CORE_ROOT) src tcl aip_cmd.tcl]
set_param path=vio.target value=h0.pf0.i0
set_param path=vio.tx.kind value=ETH_IPV4_UDP
set_param path=vio.tx.len value=128
set_param path=vio.tx.gap_ns value=100
set_param path=vio.tx.hdr.eth.dst_mac value=0x001122334455
vio_init
vio_start
vio_tx count=4
vio_stop
vio_reset
end_test
run
