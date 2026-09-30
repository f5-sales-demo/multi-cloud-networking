#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
for file in terraform/kvm.tf terraform/modules/kvm/kvm.tf; do
  grep -q 'kvm_image_cache_dir = "/data/multi-cloud-networking/cache/kvm"' "$repo/$file"
  grep -q 'target { path = "/data/multi-cloud-networking/libvirt/${local.kvm_pool_name}" }' "$repo/$file"
done
echo 'PASS: owned KVM storage and immutable image cache use data filesystem'
