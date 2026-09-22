# Root plan test for the provider-generated CE registration token. Mocks all
# three providers so the graph plans with no Azure or XC credentials. Proves the
# xcsh_token.ce resource is planned and that the CE cloud-init token feed
# resolves to xcsh_token.ce.uid by default, while an explicit
# var.registration_token still overrides it.

mock_provider "azurerm" {}
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
  enable_azure           = true
  enable_canada          = false
  enable_kvm             = false
  enable_aws             = false
  enable_aws_tgw_connect = false
}

# Default (registration_token = ""): the generated token is used.
run "generated_token_is_used" {
  command = plan

  variables {
    ce_count       = 1
    deployer       = "tester"
    enable_bgp     = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  # The xcsh_token.ce resource is planned with the expected metadata.
  assert {
    condition     = xcsh_token.ce[0].name == "mcn-ce-ha-smsv2-registration"
    error_message = "The CE registration token resource must use the permanent mcn-ce-ha-smsv2 identity."
  }

  assert {
    condition     = xcsh_token.ce[0].namespace == "system"
    error_message = "The CE registration token must live in the system namespace."
  }

  # No override => the cloud-init feed selects the generated xcsh_token.ce.uid.
  assert {
    condition     = output.registration_token_is_generated == true
    error_message = "With registration_token empty, the token feed must use the generated xcsh_token.ce.uid."
  }
}

# Explicit override: var.registration_token wins over the generated token.
run "override_token_wins" {
  command = plan

  variables {
    ce_count           = 1
    deployer           = "tester"
    enable_bgp         = false
    registration_token = "externally-minted-token-abc123"
    ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition     = output.registration_token_is_generated == false
    error_message = "A non-empty registration_token must override the generated token feed."
  }

  # The resolved token fed to cloud-init equals the supplied override.
  assert {
    condition     = output.ce_registration_token == "externally-minted-token-abc123"
    error_message = "The cloud-init token feed must resolve to the var.registration_token override."
  }
}
