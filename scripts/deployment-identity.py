#!/usr/bin/env python3
"""Derive the canonical MCN deployment identity from trusted source inputs."""
# pylint: disable=invalid-name

from __future__ import annotations

import argparse
import hashlib
import json
import re
from typing import Any

SCHEMA_VERSION = "mcn.deployment-identity/v1"
CANONICAL_REPOSITORY = "f5-sales-demo/multi-cloud-networking"
PRODUCTION_REF = "refs/heads/main"
IDENTIFIER = re.compile(r"^[a-z][a-z0-9-]{2,62}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")
BRANCH_REF = re.compile(r"^refs/heads/([^\x00-\x20\x7f]+)$")
MAX_ENVIRONMENT_KEY = 32
HASH_LENGTH = 12


def _validated_identifier(name: str, value: str) -> str:
    if not IDENTIFIER.fullmatch(value) or "@" in value:
        message = f"{name} must be a non-personal lowercase identifier using letters, digits and hyphens"
        raise ValueError(message)
    return value


def _readable_slug(branch: str) -> str:
    # Terraform has no Unicode normalization primitive. Operate on the exact
    # code points and retain only ASCII so both implementations are identical.
    slug = re.sub(r"[^a-z0-9]+", "-", branch.lower()).strip("-")
    return slug or "branch"


def _validated_branch(source_ref: str) -> str:
    match = BRANCH_REF.fullmatch(source_ref)
    if not match:
        message = "source_ref must be an exact refs/heads/* ref, never a PR merge ref"
        raise ValueError(message)
    branch = match.group(1)
    components = branch.split("/")
    if (
        source_ref.endswith("/")
        or ".." in branch
        or "@{" in branch
        or "\\" in branch
        or any(character in branch for character in "~^:?*[")
    ):
        message = "source_ref is not a valid Git branch ref"
        raise ValueError(message)
    if any(
        not component or component.startswith(".") or component.endswith((".", ".lock"))
        for component in components
    ):
        message = "source_ref contains an invalid Git branch component"
        raise ValueError(message)
    return branch


def _ref_hash(repository: str, source_ref: str) -> str:
    serialized = (
        b"mcn.deployment-identity/v1\0"
        + repository.encode("utf-8")
        + b"\0"
        + source_ref.encode("utf-8")
    )
    return hashlib.sha256(serialized).hexdigest()


def build_identity(
    *,
    repository: str,
    source_ref: str,
    source_commit: str,
    owner_id: str,
    actor_id: str,
) -> dict[str, Any]:
    """Return a validated, deterministic identity with isolated state scopes."""
    if repository != CANONICAL_REPOSITORY:
        message = f"repository must be exactly {CANONICAL_REPOSITORY}"
        raise ValueError(message)
    branch = _validated_branch(source_ref)
    if not COMMIT.fullmatch(source_commit):
        message = "source_commit must be an immutable lowercase 40-hex commit"
        raise ValueError(message)
    owner_id = _validated_identifier("owner_id", owner_id)
    actor_id = _validated_identifier("actor_id", actor_id)

    readable = _readable_slug(branch)
    digest = _ref_hash(repository, source_ref)
    production = source_ref == PRODUCTION_REF
    if production:
        environment_key = "production"
        state_key = "mcn-ce-ha-smsv2/showcase.tfstate"
        recovery_state_key = "mcn-ce-ha-smsv2/recovery/smsv2-orphans.tfstate"
        artifact_scope = "production"
    else:
        readable_budget = MAX_ENVIRONMENT_KEY - HASH_LENGTH - 1
        bounded_readable = readable[:readable_budget].rstrip("-") or "branch"
        environment_key = f"{bounded_readable}-{digest[:HASH_LENGTH]}"
        prefix = f"mcn-ce-ha-smsv2/environments/{environment_key}"
        state_key = f"{prefix}/showcase.tfstate"
        recovery_state_key = f"{prefix}/recovery/smsv2-orphans.tfstate"
        artifact_scope = f"preview/{environment_key}"

    repository_url = f"https://github.com/{repository}"
    return {
        "schemaVersion": SCHEMA_VERSION,
        "repository": repository,
        "repositoryUrl": repository_url,
        "mainNavigationUrl": f"{repository_url}/tree/main",
        "sourceRef": source_ref,
        "sourceCommit": source_commit,
        "sourceCommitUrl": f"{repository_url}/commit/{source_commit}",
        "production": production,
        "readableSlug": readable,
        "sourceRefSha256": digest,
        "environmentKey": environment_key,
        "ownerId": owner_id,
        "actorId": actor_id,
        "stateKey": state_key,
        "recoveryStateKey": recovery_state_key,
        "artifactScope": artifact_scope,
        "lockScope": f"{repository}:{environment_key}",
    }


def main() -> int:
    """Validate CLI arguments and emit one canonical JSON document."""
    parser = argparse.ArgumentParser()
    parser.add_argument("--repository", required=True)
    parser.add_argument("--source-ref", required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--owner-id", required=True)
    parser.add_argument("--actor-id", required=True)
    args = parser.parse_args()
    try:
        document = build_identity(
            repository=args.repository,
            source_ref=args.source_ref,
            source_commit=args.source_commit,
            owner_id=args.owner_id,
            actor_id=args.actor_id,
        )
    except ValueError as error:
        parser.error(str(error))
    print(json.dumps(document, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
