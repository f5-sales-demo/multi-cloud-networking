variable "origin_developer_cidrs" {
  description = "Explicit workstation public IPv4 /32 addresses allowed to reach the demo origin for development. Keep allocations in private tfvars."
  type        = list(string)
  default     = []
  validation {
    condition     = alltrue([for cidr in var.origin_developer_cidrs : can(cidrhost(cidr, 0)) && endswith(cidr, "/32") && !strcontains(cidr, ":")])
    error_message = "Developer origin access requires exact public IPv4 /32 addresses."
  }
}
variable "ca_origin_ip" {
  description = "Canadian external origin IPv4 address when the owned showcase origins are disabled. Set this for externally hosted Canadian origins."
  type        = string
  default     = null
  nullable    = true
  validation {
    condition     = var.ca_origin_ip == null || can(cidrhost("${var.ca_origin_ip}/32", 0))
    error_message = "ca_origin_ip must be a valid IPv4 address."
  }
}
variable "enable_showcase_origin" {
  description = "Deploy a disposable HTTP origin for repeatable full-showcase traffic verification."
  type        = bool
  default     = false
}
# Omit regions to include every published Regional Edge network.
data "xcsh_network_regional_edges" "origin" {
  count = var.enable_azure && var.enable_showcase_origin ? 1 : 0
}
data "xcsh_network_cdn" "origin" {
  count = var.enable_azure && var.enable_showcase_origin ? 1 : 0
}
locals {
  origin_f5_cidrs = var.enable_azure && var.enable_showcase_origin ? sort(distinct(concat(
    data.xcsh_network_regional_edges.origin[0].cidr_blocks,
    data.xcsh_network_cdn.origin[0].cidr_blocks,
  ))) : []
  ca_origin_demo_cidrs = var.enable_azure && var.enable_canada && var.enable_showcase_origin ? [
    for ip in concat(
      [for node in module.ce_node_ca : node.mgmt_private_ip],
      [for node in module.ce_node_ca : node.mgmt_public_ip],
      [module.client_vm_ca[0].private_ip, module.client_vm_ca[0].public_ip],
    ) : "${ip}/32"
  ] : []
  # CE-local load balancing and direct-origin controls use these exact owned
  # sources. They do not grant access to an arbitrary VNet or Internet client.
  origin_demo_cidrs = var.enable_azure && var.enable_showcase_origin ? [
    for ip in concat(
      [for node in module.ce_node : node.mgmt_private_ip],
      [for node in module.ce_node : node.mgmt_public_ip],
      [for node in module.ce_node_ca : node.mgmt_public_ip],
      [module.client_vm[0].private_ip, module.client_vm[0].public_ip],
      var.enable_canada ? [module.client_vm_ca[0].public_ip] : [],
    ) : "${ip}/32"
  ] : []
}
resource "terraform_data" "origin_f5_acl_gate" {
  count = var.enable_azure && var.enable_showcase_origin ? 1 : 0
  input = local.origin_f5_cidrs
  lifecycle {
    precondition {
      condition = (length(local.origin_f5_cidrs) > 0 &&
        data.xcsh_network_regional_edges.origin[0].api_release_tag == "v9.0.1" &&
      data.xcsh_network_cdn.origin[0].api_release_tag == "v9.0.1")
      error_message = "Origin ingress requires nonempty F5 provider CIDRs from the pinned API release."
    }
  }
}
module "showcase_origin" {
  count               = var.enable_azure && var.enable_showcase_origin ? 1 : 0
  source              = "./modules/client-vm"
  name                = "${var.component}-origin${local.deployment_name_suffix}"
  resource_group_name = module.azure_hub[0].resource_group_name
  location            = module.azure_hub[0].location
  subnet_id           = module.azure_hub[0].management_subnet_id
  # CE hosts use 4-6 and FRR uses 20-21 in this subnet.
  private_ip        = cidrhost(var.mgmt_subnet_prefix, 30)
  admin_username    = var.admin_username
  ssh_public_key    = local.ssh_public_key
  serve_http        = true
  allow_ssh         = false
  restrict_ingress  = true
  http_source_cidrs = sort(distinct(concat(local.origin_f5_cidrs, local.origin_demo_cidrs, var.origin_developer_cidrs)))
  tags              = local.tags
  depends_on        = [terraform_data.origin_f5_acl_gate]
  custom_data = base64encode(<<-EOF
    #cloud-config
    write_files:
      - path: /srv/mcn-origin/index.html
        permissions: '0644'
        content: |
          mcn-showcase-origin
      - path: /etc/systemd/system/mcn-origin.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Ephemeral MCN showcase HTTP origin
          After=network-online.target
          [Service]
          ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /srv/mcn-origin
          Restart=always
          [Install]
          WantedBy=multi-user.target
    runcmd:
      - [systemctl, daemon-reload]
      - [systemctl, enable, --now, mcn-origin]
    EOF
  )
}
module "showcase_origin_ca" {
  count               = var.enable_azure && var.enable_canada && var.enable_showcase_origin ? 1 : 0
  source              = "./modules/client-vm"
  name                = "${var.component}-ca-origin${local.deployment_name_suffix}"
  resource_group_name = module.azure_hub_ca[0].resource_group_name
  location            = module.azure_hub_ca[0].location
  subnet_id           = module.azure_hub_ca[0].management_subnet_id
  # CE hosts use 4-6 and FRR uses 20-21 in this subnet.
  private_ip        = cidrhost(var.ca_mgmt_subnet_prefix, 30)
  admin_username    = var.admin_username
  ssh_public_key    = local.ssh_public_key
  serve_http        = true
  allow_ssh         = false
  restrict_ingress  = true
  http_source_cidrs = sort(distinct(concat(local.origin_f5_cidrs, local.ca_origin_demo_cidrs, var.origin_developer_cidrs)))
  tags              = local.tags
  depends_on        = [terraform_data.origin_f5_acl_gate]
  custom_data = base64encode(<<-EOF
    #cloud-config
    write_files:
      - path: /srv/mcn-origin/index.html
        permissions: '0644'
        content: |
          mcn-showcase-canada-origin
      - path: /etc/systemd/system/mcn-origin.service
        permissions: '0644'
        content: |
          [Unit]
          Description=Ephemeral Canadian MCN showcase HTTP origin
          After=network-online.target
          [Service]
          ExecStart=/usr/bin/python3 -m http.server 80 --bind 0.0.0.0 --directory /srv/mcn-origin
          Restart=always
          [Install]
          WantedBy=multi-user.target
    runcmd:
      - [systemctl, daemon-reload]
      - [systemctl, enable, --now, mcn-origin]
    EOF
  )
}
locals {
  selected_origin_ip    = var.enable_azure && var.enable_showcase_origin ? module.showcase_origin[0].public_ip : var.origin_ip
  selected_ca_origin_ip = var.enable_azure && var.enable_canada && var.enable_showcase_origin ? module.showcase_origin_ca[0].public_ip : coalesce(var.ca_origin_ip, var.origin_ip)
}

output "origin_ingress_acl" {
  value = {
    f5_cidrs           = local.origin_f5_cidrs
    developer_cidrs    = var.origin_developer_cidrs
    owned_demo_cidrs   = local.origin_demo_cidrs
    provider_version   = "12.3.0"
    all_regional_edges = true
  }
}


output "ca_origin_ip" {
  description = "Canadian origin endpoint for Canadian load balancers and control probes."
  value       = var.enable_azure && var.enable_canada ? local.selected_ca_origin_ip : null
}

output "ca_origin_ingress_acl" {
  value = {
    f5_cidrs           = local.origin_f5_cidrs
    developer_cidrs    = var.origin_developer_cidrs
    owned_demo_cidrs   = local.ca_origin_demo_cidrs
    provider_version   = "12.3.0"
    all_regional_edges = true
  }
}
