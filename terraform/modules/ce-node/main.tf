# Per-CE Azure resources: managed identity, three NICs (mgmt/external/internal,
# all with IP forwarding on and accelerated networking OFF), and the volterra-node
# VM. The mgmt NIC is the VM's FIRST NIC = eth0 = the SLO/BGP local address.

resource "azurerm_user_assigned_identity" "this" {
  name                = "${var.hostname}-identity"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = var.tags
}

resource "azurerm_public_ip" "mgmt" {
  name                = "${var.hostname}-mgmt-pip"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# eth0 / SLO — mgmt subnet, static private IP (the BGP local address), public IP.
resource "azurerm_network_interface" "mgmt" {
  name                           = "${var.hostname}-mgmt-nic"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.mgmt_subnet_id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.mgmt_private_ip
    public_ip_address_id          = azurerm_public_ip.mgmt.id
  }

  tags = var.tags
}

resource "azurerm_network_interface" "external" {
  name                           = "${var.hostname}-external-nic"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.external_subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags
}

resource "azurerm_network_interface" "internal" {
  name                           = "${var.hostname}-internal-nic"
  resource_group_name            = var.resource_group_name
  location                       = var.location
  ip_forwarding_enabled          = true
  accelerated_networking_enabled = false

  ip_configuration {
    name                          = "ipconfig1"
    subnet_id                     = var.internal_subnet_id
    private_ip_address_allocation = "Dynamic"
  }

  tags = var.tags
}

# A generation exists before guest boot and changes with every boot input or NIC
# replacement. The XC site and VM use the same generation for replacement.
resource "random_uuid" "generation" {
  keepers = {
    hostname     = var.hostname
    custom_data  = sha256(var.custom_data)
    image        = "f5xc-ce-crt-20260201/20260201.0178.1"
    vm_size      = var.vm_size
    location     = var.location
    zone         = var.zone
    admin_user   = var.admin_username
    ssh_key      = sha256(var.ssh_public_key)
    disk_size    = tostring(var.os_disk_size_gb)
    mgmt_nic     = azurerm_network_interface.mgmt.id
    external_nic = azurerm_network_interface.external.id
    internal_nic = azurerm_network_interface.internal.id
  }
}
