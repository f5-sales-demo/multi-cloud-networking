#!/usr/bin/env bash
# S1 numeric- + S2 string-validation gate for the SMSv2 coverage probe.
#
# Proves the SMSv2 numeric AND string validators both ACCEPT valid input and REJECT invalid
# input, entirely credential-free (mock_provider fires the real schema validators at plan).
# The version under test is whatever `terraform init` resolved at the exact clean-break version in versions.tf
# (the lock file is gitignored) — deliberately NOT restated here, because the per-file copies of
# it drifted across four releases before S8 removed them.
#
# This wraps `terraform test` because Terraform's `expect_failures` only captures user-defined
# custom conditions, not provider schema attribute validators, so a rejection cannot be asserted
# as a passing test run natively.
#
#   Phase 1 (accept): plain `terraform test` runs the root accept case -> must exit 0.
#   Phase 2 (reject): `terraform test -test-directory=reject-tests` runs the DESIGNED-TO-FAIL
#                     reject cases -> must exit non-zero AND emit each leaf's exact validator
#                     message. One reject run per file (a failing run halts its own file).
#
# Idempotent and deterministic: no state, no network, same result every run / in CI.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

echo "== Phase 1: accept valid bounds (plain terraform test) =="
if ! terraform test; then
  fail "accept_valid_bounds did not pass 'terraform test'"
fi

echo
reject_files="$(find reject-tests -name '*.tftest.hcl' | wc -l | tr -d ' ')"
echo "== Phase 2: reject out-of-range input (${reject_files} cases via terraform test -test-directory=reject-tests) =="
# The reject suite is deliberately non-zero.  Capture it in a conditional so
# the assertion phase also runs when Actions supplies errexit via SHELLOPTS.
if reject_out="$(terraform test -test-directory=reject-tests 2>&1)"; then
  reject_rc=0
else
  reject_rc=$?
fi
echo "${reject_out}"

if [ "${reject_rc}" -eq 0 ]; then
  fail "reject suite exited 0 — validators did NOT reject out-of-range input"
fi

# Normalize: strip ANSI colors and box-drawing gutters, then join wrapped diagnostic
# lines into one blob so each validator message matches regardless of terminal wrapping.
reject_norm="$(printf '%s' "${reject_out}" | sed $'s/\x1b\\[[0-9;]*m//g' | tr '\n' ' ' | sed 's/\xe2\x94\x82//g' | tr -s ' ')"

# Each leaf's exact validator diagnostic must appear. The S1 numeric messages come from the
# framework's int64validator; the S2 string messages come from the provider's own
# internal/validators (MAC/CIDR/IP) and the framework's stringvalidator.OneOf (node type).
declare -a expected=(
  # S1 numeric
  "Value 20000 must be in one of these inclusive ranges: 0, 512-8000."
  "Value 8001 must be in one of these inclusive ranges: 0, 512-8000."
  "Value 511 must be in one of these inclusive ranges: 0, 512-8000."
  "must be between 0 and 255, got: 256"
  "must be between 1 and 4095, got: 4096"
  "must be between 0 and 65535, got: 70000"
  # S2 string
  'Value "not-a-mac" is not a valid MAC address'
  'Value "999.999.0.0/8" is not a valid CIDR range'
  'Value "10.0.0.256" is not a valid IP address'
  'Value "300.1.1.1" is not a valid IPv4 address'
  'Value "2001:db8::1" is not a valid IPv4 address'
  'value must be one of: ["Control" "Worker"], got: "Bogus"'
  # S3 interface-arm validated leaves
  "list must contain at least 1 elements and at most 8 elements, got: 0"
  'Value "2001:db8::gg/64" is not a valid CIDR range'
  # S4 networking/services validated leaves
  'value must be one of: ["VIP_VRRP_INVALID" "VIP_VRRP_ENABLE" "VIP_VRRP_DISABLE"], got: "BOGUS"'
  'value must be one of: ["VIRTUAL_NETWORK_SITE_LOCAL"'
  'Value "999.1.1.1" is not a valid IPv4 address'
  'Value "300.2.2.2" is not a valid IPv4 address'
  # S5 site-mode validated leaves (os/sw LengthAtMost(20), drain Between, primary_re LengthBetween,
  # ssh_key LengthAtMost(8192)). The two LengthAtMost(20) messages are
  # identical text, so each is qualified by its attribute path to prove BOTH leaves independently.
  "software_settings.os.operating_system_version string length must be at most 20, got: 21"
  "software_settings.sw.volterra_software_version string length must be at most 20, got: 21"
  "must be between 1 and 5000, got: 5001"
  "must be between 1 and 5000, got: 0"
  "must be between 0 and 900, got: 901"
  "re_select.specific_re.primary_re string length must be between 1 and 64, got: 65"
  "admin_user_credentials.ssh_key string length must be at most 8192, got: 8200"
)
for msg in "${expected[@]}"; do
  case "${reject_norm}" in
  *"${msg}"*) echo "OK: validator emitted -> ${msg}" ;;
  *) fail "expected validator message not found -> ${msg}" ;;
  esac
done

echo
# Count-driven, NOT a hand-maintained prose list: the previous summary re-listed the leaves and
# drifted out of step with `expected` (it still said "all four numeric leaves" and left a
# parenthesis unclosed). The array above is the single source of truth for what is asserted.
echo "PASS: the accept case plans clean and all ${#expected[@]} asserted validator diagnostics were emitted"
echo "      by the ${reject_files} reject cases in reject-tests/ (see the 'expected' array for the exact list)."
