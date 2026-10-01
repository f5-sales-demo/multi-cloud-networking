locals {
  routers = {
    "20" = { ip = cidrhost(var.mgmt_subnet_prefix, 20), zone = "1" }
    "21" = { ip = cidrhost(var.mgmt_subnet_prefix, 21), zone = "2" }
  }
}

resource "azurerm_public_ip" "frr" {
  for_each            = local.routers
  name                = "${var.name}-frr-${each.key}-pip"
  location            = var.location
  resource_group_name = var.resource_group_name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "frr" {
  name                = "${var.name}-frr-nsg"
  location            = var.location
  resource_group_name = var.resource_group_name

  security_rule {
    name                       = "bgp-from-vnet"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "179"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "http-to-demo-vip"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "VirtualNetwork"
    destination_address_prefix = var.vip
  }

  security_rule {
    name                       = "deny-other-inbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
  tags = var.tags
}

resource "azurerm_network_interface" "frr" {
  for_each                       = local.routers
  name                           = "${var.name}-frr-${each.key}-nic"
  location                       = var.location
  resource_group_name            = var.resource_group_name
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.mgmt_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.ip
    public_ip_address_id          = azurerm_public_ip.frr[each.key].id
  }
  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "frr" {
  for_each                  = local.routers
  network_interface_id      = azurerm_network_interface.frr[each.key].id
  network_security_group_id = azurerm_network_security_group.frr.id
}

resource "azurerm_linux_virtual_machine" "frr" {
  for_each                        = local.routers
  name                            = "${var.name}-frr-${each.key}"
  computer_name                   = "frr-${each.key}"
  location                        = var.location
  resource_group_name             = var.resource_group_name
  size                            = var.vm_size
  zone                            = each.value.zone
  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.frr[each.key].id]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
    router_ip              = each.value.ip
    ce_ips                 = var.ce_ips
    rs_peer_ips            = var.rs_peer_ips
    ce_asn                 = var.ce_asn
    bootstrap_script       = file("${path.module}/bootstrap.sh")
    vip_translation_script = file("${path.module}/vip_translation.py")
    frr_asn                = var.frr_asn
    rs_asn                 = var.rs_asn
    vip                    = var.vip
  }))
  tags = var.tags

  depends_on = [azurerm_network_interface_security_group_association.frr]
}

# The Route Server CLI and live qualification use Network API 2022-01-01.
# Separate resources order the peers and give each operation its own deadline.
resource "azapi_resource" "route_server_primary" {
  type      = "Microsoft.Network/virtualHubs/bgpConnections@2022-01-01"
  name      = "${var.name}-frr-20-bgp"
  parent_id = var.route_server_id
  body = {
    properties = {
      peerAsn = var.frr_asn
      peerIp  = local.routers["20"].ip
    }
  }
  response_export_values = ["properties.provisioningState"]
  locks                  = [var.route_server_id]
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
  depends_on = [azurerm_linux_virtual_machine.frr]
}

resource "azapi_resource" "route_server_secondary" {
  type      = "Microsoft.Network/virtualHubs/bgpConnections@2022-01-01"
  name      = "${var.name}-frr-21-bgp"
  parent_id = var.route_server_id
  body = {
    properties = {
      peerAsn = var.frr_asn
      peerIp  = local.routers["21"].ip
    }
  }
  response_export_values = ["properties.provisioningState"]
  locks                  = [var.route_server_id]
  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
  depends_on = [azapi_resource.route_server_primary]
}

output "peer_ips" {
  value = [for key in sort(keys(local.routers)) : local.routers[key].ip]
}

output "vm_names" {
  value = [for key in sort(keys(local.routers)) : azurerm_linux_virtual_machine.frr[key].name]
}
