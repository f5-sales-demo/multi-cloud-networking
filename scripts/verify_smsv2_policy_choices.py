#!/usr/bin/env python3
"""Require exact provider-schema rejection diagnostics from credential-free probes."""

import json
import shutil
import subprocess
from pathlib import Path


def main() -> None:
    """Check firewall and proxy contradictory selections without suppressing unexpected failures."""
    fixture = Path(__file__).resolve().parents[1] / "coverage/smsv2-runtime/contracts"
    terraform = shutil.which("terraform")
    if terraform is None:
        message = "Terraform is required"
        raise SystemExit(message)
    probes = {
        "root": (
            "xcsh_enhanced_firewall_policy.root_conflict[0]",
            "allow_all and rule_list are mutually exclusive.",
        ),
        "nested": (
            "xcsh_enhanced_firewall_policy.action_conflict[0]",
            '"allow" and "deny" are mutually exclusive.',
        ),
        "proxy-root": (
            "xcsh_forward_proxy_policy.proxy_root_conflict[0]",
            "any_proxy and drp_http_connect are mutually exclusive.",
        ),
        "proxy-path": (
            "xcsh_forward_proxy_policy.proxy_path_conflict[0]",
            '"any_path" and "path_prefix_value" are mutually exclusive.',
        ),
    }
    for label, (address, detail) in probes.items():
        result = subprocess.run(  # noqa: S603 - resolved Terraform and fixed argv only
            [terraform, "test", "-json", f"-filter=choices-{label}.tftest.hcl"],
            cwd=fixture,
            capture_output=True,
            check=False,
            timeout=120,
        )
        records = [json.loads(line) for line in result.stdout.splitlines() if line]
        errors = [
            record["diagnostic"]
            for record in records
            if record.get("type") == "diagnostic"
            and record["diagnostic"].get("severity") == "error"
        ]
        expected = {
            "severity": "error",
            "summary": "Conflicting Configuration",
            "detail": detail,
            "address": address,
        }
        actual = [{key: error.get(key) for key in expected} for error in errors]
        if result.returncode != 1 or actual != [expected]:
            message = f"Unexpected provider rejection result for {label}"
            raise SystemExit(message)
        print(f"PASS: {label} contradictory selection rejected exactly")


if __name__ == "__main__":
    main()
