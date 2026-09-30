variable "hostname" { type = string }
variable "resource_group_name" { type = string }
variable "location" { type = string }
variable "zone" { type = string }
variable "vm_size" { type = string }
variable "admin_username" { type = string }
variable "ssh_public_key" { type = string }
variable "custom_data" { type = string }
variable "os_disk_size_gb" {
  type    = number
  default = 80
}
variable "tags" { type = map(string) }
variable "network" {
  type = object({
    mgmt_nic_id     = string
    external_nic_id = string
    internal_nic_id = string
    identity_id     = string
    generation_id   = string
  })
}
