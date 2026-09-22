#!/usr/bin/env bash
# Exercise the private AWS SMSv2 device-mapping boundary without emitting any
# observed device or MAC identity to the test transcript.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
GENERATOR="$REPO_ROOT/scripts/generate-aws-smsv2-device-mapping.py"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mcn-aws-mapping-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

ENIS="$SCRATCH/enis.json"
REGISTRATIONS="$SCRATCH/registrations.json"
MAPPING="$SCRATCH/mapping.json"

python3 - "$ENIS" "$REGISTRATIONS" <<'PY'
import json
import sys

enis = []
registrations = []
for site in ("01", "02", "03"):
    for role, suffix in (("slo", 0), ("sli", 1)):
        mac = f"02:00:00:00:{int(site):02x}:{suffix:02x}"
        enis.append({"site_key": site, "role": role, "mac": mac})
        registrations.append({"site_key": site, "mac": mac, "device": f"observed-{site}-{role}"})
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(enis, handle)
with open(sys.argv[2], "w", encoding="utf-8") as handle:
    json.dump(registrations, handle)
PY

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

reject() {
  local reason=$1
  shift
  if "$@" >"$SCRATCH/reject.out" 2>&1; then
    fail "expected ${reason} to fail"
  fi
  grep -Fq "error: ${reason}" "$SCRATCH/reject.out" || fail "expected ${reason}"
}

"$GENERATOR" --registration-file "$REGISTRATIONS" --eni-file "$ENIS" --output "$MAPPING"
[ "$(stat -c '%a' "$MAPPING")" = 600 ] || fail "mapping is not private"
"$GENERATOR" --verify-file "$MAPPING" --eni-file "$ENIS"
echo "ok - valid private mapping generates and verifies"

python3 - "$REGISTRATIONS" "$SCRATCH/runtime-interfaces.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
for site in ("01", "02", "03"):
    values.extend(
        [
            {"site_key": site, "mac": f"02:aa:00:00:{int(site):02x}:00", "device": f"runtime-{site}-0"},
            {"site_key": site, "mac": f"02:aa:00:00:{int(site):02x}:01", "device": f"runtime-{site}-1"},
        ]
    )
json.dump(values, open(sys.argv[2], "w", encoding="utf-8"))
PY
"$GENERATOR" --registration-file "$SCRATCH/runtime-interfaces.json" --eni-file "$ENIS" --output "$SCRATCH/runtime-output.json"
"$GENERATOR" --verify-file "$SCRATCH/runtime-output.json" --eni-file "$ENIS"
[ "$(jq '.entries | length' "$SCRATCH/runtime-output.json")" = 6 ] || fail "runtime interfaces leaked into mapping"
echo "ok - unmatched guest runtime interfaces are excluded from the owned ENI join"

python3 - "$REGISTRATIONS" "$SCRATCH/missing.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
json.dump(values[:-1], open(sys.argv[2], "w", encoding="utf-8"))
PY
reject registration_mapping_not_one_to_one "$GENERATOR" --registration-file "$SCRATCH/missing.json" --eni-file "$ENIS" --output "$SCRATCH/missing-output.json"

python3 - "$REGISTRATIONS" "$SCRATCH/duplicate.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
values.append(values[0])
json.dump(values, open(sys.argv[2], "w", encoding="utf-8"))
PY
reject registration_mapping_invalid "$GENERATOR" --registration-file "$SCRATCH/duplicate.json" --eni-file "$ENIS" --output "$SCRATCH/duplicate-output.json"

python3 - "$REGISTRATIONS" "$SCRATCH/foreign.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
values[0]["mac"] = "02:ff:ff:ff:ff:ff"
json.dump(values, open(sys.argv[2], "w", encoding="utf-8"))
PY
reject registration_mapping_not_one_to_one "$GENERATOR" --registration-file "$SCRATCH/foreign.json" --eni-file "$ENIS" --output "$SCRATCH/foreign-output.json"

python3 - "$ENIS" "$SCRATCH/malformed-eni.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
values[0]["mac"] = "not-a-mac"
json.dump(values, open(sys.argv[2], "w", encoding="utf-8"))
PY
reject eni_mapping_invalid "$GENERATOR" --registration-file "$REGISTRATIONS" --eni-file "$SCRATCH/malformed-eni.json" --output "$SCRATCH/malformed-output.json"

python3 - "$REGISTRATIONS" "$SCRATCH/same-device.json" <<'PY'
import json
import sys
values = json.load(open(sys.argv[1], encoding="utf-8"))
values[1]["device"] = values[0]["device"]
json.dump(values, open(sys.argv[2], "w", encoding="utf-8"))
PY
reject registration_mapping_not_one_to_one "$GENERATOR" --registration-file "$SCRATCH/same-device.json" --eni-file "$ENIS" --output "$SCRATCH/same-device-output.json"

python3 - "$MAPPING" <<'PY'
import json
import sys
path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["checksum"] = "0" * 64
json.dump(value, open(path, "w", encoding="utf-8"))
PY
reject mapping_checksum_mismatch "$GENERATOR" --verify-file "$MAPPING" --eni-file "$ENIS"
echo "PASS: AWS SMSv2 mapping rejects missing, duplicate, foreign, malformed, ambiguous, and tampered input"
