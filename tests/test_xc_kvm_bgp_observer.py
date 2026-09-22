# ruff: noqa: INP001, PT009, PT027
import importlib.util
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "terraform" / "scripts" / "xc-kvm-bgp-observer.py"
SPEC = importlib.util.spec_from_file_location("xc_kvm_bgp_observer", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def peer_document(node="obelix", address="10.100.0.2", state="Established"):
    return {
        "ver": [
            {
                "name": node,
                "peer": [
                    {
                        "peer_address": {"ipv4": {"addr": address}},
                        "protocol_status": state,
                        "up_down_timestamp": "2026-09-22T16:00:00Z",
                        "received_prefix_count": 1,
                        "advertised_prefix_count": 1,
                    }
                ],
            }
        ]
    }


def route_document(node="obelix", address="10.100.0.2", subnet="198.51.100.0/24"):
    return {
        "ver": [
            {
                "name": node,
                "ri_table": [
                    {
                        "rt_table": [
                            {
                                "imported": [
                                    {
                                        "subnet": subnet,
                                        "path": [{"peer": {"ipv4": address}}],
                                    }
                                ]
                            }
                        ]
                    }
                ],
            }
        ]
    }


class ResolveBGPObservationTests(unittest.TestCase):
    def test_accepts_one_established_peer_and_exact_imported_route(self):
        result = MODULE.resolve_bgp_observation(
            "obelix", "10.100.0.2", "198.51.100.0/24", peer_document(), route_document()
        )
        self.assertEqual(result["node"], "obelix")
        self.assertEqual(result["peer_address"], "10.100.0.2")
        self.assertEqual(result["state"], "Established")
        self.assertEqual(result["imported_route"], "198.51.100.0/24")
        self.assertEqual(result["converged"], "true")

    def test_rejects_mismatched_registered_node(self):
        with self.assertRaisesRegex(MODULE.ObservationPendingError, "resolved to 0"):
            MODULE.resolve_bgp_observation(
                "obelix",
                "10.100.0.2",
                "198.51.100.0/24",
                peer_document(node="foreign"),
                route_document(),
            )

    def test_rejects_duplicate_peer_observations(self):
        peers = peer_document()
        peers["ver"][0]["peer"].append(peers["ver"][0]["peer"][0].copy())
        with self.assertRaisesRegex(MODULE.ObservationPendingError, "resolved to 2"):
            MODULE.resolve_bgp_observation(
                "obelix", "10.100.0.2", "198.51.100.0/24", peers, route_document()
            )

    def test_rejects_malformed_observation(self):
        with self.assertRaisesRegex(ValueError, "ver observations"):
            MODULE.resolve_bgp_observation(
                "obelix", "10.100.0.2", "198.51.100.0/24", {}, route_document()
            )

    def test_rejects_non_established_peer(self):
        with self.assertRaisesRegex(MODULE.ObservationPendingError, "state is Idle"):
            MODULE.resolve_bgp_observation(
                "obelix",
                "10.100.0.2",
                "198.51.100.0/24",
                peer_document(state="Idle"),
                route_document(),
            )

    def test_rejects_route_from_another_peer(self):
        with self.assertRaisesRegex(MODULE.ObservationPendingError, "imported route"):
            MODULE.resolve_bgp_observation(
                "obelix",
                "10.100.0.2",
                "198.51.100.0/24",
                peer_document(),
                route_document(address="10.100.0.3"),
            )


if __name__ == "__main__":
    unittest.main()
