import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class ExtractionTests(unittest.TestCase):
    def test_canada_has_no_resources_or_inputs(self):
        source = "\n".join(p.read_text() for p in (ROOT / "terraform").glob("*.tf"))
        self.assertNotIn('variable "enable_canada"', source)
        self.assertNotIn('module "azure_hub_ca"', source)
        self.assertNotIn('module "ce_node_ca"', source)
        self.assertNotIn('resource "xcsh_origin_pool" "canada"', source)
        self.assertNotIn("module.ce_node_ca", source)
        self.assertIn('resource "xcsh_token" "ce"', source)
        self.assertIn('backend "s3"', source)
        self.assertIn('f5xc_customer_edge_marketplace_agreement', source)

    def test_lifecycle_does_not_depend_on_canada(self):
        source = (ROOT / "scripts/showcase-lifecycle.sh").read_text()
        self.assertNotIn("ca_xc_site_names", source)
        self.assertNotIn("enable_canada", source)
        self.assertNotIn("verify-canadian-public-re.py", source)


if __name__ == "__main__":
    unittest.main()
