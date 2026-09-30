# S1 numeric- + S2 string-leaf input validation for xcsh_securemesh_site_v2.
#
# POSITIVE case: valid bounds AND valid mac/ip/CIDR/node-type plan cleanly through the REAL
# provider schema. mock_provider means no XC credentials are needed — the schema (and its
# numeric + string validators) come from whichever release `terraform init` resolved at the exact clean-break version
# in versions.tf, and fire during plan regardless of whether the API is contacted.
# versions.tf is the only tracked pin: do not restate a version in prose here or in
# reject-tests/, or the copies drift (they did, across four releases, until S8).
#
# The out-of-range REJECT cases live in ./reject-tests/reject.tftest.hcl. They cannot be
# asserted with `expect_failures` because Terraform only captures user-defined custom
# conditions there, not provider schema attribute validators (verified: TF 1.15 reports
# "was expected to report an error but did not"). They are instead proven by verify.sh,
# which runs them expecting failure and asserts the exact validator message for each leaf.

mock_provider "xcsh" {}

run "accept_valid_bounds" {
  command = plan

  variables {
    probe_name      = "cov-probe-s1-ok"
    mtu             = 1500                # API v9: 0 or 512-8000
    priority        = 0                   # Between(0, 255)   lower bound
    vlan_id         = 4095                # Between(1, 4095)  upper bound
    proxy_port      = 0                   # Between(0, 65535) lower bound
    mac             = "7C-1E-52-7F-F8-12" # MACValidator()
    node_type       = "Worker"            # OneOf("Control", "Worker") — the non-default valid arm
    ip_address      = "10.0.1.5/24"       # CIDRValidator()
    default_gw      = "10.0.1.1"          # IPValidator()
    vrf_string_arms = true                # render sli_config so the IPv4Validator leaves are reached
    nameserver      = "10.0.2.53"         # IPv4Validator()
    vip             = "10.0.2.100"        # IPv4Validator()
  }

  assert {
    condition     = xcsh_securemesh_site_v2.probe.namespace == "system"
    error_message = "Probe must plan in the system namespace."
  }

  assert {
    condition     = length(xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list) == 2
    error_message = "extended_arms must render both the eth0 and eth0-vlan interfaces so every numeric leaf is reachable."
  }

  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].type == "Worker"
    error_message = "A valid node type (Worker) must pass the OneOf(Control, Worker) validator and plan clean."
  }

  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].static_ip.ip_address == "10.0.1.5/24"
    error_message = "string_arms must render the static_ip block so a valid CIDR ip_address plans clean."
  }

  assert {
    condition     = xcsh_securemesh_site_v2.probe.local_vrf.sli_config.vip == "10.0.2.100"
    error_message = "vrf_string_arms must render sli_config so a valid IPv4 nameserver/vip plans clean through IPv4Validator."
  }
}

# S3 positive plan asserts — each interface oneof arm PLANS cleanly through the real provider
# schema (schema-valid) even where it would 400 live on a single-node `azure` probe. This proves the
# HCL wiring + provider schema accept every arm; the live/plan split is in the matrix.

run "plan_address_no_ipv4" {
  command = plan
  variables {
    probe_name  = "cov-probe-s3-no-ipv4"
    address_arm = "no_ipv4_address"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].no_ipv4_address != null
    error_message = "address_arm=no_ipv4_address must render the no_ipv4_address member of address_choice."
  }
}

run "plan_ipv6_no_ipv6" {
  command = plan
  variables {
    probe_name = "cov-probe-s3-no-ipv6"
    ipv6_arm   = "no_ipv6_address"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].no_ipv6_address != null
    error_message = "ipv6_arm=no_ipv6_address must render the no_ipv6_address member of ipv6_address_choice."
  }
}

run "plan_ipv6_static" {
  command = plan
  variables {
    probe_name = "cov-probe-s3-static-ipv6"
    ipv6_arm   = "static_ipv6_address"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].static_ipv6_address.node_static_ip.ip_address == "2001:db8::10/64"
    error_message = "ipv6_arm=static_ipv6_address must render node_static_ip so a valid IPv6 CIDR plans clean through CIDRValidator."
  }
}

run "plan_ipv6_autoconfig" {
  command = plan
  variables {
    probe_name = "cov-probe-s3-ipv6-auto"
    ipv6_arm   = "ipv6_auto_config"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].ipv6_auto_config.host != null
    error_message = "ipv6_arm=ipv6_auto_config must render the host autoconfig_choice member."
  }
}

run "plan_interface_bond" {
  command = plan
  variables {
    probe_name    = "cov-probe-s3-bond"
    interface_arm = "bond"
  }
  assert {
    condition     = length(xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].bond_interface.devices) == 2
    error_message = "interface_arm=bond must render bond_interface with 2 devices (SizeBetween(1, 8) passes)."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].bond_interface.lacp.rate == 1
    error_message = "bond_interface.lacp.rate must plan clean through Between(1, 30)."
  }
}

