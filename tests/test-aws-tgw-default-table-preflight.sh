#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
preflight="$repo_root/scripts/aws-smsv2-owned-collision-preflight.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin"

cat >"$scratch/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"sts get-caller-identity"*) printf '%s\n' '{"Account":"123456789012","Arn":"arn:aws:sts::123456789012:assumed-role/test/session","UserId":"TESTUSER:session"}' ;;
  *"describe-transit-gateways"*) printf '%s\n' '{"TransitGateways":[]}' ;;
  *"describe-transit-gateway-attachments"*) printf '%s\n' '{"TransitGatewayAttachments":[]}' ;;
  *) printf 'unexpected AWS lookup: %s\n' "$*" >&2; exit 64 ;;
esac
AWS
chmod +x "$scratch/bin/aws"

cat >"$scratch/valid.json" <<'JSON'
{
  "resource_changes": [
    {"address":"module.aws_tgw_connect[0].aws_ec2_transit_gateway.this","type":"aws_ec2_transit_gateway",
     "change":{"actions":["create"],"after":{"default_route_table_association":"enable",
       "tags":{"Name":"mcn-ce-ha-gen-01-tgw","component":"mcn-ce-ha","deployment_generation":"gen-01","deployer":"tester","managed_by":"terraform"}}}},
    {"address":"aws_ec2_transit_gateway_vpc_attachment.workload[0]","type":"aws_ec2_transit_gateway_vpc_attachment",
     "change":{"actions":["create"],"after":{"tags":{"Name":"mcn-ce-ha-gen-01-workload","component":"mcn-ce-ha","deployment_generation":"gen-01","deployer":"tester","managed_by":"terraform"}}}},
    {"address":"module.aws_tgw_connect[0].aws_ec2_transit_gateway_vpc_attachment.transport","type":"aws_ec2_transit_gateway_vpc_attachment",
     "change":{"actions":["create"],"after":{"tags":{"Name":"mcn-ce-ha-gen-01-transport","component":"mcn-ce-ha","deployment_generation":"gen-01","deployer":"tester","managed_by":"terraform"}}}},
    {"address":"module.aws_tgw_connect[0].aws_ec2_transit_gateway_connect.role[\"slo\"]","type":"aws_ec2_transit_gateway_connect",
     "change":{"actions":["create"],"after":{"tags":{"Name":"mcn-ce-ha-gen-01-connect","component":"mcn-ce-ha","deployment_generation":"gen-01","deployer":"tester","managed_by":"terraform"}}}},
    {"address":"aws_ec2_transit_gateway_route_table_propagation.workload[0]","type":"aws_ec2_transit_gateway_route_table_propagation",
     "change":{"actions":["create"],"after":{}}},
    {"address":"module.aws_tgw_connect[0].aws_ec2_transit_gateway_route_table_propagation.transport","type":"aws_ec2_transit_gateway_route_table_propagation",
     "change":{"actions":["create"],"after":{}}},
    {"address":"module.aws_tgw_connect[0].aws_ec2_transit_gateway_route_table_propagation.connect[\"slo\"]","type":"aws_ec2_transit_gateway_route_table_propagation",
     "change":{"actions":["create"],"after":{}}}
  ],
  "configuration":{"root_module":{
    "resources":[{"address":"aws_ec2_transit_gateway_route_table_propagation.workload",
      "expressions":{
        "transit_gateway_attachment_id":{"references":["aws_ec2_transit_gateway_vpc_attachment.workload[0].id"]},
        "transit_gateway_route_table_id":{"references":["module.aws_tgw_connect[0].route_table_id"]}}}],
    "module_calls":{"aws_tgw_connect":{"module":{
      "outputs":{"route_table_id":{"expression":{"references":["aws_ec2_transit_gateway.this.association_default_route_table_id"]}}},
      "resources":[
        {"address":"aws_ec2_transit_gateway_route_table_propagation.transport",
         "expressions":{"transit_gateway_attachment_id":{"references":["aws_ec2_transit_gateway_vpc_attachment.transport.id"]},
           "transit_gateway_route_table_id":{"references":["aws_ec2_transit_gateway.this.association_default_route_table_id"]}}},
        {"address":"aws_ec2_transit_gateway_route_table_propagation.connect",
         "expressions":{"transit_gateway_attachment_id":{"references":["each.value.id"]},
           "transit_gateway_route_table_id":{"references":["aws_ec2_transit_gateway.this.association_default_route_table_id"]}}}
      ]}}}
  }}
}
JSON
jq '
  .resource_changes[0].change.after.tags += {
    mcn_repository:"multi-cloud-networking",
    mcn_environment:"production",
    mcn_source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    mcn_source_ref_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    mcn_owner_id:"showcase-team",
    mcn_actor_id:"terraform-cli"
  } |
  .planned_values.outputs.deployment_provenance.value = {
    repository:"f5-sales-demo/multi-cloud-networking",
    environment_key:"production",
    source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    source_ref_sha256:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    owner_id:"showcase-team",
    actor_id:"terraform-cli"
  } |
  .variables = {
    source_commit_sha:{value:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},
    deployment_owner_id:{value:"showcase-team"}
  }
