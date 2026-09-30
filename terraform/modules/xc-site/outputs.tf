output "site_name" {
  description = "XC securemesh_site_v2 name."
  value       = var.site_name
}

output "site_created" {
  description = "Whether this module instance manages its Secure Mesh Site v2 object."
  value       = length(xcsh_securemesh_site_v2.this) == 1
}

output "bgp_name" {
  description = "XC bgp object name (null when enable_bgp is false)."
  value       = one(xcsh_bgp.this[*].name)
}

output "interface_name" {
  description = "Auto-derived network_interface object name the BGP peer binds to."
  value       = var.interface_name
}

# The shared pre-boot generation used for site and VM replacement.
output "bound_generation_id" {
  description = "Shared pre-boot CE generation that replaces the site and VM together."
  value       = terraform_data.ce_generation.output
}

output "registration_name" {
  description = "Runtime registration name (r-<uuid>) resolved from the site name; null until the CE has registered."
  value       = data.xcsh_site_registration.this.found ? data.xcsh_site_registration.this.name : null
}

output "registration_state" {
  description = "Current registration state reported by XC (NEW, APPROVED, ONLINE, ...); null until the CE has registered."
  value       = data.xcsh_site_registration.this.found ? data.xcsh_site_registration.this.state : null
}

output "registration_approval_name" {
  description = "Name of the approved registration (null when approve_registration is false or the CE has not registered yet)."
  value       = one(xcsh_registration_approval.this[*].name)
}

output "peer_count" {
  description = "Number of external BGP peers configured (one per regional FRR relay; 0 when enable_bgp is false)."
  value       = var.enable_bgp ? var.peer_count : 0
}

output "interface_count" {
  value = nonsensitive(length(one(xcsh_securemesh_site_v2.this).azure.not_managed.node_list[0].interface_list))
}