run "plan_interface_vlan" {
  command = plan
  variables {
    probe_name    = "cov-probe-s3-vlan-arm"
    interface_arm = "vlan"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].vlan_interface.vlan_id == 100
    error_message = "interface_arm=vlan must render vlan_interface on the primary oneof so vlan_id plans clean through Between(1, 4095)."
  }
}

run "plan_monitor" {
  command = plan
  variables {
    probe_name  = "cov-probe-s3-monitor"
    monitor_arm = "monitor"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].monitor != null
    error_message = "monitor_arm=monitor must render the monitor member of monitoring_choice."
  }
}

run "plan_s2s_enabled" {
  command = plan
  variables {
    probe_name    = "cov-probe-s3-s2s-enabled"
    s2s_iface_arm = "enabled"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.azure.not_managed.node_list[0].interface_list[0].site_to_site_connectivity_interface_enabled != null
    error_message = "s2s_iface_arm=enabled must render the enabled member of site_to_site_connectivity_interface_choice."
  }
}

# S4 positive plan asserts — each networking/services oneof arm PLANS cleanly through the real
# provider schema (schema-valid) whether it is live (S4a) or ref-dependent / single-node-400
# (S4b/S4c). This proves the HCL wiring + provider schema accept every arm; the live/plan
# split is recorded in the matrix.

run "plan_blocked_services" {
  command = plan
  variables {
    probe_name   = "cov-probe-s4-blocked-services"
    services_arm = "blocked_services"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].network_type == "VIRTUAL_NETWORK_SITE_LOCAL"
    error_message = "services_arm=blocked_services must render a blocked_service with the default network_type."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].ssh != null
    error_message = "the default blocked_service_arm=ssh must render the ssh member of service_choice."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].web_user_interface == null && xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].dns == null
    error_message = "exactly ONE service_choice member may render — F5 keeps a single member and silently drops the rest."
  }
}

run "plan_blocked_service_dns" {
  command = plan
  variables {
    probe_name          = "cov-probe-s7-blocked-dns"
    services_arm        = "blocked_services"
    blocked_service_arm = "dns"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].dns != null && xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].ssh == null
    error_message = "blocked_service_arm=dns must render only the dns member of service_choice."
  }
}

run "plan_blocked_service_web_user_interface" {
  command = plan
  variables {
    probe_name          = "cov-probe-s7-blocked-wui"
    services_arm        = "blocked_services"
    blocked_service_arm = "web_user_interface"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].web_user_interface != null && xcsh_securemesh_site_v2.probe.blocked_services.blocked_service[0].ssh == null
    error_message = "blocked_service_arm=web_user_interface must render only the web_user_interface member of service_choice."
  }
}

run "plan_custom_dns_ntp" {
  command = plan
  variables {
    probe_name = "cov-probe-s4-custom-dns-ntp"
    dns_arm    = "custom_dns"
    ntp_arm    = "custom_ntp"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.dns_ntp_config.custom_dns.dns_servers[0] == "8.8.8.8"
    error_message = "dns_arm=custom_dns must render custom_dns.dns_servers."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.dns_ntp_config.custom_ntp.ntp_servers[0] == "216.239.35.0"
    error_message = "ntp_arm=custom_ntp must render custom_ntp.ntp_servers."
  }
}

run "plan_f5_proxy" {
  command = plan
  variables {
    probe_name = "cov-probe-s4-f5-proxy"
    proxy_arm  = "f5_proxy"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.f5_proxy != null
    error_message = "proxy_arm=f5_proxy must render the f5_proxy member of the enterprise_proxy oneof."
  }
}

run "plan_custom_proxy_bypass" {
  command = plan
  variables {
    probe_name       = "cov-probe-s4-proxy-bypass"
    proxy_bypass_arm = "custom_proxy_bypass"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.custom_proxy_bypass.proxy_bypass[0] == "example.com"
    error_message = "proxy_bypass_arm=custom_proxy_bypass must render the proxy_bypass domain list."
  }
}

run "plan_url_categorization" {
  command = plan
  variables {
    probe_name  = "cov-probe-s4-url-cat"
    url_cat_arm = "enable_url_categorization"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.enable_url_categorization != null
    error_message = "url_cat_arm=enable_url_categorization must render the enable member of the url_categorization oneof."
  }
}

