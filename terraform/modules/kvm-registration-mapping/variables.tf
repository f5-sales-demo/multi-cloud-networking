variable "enforce" {
  description = "Fail the plan unless the observed KVM registrations map one-to-one to every Terraform-owned CE MAC."
  type        = bool
}

variable "registration_records" {
  description = "Sanitized KVM registration observations derived from the XC inventory data source."
  type = list(object({
    hostname = string
    provider = string
    mac      = string
  }))
}

variable "ce_nodes" {
  description = "Terraform-owned KVM CE network identities."
  type = map(object({
    address = string
    mac     = string
  }))
}
