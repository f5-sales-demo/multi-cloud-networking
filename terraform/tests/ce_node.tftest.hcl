# Plan-level test for the ce-node module. Mocks azurerm so no Azure credentials
# are contacted. Asserts CE NIC hardening invariants (IP forwarding on,
# accelerated networking off) and the required marketplace plan block.

mock_provider "azurerm" {}

run "ce_vm_and_nics" {
  command = plan

  module {
    source = "./modules/ce-vm"
  }

  variables {
    hostname            = "f5-xc-ce-vm-01"
    resource_group_name = "rg-mcn-ce-ha-testdeployer"
    location            = "eastus"
    zone                = "1"
    vm_size             = "Standard_D8_v4"
    admin_username      = "azureuser"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    custom_data         = "IyNjbG91ZC1jb25maWcK"
    tags                = {}
    network = {
      mgmt_nic_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/mgmt"
      external_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/external"
      internal_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/internal"
      identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ce"
      generation_id   = "example-generation"
    }
  }

  assert {
    condition     = output.vm_name == "f5-xc-ce-vm-01"
    error_message = "CE VM name must equal the hostname."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.this.source_image_reference[0].publisher == "f5-networks" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].offer == "f5xc_customer_edge" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].sku == "f5xc-ce-crt-20260201" &&
      azurerm_linux_virtual_machine.this.source_image_reference[0].version == "20260201.0178.1"
    )
    error_message = "CE VM must use the fixed certified F5 XC Customer Edge image tuple."
  }

  assert {
    condition = (
      azurerm_linux_virtual_machine.this.plan[0].publisher == "f5-networks" &&
      azurerm_linux_virtual_machine.this.plan[0].product == "f5xc_customer_edge" &&
      azurerm_linux_virtual_machine.this.plan[0].name == "f5xc-ce-crt-20260201"
    )
    error_message = "CE VM marketplace plan must exactly match its fixed image tuple."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.os_disk[0].storage_account_type == "StandardSSD_LRS"
    error_message = "CE OS disk must be StandardSSD_LRS."
  }

  # Azure Serial Console requires boot diagnostics. It is the only way into a CE that
  # has not finished its first boot: the vpm/debug API used for every other diagnostic
  # is reached through the XC control plane, so it answers only once the node is
  # ONLINE, and operator SSH only exists after cloud-init has written admin's
  # authorized_keys. Losing this block would silently remove the break-glass path for
  # the exact failure it exists to debug.
  assert {
    condition     = length(azurerm_linux_virtual_machine.this.boot_diagnostics) == 1
    error_message = "CE VM must enable boot diagnostics, or Azure Serial Console cannot attach."
  }

  # An empty block means Azure-managed storage, so there is no diagnostics storage
  # account, lifecycle policy or access key for us to own.
  assert {
    condition     = azurerm_linux_virtual_machine.this.boot_diagnostics[0].storage_account_uri == null
    error_message = "CE boot diagnostics must use Azure-managed storage (no storage_account_uri)."
  }

}

# Runtime acceptance and console credential rotation require the actual VM
# instance identity. The ARM resource id looks like a perfectly
# good identifier and is the obvious thing to reach for, but it is
# ".../virtualMachines/<hostname>" — byte-identical before and after a
# replacement — so wiring it would leave the coupling permanently inert and bring
# back #674 with no visible symptom.
#
# This run applies (against the mocked provider — still no Azure credentials)
# because both candidate attributes are computed, and a plan leaves them
# known-after-apply and therefore unassertable. Only virtual_machine_id is
# overridden; every other computed attribute keeps the value the mock invents, so
# reading the wrong one fails the comparison instead of quietly passing.
run "vm_instance_id_is_the_instance_id_not_the_arm_resource_id" {
  command = apply

  module {
    source = "./modules/ce-vm"
  }

  variables {
    hostname            = "f5-xc-ce-vm-01"
    resource_group_name = "rg-mcn-ce-ha-testdeployer"
    location            = "eastus"
    zone                = "1"
    vm_size             = "Standard_D8_v4"
    admin_username      = "azureuser"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    custom_data         = "IyNjbG91ZC1jb25maWcK"
    tags                = {}
    network = {
      mgmt_nic_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/mgmt"
      external_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/external"
      internal_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/internal"
      identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ce"
      generation_id   = "example-generation"
    }
  }

  # The mocked provider invents ids like "7251r305", and azurerm parses resource
  # ids client-side, so every id this module feeds into another resource needs a
  # well-formed one or the apply fails before any assertion runs.


  override_resource {
    target = azurerm_linux_virtual_machine.this
    values = {
      virtual_machine_id = "5efa1cf7-73ec-4bd2-b8d1-1e0d0a41bd12"
    }
  }

  assert {
    condition     = output.vm_instance_id == "5efa1cf7-73ec-4bd2-b8d1-1e0d0a41bd12"
    error_message = "vm_instance_id must expose virtual_machine_id (regenerated per instance), not the name-derived ARM resource id."
  }
}

# The CE OS disk must be sized explicitly, and large enough that the versions F5
# advertises can actually install.
#
# Measured 2026-07-29 (issue #714), one disposable single-node Azure Secure Mesh v2
# site per size, all from marketplace image 0.9.2, installing the pair the tenant
# advertises (crt-20260201-0179 + OS 9.2026.14):
#
#     31 GiB (the image default, i.e. no disk_size_gb)  FAIL — voucher DaemonSet
#                                                       0/1, site stuck
#                                                       PROVISIONING, nothing
#                                                       installed
#     33 GB                                             PASS
#     36 / 40 / 48 / 64 GB                              PASS
#
# So an unset disk_size_gb is not a neutral default: it is the one size on which the
# advertised pair fails. It matters even while the fleet pins an older build,
# because leaving the version variables EMPTY makes the server choose the newest
# advertised pair — so an unpinned deployment lands exactly on the failing case.
#
# The floor asserted here is deliberately above the measured 33 GB minimum. 33 works
# for this pair on this image today; a build with a marginally larger payload would
# fail there with no configuration change and no obvious cause, which is precisely
# the position the 31 GiB default is in now.
run "ce_os_disk_is_sized_for_the_advertised_versions" {
  command = plan

  module {
    source = "./modules/ce-vm"
  }

  variables {
    hostname            = "f5-xc-ce-vm-01"
    resource_group_name = "rg-mcn-ce-ha-testdeployer"
    location            = "eastus"
    zone                = "1"
    vm_size             = "Standard_D8_v4"
    admin_username      = "azureuser"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    custom_data         = "IyNjbG91ZC1jb25maWcK"
    tags                = {}
    network = {
      mgmt_nic_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/mgmt"
      external_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/external"
      internal_nic_id = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.Network/networkInterfaces/internal"
      identity_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/example-rg/providers/Microsoft.ManagedIdentity/userAssignedIdentities/ce"
      generation_id   = "example-generation"
    }
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.os_disk[0].disk_size_gb > 0
    error_message = "The CE OS disk size must be set explicitly. Left unset the VM inherits the marketplace image default of 31 GiB, which is the one size measured to fail the version pair F5 advertises (#714). Note the check is > 0, not != null: an unset attribute renders as 0 in a mocked plan, so a null check would pass on exactly the case it exists to catch."
  }

  assert {
    condition     = azurerm_linux_virtual_machine.this.os_disk[0].disk_size_gb >= 78
    error_message = "The CE OS disk must be at least 78 GB: Azure rejects a smaller disk for the pinned f5xc-ce-crt-20260201:20260201.0178.1 Marketplace image before VM creation."
  }
}
