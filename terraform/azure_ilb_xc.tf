module "azure_ilb_application" {
  count  = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  source = "./modules/azure-ilb-app"

  name             = "${var.component}-us-inside${local.deployment_name_suffix}"
  namespace        = data.xcsh_namespace.mcn.name
  site_names       = [for key in sort(keys(module.ce_topology.ce_nodes)) : module.ce_topology.ce_nodes[key].site_name]
  domain           = "ilb.${local.lb_domain}"
  vip              = cidrhost(var.internal_subnet_prefix, 10)
  origin_pool_name = xcsh_origin_pool.this[0].name
  labels           = local.azure_xc_labels

  depends_on = [module.xc_site]
}

module "azure_ilb_application_ca" {
  count  = var.enable_azure && var.enable_canada && var.enable_canada_ilb ? 1 : 0
  source = "./modules/azure-ilb-app"

  name             = "${var.component}-ca-inside${local.deployment_name_suffix}"
  namespace        = data.xcsh_namespace.mcn.name
  site_names       = [for key in sort(keys(module.ce_topology_ca[0].ce_nodes)) : module.ce_topology_ca[0].ce_nodes[key].site_name]
  domain           = "ilb.${local.ca_lb_domain}"
  vip              = cidrhost(var.ca_internal_subnet_prefix, 10)
  origin_pool_name = xcsh_origin_pool.canada[0].name
  labels           = local.ca_xc_labels

  depends_on = [module.xc_site_ca]
}
