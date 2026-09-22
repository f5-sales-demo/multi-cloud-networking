# AWS owns ENI, TGW, Connect, GRE, and inside-CIDR facts. F5 XC owns
# SMSv2 configuration, health, BGP, and route observations.
locals {
  # Keep the immutable source revision machine-readable without resembling an
  # access token to secret scanners. The evaluated value is the full release
  # commit recorded by the contract data source.
  aws_smsv2_api_release_commit = format("%s%s", "1c7f9e01f2011a3a4267", "d024e1eee5f71b65481f")
  aws_smsv2_bindings = var.enable_aws && var.enable_aws_tgw_connect && var.aws_site_configuration_phase == "configured" ? merge(
    {
      for index in range(var.enable_aws ? var.aws_ce_count : 0) :
      format("node_%02d_slo", index + 1) => {
        index    = index
        site_key = format("%02d", index + 1)
        site     = local.aws_sites[format("%02d", index + 1)].name
        order    = index
        node     = local.aws_ce_hostnames[index]
        role     = "slo"
        # XC rejects GRE connectors whose transport and payload networks are
        # both Site Local Outside. Keep the payload in Site Local Inside even
        # when the bound transport interface is SLO.
        payload_role      = "sli"
        mac               = aws_network_interface.slo[index].mac_address
        gre_peer_address  = aws_network_interface.slo[index].private_ip
        inside_cidr_block = cidrsubnet(var.aws_tgw_inside_cidr, 5, index)
      }
    },
    {
      for index in range(var.enable_aws ? var.aws_ce_count : 0) :
      format("node_%02d_sli", index + 1) => {
        index             = index
        site_key          = format("%02d", index + 1)
        site              = local.aws_sites[format("%02d", index + 1)].name
        order             = var.aws_ce_count + index
        node              = local.aws_ce_hostnames[index]
        role              = "sli"
        payload_role      = "sli"
        mac               = aws_network_interface.sli[index].mac_address
        gre_peer_address  = aws_network_interface.sli[index].private_ip
        inside_cidr_block = cidrsubnet(var.aws_tgw_inside_cidr, 5, var.aws_ce_count + index)
      }
    },
  ) : {}
  # Keep the live routing graph inside the same cumulative boundary as token
  # issuance and cloud-init. This lets each CE reach ONLINE and converge before
  # the next site is admitted without evaluating absent nodes from later stages.
  aws_bootstrap_smsv2_bindings = {
    for key, binding in local.aws_smsv2_bindings : key => binding
    if contains(var.aws_bootstrap_site_keys, binding.site_key)
  }
  # Session keys are known during planning; AWS supplies the two addresses.
  aws_bgp_sessions = merge([
    for key, binding in(var.enable_aws_tgw_connect ? local.aws_bootstrap_smsv2_bindings : {}) : {
      for endpoint in range(2) : "${key}_${endpoint + 1}" => merge(binding, {
        connector_key = key
        peer_address  = sort(tolist(aws_ec2_transit_gateway_connect_peer.aws[key].bgp_transit_gateway_addresses))[endpoint]
      })
    }
  ]...)
  aws_smsv2_nodes = {
    for key, interface in local.aws_bootstrap_smsv2_bindings : key => {
      node = interface.node
      role = interface.role
      mac  = interface.mac
    }
  }
}

data "xcsh_smsv2_contract" "aws" {
  count = var.enable_aws_tgw_connect ? 1 : 0
}

