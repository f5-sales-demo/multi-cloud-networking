# MCN SMSv2 multi-site showcase — top-level wiring.
#
# The supported Azure path uses an Internal Load Balancer to reach CE Site Console
# health endpoints. Azure Route Server is opt-in and deliberately fails closed until
# the immutable F5 contract supplies writable eBGP multihop semantics.
#
# Deploy-time ordering: Azure (VNet/subnets/RS/NICs/VMs) -> XC site (explicit
# interface) -> token -> CE cloud-init boot -> CE registers -> registration
# approval -> CE ONLINE -> xcsh_bgp + RS bgpConnection -> LB advertise.
#
# Approval is automated, but the deploy is inherently TWO-PHASE, not a single
# hands-off apply: a CE's registration is named r-<uuid> and only exists after
# the node has booted and registered. The xc-site module resolves that name with
# the xcsh_site_registration data source and approves it with
# xcsh_registration_approval, gated on found — so the first apply plans no
# approval, and a re-apply once the CEs have registered creates them. The bgp/LB
# objects can be applied before ONLINE; they converge once the CE is up.

# Guard: the F5 XC tenant in the environment MUST be the one this deployment
# belongs to.
#
# providers.tf already pins the xcsh endpoint to var.expected_xc_tenant, so a
# stray XCSH_API_URL can no longer redirect the deployment. What it can still do
# is mean the operator's TOKEN belongs to a different tenant — and the symptom of
# that is a bare 401 from the first API call, which reads like an expired
# credential and not like "you are pointed at the wrong tenant". This turns it
# into a sentence that says so.
#
# It is not hypothetical. The MCN demo was built in f5-sales-demo; the credential
# file later started exporting an f5-amer-ent XCSH_API_URL; subsequent applies
# minted an f5-amer-ent token, the CE VMs re-registered there, and their
# f5-sales-demo registrations were abandoned. Every plan in between was clean,
# because nothing in the configuration had an opinion about the tenant (#696).
#
# The external program reads the environment and nothing else — no credential, no
# network call — which is what keeps `terraform test` and CI's
# `terraform init -backend=false` credential-free. Where XCSH_API_URL is unset the
# program reports an empty tenant and the guard abstains.
#
# postcondition, not check{}: a check block only WARNS, and a warning scrolls past
# in exactly the situation this exists to stop.
data "external" "xc_env_tenant" {
  program = ["${path.module}/scripts/xc-env-tenant.sh"]

  lifecycle {
    postcondition {
      condition     = contains(["", var.expected_xc_tenant], self.result.tenant)
      error_message = "Wrong F5 XC tenant. XCSH_API_URL in this environment names tenant '${self.result.tenant}', but this deployment belongs to '${var.expected_xc_tenant}'. Source the credential file for '${var.expected_xc_tenant}', or — if you really do mean to act on '${self.result.tenant}' — say so explicitly with -var expected_xc_tenant=${self.result.tenant} and an isolated AWS S3 state key of its own."
    }
  }
}

# KVM uses one explicitly allocated host network. Branch naming cannot make its
# subnet, MACs, FRR identity, or host capacity safe to share. Reject a preview
# before any mutation until a separately reviewed allocation contract exists.
resource "terraform_data" "deployment_identity_guard" {
  input = local.deployment_environment_key

  lifecycle {
    precondition {
      condition     = local.deployment_is_production || !var.enable_kvm
      error_message = "KVM previews are unsupported without a separately approved subnet, MAC, bridge, FRR, and capacity allocation; disable KVM or deploy exact refs/heads/main."
    }
    precondition {
      condition     = length(local.deployment_environment_key) <= 32
      error_message = "deployment environment key exceeds its 32-character contract."
    }
    precondition {
      condition     = length(local.lb_domain) <= 253 && length(local.ca_lb_domain) <= 253 && length(local.aws_lb_domain) <= 253
      error_message = "environment-scoped load-balancer domain exceeds the DNS limit."
    }
  }
}

