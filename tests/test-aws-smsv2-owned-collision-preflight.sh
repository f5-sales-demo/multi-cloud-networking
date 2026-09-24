#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="$repo_root/scripts/aws-smsv2-owned-collision-preflight.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
plan="$scratch/plan.json"
manifest="$scratch/manifest.json"
fake_bin="$scratch/bin"
mkdir -p "$fake_bin"

cat >"$plan" <<'JSON'
{
  "resource_changes": [
    {
      "address": "aws_key_pair.ce[0]",
      "type": "aws_key_pair",
      "change": {
        "actions": ["create"],
        "after": {
          "key_name": "mcn-ce-ha-gen-01-key",
          "tags": {
            "component": "mcn-ce-ha",
            "deployment_generation": "gen-01",
            "deployer": "tester",
            "managed_by": "terraform"
          }
        }
      }
    },
    {
      "address": "aws_eip.ce[0]",
      "type": "aws_eip",
      "change": {
        "actions": ["create"],
        "after": {
          "tags": {
            "component": "mcn-ce-ha",
            "deployment_generation": "gen-01",
            "deployer": "tester",
            "managed_by": "terraform"
          }
        }
      }
    },
    {
      "address": "aws_ec2_transit_gateway_connect_peer.aws[\"01-sli\"]",
      "type": "aws_ec2_transit_gateway_connect_peer",
      "change": {
        "actions": ["create"],
        "after": {
          "bgp_asn": "64512",
          "inside_cidr_blocks": ["169.254.0.0/29"],
          "peer_address": "10.0.0.10",
          "transit_gateway_address": "10.0.0.1",
          "transit_gateway_attachment_id": "tgw-attach-0123456789abcdef0",
          "tags": {
            "Name": "mcn-ce-ha-gen-01-aws-tgw-peer-01-sli",
            "component": "mcn-ce-ha",
            "deployment_generation": "gen-01",
            "deployer": "tester",
            "managed_by": "terraform"
          }
        }
      }
    },
    {
      "address": "xcsh_virtual_site.aws[0]",
      "type": "xcsh_virtual_site",
      "change": {
        "actions": ["create"],
        "after": {
          "name": "mcn-ce-ha-gen-01-vsite",
          "namespace": "multi-cloud-networking",
          "labels": {"mcn-deployment-generation": "gen-01"}
        }
      }
    },
    {
      "address": "xcsh_securemesh_site_v2.aws[\"01\"]",
      "type": "xcsh_securemesh_site_v2",
      "change": {
        "actions": ["create"],
        "after": {
          "name": "mcn-ce-ha-gen-01-site",
          "namespace": "system",
          "labels": {"mcn-deployment-generation": "gen-01"}
        }
      }
    },
    {
      "address": "xcsh_bgp.aws_tgw[\"01\"]",
      "type": "xcsh_bgp",
      "change": {
        "actions": ["create"],
        "after": {
          "name": "mcn-ce-ha-gen-01-bgp",
          "namespace": "system",
          "labels": {"mcn-deployment-generation": "gen-01"}
        }
      }
    },
    {
      "address": "xcsh_external_connector.aws_tgw[\"node_01_slo\"]",
      "type": "xcsh_external_connector",
      "change": {
        "actions": ["create"],
        "after": {
          "name": "mcn-ce-ha-gen-01-connector",
          "namespace": "system",
          "labels": {"mcn-deployment-generation": "gen-01"}
        }
      }
    }
  ]
}
JSON

