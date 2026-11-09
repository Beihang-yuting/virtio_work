# tests：独立进程以新plusargs恢复；source必须紧跟restore，用户proc也须在恢复后定义。
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
run 1000ns
aip_restore base
source [file join $::env(AIP_CORE) dist aip_init_so.tcl]
set checks 0
proc check_reload {condition message} {
    if {!$condition} { error "PROJECT_RELOAD_TCL_FAIL: $message" }
    incr ::checks
}
reload_probe before
check_reload [expr {[aip_check_status] == 0}] "restore did not implicitly mutate cfg"
set_param path=vio.pairs value=2
load_params
check_reload [expr {[aip_check_status] != 0}] "fixed resource change rejected"
check_reload [string match {*preserves enabled/pairs/queue_type/features*} [aip_read_result]] "resource boundary error returned"
reload_probe before
check_reload [expr {[aip_check_status] == 0}] "failed candidate left same cfg unchanged"
clear_param path=vio.pairs
load_params
check_reload [expr {[aip_check_status] == 0}] "runtime reload accepted"
reload_probe reloaded
check_reload [expr {[aip_check_status] == 0}] "all consumers and frozen views refreshed"
load_params
check_reload [expr {[aip_check_status] == 0}] "repeat reload has no duplicate messages/resources"
reload_probe reloaded
check_reload [expr {[aip_check_status] == 0}] "repeat values stable"
reload_probe configure
check_reload [expr {[aip_check_status] == 0}] "real DUT tables/Notify/new MSI-X path"
load_params
check_reload [expr {[aip_check_status] != 0}] "active generation rejected"
reload_probe active
check_reload [expr {[aip_check_status] == 0}] "active state preserved"
puts "PROJECT_RELOAD_TCL_PASS checks=$checks"
end_test drain=100ns
run
quit
