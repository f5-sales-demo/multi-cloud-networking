#!/usr/bin/env bash
# Verify the rebuilt MCN deployment and write private, aggregate evidence.
#
# Run from the repository root after the second Terraform apply:
#
#   bash scripts/verify-deployment.sh --evidence-dir /private/path/mcn-evidence
#
# The default run verifies the rotated Site Console credentials as well as XC,
# Azure ILB connectivity, and traffic. Set MCN_FACTORY_PASSWORD in the environment; the
# value is read from stdin by curl and never enters a command line or output.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TERRAFORM_DIR="terraform"
EVIDENCE_DIR=""
SAMPLES_PER_BATCH=40
MAX_BATCHES=12
BATCH_INTERVAL=300
CHECK_CONSOLE=1
CONTEXT="${XCSH_CONTEXT:-f5-sales-demo}"
AZURE_SUBSCRIPTION=""

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --terraform-dir)
    TERRAFORM_DIR="${2:?--terraform-dir needs a value}"
    shift 2
    ;;
  --evidence-dir)
    EVIDENCE_DIR="${2:?--evidence-dir needs a value}"
    shift 2
    ;;
  --samples-per-batch)
    SAMPLES_PER_BATCH="${2:?--samples-per-batch needs a value}"
    shift 2
    ;;
  --max-batches)
    MAX_BATCHES="${2:?--max-batches needs a value}"
    shift 2
    ;;
  --batch-interval)
    BATCH_INTERVAL="${2:?--batch-interval needs a value}"
    shift 2
    ;;
  --context)
    CONTEXT="${2:?--context needs a value}"
    shift 2
    ;;
  --subscription)
    AZURE_SUBSCRIPTION="${2:?--subscription needs a value}"
    shift 2
    ;;
  --skip-console)
    CHECK_CONSOLE=0
    shift
    ;;
  -h | --help) usage ;;
  *) die "unknown argument: $1" ;;
  esac
done

[ -n "$EVIDENCE_DIR" ] || die "--evidence-dir is required"
[ -n "$AZURE_SUBSCRIPTION" ] || die "--subscription is required"
case "$SAMPLES_PER_BATCH:$MAX_BATCHES:$BATCH_INTERVAL" in
*[!0-9:]* | *::* | :* | *:) die "sample and interval values must be non-negative integers" ;;
esac
[ "$SAMPLES_PER_BATCH" -gt 0 ] || die "--samples-per-batch must be greater than zero"
[ "$MAX_BATCHES" -ge 3 ] || die "--max-batches must allow at least three time-separated batches"
[ $((SAMPLES_PER_BATCH * MAX_BATCHES)) -ge 100 ] || die "the configured run cannot reach the required 100 VIP samples"
if [ "$BATCH_INTERVAL" -eq 0 ] && [ "${MCN_UAT_TEST_MODE:-0}" != "1" ]; then
  die "--batch-interval 0 is test-only; live evidence must be time-separated"
fi

for command_name in terraform jq curl az; do
  command -v "$command_name" >/dev/null 2>&1 || die "$command_name is required"
done
command az account show --subscription "$AZURE_SUBSCRIPTION" --query state --output tsv | grep -qx Enabled ||
  die "configured Azure subscription is not enabled"
az() { command az "$@" --subscription "$AZURE_SUBSCRIPTION"; }

