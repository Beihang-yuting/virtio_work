#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

submodules=(
  "virtio_net_vip/ext/pcie_tl_vip"
  "virtio_net_vip/ext/host_mem"
  "virtio_net_vip/ext/net_packet"
)
expected_revisions=(
  "6913793a42dc58873935f802fab50a395ab56ff3"
  "ef056b331047f51125c2aaf248a8767b9b84862a"
  "e2af70204f53ede65e366c7a65f695c59acdbbc5"
)

for submodule in "${submodules[@]}"; do
  if [[ ! -d "$root_dir/$submodule" ]]; then
    echo "missing submodule: $submodule" >&2
    exit 2
  fi
done

for index in "${!submodules[@]}"; do
  submodule="${submodules[$index]}"
  expected="${expected_revisions[$index]}"
  actual="$(git -C "$root_dir/$submodule" rev-parse HEAD 2>/dev/null || true)"

  if [[ "$actual" != "$expected" ]]; then
    echo "submodule revision mismatch: $submodule expected $expected actual $actual" >&2
    exit 5
  fi
done

if [[ -z "${VCS_HOME:-}" ]]; then
  echo "VCS_HOME is not set; source the VCS environment before running check-deps" >&2
  exit 3
fi

if [[ ! -x "$VCS_HOME/bin/vcs" ]]; then
  echo "VCS executable not found: $VCS_HOME/bin/vcs" >&2
  exit 4
fi

missing_host_mem_sources=()
for source_file in src/host_mem_pkg.sv src/host_mem_manager.sv; do
  if [[ ! -f "$root_dir/virtio_net_vip/ext/host_mem/$source_file" ]]; then
    missing_host_mem_sources+=("$source_file")
  fi
done

if (( ${#missing_host_mem_sources[@]} > 0 )); then
  echo "pinned host_mem dependency ef056b331047f51125c2aaf248a8767b9b84862a is missing: ${missing_host_mem_sources[*]}" >&2
  echo "fix: upstream must provide compatible sources, or obtain user approval to update the pinned SHA" >&2
  exit 6
fi