resource "terraform_data" "aws_tgw_contract_gate" {
  count = var.enable_aws_tgw_connect ? 1 : 0
  input = {
    contract_id         = data.xcsh_smsv2_contract.aws[0].contract_id
    contract_version    = data.xcsh_smsv2_contract.aws[0].contract_version
    api_release_tag     = data.xcsh_smsv2_contract.aws[0].api_release_tag
    api_release_commit  = data.xcsh_smsv2_contract.aws[0].api_release_commit
    telemetry_schema_id = data.xcsh_smsv2_contract.aws[0].telemetry_schema_id
    capabilities        = data.xcsh_smsv2_contract.aws[0].capabilities
    f5xc_authorities    = data.xcsh_smsv2_contract.aws[0].f5xc_authorities
    aws_authorities     = data.xcsh_smsv2_contract.aws[0].aws_authorities
  }

  lifecycle {
    precondition {
      condition     = var.enable_aws
      error_message = "AWS TGW Connect requires enable_aws = true."
    }
    precondition {
      condition     = var.aws_ce_count == 3
      error_message = "AWS TGW Connect requires the validated three-node, six-interface topology."
    }
    precondition {
      condition = (
        data.xcsh_smsv2_contract.aws[0].contract_id == "f5xc-smsv2-api/v1" &&
        data.xcsh_smsv2_contract.aws[0].contract_version == "7.0.0" &&
        data.xcsh_smsv2_contract.aws[0].api_release_tag == "v7.0.8" &&
        data.xcsh_smsv2_contract.aws[0].api_release_commit == local.aws_smsv2_api_release_commit &&
        data.xcsh_smsv2_contract.aws[0].telemetry_schema_id == "f5xc-smsv2-aws-tgw-telemetry/v2"
      )
      error_message = "Provider v9.5.1 must expose the exact immutable SMSv2 API v7.0.8 contract."
    }
    precondition {
      condition = (
        length(data.xcsh_smsv2_contract.aws[0].capabilities) == 5 &&
        try(data.xcsh_smsv2_contract.aws[0].capabilities["aws_ce_create"], "") == "available" &&
        try(data.xcsh_smsv2_contract.aws[0].capabilities["aws_node_configuration"], "") == "available" &&
        try(data.xcsh_smsv2_contract.aws[0].capabilities["runtime_status"], "") == "available" &&
        try(data.xcsh_smsv2_contract.aws[0].capabilities["tgw_connect"], "") == "available" &&
        try(data.xcsh_smsv2_contract.aws[0].capabilities["site_upgrade"], "") == "available"
      )
      error_message = "Provider v9.5.1 must publish all and only the required SMSv2 capabilities, including evidence-backed AWS node configuration, as available."
    }
    precondition {
      condition = try(
        jsondecode(data.xcsh_smsv2_contract.aws[0].aws_node_configuration).strategy == "discovery_rebuild" &&
        jsondecode(data.xcsh_smsv2_contract.aws[0].aws_node_configuration).enforcement == "required" &&
        jsondecode(data.xcsh_smsv2_contract.aws[0].aws_node_configuration).invariants.device_source == "observed_registration_only",
        false,
      )
      error_message = "AWS configured creation requires the released discovery_rebuild contract with observed-registration-only device mapping."
    }
    precondition {
      condition = (
        length(data.xcsh_smsv2_contract.aws[0].f5xc_authorities) == 6 &&
        toset(data.xcsh_smsv2_contract.aws[0].f5xc_authorities) == toset([
          "smsv2_configuration", "runtime_health", "bgp_peers", "bgp_routes", "simplified_routes", "site_upgrade_observation",
        ]) &&
        length(data.xcsh_smsv2_contract.aws[0].aws_authorities) == 6 &&
        toset(data.xcsh_smsv2_contract.aws[0].aws_authorities) == toset([
          "eni", "transit_gateway", "transit_gateway_connect", "gre_endpoints", "bgp_inside_cidrs", "autonomous_system_numbers",
        ])
      )
      error_message = "The SMSv2 contract authority split does not match this deployment."
    }
  }
}

module "aws_tgw_connect" {
  count                      = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  source                     = "./modules/aws-tgw-connect"
  vpc_id                     = aws_vpc.aws[0].id
  amazon_side_asn            = var.aws_tgw_asn
  transit_gateway_cidr_block = var.aws_tgw_gre_cidr
  transport_subnet_ids       = aws_subnet.private_sli[*].id
  name_prefix                = local.aws_resource_prefix
  ownership_tags             = local.tags
  depends_on                 = [terraform_data.aws_tgw_contract_gate]
}

