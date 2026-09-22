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

  software_settings {
    os {
      default_os_version = {}
    }
    sw {
      volterra_software_version = var.software_version
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
  source = "../kvm-registration-mapping"

  enforce              = var.enable_kvm && var.acceptance_phase == "configured"
  registration_records = local.kvm_registration_records
  ce_nodes             = local.kvm_ce_nodes
}

data "xcsh_site_bgp_status" "kvm" {
  count = var.enable_kvm && var.acceptance_phase == "configured" ? 1 : 0

  namespace                = "system"
  site                     = xcsh_securemesh_site_v2.onprem_kvm[0].name
  expected_exported_routes = []
  expected_peers           = local.kvm_expected_bgp_peers
  timeout_seconds          = 1800
  poll_interval_seconds    = 10

  depends_on = [
    module.kvm_registration_mapping,
    xcsh_registration_approval.kvm,
    xcsh_bgp.onprem_ebgp,
    docker_container.kvm_frr,
  ]
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
        name      = "eth0"
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
    docker_container.kvm_frr,
    libvirt_domain.ce_node,
  ]
}
