#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
root="$repo_root/terraform"
lifecycle="$repo_root/scripts/showcase-lifecycle.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require() {
  grep -Fq -- "$1" "$2" || fail "missing $1 in ${2#"$repo_root"/}"
}

reject() {
  ! grep -Fq -- "$1" "$2" || fail "unexpected $1 in ${2#"$repo_root"/}"
}

test ! -d "$root/aws" || fail 'terraform/aws remains as a second active root'

require 'required_version = "= 1.16.3"' "$root/versions.tf"
require 'variable "aws_site_configuration_phase"' "$root/variables_aws.tf"
require 'variable "aws_smsv2_device_mapping_file"' "$root/variables_aws.tf"
require 'data "xcsh_site_registrations_by_site" "kvm"' "$root/onprem_kvm.tf"
require 'resource "xcsh_registration_approval" "kvm"' "$root/onprem_kvm.tf"
require 'data "xcsh_smsv2_kvm_runtime" "kvm_slo"' "$root/onprem_kvm.tf"
require 'resource "xcsh_smsv2_kvm_runtime_interface" "kvm_lan_sli"' "$root/onprem_kvm.tf"
reject 'data "external" "kvm_network_interface"' "$root/onprem_kvm.tf"
reject 'resource "xcsh_network_interface" "kvm_lan_sli"' "$root/onprem_kvm.tf"
require 'data "external" "kvm_bgp_observer"' "$root/onprem_kvm.tf"
reject 'hostname  = "onprem-ce-${each.key}"' "$root/onprem_kvm.tf"
reject 'hostname  = "onprem-ce-${each.key}"' "$root/modules/kvm/onprem_kvm.tf"
reject 'expected_exported_routes = []' "$root/onprem_kvm.tf"
test -f "$root/scripts/xc-kvm-bgp-observer.py" || fail 'KVM BGP observer is missing'
test -f "$repo_root/tests/test_xc_kvm_bgp_observer.py" || fail 'KVM BGP observer tests are missing'
test -f "$root/tests/kvm_registration_mapping.tftest.hcl" || fail 'KVM registration mapping fixtures are missing'
require 'configured_kvm_mapping_is_exact' "$root/tests/kvm_registration_mapping.tftest.hcl"
require 'configured_kvm_mapping_rejects_missing_owned_mac' "$root/tests/kvm_registration_mapping.tftest.hcl"
require 'configured_kvm_mapping_rejects_duplicate_owned_mac' "$root/tests/kvm_registration_mapping.tftest.hcl"
require 'configured_kvm_mapping_rejects_foreign_provider' "$root/tests/kvm_registration_mapping.tftest.hcl"
require 'kvm {' "$root/onprem_kvm.tf"
reject 'azure {' "$root/onprem_kvm.tf"

test -x "$lifecycle" || fail 'scripts/showcase-lifecycle.sh is missing or not executable'
require 'bootstrap' "$lifecycle"
require 'bootstrap_retirement' "$lifecycle"
require 'configured' "$lifecycle"
require 'getent passwd "$(id -un)"' "$lifecycle"
require '/PASSWORDS.txt' "$lifecycle"
require '(8#$credential_mode & 077) == 0' "$lifecycle"
require 'terraform-with-aws-sso.sh' "$lifecycle"
require 'export AWS_PROFILE' "$lifecycle"
require 'archive "$SOURCE_COMMIT_SHA:terraform"' "$lifecycle"
require 'init -backend=false -input=false -lockfile=readonly' "$lifecycle"
require "-var='enable_aws_tgw_connect=false'" "$lifecycle"
require "enable_aws_tgw_connect[[:space:]]*=[[:space:]]*true" "$lifecycle"
reject 'tf console "${IDENTITY_TF_ARGS[@]}"' "$lifecycle"
require 'var.smsv2_site_generation' "$lifecycle"
! grep -Eq '^[[:space:]]*GENERATION=smsv2([[:space:]]|$)' "$lifecycle" ||
  fail 'new deployment generation must come from the reviewed Terraform input'
require 'LEGACY_GENERATION=smsv2-current' "$lifecycle"
reject '--legacy-generation "$GENERATION"' "$lifecycle"
[ "$(grep -Fc -- '--legacy-generation "$LEGACY_GENERATION"' "$lifecycle")" -eq 2 ] ||
  fail 'both destroy validators must receive the reviewed predecessor generation'
