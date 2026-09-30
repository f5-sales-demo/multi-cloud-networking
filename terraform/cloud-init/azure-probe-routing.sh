#!/usr/bin/env bash
# Azure probes enter a secondary NIC and return through management SLO.
# Use loose source validation only on CE-owned secondary host interfaces.
set -euo pipefail
for setting in /proc/sys/net/ipv4/conf/vhost-int-*/rp_filter; do
  [ -f "$setting" ] || continue
  [ "$(cat "$setting")" = 2 ] || printf '2\n' >"$setting"
done
