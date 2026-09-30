# Tenant guard (issue #696).
#
# The F5 XC tenant used to be decided entirely by XCSH_API_URL in the operator's
# shell. When that value drifted, the whole demo silently rebuilt itself in another
# tenant and every plan in between was clean. The tenant is now config:
# var.expected_xc_tenant names it, providers.tf derives the xcsh api_url from it,
# and data.external.xc_env_tenant fails the plan when the environment disagrees.
#
# What is asserted here is the part that is deterministic on any machine: the
# variable's own validation, and the endpoint derived from it. The mismatch branch
# of the guard depends on XCSH_API_URL, which a .tftest.hcl cannot set — that
# branch is unit-tested in ../../tests/test-xc-env-tenant.sh, which drives the
# program directly with the environment it wants.
#
# data.external is NOT mocked: the program reads the environment and makes no
# network call, so running it for real is what proves the guard is credential-free.
# With XCSH_API_URL unset (CI) it reports an empty tenant and the guard abstains.

mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { mac_address = "52:54:00:10:00:11" }
  }
}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

variables {
  # Explicitly null so these assert the DERIVED names no matter what a local
  # terraform.tfvars pins — `terraform test` reads that file too, so without this a
  # deployment holding older names steady would turn this suite red on the
  # engineer's machine while CI, which has no tfvars, stayed green.
  site_prefix         = null
  lb_name             = null
  origin_pool_name    = null
  route_server_name   = null
  bastion_name        = null
  client_vm_name      = null
  region_short        = null
  resource_group_name = null
  # Pinned rather than inherited. Both now have NO default (an origin default is
  # one specific machine; an lb_domain default belongs to whoever deploys), and
  # `terraform test` also reads the gitignored terraform.tfvars — so without these
  # CI fails on a missing required variable and any assertion against them depends
  # on whose workstation ran the test. 203.0.113.0/24 is RFC 5737 documentation
  # space: unroutable by design, so it cannot name a real host.
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  enable_aws             = false
  enable_aws_tgw_connect = false
  ce_count               = 1
  deployer               = "tester"
  enable_bastion         = false
  ssh_public_key         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
}

# The default is the tenant this deployment belongs to, and the API endpoint is
# derived from it rather than read from the environment. Left at the default
# deliberately: any other value would trip the guard on a workstation that has the
# real (f5-sales-demo) credential sourced.
run "api_url_is_derived_from_the_tenant" {
  command = plan

  assert {
    condition     = output.xc_tenant == "f5-sales-demo"
    error_message = "This deployment belongs to the f5-sales-demo tenant; that must be the default, not something the environment supplies."
  }

  assert {
    condition     = output.xc_api_url == "https://f5-sales-demo.console.ves.volterra.io"
    error_message = "The xcsh endpoint must be derived from expected_xc_tenant, so naming the tenant is the only input needed."
  }

  # The guard's invariant, stated as an assertion: a plan only gets this far when
  # the environment either agrees with the configured tenant or says nothing.
  # Both outcomes are legitimate — "" is CI, where XCSH_API_URL is unset — and any
  # third value means the postcondition should already have aborted the plan.
  assert {
    condition     = contains(["", "f5-sales-demo"], output.xc_env_tenant)
    error_message = "A plan that reaches its assertions must have agreed with the environment, or found no XCSH_API_URL at all."
  }
}

# A URL is the mistake somebody will actually make, because XCSH_API_URL is a URL.
# Reject it at plan time rather than building https://https://... and failing at
# the first API call.
run "rejects_a_url_instead_of_a_tenant" {
  command = plan

  variables {
    expected_xc_tenant = "https://f5-sales-demo.console.ves.volterra.io"
  }

  expect_failures = [var.expected_xc_tenant]
}

run "rejects_a_hostname_instead_of_a_tenant" {
  command = plan

  variables {
    expected_xc_tenant = "f5-sales-demo.console.ves.volterra.io"
  }

  expect_failures = [var.expected_xc_tenant]
}

# Hostname labels are case-insensitive but the tenant string is compared verbatim
# against what the program parses out of XCSH_API_URL, so only one spelling can be
# correct.
run "rejects_uppercase" {
  command = plan

  variables {
    expected_xc_tenant = "F5-Sales-Demo"
  }

  expect_failures = [var.expected_xc_tenant]
}

# An empty tenant would derive https://.console.ves.volterra.io and, worse, make
# the guard's "" abstain value compare equal to a real mismatch.
run "rejects_empty" {
  command = plan

  variables {
    expected_xc_tenant = ""
  }

  expect_failures = [var.expected_xc_tenant]
}
