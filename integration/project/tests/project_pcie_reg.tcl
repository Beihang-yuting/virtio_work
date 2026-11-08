# integration/project/tests：真实Tcl reg_acc只传BAR偏移；SV在end_test后检查实际Intel请求。
# 编译使用AIP_CORE_ROOT，Tcl模块加载使用AIP_CORE；统一指向同一依赖仓库。
set ::env(AIP_CORE) $::env(AIP_CORE_ROOT)
source $::env(AIP_CORE_ROOT)/src/tcl/aip_cmd.tcl
set checks 0
proc check_project_reg {condition text} {
    if {!$condition} { error "PROJECT_REG_TCL_FAIL: $text" }
    incr ::checks
}
reg_acc write 0x1010 4 0x5555aaaa
check_project_reg [expr {[aip_check_status] == 0}] "PF0 BAR0 offset write"
reg_acc read 0x1010 check_read_data=0
check_project_reg [expr {[aip_read_result] eq "rdata=0x8"}] "AF status bypasses RAM comparison"
reg_acc read 0x1010 check_read_data=1
check_project_reg [expr {[aip_read_result] eq "rdata=0x8"}] "explicit RAM comparison remains enabled"
reg_acc read 0x1010
check_project_reg [expr {[aip_read_result] eq "rdata=0x8"}] "omitted option restores default comparison"
reg_acc op=write addr=0x3000 len=16 data=0x112233445566778899aabbccddeeff00
check_project_reg [expr {[aip_check_status] == 0}] "128bit write"
reg_acc read 0x3000 16
check_project_reg [expr {[aip_read_result] eq "rdata=0x112233445566778899aabbccddeeff00"}] "128bit readback"
reg_acc write 0x3000 16 0xffffffffffffffffffffffffffffffff mask=0x5555
check_project_reg [expr {[aip_check_status] == 0}] "sparse mask write"
reg_acc op=read addr=0x3000 len=16 mask=0x5555
check_project_reg [expr {[aip_read_result] eq "rdata=0xff00ff00ff00ff00ff00ff00ff00ff00"}] "masked read lanes"
reg_acc read 0x3000 16
check_project_reg [expr {[aip_read_result] eq "rdata=0xff22ff44ff66ff88ffaaffccffeeff00"}] "masked bytes retained"
reg_acc read 0x1010 check_read_data=2
check_project_reg [expr {[aip_check_status] != 0}] "invalid read policy rejected"
reg_acc read 0x1010 check_read_data=-1
check_project_reg [expr {[aip_check_status] != 0}] "negative read policy rejected"
reg_acc read 0xfffffffffffff000 16
check_project_reg [expr {[aip_check_status] != 0}] "BAR range error propagated"
check_project_reg [expr {[aip_read_result] eq "ERROR: reg reg_acc: BAR access crosses lease boundary or overflows 64-bit address"}] "range error text"
puts "PROJECT_REG_TCL_PASS checks=$checks"
end_test drain=100ns
run
