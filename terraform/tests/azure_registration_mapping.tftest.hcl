variables {
  site     = "site-example"
  hostname = "node-example"
  macs     = { slo = "52:54:00:10:00:11", sli = "52:54:00:20:00:11", external = "52:54:00:30:00:11" }
  records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }]
}
run "external_first" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  assert {
    condition     = output.valid && output.devices == { slo = "eth0", sli = "eth2", external = "eth1" }
    error_message = "External-first hardware must resolve inside SLI to eth2."
  }
}
run "inside_first" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "ONLINE", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth2", mac = "52:54:00:30:00:11" },
    { device = "eth1", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = output.valid && output.devices == { slo = "eth0", sli = "eth1", external = "eth2" }
    error_message = "Inside-first hardware must resolve inside SLI to eth1."
  }
}
run "missing" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [] }
  assert {
    condition     = !output.valid
    error_message = "Missing hardware must fail binding."
  }
}

run "retired" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "RETIRED", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "foreign_provider" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AWS", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "foreign_site" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "other-site", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "foreign_hostname" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "other-node", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "duplicate_registration" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
    ] }, { site = "site-example", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "duplicate_device" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth1", mac = "52:54:00:20:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "duplicate_mac" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { records = [{ site = "site-example", hostname = "node-example", provider = "AZURE", state = "PENDING", network = [
    { device = "eth0", mac = "52:54:00:10:00:11" },
    { device = "eth1", mac = "52:54:00:30:00:11" },
    { device = "eth2", mac = "52:54:00:30:00:11" },
  ] }] }
  assert {
    condition     = !output.valid
    error_message = "Invalid registration must not authorize interface binding."
  }
}

run "runtime_supersedes_stale_registration" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables {
    runtime_required = true
    runtime_network = [
      { device = "eth0", mac = "52:54:00:10:00:11" },
      { device = "eth1", mac = "52:54:00:20:00:11" },
      { device = "eth2", mac = "52:54:00:30:00:11" },
    ]
  }
  assert {
    condition     = output.valid && output.devices == { slo = "eth0", sli = "eth1", external = "eth2" }
    error_message = "Admitted nodes must use current runtime MAC/device facts."
  }
}
run "runtime_missing_never_falls_back" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables { runtime_required = true }
  assert {
    condition     = !output.valid
    error_message = "Admitted nodes cannot fall back to stale registration devices."
  }
}
run "runtime_foreign_mac_rejected" {
  command = plan
  module { source = "./modules/azure-registration-mapping" }
  variables {
    runtime_required = true
    runtime_network = [
      { device = "eth0", mac = "52:54:00:10:00:11" },
      { device = "eth1", mac = "52:54:00:20:00:11" },
      { device = "eth2", mac = "52:54:00:40:00:11" },
    ]
  }
  assert {
    condition     = !output.valid
    error_message = "Runtime hardware must cover exactly the three owned NICs."
  }
}
