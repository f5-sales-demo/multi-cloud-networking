"""Regression coverage for immutable provider acceptance."""

# pylint: disable=invalid-name
# ruff: noqa: INP001, PT027
import ast
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
                "release_tag": "v9.0.2",
                "version": "9.0.2",
                "target_commit": provider.SPEC_COMMIT,
            }
        ).encode()
        self.artifact = b"synthetic published ZIP"
        self.receipt = {
            "tag": "v12.4.0",
            "version": "12.4.0",
            "commit": provider.COMMIT,
            "spec_release_sha256": provider.SPEC_SHA256,
            "assets": {provider.ZIP_NAME: "sha256:" + provider.ZIP_SHA256},
        }

    def release(self):
        return {
            "tagName": "v12.4.0",
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


class SavedPlanArtifactIdentityTests(unittest.TestCase):
    def test_all_scope_gates_pin_verified_publication_artifact(self):
        repository = Path(__file__).resolve().parents[1]
        for name in ("showcase-plan-scope.py", "showcase-legacy-destroy-scope.py"):
            with self.subTest(script=name):
                tree = ast.parse((repository / "scripts" / name).read_text())
                values = [
                    ast.literal_eval(node.value)
                    for node in tree.body
                    if isinstance(node, ast.Assign)
                    and any(
                        isinstance(target, ast.Name) and target.id == "PROVIDER_SHA256"
                        for target in node.targets
                    )
                ]
                assert values == [provider.ZIP_SHA256]
