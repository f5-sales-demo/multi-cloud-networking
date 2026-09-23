import importlib.util
import pathlib
import unittest
from typing import Any

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "terraform" / "scripts" / "xc-kvm-network-interface.py"
SPEC = importlib.util.spec_from_file_location("xc_kvm_network_interface", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ResolveInterfaceTests(unittest.TestCase):
    def setUp(self):
        self.site: dict[str, Any] = {
            "system_metadata": {"uid": "site-uid-current"},
        }
        self.registrations: dict[str, Any] = {
            "items": [
                {
                    "get_spec": {
                        "infra": {
                            "provider": "KVM",
                            "hostname": "onprem-ce-01-674f7",
                            "hw_info": {
                                "network": [
                                    {
                                        "name": "ens3",
                                        "mac_address": "52:54:00:10:00:11",
                                    },
                                    {
                                        "name": "docker0",
                                        "mac_address": "02:00:00:00:00:01",
                                    },
                                ]
                            },
                        }
                    }
                }
            ]
        }
        self.interfaces: dict[str, Any] = {
            "items": [
                {
                    "name": "stale-interface",
                    "namespace": "system",
                    "owner_view": {
                        "kind": "securemesh_site_v2",
                        "name": "mcn-ce-ha-smsv2-kvm",
                        "namespace": "system",
                        "uid": "site-uid-stale",
                    },
                    "get_spec": {
                        "ethernet_interface": {
                            "node": "onprem-ce-01-674f7",
                            "device": "ens3",
                            "site_local_network": {},
                        }
                    },
                },
                {
                    "name": "ves-io-owned-runtime-interface",
                    "namespace": "system",
                    "owner_view": {
                        "kind": "securemesh_site_v2",
                        "name": "mcn-ce-ha-smsv2-kvm",
                        "namespace": "system",
                        "uid": "site-uid-current",
                    },
                    "get_spec": {
                        "ethernet_interface": {
                            "node": "onprem-ce-01-674f7",
                            "device": "ens3",
                            "site_local_network": {},
                        }
                    },
                },
            ]
        }

    def test_uses_exact_owner_registration_device_and_mac(self):
        result = MODULE.resolve_interface(
            "system",
            "mcn-ce-ha-smsv2-kvm",
            "52:54:00:10:00:11",
            "slo",
            self.site,
            self.registrations,
            self.interfaces,
        )
        self.assertEqual(result["interface_name"], "ves-io-owned-runtime-interface")
        self.assertEqual(result["hostname"], "onprem-ce-01-674f7")
        self.assertEqual(result["device"], "ens3")

    def test_rejects_stale_owner_uid(self):
        self.interfaces["items"] = self.interfaces["items"][:1]
        with self.assertRaises(MODULE.DiscoveryPendingError):
            MODULE.resolve_interface(
                "system",
                "mcn-ce-ha-smsv2-kvm",
                "52:54:00:10:00:11",
                "slo",
                self.site,
                self.registrations,
                self.interfaces,
            )

    def test_rejects_duplicate_owned_registration_mac(self):
        self.registrations["items"].append(self.registrations["items"][0])
        with self.assertRaises(MODULE.DiscoveryPendingError):
            MODULE.resolve_interface(
                "system",
                "mcn-ce-ha-smsv2-kvm",
                "52:54:00:10:00:11",
                "slo",
                self.site,
                self.registrations,
                self.interfaces,
            )

    def test_rejects_inside_interface_for_slo_peer(self):
        owned = self.interfaces["items"][1]
        ethernet = owned["get_spec"]["ethernet_interface"]
        ethernet.pop("site_local_network")
        ethernet["site_local_inside_network"] = {}
        with self.assertRaises(MODULE.DiscoveryPendingError):
            MODULE.resolve_interface(
                "system",
                "mcn-ce-ha-smsv2-kvm",
                "52:54:00:10:00:11",
                "slo",
                self.site,
                self.registrations,
                self.interfaces,
            )

    def test_resolves_owned_inside_interface_for_sli(self):
        self.registrations["items"][0]["get_spec"]["infra"]["hw_info"][
            "network"
        ].append({"name": "ens4", "mac_address": "52:54:00:20:00:11"})
        owned = self.interfaces["items"][1]
        owned["name"] = "ves-io-owned-sli-interface"
        ethernet = owned["get_spec"]["ethernet_interface"]
        ethernet["device"] = "ens4"
        ethernet.pop("site_local_network")
        ethernet["site_local_inside_network"] = {}

        result = MODULE.resolve_interface(
            "system",
            "mcn-ce-ha-smsv2-kvm",
            "52:54:00:20:00:11",
            "sli",
            self.site,
            self.registrations,
            self.interfaces,
        )
        self.assertEqual(result["interface_name"], "ves-io-owned-sli-interface")
        self.assertEqual(result["hostname"], "onprem-ce-01-674f7")
        self.assertEqual(result["device"], "ens4")
        self.assertEqual(result["role"], "sli")

    def test_rejects_slo_interface_when_sli_is_required(self):
        with self.assertRaises(MODULE.DiscoveryPendingError):
            MODULE.resolve_interface(
                "system",
                "mcn-ce-ha-smsv2-kvm",
                "52:54:00:10:00:11",
                "sli",
                self.site,
                self.registrations,
                self.interfaces,
            )

    def test_rejects_unknown_role(self):
        with self.assertRaises(ValueError):
            MODULE.resolve_interface(
                "system",
                "mcn-ce-ha-smsv2-kvm",
                "52:54:00:10:00:11",
                "management",
                self.site,
                self.registrations,
                self.interfaces,
            )


if __name__ == "__main__":
    unittest.main()
