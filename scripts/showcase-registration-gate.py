#!/usr/bin/env python3
"""Evaluate one refresh-enabled showcase registration plan without exposing identities."""
# pylint: disable=missing-function-docstring
# ruff: noqa: D103, EM101, EM102, TRY003, TRY004

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any


def _map(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _items(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _variable(document: dict[str, Any], name: str) -> Any:
    item = _map(_map(document.get("variables")).get(name))
    if "value" not in item:
        raise ValueError(f"registration plan lacks {name}")
    return item["value"]


def _key(address: object, prefix: str) -> str:
    if not isinstance(address, str):
        raise ValueError("registration plan has a malformed address")
    match = re.fullmatch(rf'{re.escape(prefix)}\["([^"\]]+)"\]', address)
    if match is None:
        raise ValueError("registration plan has an unexpected address")
    return match.group(1)


def validate(
    document: dict[str, Any],
    phase: str,
    expected_aws: int,
    expected_kvm: int,
    source_commit: str,
) -> dict[str, Any]:
    """Accept exact NEW approval actions or already ONLINE registrations."""
    if document.get("terraform_version") != "1.16.3":
        raise ValueError("unexpected Terraform version")
    if _variable(document, "source_commit_sha") != source_commit:
        raise ValueError("registration plan source commit mismatch")
    if _variable(document, "aws_site_configuration_phase") != phase:
        raise ValueError("registration plan phase mismatch")
    if (
        phase not in ("bootstrap", "configured")
        or expected_aws < 1
        or expected_kvm not in (0, 1)
    ):
        raise ValueError("invalid registration gate scope")

    online: dict[str, set[str]] = {"aws": set(), "kvm": set()}
    seen: dict[str, set[str]] = {"aws": set(), "kvm": set()}
    root = _map(
        _map(_map(document.get("prior_state")).get("values")).get("root_module")
    )
    for item in _items(root.get("resources")):
        resource = _map(item)
        kind = resource.get("name")
        if (
            resource.get("mode") != "data"
            or resource.get("type") != "xcsh_site_registration"
            or kind not in online
        ):
            continue
        key = _key(resource.get("address"), f"data.xcsh_site_registration.{kind}")
        if key in seen[kind]:
            raise ValueError("duplicate registration data source")
        seen[kind].add(key)
        values = _map(resource.get("values"))
        if values.get("found") is True and values.get("state") == "ONLINE":
            online[kind].add(key)

    approval: dict[str, set[str]] = {"aws": set(), "kvm": set()}
    active = 0
    for item in _items(document.get("resource_changes")):
        change = _map(item)
        actions = _map(change.get("change")).get("actions")
        if not isinstance(actions, list):
            raise ValueError("registration plan has malformed actions")
        if actions in (["no-op"], ["read"]):
            continue
        active += 1
        kind = change.get("name")
        if (
            change.get("type") != "xcsh_registration_approval"
            or kind not in approval
            or actions != ["create"]
        ):
            continue
        key = _key(change.get("address"), f"xcsh_registration_approval.{kind}")
        if key in approval[kind]:
            raise ValueError("duplicate registration approval")
        approval[kind].add(key)

    for kind in ("aws", "kvm"):
        if online[kind] & approval[kind]:
            raise ValueError("overlapping ONLINE registration and approval")
        if not approval[kind].issubset(seen[kind]):
            raise ValueError("approval lacks a matching registration")

    aws_ready = len(online["aws"] | approval["aws"]) == expected_aws
    kvm_ready = (
        len(online["kvm"] | approval["kvm"]) == expected_kvm
        if expected_kvm
        else not approval["kvm"]
    )
    ready = aws_ready and kvm_ready
    approval_creates = len(approval["aws"]) + len(approval["kvm"])
    if ready and approval_creates == 0 and active:
        raise ValueError("all-online registration plan has unexpected active actions")
    return {
        "ready": ready,
        "skip_approval_phase": ready and approval_creates == 0,
        "aws_online": len(online["aws"]),
        "kvm_online": len(online["kvm"]),
        "approval_creates": approval_creates,
        "active_actions": active,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--phase", choices=("bootstrap", "configured"), required=True)
    parser.add_argument("--expected-aws", type=int, required=True)
    parser.add_argument("--expected-kvm", type=int, required=True)
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    document = json.load(sys.stdin)
    if not isinstance(document, dict):
        raise ValueError("registration plan must be a JSON object")
    receipt = validate(
        document,
        args.phase,
        args.expected_aws,
        args.expected_kvm,
        args.source_commit,
    )
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, json.JSONDecodeError) as error:
        print(f"showcase-registration-gate: {error}", file=sys.stderr)
        sys.exit(2)
