terraform {
  required_version = "= 1.16.5"
  required_providers {
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 15.9.0"
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
