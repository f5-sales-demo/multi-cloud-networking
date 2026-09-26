# Provider-defined actions remain asynchronous. Operators invoke software and
# then OS for one site at a time; the read-only status data source supplies the
# bounded convergence gate.
action "xcsh_site_upgrade_sw" "aws" {
  for_each = local.aws_sites

  config {
    site             = each.value.name
    software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)
  }
}

action "xcsh_site_upgrade_os" "aws" {
  for_each = local.aws_sites

  config {
    site       = each.value.name
    os_version = coalesce(var.aws_upgrade_os_version, var.aws_os_version)
  }
}

data "xcsh_site_upgrade_status" "aws" {
  for_each = {
    for key, site in local.aws_sites : key => site
    if var.aws_site_configuration_phase == "configured" && var.enable_aws_tgw_connect && contains(var.aws_upgrade_observed_sites, key)
  }

  site                      = xcsh_securemesh_site_v2.aws[each.key].name
  expected_software_version = coalesce(var.aws_upgrade_software_version, var.aws_software_version)
  expected_os_version       = coalesce(var.aws_upgrade_os_version, var.aws_os_version)
  wait                      = var.aws_upgrade_wait
  timeout_seconds           = var.aws_upgrade_timeout_seconds
  poll_interval_seconds     = var.aws_upgrade_poll_interval_seconds

  # A fresh site has no status object until its CE runtime is published. The
  # TGW-disabled configured creation phase has no runtime gate (count zero),
  # so select observations only after TGW enables that readiness boundary.
  depends_on = [terraform_data.aws_tgw_runtime_gate]
}

output "aws_site_upgrade_status" {
  description = "Sanitized per-site software, OS, readiness, eligibility, and convergence observations."
  value = {
    for key, status in data.xcsh_site_upgrade_status.aws : key => {
      site                         = local.aws_sites[key].name
      software_installed_version   = status.software_installed_version
      software_available_version   = status.software_available_version
      software_deployment_phase    = status.software_deployment_phase
      software_deployment_result   = status.software_deployment_result
      os_installed_version         = status.os_installed_version
      os_available_version         = status.os_available_version
      os_deployment_phase          = status.os_deployment_phase
      os_deployment_result         = status.os_deployment_result
      site_state                   = status.site_state
      upgradable_software_versions = status.upgradable_software_versions
      failed_precheck_names        = status.failed_precheck_names
      eligible                     = status.eligible
      ready                        = status.ready
      target_converged             = status.target_converged
    }
  }
}

output "aws_upgrade_convergence" {
  description = "Aggregate configured runtime identities and current convergence for the AWS sites."
  value = var.enable_aws ? {
    software      = coalesce(var.aws_upgrade_software_version, var.aws_software_version)
    os            = coalesce(var.aws_upgrade_os_version, var.aws_os_version)
    all_ready     = alltrue([for status in values(data.xcsh_site_upgrade_status.aws) : status.ready])
    all_converged = alltrue([for status in values(data.xcsh_site_upgrade_status.aws) : status.target_converged])
  } : null
}
