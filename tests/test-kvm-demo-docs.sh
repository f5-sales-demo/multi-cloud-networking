#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
pages="$root/docs/en/demo"

if rg -n 'maurice_config|External tenant prerequisite unavailable|v9\.2\.2|10\.100\.0\.10([^0-9]|$)|3 KVM CEs|three KVM Customer Edge|all three On-Prem CEs|showing multiple \*=? multipath|KVM.*maximum-paths 4' "$pages"; then
  echo 'obsolete KVM demo contract or topology' >&2
  exit 1
fi

for value in 10.100.0.11 10.100.0.2 10.100.0.1 10.100.0.100 198.51.100.0/24; do
  rg -Fq "$value" "$pages" || {
    echo "missing KVM topology address: $value" >&2
    exit 1
  }
done
