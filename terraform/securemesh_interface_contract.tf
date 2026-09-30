# Azure always uses eth0 for management SLO; secondary device order varies.
# Resolve inside/external identities by the owned NIC MACs in live registration. Preserve all three devices from first boot, then bind
# observed Azure NIC MACs with a refresh-enabled plan after VM attachment.
variable "azure_site_configuration_phase" {
  description = "Azure site bootstrap declares all devices; configured binds observed NIC MACs and permits approval."
  type        = string
  default     = "bootstrap"
  validation {
    condition     = contains(["bootstrap", "configured"], var.azure_site_configuration_phase)
    error_message = "azure_site_configuration_phase must be bootstrap or configured."
  }
}

locals {
  azure_interface_contract = {
    version = "2.0.0"
    devices = { slo = "eth0", secondary = "registered-mac" }
  }
}
