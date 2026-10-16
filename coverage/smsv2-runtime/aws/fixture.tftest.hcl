mock_provider "aws" {
  mock_resource "aws_eip" { defaults = { public_ip = "192.0.2.10" } }
  mock_resource "aws_network_interface" { defaults = { mac_address = "00:00:5e:00:53:01" } }
  mock_data "aws_availability_zones" { defaults = { names = ["ap-northeast-1a"] } }
}
mock_provider "xcsh" {}
override_data {
  target = data.xcsh_site_registration.ce[0]
  values = { found = false }
}
variables {
  task_id          = "qualification-test"
  region           = "ap-northeast-1"
  xc_tenant        = "qualification-test"
  ce_image_id      = "ami-0123456789abcdef0"
  client_image_id  = "ami-0123456789abcdef1"
  operator_cidr    = "192.0.2.1/32"
  ssh_public_key   = "ssh-ed25519 c3ludGhldGlj qualification-test"
  software_version = "synthetic-version"
  os_version       = "synthetic-os"
}
run "private_client_and_ce_path" {
  command = apply
  assert {
    condition     = !aws_instance.client.associate_public_ip_address
    error_message = "Traffic client must remain private."
  }
  assert {
    condition     = one(aws_route_table.client.route).network_interface_id == aws_network_interface.sli.id
    error_message = "Client Internet traffic must route to the CE SLI."
  }
  assert {
    condition     = length(aws_instance.ce) == 1 && xcsh_securemesh_site_v2.ce[0].name == "qualification-test-bootstrap"
    error_message = "Bootstrap must use one independently named CE."
  }
}
run "retirement_preserves_substrate" {
  command = apply
  variables { phase = "retired" }
  assert {
    condition     = length(aws_instance.ce) == 0 && length(xcsh_securemesh_site_v2.ce) == 0
    error_message = "Retirement removes bootstrap CE and site."
  }
  assert {
    condition     = aws_instance.client.subnet_id == aws_subnet.client.id && aws_instance.origin.subnet_id == aws_subnet.slo.id
    error_message = "Client and origin must remain on the task-owned substrate."
  }
}
run "configured_requires_observation" {
  command = plan
  variables { phase = "configured" }
  expect_failures = [xcsh_securemesh_site_v2.ce]
}

override_resource {
  target = aws_network_interface.slo
  values = { mac_address = "00:00:5e:00:53:01" }
}
override_resource {
  target = aws_network_interface.sli
  values = { mac_address = "00:00:5e:00:53:02" }
}
run "configured_observed_mapping" {
  command = apply
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].name == "qualification-test-configured"
    error_message = "Configured site must use a distinct identity."
  }
}
run "ordered_parent_attachments" {
  command = apply
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
    firewall_policies   = [{ name = "first", namespace = "system" }, { name = "second", namespace = "system" }]
    proxy_policies      = [{ name = "proxy-first", namespace = "system" }, { name = "proxy-second", namespace = "system" }]
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].active_enhanced_firewall_policies.enhanced_firewall_policies[0].name == "first" && xcsh_securemesh_site_v2.ce[0].active_enhanced_firewall_policies.enhanced_firewall_policies[1].name == "second"
    error_message = "Parent firewall association order must be preserved."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].active_forward_proxy_policies.forward_proxy_policies[0].name == "proxy-first"
    error_message = "Parent forward proxy association order must be preserved."
  }
}
