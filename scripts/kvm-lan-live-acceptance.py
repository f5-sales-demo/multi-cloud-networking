#!/usr/bin/env python3
"""Collect and verify read-only KVM physical-LAN acceptance evidence."""
# pylint: disable=invalid-name,too-many-branches,too-many-lines,too-many-locals,too-many-statements
# ruff: noqa: ANN001, ANN202, D103, EM101, EM102, PERF401, PLR2004, S314, S603, SIM105, TRY003, TRY004, TRY301

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from typing import Any

CONFIG_SCHEMA = "mcn.kvm-lan-live-acceptance.config/v1"
OBSERVATION_SCHEMA = "mcn.kvm-lan-live-acceptance.observation/v1"
RECEIPT_SCHEMA = "mcn.kvm-lan-live-acceptance.receipt/v1"
MAX_COMMAND_SECONDS = 300
MAX_HTTP_BODY_BYTES = 1048576
SHA256 = re.compile(r"(?:sha256:)?[0-9a-f]{64}")
SOURCE_REF = re.compile(r"refs/heads/[A-Za-z0-9._/-]+")
SOURCE_COMMIT = re.compile(r"[0-9a-f]{40}")
DNS_NAME = re.compile(
    r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+"
)
SSH_NAME = re.compile(r"[A-Za-z0-9._-]+")
CLIENT_PROBE = r"""
import hashlib
import json
import socket
import sys

domain, vip, timeout_text, maximum_text = sys.argv[1:]
timeout = int(timeout_text)
maximum = int(maximum_text)
addresses = sorted({item[4][0] for item in socket.getaddrinfo(domain, 80, socket.AF_INET, socket.SOCK_STREAM)})
sock = socket.create_connection((vip, 80), timeout=timeout)
source_ip = sock.getsockname()[0]
request = f"GET / HTTP/1.1\r\nHost: {domain}\r\nConnection: close\r\nAccept: */*\r\n\r\n"
sock.sendall(request.encode("ascii"))
chunks = []
size = 0
while True:
    chunk = sock.recv(min(65536, maximum + 1 - size))
    if not chunk:
        break
    chunks.append(chunk)
    size += len(chunk)
    if size > maximum:
        raise RuntimeError("HTTP response exceeds the acceptance limit")
sock.close()
response = b"".join(chunks)
head, separator, body = response.partition(b"\r\n\r\n")
if not separator:
    raise RuntimeError("HTTP response has no header boundary")
status_line = head.split(b"\r\n", 1)[0].decode("ascii", errors="strict")
parts = status_line.split(" ", 2)
if len(parts) < 2 or not parts[1].isdigit():
    raise RuntimeError("HTTP response has an invalid status line")
print(json.dumps({
    "dns_addresses": addresses,
    "connected_ip": vip,
    "source_ip": source_ip,
    "host_header": domain,
    "http_status": int(parts[1]),
    "response_sha256": hashlib.sha256(body).hexdigest(),
}, sort_keys=True, separators=(",", ":")))
""".lstrip()


def _mapping(value: object) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def _items(value: object) -> list[Any]:
    return value if isinstance(value, list) else []


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _strings(value: object) -> list[str]:
    return [item for item in _items(value) if isinstance(item, str)]


def _canonical(value: object) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _digest_bytes(value: bytes) -> str:
    return "sha256:" + hashlib.sha256(value).hexdigest()


def _digest_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return "sha256:" + digest.hexdigest()


def _check(checks, identifier, passed, passed_detail, failed_detail):
    checks.append(
        {
            "id": identifier,
            "status": "passed" if passed else "failed",
            "detail": passed_detail if passed else failed_detail,
        }
    )


def _required_mapping(parent: dict[str, Any], name: str) -> dict[str, Any]:
    value = parent.get(name)
    if not isinstance(value, dict):
        raise ValueError(f"configuration field {name} must be an object")
    return value


