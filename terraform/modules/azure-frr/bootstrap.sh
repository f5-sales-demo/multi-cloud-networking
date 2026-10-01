#!/usr/bin/env bash
# Retry transient Azure mirror failures before enabling the regional router.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
installed=false
for attempt in $(seq 1 20); do
  if apt-get update -o Acquire::Retries=3 -o Acquire::http::Timeout=20 &&
    apt-get install -y -o Acquire::Retries=3 -o Acquire::http::Timeout=20 frr; then
    installed=true
    break
  fi
  sleep 15
done
[ "$installed" = true ] || {
  echo 'FRR package installation exceeded bounded retry window' >&2
  exit 1
}
install -m 640 /var/lib/mcn/frr.conf /etc/frr/frr.conf
chown frr:frr /etc/frr/frr.conf
sed -i 's/^bgpd=no/bgpd=yes/' /etc/frr/daemons
sysctl -w net.ipv4.ip_forward=1 net.ipv4.conf.all.rp_filter=2
systemctl enable --now frr
systemctl restart frr
systemctl enable --now mcn-vip-translation.timer
