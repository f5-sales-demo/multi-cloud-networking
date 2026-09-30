# Live Azure registration maps eth0 to management SLO, eth1 to inside SLI and
# eth2 to external SLO. Preserve all three devices from first boot, then bind
# observed Azure NIC MACs with a refresh-enabled plan after VM attachment.
variable "azure_site_configuration_phase" {
  description = "Azure site bootstrap declares all devices; configured binds observed NIC MACs and permits approval."
  type        = string
  default     = "configured"
  validation {
    condition     = contains(["bootstrap", "configured"], var.azure_site_configuration_phase)
    error_message = "azure_site_configuration_phase must be bootstrap or configured."
  }
}

locals {
  azure_interface_contract = {
    version = "2.0.0"
    devices = { slo = "eth0", sli = "eth1", external = "eth2" }
  }
  azure_observed_macs = concat(
    [for _, node in module.ce_node : [node.mgmt_nic_mac, node.inside_nic_mac, node.external_nic_mac]],
    [for _, node in module.ce_node_ca : [node.mgmt_nic_mac, node.inside_nic_mac, node.external_nic_mac]]
  )
}
