locals {
  registration_matches = {
    for key, node in var.ce_nodes : key => [
      for record in var.registration_records : record
      if record.provider == "KVM" && lower(record.mac) == lower(node.mac)
    ]
  }
  mapping_valid = (
    length(var.registration_records) >= length(var.ce_nodes) &&
    alltrue([
      for key in keys(var.ce_nodes) :
      length(local.registration_matches[key]) == 1 &&
      try(length(trimspace(one(local.registration_matches[key]).hostname)), 0) > 0
    ]) &&
    length(distinct([
      for key in keys(var.ce_nodes) :
      try(one(local.registration_matches[key]).hostname, "")
    ])) == length(var.ce_nodes)
  )
  expected_bgp_peers = local.mapping_valid ? {
    for key, node in var.ce_nodes : "node_${key}_slo" => {
      node                     = one(local.registration_matches[key]).hostname
      role                     = "slo"
      mac                      = lower(node.mac)
      peer_address             = "10.100.0.2"
      expected_imported_routes = ["198.51.100.0/24"]
    }
  } : {}
}

resource "terraform_data" "gate" {
  count = var.enforce ? 1 : 0

  input = sha256(jsonencode(local.expected_bgp_peers))

  lifecycle {
    precondition {
      condition     = local.mapping_valid && length(local.expected_bgp_peers) == length(var.ce_nodes)
      error_message = "Configured KVM verification requires exactly one observed KVM registration hostname for each Terraform-owned CE MAC; missing, duplicate, foreign, or guessed mappings are rejected."
    }
  }
}
