#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/aws-smsv2-uat-preflight.sh"
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/mcn-preflight-test.XXXXXX")
INSIDE_EVIDENCE="${REPO_ROOT}/.preflight-evidence-test-$$"
trap 'rm -rf "$TMP_ROOT" "$INSIDE_EVIDENCE"' EXIT

BIN="${TMP_ROOT}/bin"
TF_DIR="${TMP_ROOT}/terraform"
PLAN_FILE="${TMP_ROOT}/deployment.tfplan"
TF_CALLS="${TMP_ROOT}/terraform-calls.log"
CANDIDATE_DIR="${TMP_ROOT}/candidate-provider"
CANDIDATE_BINARY="${CANDIDATE_DIR}/terraform-provider-xcsh"
mkdir -p "$BIN" "$TF_DIR" "$CANDIDATE_DIR"
: >"$PLAN_FILE"

cat >"$CANDIDATE_BINARY" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 755 "$CANDIDATE_BINARY"
CANDIDATE_SHA256="sha256:$(sha256sum "$CANDIDATE_BINARY" | awk '{print $1}')"

cat >"${BIN}/aws" <<'SH'
#!/usr/bin/env bash
case "$*" in
*"describe-vpcs"*) printf '{"Vpcs":[]}\n' ;;
*"describe-instances"*) printf '{"Reservations":[]}\n' ;;
*) printf '{"%s":"%s"}\n' 'Acc''ount' "${FAKE_AWS_ACCOUNT:-111122223333}" ;;
esac
SH

cat >"${BIN}/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
output=""
url=""
while (($#)); do
  case "$1" in
  --output) output=$2; shift 2 ;;
  --write-out) shift 2 ;;
  -H | --header | --connect-timeout | --max-time | --config) shift 2 ;;
  --silent | --show-error | -fsS) shift ;;
  *) url=$1; shift ;;
  esac
done
if [ -n "$output" ]; then
  if [ "${FAKE_F5_COLLISION:-false}" = true ] && [[ $url == */securemesh_site_v2s/* ]]; then
    name=${url##*/}
    printf '{"metadata":{"name":"%s","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}},"system_metadata":{"creator_id":"tester@example.com","creation_timestamp":"2026-09-16T12:00:00Z","uid":"site-0123456789abcdef"}}\n' "$name" >"$output"
    printf 200
  else
    : >"$output"
    printf 404
  fi
  exit 0
fi
status=${FAKE_XC_PROTOCOL_STATUS:-Established}
printf '{"ver":{"peers":[{"protocol_status":"%s"},{"protocol_status":"%s"},{"protocol_status":"%s"},{"protocol_status":"%s"}]}}\n' \
  "$status" "$status" "$status" "$status"
SH

cat >"${BIN}/terraform" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
chdir=${1#-chdir=}
shift
token_state=unset
[ -n "${XCSH_API_TOKEN:-}" ] && token_state=present
api_url_state=unset
[ -n "${XCSH_API_URL:-}" ] && api_url_state=present
printf '%s\t%s\t%s\t%s\n' "$1" "${TF_CLI_CONFIG_FILE:-unset}" "$token_state" "$api_url_state" >>"$FAKE_TF_CALLS"
case "$1" in
init)
  exit 0
  ;;
version)
  printf '{"provider_selections":{"registry.terraform.io/f5-sales-demo/xcsh":"9.5.1"}}\n'
  ;;
plan)
  : >"${chdir}/contract.tfplan"
  ;;