def _validate_config(document: object) -> dict[str, Any]:
    if (
        not isinstance(document, dict)
        or document.get("schema_version") != CONFIG_SCHEMA
    ):
        raise ValueError("configuration schema_version is unsupported")
    source = _required_mapping(document, "source")
    plan = _required_mapping(document, "plan")
    host = _required_mapping(document, "host")
    vm = _required_mapping(document, "vm")
    xc = _required_mapping(document, "xc")
    frr = _required_mapping(document, "frr")
    client = _required_mapping(document, "client")
    if not SOURCE_REF.fullmatch(_text(source.get("ref"))):
        raise ValueError("source.ref is malformed")
    if not SOURCE_COMMIT.fullmatch(_text(source.get("commit_sha"))):
        raise ValueError("source.commit_sha is malformed")
    if not SHA256.fullmatch(_text(plan.get("sha256"))):
        raise ValueError("plan.sha256 is malformed")
    if plan.get("preflight_schema") != "mcn.kvm-lan-preflight/v1":
        raise ValueError("plan.preflight_schema is unsupported")
    required_host_text = (
        "bridge",
        "uplink",
        "uplink_mac",
        "management_interface",
        "default_gateway4",
    )
    if any(not _text(host.get(field)) for field in required_host_text):
        raise ValueError("host ownership fields are incomplete")
    if not isinstance(host.get("mtu"), int) or host["mtu"] < 576:
        raise ValueError("host.mtu is invalid")
    for field in ("allowed_uplink_ipv4", "allowed_uplink_ipv6"):
        if not isinstance(host.get(field), list):
            raise ValueError(f"host.{field} must be an array")
    if not _text(vm.get("domain")) or any(
        not isinstance(vm.get(field), int) or vm[field] < 1
        for field in ("vcpus", "memory_kib", "disk_min_bytes")
    ):
        raise ValueError("VM identity and resources are incomplete")
    for field in ("slo_mac", "sli_mac"):
        if not re.fullmatch(
            r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", _text(vm.get(field)).lower()
        ):
            raise ValueError(f"vm.{field} is malformed")
    ipaddress.ip_address(_text(vm.get("dhcp_ipv4")))
    ipaddress.ip_network(_text(xc.get("imported_route")), strict=False)
    ipaddress.ip_address(_text(xc.get("bgp_peer")))
    if not _text(xc.get("site_name")):
        raise ValueError("xc.site_name is required")
    if not _text(frr.get("container")):
        raise ValueError("frr.container is required")
    ipaddress.ip_address(_text(frr.get("peer")))
    for field in ("advertised_routes", "received_routes"):
        if not isinstance(frr.get(field), list):
            raise ValueError(f"frr.{field} must be an array")
        for route in frr[field]:
            ipaddress.ip_network(route, strict=False)
    if not DNS_NAME.fullmatch(_text(client.get("http_domain"))):
        raise ValueError("client.http_domain is malformed")
    ipaddress.ip_address(_text(client.get("vip")))
    if not re.fullmatch(r"[0-9a-f]{64}", _text(client.get("response_sha256"))):
        raise ValueError("client.response_sha256 is malformed")
    if not isinstance(client.get("http_status"), int):
        raise ValueError("client.http_status is invalid")
    return document


