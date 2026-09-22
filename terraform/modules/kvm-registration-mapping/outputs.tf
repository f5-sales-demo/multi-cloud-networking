output "mapping_valid" {
  description = "Whether every Terraform-owned CE MAC has exactly one KVM registration with a distinct non-empty hostname."
  value       = local.mapping_valid
}

output "expected_bgp_peers" {
  description = "Authoritative BGP peer expectations derived from the observed registration-to-owned-MAC join."
  value       = local.expected_bgp_peers
}