show)
  if [ "$chdir" != "$FAKE_TF_DIR" ] && [ "${FAKE_MUTATE_CANDIDATE_ON_SHOW:-false}" = true ]; then
    printf '# changed\n' >>"$FAKE_CANDIDATE_BINARY"
  fi
  if [ "$chdir" = "$FAKE_TF_DIR" ]; then
    plan_vip=${FAKE_PLAN_AWS_VIP_JSON:-'"10.151.1.10"'}
    plan_listeners=${FAKE_PLAN_SITE_LISTENERS_JSON:-'{"01":"10.150.11.10","02":"10.150.12.10","03":"10.150.13.10"}'}
    site_01_actions=${FAKE_SITE_01_ACTIONS:-${FAKE_SITE_ACTIONS:-'"create"'}}
    site_02_actions=${FAKE_SITE_02_ACTIONS:-${FAKE_SITE_ACTIONS:-'"create"'}}
    site_03_actions=${FAKE_SITE_03_ACTIONS:-${FAKE_SITE_ACTIONS:-'"create"'}}
    extra=${FAKE_EXTRA_CHANGE:-}
    if [ "${FAKE_BOOTSTRAP_CONTINUATION:-false}" = true ]; then
      printf '%s\n' '{"planned_values":{"outputs":{"aws_vip":{"value":"10.151.1.10"},"aws_smsv2_site_listener_ips":{"value":{"01":"10.150.11.10","02":"10.150.12.10","03":"10.150.13.10"}}}},"resource_changes":[{"address":"aws_instance.ce[0]","type":"aws_instance","name":"ce","index":0,"change":{"actions":["create"],"after":{"tags":{"ves-io-site-name":"mcn-ce-ha-aws-ap-northeast-1-01-bootstrap"}}}},{"address":"aws_instance.ce[1]","type":"aws_instance","name":"ce","index":1,"change":{"actions":["create"],"after":{"tags":{"ves-io-site-name":"mcn-ce-ha-aws-ap-northeast-1-02-bootstrap"}}}},{"address":"aws_instance.ce[2]","type":"aws_instance","name":"ce","index":2,"change":{"actions":["create"],"after":{"tags":{"ves-io-site-name":"mcn-ce-ha-aws-ap-northeast-1-03-bootstrap"}}}},{"address":"xcsh_securemesh_site_v2.aws[\"01\"]","type":"xcsh_securemesh_site_v2","name":"aws","index":"01","change":{"actions":["no-op"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-01-bootstrap"}}},{"address":"xcsh_securemesh_site_v2.aws[\"02\"]","type":"xcsh_securemesh_site_v2","name":"aws","index":"02","change":{"actions":["no-op"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-02-bootstrap"}}},{"address":"xcsh_securemesh_site_v2.aws[\"03\"]","type":"xcsh_securemesh_site_v2","name":"aws","index":"03","change":{"actions":["no-op"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-03-bootstrap"}}},{"address":"xcsh_token.aws[\"01\"]","type":"xcsh_token","name":"aws","index":"01","change":{"actions":["create"],"after":{"name":"token-01","namespace":"system","site_name":"mcn-ce-ha-aws-ap-northeast-1-01-bootstrap","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_token.aws[\"02\"]","type":"xcsh_token","name":"aws","index":"02","change":{"actions":["create"],"after":{"name":"token-02","namespace":"system","site_name":"mcn-ce-ha-aws-ap-northeast-1-02-bootstrap","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_token.aws[\"03\"]","type":"xcsh_token","name":"aws","index":"03","change":{"actions":["create"],"after":{"name":"token-03","namespace":"system","site_name":"mcn-ce-ha-aws-ap-northeast-1-03-bootstrap","labels":{"mcn-deployment-generation":"gen-01"}}}}]}'
    elif [ "${FAKE_TARGETED_BOOTSTRAP:-false}" = true ]; then
      printf '{"complete":false,"planned_values":{"outputs":{}},"resource_changes":[{"address":"xcsh_securemesh_site_v2.aws_01","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-01","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_securemesh_site_v2.aws_02","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-02","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_securemesh_site_v2.aws_03","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-03","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}}]}\n'
    elif [ "${FAKE_SHARED_TOPOLOGY_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s},"aws_site_names":{"value":{"01":"mcn-ce-ha-aws-ap-northeast-1-01","02":"mcn-ce-ha-aws-ap-northeast-1-02","03":"mcn-ce-ha-aws-ap-northeast-1-03"}}}},"resource_changes":[{"address":"aws_vpc.workload[0]","type":"aws_vpc","name":"workload","index":0,"change":{"actions":["create"],"after":{"cidr_block":"10.151.0.0/16","tags":{"Name":"mcn-ce-ha-gen-01-workload","component":"mcn-ce-ha","deployment_generation":"gen-01","deployer":"tester","managed_by":"terraform"}}}}]}\n' "$plan_vip" "$plan_listeners"
    elif [ "${FAKE_TARGETED_APPROVAL_NO_OUTPUTS:-false}" = true ]; then
      printf '{"complete":false,"planned_values":{"outputs":{}},"prior_state":{"values":{"root_module":{"resources":[{"address":"xcsh_securemesh_site_v2.aws[\\"01\\"]","type":"xcsh_securemesh_site_v2","name":"aws","index":"01","values":{"name":"mcn-ce-ha-aws-ap-northeast-1-01","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}]}}},"resource_changes":[{"address":"xcsh_registration_approval.aws[\\"01\\"]","type":"xcsh_registration_approval","name":"aws","index":"01","change":{"actions":["create"],"after":{"name":"r-example","namespace":"system","state":"APPROVED"}}}]}\n'
    elif [ "${FAKE_APPROVAL_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s},"aws_site_names":{"value":{"01":"mcn-ce-ha-aws-ap-northeast-1-01","02":"mcn-ce-ha-aws-ap-northeast-1-02","03":"mcn-ce-ha-aws-ap-northeast-1-03"}}}},"resource_changes":[{"address":"xcsh_registration_approval.aws[\\"01\\"]","type":"xcsh_registration_approval","name":"aws","index":"01","change":{"actions":["create"],"after":{"name":"r-example","namespace":"system","state":"APPROVED"}}}]}\n' "$plan_vip" "$plan_listeners"
    elif [ "${FAKE_ROUTE_GATE_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s},"aws_site_names":{"value":{"01":"mcn-ce-ha-aws-ap-northeast-1-01","02":"mcn-ce-ha-aws-ap-northeast-1-02","03":"mcn-ce-ha-aws-ap-northeast-1-03"}}}},"resource_changes":[{"address":"aws_route_table_association.private[\\"01\\"]","type":"aws_route_table_association","name":"private","index":"01","change":{"actions":["create"],"after":{}}},{"address":"terraform_data.aws_tgw_site_route_gate[\\"01\\"]","type":"terraform_data","name":"aws_tgw_site_route_gate","index":"01","change":{"actions":["create"],"after":{"input":{"public_association_id":"rtbassoc-public","private_association_id":"rtbassoc-private"}}}}]}\n' "$plan_vip" "$plan_listeners"
    elif [ "${FAKE_TGW_BGP_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s}}},"resource_changes":[{"address":"xcsh_bgp.aws_tgw_01","type":"xcsh_bgp","name":"aws_tgw","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-gen-01-bgp-01","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"},"where":{"site":{"ref":[{"name":"mcn-ce-ha-aws-ap-northeast-1-01","namespace":"system"}]}}}}},{"address":"xcsh_bgp.aws_tgw_02","type":"xcsh_bgp","name":"aws_tgw","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-gen-01-bgp-02","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"},"where":{"site":{"ref":[{"name":"mcn-ce-ha-aws-ap-northeast-1-02","namespace":"system"}]}}}}},{"address":"xcsh_bgp.aws_tgw_03","type":"xcsh_bgp","name":"aws_tgw","change":{"actions":["create"],"after":{"name":"mcn-ce-ha-gen-01-bgp-03","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"},"where":{"site":{"ref":[{"name":"mcn-ce-ha-aws-ap-northeast-1-03","namespace":"system"}]}}}}}]}\n' "$plan_vip" "$plan_listeners"
    elif [ "${FAKE_TOKEN_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s}}},"resource_changes":[{"address":"xcsh_token.aws_01","type":"xcsh_token","name":"aws","change":{"actions":[%s],"after":{"site_name":"mcn-ce-ha-aws-ap-northeast-1-01","name":"mcn-ce-ha-gen-01-token-01","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}}%s]}\n' "$plan_vip" "$plan_listeners" "$site_01_actions" "$extra"
    elif [ "${FAKE_INSTANCE_ONLY:-false}" = true ]; then
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s}}},"resource_changes":[{"address":"aws_instance.ce_0","type":"aws_instance","name":"ce","change":{"actions":[%s],"after":{"tags":{"ves-io-site-name":"mcn-ce-ha-aws-ap-northeast-1-01"}}}}%s]}\n' "$plan_vip" "$plan_listeners" "$site_01_actions" "$extra"
    else
      site_suffix=${FAKE_SITE_SUFFIX:-}
      printf '{"planned_values":{"outputs":{"aws_vip":{"value":%s},"aws_smsv2_site_listener_ips":{"value":%s}}},"resource_changes":[{"address":"xcsh_securemesh_site_v2.aws_01","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":[%s],"before":{"name":"mcn-ce-ha-aws-ap-northeast-1-01%s","namespace":"system"},"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-01%s","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_securemesh_site_v2.aws_02","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":[%s],"before":{"name":"mcn-ce-ha-aws-ap-northeast-1-02%s","namespace":"system"},"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-02%s","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}},{"address":"xcsh_securemesh_site_v2.aws_03","type":"xcsh_securemesh_site_v2","name":"aws","change":{"actions":[%s],"before":{"name":"mcn-ce-ha-aws-ap-northeast-1-03%s","namespace":"system"},"after":{"name":"mcn-ce-ha-aws-ap-northeast-1-03%s","namespace":"system","labels":{"mcn-deployment-generation":"gen-01"}}}}%s]}\n' "$plan_vip" "$plan_listeners" "$site_01_actions" "$site_suffix" "$site_suffix" "$site_02_actions" "$site_suffix" "$site_suffix" "$site_03_actions" "$site_suffix" "$site_suffix" "$extra"
    fi
  else
    capability=${FAKE_CAPABILITY_STATE:-available}
    api_release_tag=${FAKE_API_RELEASE_TAG:-v7.0.8}
    api_release_commit=${FAKE_API_RELEASE_COMMIT:-1c7f9e01f2011a3a4267d024e1eee5f71b65481f}
    node_strategy=${FAKE_AWS_NODE_STRATEGY:-discovery_rebuild}
    printf '%s\n' "{\"planned_values\":{\"outputs\":{\"contract\":{\"value\":{\"contract_id\":\"f5xc-smsv2-api/v1\",\"contract_version\":\"7.0.0\",\"api_release_tag\":\"${api_release_tag}\",\"api_release_commit\":\"${api_release_commit}\",\"telemetry_schema_id\":\"f5xc-smsv2-aws-tgw-telemetry/v2\",\"capabilities\":{\"aws_ce_create\":\"${capability}\",\"aws_node_configuration\":\"${capability}\",\"runtime_status\":\"${capability}\",\"site_upgrade\":\"${capability}\",\"tgw_connect\":\"${capability}\"},\"aws_node_configuration\":\"{\\\"strategy\\\":\\\"${node_strategy}\\\",\\\"enforcement\\\":\\\"required\\\",\\\"invariants\\\":{\\\"device_source\\\":\\\"observed_registration_only\\\"},\\\"mapping\\\":{\\\"cardinality\\\":\\\"one_to_one\\\"}}\",\"f5xc_authorities\":[\"smsv2_configuration\",\"runtime_health\",\"bgp_peers\",\"bgp_routes\",\"simplified_routes\",\"site_upgrade_observation\"],\"aws_authorities\":[\"eni\",\"transit_gateway\",\"transit_gateway_connect\",\"gre_endpoints\",\"bgp_inside_cidrs\",\"autonomous_system_numbers\"]}}}}}"
  fi
  ;;
