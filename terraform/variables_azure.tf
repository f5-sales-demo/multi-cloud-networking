# ---------------------------------------------------------
# Azure subscription / placement
# ---------------------------------------------------------

variable "subscription_id" {
  description = "Azure subscription ID used by the azurerm provider."
  type        = string
  # Default = the <AZURE_SUBSCRIPTION_ID> subscription the lab was built in.
  default = "00000000-0000-0000-0000-000000000000"
}

variable "resource_group_name" {
  description = "Resource group that holds the hub VNet, Route Server, CE VMs and test client. Leave null (the default) to derive `rg-<component>-<deployer>`, where the deployer is resolved from Azure AD — so a fresh clone names the group after whoever deploys it rather than after whoever wrote it."
  type        = string
  default     = null
}

variable "location" {
  description = "Azure region for all resources."
  type        = string
  default     = "eastus"
}

variable "enable_azure" {
  description = "Deploy the Azure US and Canada SMSv2 graphs. Keep true for the full showcase; set false only for the separately reviewed AWS-only saved-plan and preflight stage."
  type        = bool
  default     = true
}

# ---------------------------------------------------------
# Canada regional Azure placement & CIDRs
# ---------------------------------------------------------

variable "enable_canada_ilb" {
  description = "Deploy the Canadian inside application and Site Console ILB frontends alongside the BGP path."
  type        = bool
  default     = true
}

variable "enable_azure_ilb" {
  description = "Deploy the US inside application and Site Console ILB frontends alongside the BGP path."
  type        = bool
  default     = true
}

variable "ca_location" {
  description = "Azure region for Canadian regional resources."
  type        = string
  default     = "canadacentral"
}

variable "ca_resource_group_name" {
  description = "Resource group that holds the Canadian hub VNet, Route Server, CE VMs and test client. Leave null (the default) to derive `rg-<component>-ca-<deployer>`."
  type        = string
  default     = null
}

variable "ca_hub_cidr" {
  description = "Canada Hub VNet address space."
  type        = string
  default     = "10.200.0.0/16"
}

variable "ca_mgmt_subnet_prefix" {
  description = "Canada snet-hub-management prefix. CE eth0/SLO NICs live here."
  type        = string
  default     = "10.200.1.0/26"
}

variable "ca_external_subnet_prefix" {
  description = "Canada snet-hub-external prefix."
  type        = string
  default     = "10.200.2.0/26"
}

variable "ca_internal_subnet_prefix" {
  description = "Canada snet-hub-internal prefix. Test client lives here."
  type        = string
  default     = "10.200.3.0/26"
}

variable "ca_route_server_subnet_prefix" {
  description = "Canada RouteServerSubnet prefix. MUST be exactly /27."
  type        = string
  default     = "10.200.4.0/27"

  validation {
    condition     = tonumber(split("/", var.ca_route_server_subnet_prefix)[1]) == 27
    error_message = "ca_route_server_subnet_prefix must be a /27."
  }
}

variable "ca_bastion_subnet_prefix" {
  description = "Canada AzureBastionSubnet prefix. MUST be /26 or larger."
  type        = string
  default     = "10.200.5.0/26"

  validation {
    condition     = tonumber(split("/", var.ca_bastion_subnet_prefix)[1]) <= 26
    error_message = "ca_bastion_subnet_prefix must be /26 or larger."
  }
}

variable "ca_vip" {
  description = "HA VIP for Canadian CEs advertised as a /32 via eBGP."
  type        = string
  default     = "10.250.1.10"

  validation {
    condition     = can(cidrhost("${var.ca_vip}/32", 0))
    error_message = "ca_vip must be a valid IPv4 address."
  }
}

variable "ca_route_server_name" {
  description = "Canada Azure Route Server name. Leave null to derive `<component>-ca-rs`."
  type        = string
  default     = null
}

variable "ca_bastion_name" {
  description = "Canada Azure Bastion host name. Leave null to derive `<component>-ca-bastion`."
  type        = string
  default     = null
}

variable "ca_client_vm_name" {
  description = "Canada test client VM name. Leave null to derive `<component>-ca-client`."
  type        = string
  default     = null
}

variable "ca_region_short" {
  description = "Short region token for Canada site names. Leave null to use var.ca_location."
  type        = string
  default     = null
}

# ---------------------------------------------------------
# Network CIDRs
# ---------------------------------------------------------

variable "hub_cidr" {
  description = "Hub VNet address space."
  type        = string
  default     = "10.0.0.0/16"
}

