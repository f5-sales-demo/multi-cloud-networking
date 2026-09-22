#!/usr/bin/env python3
# pylint: disable=invalid-name
"""Create the private, checksummed AWS SMSv2 bootstrap device mapping.

Inputs are intentionally files outside the repository: a sanitized bootstrap
registration projection and Terraform-owned ENI facts.  This tool prints no
MAC addresses or device names and writes the final mapping mode 0600.
"""

import argparse
import hashlib
import json
import os
import re
import sys
from pathlib import Path
from typing import Any, Never

MAC = re.compile(r"^[0-9a-f]{2}(?::[0-9a-f]{2}){5}$")
EXPECTED_INTERFACE_COUNT = 6
SITE_KEYS = ("01", "02", "03")
OwnedEnis = dict[tuple[str, str], str]


def load(path: Path) -> Any:
    """Load a private JSON document."""
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def fail(reason: str) -> Never:
    """Exit with a deterministic, non-sensitive validation reason."""
    print(f"error: {reason}", file=sys.stderr)
    raise SystemExit(2)


def canonical(value: Any) -> bytes:
    """Encode a value for stable checksum calculation."""
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def owned_enis(enis: Any) -> OwnedEnis:
    """Validate and index the Terraform-owned ENIs by site and role."""
    if not isinstance(enis, list):
        fail("eni_input_must_be_list")
    owned: OwnedEnis = {}
    for item in enis:
        if not isinstance(item, dict):
            fail("eni_mapping_invalid")
        site_key = item.get("site_key")
        role = item.get("role")
        mac = str(item.get("mac", "")).lower()
        if (
            not isinstance(site_key, str)
            or not isinstance(role, str)
            or site_key not in SITE_KEYS
            or role not in {"slo", "sli"}
            or not MAC.fullmatch(mac)
        ):
            fail("eni_mapping_invalid")
        key = (site_key, role)
        if key in owned:
            fail("eni_mapping_invalid")
        owned[key] = mac
    if (
        len(owned) != EXPECTED_INTERFACE_COUNT
        or len(set(owned.values())) != EXPECTED_INTERFACE_COUNT
    ):
        fail("eni_mapping_not_one_to_one")
    return owned


def validate_document(document: Any, owned: OwnedEnis) -> None:
    """Validate a checksummed mapping against owned ENI identities."""
    if not isinstance(document, dict) or document.get("schema_version") != 1:
        fail("mapping_schema_invalid")
    entries = document.get("entries")
    if not isinstance(entries, list):
        fail("mapping_entries_invalid")
    payload = {"schema_version": document["schema_version"], "entries": entries}
    if document.get("checksum") != hashlib.sha256(canonical(payload)).hexdigest():
        fail("mapping_checksum_mismatch")
    observed = {}
    for item in entries:
        if not isinstance(item, dict):
            fail("mapping_entry_invalid")
        key = (item.get("site_key"), item.get("role"))
        mac, device = (
            str(item.get("mac", "")).lower(),
            str(item.get("device", "")).strip(),
        )
        if (
            key not in owned
            or mac != owned[key]
            or not MAC.fullmatch(mac)
            or not device
            or key in observed
        ):
            fail("mapping_entry_invalid")
        observed[key] = device
    if set(observed) != set(owned) or any(
        observed[(site, "slo")] == observed[(site, "sli")] for site in SITE_KEYS
    ):
        fail("mapping_not_one_to_one")


def main() -> None:
    """Generate or verify a private AWS SMSv2 device mapping."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--registration-file")
    parser.add_argument("--eni-file", required=True)
    parser.add_argument("--output")
    parser.add_argument("--verify-file")
    args = parser.parse_args()
    if bool(args.verify_file) == bool(args.registration_file):
        fail("choose_generate_or_verify")
    if args.verify_file and args.output:
        fail("verify_does_not_write_output")
    if args.registration_file and not args.output:
        fail("output_required")
    owned = owned_enis(load(Path(args.eni_file)))
    if args.verify_file:
        validate_document(load(Path(args.verify_file)), owned)
        return
    registrations = load(Path(args.registration_file))
    if not isinstance(registrations, list):
        fail("registration_input_must_be_list")
    observed = {}
    for item in registrations:
        if not isinstance(item, dict):
            fail("registration_mapping_invalid")
        site_key = item.get("site_key")
        mac, device = (
            str(item.get("mac", "")).lower(),
            str(item.get("device", "")).strip(),
        )
        if (
            not isinstance(site_key, str)
            or site_key not in SITE_KEYS
            or not MAC.fullmatch(mac)
            or not device
        ):
            fail("registration_mapping_invalid")
        matching_keys = [
            key
            for key, owned_mac in owned.items()
            if key[0] == site_key and owned_mac == mac
        ]
        # SMSv2 registrations report guest-runtime interfaces in addition to
        # the EC2 ENIs. Only an exact same-site owned-MAC match may enter the
        # configured mapping; valid unmatched runtime interfaces are inert.
        if not matching_keys:
            continue
        if len(matching_keys) != 1:
            fail("registration_mapping_invalid")
        key = matching_keys[0]
        if key in observed:
            fail("registration_mapping_invalid")
        observed[key] = {
            "site_key": key[0],
            "role": key[1],
            "mac": mac,
            "device": device,
        }
    if set(observed) != set(owned) or any(
        observed[(site, "slo")]["device"] == observed[(site, "sli")]["device"]
        for site in SITE_KEYS
    ):
        fail("registration_mapping_not_one_to_one")
    payload = {
        "schema_version": 1,
        "entries": [observed[key] for key in sorted(observed)],
    }
    document = dict(payload, checksum=hashlib.sha256(canonical(payload)).hexdigest())
    fd = os.open(Path(args.output), os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(document, handle, sort_keys=True, separators=(",", ":"))
        handle.write("\n")


if __name__ == "__main__":
    main()