mkdir -p "$EVIDENCE_DIR"
EVIDENCE_DIR=$(cd "$EVIDENCE_DIR" && pwd)
case "$EVIDENCE_DIR/" in
"$REPO_ROOT"/*) die "evidence must stay outside the repository" ;;
esac
if find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  die "evidence directory is not empty: $EVIDENCE_DIR"
fi
chmod 700 "$EVIDENCE_DIR"
umask 077

TF=(terraform "-chdir=${TERRAFORM_DIR}")
tf_raw() { "${TF[@]}" output -raw "$1"; }
tf_json() { "${TF[@]}" output -json "$1"; }

# Resolve the XC credential exactly as the capture harness does. A token on the
# command line is intentionally unsupported because it would enter shell history
# and process listings.
API_URL="${XCSH_API_URL:-}"
API_TOKEN="${XCSH_API_TOKEN:-}"
if [ -z "$API_URL" ] || [ -z "$API_TOKEN" ]; then
  context_file="${HOME}/.config/xcsh/contexts/${CONTEXT}.json"
  [ -f "$context_file" ] || die "no XC environment credential and no context at $context_file"
  [ -n "$API_URL" ] || API_URL=$(jq -r '.apiUrl // empty' "$context_file")
  [ -n "$API_TOKEN" ] || API_TOKEN=$(jq -r '.apiToken // empty' "$context_file")
fi
[ -n "$API_URL" ] || die "could not resolve the XC API URL"
[ -n "$API_TOKEN" ] || die "could not resolve the XC API token"

api_get() {
  local url=$1
  printf 'Authorization: APIToken %s\n' "$API_TOKEN" |
    curl -fsS --max-time 120 -H @- "$url"
}

# Azure serializes Run Command executions per VM. A preceding command can be
# complete from the caller's perspective while the extension still reports a
# short-lived Conflict. Retry only that exact transient; authentication,
# validation, and script failures remain immediate hard failures.
az_vm_run_command() {
  local attempt=1 max_attempts=20 retry_delay=15 output stderr_file
  stderr_file=$(mktemp)
  if [ "${MCN_UAT_TEST_MODE:-0}" = "1" ]; then retry_delay=0; fi
  while true; do
    if output=$(az vm run-command invoke --only-show-errors "$@" 2>"$stderr_file"); then
      rm -f "$stderr_file"
      printf '%s\n' "$output"
      return 0
    fi
    if ! grep -qF 'Run command extension execution is in progress' "$stderr_file" ||
      [ "$attempt" -ge "$max_attempts" ]; then
      cat "$stderr_file" >&2
      rm -f "$stderr_file"
      return 1
    fi
    printf 'Azure Run Command busy; retrying (%s/%s)\n' "$attempt" "$max_attempts" >&2
    attempt=$((attempt + 1))
    sleep "$retry_delay"
  done
}

STARTED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
"${TF[@]}" version -json >"${EVIDENCE_DIR}/terraform-version.json"

SITES=$(tf_json xc_site_names)
CA_SITES=$(tf_json ca_xc_site_names)
SITE_COUNT=$(jq 'length' <<<"$SITES")
[ "$SITE_COUNT" -eq 3 ] || die "expected three XC sites, found $SITE_COUNT"
[ "$(jq 'length' <<<"$CA_SITES")" -eq 3 ] || die "expected three Canadian XC sites, found $(jq 'length' <<<"$CA_SITES")"

sites_online=0
while IFS= read -r key; do
  site=$(jq -r --arg key "$key" '.[$key]' <<<"$SITES")
  state=$(api_get "${API_URL}/api/config/namespaces/system/sites/${site}" | jq -r '.spec.site_state // .get_spec.site_state // empty')
  [ "$state" = "ONLINE" ] || die "one or more XC sites are not ONLINE"
  sites_online=$((sites_online + 1))
done < <(jq -r 'keys[]' <<<"$SITES")
while IFS= read -r key; do
  site=$(jq -r --arg key "$key" '.[$key]' <<<"$CA_SITES")
  state=$(api_get "${API_URL}/api/config/namespaces/system/sites/${site}" | jq -r '.spec.site_state // .get_spec.site_state // empty')
  [ "$state" = "ONLINE" ] || die "one or more Canadian XC sites are not ONLINE"
  sites_online=$((sites_online + 1))
done < <(jq -r 'keys[]' <<<"$CA_SITES")
printf 'sites_online=%s/%s\n' "$sites_online" "$((SITE_COUNT * 2))"

RG=$(tf_raw resource_group_name)
CLIENT=$(tf_raw client_vm_name)
CA_RG=$(tf_raw ca_resource_group_name)
CA_CLIENT=$(tf_raw ca_client_vm_name)
US_ILB=$(tf_raw azure_ilb_private_ip)
CA_ILB=$(tf_raw canada_ilb_private_ip)
US_CONSOLE_ILB=$(tf_raw azure_ilb_console_ip)
CA_CONSOLE_ILB=$(tf_raw canada_ilb_console_ip)
US_INSIDE_DOMAIN=$(tf_raw azure_ilb_application_domain)
CA_INSIDE_DOMAIN=$(tf_raw canada_ilb_application_domain)
US_VIP=$(tf_raw vip)
CA_VIP=$(tf_raw ca_vip)
DOMAIN=$(tf_raw lb_domain)
CA_DOMAIN=$(tf_raw ca_lb_domain)
ORIGIN=$(tf_raw origin_ip)
CE_VM_NAMES=$(tf_json ce_vm_names)
CA_CE_VM_NAMES=$(tf_json ca_ce_vm_names)
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "lb_domain contains characters unsafe for the remote verifier"
[[ "$CA_DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "ca_lb_domain contains characters unsafe for the remote verifier"
[[ "$US_ILB" =~ ^[0-9.]+$ ]] || die "azure_ilb_private_ip is not an IPv4 literal"
[[ "$CA_ILB" =~ ^[0-9.]+$ ]] || die "canada_ilb_private_ip is not an IPv4 literal"
[[ "$ORIGIN" =~ ^[0-9.]+$ ]] || die "origin_ip is not an IPv4 literal"
[ "$(jq 'length' <<<"$CE_VM_NAMES")" -eq "$SITE_COUNT" ] || die "site and CE VM name maps differ in size"
[ "$(jq 'length' <<<"$CA_CE_VM_NAMES")" -eq 3 ] || die "Canadian site and CE VM name maps differ in size"

# Terraform and the XC API can both become ready while Azure still reports a VM
# or extension transition. Query Azure directly so a stuck control-plane
# operation cannot be mistaken for a healthy deployment.
azure_vms_running=0
password_extensions_succeeded=0
while IFS= read -r key; do
  vm_name=$(jq -r --arg key "$key" '.[$key]' <<<"$CE_VM_NAMES")
  instance_view=$(az vm get-instance-view \
    --resource-group "$RG" \
    --name "$vm_name" \
    --query '{provisioningState:provisioningState,powerState:instanceView.statuses[?starts_with(code, `PowerState/`)].code | [0]}' \
    --output json)
  provisioning_state=$(jq -r '.provisioningState // empty' <<<"$instance_view")
  power_state=$(jq -r '.powerState // empty' <<<"$instance_view")
  if [ "$provisioning_state" != "Succeeded" ] || [ "$power_state" != "PowerState/running" ]; then
    die "one CE VM is not fully running in Azure (provisioning=${provisioning_state:-unknown}, power=${power_state:-unknown})"
  fi
  azure_vms_running=$((azure_vms_running + 1))

  extension_state=$(az vm extension show \
    --resource-group "$RG" \
    --vm-name "$vm_name" \
    --name site-console-admin-password \
    --query provisioningState \
    --output tsv)
  [ "$extension_state" = "Succeeded" ] ||
    die "one Site Console password extension is not complete in Azure (provisioning=${extension_state:-unknown})"
  password_extensions_succeeded=$((password_extensions_succeeded + 1))
done < <(jq -r 'keys[]' <<<"$SITES")
while IFS= read -r key; do
  vm_name=$(jq -r --arg key "$key" '.[$key]' <<<"$CA_CE_VM_NAMES")
  instance_view=$(az vm get-instance-view \
    --resource-group "$CA_RG" \
    --name "$vm_name" \
    --query '{provisioningState:provisioningState,powerState:instanceView.statuses[?starts_with(code, `PowerState/`)].code | [0]}' \
    --output json)
  provisioning_state=$(jq -r '.provisioningState // empty' <<<"$instance_view")
  power_state=$(jq -r '.powerState // empty' <<<"$instance_view")
  if [ "$provisioning_state" != "Succeeded" ] || [ "$power_state" != "PowerState/running" ]; then
    die "one Canadian CE VM is not fully running in Azure (provisioning=${provisioning_state:-unknown}, power=${power_state:-unknown})"
  fi
  azure_vms_running=$((azure_vms_running + 1))

  extension_state=$(az vm extension show \
    --resource-group "$CA_RG" \
    --vm-name "$vm_name" \
    --name site-console-admin-password \
    --query provisioningState \
    --output tsv)
  [ "$extension_state" = "Succeeded" ] ||
    die "one Canadian Site Console password extension is not complete in Azure (provisioning=${extension_state:-unknown})"
  password_extensions_succeeded=$((password_extensions_succeeded + 1))
done < <(jq -r 'keys[]' <<<"$CA_SITES")
printf 'azure_vms_running=%s/%s\n' "$azure_vms_running" "$((SITE_COUNT * 2))"
printf 'password_extensions_succeeded=%s/%s\n' "$password_extensions_succeeded" "$((SITE_COUNT * 2))"

verify_ilb_endpoint() {
  local region=$1 resource_group=$2 client=$3 ilb=$4 output
  output=$(az_vm_run_command \
    --resource-group "$resource_group" \
    --name "$client" \
    --command-id RunShellScript \
    --query 'value[0].message' \
    --output tsv \
    --scripts "timeout 10 bash -c '</dev/tcp/${ilb}/65500' && echo MCN_ILB reachable=1")
  grep -qF 'MCN_ILB reachable=1' <<<"$output" || die "${region} ILB does not accept TCP/65500 from its Terraform-managed client"
  printf '%s_ilb_reachable=yes\n' "$region"
}

verify_ilb_endpoint us "$RG" "$CLIENT" "$US_CONSOLE_ILB"
verify_ilb_endpoint canada "$CA_RG" "$CA_CLIENT" "$CA_CONSOLE_ILB"

verify_console_backends() {
  local region=$1 rg=$2 client=$3 ips_json=$4 script="set -eu; healthy=0; " ip message
  jq -e 'length == 3 and all(.[]; type == "string" and test("^[0-9.]+$"))' <<<"$ips_json" >/dev/null ||
    die "${region} console backend inventory is invalid"
  while IFS= read -r ip; do
    script+="timeout 10 bash -c '</dev/tcp/${ip}/65500'; healthy=\$((healthy+1)); "
  done < <(jq -r '.[]' <<<"$ips_json")
  script+='echo MCN_CONSOLE_BACKENDS healthy=$healthy'
  message=$(az_vm_run_command --resource-group "$rg" --name "$client" \
    --command-id RunShellScript --query 'value[0].message' --output tsv --scripts "$script")
  grep -qF 'MCN_CONSOLE_BACKENDS healthy=3' <<<"$message" ||
    die "${region} does not have three reachable Site Console backends"
  printf '%s_console_backends=3/3\n' "$region"
}

verify_console_backends us "$RG" "$CLIENT" "$(tf_json ce_sli_private_ips | jq -c '[.[]]')"
verify_console_backends canada "$CA_RG" "$CA_CLIENT" "$(tf_json canada_ce_sli_private_ips | jq -c '[.[]]')"

verify_region_routing() {
  local region=$1 resource_group=$2 client_nic=$3 vip=$4 ce_ips_json=$5 rs_ips_json=$6 frr_names_json=$7 frr_ips_json=$8
  local frr_name message result ce_count rs_count vip_count route_json
  [ "$(jq 'length' <<<"$frr_names_json")" -eq 2 ] || die "${region} requires two FRR VMs"
  [ "$(jq 'length' <<<"$frr_ips_json")" -eq 2 ] || die "${region} requires two FRR peer addresses"
  jq -e 'length == 3 and all(.[]; type == "string" and test("^[0-9.]+$"))' <<<"$ce_ips_json" >/dev/null || die "${region} CE peer inventory is invalid"
  jq -e 'length == 2 and all(.[]; type == "string" and test("^[0-9.]+$"))' <<<"$rs_ips_json" >/dev/null || die "${region} Route Server peer inventory is invalid"
  local remote_script
  remote_script=$(
    cat <<PY
python3 - <<'MCN_PY'
import json, subprocess
ce_ips = set(json.loads('${ce_ips_json}'))
rs_ips = set(json.loads('${rs_ips_json}'))
vip = '${vip}/32'
def vtysh(*args):
    return json.loads(subprocess.check_output(['vtysh', '-c', ' '.join(args)], timeout=20))
summary = vtysh('show', 'bgp', 'ipv4', 'unicast', 'summary', 'json')
peers = summary.get('ipv4Unicast', summary).get('peers', {})
def established(ip):
    peer = peers.get(ip, {})
    return peer.get('state', peer.get('bgpState')) == 'Established'
routes = vtysh('show', 'bgp', 'ipv4', 'unicast', vip, 'json')
paths = routes.get('routes', {}).get(vip, routes.get('paths', routes.get(vip, [])))
if isinstance(paths, dict): paths = [paths]
learned = any(ip in str(path.get('peerId', path.get('nexthops', ''))) for path in paths for ip in ce_ips) if isinstance(paths, list) else False
print('MCN_FRR ce_established=%d rs_established=%d vip_learned=%d' %
      (sum(established(ip) for ip in ce_ips), sum(established(ip) for ip in rs_ips), int(learned)))
MCN_PY
PY
  )
  while IFS= read -r frr_name; do
    message=$(az_vm_run_command --resource-group "$resource_group" --name "$frr_name" \
      --command-id RunShellScript --query 'value[0].message' --output tsv --scripts "$remote_script")
    result=$(grep -Eo 'MCN_FRR ce_established=[0-9]+ rs_established=[0-9]+ vip_learned=[01]' <<<"$message" | tail -n 1)
    [ -n "$result" ] || die "${region} FRR did not return BGP evidence"
    read -r ce_count rs_count vip_count < <(sed -E 's/.*ce_established=([0-9]+) rs_established=([0-9]+) vip_learned=([01]).*/\1 \2 \3/' <<<"$result")
    [ "$ce_count" -eq 3 ] && [ "$rs_count" -eq 2 ] && [ "$vip_count" -eq 1 ] ||
      die "${region} FRR sessions or CE-learned VIP are unhealthy"
  done < <(jq -r '.[]' <<<"$frr_names_json")
  route_json=$(az network nic show-effective-route-table --resource-group "$resource_group" --name "$client_nic" --output json)
  jq -e --arg vip "${vip}/32" --argjson peers "$frr_ips_json" '
    [.value[]? | select(any(.addressPrefix[]?; . == $vip)) |
      .nextHopIpAddress | if type == "array" then .[] else . end] |
      map(select(type == "string" and length > 0)) | unique | sort == ($peers | sort)' \
    <<<"$route_json" >/dev/null || die "${region} client lacks both FRR VIP next hops"
  printf '%s_routing=ce_frr_6/6,frr_rs_4/4,vip_2/2,next_hops_2/2\n' "$region"
}