output)
  case "$*" in
  *'-raw aws_workload_instance_id'*) printf 'i-workload\n' ;;
  *'-raw aws_origin_dns_name'*) printf 'httpbin.org\n' ;;
  *'-raw aws_vip'*) printf '%s\n' "${FAKE_LIVE_AWS_VIP:-10.151.1.10}" ;;
  *'-raw aws_lb_domain'*) printf 'aws.mcn-ce-ha.example.com\n' ;;
  *'-raw aws_smsv2_target_group_arn'*) printf 'arn:aws:elasticloadbalancing:ap-northeast-1:111122223333:targetgroup/test/0123456789abcdef\n' ;;
  *'-json aws_smsv2_site_listener_ips'*) printf '%s\n' "${FAKE_LIVE_SITE_LISTENERS_JSON:-{\"01\":\"10.150.11.10\",\"02\":\"10.150.12.10\",\"03\":\"10.150.13.10\"}}" ;;
  *'-json aws_tgw_connect_status'*)
    if [ "${FAKE_TOPOLOGY_CONVERGED:-false}" = true ]; then
      printf '{"runtime_healthy":true,"bgp_converged":true,"interface_count":6,"connect_peer_count":6,"bgp_session_count":12}\n'
    else
      printf '{"runtime_healthy":false,"bgp_converged":false,"interface_count":0,"connect_peer_count":0,"bgp_session_count":0}\n'
    fi
    ;;
  *'-json'*) printf '{"aws_tgw_route_table_id":{"value":null}}\n' ;;
  *) exit 2 ;;
  esac
  ;;
