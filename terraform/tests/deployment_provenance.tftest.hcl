mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}
mock_provider "docker" {}

variables {
  source_repository   = "f5-sales-demo/multi-cloud-networking"
  source_ref          = "refs/heads/feature/a"
  source_commit_sha   = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  deployment_owner_id = "showcase-team"
  deployment_actor_id = "github-actions"
  lb_domain           = "mcn-ce-ha.example.com"
  ca_lb_domain        = "mcn-ce-ha.example.ca"
  aws_lb_domain       = "aws.mcn-ce-ha.example.com"
  origin_ip           = "203.0.113.10"
  deployer            = "tester"
  ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  enable_azure        = false
  enable_canada       = false
  enable_aws          = false
  enable_kvm          = false
  enable_bgp          = false
  tags = {
    managed_by        = "forged"
    mcn_environment   = "production"
    mcn_source_commit = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    unrelated         = "preserved"
  }
}

run "preview_identity_isolated_and_protected" {
  command = plan

  assert {
    condition     = output.deployment_provenance.environment_key == "feature-a-3556d0cec0c1"
    error_message = "Preview environment key must match the canonical full-ref hash."
  }

  assert {
    condition     = output.deployment_provenance.state_key == "mcn-ce-ha-smsv2/environments/feature-a-3556d0cec0c1/showcase.tfstate"
    error_message = "Preview state must be isolated below its environment key."
  }

  assert {
    condition     = local.site_prefix == "mcn-feature-a-3556d0cec0c1" && local.aws_resource_prefix == "mcn-3556d0cec0c1" && local.route_server_name == "mcn-ce-ha-rs-feature-a-3556d0cec0c1"
    error_message = "Preview physical names must include the environment identity."
  }

  assert {
    condition     = output.lb_domain == "feature-a-3556d0cec0c1.mcn-ce-ha.example.com" && output.aws_lb_domain == "feature-a-3556d0cec0c1.aws.mcn-ce-ha.example.com"
    error_message = "Preview load-balancer hosts must be isolated below the shared parent domain."
  }

  assert {
    condition     = local.tags.managed_by == "terraform" && local.tags.mcn_environment == "feature-a-3556d0cec0c1" && local.tags.mcn_source_commit == var.source_commit_sha && local.tags.unrelated == "preserved"
    error_message = "Protected provenance must override forged caller tags while preserving unrelated metadata."
  }

  assert {
    condition     = local.azure_xc_labels["mcn-environment"] == "feature-a-3556d0cec0c1" && local.azure_xc_labels["mcn-source-commit"] == var.source_commit_sha && local.ca_xc_labels["mcn-owner-id"] == var.deployment_owner_id
    error_message = "XC metadata maps must carry the protected environment, revision, and owner identity."
  }
}

run "preview_kvm_requires_separate_allocation" {
  command = plan

  variables {
    enable_kvm = true
  }

  expect_failures = [terraform_data.deployment_identity_guard]
}

run "unicode_only_slug_matches_executable_identity" {
  command = plan

  variables {
    source_ref = "refs/heads/é"
  }

  assert {
    condition     = output.deployment_provenance.environment_key == "branch-b617043d4981"
    error_message = "Terraform and the executable helper must serialize and normalize Unicode refs identically."
  }
}

run "production_identity_preserves_existing_names" {
  command = plan

  variables {
    source_ref = "refs/heads/main"
  }

  assert {
    condition     = output.deployment_provenance.production && output.deployment_provenance.environment_key == "production"
    error_message = "Exact refs/heads/main must be the only production identity."
  }

  assert {
    condition     = output.deployment_provenance.state_key == "mcn-ce-ha-smsv2/showcase.tfstate" && local.site_prefix == "mcn-ce-ha-smsv2" && local.route_server_name == "mcn-ce-ha-rs"
    error_message = "Production state and physical names must remain unchanged."
  }

  assert {
    condition     = output.lb_domain == var.lb_domain && output.ca_lb_domain == var.ca_lb_domain && output.aws_lb_domain == var.aws_lb_domain
    error_message = "Production domains must remain unchanged."
  }
}
