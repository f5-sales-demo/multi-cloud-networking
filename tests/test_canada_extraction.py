# ruff: noqa: INP001
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


if __name__ == "__main__":
    unittest.main()
