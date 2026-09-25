output "mgmt_nic_id" {
  description = "Resource ID of the eth0/SLO (mgmt) NIC."
  value       = azurerm_network_interface.mgmt.id
}

output "mgmt_nic_mac" {
  description = "MAC address of the eth0/SLO (mgmt) NIC. Wired into the XC site interface binding so a NIC recreate updates the site."
  value       = azurerm_network_interface.mgmt.mac_address
}

output "mgmt_private_ip" {
  description = "Private IP of the eth0/SLO (mgmt) NIC — the BGP local address and the Route Server BGP connection peer_ip."
  value       = azurerm_network_interface.mgmt.private_ip_address
}

output "sli_private_ip" {
  description = "Private IP of the internal/SLI NIC — the only one of the CE's three private addresses that answers, and where the Site Console web UI (TCP 65500) is served. Reach it from a workstation with `az network bastion tunnel --target-resource-id <this CE's vm_id> --resource-port 65500`; the mgmt/SLO and external addresses serve nothing."
  value       = azurerm_network_interface.internal.private_ip_address
}

output "vm_name" {
  description = "CE VM name."
  value       = azurerm_linux_virtual_machine.this.name
}

output "vm_id" {
  description = "CE VM ARM resource ID. Addresses the VM (this is what `az network bastion tunnel --target-resource-id` wants) — it is NOT a per-instance identity: see vm_instance_id."
  value       = azurerm_linux_virtual_machine.this.id
}

# The two ids above and below are easy to confuse and are not interchangeable.
# vm_id is the ARM resource id, ".../virtualMachines/<hostname>" — derived from
# the VM name and therefore byte-identical before and after a replacement, which
# makes it the right handle for ADDRESSING the VM (Bastion tunnels) and useless
# as a "this node was rebuilt" signal. This one is regenerated for every new
# instance, and it is the same value the CE reports to F5 XC as the
# registration's infra.instance_id — so it is the identity that binds an XC site
# object to a specific node. modules/xc-site keys the site's replace_triggered_by
# on it (see issue #674).
output "vm_instance_id" {
  description = "128-bit unique id of the CE VM INSTANCE (regenerated on replacement; equals the XC registration's infra.instance_id). Not the ARM resource id, which is name-derived and survives a replacement."
  value       = azurerm_linux_virtual_machine.this.virtual_machine_id
}

output "identity_id" {
  description = "User-assigned managed identity resource ID."
  value       = azurerm_user_assigned_identity.this.id
}

output "internal_nic_id" {
  description = "Resource ID of the CE inside NIC used by the ILB application and console pools."
  value       = azurerm_network_interface.internal.id
}