run "plan_vip_vrrp" {
  command = plan
  variables {
    probe_name    = "cov-probe-s4-vip-vrrp"
    vip_vrrp_mode = "VIP_VRRP_ENABLE"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.load_balancing.vip_vrrp_mode == "VIP_VRRP_ENABLE"
    error_message = "vip_vrrp_mode=VIP_VRRP_ENABLE must render load_balancing with the valid enum plan-clean through OneOf."
  }
}

run "plan_site_mesh_group_empty" {
  command = plan
  variables {
    probe_name  = "cov-probe-s4-smg-empty"
    s2s_slo_arm = "site_mesh_group_empty"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.site_mesh_group_on_slo.no_site_mesh_group != null
    error_message = "s2s_slo_arm=site_mesh_group_empty must render no_site_mesh_group + sm_connection_public_ip."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.site_mesh_group_on_slo.sm_connection_public_ip != null
    error_message = "site_mesh_group_empty must render the sm_connection_public_ip connection member."
  }
}

run "plan_enable_ha" {
  command = plan
  variables {
    probe_name = "cov-probe-s4-enable-ha"
    ha_arm     = "enable_ha"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.enable_ha != null
    error_message = "ha_arm=enable_ha must render the enable_ha member of the node_ha oneof (plan-only; 400 on single node)."
  }
}

run "plan_enable_management_network" {
  command = plan
  variables {
    probe_name   = "cov-probe-s4-enable-mgmt"
    mgmt_net_arm = "enable_management_network"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.enable_management_network != null
    error_message = "mgmt_net_arm=enable_management_network must render the enable member (plan-only; 400 on single node)."
  }
}

run "plan_active_forward_proxy_policies" {
  command = plan
  variables {
    probe_name        = "cov-probe-s4-fwd-proxy-pol"
    forward_proxy_arm = "active_forward_proxy_policies"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.active_forward_proxy_policies.forward_proxy_policies[0].name == "cov-forward-proxy-policy"
    error_message = "forward_proxy_arm=active_forward_proxy_policies must render the ref list (plan-only; ref-dependent)."
  }
}

run "plan_active_enhanced_firewall_policies" {
  command = plan
  variables {
    probe_name         = "cov-probe-s4-efw-pol"
    network_policy_arm = "active_enhanced_firewall_policies"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.active_enhanced_firewall_policies.enhanced_firewall_policies[0].name == "cov-enhanced-firewall-policy"
    error_message = "network_policy_arm=active_enhanced_firewall_policies must render the ref list (plan-only; ref-dependent)."
  }
}

run "plan_log_receiver_with_net" {
  command = plan
  variables {
    probe_name = "cov-probe-s4-log-recv"
    logs_arm   = "log_receiver_with_net"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.log_receiver_with_net.log_receiver.name == "cov-log-receiver"
    error_message = "logs_arm=log_receiver_with_net must render the network-aware log receiver ref (plan-only; ref-dependent)."
  }
}

run "plan_dc_cluster_group_sli" {
  command = plan
  variables {
    probe_name  = "cov-probe-s4-dccg-sli"
    s2s_sli_arm = "dc_cluster_group_sli"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.dc_cluster_group_sli.name == "cov-dc-cluster-group-sli"
    error_message = "s2s_sli_arm=dc_cluster_group_sli must render the ObjectRefType (plan-only; ref-dependent)."
  }
}

run "plan_dc_cluster_group_slo" {
  command = plan
  variables {
    probe_name  = "cov-probe-s4-dccg-slo"
    s2s_slo_arm = "dc_cluster_group_slo"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.dc_cluster_group_slo.name == "cov-dc-cluster-group-slo"
    error_message = "s2s_slo_arm=dc_cluster_group_slo must render the ObjectRefType (plan-only; ref-dependent)."
  }
}

run "plan_site_mesh_group_ref" {
  command = plan
  variables {
    probe_name  = "cov-probe-s4-smg-ref"
    s2s_slo_arm = "site_mesh_group_ref"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.site_mesh_group_on_slo.site_mesh_group.name == "cov-site-mesh-group"
    error_message = "s2s_slo_arm=site_mesh_group_ref must render the site_mesh_group ObjectRefType (plan-only; ref-dependent)."
  }
}

run "plan_segment_vrf" {
  command = plan
  variables {
    probe_name      = "cov-probe-s4-segment-vrf"
    segment_vrf_arm = "inline"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.segment_vrf[0].segment_config.nameserver == "10.0.3.53"
    error_message = "segment_vrf_arm=inline must render segment_config.nameserver plan-clean through IPv4Validator (plan-only; api-specs-enriched #1053)."
  }
}

# S5 positive plan asserts — each site-mode oneof alternative arm PLANS cleanly through the real
# provider schema (schema-valid) whether it is live (S5a) or single-node-400 (S5b). This proves
# the HCL wiring + schema accept every arm; the live/plan split is recorded in the matrix.

