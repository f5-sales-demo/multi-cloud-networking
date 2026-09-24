#!/usr/bin/env bash
set -euo pipefail

PLAN_JSON=""
MANIFEST=""
RECEIPT=""
MODE=""
PATCHED_PROVIDER_VERSION="11.0.1"

usage() {
  printf '%s\n' \
    'Usage: verify-aws-smsv2-orphan-recovery-plan.sh --mode import|destroy --plan-json FILE --manifest FILE --receipt FILE' >&2
  exit 64
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

while (($#)); do
  case "$1" in
  --mode)
    MODE=${2:?}
    shift 2
    ;;
  --plan-json)
    PLAN_JSON=${2:?}
    shift 2
    ;;
  --manifest)
    MANIFEST=${2:?}
    shift 2
    ;;
  --receipt)
    RECEIPT=${2:?}
    shift 2
    ;;
  -h | --help) usage ;;
  *) usage ;;
  esac
done

for required in MODE PLAN_JSON MANIFEST RECEIPT; do
  [[ -n ${!required} ]] || die "missing required argument"
done
[[ $MODE == import || $MODE == destroy ]] || die "mode must be import or destroy"
for command in jq sha256sum; do command -v "$command" >/dev/null || die "required command is unavailable: $command"; done

PLAN_JSON=$(realpath -e "$PLAN_JSON" 2>/dev/null) || die "plan JSON is unavailable"
MANIFEST=$(realpath -e "$MANIFEST" 2>/dev/null) || die "ownership manifest is unavailable"
RECEIPT=$(realpath -m "$RECEIPT")
[[ ! -e $RECEIPT ]] || die "receipt already exists; use a new evidence path"
mkdir -p "$(dirname "$RECEIPT")"
[[ ! -e $RECEIPT ]] || die "receipt already exists; use a new evidence path"

jq -e '
  type == "object" and .schema_version == 2 and .status == "blocked" and
  .recovery_mode == "legacy_unlabelled" and
  (.collisions | type == "array" and length > 0) and
  ([.collisions[].ownership] | all(. == "verified")) and
  ([.collisions[].resource_uid] | all(type == "string" and length > 0))
' "$MANIFEST" >/dev/null || die "ownership manifest is invalid or not recovery-authorized"

jq -e '
  (.collisions) as $collisions |
  all($collisions[];
    . as $collision |
    .type != "aws_eip" or
    (.attachment_instance_id? // "") == "" or
    any($collisions[]; .type == "aws_instance" and .resource_uid == $collision.attachment_instance_id)
  )
' "$MANIFEST" >/dev/null || die "an attached EIP is missing its owning instance from the recovery manifest"
jq -e '
  all(.collisions[];
    .type != "aws_ec2_transit_gateway_connect_peer" or
    ((.observed_config | type == "object") and
     (.observed_config.inside_cidr_blocks | type == "array" and length > 0 and all(.[]; type == "string" and length > 0)) and
     (.observed_config.peer_address | type == "string" and length > 0) and
     (.observed_config.transit_gateway_attachment_id | type == "string" and length > 0))
  )
' "$MANIFEST" >/dev/null || die "a Transit Gateway Connect peer is missing its observed immutable recovery shape"
jq -e 'type == "object" and (.resource_changes | type == "array")' "$PLAN_JSON" >/dev/null ||
  die "plan JSON is invalid"
jq -e --arg version "$PATCHED_PROVIDER_VERSION" '
  (.configuration.provider_config.xcsh.full_name == "f5-sales-demo/xcsh" or
   .configuration.provider_config.xcsh.full_name == "registry.terraform.io/f5-sales-demo/xcsh") and
  (.configuration.provider_config.xcsh.version_constraint == ("= " + $version) or
   .configuration.provider_config.xcsh.version_constraint == $version)' "$PLAN_JSON" >/dev/null ||
  die "recovery plan is not pinned to the patched xcsh provider"

scratch=$(mktemp -d "${TMPDIR:-/tmp}/mcn-recovery-plan.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
if [[ $MODE == import ]]; then
  jq -e 'all(.resource_changes[]?; .change.actions == ["no-op"] and
    (.change.importing.id | type == "string" and length > 0))' "$PLAN_JSON" >/dev/null ||
    die "recovery import plan contains a non-import or mutating action"
  jq -cS '[.collisions[] | {
    type,
    address:(.type + ".recovery[" + (.address | @json) + "]"),
    id:(if .engine == "f5" then (.namespace + "/" + .name)
        elif (.type == "aws_lb" or .type == "aws_lb_target_group" or .type == "aws_eip" or
              .type == "aws_instance" or .type == "aws_ec2_transit_gateway_connect_peer") then .resource_uid
        else .name end)
  }] | sort_by(.address,.type,.id)' "$MANIFEST" >"$scratch/expected.json"
  jq -cS '[.resource_changes[] | {address,type,id:.change.importing.id}] | sort_by(.address,.type,.id)' \
    "$PLAN_JSON" >"$scratch/actual.json"
  allowed_actions='["import","no-op"]'
else
  jq -e 'all(.resource_changes[]?; .change.actions == ["delete"] and
    (.change.importing? == null))' "$PLAN_JSON" >/dev/null ||
    die "recovery destroy plan contains an action other than delete"
  jq -cS '[.collisions[] | {
    type,
    address:(.type + ".recovery[" + (.address | @json) + "]"),
    name:(if .type == "aws_eip" or .type == "aws_instance" or .type == "aws_ec2_transit_gateway_connect_peer" then .resource_uid else .name end)
  }] | sort_by(.address,.type,.name)' "$MANIFEST" >"$scratch/expected.json"
  jq -cS '[.resource_changes[] | {
    address,type,name:(.change.before.name // .change.before.key_name // .change.before.allocation_id // .change.before.id // "")
  }] | sort_by(.address,.type,.name)' "$PLAN_JSON" >"$scratch/actual.json"
  allowed_actions='["delete"]'
fi
cmp -s "$scratch/expected.json" "$scratch/actual.json" ||
  die "recovery $MODE plan does not exactly match the ownership manifest"

plan_sha256="sha256:$(sha256sum "$PLAN_JSON" | awk '{print $1}')"
manifest_sha256="sha256:$(sha256sum "$MANIFEST" | awk '{print $1}')"
resource_count=$(jq '.resource_changes | length' "$PLAN_JSON")
jq -n --arg plan_sha256 "$plan_sha256" --arg manifest_sha256 "$manifest_sha256" \
  --arg mode "$MODE" --argjson resource_count "$resource_count" \
  --argjson allowed_actions "$allowed_actions" \
  '{schema_version:1,status:"ready",mode:$mode,plan_sha256:$plan_sha256,
    manifest_sha256:$manifest_sha256,resource_count:$resource_count,
    allowed_actions:$allowed_actions}' >"$RECEIPT"
chmod 600 "$RECEIPT"
printf 'ready: %s manifest-bound resources in %s mode\n' "$resource_count" "$MODE"
