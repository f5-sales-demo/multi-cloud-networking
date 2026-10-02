#!/usr/bin/env python3
"""Verify the Canadian public-IP binding, regional discovery and exact origin traffic."""

# pylint: disable=invalid-name
# ruff: noqa: EM101, TRY003
import argparse
import json
import os
import shutil
import subprocess
import urllib.request
from pathlib import Path
from typing import Any

LISTENER_COUNT = 7
ALLOWED_RE = {"tr2-tor", "mtl7-mon"}
SELECTOR = ["ves.io/region in (ves-io-toronto, ves-io-montreal)"]


def validate_configuration(config: dict[str, Any], objects: dict[str, Any]) -> None:
    """Reject a broader binding, advertisement, endpoint or discovery scope."""
    allocation = config["allocation"]
    public = objects["public_ip"]
    if public["spec"]["ip"] != allocation["ip"]:
        raise ValueError("allocated public IP identity differs")
    bindings = public["spec"].get("virtual_sites", [])
    if len(bindings) != 1 or (
        bindings[0].get("name"),
        bindings[0].get("namespace"),
    ) != (config["virtual_site"], config["re_namespace"]):
        raise ValueError("public IP is not exclusively bound to the Canadian selector")
    site = objects["virtual_site"]["spec"]
    if (
        site.get("site_type") != "REGIONAL_EDGE"
        or site.get("site_selector", {}).get("expressions") != SELECTOR
    ):
        raise ValueError("Canadian Regional Edge selector differs")
    if {item["name"] for item in objects["selectees"]["items"]} != ALLOWED_RE:
        raise ValueError("Regional Edge selectees must be exactly Toronto and Montreal")
    if {item["name"] for item in objects["ce_selectees"]["items"]} != set(
        config["ce_sites"]
    ):
        raise ValueError("origin discovery must select exactly the three Canadian CEs")
    lb = objects["loadbalancer"]["spec"]
    if lb.get("domains") != [config["domain"]] or not lb.get("add_location"):
        raise ValueError("Canadian load balancer domain or location receipt differs")
    ads = lb.get("advertise_custom", {}).get("advertise_where", [])
    public_ads = [
        ad["advertise_on_public"] for ad in ads if "advertise_on_public" in ad
    ]
    if (
        len(public_ads) != 1
        or public_ads[0].get("public_ip", {}).get("name") != allocation["name"]
        or public_ads[0]["public_ip"].get("namespace") != allocation["namespace"]
    ):
        raise ValueError("load balancer must use only the reserved public IP")
    if len(ads) != LISTENER_COUNT or any(
        "site" not in ad
        or ad["site"].get("site", {}).get("name") not in config["ce_sites"]
        for ad in ads
        if "advertise_on_public" not in ad
    ):
        raise ValueError("nonpublic listeners must belong only to Canadian CEs")
    pools = lb.get("default_route_pools", [])
    if len(pools) != 1 or (
        pools[0].get("pool", {}).get("name"),
        pools[0].get("pool", {}).get("namespace"),
    ) != (config["pool"], config["namespace"]):
        raise ValueError("load balancer does not use only the Canadian pool")
    pool = objects["pool"]["spec"]
    origins = pool.get("origin_servers", [])
    if pool.get("endpoint_selection") != "DISTRIBUTED" or len(origins) != 1:
        raise ValueError("Canadian pool endpoint selection differs")
    origin = origins[0].get("private_ip", {})
    locator = origin.get("site_locator", {}).get("virtual_site", {})
    if origin.get("ip") != config["origin_ip"] or (
        locator.get("name"),
        locator.get("namespace"),
    ) != (config["ce_virtual_site"], config["namespace"]):
        raise ValueError("origin discovery is not restricted to the Canadian pool")


