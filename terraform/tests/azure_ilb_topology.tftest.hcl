mock_provider "xcsh" {}

run "inside_virtual_site_uses_owned_regional_topology" {
  command = plan
  module { source = "./modules/azure-ilb-app" }
  variables {
    name             = "example-inside"
    namespace        = "demo-app"
    domain           = "inside.example.com"
    vip              = "192.0.2.10"
    origin_pool_name = "example-origin"
    labels           = { "mcn-topology" = "example-ca-azure" }
  }
  assert {
    condition     = one(xcsh_virtual_site.inside.site_selector.expressions) == "mcn-topology in (example-ca-azure)"
    error_message = "Inside VIP selection must match the exact owned regional site label."
  }
}
