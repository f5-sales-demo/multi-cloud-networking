# Optional physical-LAN SLI topology for the single KVM CE. The host bridge is
# an explicit shared prerequisite and is never created, reconfigured, or
# destroyed by this root.
locals {
  kvm_lan_enabled    = var.enable_kvm && var.enable_kvm_lan && var.kvm_lan != null
  kvm_lan_configured = local.kvm_lan_enabled && var.kvm_lan_configuration_phase == "configured" && var.kvm_lan_observed_node != null
  kvm_lan_name_stem  = "${substr(local.kvm_site_name, 0, 43)}-${substr(sha256(local.kvm_site_name), 0, 8)}"
}

check "kvm_lan_prerequisites" {
  assert {
    condition = !var.enable_kvm_lan || try(
      var.enable_kvm &&
      var.kvm_lan != null &&
      var.kvm_lan_configuration_phase != "disabled" &&
      var.kvm_lan.bridge_preprovisioned &&
      var.kvm_lan.uplink_approved &&
      var.kvm_lan.ipv4_users_reviewed &&
      var.kvm_lan.ipv6_users_reviewed &&
      var.kvm_lan.switch_multi_mac_approved &&
      var.kvm_lan.duplicate_addresses_checked &&
      var.kvm_lan.bridge != local.kvm_network_bridge &&
      lower(var.kvm_lan.sli_mac) != lower(local.kvm_ce_nodes["01"].mac) &&
      lower(var.kvm_lan.uplink_mac) != lower(local.kvm_ce_nodes["01"].mac),
      false,
    )
    error_message = "KVM LAN requires enable_kvm, a non-disabled phase, distinct bridge/MAC identity, and explicit bridge, uplink, IPv4, IPv6, switch multi-MAC, and duplicate-address approvals."
  }
}

check "kvm_lan_observed_mapping" {
  assert {
    condition = (
      (!var.enable_kvm_lan && var.kvm_lan_configuration_phase == "disabled" && var.kvm_lan == null && var.kvm_lan_observed_node == null) ||
      (var.enable_kvm_lan && var.kvm_lan_configuration_phase == "hardware" && var.kvm_lan_observed_node == null) ||
      (var.enable_kvm_lan && var.kvm_lan_configuration_phase == "configured" && var.kvm_lan_observed_node != null)
    )
    error_message = "KVM LAN phase must be disabled with no observed mapping, hardware with no guessed mapping, or configured with exact staged node/device evidence."
  }
}

resource "xcsh_virtual_site" "kvm_lan" {
  count     = local.kvm_lan_configured ? 1 : 0
  name      = "${local.kvm_lan_name_stem}-lan-vs"
  namespace = data.xcsh_namespace.mcn.name
  labels    = local.kvm_xc_labels
  site_type = "CUSTOMER_EDGE"

  site_selector {
    expressions = ["ves.io/siteName in (${xcsh_securemesh_site_v2.onprem_kvm[0].name})"]
  }
}

resource "xcsh_origin_pool" "kvm_lan" {
  count       = local.kvm_lan_configured ? 1 : 0
  name        = "${local.kvm_lan_name_stem}-lan-pool"
  namespace   = data.xcsh_namespace.mcn.name
  description = "KVM physical-LAN origin owned by ${var.kvm_lan.backend_owner}"
  labels      = local.kvm_xc_labels
  port        = var.kvm_lan.backend_port

  origin_servers {
    labels = {}
    private_ip {
      ip             = var.kvm_lan.backend_ip
      inside_network = {}
      site_locator {
        site {
          name      = xcsh_securemesh_site_v2.onprem_kvm[0].name
          namespace = xcsh_securemesh_site_v2.onprem_kvm[0].namespace
        }
      }
    }
  }

  no_tls                 = {}
  loadbalancer_algorithm = "ROUND_ROBIN"
  endpoint_selection     = "DISTRIBUTED"
}

resource "xcsh_http_loadbalancer" "kvm_lan" {
  count       = local.kvm_lan_configured ? 1 : 0
  name        = "${local.kvm_lan_name_stem}-lan-lb"
  namespace   = data.xcsh_namespace.mcn.name
  description = "KVM custom inside VIP for ${var.kvm_lan.access_scope}"
  domains     = [var.kvm_lan.http_domain]
  labels      = local.kvm_xc_labels

  http {
    port = 80
  }

  advertise_custom {
    advertise_where {
      port = 80
      virtual_site_with_vip {
        ip      = var.kvm_lan.vip
        network = "SITE_NETWORK_SPECIFIED_VIP_INSIDE"
        virtual_site {
          name      = xcsh_virtual_site.kvm_lan[0].name
          namespace = xcsh_virtual_site.kvm_lan[0].namespace
        }
      }
    }
  }

  default_route_pools {
    pool {
      name      = xcsh_origin_pool.kvm_lan[0].name
      namespace = xcsh_origin_pool.kvm_lan[0].namespace
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

  depends_on = [data.external.kvm_lan_network_interface]
}
