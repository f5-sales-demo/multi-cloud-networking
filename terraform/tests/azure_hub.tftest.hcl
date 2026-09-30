# Plan-level test for the azure-hub module. Mocks azurerm so no Azure credentials
# are contacted. Asserts on the statically-known names (subnet/VNet/RS names are
# literal; resource IDs are known-after-apply and are not asserted).

mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { mac_address = "52:54:00:10:00:11" }
  }
}

run "hub_names_and_subnets" {
  command = plan

  module {
    source = "./modules/azure-hub"
  }

  variables {
    resource_group_name        = "rg-mcn-ce-ha-testdeployer"
    location                   = "eastus"
    hub_cidr                   = "10.0.0.0/16"
    mgmt_subnet_prefix         = "10.0.1.0/26"
    external_subnet_prefix     = "10.0.2.0/26"
    internal_subnet_prefix     = "10.0.3.0/26"
    route_server_subnet_prefix = "10.0.4.0/27"
    route_server_name          = "mcn-ce-ha-rs"
    # Required like every other *_subnet_prefix, even with enable_bastion off:
    # the module never defaults a network address on the caller's behalf.
    bastion_subnet_prefix = "10.0.5.0/26"
    tags                  = {}
  }

  assert {
    condition     = output.vnet_name == "hub-vnet"
    error_message = "Hub VNet must be named hub-vnet."
  }

  assert {
    condition     = length(azurerm_subnet.route_server) == 0 && length(azurerm_route_server.this) == 0
    error_message = "The supported default must plan no Azure Route Server resources."
  }
}

run "route_server_enabled_shape" {
  command = plan

  module {
    source = "./modules/azure-hub"
  }

  variables {
    resource_group_name        = "rg-mcn-ce-ha-testdeployer"
    location                   = "eastus"
    hub_cidr                   = "10.0.0.0/16"
    mgmt_subnet_prefix         = "10.0.1.0/26"
    external_subnet_prefix     = "10.0.2.0/26"
    internal_subnet_prefix     = "10.0.3.0/26"
    route_server_subnet_prefix = "10.0.4.0/27"
    route_server_name          = "mcn-ce-ha-rs"
    enable_route_server        = true
    bastion_subnet_prefix      = "10.0.5.0/26"
    tags                       = {}
  }

  assert {
    condition     = azurerm_subnet.route_server[0].name == "RouteServerSubnet" && azurerm_subnet.route_server[0].address_prefixes[0] == "10.0.4.0/27"
    error_message = "Enabled Route Server must retain its literal /27 subnet."
  }

  assert {
    condition     = azurerm_route_server.this[0].sku == "Standard"
    error_message = "Enabled Route Server must use the Standard SKU."
  }
}

# Bastion is opt-in: switched off it must add NOTHING, so a deployment that does
# not want the hourly charge pays nothing for it.
#
# enable_bastion is set EXPLICITLY rather than left to its default. `terraform
# test` auto-loads a root terraform.tfvars, so a run that leans on the default
# passes in CI (no tfvars) and fails on any workstation whose gitignored
# terraform.tfvars turns Bastion on — an environment-dependent test. Do not
# reintroduce one; the default itself is a declaration, asserted nowhere.
run "bastion_absent_when_disabled" {
  command = plan

  module {
    source = "./modules/azure-hub"
  }

  variables {
    resource_group_name        = "rg-mcn-ce-ha-testdeployer"
    location                   = "eastus"
    hub_cidr                   = "10.0.0.0/16"
    mgmt_subnet_prefix         = "10.0.1.0/26"
    external_subnet_prefix     = "10.0.2.0/26"
    internal_subnet_prefix     = "10.0.3.0/26"
    route_server_subnet_prefix = "10.0.4.0/27"
    bastion_subnet_prefix      = "10.0.5.0/26"
    enable_bastion             = false
    tags                       = {}
  }

  assert {
    condition     = length(azurerm_subnet.bastion) == 0
    error_message = "enable_bastion = false must plan no AzureBastionSubnet."
  }

  assert {
    condition     = length(azurerm_public_ip.bastion) == 0
    error_message = "enable_bastion = false must plan no Bastion public IP."
  }

  assert {
    condition     = length(azurerm_bastion_host.this) == 0
    error_message = "enable_bastion = false must plan no Bastion host."
  }

  assert {
    condition     = output.bastion_name == null
    error_message = "bastion_name must be null when Bastion is not deployed."
  }
}

# With Bastion on, every property the CE Site Console path depends on is asserted:
# the literal subnet name, the Standard SKU, and the two feature flags without which
# `az network bastion tunnel --target-ip-address ... --resource-port 65500` cannot work.
run "bastion_enabled_shape" {
  command = plan

  module {
    source = "./modules/azure-hub"
  }

  variables {
    resource_group_name        = "rg-mcn-ce-ha-testdeployer"
    location                   = "eastus"
    hub_cidr                   = "10.0.0.0/16"
    mgmt_subnet_prefix         = "10.0.1.0/26"
    external_subnet_prefix     = "10.0.2.0/26"
    internal_subnet_prefix     = "10.0.3.0/26"
    route_server_subnet_prefix = "10.0.4.0/27"
    bastion_subnet_prefix      = "10.0.5.0/26"
    enable_bastion             = true
    bastion_name               = "mcn-ce-ha-bastion"
    tags                       = {}
  }

  assert {
    condition     = azurerm_subnet.bastion[0].name == "AzureBastionSubnet"
    error_message = "Bastion subnet must be named literally AzureBastionSubnet."
  }

  assert {
    condition     = azurerm_subnet.bastion[0].address_prefixes[0] == "10.0.5.0/26"
    error_message = "AzureBastionSubnet must take var.bastion_subnet_prefix."
  }

  assert {
    condition     = azurerm_bastion_host.this[0].sku == "Standard"
    error_message = "Bastion must use the Standard SKU — Basic supports neither tunneling nor IP-based connection."
  }

  assert {
    condition     = azurerm_bastion_host.this[0].tunneling_enabled
    error_message = "tunneling_enabled must be true or `az network bastion tunnel` cannot forward TCP 65500."
  }

  # Not the 65500 path (Azure refuses custom ports over IP-based connection — see
  # modules/azure-hub/main.tf), but asserted so the capability is not silently lost:
  # it is what lets an operator target an in-VNet IP directly for portal RDP/SSH.
  assert {
    condition     = azurerm_bastion_host.this[0].ip_connect_enabled
    error_message = "ip_connect_enabled must be true so an in-VNet IP can be targeted directly for portal RDP/SSH."
  }

  assert {
    condition     = azurerm_public_ip.bastion[0].sku == "Standard" && azurerm_public_ip.bastion[0].allocation_method == "Static"
    error_message = "Bastion requires a Standard-SKU static public IP."
  }

  # Subnet/public-IP resource IDs are known-after-apply, so the wiring itself is
  # not assertable at plan time (see the file header). The plan-knowable half —
  # that exactly one ip_configuration exists and the public IP is named after the
  # host — is asserted instead.
  assert {
    condition     = length(azurerm_bastion_host.this[0].ip_configuration) == 1
    error_message = "Bastion host must have exactly one ip_configuration."
  }

  assert {
    condition     = azurerm_public_ip.bastion[0].name == "mcn-ce-ha-bastion-pip"
    error_message = "Bastion public IP must be named <bastion_name>-pip."
  }

  assert {
    condition     = output.bastion_name == "mcn-ce-ha-bastion"
    error_message = "bastion_name output must expose the host name the tunnel command needs."
  }
}
