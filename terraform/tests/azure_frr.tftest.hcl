mock_provider "azurerm" {}

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
    condition     = length(azurerm_route_server_bgp_connection.frr) == 2 && alltrue([for _, v in azurerm_route_server_bgp_connection.frr : v.peer_asn == 65020])
    error_message = "Both FRRs must peer with Route Server under the relay ASN."
  }

  assert {
    condition = alltrue([for _, v in azurerm_linux_virtual_machine.frr :
      strcontains(base64decode(v.custom_data), "ip prefix-list VIP seq 10 permit 10.250.0.10/32") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.4.4 peer-group RS") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.4.5 peer-group RS") &&
      strcontains(base64decode(v.custom_data), "neighbor 10.0.1.4 peer-group CE") &&
      strcontains(base64decode(v.custom_data), "route-map RS-OUT permit 10") &&
      !strcontains(base64decode(v.custom_data), "network 10.250.0.10/32")
    ])
    error_message = "Each FRR must import only the CE VIP and export only that learned route."
  }
}
