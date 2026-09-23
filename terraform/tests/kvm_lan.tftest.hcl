# KVM LAN/SLI is an explicit staged opt-in. Mock plans prove the default
# remains unchanged and the final topology is fully declared before live use.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "docker" {}
mock_provider "libvirt" {}

variables {
  source_repository      = "f5-sales-demo/multi-cloud-networking"
  source_ref             = "refs/heads/main"
  source_commit_sha      = "1111111111111111111111111111111111111111"
  deployment_owner_id    = "sales-demo-team"
  deployment_actor_id    = "terraform-automation"
  site_prefix            = null
  smsv2_site_generation  = "smsv2"
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
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l kvm-lan-plan-test-only"
  xc_app_namespace       = "multi-cloud-networking"
  enable_azure           = false
  enable_canada          = false
  enable_aws             = false
  enable_aws_tgw_connect = false
  enable_bgp             = false
  enable_kvm             = true
}

run "lan_disabled_preserves_the_single_slo_topology" {
  command = plan

  assert {
    condition = (
      var.enable_kvm_lan == false &&
      length(libvirt_domain.ce_node["01"].network_interface) == 1 &&
      length(xcsh_virtual_site.kvm_lan) == 0 &&
      length(xcsh_origin_pool.kvm_lan) == 0 &&
      length(xcsh_http_loadbalancer.kvm_lan) == 0
    )
    error_message = "KVM LAN must default off without changing the released one-SLO topology."
  }
}

run "hardware_phase_declares_the_second_nic_only" {
  command = plan

  variables {
    enable_kvm_lan              = true
    kvm_lan_configuration_phase = "hardware"
    kvm_lan = {
      bridge                      = "br-lan-demo"
      uplink                      = "enp2s0"
      uplink_mac                  = "02:00:00:00:10:01"
      ownership                   = "preprovisioned-shared"
      vlan_mode                   = "access"
      vlan_id                     = null
      mtu                         = 1500
      sli_mac                     = "52:54:00:20:00:11"
      sli_cidr                    = "192.0.2.2/24"
      vip                         = "192.0.2.10"
      vip_reservation             = "lab-ipam-1227"
      backend_ip                  = "192.0.2.20"
      backend_port                = 8080
      backend_owner               = "lab-origin"
      http_domain                 = "app.example.com"
      access_scope                = "authorized-lab-lan"
      bridge_preprovisioned       = true
      uplink_approved             = true
      ipv4_users_reviewed         = true
      ipv6_users_reviewed         = true
      switch_multi_mac_approved   = true
      duplicate_addresses_checked = true
    }
  }

  assert {
    condition = (
      length(libvirt_domain.ce_node["01"].network_interface) == 2 &&
      libvirt_domain.ce_node["01"].network_interface[0].mac == "52:54:00:10:00:11" &&
      libvirt_domain.ce_node["01"].network_interface[1].bridge == "br-lan-demo" &&
      libvirt_domain.ce_node["01"].network_interface[1].mac == "52:54:00:20:00:11" &&
      length(xcsh_virtual_site.kvm_lan) == 0 &&
      length(xcsh_origin_pool.kvm_lan) == 0 &&
      length(xcsh_http_loadbalancer.kvm_lan) == 0
    )
    error_message = "Hardware phase must preserve SLO-first ordering and defer XC LAN exposure."
  }
}

