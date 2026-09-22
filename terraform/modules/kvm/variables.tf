variable "enable_kvm" {
  type = bool
}

variable "software_version" {
  description = "Explicit F5XC software build installed during the KVM CE's first boot."
  type        = string
  default     = "crt-20251002-0028"
  nullable    = false

  validation {
    condition     = can(regex("^crt-[0-9]{8}-[0-9]{4}$", var.software_version))
    error_message = "software_version must be an explicit F5XC software build such as crt-20251002-0028."
  }
}

variable "expected_xc_tenant" {
  type = string
}

variable "site_name" {
  type = string
}

variable "labels" {
  type = map(string)
}

variable "acceptance_phase" {
  type    = string
  default = "bootstrap"
}
