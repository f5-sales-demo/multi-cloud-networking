#!/usr/bin/env bash
# Create, review, and optionally apply exactly one AWS SMSv2 lifecycle phase.
# All persistent evidence and plans must be outside the repository.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
TERRAFORM_DIR="$REPO_ROOT/terraform"
PHASE=""
PLAN_FILE=""
EVIDENCE_DIR=""
TFVARS=""
MAPPING_FILE=""
REGISTRATION_PROJECTION=""
ENI_PROJECTION=""
APPLY=false
CONFIGURED_TGW=true
CLEANUP_PRIVATE_INPUTS=false
PREFLIGHT_ARGS=()
EXPECTED_AWS_REGION=""
AWS_PROFILE=${AWS_PROFILE:-sso}
SOURCE_REPOSITORY=""
SOURCE_REF=""
SOURCE_COMMIT_SHA=""
DEPLOYMENT_OWNER_ID=""
DEPLOYMENT_ACTOR_ID=""
DEPLOYMENT_ENVIRONMENT_KEY=""
BACKEND_KEY=""

usage() {
  cat <<'EOF'
Usage: aws-smsv2-lifecycle-plan.sh --phase bootstrap|bootstrap_retirement|configured \
  --plan-file PRIVATE_PATH --evidence-dir EMPTY_PRIVATE_DIRECTORY --tfvars PRIVATE_TFVARS \
  --expected-aws-account ID --expected-aws-region REGION --expected-xc-tenant NAME \
  --creator-id EMAIL --deployment-generation VALUE --expected-site NAME [--expected-site NAME ...] \
  --source-repository NAME --source-ref REF --source-commit-sha SHA \
  --deployment-owner-id ID --deployment-actor-id ID --deployment-environment-key KEY --backend-key KEY \
  [--mapping-file PRIVATE_PATH --registration-projection PRIVATE_PATH --eni-projection PRIVATE_PATH] \
  [--configured-tgw true|false] [--cleanup-private-inputs] [--apply]

Without --apply, the script creates a saved plan, records only its SHA-256
digest, and calls the non-mutating AWS SMSv2 preflight. With --apply, it
requires that existing reviewed plan and receipt, rechecks the digest, and
applies that exact plan without generating a replacement. bootstrap and
bootstrap_retirement forcibly disable TGW Connect; configured forcibly enables
it and generates the private mapping from the observed bootstrap registration
and Terraform-owned ENI projections during the planning invocation.
EOF
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
  --phase)
    PHASE=${2:?}
    shift 2
    ;;
  --plan-file)
    PLAN_FILE=${2:?}
    shift 2
    ;;
  --evidence-dir)
    EVIDENCE_DIR=${2:?}
    shift 2
    ;;
  --tfvars)
    TFVARS=${2:?}
    shift 2
    ;;
  --mapping-file)
    MAPPING_FILE=${2:?}
    shift 2
    ;;
  --registration-projection)
    REGISTRATION_PROJECTION=${2:?}
    shift 2
    ;;
  --eni-projection)
    ENI_PROJECTION=${2:?}
    shift 2
    ;;
  --apply)
    APPLY=true
    shift
    ;;
  --configured-tgw)
    CONFIGURED_TGW=${2:?}
    shift 2
    ;;
  --cleanup-private-inputs)
    CLEANUP_PRIVATE_INPUTS=true
    shift
    ;;
  --expected-aws-account | --expected-aws-region | --expected-xc-tenant | --creator-id | --deployment-generation | --component | --expected-site)
    [ "$1" != --expected-aws-region ] || EXPECTED_AWS_REGION=${2:?}
    PREFLIGHT_ARGS+=("$1" "${2:?}")
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
  --deployment-environment-key)
    DEPLOYMENT_ENVIRONMENT_KEY=${2:?}
    shift 2
    ;;
  --backend-key)
    BACKEND_KEY=${2:?}
    shift 2
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *) die "unknown argument: $1" ;;
  esac
done

