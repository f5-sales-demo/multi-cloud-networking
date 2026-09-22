# ---------------------------------------------------------
# AWS Customer Edge (EC2 instances, IAM, and ordered dual NICs)
# ---------------------------------------------------------
locals {
  aws_ssh_public_key = var.aws_ssh_public_key != "" ? var.aws_ssh_public_key : local.ssh_public_key
  aws_ce_site_cloud_init = {
    for key in keys(local.aws_active_sites) : key => replace(
      try(data.xcsh_site_cloud_init.aws[key].cloud_init_config, ""),
      "{{ .token }}",
      try(xcsh_token.aws[key].uid, "{{ .token }}"),
    )
  }
}
resource "aws_key_pair" "ce" {
  count      = var.enable_aws ? 1 : 0
  key_name   = "${local.aws_resource_prefix}-aws-ce-key"
  public_key = local.aws_ssh_public_key

  tags = local.tags
}

resource "aws_iam_role" "ce" {
  count = var.enable_aws ? 1 : 0
  name  = "${local.aws_resource_prefix}-aws-ce-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
    }]
  })

  tags = local.tags
}

resource "aws_iam_role_policy" "ce" {
  count = var.enable_aws ? 1 : 0
  name  = "${local.aws_resource_prefix}-aws-ce-policy"
  role  = aws_iam_role.ce[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "ec2:DescribeInstances",
        "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSubnets",
        "ec2:DescribeVpcs"
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}

resource "aws_iam_instance_profile" "ce" {
  count = var.enable_aws ? 1 : 0
  name  = "${local.aws_resource_prefix}-aws-ce-profile"
  role  = aws_iam_role.ce[0].id

  tags = local.tags
}

# Dual NICs per Customer Edge node
resource "aws_network_interface" "slo" {
  count = var.enable_aws ? var.aws_ce_count : 0

  subnet_id         = aws_subnet.public_slo[count.index % 3].id
  security_groups   = [aws_security_group.ce[0].id]
  source_dest_check = false

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-ce-${count.index + 1}-slo"
  })
}

resource "aws_network_interface" "sli" {
  count = var.enable_aws ? var.aws_ce_count : 0

  subnet_id         = aws_subnet.private_sli[count.index % 3].id
  private_ips       = [local.aws_sites[format("%02d", count.index + 1)].listener_ip]
  security_groups   = [aws_security_group.ce[0].id]
  source_dest_check = false

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-ce-${count.index + 1}-sli"
  })
}

resource "aws_eip" "ce" {
  #checkov:skip=CKV2_AWS_19:Lab Elastic IP - attached to SLO network interface on CE instance
  count = var.enable_aws ? var.aws_ce_count : 0

  domain            = "vpc"
  network_interface = aws_network_interface.slo[count.index].id

  depends_on = [aws_internet_gateway.aws]

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-ce-${count.index + 1}-eip"
  })
}

resource "aws_instance" "ce" {
  # Retirement must destroy only the bootstrap CE instances while preserving
  # ENIs, EIPs, VPC, IAM, and all other AWS networking for configured creation.
  count = var.enable_aws && var.aws_site_configuration_phase != "bootstrap_retirement" ? var.aws_ce_count : 0

  ami                  = var.aws_ce_ami_id
  ebs_optimized        = true
  instance_type        = var.aws_instance_type
  iam_instance_profile = aws_iam_instance_profile.ce[0].name
  key_name             = aws_key_pair.ce[0].key_name
  monitoring           = true

  network_interface {
    network_interface_id = aws_network_interface.slo[count.index].id
    device_index         = 0
  }

  network_interface {
    network_interface_id = aws_network_interface.sli[count.index].id
    device_index         = 1
  }

  root_block_device {
    delete_on_termination = true
    encrypted             = true
    volume_size           = 100
    volume_type           = "gp3"
  }

  metadata_options {
    http_tokens = "required"
  }

  # Preserve the provider-issued cloud-config as the only cloud-config MIME part.
  # A boothook and final shell part enforce SLO-only default routing and install
  # operator access without replacing the provider's /etc/vpm/user_data list.
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/cloud-init/ce-node-aws.multipart.tpl", {
    site_cloud_init = local.aws_ce_site_cloud_init[format("%02d", count.index + 1)]
    sli_mac         = aws_network_interface.sli[count.index].mac_address
    fqdn            = "${local.aws_active_sites[format("%02d", count.index + 1)].hostname}.${var.aws_location}.compute.internal"
    ssh_public_key  = chomp(local.aws_ssh_public_key)
    # These non-secret fingerprints make the EC2 lifecycle follow immutable
    # site-version changes. A replacement site needs a first-boot CE, never a
    # VM that has already consumed the former cloud-init.
    software_version = var.aws_software_version
    os_version       = var.aws_os_version
  })

  tags = merge(local.tags, {
    Name                                                                                    = local.aws_active_sites[format("%02d", count.index + 1)].name
    "ves-io-site-name"                                                                      = local.aws_active_sites[format("%02d", count.index + 1)].name
    "kubernetes.io/cluster/${local.aws_active_sites[format("%02d", count.index + 1)].name}" = "owned"
  })

  lifecycle {
    # The discovery-to-configured site update regenerates cloud-init metadata,
    # but the already-registered CE must remain in place to receive that
    # control-plane reconciliation. First creation still uses user_data.
    ignore_changes = [user_data]

    precondition {
      condition     = var.aws_ce_ami_id != null
      error_message = "AWS CE deployment requires an explicit approved aws_ce_ami_id; dynamic AMI selection is not allowed."
    }
  }
}