variable "spoke_cidr" {
  description = "Spoke VNet address space (not deployed here; used only to assert the VIP is outside it)."
  type        = string
  default     = "10.1.0.0/16"
}

variable "mgmt_subnet_prefix" {
  description = "snet-hub-management prefix. CE eth0/SLO NICs (BGP local address) live here."
  type        = string
  default     = "10.0.1.0/26"
}

variable "external_subnet_prefix" {
  description = "snet-hub-external prefix."
  type        = string
  default     = "10.0.2.0/26"
}

variable "internal_subnet_prefix" {
  description = "snet-hub-internal prefix. The test client lives here."
  type        = string
  default     = "10.0.3.0/26"
}

variable "route_server_subnet_prefix" {
  description = "RouteServerSubnet prefix. MUST be exactly /27, named literally RouteServerSubnet, with no NSG or route table."
  type        = string
  default     = "10.0.4.0/27"

  validation {
    condition     = tonumber(split("/", var.route_server_subnet_prefix)[1]) == 27
    error_message = "RouteServerSubnet must be a /27."
  }
}

variable "route_server_name" {
  description = "Azure Route Server name. Leave null (the default) to derive `<component>-rs`."
  type        = string
  default     = null
}

variable "bastion_subnet_prefix" {
  description = "AzureBastionSubnet prefix. MUST be /26 or larger, named literally AzureBastionSubnet, with no NSG or route table. 10.0.5.0/26 is the first free /26 in the hub (10.0.1.0/26 mgmt, 10.0.2.0/26 external, 10.0.3.0/26 internal, 10.0.4.0/27 RouteServerSubnet are taken)."
  type        = string
  default     = "10.0.5.0/26"

  validation {
    # Azure rejects anything smaller than /26 at APPLY time, long after the plan
    # looked healthy. Fail at plan time instead.
    condition     = tonumber(split("/", var.bastion_subnet_prefix)[1]) <= 26
    error_message = "AzureBastionSubnet must be /26 or larger (a smaller prefix, e.g. /27, is rejected by Azure)."
  }
}

# --------------------------------------------------------------------------
# Azure Bastion
# --------------------------------------------------------------------------
# Default false, deliberately. Bastion is the only resource in this deployment
# that is not load-bearing for the BGP/ECMP demo — the data path, the sites and
# the VIP all work without it — yet a Standard-SKU host bills an hourly standing
# charge from the moment it is provisioned, whether or not anyone opens a tunnel:
# USD 0.29/hour in eastus for the two included scale units (retail, 2026-07),
# roughly USD 212 a month, plus USD 0.14/hour for each scale unit beyond two.
# Opting in keeps the cost of a default `terraform apply` exactly what it is
# today and makes the spend a conscious choice by whoever needs CE console
# access. Turn it on with `enable_bastion = true` in terraform.tfvars.
variable "enable_bastion" {
  description = "Deploy Azure Bastion so developers can reach each CE's Site Console web UI (https://<sli-ip>:65500) with Azure RBAC instead of an SSH key and a jump host."
  type        = bool
  default     = false
}

variable "client_vm_name" {
  description = "Test client VM name, and the stem of its public IP, NSG and NIC. Leave null (the default) to derive `<component>-client`. Set it only to hold an existing client VM steady: the name is also its computer_name, which forces a VM replacement when it changes."
  type        = string
  default     = null
}

variable "bastion_name" {
  description = "Azure Bastion host name (the --name argument of `az network bastion tunnel`). Leave null (the default) to derive `<component>-bastion`."
  type        = string
  default     = null
}

# ---------------------------------------------------------
# CE / client VM inputs
# ---------------------------------------------------------

variable "ce_vm_size" {
  description = "VM size for the Customer Edge nodes."
  type        = string
  default     = "Standard_D8_v4"
}

variable "admin_username" {
  description = "SSH admin username for the VMs."
  type        = string
  default     = "azureuser"
}

variable "ssh_public_key" {
  description = "SSH public key MATERIAL (the key string). When empty, read from ssh_public_key_path. Passing material keeps plan tests hermetic."
  type        = string
  default     = ""
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key file, read once at the root when ssh_public_key is empty."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "azure_frr_asn" {
  description = "ASN shared by the two independent FRR relays in each Azure region."
  type        = number
  default     = 65020

  validation {
    condition     = var.azure_frr_asn >= 64512 && var.azure_frr_asn <= 65534 && !contains([var.ce_asn, var.rs_asn], var.azure_frr_asn)
    error_message = "azure_frr_asn must be a private ASN distinct from CE and Route Server ASNs."
  }
}
