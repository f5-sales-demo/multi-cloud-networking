"""Canadian public RE isolation acceptance regression tests."""

# pylint: disable=invalid-name,missing-class-docstring,missing-function-docstring
# ruff: noqa: INP001, PT009, PT027
import copy
import importlib.util
import unittest
from pathlib import Path

SPEC = importlib.util.spec_from_file_location(
    "canadian_re",
    Path(__file__).resolve().parents[1] / "scripts/verify-canadian-public-re.py",
)
assert SPEC is not None
assert SPEC.loader is not None
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class CanadianRETests(unittest.TestCase):
    def setUp(self):
        self.config = {
            "allocation": {
                "name": "ip-example",
                "namespace": "shared",
                "ip": "192.0.2.55",
            },
            "virtual_site": "canada",
            "ce_virtual_site": "canada-ce",
            "namespace": "demo",
            "ce_sites": ["ca1", "ca2", "ca3"],
            "domain": "canada.example.com",
            "pool": "canada-pool",
            "origin_ip": "192.0.2.30",
        }
        self.objects = {
            "public_ip": {
                "spec": {
                    "ip": "192.0.2.55",
                    "virtual_sites": [{"name": "canada", "namespace": "demo"}],
                }
            },
            "virtual_site": {
                "spec": {
                    "site_type": "REGIONAL_EDGE",
                    "site_selector": {"expressions": module.SELECTOR},
                }
            },
            "selectees": {"items": [{"name": name} for name in module.ALLOWED_RE]},
            "ce_selectees": {
                "items": [{"name": name} for name in self.config["ce_sites"]]
            },
            "loadbalancer": {
                "spec": {
                    "domains": ["canada.example.com"],
                    "add_location": True,
                    "advertise_custom": {
                        "advertise_where": [
                            {
                                "advertise_on_public": {
                                    "public_ip": {
                                        "name": "ip-example",
                                        "namespace": "shared",
                                    }
                                }
                            },
                            *[
                                {"site": {"site": {"name": site}}}
                                for site in ["ca1", "ca2", "ca3"]
                                for _ in range(2)
                            ],
                        ]
                    },
                    "default_route_pools": [
                        {"pool": {"name": "canada-pool", "namespace": "demo"}}
                    ],
                }
            },
            "pool": {
                "spec": {
                    "endpoint_selection": "DISTRIBUTED",
                    "origin_servers": [
                        {
                            "private_ip": {
                                "ip": "192.0.2.30",
                                "site_locator": {
                                    "virtual_site": {
                                        "name": "canada-ce",
                                        "namespace": "demo",
                                    }
                                },
                            }
                        }
                    ],
                }
            },
        }

    def test_exact_configuration_passes(self):
        module.validate_configuration(self.config, self.objects)

    def test_foreign_binding_listener_pool_and_origin_are_rejected(self):
        mutations = [
            lambda value: value["public_ip"]["spec"]["virtual_sites"].append(
                {"name": "all"}
            ),
            lambda value: value["selectees"]["items"].append({"name": "us-edge"}),
            lambda value: value["ce_selectees"]["items"].append({"name": "us-ce"}),
            lambda value: value["loadbalancer"]["spec"]["advertise_custom"][
                "advertise_where"
            ][1]["site"]["site"].update(name="us-ce"),
            lambda value: value["loadbalancer"]["spec"]["default_route_pools"][0][
                "pool"
            ].update(name="us-pool"),
            lambda value: value["pool"]["spec"]["origin_servers"][0][
                "private_ip"
            ].update(ip="192.0.2.31"),
            lambda value: value["pool"]["spec"].update(endpoint_selection="LOCAL_ONLY"),
        ]
        for mutation in mutations:
            value = copy.deepcopy(self.objects)
            mutation(value)
            with self.assertRaises(ValueError):
                module.validate_configuration(self.config, value)

    def test_response_requires_canadian_marker_and_location(self):
        for edge in module.ALLOWED_RE:
            self.assertEqual(
                module.validate_response(
                    b"mcn-showcase-canada-origin",
                    f"X-Volterra-Location: {edge}",
                    "mcn-showcase-canada-origin",
                ),
                edge,
            )
        for body, headers in [
            (b"mcn-showcase-origin", "X-Volterra-Location: tr2-tor"),
            (b"mcn-showcase-canada-origin", "X-Volterra-Location: us-edge"),
            (b"mcn-showcase-canada-origin", ""),
        ]:
            with self.assertRaises(ValueError):
                module.validate_response(body, headers, "mcn-showcase-canada-origin")
