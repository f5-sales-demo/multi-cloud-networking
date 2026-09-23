# ruff: noqa: INP001, PT009, PT027, S105
import importlib.util
import json
import pathlib
import stat
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "kvm-lan-live-acceptance.py"
SPEC = importlib.util.spec_from_file_location("kvm_lan_live_acceptance", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def config():
    return {
        "schema_version": "mcn.kvm-lan-live-acceptance.config/v1",
        "source": {
            "ref": "refs/heads/feature/1230-kvm-live-acceptance",
            "commit_sha": "a" * 40,
        },
        "plan": {
            "sha256": "sha256:" + "b" * 64,
            "preflight_schema": "mcn.kvm-lan-preflight/v1",
            "preflight_bound": True,
        },
        "host": {
            "bridge": "br-lan-demo",
            "uplink": "enp2s0",
            "uplink_mac": "02:00:00:00:10:01",
            "mtu": 1500,
            "management_interface": "enp5s0",
            "default_gateway4": "192.0.2.1",
            "allowed_uplink_ipv4": [],
            "allowed_uplink_ipv6": [],
        },
        "vm": {
            "domain": "onprem-ce-01",
            "vcpus": 8,
            "memory_kib": 33554432,
            "disk_min_bytes": 107374182400,
            "slo_mac": "52:54:00:10:00:11",
            "sli_mac": "52:54:00:20:00:11",
            "dhcp_ipv4": "10.100.0.11",
        },
        "xc": {
            "site_name": "onprem-workstation-kvm",
            "imported_route": "10.100.0.100/32",
            "bgp_peer": "10.100.0.11",
        },
        "frr": {
            "container": "mcn-kvm-frr-router",
            "peer": "10.100.0.11",
            "advertised_routes": ["10.100.0.100/32"],
            "received_routes": [],
        },
        "client": {
            "http_domain": "app.example.com",
            "vip": "192.0.2.10",
            "response_sha256": "c" * 64,
            "http_status": 200,
        },
    }


def observations():
    return {
        "schema_version": "mcn.kvm-lan-live-acceptance.observation/v1",
        "source": {
            "ref": "refs/heads/feature/1230-kvm-live-acceptance",
            "commit_sha": "a" * 40,
            "clean": True,
        },
        "plan": {
            "sha256": "sha256:" + "b" * 64,
            "preflight_schema": "mcn.kvm-lan-preflight/v1",
            "preflight_bound": True,
        },
        "host": {
            "links": {
                "br-lan-demo": {
                    "kind": "bridge",
                    "mtu": 1500,
                    "up": True,
                },
                "enp2s0": {
                    "mac": "02:00:00:00:10:01",
                    "master": "br-lan-demo",
                    "mtu": 1500,
                    "up": True,
                },
            },
            "addresses": {"enp2s0": {"ipv4": [], "ipv6": []}},
            "default_routes": [
                {
                    "family": "ipv4",
                    "dev": "enp5s0",
                    "gateway": "192.0.2.1",
                }
            ],
            "libvirt_network_bridges": ["virbr-mcn"],
            "dhcp_interfaces": ["virbr-mcn"],
        },
        "vm": {
            "domain": "onprem-ce-01",
            "state": "running",
            "autostart": True,
            "vcpus": 8,
            "memory_kib": 33554432,
            "disk_capacity_bytes": 107374182400,
            "macs": ["52:54:00:10:00:11", "52:54:00:20:00:11"],
            "ipv4": ["10.100.0.11"],
        },
        "xc": {
            "registration_count": 1,
            "online_count": 1,
            "mapping_valid": True,
            "bgp_converged": True,
            "bgp_session_count": 1,
            "lan_phase": "configured",
            "lan_site_name": "onprem-workstation-kvm",
            "slo_device": "eth0",
            "sli_device": "eth1",
            "realized_sli": "eth1",
        },
        "frr": {
            "container": "mcn-kvm-frr-router",
            "running": True,
            "peer": "10.100.0.11",
            "state": "Established",
            "advertised_routes": ["10.100.0.100/32"],
            "received_routes": [],
        },
        "client": {
            "dns_addresses": ["192.0.2.10"],
            "connected_ip": "192.0.2.10",
            "host_header": "app.example.com",
            "http_status": 200,
            "response_sha256": "c" * 64,
        },
        "terraform": {
            "zero_change": True,
            "zero_change_plan_sha256": "sha256:" + "d" * 64,
        },
    }


def failed_ids(receipt):
    return {check["id"] for check in receipt["checks"] if check["status"] != "passed"}


class AcceptanceTests(unittest.TestCase):
    def test_complete_evidence_passes(self):
        receipt = MODULE.evaluate(config(), observations())
        self.assertEqual(receipt["status"], "passed")
        self.assertTrue(all(check["status"] == "passed" for check in receipt["checks"]))

    def test_missing_bridge_and_existing_ipv6_fail_closed(self):
        observed = observations()
        del observed["host"]["links"]["br-lan-demo"]
        observed["host"]["addresses"]["enp2s0"]["ipv6"] = ["2001:db8::10/64"]
        receipt = MODULE.evaluate(config(), observed)
        self.assertEqual(receipt["status"], "failed")
        self.assertIn("host_bridge", failed_ids(receipt))
        self.assertIn("uplink_addresses", failed_ids(receipt))

    def test_management_default_route_must_not_move(self):
        observed = observations()
        observed["host"]["default_routes"][0]["dev"] = "br-lan-demo"
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("management_route", failed_ids(receipt))

    def test_vm_shape_and_ordered_macs_are_exact(self):
        observed = observations()
        observed["vm"]["vcpus"] = 4
        observed["vm"]["macs"].reverse()
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("vm_resources", failed_ids(receipt))
        self.assertIn("vm_nics", failed_ids(receipt))

    def test_stale_source_and_plan_are_rejected(self):
        observed = observations()
        observed["source"]["commit_sha"] = "e" * 40
        observed["source"]["clean"] = False
        observed["plan"]["sha256"] = "sha256:" + "f" * 64
        observed["plan"]["preflight_bound"] = False
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("source_identity", failed_ids(receipt))
        self.assertIn("saved_plan", failed_ids(receipt))

    def test_nonzero_plan_fails(self):
        observed = observations()
        observed["terraform"]["zero_change"] = False
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("terraform_convergence", failed_ids(receipt))

    def test_xc_mapping_online_and_bgp_each_fail_closed(self):
        observed = observations()
        observed["xc"]["online_count"] = 0
        observed["xc"]["mapping_valid"] = False
        observed["xc"]["bgp_converged"] = False
        observed["xc"]["bgp_session_count"] = 0
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("xc_site", failed_ids(receipt))
        self.assertIn("xc_interfaces", failed_ids(receipt))
        self.assertIn("xc_bgp", failed_ids(receipt))

    def test_frr_routes_are_exact(self):
        observed = observations()
        observed["frr"]["advertised_routes"] = []
        observed["frr"]["received_routes"] = ["192.0.2.0/24"]
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("frr_routes", failed_ids(receipt))

    def test_independent_client_must_prove_dns_vip_host_and_response(self):
        observed = observations()
        observed["client"].update(
            {
                "dns_addresses": ["192.0.2.11"],
                "connected_ip": "192.0.2.11",
                "host_header": "wrong.example.com",
                "http_status": 503,
                "response_sha256": "0" * 64,
            }
        )
        receipt = MODULE.evaluate(config(), observed)
        self.assertIn("client_dns_vip", failed_ids(receipt))
        self.assertIn("client_http", failed_ids(receipt))

    def test_receipt_is_atomic_private_and_refuses_stale_target(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory) / "receipt.json"
            MODULE.write_receipt(target, MODULE.evaluate(config(), observations()))
            self.assertEqual(stat.S_IMODE(target.stat().st_mode), 0o600)
            with target.open(encoding="utf-8") as stream:
                self.assertEqual(json.load(stream)["status"], "passed")
            with self.assertRaisesRegex(FileExistsError, "already exists"):
                MODULE.write_receipt(target, MODULE.evaluate(config(), observations()))

    def test_receipt_never_copies_secret_fields(self):
        expected = config()
        observed = observations()
        expected["api_token"] = "super-secret-api-token"
        observed["private_key"] = "-----BEGIN PRIVATE KEY-----"
        encoded = json.dumps(MODULE.evaluate(expected, observed))
        self.assertNotIn("super-secret", encoded)
        self.assertNotIn("PRIVATE KEY", encoded)

    def test_inventory_without_reviewed_config_is_blocked(self):
        receipt = MODULE.inventory_receipt(
            {
                "host": {
                    "links": {"enp3s0": {"up": True}},
                    "addresses": {"enp3s0": {"ipv4": [], "ipv6": ["2001:db8::10/64"]}},
                    "default_routes": [],
                },
                "vms": ["onprem-ce-01", "onprem-workload"],
                "containers": ["mcn-kvm-frr-router"],
            }
        )
        self.assertEqual(receipt["status"], "blocked")
        self.assertEqual(receipt["checks"][0]["id"], "reviewed_configuration")
        self.assertNotIn("super-secret", json.dumps(receipt))


if __name__ == "__main__":
    unittest.main()
