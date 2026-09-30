mock_provider "azurerm" {}
run "origin_http_has_explicit_allow_and_deny" {
  command = plan
  module { source = "./modules/client-vm" }
  variables {
    name                = "test-origin"
    resource_group_name = "test-rg"
    location            = "eastus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/test/subnets/test"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    serve_http          = true
    allow_ssh           = false
    restrict_ingress    = true
    http_source_cidrs   = ["192.0.2.0/24", "198.51.100.10/32", "203.0.113.20/32"]
  }
  assert {
    condition     = length(azurerm_network_security_group.this.security_rule) == 2 && alltrue([for rule in azurerm_network_security_group.this.security_rule : rule.name != "SSH"])
    error_message = "Origin must expose only explicit HTTP sources with an overriding deny rule."
  }
  assert {
    condition     = one([for rule in azurerm_network_security_group.this.security_rule : rule if rule.name == "HTTP"]).source_address_prefixes == toset(var.http_source_cidrs) && one([for rule in azurerm_network_security_group.this.security_rule : rule if rule.name == "deny-other-origin-ingress"]).access == "Deny"
    error_message = "HTTP sources must match the ACL and other origin ingress must be denied."
  }
}

run "origin_management_address_is_static" {
  command = plan
  module { source = "./modules/client-vm" }
  variables {
    name                = "test-origin"
    resource_group_name = "test-rg"
    location            = "eastus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/test/subnets/test"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    private_ip          = "10.0.1.30"
  }
  assert {
    condition     = azurerm_network_interface.this.ip_configuration[0].private_ip_address_allocation == "Static" && azurerm_network_interface.this.ip_configuration[0].private_ip_address == "10.0.1.30"
    error_message = "The dedicated origin address must use static NIC allocation."
  }
}
run "ordinary_client_address_remains_dynamic" {
  command = plan
  module { source = "./modules/client-vm" }
  variables {
    name                = "test-client"
    resource_group_name = "test-rg"
    location            = "eastus"
    subnet_id           = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/test-rg/providers/Microsoft.Network/virtualNetworks/test/subnets/test"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }
  assert {
    condition     = azurerm_network_interface.this.ip_configuration[0].private_ip_address_allocation == "Dynamic"
    error_message = "Ordinary clients must retain dynamic addressing."
  }
}
