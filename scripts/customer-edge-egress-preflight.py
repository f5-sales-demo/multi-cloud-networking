#!/usr/bin/env python3
"""Check the release-pinned CE DNS, NTP, and HTTPS egress contract."""
# pylint: disable=invalid-name,missing-function-docstring
# ruff: noqa: D103, TRY003, EM101, EM102, PLR2004

from __future__ import annotations

import argparse
import json
import secrets
import socket
import sys
from pathlib import Path
from typing import Any

CRITICAL_HTTPS = (
    "register.ves.volterra.io",
    "register-tls.ves.volterra.io",
    "downloads.volterra.io",
)


def requirements_from_plan(document: dict[str, Any]) -> dict[str, Any]:
    outputs = document.get("planned_values", {}).get("outputs", {})
    result = outputs.get("requirements", {}).get("value")
    if not isinstance(result, dict) or result.get("api_release_tag") != "v8.0.2":
        raise ValueError("CE allowlist is not the published v8.0.2 data set")
    expected = {
        "dns": ("egress", 53, ["udp", "tcp"]),
        "ntp": ("egress", 123, ["udp"]),
        "https": ("egress", 443, ["tcp"]),
    }
    for name, (direction, port, protocols) in expected.items():
        item = result.get(name)
        if not isinstance(item, dict) or not item.get("destinations"):
            raise ValueError(f"CE {name} egress destinations are missing")
        if (item.get("direction"), item.get("port"), item.get("protocols")) != (
            direction,
            port,
            protocols,
        ):
            raise ValueError(f"CE {name} protocol, port, or direction is invalid")
    if not set(CRITICAL_HTTPS).issubset(result["https"]["destinations"]):
        raise ValueError("CE registration and download HTTPS destinations are missing")
    return result


def dns_query(server: str, tcp: bool) -> None:
    # Standard A query for example.com, with a random transaction ID supplied
    # by the OS. A nonempty DNS response proves the configured transport path.
    ident = secrets.randbits(16).to_bytes(2, "big")
    query = (
        ident
        + b"\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00"
        + b"\x07example\x03com\x00\x00\x01\x00\x01"
    )
    if tcp:
        with socket.create_connection((server, 53), timeout=4) as conn:
            conn.sendall(len(query).to_bytes(2, "big") + query)
            header = conn.recv(2)
            if len(header) != 2:
                raise OSError("short DNS TCP response")
            response = conn.recv(int.from_bytes(header, "big"))
    else:
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as conn:
            conn.settimeout(4)
            conn.sendto(query, (server, 53))
            response, _ = conn.recvfrom(4096)
    if len(response) < 12 or response[:2] != ident or response[2] & 0x80 == 0:
        raise OSError("invalid DNS response")


def ntp_query(server: str) -> None:
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as conn:
        conn.settimeout(4)
        conn.sendto(b"\x1b" + b"\x00" * 47, (server, 123))
        response, _ = conn.recvfrom(512)
    if len(response) < 48 or (response[0] >> 6) != 0:
        raise OSError("invalid NTP response")


def https_connect(host: str) -> None:
    # This checks TCP/443 egress. TLS identity is verified during live CE traffic,
    # where service policy and corporate interceptors are in the actual path.
    with socket.create_connection((host, 443), timeout=6):
        pass


def probe(requirements: dict[str, Any]) -> list[dict[str, Any]]:
    checks: list[dict[str, Any]] = []
    # Every published default DNS/NTP endpoint is a firewall destination, so
    # test each one. HTTPS has region-specific endpoints; the critical global
    # registration/download endpoints are tested here and regional traffic is
    # checked later from the deployed Azure client VMs.
    for server in requirements["dns"]["destinations"]:
        for protocol in ("udp", "tcp"):
            dns_query(server, protocol == "tcp")
            checks.append(
                {
                    "service": "dns",
                    "protocol": protocol,
                    "port": 53,
                    "destination": server,
                    "status": "passed",
                }
            )
    for server in requirements["ntp"]["destinations"]:
        ntp_query(server)
        checks.append(
            {
                "service": "ntp",
                "protocol": "udp",
                "port": 123,
                "destination": server,
                "status": "passed",
            }
        )
    for host in CRITICAL_HTTPS:
        https_connect(host)
        checks.append(
            {
                "service": "https",
                "protocol": "tcp",
                "port": 443,
                "destination": host,
                "status": "passed",
            }
        )
    return checks


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan-json", required=True)
    parser.add_argument("--probe", action="store_true")
    args = parser.parse_args()
    with Path(args.plan_json).open(encoding="utf-8") as stream:
        requirements = requirements_from_plan(json.load(stream))
    checks = probe(requirements) if args.probe else []
    print(
        json.dumps(
            {
                "schema": "mcn.ce-egress-preflight/v1",
                "api_release_tag": "v8.0.2",
                "checks": checks,
                "status": "passed",
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, OSError, TimeoutError) as exc:
        print(f"ce-egress-preflight: {exc}", file=sys.stderr)
        sys.exit(2)
