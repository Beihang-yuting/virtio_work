#!/usr/bin/env bash
set -euo pipefail

# Contract test for the external pcie_work boundary.  This test is deliberately
# structural: it can run without VCS and verifies that the repository cannot
# silently fall back to the historical PCIe submodule.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
local_pcie_path='virtio_net_vip/ext/'
local_pcie_path+='pcie_tl_vip'
local_extension_guard='virtio_net_vip/ext/'
local_extension_guard+='pcie_tl_vip'

if [[ -e "$repo_root/.gitmodules" ]] && grep -q 'pcie_tl_vip' "$repo_root/.gitmodules"; then
  echo "pcie_tl_vip must not remain a repository submodule" >&2
  exit 1
fi

if [[ -e "$repo_root/$local_pcie_path" ]]; then
  echo "local PCIe extension directory must not remain" >&2
  exit 1
fi
if [[ -e "$repo_root/.git" ]] &&
   git -C "$repo_root" ls-files --stage -- "$local_pcie_path" | grep -q .; then
  echo "pcie_tl_vip gitlink must not remain in the index" >&2
  exit 1
fi

if ! grep -Fq '+incdir+$PCIE_WORK_ROOT/pcie_tl_vip/src' \
    "$repo_root/filelists/virtio_net.f"; then
  echo "virtio filelist does not consume PCIE_WORK_ROOT" >&2
  exit 1
fi
if grep -Fq "$local_pcie_path" "$repo_root/filelists/virtio_net.f"; then
  echo "virtio filelist still references the local PCIe extension" >&2
  exit 1
fi

for script in "$repo_root/scripts/check_deps.sh" "$repo_root/scripts/bootstrap.sh"; do
  if ! grep -Eq 'pcie_work_branch.*main|== "main"' "$script"; then
    echo "$(basename "$script") must require the external main branch" >&2
    exit 1
  fi
  if ! grep -Eq 'origin/main|pcie_work_upstream' "$script"; then
    echo "$(basename "$script") must require origin/main tracking" >&2
    exit 1
  fi
  if grep -q 'pcie_work_revision' "$script"; then
    echo "$(basename "$script") must not pin pcie_work to a SHA" >&2
    exit 1
  fi
  if ! grep -Fq "$local_extension_guard" "$script"; then
    echo "$(basename "$script") must reject a recreated local PCIe extension" >&2
    exit 1
  fi
  for source_file in \
      pcie_tl_vip/src/pcie_tl_if.sv \
      pcie_tl_vip/src/pcie_tl_pkg.sv \
      pcie_tl_vip/src/topology/pcie_topology_pkg.sv; do
    if ! grep -Fq "$source_file" "$script"; then
      echo "$(basename "$script") does not guard required source $source_file" >&2
      exit 1
    fi
  done
done

if grep -Fq 'pcie_work/pcie_tl_vip@' "$repo_root/README.md"; then
  echo "README still documents a pinned pcie_work revision" >&2
  exit 1
fi
if grep -Fq 'pcie_work@' "$repo_root/docs/virtio_net_vip_manual.md"; then
  echo "manual still documents a pinned pcie_work revision" >&2
  exit 1
fi

echo "external pcie_work contract tests PASSED"
