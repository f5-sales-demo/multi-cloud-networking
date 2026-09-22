"""Observe one exact KVM CE BGP session without asserting exported routes."""
# pylint: disable=invalid-name,too-many-branches,too-many-locals,too-many-statements
# ruff: noqa: EM101, EM102, INP001, TRY003, TRY004

from __future__ import annotations

import hashlib
import hmac
import ipaddress
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
MAX_OBSERVATION_TIMEOUT_SECONDS = 1800
MAX_POLL_INTERVAL_SECONDS = 60
MIN_TOKEN_LENGTH = 20


class ObservationPendingError(Exception):
    """The expected BGP session has not converged yet."""


def _mapping(value: object) -> dict[str, object]:
    return value if isinstance(value, dict) else {}


def _text(value: object) -> str:
    return value.strip() if isinstance(value, str) else ""


def _node_matches(expected: str, observed: str) -> bool:
    return bool(expected) and (
        observed == expected or observed.startswith(expected + ".")
    )


def _ip(value: object) -> str:
    if isinstance(value, str):
        candidate = value.strip()
    else:
        address = _mapping(value)
        candidate = ""
        for family in ("ipv4", "ipv6"):
            nested = address.get(family)
            if isinstance(nested, str):
                candidate = nested.strip()
            elif isinstance(nested, dict):
                candidate = _text(nested.get("addr"))
            if candidate:
                break
    try:
        return str(ipaddress.ip_address(candidate))
    except ValueError as error:
        raise ValueError("BGP observation contains an invalid peer address") from error


def _integer(value: object, field: str) -> str:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"BGP peer {field} is malformed")
    integer = int(value)
    if integer < 0 or integer != value:
        raise ValueError(f"BGP peer {field} is malformed")
    return str(integer)


