"""Unit tests for deterministic deployment identity and provenance."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import unittest
from typing import Any, ClassVar

ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "deployment-identity.py"


def load_module():
    spec = importlib.util.spec_from_file_location("deployment_identity", SCRIPT)
    if spec is None or spec.loader is None:
        message = "cannot load deployment identity module"
        raise RuntimeError(message)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


class DeploymentIdentityTests(unittest.TestCase):
    module: ClassVar[Any]

    @classmethod
    def setUpClass(cls) -> None:
        cls.module = load_module()

    def identity(self, ref: str, commit: str = "a" * 40):
        return self.module.build_identity(
            repository="f5-sales-demo/multi-cloud-networking",
            source_ref=ref,
            source_commit=commit,
            owner_id="showcase-team",
            actor_id="github-actions",
        )

    def test_exact_main_is_only_production_identity(self) -> None:
        main = self.identity("refs/heads/main")
        self.assertTrue(main["production"])
        self.assertEqual(main["environmentKey"], "production")
        self.assertEqual(main["stateKey"], "mcn-ce-ha-smsv2/showcase.tfstate")
        for ref in (
            "refs/heads/Main",
            "refs/heads/prod",
            "refs/heads/production",
        ):
            candidate = self.identity(ref)
            self.assertFalse(candidate["production"])
            self.assertNotEqual(candidate["environmentKey"], "production")

    def test_normalized_slugs_keep_distinct_full_ref_hashes(self) -> None:
        slash = self.identity("refs/heads/feature/a")
        hyphen = self.identity("refs/heads/feature-a")
        underscore = self.identity("refs/heads/feature_a")
        self.assertEqual(
            {value["readableSlug"] for value in (slash, hyphen, underscore)},
            {"feature-a"},
        )
        self.assertEqual(
            len({value["environmentKey"] for value in (slash, hyphen, underscore)}),
            3,
        )

    def test_unicode_empty_and_long_refs_are_bounded(self) -> None:
        unicode_only = self.identity("refs/heads/ブランチ")
        accented = self.identity("refs/heads/é")
        long_ref = self.identity("refs/heads/feature/" + "x" * 200)
        self.assertEqual(unicode_only["readableSlug"], "branch")
        self.assertEqual(accented["readableSlug"], "branch")
        self.assertLessEqual(len(unicode_only["environmentKey"]), 32)
        self.assertLessEqual(len(long_ref["environmentKey"]), 32)

    def test_new_commit_preserves_environment_and_updates_provenance(self) -> None:
        first = self.identity("refs/heads/feature/reconcile", "a" * 40)
        second = self.identity("refs/heads/feature/reconcile", "b" * 40)
        self.assertEqual(first["environmentKey"], second["environmentKey"])
        self.assertEqual(first["stateKey"], second["stateKey"])
        self.assertNotEqual(first["sourceCommit"], second["sourceCommit"])
        self.assertNotEqual(first["sourceCommitUrl"], second["sourceCommitUrl"])

    def test_preview_state_artifact_and_lock_scopes_are_isolated(self) -> None:
        first = self.identity("refs/heads/feature/one")
        second = self.identity("refs/heads/feature/two")
        for field in ("stateKey", "recoveryStateKey", "artifactScope", "lockScope"):
            self.assertNotEqual(first[field], second[field])
            self.assertIn(first["environmentKey"], first[field])

    def test_invalid_or_untrusted_identity_is_rejected(self) -> None:
        invalid = (
            ("another/repository", "refs/heads/feature/a", "a" * 40),
            (
                "f5-sales-demo/multi-cloud-networking",
                "refs/pull/1226/merge",
                "a" * 40,
            ),
            (
                "f5-sales-demo/multi-cloud-networking",
                "refs/heads/feature/a",
                "ABC",
            ),
        )
        for repository, ref, commit in invalid:
            with (
                self.subTest(repository=repository, ref=ref, commit=commit),
                self.assertRaises(ValueError),
            ):
                self.module.build_identity(
                    repository=repository,
                    source_ref=ref,
                    source_commit=commit,
                    owner_id="showcase-team",
                    actor_id="github-actions",
                )
        for unsafe in ("Robin Example", "person@example.com", "", "prod_owner"):
            with self.subTest(unsafe=unsafe), self.assertRaises(ValueError):
                self.module.build_identity(
                    repository="f5-sales-demo/multi-cloud-networking",
                    source_ref="refs/heads/feature/a",
                    source_commit="a" * 40,
                    owner_id=unsafe,
                    actor_id="github-actions",
                )

    def test_cli_emits_one_secret_free_json_document(self) -> None:
        result = subprocess.run(  # noqa: S603
            [
                sys.executable,
                str(SCRIPT),
                "--repository",
                "f5-sales-demo/multi-cloud-networking",
                "--source-ref",
                "refs/heads/feature/a",
                "--source-commit",
                "a" * 40,
                "--owner-id",
                "showcase-team",
                "--actor-id",
                "github-actions",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
        document = json.loads(result.stdout)
        self.assertEqual(document["schemaVersion"], "mcn.deployment-identity/v1")
        self.assertNotIn("@", result.stdout)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
