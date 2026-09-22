# The Marketplace agreement is fixed to the one certified CE image.  This test
# plans with mocks only: no Azure, Terraform state, or F5 API mutation occurs.
mock_provider "azurerm" {}
mock_provider "azuread" {}
mock_provider "xcsh" {}
mock_provider "azapi" {}
mock_provider "aws" {}
mock_provider "libvirt" {}

variables {
  enable_azure           = true
  enable_kvm             = false
  site_prefix            = null
  lb_name                = null
  origin_pool_name       = null
  route_server_name      = null
  bastion_name           = null
  client_vm_name         = null
  region_short           = null
  resource_group_name    = null
  lb_domain              = "mcn-ce-ha.f5-sales-demo.com"
  origin_ip              = "203.0.113.10"
  enable_aws             = false
  enable_aws_tgw_connect = false
  enable_bgp             = false
}

run "fixed_customer_edge_marketplace_agreement" {
  command = plan

  variables {
    ce_count       = 1
    deployer       = "tester"
    enable_bastion = false
    enable_bgp     = false
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKzwDqvgRGHaZqbo57o/AxuuqRNPT9MqeYNYsK1Owh8l plan-test-only"
  }

  assert {
    condition = (
      data.azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].type == "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements@2021-01-01" &&
      data.azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].resource_id == "/subscriptions/${var.subscription_id}/providers/Microsoft.MarketplaceOrdering/offerTypes/virtualmachine/publishers/f5-networks/offers/f5xc_customer_edge/plans/f5xc-ce-crt-20260201/agreements/current" &&
      data.azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].method == "GET"
    )
    error_message = "Terraform must GET the exact fixed Customer Edge Marketplace agreement."
  }

  assert {
    condition = (
      azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].type == "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements@2021-01-01" &&
      azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].resource_id == "/subscriptions/${var.subscription_id}/providers/Microsoft.MarketplaceOrdering/offerTypes/virtualmachine/publishers/f5-networks/offers/f5xc_customer_edge/plans/f5xc-ce-crt-20260201/agreements/current" &&
      azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].action == "" &&
      azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].method == "PUT" &&
      azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].body.properties.accepted == true
    )
    error_message = "Terraform must PUT accepted=true for the exact fixed Customer Edge agreement."
  }
}