def evaluate(configuration: object, observation: object) -> dict[str, Any]:
    """Evaluate captured evidence without copying secrets into the receipt."""
    expected = _validate_config(configuration)
    if (
        not isinstance(observation, dict)
        or observation.get("schema_version") != OBSERVATION_SCHEMA
    ):
        raise ValueError("observation schema_version is unsupported")
    source = _mapping(expected["source"])
    plan = _mapping(expected["plan"])
    host = _mapping(expected["host"])
    vm = _mapping(expected["vm"])
    xc = _mapping(expected["xc"])
    frr = _mapping(expected["frr"])
    client = _mapping(expected["client"])
    observed_source = _mapping(observation.get("source"))
    observed_plan = _mapping(observation.get("plan"))
    observed_host = _mapping(observation.get("host"))
    observed_vm = _mapping(observation.get("vm"))
    observed_xc = _mapping(observation.get("xc"))
    observed_frr = _mapping(observation.get("frr"))
    observed_client = _mapping(observation.get("client"))
    observed_terraform = _mapping(observation.get("terraform"))
    checks: list[dict[str, str]] = []

    _check(
        checks,
        "source_identity",
        observed_source.get("ref") == source["ref"]
        and observed_source.get("commit_sha") == source["commit_sha"]
        and observed_source.get("clean") is True,
        "source ref and commit match a clean reviewed deployment",
        "source ref, commit, or worktree does not match the reviewed deployment",
    )
    _check(
        checks,
        "saved_plan",
        observed_plan.get("sha256") == plan["sha256"]
        and observed_plan.get("preflight_schema") == plan["preflight_schema"]
        and observed_plan.get("preflight_bound") is True,
        "saved plan digest and preflight schema match",
        "saved plan digest, source binding, or preflight schema is stale or mismatched",
    )

    links = _mapping(observed_host.get("links"))
    bridge = _mapping(links.get(host["bridge"]))
    uplink = _mapping(links.get(host["uplink"]))
    _check(
        checks,
        "host_bridge",
        bridge.get("kind") == "bridge"
        and bridge.get("mtu") == host["mtu"]
        and bridge.get("up") is True,
        "approved bridge exists, is up, and has the reviewed MTU",
        "approved bridge is missing, down, not a bridge, or has the wrong MTU",
    )
    _check(
        checks,
        "host_uplink",
        _text(uplink.get("mac")).lower() == _text(host["uplink_mac"]).lower()
        and uplink.get("master") == host["bridge"]
        and uplink.get("mtu") == host["mtu"]
        and uplink.get("up") is True,
        "approved uplink identity and bridge membership match",
        "uplink identity, state, MTU, or bridge membership does not match",
    )
    uplink_addresses = _mapping(
        _mapping(observed_host.get("addresses")).get(host["uplink"])
    )
    _check(
        checks,
        "uplink_addresses",
        sorted(_strings(uplink_addresses.get("ipv4")))
        == sorted(_strings(host.get("allowed_uplink_ipv4")))
        and sorted(_strings(uplink_addresses.get("ipv6")))
        == sorted(_strings(host.get("allowed_uplink_ipv6"))),
        "uplink IPv4 and IPv6 users match the reviewed ownership contract",
        "uplink has unreviewed IPv4 or IPv6 users",
    )
    defaults = [
        item
        for item in _items(observed_host.get("default_routes"))
        if isinstance(item, dict) and item.get("family") == "ipv4"
    ]
    _check(
        checks,
        "management_route",
        len(defaults) == 1
        and defaults[0].get("dev") == host["management_interface"]
        and defaults[0].get("gateway") == host["default_gateway4"],
        "management default route remains on the reviewed interface and gateway",
        "management default route moved or became ambiguous",
    )
    _check(
        checks,
        "host_isolation",
        host["bridge"] not in _strings(observed_host.get("libvirt_network_bridges"))
        and host["bridge"] not in _strings(observed_host.get("dhcp_interfaces")),
        "physical bridge has no libvirt NAT or DHCP owner",
        "physical bridge is unexpectedly owned by libvirt NAT or DHCP",
    )

    _check(
        checks,
        "vm_state",
        observed_vm.get("domain") == vm["domain"]
        and observed_vm.get("state") == "running"
        and observed_vm.get("autostart") is True,
        "owned CE domain is running with autostart enabled",
        "owned CE domain identity or running/autostart state is wrong",
    )
    _check(
        checks,
        "vm_resources",
        observed_vm.get("vcpus") == vm["vcpus"]
        and observed_vm.get("memory_kib") == vm["memory_kib"]
        and isinstance(observed_vm.get("disk_capacity_bytes"), int)
        and observed_vm["disk_capacity_bytes"] >= vm["disk_min_bytes"],
        "CE CPU, memory, and disk meet the reviewed shape",
        "CE CPU, memory, or disk does not meet the reviewed shape",
    )
    _check(
        checks,
        "vm_nics",
        [item.lower() for item in _strings(observed_vm.get("macs"))]
        == [vm["slo_mac"].lower(), vm["sli_mac"].lower()],
        "CE has exactly the ordered deterministic SLO and SLI MACs",
        "CE NIC count, order, or MAC identity is wrong",
    )
    _check(
        checks,
        "vm_dhcp",
        vm["dhcp_ipv4"] in _strings(observed_vm.get("ipv4")),
        "CE retains its reviewed SLO DHCP identity",
        "CE SLO DHCP identity is missing or changed",
    )

    _check(
        checks,
        "xc_site",
        observed_xc.get("registration_count") == 1
        and observed_xc.get("online_count") == 1
        and observed_xc.get("lan_phase") == "configured"
        and observed_xc.get("lan_site_name") == xc["site_name"],
        "XC has exactly one ONLINE configured node for the owned site",
        "XC site identity, registration count, phase, or ONLINE state is wrong",
    )
    slo_device = _text(observed_xc.get("slo_device"))
    sli_device = _text(observed_xc.get("sli_device"))
    _check(
        checks,
        "xc_interfaces",
        observed_xc.get("mapping_valid") is True
        and bool(slo_device)
        and bool(sli_device)
        and slo_device != sli_device
        and observed_xc.get("realized_sli") == sli_device,
        "XC resolves one distinct SLO and one distinct SLI by owned identity",
        "XC SLO/SLI mapping is absent, duplicated, stale, or mismatched",
    )
    _check(
        checks,
        "xc_bgp",
        observed_xc.get("bgp_converged") is True
        and observed_xc.get("bgp_session_count") == 1,
        "XC reports exactly one converged BGP session",
        "XC does not report exactly one converged BGP session",
    )

    _check(
        checks,
        "frr_peer",
        observed_frr.get("container") == frr["container"]
        and observed_frr.get("running") is True
        and observed_frr.get("peer") == frr["peer"]
        and observed_frr.get("state") == "Established",
        "FRR reports the exact CE peer Established",
        "FRR container or exact CE peer is missing or not Established",
    )
    _check(
        checks,
        "frr_routes",
        sorted(_strings(observed_frr.get("advertised_routes")))
        == sorted(_strings(frr.get("advertised_routes")))
        and sorted(_strings(observed_frr.get("received_routes")))
        == sorted(_strings(frr.get("received_routes")))
        and xc["imported_route"] in _strings(observed_frr.get("advertised_routes")),
        "FRR advertised and received routes exactly match the reviewed contract",
        "FRR advertised or received routes do not match the reviewed contract",
    )

    _check(
        checks,
        "client_dns_vip",
        client["vip"] in _strings(observed_client.get("dns_addresses"))
        and observed_client.get("connected_ip") == client["vip"],
        "independent client resolved and connected to the inside VIP",
        "independent client DNS or connected VIP identity is wrong",
    )
    _check(
        checks,
        "client_http",
        observed_client.get("host_header") == client["http_domain"]
        and observed_client.get("http_status") == client["http_status"]
        and observed_client.get("response_sha256") == client["response_sha256"],
        "independent client received the exact Host-routed origin response",
        "independent client Host, status, or response identity is wrong",
    )
    _check(
        checks,
        "terraform_convergence",
        observed_terraform.get("zero_change") is True
        and bool(
            SHA256.fullmatch(_text(observed_terraform.get("zero_change_plan_sha256")))
        ),
        "refresh-enabled full-root Terraform plan has zero changes",
        "refresh-enabled full-root Terraform plan failed or has changes",
    )

    status_value = (
        "failed" if any(item["status"] == "failed" for item in checks) else "passed"
    )
    return {
        "schema_version": RECEIPT_SCHEMA,
        "status": status_value,
        "source": {"ref": source["ref"], "commit_sha": source["commit_sha"]},
        "plan": {
            "sha256": plan["sha256"],
            "preflight_schema": plan["preflight_schema"],
        },
        "evidence_sha256": _digest_bytes(_canonical(observation)),
        "checks": checks,
    }