# Guard: the HA VIP MUST be outside every VNet CIDR, or Azure prefers the VNet
# system route over the more-specific BGP /32. Masks the VIP to each CIDR's prefix
# length and compares network addresses (a correct containment test for any prefix).
check "vip_outside_vnet_cidrs" {
  assert {
    condition     = cidrhost(var.hub_cidr, 0) != cidrhost("${var.vip}/${split("/", var.hub_cidr)[1]}", 0)
    error_message = "vip ${var.vip} must be OUTSIDE hub_cidr ${var.hub_cidr}."
  }
  assert {
    condition     = cidrhost(var.spoke_cidr, 0) != cidrhost("${var.vip}/${split("/", var.spoke_cidr)[1]}", 0)
    error_message = "vip ${var.vip} must be OUTSIDE spoke_cidr ${var.spoke_cidr}."
  }
}

check "ca_vip_outside_vnet_cidrs" {
  assert {
    condition     = !var.enable_canada || cidrhost(var.ca_hub_cidr, 0) != cidrhost("${var.ca_vip}/${split("/", var.ca_hub_cidr)[1]}", 0)
    error_message = "ca_vip ${var.ca_vip} must be OUTSIDE ca_hub_cidr ${var.ca_hub_cidr}."
  }
}

# Tenant-scoped, reusable Azure site registration token. The provider now ships
# xcsh_token with a Computed `uid` (system_metadata.uid) — the token VALUE a CE
# feeds to VPM at registration (the resource `id` is the token NAME, not the
# value). The spec is empty; only metadata is needed and namespace defaults to
# system. This replaces the manual var.registration_token prerequisite (#1205).
# The console approval step (#1206 / #1210) is likewise gone: each CE's runtime
# registration is resolved by site name and approved in the post-registration
# phase (see modules/xc-site/main.tf and the deploy ordering above).
resource "xcsh_token" "ce" {
  count = local.azure_provider_enabled ? 1 : 0

  name        = "${local.site_prefix}-registration"
  namespace   = "system"
  description = "MCN CE-HA registration token (tenant-scoped, reusable across CE sites)"
  labels      = local.azure_xc_labels
}

# Pure expansion of ce_count into the per-CE node map (hostname, site_name,
# slo_ip, az, interface_name). Drives every for_each below.
module "ce_topology" {
  source = "./modules/ce-topology"

  ce_count           = var.ce_count
  enabled            = var.enable_azure
  region_short       = local.region_short
  mgmt_subnet_prefix = var.mgmt_subnet_prefix
  site_prefix        = local.site_prefix
}

# Hub: RG, VNet, and CE subnets. Route Server is created for the relay-backed
# BGP topology when enabled.
module "azure_hub" {
  source = "./modules/azure-hub"
  count  = var.enable_azure ? 1 : 0

  depends_on = [azapi_resource_action.f5xc_customer_edge_marketplace_agreement]

  resource_group_name        = local.resource_group_name
  location                   = var.location
  hub_cidr                   = var.hub_cidr
  mgmt_subnet_prefix         = var.mgmt_subnet_prefix
  external_subnet_prefix     = var.external_subnet_prefix
  internal_subnet_prefix     = var.internal_subnet_prefix
  route_server_subnet_prefix = var.route_server_subnet_prefix
  route_server_name          = local.route_server_name
  enable_route_server        = var.enable_bgp
  bastion_subnet_prefix      = var.bastion_subnet_prefix
  enable_bastion             = var.enable_bastion
  bastion_name               = local.bastion_name
  tags                       = local.tags
}

# One CE VM (3 NICs + identity) per node.
module "ce_node" {
  source   = "./modules/ce-node"
  for_each = module.ce_topology.ce_nodes

  hostname            = each.value.hostname
  resource_group_name = module.azure_hub[0].resource_group_name
  location            = module.azure_hub[0].location
  zone                = each.value.az
  vm_size             = var.ce_vm_size
  mgmt_subnet_id      = module.azure_hub[0].management_subnet_id
  external_subnet_id  = module.azure_hub[0].external_subnet_id
  internal_subnet_id  = module.azure_hub[0].internal_subnet_id
  mgmt_private_ip     = each.value.slo_ip
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key

  custom_data = base64encode(local.ce_cloud_init[each.key])

  tags = local.tags
}

# Generate a distinct Site Console admin password for every CE. Binding the
# password lifecycle to the VM instance rotates it automatically whenever that
# node is rebuilt, while keeping the value only in the encrypted remote state
# and sensitive Terraform output.
resource "random_password" "site_console_admin" {
  for_each = module.ce_topology.ce_nodes

  length           = 32
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "!#%*+-=?@^_~"

  keepers = {
    ce_vm_instance_id = module.ce_node[each.key].vm_instance_id
  }
}

