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
mkdir -p "$work/sys/class/net/vhost-int-1" "$work/sys/class/net/vhost-int-2" "$work/bin"
cat >"$work/bin/ip" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$MCN_IP_LOG"
case "$*" in
  '-4 -o addr show dev vhost-int-1') echo '1: vhost-int-1 inet 10.0.3.4/26 scope global vhost-int-1' ;;
  '-4 -o addr show dev vhost-int-2') echo '2: vhost-int-2 inet 10.0.2.4/26 scope global vhost-int-2' ;;
  'route show default dev vhost-int-1') echo 'default via 10.0.3.1 dev vhost-int-1 proto 100 metric 3000' ;;
  'route show default dev vhost-int-2') echo 'default via 10.0.2.1 dev vhost-int-2 proto 100 metric 3000' ;;
  'rule show') [ ! -f "$MCN_RULE_STATE" ] || cat "$MCN_RULE_STATE" ;;
  'rule add priority 103 from 10.0.3.4/32 to 168.63.129.16/32 lookup 103')
    echo '103: from 10.0.3.4 to 168.63.129.16 lookup 103' >"$MCN_RULE_STATE" ;;
esac
MOCK
chmod +x "$work/bin/ip"
export MCN_IP_LOG="$work/ip.log" MCN_RULE_STATE="$work/rule"
export PATH="$work/bin:$PATH"
sed -e "s@/proc/sys@$work@g" -e "s@/sys/class/net@$work/sys/class/net@g" "$repo/terraform/cloud-init/azure-probe-routing.sh" >"$work/run.sh"
bash "$work/run.sh" 10.0.3.0/26
bash "$work/run.sh" 10.0.3.0/26
[ "$(cat "$work/net/ipv4/conf/vhost0/rp_filter")" = 1 ]
[ "$(cat "$work/net/ipv4/conf/vhost-int-1/rp_filter")" = 2 ]
[ "$(cat "$work/net/ipv4/conf/vhost-int-2/rp_filter")" = 2 ]
grep -qF 'route replace table 103 168.63.129.16/32 via 10.0.3.1 dev vhost-int-1 src 10.0.3.4' "$MCN_IP_LOG"
[ "$(grep -c '^rule add ' "$MCN_IP_LOG")" -eq 1 ]
if grep -q 'route replace.*vhost-int-2' "$MCN_IP_LOG"; then exit 1; fi
if grep -q '^route replace.*default' "$MCN_IP_LOG"; then exit 1; fi
echo 'PASS: Azure probes preserve management and use the exact inside return interface'
