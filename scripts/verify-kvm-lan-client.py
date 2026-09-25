#!/usr/bin/env python3
"""Prove the Terraform KVM CE serves its inside VIP to the physical LAN client."""

from __future__ import annotations

import argparse
import ipaddress
import json
import pathlib
import re
import shlex
import subprocess
import sys
from datetime import datetime, timezone


def run(argv: list[str], timeout: int = 30) -> str:
    result = subprocess.run(argv, text=True, capture_output=True, timeout=timeout, check=True)
    return result.stdout.strip()


def remote(host: str, argv: list[str], timeout: int = 30) -> str:
    return run(["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", host, shlex.join(argv)], timeout)


def output(terraform_dir: pathlib.Path, name: str) -> object:
    return json.loads(run(["terraform", f"-chdir={terraform_dir}", "output", "-json", name]))


def check(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-dir", type=pathlib.Path, required=True)
    parser.add_argument("--evidence-dir", type=pathlib.Path, required=True)
    parser.add_argument("--client-host", default="NUC")
    parser.add_argument("--client-interface", default="xckvmlan")
    parser.add_argument("--client-ip", default="10.201.0.2")
    parser.add_argument("--source-commit", required=True)
    args = parser.parse_args()
    check(re.fullmatch(r"[0-9a-f]{40}", args.source_commit) is not None, "invalid source commit")
    check(re.fullmatch(r"[a-zA-Z0-9_.-]+", args.client_host) is not None, "invalid client host")
    check(re.fullmatch(r"[a-zA-Z0-9_.-]+", args.client_interface) is not None, "invalid client interface")
    client_ip = ipaddress.ip_address(args.client_ip)
    args.evidence_dir.mkdir(parents=True, exist_ok=False, mode=0o700)

    contract = output(args.terraform_dir, "kvm_lan_contract")
    status = output(args.terraform_dir, "kvm_runtime_status")
    check(isinstance(contract, dict) and contract.get("phase") == "configured", "KVM LAN is not configured")
    check(status == {
        "registration_count": 1, "online_count": 1, "mapping_valid": True,
        "bgp_converged": True, "bgp_session_count": 1,
    }, "KVM registration or BGP is unhealthy")
    check(contract.get("bridge") == "br-kvm-lan" and contract.get("uplink") == "enp3s0", "shared bridge/uplink identity changed")
    check(contract.get("observed_slo") and contract.get("realized_sli") and
          contract["observed_slo"] != contract["realized_sli"], "SLO and SLI identities are not distinct")
    check(contract.get("observed_sli") == contract.get("realized_sli"), "provider SLI identity is inconsistent")
    vip = ipaddress.ip_address(contract["vip"])
    origin = ipaddress.ip_address(contract["backend_ip"])
    domain = contract["http_domain"]
    port = contract["backend_port"]
    check(re.fullmatch(r"[a-z0-9.-]+", domain) is not None, "invalid application domain")
    check(isinstance(port, int) and 1 <= port <= 65535, "invalid origin port")

    host_addr = json.loads(run(["ip", "-j", "address", "show", "dev", contract["bridge"]]))
    check(host_addr and host_addr[0].get("operstate") == "UP", "Ubuntu shared bridge is down")
    check("enp3s0" in run(["nmcli", "-g", "GENERAL.DEVICES", "connection", "show", "br-kvm-lan-uplink"]),
          "Ubuntu shared uplink ownership changed")

    hostname = remote(args.client_host, ["hostname"])
    check(hostname == "nuc", "independent client identity changed")
    route_before = remote(args.client_host, ["ip", "-4", "route", "show", "default"])
    client_addrs = remote(args.client_host, ["ip", "-4", "addr", "show", "dev", args.client_interface])
    check(f"inet {client_ip}/24" in client_addrs, "independent client LAN allocation is missing")
    route_to_vip = remote(args.client_host, ["ip", "route", "get", str(vip)])
    check(f"dev {args.client_interface}" in route_to_vip and f"src {client_ip}" in route_to_vip,
          "VIP path does not use the independent physical LAN client")
    dns = remote(args.client_host, ["getent", "ahostsv4", domain])
    check(any(line.split()[0] == str(vip) for line in dns.splitlines()), "private application DNS does not resolve to the VIP")
    origin_body = remote(args.client_host, ["curl", "-fsS", "--max-time", "15", f"http://{origin}:{port}/"], 25)
    check("mcn-kvm-lan-origin" in origin_body, "Terraform-owned physical LAN origin marker is missing")
    for _ in range(10):
        body = remote(args.client_host, ["curl", "-fsS", "--max-time", "15", "--resolve", f"{domain}:80:{vip}", f"http://{domain}/"], 25)
        check("mcn-kvm-lan-origin" in body, "KVM inside VIP did not serve the owned origin")
    route_after = remote(args.client_host, ["ip", "-4", "route", "show", "default"])
    check(route_before == route_after, "independent client default route changed during verification")
    receipt = {
        "schema": "mcn.kvm-lan-client-receipt/v1",
        "source_commit": args.source_commit,
        "checked_at": datetime.now(timezone.utc).isoformat(),
        "site_name": contract["site_name"],
        "client_hostname": hostname,
        "client_interface": args.client_interface,
        "bridge": contract["bridge"],
        "uplink": contract["uplink"],
        "slo_sli_distinct": True,
        "registration_online": True,
        "bgp_converged": True,
        "private_dns_resolved": True,
        "origin_marker_seen": True,
        "vip_http_samples": 10,
        "default_route_preserved": True,
    }
    (args.evidence_dir / "summary.json").write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n")
    print("KVM LAN client: online=1 bgp=1 origin=1 vip_http=10/10 default_route=preserved")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired, json.JSONDecodeError) as exc:
        print(f"verify-kvm-lan-client: {exc}", file=sys.stderr)
        sys.exit(2)
