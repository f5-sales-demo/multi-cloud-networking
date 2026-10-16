terraform {
  backend "local" {}

  required_version = "= 1.16.5"
  required_providers {

    aws = {
      source  = "hashicorp/aws"
      version = "= 5.100.0"
    }
    xcsh = {
      source  = "f5-sales-demo/xcsh"
      version = "= 15.9.0"
    }

  }

}

provider "aws" {
  region = var.region
}
provider "xcsh" {
  api_url = "https://${var.xc_tenant}.console.ves.volterra.io"
}

variable "task_id" {

  type = string
  validation {

    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.task_id))
    error_message = "Use a unique, non-personal 3-20 character task identifier."

  }

}
variable "region" {
  type = string
}
variable "xc_tenant" {
  type = string
}
variable "ce_image_id" {
  type = string
}
variable "client_image_id" {
  type = string
}
variable "operator_cidr" {
  type = string
}
variable "ssh_public_key" {
  type = string
}
variable "phase" {

  type    = string
  default = "bootstrap"
  validation {

    condition     = contains(["bootstrap", "retired", "configured"], var.phase)
    error_message = "Use bootstrap, retired, or configured."

  }

}
variable "software_version" {
  type = string
}
variable "os_version" {
  type = string
}
variable "device_mapping_file" {
  type    = string
  default = null
}
variable "firewall_policies" {

  type = list(object({
    name      = string
    namespace = string
  }))
  default = []

}
variable "proxy_policies" {

  type = list(object({
    name      = string
    namespace = string
  }))
  default = []

}

locals {

  active    = var.phase != "retired"
  site_name = "${var.task_id}-${var.phase}"
  tags = {
    "task-id" = var.task_id, "component" = "smsv2-qualification"
  }

}

data "aws_availability_zones" "available" {
  state = "available"
}
data "aws_ami" "ce" {
  filter {
    name   = "image-id"
    values = [var.ce_image_id]
  }
}
data "aws_ami" "client" {
  filter {
    name   = "image-id"
    values = [var.client_image_id]
  }
}

resource "aws_vpc" "fixture" {
  # checkov:skip=CKV2_AWS_11: Disposable traffic fixture retains origin observations and private receipts; production flow-log infrastructure is outside this cycle.
  # checkov:skip=CKV2_AWS_12: The task default security group is unused; every task ENI and guest receives an explicit task security group and the VPC is destroyed.

  cidr_block           = "10.252.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = local.tags

}
resource "aws_subnet" "slo" {

  vpc_id            = aws_vpc.fixture.id
  cidr_block        = "10.252.1.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]
  tags              = local.tags

}
resource "aws_subnet" "sli" {

  vpc_id            = aws_vpc.fixture.id
  cidr_block        = "10.252.2.0/24"
  availability_zone = aws_subnet.slo.availability_zone
  tags              = local.tags

}
resource "aws_subnet" "client" {

  vpc_id            = aws_vpc.fixture.id
  cidr_block        = "10.252.3.0/24"
  availability_zone = aws_subnet.slo.availability_zone
  tags              = local.tags

}
resource "aws_internet_gateway" "fixture" {
  vpc_id = aws_vpc.fixture.id
  tags   = local.tags
}
resource "aws_route_table" "slo" {

  vpc_id = aws_vpc.fixture.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.fixture.id
  }
  tags = local.tags

}
resource "aws_route_table_association" "slo" {
  subnet_id      = aws_subnet.slo.id
  route_table_id = aws_route_table.slo.id
}
resource "aws_route_table" "client" {

  vpc_id = aws_vpc.fixture.id
  route {
    cidr_block           = "0.0.0.0/0"
    network_interface_id = aws_network_interface.sli.id
  }
  tags = local.tags

}
resource "aws_route_table_association" "client" {
  subnet_id      = aws_subnet.client.id
  route_table_id = aws_route_table.client.id
}

