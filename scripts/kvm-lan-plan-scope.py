#!/usr/bin/env python3
"""Validate one full-root saved plan for the staged KVM LAN rollout."""
# pylint: disable=invalid-name,too-many-branches,missing-function-docstring,line-too-long
# ruff: noqa: D103, EM101, EM102, PLR2004, S603, TRY003, TRY004, TRY300, TRY301

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from typing import Any

SCHEMA_VERSION = "mcn.kvm-lan-preflight/v2"
DOMAIN = 'libvirt_domain.ce_node["01"]'
INTERFACE = 'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]'
APPLICATION = {
    "xcsh_virtual_site.kvm_lan[0]",
    "xcsh_origin_pool.kvm_lan[0]",
    "xcsh_http_loadbalancer.kvm_lan[0]",
}


def _mapping(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _items(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _variable(document: dict[str, Any], name: str) -> Any:
    variable = _mapping(_mapping(document.get("variables")).get(name))
    if "value" not in variable:
        raise ValueError(f"saved plan is missing variable {name}")
    return variable["value"]


def _resources(module: dict[str, Any]) -> list[dict[str, Any]]:
    found = [
        resource
        for resource in _items(module.get("resources"))
        if isinstance(resource, dict)
    ]
    for child in _items(module.get("child_modules")):
        if isinstance(child, dict):
            found.extend(_resources(child))
    return found


def _active_changes(document: dict[str, Any]) -> dict[str, list[str]]:
    changes: dict[str, list[str]] = {}
    for raw_change in _items(document.get("resource_changes")):
        change = _mapping(raw_change)
        address = change.get("address")
        actions = _mapping(change.get("change")).get("actions")
        if not isinstance(address, str) or not isinstance(actions, list):
            raise ValueError("saved plan contains a malformed resource change")
        normalized = [action for action in actions if isinstance(action, str)]
        if normalized in (["no-op"], ["read"]):
            continue
        changes[address] = normalized
    return changes


def _lan_contract(document: dict[str, Any], stage: str) -> dict[str, Any]:
    if _variable(document, "enable_kvm") is not True:
        raise ValueError("saved plan does not enable the owned KVM site")
    if _variable(document, "enable_kvm_lan") is not True:
        raise ValueError("saved plan does not enable KVM LAN")
    if _variable(document, "kvm_lan_configuration_phase") != stage:
        raise ValueError("saved plan KVM LAN phase does not match the reviewed stage")
    lan = _mapping(_variable(document, "kvm_lan"))
    required_text = (
        "bridge",
        "uplink",
        "uplink_mac",
        "ownership",
        "sli_mac",
        "sli_cidr",
        "vip",
        "vip_reservation",
        "backend_ip",
        "backend_owner",
        "http_domain",
        "access_scope",
    )
    if any(
        not isinstance(lan.get(key), str) or not lan[key].strip()
        for key in required_text
    ):
        raise ValueError(
            "saved plan has an incomplete KVM LAN ownership/address contract"
        )
    approvals = (
        "bridge_preprovisioned",
        "uplink_approved",
        "ipv4_users_reviewed",
        "ipv6_users_reviewed",
        "switch_multi_mac_approved",
        "duplicate_addresses_checked",
    )
    if any(lan.get(key) is not True for key in approvals):
        raise ValueError("saved plan is missing a required KVM LAN approval")
    if lan.get("ownership") != "preprovisioned-shared":
        raise ValueError("saved plan must preserve a preprovisioned shared bridge")
    return lan


def _owned_unknown_slo_network(document: dict[str, Any]) -> bool:
    """Bind an unknown first-NIC network ID to the owned libvirt network."""
    change = next(
        (
            item
            for item in _items(document.get("resource_changes"))
            if _mapping(item).get("address") == DOMAIN
        ),
        {},
    )
    unknown = _mapping(_mapping(_mapping(change).get("change")).get("after_unknown"))
    unknown_interfaces = _items(unknown.get("network_interface"))
    if (
        len(unknown_interfaces) != 2
        or _mapping(unknown_interfaces[0]).get("network_id") is not True
        or _mapping(unknown_interfaces[0]).get("bridge") is True
    ):
        return False
    resources = _resources(
        _mapping(_mapping(document.get("configuration")).get("root_module"))
    )
    domain = next(
        (
            resource
            for resource in resources
            if resource.get("address") == "libvirt_domain.ce_node"
        ),
        {},
    )
    interfaces = _items(_mapping(domain.get("expressions")).get("network_interface"))
    if len(interfaces) != 1:
        return False
    references = _items(
        _mapping(_mapping(interfaces[0]).get("network_id")).get("references")
    )
    allowed = {
        "libvirt_network.ce_bgp_net[0].id",
        "libvirt_network.ce_bgp_net[0]",
        "libvirt_network.ce_bgp_net",
    }
    return "libvirt_network.ce_bgp_net[0].id" in references and all(
        reference in allowed for reference in references
    )


def validate_plan(document: object, stage: str) -> dict[str, Any]:
    """Return a secret-free receipt or reject an unsafe plan."""
    if stage not in {"hardware", "configured"}:
        raise ValueError("stage must be hardware or configured")
    if not isinstance(document, dict):
        raise ValueError("Terraform plan JSON must be one object")
    if document.get("terraform_version") != "1.16.3":
        raise ValueError("saved plan was not produced by Terraform 1.16.3")
    lan = _lan_contract(document, stage)
    changes = _active_changes(document)

    if stage == "hardware":
        if set(changes) != {DOMAIN}:
            raise ValueError(
                "hardware plan contains an action outside the owned KVM domain"
            )
        domain_change = changes[DOMAIN]
        if domain_change not in (
            ["create"],
            ["delete", "create"],
            ["create", "delete"],
        ):
            raise ValueError(
                "hardware plan must create or replace the KVM domain; update-only NIC changes are unsafe"
            )
        resources = {
            resource.get("address"): resource
            for resource in _resources(
                _mapping(_mapping(document.get("planned_values")).get("root_module"))
            )
        }
        domain = _mapping(resources.get(DOMAIN))
        interfaces = _items(_mapping(domain.get("values")).get("network_interface"))
        if len(interfaces) != 2:
            raise ValueError("hardware plan must create exactly two ordered CE NICs")
        slo, sli = (_mapping(interface) for interface in interfaces)
        if (
            not slo.get("network_id") and not _owned_unknown_slo_network(document)
        ) or slo.get("bridge"):
            raise ValueError("first CE NIC must remain the libvirt-network SLO")
        if (
            not sli.get("bridge")
            or not sli.get("mac")
            or sli.get("mac") == slo.get("mac")
        ):
            raise ValueError(
                "second CE NIC must be a distinct deterministic bridged SLI"
            )
        domain_action = "create" if domain_change == ["create"] else "replace"
    else:
        required = {INTERFACE, *APPLICATION}
        if set(changes) != required:
            raise ValueError(
                "configured plan is missing the owned SLI/application actions or contains an action outside them"
            )
        if changes[INTERFACE] != ["create"]:
            raise ValueError(
                "configured plan must adopt the owned KVM SLI interface through one create action"
            )
        resources = {
            resource.get("address"): resource
            for resource in _resources(
                _mapping(_mapping(document.get("planned_values")).get("root_module"))
            )
        }
        interface = _mapping(_mapping(resources.get(INTERFACE)).get("values"))
        shape_matches = all(
            (
                interface.get("namespace") == "system",
                isinstance(interface.get("site"), str),
                bool(str(interface.get("site", "")).strip()),
                str(interface.get("expected_mac", "")).lower()
                == str(lan.get("sli_mac", "")).lower(),
                interface.get("ipv4_cidr") == lan.get("sli_cidr"),
            )
        )
        if not shape_matches:
            raise ValueError(
                "configured plan SLI adoption does not match the reviewed owned interface shape"
            )
        if any(changes[address] != ["create"] for address in APPLICATION):
            raise ValueError(
                "configured plan must create the three owned KVM LAN application objects"
            )
        domain_action = "none"

    return {
        "schema_version": SCHEMA_VERSION,
        "stage": stage,
        "change_count": len(changes),
        "change_addresses": sorted(changes),
        "domain_action": domain_action,
        "interface_resource": INTERFACE if stage == "configured" else None,
        "host_network": {
            "bridge": lan["bridge"],
            "uplink": lan["uplink"],
            "uplink_mac": lan["uplink_mac"].lower(),
            "mtu": lan.get("mtu"),
            "ownership": lan["ownership"],
        },
    }


def verify_host_network(contract: dict[str, Any]) -> None:
    """Observe the declared existing bridge/uplink without changing either."""
    host = _mapping(contract.get("host_network"))
    bridge_name = host.get("bridge")
    uplink_name = host.get("uplink")
    expected_mac = host.get("uplink_mac")
    expected_mtu = host.get("mtu")
    if (
        not isinstance(bridge_name, str)
        or not isinstance(uplink_name, str)
        or not isinstance(expected_mac, str)
    ):
        raise ValueError("validated plan did not yield a host-network identity")

    def link(name: str, details: bool = False) -> dict[str, Any]:
        command = ["ip", "-json"]
        if details:
            command.append("-details")
        command.extend(["link", "show", "dev", name])
        completed = subprocess.run(command, check=True, capture_output=True, text=True)
        payload = json.loads(completed.stdout)
        if (
            not isinstance(payload, list)
            or len(payload) != 1
            or not isinstance(payload[0], dict)
        ):
            raise ValueError(
                "host network inventory did not return exactly one interface"
            )
        return payload[0]

    bridge = link(bridge_name, details=True)
    uplink = link(uplink_name)
    if _mapping(bridge.get("linkinfo")).get("info_kind") != "bridge":
        raise ValueError("declared KVM LAN bridge is not an existing Linux bridge")
    if bridge.get("mtu") != expected_mtu or uplink.get("mtu") != expected_mtu:
        raise ValueError(
            "declared KVM LAN MTU does not match bridge and uplink inventory"
        )
    if str(uplink.get("address", "")).lower() != expected_mac:
        raise ValueError("declared KVM LAN uplink MAC does not match host inventory")
    if uplink.get("master") != bridge_name:
        raise ValueError(
            "declared KVM LAN uplink is not enslaved to the approved bridge"
        )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--stage", choices=("hardware", "configured"), required=True)
    parser.add_argument("--plan-sha256", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-commit-sha", required=True)
    parser.add_argument("--verify-host-network", action="store_true")
    args = parser.parse_args()
    try:
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", args.plan_sha256):
            raise ValueError("plan SHA-256 is malformed")
        if not re.fullmatch(r"refs/heads/[A-Za-z0-9._/-]+", args.source_ref):
            raise ValueError("source ref is malformed")
        if not re.fullmatch(r"[0-9a-f]{40}", args.source_commit_sha):
            raise ValueError("source commit is malformed")
        document = json.load(sys.stdin)
        contract = validate_plan(document, args.stage)
        if _variable(document, "source_ref") != args.source_ref:
            raise ValueError("saved plan source ref does not match the reviewed ref")
        if _variable(document, "source_commit_sha") != args.source_commit_sha:
            raise ValueError(
                "saved plan source commit does not match the reviewed commit"
            )
        if args.verify_host_network:
            verify_host_network(contract)
        contract["plan_sha256"] = args.plan_sha256
        contract["source_ref"] = args.source_ref
        contract["source_commit_sha"] = args.source_commit_sha
        json.dump(contract, sys.stdout, sort_keys=True, separators=(",", ":"))
        sys.stdout.write("\n")
        return 0
    except (
        json.JSONDecodeError,
        OSError,
        subprocess.SubprocessError,
        ValueError,
    ) as error:
        sys.stderr.write(f"KVM LAN plan preflight failed: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
