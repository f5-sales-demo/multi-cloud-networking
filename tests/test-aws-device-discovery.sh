#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
aws_xc="$repo_root/terraform/aws_xc.tf"
aws_ce="$repo_root/terraform/aws_ce.tf"
aws_upgrade="$repo_root/terraform/aws_upgrade.tf"
variables="$repo_root/terraform/variables_aws.tf"
mapping_generator="$repo_root/scripts/generate-aws-smsv2-device-mapping.py"

fail() {
  printf "FAIL: %s\\n" "$*" >&2
  exit 1
}
require() { grep -Fq "$1" "$2" || fail "missing $1 in $2"; }
reject() { ! grep -Fq "$1" "$2" || fail "unexpected $1 in $2"; }

require "variable \"aws_site_configuration_phase\"" "$variables"
require "\"bootstrap\", \"bootstrap_retirement\", \"configured\"" "$variables"
require "variable \"aws_smsv2_device_mapping_file\"" "$variables"
require "Private, schema-validated device mapping" "$variables"
require "must contain exactly 01, 02, and 03" "$variables"
reject "variable \"aws_smsv2_devices\"" "$variables"

reject "data \"xcsh_site_registrations_by_site\" \"aws\"" "$aws_xc"
require "aws_device_mapping_document" "$aws_xc"
require "aws_device_mapping_payload" "$aws_xc"
require "aws_mapping_is_complete" "$aws_xc"
require "sha256(jsonencode(local.aws_device_mapping_payload))" "$aws_xc"
require "aws_discovered_device_candidates" "$aws_xc"
require "aws_discovered_devices" "$aws_xc"
require "xcsh_site_registrations_by_site\" \"aws_bootstrap" "$aws_xc"
require "aws_smsv2_bootstrap_registration_projection" "$repo_root/terraform/outputs.tf"
require "aws_smsv2_owned_eni_projection" "$repo_root/terraform/outputs.tf"
require "mac_address" "$aws_xc"
require "aws_network_interface.slo" "$aws_xc"
require "aws_network_interface.sli" "$aws_xc"
require "var.aws_site_configuration_phase == \"configured\"" "$aws_xc"
require "not_managed {" "$aws_xc"
reject "var.aws_smsv2_devices" "$aws_xc"
require "Only configured creates final MAC-bound sites" "$variables"

require "private, checksummed AWS SMSv2 bootstrap device mapping" "$mapping_generator"
require "registration_mapping_not_one_to_one" "$mapping_generator"
require "eni_mapping_not_one_to_one" "$mapping_generator"
require "schema_version\": 1" "$mapping_generator"
require "os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600" "$mapping_generator"

# A configured plan must use the registration's device name only after the
# exact Terraform-owned ENI MAC has one matching hardware record. These source
# assertions protect the zero-mutation failure boundary for absent/ambiguous
# observations without needing cloud credentials in CI.
require "length(local.aws_discovered_device_candidates[each.key].slo) == 1" "$aws_xc"
require "length(local.aws_discovered_device_candidates[each.key].sli) == 1" "$aws_xc"
require "local.aws_discovered_devices[each.key].slo != local.aws_discovered_devices[each.key].sli" "$aws_xc"
require "requires a checksummed bootstrap mapping" "$aws_xc"
require "do not guess guest device names" "$aws_xc"

# The discovery phase is intentionally a site/CE-only graph. It cannot create
# Connect peers before an observed MAC-to-device binding exists.
require "var.aws_site_configuration_phase == \"configured\" || !var.enable_aws_tgw_connect" "$variables"
require "Only configured creates final MAC-bound sites" "$variables"

require "ignore_changes = [user_data]" "$aws_ce"

# Discovery is intentionally pre-registration. Upgrade status is meaningful
# only in the configured phase after the runtime gate can succeed.
require 'var.aws_site_configuration_phase == "configured" && contains(var.aws_upgrade_observed_sites, key)' "$aws_upgrade"
reject 'for key, site in local.aws_sites : key => site if contains(var.aws_upgrade_observed_sites, key)' "$aws_upgrade"

printf "PASS: AWS SMSv2 device discovery is staged, exact-MAC-bound, fail-closed, and replacement-safe\\n"
