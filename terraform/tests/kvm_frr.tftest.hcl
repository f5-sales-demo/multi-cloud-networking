# KVM CE BGP fabric: assert the plan owns stable tenant identities and the
# router that peers with them.  This is a mock-only graph test; the live image
# URL and Sales Demo tenant prerequisite are deliberately exercised separately.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "docker" {}
mock_provider "libvirt" {}

variables {
  site_prefix            = null
  lb_name                = null
  origin_pool_name       = null
  route_server_name      = null
  bastion_name           = null
  client_vm_name         = null
  region_short           = null
  resource_group_name    = null
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  deployer               = "tester"
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l kvm-plan-test-only"
  xc_app_namespace       = "multi-cloud-networking"
  enable_azure           = false
  enable_canada          = false
  enable_aws             = false
  enable_aws_tgw_connect = false
  enable_bgp             = false
  enable_kvm             = true
}

run "kvm_frr_and_ce_identity_plan" {
  command = plan

  assert {
    condition     = output.kvm_bgp_fabric.router_ip == "10.100.0.2"
    error_message = "KVM BGP must use the dedicated FRR router identity, not the libvirt bridge gateway."
  }

  assert {
    condition = output.kvm_bgp_fabric.ce_addresses == {
      "01" = "10.100.0.11"
    }
    error_message = "KVM CE addresses must be a stable one-to-one mapping, independent of DHCP lease order."
  }

  assert {
    condition     = length(libvirt_domain.ce_node) == 1
    error_message = "The KVM showcase must create exactly one production-sized CE domain."
  }

  assert {
    condition = (
      libvirt_domain.ce_node["01"].memory == 32768 &&
      libvirt_domain.ce_node["01"].vcpu == 8 &&
      libvirt_domain.ce_node["01"].cpu[0].mode == "host-passthrough" &&
      libvirt_volume.ce_disk["01"].size == 85899345920
    )
    error_message = "The KVM CE must use the reviewed 32 GiB, 8-vCPU host-passthrough, 80 GiB runtime shape."
  }

  assert {
    condition = (
      xcsh_token.kvm[0].type == 1 &&
      xcsh_token.kvm[0].site_name == xcsh_securemesh_site_v2.onprem_kvm[0].name &&
      data.xcsh_site_image.kvm[0].site_name == xcsh_securemesh_site_v2.onprem_kvm[0].name &&
      data.xcsh_site_cloud_init.kvm[0].provider_ref == "kvm" &&
      data.xcsh_site_cloud_init.kvm[0].site_name == xcsh_securemesh_site_v2.onprem_kvm[0].name
    )
    error_message = "KVM must use a site-bound JWT and resolve both the image and cloud-init template by its exact SMSv2 site."
  }

  assert {
    condition = (
      length(xcsh_token.ce) == 0 &&
      output.registration_token_name == null &&
      output.registration_token_is_generated == false
    )
    error_message = "KVM-only plans must not create the shared Azure registration token."
  }

  assert {
    condition = (
      docker_network.kvm_frr[0].driver == "macvlan" &&
      docker_network.kvm_frr[0].options.parent == local.kvm_network_bridge &&
      contains([for network in docker_container.kvm_frr[0].networks_advanced : network.ipv4_address], "10.100.0.2")
    )
    error_message = "FRR must be Terraform-owned on the KVM bridge at the declared peer IP."
  }

  assert {
    condition     = xcsh_bgp.onprem_ebgp[0].peers[0].external.address == output.kvm_bgp_fabric.router_ip
    error_message = "The F5-side KVM BGP object must peer with the Terraform-owned FRR router."
  }

  assert {
    condition     = length(data.external.kvm_network_interface) == 1
    error_message = "KVM BGP must have exactly one deferred live XC network_interface discovery."
  }

  assert {
    condition     = xcsh_securemesh_site_v2.onprem_kvm[0].name == "mcn-ce-ha-smsv2-kvm"
    error_message = "KVM must use the released SMSv2 identity generation, not the legacy onprem-kvm-site name."
  }

  assert {
    condition = (
      xcsh_securemesh_site_v2.onprem_kvm[0].disable_ha != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].enable_ha == null
    )
    error_message = "The one-node KVM site must disable HA so XC generates a one-node registration configuration."
  }

  assert {
    condition = try(
      xcsh_securemesh_site_v2.onprem_kvm[0].dns_ntp_config.f5_dns_default != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].dns_ntp_config.f5_ntp_default != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].local_vrf.default_config != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].local_vrf.default_sli_config != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].performance_enhancement_mode.perf_mode_l7_enhanced.jumbo_disabled != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].offline_survivability_mode.no_offline_survivability_mode != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].re_select.geo_proximity != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].load_balancing.vip_vrrp_mode == "VIP_VRRP_ENABLE" &&
      xcsh_securemesh_site_v2.onprem_kvm[0].software_settings.os.default_os_version != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].software_settings.sw.default_sw_version != null &&
      xcsh_securemesh_site_v2.onprem_kvm[0].upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain.drain_node_timeout == 300 &&
      xcsh_securemesh_site_v2.onprem_kvm[0].upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain.drain_max_unavailable_node_count == 1 &&
      xcsh_securemesh_site_v2.onprem_kvm[0].upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain.disable_vega_upgrade_mode != null,
      false,
    )
    error_message = "KVM SMSv2 must declare the supported Console defaults used by a successful Secure Mesh installation."
  }
}

run "kvm_disabled_skips_the_image_lookup_and_plans_no_kvm_resources" {
  command = plan

  variables {
    enable_kvm = false
  }

  assert {
    condition     = length(data.xcsh_site_image.kvm) == 0
    error_message = "Disabling KVM must skip the tenant image data source so a KVM-only destroy is not blocked by image availability."
  }

  assert {
    condition = (
      length(libvirt_network.ce_bgp_net) == 0 &&
      length(libvirt_volume.base_cloud) == 0 &&
      length(libvirt_domain.ce_node) == 0 &&
      length(docker_container.kvm_frr) == 0 &&
      length(xcsh_securemesh_site_v2.onprem_kvm) == 0 &&
      length(xcsh_bgp.onprem_ebgp) == 0 &&
      output.kvm_bgp_fabric == null
    )
    error_message = "Disabling KVM must make the plan an ownership-verified KVM teardown without leaving a router or F5 site behind."
  }
}
