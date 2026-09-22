# On-Prem KVM SecureMesh Site v2
resource "xcsh_securemesh_site_v2" "onprem_kvm" {
  count = var.enable_kvm ? 1 : 0

  name        = local.kvm_site_name
  namespace   = "system"
  description = "On-Prem KVM SecureMesh Site v2"
  labels      = local.kvm_xc_labels

  kvm {
    not_managed {}
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

  # Match the non-AppStack SMSv2 Console defaults during first-boot software
  # installation. Provider v9.5.1 does not expose software_settings.waf_signatures;
  # every supported default from the Console-created KVM object is explicit here.
  dns_ntp_config {
    f5_dns_default = {}
    f5_ntp_default = {}
  }

  local_vrf {
    default_config     = {}
    default_sli_config = {}
  }

  offline_survivability_mode {
    no_offline_survivability_mode = {}
  }

  performance_enhancement_mode {
    perf_mode_l7_enhanced {
      jumbo_disabled = {}
    }
  }

  re_select {
    geo_proximity = {}
  }

  load_balancing {
    vip_vrrp_mode = "VIP_VRRP_ENABLE"
  }

  software_settings {
    os {
      default_os_version = {}
    }
    sw {
      volterra_software_version = var.kvm_software_version
    }
  }

  upgrade_settings {
    kubernetes_upgrade_drain {
      enable_upgrade_drain {
        drain_node_timeout               = 300
        drain_max_unavailable_node_count = 1
        disable_vega_upgrade_mode        = {}
      }
    }
  }
}

# A KVM CE must never consume the generic tenant token. The issued JWT is
# cryptographically bound to this exact SMSv2 site and inserted only into the
# console-provided cloud-init template.
resource "xcsh_token" "kvm" {
  count = var.enable_kvm ? 1 : 0

  name        = "${local.kvm_site_name}-registration"
  namespace   = "system"
  description = "Site-bound JWT for KVM SecureMesh site ${local.kvm_site_name}"
  labels      = local.kvm_xc_labels
  type        = 1
  site_name   = xcsh_securemesh_site_v2.onprem_kvm[0].name

  lifecycle {
    replace_triggered_by = [xcsh_securemesh_site_v2.onprem_kvm[0]]
  }
}

data "xcsh_site_registration" "kvm" {
  for_each = local.kvm_enabled_nodes

  site_name = local.kvm_site_name
  hostname  = "onprem-ce-${each.key}"
  namespace = "system"

}

resource "xcsh_registration_approval" "kvm" {
  for_each = {
    for key, registration in data.xcsh_site_registration.kvm :
    key => registration if registration.found && registration.state == "NEW"
  }

  namespace    = "system"
  name         = each.value.name
  cluster_size = 1
  state        = "APPROVED"

  depends_on = [xcsh_securemesh_site_v2.onprem_kvm]
}

data "xcsh_site_registrations_by_site" "kvm" {
  count = var.enable_kvm ? 1 : 0

  namespace = "system"
  site_name = local.kvm_site_name
}

locals {
  kvm_registration_records = var.enable_kvm ? flatten([
    for item in coalesce(try(data.xcsh_site_registrations_by_site.kvm[0].items, null), []) : [
      for network in try(item.get_spec.infra.hw_info.network, []) : {
        hostname = try(item.get_spec.infra.hostname, "")
        provider = try(item.get_spec.infra.provider_ref, "")
        mac      = lower(try(network.mac_address, ""))
      }
    ]
  ]) : []
  kvm_registration_mapping_valid = !var.enable_kvm || module.kvm_registration_mapping.mapping_valid
  kvm_expected_bgp_peers = (
    var.enable_kvm && module.kvm_registration_mapping.mapping_valid ?
    module.kvm_registration_mapping.expected_bgp_peers : {}
  )
}

module "kvm_registration_mapping" {
  source = "./modules/kvm-registration-mapping"

  enforce              = var.enable_kvm && var.aws_site_configuration_phase == "configured"
  registration_records = local.kvm_registration_records
  ce_nodes             = local.kvm_ce_nodes
}

# XC assigns a fresh node suffix and network_interface object name on every CE
# registration. Resolve that object from live ownership plus the exact observed
# KVM MAC; neither the Linux device name nor the XC object name is guessed.
data "external" "kvm_network_interface" {
  count = var.enable_kvm ? 1 : 0

  program = ["python3", "${path.module}/scripts/xc-kvm-network-interface.py"]
  query = {
    api_url               = local.xc_api_url
    namespace             = "system"
    site_name             = xcsh_securemesh_site_v2.onprem_kvm[0].name
    expected_mac          = local.kvm_ce_nodes["01"].mac
    timeout_seconds       = "7200"
    poll_interval_seconds = "10"
    resolver_sha256       = filesha256("${path.module}/scripts/xc-kvm-network-interface.py")
  }

  depends_on = [libvirt_domain.ce_node]

  lifecycle {
    postcondition {
      condition = (
        self.result.interface_name != "" &&
        self.result.hostname != "" &&
        self.result.device != "" &&
        lower(self.result.mac) == lower(local.kvm_ce_nodes["01"].mac)
      )
      error_message = "KVM BGP requires one live XC network_interface correlated by current site ownership, observed registration hostname/device, and the Terraform-owned CE MAC."
    }
  }
}

# The provider convergence data source intentionally requires a nonempty
# exported-route expectation. This KVM proof has one imported lab prefix but no
# exported prefix, so observe only the bounded facts that actually exist.
data "external" "kvm_bgp_observer" {
  count = var.enable_kvm && var.aws_site_configuration_phase == "configured" ? 1 : 0

  program = ["python3", "${path.module}/scripts/xc-kvm-bgp-observer.py"]
  query = {
    api_url                 = local.xc_api_url
    namespace               = "system"
    site_name               = xcsh_securemesh_site_v2.onprem_kvm[0].name
    expected_node           = try(local.kvm_expected_bgp_peers["node_01_slo"].node, "")
    expected_peer_address   = try(local.kvm_expected_bgp_peers["node_01_slo"].peer_address, "")
    expected_imported_route = try(one(local.kvm_expected_bgp_peers["node_01_slo"].expected_imported_routes), "")
    timeout_seconds         = "1800"
    poll_interval_seconds   = "10"
    observer_sha256         = filesha256("${path.module}/scripts/xc-kvm-bgp-observer.py")
  }

  depends_on = [
    module.kvm_registration_mapping,
    xcsh_registration_approval.kvm,
    xcsh_bgp.onprem_ebgp,
    docker_container.kvm_frr,
  ]

  lifecycle {
    postcondition {
      condition = (
        self.result.converged == "true" &&
        self.result.registered_node == try(local.kvm_expected_bgp_peers["node_01_slo"].node, "") &&
        self.result.peer_address == "10.100.0.2" &&
        self.result.state == "Established" &&
        self.result.imported_route == "198.51.100.0/24"
      )
      error_message = "KVM BGP requires the exact registered node, one Established 10.100.0.2 peer, and imported route 198.51.100.0/24."
    }
  }
}

# eBGP Peering configuration for On-Prem KVM Site
resource "xcsh_bgp" "onprem_ebgp" {
  count = var.enable_kvm ? 1 : 0

  name      = "onprem-kvm-ebgp"
  namespace = "system"
  labels    = local.kvm_xc_labels

  where {
    site {
      network_type = "VIRTUAL_NETWORK_SITE_LOCAL"
      ref {
        name      = xcsh_securemesh_site_v2.onprem_kvm[0].name
        namespace = "system"
      }
      disable_internet_vip = {}
    }
  }

  bgp_parameters {
    asn           = 64512
    local_address = {}
  }

  peers {
    metadata {
      name = "peer-router"
    }
    external {
      asn     = 65515
      address = "10.100.0.2"
      port    = 179

      interface {
        name      = data.external.kvm_network_interface[0].result.interface_name
        namespace = "system"
      }

      disable_v6 = {}
    }
    passive_mode_disabled = {}
    bfd_disabled          = {}
  }

  lifecycle {
    replace_triggered_by = [xcsh_securemesh_site_v2.onprem_kvm[0]]
  }

  # Do not redirect the F5-side peer until both the Terraform-owned router and
  # the CE interfaces with the declared static identities are ready.
  depends_on = [
    data.external.kvm_network_interface,
    docker_container.kvm_frr,
    libvirt_domain.ce_node,
  ]
}
