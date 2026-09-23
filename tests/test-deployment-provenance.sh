#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
identity="$repo_root/scripts/deployment-identity.py"
locals_file="$repo_root/terraform/locals.tf"
variables="$repo_root/terraform/variables.tf"
outputs="$repo_root/terraform/outputs.tf"
backend="$repo_root/scripts/configure-aws-state-backend.sh"
lifecycle="$repo_root/scripts/showcase-lifecycle.sh"
documentation="$repo_root/docs/en/demo/deployment-provenance.mdx"
workflow="$repo_root/.github/workflows/terraform.yml"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
require() {
  grep -Fq -- "$1" "$2" || fail "missing $1 in ${2#"$repo_root"/}"
}

test -x "$identity" || fail 'deployment identity helper is missing or not executable'
test -f "$documentation" || fail 'deployment provenance documentation is missing'
require 'variable "source_repository"' "$variables"
require 'variable "source_ref"' "$variables"
require 'variable "source_commit_sha"' "$variables"
require 'variable "deployment_owner_id"' "$variables"
require 'variable "deployment_actor_id"' "$variables"
require 'deployment_environment_key' "$locals_file"
require 'source_ref_sha256' "$locals_file"
require 'merge(var.tags, local.standard_tags)' "$locals_file"
require 'xc_provenance_labels' "$locals_file"
require 'labels               = local.azure_xc_labels' "$repo_root/terraform/main.tf"
require 'labels               = local.ca_xc_labels' "$repo_root/terraform/main.tf"
require 'output "deployment_provenance"' "$outputs"
require '--source-ref' "$backend"
require 'showcase_backend_key' "$backend"
require '--source-ref' "$lifecycle"
require 'deployment-identity.py' "$lifecycle"
require 'cross-environment' "$lifecycle"
require 'TF_VAR_source_ref: refs/heads/main' "$workflow"
require 'preview_site_prefix' "$locals_file"
require 'refs/pull/' "$documentation"
require 'feature/a' "$documentation"
require 'feature-a' "$documentation"
require 'branch rename' "$documentation"
require 'unsupported' "$documentation"

printf 'PASS: deployment provenance and branch isolation contract is wired\n'
