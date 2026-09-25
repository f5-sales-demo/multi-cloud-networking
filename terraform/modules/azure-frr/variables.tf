variable "name" { type = string }
variable "location" { type = string }
variable "resource_group_name" { type = string }
variable "mgmt_subnet_id" { type = string }
variable "mgmt_subnet_prefix" { type = string }
variable "route_server_id" { type = string }
variable "rs_peer_ips" { type = list(string) }
variable "ce_ips" { type = list(string) }
variable "vip" { type = string }
variable "ce_asn" { type = number }
variable "rs_asn" { type = number }
variable "frr_asn" {
  type    = number
  default = 65020
}
variable "vm_size" {
  type    = string
  default = "Standard_B2s"
}
variable "admin_username" { type = string }
variable "ssh_public_key" { type = string }
variable "tags" { type = map(string) }
