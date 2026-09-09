// 中文说明：先列出控制面测试和 virtio 业务测试，最后列出共享顶层；
// 控制面测试全部通过 DPU_COMMON_ROOT 引入，保证回归只使用一个版本。
// All maintained test classes followed by the shared top.
+incdir+virtio_net_vip/tests
virtio_net_vip/tests/virtio_test_device_builder.sv
// queue_work 只消费中立 gq_host_mem_provider；该适配器把项目共享 pool
// 注入 binder，不在 queue_work 或 $unit 重复编译 host_mem_pool。
virtio_net_vip/tests/virtio_queue_host_mem_provider_adapter.sv
$DPU_COMMON_ROOT/tests/dpu_resource_manager_test.sv
$DPU_COMMON_ROOT/tests/dpu_reg_plan_test.sv
$DPU_COMMON_ROOT/tests/dpu_pcie_reg_executor_test.sv
// scripts/test_manifest.sh guards these focused test sources at exact-once.
$DPU_COMMON_ROOT/tests/dpu_device_resolver_test.sv
$DPU_COMMON_ROOT/tests/dpu_placement_test.sv
$DPU_COMMON_ROOT/tests/dpu_resource_resolver_test.sv
$DPU_COMMON_ROOT/tests/dpu_device_bootstrap_plan_test.sv
$DPU_COMMON_ROOT/tests/dpu_vio_reg_plan_test.sv
virtio_net_vip/tests/virtio_unit_test.sv
virtio_net_vip/tests/virtio_shared_mem_fixture.sv
virtio_net_vip/tests/virtio_host_mem_reclaim_test.sv
virtio_net_vip/tests/virtio_queue_semantics_test.sv
virtio_net_vip/tests/virtio_fabric_resource_test.sv
virtio_net_vip/tests/virtio_stress_unit_test.sv
virtio_net_vip/tests/virtio_protocol_test.sv
virtio_net_vip/tests/virtio_indirect_desc_test.sv
virtio_net_vip/tests/virtio_desc_corruption_test.sv
virtio_net_vip/tests/virtio_admin_vq_test.sv
virtio_net_vip/tests/virtio_pf_lifecycle_reset_test.sv
virtio_net_vip/tests/virtio_monitor_test.sv
virtio_net_vip/tests/virtio_coverage_test.sv
virtio_net_vip/tests/virtio_monitor_routing_test.sv
virtio_net_vip/tests/virtio_migration_dirty_test.sv
virtio_net_vip/tests/virtio_e2e_test.sv
virtio_net_vip/tests/virtio_full_test.sv
virtio_net_vip/tests/virtio_dual_test.sv
virtio_net_vip/tests/virtio_base_test.sv
virtio_net_vip/tests/virtio_smoke_test.sv
virtio_net_vip/tests/virtio_traffic_test.sv
virtio_net_vip/tests/virtio_dut_caps_test.sv
virtio_net_vip/tests/virtio_execution_mode_test.sv
virtio_net_vip/tests/virtio_real_dut_iova_dma_test.sv
$HOST_MEM_ROOT/tb/host_mem_random_tb.sv
virtio_net_vip/tests/virtio_pcie_host_mem_test.sv
virtio_net_vip/tests/virtio_net_packet_multi_queue_test.sv
virtio_net_vip/tests/virtio_real_driver_flow_fixture.sv
virtio_net_vip/tests/virtio_real_driver_flow_test.sv
virtio_net_vip/tests/virtio_real_driver_multiqueue_test.sv
virtio_net_vip/tests/virtio_real_driver_rx_test.sv
virtio_net_vip/tests/dpu_pcie_tl_executor_integration_test.sv
virtio_net_vip/tests/virtio_tb_top.sv
