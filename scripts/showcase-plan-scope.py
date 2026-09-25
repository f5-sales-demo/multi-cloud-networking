#!/usr/bin/env python3
"""Fail closed on a saved MCN showcase plan and emit a secret-free receipt."""
# pylint: disable=invalid-name,too-many-locals,too-many-branches,too-many-statements,too-many-arguments,too-many-positional-arguments,too-many-nested-blocks,missing-function-docstring
# ruff: noqa: D103, TRY003, TRY004, EM101, EM102, PLR2004, S603, S607

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
from typing import Any

PROVIDER_SHA256 = "5dab6b26cbc2656bd7df2a8259564f238b1947d5cfdf9e9370243300c954d85d"
AZURE_PREFIXES = (
    "module.azure_hub[",
    "module.azure_hub_ca[",
    "module.ce_node[",
    "module.ce_node_ca[",
    "module.xc_site[",
    "module.xc_site_ca[",
    "module.azure_frr_us[",
    "module.azure_frr_ca[",
    "module.client_vm[",
    "module.client_vm_ca[",
    "module.azure_ilb_application[",
    "module.azure_ilb_application_ca[",
    "azurerm_lb.",
    "azurerm_lb_rule.",
    "azurerm_lb_probe.",
    "azurerm_lb_backend_address_pool.",
    "azurerm_network_interface_backend_address_pool_association.",
    "azurerm_virtual_machine_extension.site_console_password",
    "random_password.site_console_admin",
    "xcsh_origin_pool.this[",
    "xcsh_origin_pool.canada[",
    "xcsh_http_loadbalancer.this[",
    "xcsh_http_loadbalancer.canada[",
    "xcsh_virtual_site.canada_re[",
    "xcsh_virtual_site.canada_ce[",
    "xcsh_token.ce[",
    "azapi_resource_action.f5xc_customer_edge_marketplace_agreement[",
)
KVM_PREFIXES = (
    "libvirt_",
    "docker_",
    "module.kvm_registration_mapping.",
    "xcsh_token.kvm",
    "xcsh_securemesh_site_v2.onprem_kvm",
    "xcsh_registration_approval.kvm",
    "xcsh_bgp.onprem_ebgp",
    "xcsh_smsv2_kvm_runtime_interface.",
    "xcsh_virtual_site.kvm_lan",
    "xcsh_origin_pool.kvm_lan",
    "xcsh_http_loadbalancer.kvm_lan",
    "terraform_data.kvm",
    "terraform_data.deployment_identity_guard",
)
AWS_PREFIXES = (
    "aws_",
    "module.aws_tgw_connect[",
    "xcsh_token.aws",
    "xcsh_securemesh_site_v2.aws",
    "xcsh_site_cloud_init.aws",
    "xcsh_registration_approval.aws",
    "xcsh_virtual_site.aws",
    "xcsh_origin_pool.aws",
    "xcsh_http_loadbalancer.aws",
    "xcsh_external_connector.aws_tgw",
    "xcsh_bgp.aws_tgw",
    "terraform_data.aws",
)
FULL_FLAGS = (
    "enable_azure",
    "enable_canada",
    "enable_bgp",
    "enable_azure_ilb",
    "enable_canada_ilb",
    "enable_kvm",
    "enable_kvm_lan",
    "enable_aws",
    "enable_aws_tgw_connect",
)


def _value(document: dict[str, Any], name: str) -> Any:
    item = document.get("variables", {}).get(name, {})
    if not isinstance(item, dict) or "value" not in item:
        raise ValueError(f"saved plan is missing variable {name}")
    return item["value"]


