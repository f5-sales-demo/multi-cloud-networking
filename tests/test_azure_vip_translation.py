"""Only active CE-learned VIP paths may authorize relay translation."""

# ruff: noqa: INP001, PT009, PT027
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "relay", ROOT / "terraform/modules/azure-frr/vip_translation.py"
)
assert SPEC
assert SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
VIP = "10.250.0.10/32"
CE = ["10.0.1.4", "10.0.1.5", "10.0.1.6"]


def routes():
    """A route with one active owned CE next hop."""
    return {
        "prefix": VIP,
        "paths": [
            {
                "valid": True,
                "peer": {"peerId": CE[0]},
                "nexthops": [{"ip": CE[0], "accessible": True, "used": True}],
            }
        ],
    }


class TranslationTests(unittest.TestCase):
    def test_owned_active_route(self):
        self.assertEqual(MODULE.eligible_backends(routes(), VIP, CE), [CE[0]])

    def test_absent_route_removes_translation(self):
        self.assertEqual(MODULE.eligible_backends({}, VIP, CE), [])

    def test_foreign_prefix(self):
        value = routes()
        value["prefix"] = "10.250.1.10/32"
        with self.assertRaises(ValueError):
            MODULE.eligible_backends(value, VIP, CE)

    def test_foreign_peer(self):
        value = routes()
        value["paths"][0]["peer"]["peerId"] = "10.0.4.4"
        self.assertEqual(MODULE.eligible_backends(value, VIP, CE), [])

    def test_inactive_next_hop(self):
        value = routes()
        value["paths"][0]["nexthops"][0]["accessible"] = False
        self.assertEqual(MODULE.eligible_backends(value, VIP, CE), [])

    def test_invalid_bgp_path(self):
        value = routes()
        value["paths"][0]["valid"] = False
        self.assertEqual(MODULE.eligible_backends(value, VIP, CE), [])

    def test_all_active_ce_paths(self):
        value = routes()
        value["paths"] *= 3
        for index, ip in enumerate(CE):
            value["paths"][index] = {
                "valid": True,
                "peer": {"peerId": ip},
                "nexthops": [{"ip": ip, "accessible": True, "used": True}],
            }
        self.assertEqual(MODULE.eligible_backends(value, VIP, CE), CE)

    def test_malformed_path_rejected(self):
        value = routes()
        value["paths"] = "invalid"
        with self.assertRaises(ValueError):
            MODULE.eligible_backends(value, VIP, CE)


if __name__ == "__main__":
    unittest.main()
