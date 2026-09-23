#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_script="$repo_root/scripts/configure-aws-state-backend.sh"
source_wrapper="$repo_root/scripts/terraform-with-aws-sso.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[ -x "$source_script" ] || fail "backend configuration script is not executable"

mkdir -p "$work/repo/scripts" "$work/repo/terraform/bootstrap/state-backend/.terraform" \
  "$work/repo/terraform" "$work/repo/terraform/recovery/aws-smsv2-orphans" "$work/bin"
cp "$source_script" "$work/repo/scripts/"
cp "$source_wrapper" "$work/repo/scripts/"
cp "$repo_root/scripts/deployment-identity.py" "$work/repo/scripts/"

cat >"$work/source-config" <<'CONFIG'
[profile default]
region = ap-northeast-1
CONFIG

cat >"$work/bin/aws" <<'AWS'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
"configure export-credentials --profile default --format process")
  printf '%s\n' '{"Version":1,"AccessKeyId":"test_access","SecretAccessKey":"test_secret","SessionToken":"test_session","Expiration":"2099-01-01T00:00:00Z"}'
  ;;
"sts get-caller-identity --profile default --query Account --output text")
  printf '123456789012\n'
  ;;
"configure get region --profile default")
  printf 'ap-northeast-1\n'
  ;;
*) exit 1 ;;
esac
AWS

cat >"$work/bin/terraform" <<'TERRAFORM'
#!/usr/bin/env bash
set -euo pipefail
chdir=
for argument in "$@"; do
  case "$argument" in
  -chdir=*) chdir=${argument#-chdir=} ;;
  esac
done
[ -n "$chdir" ]
if [[ " $* " == *" output -json "* ]]; then
  if [ -f "$chdir/backend.generated.tf" ] && [ ! -s "$chdir/.terraform/terraform.tfstate" ]; then
    printf 'backend initialization required\n' >&2
    exit 1
  fi
  cat <<'JSON'
{"bootstrap_backend_hcl":{"value":{"bucket":"example-mcn-state-123456789012","key":"mcn-ce-ha-smsv2/bootstrap.tfstate","region":"ap-northeast-1","encrypt":true,"kms_key_id":"arn:aws:kms:ap-northeast-1:123456789012:key/11111111-2222-3333-4444-555555555555","use_lockfile":true}}}
JSON
  exit 0
fi
if [[ " $* " == *" init "* ]]; then
  printf '%s\n' "$*" >>"${BACKEND_TEST_CALLS:?}"
  if [ -n "${BACKEND_TEST_FAIL_ONCE:-}" ] && [ ! -e "${BACKEND_TEST_FAILED_MARKER:?}" ]; then
    : >"$BACKEND_TEST_FAILED_MARKER"
    exit 1
  fi
  mkdir -p "$chdir/.terraform"
  cat >"$chdir/.terraform/terraform.tfstate" <<'JSON'
{"backend":{"type":"s3","config":{"bucket":"example-mcn-state-123456789012","key":"mcn-ce-ha-smsv2/bootstrap.tfstate","region":"ap-northeast-1","encrypt":true,"kms_key_id":"arn:aws:kms:ap-northeast-1:123456789012:key/11111111-2222-3333-4444-555555555555","use_lockfile":true}}}
JSON
  exit 0
fi
exit 1
TERRAFORM
chmod +x "$work/bin/aws" "$work/bin/terraform"

run_configure() {
  BACKEND_TEST_CALLS="$work/calls" \
    BACKEND_TEST_FAILED_MARKER="$work/failed-once" \
    PATH="$work/bin:$PATH" \
    AWS_CONFIG_FILE="$work/source-config" \
    "$work/repo/scripts/configure-aws-state-backend.sh" --profile default \
    --source-ref refs/heads/main \
    --source-commit-sha aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
    --deployment-owner-id showcase-team \
    --deployment-actor-id github-actions
}

run_configure_preview() {
  BACKEND_TEST_CALLS="$work/calls" \
    BACKEND_TEST_FAILED_MARKER="$work/failed-once" \
    PATH="$work/bin:$PATH" \
    AWS_CONFIG_FILE="$work/source-config" \
    "$work/repo/scripts/configure-aws-state-backend.sh" --profile default \
    --source-ref refs/heads/feature/a \
    --source-commit-sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
    --deployment-owner-id showcase-team \
    --deployment-actor-id github-actions
}

if BACKEND_TEST_FAIL_ONCE=1 run_configure >/dev/null 2>&1; then
  fail "simulated first migration unexpectedly succeeded"
fi
run_configure

bootstrap_hcl="$work/repo/terraform/bootstrap/state-backend/backend.hcl"
aws_hcl="$work/repo/terraform/backend.hcl"
recovery_hcl="$work/repo/terraform/recovery/aws-smsv2-orphans/backend.hcl"
backend_block="$work/repo/terraform/bootstrap/state-backend/backend.generated.tf"
for generated in "$bootstrap_hcl" "$aws_hcl" "$recovery_hcl" "$backend_block"; do
  [ -f "$generated" ] || fail "missing generated backend file $generated"
  [ "$(stat -c %a "$generated" 2>/dev/null || stat -f %Lp "$generated")" = 600 ] ||
    fail "generated backend file is not mode 600: $generated"
done
grep -Fq 'backend "s3" {}' "$backend_block" || fail "generated backend declaration is missing"
grep -Fq 'key          = "mcn-ce-ha-smsv2/bootstrap.tfstate"' "$bootstrap_hcl" || fail "bootstrap key is wrong"
grep -Fq "key          = \"mcn-ce-ha-smsv2/showcase.tfstate\"" "$aws_hcl" || fail "showcase key is wrong"
grep -Fq 'key          = "mcn-ce-ha-smsv2/recovery/smsv2-orphans.tfstate"' "$recovery_hcl" ||
  fail "orphan recovery key is wrong"
grep -Fq 'init -force-copy -input=false -backend-config=backend.hcl' "$work/calls" || fail "local state was not migrated"

run_configure
grep -Fq 'init -reconfigure -input=false -backend-config=backend.hcl' "$work/calls" || fail "remote state was not reconfigured idempotently"

run_configure_preview
preview_key=$("$work/repo/scripts/deployment-identity.py" \
  --repository f5-sales-demo/multi-cloud-networking \
  --source-ref refs/heads/feature/a \
  --source-commit bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb \
  --owner-id showcase-team --actor-id github-actions | jq -r .stateKey)
grep -Fq "key          = \"$preview_key\"" "$aws_hcl" || fail "preview showcase key is not isolated"
grep -Fq "/environments/" "$recovery_hcl" || fail "preview recovery key is not isolated"

printf 'PASS: AWS backend files and bootstrap-state migration are generated deterministically\n'
