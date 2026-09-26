"""Regression coverage for the showcase registration wait gate."""
# ruff: noqa: INP001, I001, PT009, PT027

import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/showcase-registration-gate.py"
SPEC = importlib.util.spec_from_file_location("showcase_registration_gate", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def registration(kind, key, state):
    return {
        "address": f'data.xcsh_site_registration.{kind}["{key}"]',
        "mode": "data",
        "type": "xcsh_site_registration",
        "name": kind,
        "values": {"found": state is not None, "state": state},
    }


def approval(kind, key):
    return {
        "address": f'xcsh_registration_approval.{kind}["{key}"]',
        "type": "xcsh_registration_approval",
        "name": kind,
        "change": {"actions": ["create"]},
    }


def plan(registrations, changes):
    return {
        "terraform_version": "1.16.3",
        "variables": {
            "source_commit_sha": {"value": "a" * 40},
            "aws_site_configuration_phase": {"value": "bootstrap"},
        },
        "prior_state": {"values": {"root_module": {"resources": registrations}}},
        "resource_changes": changes,
    }


class RegistrationGateTest(unittest.TestCase):
    def test_all_online_skips_empty_approval_phase(self):
        document = plan(
            [registration("aws", key, "ONLINE") for key in ("01", "02", "03")]
            + [registration("kvm", "01", "ONLINE")],
            [],
        )
        receipt = MODULE.validate(document, "bootstrap", 3, 1, "a" * 40)
        self.assertTrue(receipt["ready"])
        self.assertTrue(receipt["skip_approval_phase"])
        self.assertEqual(receipt["aws_online"], 3)
        self.assertEqual(receipt["kvm_online"], 1)

    def test_mixed_new_and_online_requires_approval_plan(self):
        document = plan(
            [
                registration("aws", "01", "ONLINE"),
                registration("aws", "02", "ONLINE"),
                registration("aws", "03", "NEW"),
                registration("kvm", "01", "ONLINE"),
            ],
            [approval("aws", "03")],
        )
        receipt = MODULE.validate(document, "bootstrap", 3, 1, "a" * 40)
        self.assertTrue(receipt["ready"])
        self.assertFalse(receipt["skip_approval_phase"])
        self.assertEqual(receipt["approval_creates"], 1)

    def test_missing_registration_keeps_waiting(self):
        document = plan(
            [registration("aws", "01", "ONLINE"), registration("kvm", "01", "ONLINE")],
            [],
        )
        self.assertFalse(
            MODULE.validate(document, "bootstrap", 3, 1, "a" * 40)["ready"]
        )

    def test_configured_stage_ignores_online_kvm_without_new_approval(self):
        document = plan(
            [registration("aws", key, "ONLINE") for key in ("01", "02", "03")]
            + [registration("kvm", "01", "ONLINE")],
            [],
        )
        document["variables"]["aws_site_configuration_phase"]["value"] = "configured"
        receipt = MODULE.validate(document, "configured", 3, 0, "a" * 40)
        self.assertTrue(receipt["ready"])
        self.assertTrue(receipt["skip_approval_phase"])

    def test_duplicate_site_cannot_fill_expected_count(self):
        document = plan(
            [registration("aws", "01", "ONLINE"), registration("kvm", "01", "ONLINE")],
            [approval("aws", "01"), approval("aws", "02")],
        )
        with self.assertRaisesRegex(ValueError, "overlapping"):
            MODULE.validate(document, "bootstrap", 3, 1, "a" * 40)

    def test_online_skip_rejects_unrelated_active_action(self):
        document = plan(
            [registration("aws", key, "ONLINE") for key in ("01", "02", "03")]
            + [registration("kvm", "01", "ONLINE")],
            [{"address": "aws_instance.ce[0]", "change": {"actions": ["update"]}}],
        )
        with self.assertRaisesRegex(ValueError, "unexpected active actions"):
            MODULE.validate(document, "bootstrap", 3, 1, "a" * 40)


if __name__ == "__main__":
    unittest.main()
