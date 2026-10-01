#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
scratch=$(mktemp -d "${TMPDIR:-/tmp}/mcn-uat-sso-test.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
mkdir "$scratch/scripts" "$scratch/bin"
cat >"$scratch/scripts/terraform-with-aws-sso.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" >"$CALLS"
[ "$1" = --profile ] && [ "$2" = selected-sso ]
[ "$3" = --region ] && [ "$4" = ap-northeast-1 ]
[ "$5" = -- ]
[ "$TF_CLI_CONFIG_FILE" = selected.tfrc ]
[ "$XCSH_API_URL" = https://test.example ] && [ "$XCSH_API_TOKEN" = test-token ]
printf 'isolated-route\n'
WRAPPER
cat >"$scratch/bin/terraform" <<'DIRECT'
#!/usr/bin/env bash
printf 'direct Terraform route is forbidden\n' >&2
exit 71
DIRECT
chmod +x "$scratch/scripts/terraform-with-aws-sso.sh" "$scratch/bin/terraform"
sed -n '/^tf() {/,/^}/p' "$repo/scripts/aws-smsv2-uat-preflight.sh" >"$scratch/tf-helper.sh"
# shellcheck source=/dev/null
source "$scratch/tf-helper.sh"
export CALLS="$scratch/calls"
export PATH="$scratch/bin:$PATH"
REPO_ROOT=$scratch
TERRAFORM_DIR=/synthetic/terraform
SELECTED_CLI_CONFIG=selected.tfrc
API_URL=https://test.example
API_TOKEN=test-token
AWS_SSO_SOURCE_PROFILE=selected-sso
EXPECTED_AWS_REGION=ap-northeast-1
tf plan -refresh-only >"$scratch/result"
grep -Fxq isolated-route "$scratch/result"
grep -Fxq -- '-chdir=/synthetic/terraform' "$CALLS"
grep -Fxq -- '-refresh-only' "$CALLS"
printf 'PASS: live UAT Terraform uses the isolated SSO credential route\n'
