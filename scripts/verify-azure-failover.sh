#!/usr/bin/env bash
# Exercise one CE and one FRR failure independently in each Azure region.
set -euo pipefail

TERRAFORM_DIR=""
EVIDENCE_DIR=""
SUBSCRIPTION=""
SOURCE_COMMIT=""
while [ "$#" -gt 0 ]; do
  case "$1" in
  --terraform-dir)
    TERRAFORM_DIR=${2:?}
    shift 2
    ;;
  --evidence-dir)
    EVIDENCE_DIR=${2:?}
    shift 2
    ;;
  --subscription)
    SUBSCRIPTION=${2:?}
    shift 2
    ;;
  --source-commit)
    SOURCE_COMMIT=${2:?}
    shift 2
    ;;
  *)
    echo "verify-azure-failover: unknown argument $1" >&2
    exit 2
    ;;
  esac
done
die() {
  echo "verify-azure-failover: $*" >&2
  exit 2
}
[ -d "$TERRAFORM_DIR" ] && [ -n "$EVIDENCE_DIR" ] && [ -n "$SUBSCRIPTION" ] || die "Terraform, evidence, and subscription inputs are required"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] || die "reviewed source commit is required"
mkdir -p "$EVIDENCE_DIR"
chmod 700 "$EVIDENCE_DIR"
az() { command az "$@" --subscription "$SUBSCRIPTION"; }
tf_raw() { terraform -chdir="$TERRAFORM_DIR" output -raw "$1"; }
tf_json() { terraform -chdir="$TERRAFORM_DIR" output -json "$1"; }

recover_rg=""
recover_vm=""
recover() {
  local status=$?
  if [ -n "$recover_vm" ]; then
    az vm start --resource-group "$recover_rg" --name "$recover_vm" --only-show-errors >/dev/null || true
  fi
  exit "$status"
}
trap recover EXIT

frr_sessions() {
  local rg=$1 vm=$2 ce_ips_json=$3 rs_ips_json=$4 vip=$5
  local script result
  script=$(
    cat <<PY
python3 - <<'MCN_PY'
import json, subprocess
ce = set(json.loads('${ce_ips_json}'))
rs = set(json.loads('${rs_ips_json}'))
summary = json.loads(subprocess.check_output(['vtysh','-c','show bgp ipv4 unicast summary json'], timeout=20))
peers = summary.get('ipv4Unicast', summary).get('peers', {})
def up(ip):
    item = peers.get(ip, {})
    return item.get('state', item.get('bgpState')) == 'Established'
routes = json.loads(subprocess.check_output(['vtysh','-c','show bgp ipv4 unicast ${vip}/32 json'], timeout=20))
paths = routes.get('routes', {}).get('${vip}/32', routes.get('paths', routes.get('${vip}/32', [])))
if isinstance(paths, dict): paths = [paths]
learned = isinstance(paths, list) and any(ip in str(path.get('peerId', path.get('nexthops',''))) for path in paths for ip in ce)
print('MCN_FAILOVER ce=%d rs=%d vip=%d' % (sum(up(ip) for ip in ce), sum(up(ip) for ip in rs), int(learned)))
MCN_PY
PY
  )
  result=$(az vm run-command invoke --resource-group "$rg" --name "$vm" --command-id RunShellScript \
    --query 'value[0].message' --output tsv --scripts "$script") || return 1
  grep -Eo 'MCN_FAILOVER ce=[0-9]+ rs=[0-9]+ vip=[01]' <<<"$result" | tail -n 1
}

client_next_hops() {
  local rg=$1 nic=$2 vip=$3 expected_json=$4 routes
  routes=$(az network nic show-effective-route-table --resource-group "$rg" --name "$nic" --output json) || return 1
  jq -e --arg vip "${vip}/32" --argjson expected "$expected_json" '
    [.value[]? | select(any(.addressPrefix[]?; . == $vip)) |
      .nextHopIpAddress | if type == "array" then .[] else . end] |
      map(select(type == "string" and length > 0)) | unique | sort == ($expected | sort)' \
    <<<"$routes" >/dev/null
}

traffic() {
  local rg=$1 client=$2 domain=$3 vip=$4 inside_domain=$5 ilb=$6 console_ip=$7 result
  result=$(az vm run-command invoke --resource-group "$rg" --name "$client" --command-id RunShellScript \
    --query 'value[0].message' --output tsv --scripts \
    "set -eu; ok=0; for i in \$(seq 1 20); do a=\$(curl -fsS -m 10 --resolve '${domain}:80:${vip}' 'http://${domain}/'); b=\$(curl -fsS -m 10 --resolve '${inside_domain}:80:${ilb}' 'http://${inside_domain}/'); [ -n \"\$a\" ] && [ -n \"\$b\" ]; ok=\$((ok+1)); done; timeout 10 bash -c '</dev/tcp/${console_ip}/65500'; echo MCN_FAILOVER_TRAFFIC ok=\$ok") || return 1
  grep -qF 'MCN_FAILOVER_TRAFFIC ok=20' <<<"$result"
}

