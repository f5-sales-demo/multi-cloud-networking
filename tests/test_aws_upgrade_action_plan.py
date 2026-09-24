"""Regression tests for immutable one-site AWS action-plan scope."""
# ruff: noqa: INP001, PT009

import hashlib
import runpy
import tempfile
import unittest
from argparse import Namespace
from pathlib import Path
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]
CHECKER = ROOT / "scripts/verify-aws-upgrade-action-plan.py"
VALIDATE = runpy.run_path(str(CHECKER))["validate"]
COMMIT = "a" * 40
ENVIRONMENT = "qualify-1255-v11-abcdefabcdef"
KEY = f"mcn-ce-ha-smsv2/environments/{ENVIRONMENT}/showcase.tfstate"
SITE = "mcn-1255-unique-aws-ce-01"
SOFTWARE = "crt-20260201-0180"
OS = "9.2026.18"


class UpgradePlanTest(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.saved = self.path / "saved.tfplan"
        self.saved.write_bytes(b"immutable-saved-plan")
        self.plan = {
            "variables": {
                "source_commit_sha": {"value": COMMIT},
                "enable_aws": {"value": True},
                "enable_azure": {"value": False},
                "enable_kvm": {"value": False},
                "aws_ce_count": {"value": 3},
                "deployment_owner_id": {"value": "mcn-1255"},
                "aws_upgrade_observed_sites": {"value": ["01"]},
            },
            "resource_changes": [],
            "action_invocations": [
                {
                    "address": 'action.xcsh_site_upgrade_sw.aws["01"]',
                    "provider_name": "registry.terraform.io/f5-sales-demo/xcsh",
                    "config_values": {"site": SITE, "software_version": SOFTWARE},
                }
            ],
        }
        self.receipt = {
            "source_commit": COMMIT,
            "plan_sha256": "sha256:"
            + hashlib.sha256(self.saved.read_bytes()).hexdigest(),
            "backend_key": KEY,
            "environment_key": ENVIRONMENT,
        }

    def check(self, mode="software"):
        args = Namespace(
            plan=self.saved,
            source_commit=COMMIT,
            backend_key=KEY,
            environment_key=ENVIRONMENT,
            owner="mcn-1255",
            site="01",
            mode=mode,
            site_name=SITE,
            target=OS if mode == "os" else SOFTWARE,
        )
        try:
            VALIDATE(args, self.plan, self.receipt)
        except ValueError:
            return SimpleNamespace(returncode=1)
        return SimpleNamespace(returncode=0)

    def test_one_site_software_action(self):
        self.assertEqual(self.check().returncode, 0)

    def test_os_must_be_separate(self):
        self.assertNotEqual(self.check("os").returncode, 0)
        self.plan["action_invocations"] = [
            {
                "address": 'action.xcsh_site_upgrade_os.aws["01"]',
                "provider_name": "registry.terraform.io/f5-sales-demo/xcsh",
                "config_values": {"site": SITE, "os_version": OS},
            }
        ]
        self.assertEqual(self.check("os").returncode, 0)

    def test_other_site_or_second_action_is_rejected(self):
        self.plan["action_invocations"].append(
            {"address": 'action.xcsh_site_upgrade_sw.aws["02"]'}
        )
        self.assertNotEqual(self.check().returncode, 0)

    def test_azure_action_and_resource_mutation_are_rejected(self):
        self.plan["action_invocations"] = [
            self.plan["action_invocations"][0],
            {"address": "azurerm_resource_group.example"},
        ]
        self.assertNotEqual(self.check().returncode, 0)
        self.plan["action_invocations"] = self.plan["action_invocations"][:1]
        self.plan["resource_changes"] = [
            {"address": "aws_instance.ce[0]", "change": {"actions": ["update"]}}
        ]
        self.assertNotEqual(self.check().returncode, 0)

    def test_action_target_and_site_name_must_match_review(self):
        self.plan["action_invocations"][0]["config_values"]["site"] = "unowned-site"
        self.assertNotEqual(self.check().returncode, 0)
        self.plan["action_invocations"][0]["config_values"]["site"] = SITE
        self.plan["action_invocations"][0]["config_values"]["software_version"] = (
            "crt-20260201-0999"
        )
        self.assertNotEqual(self.check().returncode, 0)

    def test_stale_plan_and_ambiguous_ownership_are_rejected(self):
        self.receipt["plan_sha256"] = "sha256:" + "0" * 64
        self.assertNotEqual(self.check().returncode, 0)
        self.receipt["plan_sha256"] = (
            "sha256:" + hashlib.sha256(self.saved.read_bytes()).hexdigest()
        )
        self.plan["variables"].pop("deployment_owner_id")
        self.assertNotEqual(self.check().returncode, 0)

    def test_shared_backend_key_is_rejected(self):
        self.receipt["backend_key"] = "mcn-ce-ha-smsv2/showcase.tfstate"
        self.assertNotEqual(self.check().returncode, 0)

    def test_reapply_and_destroy_have_no_actions(self):
        self.assertNotEqual(self.check("reapply").returncode, 0)
        self.plan["action_invocations"] = []
        self.assertEqual(self.check("reapply").returncode, 0)
        self.plan["resource_changes"] = [
            {"address": "aws_instance.ce[0]", "change": {"actions": ["delete"]}}
        ]
        self.assertEqual(self.check("destroy").returncode, 0)
        self.plan["resource_changes"][0]["change"]["actions"] = ["create"]
        self.assertNotEqual(self.check("destroy").returncode, 0)


if __name__ == "__main__":
    unittest.main()