run "plan_perf_l3_enhanced" {
  command = plan
  variables {
    probe_name = "cov-probe-s5-perf-l3"
    perf_arm   = "perf_mode_l3_enhanced"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l3_enhanced.no_jumbo != null && xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l3_enhanced.jumbo == null
    error_message = "perf_arm=perf_mode_l3_enhanced (l3_jumbo_arm default) must render only the no_jumbo member of the perf_mode_l3_enhanced jumbo sub-oneof."
  }
}

run "plan_l3_jumbo_enabled" {
  command = plan
  variables {
    probe_name   = "cov-probe-s8-l3-jumbo"
    perf_arm     = "perf_mode_l3_enhanced"
    l3_jumbo_arm = "jumbo"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l3_enhanced.jumbo != null && xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l3_enhanced.no_jumbo == null
    error_message = "l3_jumbo_arm=jumbo must render only the jumbo member of the perf_mode_l3_enhanced jumbo sub-oneof."
  }
}

run "plan_l7_jumbo_enabled" {
  command = plan
  variables {
    probe_name   = "cov-probe-s7-l7-jumbo-enabled"
    l7_jumbo_arm = "jumbo_enabled"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l7_enhanced.jumbo_enabled != null && xcsh_securemesh_site_v2.probe.performance_enhancement_mode.perf_mode_l7_enhanced.jumbo_disabled == null
    error_message = "l7_jumbo_arm=jumbo_enabled must render only the jumbo_enabled member of the perf_mode_l7_enhanced jumbo sub-oneof."
  }
}

run "plan_os_sw_pinned" {
  command = plan
  variables {
    probe_name = "cov-probe-s5-os-sw"
    os_arm     = "operating_system_version"
    sw_arm     = "volterra_software_version"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.software_settings.os.operating_system_version == "9.2024.6"
    error_message = "os_arm=operating_system_version must render the pinned OS version plan-clean through LengthAtMost(20)."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.software_settings.sw.volterra_software_version == "crt-20250613-3382"
    error_message = "sw_arm=volterra_software_version must render the pinned SW version plan-clean through LengthAtMost(20)."
  }
}

run "plan_offline_enable" {
  command = plan
  variables {
    probe_name  = "cov-probe-s5-offline"
    offline_arm = "enable_offline_survivability_mode"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.offline_survivability_mode.enable_offline_survivability_mode != null
    error_message = "offline_arm=enable_offline_survivability_mode must render the enable member of offline_survivability_mode."
  }
}

run "plan_specific_re" {
  command = plan
  variables {
    probe_name    = "cov-probe-s5-specific-re"
    re_select_arm = "specific_re"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.re_select.specific_re.primary_re == "cov-primary-re"
    error_message = "re_select_arm=specific_re must render primary_re plan-clean through LengthBetween(1, 64) (plan-only S5b)."
  }
}

run "plan_upgrade_drain_enable" {
  command = plan
  variables {
    probe_name        = "cov-probe-s5-drain"
    upgrade_drain_arm = "enable_upgrade_drain"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain.drain_node_timeout == 300
    error_message = "upgrade_drain_arm=enable_upgrade_drain must render drain_node_timeout plan-clean through Between(0, 900) (plan-only S5b)."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.upgrade_settings.kubernetes_upgrade_drain.enable_upgrade_drain.disable_vega_upgrade_mode != null
    error_message = "vega_arm default must render the disable_vega_upgrade_mode sub-oneof member."
  }
}

run "plan_upgrade_drain_disable" {
  command = plan
  variables {
    probe_name        = "cov-probe-s5-drain-disable"
    upgrade_drain_arm = "disable_upgrade_drain"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.upgrade_settings.kubernetes_upgrade_drain.disable_upgrade_drain != null
    error_message = "upgrade_drain_arm=disable_upgrade_drain must render the disable_upgrade_drain member of kubernetes_upgrade_drain."
  }
}

run "plan_admin_user_credentials" {
  command = plan
  variables {
    probe_name  = "cov-probe-s5-admin"
    admin_creds = true
  }
  assert {
    condition     = xcsh_securemesh_site_v2.probe.admin_user_credentials.ssh_key != null
    error_message = "admin_creds=true must render the ssh_key leaf (LengthAtMost(8192))."
  }
  assert {
    condition     = startswith(xcsh_securemesh_site_v2.probe.admin_user_credentials.admin_password.clear_secret_info.url, "string:///")
    error_message = "admin_password.clear_secret_info.url must be a string:/// dummy-secret URL (dependency-free backend)."
  }
}

run "accept_mtu_api_v9_maximum" {
  command = plan
  variables {
    mtu = 8000
  }
}

run "accept_mtu_api_v9_zero" {
  command = plan
  variables {
    mtu = 0
  }
}
