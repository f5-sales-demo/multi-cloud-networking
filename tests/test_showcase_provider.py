"""Regression coverage for immutable provider acceptance."""

# pylint: disable=invalid-name
# ruff: noqa: INP001, PT027
import importlib.util
import json
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "showcase_provider",
    Path(__file__).resolve().parents[1] / "scripts/verify-showcase-provider.py",
)
assert SPEC is not None
assert SPEC.loader is not None
provider = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(provider)


class ProviderIdentityTests(unittest.TestCase):
    def setUp(self):
        self.api = json.dumps(
            {
                "release_tag": "v9.0.1",
                "version": "9.0.1",
                "target_commit": provider.SPEC_COMMIT,
            }
        ).encode()
        self.artifact = b"synthetic published ZIP"
        self.receipt = {
            "tag": "v12.3.0",
            "version": "12.3.0",
            "commit": provider.COMMIT,
            "spec_release_sha256": provider.SPEC_SHA256,
            "assets": {provider.ZIP_NAME: "sha256:" + provider.ZIP_SHA256},
        }

    def release(self):
        return {
            "tagName": "v12.3.0",
            "body": "<!-- provider-publication-receipt:"
            + json.dumps(self.receipt)
            + " -->",
        }

    def test_wrong_artifact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "artifact digest mismatch"):
            provider.validate_identity(self.release(), self.api, self.artifact)

    def test_wrong_source_is_rejected(self):
        self.receipt["commit"] = "0" * 40
        with self.assertRaisesRegex(ValueError, "publication identity mismatch"):
            provider.validate_identity(self.release(), self.api, self.artifact)

    def test_duplicate_receipt_is_rejected(self):
        release = self.release()
        release["body"] *= 2
        with self.assertRaisesRegex(ValueError, "exactly once"):
            provider.validate_identity(release, self.api, self.artifact)

    def test_wrong_api_digest_is_rejected(self):
        with patch.object(
            provider, "ZIP_SHA256", provider.hashlib.sha256(self.artifact).hexdigest()
        ):
            self.receipt["assets"][provider.ZIP_NAME] = "sha256:" + provider.ZIP_SHA256
            with self.assertRaisesRegex(ValueError, "API receipt digest mismatch"):
                provider.validate_identity(self.release(), self.api, self.artifact)

    def test_verified_identities_pass_and_old_api_is_rejected(self):
        with (
            patch.object(
                provider,
                "ZIP_SHA256",
                provider.hashlib.sha256(self.artifact).hexdigest(),
            ),
            patch.object(
                provider, "SPEC_SHA256", provider.hashlib.sha256(self.api).hexdigest()
            ),
        ):
            self.receipt["assets"][provider.ZIP_NAME] = "sha256:" + provider.ZIP_SHA256
            self.receipt["spec_release_sha256"] = provider.SPEC_SHA256
            provider.validate_identity(self.release(), self.api, self.artifact)
            with (
                patch.object(provider, "SPEC_COMMIT", "0" * 40),
                self.assertRaisesRegex(ValueError, "API release identity mismatch"),
            ):
                provider.validate_identity(self.release(), self.api, self.artifact)
