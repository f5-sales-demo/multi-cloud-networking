#!/usr/bin/env python3
"""Join one disposable AWS CE's registration to its Terraform-owned ENIs."""

import argparse
import hashlib
import json
from pathlib import Path
from typing import Any

ROLES = ("slo", "sli")


def mapping(facts: dict[str, Any], registrations: list) -> dict[str, Any]:
    """Reject foreign, ambiguous or incomplete bootstrap hardware evidence."""
    expected_site = facts["task_id"] + "-bootstrap"
    candidates = [
        item
        for item in registrations
        if item.get("get_spec", {}).get("passport", {}).get("cluster_name")
        == expected_site
        and item.get("get_spec", {}).get("infra", {}).get("hostname") == expected_site
        and item.get("object", {}).get("status", {}).get("current_state")
        not in {
            "RETIRED",
            "FAILED",
            "FAILED_INACTIVE",
            "DONE",
        }
    ]
    if (
        facts["phase"] != "bootstrap"
        or facts["site_name"] != expected_site
        or len(candidates) != 1
    ):
        message = "exactly one task-owned bootstrap registration is required"
        raise ValueError(message)
    hardware = candidates[0]["get_spec"]["infra"]["hw_info"]["network"]
    entries = []
    for role in ROLES:
        mac = facts[role + "_mac"].lower().replace("-", ":")
        matches = [
            nic
            for nic in hardware
            if nic.get("mac_address", "").lower().replace("-", ":") == mac
        ]
        if len(matches) != 1 or not matches[0].get("name"):
            message = "each owned ENI requires exactly one observed device"
            raise ValueError(message)
        entries.append({"role": role, "mac": mac, "device": matches[0]["name"]})
    if len({entry["device"] for entry in entries}) != len(ROLES) or len(
        {entry["mac"] for entry in entries}
    ) != len(ROLES):
        message = "SLO and SLI must have distinct devices and MACs"
        raise ValueError(message)
    payload = {
        "schema_version": 1,
        "task_id": facts["task_id"],
        "bootstrap_site": expected_site,
        "entries": entries,
    }
    checksum = hashlib.sha256(
        json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    return {**payload, "checksum": checksum}


def main() -> None:
    """Read private Terraform outputs and write a private checksummed mapping."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--hardware", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = mapping(
        json.loads(args.fixture.read_text()), json.loads(args.hardware.read_text())
    )
    args.output.touch(mode=0o600, exist_ok=True)
    args.output.chmod(0o600)
    args.output.write_text(json.dumps(result, sort_keys=True, indent=2) + "\n")


if __name__ == "__main__":
    main()
