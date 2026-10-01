"""Azure runtime NIC observations must supersede stale registration facts."""

# ruff: noqa: INP001, PT009, PT027
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "azure_runtime", ROOT / "terraform/scripts/xc-azure-runtime-interfaces.py"
)
assert SPEC
assert SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
MACS = {
    "slo": "52:54:00:10:00:11",
    "sli": "52:54:00:20:00:11",
    "external": "52:54:00:30:00:11",
}


def health():
    """Represent a node whose OS changed the secondary NIC order."""
    return {
        "state": "PROVISIONED",
        "hostname": "node-example",
        "os_info": {
            "network": [
                {"name": "a-i-eth0", "mac_address": MACS["slo"]},
                {"name": "a-i-eth1", "mac_address": MACS["external"]},
                {"name": "a-i-eth2", "mac_address": MACS["sli"]},
            ]
        },
    }


class RuntimeInterfacesTests(unittest.TestCase):
    def test_current_runtime_order(self):
        result = MODULE.resolve_interfaces(health(), "node-example", MACS)
        self.assertEqual(
            result,
            [
                {"device": "eth0", "mac": MACS["slo"]},
                {"device": "eth1", "mac": MACS["external"]},
                {"device": "eth2", "mac": MACS["sli"]},
            ],
        )

    def test_foreign_node(self):
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(health(), "another-node", MACS)

    def test_not_provisioned(self):
        value = health()
        value["state"] = "INSTALLING"
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_missing_mac(self):
        value = health()
        value["os_info"]["network"].pop()
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_duplicate_mac(self):
        value = health()
        value["os_info"]["network"].append(value["os_info"]["network"][1])
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_duplicate_device(self):
        value = health()
        value["os_info"]["network"][2]["name"] = "a-i-eth1"
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_foreign_management_device(self):
        value = health()
        value["os_info"]["network"][0]["name"] = "a-i-eth2"
        value["os_info"]["network"][2]["name"] = "a-i-eth0"
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_virtual_and_foreign_interfaces_do_not_authorize(self):
        value = health()
        value["os_info"]["network"][2]["name"] = "vhost-int-2"
        with self.assertRaises(ValueError):
            MODULE.resolve_interfaces(value, "node-example", MACS)

    def test_mac_normalization(self):
        value = health()
        value["os_info"]["network"][0]["mac_address"] = "52-54-00-10-00-11"
        self.assertEqual(
            MODULE.resolve_interfaces(value, "node-example", MACS)[0]["mac"],
            MACS["slo"],
        )


if __name__ == "__main__":
    unittest.main()
