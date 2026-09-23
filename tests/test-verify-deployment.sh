#!/usr/bin/env bash
# Hermetic acceptance tests for scripts/verify-deployment.sh. Terraform, Azure,
# and XC are stubbed so the aggregate gates are exercised without credentials or
# network access.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="${REPO_ROOT}/scripts/verify-deployment.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

FAIL=0
ok() { printf '  ok   — %s\n' "$1"; }
bad() {
  printf '  FAIL — %s\n' "$1"
  FAIL=1
}

mkdir -p "${WORK}/bin"

cat >"${WORK}/bin/terraform" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-chdir=terraform" ]; then shift; fi
case "${1:-} ${2:-} ${3:-}" in
"version -json ")
  printf '{"terraform_version":"1.16.1","provider_selections":{"registry.terraform.io/f5-sales-demo/xcsh":"10.1.0"}}\n'
  ;;
"output -json xc_site_names")
  printf '{"eastus01":"site-01","eastus02":"site-02","eastus03":"site-03"}\n'
  ;;
"output -json ca_xc_site_names")
  printf '{"canadacentral01":"ca-site-01","canadacentral02":"ca-site-02","canadacentral03":"ca-site-03"}\n'
  ;;
"output -json ce_vm_names")
  printf '{"eastus01":"ce-01","eastus02":"ce-02","eastus03":"ce-03"}\n'
  ;;
"output -json ca_ce_vm_names")
  printf '{"canadacentral01":"ca-ce-01","canadacentral02":"ca-ce-02","canadacentral03":"ca-ce-03"}\n'
  ;;
"output -json ce_vm_ids")
  printf '{"eastus01":"/subscriptions/000/resourceGroups/rg-example/providers/Microsoft.Compute/virtualMachines/ce-01","eastus02":"/subscriptions/000/resourceGroups/rg-example/providers/Microsoft.Compute/virtualMachines/ce-02","eastus03":"/subscriptions/000/resourceGroups/rg-example/providers/Microsoft.Compute/virtualMachines/ce-03"}\n'
  ;;
"output -json site_console_admin_passwords")
  printf '{"eastus01":"<GENERATED_PASSWORD_01>","eastus02":"<GENERATED_PASSWORD_02>","eastus03":"<GENERATED_PASSWORD_03>"}\n'
  ;;
"output -json ")
  printf '{"xc_site_names":{"sensitive":false,"value":{"eastus01":"site-01","eastus02":"site-02","eastus03":"site-03"}}}\n'
  ;;
"output -raw resource_group_name") printf 'rg-example\n' ;;
"output -raw client_vm_name") printf 'client-example\n' ;;
"output -raw ca_resource_group_name") printf 'rg-ca-example\n' ;;
"output -raw ca_client_vm_name") printf 'ca-client-example\n' ;;
"output -raw azure_ilb_private_ip") printf '10.0.1.10\n' ;;
"output -raw canada_ilb_private_ip") printf '10.200.1.10\n' ;;
"output -raw lb_domain") printf 'mcn.example.com\n' ;;
"output -raw ca_lb_domain") printf 'mcn-ca.example.com\n' ;;
"output -raw vip") printf '10.250.0.10\n' ;;
"output -raw origin_ip") printf '198.51.100.10\n' ;;
"output -raw bastion_name") printf 'bastion-example\n' ;;
*) printf 'unexpected terraform call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF

cat >"${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"%{http_code}"* ]]; then
  header=$(cat)
  factory=$(printf 'admin:%s' '<FACTORY_SITE_CONSOLE_PASSWORD>' | base64)
  if grep -qF "$factory" <<<"$header"; then
    printf '401'
  elif [[ "$*" == *"mcn-ca.example.com"* ]] && [ "${CURL_CANADA_LB_MODE:-ok}" = "fail" ]; then
    printf '503'
  else
    printf '200'
  fi
elif [[ "$*" == *"127.0.0.1"* ]]; then
  exit 0
else
  cat >/dev/null
  printf '{"spec":{"site_state":"ONLINE"}}\n'
fi
EOF

