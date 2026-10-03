#!/usr/bin/env python3
"""Verify the immutable published provider before Terraform initialization."""

# pylint: disable=invalid-name
# ruff: noqa: TRY003, EM101
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any

REPOSITORY = "f5-sales-demo/terraform-provider-xcsh"
VERSION = "12.4.0"
COMMIT = "c0169b220fe41a707260a88378dfb4d0b339f9b3"
ZIP_SHA256 = "627cf77453171094d327bb6b1f782b14f14355ce057ebebd73606caf5b95b76b"
SPEC_SHA256 = "62f71ec22260bc99f65753ef4581eb9e0dec1b65c506bb0d53099db73a05e19e"
SPEC_COMMIT = "1a0b5141f4589ffaf7bb696a4369a16ee74ae2ff"
SIGNING_FINGERPRINT = "BA597F4496B744EB2EF9D9E67282C542DC88E217"
ZIP_NAME = f"terraform-provider-xcsh_{VERSION}_linux_amd64.zip"


def validate_identity(release: dict[str, Any], spec: bytes, artifact: bytes) -> None:
    """Reject a mismatched release, embedded API receipt, or downloaded ZIP."""
    marker = "<!-- provider-publication-receipt:"
    body = release.get("body", "")
    if body.count(marker) != 1:
        raise ValueError("publication receipt must occur exactly once")
    receipt = json.loads(body.split(marker, 1)[1].split(" -->", 1)[0])
    expected = {
        "tag": "v" + VERSION,
        "version": VERSION,
        "commit": COMMIT,
        "spec_release_sha256": SPEC_SHA256,
    }
    if release.get("tagName") != "v" + VERSION or any(
        receipt.get(key) != value for key, value in expected.items()
    ):
        raise ValueError("provider publication identity mismatch")
    if receipt.get("assets", {}).get(ZIP_NAME) != "sha256:" + ZIP_SHA256:
        raise ValueError("provider publication artifact mismatch")
    if hashlib.sha256(artifact).hexdigest() != ZIP_SHA256:
        raise ValueError("provider release artifact digest mismatch")
    if hashlib.sha256(spec).hexdigest() != SPEC_SHA256:
        raise ValueError("embedded API receipt digest mismatch")
    api = json.loads(spec)
    if (api.get("release_tag"), api.get("target_commit"), api.get("version")) != (
        "v9.0.2",
        SPEC_COMMIT,
        "9.0.2",
    ):
        raise ValueError("embedded API release identity mismatch")


def run_command(args: tuple[str, ...] | list[str]) -> bytes:
    """Execute fixed tool arguments without shell interpretation."""
    executable = shutil.which(args[0])
    if executable is None:
        raise FileNotFoundError(args[0])
    # All callers select gh, curl or gpg with fixed operations; remote data is
    # passed only as an opaque argument, never interpreted as executable code.
    return subprocess.check_output([executable, *args[1:]])  # noqa: S603


def command_json(*args: str) -> Any:
    """Read one JSON document only after its producer succeeds."""
    return json.loads(run_command(args))


def main() -> int:
    """Download, verify, and record release evidence in a private directory."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--private-root", type=Path, required=True)
    args = parser.parse_args()
    directory = args.private_root
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    release = command_json(
        "gh",
        "release",
        "view",
        "v" + VERSION,
        "--repo",
        REPOSITORY,
        "--json",
        "tagName,body",
    )
    for suffix in ("linux_amd64.zip", "SHA256SUMS", "SHA256SUMS.sig"):
        name = f"terraform-provider-xcsh_{VERSION}_{suffix}"
        run_command(
            [
                "curl",
                "-fsSL",
                "--retry",
                "3",
                "--output",
                str(directory / name),
                f"https://github.com/{REPOSITORY}/releases/download/v{VERSION}/{name}",
            ]
        )
    spec = run_command(
        [
            "curl",
            "-fsSL",
            f"https://raw.githubusercontent.com/{REPOSITORY}/{COMMIT}/tools/spec-release.json",
        ]
    )
    artifact = (directory / ZIP_NAME).read_bytes()
    validate_identity(release, spec, artifact)
    registry = command_json(
        "curl",
        "-fsSL",
        f"https://registry.terraform.io/v1/providers/f5-sales-demo/xcsh/{VERSION}/download/linux/amd64",
    )
    if registry.get("shasum") != ZIP_SHA256 or registry.get("filename") != ZIP_NAME:
        raise ValueError("Terraform Registry artifact mismatch")
    with tempfile.TemporaryDirectory(
        prefix="provider-signature-", dir=directory
    ) as temp:
        key = Path(temp) / "provider-key.asc"
        key.write_text(
            registry["signing_keys"]["gpg_public_keys"][0]["ascii_armor"],
            encoding="utf-8",
        )
        run_command(["gpg", "--homedir", temp, "--batch", "--import", str(key)])
        verified = run_command(
            [
                "gpg",
                "--homedir",
                temp,
                "--batch",
                "--status-fd",
                "1",
                "--verify",
                str(directory / f"terraform-provider-xcsh_{VERSION}_SHA256SUMS.sig"),
                str(directory / f"terraform-provider-xcsh_{VERSION}_SHA256SUMS"),
            ]
        ).decode("utf-8")
        if not any(
            line.startswith("[GNUPG:] VALIDSIG ")
            and line.split()[-1] == SIGNING_FINGERPRINT
            for line in verified.splitlines()
        ):
            raise ValueError("provider signing fingerprint mismatch")
    sums = (
        (directory / f"terraform-provider-xcsh_{VERSION}_SHA256SUMS")
        .read_text()
        .splitlines()
    )
    if [line.split()[0] for line in sums if line.split()[-1] == ZIP_NAME] != [
        ZIP_SHA256
    ]:
        raise ValueError("signed provider checksum mismatch")
    tag = command_json("gh", "api", f"repos/{REPOSITORY}/git/ref/tags/v{VERSION}")
    obj = tag["object"]
    if obj["type"] == "tag":
        obj = command_json("gh", "api", f"repos/{REPOSITORY}/git/tags/{obj['sha']}")[
            "object"
        ]
    if obj["sha"] != COMMIT:
        raise ValueError("provider source tag mismatch")
    runs = command_json(
        "gh",
        "run",
        "list",
        "--repo",
        REPOSITORY,
        "--commit",
        COMMIT,
        "--workflow",
        "On Merge",
        "--json",
        "conclusion,headSha,databaseId",
    )
    successful = [
        run
        for run in runs
        if run["headSha"] == COMMIT and run["conclusion"] == "success"
    ]
    if not successful:
        raise ValueError(
            "provider publication workflow has no successful exact-commit run"
        )
    receipt = {
        "schema": "mcn.provider-release/v1",
        "status": "passed",
        "version": VERSION,
        "source_commit": COMMIT,
        "provider_zip_sha256": ZIP_SHA256,
        "api_release_tag": "v9.0.2",
        "api_release_commit": SPEC_COMMIT,
        "spec_release_sha256": SPEC_SHA256,
        "signing_fingerprint": SIGNING_FINGERPRINT,
        "publication_run": successful[0]["databaseId"],
    }
    (directory / "provider-release-receipt.json").write_text(
        json.dumps(receipt, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(
        f"PASS: published xcsh {VERSION}, signed artifact, source and API v9.0.2 identity"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
