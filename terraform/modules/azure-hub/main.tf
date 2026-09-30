resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_virtual_network" "hub" {
  name                = "hub-vnet"
  address_space       = [var.hub_cidr]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet" "management" {
  name                 = "snet-hub-management"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.mgmt_subnet_prefix]
}

# FRR advertises the VIP to Route Server for clients. Propagating that route
# back onto its own subnet causes Azure to forward the next-hop packets to FRR
# again, despite the guest route pointing at the CE.
resource "azurerm_route_table" "management" {
  count                         = var.enable_route_server ? 1 : 0
  name                          = "${var.route_server_name}-management"
  location                      = var.location
  resource_group_name           = azurerm_resource_group.this.name
  bgp_route_propagation_enabled = false
  tags                          = var.tags
}
resource "azurerm_subnet_route_table_association" "management" {
  count          = var.enable_route_server ? 1 : 0
  subnet_id      = azurerm_subnet.management.id
  route_table_id = azurerm_route_table.management[0].id
}

resource "azurerm_subnet" "external" {
  name                 = "snet-hub-external"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.external_subnet_prefix]
}

resource "azurerm_subnet" "internal" {
  name                 = "snet-hub-internal"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.internal_subnet_prefix]
}

# RouteServerSubnet: name is literal, /27, and has NO NSG and NO route table
# association (both are unsupported on the Route Server subnet).
resource "azurerm_subnet" "route_server" {
  count                = var.enable_route_server ? 1 : 0
  name                 = "RouteServerSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.route_server_subnet_prefix]
}

resource "azurerm_public_ip" "route_server" {
  count               = var.enable_route_server ? 1 : 0
  name                = "${var.route_server_name}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Azure Route Server. ASN is fixed by Azure at 65515; virtual_router_ips are the
# two BGP peer addresses (10.0.4.4 / 10.0.4.5) the CEs peer to.
resource "azurerm_route_server" "this" {
  count                = var.enable_route_server ? 1 : 0
  name                 = var.route_server_name
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  sku                  = "Standard"
  public_ip_address_id = azurerm_public_ip.route_server[0].id
  subnet_id            = azurerm_subnet.route_server[0].id
  tags                 = var.tags
}

# --------------------------------------------------------------------------
# Azure Bastion — reachability for the CE Site Console web UI (TCP 65500)
# --------------------------------------------------------------------------
# F5's documented CE troubleshooting path is the per-node Site Console at
# https://<node-ip>:65500 as `admin`. Verified on this deployment: of a CE's three
# private addresses only the SLI one (snet-hub-internal) answers at all — mgmt/SLO
# and external are closed on every port probed — and it is reachable only from
# inside the VNet. Bastion closes the gap without distributing SSH keys and
# without touching the CE: who may connect becomes an Azure RBAC decision.
#
# AzureBastionSubnet: name is literal, /26 or larger, and — like
# RouteServerSubnet above — deliberately carries NO NSG and NO route table.
# Bastion works without an NSG; adding one obliges you to maintain Azure's exact
# required allow-rule set (GatewayManager, AzureLoadBalancer, the 8080/5701
# intra-subnet pair) for no security gain in a lab whose VMs already sit behind
# their own NSGs.
resource "azurerm_subnet" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = [var.bastion_subnet_prefix]
}

resource "azurerm_public_ip" "bastion" {
  count = var.enable_bastion ? 1 : 0

  name                = "${var.bastion_name}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

# Standard SKU is not a preference — Basic supports neither native-client
# tunneling nor IP-based connection.
#
#   tunneling_enabled  -> load-bearing. `az network bastion tunnel` forwards an
#                         arbitrary TCP port, which is the only way to reach 65500.
#   ip_connect_enabled -> NOT the path to 65500, and deliberately not claimed to
#                         be. Microsoft documents that "custom ports and protocols
#                         aren't currently supported when connecting to a virtual
#                         machine via native client with IP-based connections"
#                         (learn.microsoft.com/azure/bastion/connect-ip-address),
#                         and the CLI enforces it: --target-ip-address with
#                         --resource-port 65500 is refused with "Allowed ports for
#                         Tunnel with IP connect is 22, 3389". It is on because it
#                         costs nothing and lets an operator target an in-VNet IP
#                         directly for portal RDP/SSH. The 65500 tunnel targets the
#                         CE by VM resource id instead — verified reaching the Site
#                         Console (HTTP 200) on this deployment.
resource "azurerm_bastion_host" "this" {
  count = var.enable_bastion ? 1 : 0

  name                = var.bastion_name
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  tunneling_enabled   = true
  ip_connect_enabled  = true

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.bastion[0].id
    public_ip_address_id = azurerm_public_ip.bastion[0].id
  }

  tags = var.tags
}
