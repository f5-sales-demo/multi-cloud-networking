#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
backend="$repo_root/terraform/backend.tf"
example="$repo_root/terraform/backend.hcl.example"
bootstrap="$repo_root/terraform/bootstrap/state-backend/main.tf"
bootstrap_versions="$repo_root/terraform/bootstrap/state-backend/versions.tf"
variables="$repo_root/terraform/bootstrap/state-backend/variables.tf"
configure_script="$repo_root/scripts/configure-aws-state-backend.sh"
aws_lockfile="$repo_root/terraform/.terraform.lock.hcl"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}
require() { grep -Fq "$1" "$2" || fail "missing $1 in $2"; }
reject() { ! grep -Fq "$1" "$2" || fail "unexpected $1 in $2"; }

require 'backend "s3" {}' "$backend"
reject 'backend "azurerm"' "$backend"
require 'bucket       = "REPLACE_WITH_BOOTSTRAP_BUCKET"' "$example"
require 'key          = "mcn-ce-ha-smsv2/showcase.tfstate"' "$example"
require 'use_lockfile = true' "$example"
require 'encrypt      = true' "$example"
require 'kms_key_id   = "REPLACE_WITH_BOOTSTRAP_KMS_KEY_ARN"' "$example"
reject 'dynamodb_table' "$example"
reject 'ARM_ACCESS_KEY' "$example"

require 'resource "aws_kms_key" "state"' "$bootstrap"
require 'enable_key_rotation' "$bootstrap"
require 'policy                  = data.aws_iam_policy_document.state_kms.json' "$bootstrap"
require 'resource "aws_s3_bucket" "state"' "$bootstrap"
require 'resource "aws_s3_bucket_versioning" "state"' "$bootstrap"
require 'status = "Enabled"' "$bootstrap"
require 'resource "aws_s3_bucket_server_side_encryption_configuration" "state"' "$bootstrap"
require 'aws_kms_key.state.arn' "$bootstrap"
require 'resource "aws_s3_bucket_public_access_block" "state"' "$bootstrap"
require 'block_public_acls       = true' "$bootstrap"
require 'block_public_policy     = true' "$bootstrap"
require 'resource "aws_s3_bucket_ownership_controls" "state"' "$bootstrap"
require 'BucketOwnerEnforced' "$bootstrap"
require 'resource "aws_s3_bucket_lifecycle_configuration" "state"' "$bootstrap"
require 'noncurrent_version_expiration' "$bootstrap"
require 'resource "aws_s3_bucket_policy" "state"' "$bootstrap"
require 'aws:SecureTransport' "$bootstrap"
require 'resource "aws_s3_bucket_logging" "state"' "$bootstrap"
require 'resource "aws_s3_bucket_notification" "state"' "$bootstrap"
require 'eventbridge = true' "$bootstrap"
require 'resource "aws_s3_bucket_replication_configuration" "state"' "$bootstrap"
require 'source_selection_criteria' "$bootstrap"
require 'sse_kms_encrypted_objects' "$bootstrap"
require 'resource "aws_iam_role" "replication"' "$bootstrap"
require 'resource "aws_s3_bucket" "replica"' "$bootstrap"
require 'resource "aws_kms_key" "replica"' "$bootstrap"
require 'replica_bucket_name         = "${var.bucket_name}-replica"' "$bootstrap"
require 'logging_bucket_name         = "${var.bucket_name}-logs"' "$bootstrap"
require 'replica_logging_bucket_name = "${var.bucket_name}-replica-logs"' "$bootstrap"
require 'terraform state only after this bootstrap apply succeeds' "$bootstrap"
require 'variable "bucket_name"' "$variables"
require 'variable "replica_region"' "$variables"
require 'variable "access_log_retention_days"' "$variables"
reject 'backend "s3" {}' "$bootstrap_versions"
require 'alias  = "replica"' "$bootstrap_versions"
require 'Terraform state backend bootstrap validation' "$repo_root/.github/workflows/terraform.yml"
require 'runs-on: ubuntu-latest' "$repo_root/.github/workflows/terraform.yml"
reject 'runs-on: managed-socketless' "$repo_root/.github/workflows/terraform.yml"
[ -x "$configure_script" ] || fail "backend configuration script is not executable"

# The live AWS SMSv2 root is independently initialized, so its provider
# selections must be versioned rather than inheriting an incidental developer
# lockfile.  Keep this narrow exception to the repository-wide lockfile ignore
# rule and let CI prove a clean, frozen initialization.
require '!terraform/.terraform.lock.hcl' "$repo_root/.gitignore"
[ -f "$aws_lockfile" ] || fail "missing tracked AWS root lockfile"
require 'registry.terraform.io/f5-sales-demo/xcsh' "$aws_lockfile"
require 'version     = "11.0.1"' "$aws_lockfile"
require 'registry.terraform.io/hashicorp/aws' "$aws_lockfile"
require 'version     = "5.100.0"' "$aws_lockfile"
require 'registry.terraform.io/hashicorp/external' "$aws_lockfile"
require 'version     = "2.4.2"' "$aws_lockfile"
require 'Terraform AWS SMSv2 frozen provider initialization' "$repo_root/.github/workflows/terraform.yml"
require 'working-directory: terraform' "$repo_root/.github/workflows/terraform.yml"
require 'terraform init -backend=false -input=false -lockfile=readonly' "$repo_root/.github/workflows/terraform.yml"

printf 'PASS: AWS state backend is isolated, encrypted, versioned, and lockfile-protected\n'
