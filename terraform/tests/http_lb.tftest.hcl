# Root plan test focused on the HTTP load balancer data-plane: the VIP is
# advertised per CE site (advertise_custom) and the LB serves the configured
# domain and default route pool. Mocks all providers (no credentials).

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
  deployer               = "tester"
  # enable_bgp left at its true default; the LB/advertise/origin-pool under test are
  # independent of bgp either way. It used to be forced false only to dodge the provider's
  # object-ref name length cap, relaxed in v3.74.0.
  ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  # Pinned rather than inherited: `terraform test` also reads the gitignored
  # terraform.tfvars, so an assertion against a hard-coded namespace literal would
  # pass in CI and fail for any engineer whose app namespace differs.
  xc_app_namespace = "multi-cloud-networking"
}

run "loadbalancer_advertise_and_pool" {
  command = plan

  variables {
    ce_count = 3
  }

  # The dynamic advertise_where block (one entry per CE site) is exercised by
  # this run planning cleanly at N=3 — an expansion error would fail the run.

  assert {
    condition     = xcsh_http_loadbalancer.this[0].namespace == var.xc_app_namespace
    error_message = "LB must live in the app namespace named by xc_app_namespace."
  }

  assert {
    condition     = length(xcsh_http_loadbalancer.this[0].domains) == 1 && contains(xcsh_http_loadbalancer.this[0].domains, "mcn-ce-ha.f5-sales-demo.com")
    error_message = "LB should serve exactly mcn-ce-ha.f5-sales-demo.com."
  }

  assert {
    condition     = xcsh_origin_pool.this[0].namespace == var.xc_app_namespace
    error_message = "Origin pool must live in the app namespace named by xc_app_namespace."
  }

  assert {
    condition     = xcsh_origin_pool.this[0].port == 80
    error_message = "Origin pool port should be 80."
  }

  # The Sales Demo tenant serves this hostname as a non-delegated domain.
  # Attempting to change an existing non-delegated domain to tenant-managed DNS
  # is an unsupported API transition, so the marker must remain omitted.
  assert {
    condition     = xcsh_http_loadbalancer.this[0].http.dns_volterra_managed == null
    error_message = "The US showcase HTTP LB must remain a non-delegated Sales Demo domain."
  }
}

# The app namespace is read, never owned (#634, #637): a managed xcsh_namespace
# resource would put a namespace this stack cannot recreate — and every unrelated
# object living in it — on the destroy list. Sourcing the pool/LB namespace from
# the data source is what keeps it off that list, so assert the wiring: these
# references stop resolving the moment anyone reintroduces the resource.
run "app_namespace_is_read_not_owned" {
  command = plan

  variables {
    ce_count = 1
  }

  assert {
    condition     = data.xcsh_namespace.mcn.name == var.xc_app_namespace
    error_message = "The app namespace must be looked up by the xc_app_namespace input."
  }

  # A namespace object is not itself contained in a namespace; the API reports
  # metadata.namespace as "" for one, so the lookup must ask for exactly that.
  assert {
    condition     = data.xcsh_namespace.mcn.namespace == ""
    error_message = "The namespace lookup must use an empty containing namespace."
  }

  assert {
    condition     = xcsh_origin_pool.this[0].namespace == data.xcsh_namespace.mcn.name
    error_message = "The origin pool must take its namespace from the data source, not a bare variable."
  }

  assert {
    condition     = xcsh_http_loadbalancer.this[0].namespace == data.xcsh_namespace.mcn.name
    error_message = "The LB must take its namespace from the data source, not a bare variable."
  }

  # Written as a for-expression because `terraform test` accepts only attribute
  # traversals in a reference, never an index step.
  assert {
    condition = alltrue([
      for route_pool in xcsh_http_loadbalancer.this[0].default_route_pools :
      route_pool.pool.namespace == data.xcsh_namespace.mcn.name
    ])
    error_message = "The default route pool reference must resolve through the data source."
  }
}
