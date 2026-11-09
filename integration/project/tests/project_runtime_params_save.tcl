# tests：同一个simv先运行到环境已建且未下DUT配置，再保存基准快照。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
run 1000ns
reload_probe before
if {[aip_check_status] != 0} { error [aip_read_result] }
aip_checkpoint base "note=project built before first DUT configuration"
puts "PROJECT_RELOAD_SNAPSHOT_PASS"
quit
