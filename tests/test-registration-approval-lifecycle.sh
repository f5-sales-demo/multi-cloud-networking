#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
module="$repo_root/terraform/modules/xc-site/main.tf"
aws="$repo_root/terraform/aws_xc.tf"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Fq "$1" "$2" || fail "missing $1 in $2"
}

# A registration approval is an action, not a long-lived object. It is legal
# only while XC reports NEW or PENDING. The explicit dependency prevents the approval API
# from auto-provisioning a same-named site while Terraform is creating it.
require 'count = var.approve_registration && data.xcsh_site_registration.this.found && contains(["NEW", "PENDING"], data.xcsh_site_registration.this.state) ? 1 : 0' "$module"
require 'depends_on = [xcsh_securemesh_site_v2.this]' "$module"

# AWS has the same registration lifecycle. Its for_each remains plan-known
# because the data source result is plan-known, while its dependency serializes
# the approval action after all explicitly managed AWS sites exist.
require 'key => registration if registration.found && registration.state == "NEW"' "$aws"
require 'depends_on = [xcsh_securemesh_site_v2.aws]' "$aws"

printf 'PASS: Azure approvals include NEW/PENDING and AWS remains NEW-only and ordered after site creation\n'
