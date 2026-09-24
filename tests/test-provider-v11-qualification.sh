#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)

for file in terraform/versions.tf terraform/recovery/aws-smsv2-orphans/versions.tf \
  terraform/modules/xc-site/versions.tf terraform/modules/kvm/providers.tf coverage/smsv2/versions.tf; do
  block=$(sed -n '/^[[:space:]]*xcsh = {/,/^[[:space:]]*}/p' "$root/$file")
  grep -Eq 'version[[:space:]]*=[[:space:]]*"= 11\.0\.1"' <<<"$block" || {
    echo "provider v11 pin missing: $file" >&2
    exit 1
  }
done

grep -Fq 'operating_system_version = var.aws_os_version' "$root/terraform/aws_xc.tf"
grep -Fq 'volterra_software_version = var.aws_software_version' "$root/terraform/aws_xc.tf"
grep -Fq 'software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)' "$root/terraform/aws_upgrade.tf"
grep -Fq 'os_version = coalesce(var.aws_upgrade_os_version, var.aws_os_version)' "$root/terraform/aws_upgrade.tf"
grep -Fq 'expected_software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)' "$root/terraform/aws_upgrade.tf"
grep -Fq 'expected_os_version       = coalesce(var.aws_upgrade_os_version, var.aws_os_version)' "$root/terraform/aws_upgrade.tf"
if grep -Eq '^[[:space:]]*(namespace|force)[[:space:]]*=' "$root/terraform/aws_upgrade.tf"; then
  echo 'provider-internal action inputs are not part of the MCN contract' >&2
  exit 1
fi

echo 'PASS: provider v11 pin and independent AWS upgrade targets'
