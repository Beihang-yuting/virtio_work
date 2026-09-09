#!/usr/bin/env bash
set -euo pipefail

# Contract test for the external net_packet boundary.  It intentionally uses
# repository metadata and maintained build inputs only; historical design
# notes are not part of the build contract.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
local_net_packet_path='virtio_net_vip/ext/'
local_net_packet_path+='net_packet'
local_extension_guard='root_dir/virtio_net_vip/ext/'
local_extension_guard+='net_packet'
old_revision_token='net_packet_'
old_revision_token+='revision'

if [[ -e "$repo_root/.gitmodules" ]] && grep -q 'net_packet' "$repo_root/.gitmodules"; then
  echo "net_packet must not remain a repository submodule" >&2
  exit 1
fi

if [[ -e "$repo_root/$local_net_packet_path" ]]; then
  echo "net_packet local extension directory must not remain" >&2
  exit 1
fi
if [[ -e "$repo_root/.git" ]] &&
   git -C "$repo_root" ls-files --stage -- "$local_net_packet_path" | grep -q .; then
  echo "net_packet gitlink must not remain in the index" >&2
  exit 1
fi

if ! grep -Fq '+incdir+$NET_PACKET_ROOT/src' "$repo_root/filelists/virtio_net.f"; then
  echo "virtio filelist does not consume NET_PACKET_ROOT" >&2
  exit 1
fi
if grep -Fq "$local_net_packet_path" "$repo_root/filelists/virtio_net.f"; then
  echo "virtio filelist still references the local net_packet extension" >&2
  exit 1
fi

for script in "$repo_root/scripts/check_deps.sh" "$repo_root/scripts/bootstrap.sh"; do
  if ! grep -Eq 'symbolic-ref --short( -q)? HEAD|branch --show-current' "$script" ||
     ! grep -Eq 'net_packet_branch.*master|== "master"' "$script"; then
    echo "$(basename "$script") must require the external master branch" >&2
    exit 1
  fi
  if grep -q "$old_revision_token" "$script"; then
    echo "$(basename "$script") must not pin net_packet to an old SHA" >&2
    exit 1
  fi
  if ! grep -Fq "$local_extension_guard" "$script"; then
    echo "$(basename "$script") must reject a recreated local net_packet extension" >&2
    exit 1
  fi
  for source_file in \
      src/core/packet.sv \
      src/uvm_wrapper/packet_item.sv \
      src/uvm_wrapper/packet_sequence.sv \
      src/uvm_wrapper/protocol_seq_wrapper.sv; do
    if ! grep -Fq "$source_file" "$script"; then
      echo "$(basename "$script") does not guard required net_packet source $source_file" >&2
      exit 1
    fi
  done
done

if grep -Fq 'host_mem、net_packet、pcie_work 均由环境变量' \
    "$repo_root/docs/virtio_net_vip_manual.md"; then
  echo "manual still documents net_packet as a historical local extension" >&2
  exit 1
fi

echo "external net_packet contract tests PASSED"
