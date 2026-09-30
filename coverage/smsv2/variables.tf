variable "probe_name" {
  description = "Throwaway SMSv2 site name (fresh per run to avoid duplicate-StatusObject 500)."
  type        = string
  default     = "cov-probe-01"
}

variable "mtu" {
  description = "SLO interface MTU. Provider API v9 validator: 0 or 512-8000. The gate proves both inclusive bounds and rejects out-of-range values."
  type        = number
  default     = 1500
}

variable "priority" {
  description = "eth0 interface priority. Provider validator: Between(0, 255). S1 pushes >255 to prove rejection."
  type        = number
  default     = 10
}

variable "vlan_id" {
  description = "vlan_interface VLAN tag. Provider validator: Between(1, 4095). S1 pushes >4095 to prove rejection."
  type        = number
  default     = 100
}

variable "proxy_port" {
  description = "custom_proxy port. Provider validator: Between(0, 65535). S1 pushes >65535 to prove rejection."
  type        = number
  default     = 8080
}

variable "mac" {
  description = "eth0 ethernet_interface MAC. Provider validator: `MACValidator()`. S2 pushes \"not-a-mac\" to prove rejection. Wired only when string_arms=true."
  type        = string
  default     = "7C-1E-52-7F-F8-12"
}

variable "node_type" {
  description = "node_list[].type. Provider validator: `OneOf(\"Control\", \"Worker\")`. S2 pushes \"Bogus\" to prove rejection. Always wired (valid default keeps the base probe live-appliable)."
  type        = string
  default     = "Control"
}

variable "ip_address" {
  description = "static_ip.ip_address (CIDR). Provider validator: `CIDRValidator()`. S2 pushes \"999.999.0.0/8\" to prove rejection. Rendered only when string_arms=true."
  type        = string
  default     = "10.0.1.5/24"
}

variable "default_gw" {
  description = "static_ip.default_gw (plain IP). Provider validator: `IPValidator()`. Rendered only when string_arms=true."
  type        = string
  default     = "10.0.1.1"
}

variable "nameserver" {
  description = "local_vrf.sli_config.nameserver (plain IPv4). Provider validator: `IPv4Validator()`. S2 pushes an invalid IPv4 to prove rejection. Rendered only when vrf_string_arms=true."
  type        = string
  default     = "10.0.2.53"
}

variable "vip" {
  description = "local_vrf.sli_config.vip (plain IPv4). Provider validator: `IPv4Validator()`. Rendered only when vrf_string_arms=true."
  type        = string
  default     = "10.0.2.100"
}

variable "vrf_string_arms" {
  description = <<-EOT
    When true, the probe renders an additional `local_vrf.sli_config` block exposing the
    `nameserver` and `vip` leaves so the `IPv4Validator()` string validator is reachable at PLAN
    time. Default false: `sli_config` is a distinct `local_vrf` oneof arm from the proven base
    `default_sli_config{}`, so it is NOT live-applied here (it would collide with the base VRF arm,
    an S3 oneof-coverage concern). Set true only under mock_provider tests, where the schema
    validator fires at plan without contacting the API.
  EOT
  type        = bool
  default     = false
}

variable "string_arms" {
  description = <<-EOT
    When true (default), the probe wires the eth0 `ethernet_interface.mac` leaf so the
    `MACValidator()` string validator is reachable at PLAN time (it fires during plan under both
    mock_provider tests and live plans). Set false only for a live apply if the XC API rejects the
    `mac` value on the single-node `azure` not_managed probe: the eth0 `ethernet_interface` then
    renders with no `mac`, which applies live and stays idempotent/import-clean, while `mac` remains
    plan-validated. Applies only when `interface_arm = "ethernet"` (the `mac` leaf lives on the
    ethernet arm). The node `type` leaf is always wired (its valid default is live-safe).

    NOTE (S3): the address_choice oneof (`dhcp_client`/`static_ip`/`no_ipv4_address`) is now driven
    by `var.address_arm`, not this toggle — so exactly one address member ever renders. The
    `static_ip` leaves (`ip_address`/`default_gw`) are reached at plan whenever `address_arm =
    "static_ip"` (the default), decoupled from `string_arms`.
  EOT
  type        = bool
  default     = true
}

# --- S3: interface / addressing oneof selectors --------------------------------------------------
# Each interface oneof is modeled as an enum selector so exactly ONE member renders and no two
# siblings of a oneof ever coexist (which would trip the provider's ConflictsWith). Defaults are
# the live-safe base arm so a bare `terraform apply` stays idempotent and import-clean.

