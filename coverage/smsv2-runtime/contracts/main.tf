terraform {
  required_version = "= 1.16.5"
  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 15.10.0"
    }
  }
}
variable "case" {
  type    = string
  default = "root"
}
resource "xcsh_enhanced_firewall_policy" "root_conflict" {
  count     = var.case == "root" ? 1 : 0
  name      = "qualification-root-conflict"
  namespace = "system"
  allow_all = var.case == "root" ? {} : null
  rule_list {
    rules {
      all_sources      = {}
      all_destinations = {}
      all_traffic      = {}
      allow            = {}
    }
  }
}
resource "xcsh_enhanced_firewall_policy" "action_conflict" {
  count     = var.case == "nested" ? 1 : 0
  name      = "qualification-action-conflict"
  namespace = "system"
  rule_list {
    rules {
      all_sources      = {}
      all_destinations = {}
      all_traffic      = {}
      allow            = {}
      deny             = var.case == "nested" ? {} : null
    }
  }
}

resource "xcsh_forward_proxy_policy" "proxy_root_conflict" {
  count            = var.case == "proxy-root" ? 1 : 0
  name             = "qualification-proxy-root-conflict"
  namespace        = "system"
  any_proxy        = {}
  drp_http_connect = var.case == "proxy-root" ? {} : null
  rule_list {
    rules {
      metadata { name = "qualification-allow" }
      all_sources          = {}
      all_destinations     = {}
      no_http_connect_port = {}
      action               = "ALLOW"
    }
  }
}
resource "xcsh_forward_proxy_policy" "proxy_path_conflict" {
  count     = var.case == "proxy-path" ? 1 : 0
  name      = "qualification-proxy-path-conflict"
  namespace = "system"
  any_proxy = {}
  rule_list {
    rules {
      metadata { name = "qualification-allow" }
      all_sources          = {}
      no_http_connect_port = {}
      action               = "ALLOW"
      http_list {
        http_list {
          exact_value       = "origin.qualification.test"
          any_path          = var.case == "proxy-path" ? {} : null
          path_prefix_value = "/deny"
        }
      }
    }
  }
}