def _run(argv, *, cwd=None, input_text=None, allowed=(0,), timeout=MAX_COMMAND_SECONDS):
    completed = subprocess.run(
        argv,
        cwd=cwd,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode not in allowed:
        raise RuntimeError(f"read-only command failed: {pathlib.Path(argv[0]).name}")
    return completed


def _run_json(
    argv, *, cwd=None, input_text=None, allowed=(0,), timeout=MAX_COMMAND_SECONDS
):
    completed = _run(
        argv, cwd=cwd, input_text=input_text, allowed=allowed, timeout=timeout
    )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise ValueError(
            f"{pathlib.Path(argv[0]).name} returned invalid JSON"
        ) from error


def _optional_lines(argv):
    try:
        return [line.strip() for line in _run(argv).stdout.splitlines() if line.strip()]
    except (OSError, subprocess.SubprocessError, RuntimeError):
        return []


def _network_inventory() -> dict[str, Any]:
    raw_links = _run_json(["ip", "-json", "-details", "link", "show"])
    raw_addresses = _run_json(["ip", "-json", "address", "show"])
    raw_v4_routes = _run_json(["ip", "-json", "route", "show", "default"])
    raw_v6_routes = _run_json(["ip", "-6", "-json", "route", "show", "default"])
    links = {}
    for raw in _items(raw_links):
        link = _mapping(raw)
        name = _text(link.get("ifname"))
        if not name:
            continue
        links[name] = {
            "kind": _mapping(link.get("linkinfo")).get("info_kind"),
            "mac": _text(link.get("address")).lower(),
            "master": link.get("master"),
            "mtu": link.get("mtu"),
            "up": "UP" in _strings(link.get("flags")),
        }
    addresses = {}
    for raw in _items(raw_addresses):
        item = _mapping(raw)
        name = _text(item.get("ifname"))
        if not name:
            continue
        values: dict[str, list[str]] = {"ipv4": [], "ipv6": []}
        for raw_address in _items(item.get("addr_info")):
            address = _mapping(raw_address)
            family = address.get("family")
            local = _text(address.get("local"))
            prefix = address.get("prefixlen")
            if family in {"inet", "inet6"} and local and isinstance(prefix, int):
                values["ipv4" if family == "inet" else "ipv6"].append(
                    f"{local}/{prefix}"
                )
        addresses[name] = values
    default_routes = []
    for family, routes in (("ipv4", raw_v4_routes), ("ipv6", raw_v6_routes)):
        for raw in _items(routes):
            route = _mapping(raw)
            default_routes.append(
                {
                    "family": family,
                    "dev": route.get("dev"),
                    "gateway": route.get("gateway"),
                }
            )
    libvirt_bridges = []
    for network in _optional_lines(
        ["virsh", "--connect", "qemu:///system", "net-list", "--all", "--name"]
    ):
        try:
            root = ET.fromstring(
                _run(
                    ["virsh", "--connect", "qemu:///system", "net-dumpxml", network]
                ).stdout
            )
            bridge = root.find("bridge")
            if bridge is not None and bridge.get("name"):
                libvirt_bridges.append(bridge.get("name"))
        except (ET.ParseError, OSError, RuntimeError):
            continue
    dhcp_interfaces = []
    for line in _optional_lines(["ps", "-eo", "args="]):
        if "dnsmasq" not in line:
            continue
        for match in re.finditer(r"--interface(?:=|\s+)([A-Za-z0-9_.-]+)", line):
            dhcp_interfaces.append(match.group(1))
    return {
        "links": links,
        "addresses": addresses,
        "default_routes": default_routes,
        "libvirt_network_bridges": sorted(set(libvirt_bridges)),
        "dhcp_interfaces": sorted(set(dhcp_interfaces)),
    }


def collect_inventory() -> dict[str, Any]:
    inventory = _network_inventory()
    vms = _optional_lines(
        ["virsh", "--connect", "qemu:///system", "list", "--all", "--name"]
    )
    containers = _optional_lines(["docker", "ps", "--format", "{{.Names}}"])
    filesystems = {}
    for path in (pathlib.Path("/"), pathlib.Path("/data")):
        if path.exists():
            usage = shutil.disk_usage(path)
            filesystems[str(path)] = {
                "free_bytes": usage.free,
                "total_bytes": usage.total,
            }
    memory = {}
    meminfo = pathlib.Path("/proc/meminfo")
    if meminfo.exists():
        for line in meminfo.read_text(encoding="utf-8").splitlines():
            key, _, value = line.partition(":")
            if key in {"MemAvailable", "SwapFree", "SwapTotal"}:
                memory[key] = int(value.strip().split()[0]) * 1024
    return {
        "host": inventory,
        "vms": sorted(vms),
        "containers": sorted(containers),
        "capacity": {"filesystems": filesystems, "memory": memory},
    }


def inventory_receipt(observation: object) -> dict[str, Any]:
    observed = _mapping(observation)
    host = _mapping(observed.get("host"))
    defaults = _items(host.get("default_routes"))
    management = {
        item.get("dev")
        for item in defaults
        if isinstance(item, dict) and isinstance(item.get("dev"), str)
    }
    interfaces = []
    for name, raw_link in sorted(_mapping(host.get("links")).items()):
        link = _mapping(raw_link)
        address = _mapping(_mapping(host.get("addresses")).get(name))
        interfaces.append(
            {
                "name": name,
                "kind": link.get("kind"),
                "up": link.get("up") is True,
                "management_route": name in management,
                "ipv4_address_count": len(_strings(address.get("ipv4"))),
                "ipv6_address_count": len(_strings(address.get("ipv6"))),
            }
        )
    return {
        "schema_version": RECEIPT_SCHEMA,
        "status": "blocked",
        "evidence_sha256": _digest_bytes(_canonical(observation)),
        "checks": [
            {
                "id": "reviewed_configuration",
                "status": "blocked",
                "detail": "verification requires an approved bridge, uplink, allocation, source, plan, and independent-client contract",
            }
        ],
        "inventory": {
            "interfaces": interfaces,
            "vms": sorted(_strings(observed.get("vms"))),
            "containers": sorted(_strings(observed.get("containers"))),
            "capacity": _mapping(observed.get("capacity")),
        },
    }


def _memory_bytes(element: ET.Element) -> int:
    value = int(_text(element.text))
    unit = _text(element.get("unit")).lower() or "kib"
    factors = {"b": 1, "kib": 1024, "mib": 1024**2, "gib": 1024**3}
    if unit not in factors:
        raise ValueError("libvirt domain memory unit is unsupported")
    return value * factors[unit]


def _vm_observation(expected: dict[str, Any]) -> dict[str, Any]:
    domain = expected["domain"]
    xml_text = _run(["virsh", "--connect", "qemu:///system", "dumpxml", domain]).stdout
    root = ET.fromstring(xml_text)
    vcpu = root.find("vcpu")
    memory = root.find("memory")
    if vcpu is None or memory is None:
        raise ValueError("libvirt domain XML has no CPU or memory")
    macs = [
        _text(mac.get("address")).lower()
        for interface in root.findall("./devices/interface")
        for mac in [interface.find("mac")]
        if mac is not None and mac.get("address")
    ]
    disk_sources = []
    for disk in root.findall("./devices/disk"):
        if disk.get("device") != "disk":
            continue
        source = disk.find("source")
        if source is None:
            continue
        path = source.get("file") or source.get("dev")
        pool = source.get("pool")
        volume = source.get("volume")
        if path:
            disk_sources.append(("path", path, ""))
        elif pool and volume:
            disk_sources.append(("volume", pool, volume))
    if len(disk_sources) != 1:
        raise ValueError("CE domain must have exactly one data disk")
    source_type, first, second = disk_sources[0]
    if source_type == "path":
        disk_info = _run_json(["qemu-img", "info", "--output=json", first])
        disk_capacity = int(_mapping(disk_info).get("virtual-size", 0))
    else:
        volume_info = _run(
            [
                "virsh",
                "--connect",
                "qemu:///system",
                "vol-info",
                "--bytes",
                "--pool",
                first,
                second,
            ]
        ).stdout
        match = re.search(
            r"^Capacity:\s+(\d+)(?:\s+bytes)?\s*$", volume_info, re.MULTILINE
        )
        if not match:
            raise ValueError("libvirt volume capacity is unavailable")
        disk_capacity = int(match.group(1))
    dominfo = _run(["virsh", "--connect", "qemu:///system", "dominfo", domain]).stdout
    autostart = any(
        line.lower().startswith("autostart:")
        and line.split(":", 1)[1].strip().lower() == "enable"
        for line in dominfo.splitlines()
    )
    addresses = []
    lease_text = _run(
        [
            "virsh",
            "--connect",
            "qemu:///system",
            "domifaddr",
            domain,
            "--source",
            "lease",
        ]
    ).stdout
    for match in re.finditer(r"\b(\d{1,3}(?:\.\d{1,3}){3})/\d+\b", lease_text):
        addresses.append(str(ipaddress.ip_address(match.group(1))))
    state_value = (
        _run(["virsh", "--connect", "qemu:///system", "domstate", domain])
        .stdout.strip()
        .lower()
    )
    return {
        "domain": domain,
        "state": state_value,
        "autostart": autostart,
        "vcpus": int(_text(vcpu.text)),
        "memory_kib": _memory_bytes(memory) // 1024,
        "disk_capacity_bytes": disk_capacity,
        "macs": macs,
        "ipv4": sorted(set(addresses)),
    }


def _route_prefixes(value: object) -> list[str]:
    found = set()

    def visit(item):
        if isinstance(item, dict):
            for key, child in item.items():
                for candidate in (key, child if key in {"prefix", "network"} else None):
                    if isinstance(candidate, str):
                        try:
                            found.add(
                                str(ipaddress.ip_network(candidate, strict=False))
                            )
                        except ValueError:
                            pass
                visit(child)
        elif isinstance(item, list):
            for child in item:
                visit(child)

    visit(value)
    return sorted(found)


def _frr_observation(expected: dict[str, Any]) -> dict[str, Any]:
    container = expected["container"]
    peer = expected["peer"]
    names = _optional_lines(["docker", "ps", "--format", "{{.Names}}"])
    neighbor = _run_json(
        ["docker", "exec", container, "vtysh", "-c", f"show bgp neighbor {peer} json"]
    )
    advertised = _run_json(
        [
            "docker",
            "exec",
            container,
            "vtysh",
            "-c",
            f"show bgp ipv4 unicast neighbors {peer} advertised-routes json",
        ]
    )
    received = _run_json(
        [
            "docker",
            "exec",
            container,
            "vtysh",
            "-c",
            f"show bgp ipv4 unicast neighbors {peer} received-routes json",
        ]
    )
    peer_document = _mapping(_mapping(neighbor).get(peer))
    if not peer_document and _mapping(neighbor).get("bgpState"):
        peer_document = _mapping(neighbor)
    return {
        "container": container,
        "running": container in names,
        "peer": peer,
        "state": peer_document.get("bgpState"),
        "advertised_routes": _route_prefixes(advertised),
        "received_routes": _route_prefixes(received),
    }


def _terraform_prefix(configuration: dict[str, Any]) -> list[str]:
    terraform_config = _required_mapping(configuration, "terraform")
    prefix = terraform_config.get("argv_prefix", ["terraform"])
    if (
        not isinstance(prefix, list)
        or not prefix
        or any(not _text(item) for item in prefix)
    ):
        raise ValueError("terraform.argv_prefix must be a nonempty string array")
    return prefix


def _terraform_observation(
    configuration: dict[str, Any],
) -> tuple[dict[str, Any], dict[str, Any]]:
    terraform_config = _required_mapping(configuration, "terraform")
    directory = pathlib.Path(_text(terraform_config.get("directory"))).resolve()
    if not directory.is_dir():
        raise ValueError("terraform.directory is not a directory")
    prefix = _terraform_prefix(configuration)
    args = terraform_config.get("plan_args", [])
    if not isinstance(args, list) or any(not isinstance(item, str) for item in args):
        raise ValueError("terraform.plan_args must be a string array")
    forbidden = (
        "-destroy",
        "-target",
        "-replace",
        "-refresh=false",
        "-refresh-only",
        "-out",
        "-detailed-exitcode",
    )
    if any(item.startswith(forbidden) for item in args):
        raise ValueError(
            "terraform.plan_args contains a mutating or incomplete-plan option"
        )
    handle, temporary_name = tempfile.mkstemp(
        prefix=".kvm-lan-zero-", suffix=".tfplan", dir=directory
    )
    os.close(handle)
    temporary = pathlib.Path(temporary_name)
    temporary.unlink()
    timeout = terraform_config.get("timeout_seconds", 1800)
    if not isinstance(timeout, int) or not 1 <= timeout <= 3600:
        raise ValueError("terraform.timeout_seconds is outside the bounded range")
    try:
        completed = _run(
            [
                *prefix,
                "plan",
                "-input=false",
                "-no-color",
                "-detailed-exitcode",
                f"-out={temporary}",
                *args,
            ],
            cwd=directory,
            allowed=(0, 2),
            timeout=timeout,
        )
        zero_change = completed.returncode == 0
        plan_digest = _digest_file(temporary) if temporary.is_file() else ""
        plan_document = _run_json([*prefix, "show", "-json", temporary], cwd=directory)
    finally:
        temporary.unlink(missing_ok=True)
    outputs = _mapping(_mapping(plan_document.get("planned_values")).get("outputs"))
    runtime = _mapping(_mapping(outputs.get("kvm_runtime_status")).get("value"))
    lan = _mapping(_mapping(outputs.get("kvm_lan_contract")).get("value"))
    provenance = _mapping(_mapping(outputs.get("deployment_provenance")).get("value"))
    return (
        {
            "registration_count": runtime.get("registration_count"),
            "online_count": runtime.get("online_count"),
            "mapping_valid": runtime.get("mapping_valid"),
            "bgp_converged": runtime.get("bgp_converged"),
            "bgp_session_count": runtime.get("bgp_session_count"),
            "lan_phase": lan.get("phase"),
            "lan_site_name": lan.get("site_name"),
            "slo_device": lan.get("observed_slo"),
            "sli_device": lan.get("observed_sli"),
            "realized_sli": lan.get("realized_sli"),
            "provenance_ref": provenance.get("source_ref"),
            "provenance_commit": provenance.get("source_commit"),
        },
        {"zero_change": zero_change, "zero_change_plan_sha256": plan_digest},
    )


def _client_observation(expected: dict[str, Any]) -> dict[str, Any]:
    host = _text(expected.get("ssh_host"))
    user = _text(expected.get("ssh_user"))
    if not SSH_NAME.fullmatch(host) or not SSH_NAME.fullmatch(user):
        raise ValueError(
            "client ssh_host and ssh_user are required for live verification"
        )
    port = expected.get("ssh_port", 22)
    timeout = expected.get("timeout_seconds", 15)
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise ValueError("client.ssh_port is invalid")
    if not isinstance(timeout, int) or not 1 <= timeout <= 60:
        raise ValueError("client.timeout_seconds is outside the bounded range")
    command = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        f"ConnectTimeout={timeout}",
        "-o",
        "StrictHostKeyChecking=yes",
        "-p",
        str(port),
    ]
    identity = _text(expected.get("identity_file"))
    known_hosts = _text(expected.get("known_hosts_file"))
    if identity:
        command.extend(["-i", identity])
    if known_hosts:
        command.extend(["-o", f"UserKnownHostsFile={known_hosts}"])
    remote_argv = [
        "python3",
        "-",
        expected["http_domain"],
        expected["vip"],
        str(timeout),
        str(MAX_HTTP_BODY_BYTES),
    ]
    command.extend([f"{user}@{host}", shlex.join(remote_argv)])
    result = _run_json(command, input_text=CLIENT_PROBE, timeout=timeout + 10)
    if not isinstance(result, dict):
        raise ValueError("independent client returned a non-object probe")
    return result


