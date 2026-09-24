#!/usr/bin/env python3
"""Fail closed on one task-owned, immutable AWS three-site qualification plan."""
# ruff: noqa: S603, S607
# pylint: disable=invalid-name

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

AWS_SITE_COUNT = 3
SOURCE_REPOSITORY = "f5-sales-demo/multi-cloud-networking"


def require(condition: bool, message: str) -> None:
    """Reject any incomplete or out-of-scope plan evidence."""
    if not condition:
        raise ValueError(message)


def variable(document: dict[str, Any], name: str) -> Any:
    """Read one mandatory Terraform saved-plan input."""
    entry = document.get("variables", {}).get(name)
    require(
        isinstance(entry, dict) and "value" in entry, f"missing plan variable {name}"
    )
    return entry["value"]


def expected_environment_key(source_ref: str) -> str:
    """Derive the canonical preview environment for one source ref."""
    branch_slug = re.sub(
        r"[^a-z0-9]+", "-", source_ref.removeprefix("refs/heads/")
    ).strip("-")
    ref_digest = hashlib.sha256(
        (f"mcn.deployment-identity/v1\0{SOURCE_REPOSITORY}\0{source_ref}").encode()
    ).hexdigest()[:12]
    return f"{branch_slug[:19].rstrip('-')}-{ref_digest}"


def aws_owned_address(address: str) -> bool:
    """Restrict destroy candidates to the active AWS root, not Azure/KVM XC."""
    if address.startswith(("aws_", "module.aws_tgw_connect[", "terraform_data.aws")):
        return True
    return (
        re.fullmatch(
            r"xcsh_(?:token|securemesh_site_v2|site_cloud_init|registration_approval|"
            r"virtual_site|origin_pool|http_loadbalancer)\.aws(?:\[.*\])?"
            r"|xcsh_(?:external_connector|bgp)\.aws_tgw(?:\[.*\])?",
            address,
        )
        is not None
    )


def validate(
    args: argparse.Namespace, document: dict[str, Any], receipt: dict[str, Any]
) -> dict[str, Any]:
    """Bind a saved plan to its receipt and enforce the AWS-only action scope."""
    digest = "sha256:" + hashlib.sha256(args.plan.read_bytes()).hexdigest()
    require(receipt.get("plan_sha256") == digest, "stale or mismatched saved plan")
    require(
        receipt.get("source_commit") == args.source_commit,
        "stale source commit receipt",
    )
    require(receipt.get("backend_key") == args.backend_key, "backend key mismatch")
    require(
        receipt.get("environment_key") == args.environment_key, "environment mismatch"
    )
    source_ref = variable(document, "source_ref")
    require(
        variable(document, "source_repository") == SOURCE_REPOSITORY
        and isinstance(source_ref, str)
        and re.fullmatch(r"refs/heads/qualify/1255-[a-z0-9-]+", source_ref) is not None,
        "plan is not bound to the task-owned preview source ref",
    )
    require(
        args.environment_key == expected_environment_key(source_ref)
        and args.backend_key
        == f"mcn-ce-ha-smsv2/environments/{args.environment_key}/showcase.tfstate",
        "shared or ambiguous backend key",
    )
    require(
        re.fullmatch(r"[a-f0-9]{40}", args.source_commit) is not None,
        "invalid source commit",
    )
    require(args.environment_key and args.owner, "ambiguous ownership")
    require(
        variable(document, "source_commit_sha") == args.source_commit,
        "stale plan source",
    )
    require(
        variable(document, "deployment_owner_id") == args.owner,
        "plan ownership mismatch",
    )
    require(
        variable(document, "enable_aws") is True
        and variable(document, "enable_azure") is False
        and variable(document, "enable_kvm") is False
        and variable(document, "aws_ce_count") == AWS_SITE_COUNT,
        "plan is not AWS-only three-site",
    )

    changes = document.get("resource_changes") or []
    invocations = document.get("action_invocations", [])
    require(
        isinstance(changes, list) and isinstance(invocations, list),
        "plan resource/action summary missing",
    )
    mutations = []
    for entry in changes:
        require(
            isinstance(entry, dict)
            and isinstance(entry.get("address"), str)
            and isinstance(entry.get("change"), dict)
            and isinstance(entry["change"].get("actions"), list),
            "malformed resource change",
        )
        if entry["change"]["actions"] not in (["read"], ["no-op"]):
            mutations.append(entry)
    if args.mode == "destroy":
        require(
            all(entry["change"]["actions"] == ["delete"] for entry in mutations),
            "destroy plan contains non-delete resource changes",
        )
        require(
            all(aws_owned_address(entry["address"]) for entry in mutations),
            "destroy plan contains Azure/KVM changes",
        )
    else:
        require(not mutations, "action/reapply plan contains resource changes")

    if args.mode in ("software", "os"):
        require(
            variable(document, "aws_upgrade_observed_sites") == [args.site],
            "upgrade observation must select exactly one site",
        )
        action_type = "sw" if args.mode == "software" else "os"
        expected = f'action.xcsh_site_upgrade_{action_type}.aws["{args.site}"]'
        require(
            len(invocations) == 1
            and isinstance(invocations[0], dict)
            and invocations[0].get("address") == expected
            and invocations[0].get("provider_name")
            == "registry.terraform.io/f5-sales-demo/xcsh",
            "expected exactly one selected-site action and zero Azure actions",
        )
        configuration = invocations[0].get("config_values")
        target_key = "software_version" if args.mode == "software" else "os_version"
        require(
            configuration == {"site": args.site_name, target_key: args.target},
            "action target or task-owned site name does not match review",
        )
    else:
        require(
            not invocations,
            "normal reapply/destroy must contain zero action invocations",
        )
    return {
        "plan_sha256": digest,
        "mode": args.mode,
        "site": args.site if args.mode in ("software", "os") else None,
        "resource_mutations": len(mutations),
        "action_invocations": len(invocations),
        "azure_actions": 0,
        "source_commit": args.source_commit,
    }


def main() -> int:
    """Verify a saved plan by rendering JSON from the exact binary."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument(
        "--terraform-dir",
        type=Path,
        required=True,
        help="Initialized root for Terraform show",
    )
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--backend-key", required=True)
    parser.add_argument("--environment-key", required=True)
    parser.add_argument("--owner", required=True)
    parser.add_argument("--site", choices=("01", "02", "03"), default="01")
    parser.add_argument("--site-name", help="Exact reviewed task-owned XC site name")
    parser.add_argument("--target", help="Exact advertised software or OS target")
    parser.add_argument(
        "--mode", choices=("software", "os", "reapply", "destroy"), required=True
    )
    args = parser.parse_args()
    try:
        if args.mode in ("software", "os"):
            require(
                args.site_name and args.target,
                "action requires reviewed site name and advertised target",
            )
        result = subprocess.run(
            [
                "terraform",
                f"-chdir={args.terraform_dir}",
                "show",
                "-json",
                str(args.plan),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
        document = json.loads(result.stdout)
        receipt = json.loads(args.receipt.read_text())
        print(json.dumps(validate(args, document, receipt), sort_keys=True))
    except (
        ValueError,
        OSError,
        json.JSONDecodeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"rejected: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
