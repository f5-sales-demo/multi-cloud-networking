mock_provider "xcsh" {}
mock_provider "external" {}

variables {
  site_name                  = "site-example"
  hostname                   = "node-example"
  interface_name             = "interface-example"
  mgmt_nic_mac               = "52:54:00:10:00:11"
  inside_nic_mac             = "52:54:00:20:00:11"
  external_nic_mac           = "52:54:00:30:00:11"
  ce_generation_id           = "generation-example"
  peer_ips                   = []
  enable_bgp                 = false
  approve_registration       = false
  bind_registered_interfaces = true
  labels                     = { mcn-xc-tenant = "tenant-example" }
}

override_module {
  target = module.registration_mapping
  outputs = {
    valid   = true
    devices = { slo = "eth0", sli = "eth2", external = "eth1" }
  }
}
override_data {
  target = data.xcsh_site_registration.this
  values = { found = true, state = "ONLINE", name = "registration-example" }
}

run "online_uses_current_runtime_devices" {
  command = plan
  module { source = "./modules/xc-site" }
  override_data {
    target = data.external.runtime_interfaces[0]
    values = { result = { network = jsonencode([
      { device = "eth0", mac = "52:54:00:10:00:11" },
      { device = "eth1", mac = "52:54:00:30:00:11" },
      { device = "eth2", mac = "52:54:00:20:00:11" },
    ]) } }
  }
  assert {
    condition = (
      xcsh_securemesh_site_v2.this[0].azure.not_managed.node_list[0].interface_list[2].network_option.site_local_inside_network != null &&
      xcsh_securemesh_site_v2.this[0].azure.not_managed.node_list[0].interface_list[2].ethernet_interface.mac == "52:54:00:20:00:11" &&
      xcsh_securemesh_site_v2.this[0].azure.not_managed.node_list[0].interface_list[1].network_option.site_local_network != null
    )
    error_message = "ONLINE configuration must use runtime devices while preserving owned NIC roles."
  }
}
run "pending_does_not_read_runtime" {
  command = plan
  module { source = "./modules/xc-site" }
  override_data {
    target = data.xcsh_site_registration.this
    values = { found = true, state = "PENDING", name = "registration-example" }
  }
  assert {
    condition     = length(data.external.runtime_interfaces) == 0
    error_message = "Pre-approval nodes must use registration facts without runtime reads."
  }
}