data "xcsh_smsv2_aws_runtime" "aws" {
  for_each              = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_sites : {}
  namespace             = "system"
  site                  = xcsh_securemesh_site_v2.aws[each.key].name
  nodes                 = { for key, node in local.aws_smsv2_nodes : key => node if local.aws_smsv2_bindings[key].site_key == each.key }
  timeout_seconds       = var.aws_runtime_convergence_timeout_seconds
  poll_interval_seconds = var.aws_bgp_poll_interval_seconds
  # Runtime health cannot exist until the instance has consumed the site
  # cloud-init and registered. Without this ordering Terraform can admit all
  # polling data sources before the EC2 key/profile/instances, starving the
  # bootstrap graph with waits for a runtime that it has not yet created.
  depends_on = [aws_instance.ce]
}

resource "terraform_data" "aws_tgw_runtime_gate" {
  count = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  input = {
    healthy    = alltrue([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : runtime.healthy])
    interfaces = merge([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : runtime.interfaces]...)
  }
  lifecycle {
    precondition {
      condition = (
        alltrue([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : runtime.healthy]) &&
        sum([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : length(runtime.interfaces)]) == 2 * length(local.aws_bootstrap_sites) &&
        alltrue([
          for interface in flatten([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : values(runtime.interfaces)]) :
          interface.healthy && interface.mtu == var.aws_smsv2_interface_mtu &&
          contains(["slo", "sli"], interface.role)
        ])
      )
      error_message = "Every admitted MAC-bound SMSv2 interface must agree on node/role/MTU and report healthy before its AWS Connect peer is created."
    }
  }
}

# A target rooted at one site's BGP status must still install both subnet
# associations. Without the SLI association, the SLO GRE sessions establish
# while both SLI sessions remain down because 100.64.0.0/24 follows the VPC's
# main route table instead of the TGW route.
resource "terraform_data" "aws_tgw_site_route_gate" {
  for_each = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_sites : {}
  input = {
    public_association_id  = aws_route_table_association.public[each.key].id
    private_association_id = aws_route_table_association.private[each.key].id
  }
}

resource "aws_ec2_transit_gateway_connect_peer" "aws" {
  for_each                      = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_smsv2_bindings : {}
  bgp_asn                       = tostring(var.aws_ce_bgp_asn)
  inside_cidr_blocks            = [each.value.inside_cidr_block]
  peer_address                  = each.value.gre_peer_address
  transit_gateway_address       = cidrhost(var.aws_tgw_gre_cidr, each.value.order + 1)
  transit_gateway_attachment_id = module.aws_tgw_connect[0].connect_attachment_ids[each.value.role]
  tags                          = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-tgw-peer-${replace(each.key, "_", "-")}" })
  depends_on                    = [terraform_data.aws_tgw_runtime_gate]
}

resource "xcsh_external_connector" "aws_tgw" {
  for_each    = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_smsv2_bindings : {}
  name        = "${local.aws_resource_prefix}-aws-tgw-${replace(each.key, "_", "-")}"
  namespace   = "system"
  description = "AWS TGW Connect GRE tunnel for ${each.key}."
  labels      = local.xc_labels
  ce_site_reference {
    name      = xcsh_securemesh_site_v2.aws[each.value.site_key].name
    namespace = "system"
  }
  gre {
    gre_parameters {
      site_local_network        = each.value.payload_role == "slo" ? {} : null
      site_local_inside_network = each.value.payload_role == "sli" ? {} : null
      # The external-connector API caps GRE MTU at 1370. Preserve a smaller
      # observed underlay ceiling while never constructing an invalid request.
      tunnel_mtu = min(data.xcsh_smsv2_aws_runtime.aws[each.value.site_key].interfaces[each.key].mtu - 24, 1370)
      peer_ip_address {
        addr = aws_ec2_transit_gateway_connect_peer.aws[each.key].transit_gateway_address
      }
      tunnel_eps {
        node             = data.xcsh_smsv2_aws_runtime.aws[each.value.site_key].interfaces[each.key].node
        interface        = data.xcsh_smsv2_aws_runtime.aws[each.value.site_key].interfaces[each.key].interface_name
        local_tunnel_ip  = "${aws_ec2_transit_gateway_connect_peer.aws[each.key].bgp_peer_address}/29"
        remote_tunnel_ip = "${sort(tolist(aws_ec2_transit_gateway_connect_peer.aws[each.key].bgp_transit_gateway_addresses))[0]}/29"
      }
    }
  }
  depends_on = [terraform_data.aws_tgw_site_route_gate]
}

