#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
recovery_root="$repo_root/terraform/recovery/aws-smsv2-orphans"
verifier="$repo_root/scripts/verify-aws-smsv2-orphan-recovery-plan.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

for required in versions.tf backend.tf providers.tf variables.tf locals.tf resources.tf imports.tf; do
  [[ -f "$recovery_root/$required" ]] || fail "recovery root is missing $required"
done
[[ -x "$verifier" ]] || fail "recovery plan verifier is not executable"

resource_count=$(grep -hEc '^resource "' "$recovery_root"/*.tf | awk '{ count += $1 } END { print count + 0 }')
import_count=$(grep -hEc '^import \{' "$recovery_root"/*.tf | awk '{ count += $1 } END { print count + 0 }')
ignore_count=$(grep -hEc '^[[:space:]]*ignore_changes[[:space:]]*=[[:space:]]*all$' "$recovery_root"/*.tf | awk '{ count += $1 } END { print count + 0 }')
data_lb_count=$(grep -hEc '^data "aws_lb" "recovery"' "$recovery_root"/*.tf | awk '{ count += $1 } END { print count + 0 }')
data_target_group_count=$(grep -hEc '^data "aws_lb_target_group" "recovery"' "$recovery_root"/*.tf | awk '{ count += $1 } END { print count + 0 }')
[[ $resource_count -eq 15 ]] || fail "recovery root must declare exactly fifteen supported resource types"
[[ $import_count -eq 15 ]] || fail "recovery root must declare exactly fifteen configuration-driven import blocks"
[[ $ignore_count -eq 15 ]] || fail "every recovery resource must ignore drift during adoption"
grep -Eq 'aws_eip' "$recovery_root/imports.tf" || fail "recovery must import verified legacy EIPs"
grep -Eq 'aws_eip' "$recovery_root/resources.tf" || fail "recovery must configure verified legacy EIPs"
[[ $data_lb_count -eq 1 ]] || fail "recovery must read the existing load-balancer shape for an import-only plan"
grep -Eq 'aws_instance' "$recovery_root/imports.tf" || fail "recovery must import EIP-owning instances"
grep -Eq 'aws_instance' "$recovery_root/resources.tf" || fail "recovery must configure EIP-owning instances"
grep -Eq 'attached_eip_dependency_closure' "$recovery_root/locals.tf" ||
  fail "recovery must reject an attached EIP without its owning instance"
grep -Eq 'depends_on[[:space:]]*=[[:space:]]*\[aws_eip\.recovery\]' "$recovery_root/resources.tf" ||
  fail "recovery destroy ordering must terminate instances before EIP release"
[[ $data_target_group_count -eq 1 ]] || fail "recovery must read the existing target-group shape for an import-only plan"
grep -Eq 'subnets[[:space:]]*=[[:space:]]*data\.aws_lb\.recovery' "$recovery_root/resources.tf" ||
  fail "recovery load balancer must use its observed subnets"
grep -Eq 'vpc_id[[:space:]]*=[[:space:]]*data\.aws_lb_target_group\.recovery' "$recovery_root/resources.tf" ||
  fail "recovery target group must use its observed VPC"
grep -Eq 'discovered_site_labels' "$recovery_root/locals.tf" ||
  fail "recovery must identify F5-discovered site labels"
grep -Eq '!contains\(local\.discovered_site_labels, key\)' "$recovery_root/resources.tf" ||
  fail "recovery must exclude F5-discovered labels from securemesh configuration"
grep -Eq 'xcsh_external_connector' "$recovery_root/imports.tf" ||
  fail "recovery must import verified external connectors"
grep -Eq 'xcsh_external_connector' "$recovery_root/resources.tf" ||
  fail "recovery must configure verified external connectors"
grep -Eq 'xcsh_bgp' "$recovery_root/imports.tf" ||
  fail "recovery must import verified BGP objects"
grep -Eq 'xcsh_bgp' "$recovery_root/resources.tf" ||
  fail "recovery must configure verified BGP objects"
grep -Eq 'xcsh_external_connector\.recovery' "$recovery_root/resources.tf" ||
  fail "recovery destroy ordering must terminate BGP before external connectors"
grep -Eq 'aws_ec2_transit_gateway_connect_peer' "$recovery_root/imports.tf" ||
  fail "recovery must import manifest-bound Transit Gateway Connect peers"
grep -Eq 'aws_ec2_transit_gateway_connect_peer' "$recovery_root/resources.tf" ||
  fail "recovery must configure observed Transit Gateway Connect peer shape"
grep -Eq 'connect_peer_observed_shape' "$recovery_root/locals.tf" ||
  fail "recovery must reject Connect peers without observed immutable shape"
if grep -R --exclude-dir=.terraform -En 'terraform[[:space:]]+import|local-exec|curl.+DELETE|aws.+delete-' "$recovery_root" "$verifier"; then
  fail "recovery implementation contains an imperative mutation path"
fi

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
manifest="$scratch/manifest.json"
plan="$scratch/plan.json"
receipt="$scratch/receipt.json"
provider_source='registry.terraform.io/f5-sales-demo/xcsh'

jq -n '{
  schema_version:2,status:"blocked",recovery_mode:"legacy_unlabelled",
  plan_sha256:"sha256:source-plan",aws_account_id:"123456789012",aws_region:"us-east-1",
  xc_tenant:"f5-sales-demo",creator_id:"tester@example.com",component:"mcn-ce-ha",
  deployment_generation:"gen-01",inventory_captured_at:"2026-09-16T12:00:00Z",
  collisions:[
    {engine:"aws",type:"aws_key_pair",address:"aws_key_pair.ce[0]",name:"mcn-ce-ha-gen-01-key",
     namespace:null,ownership:"verified",resource_uid:"key-0123456789abcdef0",
     created_at:"2026-09-16T12:00:00Z",creation_evidence:"ec2.describe-key-pairs.CreateTime",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_tags:{component:"mcn-ce-ha"}},
    {engine:"aws",type:"aws_eip",address:"aws_eip.ce[0]",name:"mcn-ce-ha-aws-ce-1-eip",
     namespace:null,ownership:"verified",resource_uid:"eipalloc-0123456789abcdef0",
     created_at:"2026-09-16T12:00:00Z",creation_evidence:"ec2.describe-addresses.AllocationId",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_tags:{component:"mcn-ce-ha",managed_by:"terraform"}},
    {engine:"aws",type:"aws_ec2_transit_gateway_connect_peer",address:"aws_ec2_transit_gateway_connect_peer.aws[\"01-sli\"]",name:"mcn-ce-ha-gen-01-aws-tgw-peer-01-sli",
     namespace:null,ownership:"verified",resource_uid:"tgw-connect-peer-0123456789abcdef0",
     created_at:null,creation_evidence:"ec2.describe-transit-gateway-connect-peers.TransitGatewayConnectPeerId",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_tags:{component:"mcn-ce-ha",managed_by:"terraform"},
     observed_config:{inside_cidr_blocks:["169.254.0.0/29"],peer_address:"10.0.0.10",transit_gateway_attachment_id:"tgw-attach-0123456789abcdef0",bgp_asn:"64512",transit_gateway_address:"10.0.0.1"}},
    {engine:"f5",type:"xcsh_token",address:"xcsh_token.aws[\"01\"]",name:"mcn-ce-ha-gen-01-token",
     namespace:"system",ownership:"verified",resource_uid:"11111111-1111-1111-1111-111111111111",
     created_at:"2026-09-16T12:00:00Z",creation_evidence:"system_metadata.creation_timestamp",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_labels:{}},
    {engine:"f5",type:"xcsh_external_connector",address:"xcsh_external_connector.aws_tgw[\"01-sli\"]",name:"mcn-ce-ha-gen-01-sli-connector",
     namespace:"system",ownership:"verified",resource_uid:"22222222-2222-2222-2222-222222222222",
     created_at:"2026-09-16T12:00:00Z",creation_evidence:"system_metadata.creation_timestamp",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_labels:{}},
    {engine:"f5",type:"xcsh_bgp",address:"xcsh_bgp.aws_tgw[\"01\"]",name:"mcn-ce-ha-gen-01-bgp",
     namespace:"system",ownership:"verified",resource_uid:"33333333-3333-3333-3333-333333333333",
     created_at:"2026-09-16T12:00:00Z",creation_evidence:"system_metadata.creation_timestamp",
     generation_binding:"saved_plan_name_and_legacy_ownership",observed_labels:{}}
  ]
}' >"$manifest"

jq --arg provider_source "$provider_source" -n '{format_version:"1.2",terraform_version:"1.16.3",
  configuration:{provider_config:{xcsh:{full_name:$provider_source,version_constraint:"10.1.0"}}},
  resource_changes:[
  {address:"aws_key_pair.recovery[\"aws_key_pair.ce[0]\"]",type:"aws_key_pair",
   change:{actions:["no-op"],importing:{id:"mcn-ce-ha-gen-01-key"}}},
  {address:"aws_eip.recovery[\"aws_eip.ce[0]\"]",type:"aws_eip",
   change:{actions:["no-op"],importing:{id:"eipalloc-0123456789abcdef0"}}},
  {address:"aws_ec2_transit_gateway_connect_peer.recovery[\"aws_ec2_transit_gateway_connect_peer.aws[\\\"01-sli\\\"]\"]",type:"aws_ec2_transit_gateway_connect_peer",
   change:{actions:["no-op"],importing:{id:"tgw-connect-peer-0123456789abcdef0"}}},
  {address:"xcsh_token.recovery[\"xcsh_token.aws[\\\"01\\\"]\"]",type:"xcsh_token",
   change:{actions:["no-op"],importing:{id:"system/mcn-ce-ha-gen-01-token"}}},
  {address:"xcsh_external_connector.recovery[\"xcsh_external_connector.aws_tgw[\\\"01-sli\\\"]\"]",type:"xcsh_external_connector",
   change:{actions:["no-op"],importing:{id:"system/mcn-ce-ha-gen-01-sli-connector"}}},
  {address:"xcsh_bgp.recovery[\"xcsh_bgp.aws_tgw[\\\"01\\\"]\"]",type:"xcsh_bgp",
   change:{actions:["no-op"],importing:{id:"system/mcn-ce-ha-gen-01-bgp"}}}
]}' >"$plan"

"$verifier" --mode import --plan-json "$plan" --manifest "$manifest" --receipt "$receipt"
jq -e '.schema_version == 1 and .status == "ready" and .mode == "import" and .resource_count == 6 and
  (.plan_sha256 | startswith("sha256:")) and (.manifest_sha256 | startswith("sha256:"))' \
  "$receipt" >/dev/null || fail "recovery receipt does not bind the exact plan and manifest"

mutation_plan="$scratch/mutation-plan.json"
jq '(.resource_changes[0].change.actions) = ["create"] | del(.resource_changes[0].change.importing)' \
  "$plan" >"$mutation_plan"
if "$verifier" --mode import --plan-json "$mutation_plan" --manifest "$manifest" \
  --receipt "$scratch/mutation-receipt.json" >/dev/null 2>&1; then
  fail "recovery verifier accepted a create action"
fi

mismatch_plan="$scratch/mismatch-plan.json"
jq '(.resource_changes[1].change.importing.id) = "system/wrong-token"' "$plan" >"$mismatch_plan"
if "$verifier" --mode import --plan-json "$mismatch_plan" --manifest "$manifest" \
  --receipt "$scratch/mismatch-receipt.json" >/dev/null 2>&1; then
  fail "recovery verifier accepted an import ID mismatch"
fi

attached_eip_manifest="$scratch/attached-eip-without-instance.json"
jq '(.collisions[] | select(.type == "aws_eip")).attachment_instance_id = "i-0123456789abcdef0"' \
  "$manifest" >"$attached_eip_manifest"
if "$verifier" --mode import --plan-json "$plan" --manifest "$attached_eip_manifest" \
  --receipt "$scratch/attached-eip-receipt.json" >/dev/null 2>&1; then
  fail "recovery verifier accepted an attached EIP without its owning instance"
fi

missing_connect_peer_shape_manifest="$scratch/missing-connect-peer-shape.json"
jq 'del(.collisions[] | select(.type == "aws_ec2_transit_gateway_connect_peer").observed_config)' \
  "$manifest" >"$missing_connect_peer_shape_manifest"
if "$verifier" --mode import --plan-json "$plan" --manifest "$missing_connect_peer_shape_manifest" \
  --receipt "$scratch/missing-connect-peer-shape-receipt.json" >/dev/null 2>&1; then
  fail "recovery verifier accepted a Connect peer without observed immutable shape"
fi

destroy_plan="$scratch/destroy-plan.json"
destroy_receipt="$scratch/destroy-receipt.json"
jq --arg provider_source "$provider_source" -n '{format_version:"1.2",terraform_version:"1.16.3",
  configuration:{provider_config:{xcsh:{full_name:$provider_source,version_constraint:"10.1.0"}}},
  resource_changes:[
    {address:"aws_key_pair.recovery[\"aws_key_pair.ce[0]\"]",type:"aws_key_pair",
     change:{actions:["delete"],before:{id:"mcn-ce-ha-gen-01-key",key_name:"mcn-ce-ha-gen-01-key"},after:null}},
    {address:"aws_eip.recovery[\"aws_eip.ce[0]\"]",type:"aws_eip",
     change:{actions:["delete"],before:{id:"eipalloc-0123456789abcdef0",allocation_id:"eipalloc-0123456789abcdef0"},after:null}},
    {address:"aws_ec2_transit_gateway_connect_peer.recovery[\"aws_ec2_transit_gateway_connect_peer.aws[\\\"01-sli\\\"]\"]",type:"aws_ec2_transit_gateway_connect_peer",
     change:{actions:["delete"],before:{id:"tgw-connect-peer-0123456789abcdef0"},after:null}},
    {address:"xcsh_token.recovery[\"xcsh_token.aws[\\\"01\\\"]\"]",type:"xcsh_token",
     change:{actions:["delete"],before:{id:"mcn-ce-ha-gen-01-token",name:"mcn-ce-ha-gen-01-token"},after:null}},
    {address:"xcsh_external_connector.recovery[\"xcsh_external_connector.aws_tgw[\\\"01-sli\\\"]\"]",type:"xcsh_external_connector",
     change:{actions:["delete"],before:{id:"mcn-ce-ha-gen-01-sli-connector",name:"mcn-ce-ha-gen-01-sli-connector"},after:null}},
    {address:"xcsh_bgp.recovery[\"xcsh_bgp.aws_tgw[\\\"01\\\"]\"]",type:"xcsh_bgp",
     change:{actions:["delete"],before:{id:"mcn-ce-ha-gen-01-bgp",name:"mcn-ce-ha-gen-01-bgp"},after:null}}
  ]}' >"$destroy_plan"
"$verifier" --mode destroy --plan-json "$destroy_plan" --manifest "$manifest" \
  --receipt "$destroy_receipt"
jq -e '.status == "ready" and .mode == "destroy" and .resource_count == 6 and
  .allowed_actions == ["delete"]' "$destroy_receipt" >/dev/null ||
  fail "destroy receipt does not prove an exact manifest-bound deletion"

printf 'PASS: orphan recovery is configuration-driven, import-only and plan-bound\n'
