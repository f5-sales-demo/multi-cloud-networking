#!/usr/bin/env python3
"""Fresh, origin-observed AWS/Azure fixture traffic; raw evidence stays private."""

import argparse
import ipaddress
import json
import re
import shlex
import shutil
import subprocess
import uuid
from contextlib import suppress
from dataclasses import dataclass
from pathlib import Path

CURL_TIMEOUT = 28


@dataclass(frozen=True)
class TrafficTarget:
    """Owned origin and client certificate used for independent protocol controls."""

    origin: str
    certificate: str
    http_path: str = "/allow"


def accepted(receipt: dict, expected: dict[str, str]) -> bool:
    """Require a proven CE path and a positive control for every deny case."""
    if not receipt.get(
        "ce_default_route_verified", receipt.get("aws_default_route_to_ce")
    ):
        return False
    requests = {request["scheme"]: request for request in receipt["requests"]}
    if requests.keys() != expected.keys():
        return False
    controls = []
    for scheme, action in expected.items():
        request = requests[scheme]
        observed = request["origin_observations"]
        if action == "allow":
            good = (
                request["client_exit"] == 0
                and request["http_200"]
                and request["body_case_matches"]
                and observed == 1
                and request.get(
                    "origin_source_matches_ce_public_ip",
                    request.get("origin_source_matches_ce_eip"),
                )
            )
            if not good:
                return False
            controls.append(scheme)
        elif action == "deny":
            if (
                request["http_200"]
                or observed
                or request["client_exit"] != CURL_TIMEOUT
            ):
                return False
        else:
            return False
    return bool(controls)


def capture(
    facts: dict,
    ssh_config: Path,
    evidence: Path,
    label: str,
    cloud: str = "aws",
) -> dict:
    """Capture routing, fresh clients and private origin logs on the owned fixture."""
    origin = str(ipaddress.ip_address(facts["origin_public_ip"]))
    ce_source = str(ipaddress.ip_address(facts["ce_public_ip"]))
    route_ok = route_to_ce(facts, cloud)
    ssh = [shutil.which("ssh") or "", "-F", str(ssh_config)]
    cert = subprocess.check_output(  # noqa: S603 - fixed executable and argv, no shell
        [*ssh, "qualification-origin", "sudo cat /etc/nginx/qualification/origin.crt"],
        timeout=30,
    )
    cert_path = (
        subprocess.check_output(  # noqa: S603 - fixed SSH alias, no untrusted command
            [*ssh, "qualification-client", "mktemp"], timeout=30
        )
        .decode()
        .strip()
    )
    subprocess.run(  # noqa: S603 - fixed SSH aliases; remote curl argv uses shlex.join
        [*ssh, "qualification-client", "cat > " + shlex.quote(cert_path)],
        input=cert,
        check=True,
        timeout=30,
    )
    try:
        requests = client_requests(
            ssh,
            TrafficTarget(origin, cert_path, facts.get("http_path", "/allow")),
            evidence,
            label,
        )
    finally:
        subprocess.run(  # noqa: S603 - fixed SSH alias; path escaped as one argument
            [*ssh, "qualification-client", "rm -- " + shlex.quote(cert_path)],
            capture_output=True,
            timeout=30,
            check=True,
        )
    observe_origin(
        ssh,
        evidence,
        label,
        requests,
        (
            "origin_source_matches_ce_eip"
            if cloud == "aws"
            else "origin_source_matches_ce_public_ip",
            ce_source,
        ),
    )
    return {
        "label": label,
        "cloud": cloud,
        "ce_default_route_verified": route_ok,
        **({"aws_default_route_to_ce": route_ok} if cloud == "aws" else {}),
        "requests": requests,
    }


def observe_origin(
    ssh: list[str],
    evidence: Path,
    label: str,
    requests: list[dict],
    source: tuple[str, str],
) -> None:
    """Match each fresh request to the owned origin and CE source address."""
    raw = subprocess.check_output(  # noqa: S603 - fixed executable and argv, no shell
        [*ssh, "qualification-origin", "sudo cat /var/log/nginx/qualification.jsonl"],
        timeout=30,
    )
    (evidence / f"{label}-origin.jsonl").write_bytes(raw)
    observations = [json.loads(line) for line in raw.decode().splitlines() if line]
    source_key, ce_source = source
    for request in requests:
        matched = [item for item in observations if item.get("case") == request["case"]]
        request["origin_observations"] = len(matched)
        request[source_key] = bool(matched) and all(
            item.get("source") == ce_source for item in matched
        )


