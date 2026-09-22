# Contract-v1 must keep Secure Mesh topology logical and SLO-only.  These are
# root-module plan tests with mocks, so they prove the preflight fails before
# a live Azure or XC operation can be attempted.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

variables {
  enable_azure           = true
  enable_kvm             = false
  site_prefix            = null
  lb_name                = null
  origin_pool_name       = null
  route_server_name      = null
  bastion_name           = null
  client_vm_name         = null
  region_short           = null
  resource_group_name    = null
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  enable_aws             = false
  enable_aws_tgw_connect = false
}

run "slo_only_is_the_default_logical_shape" {
  command = plan

  variables {
    ce_count       = 3
    deployer       = "tester"
    enable_bastion = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l interface-contract-test-only"
  }

  assert {
    condition = (
      var.enable_expanded_ce_interfaces == false &&
      local.securemesh_interface_contract_v1.bindable_roles == toset(["slo"])
    )
    error_message = "Interface contract v1 must expose only the SLO role by default."
  }

  assert {
    condition = (
      toset(keys(local.expected_slo_bindings)) == toset([
        "f5-xc-ce-vm-01",
        "f5-xc-ce-vm-02",
        "f5-xc-ce-vm-03",
      ]) &&
      alltrue([for hostname in keys(local.expected_slo_bindings) :
        local.expected_slo_bindings[hostname].cloud_nic_position == 1
      ])
    )
    error_message = "Every CE node must have exactly one first-NIC logical SLO binding."
  }
}

run "expanded_interfaces_fail_before_any_mapping_is_inferred" {
  command = plan

  variables {
    ce_count                                               = 1
    deployer                                               = "tester"
    enable_bastion                                         = false
    enable_expanded_ce_interfaces                          = true
    expanded_ce_interfaces_maintenance_window_acknowledged = true
    ssh_public_key                                         = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l interface-contract-test-only"
  }

  expect_failures = [check.securemesh_expanded_interfaces_are_evidence_bound]
}

run "evidence_freshness_window_is_bounded" {
  command = plan

  variables {
    ce_count                            = 1
    deployer                            = "tester"
    enable_bastion                      = false
    ce_interface_evidence_max_age_hours = 0
    ssh_public_key                      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l interface-contract-test-only"
  }

  expect_failures = [var.ce_interface_evidence_max_age_hours]
}
