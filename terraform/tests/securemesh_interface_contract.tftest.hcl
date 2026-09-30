mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" { defaults = { mac_address = "52:54:00:10:00:11" } }
}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}
variables {
  deployer               = "tester"
  enable_azure           = true
  enable_kvm             = false
  enable_aws             = false
  enable_aws_tgw_connect = false
  lb_domain              = "app.example.com"
  origin_ip              = "192.0.2.100"
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
}
run "bootstrap_preserves_three_devices_without_assuming_macs" {
  command = plan
  variables { azure_site_configuration_phase = "bootstrap" }
  assert {
    condition     = alltrue([for _, site in module.xc_site : site.interface_count == 3])
    error_message = "Bootstrap must preserve every physical Azure interface."
  }
}
run "secondary_roles_require_registered_mac_join" {
  command = plan
  assert {
    condition     = local.azure_interface_contract.devices == { slo = "eth0", secondary = "registered-mac" }
    error_message = "Secondary Azure roles must resolve by registered MAC identity."
  }
}
