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

output "identity_id" {
  description = "User-assigned managed identity resource ID."
  value       = azurerm_user_assigned_identity.this.id
}

output "internal_nic_id" {
  description = "Resource ID of the CE inside NIC used by the ILB application and console pools."
  value       = azurerm_network_interface.internal.id
}

output "generation_id" {
  description = "Pre-boot generation shared by the managed site and CE VM."
  value       = random_uuid.generation.result
}

output "network" {
  value = {
    mgmt_nic_id     = azurerm_network_interface.mgmt.id
    external_nic_id = azurerm_network_interface.external.id
    internal_nic_id = azurerm_network_interface.internal.id
    identity_id     = azurerm_user_assigned_identity.this.id
    generation_id   = random_uuid.generation.result
  }
}
