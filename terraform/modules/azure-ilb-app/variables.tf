variable "name" { type = string }
variable "namespace" { type = string }
variable "domain" { type = string }
variable "vip" { type = string }
variable "origin_pool_name" { type = string }
variable "labels" {
  type = map(string)
  validation {
    condition     = try(length(var.labels["mcn-topology"]) > 0, false)
    error_message = "The inside virtual site requires the exact regional mcn-topology label."
  }
}
