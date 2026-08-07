#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
checker="$script_dir/../strict_log_check.sh"

pass_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
warn_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 1\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
duplicate_warning_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 7\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
duplicate_zero_warning_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
missing_fatal_sim=$'--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\n'
runtime_warn=$'Warning-[DT-MCEQ] Method called on empty queue\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
leak_sim=$'UVM_WARNING [HOST_MEM] Leak check: 2 blocks not freed (total 128 bytes)\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'
scoreboard_sim=$'========== Scoreboard Report ==========\n  Mismatched:   2\n--- UVM Report Summary ---\nUVM_WARNING : 0\nUVM_ERROR : 0\nUVM_FATAL : 0\n'

printf '%s' "$pass_sim" | "$checker" sim -

if printf '%s' "$warn_sim" | "$checker" sim -; then
  echo "warning summary was accepted" >&2
  exit 1
fi
if printf '%s' "$duplicate_warning_sim" | "$checker" sim -; then
  echo "duplicate warning summary was accepted" >&2
  exit 1
fi
if printf '%s' "$duplicate_zero_warning_sim" | "$checker" sim -; then
  echo "duplicate zero warning summary was accepted" >&2
  exit 1
fi
if printf '%s' "$missing_fatal_sim" | "$checker" sim -; then
  echo "missing fatal summary was accepted" >&2
  exit 1
fi
if printf '%s' "$runtime_warn" | "$checker" sim -; then
  echo "runtime VCS warning was accepted" >&2
  exit 1
fi
if printf '%s' "$leak_sim" | "$checker" sim -; then
  echo "host-memory leak was accepted" >&2
  exit 1
fi
if printf '%s' "$scoreboard_sim" | "$checker" sim -; then
  echo "nonzero scoreboard mismatch count was accepted" >&2
  exit 1
fi
if printf '%s' 'compile Warning-[ENUMASSIGN]' | "$checker" compile -; then
  echo "compile warning was accepted" >&2
  exit 1
fi
if printf '%s' 'simulation ended without summary' | "$checker" sim -; then
  echo "missing UVM summary was accepted" >&2
  exit 1
fi

echo "strict_log_check tests PASSED"