verify_region_routing us "$RG" "$(tf_raw client_nic_name)" "$US_VIP" \
  "$(tf_json ce_mgmt_private_ips | jq -c '[.[]]')" "$(tf_json route_server_peer_ips)" \
  "$(tf_json azure_frr_vm_names)" "$(tf_json azure_frr_peer_ips)"
verify_region_routing canada "$CA_RG" "$(tf_raw canada_client_nic_name)" "$CA_VIP" \
  "$(tf_json canada_ce_mgmt_private_ips | jq -c '[.[]]')" "$(tf_json canada_route_server_peer_ips)" \
  "$(tf_json canada_frr_vm_names)" "$(tf_json canada_frr_peer_ips)"

vip_ok=0
vip_fail=0
ca_lb_ok=0
ca_lb_fail=0
us_ilb_ok=0
us_ilb_fail=0
ca_ilb_ok=0
ca_ilb_fail=0
origin_ok=0
origin_fail=0
zero_streak=0
batches=0
converged=false

probe_region() {
  local region=$1 resource_group=$2 client=$3 domain=$4 vip=$5 inside_domain=$6 ilb_ip=$7
  local remote_script message result
  remote_script="set -u; vip_ok=0; vip_fail=0; ilb_ok=0; ilb_fail=0; origin_ok=0; origin_fail=0; \
for i in \$(seq 1 ${SAMPLES_PER_BATCH}); do \
origin_body=\$(curl -fsS -m 10 'http://${ORIGIN}/' 2>/dev/null || true); \
if [ -n \"\$origin_body\" ]; then origin_ok=\$((origin_ok+1)); else origin_fail=\$((origin_fail+1)); fi; \
body=\$(curl -fsS -m 10 --resolve '${domain}:80:${vip}' 'http://${domain}/' 2>/dev/null || true); \
if [ -n \"\$origin_body\" ] && [ \"\$body\" = \"\$origin_body\" ]; then vip_ok=\$((vip_ok+1)); else vip_fail=\$((vip_fail+1)); fi; \
body=\$(curl -fsS -m 10 --resolve '${inside_domain}:80:${ilb_ip}' 'http://${inside_domain}/' 2>/dev/null || true); \
if [ -n \"\$origin_body\" ] && [ \"\$body\" = \"\$origin_body\" ]; then ilb_ok=\$((ilb_ok+1)); else ilb_fail=\$((ilb_fail+1)); fi; \
done; echo MCN_REGION region=${region} vip_ok=\$vip_ok vip_fail=\$vip_fail ilb_ok=\$ilb_ok ilb_fail=\$ilb_fail origin_ok=\$origin_ok origin_fail=\$origin_fail"
  message=$(az_vm_run_command --resource-group "$resource_group" --name "$client" \
    --command-id RunShellScript --query 'value[0].message' --output tsv --scripts "$remote_script")
  result=$(grep -Eo "MCN_REGION region=${region} vip_ok=[0-9]+ vip_fail=[0-9]+ ilb_ok=[0-9]+ ilb_fail=[0-9]+ origin_ok=[0-9]+ origin_fail=[0-9]+" <<<"$message" | tail -n 1)
  [ -n "$result" ] || die "${region} client traffic verifier returned no aggregate result"
  read -r region_vip_ok region_vip_fail region_ilb_ok region_ilb_fail region_origin_ok region_origin_fail < <(
    sed -E 's/.*vip_ok=([0-9]+) vip_fail=([0-9]+) ilb_ok=([0-9]+) ilb_fail=([0-9]+) origin_ok=([0-9]+) origin_fail=([0-9]+).*/\1 \2 \3 \4 \5 \6/' <<<"$result"
  )
  [ $((region_vip_ok + region_vip_fail)) -eq "$SAMPLES_PER_BATCH" ] || die "${region} VIP sample count differs"
  [ $((region_ilb_ok + region_ilb_fail)) -eq "$SAMPLES_PER_BATCH" ] || die "${region} ILB sample count differs"
  [ $((region_origin_ok + region_origin_fail)) -eq "$SAMPLES_PER_BATCH" ] || die "${region} origin sample count differs"
  printf 'batch=%s region=%s vip_ok=%s vip_fail=%s ilb_ok=%s ilb_fail=%s origin_ok=%s origin_fail=%s\n' \
    "$batches" "$region" "$region_vip_ok" "$region_vip_fail" "$region_ilb_ok" "$region_ilb_fail" "$region_origin_ok" "$region_origin_fail"
}

