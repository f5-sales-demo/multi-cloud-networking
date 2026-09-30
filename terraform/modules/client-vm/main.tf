# Simple Ubuntu test client in snet-hub-internal. Used to generate HTTP traffic
# to the VIP and to read the VNet effective route table (ECMP proof).

resource "azurerm_public_ip" "this" {
  name                = "${var.name}PublicIP"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "this" {
  #checkov:skip=CKV_AZURE_10:Lab NSG - SSH open for demo access
  #checkov:skip=CKV_AZURE_160:Lab NSG - HTTP port 80 required for traffic
  #checkov:skip=CKV_AZURE_220:Lab NSG - SSH open for demo access
  name                = "${var.name}NSG"
  resource_group_name = var.resource_group_name
  location            = var.location

  dynamic "security_rule" {
    for_each = var.allow_ssh ? [1] : []
    content {
      name                       = "SSH"
      priority                   = 1001
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "22"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }

  dynamic "security_rule" {
    for_each = var.serve_http ? [1] : []
    content {
      name                       = "HTTP"
      priority                   = 1002
      direction                  = "Inbound"
      access                     = "Allow"
      protocol                   = "Tcp"
      source_port_range          = "*"
      destination_port_range     = "80"
      source_address_prefixes    = var.http_source_cidrs
      destination_address_prefix = "*"
    }
  }

  dynamic "security_rule" {
    for_each = var.restrict_ingress ? [1] : []
    content {
      name                       = "deny-other-origin-ingress"
      priority                   = 4096
      direction                  = "Inbound"
      access                     = "Deny"
      protocol                   = "*"
      source_port_range          = "*"
      destination_port_range     = "*"
      source_address_prefix      = "*"
      destination_address_prefix = "*"
    }
  }
  lifecycle {
    precondition {
      condition     = !var.serve_http || length(var.http_source_cidrs) > 0
      error_message = "HTTP origins require a nonempty explicit source ACL."
    }
  }

  tags = var.tags
}

resource "azurerm_network_interface" "this" {
  #checkov:skip=CKV_AZURE_119:Lab NIC - public IP required for demo access
  name                = "${var.name}VMNic"
  resource_group_name = var.resource_group_name
  location            = var.location

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.subnet_id
    private_ip_address_allocation = var.private_ip == "" ? "Dynamic" : "Static"
    private_ip_address            = var.private_ip == "" ? null : var.private_ip
    public_ip_address_id          = azurerm_public_ip.this.id
  }

  tags = var.tags
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

resource "azurerm_linux_virtual_machine" "this" {
  #checkov:skip=CKV_AZURE_50:Lab VM - no extensions required
  #checkov:skip=CKV_AZURE_93:Lab VM - platform-managed encryption sufficient
  name                = var.name
  computer_name       = var.name
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  network_interface_ids = [azurerm_network_interface.this.id]

  # Install the declared ingress ACL before cloud-init can start an origin.
  depends_on = [azurerm_network_interface_security_group_association.this]

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "0001-com-ubuntu-server-jammy"
    sku       = "22_04-lts-gen2"
    version   = "latest"
  }

  custom_data = var.custom_data != "" ? var.custom_data : null

  tags = var.tags
}

output "public_ip" {
  description = "Public IP of the test client."
  value       = azurerm_public_ip.this.ip_address
}

output "private_ip" {
  description = "Private IP of the test client."
  value       = azurerm_network_interface.this.private_ip_address
}

output "vm_name" {
  description = "Test client VM name."
  value       = azurerm_linux_virtual_machine.this.name
}

output "nic_name" {
  description = "Test client NIC name (read effective routes from this NIC)."
  value       = azurerm_network_interface.this.name
}
