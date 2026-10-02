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


run "provider_f5_acl_and_both_developer_routes" {
  command = plan
  variables {
    enable_showcase_origin = true
    origin_developer_cidrs = ["198.51.100.10/32", "203.0.113.20/32"]
  }
  override_data {
    target = data.xcsh_network_regional_edges.origin[0]
    values = { cidr_blocks = ["192.0.2.0/25", "192.0.2.128/25"], api_release_tag = "v9.0.1" }
  }
  override_data {
    target = data.xcsh_network_cdn.origin[0]
    values = { cidr_blocks = ["192.0.2.0/25"], api_release_tag = "v9.0.1" }
  }
  assert {
    condition     = output.origin_ingress_acl.f5_cidrs == tolist(["192.0.2.0/25", "192.0.2.128/25"]) && output.origin_ingress_acl.developer_cidrs == tolist(["198.51.100.10/32", "203.0.113.20/32"])
    error_message = "The origin ACL must include every provider CIDR and both independent developer egress /32s."
  }
}
run "developer_wildcard_rejected" {
  command = plan
  variables { origin_developer_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.origin_developer_cidrs]
}