variable "interface_arm" {
  description = <<-EOT
    interface_choice oneof member for eth0. `ethernet` (default) is the live-safe base arm and
    carries the `mac` leaf (via `string_arms`). `bond` and `vlan` 400 on a single-node `azure`
    not_managed probe (bond needs real member devices; vlan needs a parent device) so they are
    plan-only — their schema (bond `devices` `SizeBetween(1, 8)`, vlan `vlan_id` `Between(1, 4095)`)
    is proven at PLAN.
  EOT
  type        = string
  default     = "ethernet"
  validation {
    condition     = contains(["ethernet", "bond", "vlan"], var.interface_arm)
    error_message = "interface_arm must be ethernet | bond | vlan."
  }
}

variable "address_arm" {
  description = <<-EOT
    address_choice oneof member for eth0. `static_ip` (default) and `dhcp_client` and
    `no_ipv4_address` are all live-appliable. `static_ip` exposes the `ip_address` `CIDRValidator()`
    and `default_gw` `IPValidator()` leaves at PLAN; `dhcp_client`/`no_ipv4_address` are empty
    markers. Exactly one address member renders (supersedes the old `string_arms` address swap).
  EOT
  type        = string
  default     = "static_ip"
  validation {
    condition     = contains(["dhcp_client", "static_ip", "no_ipv4_address"], var.address_arm)
    error_message = "address_arm must be dhcp_client | static_ip | no_ipv4_address."
  }
}

variable "ipv6_arm" {
  description = <<-EOT
    ipv6_address_choice oneof member for eth0. `no_ipv6_address` (default) is live-appliable.
    `ipv6_auto_config` (renders the `host {}` autoconfig arm) and `static_ipv6_address` (renders
    `node_static_ip { ip_address }`, `CIDRValidator()`) 400 on a single-node IPv4 `azure` probe, so
    they are plan-only — their schema is proven at PLAN.
  EOT
  type        = string
  default     = "no_ipv6_address"
  validation {
    condition     = contains(["no_ipv6_address", "ipv6_auto_config", "static_ipv6_address"], var.ipv6_arm)
    error_message = "ipv6_arm must be no_ipv6_address | ipv6_auto_config | static_ipv6_address."
  }
}

variable "monitor_arm" {
  description = "monitoring_choice oneof member for eth0. Both `monitor` and `monitor_disabled` (default) are empty markers and live-appliable."
  type        = string
  default     = "monitor_disabled"
  validation {
    condition     = contains(["monitor", "monitor_disabled"], var.monitor_arm)
    error_message = "monitor_arm must be monitor | monitor_disabled."
  }
}

variable "s2s_iface_arm" {
  description = <<-EOT
    site_to_site_connectivity_interface_choice oneof member for eth0. Both `disabled` (default) and
    `enabled` are empty markers and both are live-appliable on the single-node `azure` probe
    (confirmed apply/idempotent/import-clean).
  EOT
  type        = string
  default     = "disabled"
  validation {
    condition     = contains(["disabled", "enabled"], var.s2s_iface_arm)
    error_message = "s2s_iface_arm must be disabled | enabled."
  }
}

variable "ipv6_address" {
  description = "static_ipv6_address.node_static_ip.ip_address (IPv6 CIDR). Provider validator: `CIDRValidator()` + `LengthBetween(7, 1024)`. Rendered only when ipv6_arm=static_ipv6_address. reject-static-ipv6 pushes a malformed CIDR."
  type        = string
  default     = "2001:db8::10/64"
}

variable "bond_devices" {
  description = "bond_interface.devices (member ethernet devices). Provider validator: `SizeBetween(1, 8)`. Rendered only when interface_arm=bond. reject-bond-devices pushes an empty list."
  type        = list(string)
  default     = ["eth1", "eth2"]
}

variable "bond_lacp_rate" {
  description = "bond_interface.lacp.rate (LACP transmit interval, seconds). Provider validator: `Between(1, 30)`. Rendered only when interface_arm=bond."
  type        = number
  default     = 1
}