# Site Console Basic Auth delegates password verification to VPM on the CE host.
# The XC site's admin_user_credentials field is accepted by the API but VPM
# deliberately skips the built-in admin user, so it does not rotate this
# credential. Apply the generated value on the node as root instead.
#
# The Custom Script extension receives only an encrypted protected setting. Its
# inline script keeps the password out of command arguments and produces no
# output. The password resource is keyed by Azure's per-instance VM id, so a VM
# replacement generates a new value and updates this extension even though the
# name-derived ARM resource id stays the same.
resource "azurerm_virtual_machine_extension" "site_console_password" {
  for_each = module.ce_topology.ce_nodes

  name                       = "site-console-admin-password"
  virtual_machine_id         = module.ce_node[each.key].vm_id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(<<-SCRIPT
      #!/usr/bin/env bash
      set -euo pipefail
      password_b64='${base64encode(random_password.site_console_admin[each.key].result)}'
      password=$(printf '%s' "$password_b64" | base64 --decode)
      printf 'admin:%s\n' "$password" | chpasswd
      unset password password_b64
    SCRIPT
    )
  })
}

# One XC SMSv2 site + bgp object per node. The MAC is wired from the mgmt NIC so
# a NIC recreate updates the site binding automatically.
module "xc_site" {
  source   = "./modules/xc-site"
  for_each = module.ce_topology.ce_nodes

  site_name      = each.value.site_name
  hostname       = each.value.hostname
  interface_name = each.value.interface_name
  mgmt_nic_mac   = module.ce_node[each.key].mgmt_nic_mac
  # Couples the site object's lifecycle to the CE VM INSTANCE (issue #674):
  # replacing the VM replaces the site, which takes the registration bound to the
  # destroyed instance with it. Must be virtual_machine_id, not the ARM resource
  # id — the latter is name-derived and identical after a replacement.
  ce_vm_instance_id    = module.ce_node[each.key].vm_instance_id
  peer_ips             = try(module.azure_frr_us[0].peer_ips, [])
  ce_asn               = var.ce_asn
  peer_asn             = var.azure_frr_asn
  os_version           = var.ce_os_version
  sw_version           = var.ce_sw_version
  enable_bgp           = var.enable_bgp
  approve_registration = var.approve_registration
  labels               = local.azure_xc_labels
}

# Each CE peers with both local FRRs. The FRRs, and only the FRRs, peer
# with Azure Route Server and export a CE-learned application VIP /32.
module "azure_frr_us" {
  count  = var.enable_azure && var.enable_bgp ? 1 : 0
  source = "./modules/azure-frr"

  name                = "${var.component}-us"
  location            = module.azure_hub[0].location
  resource_group_name = module.azure_hub[0].resource_group_name
  mgmt_subnet_id      = module.azure_hub[0].management_subnet_id
  mgmt_subnet_prefix  = var.mgmt_subnet_prefix
  route_server_id     = module.azure_hub[0].route_server_id
  rs_peer_ips         = module.azure_hub[0].rs_peer_ips
  ce_ips              = [for key in sort(keys(module.ce_topology.ce_nodes)) : module.ce_node[key].mgmt_private_ip]
  vip                 = var.vip
  ce_asn              = var.ce_asn
  frr_asn             = var.azure_frr_asn
  rs_asn              = var.rs_asn
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key
  tags                = local.tags
}

# Test client in snet-hub-internal.
module "client_vm" {
  source = "./modules/client-vm"
  count  = var.enable_azure ? 1 : 0

  name                = local.client_vm_name
  resource_group_name = module.azure_hub[0].resource_group_name
  location            = module.azure_hub[0].location
  subnet_id           = module.azure_hub[0].internal_subnet_id
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key
  tags                = local.tags
}

# ---------------------------------------------------------
# F5 XC data-plane (app tier)
# ---------------------------------------------------------