*) exit 2 ;;
esac
SH
chmod 755 "${BIN}/aws" "${BIN}/curl" "${BIN}/terraform"

export PATH="${BIN}:$PATH"
FAKE_TF_DIR="$(cd "$TF_DIR" && pwd)"
export FAKE_TF_DIR
export FAKE_TF_CALLS="$TF_CALLS"
export FAKE_CANDIDATE_BINARY="$CANDIDATE_BINARY"
export AWS_REGION="ap-northeast-1"
export XCSH_API_URL="https://f5-sales-demo.console.ves.volterra.io"
export XCSH_API_TOKEN="test-token-must-not-leak"

common=(
  --terraform-dir "$TF_DIR"
  --plan-file "$PLAN_FILE"
  --expected-aws-account 111122223333
  --expected-aws-region ap-northeast-1
  --expected-xc-tenant f5-sales-demo
  --creator-id tester@example.com
  --deployment-generation gen-01
  --source-repository f5-sales-demo/multi-cloud-networking
  --source-ref refs/heads/main
  --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --deployment-owner-id showcase-team
  --deployment-actor-id github-actions
  --lifecycle-phase configured
  --expected-site mcn-ce-ha-aws-ap-northeast-1-01
  --expected-site mcn-ce-ha-aws-ap-northeast-1-02
  --expected-site mcn-ce-ha-aws-ap-northeast-1-03
)
bootstrap_common=(
  --terraform-dir "$TF_DIR"
  --plan-file "$PLAN_FILE"
  --expected-aws-account 111122223333
  --expected-aws-region ap-northeast-1
  --expected-xc-tenant f5-sales-demo
  --creator-id tester@example.com
  --deployment-generation gen-01
  --source-repository f5-sales-demo/multi-cloud-networking
  --source-ref refs/heads/main
  --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --deployment-owner-id showcase-team
  --deployment-actor-id github-actions
  --lifecycle-phase bootstrap
  --expected-site mcn-ce-ha-aws-ap-northeast-1-01-bootstrap
  --expected-site mcn-ce-ha-aws-ap-northeast-1-02-bootstrap
  --expected-site mcn-ce-ha-aws-ap-northeast-1-03-bootstrap
)

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

continuity_only_output="${TMP_ROOT}/retired-continuity-only.out"
if "$SCRIPT" --continuity-only --evidence-dir "${TMP_ROOT}/continuity-only-without-uat" \
  "${common[@]}" >"$continuity_only_output" 2>&1; then
  fail "retired continuity-only mode must not be accepted"
fi
grep -Fq 'unknown argument' "$continuity_only_output" ||
  fail "retired continuity-only mode did not fail as an unknown argument"
echo "ok - retired continuity-only mode is rejected cleanly"

assert_sanitized() {
  local evidence=$1 output=$2
  [ "$(find "$evidence" -maxdepth 1 -type f -printf '%f\n')" = summary.json ] || fail "evidence contains unexpected files"
  [ "$(jq -r 'keys | sort | join(",")' "$evidence/summary.json")" = provider_mode,provider_sha256,reason,status,timestamp ] || fail "summary has unexpected keys"
  if grep -R -E '111122223333|mcn-ce-ha-aws-ap-northeast-1|test-token-must-not-leak|f5-sales-demo\.console\.ves\.volterra\.io' "$evidence" "$output"; then
    fail "identity or credential leaked into sanitized evidence"
  fi
}

evidence="${TMP_ROOT}/ready"
mkdir "$evidence"
output="${TMP_ROOT}/ready.out"
if ! "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "available contract should pass"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "ready status not recorded"
[ "$(jq -r .reason "$evidence/summary.json")" = preflight_passed ] || fail "ready reason not recorded"
assert_sanitized "$evidence" "$output"
[ "$(jq -r .provider_mode "$evidence/summary.json")" = registry ] || fail "registry mode not recorded"
[ "$(jq -r .provider_sha256 "$evidence/summary.json")" = null ] || fail "registry digest must be null"
echo "ok - exact v9.5.1 available contract passes with sanitized evidence"

evidence="${TMP_ROOT}/no-explicit-region"
mkdir "$evidence"
output="${TMP_ROOT}/no-explicit-region.out"
if ! env -u AWS_REGION -u AWS_DEFAULT_REGION \
  "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "an unrelated profile default must not override the reviewed expected region"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "no-explicit-region status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - reviewed region binds UAT when no explicit environment override is present"

evidence="${TMP_ROOT}/explicit-region-mismatch"
mkdir "$evidence"
output="${TMP_ROOT}/explicit-region-mismatch.out"
if AWS_REGION=us-east-1 "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "an explicit conflicting AWS region must fail closed"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = aws_region_mismatch ] ||
  fail "explicit region mismatch reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - explicit region mismatch is rejected before plan review"

evidence="${TMP_ROOT}/obsolete-contract"
mkdir "$evidence"
output="${TMP_ROOT}/obsolete-contract.out"
obsolete_api_commit="$(printf '%s%s' '76973b4ef84f73d41b648' 'a27f38c2735a8c255ef')"
if FAKE_API_RELEASE_TAG=v7.0.2 FAKE_API_RELEASE_COMMIT="$obsolete_api_commit" \
  "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "obsolete immutable contract binding must be rejected"
fi
[ "$(jq -r .status "$evidence/summary.json")" = blocked ] || fail "obsolete contract status not recorded"
[ "$(jq -r .reason "$evidence/summary.json")" = v9_contract_identity_mismatch ] || fail "obsolete contract reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - obsolete immutable contract binding is rejected before plan review"

