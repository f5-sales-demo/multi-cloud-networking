# ---------------------------------------------------------
# Topology
# ---------------------------------------------------------

output "ce_nodes" {
  description = "Expanded per-CE node map (hostname, site_name, slo_ip, az, interface_name)."
  value       = module.ce_topology.ce_nodes
}

output "ce_count" {
  description = "Number of CE nodes deployed."
  value       = module.ce_topology.ce_count
}

# ---------------------------------------------------------
# Azure hub / Route Server
# ---------------------------------------------------------

output "resource_group_name" {
  description = "Hub resource group name."
  value       = try(module.azure_hub[0].resource_group_name, null)
}

output "route_server_id" {
  description = "Azure Route Server resource ID."
  value       = try(module.azure_hub[0].route_server_id, null)
}

# The four outputs below exist so the documentation can name nothing. Every
# operational value a reader needs has to be readable from the deployment rather
# than copied out of prose, because prose goes stale silently and a reader cannot
# tell. Anything documented as a command therefore needs an output behind it.
output "route_server_name" {
  description = "Azure Route Server name — the --routeserver argument of `az network routeserver peering list-learned-routes`."
  value       = local.route_server_name
}

output "azure_ilb_private_ip" {
  description = "Azure US ILB private address for supported CE Site Console health and traffic verification; null when disabled."
  value       = try(azurerm_lb.azure_ilb[0].frontend_ip_configuration[0].private_ip_address, null)
}

output "canada_ilb_private_ip" {
  description = "Canadian ILB private address for supported CE Site Console health and traffic verification; null when disabled."
  value       = try(azurerm_lb.ca_ilb[0].frontend_ip_configuration[0].private_ip_address, null)
}

output "ca_resource_group_name" {
  description = "Canadian Azure resource group used for supported ILB verification."
  value       = try(module.azure_hub_ca[0].resource_group_name, null)
}

output "ca_client_vm_name" {
  description = "Canadian test client VM used to probe the Canadian ILB."
  value       = try(module.client_vm_ca[0].vm_name, null)
}

output "client_vm_name" {
  description = "Test client VM name — the -n argument of `az vm run-command invoke` when driving traffic at the VIP from inside the VNet."
  value       = local.client_vm_name
}

output "lb_domain" {
  description = "Domain the HTTP load balancer matches on. Requests to the VIP MUST send it as the Host header; without it the load balancer has no matching domain and answers 404."
  value       = var.lb_domain
}

output "origin_ip" {
  description = "Origin the pool targets. Useful as a control: a batch straight to the origin, bypassing the VIP, separates an origin fault from a VIP/ECMP/CE fault."
  value       = var.origin_ip
}

output "route_server_peer_ips" {
  description = "Route Server BGP peer IPs (the CE external BGP peer addresses)."
  value       = try(module.azure_hub[0].rs_peer_ips, [])
}

output "ce_mgmt_private_ips" {
  description = "Per-CE eth0/SLO private IPs (BGP local addresses / RS bgpConnection peer IPs)."
  value       = { for k, m in module.ce_node : k => m.mgmt_private_ip }
}

output "ce_vm_names" {
  description = "Per-CE VM names."
  value       = { for k, m in module.ce_node : k => m.vm_name }
}

output "ce_sli_private_ips" {
  description = "Per-CE internal/SLI private IPs — where each CE serves its Site Console web UI (TCP 65500). Informational: the Bastion tunnel is targeted by VM resource id (ce_vm_ids), because Azure does not allow a custom resource port over an IP-targeted tunnel."
  value       = { for k, m in module.ce_node : k => m.sli_private_ip }
}

output "ce_vm_ids" {
  description = "Per-CE VM resource IDs — the --target-resource-id of `az network bastion tunnel` when opening the Site Console web UI on 65500."
  value       = { for k, m in module.ce_node : k => m.vm_id }
}

output "site_console_admin_passwords" {
  description = "Generated per-CE passwords for the node-local Site Console admin user. Retrieve only for an active tunnel and keep them out of logs and published documentation."
  value       = { for k, password in random_password.site_console_admin : k => password.result }
  sensitive   = true
}

output "bastion_name" {
  description = "Azure Bastion host name, or null when enable_bastion is false. Feed it to `az network bastion tunnel --name`."
  value       = try(module.azure_hub[0].bastion_name, null)
}

output "client_public_ip" {
  description = "Public IP of the test client."
  value       = try(module.client_vm[0].public_ip, null)
}

output "client_nic_name" {
  description = "Test client NIC name (read effective routes here to prove ECMP)."
  value       = try(module.client_vm[0].nic_name, null)
}

# ---------------------------------------------------------
# XC tenant
# ---------------------------------------------------------

output "xc_tenant" {
  description = "F5 XC tenant this deployment writes to. Config-controlled (var.expected_xc_tenant), not taken from XCSH_API_URL."
  value       = var.expected_xc_tenant
}

