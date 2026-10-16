# ruff: noqa: PT009

"""Prevent fixture failures and bypass traffic from passing policy acceptance."""

import json
import shlex
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path
from typing import Any
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from smsv2_traffic_receipt import TrafficTarget, accepted, client_requests, route_to_ce


class TrafficAcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.receipt: dict[str, Any] = {
            "aws_default_route_to_ce": True,
            "requests": [
                {
                    "scheme": scheme,
                    "client_exit": 0,
                    "http_200": True,
                    "body_case_matches": True,
                    "origin_observations": 1,
                    "origin_source_matches_ce_eip": True,
                }
                for scheme in ("http", "https")
            ],
        }

    def test_scoped_http_path_keeps_https_control(self):
        with (
            tempfile.TemporaryDirectory() as directory,
            patch(
                "smsv2_traffic_receipt.subprocess.run",
                return_value=subprocess.CompletedProcess([], 28, b"", b""),
            ) as run,
        ):
            client_requests(
                ["ssh"],
                TrafficTarget(
                    "192.0.2.10", str(Path(directory) / "certificate.pem"), "/deny"
                ),
                Path(directory),
                "scope",
            )
        urls = [
            next(arg for arg in shlex.split(call.args[0][-1]) if arg.startswith(scheme))
            for call, scheme in zip(
                run.call_args_list, ("http://", "https://"), strict=True
            )
        ]
        self.assertTrue(
            urls[0].startswith("http://origin.qualification.test/deny?case=")
        )
        self.assertTrue(
            urls[1].startswith("https://origin.qualification.test/allow?case=")
        )
        self.assertNotEqual(urls[0].split("case=")[1], urls[1].split("case=")[1])

    def test_observed_baseline(self):
        self.assertTrue(accepted(self.receipt, {"http": "allow", "https": "allow"}))

    def test_drop_requires_control(self):
        receipt = deepcopy(self.receipt)
        denied = receipt["requests"][0]
        denied.update(
            client_exit=28,
            http_200=False,
            body_case_matches=False,
            origin_observations=0,
            origin_source_matches_ce_eip=False,
        )
        self.assertTrue(accepted(receipt, {"http": "deny", "https": "allow"}))
        receipt["requests"][1].update(
            client_exit=28, http_200=False, origin_observations=0
        )
        self.assertFalse(accepted(receipt, {"http": "deny", "https": "deny"}))

    def test_bypass_never_passes(self):
        self.receipt["aws_default_route_to_ce"] = False
        self.assertFalse(accepted(self.receipt, {"http": "allow", "https": "allow"}))

    def test_foreign_source_never_passes(self):
        self.receipt["requests"][0]["origin_source_matches_ce_eip"] = False
        self.assertFalse(accepted(self.receipt, {"http": "allow", "https": "allow"}))

    def test_stale_or_duplicate_response_never_passes(self):
        for key, value in (("body_case_matches", False), ("origin_observations", 2)):
            with self.subTest(key=key):
                receipt = deepcopy(self.receipt)
                receipt["requests"][0][key] = value
                self.assertFalse(accepted(receipt, {"http": "allow", "https": "allow"}))

    def test_ssh_failure_is_not_a_policy_drop(self):
        self.receipt["requests"][0].update(
            client_exit=255, http_200=False, origin_observations=0
        )
        self.assertFalse(accepted(self.receipt, {"http": "deny", "https": "allow"}))

    def test_azure_route_requires_owned_active_user_next_hop(self):
        facts = {"client_nic": "task-owned-nic", "ce_sli_ip": "192.0.2.4"}
        route = {
            "source": "User",
            "state": "Active",
            "nextHopType": "VirtualAppliance",
            "addressPrefix": ["0.0.0.0/0"],
            "nextHopIpAddress": ["192.0.2.4"],
        }
        with patch(
            "smsv2_traffic_receipt.subprocess.check_output",
            return_value=json.dumps({"value": [route]}).encode(),
        ):
            self.assertTrue(route_to_ce(facts, "azure"))
        for key, value in (
            ("state", "Invalid"),
            ("source", "Default"),
            ("nextHopIpAddress", ["192.0.2.5"]),
        ):
            with self.subTest(key=key):
                wrong = {**route, key: value}
                with patch(
                    "smsv2_traffic_receipt.subprocess.check_output",
                    return_value=json.dumps({"value": [wrong]}).encode(),
                ):
                    self.assertFalse(route_to_ce(facts, "azure"))

    def test_azure_source_and_generic_route_receipt(self):
        receipt = deepcopy(self.receipt)
        receipt.pop("aws_default_route_to_ce")
        receipt["ce_default_route_verified"] = True
        for request in receipt["requests"]:
            request["origin_source_matches_ce_public_ip"] = request.pop(
                "origin_source_matches_ce_eip"
            )
        self.assertTrue(accepted(receipt, {"http": "allow", "https": "allow"}))


if __name__ == "__main__":
    unittest.main()
