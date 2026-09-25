# Test suite for Canadian Azure Internal Load Balancer (ILB) variant architecture.

mock_provider "azurerm" {}
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

run "canadian_ilb_plans_successfully" {
  command = plan

  variables {
    ca_ce_count = 3
  }

  assert {
    condition     = output.ca_ilb_frontend_ip == "10.200.3.10"
    error_message = "Canada ILB frontend private IP should be 10.200.3.10."
  }

  assert {
    condition     = length(azurerm_lb.ca_ilb) == 1
    error_message = "When enable_canada = true and enable_canada_ilb = true, exactly one Canadian ILB should be created."
  }

  assert {
    condition     = length(azurerm_lb_rule.ca_application) == 1 && length(azurerm_lb_rule.ca_console) == 1
    error_message = "Canadian ILB application and console rules should be created."
  }
}

run "canadian_ilb_disabled_plans_no_ilb_resources" {
  command = plan

  variables {
    enable_canada_ilb = false
  }

  assert {
    condition     = length(azurerm_lb.ca_ilb) == 0
    error_message = "When enable_canada_ilb = false, no Canadian ILB should be created."
  }

  assert {
    condition     = output.ca_ilb_id == null
    error_message = "When enable_canada_ilb = false, ca_ilb_id output must be null."
  }
}