cat >"${WORK}/bin/az" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
*"vm get-instance-view"*)
  vm_name=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--name" ]; then vm_name=$2; break; fi
    shift
  done
  if [ "${AZ_VM_MODE:-ok}" = "stuck" ] && [ "$vm_name" = "ce-03" ]; then
    printf '{"provisioningState":"Updating","powerState":"PowerState/starting"}\n'
  else
    printf '{"provisioningState":"Succeeded","powerState":"PowerState/running"}\n'
  fi
  ;;
*"vm extension show"*)
  vm_name=""
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--vm-name" ]; then vm_name=$2; break; fi
    shift
  done
  if [ "${AZ_EXTENSION_MODE:-ok}" = "stuck" ] && [ "$vm_name" = "ce-03" ]; then
    printf 'Creating\n'
  else
    printf 'Succeeded\n'
  fi
  ;;
*"vm run-command invoke"*)
  if [[ "$*" == *"MCN_ILB"* ]]; then
    if [ "${AZ_ILB_MODE:-ok}" = "missing" ]; then
      printf 'MCN_ILB reachable=0\n'
    else
      printf 'MCN_ILB reachable=1\n'
    fi
    exit 0
  fi
  if [ "${AZ_RUN_COMMAND_MODE:-ok}" = "conflict-once" ] &&
    [ ! -e "${AZ_RUN_COMMAND_COUNT_FILE:?}" ]; then
    : >"$AZ_RUN_COMMAND_COUNT_FILE"
    printf '%s\n' 'ERROR: (Conflict) Run command extension execution is in progress. Please wait for completion before invoking a run command.' >&2
    exit 1
  fi
  if [ "${CURL_CANADA_LB_MODE:-ok}" = "fail" ]; then
    printf 'MCN_UAT vip_ok=50 vip_fail=0 ca_lb_ok=0 ca_lb_fail=50 origin_ok=25 origin_fail=0\n'
  else
    printf 'MCN_UAT vip_ok=50 vip_fail=0 ca_lb_ok=50 ca_lb_fail=0 origin_ok=25 origin_fail=0\n'
  fi
  ;;
*"network bastion tunnel"*)
  sleep 30
  ;;
*) printf 'unexpected az call: %s\n' "$*" >&2; exit 2 ;;
esac
EOF
chmod +x "${WORK}/bin/terraform" "${WORK}/bin/curl" "${WORK}/bin/az"

run_uat() {
  PATH="${WORK}/bin:${PATH}" \
    XCSH_API_URL="https://example.invalid" \
    XCSH_API_TOKEN="<XC_API_TOKEN>" \
    MCN_UAT_TEST_MODE=1 \
    bash "$SCRIPT" \
    --terraform-dir terraform \
    --evidence-dir "${WORK}/evidence-$1" \
    --samples-per-batch 50 \
    --max-batches 3 \
    --batch-interval 0 \
    --skip-console
}

echo "1. healthy deployment passes every aggregate gate"
if OUT=$(run_uat healthy 2>&1); then
  for expected in 'sites_online=6/6' 'azure_vms_running=6/6' 'password_extensions_succeeded=6/6' 'us_ilb_reachable=yes' 'canada_ilb_reachable=yes' 'vip_samples=150' 'ca_lb_samples=150' 'ca_lb_failures=0' 'origin_failures=0' 'converged=yes'; do
    if grep -qF "$expected" <<<"$OUT"; then
      ok "reported ${expected}"
    else
      bad "missing ${expected} from output"
    fi
  done
  if jq -e '.sites_online == 6 and .azure_vms_running == 6 and .password_extensions_succeeded == 6 and .us_ilb_reachable == "yes" and .canada_ilb_reachable == "yes" and .vip_samples == 150 and .ca_lb_samples == 150 and .ca_lb_failures == 0 and .converged == true' "${WORK}/evidence-healthy/summary.json" >/dev/null; then
    ok "wrote a machine-readable aggregate summary"
  else
    bad "aggregate summary is missing or incorrect"
  fi
  if jq -e '.xc_site_names.value | length == 3' "${WORK}/evidence-healthy/terraform-output.json" >/dev/null; then
    ok "wrote the private Terraform output snapshot"
  else
    bad "Terraform output snapshot is missing"
  fi
