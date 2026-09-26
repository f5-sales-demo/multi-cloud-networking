#!/usr/bin/env bash
# Inspect only the create operations in one reviewed plan.  A collision is
# never adopted: it is recorded with its owner evidence and blocks before
# Terraform is allowed to mutate AWS or F5 Distributed Cloud.
set -euo pipefail

PLAN_JSON=""
AWS_REGION=""
AWS_ACCOUNT_ID=""
XC_TENANT=""
CREATOR_ID=""
COMPONENT=""
DEPLOYMENT_GENERATION=""
RECOVERY_MODE="strict"
MANIFEST=""
SCRATCH=""

usage() {
  cat <<'EOF' >&2
Usage: aws-smsv2-owned-collision-preflight.sh \
  --plan-json FILE --aws-region REGION --aws-account-id ACCOUNT_ID \
  --xc-tenant TENANT --creator-id EMAIL --component COMPONENT \
  --deployment-generation GENERATION [--legacy-unlabelled-recovery] \
  --manifest FILE

The input must be the JSON rendering of the exact saved Terraform plan under
review. The manifest is an evidence record only; it never grants mutation.
Legacy recovery mode is only for adopting a pre-generation deployment through
reviewed Terraform import blocks before its ownership-verified destruction.
EOF
  exit 64
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 2
}

require_local_name_absent() {
  local address=$1 name=$2 inventory
  shift 2
  inventory=$("$@") || die "cannot inspect local KVM candidates for $address"
  if printf '%s\n' "$inventory" | grep -Fxq -- "$name"; then
    die "unowned local KVM collision: $address ($name)"
  fi
}

while (($#)); do
  case "$1" in
  --plan-json)
    PLAN_JSON=${2:?}
    shift 2
    ;;
  --aws-region)
    AWS_REGION=${2:?}
    shift 2
    ;;
  --aws-account-id)
    AWS_ACCOUNT_ID=${2:?}
    shift 2
    ;;
  --xc-tenant)
    XC_TENANT=${2:?}
    shift 2
    ;;
  --creator-id)
    CREATOR_ID=${2:?}
    shift 2
    ;;
  --component)
    COMPONENT=${2:?}
    shift 2
    ;;
  --deployment-generation)
    DEPLOYMENT_GENERATION=${2:?}
    shift 2
    ;;
  --legacy-unlabelled-recovery)
    RECOVERY_MODE="legacy_unlabelled"
    shift
    ;;
  --manifest)
    MANIFEST=${2:?}
    shift 2
    ;;
  -h | --help) usage ;;
  *) usage ;;
  esac
done

for required in PLAN_JSON AWS_REGION AWS_ACCOUNT_ID XC_TENANT CREATOR_ID COMPONENT DEPLOYMENT_GENERATION MANIFEST; do
  [[ -n ${!required} ]] || die "missing required argument"