wait_state() {
  local deadline=$((SECONDS + 900)) rg=$1 nic=$2 vip=$3 frr=$4 ce_ips=$5 rs_ips=$6 expected_ce=$7 expected_hops=$8
  local result
  while ((SECONDS < deadline)); do
    result=$(frr_sessions "$rg" "$frr" "$ce_ips" "$rs_ips" "$vip" 2>/dev/null || true)
    if [ "$result" = "MCN_FAILOVER ce=${expected_ce} rs=2 vip=1" ] &&
      client_next_hops "$rg" "$nic" "$vip" "$expected_hops"; then return 0; fi
    sleep 30
  done
  return 1
}

run_region() {
  local region=$1 rg=$2 client=$3 nic=$4 vip=$5 domain=$6 inside_domain=$7 ilb=$8 console_ip=$9
  shift 9
  local ce_vms=$1 frr_vms=$2 ce_ips=$3 rs_ips=$4 frr_ips=$5
  local ce_vm frr_vm survivor_ip survivor_vm
  ce_vm=$(jq -r 'to_entries | sort_by(.key) | .[0].value' <<<"$ce_vms")
  frr_vm=$(jq -r '.[0]' <<<"$frr_vms")
  survivor_vm=$(jq -r '.[1]' <<<"$frr_vms")
  survivor_ip=$(jq -r '.[1]' <<<"$frr_ips")
  [ -n "$ce_vm" ] && [ -n "$frr_vm" ] && [ -n "$survivor_vm" ] || die "$region VM inventory is incomplete"

  recover_rg=$rg
  recover_vm=$ce_vm
  az vm stop --resource-group "$rg" --name "$ce_vm" --only-show-errors >/dev/null
  wait_state "$rg" "$nic" "$vip" "$survivor_vm" "$ce_ips" "$rs_ips" 2 "$frr_ips" || die "$region CE failure did not withdraw one direct session"
  traffic "$rg" "$client" "$domain" "$vip" "$inside_domain" "$ilb" "$console_ip" || die "$region traffic failed during CE stop"
  az vm start --resource-group "$rg" --name "$ce_vm" --only-show-errors >/dev/null
  wait_state "$rg" "$nic" "$vip" "$survivor_vm" "$ce_ips" "$rs_ips" 3 "$frr_ips" || die "$region CE recovery failed"
  recover_vm=""
  jq -n --arg region "$region" --arg commit "$SOURCE_COMMIT" \
    '{region:$region,source_commit:$commit,stage:"ce",sessions_during_failure:2,traffic_samples:20,recovered:true}' \
    >"$EVIDENCE_DIR/${region}-ce.json"

  recover_rg=$rg
  recover_vm=$frr_vm
  az vm stop --resource-group "$rg" --name "$frr_vm" --only-show-errors >/dev/null
  wait_state "$rg" "$nic" "$vip" "$survivor_vm" "$ce_ips" "$rs_ips" 3 "[\"$survivor_ip\"]" || die "$region FRR failure did not withdraw its VIP next hop"
  traffic "$rg" "$client" "$domain" "$vip" "$inside_domain" "$ilb" "$console_ip" || die "$region traffic failed during FRR stop"
  az vm start --resource-group "$rg" --name "$frr_vm" --only-show-errors >/dev/null
  wait_state "$rg" "$nic" "$vip" "$frr_vm" "$ce_ips" "$rs_ips" 3 "$frr_ips" || die "$region FRR recovery failed"
  recover_vm=""
  jq -n --arg region "$region" --arg commit "$SOURCE_COMMIT" \
    '{region:$region,source_commit:$commit,stage:"frr",next_hops_during_failure:1,traffic_samples:20,recovered:true}' \
    >"$EVIDENCE_DIR/${region}-frr.json"
}

run_region us "$(tf_raw resource_group_name)" "$(tf_raw client_vm_name)" "$(tf_raw client_nic_name)" \
  "$(tf_raw vip)" "$(tf_raw lb_domain)" "$(tf_raw azure_ilb_application_domain)" \
  "$(tf_raw azure_ilb_private_ip)" "$(tf_raw azure_ilb_console_ip)" \
  "$(tf_json ce_vm_names)" "$(tf_json azure_frr_vm_names)" \
  "$(tf_json ce_mgmt_private_ips | jq -c '[.[]]')" "$(tf_json route_server_peer_ips)" "$(tf_json azure_frr_peer_ips)"
run_region canada "$(tf_raw ca_resource_group_name)" "$(tf_raw ca_client_vm_name)" "$(tf_raw canada_client_nic_name)" \
  "$(tf_raw ca_vip)" "$(tf_raw ca_lb_domain)" "$(tf_raw canada_ilb_application_domain)" \
  "$(tf_raw canada_ilb_private_ip)" "$(tf_raw canada_ilb_console_ip)" \
  "$(tf_json ca_ce_vm_names)" "$(tf_json canada_frr_vm_names)" \
  "$(tf_json canada_ce_mgmt_private_ips | jq -c '[.[]]')" "$(tf_json canada_route_server_peer_ips)" "$(tf_json canada_frr_peer_ips)"
