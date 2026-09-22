# ---------------------------------------------------------
# AWS site deployment & placement
# ---------------------------------------------------------

variable "enable_aws" {
  description = "Enable deployment of the AWS Customer Edge site, VPC, EC2 instances, and XC resources."
  type        = bool
  default     = false
}

variable "aws_ce_ami_id" {
  description = "Explicit approved AWS Marketplace AMI ID for Customer Edge instances. A deployment must not select the most-recent image dynamically."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.aws_ce_ami_id == null || can(regex("^ami-[0-9a-f]+$", var.aws_ce_ami_id))
    error_message = "aws_ce_ami_id must be an AWS AMI ID such as ami-0123456789abcdef0."
  }
}

variable "aws_workload_ami_id" {
  description = "Explicit approved Amazon Linux AMI ID for the AWS workload client. A deployment must not select the most-recent image dynamically because that causes unrelated reconciliation replacements."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.aws_workload_ami_id == null || can(regex("^ami-[0-9a-f]+$", var.aws_workload_ami_id))
    error_message = "aws_workload_ami_id must be an AWS AMI ID such as ami-0123456789abcdef0."
  }
}

variable "aws_ssh_public_key" {
  description = "Optional AWS-only SSH public key material. When empty, the shared ssh_public_key input is used."
  type        = string
  default     = ""
}

variable "enable_aws_tgw_connect" {
  description = "Enable the v8 SMSv2 AWS Transit Gateway Connect topology."
  type        = bool
  default     = false
}

variable "aws_tgw_asn" {
  description = "Amazon-side BGP ASN for the Transit Gateway."
  type        = number
  default     = 64520

  validation {
    condition     = var.aws_tgw_asn >= 1 && var.aws_tgw_asn <= 4294967295
    error_message = "aws_tgw_asn must be a valid 32-bit ASN."
  }
}

variable "aws_ce_bgp_asn" {
  description = "BGP ASN used by the AWS Customer Edge site."
  type        = number
  default     = 64513

  validation {
    condition     = var.aws_ce_bgp_asn >= 1 && var.aws_ce_bgp_asn <= 4294967295 && var.aws_ce_bgp_asn != var.aws_tgw_asn
    error_message = "aws_ce_bgp_asn must be a valid 32-bit ASN different from aws_tgw_asn."
  }
}

variable "aws_tgw_gre_cidr" {
  description = "Non-overlapping /24 CIDR owned by the Transit Gateway for GRE endpoints."
  type        = string
  default     = "100.64.0.0/24"

  validation {
    condition     = can(cidrhost(var.aws_tgw_gre_cidr, 0)) && try(tonumber(split("/", var.aws_tgw_gre_cidr)[1]), 0) == 24
    error_message = "aws_tgw_gre_cidr must be a valid IPv4 /24."
  }
}

variable "aws_tgw_inside_cidr" {
  description = "Link-local /24 subdivided into one AWS-owned /29 per physical CE interface."
  type        = string
  default     = "169.254.100.0/24"

  validation {
    condition     = can(cidrhost(var.aws_tgw_inside_cidr, 0)) && try(tonumber(split("/", var.aws_tgw_inside_cidr)[1]), 0) == 24
    error_message = "aws_tgw_inside_cidr must be a valid IPv4 /24."
  }
}

variable "aws_site_configuration_phase" {
  description = "AWS SMSv2 lifecycle phase. bootstrap creates only distinct -bootstrap sites and CEs; bootstrap_retirement removes only their XC/CE material while retaining AWS networking and ENIs; configured creates distinct final sites and CEs from the private observed device mapping."
  type        = string
  default     = "bootstrap"
  nullable    = false

  validation {
    condition     = contains(["bootstrap", "bootstrap_retirement", "configured"], var.aws_site_configuration_phase)
    error_message = "aws_site_configuration_phase must be bootstrap, bootstrap_retirement, or configured."
  }

  validation {
    condition     = var.aws_site_configuration_phase == "configured" || !var.enable_aws_tgw_connect
    error_message = "Only configured creates final MAC-bound sites and may enable AWS TGW Connect."
  }
}

variable "aws_smsv2_device_mapping_file" {
  description = "Private, schema-validated device mapping generated from bootstrap registration observations and Terraform-owned ENI MACs. It is required only during configured and must never be committed."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.aws_site_configuration_phase != "configured" || (var.aws_smsv2_device_mapping_file != null && trimspace(var.aws_smsv2_device_mapping_file) != "")
    error_message = "configured requires aws_smsv2_device_mapping_file generated from bootstrap registration records; arbitrary device input is not accepted."
  }
}

