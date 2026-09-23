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
require 'var.smsv2_site_generation' "$lifecycle"
reject 'GENERATION=smsv2' "$lifecycle"
require 'wait_for_approvals bootstrap 3 1' "$lifecycle"
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
require 'shared bridge/uplink resources survive' "$lifecycle"
require 'exercise_managed_drift first' "$lifecycle"
require 'exercise_managed_drift second' "$lifecycle"
reject 'terraform destroy' "$lifecycle"
reject 'terraform import' "$lifecycle"
reject 'terraform state rm' "$lifecycle"
reject 'preflight_kvm_image' "$lifecycle"
reject "-target='data.xcsh_site_image.kvm'" "$lifecycle"
reject 'maurice_config_cardinality_exactly_one' "$lifecycle"

printf 'PASS: unified AWS and KVM lifecycle contract is enforced\n'
