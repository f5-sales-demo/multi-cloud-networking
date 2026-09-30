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
