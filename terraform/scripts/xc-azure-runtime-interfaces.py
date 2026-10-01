"""Read current physical Azure CE NIC identities for Terraform."""

# pylint: disable=invalid-name,no-else-return
# ruff: noqa: EM101, INP001, TRY003, TRY004, TRY301
from __future__ import annotations

import hashlib
import hmac
import json
import os
import pathlib
import re
import sys
import urllib.parse
import urllib.request

NIC_COUNT = 3
MIN_TOKEN_LENGTH = 20


def normalize_mac(value: object) -> str:
    """Normalize a valid physical MAC without accepting a placeholder."""
    if not isinstance(value, str):
        raise ValueError("Physical NIC MAC is missing")
    mac = value.lower().replace("-", ":")
    if not re.fullmatch(r"(?:[0-9a-f]{2}:){5}[0-9a-f]{2}", mac):
        raise ValueError("Physical NIC MAC is malformed")
    return mac


def resolve_interfaces(
    health: dict, hostname: str, role_macs: dict
) -> list[dict[str, str]]:
    """Join current physical devices to exactly three owned Azure NIC MACs."""
    if health.get("state") != "PROVISIONED" or health.get("hostname") != hostname:
        raise ValueError("Runtime health does not identify the provisioned owned node")
    owned = {role: normalize_mac(mac) for role, mac in role_macs.items()}
    if (
        set(owned) != {"slo", "sli", "external"}
        or len(set(owned.values())) != NIC_COUNT
    ):
        raise ValueError("Expected three distinct owned Azure NIC MACs")
    network = health.get("os_info", {}).get("network")
    if not isinstance(network, list):
        raise ValueError("Runtime physical network observations are missing")
    result = []
    for nic in network:
        if not isinstance(nic, dict):
            raise ValueError("Runtime NIC observation is malformed")
        name = nic.get("name", "")
        if not isinstance(name, str) or not re.fullmatch(r"(?:a-i-)?eth[0-2]", name):
            continue
        mac = normalize_mac(nic.get("mac_address"))
        if mac in owned.values():
            result.append({"device": name.removeprefix("a-i-"), "mac": mac})
    if (
        len(result) != NIC_COUNT
        or {row["mac"] for row in result} != set(owned.values())
        or {row["device"] for row in result} != {"eth0", "eth1", "eth2"}
        or next(row["device"] for row in result if row["mac"] == owned["slo"]) != "eth0"
    ):
        raise ValueError("Runtime NICs do not map one-to-one to owned Azure devices")
    return sorted(result, key=lambda row: row["device"])


def main() -> int:
    """Emit string-valued, credential-free Terraform external data."""
    try:
        query = json.load(sys.stdin)
        digest = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
        if not hmac.compare_digest(query["observer_sha256"], digest):
            raise ValueError("Runtime observer differs from the saved-plan digest")
        url = query["api_url"].rstrip("/")
        parsed = urllib.parse.urlparse(url)
        if (
            parsed.scheme != "https"
            or not parsed.hostname
            or any(
                (
                    parsed.path,
                    parsed.query,
                    parsed.fragment,
                    parsed.username,
                    parsed.password,
                )
            )
        ):
            raise ValueError("Runtime API URL must be an HTTPS origin")
        token = os.environ.get("XCSH_API_TOKEN", "")
        if len(token) < MIN_TOKEN_LENGTH:
            raise ValueError("Runtime API credential is unavailable")
        site = urllib.parse.quote(query["site_name"], safe="")
        request = urllib.request.Request(  # noqa: S310 -- validated HTTPS origin.
            url
            + f"/api/operate/namespaces/system/sites/{site}/vpm/debug/global/health",
            headers={
                "Accept": "application/json",
                "Authorization": "APIToken " + token,
            },
        )
        with urllib.request.urlopen(request, timeout=30) as response:  # noqa: S310
            health = json.load(response)
        result = resolve_interfaces(
            health, query["hostname"], json.loads(query["role_macs"])
        )
        json.dump({"network": json.dumps(result)}, sys.stdout)
        sys.stdout.write("\n")
    except (OSError, ValueError, TypeError, KeyError, StopIteration):
        sys.stderr.write(
            "Azure runtime NIC observation failed; no stale fallback allowed\n"
        )
        return 1
    else:
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