# The application namespace (origin pool + VIP load balancer live here) is an
# input, never an owned object. `multi-cloud-networking` predates this deployment
# and outlives it, and a `resource` block would put a namespace full of other
# people's demos on this stack's destroy list — which is how issue #637 happened.
#
# Issues #634 ("cannot be recreated, POST is 403") and #639 ("defaults to a
# namespace that no longer exists") were symptoms of reading the WRONG TENANT, not
# of a permissions or lifecycle problem: the namespace exists, in f5-sales-demo,
# and always did. The tenant guard at the top of this file is the actual fix (#696).
# Reading rather than owning the namespace is still correct, for the #637 reason.
#
# Reading it means Terraform never creates, updates or destroys it. The
# read still gives the pool and the load balancer their apply-time ordering: they
# take their namespace from this data source, so a missing namespace fails the
# plan loudly rather than half-applying. `namespace` is empty because a namespace
# object is not itself contained in a namespace (the API returns
# `metadata.namespace: ""` for one).
data "xcsh_namespace" "mcn" {
  name      = var.xc_app_namespace
  namespace = ""
}

resource "xcsh_origin_pool" "this" {
  count       = var.enable_azure ? 1 : 0
  name        = local.origin_pool_name
  namespace   = data.xcsh_namespace.mcn.name
  description = "MCN reference origin pool -> ${var.origin_ip}:${var.origin_port}"
  labels      = local.azure_xc_labels

  port = var.origin_port

  origin_servers {
    labels = {}
    public_ip {
      ip = var.origin_ip
    }
  }

  no_tls                 = {}
  loadbalancer_algorithm = "ROUND_ROBIN"
  endpoint_selection     = "DISTRIBUTED"
}

resource "xcsh_http_loadbalancer" "this" {
  count = var.enable_azure ? 1 : 0
  # The advertise_custom block below names each CE site, but it takes those names from
  # module.ce_topology — a pure computation module that only derives strings. The
  # objects themselves come from module.xc_site, and nothing in this resource
  # references them, so Terraform sees NO dependency and is free to create the load
  # balancer before any site exists. XC then rejects the dangling site reference with
  # `[BAD_REQUEST] Invalid request parameters` on POST .../http_loadbalancers.
  #
  # The bug is invisible while the sites already exist under the names being
  # referenced, which is why it stayed latent until the demo was renamed: that
  # destroyed every site and created new ones, and the load balancer raced ahead of
  # them. Making the dependency explicit is the fix; there is no cycle, because
  # xc-site does not reference the load balancer.
  depends_on = [module.xc_site]

  name        = local.lb_name
  namespace   = data.xcsh_namespace.mcn.name
  description = "BGP/ECMP HA: custom VIP ${var.vip} advertised from every CE site."
  labels      = local.azure_xc_labels

  domains = [local.lb_domain]

  http {
    port = 80
  }

  # Advertise the VIP on the outside network of every CE site.
  advertise_custom {
    dynamic "advertise_where" {
      for_each = module.ce_topology.ce_nodes
      content {
        site {
          network = "SITE_NETWORK_OUTSIDE"
          site {
            namespace = "system"
            name      = advertise_where.value.site_name
          }
          ip = var.vip
        }
        use_default_port = {}
      }
    }
  }

  default_route_pools {
    pool {
      namespace = data.xcsh_namespace.mcn.name
      name      = xcsh_origin_pool.this[0].name
    }
    weight   = 1
    priority = 1
  }

  round_robin            = {}
  no_challenge           = {}
  user_id_client_ip      = {}
  disable_waf            = {}
  disable_rate_limit     = {}
  disable_api_discovery  = {}
  disable_api_testing    = {}
  disable_api_definition = {}
  l7_ddos_protection {}
  service_policies_from_namespace  = {}
  disable_trust_client_ip_headers  = {}
  disable_malicious_user_detection = {}
  disable_malware_protection       = {}
  disable_threat_mesh              = {}
  default_sensitive_data_policy    = {}
}

# ---------------------------------------------------------
# Canada Regional Infrastructure & F5 XC Data-Plane (Canada Path)
# ---------------------------------------------------------

# Pure expansion of ca_ce_count into the per-CE node map for Canada.
module "ce_topology_ca" {
  count  = var.enable_azure && var.enable_canada ? 1 : 0
  source = "./modules/ce-topology"

  ce_count           = var.ca_ce_count
  region_short       = local.ca_region_short
  mgmt_subnet_prefix = var.ca_mgmt_subnet_prefix
  site_prefix        = local.ca_site_prefix
}

# Canada Hub: RG, VNet, and CE subnets; Route Server remains opt-in.
module "azure_hub_ca" {
  count  = var.enable_azure && var.enable_canada ? 1 : 0
  source = "./modules/azure-hub"

  depends_on = [azapi_resource_action.f5xc_customer_edge_marketplace_agreement]

