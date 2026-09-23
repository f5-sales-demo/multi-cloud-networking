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
GENERATION=""
MODE=full
PRIVATE_ROOT=""
CREATOR_ID=$(git -C "$REPO_ROOT" config user.email 2>/dev/null || true)
SOURCE_REPOSITORY=f5-sales-demo/multi-cloud-networking
SOURCE_REF=""
SOURCE_COMMIT_SHA=""
DEPLOYMENT_OWNER_ID=""
DEPLOYMENT_ACTOR_ID=""
KVM_LAN_PLAN=""
KVM_LAN_PLAN_SHA256=""
KVM_LAN_STAGE=""
KVM_LAN_RECEIPT=""

usage() {
  cat <<'EOF'
Usage: showcase-lifecycle.sh [--mode full|build|verify|destroy|kvm-lan-preflight] [options]

Options:
  --tfvars PATH             Ignored unified-root variables file.
  --backend-config PATH     Ignored AWS S3 backend configuration.
  --credentials-file PATH  Protected XC URL/token file.
  --private-root PATH       Empty directory outside the repository for plans.
  --aws-profile NAME        AWS SSO profile (default: sso).
  --creator-id EMAIL        Expected XC object creator.
  --source-repository NAME  Canonical source repository.
  --source-ref REF          Exact reviewed refs/heads/* source ref.
  --source-commit-sha SHA   Exact reviewed 40-hex source commit.
  --deployment-owner-id ID  Non-personal deployment owner identifier.
  --deployment-actor-id ID  Non-personal automation actor identifier.
  --kvm-lan-plan PATH       Existing full-root saved plan for LAN preflight.
  --kvm-lan-plan-sha256 ID  Reviewed sha256:<64-hex> digest of that plan.
  --kvm-lan-stage STAGE     Reviewed hardware or configured stage.
  --kvm-lan-receipt PATH    New mode-0600 preflight receipt outside the repo.

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
  --source-repository)
    SOURCE_REPOSITORY=${2:?}
    shift 2
    ;;
  --source-ref)
    SOURCE_REF=${2:?}
    shift 2
    ;;
  --source-commit-sha)
    SOURCE_COMMIT_SHA=${2:?}
    shift 2
    ;;
  --deployment-owner-id)
    DEPLOYMENT_OWNER_ID=${2:?}
    shift 2
    ;;
  --deployment-actor-id)
    DEPLOYMENT_ACTOR_ID=${2:?}
    shift 2
    ;;
  --kvm-lan-plan)
    KVM_LAN_PLAN=${2:?}
    shift 2
    ;;
  --kvm-lan-plan-sha256)
    KVM_LAN_PLAN_SHA256=${2:?}
    shift 2
    ;;
  --kvm-lan-stage)
    KVM_LAN_STAGE=${2:?}
    shift 2
    ;;
  --kvm-lan-receipt)
    KVM_LAN_RECEIPT=${2:?}
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1" ;;
  esac
done
case "$MODE" in full | build | verify | destroy | kvm-lan-preflight) ;; *) die "invalid --mode" ;; esac

# KVM LAN preflight is read-only with respect to infrastructure. It runs before
# credential loading, service enablement, Terraform initialization, or any
# apply/destroy path. The scope checker proves shared bridge/uplink resources survive
# because no host-network resource or unrelated cloud action is allowed.
if [ "$MODE" = kvm-lan-preflight ]; then
  for command_name in git ip python3 realpath sha256sum terraform; do
    command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
  done
  [ -r "$KVM_LAN_PLAN" ] || die "--kvm-lan-plan must name a readable saved plan"
  case "$(realpath "$KVM_LAN_PLAN")" in "$REPO_ROOT"/*) die "KVM LAN saved plan must be outside the repository" ;; esac
  [[ "$KVM_LAN_PLAN_SHA256" =~ ^sha256:[0-9a-f]{64}$ ]] || die "--kvm-lan-plan-sha256 is invalid"
  case "$KVM_LAN_STAGE" in hardware | configured) ;; *) die "--kvm-lan-stage must be hardware or configured" ;; esac
  [ -n "$KVM_LAN_RECEIPT" ] || die "--kvm-lan-receipt is required"
  [ ! -e "$KVM_LAN_RECEIPT" ] || die "KVM LAN receipt already exists"
  case "$(realpath -m "$KVM_LAN_RECEIPT")" in "$REPO_ROOT"/*) die "KVM LAN receipt must be outside the repository" ;; esac
  [ -n "$SOURCE_REF" ] || die "--source-ref is required"
  [ -n "$SOURCE_COMMIT_SHA" ] || die "--source-commit-sha is required"
  checked_out_commit=$(git -C "$REPO_ROOT" rev-parse --verify HEAD) || die "cannot resolve checked-out commit"
  [ "$checked_out_commit" = "$SOURCE_COMMIT_SHA" ] || die "source commit does not match the checked-out commit"
  checked_out_ref="refs/heads/$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)" || die "lifecycle requires a named source branch"
  [ "$checked_out_ref" = "$SOURCE_REF" ] || die "source ref does not match the checked-out branch"
  actual_plan_sha256="sha256:$(sha256sum "$KVM_LAN_PLAN" | awk '{print $1}')"
  [ "$actual_plan_sha256" = "$KVM_LAN_PLAN_SHA256" ] || die "saved plan digest does not match the reviewed digest"
  receipt_parent=$(dirname "$KVM_LAN_RECEIPT")
  [ -d "$receipt_parent" ] || die "KVM LAN receipt directory does not exist"
  plan_json=$(mktemp "$receipt_parent/.kvm-lan-plan.XXXXXX")
  receipt_tmp=$(mktemp "$receipt_parent/.kvm-lan-receipt.XXXXXX")
  trap 'rm -f -- "$plan_json" "$receipt_tmp"' EXIT
  chmod 600 "$plan_json" "$receipt_tmp"
  terraform -chdir="$TERRAFORM_DIR" show -json "$KVM_LAN_PLAN" >"$plan_json"
  python3 "$REPO_ROOT/scripts/kvm-lan-plan-scope.py" \
    --stage "$KVM_LAN_STAGE" --plan-sha256 "$KVM_LAN_PLAN_SHA256" \
    --source-ref "$SOURCE_REF" --source-commit-sha "$SOURCE_COMMIT_SHA" \
    --verify-host-network <"$plan_json" >"$receipt_tmp"
  chmod 600 "$receipt_tmp"
  mv "$receipt_tmp" "$KVM_LAN_RECEIPT"
  trap - EXIT
  rm -f -- "$plan_json"
  printf 'showcase-lifecycle: mode=kvm-lan-preflight status=passed receipt=%s\n' "$KVM_LAN_RECEIPT"
  exit 0
fi

for command_name in aws curl getent jq stat sudo systemctl terraform sha256sum virsh; do
  command -v "$command_name" >/dev/null 2>&1 || die "required command is unavailable: $command_name"
done
[ -n "$CREATOR_ID" ] || die "Git user.email is required for ownership checks"
[ -n "$SOURCE_REF" ] || die "--source-ref is required"
[ -n "$SOURCE_COMMIT_SHA" ] || die "--source-commit-sha is required"
[ -n "$DEPLOYMENT_OWNER_ID" ] || die "--deployment-owner-id is required"
[ -n "$DEPLOYMENT_ACTOR_ID" ] || die "--deployment-actor-id is required"
[ -r "$TFVARS" ] || die "tfvars file is unavailable"
[ -r "$BACKEND_CONFIG" ] || die "backend configuration is unavailable"
[ -r "$CREDENTIAL_FILE" ] || die "XC credential file is unavailable"

checked_out_commit=$(git -C "$REPO_ROOT" rev-parse --verify HEAD) || die "cannot resolve checked-out commit"
[ "$checked_out_commit" = "$SOURCE_COMMIT_SHA" ] || die "source commit does not match the checked-out commit"
checked_out_ref="refs/heads/$(git -C "$REPO_ROOT" symbolic-ref --short HEAD)" || die "lifecycle requires a named source branch"
[ "$checked_out_ref" = "$SOURCE_REF" ] || die "source ref does not match the checked-out branch"
identity_json=$(
  "$REPO_ROOT/scripts/deployment-identity.py" \
    --repository "$SOURCE_REPOSITORY" --source-ref "$SOURCE_REF" \
    --source-commit "$SOURCE_COMMIT_SHA" --owner-id "$DEPLOYMENT_OWNER_ID" \
    --actor-id "$DEPLOYMENT_ACTOR_ID"
) || die "deployment identity is invalid"
DEPLOYMENT_ENVIRONMENT_KEY=$(jq -er '.environmentKey' <<<"$identity_json") || die "environment key is missing"
SHOWCASE_BACKEND_KEY=$(jq -er '.stateKey' <<<"$identity_json") || die "state key is missing"
ARTIFACT_SCOPE=$(jq -er '.artifactScope' <<<"$identity_json") || die "artifact scope is missing"
unset identity_json checked_out_commit checked_out_ref
configured_backend_key=$(sed -n 's/^[[:space:]]*key[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$BACKEND_CONFIG")
[ "$configured_backend_key" = "$SHOWCASE_BACKEND_KEY" ] || die "backend key does not match the reviewed deployment environment"
unset configured_backend_key

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
  PRIVATE_ROOT="/home/$(id -un)/.local/state/multi-cloud-networking/${ARTIFACT_SCOPE}/showcase-$(date -u +%Y%m%dT%H%M%SZ)"
fi
case "$(realpath -m "$PRIVATE_ROOT")/" in "$REPO_ROOT"/*) die "private root must be outside the repository" ;; esac
mkdir -p "$PRIVATE_ROOT"
chmod 700 "$PRIVATE_ROOT"
umask 077

TF_RUNNER=("$REPO_ROOT/scripts/terraform-with-aws-sso.sh" --profile "$AWS_PROFILE" --region "$AWS_REGION" --)
tf() {
  "${TF_RUNNER[@]}" -chdir="$TERRAFORM_DIR" "$@"
}
IDENTITY_TF_ARGS=(
  -var="source_repository=$SOURCE_REPOSITORY"
  -var="source_ref=$SOURCE_REF"
  -var="source_commit_sha=$SOURCE_COMMIT_SHA"
  -var="deployment_owner_id=$DEPLOYMENT_OWNER_ID"
  -var="deployment_actor_id=$DEPLOYMENT_ACTOR_ID"
)
tf_plan() {
  tf plan "${IDENTITY_TF_ARGS[@]}" "$@"
}

terraform_version=$(terraform version -json | jq -r .terraform_version)
[ "$terraform_version" = 1.16.3 ] || die "Terraform 1.16.3 is required"
caller_account=$(AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_SDK_LOAD_CONFIG=1 \
  aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" --query Account --output text) ||
  die "AWS SSO identity is unavailable"
[ "$caller_account" = "$AWS_ACCOUNT" ] || die "AWS account mismatch"
unset caller_account

tf init -reconfigure -input=false -lockfile=readonly -backend-config="$BACKEND_CONFIG"
existing_provenance=$(tf output -json deployment_provenance 2>/dev/null || true)
if [ -n "$existing_provenance" ] && [ "$existing_provenance" != null ]; then
  jq -e \
    --arg repository "$SOURCE_REPOSITORY" \
    --arg source_ref "$SOURCE_REF" \
    --arg environment_key "$DEPLOYMENT_ENVIRONMENT_KEY" \
    --arg owner_id "$DEPLOYMENT_OWNER_ID" \
    '.repository == $repository and .source_ref == $source_ref and
     .environment_key == $environment_key and .owner_id == $owner_id' \
    <<<"$existing_provenance" >/dev/null ||
    die "cross-environment state ownership mismatch"
fi
unset existing_provenance
generation_json=$(printf '%s\n' 'var.smsv2_site_generation' | tf console "${IDENTITY_TF_ARGS[@]}" -var-file="$TFVARS") ||
  die "cannot resolve smsv2_site_generation from tfvars"
GENERATION=$(jq -er 'select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$generation_json") ||
  die "smsv2_site_generation is not a DNS-style label"
unset generation_json
site_prefix_json=$(printf '%s\n' 'local.site_prefix' | tf console "${IDENTITY_TF_ARGS[@]}" -var-file="$TFVARS") ||
  die "cannot resolve environment-scoped site prefix"
SITE_PREFIX=$(jq -er 'select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$site_prefix_json") ||
  die "environment-scoped site prefix is not a DNS-style label"
aws_resource_prefix_json=$(printf '%s\n' 'local.aws_resource_prefix' | tf console "${IDENTITY_TF_ARGS[@]}" -var-file="$TFVARS") ||
  die "cannot resolve environment-scoped AWS prefix"
AWS_RESOURCE_PREFIX=$(jq -er 'select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$aws_resource_prefix_json") ||
  die "environment-scoped AWS prefix is not a DNS-style label"
unset site_prefix_json aws_resource_prefix_json

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
  final_sites+=("${SITE_PREFIX}-aws-${AWS_REGION}-${key}")
  bootstrap_sites+=("${SITE_PREFIX}-aws-${AWS_REGION}-${key}-bootstrap")
done

common_phase_args=(
  --tfvars "$TFVARS"
  --expected-aws-account "$AWS_ACCOUNT"
  --expected-aws-region "$AWS_REGION"
  --expected-xc-tenant "$XC_TENANT"
  --creator-id "$CREATOR_ID"
  --deployment-generation "$GENERATION"
  --component "$COMPONENT"
  --source-repository "$SOURCE_REPOSITORY"
  --source-ref "$SOURCE_REF"
  --source-commit-sha "$SOURCE_COMMIT_SHA"
  --deployment-owner-id "$DEPLOYMENT_OWNER_ID"
  --deployment-actor-id "$DEPLOYMENT_ACTOR_ID"
  --deployment-environment-key "$DEPLOYMENT_ENVIRONMENT_KEY"
  --backend-key "$SHOWCASE_BACKEND_KEY"
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
    if tf_plan "${args[@]}" -out="$probe" >/dev/null 2>&1; then
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
      --source-repository "$SOURCE_REPOSITORY" --source-ref "$SOURCE_REF" \
      --source-commit-sha "$SOURCE_COMMIT_SHA" --deployment-owner-id "$DEPLOYMENT_OWNER_ID" \
      --deployment-actor-id "$DEPLOYMENT_ACTOR_ID" \
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
  tf_plan -destroy -input=false -no-color -var-file="$TFVARS" \
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
    --source-repository "$SOURCE_REPOSITORY" --source-ref "$SOURCE_REF" \
    --source-commit-sha "$SOURCE_COMMIT_SHA" --deployment-owner-id "$DEPLOYMENT_OWNER_ID" \
    --deployment-actor-id "$DEPLOYMENT_ACTOR_ID" \
    --expected-site "${final_sites[0]}" --expected-site "${final_sites[1]}" --expected-site "${final_sites[2]}"
  plan_sha256="sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
  jq -n --arg phase full_destroy --arg plan_sha256 "$plan_sha256" \
    --arg environment_key "$DEPLOYMENT_ENVIRONMENT_KEY" --arg source_commit "$SOURCE_COMMIT_SHA" \
    --arg backend_key "$SHOWCASE_BACKEND_KEY" \
    '{phase:$phase,plan_sha256:$plan_sha256,environment_key:$environment_key,source_commit:$source_commit,backend_key:$backend_key}' \
    >"$EVIDENCE_DIR/plan-receipt.json"
  tf apply -input=false -no-color "$PLAN_FILE"
  rm -f -- "$PLAN_FILE"
  [ -z "$(tf state list)" ] || die "Terraform state is not empty after destroy"
}

verify_absence() {
  local response_file="$PRIVATE_ROOT/xc-absence.json" status site
  for site in "${final_sites[@]}" "${bootstrap_sites[@]}" "${SITE_PREFIX}-kvm"; do
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
  tf_plan -refresh-only -input=false -no-color -var-file="$TFVARS" \
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
    --arg environment_key "$DEPLOYMENT_ENVIRONMENT_KEY" --arg source_commit "$SOURCE_COMMIT_SHA" \
    --arg backend_key "$SHOWCASE_BACKEND_KEY" \
    '{phase:$phase,drift_kind:$drift_kind,expected_address:$expected_address,plan_sha256:$plan_sha256,environment_key:$environment_key,source_commit:$source_commit,backend_key:$backend_key}' \
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
  expected_name="${AWS_RESOURCE_PREFIX}-aws-ce-1-slo"
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
