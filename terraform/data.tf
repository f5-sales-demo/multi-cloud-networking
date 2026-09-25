# Deployer identity resolution (read-only, azuread). An explicit deployer makes
# the lookup unnecessary, which keeps AWS-only planning from contacting Azure.
data "azuread_client_config" "current" {
  count = var.enable_azure && var.deployer == "" ? 1 : 0
}

data "azuread_user" "current" {
  count     = var.enable_azure && var.deployer == "" ? 1 : 0
  object_id = data.azuread_client_config.current[0].object_id
}

# The v11.3.0 provider embeds the v8.0.2 published network allowlist. These
# values identify destinations, not firewall rules: protocol, port, direction,
# and reachability are checked explicitly by the lifecycle preflight.
data "xcsh_network_customer_edge_defaults" "system_services" {}
data "xcsh_network_customer_edge_egress" "secure_mesh_v2" {}