def validate_response(body: bytes, headers: str, expected: str) -> str:
    """Require the distinct origin marker and an exact Canadian RE response."""
    if body.decode().strip() != expected:
        raise ValueError("public RE response does not match the Canadian origin")
    locations = [
        line.split(":", 1)[1].strip()
        for line in headers.splitlines()
        if line.lower().startswith("x-volterra-location:")
    ]
    if len(locations) != 1 or locations[0] not in ALLOWED_RE:
        raise ValueError("public response has no exact Canadian RE location")
    return locations[0]


def collect_configuration(config: dict[str, Any], get: Any) -> dict[str, Any]:
    """Read RE objects in allocation scope and application objects in app scope."""
    allocation = config["allocation"]
    namespace = config["namespace"]
    re_namespace = config["re_namespace"]
    return {
        "public_ip": get(allocation["namespace"], "public_ips", allocation["name"]),
        "virtual_site": get(re_namespace, "virtual_sites", config["virtual_site"]),
        "selectees": get(
            re_namespace, "virtual_sites", config["virtual_site"], "/selectees"
        ),
        "loadbalancer": get(namespace, "http_loadbalancers", config["loadbalancer"]),
        "ce_selectees": get(
            namespace, "virtual_sites", config["ce_virtual_site"], "/selectees"
        ),
        "pool": get(namespace, "origin_pools", config["pool"]),
    }


def main() -> int:
    """Collect private configuration and traffic evidence from the deployed stack."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--terraform-dir", required=True)
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--samples", type=int, default=10)
    args = parser.parse_args()
    config = json.loads(
        subprocess.check_output(  # noqa: S603 - fixed Terraform output operation and argv
            [
                shutil.which("terraform") or "/usr/bin/terraform",
                "-chdir=" + args.terraform_dir,
                "output",
                "-json",
                "canada_public_re",
            ]
        )
    )
    if config is None:
        print("Canadian public RE verification skipped (advertisement disabled)")
        return 0
    if args.samples < 1:
        parser.error("--samples must be positive")
    args.evidence_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    os.umask(0o077)
    base = os.environ["XCSH_API_URL"]
    if not base.startswith("https://"):
        parser.error("XCSH_API_URL must use HTTPS")
    token = os.environ["XCSH_API_TOKEN"]

    def get(namespace: str, kind: str, name: str, suffix: str = "") -> Any:
        request = urllib.request.Request(  # noqa: S310 - HTTPS tenant URL checked above
            f"{base}/api/config/namespaces/{namespace}/{kind}/{name}{suffix}",
            headers={"Authorization": "APIToken " + token},
        )
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310
            return json.load(response)

    allocation = config["allocation"]
    objects = collect_configuration(config, get)
    (args.evidence_dir / "configuration.json").write_text(json.dumps(objects))
    validate_configuration(config, objects)
    expected = config["expected_marker"]
    if expected is None:
        parser.error("public RE acceptance requires the distinct owned Canadian origin")
    locations = []
    for index in range(args.samples):
        headers = args.evidence_dir / f"headers-{index}.txt"
        result = subprocess.run(  # noqa: S603 - fixed curl operation and opaque argv
            [
                shutil.which("curl") or "/usr/bin/curl",
                "--silent",
                "--show-error",
                "--fail",
                "--noproxy",
                "*",
                "--max-time",
                "30",
                "--dump-header",
                str(headers),
                "--resolve",
                f"{config['domain']}:80:{allocation['ip']}",
                f"http://{config['domain']}/",
            ],
            capture_output=True,
            check=True,
        )
        (args.evidence_dir / f"body-{index}.txt").write_bytes(result.stdout)
        locations.append(
            validate_response(result.stdout, headers.read_text(), expected)
        )
    receipt = {
        "status": "passed",
        "samples": args.samples,
        "exact_canadian_origin": True,
        "regional_edges": sorted(set(locations)),
        "selector_exact": True,
        "exclusive_public_ip_binding": True,
        "canadian_pool_only": True,
    }
    (args.evidence_dir / "receipt.json").write_text(json.dumps(receipt))
    print(
        f"PASS: {args.samples} Canadian-origin responses through Canadian Regional Edges"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
