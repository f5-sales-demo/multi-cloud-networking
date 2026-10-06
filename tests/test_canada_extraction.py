# ruff: noqa: INP001
import json
import re
import shutil
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ExtractionTests(unittest.TestCase):
    def test_canada_has_no_resources_or_inputs(self):
        source = "\n".join(p.read_text() for p in (ROOT / "terraform").glob("*.tf"))
        assert 'variable "enable_canada"' not in source
        assert 'module "azure_hub_ca"' not in source
        assert 'module "ce_node_ca"' not in source
        assert 'resource "xcsh_origin_pool" "canada"' not in source
        assert "module.ce_node_ca" not in source
        assert 'resource "xcsh_token" "ce"' in source
        assert 'backend "s3"' in source
        assert "f5xc_customer_edge_marketplace_agreement" in source

    def test_lifecycle_does_not_depend_on_canada(self):
        source = (ROOT / "scripts/showcase-lifecycle.sh").read_text()
        assert "ca_xc_site_names" not in source
        assert "enable_canada" not in source
        assert "verify-canadian-public-re.py" not in source

    def test_saved_plan_and_aws_helpers_have_no_canada_inputs(self):
        for relative in [
            "scripts/showcase-plan-scope.py",
            "scripts/aws-smsv2-lifecycle-plan.sh",
            "scripts/aws-smsv2-uat-preflight.sh",
        ]:
            assert "enable_canada" not in (ROOT / relative).read_text()

    def test_lifecycle_enabled_paths_match_current_graph(self):
        source = (ROOT / "scripts/showcase-lifecycle.sh").read_text()
        pattern = r"jq -e '([^']+)' <<<\"\$INPUT_VALUES_JSON\""
        expressions = re.findall(pattern, source)
        predicate = next(value for value in expressions if ".flags |" in value)
        enabled = dict.fromkeys(
            ["aws", "azure", "bgp", "kvm", "kvm_lan", "us_ilb"], True
        )
        rejected = [
            {key: value for key, value in enabled.items() if key != "azure"},
            {**enabled, "canada": True},
            {**enabled, "kvm_lan": False},
        ]
        jq = shutil.which("jq")
        assert jq is not None
        for flags, expected in [(enabled, 0), *[(item, 1) for item in rejected]]:
            with self.subTest(flags=flags):
                result = subprocess.run(  # noqa: S603 - tracked jq predicate, no shell
                    [jq, "-e", predicate],
                    input=json.dumps({"flags": flags}),
                    text=True,
                    capture_output=True,
                    check=False,
                )
                assert result.returncode == expected, result.stderr


if __name__ == "__main__":
    unittest.main()
