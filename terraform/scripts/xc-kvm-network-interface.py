#!/usr/bin/env python3
"""Resolve one Terraform-owned KVM CE MAC to its realized XC interface object."""

from __future__ import annotations

import json
import hashlib
import hmac
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class DiscoveryPending(Exception):
    """The owned interface is not yet uniquely observable."""


def _mapping(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _items(value: object) -> list[object]:
    return value if isinstance(value, list) else []


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _mac(value: object) -> str:
    candidate = _text(value).lower().replace("-", ":")
    if not re.fullmatch(r"[0-9a-f]{2}(?::[0-9a-f]{2}){5}", candidate):
        raise ValueError("expected_mac must be a six-octet MAC address")
    return candidate


def resolve_interface(
    namespace: str,
    site_name: str,
    expected_mac: str,
    site: dict[str, object],
    registrations: dict[str, object],
    interfaces: dict[str, object],
) -> dict[str, str]:
    """Require a unique site-owner -> node -> device -> MAC correlation."""
    site_uid = _text(_mapping(site.get("system_metadata")).get("uid"))
    if not site_uid:
        raise DiscoveryPending("the Secure Mesh v2 site UID is not available")

    registration_matches: list[tuple[str, str]] = []
    for raw_registration in _items(registrations.get("items")):
        registration = _mapping(raw_registration)
        infra = _mapping(_mapping(registration.get("get_spec")).get("infra"))
        if _text(infra.get("provider")).upper() != "KVM":
            continue
        hostname = _text(infra.get("hostname"))
        if not hostname:
            continue
        hardware = _mapping(infra.get("hw_info"))
        for raw_network in _items(hardware.get("network")):
            network = _mapping(raw_network)
            try:
                observed_mac = _mac(network.get("mac_address"))
            except ValueError:
                continue
            if observed_mac == expected_mac:
                device = _text(network.get("name"))
                if device:
                    registration_matches.append((hostname, device))

    if len(registration_matches) != 1:
        raise DiscoveryPending(
            f"expected one KVM registration interface for the owned MAC; observed {len(registration_matches)}"
        )
    hostname, device = registration_matches[0]

    object_matches: list[str] = []
    for raw_interface in _items(interfaces.get("items")):
        interface = _mapping(raw_interface)
        owner = _mapping(interface.get("owner_view"))
        if not owner:
            owner = _mapping(_mapping(interface.get("system_metadata")).get("owner_view"))
        if (
            _text(owner.get("kind")) != "securemesh_site_v2"
            or _text(owner.get("name")) != site_name
            or _text(owner.get("namespace")) != namespace
            or _text(owner.get("uid")) != site_uid
        ):
            continue
        ethernet = _mapping(_mapping(interface.get("get_spec")).get("ethernet_interface"))
        if _text(ethernet.get("node")) != hostname or _text(ethernet.get("device")) != device:
            continue
        if "site_local_network" not in ethernet or "site_local_inside_network" in ethernet:
            continue
        name = _text(interface.get("name"))
        if _text(interface.get("namespace")) == namespace and name:
            object_matches.append(name)

    if len(object_matches) != 1:
        raise DiscoveryPending(
            f"expected one owned SLO network_interface for the observed node and device; observed {len(object_matches)}"
        )
    return {
        "interface_name": object_matches[0],
        "hostname": hostname,
        "device": device,
        "mac": expected_mac,
    }


def _get_json(api_url: str, path: str, token: str) -> dict[str, object]:
    request = urllib.request.Request(
        api_url + path,
        headers={
            "Accept": "application/json",
            "Authorization": "APIToken " + token,
            "Connection": "close",
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        payload = response.read().decode("utf-8", errors="strict")
    value = json.loads(payload, strict=False)
    if not isinstance(value, dict):
        raise ValueError("XC returned a non-object JSON document")
    return value


def _validated_query() -> tuple[str, str, str, str, int, float]:
    query = json.load(sys.stdin)
    if not isinstance(query, dict):
        raise ValueError("external query must be a JSON object")
    api_url = _text(query.get("api_url")).rstrip("/")
    parsed = urllib.parse.urlparse(api_url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.path or parsed.query or parsed.fragment:
        raise ValueError("api_url must be an HTTPS origin without a path")
    namespace = _text(query.get("namespace"))
    site_name = _text(query.get("site_name"))
    if namespace != "system" or not site_name:
        raise ValueError("namespace must be system and site_name must be non-empty")
    expected_mac = _mac(query.get("expected_mac"))
    timeout_seconds = int(_text(query.get("timeout_seconds")))
    poll_interval_seconds = float(_text(query.get("poll_interval_seconds")))
    if timeout_seconds < 1 or timeout_seconds > 7200 or poll_interval_seconds <= 0 or poll_interval_seconds > 60:
        raise ValueError("poll timing is outside the bounded discovery range")
    expected_hash = _text(query.get("resolver_sha256"))
    actual_hash = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash) or not hmac.compare_digest(expected_hash, actual_hash):
        raise ValueError("resolver script does not match the SHA-256 captured in the saved plan")
    return api_url, namespace, site_name, expected_mac, timeout_seconds, poll_interval_seconds


def main() -> int:
    try:
        api_url, namespace, site_name, expected_mac, timeout_seconds, poll_interval_seconds = _validated_query()
        token = os.environ.get("XCSH_API_TOKEN", "")
        if len(token) < 20:
            raise ValueError("XCSH_API_TOKEN is missing or unexpectedly short")
        quoted_namespace = urllib.parse.quote(namespace, safe="")
        quoted_site = urllib.parse.quote(site_name, safe="")
        paths = (
            f"/api/config/namespaces/{quoted_namespace}/securemesh_site_v2s/{quoted_site}",
            f"/api/register/namespaces/{quoted_namespace}/registrations_by_site/{quoted_site}",
            f"/api/config/namespaces/{quoted_namespace}/network_interfaces?report_fields=get_spec&report_fields=system_metadata",
        )
        deadline = time.monotonic() + timeout_seconds
        last_reason = "runtime objects are not yet visible"
        while True:
            try:
                documents = [_get_json(api_url, path, token) for path in paths]
                result = resolve_interface(namespace, site_name, expected_mac, *documents)
                json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
                sys.stdout.write("\n")
                return 0
            except DiscoveryPending as error:
                last_reason = str(error)
            except urllib.error.HTTPError as error:
                last_reason = f"XC returned HTTP {error.code} while runtime objects were being discovered"
            except (urllib.error.URLError, TimeoutError):
                last_reason = "XC transport was unavailable while runtime objects were being discovered"
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                last_reason = "XC returned an invalid runtime observation"
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(last_reason)
            time.sleep(min(poll_interval_seconds, remaining))
    except Exception as error:  # external provider requires a concise stderr failure
        print(f"KVM interface discovery failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