def collect_verification(configuration: object) -> dict[str, Any]:
    config = _validate_config(configuration)
    source = _mapping(config["source"])
    source_directory = pathlib.Path(_text(source.get("directory", "."))).resolve()
    actual_source = {
        "ref": _run(
            ["git", "symbolic-ref", "HEAD"], cwd=source_directory
        ).stdout.strip(),
        "commit_sha": _run(
            ["git", "rev-parse", "HEAD"], cwd=source_directory
        ).stdout.strip(),
        "clean": not bool(
            _run(
                ["git", "status", "--porcelain", "--untracked-files=no"],
                cwd=source_directory,
            ).stdout.strip()
        ),
    }
    plan = _mapping(config["plan"])
    plan_path = pathlib.Path(_text(plan.get("path"))).resolve()
    preflight_path = pathlib.Path(_text(plan.get("preflight_receipt"))).resolve()
    if not plan_path.is_file() or not preflight_path.is_file():
        raise ValueError("saved plan or preflight receipt is unavailable")
    with preflight_path.open(encoding="utf-8") as stream:
        preflight = json.load(stream)
    actual_plan = {
        "sha256": _digest_file(plan_path),
        "preflight_schema": _mapping(preflight).get("schema_version"),
        "preflight_bound": (
            _mapping(preflight).get("plan_sha256") == plan["sha256"]
            and _mapping(preflight).get("source_ref") == source["ref"]
            and _mapping(preflight).get("source_commit_sha") == source["commit_sha"]
            and _mapping(preflight).get("stage") == "configured"
        ),
    }
    xc, terraform_result = _terraform_observation(config)
    if (
        xc.get("provenance_ref") != source["ref"]
        or xc.get("provenance_commit") != source["commit_sha"]
    ):
        actual_source = {
            "ref": "state-provenance-mismatch",
            "commit_sha": "",
            "clean": actual_source["clean"],
        }
    return {
        "schema_version": OBSERVATION_SCHEMA,
        "source": actual_source,
        "plan": actual_plan,
        "host": _network_inventory(),
        "vm": _vm_observation(_mapping(config["vm"])),
        "xc": xc,
        "frr": _frr_observation(_mapping(config["frr"])),
        "client": _client_observation(_mapping(config["client"])),
        "terraform": terraform_result,
    }


