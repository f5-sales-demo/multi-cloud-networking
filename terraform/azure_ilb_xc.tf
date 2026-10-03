module "azure_ilb_application" {
  count  = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  source = "./modules/azure-ilb-app"

  name             = "${var.component}-us-inside${local.deployment_name_suffix}"
  namespace        = data.xcsh_namespace.mcn.name
  domain           = "ilb.${local.lb_domain}"
  vip              = cidrhost(var.internal_subnet_prefix, 10)
  origin_pool_name = xcsh_origin_pool.this[0].name
  labels           = local.azure_xc_labels

  depends_on = [module.xc_site]
}