  resource_group_name        = local.ca_resource_group_name
  location                   = var.ca_location
  hub_cidr                   = var.ca_hub_cidr
  mgmt_subnet_prefix         = var.ca_mgmt_subnet_prefix
  external_subnet_prefix     = var.ca_external_subnet_prefix
  internal_subnet_prefix     = var.ca_internal_subnet_prefix
  route_server_subnet_prefix = var.ca_route_server_subnet_prefix
  route_server_name          = local.ca_route_server_name
  enable_route_server        = var.enable_bgp
  bastion_subnet_prefix      = var.ca_bastion_subnet_prefix
  enable_bastion             = var.enable_bastion
  bastion_name               = local.ca_bastion_name
  tags                       = local.tags
}

# One Canadian CE VM (3 NICs + identity) per node.
module "ce_node_ca" {
  for_each = try(module.ce_topology_ca[0].ce_nodes, {})
  source   = "./modules/ce-node"

  hostname            = each.value.hostname
  resource_group_name = try(module.azure_hub_ca[0].resource_group_name, null)
  location            = try(module.azure_hub_ca[0].location, null)
  zone                = each.value.az
  vm_size             = var.ce_vm_size
  mgmt_subnet_id      = try(module.azure_hub_ca[0].management_subnet_id, null)
  external_subnet_id  = try(module.azure_hub_ca[0].external_subnet_id, null)
  internal_subnet_id  = try(module.azure_hub_ca[0].internal_subnet_id, null)
  mgmt_private_ip     = each.value.slo_ip
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key

  custom_data = base64encode(local.ca_ce_cloud_init[each.key])

  tags = local.tags
}

resource "random_password" "site_console_admin_ca" {
  for_each = try(module.ce_topology_ca[0].ce_nodes, {})

  length           = 32
  min_lower        = 1
  min_numeric      = 1
  min_special      = 1
  min_upper        = 1
  override_special = "!#%*+-=?@^_~"

  keepers = {
    ce_vm_instance_id = module.ce_node_ca[each.key].vm_instance_id
  }
}

resource "azurerm_virtual_machine_extension" "site_console_password_ca" {
  for_each = try(module.ce_topology_ca[0].ce_nodes, {})

  name                       = "site-console-admin-password"
  virtual_machine_id         = module.ce_node_ca[each.key].vm_id
  publisher                  = "Microsoft.Azure.Extensions"
  type                       = "CustomScript"
  type_handler_version       = "2.1"
  auto_upgrade_minor_version = true

  protected_settings = jsonencode({
    script = base64encode(<<-SCRIPT
      #!/usr/bin/env bash
      set -euo pipefail
      password_b64='${base64encode(random_password.site_console_admin_ca[each.key].result)}'
      password=$(printf '%s' "$password_b64" | base64 --decode)
      printf 'admin:%s\n' "$password" | chpasswd
      unset password password_b64
    SCRIPT
    )
  })
}

# Canadian XC SMSv2 site + BGP object per node.
module "xc_site_ca" {
  for_each = try(module.ce_topology_ca[0].ce_nodes, {})
  source   = "./modules/xc-site"

  create_site          = true
  site_name            = each.value.site_name
  hostname             = each.value.hostname
  interface_name       = each.value.interface_name
  mgmt_nic_mac         = module.ce_node_ca[each.key].mgmt_nic_mac
  ce_vm_instance_id    = module.ce_node_ca[each.key].vm_instance_id
  peer_ips             = try(module.azure_frr_ca[0].peer_ips, [])
  ce_asn               = var.ce_asn
  peer_asn             = var.azure_frr_asn
  os_version           = var.ce_os_version
  sw_version           = var.ce_sw_version
  enable_bgp           = var.enable_bgp
  approve_registration = var.approve_registration
  labels               = local.ca_xc_labels
}

module "azure_frr_ca" {
  count  = var.enable_azure && var.enable_canada && var.enable_bgp ? 1 : 0
  source = "./modules/azure-frr"

  name                = "${var.component}-ca"
  location            = module.azure_hub_ca[0].location
  resource_group_name = module.azure_hub_ca[0].resource_group_name
  mgmt_subnet_id      = module.azure_hub_ca[0].management_subnet_id
  mgmt_subnet_prefix  = var.ca_mgmt_subnet_prefix
  route_server_id     = module.azure_hub_ca[0].route_server_id
  rs_peer_ips         = module.azure_hub_ca[0].rs_peer_ips
  ce_ips              = [for key in sort(keys(module.ce_topology_ca[0].ce_nodes)) : module.ce_node_ca[key].mgmt_private_ip]
  vip                 = var.ca_vip
  ce_asn              = var.ce_asn
  frr_asn             = var.azure_frr_asn
  rs_asn              = var.rs_asn
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key
  tags                = local.tags
}

