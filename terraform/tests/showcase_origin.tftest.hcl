# Test suite for Canadian Azure Internal Load Balancer (ILB) variant architecture.

mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { mac_address = "52:54:00:10:00:11" }
  }
}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

variables {
  enable_azure           = true
  enable_kvm             = false
  site_prefix            = null
  ca_site_prefix         = null
  lb_name                = null
  ca_lb_name             = null
  origin_pool_name       = null
  ca_origin_pool_name    = null
  route_server_name      = null
  ca_route_server_name   = null
  bastion_name           = null
  ca_bastion_name        = null
  client_vm_name         = null
  ca_client_vm_name      = null
  region_short           = null
  ca_region_short        = null
  resource_group_name    = null
  ca_resource_group_name = null
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  ca_lb_domain           = "mcn-ce-ha.f5-sales-demo.ca"
  origin_ip              = "203.0.113.10"
  deployer               = "tester"
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  xc_app_namespace       = "multi-cloud-networking"
  enable_aws             = false
  enable_aws_tgw_connect = false
  enable_canada          = true
  enable_canada_ilb      = true
}


run "distinct_owned_origins_selected_by_region" {
  command = plan
  variables { enable_showcase_origin = true }
  override_data {
    target = data.xcsh_network_regional_edges.origin[0]
    values = { cidr_blocks = ["192.0.2.0/24"], api_release_tag = "v9.0.0" }
  }
  override_data {
    target = data.xcsh_network_cdn.origin[0]
    values = { cidr_blocks = ["192.0.2.0/24"], api_release_tag = "v9.0.0" }
  }

  override_module {
    target  = module.showcase_origin[0]
    outputs = { public_ip = "198.51.100.42" }
  }
  override_module {
    target  = module.showcase_origin_ca[0]
    outputs = { public_ip = "198.51.100.43" }
  }
  assert {
    condition = (
      output.origin_ip == "198.51.100.42" &&
      output.ca_origin_ip == "198.51.100.43" &&
      xcsh_origin_pool.this[0].origin_servers[0].private_ip.ip == "198.51.100.42" &&
      xcsh_origin_pool.canada[0].origin_servers[0].private_ip.ip == "198.51.100.43"
    )
    error_message = "Each regional pool and its controls must use a distinct owned regional origin."
  }

}
run "external_origin_preserved_when_disabled" {
  command = plan
  variables { enable_showcase_origin = false }
  assert {
    condition     = output.origin_ip == var.origin_ip && length(module.showcase_origin) == 0 && length(module.showcase_origin_ca) == 0 && output.ca_origin_ip == var.origin_ip
    error_message = "Existing external-origin deployments must remain supported."
  }
}


run "canadian_origin_is_owned_in_canada_with_restricted_ingress" {
  command = plan
  variables {
    enable_showcase_origin = true
    origin_developer_cidrs = ["198.51.100.10/32", "203.0.113.20/32"]
  }
  override_data {
    target = data.xcsh_network_regional_edges.origin[0]
    values = { cidr_blocks = ["192.0.2.0/24"], api_release_tag = "v9.0.0" }
  }
  override_data {
    target = data.xcsh_network_cdn.origin[0]
    values = { cidr_blocks = ["192.0.2.128/25"], api_release_tag = "v9.0.0" }
  }
  assert {
    condition = (
      module.showcase_origin_ca[0].vm_name != module.showcase_origin[0].vm_name &&
      contains(["canadacentral", "canadaeast"], module.azure_hub_ca[0].location) &&
      output.ca_origin_ingress_acl.f5_cidrs == output.origin_ingress_acl.f5_cidrs &&
      output.ca_origin_ingress_acl.developer_cidrs == var.origin_developer_cidrs &&
      length(output.ca_origin_ingress_acl.owned_demo_cidrs) == 8
    )
    error_message = "Canadian origin needs distinct ownership, Canadian subnet and complete restricted source ACL."
  }
}
run "non_canadian_origin_region_rejected" {
  command = plan
  variables { ca_location = "eastus" }
  expect_failures = [var.ca_location]
}
run "explicit_external_canadian_origin" {
  command = plan
  variables {
    enable_showcase_origin = false
    ca_origin_ip           = "203.0.113.11"
  }
  assert {
    condition     = output.ca_origin_ip == "203.0.113.11" && xcsh_origin_pool.canada[0].origin_servers[0].private_ip.ip == "203.0.113.11"
    error_message = "Explicit Canadian external origins must remain independent of the US origin."
  }
}
