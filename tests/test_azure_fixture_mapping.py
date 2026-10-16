# ruff: noqa: PT009, PT027
"""Reject unknown or ambiguous Azure VF pairs without guessing device names."""

import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "azure_fixture_mapping",
    Path(__file__).parents[1] / "scripts/smsv2_azure_fixture_mapping.py",
)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def inputs():
    facts = {
        "task_id": "qualification-test",
        "phase": "bootstrap",
        "site_name": "qualification-test-bootstrap",
        "slo_mac": "00-00-5E-00-53-01",
        "sli_mac": "00-00-5E-00-53-02",
    }
    network = [
        {
            "name": "nic-observed-0",
            "driver": "hv_netvsc",
            "mac_address": "00:00:5e:00:53:01",
        },
        {
            "name": "vf-observed-0",
            "driver": "mlx5_core",
            "mac_address": "00:00:5e:00:53:01",
        },
        {
            "name": "nic-observed-1",
            "driver": "hv_netvsc",
            "mac_address": "00:00:5e:00:53:02",
        },
        {
            "name": "vf-observed-1",
            "driver": "mlx5_core",
            "mac_address": "00:00:5e:00:53:02",
        },
    ]
    registrations = [
        {
            "object": {"status": {"current_state": "ONLINE"}},
            "get_spec": {
                "passport": {"cluster_name": "qualification-test-bootstrap"},
                "infra": {
                    "hostname": "qualification-test-bootstrap",
                    "hw_info": {"network": network},
                },
            },
        }
    ]
    return facts, registrations


class AzureMappingTests(unittest.TestCase):
    def test_observed_synthetic_devices_and_aliases(self):
        facts, registrations = inputs()
        result = MODULE.mapping(facts, registrations)
        self.assertEqual(
            [entry["device"] for entry in result["entries"]],
            ["nic-observed-0", "nic-observed-1"],
        )
        self.assertEqual(
            result["entries"][0]["aliases"],
            [{"device": "vf-observed-0", "driver": "mlx5_core"}],
        )

    def test_no_vf_is_supported(self):
        facts, registrations = inputs()
        network = registrations[0]["get_spec"]["infra"]["hw_info"]["network"]
        network[:] = [nic for nic in network if nic["driver"] == "hv_netvsc"]
        result = MODULE.mapping(facts, registrations)
        self.assertEqual(result["entries"][0]["aliases"], [])

    def test_unknown_alias_is_rejected(self):
        facts, registrations = inputs()
        registrations[0]["get_spec"]["infra"]["hw_info"]["network"][1]["driver"] = (
            "unknown"
        )
        with self.assertRaises(ValueError):
            MODULE.mapping(facts, registrations)

    def test_two_synthetic_devices_are_rejected(self):
        facts, registrations = inputs()
        registrations[0]["get_spec"]["infra"]["hw_info"]["network"][1]["driver"] = (
            "hv_netvsc"
        )
        with self.assertRaises(ValueError):
            MODULE.mapping(facts, registrations)

    def test_vf_only_is_rejected(self):
        facts, registrations = inputs()
        network = registrations[0]["get_spec"]["infra"]["hw_info"]["network"]
        network[:] = [nic for nic in network if nic["driver"] != "hv_netvsc"]
        with self.assertRaises(ValueError):
            MODULE.mapping(facts, registrations)

    def test_additional_alias_is_rejected(self):
        facts, registrations = inputs()
        network = registrations[0]["get_spec"]["infra"]["hw_info"]["network"]
        extra = copy.deepcopy(network[1])
        extra["name"] = "vf-extra"
        network.append(extra)
        with self.assertRaises(ValueError):
            MODULE.mapping(facts, registrations)


if __name__ == "__main__":
    unittest.main()
