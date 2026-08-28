#!/usr/bin/env bash

VIRTIO_MAINTAINED_TESTS=(
  dpu_resource_manager_test
  dpu_reg_plan_test
  dpu_device_resolver_test
  dpu_placement_test
  dpu_resource_resolver_test
  dpu_device_bootstrap_plan_test
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

_validate_virtio_test_manifest() {
  local manifest_root required test_name count
  local -A seen=()

  manifest_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  for test_name in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
    if [[ -n "${seen[$test_name]+present}" ]]; then
      echo "duplicate maintained test: $test_name" >&2
      return 1
    fi
    seen["$test_name"]=1
  done

  for required in dpu_device_resolver_test dpu_placement_test dpu_resource_resolver_test dpu_device_bootstrap_plan_test; do
    count=0
    for test_name in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
      [[ "$test_name" == "$required" ]] && count=$((count + 1))
    done
    if [[ "$count" -ne 1 ]]; then
      echo "required maintained test must appear exactly once: $required" >&2
      return 1
    fi
    count="$(awk -v source="dpu_common/tests/${required}.sv" \
      '$0 == source { count++ } END { print count + 0 }' \
      "$manifest_root/filelists/tests.f")"
    if [[ "$count" -ne 1 ]]; then
      echo "required test source must appear exactly once: dpu_common/tests/${required}.sv" >&2
      return 1
    fi
  done
}

_validate_global_dpu_static_contracts() {
  local manifest_root builder definition_count named_use_count literal_count
  local executor_input_count executor_assignment_count
  local removed_caps_binder removed_caps_call_pattern

  manifest_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  if awk '
      BEGIN { RS = "" }
      /BAR2\/3/ && tolower($0) ~ /reserved/ {
        print FILENAME ": BAR2/3 and reserved occur in one paragraph" > "/dev/stderr"
        found = 1
      }
      END { exit(found ? 0 : 1) }
    ' "$manifest_root/README.md" \
      "$manifest_root/docs/virtio_net_vip_manual.md"; then
    echo "stale BAR2/3 reserved description is forbidden" >&2
    return 1
  fi

  builder="$manifest_root/dpu_common/src/dpu_device_bootstrap_plan_builder.sv"
  definition_count="$(awk '
      $0 == "localparam bit [63:0] DPU_AF_DECLARATION_ADDR = 64\047h1010;" {
        count++
      }
      END { print count + 0 }
    ' "$builder")"
  named_use_count="$(grep -c \
    '^[[:space:]]*DPU_AF_DECLARATION_ADDR);$' "$builder" || true)"
  literal_count="$(grep -c "64'h1010" "$builder" || true)"
  if [[ "$definition_count" -ne 1 || "$named_use_count" -ne 3 ||
        "$literal_count" -ne 1 ]]; then
    echo "production AF declaration contract requires one definition and three named uses" >&2
    return 1
  fi

  executor_input_count="$(grep -c \
    '^function void configure_devices(input dpu_reg_executor injected_executor);$' \
    "$manifest_root/README.md" || true)"
  executor_assignment_count="$(grep -c \
    '^global_cfg.executor = injected_executor;' \
    "$manifest_root/README.md" || true)"
  if [[ "$executor_input_count" -ne 1 ||
        "$executor_assignment_count" -ne 1 ]]; then
    echo "README executor example requires one explicit input and one injection" >&2
    return 1
  fi

  # Assemble the removed name so this maintained guard cannot match itself.
  # Restrict the scan to maintained source/tests and user-facing docs; design
  # history may legitimately explain why the old entry point was deleted.
  removed_caps_binder='bind_'
  removed_caps_binder+='dut_caps'
  removed_caps_call_pattern="(^|[^[:alnum:]_])${removed_caps_binder}[[:space:]]*\\("
  if grep -R -n -E --include='*.sv' "$removed_caps_call_pattern" \
      "$manifest_root/dpu_common/src" \
      "$manifest_root/dpu_common/tests" \
      "$manifest_root/virtio_net_vip/src" \
      "$manifest_root/virtio_net_vip/tests" ||
     grep -n -E "$removed_caps_call_pattern" \
      "$manifest_root/README.md" \
      "$manifest_root/docs/virtio_net_vip_manual.md"; then
    echo "removed direct DUT-capability binder remains reachable" >&2
    return 1
  fi
}

_validate_documentation_contracts() {
  local manifest_root invalid_default_path stale_default_method
  local stale_vf_method positional_vf_phrase doc label failures index
  local -a expected_tests documented_tests

  manifest_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  failures=0

  # Build every forbidden spelling from fragments so the guard source cannot
  # satisfy its own search if its scan scope is widened later.
  invalid_default_path='env.'
  invalid_default_path+='vf_instances[0]'
  stale_default_method='get_default_'
  stale_default_method+='driver_config'
  stale_vf_method='get_'
  stale_vf_method+='vf_config'
  positional_vf_phrase='per-'
  positional_vf_phrase+='VF pair'

  if grep -n -F "$invalid_default_path" \
      "$manifest_root/README.md" \
      "$manifest_root/docs/virtio_net_vip_manual.md"; then
    echo "default example indexes a VF that the base topology does not declare" >&2
    failures=$((failures + 1))
  fi
  if grep -n -E \
      "(${stale_default_method}|${stale_vf_method})[[:space:]]*\\(" \
      "$manifest_root/README.md" \
      "$manifest_root/docs/virtio_net_vip_manual.md"; then
    echo "user documentation contains removed positional config methods" >&2
    failures=$((failures + 1))
  fi
  if grep -n -F "$positional_vf_phrase" \
      "$manifest_root/docs/virtio_net_vip_manual.md"; then
    echo "manual describes positional VF behavior instead of service-keyed behavior" >&2
    failures=$((failures + 1))
  fi

  expected_tests=("${VIRTIO_MAINTAINED_TESTS[@]}")
  for doc in "$manifest_root/README.md" \
             "$manifest_root/docs/virtio_net_vip_manual.md"; do
    label="${doc#"$manifest_root/"}"
    mapfile -t documented_tests < <(
      awk '
        /VIRTIO_MAINTAINED_TESTS/ { capture = 1 }
        capture && /^$/ { exit }
        capture { print }
      ' "$doc" | grep -oE '[a-z0-9_]+_test' || true
    )
    if [[ "${#documented_tests[@]}" -ne "${#expected_tests[@]}" ]]; then
      echo "$label maintained-test list has ${#documented_tests[@]} entries; expected ${#expected_tests[@]}" >&2
      failures=$((failures + 1))
      continue
    fi
    for index in "${!expected_tests[@]}"; do
      if [[ "${documented_tests[$index]}" != "${expected_tests[$index]}" ]]; then
        echo "$label maintained-test order mismatch at $index: expected ${expected_tests[$index]}, got ${documented_tests[$index]}" >&2
        failures=$((failures + 1))
        break
      fi
    done
  done

  [[ "$failures" -eq 0 ]]
}

_validate_virtio_test_manifest || {
  manifest_status=$?
  unset -f _validate_virtio_test_manifest
  return "$manifest_status" 2>/dev/null || exit "$manifest_status"
}
unset -f _validate_virtio_test_manifest

_validate_global_dpu_static_contracts || {
  contract_status=$?
  unset -f _validate_global_dpu_static_contracts
  return "$contract_status" 2>/dev/null || exit "$contract_status"
}
unset -f _validate_global_dpu_static_contracts

_validate_documentation_contracts || {
  documentation_status=$?
  unset -f _validate_documentation_contracts
  return "$documentation_status" 2>/dev/null || exit "$documentation_status"
}
unset -f _validate_documentation_contracts

is_virtio_maintained_test() {
  local requested="$1"
  local maintained
  for maintained in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
    [[ "$requested" == "$maintained" ]] && return 0
  done
  return 1
}