case "$PHASE" in bootstrap | bootstrap_retirement | configured) ;; *) die "--phase is required" ;; esac
case "$CONFIGURED_TGW" in true | false) ;; *) die "--configured-tgw must be true or false" ;; esac
[ "$PHASE" = configured ] || [ "$CONFIGURED_TGW" = true ] || die "--configured-tgw is valid only for configured"
[ "$PHASE" = configured ] || [ "$CLEANUP_PRIVATE_INPUTS" = false ] || die "--cleanup-private-inputs is valid only for configured"
[ -n "$PLAN_FILE" ] || die "--plan-file is required"
[ -n "$EVIDENCE_DIR" ] || die "--evidence-dir is required"
[ -n "$TFVARS" ] || die "--tfvars is required"
[ -n "$EXPECTED_AWS_REGION" ] || die "--expected-aws-region is required"
[ -n "$SOURCE_REPOSITORY" ] || die "--source-repository is required"
[ -n "$SOURCE_REF" ] || die "--source-ref is required"
[ -n "$SOURCE_COMMIT_SHA" ] || die "--source-commit-sha is required"
[ -n "$DEPLOYMENT_OWNER_ID" ] || die "--deployment-owner-id is required"
[ -n "$DEPLOYMENT_ACTOR_ID" ] || die "--deployment-actor-id is required"
[ -n "$DEPLOYMENT_ENVIRONMENT_KEY" ] || die "--deployment-environment-key is required"
[ -n "$BACKEND_KEY" ] || die "--backend-key is required"
PREFLIGHT_ARGS+=(
  --source-repository "$SOURCE_REPOSITORY"
  --source-ref "$SOURCE_REF"
  --source-commit-sha "$SOURCE_COMMIT_SHA"
  --deployment-owner-id "$DEPLOYMENT_OWNER_ID"
  --deployment-actor-id "$DEPLOYMENT_ACTOR_ID"
)
[ -f "$TFVARS" ] || die "--tfvars is not readable"
[ -d "$EVIDENCE_DIR" ] || die "--evidence-dir must already exist"