variable "aws_smsv2_interface_mtu" {
  description = "Expected MTU configured on every AWS SMSv2 SLO and SLI interface."
  type        = number
  default     = 1500
}

variable "aws_runtime_convergence_timeout_seconds" {
  description = "Maximum bounded wait for first-boot runtime readiness. This covers the platform-managed installation of the explicit CE software and OS pair."
  type        = number
  default     = 7200

  validation {
    condition     = var.aws_runtime_convergence_timeout_seconds == 7200
    error_message = "aws_runtime_convergence_timeout_seconds is fixed at 7200 seconds so a fresh SMSv2 CE has the full platform-managed first-boot convergence budget."
  }
}

variable "aws_bgp_convergence_timeout_seconds" {
  description = "Maximum bounded wait for authoritative BGP and route convergence after the runtime-health gate has passed. This is bounded by the released provider schema."
  type        = number
  default     = 1800

  validation {
    condition     = var.aws_bgp_convergence_timeout_seconds == 1800
    error_message = "aws_bgp_convergence_timeout_seconds is fixed at 1800 seconds, the maximum accepted by xcsh_site_bgp_status."
  }
}

variable "aws_bgp_poll_interval_seconds" {
  description = "Polling interval for authoritative BGP and route observations."
  type        = number
  default     = 10
}


variable "aws_location" {
  description = "AWS region for all AWS resources."
  type        = string
  default     = "ap-northeast-1"
}

variable "aws_vpc_cidr" {
  description = "AWS VPC address space."
  type        = string
  default     = "10.150.0.0/16"
}

variable "aws_ce_count" {
  description = "Number of independent single-node Customer Edge sites. The validated showcase topology requires exactly three."
  type        = number
  default     = 3

  validation {
    condition     = var.aws_ce_count == 3
    error_message = "aws_ce_count must remain 3 for the validated three-site showcase."
  }
}

variable "aws_bootstrap_site_keys" {
  description = "The complete three-site AWS lifecycle set. Partial site admission is not supported: bootstrap, retirement, and configured phases are reviewed as one three-site transition."
  type        = list(string)
  default     = ["01", "02", "03"]

  validation {
    condition     = toset(var.aws_bootstrap_site_keys) == toset(["01", "02", "03"]) && length(var.aws_bootstrap_site_keys) == 3
    error_message = "aws_bootstrap_site_keys must contain exactly 01, 02, and 03 for the reviewed three-site lifecycle."
  }
}

variable "aws_instance_type" {
  description = "EC2 instance size for the Customer Edge nodes."
  type        = string
  default     = "m5.2xlarge"
}

variable "aws_vip" {
  description = "Plan-bound private address of the internal AWS Network Load Balancer in the workload subnet."
  type        = string
  default     = "10.151.1.10"

  validation {
    condition     = can(cidrhost("${var.aws_vip}/32", 0))
    error_message = "aws_vip must be a valid IPv4 address."
  }
}

variable "aws_workload_vpc_cidr" {
  description = "Address space for the TGW-attached AWS workload VPC."
  type        = string
  default     = "10.151.0.0/16"
}

variable "aws_software_version" {
  description = "Field-proven F5 Distributed Cloud software version requested on first boot for every AWS SMSv2 CE. Do not use an intermediate baseline: first-boot health is a prerequisite for later actions."
  type        = string
  default     = "crt-20260201-0179"
}

variable "aws_os_version" {
  description = "Field-proven F5 Distributed Cloud operating-system version requested on first boot for every AWS SMSv2 CE."
  type        = string
  default     = "9.2026.17"
}

variable "aws_upgrade_wait" {
  description = "Wait for every supplied upgrade target to be installed and for each site to return ONLINE."
  type        = bool
  default     = false
}

variable "aws_upgrade_timeout_seconds" {
  description = "Bounded per-site upgrade convergence timeout."
  type        = number
  default     = 7200
}

variable "aws_upgrade_poll_interval_seconds" {
  description = "Polling interval for site upgrade observations."
  type        = number
  default     = 30
}

variable "aws_upgrade_observed_sites" {
  description = "Canonical two-digit AWS site keys observed by the upgrade status data source."
  type        = set(string)
  default     = ["01", "02", "03"]

  validation {
    condition     = length(setsubtract(var.aws_upgrade_observed_sites, toset(["01", "02", "03"]))) == 0
    error_message = "aws_upgrade_observed_sites may contain only 01, 02, and 03."
  }
}

variable "aws_lb_domain" {
  description = "Domain name for the HTTP Load Balancer serving the AWS CE site."
  type        = string
  default     = "aws.mcn-ce-ha.f5-sales-demo.com"
}
