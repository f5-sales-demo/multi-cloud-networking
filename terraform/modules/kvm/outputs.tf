output "runtime_status" {
  value = var.enable_kvm ? {
    registration_count = length([for registration in values(data.xcsh_site_registration.kvm) : registration if registration.found])
    online_count       = length([for registration in values(data.xcsh_site_registration.kvm) : registration if registration.state == "ONLINE"])
    mapping_valid      = local.kvm_registration_mapping_valid
    bgp_converged      = try(data.xcsh_site_bgp_status.kvm[0].converged, false)
    bgp_session_count  = length(try(data.xcsh_site_bgp_status.kvm[0].peers, {}))
  } : null
}

output "bgp_fabric" {
  value = var.enable_kvm ? {
    router_name  = docker_container.kvm_frr[0].name
    router_ip    = "10.100.0.2"
    router_asn   = 65515
    ce_asn       = 64512
    ce_addresses = { for key, node in local.kvm_ce_nodes : key => node.address }
  } : null
}
