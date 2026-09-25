terraform {
  required_version = "= 1.16.3"
  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 11.3.0"
    }
  }
}

variable "source_commit_sha" {
  type = string
  validation {
    condition     = can(regex("^[0-9a-f]{40}$", var.source_commit_sha))
    error_message = "source_commit_sha must identify a reviewed commit."
  }
}

variable "backend_key" {
  type = string
  validation {
    condition     = startswith(var.backend_key, "mcn-ce-ha-smsv2/")
    error_message = "backend_key must identify the reviewed showcase backend."
  }
}

output "reviewed_identity" {
  value = {
    source_commit_sha = var.source_commit_sha
    backend_key       = var.backend_key
  }
}

data "xcsh_network_customer_edge_defaults" "system_services" {}
data "xcsh_network_customer_edge_egress" "secure_mesh_v2" {}

output "requirements" {
  value = {
    api_release_tag = data.xcsh_network_customer_edge_egress.secure_mesh_v2.api_release_tag
    dns = {
      direction    = "egress"
      protocols    = ["udp", "tcp"]
      port         = 53
      destinations = data.xcsh_network_customer_edge_defaults.system_services.dns_servers
    }
    ntp = {
      direction    = "egress"
      protocols    = ["udp"]
      port         = 123
      destinations = data.xcsh_network_customer_edge_defaults.system_services.ntp_servers
    }
    https = {
      direction    = "egress"
      protocols    = ["tcp"]
      port         = 443
      destinations = data.xcsh_network_customer_edge_egress.secure_mesh_v2.domains
    }
  }
}