evidence="${TMP_ROOT}/no-change"
mkdir "$evidence"
output="${TMP_ROOT}/no-change.out"
if ! FAKE_SITE_ACTIONS='"no-op"' "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "no-change plan should prove the exact configured site identities"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "no-change status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - no-change plan is accepted for the exact configured sites"

evidence="${TMP_ROOT}/candidate-ready"
mkdir "$evidence"
output="${TMP_ROOT}/candidate-ready.out"
: >"$TF_CALLS"
if ! TF_CLI_CONFIG_FILE="${TMP_ROOT}/ambient-must-not-be-used.tfrc" "$SCRIPT" \
  --candidate-provider-binary "$CANDIDATE_BINARY" \
  --candidate-provider-sha256 "$CANDIDATE_SHA256" \
  --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "matching candidate artifact should pass"
fi
assert_sanitized "$evidence" "$output"
[ "$(jq -r .provider_mode "$evidence/summary.json")" = candidate ] || fail "candidate mode not recorded"
[ "$(jq -r .provider_sha256 "$evidence/summary.json")" = "$CANDIDATE_SHA256" ] || fail "candidate digest not recorded"
awk -F '\t' '
  $1 == "init" { init_found=1; if ($2 !~ /registry\.tfrc$/) bad=1; next }
  { operation_found=1; if ($2 !~ /candidate\.tfrc$/) bad=1 }
  END { exit bad || !init_found || !operation_found }
' "$TF_CALLS" || fail "candidate mode did not isolate registry init from candidate operations"
if grep -Fq 'ambient-must-not-be-used' "$TF_CALLS"; then
  fail "ambient Terraform CLI config leaked into candidate validation"
fi
echo "ok - matching candidate artifact is selected explicitly and bound to evidence"

context_home="${TMP_ROOT}/context-home"
mkdir -p "${context_home}/.config/xcsh/contexts"
printf '{"apiUrl":"https://f5-sales-demo.console.ves.volterra.io","apiToken":"context-token-must-not-leak"}\n' \
  >"${context_home}/.config/xcsh/contexts/context-test.json"
evidence="${TMP_ROOT}/context-auth"
mkdir "$evidence"
output="${TMP_ROOT}/context-auth.out"
: >"$TF_CALLS"
if env -u XCSH_API_URL -u XCSH_API_TOKEN HOME="$context_home" \
  "$SCRIPT" --execute-uat --xc-context context-test \
  --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "non-converged fake topology must stop context-auth UAT"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = topology_not_converged ] ||
  fail "context-auth UAT did not reach topology validation"
awk -F '\t' '$1 == "output" { found=1; if ($3 != "present") bad=1 } END { exit bad || !found }' "$TF_CALLS" ||
  fail "context-derived token did not reach live Terraform operations"
awk -F '\t' '$1 == "output" { found=1; if ($4 != "present") bad=1 } END { exit bad || !found }' "$TF_CALLS" ||
  fail "context-derived API URL did not reach live Terraform operations"
if grep -Fq 'context-token-must-not-leak' "$output" "$evidence/summary.json"; then
  fail "context-derived token leaked into sanitized output"
fi
echo "ok - context-derived authentication and API URL reach live Terraform operations"

candidate_failure() {
  local name=$1 reason=$2
  shift 2
  local evidence="${TMP_ROOT}/${name}" output="${TMP_ROOT}/${name}.out"
  mkdir "$evidence"
  if "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" "$@" >"$output" 2>&1; then
    fail "${name} candidate validation must fail closed"
  fi
  [ "$(jq -r .reason "$evidence/summary.json")" = "$reason" ] || fail "${name} reason not recorded"
  assert_sanitized "$evidence" "$output"
}

candidate_failure candidate-missing-digest candidate_provider_arguments_incomplete \
  --candidate-provider-binary "$CANDIDATE_BINARY"
candidate_failure candidate-missing-binary candidate_provider_arguments_incomplete \
  --candidate-provider-sha256 "$CANDIDATE_SHA256"
candidate_failure candidate-malformed-digest candidate_provider_digest_invalid \
  --candidate-provider-binary "$CANDIDATE_BINARY" --candidate-provider-sha256 sha256:ABC
candidate_failure candidate-wrong-digest candidate_provider_digest_mismatch \
  --candidate-provider-binary "$CANDIDATE_BINARY" --candidate-provider-sha256 "sha256:$(printf '0%.0s' {1..64})"
candidate_failure candidate-unavailable candidate_provider_unavailable \
  --candidate-provider-binary "${TMP_ROOT}/missing/terraform-provider-xcsh" --candidate-provider-sha256 "$CANDIDATE_SHA256"

NONEXEC_BINARY="${TMP_ROOT}/nonexec/terraform-provider-xcsh"
mkdir -p "${NONEXEC_BINARY%/*}"
cp "$CANDIDATE_BINARY" "$NONEXEC_BINARY"
chmod 600 "$NONEXEC_BINARY"
NONEXEC_SHA256="sha256:$(sha256sum "$NONEXEC_BINARY" | awk '{print $1}')"
candidate_failure candidate-nonexecutable candidate_provider_unavailable \
  --candidate-provider-binary "$NONEXEC_BINARY" --candidate-provider-sha256 "$NONEXEC_SHA256"

WRONG_BINARY="${TMP_ROOT}/wrong-provider-name"
cp "$CANDIDATE_BINARY" "$WRONG_BINARY"
chmod 755 "$WRONG_BINARY"
WRONG_SHA256="sha256:$(sha256sum "$WRONG_BINARY" | awk '{print $1}')"
candidate_failure candidate-wrong-layout candidate_provider_layout_invalid \
  --candidate-provider-binary "$WRONG_BINARY" --candidate-provider-sha256 "$WRONG_SHA256"

