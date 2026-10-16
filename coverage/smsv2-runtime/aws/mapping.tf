locals {
  mapping = var.phase == "configured" && var.device_mapping_file != null ? jsondecode(file(var.device_mapping_file)) : {
    schema_version = 1
    task_id        = ""
    bootstrap_site = ""
    entries        = []
    checksum       = ""
  }
  mapping_entries = try(local.mapping.entries, [])
  mapping_payload = {
    schema_version = local.mapping.schema_version
    task_id        = local.mapping.task_id
    bootstrap_site = local.mapping.bootstrap_site
    entries        = local.mapping_entries
  }
  devices = {
    slo = try(one([for entry in local.mapping_entries : entry.device if entry.role == "slo" && lower(entry.mac) == lower(aws_network_interface.slo.mac_address)]), "")
    sli = try(one([for entry in local.mapping_entries : entry.device if entry.role == "sli" && lower(entry.mac) == lower(aws_network_interface.sli.mac_address)]), "")
  }
  mapping_valid = (
    try(local.mapping.schema_version, 0) == 1 &&
    try(local.mapping.task_id, "") == var.task_id &&
    try(local.mapping.bootstrap_site, "") == "${var.task_id}-bootstrap" &&
    try(local.mapping.checksum, "") == sha256(jsonencode(local.mapping_payload)) &&
    length(local.mapping_entries) == 2 &&
    try(length(distinct([for entry in local.mapping_entries : entry.role])), 0) == 2 &&
    try(local.devices.slo != "" && local.devices.sli != "" && local.devices.slo != local.devices.sli, false)
  )
}
