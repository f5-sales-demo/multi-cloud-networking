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
    rules {
      metadata {
        name = "scoped-http"
      }
      source_prefix_list {
        prefixes = [aws_subnet.client.cidr_block]
      }
      destination_prefix_list {
        prefixes = ["${aws_instance.origin.public_ip}/32"]
      }
      protocol_port_range {
        protocol    = "TCP"
        port_ranges = ["80"]
      }
      allow = var.firewall_action == "allow" ? {} : null
      deny  = var.firewall_action == "deny" ? {} : null
    }
    rules {
      metadata {
        name = "allow-unrelated"
      }
      all_sources      = {}
      all_destinations = {}
      all_traffic      = {}
      allow            = {}
    }
  }
}