def resolve_bgp_observation(
    expected_node: str,
    expected_peer_address: str,
    expected_imported_route: str,
    peers: dict[str, object],
    routes: dict[str, object],
) -> dict[str, str]:
    """Require one Established peer and its exact imported route path."""
    raw_nodes = peers.get("ver")
    if not isinstance(raw_nodes, list):
        raise ValueError("BGP peer response has no ver observations")
    matches: list[dict[str, object]] = []
    observed_node = ""
    for raw_node in raw_nodes:
        if not isinstance(raw_node, dict):
            raise ValueError("BGP node observation is malformed")
        node = _text(raw_node.get("name"))
        if not node:
            raise ValueError("BGP node observation has no name")
        raw_peers = raw_node.get("peer")
        if not isinstance(raw_peers, list):
            raise ValueError("BGP node peer observations are malformed")
        for raw_peer in raw_peers:
            if not isinstance(raw_peer, dict):
                raise ValueError("BGP peer observation is malformed")
            address = _ip(raw_peer.get("peer_address"))
            if _node_matches(expected_node, node) and address == expected_peer_address:
                matches.append(raw_peer)
                observed_node = node
    if len(matches) != 1:
        raise ObservationPendingError(
            f"expected registered node and peer resolved to {len(matches)} BGP observations"
        )
    peer = matches[0]
    state = _text(peer.get("protocol_status"))
    if state != "Established":
        raise ObservationPendingError(
            f"expected BGP peer state is {state or 'missing'}"
        )

    raw_route_nodes = routes.get("ver")
    if not isinstance(raw_route_nodes, list):
        raise ValueError("BGP route response has no ver observations")
    route_nodes = [
        node
        for node in raw_route_nodes
        if isinstance(node, dict)
        and _node_matches(expected_node, _text(node.get("name")))
    ]
    if len(route_nodes) != 1:
        raise ObservationPendingError(
            f"expected registered node resolved to {len(route_nodes)} BGP route observations"
        )
    matched_route = False
    routing_instances = route_nodes[0].get("ri_table")
    if not isinstance(routing_instances, list):
        raise ValueError("BGP route observation ri_table is malformed")
    for raw_instance in routing_instances:
        if not isinstance(raw_instance, dict):
            raise ValueError("BGP routing instance is malformed")
        tables = raw_instance.get("rt_table")
        if not isinstance(tables, list):
            raise ValueError("BGP route table collection is malformed")
        for raw_table in tables:
            if not isinstance(raw_table, dict):
                raise ValueError("BGP route table is malformed")
            imported = raw_table.get("imported")
            if not isinstance(imported, list):
                raise ValueError("BGP imported routes are malformed")
            for raw_route in imported:
                if not isinstance(raw_route, dict):
                    raise ValueError("BGP imported route is malformed")
                try:
                    subnet = str(
                        ipaddress.ip_network(
                            _text(raw_route.get("subnet")), strict=False
                        )
                    )
                except ValueError as error:
                    raise ValueError(
                        "BGP imported route has an invalid subnet"
                    ) from error
                paths = raw_route.get("path")
                if not isinstance(paths, list):
                    raise ValueError("BGP imported route paths are malformed")
                if subnet == expected_imported_route:
                    matched_route = any(
                        isinstance(path, dict)
                        and _ip(path.get("peer")) == expected_peer_address
                        for path in paths
                    )
                    if matched_route:
                        break
            if matched_route:
                break
        if matched_route:
            break
    if not matched_route:
        raise ObservationPendingError(
            "expected imported route has no path from the exact BGP peer"
        )
    return {
        "registered_node": expected_node,
        "observed_node": observed_node,
        "node": expected_node,
        "peer_address": expected_peer_address,
        "state": state,
        "state_changed_at": _text(peer.get("up_down_timestamp")),
        "received_prefix_count": _integer(
            peer.get("received_prefix_count"), "received_prefix_count"
        ),
        "advertised_prefix_count": _integer(
            peer.get("advertised_prefix_count"), "advertised_prefix_count"
        ),
        "imported_route": expected_imported_route,
        "converged": "true",
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
        raise TypeError("XC returned a non-object JSON document")
    return value


def _validated_query() -> tuple[str, str, str, str, str, str, int, float]:
    query = json.load(sys.stdin)
    if not isinstance(query, dict):
        raise TypeError("external query must be a JSON object")
    api_url = _text(query.get("api_url")).rstrip("/")
    parsed = urllib.parse.urlparse(api_url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.path
        or parsed.query
        or parsed.fragment
    ):
        raise ValueError("api_url must be an HTTPS origin without a path")
    namespace = _text(query.get("namespace"))
    site_name = _text(query.get("site_name"))
    expected_node = _text(query.get("expected_node"))
    if namespace != "system" or not site_name or not expected_node:
        raise ValueError("namespace, site_name, and expected_node are required")
    expected_peer = _ip(query.get("expected_peer_address"))
    try:
        expected_route = str(
            ipaddress.ip_network(
                _text(query.get("expected_imported_route")), strict=False
            )
        )
    except ValueError as error:
        raise ValueError("expected_imported_route must be a valid CIDR") from error
    timeout_seconds = int(_text(query.get("timeout_seconds")))
    poll_interval_seconds = float(_text(query.get("poll_interval_seconds")))
    if (
        timeout_seconds < 1
        or timeout_seconds > MAX_OBSERVATION_TIMEOUT_SECONDS
        or poll_interval_seconds <= 0
        or poll_interval_seconds > MAX_POLL_INTERVAL_SECONDS
    ):
        raise ValueError("poll timing is outside the bounded observation range")
    expected_hash = _text(query.get("observer_sha256"))
    actual_hash = hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest()
    if not re.fullmatch(r"[0-9a-f]{64}", expected_hash) or not hmac.compare_digest(
        expected_hash, actual_hash
    ):
        raise ValueError("observer script does not match the saved-plan SHA-256")
    return (
        api_url,
        namespace,
        site_name,
        expected_node,
        expected_peer,
        expected_route,
        timeout_seconds,
        poll_interval_seconds,
    )


def _api_token() -> str:
    token = os.environ.get("XCSH_API_TOKEN", "")
    if len(token) < MIN_TOKEN_LENGTH:
        raise ValueError("XCSH_API_TOKEN is missing or unexpectedly short")
    return token


def main() -> int:
    """Poll and emit one secret-free KVM BGP observation."""
    try:
        (
            api_url,
            namespace,
            site_name,
            expected_node,
            expected_peer,
            expected_route,
            timeout_seconds,
            poll_interval_seconds,
        ) = _validated_query()
        token = _api_token()
        quoted_namespace = urllib.parse.quote(namespace, safe="")
        quoted_site = urllib.parse.quote(site_name, safe="")
        paths = (
            f"/api/operate/namespaces/{quoted_namespace}/sites/{quoted_site}/ver/bgp_peers",
            f"/api/operate/namespaces/{quoted_namespace}/sites/{quoted_site}/ver/bgp_routes",
        )
        deadline = time.monotonic() + timeout_seconds
        last_reason = "BGP observations are not yet visible"
        while True:
            try:
                peers, routes = [_get_json(api_url, path, token) for path in paths]
                result = resolve_bgp_observation(
                    expected_node, expected_peer, expected_route, peers, routes
                )
            except ObservationPendingError as error:
                last_reason = str(error)
            except urllib.error.HTTPError as error:
                last_reason = f"XC returned HTTP {error.code} while BGP was observed"
            except (urllib.error.URLError, TimeoutError):
                last_reason = "XC transport was unavailable while BGP was observed"
            except (json.JSONDecodeError, UnicodeDecodeError, ValueError):
                last_reason = "XC returned an invalid BGP observation"
            else:
                json.dump(result, sys.stdout, sort_keys=True, separators=(",", ":"))
                sys.stdout.write("\n")
                return 0
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError(last_reason)
            time.sleep(min(poll_interval_seconds, remaining))
    except (OSError, TypeError, ValueError) as error:
        sys.stderr.write(f"KVM BGP observation failed: {error}\n")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
