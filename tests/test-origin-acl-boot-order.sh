#!/usr/bin/env bash
# The VM must not boot its HTTP origin before the NIC ACL is installed.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
graph=$(terraform -chdir="$repo/terraform/modules/client-vm" graph)
if ! grep -Fq '"azurerm_linux_virtual_machine.this" -> "azurerm_network_interface_security_group_association.this"' <<<"$graph"; then
  printf 'FAIL: VM can boot before its NIC security-group association\n' >&2
  exit 1
fi
printf 'PASS: VM boot waits for its NIC security-group association\n'
