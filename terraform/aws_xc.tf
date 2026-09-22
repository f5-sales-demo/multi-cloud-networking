# ---------------------------------------------------------
# Three independent F5 XC SecureMesh v2 sites and AWS VIP
# ---------------------------------------------------------

locals {
  aws_sites = {
    for index in range(var.enable_aws ? var.aws_ce_count : 0) :
    format("%02d", index + 1) => {
      index = index
      name  = format("%s-aws-%s-%02d", local.site_prefix, var.aws_location, index + 1)
      # XC embeds the site and node names in generated child interface names.
      # Keep the hostname compact so the resulting identity remains within the
      # platform's 128-byte name limit even when the site name is region-scoped.
      hostname    = format("%s-aws-%02d", var.component, index + 1)
      listener_ip = cidrhost(cidrsubnet(var.aws_vpc_cidr, 8, index + 11), 10)
    }
  }
  # Bootstrap identities are disposable and deliberately differ from the final
  # site identities.  The retirement plan deletes these objects before a final
  # site is ever created on the retained ENIs.
  aws_bootstrap_sites = {
    for key, site in local.aws_sites : key => merge(site, {
      name     = "${site.name}-bootstrap"
      hostname = "${site.hostname}-bootstrap"
    }) if contains(var.aws_bootstrap_site_keys, key)
  }
  aws_active_sites = var.aws_site_configuration_phase == "bootstrap" ? local.aws_bootstrap_sites : (
    var.aws_site_configuration_phase == "configured" ? local.aws_sites : {}
  )
  aws_ce_hostnames = [for site in values(local.aws_active_sites) : site.hostname]
}

# During bootstrap this is the authoritative observed guest-hardware inventory.
# It is intentionally absent from configured creation: final sites do not yet
# have registrations until their CEs boot. The sensitive projection is consumed
# privately after bootstrap, MAC-joined with Terraform-owned ENIs, then deleted.
data "xcsh_site_registrations_by_site" "aws_bootstrap" {
  for_each = var.aws_site_configuration_phase == "bootstrap" ? local.aws_bootstrap_sites : {}

  namespace = "system"
  site_name = xcsh_securemesh_site_v2.aws[each.key].name
}

locals {
  # This private artifact is generated from bootstrap registrations, joined to
  # Terraform-owned ENI MACs, then retained across retirement. It is never an
  # arbitrary device input and it must not be committed.
  aws_device_mapping_document = var.aws_site_configuration_phase == "configured" ? jsondecode(file(var.aws_smsv2_device_mapping_file)) : {
    schema_version = 1
    entries        = []
    checksum       = ""
  }
  aws_device_mapping_entries = try(local.aws_device_mapping_document.entries, [])
  aws_device_mapping_payload = {
    schema_version = try(local.aws_device_mapping_document.schema_version, 0)
    entries        = local.aws_device_mapping_entries
  }
  aws_discovered_device_candidates = {
    for key, site in local.aws_sites : key => {
      slo = [
        for entry in local.aws_device_mapping_entries : entry
        if try(entry.site_key, "") == key && try(entry.role, "") == "slo" && try(lower(entry.mac), "") == lower(aws_network_interface.slo[site.index].mac_address)
      ]
      sli = [
        for entry in local.aws_device_mapping_entries : entry
        if try(entry.site_key, "") == key && try(entry.role, "") == "sli" && try(lower(entry.mac), "") == lower(aws_network_interface.sli[site.index].mac_address)
      ]
    }
  }
  aws_discovered_devices = {
    for key, site in local.aws_sites : key => {
      slo = try(trimspace(one(local.aws_discovered_device_candidates[key].slo).device), null)
      sli = try(trimspace(one(local.aws_discovered_device_candidates[key].sli).device), null)
    }
  }
  aws_mapping_keys = [for entry in local.aws_device_mapping_entries : "${try(entry.site_key, "")}:${try(entry.role, "")}"]
  aws_mapping_is_complete = var.aws_site_configuration_phase != "configured" || (
    try(local.aws_device_mapping_document.schema_version, 0) == 1 &&
    try(local.aws_device_mapping_document.checksum, "") == sha256(jsonencode(local.aws_device_mapping_payload)) &&
    length(local.aws_device_mapping_entries) == 2 * length(local.aws_sites) &&
    length(distinct(local.aws_mapping_keys)) == length(local.aws_mapping_keys) &&
    alltrue([for entry in local.aws_device_mapping_entries :
      contains(keys(local.aws_sites), try(entry.site_key, "")) &&
      contains(["slo", "sli"], try(entry.role, "")) &&
      can(regex("^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", lower(try(entry.mac, "")))) &&
      try(length(trimspace(entry.device)), 0) > 0
    ])
  )
}

resource "xcsh_token" "aws" {
  for_each = local.aws_active_sites

  # XC validates token names as DNS-1035 labels, whose maximum length is 63.
  name        = substr("${each.value.name}-registration", 0, 63)
  namespace   = "system"
  description = "Registration token for independent AWS site ${each.value.name}"
  labels      = local.xc_labels
  type        = 1
  site_name   = xcsh_securemesh_site_v2.aws[each.key].name
}

