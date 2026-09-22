# General variables. Domain-specific inputs live in variables_azure.tf,
# variables_xc.tf and variables_ce.tf.

variable "component" {
  description = "Component name used in tags."
  type        = string
  default     = "mcn-ce-ha"
}

variable "environment" {
  description = "Environment label used in tags."
  type        = string
  default     = "lab"
}

variable "deployer" {
  description = "Override for the deployer identifier used in tags (auto-resolved from Azure AD when empty)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged with the standard tags (component/environment/deployer/managed_by)."
  type        = map(string)
  default     = {}
}

variable "enable_kvm" {
  description = "Enable the local KVM/libvirt SMSv2 site. Set false for a KVM-only destroy or when the tenant-owned KVM image prerequisite is unavailable; no KVM image lookup occurs while disabled."
  type        = bool
  default     = false
}

variable "kvm_software_version" {
  description = "F5XC software installed during the KVM CE's first boot. This is pinned explicitly so a fresh install does not consume an unqualified tenant default release."
  type        = string
  default     = "crt-20251002-0028"
  nullable    = false

  validation {
    condition     = can(regex("^crt-[0-9]{8}-[0-9]{4}$", var.kvm_software_version))
    error_message = "kvm_software_version must be an explicit F5XC software build such as crt-20251002-0028."
  }
}

variable "aws_origin_dns_name" {
  description = "DNS name of the public HTTP origin for the AWS SMSv2 load balancer."
  type        = string
  default     = "httpbin.org"
  nullable    = false

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.aws_origin_dns_name))
    error_message = "aws_origin_dns_name must be a fully-qualified lowercase DNS name."
  }
}