PLAN_FILE=$(realpath -m "$PLAN_FILE")
EVIDENCE_DIR=$(realpath "$EVIDENCE_DIR")
case "$PLAN_FILE" in "$REPO_ROOT"/*) die "--plan-file must be outside the repository" ;; esac
case "$EVIDENCE_DIR" in "$REPO_ROOT"/*) die "--evidence-dir must be outside the repository" ;; esac
if [ "$APPLY" = true ]; then
  [ -f "$PLAN_FILE" ] || die "--apply requires an existing saved plan"
  [ -f "$EVIDENCE_DIR/summary.json" ] || die "--apply requires a preflight receipt"
  [ -f "$EVIDENCE_DIR/plan-receipt.json" ] || die "--apply requires a plan receipt"
else
  [ ! -e "$PLAN_FILE" ] || die "--plan-file must not already exist"
  [ -z "$(find "$EVIDENCE_DIR" -mindepth 1 -maxdepth 1 -print -quit)" ] || die "--evidence-dir must be empty"
fi

if [ "$PHASE" = configured ]; then
  [ -n "$MAPPING_FILE" ] || die "configured requires --mapping-file"
  [ -n "$REGISTRATION_PROJECTION" ] || die "configured requires --registration-projection"
  [ -n "$ENI_PROJECTION" ] || die "configured requires --eni-projection"
  MAPPING_FILE=$(realpath "$MAPPING_FILE")
  REGISTRATION_PROJECTION=$(realpath "$REGISTRATION_PROJECTION")
  ENI_PROJECTION=$(realpath "$ENI_PROJECTION")
  [ -f "$REGISTRATION_PROJECTION" ] || die "--registration-projection is not readable"
  [ -f "$ENI_PROJECTION" ] || die "--eni-projection is not readable"
  if [ "$APPLY" = true ]; then
    [ -f "$MAPPING_FILE" ] || die "--apply requires the reviewed mapping artifact for cleanup"
  fi
  case "$MAPPING_FILE" in "$REPO_ROOT"/*) die "--mapping-file must be outside the repository" ;; esac
  case "$REGISTRATION_PROJECTION" in "$REPO_ROOT"/*) die "--registration-projection must be outside the repository" ;; esac
  case "$ENI_PROJECTION" in "$REPO_ROOT"/*) die "--eni-projection must be outside the repository" ;; esac
else
  [ -z "$MAPPING_FILE$REGISTRATION_PROJECTION$ENI_PROJECTION" ] || die "mapping inputs are valid only for configured"
fi

TF_RUNNER=("$REPO_ROOT/scripts/terraform-with-aws-sso.sh" --profile "$AWS_PROFILE" --region "$EXPECTED_AWS_REGION")
TF_IDENTITY_ARGS=(
  -var="source_repository=$SOURCE_REPOSITORY"
  -var="source_ref=$SOURCE_REF"
  -var="source_commit_sha=$SOURCE_COMMIT_SHA"
  -var="deployment_owner_id=$DEPLOYMENT_OWNER_ID"
  -var="deployment_actor_id=$DEPLOYMENT_ACTOR_ID"
)
PLAN_MODE=apply
TF_PHASE_ARGS=(-var="aws_site_configuration_phase=$PHASE")
# This helper owns the AWS and initial two-NIC KVM stages. Azure is added only
# after the AWS/KVM registration and mapping gates have passed.
TF_PHASE_ARGS+=(
  -var='enable_azure=false' -var='enable_canada=false'
  -var='enable_azure_ilb=false' -var='enable_canada_ilb=false'
  -var='kvm_lan_configuration_phase=hardware'
)
if [ "$PHASE" = configured ]; then
  TF_PHASE_ARGS+=(-var="enable_aws_tgw_connect=$CONFIGURED_TGW" -var="aws_smsv2_device_mapping_file=$MAPPING_FILE")
else
  TF_PHASE_ARGS+=(-var='enable_aws_tgw_connect=false')
fi
if [ "$PHASE" = bootstrap_retirement ]; then PLAN_MODE=destroy; fi

if [ "$APPLY" = true ]; then
  PLAN_SHA256="sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
  jq -e --arg phase "$PHASE" --arg plan_sha256 "$PLAN_SHA256" \
    --arg environment_key "$DEPLOYMENT_ENVIRONMENT_KEY" --arg source_commit "$SOURCE_COMMIT_SHA" \
    --arg backend_key "$BACKEND_KEY" '
    .phase == $phase and .plan_sha256 == $plan_sha256 and
    .environment_key == $environment_key and .source_commit == $source_commit and
    .backend_key == $backend_key' "$EVIDENCE_DIR/plan-receipt.json" >/dev/null ||
    die "cross-environment or stale saved plan receipt rejected"
  jq -e '.status == "ready" and .reason == "preflight_passed"' "$EVIDENCE_DIR/summary.json" >/dev/null ||
    die "saved plan does not have a ready preflight receipt"
  "${TF_RUNNER[@]}" -- -chdir="$TERRAFORM_DIR" apply -input=false -no-color "$PLAN_FILE"
  if [ "$PHASE" = configured ] && [ "$CLEANUP_PRIVATE_INPUTS" = true ]; then
    rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"
  fi
  exit 0
fi

if [ "$PHASE" = configured ]; then
  if [ -f "$MAPPING_FILE" ]; then
    "$REPO_ROOT/scripts/generate-aws-smsv2-device-mapping.py" \
      --verify-file "$MAPPING_FILE" --eni-file "$ENI_PROJECTION"
  else
    "$REPO_ROOT/scripts/generate-aws-smsv2-device-mapping.py" \
      --registration-file "$REGISTRATION_PROJECTION" --eni-file "$ENI_PROJECTION" --output "$MAPPING_FILE"
  fi
  "$REPO_ROOT/scripts/generate-aws-smsv2-device-mapping.py" \
    --verify-file "$MAPPING_FILE" --eni-file "$ENI_PROJECTION"
fi

mkdir -p "$(dirname "$PLAN_FILE")"
umask 077
"${TF_RUNNER[@]}" -- -chdir="$TERRAFORM_DIR" plan -input=false -no-color -var-file="$TFVARS" \
  "${TF_IDENTITY_ARGS[@]}" "${TF_PHASE_ARGS[@]}" -out="$PLAN_FILE"

PLAN_SHA256="sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')"
PREFLIGHT_INPUT_ARGS=(--tfvars "$TFVARS")
if [ "$PHASE" = configured ]; then
  PREFLIGHT_INPUT_ARGS+=(--mapping-file "$MAPPING_FILE")
fi
"$REPO_ROOT/scripts/aws-smsv2-uat-preflight.sh" \
  --evidence-dir "$EVIDENCE_DIR" --terraform-dir "$TERRAFORM_DIR" --plan-file "$PLAN_FILE" \
  "${PREFLIGHT_INPUT_ARGS[@]}" --plan-mode "$PLAN_MODE" --lifecycle-phase "$PHASE" \
  "${PREFLIGHT_ARGS[@]}"

[ "$PLAN_SHA256" = "sha256:$(sha256sum "$PLAN_FILE" | awk '{print $1}')" ] || die "saved plan changed during review"
jq -n --arg phase "$PHASE" --arg plan_sha256 "$PLAN_SHA256" \
  --arg environment_key "$DEPLOYMENT_ENVIRONMENT_KEY" --arg source_commit "$SOURCE_COMMIT_SHA" \
  --arg backend_key "$BACKEND_KEY" \
  '{phase:$phase,plan_sha256:$plan_sha256,environment_key:$environment_key,source_commit:$source_commit,backend_key:$backend_key}' \
  >"$EVIDENCE_DIR/plan-receipt.json"
chmod 600 "$EVIDENCE_DIR/plan-receipt.json"

exit 0
