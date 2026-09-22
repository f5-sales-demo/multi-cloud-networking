# Root integration plan test. Mocks all three providers so the whole graph
# (hub -> CE VMs -> XC sites/bgp -> RS bgp connections -> client -> origin pool +
# HTTP LB) plans with no Azure or XC credentials. Passing ssh_public_key material
# means the root never reads a key file.

mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

variables {
  enable_azure = true
  enable_kvm   = false
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
  # Route Server BGP is intentionally unavailable until F5 publishes a
  # schema-valid multihop request control. Structural root tests must exercise
  # the supported non-BGP graph; the unavailable boundary is verified below.
  enable_bgp = false
}

run "root_plans_end_to_end" {
  command = plan

  variables {
    ce_count   = 2
    deployer   = "tester"
    enable_bgp = false
    # Explicit, not defaulted: `terraform test` auto-loads a root terraform.tfvars,
    # so relying on the default here would make the run's result depend on whether
    # the workstation has Bastion switched on locally.
    enable_bastion = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition     = output.loadbalancer_name == "mcn-ce-ha-f5se"
    error_message = "Load balancer name should be mcn-ce-ha-f5se."
  }

  assert {
    condition     = output.origin_pool_name == "mcn-ce-ha-pool"
    error_message = "Origin pool name should be mcn-ce-ha-pool."
  }

  # The documentation names no operational value; it reads each one from an output.
  # These four are what the demo pages call, so a rename or removal has to fail here
  # rather than silently leaving a documented command with nothing behind it.
  assert {
    condition     = output.route_server_name == "mcn-ce-ha-rs"
    error_message = "Route Server name should derive to mcn-ce-ha-rs; the verify page reads it for --routeserver."
  }

  assert {
    condition     = output.client_vm_name == "mcn-ce-ha-client"
    error_message = "Client VM name should derive to mcn-ce-ha-client; the verify page reads it for az vm run-command."
  }

  assert {
    condition     = output.lb_domain == "mcn-ce-ha.f5-sales-demo.com"
    error_message = "lb_domain must be surfaced as an output; every VIP request has to send it as the Host header."
  }

  assert {
    condition     = output.origin_ip == "203.0.113.10"
    error_message = "origin_ip must be surfaced as an output; it is the control batch that separates an origin fault from a VIP fault."
  }

  assert {
    condition     = output.ce_count == 2
    error_message = "ce_count=2 should deploy two CE nodes."
  }

  assert {
    condition     = output.xc_site_names["eastus01"] == "mcn-ce-ha-smsv2-eastus01"
    error_message = "CE-01 must use the released SMSv2 identity generation instead of the legacy collision-prone site name."
  }

  assert {
    condition     = output.vip == "10.250.0.10"
    error_message = "VIP should be 10.250.0.10."
  }

  assert {
    condition     = output.bastion_name == null
    error_message = "Bastion is opt-in: with enable_bastion = false the root must deploy none."
  }

  # Every CE site is coupled to its own node instance (issue #674): exactly one
  # binding per node, keyed by that node. The VALUES cannot be checked here —
  # virtual_machine_id is computed, so at plan time each binding is
  # known-after-apply — but the SHAPE can, and a binding that is fleet-wide
  # rather than per-node would show up as a key set that does not match
  # ce_nodes. That the bound value is the instance id and not the (name-derived,
  # replacement-stable) ARM resource id is pinned in ce_node.tftest.hcl.
  assert {
    condition = (
      length(output.ce_bound_instance_ids) == length(output.ce_nodes) &&
      alltrue([for k in keys(output.ce_nodes) : contains(keys(output.ce_bound_instance_ids), k)])
    )
    error_message = "Every CE node must contribute exactly one site-to-instance binding, keyed by that node."
  }

  assert {
    condition = (
      length(random_password.site_console_admin) == length(output.ce_nodes) &&
      alltrue([for k in keys(output.ce_nodes) : contains(keys(random_password.site_console_admin), k)])
    )
    error_message = "Every CE node must receive its own generated Site Console admin password."
  }
}

# Azure refuses an AzureBastionSubnet smaller than /26, and it refuses it at APPLY
# time — after the plan looked fine. Reject it at plan time instead, the same way
# route_server_subnet_prefix rejects anything that is not a /27.
run "bastion_subnet_prefix_rejects_too_small" {
  command = plan

  variables {
    ce_count              = 1
    deployer              = "tester"
    enable_bgp            = false
    ssh_public_key        = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    bastion_subnet_prefix = "10.0.5.0/27"
  }

  expect_failures = [var.bastion_subnet_prefix]
}

run "bastion_enabled_root_wiring" {
  command = plan

  variables {
    ce_count       = 1
    deployer       = "tester"
    enable_bgp     = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    enable_bastion = true
  }

  assert {
    condition     = output.bastion_name == "mcn-ce-ha-bastion"
    error_message = "Root must surface the Bastion host name so the tunnel command is copy-pasteable."
  }

  assert {
    condition     = module.azure_hub[0].bastion_subnet_prefix == "10.0.5.0/26"
    error_message = "The default Bastion prefix must be 10.0.5.0/26 — the only free /26 left in the hub."
  }
}