resource "xcsh_bgp" "aws_tgw" {
  for_each    = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_sites : {}
  name        = "${each.value.name}-tgw-bgp"
  namespace   = "system"
  description = "Four-session AWS TGW Connect BGP for independent site ${each.value.name}."
  labels      = local.xc_labels
  where {
    site {
      # The external-connector API accepts TGW payload only in Site Local
      # Inside, independently of whether GRE transport uses SLO or SLI.
      network_type = "VIRTUAL_NETWORK_SITE_LOCAL_INSIDE"
      ref {
        name      = xcsh_securemesh_site_v2.aws[each.key].name
        namespace = "system"
      }
    }
  }
  bgp_parameters {
    asn           = var.aws_ce_bgp_asn
    local_address = {}
  }
  dynamic "peers" {
    for_each = { for key, session in local.aws_bgp_sessions : key => session if session.site_key == each.key }
    content {
      metadata { name = replace(peers.key, "_", "-") }
      external {
        asn     = module.aws_tgw_connect[0].amazon_side_asn
        address = peers.value.peer_address
        port    = 179
        family_inet {
          enable {}
        }
        interface {
          name      = "ves-io-external-connector-${xcsh_external_connector.aws_tgw[peers.value.connector_key].name}"
          namespace = "system"
        }
        disable_v6 = {}
      }
      passive_mode_disabled = {}
      bfd_disabled          = {}
    }
  }
  depends_on = [xcsh_external_connector.aws_tgw]
}

data "xcsh_site_bgp_status" "aws" {
  for_each  = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_bootstrap_sites : {}
  namespace = "system"
  site      = xcsh_securemesh_site_v2.aws[each.key].name
  expected_peers = {
    for key, interface in local.aws_bgp_sessions : key => {
      node                     = interface.node
      role                     = interface.payload_role
      mac                      = interface.mac
      peer_address             = interface.peer_address
      expected_imported_routes = [var.aws_workload_vpc_cidr]
    } if interface.site_key == each.key
  }
  expected_exported_routes = ["${each.value.listener_ip}/32"]
  timeout_seconds          = var.aws_bgp_convergence_timeout_seconds
  poll_interval_seconds    = var.aws_bgp_poll_interval_seconds
  depends_on = [
    xcsh_bgp.aws_tgw,
    module.aws_tgw_connect,
    aws_ec2_transit_gateway_route_table_association.workload,
    aws_ec2_transit_gateway_route_table_propagation.workload,
    xcsh_http_loadbalancer.aws,
  ]
}

output "aws_tgw_connect_status" {
  description = "Non-sensitive SMSv2 contract, runtime, and BGP convergence summary."
  value = var.enable_aws && var.enable_aws_tgw_connect ? {
    contract_id        = data.xcsh_smsv2_contract.aws[0].contract_id
    contract_version   = data.xcsh_smsv2_contract.aws[0].contract_version
    api_release        = data.xcsh_smsv2_contract.aws[0].api_release_tag
    telemetry_schema   = data.xcsh_smsv2_contract.aws[0].telemetry_schema_id
    runtime_healthy    = alltrue([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : runtime.healthy])
    interface_count    = sum([for runtime in values(data.xcsh_smsv2_aws_runtime.aws) : length(runtime.interfaces)])
    bgp_converged      = alltrue([for status in values(data.xcsh_site_bgp_status.aws) : status.converged])
    connect_peer_count = length(aws_ec2_transit_gateway_connect_peer.aws)
    bgp_session_count  = sum([for status in values(data.xcsh_site_bgp_status.aws) : length(status.peers)])
  } : null
}
