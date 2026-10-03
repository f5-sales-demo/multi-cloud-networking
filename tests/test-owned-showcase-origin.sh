#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'module "showcase_origin"' "$repo/terraform/azure_origin.tf"
grep -Eq 'ip[[:space:]]*=[[:space:]]*local.selected_origin_ip' "$repo/terraform/main.tf"
grep -Eq 'value[[:space:]]*=[[:space:]]*local.selected_origin_ip' "$repo/terraform/outputs.tf"
grep -q 'var.serve_http' "$repo/terraform/modules/client-vm/main.tf"
grep -q 'mcn-showcase-origin' "$repo/terraform/azure_origin.tf"
grep -Eq 'private_ip[[:space:]]*=[[:space:]]*cidrhost\(var.mgmt_subnet_prefix, 30\)' "$repo/terraform/azure_origin.tf"
echo 'PASS: retained US origin remains owned and selected'
