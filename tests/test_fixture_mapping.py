"""Exercise task identity and MAC joins for the one-CE fixture."""

import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "fixture_mapping", Path(__file__).parents[1] / "scripts/smsv2_fixture_mapping.py"
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
        "slo_mac": "00:00:5e:00:53:01",
        "sli_mac": "00:00:5e:00:53:02",
    }
    hardware = [
        {
            "get_spec": {
                "passport": {"cluster_name": facts["site_name"]},
                "infra": {
                    "hostname": facts["site_name"],
                    "hw_info": {
                        "network": [
                            {"name": "ens8", "mac_address": facts["sli_mac"]},
                            {"name": "ens7", "mac_address": facts["slo_mac"]},
                        ]
                    },
                },
            },
            "object": {"status": {"current_state": "ONLINE"}},
        }
    ]
    return facts, hardware


def rejection(facts, hardware):
    try:
        MODULE.mapping(facts, hardware)
    except ValueError as error:
        return str(error)
    return ""


class MappingTests(unittest.TestCase):
    def test_join_uses_mac_not_interface_order(self):
        facts, hardware = inputs()
        result = MODULE.mapping(facts, hardware)
        assert [entry["device"] for entry in result["entries"]] == ["ens7", "ens8"]
        assert result == MODULE.mapping(facts, copy.deepcopy(hardware))

    def test_foreign_and_duplicate_registrations_fail(self):
        facts, hardware = inputs()
        assert "exactly one" in rejection(facts, hardware + hardware)
        hardware[0]["get_spec"]["passport"]["cluster_name"] = "another-site"
        assert "exactly one" in rejection(facts, hardware)

    def test_missing_or_duplicate_mac_fails(self):
        facts, hardware = inputs()
        hardware[0]["get_spec"]["infra"]["hw_info"]["network"].pop()
        assert "each owned ENI" in rejection(facts, hardware)
        facts, hardware = inputs()
        hardware[0]["get_spec"]["infra"]["hw_info"]["network"] *= 2
        assert "each owned ENI" in rejection(facts, hardware)

    def test_terminal_registration_and_wrong_phase_fail(self):
        facts, hardware = inputs()
        hardware[0]["object"]["status"]["current_state"] = "RETIRED"
        assert "exactly one" in rejection(facts, hardware)
        facts, hardware = inputs()
        facts["phase"] = "configured"
        assert "exactly one" in rejection(facts, hardware)


if __name__ == "__main__":
    unittest.main()