done
[[ $AWS_ACCOUNT_ID =~ ^[0-9]{12}$ ]] || die "aws account ID must contain exactly 12 digits"
[[ $AWS_REGION =~ ^[a-z]{2}(-gov)?-[a-z]+-[0-9]+$ ]] || die "aws region is invalid"
[[ $COMPONENT =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] ||
  die "component must be a 1-32 character DNS-style label"
[[ $DEPLOYMENT_GENERATION =~ ^[a-z0-9]([a-z0-9-]{0,30}[a-z0-9])?$ ]] ||
  die "deployment generation must be a 1-32 character DNS-style label"
[[ "$XC_TENANT" == f5-sales-demo ]] || die "xc tenant must be f5-sales-demo"
[[ ${XCSH_API_URL:-} == "https://${XC_TENANT}.console.ves.volterra.io" ]] || die "XCSH_API_URL must match the expected Sales Demo tenant"
[[ -n ${XCSH_API_TOKEN:-} ]] || die "XCSH_API_TOKEN is required"
for command in aws jq sha256sum; do command -v "$command" >/dev/null || die "required command is unavailable: $command"; done

PLAN_JSON=$(realpath -e "$PLAN_JSON" 2>/dev/null) || die "plan JSON is unavailable"
MANIFEST=$(realpath -m "$MANIFEST")
[[ ! -e "$MANIFEST" ]] || die "manifest already exists; use a new evidence path"
mkdir -p "$(dirname "$MANIFEST")"
[[ ! -e "$MANIFEST" ]] || die "manifest already exists; use a new evidence path"
jq -e 'type == "object" and (.resource_changes | type == "array")' "$PLAN_JSON" >/dev/null || die "plan JSON is invalid"
replacement_sites=$(jq -ec '
  [.resource_changes[]? |
   select(.type == "xcsh_securemesh_site_v2" and (.change.actions | index("delete") != null)) |
   {address, actions:.change.actions, replace_paths:(.change.replace_paths // [])}]
' "$PLAN_JSON") || die "cannot inspect SecureMesh site lifecycle actions"
if [[ $(jq -er 'length' <<<"$replacement_sites") -ne 0 ]]; then
  die "planned SecureMesh site replacement is prohibited before mutation: $replacement_sites"
fi

caller_identity=$(aws sts get-caller-identity --output json 2>/dev/null) || die "cannot verify AWS caller identity"
actual_aws_account_id=$(jq -er '.Account | select(type == "string")' <<<"$caller_identity") ||
  die "AWS caller identity did not include an account ID"
[[ $actual_aws_account_id == "$AWS_ACCOUNT_ID" ]] ||
  die "AWS caller account does not match the expected account"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/mcn-owned-collision.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
umask 077
collisions_file="$SCRATCH/collisions.jsonl"
touch "$collisions_file"

append_aws_collision() {
  local type=$1 address=$2 name=$3 expected_tags=$4 actual_tags=$5 identity=$6
  jq -nc \
    --arg type "$type" --arg address "$address" --arg name "$name" \
    --arg account_id "$AWS_ACCOUNT_ID" --arg region "$AWS_REGION" --arg recovery_mode "$RECOVERY_MODE" \
    --argjson expected_tags "$expected_tags" --argjson observed_tags "$actual_tags" \
    --argjson identity "$identity" \
    '{engine:"aws",type:$type,address:$address,name:$name,namespace:null,
      ownership:"verified",aws_account_id:$account_id,aws_region:$region,
      expected_tags:$expected_tags,observed_tags:$observed_tags,
      resource_uid:$identity.resource_uid,created_at:$identity.created_at,
      creation_evidence:$identity.creation_evidence,
      generation_binding:(if $recovery_mode == "strict" then "observed_metadata"
        else "saved_plan_name_and_legacy_ownership" end)} +
      (if $identity.observed_config == null then {} else {observed_config:$identity.observed_config} end)' >>"$collisions_file"
}

append_f5_collision() {
  local type=$1 address=$2 name=$3 namespace=$4 expected_labels=$5 observed=$6
  jq -nc \
    --arg type "$type" --arg address "$address" --arg name "$name" \
    --arg namespace "$namespace" --arg tenant "$XC_TENANT" --arg recovery_mode "$RECOVERY_MODE" \
    --argjson expected_labels "$expected_labels" --argjson observed "$observed" \
    '{engine:"f5",type:$type,address:$address,name:$name,namespace:$namespace,
      ownership:"verified",xc_tenant:$tenant,
      expected_labels:$expected_labels,observed_labels:$observed.metadata.labels,
      creator_id:$observed.system_metadata.creator_id,
      created_at:$observed.system_metadata.creation_timestamp,
      creation_evidence:"system_metadata.creation_timestamp",
      resource_uid:$observed.system_metadata.uid,
      generation_binding:(if $recovery_mode == "strict" then "observed_metadata"
        else "saved_plan_name_and_legacy_ownership" end)}' >>"$collisions_file"
}

aws_not_found() {
  grep -Eq 'InvalidKeyPair\.NotFound|NoSuchEntity|LoadBalancerNotFound|TargetGroupNotFound|NoSuchEntity' "$1"
}

aws_lookup() {
  local out=$1 err=$2
  shift 2
  if aws "$@" --region "$AWS_REGION" --output json >"$out" 2>"$err"; then
    return 0
  fi
  aws_not_found "$err" && return 10
  return 1
}

require_aws_ownership() {
  local expected=$1 actual=$2 name=$3
  jq -ne --arg component "$COMPONENT" --argjson expected "$expected" --argjson actual "$actual" '
    ($expected | type == "object") and
    ([$expected.component, $expected.deployer, $expected.managed_by] |
      all(type == "string" and length > 0)) and
    $expected.component == $component and
    ($expected | to_entries | all(.[]; $actual[.key] == .value))' >/dev/null
  if [[ $RECOVERY_MODE == strict ]]; then
    jq -ne --arg generation "$DEPLOYMENT_GENERATION" --argjson expected "$expected" --argjson actual "$actual" '
      $expected.deployment_generation == $generation and
      $actual.deployment_generation == $generation' >/dev/null
  else
    [[ $name == "$COMPONENT-$DEPLOYMENT_GENERATION-"* ]] || return 1
    jq -ne --arg generation "$DEPLOYMENT_GENERATION" --argjson expected "$expected" --argjson actual "$actual" '
      (($expected.deployment_generation? // $generation) == $generation) and
      (($actual.deployment_generation? // $generation) == $generation)' >/dev/null
  fi
}

aws_identity_for() {
  local type=$1 response=$2
  case "$type" in
  aws_key_pair)
    jq -ec '{resource_uid:.KeyPairs[0].KeyPairId,created_at:(.KeyPairs[0].CreateTime // null),
      creation_evidence:(if .KeyPairs[0].CreateTime then "ec2.describe-key-pairs.CreateTime" else "not_exposed" end)}' "$response"
    ;;
  aws_iam_role)
    jq -ec '{resource_uid:.Role.RoleId,created_at:(.Role.CreateDate // null),
      creation_evidence:(if .Role.CreateDate then "iam.get-role.CreateDate" else "not_exposed" end)}' "$response"
    ;;
  aws_iam_instance_profile)
    jq -ec '{resource_uid:.InstanceProfile.InstanceProfileId,created_at:(.InstanceProfile.CreateDate // null),
      creation_evidence:(if .InstanceProfile.CreateDate then "iam.get-instance-profile.CreateDate" else "not_exposed" end)}' "$response"
    ;;
  aws_lb)
    jq -ec '{resource_uid:.LoadBalancers[0].LoadBalancerArn,created_at:(.LoadBalancers[0].CreatedTime // null),
      creation_evidence:(if .LoadBalancers[0].CreatedTime then "elbv2.describe-load-balancers.CreatedTime" else "not_exposed" end)}' "$response"
    ;;
  aws_lb_target_group)
    jq -ec '{resource_uid:.TargetGroups[0].TargetGroupArn,created_at:null,
      creation_evidence:"not_exposed_by_elbv2_describe_target_groups"}' "$response"
    ;;
  aws_eip)
    jq -ec '{resource_uid:.Addresses[0].AllocationId,created_at:null,
      creation_evidence:"not_exposed_by_ec2_describe_addresses"}' "$response"
    ;;
  aws_instance)
    jq -ec '{resource_uid:([.Reservations[].Instances[]? | .InstanceId][0]),created_at:([.Reservations[].Instances[]? | .LaunchTime][0]),creation_evidence:"ec2.describe-instances.LaunchTime"}' "$response"
    ;;
  aws_internet_gateway)
    jq -ec '{resource_uid:.InternetGateways[0].InternetGatewayId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_internet_gateways"}' "$response"
    ;;
  aws_network_interface)
    jq -ec '{resource_uid:.NetworkInterfaces[0].NetworkInterfaceId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_network_interfaces"}' "$response"
    ;;
  aws_route_table)
    jq -ec '{resource_uid:.RouteTables[0].RouteTableId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_route_tables"}' "$response"
    ;;
  aws_security_group)
    jq -ec '{resource_uid:.SecurityGroups[0].GroupId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_security_groups"}' "$response"
    ;;
  aws_subnet)
    jq -ec '{resource_uid:.Subnets[0].SubnetId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_subnets"}' "$response"
    ;;
  aws_vpc)
    jq -ec '{resource_uid:.Vpcs[0].VpcId,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_vpcs"}' "$response"
    ;;
  *) return 1 ;;
  esac
}

