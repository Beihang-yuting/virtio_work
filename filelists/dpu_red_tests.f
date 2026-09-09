// 中文说明：该红色测试只引用外部控制面的 manager 实现，验证 filelist
// 的隔离路径不会重新引入本地 dpu_common。
// This test deliberately references the Task 3 manager implementation.
$DPU_COMMON_ROOT/tests/dpu_resource_manager_test.sv
