# Plan-level tests for the rendered CE cloud-init document.
#
# The document is rendered into local.ce_cloud_init (locals.tf) specifically so that
# its content is assertable here — a templatefile() call inlined in the module block
# is not addressable from a test.
#
# registration_token is pinned to a literal so the rendered document is KNOWN at plan
# time. Left at its default the token comes from xcsh_token.ce.uid, which stays unknown
# until apply even under mock_provider, and every assertion below would fail with
# "Unknown condition value" instead of on its own merits.

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
  ce_count               = 1
  enable_aws             = false
  enable_aws_tgw_connect = false
  deployer               = "tester"
  registration_token     = "plan-test-token"
}

# The operator SSH grant. Asserted as one exact multi-line substring rather than as
# four independent contains() checks, because path, mode, owner, key and the two-space
# YAML indent only mean anything together: a correct mode on the wrong path, or the
# right key under a mis-indented entry, would each pass a looser test and fail on the
# node.
#
# owner: admin:admin resolves at write time because admin (uid 2202) is baked into the
# node image and therefore exists before cloud-init runs — hence no runcmd/chown fixup.
run "cloud_init_authorizes_operator_ssh_for_admin" {
  command = plan

  variables {
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition = strcontains(
      local.ce_cloud_init["eastus01"],
      "  - path: /var/home/admin/.ssh/authorized_keys\n    permissions: \"0600\"\n    owner: admin:admin\n    content: |\n      ${var.ssh_public_key}\n"
    )
    error_message = "CE cloud-init must write the operator key to /var/home/admin/.ssh/authorized_keys as admin:admin mode 0600."
  }
}

# Regression guard: the SSH entry is ADDITIVE. The vpm config is what makes the node
# register at all, so a template edit that displaced or malformed it would cost three
# CE rebuilds to discover.
run "cloud_init_still_writes_the_vpm_config" {
  command = plan

  variables {
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition     = strcontains(local.ce_cloud_init["eastus01"], "  - path: /etc/vpm/config.yaml\n    permissions: \"0600\"\n    owner: root\n")
    error_message = "CE cloud-init must still write /etc/vpm/config.yaml root-only 0600."
  }

  assert {
    condition     = strcontains(local.ce_cloud_init["eastus01"], "    Token: plan-test-token\n")
    error_message = "CE cloud-init must still carry the registration token into the vpm config."
  }

  assert {
    condition     = strcontains(local.ce_cloud_init["eastus01"], "    ClusterName: mcn-ce-ha-smsv2-eastus01\n")
    error_message = "CE cloud-init must carry the generated SMSv2 site identity as ClusterName."
  }

  assert {
    condition     = startswith(local.ce_cloud_init["eastus01"], "#cloud-config\n")
    error_message = "The rendered document must still begin with the #cloud-config header."
  }
}

# A public key read from a .pub file carries a trailing newline. Interpolated raw under
# `content: |` that newline renders a second, empty line into the key file, so the key
# is chomped. Passing the key WITH a trailing newline here reproduces exactly what
# file() yields on the real path (locals.tf falls back to file(var.ssh_public_key_path)).
run "cloud_init_chomps_trailing_newline_on_the_key" {
  command = plan

  variables {
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l chomp-test\n"
  }

  assert {
    condition     = !strcontains(local.ce_cloud_init["eastus01"], "chomp-test\n\n")
    error_message = "A trailing newline on the public key must be chomped, or a blank line lands in authorized_keys."
  }

  assert {
    condition     = strcontains(local.ce_cloud_init["eastus01"], "      ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l chomp-test\n")
    error_message = "The chomped key must still be written, indented under content:."
  }
}

# Every node gets the key, not just the first. ce_count=3 is the demo shape.
run "every_ce_node_gets_the_operator_key" {
  command = plan

  variables {
    ce_count       = 3
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition = alltrue([
      for k, doc in local.ce_cloud_init :
      strcontains(doc, "  - path: /var/home/admin/.ssh/authorized_keys\n") && strcontains(doc, "      ${var.ssh_public_key}\n")
    ])
    error_message = "Every CE node's cloud-init must authorize the operator key."
  }

  assert {
    condition     = length(local.ce_cloud_init) == 3
    error_message = "ce_count=3 must render three cloud-init documents."
  }
}
