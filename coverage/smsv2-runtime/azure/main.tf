terraform {
  backend "local" {}
  required_version = "= 1.16.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "= 4.81.0"
    }
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 15.9.0"
    }
  }
}
provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}
provider "xcsh" { api_url = "https://${var.xc_tenant}.console.ves.volterra.io" }
variable "subscription_id" { type = string }
variable "xc_tenant" { type = string }
variable "task_id" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.task_id))
    error_message = "Use a unique non-personal 3-20 character task ID."
  }
}
variable "location" { type = string }
variable "operator_cidr" { type = string }
variable "ssh_public_key" { type = string }
variable "phase" {
  type    = string
  default = "bootstrap"
  validation {
    condition     = contains(["bootstrap", "retired", "configured"], var.phase)
    error_message = "Use bootstrap, retired or configured."
  }
}
variable "device_mapping_file" {
  type    = string
  default = null
}
variable "software_version" { type = string }
variable "os_version" { type = string }
variable "ce_image_version" { type = string }
variable "ce_image_sku" { type = string }
variable "origin_image_version" { type = string }
variable "firewall_policies" {
  type    = list(object({ name = string, namespace = string }))
  default = []
}
variable "proxy_policies" {
  type    = list(object({ name = string, namespace = string }))
  default = []
}
locals {
  active    = var.phase != "retired"
  site_name = "${var.task_id}-${var.phase}"
  tags      = { task-id = var.task_id, component = "smsv2-qualification" }
}
resource "azurerm_resource_group" "fixture" {
  name     = var.task_id
  location = var.location
  tags     = local.tags
}
resource "azurerm_virtual_network" "fixture" {
  name                = var.task_id
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  address_space       = ["10.246.0.0/16"]
  tags                = local.tags
}
resource "azurerm_subnet" "slo" {
  name                 = "slo"
  resource_group_name  = azurerm_resource_group.fixture.name
  virtual_network_name = azurerm_virtual_network.fixture.name
  address_prefixes     = ["10.246.1.0/24"]
}
resource "azurerm_subnet" "sli" {
  name                 = "sli"
  resource_group_name  = azurerm_resource_group.fixture.name
  virtual_network_name = azurerm_virtual_network.fixture.name
  address_prefixes     = ["10.246.2.0/24"]
}
resource "azurerm_subnet" "client" {
  name                            = "client"
  resource_group_name             = azurerm_resource_group.fixture.name
  virtual_network_name            = azurerm_virtual_network.fixture.name
  address_prefixes                = ["10.246.3.0/24"]
  default_outbound_access_enabled = false
}
resource "azurerm_public_ip" "ce" {
  name                = "${var.task_id}-ce"
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}
resource "azurerm_public_ip" "origin" {
  name                = "${var.task_id}-origin"
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags
}
resource "azurerm_network_security_group" "fixture" {
  name                = var.task_id
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  security_rule {
    name                       = "operator-ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.operator_cidr
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "origin-from-ce"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = "${azurerm_public_ip.ce.ip_address}/32"
    destination_address_prefix = "*"
  }
  security_rule {
    name                       = "client-transit"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["80", "443"]
    source_address_prefix      = azurerm_subnet.client.address_prefixes[0]
    destination_address_prefix = azurerm_public_ip.origin.ip_address
  }

  tags = local.tags
}
resource "azurerm_network_interface" "slo" {
  name                  = "${var.task_id}-slo"
  location              = var.location
  resource_group_name   = azurerm_resource_group.fixture.name
  ip_forwarding_enabled = true
  ip_configuration {
    name                          = "slo"
    subnet_id                     = azurerm_subnet.slo.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.ce.id
  }
  tags = local.tags
}
resource "azurerm_network_interface" "sli" {
  name                  = "${var.task_id}-sli"
  location              = var.location
  resource_group_name   = azurerm_resource_group.fixture.name
  ip_forwarding_enabled = true
  ip_configuration {
    name                          = "sli"
    subnet_id                     = azurerm_subnet.sli.id
    private_ip_address_allocation = "Dynamic"
  }
  tags = local.tags
}
resource "azurerm_network_interface" "origin" {
  name                = "${var.task_id}-origin"
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  ip_configuration {
    name                          = "origin"
    subnet_id                     = azurerm_subnet.slo.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.origin.id
  }
  tags = local.tags
}
resource "azurerm_network_interface" "client" {
  name                = "${var.task_id}-client"
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  ip_configuration {
    name                          = "client"
    subnet_id                     = azurerm_subnet.client.id
    private_ip_address_allocation = "Dynamic"
  }
  tags = local.tags
}
resource "azurerm_network_interface_security_group_association" "fixture" {
  for_each                  = { slo = azurerm_network_interface.slo.id, sli = azurerm_network_interface.sli.id, origin = azurerm_network_interface.origin.id, client = azurerm_network_interface.client.id }
  network_interface_id      = each.value
  network_security_group_id = azurerm_network_security_group.fixture.id
}
resource "azurerm_route_table" "client" {
  name                          = "${var.task_id}-client"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.fixture.name
  bgp_route_propagation_enabled = false
  route {
    name                   = "default-via-ce"
    address_prefix         = "0.0.0.0/0"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_network_interface.sli.private_ip_address
  }
  tags = local.tags
}
resource "azurerm_subnet_route_table_association" "client" {
  subnet_id      = azurerm_subnet.client.id
  route_table_id = azurerm_route_table.client.id
}
resource "azurerm_user_assigned_identity" "ce" {
  name                = "${var.task_id}-ce"
  location            = var.location
  resource_group_name = azurerm_resource_group.fixture.name
  tags                = local.tags
}
resource "xcsh_securemesh_site_v2" "ce" {
  count     = local.active ? 1 : 0
  name      = local.site_name
  namespace = "system"
  labels    = local.tags
  azure {
    not_managed {
      dynamic "node_list" {
        for_each = var.phase == "configured" ? [1] : []
        content {
          hostname = local.site_name
          type     = "Control"
          interface_list {
            name = "slo"
            ethernet_interface {
              device = local.devices.slo
              mac    = replace(lower(azurerm_network_interface.slo.mac_address), "-", ":")
            }
            network_option { site_local_network = {} }
            dhcp_client = {}
          }
          interface_list {
            name = "sli"
            ethernet_interface {
              device = local.devices.sli
              mac    = replace(lower(azurerm_network_interface.sli.mac_address), "-", ":")
            }
            network_option { site_local_inside_network = {} }
            dhcp_client = {}
          }
        }
      }
    }
  }
  disable_ha         = {}
  block_all_services = {}
  no_network_policy  = length(var.firewall_policies) == 0 ? {} : null
  no_forward_proxy   = length(var.proxy_policies) == 0 ? {} : null
  dynamic "active_enhanced_firewall_policies" {
    for_each = length(var.firewall_policies) > 0 ? [var.firewall_policies] : []
    content {
      dynamic "enhanced_firewall_policies" {
        for_each = active_enhanced_firewall_policies.value
        content {
          name      = enhanced_firewall_policies.value.name
          namespace = enhanced_firewall_policies.value.namespace
        }
      }
    }
  }
  dynamic "active_forward_proxy_policies" {
    for_each = length(var.proxy_policies) > 0 ? [var.proxy_policies] : []
    content {
      dynamic "forward_proxy_policies" {
        for_each = active_forward_proxy_policies.value
        content {
          name      = forward_proxy_policies.value.name
          namespace = forward_proxy_policies.value.namespace
        }
      }
    }
  }
  f5_proxy                = {}
  no_proxy_bypass         = {}
  logs_streaming_disabled = {}
  no_s2s_connectivity_sli = {}
  no_s2s_connectivity_slo = {}
  local_vrf {
    default_config     = {}
    default_sli_config = {}
  }
  software_settings {
    os { operating_system_version = var.os_version }
    sw { volterra_software_version = var.software_version }
  }
  lifecycle {
    precondition {
      condition     = var.phase != "configured" || local.mapping_valid
      error_message = "Configured creation requires distinct devices observed by MAC from this fixture's bootstrap registration."
    }
  }
}
resource "xcsh_token" "ce" {
  count     = local.active ? 1 : 0
  name      = "${local.site_name}-reg"
  namespace = "system"
  labels    = local.tags
  type      = 1
  site_name = xcsh_securemesh_site_v2.ce[0].name
}
data "xcsh_site_cloud_init" "ce" {
  count                     = local.active ? 1 : 0
  site_name                 = xcsh_securemesh_site_v2.ce[0].name
  provider_ref              = "azure"
  enable_management_network = false
}
resource "azurerm_linux_virtual_machine" "ce" {
  count                           = local.active ? 1 : 0
  name                            = local.site_name
  computer_name                   = local.site_name
  location                        = var.location
  resource_group_name             = azurerm_resource_group.fixture.name
  size                            = "Standard_D8s_v5"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }
  network_interface_ids = [azurerm_network_interface.slo.id, azurerm_network_interface.sli.id]
  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.ce.id]
  }
  os_disk {
    name                 = "${local.site_name}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
    disk_size_gb         = 100
  }
  source_image_reference {
    publisher = "f5-networks"
    offer     = "f5xc_customer_edge"
    sku       = var.ce_image_sku
    version   = var.ce_image_version
  }
  plan {
    publisher = "f5-networks"
    product   = "f5xc_customer_edge"
    name      = var.ce_image_sku
  }
  custom_data = base64encode(templatefile("${path.module}/ce-cloud-init.tpl", {
    site_cloud_init = replace(data.xcsh_site_cloud_init.ce[0].cloud_init_config, "{{ .token }}", xcsh_token.ce[0].uid)
    ssh_public_key  = var.ssh_public_key
  }))
  boot_diagnostics {}
  tags = local.tags
  lifecycle { ignore_changes = [custom_data] }
}
resource "azurerm_linux_virtual_machine" "traffic" {
  for_each                        = { origin = azurerm_network_interface.origin.id, client = azurerm_network_interface.client.id }
  name                            = "${var.task_id}-${each.key}"
  location                        = var.location
  resource_group_name             = azurerm_resource_group.fixture.name
  size                            = "Standard_B1s"
  admin_username                  = "azureuser"
  disable_password_authentication = true
  admin_ssh_key {
    username   = "azureuser"
    public_key = var.ssh_public_key
  }
  network_interface_ids = [each.value]
  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }
  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = var.origin_image_version
  }
  custom_data = each.key == "origin" ? base64encode("#cloud-config\nruncmd:\n  - [bash, -c, ${jsonencode(file("${path.module}/origin.sh"))}]\n") : null
  tags        = local.tags
}
data "xcsh_site_registration" "ce" {
  count     = local.active ? 1 : 0
  site_name = local.site_name
  hostname  = local.site_name
  namespace = "system"
}
data "xcsh_site_registrations_by_site" "hardware" {
  count     = local.active ? 1 : 0
  site_name = local.site_name
  namespace = "system"
}
resource "xcsh_registration_approval" "ce" {
  count        = local.active && try(data.xcsh_site_registration.ce[0].found, false) ? 1 : 0
  name         = data.xcsh_site_registration.ce[0].name
  namespace    = "system"
  cluster_size = 1
  state        = "APPROVED"
}
output "fixture" {
  value = {
    task_id             = var.task_id
    phase               = var.phase
    site_name           = local.active ? local.site_name : null
    ce_vm_id            = local.active ? azurerm_linux_virtual_machine.ce[0].id : null
    client_vm_id        = azurerm_linux_virtual_machine.traffic["client"].id
    origin_vm_id        = azurerm_linux_virtual_machine.traffic["origin"].id
    ce_vm_name          = local.active ? azurerm_linux_virtual_machine.ce[0].name : null
    resource_group_name = azurerm_resource_group.fixture.name
    ce_public_ip        = azurerm_public_ip.ce.ip_address
    ce_sli_ip           = azurerm_network_interface.sli.private_ip_address
    client_private_ip   = azurerm_network_interface.client.private_ip_address
    origin_public_ip    = azurerm_public_ip.origin.ip_address
    slo_mac             = replace(lower(azurerm_network_interface.slo.mac_address), "-", ":")
    sli_mac             = replace(lower(azurerm_network_interface.sli.mac_address), "-", ":")
    slo_nic             = azurerm_network_interface.slo.id
    sli_nic             = azurerm_network_interface.sli.id
    client_nic          = azurerm_network_interface.client.id
    client_route_table  = azurerm_route_table.client.id
  }
}
output "hardware" {
  sensitive = true
  value     = local.active ? data.xcsh_site_registrations_by_site.hardware[0].items : null
}
