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
  lb_name                = null
  origin_pool_name       = null
  route_server_name      = null
  bastion_name           = null
  client_vm_name         = null
  region_short           = null
  resource_group_name    = null
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  deployer               = "tester"
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  xc_app_namespace       = "multi-cloud-networking"
  enable_aws             = false
  enable_aws_tgw_connect = false
}


run "distinct_owned_origins_selected_by_region" {
  command = plan
  variables { enable_showcase_origin = true }
  override_data {
    target = data.xcsh_network_regional_edges.origin[0]
    values = { cidr_blocks = ["192.0.2.0/24"], api_release_tag = "v9.0.2" }
  }
  override_data {
    target = data.xcsh_network_cdn.origin[0]
    values = { cidr_blocks = ["192.0.2.0/24"], api_release_tag = "v9.0.2" }
  }

  override_module {
    target  = module.showcase_origin[0]
    outputs = { public_ip = "198.51.100.42" }
  }
  assert {
    condition = (
      output.origin_ip == "198.51.100.42" &&
      xcsh_origin_pool.this[0].origin_servers[0].private_ip.ip == "198.51.100.42"
    )
    error_message = "Each regional pool and its controls must use a distinct owned regional origin."
  }

}
run "external_origin_preserved_when_disabled" {
  command = plan
  variables { enable_showcase_origin = false }
  assert {
    condition     = output.origin_ip == var.origin_ip && length(module.showcase_origin) == 0
    error_message = "Existing external-origin deployments must remain supported."
  }
}