def route_to_ce(facts: dict, cloud: str) -> bool:
    """Require an active route on the fixture client to the owned CE inside NIC."""
    if cloud == "azure":
        response = json.loads(
            subprocess.check_output(  # noqa: S603 - fixed Azure CLI, argv only
                [
                    shutil.which("az") or "",
                    "network",
                    "nic",
                    "show-effective-route-table",
                    "--ids",
                    facts["client_nic"],
                    "-o",
                    "json",
                ],
                timeout=60,
            )
        )
        return any(
            route.get("source") == "User"
            and route.get("state") == "Active"
            and route.get("nextHopType") == "VirtualAppliance"
            and "0.0.0.0/0" in route.get("addressPrefix", [])
            and facts["ce_sli_ip"] in route.get("nextHopIpAddress", [])
            for route in response["value"]
        )
    if cloud != "aws":
        return False
    routes = json.loads(
        subprocess.check_output(  # noqa: S603 - fixed executable and argv, no shell
            [
                shutil.which("aws") or "",
                "ec2",
                "describe-route-tables",
                "--region",
                facts["region"],
                "--route-table-ids",
                facts["client_route_table"],
                "--output",
                "json",
            ],
            timeout=60,
        )
    )["RouteTables"][0]["Routes"]
    return any(
        route.get("DestinationCidrBlock") == "0.0.0.0/0"
        and route.get("NetworkInterfaceId") == facts["sli_eni"]
        and route.get("State") == "active"
        for route in routes
    )


def client_requests(
    ssh: list[str],
    target: TrafficTarget,
    evidence: Path,
    label: str,
) -> list[dict]:
    """Issue independent HTTP and certificate-validated HTTPS connections."""
    requests: list[dict] = []
    for scheme, port in (("http", 80), ("https", 443)):
        case = str(uuid.uuid4())
        path = target.http_path if scheme == "http" else "/allow"
        args = [
            "curl",
            "-sS",
            "--max-time",
            "8",
            "--connect-timeout",
            "5",
            "-H",
            "Connection: close",
            "--resolve",
            f"origin.qualification.test:{port}:{target.origin}",
            f"{scheme}://origin.qualification.test{path}?case={case}",
            "-w",
            "\n%{http_code}\n",
        ]
        if scheme == "https":
            args += ["--cacert", target.certificate]
        result = subprocess.run(  # noqa: S603 - fixed SSH aliases; remote curl argv uses shlex.join
            [*ssh, "qualification-client", shlex.join(args)],
            capture_output=True,
            timeout=30,
            check=False,
        )
        (evidence / f"{label}-{scheme}-client.log").write_bytes(
            result.stdout + result.stderr
        )
        lines = result.stdout.decode().strip().splitlines()
        body_match = False
        if lines:
            with suppress(json.JSONDecodeError, AttributeError):
                body_match = json.loads(lines[0]).get("case") == case
        requests.append(
            {
                "scheme": scheme,
                "case": case,
                "client_exit": result.returncode,
                "http_200": bool(lines) and lines[-1] == "200",
                "body_case_matches": body_match,
            }
        )
    return requests


def main() -> None:
    """Run bounded traffic acceptance with explicitly supplied private evidence paths."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cloud", choices=("aws", "azure"), default="aws")
    parser.add_argument("--facts", type=Path, required=True)
    parser.add_argument("--ssh-config", type=Path, required=True)
    parser.add_argument("--evidence", type=Path, required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--http-path", default="/allow")
    parser.add_argument("--http", choices=("allow", "deny"), required=True)
    parser.add_argument("--https", choices=("allow", "deny"), default="allow")
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z0-9-]+", args.label):
        parser.error("Use a lowercase non-personal evidence label")
    if not re.fullmatch(r"/[a-zA-Z0-9/_-]*", args.http_path):
        parser.error("Use an origin-relative HTTP path without query or fragment")
    facts = json.loads(args.facts.read_text())
    if not re.fullmatch(r"[a-z][a-z0-9-]{2,19}", facts["task_id"]):
        parser.error("Invalid fixture task identity")
    args.evidence.mkdir(mode=0o700, parents=True, exist_ok=True)
    path = args.evidence / f"{args.label}-receipt.json"
    if path.exists():
        parser.error("Evidence label already exists; preserve the first attempt")
    facts["http_path"] = args.http_path
    receipt = capture(facts, args.ssh_config, args.evidence, args.label, args.cloud)
    receipt["accepted"] = accepted(receipt, {"http": args.http, "https": args.https})
    path.write_text(json.dumps(receipt, indent=2) + "\n")
    print(json.dumps(receipt))
    raise SystemExit(0 if receipt["accepted"] else 1)


if __name__ == "__main__":
    main()
