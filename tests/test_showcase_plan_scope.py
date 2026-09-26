# pylint: disable=missing-module-docstring,missing-class-docstring,missing-function-docstring,duplicate-code
# ruff: noqa: INP001, I001, PT009, PT027, RUF005
import importlib.util
from pathlib import Path
from typing import Any
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/showcase-plan-scope.py"
spec = importlib.util.spec_from_file_location("showcase_plan_scope", SCRIPT)
assert spec is not None
assert spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def plan(changes):
    flags = {
        "source_commit_sha": "a" * 40,
        "enable_azure": True,
        "enable_canada": True,
        "enable_bgp": True,
        "enable_azure_ilb": True,
        "enable_canada_ilb": True,
        "enable_kvm_lan": True,
        "enable_kvm": True,
        "enable_aws": True,
        "enable_aws_tgw_connect": True,
        "kvm_lan_configuration_phase": "configured",
    }
    return {
        "terraform_version": "1.16.3",
        "variables": {name: {"value": value} for name, value in flags.items()},
        "configuration": {
            "provider_config": {
                "xcsh": {
                    "full_name": "registry.terraform.io/f5-sales-demo/xcsh",
                    "version_constraint": "11.3.0",
                }
            }
        },
        "resource_changes": [
            {"address": address, "change": {"actions": actions}}
            for address, actions in changes
        ],
    }


def prior(document, addresses):
    document["prior_state"] = {
        "values": {
            "root_module": {
                "resources": [
                    {"mode": "managed", "address": address} for address in addresses
                ]
            }
        }
    }
    return document


