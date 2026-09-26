#!/usr/bin/env bash
# Drive the complete AWS + KVM + Azure showcase lifecycle from the unified Terraform
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
# The reviewed predecessor state uses a different generation from new builds.
LEGACY_GENERATION=smsv2-current
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
PROVIDER_ZIP=""
AZURE_SUBSCRIPTION=""

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

full performs clean teardown when state exists, staged build/verify, controlled
drift repair, reviewed full teardown, absence proof, and a second build.
The second verified AWS + KVM + Azure deployment is intentionally left online.
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

export AWS_PROFILE
for command_name in aws az curl getent gh jq python3 stat sudo systemctl tar terraform sha256sum virsh; do
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
[ -z "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=all)" ] ||
  die "lifecycle source worktree must be clean and committed"
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
if [ "$SHOWCASE_BACKEND_KEY" = mcn-ce-ha-smsv2/showcase.tfstate ]; then
  [ "$SOURCE_REF" = refs/heads/main ] || die "production backend requires merged main"
  [ "$(git -C "$REPO_ROOT" rev-parse origin/main)" = "$SOURCE_COMMIT_SHA" ] ||
    die "production backend requires the exact current origin/main commit"
fi
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
# The old production state contains xcsh data attributes the current provider
# cannot decode in terraform console. Evaluate only tracked source and private
# inputs in an empty local-backend copy. The TGW toggle is temporarily disabled
# for this read: bootstrap has no device mapping yet. Its actual private value
# is checked below and every saved build/final plan validates the full scope.
INPUT_DIR=$(mktemp -d "$PRIVATE_ROOT/input-console.XXXXXX")
git -C "$REPO_ROOT" archive "$SOURCE_COMMIT_SHA:terraform" | tar -x -C "$INPUT_DIR"
[ "$(grep -Ec '^[[:space:]]*backend "s3" \{\}[[:space:]]*$' "$INPUT_DIR/backend.tf")" -eq 1 ] ||
  die "isolated input root has an unexpected backend declaration"
sed -i '/^[[:space:]]*backend "s3" {}[[:space:]]*$/d' "$INPUT_DIR/backend.tf"
terraform -chdir="$INPUT_DIR" init -backend=false -input=false -lockfile=readonly \
  >"$PRIVATE_ROOT/input-console-init.log" 2>&1 || die "isolated input root initialization failed"
input_expr='jsonencode({subscription=var.subscription_id,flags={aws=var.enable_aws,azure=var.enable_azure,canada=var.enable_canada,bgp=var.enable_bgp,us_ilb=var.enable_azure_ilb,ca_ilb=var.enable_canada_ilb,kvm=var.enable_kvm,kvm_lan=var.enable_kvm_lan},generation=var.smsv2_site_generation,site_prefix=local.site_prefix,aws_prefix=local.aws_resource_prefix,deployer=local.deployer,environment=var.environment})'
input_line=$(printf '%s\n' "$input_expr" |
  "${TF_RUNNER[@]}" -chdir="$INPUT_DIR" console "${IDENTITY_TF_ARGS[@]}" \
    -var-file="$TFVARS" -var='enable_aws_tgw_connect=false' | tail -n 1) ||
  die "isolated input console failed"
INPUT_VALUES_JSON=$(jq -er 'fromjson | select(type == "object" and (.flags | type == "object"))' <<<"$input_line") ||
  die "isolated input console did not return a JSON object"
rm -r -- "$INPUT_DIR"
unset INPUT_DIR input_expr input_line
AZURE_SUBSCRIPTION=$(jq -er '.subscription | select(type == "string" and test("^[0-9a-fA-F-]{36}$"))' <<<"$INPUT_VALUES_JSON") ||
  die "configured Azure subscription is unavailable"
az account show --subscription "$AZURE_SUBSCRIPTION" --query state --output tsv | grep -qx Enabled ||
  die "configured Azure subscription is not enabled"
jq -e '.flags | length == 8 and all(.[]; . == true)' <<<"$INPUT_VALUES_JSON" >/dev/null ||
  die "all non-TGW showcase paths must be enabled in tfvars"
