# The Azure Secure Mesh interface contract v1 is deliberately SLO-only. The artifact
# captured by scripts/capture_ce_interface_evidence.py may diagnose Azure NIC
# identities, but it cannot make external or SLI configurable without a later
# immutable contract revision that publishes their F5 control-plane mappings.

variable "enable_expanded_ce_interfaces" {
  description = "Request external/SLI CE interfaces. Defaults false and fails closed under interface contract v1."
  type        = bool
  default     = false
}

variable "ce_interface_evidence_file" {
  description = "Path to a sanitized securemesh-ce-interface-evidence.json artifact. Required before any future expanded-interface rollout."
  type        = string
  default     = null
  nullable    = true
}

variable "ce_interface_evidence_max_age_hours" {
  description = "Maximum age of a sanitized CE interface evidence artifact when expansion is requested."
  type        = number
  default     = 24

  validation {
    condition     = var.ce_interface_evidence_max_age_hours > 0 && var.ce_interface_evidence_max_age_hours <= 168
    error_message = "ce_interface_evidence_max_age_hours must be between one hour and seven days."
  }
}

variable "expanded_ce_interfaces_maintenance_window_acknowledged" {
  description = "Explicit acknowledgement that adding or removing CE interfaces restarts data-plane services."
  type        = bool
  default     = false
}

locals {
  securemesh_interface_contract_v1 = {
    version        = "1.0.0"
    bindable_roles = toset(["slo"])
    stable_identity = toset([
      "node_hostname",
      "cloud_nic_position",
      "nic_mac",
      "ip_configuration",
      "subnet",
      "control_plane_interface_reference",
    ])
  }

  ce_interface_evidence = var.ce_interface_evidence_file == null ? null : jsondecode(file(var.ce_interface_evidence_file))
  ce_evidence_nodes_by_hostname = local.ce_interface_evidence == null ? {} : {
    for node in try(local.ce_interface_evidence.nodes, []) : node.node_hostname => node
  }

  expected_slo_bindings = var.enable_azure ? {
    for key, node in module.ce_topology.ce_nodes : node.hostname => {
      cloud_nic_position = 1
      nic_mac            = module.ce_node[key].mgmt_nic_mac
      private_ip         = module.ce_node[key].mgmt_private_ip
      subnet_resource_id = module.azure_hub[0].management_subnet_id
    }
  } : {}

  evidence_is_current = local.ce_interface_evidence != null && try(
    timecmp(timestamp(), timeadd(local.ce_interface_evidence.captured_at_utc, "${var.ce_interface_evidence_max_age_hours}h")) < 0,
    false,
  )

  evidence_matches_planned_slo = local.ce_interface_evidence != null && alltrue([
    for hostname, expected in local.expected_slo_bindings :
    try(local.ce_evidence_nodes_by_hostname[hostname].slo_binding.cloud_nic_position, 0) == expected.cloud_nic_position &&
    lower(try(local.ce_evidence_nodes_by_hostname[hostname].slo_binding.nic_mac, "")) == lower(expected.nic_mac) &&
    try(local.ce_evidence_nodes_by_hostname[hostname].slo_binding.private_ip, "") == expected.private_ip &&
    try(local.ce_evidence_nodes_by_hostname[hostname].slo_binding.subnet_resource_id, "") == expected.subnet_resource_id &&
    trimspace(try(local.ce_evidence_nodes_by_hostname[hostname].slo_binding.control_plane_interface_reference, "")) != ""
  ])
}

check "securemesh_expanded_interfaces_are_evidence_bound" {
  assert {
    condition = !var.enable_expanded_ce_interfaces || (
      var.expanded_ce_interfaces_maintenance_window_acknowledged &&
      local.ce_interface_evidence != null &&
      try(local.ce_interface_evidence.evidence_status, "") == "slo_reference_complete" &&
      local.evidence_is_current &&
      local.evidence_matches_planned_slo &&
      contains(local.securemesh_interface_contract_v1.bindable_roles, "external") &&
      contains(local.securemesh_interface_contract_v1.bindable_roles, "sli")
    )
    error_message = "Expanded CE interfaces are disabled by interface contract v1. A future immutable contract must bind external and SLI, and a current sanitized evidence artifact must match every planned SLO MAC/private-IP/subnet/control-plane reference during an approved maintenance window."
  }
}