while [ "$batches" -lt "$MAX_BATCHES" ]; do
  batches=$((batches + 1))
  probe_region us "$RG" "$CLIENT" "$DOMAIN" "$US_VIP" "$US_INSIDE_DOMAIN" "$US_ILB"
  vip_ok=$((vip_ok + region_vip_ok))
  vip_fail=$((vip_fail + region_vip_fail))
  us_ilb_ok=$((us_ilb_ok + region_ilb_ok))
  us_ilb_fail=$((us_ilb_fail + region_ilb_fail))
  origin_ok=$((origin_ok + region_origin_ok))
  origin_fail=$((origin_fail + region_origin_fail))
  batch_fail=$((region_vip_fail + region_ilb_fail + region_origin_fail))
  probe_region canada "$CA_RG" "$CA_CLIENT" "$CA_DOMAIN" "$CA_VIP" "$CA_INSIDE_DOMAIN" "$CA_ILB"
  ca_lb_ok=$((ca_lb_ok + region_vip_ok))
  ca_lb_fail=$((ca_lb_fail + region_vip_fail))
  ca_ilb_ok=$((ca_ilb_ok + region_ilb_ok))
  ca_ilb_fail=$((ca_ilb_fail + region_ilb_fail))
  origin_ok=$((origin_ok + region_origin_ok))
  origin_fail=$((origin_fail + region_origin_fail))
  batch_fail=$((batch_fail + region_vip_fail + region_ilb_fail + region_origin_fail))
  if [ "$batch_fail" -eq 0 ]; then zero_streak=$((zero_streak + 1)); else zero_streak=0; fi
  if [ $((vip_ok + vip_fail)) -ge 100 ] && [ $((ca_lb_ok + ca_lb_fail)) -ge 100 ] &&
    [ "$batches" -ge 3 ] && [ "$zero_streak" -ge 2 ]; then
    converged=true
    break
  fi
  [ "$batches" -ge "$MAX_BATCHES" ] || sleep "$BATCH_INTERVAL"
