# General variables. Domain-specific inputs live in variables_azure.tf,
# variables_xc.tf and variables_ce.tf.

variable "source_repository" {
  description = "Canonical GitHub repository identity of the reviewed source. Only this repository can produce a deployment identity."
  type        = string

  validation {
    condition     = var.source_repository == "f5-sales-demo/multi-cloud-networking"
    error_message = "source_repository must be exactly f5-sales-demo/multi-cloud-networking."
  }
}

variable "source_ref" {
  description = "Exact trusted branch ref of the reviewed source. PR merge refs and abbreviated branch names are rejected."
  type        = string

  validation {
    condition = (
      can(regex("^refs/heads/[^[:cntrl:][:space:]~^:?*\\\\\\[]+$", var.source_ref)) &&
      !strcontains(var.source_ref, "..") &&
      !strcontains(var.source_ref, "@{") &&
      !strcontains(var.source_ref, "//") &&
      !can(regex("(^refs/heads/|/)\\.", var.source_ref)) &&
      !can(regex("(\\.|\\.lock)(/|$)", var.source_ref)) &&
      var.source_ref != "refs/heads/@" &&
      !endswith(var.source_ref, "/")
    )
    error_message = "source_ref must be a valid exact refs/heads/* ref, never refs/pull/* or an abbreviated branch."
  }
}

variable "source_commit_sha" {
  description = "Immutable lowercase 40-hex commit that was reviewed and used to create the saved plan."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.source_commit_sha))
    error_message = "source_commit_sha must be an immutable lowercase 40-hex Git commit."
  }
}

variable "deployment_owner_id" {
  description = "Non-personal stable identifier for the team or service that owns the deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,62}$", var.deployment_owner_id))
    error_message = "deployment_owner_id must be a 3-63 character lowercase non-personal identifier."
  }
}

variable "deployment_actor_id" {
  description = "Non-personal stable identifier for the automation actor that applies the deployment."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,62}$", var.deployment_actor_id))
    error_message = "deployment_actor_id must be a 3-63 character lowercase non-personal identifier."
  }
}

variable "component" {
  description = "Component name used in tags."
  type        = string
  default     = "mcn-ce-ha"
}

variable "environment" {
  description = "Environment label used in tags."
  type        = string
  default     = "lab"
}

variable "deployer" {
  description = "Override for the deployer identifier used in tags (auto-resolved from Azure AD when empty)."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Additional tags merged with the standard tags (component/environment/deployer/managed_by)."
  type        = map(string)
  default     = {}
}

variable "enable_kvm" {
  description = "Enable the local KVM/libvirt SMSv2 site. Set false for a KVM-only destroy or when the tenant-owned KVM image prerequisite is unavailable; no KVM image lookup occurs while disabled."
  type        = bool
  default     = false
}

variable "enable_kvm_lan" {
  description = "Opt in to the staged KVM physical-LAN SLI topology. This does not authorize or perform CE replacement by itself."
  type        = bool
  default     = false
}

variable "kvm_lan_configuration_phase" {
  description = "KVM LAN rollout phase: disabled, hardware (two NICs only), or configured (provider-owned runtime discovery plus inside VIP)."
  type        = string
  default     = "disabled"
  nullable    = false

  validation {
    condition     = contains(["disabled", "hardware", "configured"], var.kvm_lan_configuration_phase)
    error_message = "kvm_lan_configuration_phase must be disabled, hardware, or configured."
  }
}

