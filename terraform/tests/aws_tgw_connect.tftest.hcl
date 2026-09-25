# Three independent one-node sites share two role-based TGW Connect
# attachments, with one SLO and one SLI peer per site.
mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "libvirt" {}
mock_provider "random" {}
mock_provider "docker" {}

mock_provider "aws" {
  mock_resource "aws_ec2_transit_gateway_connect_peer" {
    override_during = plan
    defaults = {
      bgp_peer_address              = "169.254.100.1"
      bgp_transit_gateway_addresses = ["169.254.100.2", "169.254.100.3"]
      transit_gateway_address       = "100.64.0.1"
    }
  }
}

mock_provider "xcsh" {}
mock_provider "azapi" {}

override_data {
  override_during = plan
  target          = data.xcsh_smsv2_contract.aws[0]
  values = {
    contract_id         = "f5xc-smsv2-api/v1"
    contract_version    = "7.0.0"
    api_release_tag     = "v8.0.2"
    api_release_commit  = format("%s%s", "00f60b8792a1962b88d4", "0377114724c61f276062")
    telemetry_schema_id = "f5xc-smsv2-aws-tgw-telemetry/v2"
    capabilities = {
      aws_ce_create          = "available"
      aws_node_configuration = "available"
      runtime_status         = "available"
      site_upgrade           = "available"
      tgw_connect            = "available"
    }
    aws_node_configuration = jsonencode({ strategy = "discovery_rebuild", enforcement = "required", invariants = { device_source = "observed_registration_only" } })
    f5xc_authorities       = ["smsv2_configuration", "runtime_health", "bgp_peers", "bgp_routes", "simplified_routes", "site_upgrade_observation"]
    aws_authorities        = ["eni", "transit_gateway", "transit_gateway_connect", "gre_endpoints", "bgp_inside_cidrs", "autonomous_system_numbers"]
  }
}

