variable "enable_kvm" {
  type = bool
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