cat >"$fake_bin/aws" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *"sts get-caller-identity"*)
    printf '{"Account":"%s","Arn":"arn:aws:sts::123456789012:assumed-role/test/session","UserId":"TESTUSER:session"}\n' "${FAKE_ACCOUNT_ID:-123456789012}"
    ;;
  *"describe-key-pairs"*"mcn-ce-ha-gen-01-key"*)
    if [[ ${FAKE_ABSENT:-false} == true ]]; then
      printf '%s\n' 'InvalidKeyPair.NotFound' >&2
      exit 255
    fi
    generation=${FAKE_AWS_GENERATION:-gen-01}
    printf '{"KeyPairs":[{"KeyPairId":"key-0123456789abcdef0","CreateTime":"2026-09-16T12:00:00Z","Tags":[{"Key":"component","Value":"mcn-ce-ha"},{"Key":"deployment_generation","Value":"%s"},{"Key":"deployer","Value":"tester"},{"Key":"managed_by","Value":"terraform"}]}]}\n' "$generation"
    ;;
  *"describe-addresses"*)
    if [[ ${FAKE_ABSENT:-false} == true ]]; then
      printf '{"Addresses":[]}\n'
      exit 0
    fi
    generation=${FAKE_EIP_GENERATION:-gen-01}
    printf '{"Addresses":[{"AllocationId":"eipalloc-0123456789abcdef0","Tags":[{"Key":"component","Value":"mcn-ce-ha"},{"Key":"deployment_generation","Value":"%s"},{"Key":"deployer","Value":"tester"},{"Key":"managed_by","Value":"terraform"}]}]}\n' "$generation"
    ;;
  *"describe-transit-gateway-connect-peers"*)
    if [[ ${FAKE_ABSENT:-false} == true ]]; then
      printf '{"TransitGatewayConnectPeers":[]}\n'
      exit 0
    fi
    generation=${FAKE_AWS_GENERATION:-gen-01}
    printf '{"TransitGatewayConnectPeers":[{"TransitGatewayConnectPeerId":"tgw-connect-peer-0123456789abcdef0","BgpAsn":"64512","InsideCidrBlocks":["169.254.0.0/29"],"PeerAddress":"10.0.0.10","TransitGatewayAddress":"10.0.0.1","TransitGatewayAttachmentId":"tgw-attach-0123456789abcdef0","Tags":[{"Key":"Name","Value":"mcn-ce-ha-gen-01-aws-tgw-peer-01-sli"},{"Key":"component","Value":"mcn-ce-ha"},{"Key":"deployment_generation","Value":"%s"},{"Key":"deployer","Value":"tester"},{"Key":"managed_by","Value":"terraform"}]}]}\n' "$generation"
    ;;
  *)
    printf '%s\n' 'unexpected aws command' >&2
    exit 64
    ;;
esac
EOF
chmod +x "$fake_bin/aws"

cat >"$fake_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
output=""
while (($#)); do
  case "$1" in
    --output) output=$2; shift 2 ;;
    *) url=$1; shift ;;
  esac
done
case "$url" in
  */virtual_sites/mcn-ce-ha-gen-01-vsite)
    if [[ ${FAKE_ABSENT:-false} == true ]]; then
      : >"$output"
      printf 404
      exit 0
    fi
    generation=${FAKE_F5_GENERATION:-gen-01}
    printf '{"metadata":{"name":"mcn-ce-ha-gen-01-vsite","namespace":"multi-cloud-networking","labels":{"mcn-deployment-generation":"%s"}},"system_metadata":{"uid":"11111111-1111-1111-1111-111111111111","creation_timestamp":"2026-09-16T12:00:00Z","creator_id":"tester@example.test"}}\n' "$generation" >"$output"
    printf 200
    ;;
  */securemesh_site_v2s/mcn-ce-ha-gen-01-site | */bgps/mcn-ce-ha-gen-01-bgp | */external_connectors/mcn-ce-ha-gen-01-connector)
    if [[ ${FAKE_ABSENT:-false} == true ]]; then
      : >"$output"
      printf 404
      exit 0
    fi
    name=${url##*/}
    generation=${FAKE_F5_GENERATION:-gen-01}
    printf '{"metadata":{"name":"%s","namespace":"system","labels":{"mcn-deployment-generation":"%s"}},"system_metadata":{"uid":"22222222-2222-2222-2222-222222222222","creation_timestamp":"2026-09-16T12:00:00Z","creator_id":"tester@example.test"}}\n' "$name" "$generation" >"$output"
    printf 200
    ;;
  *)
    : >"$output"
    printf 404
    ;;
esac
EOF
chmod +x "$fake_bin/curl"

set +e
output=$(PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 \
  --component mcn-ce-ha \
  --creator-id tester@example.test --manifest "$manifest" 2>&1)
