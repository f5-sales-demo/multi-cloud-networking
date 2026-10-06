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

PROVIDER_SHA256 = "1336457feafbd7753de500f73db514a8a2e5c5d516a1f3dfc6a484ea956bfc53"
AZURE_PREFIXES = (
    "module.azure_hub[",
    "module.ce_node[",
    "module.ce_vm[",
    "module.xc_site[",
    "module.azure_frr_us[",
    "terraform_data.origin_f5_acl_gate[",
    "module.showcase_origin[",
    "module.client_vm[",
    "module.azure_ilb_application[",
    "azurerm_lb.",
    "azurerm_lb_rule.",
    "azurerm_lb_probe.",
    "azurerm_lb_backend_address_pool.",
    "azurerm_network_interface_backend_address_pool_association.",
    "azurerm_virtual_machine_extension.site_console_password",
    "random_password.site_console_admin",
    "xcsh_origin_pool.this[",
    "xcsh_http_loadbalancer.this[",
    "xcsh_virtual_site.regional_ce[",
    "xcsh_token.ce[",
    "azapi_resource_action.f5xc_customer_edge_marketplace_agreement[",
)
KVM_PREFIXES = (
    "libvirt_",
    "docker_",
    "module.kvm_registration_mapping.",
    "module.kvm_boot_image[",
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
    "enable_bgp",
    "enable_azure_ilb",
    "enable_kvm",
    "enable_kvm_lan",
    "enable_aws",
    "enable_aws_tgw_connect",
)

PRODUCTION_KEY = "mcn-ce-ha-smsv2/showcase.tfstate"
LEGACY_KVM_BGP = "xcsh_bgp.onprem_ebgp[0]"
LEGACY_TENANT = "f5-sales-demo"


def legacy_kvm_bgp_owned(
    address: str,
    before: dict[str, Any],
    backend_key: str | None,
    legacy: dict[str, str] | None,
) -> bool:
    """Recognize only the reviewed predecessor KVM BGP object."""
    if address != LEGACY_KVM_BGP or backend_key != PRODUCTION_KEY or legacy is None:
        return False
    labels = before.get("labels") or {}
    refs = ((before.get("where") or {}).get("site") or {}).get("ref")
    site_name = "mcn-ce-ha-smsv2-current-kvm"
    return all(
        (
            before.get("name") == "onprem-kvm-ebgp",
            before.get("namespace") == "system",
            labels.get("mcn-owner-id") == "kvm-poc",
            labels.get("mcn-environment") == "production",
            labels.get("mcn-deployment-generation")
            == legacy.get("generation")
            == "smsv2-current",
            labels.get("mcn-xc-tenant") == legacy.get("tenant") == LEGACY_TENANT,
            labels.get("mcn-topology") == site_name,
            isinstance(refs, list)
            and len(refs) == 1
            and isinstance(refs[0], dict)
            and refs[0].get("name") == site_name
            and refs[0].get("namespace") == "system"
            and refs[0].get("kind", "site.Object") == "site.Object",
        )
    )


def prior_managed_addresses(document: dict[str, Any]) -> set[str]:
    """Collect every managed address, including nested child modules."""
    root = ((document.get("prior_state") or {}).get("values") or {}).get("root_module")
    if not isinstance(root, dict):
        raise ValueError("destroy plan lacks prior state")
    addresses: set[str] = set()

    def visit(module: dict[str, Any]) -> None:
        for resource in module.get("resources") or []:
            if resource.get("mode") != "managed":
                continue
            address = resource.get("address")
            if not isinstance(address, str) or not address or address in addresses:
                raise ValueError(
                    "destroy prior state has malformed or duplicate address"
                )
            addresses.add(address)
        for child in module.get("child_modules") or []:
            if not isinstance(child, dict):
                raise ValueError("destroy prior state has malformed child module")
            visit(child)

    visit(root)
    return addresses


def _value(document: dict[str, Any], name: str) -> Any:
    item = document.get("variables", {}).get(name, {})
    if not isinstance(item, dict) or "value" not in item:
        raise ValueError(f"saved plan is missing variable {name}")
    value = item["value"]
    if name in FULL_FLAGS:
        if isinstance(value, bool):
            return value
        if value == "true":
            return True
        if value == "false":
            return False
        raise ValueError(f"saved plan has invalid boolean variable {name}")
    return value


