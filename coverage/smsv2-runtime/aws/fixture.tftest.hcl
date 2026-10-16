mock_provider "aws" {
  mock_resource "aws_instance" { defaults = { public_ip = "192.0.2.20" } }
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
override_data {
  target = data.aws_ami.ce
  values = { id = "ami-0123456789abcdef0" }
}
override_data {
  target = data.aws_ami.client
  values = { id = "ami-0123456789abcdef1" }
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

run "attachment_keeps_instance" {
  command = plan
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
    firewall_policies   = [{ name = "replacement", namespace = "system" }]
  }
  assert {
    condition     = aws_instance.ce[0].id == run.ordered_parent_attachments.fixture.ce_instance_id
    error_message = "Policy association changes must preserve the running CE."
  }
}

run "scoped_firewall_policy" {
  command = plan
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
    firewall_action     = "deny"
  }
  assert {
    condition     = xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[0].source_prefix_list.prefixes[0] == aws_subnet.client.cidr_block
    error_message = "Firewall rule must be scoped to the private client subnet."
  }
  assert {
    condition     = xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[0].protocol_port_range.port_ranges[0] == "80"
    error_message = "Firewall rule must target only HTTP port 80."
  }
}

run "reversed_firewall_rules" {
  command = plan
  variables {
    phase                     = "configured"
    device_mapping_file       = "tests/mapping-valid.json"
    firewall_action           = "deny"
    firewall_scoped_first     = false
    firewall_companion_action = "allow"
  }
  assert {
    condition     = xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[0].metadata.name == "allow-unrelated" && xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[1].metadata.name == "scoped-http"
    error_message = "Configured rule order must reach the policy payload unchanged."
  }
  assert {
    condition     = xcsh_enhanced_firewall_policy.companion[0].rule_list.rules[0].allow != null && xcsh_enhanced_firewall_policy.companion[0].rule_list.rules[0].deny == null
    error_message = "Companion policy must use the independent scoped action."
  }
}
run "invalid_firewall_action" {
  command = plan
  variables { firewall_action = "NEXT_POLICY" }
  expect_failures = [var.firewall_action]
}

run "forward_proxy_url_and_sni_rules" {
  command = plan
  variables {
    phase                  = "configured"
    device_mapping_file    = "tests/mapping-valid.json"
    proxy_http_action      = "DENY"
    proxy_tls_action       = "DENY"
    proxy_fallback_action  = "NEXT_POLICY"
    proxy_companion_action = "ALLOW"
  }
  assert {
    condition     = xcsh_forward_proxy_policy.traffic[0].rule_list.rules[0].http_list.http_list[0].path_prefix_value == "/deny"
    error_message = "HTTP rule must retain the configured URL path matcher."
  }
  assert {
    condition     = xcsh_forward_proxy_policy.traffic[0].rule_list.rules[1].tls_list.tls_list[0].exact_value == "origin.qualification.test"
    error_message = "TLS rule must retain the controlled SNI domain."
  }
  assert {
    condition     = xcsh_forward_proxy_policy.traffic[0].rule_list.rules[2].action == "NEXT_POLICY"
    error_message = "Fallback must explicitly continue to the next policy."
  }
}

run "forward_proxy_scope_and_order" {
  command = apply
  variables {
    phase                  = "configured"
    device_mapping_file    = "tests/mapping-valid.json"
    proxy_http_action      = "DENY"
    proxy_tls_action       = "ALLOW"
    proxy_rule_order       = ["fallback", "tls", "http"]
    proxy_companion_action = "DENY"
    proxy_policies         = [{ name = "qualification-test-fpx", namespace = "system" }, { name = "qualification-test-fpx-next", namespace = "system" }]
  }
  assert {
    condition     = xcsh_forward_proxy_policy.traffic[0].rule_list.rules[0].all_destinations != null && xcsh_forward_proxy_policy.traffic[0].rule_list.rules[2].prefix_list.prefixes[0] == aws_subnet.client.cidr_block
    error_message = "Rule order and client scope must reach the policy unchanged."
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].no_forward_proxy == null && [for ref in xcsh_securemesh_site_v2.ce[0].active_forward_proxy_policies.forward_proxy_policies : ref.name] == ["qualification-test-fpx", "qualification-test-fpx-next"]
    error_message = "Only the parent writes ordered proxy associations."
  }
}
run "forward_proxy_detached_defaults" {
  command = plan
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
  }
  assert {
    condition     = length(xcsh_forward_proxy_policy.traffic) == 0 && length(xcsh_forward_proxy_policy.companion) == 0 && xcsh_securemesh_site_v2.ce[0].active_forward_proxy_policies == null && xcsh_securemesh_site_v2.ce[0].no_forward_proxy != null
    error_message = "Omitted controls must remove policies and return the parent to no proxy."
  }
}
run "invalid_forward_proxy_action" {
  command = plan
  variables { proxy_http_action = "drop" }
  expect_failures = [var.proxy_http_action]
}
run "duplicate_forward_proxy_rule_order" {
  command = plan
  variables { proxy_rule_order = ["http", "http", "fallback"] }
  expect_failures = [var.proxy_rule_order]
}
