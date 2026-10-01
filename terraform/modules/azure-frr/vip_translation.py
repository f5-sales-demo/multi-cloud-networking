"""Converge one regional VIP translation from active CE-learned BGP paths."""

# ruff: noqa: EM101, INP001, TRY003, TRY004
from __future__ import annotations

import argparse
import ipaddress
import json
import pathlib
import subprocess

CHAIN = "MCN_VIP"
HTTP_PORT = "80"


def eligible_backends(document: dict, vip: str, ce_ips: list[str]) -> list[str]:
    """Require exact VIP identity and a valid active path from an owned CE."""
    if not document:
        return []
    if document.get("prefix") != vip:
        raise ValueError("BGP response does not describe the regional VIP")
    paths = document.get("paths")
    if not isinstance(paths, list):
        raise ValueError("BGP paths are malformed")
    result = set()
    for path in paths:
        if not isinstance(path, dict):
            raise ValueError("BGP path is malformed")
        peer = path.get("peer", {})
        hops = path.get("nexthops")
        if not isinstance(peer, dict) or not isinstance(hops, list):
            raise ValueError("BGP peer or next hops are malformed")
        if path.get("valid") is not True or peer.get("peerId") not in ce_ips:
            continue
        for hop in hops:
            if not isinstance(hop, dict):
                raise ValueError("BGP next hop is malformed")
            if (
                hop.get("accessible") is True
                and hop.get("used") is True
                and hop.get("ip") == peer["peerId"]
            ):
                result.add(hop["ip"])
    return sorted(result)


def run(argv: list[str], *, check: bool = True) -> subprocess.CompletedProcess:
    """Run fixed local routing tools with bounded execution."""
    return subprocess.run(  # noqa: S603 -- fixed routing tools and validated IPv4 inputs.
        argv, capture_output=True, text=True, timeout=15, check=check
    )


def converge(vip: str, router_ip: str, ce_ips: list[str]) -> None:
    """Change only the demo HTTP NAT chain when its learned backend changes."""
    try:
        observation = json.loads(
            run(["vtysh", "-c", f"show bgp ipv4 unicast {vip}/32 json"]).stdout
        )
        eligible = eligible_backends(observation, vip + "/32", ce_ips)
    except (ValueError, subprocess.SubprocessError):
        eligible = []
    target = eligible[0] if eligible else None
    run(["iptables", "-t", "nat", "-N", CHAIN], check=False)
    jump = [
        "PREROUTING",
        "-d",
        vip + "/32",
        "-p",
        "tcp",
        "--dport",
        HTTP_PORT,
        "-j",
        CHAIN,
    ]
    if run(["iptables", "-t", "nat", "-C", *jump], check=False).returncode:
        run(["iptables", "-t", "nat", "-A", *jump])
    current = run(["iptables", "-t", "nat", "-S", CHAIN]).stdout
    expected = (
        f"-A {CHAIN} -p tcp -m tcp --dport {HTTP_PORT} "
        f"-j DNAT --to-destination {target}:{HTTP_PORT}"
        if target
        else None
    )
    rules = [line for line in current.splitlines() if line.startswith("-A ")]
    if rules != ([expected] if expected else []):
        run(["iptables", "-t", "nat", "-F", CHAIN])
        if target:
            run(
                [
                    "iptables",
                    "-t",
                    "nat",
                    "-A",
                    CHAIN,
                    "-p",
                    "tcp",
                    "--dport",
                    HTTP_PORT,
                    "-j",
                    "DNAT",
                    "--to-destination",
                    target + ":" + HTTP_PORT,
                ]
            )
    # Keep translated responses on their originating FRR, even if CE routing
    # later gains another route to the client network.
    for ip in ce_ips:
        rule = [
            "POSTROUTING",
            "-d",
            ip + "/32",
            "-p",
            "tcp",
            "--dport",
            HTTP_PORT,
            "-j",
            "SNAT",
            "--to-source",
            router_ip,
        ]
        if run(["iptables", "-t", "nat", "-C", *rule], check=False).returncode:
            run(["iptables", "-t", "nat", "-A", *rule])
    pathlib.Path("/run/mcn-vip-translation.json").write_text(
        json.dumps({"vip": vip, "eligible_ce_count": len(eligible), "backend": target})
    )


def main() -> None:
    """Validate installed demo inputs and converge its exact VIP."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--vip", required=True)
    parser.add_argument("--router-ip", required=True)
    parser.add_argument("--ce-ips", nargs="+", required=True)
    args = parser.parse_args()
    for address in [args.vip, args.router_ip, *args.ce_ips]:
        ipaddress.IPv4Address(address)
    converge(args.vip, args.router_ip, args.ce_ips)


if __name__ == "__main__":
    main()
