# ruff: noqa: INP001, PT009, PT027
import importlib.util
import json
import pathlib
import subprocess
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "kvm-lan-plan-scope.py"
SPEC = importlib.util.spec_from_file_location("kvm_lan_plan_scope", SCRIPT)
assert SPEC is not None
assert SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def plan(stage, changes, resources):
    return {
        "format_version": "1.2",
        "terraform_version": "1.16.3",
        "variables": {
            "enable_kvm": {"value": True},
            "enable_kvm_lan": {"value": True},
            "kvm_lan_configuration_phase": {"value": stage},
            "kvm_lan": {
                "value": {
                    "bridge": "br-lan-demo",
                    "uplink": "enp2s0",
                    "uplink_mac": "02:00:00:00:10:01",
                    "ownership": "preprovisioned-shared",
                    "mtu": 1500,
                    "sli_mac": "52:54:00:20:00:11",
                    "sli_cidr": "192.0.2.2/24",
                    "vip": "192.0.2.10",
                    "vip_reservation": "lab-ipam-1227",
                    "backend_ip": "192.0.2.20",
                    "backend_owner": "lab-origin",
                    "http_domain": "app.example.com",
                    "access_scope": "authorized-lab-lan",
                    "bridge_preprovisioned": True,
                    "uplink_approved": True,
                    "ipv4_users_reviewed": True,
                    "ipv6_users_reviewed": True,
                    "switch_multi_mac_approved": True,
                    "duplicate_addresses_checked": True,
                }
            },
        },
        "resource_changes": changes,
        "planned_values": {"root_module": {"resources": resources}},
    }


