resource "xcsh_virtual_site" "inside" {
  name      = var.name
  namespace = var.namespace
  labels    = var.labels
  site_type = "CUSTOMER_EDGE"

  site_selector {
    expressions = ["ves.io/siteName in (${join(", ", var.site_names)})"]
  }
}

resource "xcsh_http_loadbalancer" "inside" {
  name        = "${var.name}-http"
  namespace   = var.namespace
  description = "Regional Azure ILB application on specified inside VIP ${var.vip}."
  domains     = [var.domain]
  labels      = var.labels

  http { port = 80 }

  advertise_custom {
    advertise_where {
      port = 80
      virtual_site_with_vip {
        ip      = var.vip
        network = "SITE_NETWORK_SPECIFIED_VIP_INSIDE"
        virtual_site {
          name      = xcsh_virtual_site.inside.name
          namespace = xcsh_virtual_site.inside.namespace
        }
      }
    }
  }

  default_route_pools {
    pool {
      name      = var.origin_pool_name
      namespace = var.namespace
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
  service_policies_from_namespace  = {}
  disable_trust_client_ip_headers  = {}
  disable_malicious_user_detection = {}
  disable_malware_protection       = {}
  disable_threat_mesh              = {}
  default_sensitive_data_policy    = {}
}

output "domain" { value = var.domain }
output "vip" { value = var.vip }
