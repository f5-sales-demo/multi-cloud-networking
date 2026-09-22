#!/usr/bin/env bash
# Drive the complete AWS + KVM showcase lifecycle from the unified Terraform
# root. Every terraform plan is saved, checked, and applied by exact digest.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TERRAFORM_DIR="$REPO_ROOT/terraform"
TFVARS="$TERRAFORM_DIR/terraform.tfvars"
BACKEND_CONFIG="$TERRAFORM_DIR/backend.hcl"
CREDENTIAL_FILE="$(getent passwd "$(id -un)" | cut -d: -f6)/PASSWORDS.txt"
AWS_PROFILE=sso
AWS_REGION=ap-northeast-1
AWS_ACCOUNT=280469140135
XC_TENANT=f5-sales-demo
COMPONENT=mcn-ce-ha
GENERATION=smsv2
MODE=full
PRIVATE_ROOT=""
CREATOR_ID=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)

usage() {
  cat <<'EOF'
Usage: showcase-lifecycle.sh [--mode full|build|verify|destroy] [options]

Options:
  --tfvars PATH             Ignored unified-root variables file.
  --backend-config PATH     Ignored AWS S3 backend configuration.
  --credentials-file PATH  Protected XC URL/token file.
  --private-root PATH       Empty directory outside the repository for plans.
  --aws-profile NAME        AWS SSO profile (default: sso).
  --creator-id EMAIL        Expected XC object creator.

full performs clean teardown when state exists, build/verify, controlled ENI
tag drift repair, reviewed full teardown, absence proof, and a second build.
The second verified AWS + KVM deployment is intentionally left online.
EOF
}

die() {
  printf 'showcase-lifecycle: %s\n' "$*" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --mode)
    MODE=${2:?}
    shift 2
    ;;
  --tfvars)
    TFVARS=${2:?}
    shift 2
    ;;
  --backend-config)
    BACKEND_CONFIG=${2:?}
    shift 2
    ;;
  --credentials-file)
    CREDENTIAL_FILE=${2:?}
    shift 2
    ;;
  --private-root)
    PRIVATE_ROOT=${2:?}
    shift 2
    ;;
  --aws-profile)
    AWS_PROFILE=${2:?}
    shift 2
    ;;
  --creator-id)
    CREATOR_ID=${2:?}
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1" ;;
  esac
done
case "$MODE" in full | build | verify | destroy) ;; *) die "invalid --mode" ;; esac

for command_name in aws curl getent jq stat sudo systemctl terraform sha256sum virsh; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done
[ -n "$CREATOR_ID" ] || die "Git user.email is required for ownership checks"
[ -r "$TFVARS" ] || die "tfvars file is unavailable"
[ -r "$BACKEND_CONFIG" ] || die "backend configuration is unavailable"
[ -r "$CREDENTIAL_FILE" ] || die "XC credential file is unavailable"

