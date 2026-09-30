#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
grep -q 'data "xcsh_network_regional_edges" "origin"' "$repo/terraform/azure_origin.tf"
grep -q 'data "xcsh_network_cdn" "origin"' "$repo/terraform/azure_origin.tf"
grep -q 'data.xcsh_network_regional_edges.origin\[0\].cidr_blocks' "$repo/terraform/azure_origin.tf"
grep -q 'data.xcsh_network_cdn.origin\[0\].cidr_blocks' "$repo/terraform/azure_origin.tf"
grep -q 'source_address_prefixes.*=.*var.http_source_cidrs' "$repo/terraform/modules/client-vm/main.tf"
grep -q 'name.*=.*"deny-other-origin-ingress"' "$repo/terraform/modules/client-vm/main.tf"
grep -q 'allow_ssh.*=.*false' "$repo/terraform/azure_origin.tf"
echo 'PASS: origin ACL consumes all F5 regions and denies unlisted ingress'
