"""Guard the event-stream fallback used for one legacy production teardown."""
# pylint: disable=missing-class-docstring,missing-function-docstring,duplicate-code
# ruff: noqa: INP001, PT009, PT018, PT027

import importlib.util
import json
import unittest
from pathlib import Path

SCRIPT = (
    Path(__file__).resolve().parents[1] / "scripts/showcase-legacy-destroy-scope.py"
)
spec = importlib.util.spec_from_file_location("showcase_legacy_destroy_scope", SCRIPT)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

LEGACY = {
    "deployer": "operator",
    "environment": "lab",
    "generation": "smsv2-current",
    "tenant": "f5-sales-demo",
}


def fixture():
    """Make a complete legacy state and its one-action destroy stream."""
    state = {
        "resources": [
            {
                "mode": "data",
                "type": "xcsh_site_upgrade_status",
                "instances": [{"attributes": {"namespace": "system"}}],
            },
            {
                "mode": "managed",
                "type": "aws_vpc",
                "name": "aws",
                "instances": [
                    {
                        "index_key": 0,
                        "attributes": {
                            "tags": {
                                "component": "mcn-ce-ha",
                                "environment": "lab",
                                "deployer": "operator",
                                "managed_by": "terraform",
                            }
                        },
                    }
                ],
            },
        ]
    }
    events = [
        {
            "type": "planned_change",
            "change": {"resource": {"addr": "aws_vpc.aws[0]"}, "action": "delete"},
        },
        {
            "type": "change_summary",
            "changes": {"remove": 1, "add": 0, "change": 0, "import": 0},
        },
    ]
    return state, events


def check(state, events):
    """Call the validator with serialized Terraform machine events."""
    return module.verify(
        state,
        [json.dumps(event) for event in events],
        LEGACY,
        "showcase-team",
        "production",
    )


class LegacyDestroyScopeTest(unittest.TestCase):
    def test_exact_owned_delete_set(self):
        state, events = fixture()
        self.assertEqual(check(state, events), 1)

    def test_missing_and_foreign_actions(self):
        state, events = fixture()
        with self.assertRaisesRegex(ValueError, "scope mismatch"):
            check(state, events[1:])
        events[0]["change"]["resource"]["addr"] = "aws_vpc.foreign[0]"
        with self.assertRaisesRegex(ValueError, "scope mismatch"):
            check(state, events)

    def test_nondelete_and_shared_host_action(self):
        state, events = fixture()
        events[0]["change"]["action"] = "create"
        with self.assertRaisesRegex(ValueError, "non-delete"):
            check(state, events)
        events[0]["change"] = {
            "resource": {"addr": "terraform_data.host_bridge[0]"},
            "action": "delete",
        }
        with self.assertRaisesRegex(ValueError, "shared host networking"):
            check(state, events)

    def test_owner_and_schema_required(self):
        state, events = fixture()
        state["resources"][1]["instances"][0]["attributes"]["tags"]["deployer"] = (
            "foreign"
        )
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            check(state, events)
        state, events = fixture()
        del state["resources"][0]["instances"][0]["attributes"]["namespace"]
        with self.assertRaisesRegex(ValueError, "exact stale"):
            check(state, events)

    def test_summary_and_action_invocation_required(self):
        state, events = fixture()
        events[1]["changes"]["remove"] = 2
        with self.assertRaisesRegex(ValueError, "summary"):
            check(state, events)
        state, events = fixture()
        events.insert(
            1,
            {
                "type": "planned_action_invocation",
                "action": {"addr": "action.xcsh_site_upgrade_sw.aws"},
            },
        )
        with self.assertRaisesRegex(ValueError, "provider action invocation"):
            check(state, events)

    def test_kvm_poc_bgp_requires_exact_legacy_owner_and_site(self):
        state, events = fixture()
        resource = state["resources"][1]
        resource["type"] = "xcsh_bgp"
        resource["name"] = "onprem_ebgp"
        resource["instances"][0]["attributes"] = {
            "name": "onprem-kvm-ebgp",
            "namespace": "system",
            "labels": {
                "mcn-owner-id": "kvm-poc",
                "mcn-environment": "production",
                "mcn-deployment-generation": "smsv2-current",
                "mcn-xc-tenant": "f5-sales-demo",
                "mcn-topology": "mcn-ce-ha-smsv2-current-kvm",
            },
            "where": {
                "site": {
                    "ref": [
                        {
                            "name": "mcn-ce-ha-smsv2-current-kvm",
                            "namespace": "system",
                        }
                    ]
                }
            },
        }
        events[0]["change"]["resource"]["addr"] = "xcsh_bgp.onprem_ebgp[0]"
        self.assertEqual(check(state, events), 1)
        resource["instances"][0]["attributes"]["labels"]["mcn-owner-id"] = "foreign"
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            check(state, events)
        resource["instances"][0]["attributes"]["labels"]["mcn-owner-id"] = "kvm-poc"
        resource["instances"][0]["attributes"]["where"]["site"]["ref"][0]["name"] = (
            "foreign"
        )
        with self.assertRaisesRegex(ValueError, "ownership marker mismatch"):
            check(state, events)


if __name__ == "__main__":
    unittest.main()