status=$?
set -e
test "$status" -eq 3 || fail "owned collision must exit 3, got $status: $output"
[[ "$output" == *"owned collision"* ]] || fail "owned collision diagnostic missing"
jq -e '
  .schema_version == 2 and
  .status == "blocked" and
  .recovery_mode == "strict" and
  .aws_account_id == "123456789012" and
  .aws_caller_arn == "arn:aws:sts::123456789012:assumed-role/test/session" and
  .aws_caller_user_id == "TESTUSER:session" and
  (.inventory_captured_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")) and
  .deployment_generation == "gen-01" and
  (.collisions | length) == 7 and
  ([.collisions[].ownership] | all(. == "verified")) and
  ([.collisions[] | select(.engine == "f5") | .creator_id] | all(. == "tester@example.test")) and
  ([.collisions[] | select(.engine == "f5") | .created_at] | all(. == "2026-09-16T12:00:00Z")) and
  ([.collisions[] | select(.engine == "f5") | .creation_evidence] | all(. == "system_metadata.creation_timestamp")) and
  ([.collisions[] | select(.engine == "f5") | .resource_uid] | all(type == "string" and length > 0)) and
  ([.collisions[] | select(.engine == "aws") | .observed_tags.deployment_generation] | all(. == "gen-01")) and
  ([.collisions[] | select(.engine == "aws") | .resource_uid] | all(type == "string" and length > 0)) and
  ([.collisions[] | select(.engine == "aws" and .type != "aws_eip" and .type != "aws_ec2_transit_gateway_connect_peer") | .created_at] | all(. == "2026-09-16T12:00:00Z")) and
  ([.collisions[] | select(.type == "aws_eip") | .resource_uid] | all(. == "eipalloc-0123456789abcdef0")) and
  ([.collisions[] | select(.type == "aws_eip") | .creation_evidence] | all(. == "not_exposed_by_ec2_describe_addresses")) and
  ([.collisions[].generation_binding] | all(. == "observed_metadata")) and
  ([.collisions[] | select(.type == "aws_ec2_transit_gateway_connect_peer")] | length) == 1 and
  ([.collisions[] | select(.type == "aws_ec2_transit_gateway_connect_peer") | .resource_uid] | all(. == "tgw-connect-peer-0123456789abcdef0")) and
  ([.collisions[] | select(.type == "aws_ec2_transit_gateway_connect_peer") | .observed_config] | all(.inside_cidr_blocks == ["169.254.0.0/29"] and .peer_address == "10.0.0.10" and .transit_gateway_attachment_id == "tgw-attach-0123456789abcdef0")) and
  ([.collisions[].name] | sort) == ["mcn-ce-ha-gen-01-aws-tgw-peer-01-sli", "mcn-ce-ha-gen-01-bgp", "mcn-ce-ha-gen-01-connector", "mcn-ce-ha-gen-01-eip-aws_eip.ce[0]", "mcn-ce-ha-gen-01-key", "mcn-ce-ha-gen-01-site", "mcn-ce-ha-gen-01-vsite"]
' "$manifest" >/dev/null || fail "manifest must retain the exact verified collision inventory"

guard_plan="$scratch/guard-plan.json"
jq '
  .resource_changes += [{address:"terraform_data.deployment_identity_guard",type:"terraform_data",
    change:{actions:["create"],after:{input:"preview-owned"}}}] |
  .variables.source_commit_sha.value = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" |
  .variables.deployment_owner_id.value = "showcase-team" |
  .planned_values.outputs.deployment_provenance.value = {
    environment_key:"preview-owned",source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",owner_id:"showcase-team"
  }' "$plan" >"$guard_plan"
guard_manifest="$scratch/guard-manifest.json"
if ! FAKE_ABSENT=true PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$guard_plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 \
  --component mcn-ce-ha --creator-id tester@example.test --manifest "$guard_manifest" >/dev/null; then
  fail "an exact plan-bound deployment identity guard must be accepted"
fi
jq -e '.status == "ready" and .collisions == []' "$guard_manifest" >/dev/null ||
  fail "the exact identity guard must not masquerade as an external collision"

jq '.planned_values.outputs.deployment_provenance.value.environment_key = "wrong-preview"' \
  "$guard_plan" >"$scratch/guard-mismatch.json"
if FAKE_ABSENT=true PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$scratch/guard-mismatch.json" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 \
  --component mcn-ce-ha --creator-id tester@example.test --manifest "$scratch/guard-mismatch-manifest.json" >/dev/null 2>&1; then
  fail "a mismatched identity guard must be rejected"
fi

empty_manifest="$scratch/empty-manifest.json"
if ! FAKE_ABSENT=true PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 \
  --component mcn-ce-ha \
  --creator-id tester@example.test --manifest "$empty_manifest" >/dev/null; then
  fail "an absent planned name must pass the collision preflight"
fi
jq -e '.status == "ready" and .collisions == []' "$empty_manifest" >/dev/null ||
  fail "no-collision manifest must be explicitly ready and empty"

replacement_plan="$scratch/replacement-plan.json"
jq '(.resource_changes[] | select(.type == "xcsh_securemesh_site_v2")).change.actions = ["delete", "create"] |
    (.resource_changes[] | select(.type == "xcsh_securemesh_site_v2")).change.replace_paths = [["aws"]]' \
  "$plan" >"$replacement_plan"
replacement_manifest="$scratch/replacement-manifest.json"
set +e
replacement_output=$(FAKE_ABSENT=true PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$replacement_plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 --component mcn-ce-ha \
  --creator-id tester@example.test --manifest "$replacement_manifest" 2>&1)
replacement_status=$?
set -e
test "$replacement_status" -eq 2 || fail "securemesh replacement must fail closed with exit 2, got $replacement_status"
[[ "$replacement_output" == *"SecureMesh site replacement is prohibited before mutation"* ]] ||
  fail "securemesh replacement diagnostic is missing"
[[ "$replacement_output" == *'"replace_paths":[["aws"]]'* ]] ||
  fail "securemesh replacement diagnostic must include replacement paths"
[[ ! -e "$replacement_manifest" ]] || fail "securemesh replacement must not produce an ownership manifest"

expect_rejection() {
  local label=$1 expected=$2
  shift 2
  local rejected_output rejected_status
  set +e
  rejected_output=$(env "$@" PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
    XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
    "$script" --plan-json "$plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
    --aws-account-id 123456789012 --deployment-generation gen-01 \
    --component mcn-ce-ha \
    --creator-id tester@example.test --manifest "$scratch/rejected-$label.json" 2>&1)
  rejected_status=$?
  set -e
  test "$rejected_status" -eq 2 || fail "$label must fail closed with exit 2, got $rejected_status"
  [[ "$rejected_output" == *"$expected"* ]] || fail "$label diagnostic is not actionable: $rejected_output"
  [[ ! -e "$scratch/rejected-$label.json" ]] || fail "$label must not produce an ownership manifest"
}

expect_rejection account-mismatch "caller account does not match" FAKE_ACCOUNT_ID=999999999999
expect_rejection aws-generation-mismatch "unowned or ambiguous AWS collision" FAKE_AWS_GENERATION=gen-02
expect_rejection eip-generation-mismatch "unowned or ambiguous AWS collision" FAKE_EIP_GENERATION=gen-02
expect_rejection f5-generation-mismatch "unowned or ambiguous F5 collision" FAKE_F5_GENERATION=gen-02

set +e
invalid_output=$(PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation INVALID \
  --component mcn-ce-ha \
  --creator-id tester@example.test --manifest "$scratch/invalid-generation.json" 2>&1)
invalid_status=$?
set -e
test "$invalid_status" -eq 2 || fail "invalid generation must fail closed with exit 2"
[[ "$invalid_output" == *"deployment generation"* ]] || fail "invalid generation diagnostic is missing"

legacy_plan="$scratch/legacy-plan.json"
jq '(.resource_changes[].change.after.tags? // {}) |= del(.deployment_generation) |
    (.resource_changes[].change.after.labels? // {}) |= del(."mcn-deployment-generation")' \
  "$plan" >"$legacy_plan"
legacy_manifest="$scratch/legacy-manifest.json"
set +e
legacy_output=$(PATH="$fake_bin:$PATH" CURL_BIN="$fake_bin/curl" \
  XCSH_API_URL=https://f5-sales-demo.console.ves.volterra.io XCSH_API_TOKEN=test-token \
  "$script" --plan-json "$legacy_plan" --aws-region ap-northeast-1 --xc-tenant f5-sales-demo \
  --aws-account-id 123456789012 --deployment-generation gen-01 --component mcn-ce-ha \
  --legacy-unlabelled-recovery --creator-id tester@example.test --manifest "$legacy_manifest" 2>&1)
legacy_status=$?
set -e
test "$legacy_status" -eq 3 || fail "legacy recovery collision must exit 3, got $legacy_status: $legacy_output"
jq -e '.schema_version == 2 and .recovery_mode == "legacy_unlabelled" and
  ([.collisions[].generation_binding] | all(. == "saved_plan_name_and_legacy_ownership"))' \
  "$legacy_manifest" >/dev/null || fail "legacy manifest must disclose its generation evidence boundary"

for required in \
  'aws_iam_role_policy_attachment' \
  'iam list-attached-role-policies' \
  'planned inline policy role reference is unavailable' \
  'aws_instance' \
  'multiple instances match the planned ownership tags'; do
  grep -Fq "$required" "$script" || fail "collision gate lost required coverage: $required"
done

printf 'PASS: owned AWS and F5 name collisions are rejected before Terraform apply with a verified manifest\n'