def write_receipt(path: pathlib.Path, receipt: object) -> None:
    """Atomically create one mode-0600 receipt without replacing stale evidence."""
    target = path.resolve()
    if target.exists():
        raise FileExistsError(f"receipt already exists: {target}")
    if not target.parent.is_dir():
        raise FileNotFoundError("receipt directory does not exist")
    handle, temporary_name = tempfile.mkstemp(
        prefix=".kvm-lan-live-", dir=target.parent
    )
    temporary = pathlib.Path(temporary_name)
    try:
        os.fchmod(handle, stat.S_IRUSR | stat.S_IWUSR)
        with os.fdopen(handle, "w", encoding="utf-8") as stream:
            json.dump(receipt, stream, sort_keys=True, separators=(",", ":"))
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.link(temporary, target)
        directory_fd = os.open(target.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
    finally:
        temporary.unlink(missing_ok=True)


def _load_json(path: pathlib.Path) -> object:
    with path.open(encoding="utf-8") as stream:
        return json.load(stream)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mode", choices=("inventory", "verify"), default="inventory")
    parser.add_argument("--config", type=pathlib.Path)
    parser.add_argument("--observations", type=pathlib.Path)
    parser.add_argument("--receipt", type=pathlib.Path, required=True)
    args = parser.parse_args()
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    receipt_path = args.receipt.resolve()
    try:
        if receipt_path.is_relative_to(repo_root):
            raise ValueError("receipt must be outside the repository")
        if args.mode == "inventory":
            observed = (
                _load_json(args.observations)
                if args.observations
                else collect_inventory()
            )
            receipt = inventory_receipt(observed)
        else:
            if args.config is None:
                raise ValueError("--config is required for verification")
            configuration = _load_json(args.config)
            observed = (
                _load_json(args.observations)
                if args.observations
                else collect_verification(configuration)
            )
            receipt = evaluate(configuration, observed)
        write_receipt(receipt_path, receipt)
        json.dump(
            {
                "schema_version": RECEIPT_SCHEMA,
                "status": receipt["status"],
                "receipt": str(receipt_path),
            },
            sys.stdout,
            sort_keys=True,
            separators=(",", ":"),
        )
        sys.stdout.write("\n")
        return 0 if receipt["status"] == "passed" else 2
    except (
        FileExistsError,
        FileNotFoundError,
        json.JSONDecodeError,
        OSError,
        subprocess.SubprocessError,
        ValueError,
        RuntimeError,
    ) as error:
        failure = {
            "schema_version": RECEIPT_SCHEMA,
            "status": "failed",
            "checks": [
                {
                    "id": "collection",
                    "status": "failed",
                    "detail": "read-only evidence collection or validation failed",
                }
            ],
            "error_type": type(error).__name__,
        }
        try:
            if not receipt_path.exists() and not receipt_path.is_relative_to(repo_root):
                write_receipt(receipt_path, failure)
        except (FileExistsError, FileNotFoundError, OSError):
            pass
        json.dump(
            {
                "schema_version": RECEIPT_SCHEMA,
                "status": "failed",
                "receipt": str(receipt_path) if receipt_path.exists() else None,
            },
            sys.stdout,
            sort_keys=True,
            separators=(",", ":"),
        )
        sys.stdout.write("\n")
        sys.stderr.write(f"KVM LAN live acceptance failed: {type(error).__name__}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
