#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
file="$repo/terraform/modules/azure-hub/main.tf"
grep -q 'bgp_route_propagation_enabled.*=.*false' "$file"
grep -q 'subnet_id.*=.*azurerm_subnet.management.id' "$file"
if grep -q 'subnet_id.*=.*azurerm_subnet.internal.id' "$file"; then exit 1; fi
echo 'PASS: relay propagation isolated while client route propagation remains'