run "configured_phase_adopts_and_changes_only_the_runtime_sli" {
  command = plan

  override_data {
    target          = data.xcsh_smsv2_kvm_runtime.kvm_slo[0]
    override_during = plan
    values = {
      interface_name     = "ves-io-securemesh-site-v2-test-network-onprem-ce-01-674f7-ens3-0"
      hostname           = "onprem-ce-01-674f7"
      device             = "ens3"
      mac                = "52:54:00:10:00:11"
      online             = true
      registration_state = "ONLINE"
    }
  }

  override_resource {
    target          = xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"]
    override_during = plan
    values = {
      namespace      = "system"
      site           = "test"
      expected_mac   = "52:54:00:20:00:11"
      ipv4_cidr      = "192.0.2.2/24"
      interface_name = "ves-io-securemesh-site-v2-test-network-onprem-ce-01-674f7-ens4-0"
      hostname       = "onprem-ce-01-674f7"
      device         = "ens4"
      configured     = true
    }
  }

  variables {
    enable_kvm_lan              = true
    kvm_lan_configuration_phase = "configured"
    kvm_lan = {
      bridge                      = "br-lan-demo"
      uplink                      = "enp2s0"
      uplink_mac                  = "02:00:00:00:10:01"
      ownership                   = "preprovisioned-shared"
      vlan_mode                   = "access"
      vlan_id                     = null
      mtu                         = 1500
      sli_mac                     = "52:54:00:20:00:11"
      sli_cidr                    = "192.0.2.2/24"
      vip                         = "192.0.2.10"
      vip_reservation             = "lab-ipam-1227"
      backend_ip                  = "192.0.2.20"
      backend_port                = 8080
      backend_owner               = "lab-origin"
      http_domain                 = "app.example.com"
      access_scope                = "authorized-lab-lan"
      bridge_preprovisioned       = true
      uplink_approved             = true
      ipv4_users_reviewed         = true
      ipv6_users_reviewed         = true
      switch_multi_mac_approved   = true
      duplicate_addresses_checked = true
    }
  }

  assert {
    condition = (
      length(xcsh_virtual_site.kvm_lan) == 1 &&
      xcsh_virtual_site.kvm_lan[0].site_type == "CUSTOMER_EDGE" &&
      length(xcsh_virtual_site.kvm_lan[0].site_selector.expressions) == 1 &&
      one(xcsh_virtual_site.kvm_lan[0].site_selector.expressions) == "ves.io/siteName in (${xcsh_securemesh_site_v2.onprem_kvm[0].name})" &&
      xcsh_origin_pool.kvm_lan[0].port == 8080 &&
      length(xcsh_http_loadbalancer.kvm_lan[0].domains) == 1 &&
      one(xcsh_http_loadbalancer.kvm_lan[0].domains) == "app.example.com" &&
      length(libvirt_domain.ce_node) == 1 &&
      length(libvirt_domain.ce_node["01"].network_interface) == 2 &&
      libvirt_domain.ce_node["01"].network_interface[0].mac == "52:54:00:10:00:11" &&
      libvirt_domain.ce_node["01"].network_interface[1].mac == "52:54:00:20:00:11" &&
      length(xcsh_securemesh_site_v2.onprem_kvm[0].kvm.not_managed.node_list) == 0 &&
      length(xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli) == 1 &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].namespace == "system" &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].site == local.kvm_site_name &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].expected_mac == "52:54:00:20:00:11" &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].ipv4_cidr == "192.0.2.2/24" &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].device == "ens4" &&
      xcsh_smsv2_kvm_runtime_interface.kvm_lan_sli["sli"].configured &&
      length(xcsh_bgp.onprem_ebgp) == 1 &&
      xcsh_http_loadbalancer.kvm_lan[0].http.port == 80 &&
      xcsh_http_loadbalancer.kvm_lan[0].advertise_custom.advertise_where[0].port == 80 &&
      xcsh_http_loadbalancer.kvm_lan[0].advertise_custom.advertise_where[0].virtual_site_with_vip.ip == "192.0.2.10" &&
      xcsh_http_loadbalancer.kvm_lan[0].advertise_custom.advertise_where[0].virtual_site_with_vip.network == "SITE_NETWORK_SPECIFIED_VIP_INSIDE"
    )
    error_message = "Configured KVM LAN must leave the site payload empty, adopt only the exact runtime SLI child, and bind the exact site to the inside VIP and real LAN origin."
  }
}

run "configured_phase_rejects_missing_lan_contract" {
  command = plan

  variables {
    enable_kvm_lan              = true
    kvm_lan_configuration_phase = "configured"
  }

  expect_failures = [check.kvm_lan_prerequisites, check.kvm_lan_phase_contract]
}