credential_owner=$(stat -c %U "$CREDENTIAL_FILE")
credential_mode=$(stat -c %a "$CREDENTIAL_FILE")
[ "$credential_owner" = "$(id -un)" ] || die "XC credential file owner mismatch"
(((8#$credential_mode & 077) == 0)) || die "XC credential file must not be group/world accessible"

XCSH_API_URL_VALUE=""
XCSH_API_TOKEN_VALUE=""
url_count=0
token_count=0
while IFS= read -r credential_line || [ -n "$credential_line" ]; do
  credential_line=${credential_line%$'\r'}
  case "$credential_line" in '' | \#*) continue ;; esac
  [[ "$credential_line" == *=* ]] || die "credential file contains a malformed line"
  credential_key=${credential_line%%=*}
  credential_value=${credential_line#*=}
  case "$credential_key" in
  XCSH_API_URL)
    XCSH_API_URL_VALUE=$credential_value
    url_count=$((url_count + 1))
    ;;
  XCSH_API_TOKEN)
    XCSH_API_TOKEN_VALUE=$credential_value
    token_count=$((token_count + 1))
    ;;
  *) die "credential file contains an unexpected key" ;;
  esac
done <"$CREDENTIAL_FILE"
[ "$url_count" -eq 1 ] && [ "$token_count" -eq 1 ] || die "credential file must contain each XC key exactly once"
[ "$XCSH_API_URL_VALUE" = "https://${XC_TENANT}.console.ves.volterra.io" ] || die "XC tenant URL mismatch"
[ -n "$XCSH_API_TOKEN_VALUE" ] || die "XC API token is empty"
export XCSH_API_URL="$XCSH_API_URL_VALUE"
export XCSH_API_TOKEN="$XCSH_API_TOKEN_VALUE"
unset XCSH_API_URL_VALUE XCSH_API_TOKEN_VALUE credential_line credential_value

if [ -z "$PRIVATE_ROOT" ]; then
  PRIVATE_ROOT="/home/$(id -un)/.local/state/multi-cloud-networking/showcase-$(date -u +%Y%m%dT%H%M%SZ)"
fi
case "$(realpath -m "$PRIVATE_ROOT")/" in "$REPO_ROOT"/*) die "private root must be outside the repository" ;; esac
mkdir -p "$PRIVATE_ROOT"
chmod 700 "$PRIVATE_ROOT"
umask 077

TF_RUNNER=("$REPO_ROOT/scripts/terraform-with-aws-sso.sh" --profile "$AWS_PROFILE" --region "$AWS_REGION" --)
tf() {
  "${TF_RUNNER[@]}" -chdir="$TERRAFORM_DIR" "$@"
}

terraform_version=$(terraform version -json | jq -r .terraform_version)
[ "$terraform_version" = 1.16.3 ] || die "Terraform 1.16.3 is required"
caller_account=$(AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_SDK_LOAD_CONFIG=1 \
  aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" --query Account --output text) ||
  die "AWS SSO identity is unavailable"
[ "$caller_account" = "$AWS_ACCOUNT" ] || die "AWS account mismatch"
unset caller_account

tf init -reconfigure -input=false -lockfile=readonly -backend-config="$BACKEND_CONFIG"

libvirt_unit=""
for candidate in libvirtd.service virtqemud.service; do
  if systemctl list-unit-files "$candidate" --no-legend 2>/dev/null | grep -q "^${candidate}"; then
    libvirt_unit=$candidate
    break
  fi
done
[ -n "$libvirt_unit" ] || die "no supported libvirt service is installed"
sudo -n systemctl enable --now "$libvirt_unit"
systemctl is-active --quiet "$libvirt_unit" || die "libvirt service did not become active"
systemctl is-active --quiet docker.service || sudo -n systemctl enable --now docker.service

final_sites=()
bootstrap_sites=()
for key in 01 02 03; do
  final_sites+=("${COMPONENT}-${GENERATION}-aws-${AWS_REGION}-${key}")
  bootstrap_sites+=("${COMPONENT}-${GENERATION}-aws-${AWS_REGION}-${key}-bootstrap")
done

common_phase_args=(
  --tfvars "$TFVARS"
  --expected-aws-account "$AWS_ACCOUNT"
  --expected-aws-region "$AWS_REGION"
  --expected-xc-tenant "$XC_TENANT"
  --creator-id "$CREATOR_ID"
  --deployment-generation "$GENERATION"
  --component "$COMPONENT"
)

phase_paths() {
  local cycle=$1 phase=$2 step=$3
  PHASE_DIR="$PRIVATE_ROOT/${cycle}-${phase}-${step}"
  PLAN_FILE="$PHASE_DIR/showcase.tfplan"
  EVIDENCE_DIR="$PHASE_DIR/evidence"
  mkdir -p "$EVIDENCE_DIR"
  chmod 700 "$PHASE_DIR" "$EVIDENCE_DIR"
}

run_phase() {
  local cycle=$1 phase=$2 step=$3 configured_tgw=${4:-true}
  local -a args=("${common_phase_args[@]}" --phase "$phase") sites=()
  phase_paths "$cycle" "$phase" "$step"
  case "$phase" in
  bootstrap | bootstrap_retirement) sites=("${bootstrap_sites[@]}") ;;
  configured) sites=("${final_sites[@]}") ;;
  esac
  args+=(--plan-file "$PLAN_FILE" --evidence-dir "$EVIDENCE_DIR")
  for site in "${sites[@]}"; do args+=(--expected-site "$site"); done
  if [ "$phase" = configured ]; then
    args+=(--mapping-file "$MAPPING_FILE" --registration-projection "$REGISTRATION_PROJECTION"
      --eni-projection "$ENI_PROJECTION" --configured-tgw "$configured_tgw")
  fi
  "$REPO_ROOT/scripts/aws-smsv2-lifecycle-plan.sh" "${args[@]}"
  "$REPO_ROOT/scripts/aws-smsv2-lifecycle-plan.sh" "${args[@]}" --apply
  rm -f -- "$PLAN_FILE"
}

wait_for_approvals() {
  local phase=$1 expected_aws=$2 expected_kvm=$3 deadline=$((SECONDS + 5400))
  local probe="$PRIVATE_ROOT/registration-wait.tfplan" aws_count kvm_count
  local -a args=(-input=false -no-color -lock=false -var-file="$TFVARS"
    -var="aws_site_configuration_phase=$phase" -var='enable_aws_tgw_connect=false')
  if [ "$phase" = configured ]; then
    args+=(-var="aws_smsv2_device_mapping_file=$MAPPING_FILE")
  fi
  while ((SECONDS < deadline)); do
    if tf plan "${args[@]}" -out="$probe" >/dev/null 2>&1; then
      read -r aws_count kvm_count < <(tf show -json "$probe" | jq -r '
        [([.resource_changes[]? | select(.type == "xcsh_registration_approval" and .name == "aws" and .change.actions == ["create"])] | length),
         ([.resource_changes[]? | select(.type == "xcsh_registration_approval" and .name == "kvm" and .change.actions == ["create"])] | length)] | @tsv')
      if [ "$aws_count" -eq "$expected_aws" ] && [ "$kvm_count" -eq "$expected_kvm" ]; then
        rm -f -- "$probe"
        return 0
      fi
    fi
    rm -f -- "$probe"
    sleep 30
  done
  die "registration approval plan did not converge before the bounded deadline"
}

capture_bootstrap_mapping_inputs() {
  REGISTRATION_PROJECTION="$CYCLE_DIR/aws-registration-projection.json"
  ENI_PROJECTION="$CYCLE_DIR/aws-eni-projection.json"
  MAPPING_FILE="$CYCLE_DIR/aws-device-mapping.json"
  tf output -json aws_smsv2_bootstrap_registration_projection >"$REGISTRATION_PROJECTION"
  tf output -json aws_smsv2_owned_eni_projection >"$ENI_PROJECTION"
  chmod 600 "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  "$REPO_ROOT/scripts/generate-aws-smsv2-device-mapping.py" \
    --registration-file "$REGISTRATION_PROJECTION" --eni-file "$ENI_PROJECTION" --output "$MAPPING_FILE"
}

verify_configured() {
  local cycle=$1 step=$2 execute_uat=${3:-false}
  local -a args=("${common_phase_args[@]}" --phase configured --configured-tgw true
    --mapping-file "$MAPPING_FILE" --registration-projection "$REGISTRATION_PROJECTION"
    --eni-projection "$ENI_PROJECTION")
  phase_paths "$cycle" configured "$step"
  args+=(--plan-file "$PLAN_FILE" --evidence-dir "$EVIDENCE_DIR")
  for site in "${final_sites[@]}"; do args+=(--expected-site "$site"); done
  "$REPO_ROOT/scripts/aws-smsv2-lifecycle-plan.sh" "${args[@]}"
  tf show -json "$PLAN_FILE" | jq -e \
    '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length == 0' >/dev/null ||
    die "configured verification plan is not zero-change"
  if [ "$execute_uat" = true ]; then
    local uat_evidence="$PHASE_DIR/uat-evidence"
    mkdir "$uat_evidence"
    "$REPO_ROOT/scripts/aws-smsv2-uat-preflight.sh" \
      --evidence-dir "$uat_evidence" --terraform-dir "$TERRAFORM_DIR" --plan-file "$PLAN_FILE" \
      --tfvars "$TFVARS" --mapping-file "$MAPPING_FILE" --plan-mode apply --lifecycle-phase configured \
      --expected-aws-account "$AWS_ACCOUNT" --expected-aws-region "$AWS_REGION" \
      --expected-xc-tenant "$XC_TENANT" --creator-id "$CREATOR_ID" \
      --deployment-generation "$GENERATION" --component "$COMPONENT" \
      --expected-site "${final_sites[0]}" --expected-site "${final_sites[1]}" \
      --expected-site "${final_sites[2]}" --execute-uat
  fi
  kvm_status=$(tf output -json kvm_runtime_status)
  jq -e '.registration_count == 1 and .online_count == 1 and .mapping_valid == true and .bgp_converged == true and .bgp_session_count == 1' \
    <<<"$kvm_status" >/dev/null || die "KVM runtime/BGP acceptance failed"
  unset kvm_status
  rm -f -- "$PLAN_FILE"
}

build_cycle() {
  local cycle=$1 run_uat=$2
  CYCLE_DIR="$PRIVATE_ROOT/$cycle-private"
  mkdir -p "$CYCLE_DIR"
  chmod 700 "$CYCLE_DIR"
  run_phase "$cycle" bootstrap create
  wait_for_approvals bootstrap 3 1
  run_phase "$cycle" bootstrap approvals
  capture_bootstrap_mapping_inputs
  run_phase "$cycle" bootstrap_retirement retire
  run_phase "$cycle" configured create false
  wait_for_approvals configured 3 0
  run_phase "$cycle" configured approvals false
  run_phase "$cycle" configured tgw true
  verify_configured "$cycle" healthy "$run_uat"
}

destroy_all() {
  local cycle=$1 require_kvm=${2:-false}
  phase_paths "$cycle" full_destroy reviewed
  tf plan -destroy -input=false -no-color -var-file="$TFVARS" \
    -var='aws_site_configuration_phase=bootstrap' -var='enable_aws_tgw_connect=false' \
    -var='enable_kvm=false' -out="$PLAN_FILE"
  DESTROY_JSON=$(tf show -json "$PLAN_FILE")
  jq -e '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"] and .change.actions != ["delete"])] | length == 0' \
    <<<"$DESTROY_JSON" >/dev/null || die "destroy plan contains a non-delete action"
  jq -e '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"]) | select(.type | startswith("azurerm_") or startswith("azuread_") or startswith("azapi_"))] | length == 0' \
    <<<"$DESTROY_JSON" >/dev/null || die "destroy plan contains an Azure action"
  if [ "$require_kvm" = true ]; then
    jq -e '[.resource_changes[]? | select(.type == "xcsh_securemesh_site_v2" and .name == "onprem_kvm" and .change.actions == ["delete"])] | length == 1' \
      <<<"$DESTROY_JSON" >/dev/null || die "destroy plan does not contain the owned KVM site"
  fi
  unset DESTROY_JSON
  "$REPO_ROOT/scripts/aws-smsv2-uat-preflight.sh" \
    --evidence-dir "$EVIDENCE_DIR" --terraform-dir "$TERRAFORM_DIR" --plan-file "$PLAN_FILE" \
    --tfvars "$TFVARS" --plan-mode destroy --lifecycle-phase full_destroy \
    --expected-aws-account "$AWS_ACCOUNT" --expected-aws-region "$AWS_REGION" \
    --expected-xc-tenant "$XC_TENANT" --creator-id "$CREATOR_ID" \
    --deployment-generation "$GENERATION" --component "$COMPONENT" \
    --expected-site "${final_sites[0]}" --expected-site "${final_sites[1]}" --expected-site "${final_sites[2]}"
  plan_sha256="sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
  jq -n --arg phase full_destroy --arg plan_sha256 "$plan_sha256" \
    '{phase:$phase,plan_sha256:$plan_sha256}' >"$EVIDENCE_DIR/plan-receipt.json"
  tf apply -input=false -no-color "$PLAN_FILE"
  rm -f -- "$PLAN_FILE"
  [ -z "$(tf state list)" ] || die "Terraform state is not empty after destroy"
}

verify_absence() {
  local response_file="$PRIVATE_ROOT/xc-absence.json" status site
  for site in "${final_sites[@]}" "${bootstrap_sites[@]}" "${COMPONENT}-${GENERATION}-kvm"; do
    status=$(printf 'header = "Authorization: APIToken %s"\n' "$XCSH_API_TOKEN" |
      curl -sS --connect-timeout 10 --max-time 30 --config - --output "$response_file" --write-out '%{http_code}' \
        "$XCSH_API_URL/api/config/namespaces/system/securemesh_site_v2s/$site") || die "XC absence query failed"
    [ "$status" = 404 ] || die "an owned XC site remains after destroy"
  done
  rm -f -- "$response_file"
  instance_count=$(AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_SDK_LOAD_CONFIG=1 \
    aws ec2 describe-instances --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=tag:component,Values=$COMPONENT" "Name=tag:managed_by,Values=terraform" \
    'Name=instance-state-name,Values=pending,running,stopping,stopped' \
    --query 'length(Reservations[].Instances[])' --output text)
  [ "$instance_count" = 0 ] || die "owned AWS instances remain after destroy"
}

observe_refresh_only_drift() {
  local cycle=$1 step=$2 expected_address=$3 drift_kind=$4 expected_value=$5 observed_value=$6
  local drift_json plan_sha256
  phase_paths "$cycle" refresh_only "$step"
  tf plan -refresh-only -input=false -no-color -var-file="$TFVARS" \
    -var='aws_site_configuration_phase=configured' -var='enable_aws_tgw_connect=true' \
    -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE"
  drift_json=$(tf show -json "$PLAN_FILE")
  jq -e --arg address "$expected_address" '
    [.resource_changes[]? |
      select(.change.actions != ["no-op"] and .change.actions != ["read"])] as $changes |
    ($changes | length) == 1 and
    $changes[0].address == $address and
    $changes[0].change.actions == ["update"]' <<<"$drift_json" >/dev/null ||
    die "refresh-only plan did not isolate the expected drift"
  jq -e '
    [.resource_changes[]? |
      select(.change.actions != ["no-op"] and .change.actions != ["read"]) |
      select(.type | startswith("azurerm_") or startswith("azuread_") or startswith("azapi_"))] |
    length == 0' <<<"$drift_json" >/dev/null || die "refresh-only plan contains an Azure action"
  case "$drift_kind" in
  eni_name)
    jq -e --arg address "$expected_address" --arg expected "$expected_value" --arg observed "$observed_value" '
      first(.resource_changes[] | select(.address == $address)) as $change |
      $change.change.before.tags.Name == $expected and
      $change.change.after.tags.Name == $observed' <<<"$drift_json" >/dev/null ||
      die "refresh-only plan did not observe the managed ENI Name-tag drift"
    ;;
  kvm_autostart)
    jq -e --arg address "$expected_address" '
      first(.resource_changes[] | select(.address == $address)) as $change |
      $change.change.before.autostart == true and
      $change.change.after.autostart == false' <<<"$drift_json" >/dev/null ||
      die "refresh-only plan did not observe the KVM domain autostart drift"
    ;;
  *) die "unsupported refresh-only drift kind" ;;
  esac
  unset drift_json
  plan_sha256="sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
  jq -n --arg phase refresh_only --arg drift_kind "$drift_kind" \
    --arg expected_address "$expected_address" --arg plan_sha256 "$plan_sha256" \
    '{phase:$phase,drift_kind:$drift_kind,expected_address:$expected_address,plan_sha256:$plan_sha256}' \
    >"$EVIDENCE_DIR/plan-receipt.json"
  chmod 600 "$EVIDENCE_DIR/plan-receipt.json"
  [ "$plan_sha256" = "sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')" ] ||
    die "refresh-only saved plan changed before apply"
  tf apply -input=false -no-color "$PLAN_FILE"
  rm -f -- "$PLAN_FILE"
}

repair_eni_tag_drift() {
  local cycle=$1 eni_id drift_name expected_name repaired_name
  eni_id=$(tf state show -no-color 'aws_network_interface.slo[0]' | awk -F' = ' '$1 ~ /^[[:space:]]*id$/ {gsub(/\"/, "", $2); print $2; exit}')
  [ -n "$eni_id" ] || die "managed ENI identity is unavailable"
  expected_name="${COMPONENT}-${GENERATION}-aws-ce-1-slo"
  drift_name="${expected_name}-drift-check"
  AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_SDK_LOAD_CONFIG=1 \
    aws ec2 create-tags --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --resources "$eni_id" --tags "Key=Name,Value=$drift_name"
  observe_refresh_only_drift "$cycle" eni-tag-drift 'aws_network_interface.slo[0]' eni_name "$expected_name" "$drift_name"
  run_phase "$cycle" configured eni-tag-drift-repair true
  repaired_name=$(AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_SDK_LOAD_CONFIG=1 \
    aws ec2 describe-tags --profile "$AWS_PROFILE" --region "$AWS_REGION" \
    --filters "Name=resource-id,Values=$eni_id" 'Name=key,Values=Name' \
    --query 'Tags[0].Value' --output text)
  [ "$repaired_name" = "$expected_name" ] || die "managed ENI Name-tag drift was not repaired"
  verify_configured "$cycle" eni-tag-drift-zero-change false
}

repair_kvm_autostart_drift() {
  local cycle=$1 domain=onprem-ce-01 autostart
  autostart=$(virsh --connect qemu:///system dominfo "$domain" | awk -F: '$1 ~ /^Autostart/ {gsub(/[[:space:]]/, "", $2); print tolower($2)}')
  [ "$autostart" = yes ] || die "managed KVM domain is not autostart-enabled before drift injection"
  virsh --connect qemu:///system autostart --disable "$domain" >/dev/null
  autostart=$(virsh --connect qemu:///system dominfo "$domain" | awk -F: '$1 ~ /^Autostart/ {gsub(/[[:space:]]/, "", $2); print tolower($2)}')
  [ "$autostart" = no ] || die "KVM domain autostart drift injection failed"
  observe_refresh_only_drift "$cycle" kvm-autostart-drift 'libvirt_domain.ce_node["01"]' kvm_autostart true false
  run_phase "$cycle" configured kvm-autostart-drift-repair true
  autostart=$(virsh --connect qemu:///system dominfo "$domain" | awk -F: '$1 ~ /^Autostart/ {gsub(/[[:space:]]/, "", $2); print tolower($2)}')
  [ "$autostart" = yes ] || die "managed KVM domain autostart drift was not repaired"
  verify_configured "$cycle" kvm-autostart-drift-zero-change false
}

exercise_managed_drift() {
  local cycle=$1
  repair_eni_tag_drift "$cycle"
  repair_kvm_autostart_drift "$cycle"
}

case "$MODE" in
verify)
  CYCLE_DIR="$PRIVATE_ROOT/verify-private"
  REGISTRATION_PROJECTION=${REGISTRATION_PROJECTION:-$CYCLE_DIR/aws-registration-projection.json}
  ENI_PROJECTION=${ENI_PROJECTION:-$CYCLE_DIR/aws-eni-projection.json}
  MAPPING_FILE=${MAPPING_FILE:-$CYCLE_DIR/aws-device-mapping.json}
  [ -f "$MAPPING_FILE" ] || die "verify requires retained private mapping artifacts"
  verify_configured verify healthy true
  ;;
destroy)
  destroy_all requested false
  verify_absence
  ;;
build)
  [ -z "$(tf state list)" ] || die "build requires empty state"
  build_cycle build true
  rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  ;;
full)
  if [ -n "$(tf state list)" ]; then
    destroy_all initial false
    verify_absence
  fi
  build_cycle first true
  exercise_managed_drift first
  rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  destroy_all first true
  verify_absence
  build_cycle second true
  exercise_managed_drift second
  rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  ;;
esac

printf 'showcase-lifecycle: mode=%s status=passed final_state=%s evidence=%s\n' \
  "$MODE" "$([ "$MODE" = destroy ] && printf absent || printf online)" "$PRIVATE_ROOT"