AMBIGUOUS_DIR="${TMP_ROOT}/ambiguous"
mkdir "$AMBIGUOUS_DIR"
cp "$CANDIDATE_BINARY" "$AMBIGUOUS_DIR/terraform-provider-xcsh"
cp "$CANDIDATE_BINARY" "$AMBIGUOUS_DIR/terraform-provider-xcsh.backup"
chmod 755 "$AMBIGUOUS_DIR/terraform-provider-xcsh" "$AMBIGUOUS_DIR/terraform-provider-xcsh.backup"
AMBIGUOUS_SHA256="sha256:$(sha256sum "$AMBIGUOUS_DIR/terraform-provider-xcsh" | awk '{print $1}')"
candidate_failure candidate-ambiguous-layout candidate_provider_layout_invalid \
  --candidate-provider-binary "$AMBIGUOUS_DIR/terraform-provider-xcsh" --candidate-provider-sha256 "$AMBIGUOUS_SHA256"

MUTATING_BINARY="${TMP_ROOT}/mutating/terraform-provider-xcsh"
mkdir -p "${MUTATING_BINARY%/*}"
cp "$CANDIDATE_BINARY" "$MUTATING_BINARY"
chmod 755 "$MUTATING_BINARY"
MUTATING_SHA256="sha256:$(sha256sum "$MUTATING_BINARY" | awk '{print $1}')"
FAKE_CANDIDATE_BINARY="$MUTATING_BINARY" FAKE_MUTATE_CANDIDATE_ON_SHOW=true \
  candidate_failure candidate-mutated candidate_provider_changed \
  --candidate-provider-binary "$MUTATING_BINARY" --candidate-provider-sha256 "$MUTATING_SHA256"
echo "ok - incomplete, malformed, mismatched, invalid and changing candidates fail closed"

evidence="${TMP_ROOT}/replacement"
mkdir "$evidence"
output="${TMP_ROOT}/replacement.out"
if FAKE_SITE_ACTIONS='"delete","create"' "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "site replacement must be rejected before any Terraform, AWS, or F5 mutation"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = collision_preflight_failed ] || fail "replacement rejection reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - site replacement is rejected before mutation"

single_site=(
  --terraform-dir "$TF_DIR"
  --plan-file "$PLAN_FILE"
  --expected-aws-account 111122223333
  --expected-aws-region ap-northeast-1
  --expected-xc-tenant f5-sales-demo
  --creator-id tester@example.com
  --deployment-generation gen-01
  --source-repository f5-sales-demo/multi-cloud-networking
  --source-ref refs/heads/main
  --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --deployment-owner-id showcase-team
  --deployment-actor-id github-actions
  --lifecycle-phase configured
  --expected-site mcn-ce-ha-aws-ap-northeast-1-01
)
evidence="${TMP_ROOT}/single-site"
mkdir "$evidence"
output="${TMP_ROOT}/single-site.out"
if FAKE_SITE_01_ACTIONS='"delete","create"' FAKE_SITE_02_ACTIONS='"no-op"' FAKE_SITE_03_ACTIONS='"no-op"' \
  "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  fail "one-site replacement must be rejected before any Terraform, AWS, or F5 mutation"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = collision_preflight_failed ] || fail "one-site replacement rejection reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - one-site replacement is rejected before mutation"

evidence="${TMP_ROOT}/single-site-no-change"
mkdir "$evidence"
output="${TMP_ROOT}/single-site-no-change.out"
if FAKE_SITE_ACTIONS='"no-op"' "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  fail "one-site no-change plan must reject the three-site configured identity set"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = task_site_identity_mismatch ] ||
  fail "single-site no-change mismatch reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - no-change plan rejects a mismatched stage identity set"

evidence="${TMP_ROOT}/single-token"
mkdir "$evidence"
output="${TMP_ROOT}/single-token.out"
if ! FAKE_TOKEN_ONLY=true FAKE_SITE_01_ACTIONS='"create"' "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "one-site JWT issuance must prove the site stage without forcing peer tokens"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "one-site JWT issuance status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - site-scoped JWT issuance is accepted before the remaining sites"

evidence="${TMP_ROOT}/single-route-gate"
mkdir "$evidence"
output="${TMP_ROOT}/single-route-gate.out"
if ! FAKE_ROUTE_GATE_ONLY=true "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "one-site subnet-route repair must prove its site through the keyed route gate"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "one-site route-gate status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - keyed route gate binds a subnet-route repair to one exact site"

evidence="${TMP_ROOT}/single-approval"
mkdir "$evidence"
output="${TMP_ROOT}/single-approval.out"
if ! FAKE_APPROVAL_ONLY=true "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "one-site registration approval must prove its site through the keyed approval resource"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "one-site approval status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - keyed registration approval binds an unpredictable registration to one exact site"

evidence="${TMP_ROOT}/single-targeted-approval"
mkdir "$evidence"
output="${TMP_ROOT}/single-targeted-approval.out"
if ! FAKE_TARGETED_APPROVAL_NO_OUTPUTS=true \
  "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "targeted approval must resolve its keyed site from prior managed state"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "targeted approval ready status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - targeted approval resolves its site from prior managed state"

evidence="${TMP_ROOT}/single-instance"
mkdir "$evidence"
output="${TMP_ROOT}/single-instance.out"
if ! FAKE_INSTANCE_ONLY=true FAKE_SITE_01_ACTIONS='"delete","create"' \
  "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "one-site CE instance replacement must use its exact site tag"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "one-site instance replacement status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - one-site CE instance replacement is accepted by exact site tag"