' "$scratch/valid.json" >"$scratch/valid-with-provenance.json"
mv "$scratch/valid-with-provenance.json" "$scratch/valid.json"

run_plan() {
  local plan=$1 manifest=$2
  PATH="$scratch/bin:$PATH" XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
    "$preflight" --plan-json "$plan" --aws-region ap-northeast-1 --aws-account-id 123456789012 \
    --xc-tenant f5-sales-demo --creator-id tester@example.test --component mcn-ce-ha \
    --deployment-generation gen-01 --manifest "$manifest"
}

run_plan "$scratch/valid.json" "$scratch/valid-manifest.json" >/dev/null ||
  {
    printf 'valid owned TGW default-table propagation was rejected\n' >&2
    exit 1
  }
jq -e '.status == "ready" and .collisions == []' "$scratch/valid-manifest.json" >/dev/null

reject_plan() {
  local label=$1 filter=$2 expected=$3
  jq "$filter" "$scratch/valid.json" >"$scratch/$label.json"
  local output
  if output=$(run_plan "$scratch/$label.json" "$scratch/$label-manifest.json" 2>&1); then
    printf 'invalid %s plan was accepted\n' "$label" >&2
    exit 1
  fi
  [[ $output == *"$expected"* ]] || {
    printf 'wrong %s rejection: %s\n' "$label" "$output" >&2
    exit 1
  }
  [[ ! -e "$scratch/$label-manifest.json" ]] || {
    printf '%s wrote a manifest\n' "$label" >&2
    exit 1
  }
}

reject_plan missing-tgw 'del(.resource_changes[0])' 'collision-checked route table'
reject_plan disabled-default '.resource_changes[0].change.after.default_route_table_association = "disable"' 'collision-checked route table'
reject_plan unowned-tgw '.resource_changes[0].change.after.tags.component = "someone-else"' 'collision-checked route table'
reject_plan unrelated-commit '.resource_changes[0].change.after.tags.mcn_source_commit = "cccccccccccccccccccccccccccccccccccccccc"' 'collision-checked route table'
reject_plan unrelated-output '.configuration.root_module.module_calls.aws_tgw_connect.module.outputs.route_table_id.expression.references[0] = "aws_ec2_transit_gateway.unrelated.association_default_route_table_id"' 'collision-checked route table'
reject_plan unrelated-module '.configuration.root_module.module_calls.aws_tgw_connect.module.resources[1].expressions.transit_gateway_route_table_id.references[0] = "aws_ec2_transit_gateway.unrelated.association_default_route_table_id"' 'collision-checked route table'

printf '%s\n' 'PASS: TGW default-table propagation is bound to the owned TGW'