variable "extended_arms" {
  description = <<-EOT
    When true (default), the probe renders the S1 vlan_interface interface entry and the
    top-level custom_proxy block so the vlan_id and proxy_port numeric leaves are reachable
    at PLAN time (schema validators fire during plan under both mock_provider tests and live
    plans). Set false only for a live apply if the XC API rejects the vlan/proxy combination:
    the base eth0 interface (which carries the mtu and priority leaves) still applies live and
    stays idempotent/import-clean, while vlan_id/proxy_port remain plan-validated.
  EOT
  type        = bool
  default     = true
}

# --- S4: networking / services top-level oneof selectors ------------------------------------------
# Each top-level networking/services oneof is modeled as an enum selector driving mutually-exclusive
# `dynamic` blocks so exactly ONE member of each oneof renders (no ConflictsWith trip). Every default
# is the arm the base probe already applies live, so a bare `terraform plan` (all defaults) shows NO
# diff versus the pre-S4 base. Live-appliable (S4a) arms apply/idempotent/import on the single-node
# `azure` probe; ref-dependent (S4b) and single-node-400 (S4c) arms are plan-only.

variable "services_arm" {
  description = <<-EOT
    services oneof member. `block_all_services` (default) is the base arm. `blocked_services` renders
    a `blocked_service` entry (S4a live) exposing the `network_type` `OneOf` validator.
  EOT
  type        = string
  default     = "block_all_services"
  validation {
    condition     = contains(["block_all_services", "blocked_services"], var.services_arm)
    error_message = "services_arm must be block_all_services | blocked_services."
  }
}

variable "blocked_network_type" {
  description = "blocked_services.blocked_service.network_type. Provider validator: `OneOf(VIRTUAL_NETWORK_*)`. reject-network-type pushes \"BOGUS\". No terraform validation so the provider OneOf fires at plan."
  type        = string
  default     = "VIRTUAL_NETWORK_SITE_LOCAL"
}

variable "blocked_service_arm" {
  description = <<-EOT
    blocked_service service_choice member: `dns` | `ssh` (default) | `web_user_interface`. Exactly one
    marker renders — F5's runtime keeps a single member, so sending two siblings silently drops one.
    Rendered only when services_arm=blocked_services.
  EOT
  type        = string
  default     = "ssh"
  validation {
    condition     = contains(["dns", "ssh", "web_user_interface"], var.blocked_service_arm)
    error_message = "blocked_service_arm must be dns | ssh | web_user_interface."
  }
}

variable "ha_arm" {
  description = <<-EOT
    node_ha oneof member. `disable_ha` (default) is the base arm and live-appliable. `enable_ha`
    400s on a single-node `azure` probe (needs >=3 nodes) so it is plan-only (S4c).
  EOT
  type        = string
  default     = "disable_ha"
  validation {
    condition     = contains(["disable_ha", "enable_ha"], var.ha_arm)
    error_message = "ha_arm must be disable_ha | enable_ha."
  }
}

variable "dns_arm" {
  description = "dns_ntp_config dns oneof member. `f5_dns_default` (default, base) | `custom_dns` (renders `dns_servers`, S4a live)."
  type        = string
  default     = "f5_dns_default"
  validation {
    condition     = contains(["f5_dns_default", "custom_dns"], var.dns_arm)
    error_message = "dns_arm must be f5_dns_default | custom_dns."
  }
}

variable "ntp_arm" {
  description = "dns_ntp_config ntp oneof member. `f5_ntp_default` (default, base) | `custom_ntp` (renders `ntp_servers`, S4a live)."
  type        = string
  default     = "f5_ntp_default"
  validation {
    condition     = contains(["f5_ntp_default", "custom_ntp"], var.ntp_arm)
    error_message = "ntp_arm must be f5_ntp_default | custom_ntp."
  }
}

variable "dns_servers" {
  description = "custom_dns.dns_servers (list of DNS server IPs). Rendered only when dns_arm=custom_dns. Provider validator: `SizeAtMost(64)`."
  type        = list(string)
  default     = ["8.8.8.8", "8.8.4.4"]
}

variable "ntp_servers" {
  description = "custom_ntp.ntp_servers (list of NTP servers). Rendered only when ntp_arm=custom_ntp. Provider validator: `SizeAtMost(64)`."
  type        = list(string)
  default     = ["216.239.35.0", "216.239.35.4"]
}