def validate(
    document: dict[str, Any],
    scope: str,
    source_commit: str,
    environment_key: str | None = None,
    owner_id: str | None = None,
    backend_key: str | None = None,
    legacy: dict[str, str] | None = None,
) -> int:
    """Validate source, provider, toggles, and every active action."""
    if document.get("terraform_version") != "1.16.3":
        raise ValueError("unexpected Terraform version")
    if _value(document, "source_commit_sha") != source_commit:
        raise ValueError("source commit does not match saved plan")
    providers = document.get("configuration", {}).get("provider_config", {})
    xcsh = providers.get("xcsh", {})
    if xcsh.get("full_name") != "registry.terraform.io/f5-sales-demo/xcsh" or xcsh.get(
        "version_constraint"
    ) not in ("11.3.0", "= 11.3.0"):
        raise ValueError("saved plan does not pin xcsh 11.3.0")

    changes = []
    if document.get("action_invocations"):
        raise ValueError("saved plan contains an unscoped provider action invocation")
    for item in document.get("resource_changes") or []:
        if not isinstance(item, dict) or not isinstance(item.get("address"), str):
            raise ValueError("malformed resource change")
        actions = item.get("change", {}).get("actions")
        if not isinstance(actions, list):
            raise ValueError("malformed change actions")
        if actions in (["no-op"], ["read"]):
            continue
        changes.append((item["address"], actions))

    output_changes = [
        name
        for name, item in (document.get("output_changes") or {}).items()
        if item.get("change", {}).get("actions") not in (["no-op"], ["read"])
    ]

    if scope == "azure-approvals":
        if any(_value(document, name) is not True for name in FULL_FLAGS):
            raise ValueError("Azure approvals require every showcase path enabled")
        if _value(document, "kvm_lan_configuration_phase") != "configured":
            raise ValueError("Azure approvals must preserve configured KVM LAN")
        approvals = [
            address
            for address, actions in changes
            if address.startswith(("module.xc_site[", "module.xc_site_ca["))
            and ".xcsh_registration_approval.this[" in address
            and actions == ["create"]
        ]
        if len(approvals) != 6:
            raise ValueError(
                "Azure approval plan must create six registration approvals"
            )
        for address, actions in changes:
            if address in approvals:
                continue
            if not (
                address.startswith(("module.xc_site[", "module.xc_site_ca["))
                and ".xcsh_securemesh_site_v2.this[" in address
                and actions == ["update"]
            ):
                raise ValueError(
                    f"Azure approval plan contains an action outside its scope: {address}"
                )
    elif scope == "azure-converge":
        if not changes:
            raise ValueError("Azure convergence plan has no actions")
        if any(_value(document, name) is not True for name in FULL_FLAGS):
            raise ValueError("Azure convergence requires every showcase path enabled")
        for address, actions in changes:
            if not address.startswith(AZURE_PREFIXES) or actions != ["update"]:
                raise ValueError(
                    f"Azure convergence contains an action outside its update scope: {address}"
                )
    elif scope == "azure-build":
        required = {
            "enable_azure": True,
            "enable_canada": True,
            "enable_bgp": True,
            "enable_azure_ilb": True,
            "enable_canada_ilb": True,
            "enable_kvm_lan": True,
        }
        for name, expected in required.items():
            if _value(document, name) is not expected:
                raise ValueError(f"azure-build requires {name}={expected}")
        if _value(document, "kvm_lan_configuration_phase") != "configured":
            raise ValueError("Azure build must preserve configured KVM LAN")
        if not changes:
            raise ValueError("Azure build plan has no actions")
        for address, actions in changes:
            if not address.startswith(AZURE_PREFIXES):
                raise ValueError(
                    f"Azure build contains an action outside its scope: {address}"
                )
            if actions not in (["create"], ["update"]):
                raise ValueError(
                    f"Azure build contains a destructive action: {address}"
                )
    elif scope == "aws-kvm-build":
        if (
            _value(document, "enable_azure") is not False
            or _value(document, "enable_canada") is not False
        ):
            raise ValueError("AWS/KVM stage must disable Azure")
        if (
            _value(document, "enable_kvm_lan") is not True
            or _value(document, "kvm_lan_configuration_phase") != "hardware"
        ):
            raise ValueError("AWS/KVM stage requires two-NIC hardware phase")
        if not changes:
            raise ValueError("AWS/KVM build plan has no actions")
        for address, actions in changes:
            if not address.startswith(AWS_PREFIXES + KVM_PREFIXES):
                raise ValueError(
                    f"AWS/KVM build contains an action outside its scope: {address}"
                )
            if actions not in (["create"], ["update"], ["delete"]):
                raise ValueError(
                    f"AWS/KVM build contains an unsupported action: {address}"
                )
    elif scope == "kvm-configured":
        if (
            _value(document, "enable_azure") is not False
            or _value(document, "enable_canada") is not False
        ):
            raise ValueError("KVM configuration stage must disable Azure")
        if _value(document, "kvm_lan_configuration_phase") != "configured":
            raise ValueError("KVM configuration stage requires configured phase")
        if not changes:
            raise ValueError("KVM configuration plan has no actions")
        for address, actions in changes:
            if not address.startswith(KVM_PREFIXES):
                raise ValueError(
                    f"KVM configuration contains an action outside its scope: {address}"
                )
            if actions not in (["create"], ["update"], ["delete"]):
                raise ValueError(
                    f"KVM configuration contains an unsupported action: {address}"
                )
    elif scope == "aws-kvm-zero":
        if changes or output_changes:
            raise ValueError("AWS/KVM verification plan is not zero-change")
        if (
            _value(document, "enable_azure") is not False
            or _value(document, "enable_canada") is not False
        ):
            raise ValueError("AWS/KVM verification must disable Azure")
        if _value(document, "kvm_lan_configuration_phase") != "hardware":
            raise ValueError("AWS/KVM verification must preserve the hardware phase")
    elif scope == "refresh-only":
        if (
            len(changes) != 1
            or changes[0][0]
            not in ("aws_network_interface.slo[0]", 'libvirt_domain.ce_node["01"]')
            or changes[0][1] != ["update"]
        ):
            raise ValueError("refresh-only plan must isolate one owned drift update")
    elif scope == "full-destroy":
        if not changes:
            raise ValueError("destroy plan has no actions")
        for address, actions in changes:
            if actions != ["delete"]:
                raise ValueError(f"destroy contains a non-delete action: {address}")
            if any(
                part in address for part in ("host_bridge", "shared_bridge", "uplink")
            ):
                raise ValueError(f"destroy includes shared host networking: {address}")
        if environment_key is not None and owner_id is not None:
            for item in document.get("resource_changes") or []:
                if item.get("change", {}).get("actions") != ["delete"]:
                    continue
                before = item.get("change", {}).get("before") or {}
                tags = before.get("tags") or {}
                labels = before.get("labels") or {}
                marker = (
                    tags
                    if "mcn_owner_id" in tags
                    else labels
                    if "mcn-owner-id" in labels
                    else None
                )
                if marker is None:
                    if item.get("type") in (
                        "azurerm_resource_group",
                        "aws_vpc",
                        "aws_instance",
                        "xcsh_securemesh_site_v2",
                    ):
                        legacy_owned = (
                            backend_key == "mcn-ce-ha-smsv2/showcase.tfstate"
                            and legacy is not None
                        )
                        if item.get("type") in ("aws_vpc", "aws_instance"):
                            legacy_owned = legacy_owned and all(
                                (
                                    tags.get("component") == "mcn-ce-ha",
                                    tags.get("environment")
                                    == (legacy or {}).get("environment"),
                                    tags.get("deployer")
                                    == (legacy or {}).get("deployer"),
                                    tags.get("managed_by") == "terraform",
                                )
                            )
                        elif item.get("type") == "xcsh_securemesh_site_v2":
                            legacy_owned = legacy_owned and all(
                                (
                                    before.get("namespace") == "system",
                                    labels.get("mcn-deployment-generation")
                                    == (legacy or {}).get("generation"),
                                    labels.get("mcn-xc-tenant")
                                    == (legacy or {}).get("tenant"),
                                    str(labels.get("mcn-topology", "")).endswith(
                                        "-aws"
                                    ),
                                )
                            )
                        else:
                            legacy_owned = False
                        if not legacy_owned:
                            raise ValueError(
                                f"destroy lacks required ownership markers: {item['address']}"
                            )
                    continue
                if (
                    marker.get("mcn_owner_id", marker.get("mcn-owner-id")) != owner_id
                    or marker.get("mcn_environment", marker.get("mcn-environment"))
                    != environment_key
                ):
                    raise ValueError(
                        f"destroy ownership marker mismatch: {item['address']}"
                    )
    elif scope == "zero-change":
        if changes or output_changes:
            raise ValueError(
                f"final plan is not zero-change: {changes[0][0] if changes else output_changes[0]}"
            )
        if any(_value(document, name) is not True for name in FULL_FLAGS):
            raise ValueError("zero-change plan does not enable all showcase paths")
        if _value(document, "kvm_lan_configuration_phase") != "configured":
            raise ValueError("zero-change plan does not preserve KVM LAN")
    else:
        raise ValueError("unknown plan scope")
    return len(changes)


