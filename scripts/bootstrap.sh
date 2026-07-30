#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"

git -C "$root_dir" submodule sync --recursive
git -C "$root_dir" submodule update --init --recursive
git -C "$root_dir" submodule status --recursive
