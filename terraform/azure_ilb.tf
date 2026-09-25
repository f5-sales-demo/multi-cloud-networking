resource "azurerm_lb" "azure_ilb" {
  count               = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name                = "${var.component}-ilb"
  location            = module.azure_hub[0].location
  resource_group_name = module.azure_hub[0].resource_group_name
  sku                 = "Standard"

  frontend_ip_configuration {
    name                          = "application-frontend"
    subnet_id                     = module.azure_hub[0].internal_subnet_id
    private_ip_address            = cidrhost(var.internal_subnet_prefix, 10)
    private_ip_address_allocation = "Static"
  }

  frontend_ip_configuration {
    name                          = "console-frontend"
    subnet_id                     = module.azure_hub[0].internal_subnet_id
    private_ip_address            = cidrhost(var.internal_subnet_prefix, 11)
    private_ip_address_allocation = "Static"
  }
  tags = local.tags
}

resource "azurerm_lb_backend_address_pool" "azure_ce_backend" {
  count           = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name            = "ce-inside-backend"
  loadbalancer_id = azurerm_lb.azure_ilb[0].id
}

resource "azurerm_network_interface_backend_address_pool_association" "azure_ce" {
  for_each = var.enable_azure && var.enable_azure_ilb ? module.ce_topology.ce_nodes : {}

  network_interface_id    = module.ce_node[each.key].internal_nic_id
  ip_configuration_name   = "ipconfig1"
  backend_address_pool_id = azurerm_lb_backend_address_pool.azure_ce_backend[0].id
}

resource "azurerm_lb_probe" "azure_application" {
  count               = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name                = "application-probe"
  loadbalancer_id     = azurerm_lb.azure_ilb[0].id
  protocol            = "Tcp"
  port                = 80
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_probe" "azure_site_console" {
  count               = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name                = "site-console-probe"
  loadbalancer_id     = azurerm_lb.azure_ilb[0].id
  protocol            = "Tcp"
  port                = 65500
  interval_in_seconds = 5
  number_of_probes    = 2
}

resource "azurerm_lb_rule" "azure_application" {
  count                          = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name                           = "application-rule"
  loadbalancer_id                = azurerm_lb.azure_ilb[0].id
  frontend_ip_configuration_name = "application-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.azure_ce_backend[0].id]
  probe_id                       = azurerm_lb_probe.azure_application[0].id
  protocol                       = "Tcp"
  frontend_port                  = 80
  backend_port                   = 80
  floating_ip_enabled            = true
}

resource "azurerm_lb_rule" "azure_console" {
  count                          = var.enable_azure && var.enable_azure_ilb ? 1 : 0
  name                           = "console-rule"
  loadbalancer_id                = azurerm_lb.azure_ilb[0].id
  frontend_ip_configuration_name = "console-frontend"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.azure_ce_backend[0].id]
  probe_id                       = azurerm_lb_probe.azure_site_console[0].id
  protocol                       = "Tcp"
  frontend_port                  = 65500
  backend_port                   = 65500
  floating_ip_enabled            = false
}
