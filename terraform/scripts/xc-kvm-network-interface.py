"""Resolve one Terraform-owned KVM CE MAC to its realized XC interface object."""
# pylint: disable=invalid-name

from __future__ import annotations

import hashlib
import hmac
import json
import os
import pathlib
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

HTTP_TIMEOUT_SECONDS = 30
MAX_DISCOVERY_TIMEOUT_SECONDS = 7200
MAX_POLL_INTERVAL_SECONDS = 60
MIN_TOKEN_LENGTH = 20


class DiscoveryPendingError(Exception):
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
        message = "expected_mac must be a six-octet MAC address"
        raise ValueError(message)
    return candidate


# The correlation intentionally validates several nested XC runtime documents.
# pylint: disable=too-many-locals,too-many-branches
def resolve_interface(
    namespace: str,
    site_name: str,
    expected_mac: str,
    role: str,
    site: dict[str, object],
    registrations: dict[str, object],
    interfaces: dict[str, object],
) -> dict[str, str]:
    """Require a unique site-owner -> node -> device -> MAC correlation."""
    if role not in {"slo", "sli"}:
        message = "role must be slo or sli"
        raise ValueError(message)
    required_network_key = (
        "site_local_network" if role == "slo" else "site_local_inside_network"
    )
    forbidden_network_key = (
        "site_local_inside_network" if role == "slo" else "site_local_network"
    )
    site_uid = _text(_mapping(site.get("system_metadata")).get("uid"))
    if not site_uid:
        message = "the Secure Mesh v2 site UID is not available"
        raise DiscoveryPendingError(message)

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
        message = (
            "expected one KVM registration interface for the owned MAC; "
            f"observed {len(registration_matches)}"
        )
        raise DiscoveryPendingError(message)
    hostname, device = registration_matches[0]

    object_matches: list[str] = []
    for raw_interface in _items(interfaces.get("items")):
        interface = _mapping(raw_interface)
        owner = _mapping(interface.get("owner_view"))
        if not owner:
            owner = _mapping(
                _mapping(interface.get("system_metadata")).get("owner_view")
            )
        if (
            _text(owner.get("kind")) != "securemesh_site_v2"
            or _text(owner.get("name")) != site_name
            or _text(owner.get("namespace")) != namespace
            or _text(owner.get("uid")) != site_uid
        ):
            continue
        ethernet = _mapping(
            _mapping(interface.get("get_spec")).get("ethernet_interface")
        )
        if (
            _text(ethernet.get("node")) != hostname
            or _text(ethernet.get("device")) != device
        ):
            continue
        if required_network_key not in ethernet or forbidden_network_key in ethernet:
            continue
        name = _text(interface.get("name"))
        if _text(interface.get("namespace")) == namespace and name:
            object_matches.append(name)

    if len(object_matches) != 1:
        message = (
            f"expected one owned {role.upper()} network_interface for the observed node and device; "
            f"observed {len(object_matches)}"
        )
        raise DiscoveryPendingError(message)
    return {
        "interface_name": object_matches[0],
        "hostname": hostname,
        "device": device,
        "mac": expected_mac,
        "role": role,
    }


def _get_json(api_url: str, path: str, token: str) -> dict[str, object]:
    request = urllib.request.Request(  # noqa: S310 -- HTTPS origin is validated.
        api_url + path,
        headers={
            "Accept": "application/json",
            "Authorization": "APIToken " + token,
            "Connection": "close",
        },
        method="GET",
    )
    with urllib.request.urlopen(  # noqa: S310 -- request URL is HTTPS.
        request, timeout=HTTP_TIMEOUT_SECONDS
    ) as response:
        payload = response.read().decode("utf-8", errors="strict")
    value = json.loads(payload, strict=False)
    if not isinstance(value, dict):
        message = "XC returned a non-object JSON document"
        raise TypeError(message)
    return value


def _validated_query() -> tuple[str, str, str, str, str, int, float]:
    query = json.load(sys.stdin)
    if not isinstance(query, dict):
        message = "external query must be a JSON object"
        raise TypeError(message)
    api_url = _text(query.get("api_url")).rstrip("/")
    parsed = urllib.parse.urlparse(api_url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        message = "api_url must be an HTTPS origin without a path"
        raise ValueError(message)
    namespace = _text(query.get("namespace"))
    site_name = _text(query.get("site_name"))
    if namespace != "system" or not site_name:
        message = "namespace must be system and site_name must be non-empty"
        raise ValueError(message)
    expected_mac = _mac(query.get("expected_mac"))
    role = _text(query.get("role"))
    if role not in {"slo", "sli"}:
        message = "role must be slo or sli"
        raise ValueError(message)
    timeout_seconds = int(_text(query.get("timeout_seconds")))
    poll_interval_seconds = float(_text(query.get("poll_interval_seconds")))
    if (
        timeout_seconds < 1
        or timeout_seconds > MAX_DISCOVERY_TIMEOUT_SECONDS
        or poll_interval_seconds <= 0
        or poll_interval_seconds > MAX_POLL_INTERVAL_SECONDS
    ):
        message = "poll timing is outside the bounded discovery range"
        raise ValueError(message)
    expected_hash = _text(query.get("resolver_sha256"))
    actual_hash = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
    hash_matches = hmac.compare_digest(expected_hash, actual_hash)
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash) or not hash_matches:
        message = "resolver script does not match the saved-plan SHA-256"
        raise ValueError(message)
    return (
        api_url,
        namespace,
        site_name,
        expected_mac,
        role,
        timeout_seconds,
        poll_interval_seconds,
    )


def _api_token() -> str:
    token = os.environ.get("XCSH_API_TOKEN", "")
    if len(token) < MIN_TOKEN_LENGTH:
        message = "XCSH_API_TOKEN is missing or unexpectedly short"
        raise ValueError(message)
    return token


def _raise_timeout(reason: str) -> None:
    raise TimeoutError(reason)


def main() -> int:
    """Resolve and emit the owned interface for Terraform external data."""
    try:
        (
            api_url,
            namespace,
            site_name,
            expected_mac,
            role,
            timeout_seconds,
            poll_interval_seconds,
        ) = _validated_query()
        token = _api_token()
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
                result = resolve_interface(
                    namespace, site_name, expected_mac, role, *documents
                )
            except DiscoveryPendingError as error:
                last_reason = str(error)
            except urllib.error.HTTPError as error:
                last_reason = f"XC returned HTTP {error.code} while runtime objects were being discovered"
            except (urllib.error.URLError, TimeoutError):
                last_reason = "XC transport was unavailable while runtime objects were being discovered"
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                last_reason = "XC returned an invalid runtime observation"
            else:
                json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
                sys.stdout.write("\n")
                return 0
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                _raise_timeout(last_reason)
            time.sleep(min(poll_interval_seconds, remaining))
    except (OSError, TypeError, ValueError) as error:
        sys.stderr.write(f"KVM interface discovery failed: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
