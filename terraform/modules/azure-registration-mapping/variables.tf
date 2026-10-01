variable "site" { type = string }
variable "hostname" { type = string }
variable "macs" { type = map(string) }
variable "records" {
  type = list(object({
    site     = string
    hostname = string
    provider = string
    state    = string
    network  = list(object({ device = string, mac = string }))
  }))
}

variable "runtime_required" {
  description = "Admitted nodes require fresh runtime device facts instead of the registration snapshot."
  type        = bool
  default     = false
}
variable "runtime_network" {
  description = "Current physical devices observed in exact owned node runtime health."
  type        = list(object({ device = string, mac = string }))
  default     = null
}