if [ "$(grep -Ec '^[[:space:]]*enable_aws_tgw_connect[[:space:]]*=' "$TFVARS")" -ne 1 ] ||
  ! grep -Eq '^[[:space:]]*enable_aws_tgw_connect[[:space:]]*=[[:space:]]*true[[:space:]]*(#.*)?$' "$TFVARS"; then
  die "private tfvars must explicitly enable AWS TGW Connect"
fi
latest_xcsh=$(gh release view --repo f5-sales-demo/terraform-provider-xcsh --json tagName --jq .tagName) || die "cannot check latest xcsh release"
[ "$latest_xcsh" = v11.3.0 ] || die "xcsh release advanced beyond the pinned v11.3.0"
PROVIDER_ZIP="$PRIVATE_ROOT/terraform-provider-xcsh_11.3.0_linux_amd64.zip"
if [ ! -f "$PROVIDER_ZIP" ]; then
  curl -fsSL --retry 3 --output "$PROVIDER_ZIP" \
    'https://github.com/f5-sales-demo/terraform-provider-xcsh/releases/download/v11.3.0/terraform-provider-xcsh_11.3.0_linux_amd64.zip' ||
    die "cannot download pinned xcsh provider artifact"
fi
[ "$(sha256sum "$PROVIDER_ZIP" | awk '{print $1}')" = 5dab6b26cbc2656bd7df2a8259564f238b1947d5cfdf9e9370243300c954d85d ] ||
  die "xcsh release artifact digest mismatch"
PREFLIGHT_DIR="$TERRAFORM_DIR/preflight/ce-egress"
terraform -chdir="$PREFLIGHT_DIR" init -backend=false -input=false >/dev/null
PREFLIGHT_PLAN="$PRIVATE_ROOT/ce-egress.tfplan"
PREFLIGHT_JSON="$PRIVATE_ROOT/ce-egress-plan.json"
terraform -chdir="$PREFLIGHT_DIR" plan -input=false -no-color \
  -var="source_commit_sha=$SOURCE_COMMIT_SHA" -var="backend_key=$SHOWCASE_BACKEND_KEY" \
  -out="$PREFLIGHT_PLAN" >/dev/null
