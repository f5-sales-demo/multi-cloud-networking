# Plan-level test for the xc-site module's registration approval wiring: the
# xcsh_site_registration data source resolves a CE's runtime registration name
# ("r-<uuid>" — the site name itself is NOT a registration) and the approval
# resource is gated on that lookup plus var.approve_registration.
#
# override_data pins the data source so the three gates are deterministic
# without contacting XC. Every run is MODULE-scoped: mixing module- and
# root-scoped runs under one mock_provider "xcsh" throws a provider type
# mismatch. That means these runs exercise ONE module instance directly — they
# say nothing about the root module's per-CE for_each fan-out, which is never
# instantiated here.

mock_provider "xcsh" {}

# Gate 1 — the CE has not registered yet (registrations_by_site returned
# items: []). The data source reports found = false with no error, so the
# approval must not be planned at all.
run "no_approval_before_the_ce_registers" {
  command = plan

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name         = "mcn-ce-ha-eastus01"
    hostname          = "f5-xc-ce-vm-01"
    interface_name    = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac      = "7c:1e:52:18:c1:77"
    ce_vm_instance_id = "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    peer_ips          = ["10.0.1.20", "10.0.1.21"]
    ce_asn            = 64512
    peer_asn          = 65020
    # Not under test here; the real 71-char interface name is covered by bgp.tftest.hcl.
    enable_bgp           = false
    approve_registration = true
  }

  override_data {
    target = data.xcsh_site_registration.this
    values = {
      found = false
      name  = null
      state = null
    }
  }

  assert {
    condition     = length(xcsh_registration_approval.this) == 0
    error_message = "No approval may be planned while the CE registration does not exist (found = false)."
  }

  assert {
    condition     = output.registration_approval_name == null
    error_message = "registration_approval_name must be null when no approval is planned."
  }

  assert {
    condition     = output.registration_name == null
    error_message = "registration_name must be null until the CE has registered."
  }
}

# Gate 2 — the CE has registered in NEW. Exactly one approval is planned, carrying the
# resolved r-<uuid> name (NOT the site name) in the system namespace.
run "new_registration_uses_the_resolved_registration_name" {
  command = plan

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name            = "mcn-ce-ha-eastus01"
    hostname             = "f5-xc-ce-vm-01"
    interface_name       = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac         = "7c:1e:52:18:c1:77"
    ce_vm_instance_id    = "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    peer_ips             = ["10.0.1.20", "10.0.1.21"]
    ce_asn               = 64512
    peer_asn             = 65515
    enable_bgp           = false
    approve_registration = true
  }

  override_data {
    target = data.xcsh_site_registration.this
    values = {
      found = true
      name  = "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
      state = "NEW"
    }
  }

  assert {
    condition     = length(xcsh_registration_approval.this) == 1
    error_message = "Exactly one approval must be planned once the registration is found."
  }

  assert {
    condition     = xcsh_registration_approval.this[0].name == "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
    error_message = "The approval must target the resolved r-<uuid> registration name, not the site name."
  }

  assert {
    condition     = xcsh_registration_approval.this[0].namespace == "system"
    error_message = "Registrations are approved in the system namespace."
  }

  assert {
    condition     = xcsh_registration_approval.this[0].state == "APPROVED"
    error_message = "The approval must request state APPROVED."
  }

  assert {
    condition     = output.registration_name == "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
    error_message = "registration_name must expose the resolved r-<uuid> name."
  }

  assert {
    condition     = output.registration_state == "NEW"
    error_message = "registration_state must expose the NEW state reported by XC."
  }
}

# Gate 3 — an operator owns approval. Even with the registration resolved,
# approve_registration = false plans nothing.
run "approve_registration_false_plans_no_approval" {
  command = plan

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name            = "mcn-ce-ha-eastus01"
    hostname             = "f5-xc-ce-vm-01"
    interface_name       = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac         = "7c:1e:52:18:c1:77"
    ce_vm_instance_id    = "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    peer_ips             = ["10.0.1.20", "10.0.1.21"]
    ce_asn               = 64512
    peer_asn             = 65515
    enable_bgp           = false
    approve_registration = false
  }

  override_data {
    target = data.xcsh_site_registration.this
    values = {
      found = true
      name  = "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
      state = "ONLINE"
    }
  }

  assert {
    condition     = length(xcsh_registration_approval.this) == 0
    error_message = "approve_registration = false must plan no approval even when the registration exists."
  }

  assert {
    condition     = output.registration_name == "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
    error_message = "The lookup still resolves the registration name when approval is disabled."
  }
}

# Gate 4 — terminal registrations are retained by some installed provider
# versions, but XC forbids RETIRED -> APPROVED. The module itself must keep the
# action out of the graph so a stale registration cannot fail a recovery apply.
run "retired_registration_plans_no_approval" {
  command = plan

  module {
    source = "./modules/xc-site"
  }

  variables {
    site_name            = "mcn-ce-ha-eastus01"
    hostname             = "f5-xc-ce-vm-01"
    interface_name       = "ves-io-securemesh-site-v2-mcn-ce-ha-eastus01-network-f5-xc-ce-vm-01-eth0-0"
    mgmt_nic_mac         = "7c:1e:52:18:c1:77"
    ce_vm_instance_id    = "89e6c538-6bc2-4c2c-a37e-d6149c1708ce"
    peer_ips             = ["10.0.1.20", "10.0.1.21"]
    ce_asn               = 64512
    peer_asn             = 65515
    enable_bgp           = false
    approve_registration = true
  }

  override_data {
    target = data.xcsh_site_registration.this
    values = {
      found = true
      name  = "r-dcec2400-52d5-4154-9fd0-4b042d3fe18d"
      state = "RETIRED"
    }
  }

  assert {
    condition     = length(xcsh_registration_approval.this) == 0
    error_message = "A RETIRED registration must never plan an APPROVED transition."
  }
}
