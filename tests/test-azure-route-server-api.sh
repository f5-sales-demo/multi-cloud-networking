#!/usr/bin/env bash
# Each Route Server peer has an independent operation after its predecessor.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mcn-frr-graph.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cp "$repo/terraform/modules/azure-frr/"*.tf "$scratch/"
cp "$repo/terraform/modules/azure-frr/cloud-init.yaml.tftpl" "$scratch/"
terraform -chdir="$scratch" init -backend=false -input=false -no-color >/dev/null
graph=$(terraform -chdir="$scratch" graph)
grep -Fq '"azapi_resource.route_server_secondary" -> "azapi_resource.route_server_primary"' <<<"$graph"
printf 'PASS: Route Server BGP peer operations are ordered in Terraform\n'