terraform -chdir="$PREFLIGHT_DIR" show -json "$PREFLIGHT_PLAN" >"$PREFLIGHT_JSON"
jq -e --arg commit "$SOURCE_COMMIT_SHA" --arg key "$SHOWCASE_BACKEND_KEY" '
  .planned_values.outputs.reviewed_identity.value.source_commit_sha == $commit and
  .planned_values.outputs.reviewed_identity.value.backend_key == $key and
  .configuration.provider_config.xcsh.full_name == "registry.terraform.io/f5-sales-demo/xcsh" and
  (.configuration.provider_config.xcsh.version_constraint | . == "11.3.0" or . == "= 11.3.0") and
  ([.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length == 0) and
  ((.action_invocations // []) | length == 0)' "$PREFLIGHT_JSON" >/dev/null ||
  die "CE egress preflight plan identity or action scope failed"
python3 "$REPO_ROOT/scripts/customer-edge-egress-preflight.py" \
  --plan-json "$PREFLIGHT_JSON" --probe >"$PRIVATE_ROOT/ce-egress-receipt.json" ||
  die "CE DNS/NTP/HTTPS egress preflight failed"
jq -n --arg commit "$SOURCE_COMMIT_SHA" --arg key "$SHOWCASE_BACKEND_KEY" \
  --arg digest "sha256:$(sha256sum "$PREFLIGHT_PLAN" | awk '{print $1}')" \
  --arg provider "sha256:$(sha256sum "$PROVIDER_ZIP" | awk '{print $1}')" \
  '{scope:"ce-egress-preflight",source_commit:$commit,backend_key:$key,plan_sha256:$digest,provider_artifact_sha256:$provider}' \
  >"$PRIVATE_ROOT/ce-egress-plan-receipt.json"
rm -f -- "$PREFLIGHT_PLAN" "$PREFLIGHT_JSON"
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
GENERATION=$(jq -er '.generation | select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$INPUT_VALUES_JSON") ||
  die "smsv2_site_generation is not a DNS-style label"
SITE_PREFIX=$(jq -er '.site_prefix | select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$INPUT_VALUES_JSON") ||
  die "environment-scoped site prefix is not a DNS-style label"
AWS_RESOURCE_PREFIX=$(jq -er '.aws_prefix | select(type == "string" and test("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$"))' <<<"$INPUT_VALUES_JSON") ||
  die "environment-scoped AWS prefix is not a DNS-style label"
LEGACY_DEPLOYER=$(jq -er '.deployer | select(type == "string" and test("^[a-z0-9]+$"))' <<<"$INPUT_VALUES_JSON") ||
  die "legacy deployer identity is unavailable"
LEGACY_ENVIRONMENT=$(jq -er '.environment | select(type == "string" and test("^[a-z0-9-]+$"))' <<<"$INPUT_VALUES_JSON") ||
  die "legacy environment identity is unavailable"
unset INPUT_VALUES_JSON

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

scope_plan() {
  local scope=$1 receipt=$EVIDENCE_DIR/showcase-plan-receipt.json
  if [ "$scope" = full-destroy ] && [ "${DESTROY_FALLBACK:-false}" = true ]; then
    python3 "$REPO_ROOT/scripts/showcase-legacy-destroy-scope.py" \
      --terraform-dir "$TERRAFORM_DIR" --state "$EVIDENCE_DIR/prior-state.json" \
      --events "$EVIDENCE_DIR/destroy-events.jsonl" --plan "$PLAN_FILE" \
      --provider-zip "$PROVIDER_ZIP" --backend-config "$BACKEND_CONFIG" \
      --source-commit "$SOURCE_COMMIT_SHA" --backend-key "$SHOWCASE_BACKEND_KEY" \
      --environment-key "$DEPLOYMENT_ENVIRONMENT_KEY" --owner-id "$DEPLOYMENT_OWNER_ID" \
      --legacy-deployer "$LEGACY_DEPLOYER" --legacy-environment "$LEGACY_ENVIRONMENT" \
      --legacy-generation "$LEGACY_GENERATION" --legacy-tenant "$XC_TENANT" \
      >"$receipt" || die "legacy destroy plan failed exact ownership/action scope"
  else
    python3 "$REPO_ROOT/scripts/showcase-plan-scope.py" \
      --terraform-dir "$TERRAFORM_DIR" --plan-file "$PLAN_FILE" \
      --provider-zip "$PROVIDER_ZIP" --backend-config "$BACKEND_CONFIG" \
      --scope "$scope" --source-commit "$SOURCE_COMMIT_SHA" \
      --backend-key "$SHOWCASE_BACKEND_KEY" --environment-key "$DEPLOYMENT_ENVIRONMENT_KEY" \
      --owner-id "$DEPLOYMENT_OWNER_ID" \
      --legacy-deployer "$LEGACY_DEPLOYER" --legacy-environment "$LEGACY_ENVIRONMENT" \
      --legacy-generation "$LEGACY_GENERATION" --legacy-tenant "$XC_TENANT" \
      >"$receipt" || die "saved plan failed $scope scope"
  fi
  chmod 600 "$receipt"
  jq -e --arg digest "sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')" \
    '.plan_sha256 == $digest' "$receipt" >/dev/null || die "saved plan digest changed"
}

apply_scoped_plan() {
  local scope=$1
  scope_plan "$scope"
  local digest
  digest=$(jq -er .plan_sha256 "$EVIDENCE_DIR/showcase-plan-receipt.json")
  [ "$digest" = "sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')" ] || die "saved plan digest changed before apply"
  tf apply -input=false -no-color "$PLAN_FILE"
  jq -n --arg scope "$scope" --arg digest "$digest" --arg completed_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{scope:$scope,plan_sha256:$digest,completed_at:$completed_at,status:"applied"}' >"$EVIDENCE_DIR/apply-receipt.json"
  rm -f -- "$PLAN_FILE"
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
  scope_plan aws-kvm-build
  if [ "$phase" = bootstrap ] && [ "$step" = create ]; then
    # The full saved plan is already scoped above. Inspect its owned KVM
    # projection before first boot, with the same digest, and verify that
    # the shared bridge/uplink still match the private allocation.
    local plan_digest
    plan_digest=$(jq -er .plan_sha256 "$EVIDENCE_DIR/showcase-plan-receipt.json")
    tf show -json "$PLAN_FILE" |
      jq '.resource_changes |= map(select(.address == "libvirt_domain.ce_node[\"01\"]"))' |
      python3 "$REPO_ROOT/scripts/kvm-lan-plan-scope.py" --stage hardware \
        --plan-sha256 "$plan_digest" --source-ref "$SOURCE_REF" \
        --source-commit-sha "$SOURCE_COMMIT_SHA" --verify-host-network \
        >"$EVIDENCE_DIR/kvm-host-network-receipt.json" ||
      die "KVM hardware plan or shared host network preflight failed"
  fi
  "$REPO_ROOT/scripts/aws-smsv2-lifecycle-plan.sh" "${args[@]}" --apply
  jq -n --arg phase "$phase" --arg digest "$(jq -r .plan_sha256 "$EVIDENCE_DIR/showcase-plan-receipt.json")" \
    '{phase:$phase,plan_sha256:$digest,status:"applied"}' >"$EVIDENCE_DIR/apply-receipt.json"
  rm -f -- "$PLAN_FILE"
}

wait_for_approvals() {
  local phase=$1 expected_aws=$2 expected_kvm=$3 deadline=$((SECONDS + 5400))
  local probe="$PRIVATE_ROOT/registration-wait.tfplan" gate digest projection_tmp projection_digest
  local -a args=(-input=false -no-color -lock=false -var-file="$TFVARS"
    -var="aws_site_configuration_phase=$phase" -var='enable_aws_tgw_connect=false'
    -var='enable_azure=false' -var='enable_canada=false'
    -var='enable_azure_ilb=false' -var='enable_canada_ilb=false'
    -var='kvm_lan_configuration_phase=hardware')
  if [ "$phase" = configured ]; then
    args+=(-var="aws_smsv2_device_mapping_file=$MAPPING_FILE")
  fi
  while ((SECONDS < deadline)); do
    if tf_plan "${args[@]}" -out="$probe" >/dev/null 2>&1; then
      digest="sha256:$(sha256sum "$probe" | awk '{print $1}')"
      gate=$(tf show -json "$probe" | python3 "$REPO_ROOT/scripts/showcase-registration-gate.py" \
        --phase "$phase" --expected-aws "$expected_aws" --expected-kvm "$expected_kvm" \
        --source-commit "$SOURCE_COMMIT_SHA") || die "registration plan gate failed"
      [ "$digest" = "sha256:$(sha256sum "$probe" | awk '{print $1}')" ] ||
        die "registration plan digest changed during review"
      if jq -e '.ready == true' <<<"$gate" >/dev/null; then
        projection_digest=""
        if [ "$phase" = bootstrap ]; then
          # The output in state can lag the registration data source when every
          # CE is already ONLINE and the approval apply is correctly skipped.
          # Keep the projection from this exact reviewed, refresh-enabled plan.
          projection_tmp=$(mktemp "$CYCLE_DIR/.aws-registration-projection.XXXXXX")
          chmod 600 "$projection_tmp"
          tf show -json "$probe" |
            jq -e '.planned_values.outputs.aws_smsv2_bootstrap_registration_projection.value' \
              >"$projection_tmp" || die "bootstrap registration projection is missing from reviewed plan"
          [ "$digest" = "sha256:$(sha256sum "$probe" | awk '{print $1}')" ] ||
            die "registration plan digest changed while capturing projection"
          REGISTRATION_PROJECTION="$CYCLE_DIR/aws-registration-projection.json"
          mv -- "$projection_tmp" "$REGISTRATION_PROJECTION"
          projection_digest="sha256:$(sha256sum "$REGISTRATION_PROJECTION" | awk '{print $1}')"
        fi
        jq -n --arg phase "$phase" --arg source_commit "$SOURCE_COMMIT_SHA" \
          --arg plan_sha256 "$digest" --arg registration_projection_sha256 "$projection_digest" \
          --argjson gate "$gate" \
          '{phase:$phase,source_commit:$source_commit,plan_sha256:$plan_sha256,registration_projection_sha256:$registration_projection_sha256,gate:$gate}' \
          >"$CYCLE_DIR/$phase-registration-wait-receipt.json"
        chmod 600 "$CYCLE_DIR/$phase-registration-wait-receipt.json"
        REGISTRATION_APPROVAL_COUNT=$(jq -er '.approval_creates' <<<"$gate")
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
  [ -s "$REGISTRATION_PROJECTION" ] || die "reviewed bootstrap registration projection is missing"
  local projection_digest="sha256:$(sha256sum "$REGISTRATION_PROJECTION" | awk '{print $1}')"
  jq -e --arg source_commit "$SOURCE_COMMIT_SHA" --arg projection_digest "$projection_digest" \
    '.phase == "bootstrap" and .source_commit == $source_commit and
     .registration_projection_sha256 == $projection_digest and
     (.plan_sha256 | test("^sha256:[0-9a-f]{64}$"))' \
    "$CYCLE_DIR/bootstrap-registration-wait-receipt.json" >/dev/null ||
    die "bootstrap registration projection does not match its reviewed plan receipt"
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
  scope_plan aws-kvm-zero
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
  if [ "$REGISTRATION_APPROVAL_COUNT" -gt 0 ]; then
    run_phase "$cycle" bootstrap approvals
  fi
  capture_bootstrap_mapping_inputs
  run_phase "$cycle" bootstrap_retirement retire
  run_phase "$cycle" configured create false
  wait_for_approvals configured 3 0
  if [ "$REGISTRATION_APPROVAL_COUNT" -gt 0 ]; then
    run_phase "$cycle" configured approvals false
  fi
  run_phase "$cycle" configured tgw true
  verify_configured "$cycle" healthy "$run_uat"
  exercise_managed_drift "$cycle"
  phase_paths "$cycle" kvm_configured inside-vip
  tf_plan -input=false -no-color -var-file="$TFVARS" \
    -var='enable_azure=false' -var='enable_canada=false' \
    -var='enable_azure_ilb=false' -var='enable_canada_ilb=false' \
    -var='kvm_lan_configuration_phase=configured' \
    -var='aws_site_configuration_phase=configured' \
    -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE"
  apply_scoped_plan kvm-configured
  python3 "$REPO_ROOT/scripts/verify-kvm-lan-client.py" \
    --terraform-dir "$TERRAFORM_DIR" --evidence-dir "$CYCLE_DIR/kvm-client" \
    --source-commit "$SOURCE_COMMIT_SHA"
  phase_paths "$cycle" azure_build both-regions
  tf_plan -input=false -no-color -var-file="$TFVARS" \
    -var='kvm_lan_configuration_phase=configured' \
    -var='aws_site_configuration_phase=configured' \
    -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE"
  apply_scoped_plan azure-build
  wait_for_azure_approvals "$cycle"
  wait_for_azure_online "$cycle"
  settle_azure "$cycle"
  verify_final "$cycle"
}

wait_for_azure_approvals() {
  local cycle=$1 deadline=$((SECONDS + 5400)) approval_count
  phase_paths "$cycle" azure_approval registered
  while ((SECONDS < deadline)); do
    if tf_plan -input=false -no-color -var-file="$TFVARS" \
      -var='kvm_lan_configuration_phase=configured' \
      -var='aws_site_configuration_phase=configured' \
      -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE" \
      >"$EVIDENCE_DIR/registration-plan.log" 2>&1; then
      approval_count=$(tf show -json "$PLAN_FILE" |
        jq '[.resource_changes[]? | select(.type == "xcsh_registration_approval" and .name == "this" and .change.actions == ["create"])] | length')
      if [ "$approval_count" -eq 6 ]; then
        apply_scoped_plan azure-approvals
        return 0
      fi
    fi
    rm -f -- "$PLAN_FILE"
    sleep 30
  done
  die "six Azure CE registrations did not reach NEW before the bounded deadline"
}

wait_for_azure_online() {
  local cycle=$1 deadline=$((SECONDS + 5400)) site state all_online
  local -a sites=() canadian_sites=()
  mapfile -t sites < <(tf output -json xc_site_names | jq -r '.[]')
  mapfile -t canadian_sites < <(tf output -json ca_xc_site_names | jq -r '.[]')
  sites+=("${canadian_sites[@]}")
  [ "${#sites[@]}" -eq 6 ] || die "Azure online wait requires six owned sites"
  while ((SECONDS < deadline)); do
    all_online=true
    for site in "${sites[@]}"; do
      state=$(printf 'Authorization: APIToken %s\n' "$XCSH_API_TOKEN" |
        curl -fsS --connect-timeout 10 --max-time 30 -H @- \
          "$XCSH_API_URL/api/config/namespaces/system/sites/$site" 2>/dev/null |
        jq -r '.spec.site_state // .get_spec.site_state // empty') || state=""
      if [ "$state" != ONLINE ]; then
        all_online=false
        break
      fi
    done
    if [ "$all_online" = true ]; then
      jq -n --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{checked_at:$checked_at,online_sites:6,status:"passed"}' \
        >"$PRIVATE_ROOT/$cycle-azure-online-receipt.json"
      return 0
    fi
    sleep 30
  done
  die "six Azure CEs did not become ONLINE before the bounded deadline"
}

settle_azure() {
  local cycle=$1 attempt active_count
  for attempt in 1 2 3 4; do
    phase_paths "$cycle" azure_converge "$attempt"
    tf_plan -input=false -no-color -refresh=true -var-file="$TFVARS" \
      -var='kvm_lan_configuration_phase=configured' \
      -var='aws_site_configuration_phase=configured' \
      -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE"
    active_count=$(tf show -json "$PLAN_FILE" |
      jq '[.resource_changes[]? | select(.change.actions != ["no-op"] and .change.actions != ["read"])] | length')
    if [ "$active_count" -eq 0 ]; then
      scope_plan zero-change
      rm -f -- "$PLAN_FILE"
      return 0
    fi
    [ "$attempt" -lt 4 ] || die "Azure registration labels or provider read-back did not converge after three reviewed plans"
    apply_scoped_plan azure-converge
  done
}

verify_final() {
  local cycle=$1
  phase_paths "$cycle" final refresh-zero-change
  "$REPO_ROOT/scripts/verify-deployment.sh" --terraform-dir "$TERRAFORM_DIR" \
    --evidence-dir "$PHASE_DIR/azure-uat" --subscription "$AZURE_SUBSCRIPTION" --skip-console
  if [ "$cycle" != verify ]; then
    "$REPO_ROOT/scripts/verify-azure-failover.sh" --terraform-dir "$TERRAFORM_DIR" \
      --evidence-dir "$PHASE_DIR/azure-failover" --subscription "$AZURE_SUBSCRIPTION" \
      --source-commit "$SOURCE_COMMIT_SHA"
  fi
  tf_plan -input=false -no-color -refresh=true -var-file="$TFVARS" \
    -var='kvm_lan_configuration_phase=configured' \
    -var='aws_site_configuration_phase=configured' \
    -var="aws_smsv2_device_mapping_file=$MAPPING_FILE" -out="$PLAN_FILE"
  scope_plan zero-change
  rm -f -- "$PLAN_FILE"
}

destroy_all() {
  local cycle=$1 require_kvm=${2:-false}
  phase_paths "$cycle" full_destroy reviewed
  DESTROY_FALLBACK=false
  tf output -json xc_site_names >"$PRIVATE_ROOT/latest-destroy-us-sites.json" 2>/dev/null || printf '{}\n' >"$PRIVATE_ROOT/latest-destroy-us-sites.json"
  tf output -json ca_xc_site_names >"$PRIVATE_ROOT/latest-destroy-ca-sites.json" 2>/dev/null || printf '{}\n' >"$PRIVATE_ROOT/latest-destroy-ca-sites.json"
  tf output -json resource_group_name >"$PRIVATE_ROOT/latest-destroy-us-rg.json" 2>/dev/null || printf 'null\n' >"$PRIVATE_ROOT/latest-destroy-us-rg.json"
  tf output -json ca_resource_group_name >"$PRIVATE_ROOT/latest-destroy-ca-rg.json" 2>/dev/null || printf 'null\n' >"$PRIVATE_ROOT/latest-destroy-ca-rg.json"
  tf state pull >"$EVIDENCE_DIR/prior-state.json"
  tf_plan -destroy -json -input=false -no-color -var-file="$TFVARS" \
    -var='aws_site_configuration_phase=bootstrap' -var='enable_aws_tgw_connect=false' \
    -var='enable_kvm=false' -var='enable_kvm_lan=false' \
    -var='kvm_lan_configuration_phase=disabled' -var='kvm_lan=null' \
    -out="$PLAN_FILE" >"$EVIDENCE_DIR/destroy-events.jsonl"
  if tf show -json "$PLAN_FILE" >"$EVIDENCE_DIR/destroy-plan.json" 2>"$EVIDENCE_DIR/show-json-error.log"; then
    DESTROY_JSON=$(cat "$EVIDENCE_DIR/destroy-plan.json")
  elif [ "$require_kvm" = false ] &&
    grep -Fq 'unsupported attribute "namespace"' "$EVIDENCE_DIR/show-json-error.log"; then
    DESTROY_FALLBACK=true
    DESTROY_JSON=""
  else
    die "saved destroy plan could not be decoded for review"
  fi
  if [ "$require_kvm" = true ]; then
    jq -e '[.resource_changes[]? | select(.type == "xcsh_securemesh_site_v2" and .name == "onprem_kvm" and .change.actions == ["delete"])] | length == 1' \
      <<<"$DESTROY_JSON" >/dev/null || die "destroy plan does not contain the owned KVM site"
  fi
  unset DESTROY_JSON
  apply_scoped_plan full-destroy
  rm -f -- "$EVIDENCE_DIR/prior-state.json" "$EVIDENCE_DIR/destroy-events.jsonl" \
    "$EVIDENCE_DIR/destroy-plan.json" "$EVIDENCE_DIR/show-json-error.log"
  DESTROY_FALLBACK=false
  [ -z "$(tf state list)" ] || die "Terraform state is not empty after destroy"
}

verify_absence() {
  local response_file="$PRIVATE_ROOT/xc-absence.json" status site
  local -a azure_sites=()
  mapfile -t azure_sites < <(jq -r '.[]' "$PRIVATE_ROOT/latest-destroy-us-sites.json" "$PRIVATE_ROOT/latest-destroy-ca-sites.json")
  for site in "${final_sites[@]}" "${bootstrap_sites[@]}" "${SITE_PREFIX}-kvm" "${azure_sites[@]}"; do
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
  local rg
  for file in "$PRIVATE_ROOT/latest-destroy-us-rg.json" "$PRIVATE_ROOT/latest-destroy-ca-rg.json"; do
    rg=$(jq -r '. // empty' "$file")
    [ -z "$rg" ] || [ "$(az group exists --subscription "$AZURE_SUBSCRIPTION" --name "$rg")" = false ] ||
      die "owned Azure resource group remains after destroy: $rg"
  done
  jq -n --arg checked_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --argjson azure_site_count "${#azure_sites[@]}" \
    '{checked_at:$checked_at,azure_site_count:$azure_site_count,aws_instance_count:0,azure_resource_groups_absent:true,xc_sites_absent:true}' \
    >"$PRIVATE_ROOT/absence-receipt-$(date -u +%Y%m%dT%H%M%SZ).json"
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
  scope_plan refresh-only
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
  CYCLE_DIR="$PRIVATE_ROOT/second-private"
  REGISTRATION_PROJECTION=${REGISTRATION_PROJECTION:-$CYCLE_DIR/aws-registration-projection.json}
  ENI_PROJECTION=${ENI_PROJECTION:-$CYCLE_DIR/aws-eni-projection.json}
  MAPPING_FILE=${MAPPING_FILE:-$CYCLE_DIR/aws-device-mapping.json}
  [ -f "$MAPPING_FILE" ] || die "verify requires retained private mapping artifacts"
  verify_final verify
  ;;
destroy)
  destroy_all requested false
  verify_absence
  ;;
build)
  [ -z "$(tf state list)" ] || die "build requires empty state"
  build_cycle build true
  ;;
full)
  if [ -n "$(tf state list)" ]; then
    destroy_all initial false
    verify_absence
  fi
  build_cycle first true
  rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  destroy_all first true
  verify_absence
  build_cycle second true
  ;;
esac

printf 'showcase-lifecycle: mode=%s status=passed final_state=%s evidence=%s\n' \
  "$MODE" "$([ "$MODE" = destroy ] && printf absent || printf online)" "$PRIVATE_ROOT"
