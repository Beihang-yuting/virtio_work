#!/usr/bin/env bash

VIRTIO_MAINTAINED_TESTS=(
  dpu_resource_manager_test
  dpu_reg_plan_test
  dpu_device_resolver_test
  virtio_dut_caps_test
  virtio_fabric_resource_test
  virtio_unit_test
  virtio_stress_unit_test
  virtio_protocol_test
  virtio_indirect_desc_test
  virtio_admin_vq_test
  virtio_migration_dirty_test
  virtio_monitor_test
  virtio_coverage_test
  virtio_e2e_test
  virtio_full_integration_test
  virtio_pf_lifecycle_reset_test
  virtio_monitor_routing_test
  virtio_dual_test
  virtio_smoke_test
  virtio_traffic_test
)

is_virtio_maintained_test() {
  local requested="$1"
  local maintained
  for maintained in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
    [[ "$requested" == "$maintained" ]] && return 0
  done
  return 1
}