variable "proxy_arm" {
  description = <<-EOT
    enterprise_proxy oneof member. `custom_proxy` (default) keeps the S1/S2 `proxy_port` +
    `proxy_ip_address` coverage and renders only when `extended_arms` is true (matching the pre-S4
    base — `custom_proxy` 400s live on this probe). `f5_proxy` is an empty marker and S4a live.
    `none` renders neither member.
  EOT
  type        = string
  default     = "custom_proxy"
  validation {
    condition     = contains(["custom_proxy", "f5_proxy", "none"], var.proxy_arm)
    error_message = "proxy_arm must be custom_proxy | f5_proxy | none."
  }
}

variable "proxy_ip_address" {
  description = "custom_proxy.proxy_ip_address (IPv4). Provider validator: `IPv4Validator()`. reject-proxy-ip pushes \"999.1.1.1\". No terraform validation so the provider IPv4 validator fires at plan."
  type        = string
  default     = "10.0.0.10"
}

variable "proxy_bypass_arm" {
  description = <<-EOT
    proxy_bypass oneof member. `unset` (default) omits the oneof entirely (matching the pre-S4 base,
    which never set it). `no_proxy_bypass` (empty marker) and `custom_proxy_bypass` (renders
    `proxy_bypass` domain list) are S4a live.
  EOT
  type        = string
  default     = "unset"
  validation {
    condition     = contains(["unset", "no_proxy_bypass", "custom_proxy_bypass"], var.proxy_bypass_arm)
    error_message = "proxy_bypass_arm must be unset | no_proxy_bypass | custom_proxy_bypass."
  }
}

variable "proxy_bypass_domains" {
  description = "custom_proxy_bypass.proxy_bypass (list of domains to bypass the proxy). Rendered only when proxy_bypass_arm=custom_proxy_bypass."
  type        = list(string)
  default     = ["example.com", "internal.local"]
}

variable "url_cat_arm" {
  description = <<-EOT
    url_categorization oneof member. `unset` (default) omits the oneof (pre-S4 base never set it).
    `disable_url_categorization` and `enable_url_categorization` are empty markers, both S4a live.
  EOT
  type        = string
  default     = "unset"
  validation {
    condition     = contains(["unset", "disable_url_categorization", "enable_url_categorization"], var.url_cat_arm)
    error_message = "url_cat_arm must be unset | disable_url_categorization | enable_url_categorization."
  }
}

variable "mgmt_net_arm" {
  description = <<-EOT
    management_network oneof member. `unset` (default) omits the oneof (pre-S4 base never set it).
    `disable_management_network` is an empty marker, S4a live. `enable_management_network` 400s on a
    single-node `azure` probe so it is plan-only (S4c).
  EOT
  type        = string
  default     = "unset"
  validation {
    condition     = contains(["unset", "disable_management_network", "enable_management_network"], var.mgmt_net_arm)
    error_message = "mgmt_net_arm must be unset | disable_management_network | enable_management_network."
  }
}

variable "s2s_slo_arm" {
  description = <<-EOT
    s2s_connectivity_slo oneof member. `no_s2s_connectivity_slo` (default, base). `dc_cluster_group_slo`
    (ObjectRefType) is ref-dependent, plan-only (S4b). `site_mesh_group_empty` renders
    `site_mesh_group_on_slo { no_site_mesh_group {} sm_connection_public_ip {} }` (S4a live).
    `site_mesh_group_ref` renders the `site_mesh_group` ObjectRefType arm, plan-only (S4b).
  EOT
  type        = string
  default     = "no_s2s_connectivity_slo"
  validation {
    condition     = contains(["no_s2s_connectivity_slo", "dc_cluster_group_slo", "site_mesh_group_empty", "site_mesh_group_ref"], var.s2s_slo_arm)
    error_message = "s2s_slo_arm must be no_s2s_connectivity_slo | dc_cluster_group_slo | site_mesh_group_empty | site_mesh_group_ref."
  }
}

variable "s2s_sli_arm" {
  description = "s2s_connectivity_sli oneof member. `no_s2s_connectivity_sli` (default, base) | `dc_cluster_group_sli` (ObjectRefType, ref-dependent, plan-only S4b)."
  type        = string
  default     = "no_s2s_connectivity_sli"
  validation {
    condition     = contains(["no_s2s_connectivity_sli", "dc_cluster_group_sli"], var.s2s_sli_arm)
    error_message = "s2s_sli_arm must be no_s2s_connectivity_sli | dc_cluster_group_sli."
  }
}