aws_tags_for() {
  local type=$1 response=$2 arn tags_response
  case "$type" in
  aws_key_pair) jq -ec '.KeyPairs[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_iam_role) jq -ec '.Role.Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_iam_instance_profile) jq -ec '.InstanceProfile.Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_lb)
    arn=$(jq -er '.LoadBalancers[0].LoadBalancerArn' "$response") || return 1
    tags_response="$SCRATCH/tags-${RANDOM}.json"
    aws elbv2 describe-tags --resource-arns "$arn" --region "$AWS_REGION" --output json >"$tags_response" 2>/dev/null || return 1
    jq -ec '.TagDescriptions[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$tags_response"
    ;;
  aws_lb_target_group)
    arn=$(jq -er '.TargetGroups[0].TargetGroupArn' "$response") || return 1
    tags_response="$SCRATCH/tags-${RANDOM}.json"
    aws elbv2 describe-tags --resource-arns "$arn" --region "$AWS_REGION" --output json >"$tags_response" 2>/dev/null || return 1
    jq -ec '.TagDescriptions[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$tags_response"
    ;;
  aws_eip) jq -ec '.Addresses[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_instance) jq -ec '[.Reservations[].Instances[]? | .Tags // []] | flatten | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_internet_gateway) jq -ec '.InternetGateways[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_network_interface) jq -ec '.NetworkInterfaces[0].TagSet // .NetworkInterfaces[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_route_table) jq -ec '.RouteTables[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_security_group) jq -ec '.SecurityGroups[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_subnet) jq -ec '.Subnets[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  aws_vpc) jq -ec '.Vpcs[0].Tags // [] | map({key:.Key,value:.Value}) | from_entries' "$response" ;;
  *) return 1 ;;
  esac
}

f5_endpoint() {
  case "$1" in
  xcsh_virtual_site) printf 'virtual_sites' ;;
  xcsh_origin_pool) printf 'origin_pools' ;;
  xcsh_http_loadbalancer) printf 'http_loadbalancers' ;;
  xcsh_token) printf 'tokens' ;;
  xcsh_securemesh_site_v2) printf 'securemesh_site_v2s' ;;
  xcsh_bgp) printf 'bgps' ;;
  xcsh_external_connector) printf 'external_connectors' ;;
  *) return 1 ;;
  esac
}

f5_namespace_prefix() {
  [[ $1 == xcsh_token ]] && printf 'api/register/namespaces' || printf 'api/config/namespaces'
}

