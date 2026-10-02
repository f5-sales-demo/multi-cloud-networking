# ---------------------------------------------------------
# F5 XC tenant
# ---------------------------------------------------------

variable "expected_xc_tenant" {
  description = "F5 XC tenant this deployment belongs to: the first hostname label of the console URL (`f5-sales-demo` for https://f5-sales-demo.console.ves.volterra.io). This is the ONLY place the tenant is named. The xcsh provider's api_url is derived from it, so the configuration — not the ambient environment — decides which tenant is written to, and a plan FAILS when XCSH_API_URL in the environment names a different one."
  type        = string
  default     = "f5-sales-demo"

  validation {
    # A hostname label, not a URL: the scheme and domain are added in locals.tf.
    condition     = can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.expected_xc_tenant))
    error_message = "expected_xc_tenant must be a bare DNS label (lowercase letters, digits and hyphens) such as f5-sales-demo — not a URL and not a hostname."
  }
}

# ---------------------------------------------------------
# F5 XC data-plane inputs
# ---------------------------------------------------------

variable "xc_app_namespace" {
  description = "Name of a PRE-EXISTING F5 XC namespace in expected_xc_tenant to place the app-tier objects (origin pool + HTTP load balancer) in. This deployment READS the namespace; it never creates or deletes it, so a namespace holding unrelated demos can never land on this stack's destroy list."
  type        = string
  default     = "multi-cloud-networking"

  validation {
    condition     = length(var.xc_app_namespace) > 0
    error_message = "xc_app_namespace must name an existing namespace; it is looked up, not created."
  }
}

variable "origin_pool_name" {
  description = "Name of the origin pool. Leave null (the default) to derive `<component>-pool`."
  type        = string
  default     = null
}

variable "origin_ip" {
  description = "Public IP of the origin server the pool targets. REQUIRED, deliberately without a default: any default here is one specific machine, and a wrong one silently sends a fresh deployment's traffic to somebody else's host instead of failing."
  type        = string

  validation {
    condition     = can(cidrhost("${var.origin_ip}/32", 0))
    error_message = "origin_ip must be a single IPv4 address."
  }
}

variable "origin_port" {
  description = "TCP port of the origin server."
  type        = number
  default     = 80
}

variable "lb_name" {
  description = "Name of the HTTP load balancer. Leave null (the default) to derive `<component>-f5se`, matching the naming this tenant's other load balancers use."
  type        = string
  default     = null
}

variable "lb_domain" {
  description = "Domain served by the HTTP load balancer for Rest of World. REQUIRED, deliberately without a default: the load balancer matches on Host, so this value is what every request must send, and it belongs to whoever runs the deployment."
  type        = string

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.lb_domain))
    error_message = "lb_domain must be a fully-qualified lowercase domain name (for example mcn-ce-ha.f5-sales-demo.com)."
  }
}

# ---------------------------------------------------------
# Canada Regional F5 XC inputs
# ---------------------------------------------------------

variable "enable_canada" {
  description = "Enable parallel Canada-only regional infrastructure, Canadian virtual sites, and f5-sales-demo.ca load balancer."
  type        = bool
  default     = true
}

variable "ca_lb_domain" {
  description = "Domain served by the Canada HTTP load balancer. Defaults to mcn-ce-ha.f5-sales-demo.ca."
  type        = string
  default     = "mcn-ce-ha.f5-sales-demo.ca"

  validation {
    condition     = can(regex("^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$", var.ca_lb_domain))
    error_message = "ca_lb_domain must be a fully-qualified lowercase domain name (for example mcn-ce-ha.f5-sales-demo.ca)."
  }
}

variable "ca_re_cities" {
  description = "List of cities for the Canadian Regional Edge Virtual Site selector. Defaults to Toronto and Montreal."
  type        = list(string)
  default     = ["toronto", "montreal"]
  validation {
    condition = (
      length(var.ca_re_cities) > 0 &&
      alltrue([for city in var.ca_re_cities : contains(["toronto", "montreal"], city)])
    )
    error_message = "Canadian RE advertisement must select Toronto and/or Montreal."
  }
}

variable "ca_lb_name" {
  description = "Name of the Canada HTTP load balancer. Leave null (the default) to derive `<component>-ca-f5se`."
  type        = string
  default     = null
}

variable "ca_origin_pool_name" {
  description = "Name of the Canada origin pool. Leave null (the default) to derive `<component>-ca-pool`."
  type        = string
  default     = null
}

variable "ca_re_vsite_name" {
  description = "Name of the Canadian Regional Edge virtual site. Leave null (the default) to derive `<component>-ca-re-vsite`."
  type        = string
  default     = null
}

variable "ca_ce_vsite_name" {
  description = "Name of the Canadian Customer Edge virtual site. Leave null (the default) to derive `<component>-ca-ce-vsite`."
  type        = string
  default     = null
}

variable "vip" {
  description = "HA VIP advertised as a /32 by every CE via eBGP. MUST be outside all VNet CIDRs (Azure prefers the VNet system route over a more-specific BGP /32 otherwise)."
  type        = string
  default     = "10.250.0.10"

  validation {
    # Self-contained format check. Cross-CIDR containment is asserted by the
    # check{} block in main.tf (which may reference other variables).
    condition     = can(cidrhost("${var.vip}/32", 0))
    error_message = "vip must be a valid IPv4 address."
  }
}

variable "enable_canada_public_re" {
  description = "Advertise the Canadian HTTP-LB publicly on Toronto/Montreal using a dedicated allocated XC public IP. Requires ca_re_public_ip."
  type        = bool
  default     = false
}
variable "ca_re_public_ip" {
  description = "Dedicated XC public-IP allocation reserved for this Canadian demo. Use an existing unused allocation or obtain an additional one through F5 support; keep the actual allocation in private tfvars."
  type = object({
    name      = string
    namespace = string
    ip        = string
  })
  default  = null
  nullable = true
  validation {
    condition = var.ca_re_public_ip == null || try(
      length(var.ca_re_public_ip.name) > 0 &&
      length(var.ca_re_public_ip.namespace) > 0 &&
      can(cidrhost("${var.ca_re_public_ip.ip}/32", 0)) &&
    !strcontains(var.ca_re_public_ip.ip, ":"), false)
    error_message = "ca_re_public_ip must identify an allocated IPv4 public-IP object by name and namespace."
  }
}
