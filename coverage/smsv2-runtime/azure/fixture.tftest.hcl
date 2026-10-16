mock_provider "azurerm" {}
mock_provider "xcsh" {
  mock_data "xcsh_site_cloud_init" {
    defaults = { cloud_init_config = "#cloud-config\nwrite_files:\n  - path: /etc/vpm/user_data\n    content: qualification-data\n" }
  }
  mock_data "xcsh_site_registration" { defaults = { found = false } }
}
variables {
  subscription_id      = format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)
  xc_tenant            = "qualification-test"
  task_id              = "qualification-test"
  location             = "japaneast"
  operator_cidr        = "192.0.2.10/32"
  ssh_public_key       = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC5PTzIuSNAHOyK3o9MPLwagqpxjD7WCxobuKDUuvo1l1y00WfOzzTVsXVarf+yIZc0dLBIHeLmv1cg+KhmtcOUmqeFz/UPIkMP8V1C4MuAUNh5k05Ig4Euk5MB3C9mLwUAilMG9epketToONZR9fggIX7rAUsw06K70nYmSpg53jPRElHVDhPAyFIfqDVfk3yd2kzUWqLh3PJzUyrn5RiOCYVuAkU2wTjtJqA5IuzND0hzZnCX2CO7zp1XG3mqajhBNgHy6RicrwT1V3K2hOUUsEeq/822Id07OulpBQCXmiOXKRkJt8BY06XZn6Kvzm6V+bQiHchQfw14amVjU25T qualification-test"
  software_version     = "crt-20260801-0205"
  os_version           = "9.2026.17"
  ce_image_sku         = "crt-20260801"
  ce_image_version     = "20260801.0205.1"
  origin_image_version = "24.04.202610100"
}
override_resource {
  target = azurerm_network_interface.slo
  values = { mac_address = "00-00-5E-00-53-01", id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/networkInterfaces/qualification-test-slo", private_ip_address = "10.246.1.4" }
}
override_resource {
  target = azurerm_network_interface.sli
  values = { mac_address = "00-00-5E-00-53-02", id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/networkInterfaces/qualification-test-sli", private_ip_address = "10.246.2.4" }
}
run "bootstrap" {
  command = apply
  assert {
    condition     = azurerm_linux_virtual_machine.ce[0].network_interface_ids[0] == azurerm_network_interface.slo.id && azurerm_linux_virtual_machine.ce[0].network_interface_ids[1] == azurerm_network_interface.sli.id
    error_message = "SLO must be first and SLI second in the real Azure VM topology."
  }
  assert {
    condition     = yamldecode(base64decode(azurerm_linux_virtual_machine.ce[0].custom_data)).write_files[0].path == "/etc/vpm/user_data"
    error_message = "Bootstrap must retain the provider-issued write_files payload."
  }
  assert {
    condition     = length(yamldecode(base64decode(azurerm_linux_virtual_machine.ce[0].custom_data)).write_files) == 2
    error_message = "Bootstrap must append the operator key without replacing token setup."
  }
  assert {
    condition     = azurerm_network_interface.client.ip_configuration[0].public_ip_address_id == null && azurerm_subnet.client.default_outbound_access_enabled == false
    error_message = "The traffic client must have no independent public Internet path."
  }
}
run "retired" {
  command = plan
  variables { phase = "retired" }
  assert {
    condition     = length(azurerm_linux_virtual_machine.ce) == 0 && length(xcsh_securemesh_site_v2.ce) == 0 && azurerm_linux_virtual_machine.traffic["client"].id == run.bootstrap.fixture.client_vm_id
    error_message = "Retirement must remove only CE/site while retaining traffic substrate."
  }
}
run "missing_mapping" {
  command = plan
  variables { phase = "configured" }
  expect_failures = [xcsh_securemesh_site_v2.ce]
}
run "configured" {
  command = apply
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].azure.not_managed.node_list[0].interface_list[0].ethernet_interface.mac == "00:00:5e:00:53:01"
    error_message = "Azure hyphenated MAC must match the observed colon-form registration."
  }
}
run "parent_attachments" {
  command = apply
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
    firewall_policies   = [{ name = "first", namespace = "system" }, { name = "second", namespace = "system" }]
    proxy_policies      = [{ name = "proxy-first", namespace = "system" }]
  }
  assert {
    condition     = xcsh_securemesh_site_v2.ce[0].active_enhanced_firewall_policies.enhanced_firewall_policies[0].name == "first" && xcsh_securemesh_site_v2.ce[0].active_enhanced_firewall_policies.enhanced_firewall_policies[1].name == "second"
    error_message = "Parent association list order must be preserved."
  }
}
run "attachment_keeps_vm" {
  command = plan
  variables {
    phase               = "configured"
    device_mapping_file = "tests/mapping-valid.json"
    firewall_policies   = [{ name = "replacement", namespace = "system" }]
  }
  assert {
    condition     = azurerm_linux_virtual_machine.ce[0].id == run.parent_attachments.fixture.ce_vm_id
    error_message = "Policy updates must retain the running CE VM."
  }
}
run "scoped_firewall" {
  command = plan
  variables {
    phase                     = "configured"
    device_mapping_file       = "tests/mapping-valid.json"
    firewall_action           = "deny"
    firewall_companion_action = "allow"
    firewall_scoped_first     = false
  }
  assert {
    condition     = xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[0].metadata.name == "allow-unrelated" && xcsh_enhanced_firewall_policy.traffic[0].rule_list.rules[1].protocol_port_range.port_ranges[0] == "80"
    error_message = "The scoped HTTP rule must retain its port and requested order."
  }
}
run "invalid_action" {
  command = plan
  variables { firewall_action = "NEXT_POLICY" }
  expect_failures = [var.firewall_action]
}

override_resource {
  target = azurerm_virtual_network.fixture
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/virtualNetworks/qualification-test" }
}

override_resource {
  target = azurerm_network_security_group.fixture
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/networkSecurityGroups/qualification-test" }
}

override_resource {
  target = azurerm_route_table.client
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/routeTables/qualification-test-client" }
}

override_resource {
  target = azurerm_user_assigned_identity.ce
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.ManagedIdentity/userAssignedIdentities/qualification-test-ce" }
}

override_resource {
  target = azurerm_subnet.slo
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/virtualNetworks/qualification-test/subnets/slo" }
}

override_resource {
  target = azurerm_subnet.sli
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/virtualNetworks/qualification-test/subnets/sli" }
}

override_resource {
  target = azurerm_subnet.client
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/virtualNetworks/qualification-test/subnets/client" }
}

override_resource {
  target = azurerm_public_ip.ce
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/publicIPAddresses/qualification-test-ce", ip_address = "203.0.113.10" }
}

override_resource {
  target = azurerm_public_ip.origin
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/publicIPAddresses/qualification-test-origin", ip_address = "203.0.113.20" }
}

override_resource {
  target = azurerm_network_interface.origin
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/networkInterfaces/qualification-test-origin", private_ip_address = "10.246.1.5", mac_address = "00-00-5E-00-53-03" }
}

override_resource {
  target = azurerm_network_interface.client
  values = { id = "/subscriptions/${format("%08d-%04d-%04d-%04d-%012d", 0, 0, 0, 0, 1)}/resourceGroups/qualification-test/providers/Microsoft.Network/networkInterfaces/qualification-test-client", private_ip_address = "10.246.3.4", mac_address = "00-00-5E-00-53-04" }
}