evidence="${TMP_ROOT}/tgw-bgp"
mkdir "$evidence"
output="${TMP_ROOT}/tgw-bgp.out"
if ! FAKE_TGW_BGP_ONLY=true "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "TGW BGP-only stage must prove all three exact site bindings"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "TGW BGP stage status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - TGW BGP-only stage is accepted by exact site bindings"

evidence="${TMP_ROOT}/shared-topology"
mkdir "$evidence"
output="${TMP_ROOT}/shared-topology.out"
if ! FAKE_SHARED_TOPOLOGY_ONLY=true "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "shared topology changes must bind to the exact plan-bound three-site set"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "shared topology status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - shared topology changes bind to the exact three-site plan output"

evidence="${TMP_ROOT}/single-shared-topology"
mkdir "$evidence"
output="${TMP_ROOT}/single-shared-topology.out"
if FAKE_SHARED_TOPOLOGY_ONLY=true "$SCRIPT" --evidence-dir "$evidence" "${single_site[@]}" >"$output" 2>&1; then
  fail "shared three-site topology must reject a one-site expected identity"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = task_site_identity_mismatch ] ||
  fail "single-site shared topology mismatch reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - shared topology rejects a mismatched one-site claim"

evidence="${TMP_ROOT}/targeted-bootstrap"
mkdir "$evidence"
output="${TMP_ROOT}/targeted-bootstrap.out"
if ! FAKE_TARGETED_BOOTSTRAP=true "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "incomplete targeted bootstrap plan should not require omitted apply-only outputs"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "targeted bootstrap ready status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - targeted bootstrap accepts omitted apply-only plan outputs"

evidence="${TMP_ROOT}/bootstrap-continuation"
mkdir "$evidence"
output="${TMP_ROOT}/bootstrap-continuation.out"
if ! FAKE_BOOTSTRAP_CONTINUATION=true \
  "$SCRIPT" --evidence-dir "$evidence" "${bootstrap_common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "bootstrap continuation must accept three existing exact sites plus three tokens and three CE instances"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "bootstrap continuation ready status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - bootstrap continuation binds existing sites, tokens, and CE instances"

evidence="${TMP_ROOT}/destroy"
mkdir "$evidence"
output="${TMP_ROOT}/destroy.out"
retirement_sites=(
  --terraform-dir "$TF_DIR" --plan-file "$PLAN_FILE"
  --expected-aws-account 111122223333 --expected-aws-region ap-northeast-1
  --expected-xc-tenant f5-sales-demo --creator-id tester@example.com
  --deployment-generation gen-01 --lifecycle-phase bootstrap_retirement
  --source-repository f5-sales-demo/multi-cloud-networking
  --source-ref refs/heads/main
  --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --deployment-owner-id showcase-team
  --deployment-actor-id github-actions
  --expected-site mcn-ce-ha-aws-ap-northeast-1-01-bootstrap
  --expected-site mcn-ce-ha-aws-ap-northeast-1-02-bootstrap
  --expected-site mcn-ce-ha-aws-ap-northeast-1-03-bootstrap
)
if ! FAKE_SITE_SUFFIX=-bootstrap FAKE_SITE_ACTIONS='"delete"' FAKE_PLAN_AWS_VIP_JSON=null FAKE_PLAN_SITE_LISTENERS_JSON='{}' \
  "$SCRIPT" --plan-mode destroy --evidence-dir "$evidence" "${retirement_sites[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "AWS-only delete plan should pass destroy mode"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "destroy ready status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - destroy mode accepts only the three expected site deletions without apply-only outputs"

evidence="${TMP_ROOT}/destroy-mixed"
mkdir "$evidence"
output="${TMP_ROOT}/destroy-mixed.out"
if FAKE_SITE_SUFFIX=-bootstrap FAKE_SITE_ACTIONS='"delete"' FAKE_EXTRA_CHANGE=',{"address":"aws_instance.unexpected","type":"aws_instance","name":"unexpected","change":{"actions":["create"],"after":{}}}' \
  "$SCRIPT" --plan-mode destroy --evidence-dir "$evidence" "${retirement_sites[@]}" >"$output" 2>&1; then
  fail "destroy mode must reject non-delete actions"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = destroy_plan_contains_non_delete_actions ] || fail "mixed destroy blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - destroy mode rejects non-delete actions"

evidence="${TMP_ROOT}/unavailable"
mkdir "$evidence"
output="${TMP_ROOT}/unavailable.out"
if FAKE_CAPABILITY_STATE=unavailable "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "unavailable capabilities must block"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = v9_capabilities_unavailable ] || fail "capability blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - unavailable capabilities fail closed"

evidence="${TMP_ROOT}/wrong-node-strategy"
mkdir "$evidence"
output="${TMP_ROOT}/wrong-node-strategy.out"
if FAKE_AWS_NODE_STRATEGY=same_site_replace "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "a direct same-site node strategy must block"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = v9_aws_node_configuration_contract_mismatch ] || fail "node strategy blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - non-rebuild AWS node strategy fails closed"

evidence="${TMP_ROOT}/identity"
mkdir "$evidence"
output="${TMP_ROOT}/identity.out"
if FAKE_AWS_ACCOUNT=999900001111 "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "wrong AWS account must block"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = aws_account_mismatch ] || fail "AWS blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - target identity mismatch fails closed"

evidence="${TMP_ROOT}/azure-change"
mkdir "$evidence"
output="${TMP_ROOT}/azure-change.out"
if FAKE_EXTRA_CHANGE=',{"address":"azurerm_virtual_network.hub","type":"azurerm_virtual_network","name":"hub","change":{"actions":["update"],"after":{}}}' \
  "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "any Azure action must block"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = azure_changes_present ] || fail "Azure-change blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - an Azure change is rejected without Azure CLI access"

