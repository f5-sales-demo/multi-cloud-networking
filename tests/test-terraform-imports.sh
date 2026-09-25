#!/usr/bin/env bash
# Contract test for path-preserving Terraform documentation imports.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW_PATH=.github/workflows/terraform.yml
TEST_PATH=tests/test-terraform-imports.sh
LEGACY_PATH="_includes""/terraform"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  return 1
}

tracked_terraform() {
  git -C "$1" ls-files 'terraform/*.tf' 'terraform/**/*.tf' 'terraform/**/*.tftpl' 'terraform/cloud-init/ce-node-aws.multipart.tpl' | LC_ALL=C sort -u
}

manifest_terraform() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      if (line !~ /^[[:space:]]*terraform\//) next
      split(line, parts, /[[:space:]]*->[[:space:]]*/)
      src = parts[1]
      dest = parts[2]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", src)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", dest)
      if (dest == "") dest = "<missing>"
      print src " -> " dest
    }
  ' "$1/docs/_imports" | LC_ALL=C sort
}

manifest_destinations() {
  awk '
    /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
    {
      line = $0
      sub(/[[:space:]]+#.*$/, "", line)
      count = split(line, parts, /[[:space:]]*->[[:space:]]*/)
      src = parts[1]
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", src)
      if (count > 1) {
        dest = parts[2]
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", dest)
      } else {
        pieces = split(src, path, "/")
        dest = path[pieces]
      }
      print dest
    }
  ' "$1/docs/_imports"
}

check_tree() {
  local root=$1 expected actual duplicate legacy workflow trigger_count
  [ -f "$root/docs/_imports" ] || fail "missing docs/_imports" || return 1

  expected=$(tracked_terraform "$root" | awk '{ print $0 " -> " $0 }')
  actual=$(manifest_terraform "$root")
  if [ "$actual" != "$expected" ]; then
    printf '%s\n' "expected Terraform mappings:" "$expected" >&2
    printf '%s\n' "actual Terraform mappings:" "$actual" >&2
    fail "docs/_imports does not exactly cover tracked Terraform sources" || return 1
  fi

  if manifest_terraform "$root" | grep -Eq '(\.tfvars|\.terraform\.lock\.hcl)'; then
    fail "docs/_imports includes tfvars or lock material" || return 1
  fi

  duplicate=$(manifest_destinations "$root" | LC_ALL=C sort | uniq -d | head -1)
  [ -z "$duplicate" ] || fail "duplicate import destination: $duplicate" || return 1

  if legacy=$(git -C "$root" grep -n "$LEGACY_PATH" -- docs scripts tests .github \
    ":!$TEST_PATH" 2>/dev/null); then
    printf '%s\n' "$legacy" >&2
    fail "stale Terraform include reference remains" || return 1
  fi

  workflow="$root/$WORKFLOW_PATH"
  [ -f "$workflow" ] || fail "missing Terraform workflow" || return 1
  grep -Eq 'run:[[:space:]]+bash[[:space:]]+tests/test-terraform-imports\.sh' "$workflow" ||
    fail "Terraform workflow does not run the manifest test" || return 1
  for watched in 'docs/_imports' "$TEST_PATH"; do
    trigger_count=$(grep -cF "'$watched'" "$workflow" || true)
    [ "$trigger_count" -eq 2 ] ||
      fail "expected pull_request and push triggers for $watched" || return 1
  done
}

new_fixture() {
  local root=$1
  mkdir -p "$root/terraform/modules/thing" "$root/terraform/cloud-init" "$root/docs/en" \
    "$root/tests" "$root/.github/workflows"
  printf 'locals {}\n' >"$root/terraform/main.tf"
  printf '${site_cloud_init}\n' >"$root/terraform/cloud-init/ce-node-aws.multipart.tpl"
  printf 'output "x" {}\n' >"$root/terraform/modules/thing/outputs.tf"
  printf 'secret = "never publish"\n' >"$root/terraform/terraform.tfvars"
  printf '# lock\n' >"$root/terraform/.terraform.lock.hcl"
  printf '%s\n' \
    'terraform/main.tf -> terraform/main.tf' \
    'terraform/cloud-init/ce-node-aws.multipart.tpl -> terraform/cloud-init/ce-node-aws.multipart.tpl' \
    'terraform/modules/thing/outputs.tf -> terraform/modules/thing/outputs.tf' \
    >"$root/docs/_imports"
  printf 'import source from "../../_data/terraform/main.tf?raw";\n' \
    >"$root/docs/en/page.mdx"
  printf '%s\n' \
    'on:' \
    '  pull_request:' \
    '    paths:' \
    "      - 'docs/_imports'" \
    "      - '$TEST_PATH'" \
    '  push:' \
    '    paths:' \
    "      - 'docs/_imports'" \
    "      - '$TEST_PATH'" \
    'jobs:' \
    '  validate:' \
    '    steps:' \
    '      - run: bash tests/test-terraform-imports.sh' \
    >"$root/$WORKFLOW_PATH"
  cp "$REPO_ROOT/$TEST_PATH" "$root/$TEST_PATH"
  git -C "$root" init -q
  git -C "$root" add .
}

expect_rejected() {
  local name=$1
  if check_tree "$WORK/$name" >/dev/null 2>&1; then
    fail "negative fixture passed: $name"
  fi
}

new_fixture "$WORK/valid"
check_tree "$WORK/valid"

cp -a "$WORK/valid" "$WORK/missing"
sed -i '/modules\/thing\/outputs.tf/d' "$WORK/missing/docs/_imports"
expect_rejected missing

cp -a "$WORK/valid" "$WORK/missing-template"
sed -i '/ce-node-aws.multipart.tpl/d' "$WORK/missing-template/docs/_imports"
expect_rejected missing-template

cp -a "$WORK/valid" "$WORK/tfvars"
printf '%s\n' 'terraform/terraform.tfvars -> terraform/terraform.tfvars' \
  >>"$WORK/tfvars/docs/_imports"
expect_rejected tfvars

cp -a "$WORK/valid" "$WORK/duplicate"
printf '%s\n' 'other/source.txt -> terraform/main.tf' \
  >>"$WORK/duplicate/docs/_imports"
expect_rejected duplicate

cp -a "$WORK/valid" "$WORK/legacy"
printf 'legacy=%s\n' "$LEGACY_PATH/main.tf" >"$WORK/legacy/docs/en/legacy.txt"
git -C "$WORK/legacy" add docs/en/legacy.txt
expect_rejected legacy

check_tree "$REPO_ROOT"
printf 'PASS: Terraform import manifest contract\n'
