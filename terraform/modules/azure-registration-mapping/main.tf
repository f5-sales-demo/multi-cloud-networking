locals {
  macs = { for role, mac in var.macs : role => lower(replace(coalesce(mac, "unbound"), "-", ":")) }
  nodes = [for record in var.records : record
    if record.site == var.site && record.hostname == var.hostname && record.provider == "AZURE" &&
    !contains(["RETIRED", "FAILED", "FAILED_INACTIVE", "DONE"], record.state) &&
    alltrue([for mac in values(local.macs) : contains([for nic in record.network : lower(replace(nic.mac, "-", ":"))], mac)])
  ]
  network = var.runtime_required ? coalesce(var.runtime_network, []) : try(one(local.nodes).network, [])
  matches = { for role, mac in local.macs : role => [for nic in local.network : nic.device if lower(replace(nic.mac, "-", ":")) == mac] }
  valid = (length(local.nodes) == 1 && length(distinct(values(local.macs))) == 3 &&
    alltrue([for matches in values(local.matches) : length(matches) == 1]) &&
    try(one(local.matches.slo), "") == "eth0" &&
  toset([for matches in values(local.matches) : try(one(matches), "")]) == toset(["eth0", "eth1", "eth2"]))
  devices = { for role, matches in local.matches : role => try(one(matches), "") }
}
output "valid" { value = local.valid }
output "devices" { value = local.devices }