output "xc_api_url" {
  description = "F5 XC API endpoint the xcsh provider is pinned to, derived from var.expected_xc_tenant."
  value       = local.xc_api_url
}

# The other half of the tenant guard's comparison, published so an operator can
# see what their shell is claiming without having to trip the guard to find out —
# `terraform output xc_env_tenant` answers "which tenant am I sourced for?".
# Empty means XCSH_API_URL is unset, which is the CI case and which the guard
# treats as no opinion rather than as a mismatch.
output "xc_env_tenant" {
  description = "F5 XC tenant named by XCSH_API_URL in the environment this ran in, or empty when unset. Diagnostic only: xc_tenant is what the deployment actually targets."
  value       = data.external.xc_env_tenant.result.tenant
}

# ---------------------------------------------------------
# XC data-plane
# ---------------------------------------------------------

output "xc_site_names" {
  description = "Per-CE XC site names."
  value       = { for k, m in module.xc_site : k => m.site_name }
}

output "ca_xc_site_names" {
  description = "Per-CE Canadian XC site names."
  value       = { for k, m in module.xc_site_ca : k => m.site_name }
}

output "ca_ce_vm_names" {
  description = "Per-CE Canadian VM names used for Azure runtime and extension verification."
  value       = { for k, m in module.ce_node_ca : k => m.vm_name }
}

# Makes the site-to-node binding that closes #674 observable from the CLI. Each
# value is the CE VM instance id its XC site object is coupled to; the matching
# registration reports the same value as infra.instance_id. When the two disagree
# the site is bound to a node that no longer exists — the state in which a
# rebuilt CE can never register. (The registration side is not on the
# xcsh_site_registration data source yet: provider issue #1376.)
output "ce_bound_instance_ids" {
  description = "Per-CE VM instance id each XC site object is bound to. Compare with the registration's infra.instance_id to spot a site still bound to a destroyed node."
  value       = { for k, m in module.xc_site : k => m.bound_vm_instance_id }
}

output "xc_interface_names" {
  description = "Per-CE auto-derived network_interface object names (BGP peer bind target)."
  value       = { for k, m in module.xc_site : k => m.interface_name }
}

output "loadbalancer_name" {
  description = "HTTP load balancer name."
  value       = try(xcsh_http_loadbalancer.this[0].name, null)
}

output "origin_pool_name" {
  description = "Origin pool name."
  value       = try(xcsh_origin_pool.this[0].name, null)
}

output "vip" {
  description = "HA VIP advertised via eBGP/ECMP."
  value       = var.vip
}

# ---------------------------------------------------------
# Canada Regional outputs
# ---------------------------------------------------------

output "ca_lb_domain" {
  description = "Domain served by the Canada HTTP load balancer."
  value       = var.ca_lb_domain
}

output "ca_re_virtual_site_name" {
  description = "Name of the Canadian Regional Edge virtual site."
  value       = try(xcsh_virtual_site.canada_re[0].name, null)
}

output "ca_ce_virtual_site_name" {
  description = "Name of the Canadian Customer Edge virtual site."
  value       = try(xcsh_virtual_site.canada_ce[0].name, null)
}

output "ca_loadbalancer_name" {
  description = "Name of the Canadian HTTP load balancer."
  value       = try(xcsh_http_loadbalancer.canada[0].name, null)
}

output "ca_origin_pool_name" {
  description = "Name of the Canadian origin pool."
  value       = try(xcsh_origin_pool.canada[0].name, null)
}

output "ca_vip" {
  description = "HA VIP for Canadian CEs advertised via eBGP/ECMP or Azure ILB."
  value       = var.ca_vip
}

output "ca_ilb_id" {
  description = "Azure Internal Load Balancer ID for Canadian regional path."
  value       = try(azurerm_lb.ca_ilb[0].id, null)
}

output "ca_ilb_frontend_ip" {
  description = "Azure Internal Load Balancer frontend private IP for Canadian regional path."
  value       = try(azurerm_lb.ca_ilb[0].frontend_ip_configuration[0].private_ip_address, null)
}

# ---------------------------------------------------------
# CE registration token
# ---------------------------------------------------------

output "registration_token_name" {
  description = "Name (metadata id) of the generated xcsh_token used for Azure CE registration, or null when Azure is disabled."
  value       = try(xcsh_token.ce[0].name, null)
}

output "registration_token_is_generated" {
  description = "True when an enabled Azure CE cloud-init token feed uses the generated xcsh_token.ce[0].uid."
  # Whether an override was supplied is not itself secret (the token value is).
  value = nonsensitive(local.azure_provider_enabled && var.registration_token == "")
}

output "ce_registration_token" {
  description = "Resolved Azure CE registration token fed to cloud-init, or null when Azure is disabled and no override is supplied."
  value       = local.ce_registration_token
  sensitive   = true
}