override_resource {
  override_during = plan
  target          = aws_network_interface.slo[0]
  values          = { mac_address = "02:00:00:00:00:01", private_ip = "10.150.1.10" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.slo[1]
  values          = { mac_address = "02:00:00:00:00:02", private_ip = "10.150.2.10" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.slo[2]
  values          = { mac_address = "02:00:00:00:00:03", private_ip = "10.150.3.10" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[0]
  values          = { mac_address = "02:00:00:00:01:01", private_ip = "10.150.11.10" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[1]
  values          = { mac_address = "02:00:00:00:01:02", private_ip = "10.150.12.10" }
}
override_resource {
  override_during = plan
  target          = aws_network_interface.sli[2]
  values          = { mac_address = "02:00:00:00:01:03", private_ip = "10.150.13.10" }
}

override_data {
  target = data.xcsh_smsv2_aws_runtime.aws["01"]
  values = {
    healthy = true
    interfaces = {
      node_01_slo = { node = "mcn-ce-ha-aws-ap-northeast-1-01", role = "slo", mac = "02:00:00:00:00:01", interface_name = "site-01-eth0", mtu = 1500, healthy = true }
      node_01_sli = { node = "mcn-ce-ha-aws-ap-northeast-1-01", role = "sli", mac = "02:00:00:00:01:01", interface_name = "site-01-eth1", mtu = 1500, healthy = true }
    }
  }
}
override_data {
  target = data.xcsh_smsv2_aws_runtime.aws["02"]
  values = {
    healthy = true
    interfaces = {
      node_02_slo = { node = "mcn-ce-ha-aws-ap-northeast-1-02", role = "slo", mac = "02:00:00:00:00:02", interface_name = "site-02-eth0", mtu = 1500, healthy = true }
      node_02_sli = { node = "mcn-ce-ha-aws-ap-northeast-1-02", role = "sli", mac = "02:00:00:00:01:02", interface_name = "site-02-eth1", mtu = 1500, healthy = true }
    }
  }
}
override_data {
  target = data.xcsh_smsv2_aws_runtime.aws["03"]
  values = {
    healthy = true
    interfaces = {
      node_03_slo = { node = "mcn-ce-ha-aws-ap-northeast-1-03", role = "slo", mac = "02:00:00:00:00:03", interface_name = "site-03-eth0", mtu = 1500, healthy = true }
      node_03_sli = { node = "mcn-ce-ha-aws-ap-northeast-1-03", role = "sli", mac = "02:00:00:00:01:03", interface_name = "site-03-eth1", mtu = 1500, healthy = true }
    }
  }
}

variables {
  lb_domain                     = "mcn-ce-ha.example.com"
  aws_lb_domain                 = "aws.mcn-ce-ha.example.com"
  origin_ip                     = "203.0.113.10"
  deployer                      = "tester"
  enable_bastion                = false
  ssh_public_key                = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  aws_ce_ami_id                 = "ami-0123456789abcdef0"
  aws_workload_ami_id           = "ami-0123456789abcdef0"
  aws_vip                       = "10.151.1.10"
  enable_azure                  = false
  enable_kvm                    = false
  enable_aws                    = true
  enable_aws_tgw_connect        = true
  aws_site_configuration_phase  = "configured"
  aws_smsv2_device_mapping_file = "tests/fixtures/aws-device-mapping.valid.json"
}

run "plans_three_sites_six_peers_and_workload_attachment" {
  command = plan

  assert {
    condition     = length(xcsh_securemesh_site_v2.aws) == 3 && alltrue([for site in values(xcsh_securemesh_site_v2.aws) : length(site.aws.not_managed.node_list) == 1])
    error_message = "The topology must contain three independent one-node sites."
  }
  assert {
    condition     = length(module.aws_tgw_connect) == 1 && length(module.aws_tgw_connect[0].connect_attachment_ids) == 2
    error_message = "The topology must contain exactly two role-based Connect attachments."
  }
  assert {
    condition     = length(aws_route_table_association.public) == 3 && length(aws_route_table_association.private) == 3 && length(terraform_data.aws_tgw_site_route_gate) == 3 && length(aws_ec2_transit_gateway_connect_peer.aws) == 6 && length(xcsh_external_connector.aws_tgw) == 6
    error_message = "All three site subnet pairs must be associated before six MAC-bound interfaces own an AWS Connect peer and XC external connector."
  }
  assert {
    condition     = alltrue([for binding in values(local.aws_smsv2_bindings) : binding.payload_role == "sli"])
    error_message = "TGW external connectors must retain the API-required Site Local Inside payload network."
  }
  assert {
    condition     = length(xcsh_bgp.aws_tgw) == 3 && alltrue([for bgp in values(xcsh_bgp.aws_tgw) : length(bgp.peers) == 4])
    error_message = "Every site must configure both AWS BGP endpoints on each of its two Connect peers."
  }
  assert {
    condition = alltrue([for site_key, bgp in xcsh_bgp.aws_tgw :
      bgp.name == "${local.aws_resource_prefix}-aws-tgw-bgp-${site_key}" && length(bgp.name) <= 64
    ])
    error_message = "Preview BGP names must remain unique and within the XC 64-character limit."
  }
  assert {
    condition     = alltrue(flatten([for bgp in values(xcsh_bgp.aws_tgw) : [for peer in bgp.peers : peer.external.external_connector == null]]))
    error_message = "TGW BGP peers must use their assigned AWS transit-gateway BGP address, not the external-connector address selector."
  }
  assert {
    condition     = alltrue([for status in values(data.xcsh_site_bgp_status.aws) : length(status.expected_peers) == 4])
    error_message = "Each site must observe four distinct BGP sessions."
  }
  assert {
    condition = alltrue([
      for key, status in data.xcsh_site_bgp_status.aws :
      status.expected_exported_routes == toset([format("10.150.%d.10/32", tonumber(key) + 10)]) &&
      alltrue([for peer in values(status.expected_peers) : peer.expected_imported_routes == toset([var.aws_workload_vpc_cidr])])
    ])
    error_message = "Every site must prove its exact exported listener /32 and each session's exact imported workload prefix."
  }
  assert {
    condition     = alltrue([for bgp in values(xcsh_bgp.aws_tgw) : toset([for peer in bgp.peers : peer.external.address]) == toset(["169.254.100.2", "169.254.100.3"])])
    error_message = "Both AWS-assigned endpoint addresses must appear in every BGP object."
  }
  assert {
    condition     = length(data.xcsh_smsv2_aws_runtime.aws) == 3 && length(data.xcsh_site_bgp_status.aws) == 3
    error_message = "Runtime and BGP convergence must be observed independently for all sites."
  }
  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.workload) == 1 && length(aws_ec2_transit_gateway_route_table_association.workload) == 1 && length(aws_ec2_transit_gateway_route_table_propagation.workload) == 1
    error_message = "The workload VPC must have explicit TGW attachment, association, and propagation."
  }
  assert {
    condition = alltrue([
      for expected in ["10.150.11.10/32", "10.150.12.10/32", "10.150.13.10/32"] :
      contains([for route in aws_route_table.workload[0].route : route.cidr_block], expected)
    ])
    error_message = "The workload route table must send all three site-local listener addresses through the TGW."
  }
  assert {
    condition = alltrue([
      for index, expected in ["10.150.11.10", "10.150.12.10", "10.150.13.10"] :
      aws_network_interface.sli[index].private_ips == toset([expected])
    ])
    error_message = "Each SLI ENI must reserve its plan-known site listener address for deterministic rebuilds."
  }
  assert {
    condition = (
      length(aws_lb.smsv2) == 1 &&
      aws_lb.smsv2[0].internal == true &&
      aws_lb.smsv2[0].load_balancer_type == "network" &&
      one(aws_lb.smsv2[0].subnet_mapping).private_ipv4_address == "10.151.1.10"
    )
    error_message = "The stable AWS VIP must be a private, statically addressed Network Load Balancer."
  }
  assert {
    condition = (
      length(aws_lb_target_group.smsv2) == 1 &&
      aws_lb_target_group.smsv2[0].target_type == "ip" &&
      length(aws_lb_target_group_attachment.smsv2) == 3 &&
      toset([for target in values(aws_lb_target_group_attachment.smsv2) : target.target_id]) == toset([
        "10.150.11.10",
        "10.150.12.10",
        "10.150.13.10",
      ]) &&
      length(aws_lb_listener.smsv2) == 1
    )
    error_message = "The NLB must forward TCP/80 to all three BGP-routed site-local listeners."
  }
}

run "bootstrap_stage_has_no_tgw_or_runtime_actions" {
  command = plan

  variables {
    aws_site_configuration_phase  = "bootstrap"
    aws_smsv2_device_mapping_file = null
    enable_aws_tgw_connect        = false
  }

  assert {
    condition = (
      length(xcsh_securemesh_site_v2.aws) == 3 &&
      length(aws_instance.ce) == 3 &&
      length(data.xcsh_smsv2_aws_runtime.aws) == 0 &&
      length(terraform_data.aws_tgw_site_route_gate) == 0 &&
      length(aws_ec2_transit_gateway_connect_peer.aws) == 0 &&
      length(xcsh_external_connector.aws_tgw) == 0 &&
      length(xcsh_bgp.aws_tgw) == 0 &&
      length(data.xcsh_site_bgp_status.aws) == 0
    )
    error_message = "Bootstrap must create all three discovery CEs without any TGW or runtime action."
  }
}
