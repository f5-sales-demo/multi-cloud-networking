# Azure Marketplace agreement for the sole Customer Edge image accepted by this
# configuration.  The agreement identity is deliberately fixed: callers cannot
# substitute a publisher, offer, or plan through an input variable.
locals {
  f5xc_customer_edge_marketplace_agreement_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.MarketplaceOrdering/offerTypes/virtualmachine/publishers/f5-networks/offers/f5xc_customer_edge/plans/f5xc-ce-crt-20260201/agreements/current"
}

# Read the exact subscription agreement first. Azure exposes this object even
# before Terraform tracks it, so acceptance uses an idempotent PUT action rather
# than a create-managed resource and remains inside Terraform apply.
data "azapi_resource_action" "f5xc_customer_edge_marketplace_agreement" {
  count       = var.enable_azure ? 1 : 0
  type        = "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements@2021-01-01"
  resource_id = local.f5xc_customer_edge_marketplace_agreement_id
  action      = ""
  method      = "GET"

  response_export_values = ["*"]
}

resource "azapi_resource_action" "f5xc_customer_edge_marketplace_agreement" {
  count       = var.enable_azure ? 1 : 0
  type        = "Microsoft.MarketplaceOrdering/offerTypes/publishers/offers/plans/agreements@2021-01-01"
  resource_id = local.f5xc_customer_edge_marketplace_agreement_id
  action      = ""
  method      = "PUT"

  body = {
    properties = merge(
      try(data.azapi_resource_action.f5xc_customer_edge_marketplace_agreement[0].output.properties, {}),
      { accepted = true },
    )
  }

  response_export_values = ["*"]

  # Azure requires the current signed receipt on initial acceptance, but rotates
  # it on every GET. Retain that creation receipt while still repairing accepted.
  lifecycle {
    ignore_changes = [body.properties.retrieveDatetime, body.properties.signature]
  }

  depends_on = [data.azapi_resource_action.f5xc_customer_edge_marketplace_agreement]
}