class PlanScopeTests(unittest.TestCase):
    def test_hardware_stage_accepts_initial_two_nic_create(self):
        document = plan(
            "hardware",
            [{"address": 'libvirt_domain.ce_node["01"]', "change": {"actions": ["create"]}}],
            [{"address": 'libvirt_domain.ce_node["01"]', "values": {
                "network_interface": [
                    {"mac": "52:54:00:10:00:11", "network_id": "bgp"},
                    {"mac": "52:54:00:20:00:11", "bridge": "br-lan-demo"},
                ]
            }}],
        )
        self.assertEqual(MODULE.validate_plan(document, "hardware")["domain_action"], "create")
    @patch.object(MODULE.subprocess, "run")
    def test_host_network_verifies_bridge_uplink_mac_and_mtu(self, run):
        run.side_effect = [
            subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps(
                    [
                        {
                            "ifname": "br-lan-demo",
                            "mtu": 1500,
                            "linkinfo": {"info_kind": "bridge"},
                        }
                    ]
                ),
            ),
            subprocess.CompletedProcess(
                [],
                0,
                stdout=json.dumps(
                    [
                        {
                            "ifname": "enp2s0",
                            "address": "02:00:00:00:10:01",
                            "master": "br-lan-demo",
                            "mtu": 1500,
                        }
                    ]
                ),
            ),
        ]
        contract = MODULE.validate_plan(
            plan(
                "hardware",
                [
                    {
                        "address": 'libvirt_domain.ce_node["01"]',
                        "type": "libvirt_domain",
                        "name": "ce_node",
                        "change": {"actions": ["delete", "create"]},
                    }
                ],
                [
                    {
                        "address": 'libvirt_domain.ce_node["01"]',
                        "values": {
                            "network_interface": [
                                {"mac": "52:54:00:10:00:11", "network_id": "bgp"},
                                {
                                    "mac": "52:54:00:20:00:11",
                                    "bridge": "br-lan-demo",
                                },
                            ]
                        },
                    }
                ],
            ),
            "hardware",
        )

        MODULE.verify_host_network(contract)
        self.assertEqual(run.call_count, 2)

    def test_hardware_stage_requires_scoped_domain_replacement(self):
        document = plan(
            "hardware",
            [
                {
                    "address": 'libvirt_domain.ce_node["01"]',
                    "type": "libvirt_domain",
                    "name": "ce_node",
                    "change": {"actions": ["delete", "create"]},
                }
            ],
            [
                {
                    "address": 'libvirt_domain.ce_node["01"]',
                    "values": {
                        "network_interface": [
                            {"mac": "52:54:00:10:00:11", "network_id": "bgp"},
                            {"mac": "52:54:00:20:00:11", "bridge": "br-lan-demo"},
                        ]
                    },
                }
            ],
        )
        receipt = MODULE.validate_plan(document, "hardware")
        self.assertEqual(receipt["change_count"], 1)
        self.assertEqual(receipt["domain_action"], "replace")

    def test_hardware_stage_rejects_update_only_nic_change(self):
        document = plan(
            "hardware",
            [
                {
                    "address": 'libvirt_domain.ce_node["01"]',
                    "type": "libvirt_domain",
                    "name": "ce_node",
                    "change": {"actions": ["update"]},
                }
            ],
            [],
        )
        with self.assertRaisesRegex(ValueError, "create or replace"):
            MODULE.validate_plan(document, "hardware")

    def test_rejects_unrelated_cloud_action(self):
        document = plan(
            "hardware",
            [
                {
                    "address": "aws_instance.workload[0]",
                    "type": "aws_instance",
                    "name": "workload",
                    "change": {"actions": ["update"]},
                }
            ],
            [],
        )
        with self.assertRaisesRegex(ValueError, "outside"):
            MODULE.validate_plan(document, "hardware")

    def test_configured_stage_requires_exact_owned_application_set(self):
        changes = [
            {
                "address": 'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]',
                "type": "xcsh_smsv2_kvm_runtime_interface",
                "name": "kvm_lan_sli",
                "change": {"actions": ["create"]},
            },
            *[
                {
                    "address": f"{resource_type}.kvm_lan[0]",
                    "type": resource_type,
                    "name": "kvm_lan",
                    "change": {"actions": ["create"]},
                }
                for resource_type in (
                    "xcsh_virtual_site",
                    "xcsh_origin_pool",
                    "xcsh_http_loadbalancer",
                )
            ],
        ]
        resources = [
            {
                "address": 'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]',
                "values": {
                    "namespace": "system",
                    "site": "test",
                    "expected_mac": "52:54:00:20:00:11",
                    "ipv4_cidr": "192.0.2.2/24",
                },
            }
        ]
        receipt = MODULE.validate_plan(
            plan("configured", changes, resources), "configured"
        )
        self.assertEqual(receipt["change_count"], 4)
        self.assertEqual(receipt["stage"], "configured")
        self.assertEqual(receipt["schema_version"], "mcn.kvm-lan-preflight/v2")
        self.assertEqual(
            receipt["interface_resource"],
            'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]',
        )

    def test_configured_stage_rejects_missing_origin(self):
        changes = [
            {
                "address": 'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]',
                "type": "xcsh_smsv2_kvm_runtime_interface",
                "name": "kvm_lan_sli",
                "change": {"actions": ["create"]},
            }
        ]
        with self.assertRaisesRegex(ValueError, "missing"):
            MODULE.validate_plan(plan("configured", changes, []), "configured")

    def test_configured_stage_rejects_site_update(self):
        changes = [
            {
                "address": "xcsh_securemesh_site_v2.onprem_kvm[0]",
                "type": "xcsh_securemesh_site_v2",
                "name": "onprem_kvm",
                "change": {"actions": ["update"]},
            }
        ]
        with self.assertRaisesRegex(ValueError, "outside"):
            MODULE.validate_plan(plan("configured", changes, []), "configured")

    def test_configured_stage_rejects_interface_update_instead_of_owned_adoption(self):
        changes = [
            {
                "address": 'xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]',
                "type": "xcsh_smsv2_kvm_runtime_interface",
                "name": "kvm_lan_sli",
                "change": {"actions": ["update"]},
            },
            *[
                {
                    "address": f"{resource_type}.kvm_lan[0]",
                    "type": resource_type,
                    "name": "kvm_lan",
                    "change": {"actions": ["create"]},
                }
                for resource_type in (
                    "xcsh_virtual_site",
                    "xcsh_origin_pool",
                    "xcsh_http_loadbalancer",
                )
            ],
        ]
        with self.assertRaisesRegex(ValueError, "must adopt"):
            MODULE.validate_plan(plan("configured", changes, []), "configured")


if __name__ == "__main__":
    unittest.main()