evidence="${TMP_ROOT}/kvm-registration-mapping-gate"
mkdir "$evidence"
output="${TMP_ROOT}/kvm-registration-mapping-gate.out"
if ! FAKE_EXTRA_CHANGE=',{"address":"module.kvm_registration_mapping.terraform_data.gate[0]","type":"terraform_data","name":"gate","index":0,"change":{"actions":["create"],"after":{}}}' \
  "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  cat "$output" >&2
  fail "the owned KVM registration mapping gate must be accepted"
fi
[ "$(jq -r .status "$evidence/summary.json")" = ready ] || fail "KVM mapping gate ready status not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - the exact KVM registration mapping gate is accepted"

evidence="${TMP_ROOT}/outside-allowlist"
mkdir "$evidence"
output="${TMP_ROOT}/outside-allowlist.out"
if FAKE_EXTRA_CHANGE=',{"address":"random_id.unrelated","type":"random_id","name":"unrelated","change":{"actions":["create"],"after":{}}}' \
  "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "a change outside the unified showcase allowlist must block"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = plan_resource_outside_showcase_allowlist ] || fail "allowlist blocker not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - changes outside the unified showcase allowlist fail closed"

plan_vip_failure() {
  local name=$1 plan_vip=$2 reason=$3
  local evidence="${TMP_ROOT}/${name}" output="${TMP_ROOT}/${name}.out"
  mkdir "$evidence"
  if FAKE_PLAN_AWS_VIP_JSON="$plan_vip" "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
    fail "${name} plan VIP validation must fail closed"
  fi
  [ "$(jq -r .reason "$evidence/summary.json")" = "$reason" ] || fail "${name} reason not recorded"
  assert_sanitized "$evidence" "$output"
}

plan_vip_failure plan-vip-missing null plan_vip_identity_unavailable
plan_vip_failure plan-vip-malformed '"not-an-ip"' plan_vip_identity_invalid
echo "ok - missing and malformed plan-bound VIP identities fail closed"

plan_listener_failure() {
  local name=$1 listeners=$2
  local evidence="${TMP_ROOT}/${name}" output="${TMP_ROOT}/${name}.out"
  mkdir "$evidence"
  if FAKE_PLAN_SITE_LISTENERS_JSON="$listeners" "$SCRIPT" --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
    fail "${name} plan listener validation must fail closed"
  fi
  [ "$(jq -r .reason "$evidence/summary.json")" = plan_site_listener_identities_invalid ] || fail "${name} reason not recorded"
  assert_sanitized "$evidence" "$output"
}

plan_listener_failure plan-listeners-missing null
plan_listener_failure plan-listeners-duplicate '{"01":"10.150.11.10","02":"10.150.11.10","03":"10.150.13.10"}'
plan_listener_failure plan-listeners-malformed '{"01":"10.150.11.10","02":"not-an-ip","03":"10.150.13.10"}'
echo "ok - plan-bound listener identities require three distinct site addresses"

evidence="${TMP_ROOT}/matching-vip-override"
mkdir "$evidence"
output="${TMP_ROOT}/matching-vip-override.out"
if FAKE_PLAN_AWS_VIP_JSON='"203.0.113.10"' FAKE_LIVE_AWS_VIP=203.0.113.10 \
  "$SCRIPT" --execute-uat --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "non-converged fake topology must stop live UAT"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = topology_not_converged ] || fail "matching VIP override did not reach topology validation"
assert_sanitized "$evidence" "$output"

evidence="${TMP_ROOT}/mismatched-vip-override"
mkdir "$evidence"
output="${TMP_ROOT}/mismatched-vip-override.out"
if FAKE_PLAN_AWS_VIP_JSON='"203.0.113.10"' FAKE_LIVE_AWS_VIP=198.51.100.10 \
  "$SCRIPT" --execute-uat --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "plan/live VIP mismatch must stop live UAT"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = vip_identity_mismatch ] || fail "plan/live VIP mismatch reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - live UAT binds an overridden VIP to the reviewed plan"

evidence="${TMP_ROOT}/mismatched-site-listeners"
mkdir "$evidence"
output="${TMP_ROOT}/mismatched-site-listeners.out"
if FAKE_LIVE_SITE_LISTENERS_JSON='{"01":"10.150.11.11","02":"10.150.12.10","03":"10.150.13.10"}' \
  "$SCRIPT" --execute-uat --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "plan/live site-listener mismatch must stop live UAT"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = site_listener_identity_mismatch ] || fail "plan/live site-listener mismatch reason not recorded"
assert_sanitized "$evidence" "$output"
echo "ok - live UAT binds all three listener identities to the reviewed plan"

evidence="${TMP_ROOT}/mixed-case-established"
mkdir "$evidence"
output="${TMP_ROOT}/mixed-case-established.out"
if FAKE_TOPOLOGY_CONVERGED=true FAKE_XC_PROTOCOL_STATUS=Established \
  "$SCRIPT" --execute-uat --evidence-dir "$evidence" "${common[@]}" >"$output" 2>&1; then
  fail "fake UAT without a TGW route table identity must stop"
fi
[ "$(jq -r .reason "$evidence/summary.json")" = tgw_route_table_identity_unavailable ] || fail "mixed-case established sessions did not pass peer validation"
assert_sanitized "$evidence" "$output"
echo "ok - XC mixed-case Established status counts toward twelve sessions"

mkdir "$INSIDE_EVIDENCE"
if "$SCRIPT" --evidence-dir "$INSIDE_EVIDENCE" "${common[@]}" >/dev/null 2>&1; then
  fail "repository-local evidence directory must be rejected"
fi
echo "ok - repository-local evidence is rejected"

echo "PASS: AWS SMSv2 UAT preflight shell tests"
