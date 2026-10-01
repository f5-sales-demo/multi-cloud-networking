#!/usr/bin/env bash
# Azure probes enter a secondary NIC and return through management SLO.
# Use loose source validation only on CE-owned secondary host interfaces.
set -euo pipefail
for setting in /proc/sys/net/ipv4/conf/vhost-int-*/rp_filter; do
  [ -f "$setting" ] || continue
  [ "$(cat "$setting")" = 2 ] || printf '2\n' >"$setting"
done

# Azure requires probe replies to leave through the NIC that received them.
# Scope policy routing to the configured inside subnet and probe endpoint only.
inside_subnet=${1:?inside subnet required}
inside_prefix=${inside_subnet%/*}
inside_gateway=${inside_prefix%.*}.1
for device in /sys/class/net/vhost-int-*; do
  [ -d "$device" ] || continue
  interface=${device##*/}
  source=$(ip -4 -o addr show dev "$interface" | awk '{print $4}' | cut -d/ -f1)
  [ -n "$source" ] || continue
  python3 -c 'import ipaddress,sys; sys.exit(0 if ipaddress.ip_address(sys.argv[1]) in ipaddress.ip_network(sys.argv[2]) else 1)' "$source" "$inside_subnet" || continue
  ip route replace table 103 168.63.129.16/32 via "$inside_gateway" dev "$interface" src "$source"
  if ! ip rule show | grep -q "from $source to 168.63.129.16 lookup 103"; then
    ip rule add priority 103 from "$source/32" to 168.63.129.16/32 lookup 103
  fi
done
