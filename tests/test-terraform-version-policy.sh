#!/usr/bin/env bash
# Regression guard for the released SMSv2 clean-break provider boundary.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/terraform.yml"
EXAMPLE="${REPO_ROOT}/terraform/terraform.tfvars.example"
FAIL=0

ok() { printf '  ok   — %s\n' "$1"; }
bad() {
  printf '  FAIL — %s\n' "$1"
  FAIL=1
}

echo "1. lifecycle execution pins Terraform 1.16.3"
if [ -e "${REPO_ROOT}/terraform/.terraform-version" ]; then
  bad "terraform/.terraform-version pins the Terraform CLI"
else
  ok "no competing local Terraform CLI pin"
fi
if [ "$(grep -Ec '^[[:space:]]*terraform_version:[[:space:]]*1\.16\.3$' "$WORKFLOW")" -eq 2 ]; then
  ok "both Terraform workflow jobs pin 1.16.3"
else
  bad "Terraform workflow jobs do not both pin 1.16.3"
fi

echo "2. every xcsh consumer pins exactly v10.1.0"
for relative in terraform/versions.tf \
  terraform/recovery/aws-smsv2-orphans/versions.tf \
  terraform/modules/xc-site/versions.tf \
  terraform/modules/kvm/providers.tf coverage/smsv2/versions.tf; do
  file="${REPO_ROOT}/${relative}"
  block=$(sed -n '/^[[:space:]]*xcsh = {/,/^[[:space:]]*}/p' "$file")
  if printf '%s\n' "$block" | grep -Eq 'version[[:space:]]*=[[:space:]]*"= 10\.1\.0"'; then
    ok "${relative} pins = 10.1.0"
  else
    bad "${relative} does not pin exactly = 10.1.0"
  fi
  count=$(printf '%s\n' "$block" | grep -Ec '^[[:space:]]*version[[:space:]]*=' || true)
  [ "$count" -eq 1 ] || bad "${relative} has ${count} xcsh version constraints"
done

for relative in .github/workflows/terraform.yml prompt.txt docs/en/demo/deploy.mdx \
  docs/en/demo/prompt.mdx docs/en/demo/spec.mdx docs/en/demo/terraform.mdx \
  tests/test-verify-deployment.sh; do
  if grep -Fq '10.1.0' "${REPO_ROOT}/${relative}"; then
    ok "${relative} references v10.1.0"
  else
    bad "${relative} is missing the v10.1.0 reference"
  fi
done
legacy_version='7''.''4''.''1'
if grep -R -n -F --exclude-dir=.terraform --exclude=.terraform.lock.hcl "$legacy_version" \
  "${REPO_ROOT}/terraform" "${REPO_ROOT}/coverage/smsv2" \
  "${REPO_ROOT}/.github/workflows/terraform.yml" "${REPO_ROOT}/prompt.txt" \
  "${REPO_ROOT}/docs/en"; then
  bad "a legacy provider consumer or English reference remains"
else
  ok "no legacy provider consumer or English reference remains"
fi

source_count=$(grep -R -lF 'source  = "f5-sales-demo/xcsh"' \
  "${REPO_ROOT}/terraform" "${REPO_ROOT}/coverage/smsv2" --include='*.tf' | wc -l)
if [ "$source_count" -eq 5 ]; then
  ok "the five known xcsh consumers are the complete provider surface"
else
  bad "expected exactly five xcsh provider declarations, found ${source_count}"
fi

echo "3. the v10 clean break has no legacy observation-freshness inputs"
if grep -R -n -E 'aws_bgp_max_observation_age_seconds|max_observation_age_seconds|observed_at' \
  "${REPO_ROOT}/terraform" --include='*.tf' --include='*.tftest.hcl'; then
  bad "legacy observation freshness fields remain in Terraform"
else
  ok "Terraform uses deadline/poll controls and state_changed_at only"
fi

echo "4. provider resolution is clean and reproducible"
if git -C "$REPO_ROOT" ls-files --error-unmatch terraform/.terraform.lock.hcl >/dev/null 2>&1; then
  ok "unified-root Terraform lockfile is committed"
else
  bad "unified-root Terraform lockfile is not committed"
fi
if grep -Fqx '!terraform/.terraform.lock.hcl' "${REPO_ROOT}/.gitignore"; then
  ok "unified-root lockfile has a narrow ignore exception"
else
  bad "unified-root lockfile is still ignored"
fi

echo "5. the fresh-clone example keeps environment values external"
for assignment in 'ce_os_version = ""' 'ce_sw_version = ""' 'lb_domain = "mcn-ce-ha.example.com"' 'subscription_id = "<AZURE_SUBSCRIPTION_ID>"' 'xc_app_namespace = "demo-app"'; do
  if grep -Fqx "$assignment" "$EXAMPLE"; then
    ok "example contains ${assignment}"
  else
    bad "example is missing ${assignment}"
  fi
done
if grep -Fq 'f5-sales-demo.' "$EXAMPLE"; then
  bad "example publishes a deployment-specific domain"
else
  ok "example contains no deployment-specific domain"
fi

echo "6. policy-test edits trigger Terraform CI"
trigger_count=$(grep -cF "'tests/test-terraform-version-policy.sh'" "$WORKFLOW" || true)
if [ "$trigger_count" -eq 2 ]; then
  ok "pull_request and push watch the policy test"
else
  bad "expected two workflow path filters, found ${trigger_count}"
fi

echo "7. provider v10.1.0 uses one immutable API release identity"
api_tag='v7.0.9'
release_revision_left='1c4f4eb8dd6cd9c440c2'
release_revision_right='41b995a6c0ef1bcd23ab'
for relative in terraform/aws_tgw_connect.tf terraform/tests/aws_tgw_connect.tftest.hcl \
  scripts/aws-smsv2-uat-preflight.sh tests/test-aws-smsv2-uat-preflight.sh \
  docs/en/demo/deploy.mdx; do
  if grep -Fq "$api_tag" "${REPO_ROOT}/${relative}"; then
    ok "${relative} requires ${api_tag}"
  else
    bad "${relative} is missing ${api_tag}"
  fi
done
for relative in terraform/aws_tgw_connect.tf terraform/tests/aws_tgw_connect.tftest.hcl \
  scripts/aws-smsv2-uat-preflight.sh tests/test-aws-smsv2-uat-preflight.sh; do
  if grep -Fq "$release_revision_left" "${REPO_ROOT}/${relative}" &&
    grep -Fq "$release_revision_right" "${REPO_ROOT}/${relative}"; then
    ok "${relative} requires the exact v7.0.9 commit"
  else
    bad "${relative} is missing the exact v7.0.9 commit"
  fi
done
legacy_api_tag='v7''.''0''.''8'
if grep -R -n -F "$legacy_api_tag" \
  "${REPO_ROOT}/terraform" "${REPO_ROOT}/scripts" "${REPO_ROOT}/tests" \
  "${REPO_ROOT}/docs/en"; then
  bad "the previous immutable API release remains"
else
  ok "the previous immutable API release is absent"
fi

if [ "$FAIL" -eq 0 ]; then
  echo "PASS: Terraform version policy"
else
  echo "FAIL: Terraform version policy"
fi
exit "$FAIL"
