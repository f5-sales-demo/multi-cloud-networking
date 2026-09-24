#!/usr/bin/env bash
# Repository-specific pre-commit checks, invoked by the `local-hooks` hook in
# .pre-commit-config.yaml (which is governance-managed and must not be edited
# here — this file is the sanctioned extension point).
#
# Everything below is offline and credential-free, so it behaves identically on a
# workstation and in CI. Refreshing the CE command catalog is deliberately NOT
# here: it needs a live tenant, and no runner can hold that credential. See
# scripts/capture-sitecli.sh.
set -euo pipefail

cd "$(dirname "$0")/.."

if git diff --cached --name-only | grep -qE '^(docs/en/demo/|tests/test-kvm-demo-docs\.sh$)'; then
  bash tests/test-kvm-demo-docs.sh
fi

run() {
  printf '\n== %s\n' "$1"
  shift
  "$@"
}

# The hook is wired with `always_run: true` and `pass_filenames: false`, so the
# relevance check has to happen here. The CE suite takes ~12s; running it on a
# commit that touches only Terraform earns nothing and is how hooks end up
# disabled. `git diff` against HEAD covers the staged set; when there is no HEAD
# yet (initial commit) fall back to running everything.
staged() {
  if git rev-parse --verify -q HEAD >/dev/null; then
    git diff --cached --name-only
  else
    git ls-files
  fi
}

if staged | grep -qE '^(sitecli/|scripts/(capture-sitecli|check-sitecli-docs|sitecli-scrub|pre-commit-local)\.sh|tests/test-(sitecli-scrub|check-sitecli-docs)\.sh|docs/(_imports|en/customer-edge/))'; then
  run "CE scrub filter tests" bash tests/test-sitecli-scrub.sh
  run "CE docs consistency gate tests" bash tests/test-check-sitecli-docs.sh
  run "CE catalog vs documentation" bash scripts/check-sitecli-docs.sh
else
  printf 'CE Site CLI checks skipped (no related paths staged)\n'
fi

# The tenant guard's extraction logic (issue #696). Sub-second, and the branch it
# covers — XCSH_API_URL naming the WRONG tenant — is unreachable from
# `terraform test`, which cannot set an environment variable. Nothing else runs it.
if staged | grep -qE '^(terraform/scripts/xc-env-tenant\.sh|tests/test-xc-env-tenant\.sh|scripts/pre-commit-local\.sh)$'; then
  run "XC tenant guard extraction tests" bash tests/test-xc-env-tenant.sh
else
  printf 'XC tenant guard checks skipped (no related paths staged)\n'
fi

# Relative documentation links resolve against the PAGE URL, so './x/' means one
# directory deeper on a non-index page than it does on an index page. Nothing else
# catches a link that resolves nowhere: the prose linter does not resolve links,
# the translation audit only compares hashes, and the site build does not fail on
# a dangling relative link. Three of them reached published documentation before
# this ran (issue #828). Sub-second, offline, and English-only, because the locale
# trees are generated from docs/en and link paths are not translated.
if staged | grep -qE '^(docs/en/|scripts/(check_doc_links\.py|pre-commit-local\.sh)$|tests/test-check-doc-links\.sh$)'; then
  run "documentation link guard tests" bash tests/test-check-doc-links.sh
  run "documentation relative links" python3 scripts/check_doc_links.py
else
  printf 'Documentation link checks skipped (no related paths staged)\n'
fi

# shfmt is enforced by the Lint Code Base gate (super-linter SHELL_SHFMT) but is
# absent from .pre-commit-config.yaml, which is governance-managed. Without this,
# a formatting-only failure is only discoverable after pushing — which is exactly
# how it was found. Runs on every staged shell script, not just the CE ones.
if command -v shfmt >/dev/null 2>&1; then
  # No mapfile: macOS ships bash 3.2, where it does not exist. Anything that runs
  # in a git hook on this fleet has to work there.
  sh_files=$(staged | grep -E '\.sh$' || true)
  if [ -n "$sh_files" ]; then
    printf '\n== shfmt (mirrors the CI Lint Code Base gate)\n'
    printf '%s\n' "$sh_files" | tr '\n' '\0' | xargs -0 shfmt -d
  fi
else
  printf '\nshfmt not installed — the CI Lint Code Base gate will still enforce it\n'
fi
