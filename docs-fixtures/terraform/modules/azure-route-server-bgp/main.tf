# The Azure side of the eBGP session: a Route Server BGP connection to a CE's
# eth0/SLO private IP. Peer ASN = the CE ASN (64512). The CE originates the LB
# VIP /32; equal-cost advertisements from multiple CEs program ECMP into the VNet.

variable "name" {
  description = "BGP connection name (e.g. eastus01-bgp)."
  type        = string
}

variable "route_server_id" {
  description = "Azure Route Server resource ID."
  type        = string
}

variable "peer_asn" {
  description = "Peer (CE) ASN."
  type        = number
  default     = 64512
}

variable "peer_ip" {
  description = "Peer (CE) eth0/SLO private IP."
  type        = string
}

resource "azurerm_route_server_bgp_connection" "this" {
  name            = var.name
  route_server_id = var.route_server_id
  peer_asn        = var.peer_asn
  peer_ip         = var.peer_ip
}

output "connection_id" {
  description = "Route Server BGP connection resource ID."
  value       = azurerm_route_server_bgp_connection.this.id
}

output "connection_name" {
  description = "Route Server BGP connection name."
  value       = azurerm_route_server_bgp_connection.this.name
}