resource "aws_security_group" "fixture" {
  # checkov:skip=CKV_AWS_382: This temporary CE transit fixture intentionally permits egress so cloud filtering cannot masquerade as XC enforcement; it is not a production egress policy.

  name        = var.task_id
  vpc_id      = aws_vpc.fixture.id
  description = "Task-owned CE and traffic lab; permit VPC test flows."
  ingress {
    description = "Task VPC traffic between CE and private guests"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.fixture.cidr_block]
  }
  ingress {
    description = "Operator SSH from the explicitly supplied CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }
  egress {
    description = "Temporary qualification egress; XC enforcement is tested separately"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags

}
resource "aws_key_pair" "fixture" {
  key_name   = var.task_id
  public_key = var.ssh_public_key
  tags       = local.tags
}
resource "aws_network_interface" "slo" {

  subnet_id         = aws_subnet.slo.id
  security_groups   = [aws_security_group.fixture.id]
  source_dest_check = false
  tags = merge(local.tags, {
    role = "slo"
  })

}
resource "aws_network_interface" "sli" {

  subnet_id         = aws_subnet.sli.id
  security_groups   = [aws_security_group.fixture.id]
  source_dest_check = false
  tags = merge(local.tags, {
    role = "sli"
  })

}
resource "aws_eip" "ce" {
  # checkov:skip=CKV2_AWS_19: Bound to the owned SLO ENI, including its reviewed retirement/reuse phase; actual CE attachment and final absence are verified in the receipt.
  domain            = "vpc"
  network_interface = aws_network_interface.slo.id
  tags              = local.tags
}

resource "xcsh_securemesh_site_v2" "ce" {

  count     = local.active ? 1 : 0
  name      = local.site_name
  namespace = "system"
  labels    = local.tags
  aws {

    not_managed {

      dynamic "node_list" {

        for_each = var.phase == "configured" ? [1] : []
        content {

          hostname = local.site_name
          type     = "Control"
          interface_list {

            name = "slo"
            ethernet_interface {
              device = local.devices.slo
              mac    = aws_network_interface.slo.mac_address
            }
            network_option {
              site_local_network = {

              }
            }
            dhcp_client = {

            }

          }
          interface_list {

            name = "sli"
            ethernet_interface {
              device = local.devices.sli
              mac    = aws_network_interface.sli.mac_address
            }
            network_option {
              site_local_inside_network = {

              }
            }
            dhcp_client = {

            }

          }

        }

      }

    }

  }
  disable_ha = {

  }
  block_all_services = {

  }
  no_network_policy = length(var.firewall_policies) == 0 ? {

  } : null
  no_forward_proxy = length(var.proxy_policies) == 0 ? {

  } : null
  dynamic "active_enhanced_firewall_policies" {

    for_each = length(var.firewall_policies) > 0 ? [var.firewall_policies] : []
    content {

      dynamic "enhanced_firewall_policies" {

        for_each = active_enhanced_firewall_policies.value
        content {
          name      = enhanced_firewall_policies.value.name
          namespace = enhanced_firewall_policies.value.namespace
        }

      }

    }

  }
  dynamic "active_forward_proxy_policies" {

    for_each = length(var.proxy_policies) > 0 ? [var.proxy_policies] : []
    content {

      dynamic "forward_proxy_policies" {

        for_each = active_forward_proxy_policies.value
        content {
          name      = forward_proxy_policies.value.name
          namespace = forward_proxy_policies.value.namespace
        }

      }

    }

  }
  f5_proxy = {

  }
  no_proxy_bypass = {

  }
  logs_streaming_disabled = {

  }
  no_s2s_connectivity_sli = {

  }
  no_s2s_connectivity_slo = {

  }
  local_vrf {
    default_config = {

    }
    default_sli_config = {

    }
  }
  software_settings {

    os {
      operating_system_version = var.os_version
    }
    sw {
      volterra_software_version = var.software_version
    }

  }
  lifecycle {

    precondition {

      condition     = var.phase != "configured" || local.mapping_valid
      error_message = "Configured creation requires distinct devices observed by MAC from this fixture's bootstrap registration."

    }

  }

}
resource "xcsh_token" "ce" {

  count     = local.active ? 1 : 0
  name      = "${local.site_name}-reg"
  namespace = "system"
  labels    = local.tags
  type      = 1
  site_name = xcsh_securemesh_site_v2.ce[0].name

}
data "xcsh_site_cloud_init" "ce" {

  count                     = local.active ? 1 : 0
  site_name                 = xcsh_securemesh_site_v2.ce[0].name
  provider_ref              = "aws"
  enable_management_network = false

}
resource "aws_instance" "ce" {
  monitoring    = true
  ebs_optimized = true
  lifecycle {
    ignore_changes = [user_data]
  }
  iam_instance_profile = aws_iam_instance_profile.ce.name

  count         = local.active ? 1 : 0
  ami           = data.aws_ami.ce.id
  instance_type = "m5.2xlarge"
  key_name      = aws_key_pair.fixture.key_name
  network_interface {
    network_interface_id = aws_network_interface.slo.id
    device_index         = 0
  }
  network_interface {
    network_interface_id = aws_network_interface.sli.id
    device_index         = 1
  }
  root_block_device {
    encrypted             = true
    volume_size           = 100
    volume_type           = "gp3"
    delete_on_termination = true
  }
  metadata_options {
    http_tokens = "required"
  }
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/../../../terraform/cloud-init/ce-node-aws.multipart.tpl", {

    site_cloud_init  = replace(data.xcsh_site_cloud_init.ce[0].cloud_init_config, "{{ .token }}", xcsh_token.ce[0].uid)
    sli_mac          = aws_network_interface.sli.mac_address
    fqdn             = "${local.site_name}.qualification.internal"
    ssh_public_key   = var.ssh_public_key
    software_version = var.software_version
    os_version       = var.os_version

  })
  tags = merge(local.tags, {
    Name = local.site_name, "ves-io-site-name" = local.site_name
  })
  depends_on = [aws_internet_gateway.fixture, aws_route_table_association.slo]

}
resource "aws_instance" "origin" {
  monitoring    = true
  ebs_optimized = true
  # checkov:skip=CKV_AWS_88: Task-owned public HTTP/HTTPS destination and SSH jump; ingress permits only the CE EIP and operator CIDR, with fresh origin-side observations and verified cleanup.
  # checkov:skip=CKV2_AWS_41: The controlled traffic guest makes no AWS API calls; no workload role or instance credentials are granted.

  ami                         = data.aws_ami.client.id
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.fixture.key_name
  subnet_id                   = aws_subnet.slo.id
  associate_public_ip_address = true
  vpc_security_group_ids      = [aws_security_group.origin.id]
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted             = true
    delete_on_termination = true
  }
  user_data                   = file("${path.module}/origin.sh")
  user_data_replace_on_change = true
  tags = merge(local.tags, {
    Name = "${var.task_id}-origin"
  })
  depends_on = [aws_route_table_association.slo]

}
resource "aws_instance" "client" {
  monitoring    = true
  ebs_optimized = true
  # checkov:skip=CKV2_AWS_41: The private traffic guest makes no AWS API calls; no workload role or instance credentials are granted.

  ami                         = data.aws_ami.client.id
  instance_type               = "t3.micro"
  key_name                    = aws_key_pair.fixture.key_name
  subnet_id                   = aws_subnet.client.id
  associate_public_ip_address = false
  vpc_security_group_ids      = [aws_security_group.fixture.id]
  metadata_options {
    http_tokens = "required"
  }
  root_block_device {
    encrypted             = true
    delete_on_termination = true
  }
  tags = merge(local.tags, {
    Name = "${var.task_id}-client"
  })

}
data "xcsh_site_registration" "ce" {

  count     = local.active ? 1 : 0
  site_name = local.site_name
  hostname  = local.site_name
  namespace = "system"

}
data "xcsh_site_registrations_by_site" "hardware" {

  count     = local.active ? 1 : 0
  site_name = local.site_name
  namespace = "system"

}
resource "xcsh_registration_approval" "ce" {
  cluster_size = 1
  state        = "APPROVED"

  count     = local.active && try(data.xcsh_site_registration.ce[0].found, false) ? 1 : 0
  name      = data.xcsh_site_registration.ce[0].name
  namespace = "system"

}
output "fixture" {

  value = {

    task_id            = var.task_id
    phase              = var.phase
    site_name          = local.active ? local.site_name : null
    ce_public_ip       = aws_eip.ce.public_ip
    ce_instance_id     = local.active ? aws_instance.ce[0].id : null
    client_private_ip  = aws_instance.client.private_ip
    origin_public_ip   = aws_instance.origin.public_ip
    slo_mac            = aws_network_interface.slo.mac_address
    sli_mac            = aws_network_interface.sli.mac_address
    slo_eni            = aws_network_interface.slo.id
    sli_eni            = aws_network_interface.sli.id
    client_route_table = aws_route_table.client.id

  }

}
output "hardware" {

  sensitive = true
  value     = local.active ? data.xcsh_site_registrations_by_site.hardware[0].items : null

}