resource "xcsh_securemesh_site_v2" "aws" {
  for_each    = local.aws_active_sites
  name        = each.value.name
  namespace   = "system"
  description = "Independent AWS Customer Edge SecureMesh v2 site ${each.key}"
  labels      = local.xc_labels

  aws {
    not_managed {
      dynamic "node_list" {
        for_each = var.aws_site_configuration_phase == "configured" ? [each.value] : []

        content {
          hostname  = node_list.value.hostname
          type      = "Control"
          public_ip = null

          interface_list {
            name = "slo"
            mtu  = var.aws_smsv2_interface_mtu
            ethernet_interface {
              device = local.aws_discovered_devices[each.key].slo
              mac    = aws_network_interface.slo[node_list.value.index].mac_address
            }
            network_option {
              site_local_network = {}
            }
            dhcp_client = {}
          }

          interface_list {
            name = "sli"
            mtu  = var.aws_smsv2_interface_mtu
            ethernet_interface {
              device = local.aws_discovered_devices[each.key].sli
              mac    = aws_network_interface.sli[node_list.value.index].mac_address
            }
            network_option {
              site_local_inside_network = {}
            }
            dhcp_client = {}
          }
        }
      }
    }
  }

  disable_ha                 = {}
  block_all_services         = {}
  no_network_policy          = {}
  no_forward_proxy           = {}
  f5_proxy                   = {}
  no_proxy_bypass            = {}
  logs_streaming_disabled    = {}
  no_s2s_connectivity_sli    = {}
  no_s2s_connectivity_slo    = {}
  disable_url_categorization = {}
  disable_management_network = {}

  local_vrf {
    default_config     = {}
    default_sli_config = {}
  }

  software_settings {
    # First boot must request the field-proven runtime pair.  A staged
    # baseline leaves a newly created CE in UPGRADE_IN_PROGRESS before the
    # post-bootstrap action stage can observe or recover it.
    os {
      operating_system_version = var.aws_os_version
    }
    sw {
      volterra_software_version = var.aws_software_version
    }
  }

  lifecycle {
    precondition {
      condition = var.aws_site_configuration_phase == "bootstrap" || (
        local.aws_mapping_is_complete &&
        length(local.aws_discovered_device_candidates[each.key].slo) == 1 &&
        length(local.aws_discovered_device_candidates[each.key].sli) == 1 &&
        try(length(local.aws_discovered_devices[each.key].slo), 0) > 0 &&
        try(length(local.aws_discovered_devices[each.key].sli), 0) > 0 &&
        local.aws_discovered_devices[each.key].slo != local.aws_discovered_devices[each.key].sli
      )
      error_message = "Configured AWS SMSv2 requires a checksummed bootstrap mapping with exactly one nonempty observed device for each Terraform-owned SLO/SLI ENI MAC, no duplicate or foreign entry, and distinct devices; do not guess guest device names."
    }
  }
}

data "xcsh_site_cloud_init" "aws" {
  # The console supplies a template, not a mutable cloud-init resource. The
  # separately-issued, site-bound JWT is substituted by aws_ce.tf.
  for_each                  = local.aws_active_sites
  provider_ref              = "aws"
  site_name                 = xcsh_securemesh_site_v2.aws[each.key].name
  enable_management_network = false
}

data "xcsh_site_registration" "aws" {
  for_each = local.aws_active_sites

  site_name = each.value.name
  hostname  = each.value.hostname
  namespace = "system"

}

resource "xcsh_registration_approval" "aws" {
  for_each = {
    for key, registration in data.xcsh_site_registration.aws :
    key => registration if registration.found && registration.state == "NEW"
  }

  namespace    = "system"
  name         = each.value.name
  cluster_size = 1
  state        = "APPROVED"

  depends_on = [xcsh_securemesh_site_v2.aws]
}

resource "xcsh_virtual_site" "aws" {
  count     = var.enable_aws ? 1 : 0
  name      = "${local.aws_resource_prefix}-aws-vsite"
  namespace = data.xcsh_namespace.mcn.name
  labels    = local.xc_labels

  site_type = "CUSTOMER_EDGE"
  site_selector {
    expressions = ["mcn-topology in (${local.site_prefix}-aws)"]
  }
}

resource "xcsh_origin_pool" "aws" {
  count       = var.enable_aws ? 1 : 0
  name        = "${local.aws_resource_prefix}-aws-pool"
  namespace   = data.xcsh_namespace.mcn.name
  description = "AWS origin pool serving the three-site TGW showcase"
  labels      = local.xc_labels
  port        = var.origin_port

  origin_servers {
    labels = {}
    public_name { dns_name = var.aws_origin_dns_name }
  }

  no_tls                 = {}
  loadbalancer_algorithm = "ROUND_ROBIN"
  endpoint_selection     = "DISTRIBUTED"

}

resource "xcsh_http_loadbalancer" "aws" {
  count     = var.enable_aws ? 1 : 0
  name      = "${local.aws_resource_prefix}-aws-lb"
  namespace = data.xcsh_namespace.mcn.name
  domains   = [var.aws_lb_domain]
  labels    = local.xc_labels

  # Final-site names are intentionally derived from stable locals so the
  # retirement stage can retain this object without dereferencing an empty
  # site map. Preserve the creation ordering explicitly for configured apply.
  depends_on = [xcsh_securemesh_site_v2.aws]

  http {
    port = 80
  }

  advertise_custom {
    dynamic "advertise_where" {
      # Retirement retains the load balancer and its advertisement shape while
      # bootstrap sites are removed, avoiding an empty resource-map lookup or
      # a retained-object mutation during the retirement-only phase.
      for_each = var.aws_site_configuration_phase == "configured" ? local.aws_sites : local.aws_bootstrap_sites
      content {
        site {
          network = "SITE_NETWORK_INSIDE"
          site {
            name      = advertise_where.value.name
            namespace = "system"
          }
        }
        use_default_port = {}
      }
    }
  }

  default_route_pools {
    pool {
      name      = xcsh_origin_pool.aws[0].name
      namespace = data.xcsh_namespace.mcn.name
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
}
