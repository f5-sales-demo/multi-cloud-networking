#!/usr/bin/env python3
"""Verify a saved legacy destroy plan from Terraform's JSON event stream."""
# pylint: disable=invalid-name,too-many-locals,too-many-branches,duplicate-code
# ruff: noqa: TRY003, EM101, EM102, S603, S607

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import Any

PROVIDER_SHA256 = "5dab6b26cbc2656bd7df2a8259564f238b1947d5cfdf9e9370243300c954d85d"
PRODUCTION_KEY = "mcn-ce-ha-smsv2/showcase.tfstate"
LEGACY_KVM_BGP = "xcsh_bgp.onprem_ebgp[0]"


def legacy_kvm_bgp_owned(
    address: str, before: dict[str, Any], legacy: dict[str, str]
) -> bool:
    """Recognize only the reviewed predecessor KVM BGP object."""
    if address != LEGACY_KVM_BGP:
        return False
    labels = before.get("labels") or {}
    refs = ((before.get("where") or {}).get("site") or {}).get("ref")
    site_name = "mcn-ce-ha-smsv2-current-kvm"
    return all(
        (
            before.get("name") == "onprem-kvm-ebgp",
            before.get("namespace") == "system",
            labels.get("mcn-owner-id") == "kvm-poc",
            labels.get("mcn-environment") == "production",
            labels.get("mcn-deployment-generation")
            == legacy.get("generation")
            == "smsv2-current",
            labels.get("mcn-xc-tenant") == legacy.get("tenant") == "f5-sales-demo",
            labels.get("mcn-topology") == site_name,
            isinstance(refs, list)
            and len(refs) == 1
            and isinstance(refs[0], dict)
            and refs[0].get("name") == site_name
            and refs[0].get("namespace") == "system"
            and refs[0].get("kind", "site.Object") == "site.Object",
        )
    )


def digest(path: pathlib.Path) -> str:
    """Hash an immutable private input."""
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def state_address(resource: dict[str, Any], instance: dict[str, Any]) -> str:
    """Reconstruct Terraform's canonical address for one managed instance."""
    prefix = f"{resource['module']}." if resource.get("module") else ""
    address = f"{prefix}{resource['type']}.{resource['name']}"
    if "index_key" in instance:
        address += f"[{json.dumps(instance['index_key'], separators=(',', ':'))}]"
    return address


def verify_owner(
    resource: dict[str, Any],
    instance: dict[str, Any],
    legacy: dict[str, str],
    owner: str,
    environment: str,
) -> None:
    """Verify old and new ownership markers on destructive core resources."""
    resource_type = resource["type"]
    address = state_address(resource, instance)
    if address == LEGACY_KVM_BGP and resource_type == "xcsh_bgp":
        if not legacy_kvm_bgp_owned(address, instance.get("attributes") or {}, legacy):
            raise ValueError(f"ownership marker mismatch: {address}")
        return
    if resource_type not in {
        "aws_vpc",
        "aws_instance",
        "azurerm_resource_group",
        "xcsh_securemesh_site_v2",
    }:
        return
    before = instance.get("attributes") or {}
    tags = before.get("tags") or {}
    labels = before.get("labels") or {}
    modern = (
        tags if "mcn_owner_id" in tags else labels if "mcn-owner-id" in labels else None
    )
    if modern is not None:
        if (
            modern.get("mcn_owner_id", modern.get("mcn-owner-id")) != owner
            or modern.get("mcn_environment", modern.get("mcn-environment"))
            != environment
        ):
            raise ValueError(f"ownership marker mismatch: {address}")
        return
    if resource_type in {"aws_vpc", "aws_instance"}:
        valid = all(
            (
                tags.get("component") == "mcn-ce-ha",
                tags.get("environment") == legacy["environment"],
                tags.get("deployer") == legacy["deployer"],
                tags.get("managed_by") == "terraform",
            )
        )
    elif resource_type == "xcsh_securemesh_site_v2":
        valid = all(
            (
                before.get("namespace") == "system",
                labels.get("mcn-deployment-generation") == legacy["generation"],
                labels.get("mcn-xc-tenant") == legacy["tenant"],
                str(labels.get("mcn-topology", "")).endswith("-aws"),
            )
        )
    else:
        valid = False
    if not valid:
        raise ValueError(f"legacy ownership marker mismatch: {address}")


