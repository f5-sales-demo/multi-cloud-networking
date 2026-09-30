#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'name.*=.*"http-to-demo-vip"' "$repo/terraform/modules/azure-frr/main.tf"
grep -q 'destination_address_prefix.*=.*var.vip' "$repo/terraform/modules/azure-frr/main.tf"
grep -q 'destination_port_range.*=.*"80"' "$repo/terraform/modules/azure-frr/main.tf"
echo 'PASS: relay HTTP transit is scoped to the demo VIP'
