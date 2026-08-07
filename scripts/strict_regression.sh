#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
source "$script_dir/test_manifest.sh"

timeout_seconds="${STRICT_TEST_TIMEOUT_SECONDS:-180}"
if ! [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]]; then
  echo "STRICT_TEST_TIMEOUT_SECONDS must be a positive integer" >&2
  exit 2
fi

log_dir="$root_dir/build/strict"
mkdir -p "$log_dir"

compile_log="$log_dir/compile.log"
: >"$compile_log"
for test_name in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
  : >"$log_dir/$test_name.log"
done

TEST="${VIRTIO_MAINTAINED_TESTS[0]}" "$script_dir/vcs.sh" --compile-only >"$compile_log" 2>&1
"$script_dir/strict_log_check.sh" compile "$compile_log"

failures=0
for test_name in "${VIRTIO_MAINTAINED_TESTS[@]}"; do
  test_log="$log_dir/$test_name.log"
  set +e
  timeout --signal=KILL "${timeout_seconds}s" "$root_dir/build/simv" \
    +UVM_TESTNAME="$test_name" +UVM_VERBOSITY=UVM_LOW +UVM_NO_RELNOTES \
    >"$test_log" 2>&1
  run_rc=$?
  set -e

  if [[ "$run_rc" -ne 0 ]]; then
    echo "STRICT_RESULT $test_name FAIL rc=$run_rc"
    failures=$((failures + 1))
    continue
  fi
  if ! "$script_dir/strict_log_check.sh" sim "$test_log"; then
    echo "STRICT_RESULT $test_name FAIL log-policy"
    failures=$((failures + 1))
    continue
  fi
  echo "STRICT_RESULT $test_name PASS"
done

if [[ "$failures" -ne 0 ]]; then
  echo "STRICT_REGRESSION FAIL failures=$failures" >&2
  exit 1
fi

echo "STRICT_REGRESSION PASS tests=${#VIRTIO_MAINTAINED_TESTS[@]}"