require 'wait_for_approvals bootstrap 3 1' "$lifecycle"
require 'showcase-registration-gate.py' "$lifecycle"
require 'REGISTRATION_APPROVAL_COUNT=$(jq -er' "$lifecycle"
require 'registration-wait-receipt.json' "$lifecycle"
require '.planned_values.outputs.aws_smsv2_bootstrap_registration_projection.value' "$lifecycle"
require 'registration_projection_sha256' "$lifecycle"
reject 'tf output -json aws_smsv2_bootstrap_registration_projection' "$lifecycle"
require '.registration_count == 1 and .online_count == 1' "$lifecycle"
require 'systemctl enable --now' "$lifecycle"
require 'terraform plan' "$lifecycle"
require 'tf apply -input=false -no-color "$PLAN_FILE"' "$lifecycle"
require 'plan -destroy' "$lifecycle"
require "-var='enable_kvm=false'" "$lifecycle"
require 'plan -refresh-only' "$lifecycle"
require 'refresh-only plan did not isolate the expected drift' "$lifecycle"
require 'virsh --connect qemu:///system autostart --disable' "$lifecycle"
require 'managed KVM domain autostart drift was not repaired' "$lifecycle"
require 'kvm-lan-preflight' "$lifecycle"
require 'KVM LAN preflight is read-only' "$lifecycle"
require 'kvm-lan-plan-scope.py' "$lifecycle"
test -x "$repo_root/scripts/kvm-lan-live-acceptance.py" || fail 'KVM LAN live acceptance driver is missing'
require 'shared bridge/uplink resources survive' "$lifecycle"
require 'exercise_managed_drift "$cycle"' "$lifecycle"
# Exercise the exact state lookup used before ENI tag mutation. Terraform's
# human-readable state output aligns `id` with spaces, so only state JSON is
# a reliable identity boundary.
eni_lookup_source=$(mktemp)
trap 'rm -f "$eni_lookup_source"' EXIT
sed -n '/^resolve_owned_eni_id() {/,/^}/p' "$lifecycle" >"$eni_lookup_source"
test -s "$eni_lookup_source" || fail 'managed ENI lookup must use an executable state JSON resolver'
# shellcheck source=/dev/null
source "$eni_lookup_source"
tf() {
  [ "$*" = 'state pull' ] || return 1
  printf '%s\n' "$FAKE_STATE"
}
valid_eni_state='{"resources":[{"mode":"managed","type":"aws_network_interface","name":"slo","instances":[{"index_key":0,"attributes":{"id":"eni-0123456789abcdef0"}}]}]}'
[ "$(FAKE_STATE="$valid_eni_state" resolve_owned_eni_id)" = eni-0123456789abcdef0 ] ||
  fail 'managed ENI lookup did not select the exact indexed state identity'
for invalid_eni_state in \
  '{"resources":[]}' \
  '{"resources":[{"mode":"managed","type":"aws_network_interface","name":"slo","instances":[{"index_key":1,"attributes":{"id":"eni-0123456789abcdef0"}}]}]}' \
  '{"resources":[{"mode":"managed","type":"aws_network_interface","name":"slo","instances":[{"index_key":0,"attributes":{"id":"eni-0123456789abcdef0"}},{"index_key":0,"attributes":{"id":"eni-11111111111111111"}}]}]}' \
  '{"resources":[{"mode":"managed","type":"aws_network_interface","name":"slo","instances":[{"index_key":0,"attributes":{"id":"not-an-eni"}}]}]}'
do
  if FAKE_STATE="$invalid_eni_state" resolve_owned_eni_id >/dev/null 2>&1; then
    fail 'managed ENI lookup accepted a missing, wrong-index, duplicate, or malformed identity'
  fi
done
require 'eni_id=$(resolve_owned_eni_id) || die "managed ENI identity is unavailable"' "$lifecycle"
require 'apply_scoped_plan kvm-configured' "$lifecycle"
require 'apply_scoped_plan aws-status-output-refresh' "$lifecycle"
require 'apply_scoped_plan azure-build' "$lifecycle"
require 'scope_plan zero-change' "$lifecycle"
require 'verify-azure-failover.sh' "$lifecycle"
test -x "$repo_root/scripts/verify-azure-failover.sh" || fail 'Azure failover verifier is not executable'
require 'verify-kvm-lan-client.py' "$lifecycle"
reject 'terraform destroy' "$lifecycle"
reject 'terraform import' "$lifecycle"
reject 'terraform state rm' "$lifecycle"
reject 'preflight_kvm_image' "$lifecycle"
reject "-target='data.xcsh_site_image.kvm'" "$lifecycle"
reject 'maurice_config_cardinality_exactly_one' "$lifecycle"

printf 'PASS: unified AWS, KVM, and Azure lifecycle contract is enforced\n'
python3 -m unittest tests/test_showcase_registration_gate.py