def verify(
    state: dict[str, Any],
    event_lines: list[str],
    legacy: dict[str, str],
    owner: str,
    environment: str,
) -> int:
    """Require one delete event per owned managed instance and no other actions."""
    stale = [
        item
        for item in state.get("resources", [])
        if item.get("mode") == "data" and item.get("type") == "xcsh_site_upgrade_status"
        for instance in item.get("instances", [])
        if "namespace" in (instance.get("attributes") or {})
    ]
    if not stale:
        raise ValueError(
            "legacy event fallback requires the exact stale upgrade-status schema"
        )
    state_addresses: set[str] = set()
    for resource in state.get("resources", []):
        if resource.get("mode") != "managed":
            continue
        for instance in resource.get("instances", []):
            if instance.get("deposed"):
                raise ValueError("deposed state instance requires separate review")
            address = state_address(resource, instance)
            if address in state_addresses:
                raise ValueError(f"duplicate state address: {address}")
            state_addresses.add(address)
            verify_owner(resource, instance, legacy, owner, environment)
    if not state_addresses:
        raise ValueError("legacy state has no managed instances to destroy")
    event_addresses: set[str] = set()
    summary: dict[str, Any] | None = None
    for line in event_lines:
        event = json.loads(line)
        if event.get("type") in {"planned_action_invocation", "action_invocation"}:
            raise ValueError("destroy stream contains a provider action invocation")
        if (
            event.get("type") == "diagnostic"
            and event.get("diagnostic", {}).get("severity") == "error"
        ):
            raise ValueError("destroy planning emitted an error diagnostic")
        if event.get("type") == "planned_change":
            change = event.get("change") or {}
            event_address = (change.get("resource") or {}).get("addr")
            if not isinstance(event_address, str) or change.get("action") != "delete":
                raise ValueError(
                    "destroy event contains a non-delete or malformed action"
                )
            if any(
                part in event_address
                for part in ("host_bridge", "shared_bridge", "uplink")
            ):
                raise ValueError(
                    f"destroy includes shared host networking: {event_address}"
                )
            if event_address in event_addresses:
                raise ValueError(f"duplicate destroy event: {event_address}")
            event_addresses.add(event_address)
        elif event.get("type") == "change_summary":
            if summary is not None:
                raise ValueError("destroy stream contains multiple change summaries")
            summary = event.get("changes")
    if state_addresses != event_addresses:
        missing = sorted(state_addresses - event_addresses)
        extra = sorted(event_addresses - state_addresses)
        raise ValueError(
            f"destroy event/state scope mismatch: missing={missing[:1]} extra={extra[:1]}"
        )
    if (
        not isinstance(summary, dict)
        or summary.get("remove") != len(event_addresses)
        or any(summary.get(name, 0) != 0 for name in ("add", "change", "import"))
    ):
        raise ValueError("destroy summary does not match the complete delete set")
    return len(event_addresses)


def main() -> int:
    """Validate private inputs and print one sanitized receipt."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-dir", type=pathlib.Path, required=True)
    parser.add_argument("--state", type=pathlib.Path, required=True)
    parser.add_argument("--events", type=pathlib.Path, required=True)
    parser.add_argument("--plan", type=pathlib.Path, required=True)
    parser.add_argument("--provider-zip", type=pathlib.Path, required=True)
    parser.add_argument("--backend-config", type=pathlib.Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--backend-key", required=True)
    parser.add_argument("--environment-key", required=True)
    parser.add_argument("--owner-id", required=True)
    parser.add_argument("--legacy-deployer", required=True)
    parser.add_argument("--legacy-environment", required=True)
    parser.add_argument("--legacy-generation", required=True)
    parser.add_argument("--legacy-tenant", required=True)
    args = parser.parse_args()
    if args.backend_key != PRODUCTION_KEY:
        raise ValueError("legacy destroy requires the production backend key")
    if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit):
        raise ValueError("source commit is invalid")
    head = subprocess.check_output(
        ["git", "-C", str(args.terraform_dir), "rev-parse", "HEAD"], text=True
    ).strip()
    # The lifecycle also checks the named main branch and origin/main before this
    # isolated scope check; the receipt binds the actual checked-out commit.
    if head != args.source_commit:
        raise ValueError("source commit differs from the checked-out repository")
    backend_match = re.search(
        r'^\s*key\s*=\s*"([^"]+)"\s*$', args.backend_config.read_text(), re.MULTILINE
    )
    if backend_match is None or backend_match.group(1) != args.backend_key:
        raise ValueError("backend key does not match the reviewed destroy scope")
    if digest(args.provider_zip) != PROVIDER_SHA256:
        raise ValueError("xcsh provider artifact digest mismatch")
    state = json.loads(args.state.read_text())
    event_lines = args.events.read_text().splitlines()
    legacy = {
        "deployer": args.legacy_deployer,
        "environment": args.legacy_environment,
        "generation": args.legacy_generation,
        "tenant": args.legacy_tenant,
    }
    count = verify(state, event_lines, legacy, args.owner_id, args.environment_key)
    print(
        json.dumps(
            {
                "schema": "mcn.showcase-plan-receipt/v1",
                "scope": "full-destroy",
                "source_commit": args.source_commit,
                "backend_key": args.backend_key,
                "environment_key": args.environment_key,
                "owner_id": args.owner_id,
                "provider_artifact_sha256": "sha256:" + PROVIDER_SHA256,
                "plan_sha256": "sha256:" + digest(args.plan),
                "prior_state_sha256": "sha256:" + digest(args.state),
                "destroy_events_sha256": "sha256:" + digest(args.events),
                "action_count": count,
                "ownership_mode": "legacy-production",
            },
            sort_keys=True,
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
        KeyError,
    ) as exc:
        print(f"showcase-legacy-destroy-scope: {exc}", file=sys.stderr)
        sys.exit(2)
