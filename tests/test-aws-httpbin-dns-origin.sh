#!/usr/bin/env bash
# The AWS showcase uses the user-selected DNS origin.  It must never pin a
# resolved address or provision a second origin instance just to serve traffic.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
aws_root="$repo_root/terraform"
xc="$aws_root/aws_xc.tf"
vpc="$aws_root/aws_vpc.tf"
variables="$aws_root/variables.tf"
outputs="$aws_root/outputs.tf"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_text() {
  local file=$1 text=$2
  grep -Fq -- "$text" "$file" || fail "${file#"$repo_root"/} is missing: $text"
}

require_text "$variables" 'variable "aws_origin_dns_name" {'
origin_variable=$(sed -n '/variable "aws_origin_dns_name" {/,/^}/p' "$variables")
grep -Eq '^[[:space:]]*default[[:space:]]*=[[:space:]]*"httpbin\.org"$' <<<"$origin_variable" ||
  fail 'aws_origin_dns_name must default to the selected httpbin.org DNS name'

origin_pool=$(sed -n '/resource "xcsh_origin_pool" "aws" {/,/^}/p' "$xc")
grep -Fq 'public_name { dns_name = var.aws_origin_dns_name }' <<<"$origin_pool" ||
  fail 'AWS origin pool must use public_name.dns_name'
if grep -Fq 'public_ip' <<<"$origin_pool"; then
  fail 'AWS origin pool must not use a public IP member'
fi
if grep -Fq 'depends_on = [aws_instance.origin]' <<<"$origin_pool"; then
  fail 'AWS origin pool must not depend on a removed origin instance'
fi

if rg -n 'resource "aws_(instance|security_group)" "origin"|aws_instance\.origin|aws_security_group\.origin' "$vpc" "$outputs"; then
  fail 'AWS root retains the obsolete provisioned origin graph'
fi

require_text "$outputs" 'output "aws_origin_dns_name" {'
require_text "$outputs" 'value       = var.aws_origin_dns_name'

printf 'PASS: AWS origin pool uses the explicit httpbin.org DNS member without an owned origin instance\n'