variable "kvm_lan" {
  description = "Approved pre-existing LAN bridge/uplink inventory, deterministic SLI identity, and reserved inside-VIP/origin contract. Terraform never creates or mutates the shared bridge or uplink."
  type = object({
    bridge                      = string
    uplink                      = string
    uplink_mac                  = string
    ownership                   = string
    vlan_mode                   = string
    vlan_id                     = optional(number)
    mtu                         = number
    sli_mac                     = string
    sli_cidr                    = string
    sli_ipv6_mode               = optional(string, "disabled")
    vip                         = string
    vip_reservation             = string
    backend_ip                  = string
    backend_port                = number
    backend_owner               = string
    http_domain                 = string
    access_scope                = string
    bridge_preprovisioned       = bool
    uplink_approved             = bool
    ipv4_users_reviewed         = bool
    ipv6_users_reviewed         = bool
    switch_multi_mac_approved   = bool
    duplicate_addresses_checked = bool
  })
  default  = null
  nullable = true

  validation {
    condition = var.kvm_lan == null || try(
      can(regex("^[a-zA-Z0-9_.-]{1,15}$", var.kvm_lan.bridge)) &&
      can(regex("^[a-zA-Z0-9_.:-]{1,15}$", var.kvm_lan.uplink)) &&
      var.kvm_lan.bridge != var.kvm_lan.uplink &&
      can(regex("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", var.kvm_lan.uplink_mac)) &&
      can(regex("^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$", var.kvm_lan.sli_mac)) &&
      lower(var.kvm_lan.uplink_mac) != lower(var.kvm_lan.sli_mac),
      false,
    )
    error_message = "kvm_lan requires distinct valid bridge/uplink names and six-octet uplink/SLI MAC addresses."
  }

  validation {
    condition = var.kvm_lan == null || try(
      var.kvm_lan.ownership == "preprovisioned-shared" &&
      var.kvm_lan.vlan_mode == "access" &&
      var.kvm_lan.vlan_id == null &&
      var.kvm_lan.mtu >= 1280 && var.kvm_lan.mtu <= 9216 &&
      var.kvm_lan.sli_ipv6_mode == "disabled",
      false,
    )
    error_message = "kvm_lan currently supports an approved preprovisioned-shared access bridge, MTU 1280-9216, and an explicit disabled guest-SLI IPv6 policy; trunk VLANs are rejected until guest tagging is implemented."
  }

  validation {
    condition = var.kvm_lan == null || try(
      can(cidrnetmask(var.kvm_lan.sli_cidr)) &&
      can(cidrnetmask("${var.kvm_lan.vip}/32")) &&
      can(cidrnetmask("${var.kvm_lan.backend_ip}/32")) &&
      cidrhost(var.kvm_lan.sli_cidr, 0) == cidrhost("${var.kvm_lan.vip}/${split("/", var.kvm_lan.sli_cidr)[1]}", 0) &&
      cidrhost(var.kvm_lan.sli_cidr, 0) == cidrhost("${var.kvm_lan.backend_ip}/${split("/", var.kvm_lan.sli_cidr)[1]}", 0) &&
      cidrhost(var.kvm_lan.sli_cidr, 0) != cidrhost("10.100.0.0/24", 0) &&
      !contains([
        cidrhost(var.kvm_lan.sli_cidr, 0),
        cidrhost(var.kvm_lan.sli_cidr, -1),
      ], split("/", var.kvm_lan.sli_cidr)[0]) &&
      !contains([
        cidrhost(var.kvm_lan.sli_cidr, 0),
        cidrhost(var.kvm_lan.sli_cidr, -1),
      ], var.kvm_lan.vip) &&
      !contains([
        cidrhost(var.kvm_lan.sli_cidr, 0),
        cidrhost(var.kvm_lan.sli_cidr, -1),
      ], var.kvm_lan.backend_ip) &&
      length(distinct([split("/", var.kvm_lan.sli_cidr)[0], var.kvm_lan.vip, var.kvm_lan.backend_ip])) == 3,
      false,
    )
    error_message = "kvm_lan requires usable, distinct IPv4 SLI, VIP, and backend addresses in one subnet that does not overlap the 10.100.0.0/24 SLO fabric."
  }

  validation {
    condition = var.kvm_lan == null || try(
      floor(var.kvm_lan.backend_port) == var.kvm_lan.backend_port &&
      var.kvm_lan.backend_port >= 1 && var.kvm_lan.backend_port <= 65535 &&
      can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.kvm_lan.http_domain)) &&
      alltrue([
        for value in [var.kvm_lan.vip_reservation, var.kvm_lan.backend_owner, var.kvm_lan.access_scope] :
        trimspace(value) != ""
      ]),
      false,
    )
    error_message = "kvm_lan requires a valid backend port, lowercase HTTP domain, and nonempty reservation, origin-owner, and access-scope records."
  }
}

variable "kvm_software_version" {
  description = "F5XC software installed during the KVM CE's first boot. This is pinned explicitly so a fresh install does not consume an unqualified tenant default release."
  type        = string
  default     = "crt-20260801-0205"
  nullable    = false

  validation {
    condition     = can(regex("^crt-[0-9]{8}-[0-9]{4}$", var.kvm_software_version))
    error_message = "kvm_software_version must be an explicit F5XC software build such as crt-20260801-0205."
  }
}

variable "aws_origin_dns_name" {
  description = "DNS name of the public HTTP origin for the AWS SMSv2 load balancer."
  type        = string
  default     = "httpbin.org"
  nullable    = false

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.aws_origin_dns_name))
    error_message = "aws_origin_dns_name must be a fully-qualified lowercase DNS name."
  }
}