def sha256_file(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--terraform-dir", type=pathlib.Path, required=True)
    parser.add_argument("--plan-file", type=pathlib.Path, required=True)
    parser.add_argument("--provider-zip", type=pathlib.Path, required=True)
    parser.add_argument("--backend-config", type=pathlib.Path, required=True)
    parser.add_argument(
        "--scope",
        choices=(
            "aws-kvm-build",
            "aws-kvm-zero",
            "kvm-configured",
            "azure-build",
            "azure-approvals",
            "azure-converge",
            "refresh-only",
            "full-destroy",
            "zero-change",
        ),
        required=True,
    )
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--backend-key", required=True)
    parser.add_argument("--environment-key", required=True)
    parser.add_argument("--owner-id", required=True)
    parser.add_argument("--legacy-deployer")
    parser.add_argument("--legacy-environment")
    parser.add_argument("--legacy-generation")
    parser.add_argument("--legacy-tenant")
    args = parser.parse_args()
    if sha256_file(args.provider_zip) != PROVIDER_SHA256:
        raise ValueError("provider release asset digest mismatch")
    backend_match = re.search(
        r'^\s*key\s*=\s*"([^"]+)"\s*$', args.backend_config.read_text(), re.MULTILINE
    )
    if backend_match is None or backend_match.group(1) != args.backend_key:
        raise ValueError("backend key does not match saved-plan scope")
    result = subprocess.run(
        [
            "terraform",
            f"-chdir={args.terraform_dir}",
            "show",
            "-json",
            str(args.plan_file),
        ],
        capture_output=True,
        check=True,
        timeout=120,
    )
    document = json.loads(result.stdout)
    legacy_values = (
        args.legacy_deployer,
        args.legacy_environment,
        args.legacy_generation,
        args.legacy_tenant,
    )
    legacy = None
    if all(legacy_values):
        legacy = dict(
            zip(
                ("deployer", "environment", "generation", "tenant"),
                legacy_values,
                strict=True,
            )
        )
    count = validate(
        document,
        args.scope,
        args.source_commit,
        args.environment_key,
        args.owner_id,
        args.backend_key,
        legacy,
    )
    receipt = {
        "schema": "mcn.showcase-plan-receipt/v1",
        "scope": args.scope,
        "source_commit": args.source_commit,
        "backend_key": args.backend_key,
        "environment_key": args.environment_key,
        "owner_id": args.owner_id,
        "provider_artifact_sha256": "sha256:" + PROVIDER_SHA256,
        "plan_sha256": "sha256:" + sha256_file(args.plan_file),
        "action_count": count,
    }
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (
        ValueError,
        OSError,
        subprocess.SubprocessError,
        json.JSONDecodeError,
    ) as exc:
        print(f"showcase-plan-scope: {exc}", file=sys.stderr)
        sys.exit(2)
