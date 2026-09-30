# The caller depends on the managed XC site, so guest boot follows site creation.
resource "terraform_data" "generation" {
  input = var.network.generation_id
}

resource "azurerm_linux_virtual_machine" "this" {
  name                = var.hostname
  computer_name       = var.hostname
  resource_group_name = var.resource_group_name
  location            = var.location
  size                = var.vm_size
  zone                = var.zone

  admin_username                  = var.admin_username
  disable_password_authentication = true

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  # eth0 first = mgmt/SLO NIC (BGP local + MAC-bound to the XC site interface).
  network_interface_ids = [
    var.network.mgmt_nic_id,
    var.network.external_nic_id,
    var.network.internal_nic_id,
  ]

  identity {
    type         = "UserAssigned"
    identity_ids = [var.network.identity_id]
  }

  os_disk {
    name                 = "${var.hostname}-osdisk"
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"

    # Explicit, because the image default is the one size measured to fail the
    # advertised version pair (#714). See variables.tf for the measurements.
    disk_size_gb = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "f5-networks"
    offer     = "f5xc_customer_edge"
    sku       = "f5xc-ce-crt-20260201"
    version   = "20260201.0178.1"
  }

  # Marketplace plan is REQUIRED for this exact certified Customer Edge image.
  plan {
    name      = "f5xc-ce-crt-20260201"
    product   = "f5xc_customer_edge"
    publisher = "f5-networks"
  }

  custom_data = var.custom_data

  # Required for Azure Serial Console, which is the only way into a CE that has not
  # finished its first boot: the vpm/debug API used for every other diagnostic is
  # reached through the XC control plane, so it answers only once the node is ONLINE,
  # and operator SSH depends on cloud-init having written admin's authorized_keys and
  # on the SLI interface being up. Empty block = Azure-managed storage, so there is
  # no diagnostics storage account or access key to own.
  boot_diagnostics {}

  tags = var.tags

  depends_on = [terraform_data.generation]
  lifecycle {
    replace_triggered_by = [terraform_data.generation]
  }
}