# ---------------------------------------------------------
# AWS outputs
# ---------------------------------------------------------

output "aws_vpc_id" {
  description = "AWS VPC ID."
  value       = try(aws_vpc.aws[0].id, null)
}

output "aws_workload_vpc_id" {
  description = "Dedicated AWS workload VPC identity."
  value       = try(aws_vpc.workload[0].id, null)
}

output "aws_workload_instance_id" {
  description = "Amazon Linux SSM client identity."
  value       = try(aws_instance.workload[0].id, null)
}

output "aws_workload_private_ip" {
  description = "Private address of the Amazon Linux SSM client."
  value       = try(aws_instance.workload[0].private_ip, null)
}

output "aws_origin_dns_name" {
  description = "DNS name of the external HTTP origin used by the AWS SMSv2 showcase."
  value       = var.aws_origin_dns_name
}

output "aws_site_names" {
  description = "Canonical independent AWS SecureMesh v2 site names."
  value       = { for key, site in local.aws_sites : key => site.name }
}

output "aws_smsv2_owned_eni_projection" {
  description = "Private Terraform-owned AWS ENI MAC projection for the one-to-one bootstrap registration join."
  sensitive   = true
  value = flatten([
    for key, site in local.aws_sites : [
      { site_key = key, role = "slo", mac = aws_network_interface.slo[site.index].mac_address },
      { site_key = key, role = "sli", mac = aws_network_interface.sli[site.index].mac_address },
    ]
  ])
}

output "aws_smsv2_bootstrap_registration_projection" {
  description = "Private observed bootstrap hardware projection for the one-to-one device join."
  sensitive   = true
  value = flatten([
    for key, registration in data.xcsh_site_registrations_by_site.aws_bootstrap : [
      for item in coalesce(try(registration.items, null), []) : [
        for network in try(item.get_spec.infra.hw_info.network, []) : {
          site_key = key
          mac      = network.mac_address
          device   = network.name
        }
      ]
    ]
  ])
}

output "kvm_runtime_status" {
  description = "Sanitized KVM registration and BGP convergence summary."
  value = var.enable_kvm ? {
    registration_count = length([
      for registration in values(data.xcsh_site_registration.kvm) : registration if registration.found
    ])
    online_count = length([
      # xcsh_site_registration.state is the registration object's current
      # state. ONLINE means the matched CE node is admitted and healthy; it is
      # not inferred from approval-resource presence or from plan completion.
      for registration in values(data.xcsh_site_registration.kvm) : registration if registration.state == "ONLINE"
    ])
    mapping_valid     = local.kvm_registration_mapping_valid
    bgp_converged     = try(data.external.kvm_bgp_observer[0].result.converged == "true", false)
    bgp_session_count = try(data.external.kvm_bgp_observer[0].result.converged == "true" ? 1 : 0, 0)
  } : null
}

output "aws_tgw_id" {
  description = "AWS Transit Gateway identity."
  value       = try(module.aws_tgw_connect[0].transit_gateway_id, null)
}

output "aws_tgw_route_table_id" {
  description = "TGW route table used for explicit workload association and propagation."
  value       = try(module.aws_tgw_connect[0].route_table_id, null)
}

output "aws_ce_instance_ids" {
  description = "EC2 instance IDs of the AWS Customer Edge nodes."
  value       = aws_instance.ce[*].id
}

output "aws_ce_public_ips" {
  description = "Elastic IPs assigned to the AWS Customer Edge nodes."
  value       = aws_eip.ce[*].public_ip
}

output "aws_lb_domain" {
  description = "Domain served by the AWS HTTP load balancer."
  value       = var.aws_lb_domain
}

output "aws_loadbalancer_name" {
  description = "Name of the AWS HTTP load balancer."
  value       = try(xcsh_http_loadbalancer.aws[0].name, null)
}

output "aws_origin_pool_name" {
  description = "Name of the AWS origin pool."
  value       = try(xcsh_origin_pool.aws[0].name, null)
}

output "aws_vip" {
  description = "Plan-bound private IP of the internal NLB fronting the three BGP-routed SMSv2 listeners."
  value       = var.aws_vip
}

output "aws_smsv2_site_listener_ips" {
  description = "Per-site automatic SLI listener addresses exported over TGW Connect BGP."
  value       = { for key, site in local.aws_sites : key => site.listener_ip }
}

output "aws_smsv2_nlb_dns_name" {
  description = "Internal AWS NLB DNS name for the SMSv2 service."
  value       = try(aws_lb.smsv2[0].dns_name, null)
}

output "aws_smsv2_target_group_arn" {
  description = "Target group containing the three BGP-routed SMSv2 site listeners."
  value       = try(aws_lb_target_group.smsv2[0].arn, null)
}
