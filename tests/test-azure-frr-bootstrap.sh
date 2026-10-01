#!/usr/bin/env bash
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/etc/frr" "$work/var/lib/mcn"
printf 'bgpd=no\n' >"$work/etc/frr/daemons"
printf 'router bgp 65020\n' >"$work/var/lib/mcn/frr.conf"
cat >"$work/bin/apt-get" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MCN_LOG"
if [ "$1" = install ]; then
  if [ ! -f "$MCN_APT_RETRIED" ]; then touch "$MCN_APT_RETRIED"; exit 100; fi
fi
MOCK
for tool in sleep chown systemctl sysctl; do
  cat >"$work/bin/$tool" <<'MOCK'
#!/usr/bin/env bash
printf '%s %s\n' "${0##*/}" "$*" >>"$MCN_LOG"
MOCK
  chmod +x "$work/bin/$tool"
done
chmod +x "$work/bin/apt-get"
export MCN_LOG="$work/log" MCN_APT_RETRIED="$work/retried"
export PATH="$work/bin:$PATH"
sed -e "s@/etc/frr@$work/etc/frr@g" -e "s@/var/lib/mcn@$work/var/lib/mcn@g" "$repo/terraform/modules/azure-frr/bootstrap.sh" >"$work/run.sh"
bash "$work/run.sh"
[ "$(grep -c '^install ' "$MCN_LOG")" -eq 2 ]
grep -q 'bgpd=yes' "$work/etc/frr/daemons"
cmp "$work/etc/frr/frr.conf" "$work/var/lib/mcn/frr.conf"
grep -q 'chown frr:frr' "$MCN_LOG"
grep -q 'systemctl enable --now frr' "$MCN_LOG"
grep -q 'systemctl enable --now mcn-vip-translation.timer' "$MCN_LOG"
echo 'PASS: transient package failure retried before FRR configuration and startup'