else
  bad "healthy UAT failed: ${OUT}"
fi

echo "2. a CE stuck in Azure provisioning fails the UAT"
if AZ_VM_MODE=stuck run_uat stuck-vm >/dev/null 2>&1; then
  bad "UAT passed with one CE still starting in Azure"
else
  ok "rejected the stuck Azure VM"
fi

echo "3. a stuck password-rotation extension fails the UAT"
if AZ_EXTENSION_MODE=stuck run_uat stuck-extension >/dev/null 2>&1; then
  bad "UAT passed with one password extension still creating"
else
  ok "rejected the stuck Azure VM extension"
fi

echo "4. an unreachable ILB fails the UAT"
if AZ_ILB_MODE=missing run_uat missing-ilb >/dev/null 2>&1; then
  bad "UAT passed with an unreachable ILB"
else
  ok "rejected the unreachable ILB"
fi

echo "5. Canadian advertised-LB traffic loss fails the UAT"
if CURL_CANADA_LB_MODE=fail run_uat canada-lb-failure >/dev/null 2>&1; then
  bad "UAT passed with Canadian advertised-LB traffic loss"
else
  ok "rejected Canadian advertised-LB traffic loss"
fi

echo "6. fewer than 100 possible samples is rejected before any API call"
if PATH="${WORK}/bin:${PATH}" MCN_UAT_TEST_MODE=1 bash "$SCRIPT" \
  --terraform-dir terraform \
  --evidence-dir "${WORK}/evidence-too-small" \
  --samples-per-batch 30 \
  --max-batches 3 \
  --batch-interval 0 \
  --skip-console >/dev/null 2>&1; then
  bad "accepted a run capped below 100 samples"
else
  ok "enforced the 100-sample minimum"
fi

echo "7. a transient Azure Run Command conflict is retried"
if OUT=$(AZ_RUN_COMMAND_MODE=conflict-once \
  AZ_RUN_COMMAND_COUNT_FILE="${WORK}/run-command-conflict-seen" \
  run_uat transient-conflict 2>&1); then
  if grep -qF 'converged=yes' <<<"$OUT"; then
    ok "recovered from the transient Azure conflict"
  else
    bad "retry run completed without convergence evidence"
  fi
else
  bad "transient Azure conflict aborted the UAT: ${OUT}"
fi

echo "8. factory credentials fail and generated credentials pass on every console"
if OUT=$(PATH="${WORK}/bin:${PATH}" \
  XCSH_API_URL="https://example.invalid" \
  XCSH_API_TOKEN="<XC_API_TOKEN>" \
  MCN_FACTORY_PASSWORD="<FACTORY_SITE_CONSOLE_PASSWORD>" \
  MCN_UAT_TEST_MODE=1 \
  bash "$SCRIPT" \
  --terraform-dir terraform \
  --evidence-dir "${WORK}/evidence-console" \
  --samples-per-batch 50 \
  --max-batches 3 \
  --batch-interval 0 2>&1); then
  for expected in 'console_factory_rejected=3/3' 'console_generated_accepted=3/3'; do
    if grep -qF "$expected" <<<"$OUT"; then
      ok "reported ${expected}"
    else
      bad "missing ${expected} from output"
    fi
  done
else
  bad "Site Console UAT failed: ${OUT}"
fi

echo "9. the default verifier uses only the supported ILB topology"
if rg -qi 'routeserver peering|show-effective-route-table|effective_next_hops|peerings_with_vip' "$SCRIPT"; then
  bad "default verifier still contains an Azure Route Server verification path"
else
  ok "default verifier contains no Azure Route Server verification path"
fi
if rg -q 'azure_ilb_private_ip' "$SCRIPT" && rg -q 'canada_ilb_private_ip' "$SCRIPT"; then
  ok "default verifier requires both US and Canada ILB endpoints"
else
  bad "default verifier does not require both supported ILB endpoints"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: deployment UAT harness"
else
  echo "FAIL: deployment UAT harness"
fi
exit "$FAIL"