def validate_azure_site_bindings(item: dict[str, Any]) -> None:
    """Require complete, distinct hardware MACs in the exact configured plan."""
    after = item.get("change", {}).get("after") or {}
    nodes = after.get("azure", {}).get("not_managed", {}).get("node_list")
    if not isinstance(nodes, list) or len(nodes) != 1:
        raise ValueError("Azure MAC binding requires exactly one configured node")
    interfaces = nodes[0].get("interface_list")
    if not isinstance(interfaces, list) or len(interfaces) != 3:
        raise ValueError("Azure MAC binding requires all three registered interfaces")
    macs = []
    inside_count = 0
    for index, interface in enumerate(interfaces):
        ethernet = interface.get("ethernet_interface") or {}
        mac = str(ethernet.get("mac", "")).lower().replace("-", ":")
        if ethernet.get("device") != f"eth{index}" or not re.fullmatch(
            r"[0-9a-f]{2}(:[0-9a-f]{2}){5}", mac
        ):
            raise ValueError(
                "Azure MAC binding has a missing or incorrect hardware identity"
            )
        role = interface.get("network_option") or {}
        inside = role.get("site_local_inside_network") is not None
        outside = role.get("site_local_network") is not None
        if inside == outside or (index == 0 and not outside):
            raise ValueError("Azure MAC binding changes the primary interface role")
        inside_count += int(inside)
        macs.append(mac)
    if inside_count != 1:
        raise ValueError("Azure MAC binding requires exactly one inside interface")
    if len(set(macs)) != 3:
        raise ValueError("Azure MAC binding contains duplicate hardware identities")


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
    for name in FULL_FLAGS:
        _value(document, name)
    providers = document.get("configuration", {}).get("provider_config", {})
    xcsh = providers.get("xcsh", {})
    if xcsh.get("full_name") != "registry.terraform.io/f5-sales-demo/xcsh" or xcsh.get(
        "version_constraint"
    ) not in ("15.0.3", "= 15.0.3"):
        raise ValueError("saved plan does not pin xcsh 15.0.3")

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
        if item.get("actions") not in (["no-op"], ["read"])
    ]

    if scope == "azure-approvals":
        if any(_value(document, name) is not True for name in FULL_FLAGS):
            raise ValueError("Azure approvals require every showcase path enabled")
        if _value(document, "kvm_lan_configuration_phase") != "configured":
            raise ValueError("Azure approvals must preserve configured KVM LAN")
        approvals = [
            address
            for address, actions in changes
            if address.startswith(("module.xc_site[",))
            and ".xcsh_registration_approval.this[" in address
            and actions == ["create"]
        ]
        if len(approvals) != 3:
            raise ValueError(
                "Azure approval plan must create three registration approvals"
            )
        for address, actions in changes:
            if address in approvals:
                continue
            if not (
                address.startswith(("module.xc_site[",))
                and ".xcsh_securemesh_site_v2.this[" in address
                and actions == ["update"]
            ):
                raise ValueError(
                    f"Azure approval plan contains an action outside its scope: {address}"
                )
    elif scope == "azure-bindings":
        if _value(document, "azure_site_configuration_phase") != "configured":
            raise ValueError("Azure MAC binding requires configured phase")
        if not changes:
            raise ValueError("Azure MAC binding plan has no actions")
        for address, actions in changes:
            if not (
                address.startswith(("module.xc_site[",))
                and ".xcsh_securemesh_site_v2.this[" in address
                and actions == ["update"]
            ):
                raise ValueError(
                    f"Azure MAC binding contains an action outside its scope: {address}"
                )
        for item in document.get("resource_changes") or []:
            if item.get("change", {}).get("actions") == ["update"]:
                validate_azure_site_bindings(item)
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
            "enable_bgp": True,
            "enable_azure_ilb": True,
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
        if _value(document, "enable_azure") is not False:
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
        if _value(document, "enable_azure") is not False:
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
        if _value(document, "enable_azure") is not False:
            raise ValueError("AWS/KVM verification must disable Azure")
        if _value(document, "kvm_lan_configuration_phase") != "hardware":
            raise ValueError("AWS/KVM verification must preserve the hardware phase")
    elif scope == "kvm-status-output-refresh":
        if changes or output_changes != ["kvm_runtime_status"]:
            raise ValueError("KVM status refresh must change only its status output")
        if (
            _value(document, "enable_azure") is not False
            or _value(document, "kvm_lan_configuration_phase") != "hardware"
        ):
            raise ValueError("KVM status refresh must preserve the AWS/KVM stage")
        change = document["output_changes"]["kvm_runtime_status"]
        before, after = change.get("before"), change.get("after")
        healthy = {
            "bgp_converged": True,
            "bgp_session_count": 1,
            "mapping_valid": True,
            "online_count": 1,
            "registration_count": 1,
        }
        if (
            change.get("actions") != ["update"]
            or not isinstance(before, dict)
            or not isinstance(after, dict)
        ):
            raise ValueError("KVM status refresh has a malformed output action")
        if set(before) != set(healthy) or set(after) != set(healthy) or before == after:
            raise ValueError("KVM status refresh is not an exact healthy transition")
        if any(
            type(after[key]) is not type(value) or after[key] != value
            for key, value in healthy.items()
        ):
            raise ValueError("KVM status refresh does not end healthy")
        for key, value in before.items():
            if key in ("online_count", "registration_count"):
                if (
                    isinstance(value, bool)
                    or not isinstance(value, int)
                    or value not in (0, 1)
                ):
                    raise ValueError("KVM status refresh has an invalid prior count")
            elif type(value) is not type(healthy[key]) or value != healthy[key]:
                raise ValueError("KVM status refresh changes a routing or mapping fact")
    elif scope == "aws-status-output-refresh":
        if changes or output_changes != ["aws_site_upgrade_status"]:
            raise ValueError("AWS status refresh must change only its status output")
        if (
            _value(document, "enable_azure") is not False
            or _value(document, "kvm_lan_configuration_phase") != "hardware"
        ):
            raise ValueError("AWS status refresh must preserve the AWS/KVM stage")
        status_change = document["output_changes"]["aws_site_upgrade_status"]
        before = status_change.get("before")
        after = status_change.get("after")
        if (
            status_change.get("actions") != ["update"]
            or not isinstance(before, dict)
            or not isinstance(after, dict)
            or set(before) != {"01", "02", "03"}
            or set(after) != set(before)
        ):
            raise ValueError("AWS status refresh has an unexpected output shape")
        changed_sites = 0
        status_fields = {"os_deployment_phase", "os_deployment_result"}
        for site in before:
            old, new = before[site], after[site]
            if not isinstance(old, dict) or not isinstance(new, dict):
                raise ValueError("AWS status refresh has a malformed site status")
            if old == new:
                continue
            old_other = {
                key: value for key, value in old.items() if key not in status_fields
            }
            new_other = {
                key: value for key, value in new.items() if key not in status_fields
            }
            if (
                old_other != new_other
                or old.get("os_deployment_phase") != "UPGRADE_IN_PROGRESS"
                or old.get("os_deployment_result") != "inProgress"
                or new.get("os_deployment_phase") != "UPGRADE_COMPLETED"
                or new.get("os_deployment_result") != "success"
            ):
                raise ValueError(
                    "AWS status refresh is not a successful upgrade transition"
                )
            changed_sites += 1
        if changed_sites == 0:
            raise ValueError("AWS status refresh has no successful transition")
    elif scope == "refresh-only":
        if changes:
            raise ValueError("refresh-only plan contains a normal resource action")
        if output_changes:
            raise ValueError("refresh-only plan contains an output action")
        drift = document.get("resource_drift") or []
        if not isinstance(drift, list):
            raise ValueError("refresh-only plan has malformed resource drift")
        drift_changes = []
        for item in drift:
            if not isinstance(item, dict) or not isinstance(item.get("address"), str):
                raise ValueError("refresh-only plan has malformed resource drift")
            actions = item.get("change", {}).get("actions")
            if not isinstance(actions, list):
                raise ValueError("refresh-only plan has malformed resource drift")
            if actions != ["no-op"]:
                drift_changes.append((item["address"], actions))
        if (
            len(drift_changes) != 1
            or drift_changes[0][0]
            not in ("aws_network_interface.slo[0]", 'libvirt_domain.ce_node["01"]')
            or drift_changes[0][1] != ["update"]
        ):
            raise ValueError("refresh-only plan must isolate one owned drift update")
        return 1
    elif scope == "full-destroy":
        if not changes:
            raise ValueError("destroy plan has no actions")
        delete_addresses = [address for address, _ in changes]
        if len(delete_addresses) != len(set(delete_addresses)) or set(
            delete_addresses
        ) != prior_managed_addresses(document):
            raise ValueError("destroy delete set does not match complete prior state")
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
                if item.get("type") == "xcsh_bgp" and legacy_kvm_bgp_owned(
                    item["address"], before, backend_key, legacy
                ):
                    continue
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
            "aws-status-output-refresh",
            "kvm-status-output-refresh",
            "kvm-configured",
            "azure-build",
            "azure-approvals",
            "azure-converge",
            "azure-bindings",
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
