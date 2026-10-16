variable "firewall_action" {
  type    = string
  default = null
  validation {
    condition     = var.firewall_action == null || contains(["allow", "deny"], var.firewall_action)
    error_message = "Use null for no policy, or allow/deny for scoped HTTP traffic."
  }
}

resource "xcsh_enhanced_firewall_policy" "traffic" {
  count     = var.firewall_action == null ? 0 : 1
  name      = "${var.task_id}-efw"
  namespace = "system"
  labels    = local.tags
  rule_list {
    dynamic "rules" {
      for_each = var.firewall_scoped_first ? ["scoped-http", "allow-unrelated"] : ["allow-unrelated", "scoped-http"]
      content {
        metadata { name = rules.value }
        all_sources      = rules.value == "allow-unrelated" ? {} : null
        all_destinations = rules.value == "allow-unrelated" ? {} : null
        all_traffic      = rules.value == "allow-unrelated" ? {} : null
        dynamic "source_prefix_list" {
          for_each = rules.value == "scoped-http" ? [1] : []
          content { prefixes = [aws_subnet.client.cidr_block] }
        }
        dynamic "destination_prefix_list" {
          for_each = rules.value == "scoped-http" ? [1] : []
          content { prefixes = ["${aws_instance.origin.public_ip}/32"] }
        }
        dynamic "protocol_port_range" {
          for_each = rules.value == "scoped-http" ? [1] : []
          content {
            protocol    = "TCP"
            port_ranges = ["80"]
          }
        }
        allow = rules.value == "allow-unrelated" || var.firewall_action == "allow" ? {} : null
        deny  = rules.value == "scoped-http" && var.firewall_action == "deny" ? {} : null
      }
    }
  }
}

variable "firewall_scoped_first" {
  type    = bool
  default = true
}
variable "firewall_companion_action" {
  type    = string
  default = null
  validation {
    condition     = var.firewall_companion_action == null || contains(["allow", "deny"], var.firewall_companion_action)
    error_message = "Use null, allow or deny for the companion policy."
  }
}

resource "xcsh_enhanced_firewall_policy" "companion" {
  count     = var.firewall_companion_action == null ? 0 : 1
  name      = "${var.task_id}-efw-companion"
  namespace = "system"
  labels    = local.tags
  rule_list {
    rules {
      metadata { name = "scoped-http" }
      source_prefix_list { prefixes = [aws_subnet.client.cidr_block] }
      destination_prefix_list { prefixes = ["${aws_instance.origin.public_ip}/32"] }
      protocol_port_range {
        protocol    = "TCP"
        port_ranges = ["80"]
      }
      allow = var.firewall_companion_action == "allow" ? {} : null
      deny  = var.firewall_companion_action == "deny" ? {} : null
    }
    rules {
      metadata { name = "allow-unrelated" }
      all_sources      = {}
      all_destinations = {}
      all_traffic      = {}
      allow            = {}
    }
  }
}

data "xcsh_enhanced_firewall_policy" "traffic" {
  count     = var.firewall_action == null ? 0 : 1
  name      = xcsh_enhanced_firewall_policy.traffic[0].name
  namespace = "system"
}
data "xcsh_enhanced_firewall_policy" "companion" {
  count     = var.firewall_companion_action == null ? 0 : 1
  name      = xcsh_enhanced_firewall_policy.companion[0].name
  namespace = "system"
}