done

console_factory_rejected=0
console_generated_accepted=0
if [ "$CHECK_CONSOLE" -eq 1 ]; then
  [ -n "${MCN_FACTORY_PASSWORD:-}" ] || die "MCN_FACTORY_PASSWORD is required unless --skip-console is explicit"
  BASTION=$(tf_raw bastion_name)
  [ -n "$BASTION" ] && [ "$BASTION" != "null" ] || die "Azure Bastion must be enabled for Site Console verification"
  VM_IDS=$(tf_json ce_vm_ids)
  GENERATED_PASSWORDS=$(tf_json site_console_admin_passwords)
  index=0
  while IFS= read -r key; do
    port=$((65500 + index))
    vm_id=$(jq -r --arg key "$key" '.[$key]' <<<"$VM_IDS")
    generated_password=$(jq -r --arg key "$key" '.[$key]' <<<"$GENERATED_PASSWORDS")
    az network bastion tunnel \
      --name "$BASTION" \
      --resource-group "$RG" \
      --target-resource-id "$vm_id" \
      --resource-port 65500 \
      --port "$port" >"${EVIDENCE_DIR}/bastion-tunnel-${index}.log" 2>&1 &
    tunnel_pid=$!
    ready=0
    for _ in $(seq 1 60); do
      if curl -ksS --max-time 2 -o /dev/null "https://127.0.0.1:${port}/"; then
        ready=1
        break
      fi
      sleep 2
    done
    if [ "$ready" -ne 1 ]; then
      kill "$tunnel_pid" 2>/dev/null || true
      wait "$tunnel_pid" 2>/dev/null || true
      die "one Site Console tunnel did not become ready"
    fi
    factory_auth=$(printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "$MCN_FACTORY_PASSWORD" | base64)" |
      curl -ksS --max-time 10 -o /dev/null -w '%{http_code}' -H @- "https://127.0.0.1:${port}/")
    generated_auth=$(printf 'Authorization: Basic %s\n' "$(printf 'admin:%s' "$generated_password" | base64)" |
      curl -ksS --max-time 10 -o /dev/null -w '%{http_code}' -H @- "https://127.0.0.1:${port}/")
    kill "$tunnel_pid" 2>/dev/null || true
    wait "$tunnel_pid" 2>/dev/null || true
    [ "$factory_auth" != "200" ] || die "the factory Site Console credential still authenticates"
    [ "$generated_auth" = "200" ] || die "a generated Site Console credential does not authenticate"
    console_factory_rejected=$((console_factory_rejected + 1))
    console_generated_accepted=$((console_generated_accepted + 1))
    generated_password=""
    index=$((index + 1))
  done < <(jq -r 'keys[]' <<<"$SITES")
  printf 'console_factory_rejected=%s/%s\n' "$console_factory_rejected" "$SITE_COUNT"
  printf 'console_generated_accepted=%s/%s\n' "$console_generated_accepted" "$SITE_COUNT"