while IFS= read -r item; do
  type=$(jq -er '.type' <<<"$item") || die "plan resource type is invalid"
  address=$(jq -er '.address' <<<"$item") || die "plan resource address is invalid"
  after=$(jq -ec '.after' <<<"$item") || die "plan resource after value is invalid"
  expected_tags=""
  if [[ $type == aws_route_table_association ]]; then
    # Associations create no independently owned or name-addressable object.
    # Their route tables, when created, are inventoried by their own changes.
    continue
  fi
  if [[ $type == xcsh_registration_approval ]]; then
    # Registration approval is an ephemeral action keyed to a site, not an owned
    # named object. The UAT site-binding gate validates that relationship.
    continue
  fi
  if [[ $type == xcsh_site_cloud_init ]]; then
    site_name=$(jq -er '.site_name // empty' <<<"$after") || die "planned cloud-init site name is unavailable for $address"
    jq -e --arg site_name "$site_name" '
      .resource_changes[] | select(.type == "xcsh_securemesh_site_v2" and .change.actions == ["create"] and .change.after.name == $site_name)
    ' "$PLAN_JSON" >/dev/null || die "planned cloud-init is not bound to a collision-checked SecureMesh site: $address"
    continue
  fi
  if [[ $type == aws_iam_role_policy_attachment ]]; then
    attachment_config_address=${address%%\[*}
    role_reference=$(jq -er --arg address "$attachment_config_address" '
      .configuration.root_module.resources[] | select(.address == $address) |
      .expressions.role.references[0] // empty
    ' "$PLAN_JSON") || die "planned IAM attachment role reference is unavailable for $address"
    role_resource_address=${role_reference%.name}
    role_name=$(jq -er --arg address "$role_resource_address" '
      .resource_changes[] | select(.address == $address) | .change.after.name // empty
    ' "$PLAN_JSON") || die "planned IAM attachment role is unavailable for $address"
    policy_arn=$(jq -er --arg address "$attachment_config_address" '
      .configuration.root_module.resources[] | select(.address == $address) |
      .expressions.policy_arn.constant_value // empty
    ' "$PLAN_JSON") || die "planned IAM attachment policy ARN is unavailable for $address"
    role_response="$SCRATCH/aws-role-${RANDOM}.json"
    role_error="$SCRATCH/aws-role-${RANDOM}.err"
    if aws_lookup "$role_response" "$role_error" iam get-role --role-name "$role_name"; then
      :
    else
      status=$?
      [[ $status -eq 10 ]] && continue
      die "cannot inspect IAM role ownership for $address"
    fi
    attached_response="$SCRATCH/aws-attachments-${RANDOM}.json"
    aws iam list-attached-role-policies --role-name "$role_name" --region "$AWS_REGION" --output json >"$attached_response" 2>/dev/null ||
      die "cannot inspect IAM policy attachments for $address"
    jq -e --arg arn "$policy_arn" '.AttachedPolicies[]? | select(.PolicyArn == $arn)' "$attached_response" >/dev/null || continue
    actual_tags=$(aws_tags_for aws_iam_role "$role_response") || die "cannot read IAM role tags for existing $address"
    expected_tags=$(jq -ec --arg role "$role_name" '
      [.resource_changes[] | select(.type == "aws_iam_role" and .change.after.name == $role) | .change.after.tags][0] // empty
    ' "$PLAN_JSON") || die "planned parent role tags are unavailable for $address"
    require_aws_ownership "$expected_tags" "$actual_tags" "$role_name" ||
      die "unowned or ambiguous AWS collision: $address ($role_name/$policy_arn)"
    role_identity=$(aws_identity_for aws_iam_role "$role_response") || die "cannot read IAM role identity for existing $address"
    identity=$(jq -nc --arg role_id "$(jq -r '.resource_uid' <<<"$role_identity")" --arg arn "$policy_arn" '{resource_uid:($role_id + ":" + $arn),created_at:null,creation_evidence:"not_exposed_by_iam_list_attached_role_policies"}')
    append_aws_collision "$type" "$address" "${role_name}/${policy_arn}" "$expected_tags" "$actual_tags" "$identity"
    continue
  fi
  if [[ $type == aws_ec2_transit_gateway_route_table_association || $type == aws_ec2_transit_gateway_route_table_propagation ]]; then
    relation_config_address=$address
    if [[ $relation_config_address == *'['*']' ]]; then
      relation_config_address=${relation_config_address%\[*}
    fi
    if [[ $relation_config_address == module.* ]]; then
      relation_config_address=${relation_config_address##*]}
      relation_config_address=${relation_config_address#.}
    fi
    attachment_reference=$(jq -er --arg address "$relation_config_address" '
      .configuration.root_module | .. | objects | select(.address? == $address) |
      .expressions.transit_gateway_attachment_id.references[0] // empty
    ' "$PLAN_JSON") || die "planned TGW relation attachment reference is unavailable for $address"
    if [[ $attachment_reference == each.value.id ]]; then
      module_prefix=${address%%.aws_ec2_transit_gateway_route_table_*}
      jq -e --arg module "$module_prefix" '
        .resource_changes[] | select(.address | startswith($module + ".aws_ec2_transit_gateway_connect.")) |
        select(.change.actions == ["create"])
      ' "$PLAN_JSON" >/dev/null || die "planned TGW module relation is not bound to collision-checked Connect attachments: $address"
    else
      attachment_address=${attachment_reference%.id}
      if [[ $attachment_address == aws_ec2_transit_gateway_* && $address == module.* ]]; then
        module_prefix=${address%%.aws_ec2_transit_gateway_route_table_*}
        attachment_address="${module_prefix}.${attachment_address}"
      fi
      jq -e --arg address "$attachment_address" '
        .resource_changes[] | select(.address == $address and
          (.type == "aws_ec2_transit_gateway_vpc_attachment" or .type == "aws_ec2_transit_gateway_connect") and
          .change.actions == ["create"])
      ' "$PLAN_JSON" >/dev/null || die "planned TGW relation is not bound to a collision-checked attachment: $address"
    fi
    route_reference=$(jq -er --arg address "$relation_config_address" '
      .configuration.root_module | .. | objects | select(.address? == $address) |
      .expressions.transit_gateway_route_table_id.references[0] // empty
    ' "$PLAN_JSON") || die "planned TGW relation route-table reference is unavailable for $address"
    route_address=${route_reference%.id}
    if [[ $route_address == module.*.route_table_id ]]; then
      module_prefix=${route_address%.route_table_id}
      route_address="${module_prefix}.aws_ec2_transit_gateway_route_table.this"
    elif [[ $route_address == aws_ec2_transit_gateway_route_table.* ]]; then
      module_prefix=${address%%.aws_ec2_transit_gateway_route_table_*}
      route_address="${module_prefix}.${route_address}"
    fi
    jq -e --arg address "$route_address" '
      .resource_changes[] | select(.address == $address and .type == "aws_ec2_transit_gateway_route_table" and .change.actions == ["create"])
    ' "$PLAN_JSON" >/dev/null || die "planned TGW relation is not bound to a collision-checked route table: $address"
    continue
  fi
  if [[ $type == aws_lb_listener ]]; then
    listener_config_address=${address%%\[*}
    lb_reference=$(jq -er --arg address "$listener_config_address" '.configuration.root_module.resources[] | select(.address == $address) | .expressions.load_balancer_arn.references[0] // empty' "$PLAN_JSON") || die "planned listener load-balancer reference is unavailable for $address"
    target_reference=$(jq -er --arg address "$listener_config_address" '.configuration.root_module.resources[] | select(.address == $address) | .expressions.default_action[0].target_group_arn.references[0] // empty' "$PLAN_JSON") || die "planned listener target-group reference is unavailable for $address"
    lb_address=${lb_reference%.arn}
    target_address=${target_reference%.arn}
    jq -e --arg lb "$lb_address" --arg target "$target_address" '
      any(.resource_changes[]; .address == $lb and .type == "aws_lb" and .change.actions == ["create"]) and
      any(.resource_changes[]; .address == $target and .type == "aws_lb_target_group" and .change.actions == ["create"])
    ' "$PLAN_JSON" >/dev/null || die "planned listener is not bound to collision-checked NLB and target group: $address"
    continue
  fi
  if [[ $type == aws_ec2_transit_gateway || $type == aws_ec2_transit_gateway_route_table || $type == aws_ec2_transit_gateway_connect ]]; then
    expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
    name=$(jq -er '.Name' <<<"$expected_tags") || die "planned TGW Name tag is unavailable for $address"
    response="$SCRATCH/aws-tgw-tagged-${RANDOM}.json"
    case "$type" in
    aws_ec2_transit_gateway)
      aws ec2 describe-transit-gateways --region "$AWS_REGION" --output json >"$response" 2>/dev/null || die "cannot inspect AWS Transit Gateway candidates for $address"
      collection="TransitGateways"
      id_field="TransitGatewayId"
      ;;
    aws_ec2_transit_gateway_route_table)
      aws ec2 describe-transit-gateway-route-tables --region "$AWS_REGION" --output json >"$response" 2>/dev/null || die "cannot inspect AWS TGW route-table candidates for $address"
      collection="TransitGatewayRouteTables"
      id_field="TransitGatewayRouteTableId"
      ;;
    aws_ec2_transit_gateway_connect)
      aws ec2 describe-transit-gateway-attachments --region "$AWS_REGION" --output json >"$response" 2>/dev/null || die "cannot inspect AWS TGW Connect attachment candidates for $address"
      collection="TransitGatewayAttachments"
      id_field="TransitGatewayAttachmentId"
      ;;
    esac
    matches=$(jq -ec --arg collection "$collection" --arg id_field "$id_field" --argjson expected "$expected_tags" '
      [.[$collection][]? | (.Tags // [] | map({key:.Key,value:.Value}) | from_entries) as $tags |
       select($tags == $expected) | {id:.[ $id_field ],tags:$tags}]
    ' "$response") || die "cannot normalize AWS TGW tagged candidates for $address"
    match_count=$(jq -er 'length' <<<"$matches") || die "cannot count AWS TGW tagged candidates for $address"
    [[ $match_count -eq 0 ]] && continue
    [[ $match_count -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple TGW resources match exact ownership tags)"
    actual_tags=$(jq -ec '.[0].tags' <<<"$matches") || die "cannot read AWS TGW ownership tags for $address"
    require_aws_ownership "$expected_tags" "$actual_tags" "$name" || die "unowned or ambiguous AWS collision: $address ($name)"
    identity=$(jq -ec '.[0] | {resource_uid:.id,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_transit_gateway_inventory"}' <<<"$matches") || die "cannot read AWS TGW identity for $address"
    append_aws_collision "$type" "$address" "$name" "$expected_tags" "$actual_tags" "$identity"
    continue
  fi
  if [[ $type == terraform_data ]]; then
    case "$address" in
    terraform_data.deployment_identity_guard)
      jq -e --argjson after "$after" '
        .planned_values.outputs.deployment_provenance.value as $provenance |
        ($after.input | type == "string" and length > 0) and
        $after.input == $provenance.environment_key and
        $provenance.source_commit == .variables.source_commit_sha.value and
        $provenance.owner_id == .variables.deployment_owner_id.value and
        (.variables.source_commit_sha.value | type == "string" and length == 40) and
        (.variables.deployment_owner_id.value | type == "string" and length > 0)' "$PLAN_JSON" >/dev/null ||
        die "planned deployment identity guard does not match its provenance: $address"
      continue
      ;;
    terraform_data.aws_tgw_contract_gate[[]0[]] | terraform_data.aws_tgw_runtime_gate[[]0[]] | terraform_data.aws_tgw_site_route_gate[[]*[]] | module.kvm_registration_mapping.terraform_data.gate[[]0[]] | terraform_data.kvm_ce_image_cache[[]0[]] | terraform_data.kvm_network_identity[[]0[]] | terraform_data.kvm_workload_image_cache[[]0[]])
      continue
      ;;
    *) die "preflight has no complete ownership adapter for internal Terraform data resource: $address" ;;
    esac
  fi
  case "$type" in
  docker_container)
    [[ $address == 'docker_container.kvm_frr[0]' ]] || die "unexpected local KVM container: $address"
    name=$(jq -er '.name | select(type == "string" and length > 0)' <<<"$after") || die "planned container name is unavailable for $address"
    require_local_name_absent "$address" "$name" docker container ls --all --format '{{.Names}}'
    continue
    ;;
  docker_network)
    [[ $address == 'docker_network.kvm_frr[0]' ]] || die "unexpected local KVM network: $address"
    name=$(jq -er '.name | select(type == "string" and length > 0)' <<<"$after") || die "planned Docker network name is unavailable for $address"
    require_local_name_absent "$address" "$name" docker network ls --format '{{.Name}}'
    continue
    ;;
  docker_image)
    [[ $address == 'docker_image.kvm_frr[0]' ]] || die "unexpected local KVM image: $address"
    jq -e '.name == "frrouting/frr@sha256:990e83490108b686fd6df3b1cafa6bdbb2714acb00eedb9a89693946f46f45ce"' <<<"$after" >/dev/null ||
      die "planned FRR image digest is unexpected for $address"
    # An immutable image already in the local cache is safe to reuse.
    continue
    ;;
  libvirt_pool | libvirt_domain | libvirt_network)
    case "$address:$type" in
    'libvirt_pool.kvm[0]:libvirt_pool') inventory_args=(pool-list --all --name) ;;
    'libvirt_domain.ce_node["01"]:libvirt_domain' | 'libvirt_domain.workload[0]:libvirt_domain') inventory_args=(list --all --name) ;;
    'libvirt_network.ce_bgp_net[0]:libvirt_network') inventory_args=(net-list --all --name) ;;
    *) die "unexpected local KVM resource: $address" ;;
    esac
    name=$(jq -er '.name | select(type == "string" and length > 0)' <<<"$after") || die "planned libvirt name is unavailable for $address"
    require_local_name_absent "$address" "$name" virsh --connect qemu:///system "${inventory_args[@]}"
    continue
    ;;
  libvirt_volume | libvirt_cloudinit_disk)
    case "$address:$type" in
    'libvirt_volume.base_cloud[0]:libvirt_volume' | 'libvirt_volume.ce_disk["01"]:libvirt_volume' | 'libvirt_volume.workload_base[0]:libvirt_volume' | 'libvirt_volume.workload_disk[0]:libvirt_volume' | 'libvirt_cloudinit_disk.ce_cloudinit["01"]:libvirt_cloudinit_disk' | 'libvirt_cloudinit_disk.workload[0]:libvirt_cloudinit_disk') ;;
    *) die "unexpected local KVM volume: $address" ;;
    esac
    pool=$(jq -er '.pool | select(type == "string" and length > 0)' <<<"$after") || die "planned libvirt pool is unavailable for $address"
    planned_pool=$(jq -er '.resource_changes[] | select(.address == "libvirt_pool.kvm[0]" and .change.actions == ["create"]) | .change.after.name' "$PLAN_JSON") ||
      die "planned KVM pool create is unavailable for $address"
    [[ $pool == "$planned_pool" ]] || die "planned KVM volume is outside the new owned pool: $address"
    continue
    ;;
  esac
  if [[ $type == aws_lb_target_group_attachment ]]; then
    attachment_config_address=${address%%\[*}
    target_group_reference=$(jq -er --arg address "$attachment_config_address" '.configuration.root_module.resources[] | select(.address == $address) | .expressions.target_group_arn.references[0] // empty' "$PLAN_JSON") || die "planned target attachment target-group reference is unavailable for $address"
    target_group_address=${target_group_reference%.arn}
    target_id=$(jq -er '.target_id' <<<"$after") || die "planned target attachment target identity is unavailable for $address"
    jq -e --arg group "$target_group_address" --arg target "$target_id" '
      any(.resource_changes[]; .address == $group and .type == "aws_lb_target_group" and .change.actions == ["create"]) and
      any(.resource_changes[]; .type == "aws_network_interface" and (((.change.after.private_ips // []) | index($target)) != null))
    ' "$PLAN_JSON" >/dev/null || die "planned target attachment is not bound to collision-checked target group and CE listener ENI: $address"
    continue
  fi
  if [[ $type == aws_ec2_transit_gateway_vpc_attachment ]]; then
    expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
    name=$(jq -er '.Name' <<<"$expected_tags") || die "planned TGW VPC attachment Name tag is unavailable for $address"
    response="$SCRATCH/aws-tgw-attachments-${RANDOM}.json"
    aws ec2 describe-transit-gateway-attachments --region "$AWS_REGION" --output json >"$response" 2>/dev/null ||
      die "cannot inspect AWS TGW attachment candidates for $address"
    matches=$(jq -ec --argjson expected "$expected_tags" '
      [.TransitGatewayAttachments[]? |
       (.Tags // [] | map({key:.Key,value:.Value}) | from_entries) as $tags |
       select($tags == $expected) |
       {id:.TransitGatewayAttachmentId,tags:$tags}]
    ' "$response") || die "cannot normalize AWS TGW attachment candidates for $address"
    match_count=$(jq -er 'length' <<<"$matches") || die "cannot count AWS TGW attachment candidates for $address"
    [[ $match_count -eq 0 ]] && continue
    [[ $match_count -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple TGW attachments match the exact ownership tags)"
    actual_tags=$(jq -ec '.[0].tags' <<<"$matches") || die "cannot read AWS TGW attachment ownership tags for $address"
    require_aws_ownership "$expected_tags" "$actual_tags" "$name" || die "unowned or ambiguous AWS collision: $address ($name)"
    identity=$(jq -ec '.[0] | {resource_uid:.id,created_at:null,creation_evidence:"not_exposed_by_ec2_describe_transit_gateway_attachments"}' <<<"$matches") ||
      die "cannot read AWS TGW attachment identity for $address"
    append_aws_collision "$type" "$address" "$name" "$expected_tags" "$actual_tags" "$identity"
    continue
  fi
  if [[ $type == aws_ec2_transit_gateway_connect_peer ]]; then
    expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
    name=$(jq -er '.Name' <<<"$expected_tags") || die "planned Connect peer Name tag is unavailable for $address"
    response="$SCRATCH/aws-connect-peers-${RANDOM}.json"
    aws ec2 describe-transit-gateway-connect-peers --region "$AWS_REGION" --output json >"$response" 2>/dev/null ||
      die "cannot inspect AWS Connect-peer candidates for $address"
    matches=$(jq -ec --argjson expected "$expected_tags" '
      [.TransitGatewayConnectPeers[]? |
       (.Tags // [] | map({key:.Key,value:.Value}) | from_entries) as $tags |
       select($tags == $expected) |
       {
         id:.TransitGatewayConnectPeerId,
         tags:$tags,
         observed_config:{
           inside_cidr_blocks:(.InsideCidrBlocks // []),
           peer_address:(.PeerAddress // ""),
           transit_gateway_attachment_id:(.TransitGatewayAttachmentId // ""),
           bgp_asn:(.BgpAsn | tostring),
           transit_gateway_address:(.TransitGatewayAddress // "")
         }
       }]
    ' "$response") || die "cannot normalize AWS Connect-peer candidates for $address"
    match_count=$(jq -er 'length' <<<"$matches") || die "cannot count AWS Connect-peer candidates for $address"
    [[ $match_count -eq 0 ]] && continue
    [[ $match_count -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple Connect peers match the exact ownership tags)"
    actual_tags=$(jq -ec '.[0].tags' <<<"$matches") || die "cannot read AWS Connect-peer ownership tags for $address"
    require_aws_ownership "$expected_tags" "$actual_tags" "$name" || die "unowned or ambiguous AWS collision: $address ($name)"
    identity=$(jq -ec '.[0] | {
      resource_uid:.id,
      created_at:null,
      creation_evidence:"not_exposed_by_ec2_describe_transit_gateway_connect_peers",
      observed_config:.observed_config
    }' <<<"$matches") ||
      die "cannot read AWS Connect-peer identity for $address"
    append_aws_collision "$type" "$address" "$name" "$expected_tags" "$actual_tags" "$identity"
    continue
  fi
  case "$type" in
  aws_key_pair | aws_iam_role | aws_iam_instance_profile | aws_lb | aws_lb_target_group | aws_eip | aws_instance | aws_internet_gateway | aws_network_interface | aws_route_table | aws_security_group | aws_subnet | aws_vpc | aws_iam_role_policy)
    case "$type" in
    aws_key_pair)
      name=$(jq -er '.key_name' <<<"$after")
      lookup=(ec2 describe-key-pairs --key-names "$name")
      ;;
    aws_iam_role)
      name=$(jq -er '.name' <<<"$after")
      lookup=(iam get-role --role-name "$name")
      ;;
    aws_iam_instance_profile)
      name=$(jq -er '.name' <<<"$after")
      lookup=(iam get-instance-profile --instance-profile-name "$name")
      ;;
    aws_lb)
      name=$(jq -er '.name' <<<"$after")
      lookup=(elbv2 describe-load-balancers --names "$name")
      ;;
    aws_lb_target_group)
      name=$(jq -er '.name' <<<"$after")
      lookup=(elbv2 describe-target-groups --names "$name")
      ;;
    aws_eip)
      # Elastic IPs have allocation IDs only after creation. The exact
      # deployment tag tuple is therefore their planned identity; make that
      # binding explicit in the evidence name for legacy-recovery validation.
      name="${COMPONENT}-${DEPLOYMENT_GENERATION}-eip-${address}"
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t eip_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#eip_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-addresses --filters "${eip_tag_filters[@]}")
      ;;
    aws_instance)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t instance_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#instance_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-instances --filters "${instance_tag_filters[@]}")
      ;;
    aws_internet_gateway)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t igw_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#igw_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-internet-gateways --filters "${igw_tag_filters[@]}")
      ;;
    aws_network_interface)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t eni_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#eni_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-network-interfaces --filters "${eni_tag_filters[@]}")
      ;;
    aws_route_table)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t rt_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#rt_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-route-tables --filters "${rt_tag_filters[@]}")
      ;;
    aws_security_group)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t sg_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#sg_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-security-groups --filters "${sg_tag_filters[@]}")
      ;;
    aws_subnet)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t subnet_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#subnet_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-subnets --filters "${subnet_tag_filters[@]}")
      ;;
    aws_vpc)
      name=$address
      expected_tags=$(jq -ec '.tags // {}' <<<"$after") || die "planned tags are invalid for $address"
      mapfile -t vpc_tag_filters < <(jq -r 'to_entries[] | "Name=tag:\(.key),Values=\(.value)"' <<<"$expected_tags")
      ((${#vpc_tag_filters[@]} > 0)) || die "planned tags are incomplete for $address"
      lookup=(ec2 describe-vpcs --filters "${vpc_tag_filters[@]}")
      ;;
    aws_iam_role_policy)
      name=$(jq -er '.name' <<<"$after") || die "planned inline policy name is invalid for $address"
      role_name=$(jq -er '.role' <<<"$after" 2>/dev/null || true)
      if [[ -z $role_name ]]; then
        policy_config_address=${address%%\[*}
        role_reference=$(jq -er --arg address "$policy_config_address" '
          .configuration.root_module.resources[] | select(.address == $address) |
          .expressions.role.references[0] // empty
        ' "$PLAN_JSON") || die "planned inline policy role reference is unavailable for $address"
        role_resource_address=${role_reference%.id}
        role_name=$(jq -er --arg address "$role_resource_address" '
          .resource_changes[] | select(.address == $address) | .change.after.name // empty
        ' "$PLAN_JSON") || die "planned inline policy role is unavailable for $address"
      fi
      lookup=(iam get-role-policy --role-name "$role_name" --policy-name "$name")
      ;;
    esac
    expected_tags=${expected_tags:-$(jq -ec '.tags // {}' <<<"$after")} || die "planned tags are invalid for $address"
    response="$SCRATCH/aws-${RANDOM}.json"
    error="$SCRATCH/aws-${RANDOM}.err"
    if aws_lookup "$response" "$error" "${lookup[@]}"; then
      if [[ $type == aws_iam_role_policy ]]; then
        role_response="$SCRATCH/aws-role-${RANDOM}.json"
        role_error="$SCRATCH/aws-role-${RANDOM}.err"
        aws_lookup "$role_response" "$role_error" iam get-role --role-name "$role_name" ||
          die "cannot inspect IAM role ownership for existing $address"
        actual_tags=$(aws_tags_for aws_iam_role "$role_response") || die "cannot read IAM role tags for existing $address"
        role_identity=$(aws_identity_for aws_iam_role "$role_response") || die "cannot read IAM role identity for existing $address"
        expected_tags=$(jq -ec --arg role "$role_name" '
          [.resource_changes[] | select(.type == "aws_iam_role" and .change.after.name == $role) | .change.after.tags][0] // empty
        ' "$PLAN_JSON") || die "planned parent role tags are unavailable for $address"
        require_aws_ownership "$expected_tags" "$actual_tags" "$role_name" ||
          die "unowned or ambiguous AWS collision: $address ($role_name/$name)"
        identity=$(jq -nc --arg role "$role_name" --arg policy "$name" --arg role_id "$(jq -r '.resource_uid' <<<"$role_identity")" '{resource_uid:($role_id + ":" + $policy),created_at:null,creation_evidence:"not_exposed_by_iam_get_role_policy"}')
        append_aws_collision "$type" "$address" "${role_name}/${name}" "$expected_tags" "$actual_tags" "$identity"
        continue
      fi
      if [[ $type == aws_eip ]]; then
        eip_matches=$(jq -er '.Addresses | length' "$response") || die "cannot read existing EIP candidates for $address"
        [[ $eip_matches -eq 0 ]] && continue
        [[ $eip_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple Elastic IPs match the planned ownership tags)"
      fi
      if [[ $type == aws_instance ]]; then
        instance_matches=$(jq -er '[.Reservations[].Instances[]?] | length' "$response") || die "cannot read existing instance candidates for $address"
        [[ $instance_matches -eq 0 ]] && continue
        [[ $instance_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple instances match the planned ownership tags)"
      fi
      if [[ $type == aws_internet_gateway ]]; then
        igw_matches=$(jq -er '.InternetGateways | length' "$response") || die "cannot read existing internet gateway candidates for $address"
        [[ $igw_matches -eq 0 ]] && continue
        [[ $igw_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple internet gateways match the planned ownership tags)"
      fi
      if [[ $type == aws_network_interface ]]; then
        eni_matches=$(jq -er '.NetworkInterfaces | length' "$response") || die "cannot read existing network interface candidates for $address"
        [[ $eni_matches -eq 0 ]] && continue
        [[ $eni_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple network interfaces match the planned ownership tags)"
      fi
      if [[ $type == aws_route_table ]]; then
        rt_matches=$(jq -er '.RouteTables | length' "$response") || die "cannot read existing route table candidates for $address"
        [[ $rt_matches -eq 0 ]] && continue
        [[ $rt_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple route tables match the planned ownership tags)"
      fi
      if [[ $type == aws_security_group ]]; then
        sg_matches=$(jq -er '.SecurityGroups | length' "$response") || die "cannot read existing security group candidates for $address"
        [[ $sg_matches -eq 0 ]] && continue
        [[ $sg_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple security groups match the planned ownership tags)"
      fi
      if [[ $type == aws_subnet ]]; then
        subnet_matches=$(jq -er '.Subnets | length' "$response") || die "cannot read existing subnet candidates for $address"
        [[ $subnet_matches -eq 0 ]] && continue
        [[ $subnet_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple subnets match the planned ownership tags)"
      fi
      if [[ $type == aws_vpc ]]; then
        vpc_matches=$(jq -er '.Vpcs | length' "$response") || die "cannot read existing VPC candidates for $address"
        [[ $vpc_matches -eq 0 ]] && continue
        [[ $vpc_matches -eq 1 ]] || die "unowned or ambiguous AWS collision: $address (multiple VPCs match the planned ownership tags)"
      fi
      actual_tags=$(aws_tags_for "$type" "$response") || die "cannot read tags for existing $address"
      require_aws_ownership "$expected_tags" "$actual_tags" "$name" || die "unowned or ambiguous AWS collision: $address ($name)"
      identity=$(aws_identity_for "$type" "$response") || die "cannot read provider identity for existing $address"
      jq -e '.resource_uid | type == "string" and length > 0' <<<"$identity" >/dev/null ||
        die "provider identity is unavailable for existing $address"
      append_aws_collision "$type" "$address" "$name" "$expected_tags" "$actual_tags" "$identity"
    else
      status=$?
      [[ $status -eq 10 ]] || die "cannot inspect AWS collision candidate: $address"
    fi
    ;;
  xcsh_virtual_site | xcsh_origin_pool | xcsh_http_loadbalancer | xcsh_token | xcsh_securemesh_site_v2 | xcsh_bgp | xcsh_external_connector)
    name=$(jq -er '.name' <<<"$after") || die "planned name is invalid for $address"
    namespace=$(jq -er '.namespace' <<<"$after") || die "planned namespace is invalid for $address"
    expected_labels=$(jq -ec '.labels // {}' <<<"$after") || die "planned labels are invalid for $address"
    if [[ $RECOVERY_MODE == strict ]]; then
      jq -e --arg generation "$DEPLOYMENT_GENERATION" '
        .["mcn-deployment-generation"] == $generation' <<<"$expected_labels" >/dev/null ||
        die "planned deployment generation label is missing or mismatched for $address"
    else
      jq -e --arg generation "$DEPLOYMENT_GENERATION" '
        ((.["mcn-deployment-generation"]? // $generation) == $generation)' <<<"$expected_labels" >/dev/null ||
        die "legacy planned generation label conflicts with the recovery generation for $address"
    fi
    endpoint=$(f5_endpoint "$type")
    prefix=$(f5_namespace_prefix "$type")
    body="$SCRATCH/f5-${RANDOM}.json"
    status=$("${CURL_BIN:-curl}" --silent --show-error --output "$body" --write-out '%{http_code}' \
      -H "Authorization: APIToken $XCSH_API_TOKEN" \
      "${XCSH_API_URL%/}/${prefix}/${namespace}/${endpoint}/${name}") || die "cannot inspect F5 collision candidate: $address"
    case "$status" in
    404) ;;
    200)
      if [[ $RECOVERY_MODE == legacy_unlabelled && $name != "$COMPONENT-$DEPLOYMENT_GENERATION-"* ]]; then
        die "legacy recovery name is not bound to the expected component and generation: $address"
      fi
      jq -e --arg creator "$CREATOR_ID" --arg name "$name" --arg namespace "$namespace" \
        --arg generation "$DEPLOYMENT_GENERATION" --arg recovery_mode "$RECOVERY_MODE" '
            .metadata.name == $name and .metadata.namespace == $namespace and
            (if $recovery_mode == "strict" then
              .metadata.labels["mcn-deployment-generation"] == $generation
            else
              ((.metadata.labels["mcn-deployment-generation"]? // $generation) == $generation)
            end) and
            .system_metadata.creator_id == $creator and
            (.system_metadata.uid | type == "string" and length > 0) and
            (.system_metadata.creation_timestamp | type == "string" and length > 0)' "$body" >/dev/null ||
        die "unowned or ambiguous F5 collision: $address ($namespace/$name)"
      observed=$(jq -ec '{metadata:{labels:.metadata.labels},system_metadata:{
        creator_id:.system_metadata.creator_id,creation_timestamp:.system_metadata.creation_timestamp,
        uid:.system_metadata.uid}}' "$body") || die "cannot normalize F5 ownership evidence for $address"
      append_f5_collision "$type" "$address" "$name" "$namespace" "$expected_labels" "$observed"
      ;;
    *) die "unexpected F5 response for $address: $status" ;;
    esac
    ;;
  *) die "preflight has no complete ownership adapter for planned resource type: $type ($address)" ;;
  esac
done < <(jq -c '
  .resource_changes[]? |
  select(.change.actions == ["create"]) |
  {address, type, after:.change.after}' "$PLAN_JSON")

collisions=$(jq -sc 'sort_by(.engine, .type, .address)' "$collisions_file")
plan_sha256="sha256:$(sha256sum "$PLAN_JSON" | awk '{print $1}')"
inventory_captured_at=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
if [[ $collisions == '[]' ]]; then status=ready; else status=blocked; fi
jq -n --argjson collisions "$collisions" --arg status "$status" \
  --argjson caller_identity "$caller_identity" --arg inventory_captured_at "$inventory_captured_at" \
  --arg plan_sha256 "$plan_sha256" --arg aws_region "$AWS_REGION" \
  --arg aws_account_id "$AWS_ACCOUNT_ID" --arg deployment_generation "$DEPLOYMENT_GENERATION" \
  --arg xc_tenant "$XC_TENANT" --arg creator_id "$CREATOR_ID" --arg component "$COMPONENT" \
  --arg recovery_mode "$RECOVERY_MODE" \
  '{schema_version:2,status:$status,plan_sha256:$plan_sha256,
    aws_region:$aws_region,aws_account_id:$aws_account_id,
    aws_caller_arn:($caller_identity.Arn // null),
    aws_caller_user_id:($caller_identity.UserId // null),inventory_captured_at:$inventory_captured_at,
    xc_tenant:$xc_tenant,creator_id:$creator_id,component:$component,
    deployment_generation:$deployment_generation,recovery_mode:$recovery_mode,
    collisions:$collisions}' >"$MANIFEST"
chmod 600 "$MANIFEST"

if [[ $status == blocked ]]; then
  printf 'blocked: owned collision(s) recorded in %s; do not apply this plan\n' "$MANIFEST" >&2
  exit 3
fi
printf 'ready: no owned name collision in reviewed plan\n'