variable "forward_proxy_arm" {
  description = "forward_proxy oneof member. `no_forward_proxy` (default, base) | `active_forward_proxy_policies` (ObjectRefType list, ref-dependent, plan-only S4b)."
  type        = string
  default     = "no_forward_proxy"
  validation {
    condition     = contains(["no_forward_proxy", "active_forward_proxy_policies"], var.forward_proxy_arm)
    error_message = "forward_proxy_arm must be no_forward_proxy | active_forward_proxy_policies."
  }
}

variable "network_policy_arm" {
  description = "network_policy oneof member. `no_network_policy` (default, base) | `active_enhanced_firewall_policies` (ObjectRefType list, ref-dependent, plan-only S4b)."
  type        = string
  default     = "no_network_policy"
  validation {
    condition     = contains(["no_network_policy", "active_enhanced_firewall_policies"], var.network_policy_arm)
    error_message = "network_policy_arm must be no_network_policy | active_enhanced_firewall_policies."
  }
}

variable "logs_arm" {
  description = <<-EOT
    logs_receiver oneof member. `logs_streaming_disabled` (default, base) | `log_receiver_with_net`
    (ObjectRefType log_receiver + use_slo_sli, ref-dependent, plan-only S4b). Drives logs via
    `log_receiver_with_net`, never the stale top-level `log_receiver` field (provider #1256).
  EOT
  type        = string
  default     = "logs_streaming_disabled"
  validation {
    condition     = contains(["logs_streaming_disabled", "log_receiver_with_net"], var.logs_arm)
    error_message = "logs_arm must be logs_streaming_disabled | log_receiver_with_net."
  }
}

variable "vip_vrrp_mode" {
  description = <<-EOT
    load_balancing.vip_vrrp_mode. Empty string "" (default) omits the `load_balancing` block entirely
    (pre-S4 base never set it). `VIP_VRRP_ENABLE`/`VIP_VRRP_DISABLE`/`VIP_VRRP_INVALID` render
    `load_balancing`; ENABLE/DISABLE are S4a live. Provider validator: `OneOf(VIP_VRRP_INVALID,
    VIP_VRRP_ENABLE, VIP_VRRP_DISABLE)`. reject-vip-vrrp-mode pushes "BOGUS". No terraform validation
    so the provider OneOf fires at plan.
  EOT
  type        = string
  default     = ""
}

variable "segment_vrf_arm" {
  description = <<-EOT
    segment_vrf selector. `unset` (default) omits `segment_vrf` (pre-S4 base never set it). `inline`
    renders one `segment_vrf { segment_config { nameserver ... } }` entry. Plan-only: a live
    `segment_vrf` needs a Segment object reference the provider cannot yet inject (api-specs-enriched #1053).
  EOT
  type        = string
  default     = "unset"
  validation {
    condition     = contains(["unset", "inline"], var.segment_vrf_arm)
    error_message = "segment_vrf_arm must be unset | inline."
  }
}

variable "segment_nameserver" {
  description = "segment_vrf.segment_config.nameserver (IPv4). Provider validator: `IPv4Validator()`. reject-segment-nameserver pushes an invalid IPv4. No terraform validation so the provider IPv4 validator fires at plan."
  type        = string
  default     = "10.0.3.53"
}

# --- S4b plan-only ObjectRefType names (each ref points at a fictitious object in `system`; the arm
# is proven at PLAN only, so the referent need not exist) -----------------------------------------

variable "forward_proxy_policy_ref_name" {
  description = "active_forward_proxy_policies.forward_proxy_policies[].name (plan-only ref)."
  type        = string
  default     = "cov-forward-proxy-policy"
}

variable "firewall_policy_ref_name" {
  description = "active_enhanced_firewall_policies.enhanced_firewall_policies[].name (plan-only ref)."
  type        = string
  default     = "cov-enhanced-firewall-policy"
}

variable "log_receiver_ref_name" {
  description = "log_receiver_with_net.log_receiver.name (plan-only ref)."
  type        = string
  default     = "cov-log-receiver"
}

variable "dc_cluster_group_slo_ref_name" {
  description = "dc_cluster_group_slo.name (plan-only ref)."
  type        = string
  default     = "cov-dc-cluster-group-slo"
}

variable "dc_cluster_group_sli_ref_name" {
  description = "dc_cluster_group_sli.name (plan-only ref)."
  type        = string
  default     = "cov-dc-cluster-group-sli"
}

variable "site_mesh_group_ref_name" {
  description = "site_mesh_group_on_slo.site_mesh_group.name (plan-only ref)."
  type        = string
  default     = "cov-site-mesh-group"
}

variable "ref_namespace" {
  description = "Namespace for the S4b plan-only ObjectRefType references."
  type        = string
  default     = "system"
}

# --- S5: site-mode oneof selectors (perf / os / sw / offline / re_select / upgrade / admin) --------
# Each site-mode oneof is modeled as an enum selector superseding the pre-S5 base literal so exactly
# ONE member of each oneof renders. Every default is the arm the base probe already applied, so a bare
# `terraform plan` (all defaults) shows NO diff versus the pre-S5 base (defaults-supersession
# invariant). S5a arms apply live on the single-node `azure` probe; S5b arms are plan-only.

variable "perf_arm" {
  description = <<-EOT
    performance_enhancement_mode oneof member. `perf_mode_l7_enhanced` (default, base) renders its own
    jumbo sub-oneof via l7_jumbo_arm and is S5a live. `perf_mode_l3_enhanced` renders its own
    {jumbo | no_jumbo} sub-oneof via l3_jumbo_arm (S5a live).
  EOT
  type        = string
  default     = "perf_mode_l7_enhanced"
  validation {
    condition     = contains(["perf_mode_l7_enhanced", "perf_mode_l3_enhanced"], var.perf_arm)
    error_message = "perf_arm must be perf_mode_l7_enhanced | perf_mode_l3_enhanced."
  }
}

variable "l3_jumbo_arm" {
  description = <<-EOT
    perf_mode_l3_enhanced jumbo sub-oneof member: `no_jumbo` (default) | `jumbo`. Distinct from the
    l7 pair (`jumbo_disabled`/`jumbo_enabled`) — F5 spells the l3 members differently. Rendered only
    when perf_arm=perf_mode_l3_enhanced.
  EOT
  type        = string
  default     = "no_jumbo"
  validation {
    condition     = contains(["no_jumbo", "jumbo"], var.l3_jumbo_arm)
    error_message = "l3_jumbo_arm must be no_jumbo | jumbo."
  }
}

variable "l7_jumbo_arm" {
  description = <<-EOT
    perf_mode_l7_enhanced jumbo sub-oneof member: `jumbo_disabled` (default) | `jumbo_enabled`. New in
    provider v3.80.0 (specs v2.1.194). The server materializes `jumbo_disabled`, so declaring it keeps
    the object import-clean; an undeclared marker re-plans as a removal after import.
  EOT
  type        = string
  default     = "jumbo_disabled"
  validation {
    condition     = contains(["jumbo_disabled", "jumbo_enabled"], var.l7_jumbo_arm)
    error_message = "l7_jumbo_arm must be jumbo_disabled | jumbo_enabled."
  }
}

variable "os_arm" {
  description = <<-EOT
    software_settings.os oneof member. `default_os_version` (default, base, empty) is S5a live.
    `operating_system_version` renders the pinned OS-version string leaf (S5a live; create-only).
  EOT
  type        = string
  default     = "default_os_version"
  validation {
    condition     = contains(["default_os_version", "operating_system_version"], var.os_arm)
    error_message = "os_arm must be default_os_version | operating_system_version."
  }
}

variable "os_version" {
  description = "software_settings.os.operating_system_version. Provider validator: `LengthAtMost(20)`. Create-only. reject-os-version pushes a 21-char string. Rendered only when os_arm=operating_system_version."
  type        = string
  default     = "9.2024.6"
}

variable "sw_arm" {
  description = <<-EOT
    software_settings.sw oneof member. `default_sw_version` (default, base, empty) is S5a live.
    `volterra_software_version` renders the pinned SW-version string leaf (S5a live; create-only).
  EOT
  type        = string
  default     = "default_sw_version"
  validation {
    condition     = contains(["default_sw_version", "volterra_software_version"], var.sw_arm)
    error_message = "sw_arm must be default_sw_version | volterra_software_version."
  }
}

variable "sw_version" {
  description = "software_settings.sw.volterra_software_version. Provider validator: `LengthAtMost(20)`. Create-only. Default is the live-proven version (iter-1). reject-sw-version pushes a 21-char string. Rendered only when sw_arm=volterra_software_version."
  type        = string
  default     = "crt-20250613-3382"
}

variable "offline_arm" {
  description = <<-EOT
    offline_survivability_mode oneof member. `no_offline_survivability_mode` (default, base, empty) is
    S5a live. `enable_offline_survivability_mode` (empty marker) is S5a live.
  EOT
  type        = string
  default     = "no_offline_survivability_mode"
  validation {
    condition     = contains(["no_offline_survivability_mode", "enable_offline_survivability_mode"], var.offline_arm)
    error_message = "offline_arm must be no_offline_survivability_mode | enable_offline_survivability_mode."
  }
}

variable "re_select_arm" {
  description = <<-EOT
    re_select oneof member. `geo_proximity` (default, base, empty) is S5a live. `specific_re` renders
    `primary_re`/`backup_re` (plan-only S5b — `primary_re` must name a real RE geography).
  EOT
  type        = string
  default     = "geo_proximity"
  validation {
    condition     = contains(["geo_proximity", "specific_re"], var.re_select_arm)
    error_message = "re_select_arm must be geo_proximity | specific_re."
  }
}

variable "primary_re" {
  description = "re_select.specific_re.primary_re (Primary RE Geography). Provider validator: `LengthBetween(1, 64)`. reject-primary-re pushes a 65-char string. Rendered only when re_select_arm=specific_re."
  type        = string
  default     = "cov-primary-re"
}

variable "backup_re" {
  description = "re_select.specific_re.backup_re (Backup RE Geography; no validator). Rendered only when re_select_arm=specific_re."
  type        = string
  default     = "cov-backup-re"
}

variable "upgrade_drain_arm" {
  description = <<-EOT
    upgrade_settings.kubernetes_upgrade_drain oneof selector. `unset` (default) omits the entire
    `upgrade_settings` block (pre-S5 base never set it). `disable_upgrade_drain` (empty marker) and
    `enable_upgrade_drain` (renders the drain leaves + vega sub-oneof) are plan-only S5b — worker-node
    drain 400s on a non-k8s single-node probe.
  EOT
  type        = string
  default     = "unset"
  validation {
    condition     = contains(["unset", "disable_upgrade_drain", "enable_upgrade_drain"], var.upgrade_drain_arm)
    error_message = "upgrade_drain_arm must be unset | disable_upgrade_drain | enable_upgrade_drain."
  }
}

variable "drain_max_unavailable" {
  description = "enable_upgrade_drain.drain_max_unavailable_node_count (node batch size). Provider validator: `Between(1, 5000)`. reject-drain-count pushes 5001. Rendered only when upgrade_drain_arm=enable_upgrade_drain."
  type        = number
  default     = 1
}

variable "drain_node_timeout" {
  description = "enable_upgrade_drain.drain_node_timeout (seconds). Provider validator: `Between(0, 900)`. reject-drain-timeout pushes 901. Rendered only when upgrade_drain_arm=enable_upgrade_drain."
  type        = number
  default     = 300
}

variable "vega_arm" {
  description = <<-EOT
    enable_upgrade_drain vega sub-oneof member. `disable_vega_upgrade_mode` (default, empty marker) |
    `enable_vega_upgrade_mode` (empty marker). Rendered only when upgrade_drain_arm=enable_upgrade_drain.
  EOT
  type        = string
  default     = "disable_vega_upgrade_mode"
  validation {
    condition     = contains(["disable_vega_upgrade_mode", "enable_vega_upgrade_mode"], var.vega_arm)
    error_message = "vega_arm must be disable_vega_upgrade_mode | enable_vega_upgrade_mode."
  }
}

variable "admin_creds" {
  description = <<-EOT
    When true, renders the `admin_user_credentials` block (unset in the pre-S5 base) with the `ssh_key`
    leaf + an `admin_password` SecretType backed by `clear_secret_info`. Attempted S5a live. Default
    false so a bare plan omits the block (defaults-supersession invariant).
  EOT
  type        = bool
  default     = false
}

variable "ssh_key" {
  description = "admin_user_credentials.ssh_key (public SSH key). Provider validator: `LengthAtMost(8192)`. reject-ssh-key pushes a >8192-char string. Rendered only when admin_creds=true. Dummy public key — never a real key."
  type        = string
  default     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDummyCoveragePublicKeyNotARealKey000000000000 cov-probe@example.com"
}

variable "admin_password_b64_source" {
  description = <<-EOT
    Cleartext DUMMY password whose base64 encoding feeds admin_password.clear_secret_info.url as
    `string:///<base64>`. NEVER a real secret — a throwaway placeholder committed only for coverage.
  EOT
  type        = string
  default     = "dummy-not-a-real-secret"
}