class ShowcasePlanScopeTest(unittest.TestCase):
    def test_aws_kvm_stage_accepts_exact_saved_plan_boolean_strings(self):
        document = plan([("aws_vpc.aws[0]", ["create"])])
        document["variables"]["enable_azure"]["value"] = "false"
        document["variables"]["enable_canada"]["value"] = "false"
        document["variables"]["enable_kvm_lan"]["value"] = "true"
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        self.assertEqual(module.validate(document, "aws-kvm-build", "a" * 40), 1)

    def test_saved_plan_boolean_strings_must_be_exact(self):
        document = plan([("aws_vpc.aws[0]", ["create"])])
        document["variables"]["enable_azure"]["value"] = "False"
        document["variables"]["enable_canada"]["value"] = "false"
        document["variables"]["enable_kvm_lan"]["value"] = "true"
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        with self.assertRaisesRegex(ValueError, "invalid boolean"):
            module.validate(document, "aws-kvm-build", "a" * 40)

    def test_final_scope_accepts_exact_true_strings(self):
        document = plan([])
        for name in module.FULL_FLAGS:
            document["variables"][name]["value"] = "true"
        self.assertEqual(module.validate(document, "zero-change", "a" * 40), 0)

    def test_saved_plan_rejects_non_boolean_flag_value(self):
        document = plan([])
        document["variables"]["enable_azure"]["value"] = 1
        with self.assertRaisesRegex(ValueError, "invalid boolean"):
            module.validate(document, "zero-change", "a" * 40)

    def test_stage_rejects_malformed_unreferenced_boolean_flag(self):
        document = plan([("aws_vpc.aws[0]", ["create"])])
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        document["variables"]["enable_azure"]["value"] = "false"
        document["variables"]["enable_canada"]["value"] = "false"
        document["variables"]["enable_azure_ilb"]["value"] = "FALSE"
        with self.assertRaisesRegex(
            ValueError, "invalid boolean variable enable_azure_ilb"
        ):
            module.validate(document, "aws-kvm-build", "a" * 40)

    def test_azure_approvals_require_six_scoped_creates(self):
        approvals = [
            (
                f'module.xc_site["{i:02d}"].xcsh_registration_approval.this[0]',
                ["create"],
            )
            for i in range(1, 4)
        ] + [
            (
                f'module.xc_site_ca[0].module.site["{i:02d}"].xcsh_registration_approval.this[0]',
                ["create"],
            )
            for i in range(1, 4)
        ]
        self.assertEqual(
            module.validate(plan(approvals), "azure-approvals", "a" * 40), 6
        )
        with self.assertRaisesRegex(ValueError, "six registration"):
            module.validate(plan(approvals[:-1]), "azure-approvals", "a" * 40)
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(
                plan(approvals + [("aws_instance.ce[0]", ["update"])]),
                "azure-approvals",
                "a" * 40,
            )

    def test_azure_build_allows_regional_relay_only(self):
        document = plan(
            [
                (
                    'module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]',
                    ["create"],
                ),
                (
                    "module.azure_ilb_application[0].xcsh_http_loadbalancer.inside",
                    ["create"],
                ),
            ]
        )
        self.assertEqual(module.validate(document, "azure-build", "a" * 40), 2)

    def test_azure_build_rejects_aws_change(self):
        document = plan([('aws_instance.ce["01"]', ["create"])])
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(document, "azure-build", "a" * 40)

    def test_azure_build_rejects_destroy(self):
        document = plan(
            [
                (
                    'module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]',
                    ["delete"],
                )
            ]
        )
        with self.assertRaisesRegex(ValueError, "destructive action"):
            module.validate(document, "azure-build", "a" * 40)

    def test_azure_convergence_rejects_new_resources(self):
        document = plan(
            [('module.xc_site["01"].xcsh_registration_approval.this[0]', ["create"])]
        )
        with self.assertRaisesRegex(ValueError, "outside its update scope"):
            module.validate(document, "azure-converge", "a" * 40)

    def test_zero_change_rejects_hidden_action(self):
        document = plan(
            [
                (
                    'module.azure_frr_ca[0].azurerm_linux_virtual_machine.frr["21"]',
                    ["update"],
                )
            ]
        )
        with self.assertRaisesRegex(ValueError, "not zero-change"):
            module.validate(document, "zero-change", "a" * 40)

    def test_destroy_rejects_shared_uplink(self):
        document = plan([("terraform_data.host_bridge_uplink", ["delete"])])
        prior(document, ["terraform_data.host_bridge_uplink"])
        with self.assertRaisesRegex(ValueError, "shared host networking"):
            module.validate(document, "full-destroy", "a" * 40)

    def test_destroy_rejects_foreign_core_resource(self):
        document = plan([("azurerm_resource_group.hub", ["delete"])])
        prior(document, ["azurerm_resource_group.hub"])
        document["resource_changes"][0]["type"] = "azurerm_resource_group"
        document["resource_changes"][0]["change"]["before"] = {
            "tags": {"mcn_owner_id": "foreign-team", "mcn_environment": "production"}
        }
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            module.validate(
                document, "full-destroy", "a" * 40, "production", "showcase-team"
            )

    def test_destroy_accepts_exact_legacy_production_owner(self):
        document = plan([("aws_vpc.aws[0]", ["delete"])])
        prior(document, ["aws_vpc.aws[0]"])
        document["resource_changes"][0]["type"] = "aws_vpc"
        document["resource_changes"][0]["change"]["before"] = {
            "tags": {
                "component": "mcn-ce-ha",
                "environment": "lab",
                "deployer": "operator",
                "managed_by": "terraform",
            }
        }
        legacy = {
            "deployer": "operator",
            "environment": "lab",
            "generation": "smsv2-current",
            "tenant": "f5-sales-demo",
        }
        self.assertEqual(
            module.validate(
                document,
                "full-destroy",
                "a" * 40,
                "production",
                "showcase-team",
                "mcn-ce-ha-smsv2/showcase.tfstate",
                legacy,
            ),
            1,
        )
        with self.assertRaisesRegex(ValueError, "ownership markers"):
            module.validate(
                document,
                "full-destroy",
                "a" * 40,
                "production",
                "showcase-team",
                "foreign/backend.tfstate",
                legacy,
            )

    def test_destroy_requires_complete_prior_state(self):
        document = plan([("aws_security_group.ce[0]", ["delete"])])
        with self.assertRaisesRegex(ValueError, "prior state"):
            module.validate(document, "full-destroy", "a" * 40)
        prior(document, ["aws_security_group.other[0]"])
        with self.assertRaisesRegex(ValueError, "prior state"):
            module.validate(document, "full-destroy", "a" * 40)

    def test_destroy_requires_recursive_exact_set_without_duplicates(self):
        address = 'module.site["01"].aws_instance.ce[0]'
        document = plan([(address, ["delete"])])
        prior(document, [])
        document["prior_state"]["values"]["root_module"]["child_modules"] = [
            {"resources": [{"mode": "managed", "address": address}]}
        ]
        self.assertEqual(module.validate(document, "full-destroy", "a" * 40), 1)
        document["prior_state"]["values"]["root_module"]["resources"].append(
            {"mode": "managed", "address": address}
        )
        with self.assertRaisesRegex(ValueError, "duplicate"):
            module.validate(document, "full-destroy", "a" * 40)
        document["prior_state"]["values"]["root_module"]["resources"] = []
        document["resource_changes"].append(document["resource_changes"][0].copy())
        with self.assertRaisesRegex(ValueError, "prior state"):
            module.validate(document, "full-destroy", "a" * 40)

    def test_destroy_accepts_only_exact_legacy_kvm_poc_bgp(self):
        address = "xcsh_bgp.onprem_ebgp[0]"
        document = prior(plan([(address, ["delete"])]), [address])
        document["resource_changes"][0]["type"] = "xcsh_bgp"
        before: dict[str, Any] = {
            "name": "onprem-kvm-ebgp",
            "namespace": "system",
            "labels": {
                "mcn-owner-id": "kvm-poc",
                "mcn-environment": "production",
                "mcn-deployment-generation": "smsv2-current",
                "mcn-xc-tenant": "f5-sales-demo",
                "mcn-topology": "mcn-ce-ha-smsv2-current-kvm",
            },
            "where": {
                "site": {
                    "ref": [
                        {
                            "name": "mcn-ce-ha-smsv2-current-kvm",
                            "namespace": "system",
                        }
                    ]
                }
            },
        }
        document["resource_changes"][0]["change"]["before"] = before
        legacy = {
            "deployer": "operator",
            "environment": "lab",
            "generation": "smsv2-current",
            "tenant": "f5-sales-demo",
        }
        args = (
            document,
            "full-destroy",
            "a" * 40,
            "production",
            "showcase-team",
            "mcn-ce-ha-smsv2/showcase.tfstate",
            legacy,
        )
        self.assertEqual(module.validate(*args), 1)
        before["where"]["site"]["ref"][0]["name"] = "foreign-kvm"
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            module.validate(*args)
        before["where"]["site"]["ref"][0]["name"] = "mcn-ce-ha-smsv2-current-kvm"
        before["labels"]["mcn-owner-id"] = "foreign-team"
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            module.validate(*args)
        before["labels"]["mcn-owner-id"] = "kvm-poc"
        args = (*args[:5], "foreign/backend.tfstate", legacy)
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            module.validate(*args)

    def test_source_mismatch_rejected(self):
        with self.assertRaisesRegex(ValueError, "source commit"):
            module.validate(plan([]), "zero-change", "b" * 40)

    def test_zero_change_accepts_null_change_list(self):
        document = plan([])
        document["resource_changes"] = None
        self.assertEqual(module.validate(document, "zero-change", "a" * 40), 0)

    def test_zero_change_rejects_output_only_drift(self):
        document = plan([])
        document["output_changes"] = {"status": {"change": {"actions": ["update"]}}}
        with self.assertRaisesRegex(ValueError, "not zero-change"):
            module.validate(document, "zero-change", "a" * 40)

    def test_provider_action_is_never_hidden_in_noop(self):
        document = plan([])
        document["action_invocations"] = [
            {"address": "action.xcsh_site_upgrade_sw.aws"}
        ]
        with self.assertRaisesRegex(ValueError, "unscoped provider action"):
            module.validate(document, "zero-change", "a" * 40)

    def test_aws_kvm_stage_rejects_azure_action(self):
        document = plan([("azurerm_resource_group.hub", ["create"])])
        document["variables"]["enable_azure"]["value"] = False
        document["variables"]["enable_canada"]["value"] = False
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(document, "aws-kvm-build", "a" * 40)

    def test_kvm_configuration_rejects_aws_change(self):
        document = plan([('aws_instance.ce["01"]', ["update"])])
        document["variables"]["enable_azure"]["value"] = False
        document["variables"]["enable_canada"]["value"] = False
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(document, "kvm-configured", "a" * 40)

    def test_refresh_only_rejects_unowned_drift(self):
        with self.assertRaisesRegex(ValueError, "one owned drift"):
            module.validate(
                plan([("azurerm_resource_group.hub", ["update"])]),
                "refresh-only",
                "a" * 40,
            )

    def test_aws_kvm_zero_rejects_hidden_azure_action(self):
        document = plan(
            [
                (
                    'module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]',
                    ["create"],
                )
            ]
        )
        document["variables"]["enable_azure"]["value"] = False
        document["variables"]["enable_canada"]["value"] = False
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        with self.assertRaisesRegex(ValueError, "not zero-change"):
            module.validate(document, "aws-kvm-zero", "a" * 40)


if __name__ == "__main__":
    unittest.main()
