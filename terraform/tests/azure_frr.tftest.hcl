mock_provider "azapi" {}
mock_provider "azurerm" {
  mock_resource "azurerm_network_interface" {
    defaults = { mac_address = "52:54:00:10:00:11" }
  }
}

run "two_regional_relays_and_vip_only_export" {
  command = plan
  module { source = "./modules/azure-frr" }

  variables {
    name                = "mcn-us"
    location            = "eastus"
    resource_group_name = "rg-mcn-us"
    mgmt_subnet_id      = "/subscriptions/test/subnets/mgmt"
    mgmt_subnet_prefix  = "10.0.1.0/26"
    route_server_id     = "/subscriptions/00000000-0000-0000-0000-000000000000/resourceGroups/rg-mcn-us/providers/Microsoft.Network/virtualHubs/us"
    rs_peer_ips         = ["10.0.4.4", "10.0.4.5"]
    ce_ips              = ["10.0.1.4", "10.0.1.5", "10.0.1.6"]
    vip                 = "10.250.0.10"
    ce_asn              = 64512
    rs_asn              = 65515
    frr_asn             = 65020
    admin_username      = "azureuser"
    ssh_public_key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
    tags                = {}
  }

  assert {
    condition     = output.peer_ips == ["10.0.1.20", "10.0.1.21"]
    error_message = "Relays must use reserved management addresses .20 and .21."
  }

  assert {
    condition     = alltrue([for v in [azapi_resource.route_server_primary, azapi_resource.route_server_secondary] : v.type == "Microsoft.Network/virtualHubs/bgpConnections@2022-01-01" && v.body.properties.peerAsn == 65020 && v.parent_id == var.route_server_id && v.timeouts.create == "30m" && v.timeouts.delete == "30m"])
    error_message = "Both FRRs must peer with Route Server under the relay ASN."
  }

  assert {
    condition     = azapi_resource.route_server_primary.body.properties.peerIp == "10.0.1.20" && azapi_resource.route_server_secondary.body.properties.peerIp == "10.0.1.21"
    error_message = "Both Route Server requests must use the exact reserved FRR addresses."
  }

  assert {
    condition = alltrue([for _, v in azurerm_linux_virtual_machine.frr :
      strcontains(base64decode(v.custom_data), "defer: true") &&
      strcontains(base64decode(v.custom_data), "ip prefix-list VIP seq 10 permit 10.250.0.10/32") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.4.4 peer-group RS") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.4.5 peer-group RS") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.1.4 peer-group CE") &&
      strcontains(base64decode(v.custom_data), "route-map RS-OUT permit 10") &&
      !strcontains(base64decode(v.custom_data), "network 10.250.0.10/32")
    ])
    error_message = "Each FRR must import only the CE VIP and export only that learned route."
  }

  assert {
    condition = alltrue([for _, vm in azurerm_linux_virtual_machine.frr :
      strcontains(base64decode(vm.custom_data), "--vip 10.250.0.10 --router-ip") &&
      strcontains(base64decode(vm.custom_data), "--ce-ips 10.0.1.4 10.0.1.5 10.0.1.6") &&
      strcontains(base64decode(vm.custom_data), "OnUnitActiveSec=3s") &&
      strcontains(base64decode(vm.custom_data), "mcn-vip-translation.timer")
    ])
    error_message = "Each relay must follow only its regional CE-learned VIP paths."
  }
}
