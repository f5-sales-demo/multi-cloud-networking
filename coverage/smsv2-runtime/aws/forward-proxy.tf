variable "proxy_http_action" {
  type    = string
  default = null
  validation {
    condition     = var.proxy_http_action == null || contains(["ALLOW", "DENY", "NEXT_POLICY"], var.proxy_http_action)
    error_message = "Use null, ALLOW, DENY or NEXT_POLICY."
  }
}
variable "proxy_tls_action" {
  type    = string
  default = null
  validation {
    condition     = var.proxy_tls_action == null || contains(["ALLOW", "DENY", "NEXT_POLICY"], var.proxy_tls_action)
    error_message = "Use null, ALLOW, DENY or NEXT_POLICY."
  }
}
variable "proxy_fallback_action" {
  type    = string
  default = "ALLOW"
  validation {
    condition     = contains(["ALLOW", "DENY", "NEXT_POLICY"], var.proxy_fallback_action)
    error_message = "Use ALLOW, DENY or NEXT_POLICY."
  }
}
variable "proxy_companion_action" {
  type    = string
  default = null
  validation {
    condition     = var.proxy_companion_action == null || contains(["ALLOW", "DENY", "NEXT_POLICY"], var.proxy_companion_action)
    error_message = "Use null, ALLOW, DENY or NEXT_POLICY."
  }
}
variable "proxy_origin_hostname" {
  type    = string
  default = "origin.qualification.test"
}
variable "proxy_http_origin_hostname" {
  type    = string
  default = null
}
variable "proxy_http_path_prefix" {
  type    = string
  default = "/deny"
}
variable "proxy_rule_order" {
  type    = list(string)
  default = ["http", "tls", "fallback"]
  validation {
    condition     = length(var.proxy_rule_order) == 3 && toset(var.proxy_rule_order) == toset(["http", "tls", "fallback"])
    error_message = "Provide each of http, tls and fallback exactly once."
  }
}
locals {
  proxy_enabled = var.proxy_http_action != null || var.proxy_tls_action != null
  proxy_rules   = [for kind in var.proxy_rule_order : kind if kind == "fallback" || (kind == "http" && var.proxy_http_action != null) || (kind == "tls" && var.proxy_tls_action != null)]
}
resource "xcsh_forward_proxy_policy" "traffic" {
  count     = local.proxy_enabled ? 1 : 0
  name      = "${var.task_id}-fpx"
  namespace = "system"
  labels    = local.tags
  rule_list {
    dynamic "rules" {
      for_each = local.proxy_rules
      content {
        metadata { name = "qualification-${rules.value}" }
        action               = rules.value == "http" ? var.proxy_http_action : (rules.value == "tls" ? var.proxy_tls_action : var.proxy_fallback_action)
        all_sources          = rules.value == "fallback" ? {} : null
        all_destinations     = rules.value == "fallback" ? {} : null
        no_http_connect_port = {}
        dynamic "prefix_list" {
          for_each = rules.value == "fallback" ? [] : [1]
          content { prefixes = [aws_subnet.client.cidr_block] }
        }
        dynamic "http_list" {
          for_each = rules.value == "http" ? [1] : []
          content {
            http_list {
              exact_value       = coalesce(var.proxy_http_origin_hostname, var.proxy_origin_hostname)
              path_prefix_value = var.proxy_http_path_prefix
            }
          }
        }
        dynamic "tls_list" {
          for_each = rules.value == "tls" ? [1] : []
          content {
            tls_list { exact_value = var.proxy_origin_hostname }
          }
        }
      }
    }
  }
}
resource "xcsh_forward_proxy_policy" "companion" {
  count     = var.proxy_companion_action == null ? 0 : 1
  name      = "${var.task_id}-fpx-next"
  namespace = "system"
  labels    = local.tags
  rule_list {
    rules {
      metadata { name = "qualification-companion" }
      all_sources          = {}
      all_destinations     = {}
      no_http_connect_port = {}
      action               = var.proxy_companion_action
    }
  }
}
data "xcsh_forward_proxy_policy" "traffic" {
  count     = local.proxy_enabled ? 1 : 0
  name      = xcsh_forward_proxy_policy.traffic[0].name
  namespace = "system"
}
output "proxy_readback" {
  value = try(data.xcsh_forward_proxy_policy.traffic[0].rule_list == xcsh_forward_proxy_policy.traffic[0].rule_list, null)
}

variable "proxy_allowlist_next" {
  type    = bool
  default = false
}
resource "xcsh_forward_proxy_policy" "allowlist" {
  count     = var.proxy_allowlist_next ? 1 : 0
  name      = "${var.task_id}-fpx-list"
  namespace = "system"
  labels    = local.tags
  any_proxy = {}
  allow_list {
    default_action_next_policy = {}
    http_list {
      exact_value = "unrelated.qualification.test"
      any_path    = {}
    }
    tls_list { exact_value = "origin.qualification.test" }
  }
}
data "xcsh_forward_proxy_policy" "allowlist" {
  count     = var.proxy_allowlist_next ? 1 : 0
  name      = xcsh_forward_proxy_policy.allowlist[0].name
  namespace = "system"
}
output "proxy_allowlist_readback" {
  value = try(data.xcsh_forward_proxy_policy.allowlist[0].allow_list == xcsh_forward_proxy_policy.allowlist[0].allow_list, null)
}