fi

FINISHED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
jq -n \
  --arg started_at "$STARTED_AT" \
  --arg finished_at "$FINISHED_AT" \
  --argjson sites_online "$sites_online" \
  --argjson azure_vms_running "$azure_vms_running" \
  --argjson password_extensions_succeeded "$password_extensions_succeeded" \
  --arg us_ilb_reachable "yes" \
  --arg canada_ilb_reachable "yes" \
  --argjson us_console_backends 3 \
  --argjson canada_console_backends 3 \
  --argjson batches "$batches" \
  --argjson vip_samples "$((vip_ok + vip_fail))" \
  --argjson vip_failures "$vip_fail" \
  --argjson ca_lb_samples "$((ca_lb_ok + ca_lb_fail))" \
  --argjson ca_lb_failures "$ca_lb_fail" \
  --argjson us_ilb_samples "$((us_ilb_ok + us_ilb_fail))" \
  --argjson us_ilb_failures "$us_ilb_fail" \
  --argjson ca_ilb_samples "$((ca_ilb_ok + ca_ilb_fail))" \
  --argjson ca_ilb_failures "$ca_ilb_fail" \
  --argjson origin_samples "$((origin_ok + origin_fail))" \
  --argjson origin_failures "$origin_fail" \
  --argjson console_factory_rejected "$console_factory_rejected" \
  --argjson console_generated_accepted "$console_generated_accepted" \
  --argjson converged "$converged" \
  '{
    started_at: $started_at,
    finished_at: $finished_at,
    sites_online: $sites_online,
    azure_vms_running: $azure_vms_running,
    password_extensions_succeeded: $password_extensions_succeeded,
    us_ilb_reachable: $us_ilb_reachable,
    canada_ilb_reachable: $canada_ilb_reachable,
    us_console_backends: $us_console_backends,
    canada_console_backends: $canada_console_backends,
    batches: $batches,
    vip_samples: $vip_samples,
    vip_failures: $vip_failures,
    ca_lb_samples: $ca_lb_samples,
    ca_lb_failures: $ca_lb_failures,
    us_ilb_samples: $us_ilb_samples,
    us_ilb_failures: $us_ilb_failures,
    ca_ilb_samples: $ca_ilb_samples,
    ca_ilb_failures: $ca_ilb_failures,
    origin_samples: $origin_samples,
    origin_failures: $origin_failures,
    console_factory_rejected: $console_factory_rejected,
    console_generated_accepted: $console_generated_accepted,
    converged: $converged
  }' >"${EVIDENCE_DIR}/summary.json"

printf 'vip_samples=%s vip_failures=%s\n' "$((vip_ok + vip_fail))" "$vip_fail"
printf 'ca_lb_samples=%s ca_lb_failures=%s\n' "$((ca_lb_ok + ca_lb_fail))" "$ca_lb_fail"
printf 'us_ilb_samples=%s us_ilb_failures=%s\n' "$((us_ilb_ok + us_ilb_fail))" "$us_ilb_fail"
printf 'ca_ilb_samples=%s ca_ilb_failures=%s\n' "$((ca_ilb_ok + ca_ilb_fail))" "$ca_ilb_fail"
printf 'origin_samples=%s origin_failures=%s\n' "$((origin_ok + origin_fail))" "$origin_fail"
if [ "$converged" = true ]; then
  echo 'converged=yes'
else
  echo 'converged=no'
  exit 1
fi
