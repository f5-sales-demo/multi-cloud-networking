import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/showcase-plan-scope.py"
spec = importlib.util.spec_from_file_location("showcase_plan_scope", SCRIPT)
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
        "configuration": {"provider_config": {"xcsh": {
            "full_name": "registry.terraform.io/f5-sales-demo/xcsh",
            "version_constraint": "11.3.0",
        }}},
        "resource_changes": [
            {"address": address, "change": {"actions": actions}} for address, actions in changes
        ],
    }


class ShowcasePlanScopeTest(unittest.TestCase):
    def test_azure_approvals_require_six_scoped_creates(self):
        approvals = [
            (f'module.xc_site[\"{i:02d}\"].xcsh_registration_approval.this[0]', ["create"])
            for i in range(1, 4)
        ] + [
            (f'module.xc_site_ca[0].module.site[\"{i:02d}\"].xcsh_registration_approval.this[0]', ["create"])
            for i in range(1, 4)
        ]
        self.assertEqual(module.validate(plan(approvals), "azure-approvals", "a" * 40), 6)
        with self.assertRaisesRegex(ValueError, "six registration"):
            module.validate(plan(approvals[:-1]), "azure-approvals", "a" * 40)
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(plan(approvals + [('aws_instance.ce[0]', ["update"])]),
                            "azure-approvals", "a" * 40)

    def test_azure_build_allows_regional_relay_only(self):
        document = plan([
            ('module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]', ["create"]),
            ('module.azure_ilb_application[0].xcsh_http_loadbalancer.inside', ["create"]),
        ])
        self.assertEqual(module.validate(document, "azure-build", "a" * 40), 2)

    def test_azure_build_rejects_aws_change(self):
        document = plan([('aws_instance.ce["01"]', ["create"])])
        with self.assertRaisesRegex(ValueError, "outside its scope"):
            module.validate(document, "azure-build", "a" * 40)

    def test_azure_build_rejects_destroy(self):
        document = plan([('module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]', ["delete"])])
        with self.assertRaisesRegex(ValueError, "destructive action"):
            module.validate(document, "azure-build", "a" * 40)

    def test_azure_convergence_rejects_new_resources(self):
        document = plan([('module.xc_site["01"].xcsh_registration_approval.this[0]', ["create"])])
        with self.assertRaisesRegex(ValueError, "outside its update scope"):
            module.validate(document, "azure-converge", "a" * 40)

    def test_zero_change_rejects_hidden_action(self):
        document = plan([('module.azure_frr_ca[0].azurerm_linux_virtual_machine.frr["21"]', ["update"])])
        with self.assertRaisesRegex(ValueError, "not zero-change"):
            module.validate(document, "zero-change", "a" * 40)

    def test_destroy_rejects_shared_uplink(self):
        document = plan([('terraform_data.host_bridge_uplink', ["delete"])])
        with self.assertRaisesRegex(ValueError, "shared host networking"):
            module.validate(document, "full-destroy", "a" * 40)

    def test_destroy_rejects_foreign_core_resource(self):
        document = plan([('azurerm_resource_group.hub', ["delete"])])
        document["resource_changes"][0]["type"] = "azurerm_resource_group"
        document["resource_changes"][0]["change"]["before"] = {
            "tags": {"mcn_owner_id": "foreign-team", "mcn_environment": "production"}
        }
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            module.validate(document, "full-destroy", "a" * 40, "production", "showcase-team")

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
        document["action_invocations"] = [{"address": "action.xcsh_site_upgrade_sw.aws"}]
        with self.assertRaisesRegex(ValueError, "unscoped provider action"):
            module.validate(document, "zero-change", "a" * 40)

    def test_aws_kvm_stage_rejects_azure_action(self):
        document = plan([('azurerm_resource_group.hub', ["create"])])
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
            module.validate(plan([('azurerm_resource_group.hub', ["update"])]), "refresh-only", "a" * 40)

    def test_aws_kvm_zero_rejects_hidden_azure_action(self):
        document = plan([('module.azure_frr_us[0].azurerm_linux_virtual_machine.frr["20"]', ["create"])])
        document["variables"]["enable_azure"]["value"] = False
        document["variables"]["enable_canada"]["value"] = False
        document["variables"]["kvm_lan_configuration_phase"]["value"] = "hardware"
        with self.assertRaisesRegex(ValueError, "not zero-change"):
            module.validate(document, "aws-kvm-zero", "a" * 40)


if __name__ == "__main__":
    unittest.main()
