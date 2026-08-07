#!/usr/bin/env bash
set -euo pipefail

mode="${1:-}"
log_path="${2:-}"

if [[ "$mode" != "compile" && "$mode" != "sim" ]]; then
  echo "usage: $0 compile|sim LOG_PATH|-" >&2
  exit 2
fi
if [[ -z "$log_path" ]]; then
  echo "missing log path" >&2
  exit 2
fi

if [[ "$log_path" == "-" ]]; then
  log_text="$(cat)"
else
  if [[ ! -f "$log_path" ]]; then
    echo "missing log: $log_path" >&2
    exit 1
  fi
  log_text="$(<"$log_path")"
fi

reject_fixed() {
  local needle="$1"
  local label="$2"
  if grep -Fq "$needle" <<<"$log_text"; then
    echo "$label found" >&2
    return 1
  fi
}

reject_fixed 'Warning-[' 'VCS warning'
reject_fixed 'Error-[' 'VCS error'

if [[ "$mode" == "compile" ]]; then
  exit 0
fi

summary_count="$(grep -c 'UVM Report Summary' <<<"$log_text" || true)"
if [[ "$summary_count" -ne 1 ]]; then
  echo "expected one UVM Report Summary, found $summary_count" >&2
  exit 1
fi

for severity in UVM_WARNING UVM_ERROR UVM_FATAL; do
  read -r row_count count < <(
    awk -v key="$severity" \
      '$1 == key && $2 == ":" {row_count++; value=$3} END {print row_count, value}' \
      <<<"$log_text"
  )
  if [[ "$row_count" != "1" || ! "$count" =~ ^0$ ]]; then
    echo "$severity count is ${count:-missing}" >&2
    exit 1
  fi
done

if grep -Eq 'Leak check: [1-9][0-9]* blocks not freed' <<<"$log_text"; then
  echo "host-memory leak found" >&2
  exit 1
fi
if grep -Eq 'Completion (byte_count|lower_addr|requester_id) mismatch' <<<"$log_text"; then
  echo "PCIe completion mismatch found" >&2
  exit 1
fi
if grep -Eq '(Mismatched|TX mismatched|RX mismatched):[[:space:]]*[1-9][0-9]*' \
    <<<"$log_text"; then
  echo "nonzero scoreboard mismatch count found" >&2
  exit 1
fi

exit 0
