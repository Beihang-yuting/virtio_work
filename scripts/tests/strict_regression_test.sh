#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_script_dir="$(cd "$script_dir/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
  if [[ -f "$tmp_root/simv.pid" ]]; then
    simv_pid="$(<"$tmp_root/simv.pid")"
    kill -KILL "$simv_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp_root"
}
trap cleanup EXIT

make_harness() {
  local harness="$1"
  mkdir -p "$harness/scripts" "$harness/build"
  cp "$repo_script_dir/strict_regression.sh" "$repo_script_dir/strict_log_check.sh" \
    "$harness/scripts/"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'VIRTIO_MAINTAINED_TESTS=(hard_timeout_test)' \
    'is_virtio_maintained_test() {' \
    '  [[ "$1" == "hard_timeout_test" ]]' \
    '}' >"$harness/scripts/test_manifest.sh"
  chmod +x "$harness/scripts/strict_regression.sh" \
    "$harness/scripts/strict_log_check.sh" "$harness/scripts/test_manifest.sh"
}

invalid_harness="$tmp_root/invalid"
make_harness "$invalid_harness"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' \
  'root_dir="$(cd "$script_dir/.." && pwd)"' \
  ': > "$root_dir/vcs_invoked"' \
  'exit 99' >"$invalid_harness/scripts/vcs.sh"
chmod +x "$invalid_harness/scripts/vcs.sh"

set +e
STRICT_TEST_TIMEOUT_SECONDS=0 "$invalid_harness/scripts/strict_regression.sh" \
  >"$invalid_harness/output.log" 2>&1
invalid_rc=$?
set -e

if [[ "$invalid_rc" -eq 0 || -f "$invalid_harness/vcs_invoked" ]] ||
    ! grep -Fq 'STRICT_TEST_TIMEOUT_SECONDS must be a positive integer' \
      "$invalid_harness/output.log"; then
  echo "invalid timeout override was not rejected before VCS" >&2
  exit 1
fi

timeout_harness="$tmp_root/timeout"
make_harness "$timeout_harness"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'exit 0' >"$timeout_harness/scripts/vcs.sh"
chmod +x "$timeout_harness/scripts/vcs.sh"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "%s\n" "$$" > "${TEST_HARNESS_PID_FILE:?}"' \
  'trap "" TERM' \
  'while :; do sleep 0.05; done' >"$timeout_harness/build/simv"
chmod +x "$timeout_harness/build/simv"

set +e
TEST_HARNESS_PID_FILE="$tmp_root/simv.pid" STRICT_TEST_TIMEOUT_SECONDS=1 \
  timeout --signal=KILL 4s "$timeout_harness/scripts/strict_regression.sh" \
  >"$timeout_harness/output.log" 2>&1
timeout_rc=$?
set -e

if [[ "$timeout_rc" -ne 1 ]] ||
    ! grep -Fq 'STRICT_RESULT hard_timeout_test FAIL rc=137' \
      "$timeout_harness/output.log"; then
  echo "TERM-ignoring simulation did not hit the hard timeout" >&2
  exit 1
fi

echo "strict_regression tests PASSED"