module "client_vm_ca" {
  count  = var.enable_azure && var.enable_canada ? 1 : 0
  source = "./modules/client-vm"

  name                = local.ca_client_vm_name
  resource_group_name = try(module.azure_hub_ca[0].resource_group_name, null)
  location            = try(module.azure_hub_ca[0].location, null)
  subnet_id           = try(module.azure_hub_ca[0].internal_subnet_id, null)
  admin_username      = var.admin_username
  ssh_public_key      = local.ssh_public_key
  tags                = local.tags
}

# ---------------------------------------------------------
# F5 XC Virtual Sites (Canada RE & Canada CE)
# ---------------------------------------------------------

resource "xcsh_virtual_site" "canada_re" {
  count     = var.enable_azure && var.enable_canada ? 1 : 0
  name      = local.ca_re_vsite_name
  namespace = data.xcsh_namespace.mcn.name
  labels    = local.ca_xc_labels

  site_type = "REGIONAL_EDGE"
  site_selector {
    expressions = ["ves.io/city in (${join(", ", var.ca_re_cities)})"]
  }
}

resource "xcsh_virtual_site" "canada_ce" {
  count     = var.enable_azure && var.enable_canada ? 1 : 0
  name      = local.ca_ce_vsite_name
  namespace = data.xcsh_namespace.mcn.name
  labels    = local.ca_xc_labels

  site_type = "CUSTOMER_EDGE"
  site_selector {
    expressions = ["ves.io/siteName in (${join(", ", [for k, v in try(module.ce_topology_ca[0].ce_nodes, {}) : v.site_name])})"]
  }
}

resource "xcsh_origin_pool" "canada" {
  count       = var.enable_azure && var.enable_canada ? 1 : 0
  name        = local.ca_origin_pool_name
  namespace   = data.xcsh_namespace.mcn.name
  description = "Canada reference origin pool -> ${var.origin_ip}:${var.origin_port}"
  labels      = local.ca_xc_labels

  port = var.origin_port

  origin_servers {
    labels = {}
    public_ip {
      ip = var.origin_ip
    }
  }

  no_tls                 = {}
  loadbalancer_algorithm = "ROUND_ROBIN"
  endpoint_selection     = "DISTRIBUTED"
}

resource "xcsh_http_loadbalancer" "canada" {
  count      = var.enable_azure && var.enable_canada ? 1 : 0
  depends_on = [module.xc_site_ca, xcsh_virtual_site.canada_re, xcsh_virtual_site.canada_ce]

  name        = local.ca_lb_name
  namespace   = data.xcsh_namespace.mcn.name
  description = "Canada Regional HA: custom VIP ${var.ca_vip} advertised strictly via Canadian Regional Edges (Toronto and Montreal) and Canadian CEs."
  labels      = local.ca_xc_labels

  domains = [local.ca_lb_domain]

  http {
    port = 80
  }

  advertise_custom {
    dynamic "advertise_where" {
      for_each = try(module.ce_topology_ca[0].ce_nodes, {})
      content {
        site {
          network = "SITE_NETWORK_OUTSIDE"
          site {
            namespace = "system"
            name      = advertise_where.value.site_name
          }
          ip = var.ca_vip
        }
        use_default_port = {}
      }
    }
  }

  default_route_pools {
    pool {
      namespace = data.xcsh_namespace.mcn.name
      name      = try(xcsh_origin_pool.canada[0].name, null)
    }
    weight   = 1
    priority = 1
  }

  round_robin            = {}
  no_challenge           = {}
  user_id_client_ip      = {}
  disable_waf            = {}
  disable_rate_limit     = {}
  disable_api_discovery  = {}
  disable_api_testing    = {}
  disable_api_definition = {}
  l7_ddos_protection {}
  service_policies_from_namespace  = {}
  disable_trust_client_ip_headers  = {}
  disable_malicious_user_detection = {}
  disable_malware_protection       = {}
  disable_threat_mesh              = {}
  default_sensitive_data_policy    = {}
}
