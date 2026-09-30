#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
for region in azure ca; do
  sed -n "/resource \"azurerm_lb_rule\" \"${region}_application\" {/,/^}/p" "$repo/terraform/${region}_ilb.tf" | grep -Eq "probe_id[[:space:]]*=[[:space:]]*azurerm_lb_probe.${region}_site_console" || {
    echo "FAIL: floating application must probe a backend listener" >&2
    exit 1
  }
done
grep -q 'mcn-azure-probes.timer' "$repo/terraform/cloud-init/ce-node.yaml"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
for device in vhost0 vhost-int-1 vhost-int-2; do
  mkdir -p "$work/net/ipv4/conf/$device"
  printf '1\n' >"$work/net/ipv4/conf/$device/rp_filter"
done
sed "s@/proc/sys@$work@g" "$repo/terraform/cloud-init/azure-probe-routing.sh" >"$work/run.sh"
bash "$work/run.sh"
bash "$work/run.sh"
[ "$(cat "$work/net/ipv4/conf/vhost0/rp_filter")" = 1 ]
[ "$(cat "$work/net/ipv4/conf/vhost-int-1/rp_filter")" = 2 ]
[ "$(cat "$work/net/ipv4/conf/vhost-int-2/rp_filter")" = 2 ]
echo 'PASS: Azure probes preserve management and converge secondary filtering'
