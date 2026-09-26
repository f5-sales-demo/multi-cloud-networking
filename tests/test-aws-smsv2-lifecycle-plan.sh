#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRIPT="$REPO_ROOT/scripts/aws-smsv2-lifecycle-plan.sh"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mcn-lifecycle-plan-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}
require() { grep -Fq -- "$1" "$2" || fail "missing $1 in $2"; }

identity_args=(
  --source-repository f5-sales-demo/multi-cloud-networking
  --source-ref refs/heads/main
  --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  --deployment-owner-id showcase-team
  --deployment-actor-id github-actions
  --deployment-environment-key production
  --backend-key mcn-ce-ha-smsv2/showcase.tfstate
)

"$SCRIPT" --help >/dev/null
if "$SCRIPT" --plan-file "$SCRATCH/plan" --evidence-dir "$SCRATCH/evidence" --tfvars "$SCRATCH/missing" >"$SCRATCH/out" 2>&1; then
  fail "missing phase must fail"
fi
grep -Fq -- '--phase is required' "$SCRATCH/out" || fail "missing phase reason"

mkdir "$SCRATCH/evidence"
: >"$SCRATCH/input.tfvars"
if "$SCRIPT" --phase bootstrap --plan-file "$REPO_ROOT/plan.tfplan" --evidence-dir "$SCRATCH/evidence" --tfvars "$SCRATCH/input.tfvars" --expected-aws-region ap-northeast-1 "${identity_args[@]}" >"$SCRATCH/out" 2>&1; then
  fail "repository plan path must fail"
fi
grep -Fq 'outside the repository' "$SCRATCH/out" || fail "repository plan rejection reason"

rm -rf "$SCRATCH/evidence"
mkdir "$SCRATCH/evidence"
if "$SCRIPT" --phase configured --plan-file "$SCRATCH/plan" --evidence-dir "$SCRATCH/evidence" --tfvars "$SCRATCH/input.tfvars" --expected-aws-region ap-northeast-1 "${identity_args[@]}" >"$SCRATCH/out" 2>&1; then
  fail "configured without mapping must fail"
fi
grep -Fq 'configured requires --mapping-file' "$SCRATCH/out" || fail "mapping rejection reason"

require 'AWS_PROFILE=${AWS_PROFILE:-sso}' "$SCRIPT"
require 'terraform-with-aws-sso.sh" --profile "$AWS_PROFILE" --region "$EXPECTED_AWS_REGION"' "$SCRIPT"
require 'aws_site_configuration_phase=$PHASE' "$SCRIPT"
require 'enable_aws_tgw_connect=$CONFIGURED_TGW' "$SCRIPT"
require '--configured-tgw must be true or false' "$SCRIPT"
require 'generate-aws-smsv2-device-mapping.py' "$SCRIPT"
require 'registration-projection must be outside the repository' "$SCRIPT"
require 'plan-file must not already exist' "$SCRIPT"
require '--verify-file "$MAPPING_FILE"' "$SCRIPT"
require '--cleanup-private-inputs' "$SCRIPT"
require '--apply requires an existing saved plan' "$SCRIPT"
require 'cross-environment or stale saved plan receipt rejected' "$SCRIPT"
require '.environment_key == $environment_key' "$SCRIPT"
require '.source_commit == $source_commit' "$SCRIPT"
require '.backend_key == $backend_key' "$SCRIPT"
require 'saved plan does not have a ready preflight receipt' "$SCRIPT"
require 'aws-smsv2-uat-preflight.sh' "$SCRIPT"
require 'saved plan changed during review' "$SCRIPT"
require 'plan-receipt.json' "$SCRIPT"
require 'apply -input=false -no-color "$PLAN_FILE"' "$SCRIPT"
require 'rm -f -- "$MAPPING_FILE" "$REGISTRATION_PROJECTION" "$ENI_PROJECTION"' "$SCRIPT"

rm -rf "$SCRATCH/evidence"
mkdir "$SCRATCH/evidence"
printf 'reviewed-plan' >"$SCRATCH/plan"
printf '%s\n' '{"status":"ready","reason":"preflight_passed"}' >"$SCRATCH/evidence/summary.json"
plan_sha256="sha256:$(sha256sum "$SCRATCH/plan" | awk '{print $1}')"
jq -n --arg plan_sha256 "$plan_sha256" \
  '{phase:"bootstrap",plan_sha256:$plan_sha256,environment_key:"another-environment",source_commit:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",backend_key:"mcn-ce-ha-smsv2/showcase.tfstate"}' \
  >"$SCRATCH/evidence/plan-receipt.json"
if "$SCRIPT" --phase bootstrap --apply --plan-file "$SCRATCH/plan" \
  --evidence-dir "$SCRATCH/evidence" --tfvars "$SCRATCH/input.tfvars" \
  --expected-aws-region ap-northeast-1 "${identity_args[@]}" >"$SCRATCH/out" 2>&1; then
  fail "cross-environment receipt must fail before Terraform apply"
fi
grep -Fq 'cross-environment or stale saved plan receipt rejected' "$SCRATCH/out" ||
  fail "cross-environment receipt rejection reason"
echo "PASS: AWS SMSv2 lifecycle creates an immutable reviewed phase plan before optional apply"
