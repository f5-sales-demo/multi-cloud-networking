# ---------------------------------------------------------
# AWS VPC, Subnets, Gateways, Route Tables & Security Groups
# ---------------------------------------------------------

data "aws_availability_zones" "available" {
  count = var.enable_aws ? 1 : 0
  state = "available"
}

resource "aws_vpc" "aws" {
  #checkov:skip=CKV2_AWS_11:Lab VPC - flow logging not required
  #checkov:skip=CKV2_AWS_12:Lab VPC - default security group managed by AWS
  count = var.enable_aws ? 1 : 0

  cidr_block           = var.aws_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-vpc"
  })
}

resource "aws_internet_gateway" "aws" {
  count = var.enable_aws ? 1 : 0

  vpc_id = aws_vpc.aws[0].id

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-igw"
  })
}

# 3 Public SLO Subnets (10.150.1.0/24, 10.150.2.0/24, 10.150.3.0/24)
resource "aws_subnet" "public_slo" {
  count = var.enable_aws ? 3 : 0

  vpc_id                  = aws_vpc.aws[0].id
  cidr_block              = cidrsubnet(var.aws_vpc_cidr, 8, count.index + 1)
  availability_zone       = try(data.aws_availability_zones.available[0].names[count.index], "${var.aws_location}${element(["a", "b", "c"], count.index)}")
  map_public_ip_on_launch = false

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-slo-subnet-${count.index + 1}"
  })
}

# 3 Private SLI Subnets (10.150.11.0/24, 10.150.12.0/24, 10.150.13.0/24)
resource "aws_subnet" "private_sli" {
  count = var.enable_aws ? 3 : 0

  vpc_id            = aws_vpc.aws[0].id
  cidr_block        = cidrsubnet(var.aws_vpc_cidr, 8, count.index + 11)
  availability_zone = try(data.aws_availability_zones.available[0].names[count.index], "${var.aws_location}${element(["a", "b", "c"], count.index)}")

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-sli-subnet-${count.index + 1}"
  })
}

resource "aws_route_table" "public" {
  count = var.enable_aws ? 1 : 0

  depends_on = [module.aws_tgw_connect]

  vpc_id = aws_vpc.aws[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.aws[0].id
  }

  dynamic "route" {
    for_each = var.enable_aws_tgw_connect ? [1] : []
    content {
      cidr_block         = var.aws_tgw_gre_cidr
      transit_gateway_id = module.aws_tgw_connect[0].transit_gateway_id
    }
  }

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-public-rt"
  })
}

resource "aws_route_table_association" "public" {
  for_each = var.enable_aws ? local.aws_bootstrap_sites : {}

  subnet_id      = aws_subnet.public_slo[each.value.index].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table" "private" {
  count = var.enable_aws ? 1 : 0

  depends_on = [module.aws_tgw_connect]

  vpc_id = aws_vpc.aws[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.aws[0].id
  }

  dynamic "route" {
    for_each = var.enable_aws_tgw_connect ? [1] : []
    content {
      cidr_block         = var.aws_tgw_gre_cidr
      transit_gateway_id = module.aws_tgw_connect[0].transit_gateway_id
    }
  }

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-private-rt"
  })
}

resource "aws_route_table_association" "private" {
  for_each = var.enable_aws ? local.aws_bootstrap_sites : {}

  subnet_id      = aws_subnet.private_sli[each.value.index].id
  route_table_id = aws_route_table.private[0].id
}

resource "aws_security_group" "ce" {
  #checkov:skip=CKV2_AWS_5:Attached to every CE SLO and SLI ENI; Checkov does not follow counted expression references.
  count = var.enable_aws ? 1 : 0

  name        = "${local.aws_resource_prefix}-aws-ce-sg"
  description = "Security group for F5 XC Customer Edge nodes in AWS"
  vpc_id      = aws_vpc.aws[0].id

  ingress {
    description = "Site Console Local UI"
    from_port   = 65500
    to_port     = 65500
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "ICMP"
    from_port   = -1
    to_port     = -1
    protocol    = "icmp"
    cidr_blocks = [var.aws_vpc_cidr]
  }

  ingress {
    description = "Intra-cluster communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  dynamic "ingress" {
    for_each = var.enable_aws_tgw_connect ? [1] : []
    content {
      description = "GRE from the Transit Gateway Connect endpoint"
      from_port   = 0
      to_port     = 0
      protocol    = "47"
      cidr_blocks = [var.aws_tgw_gre_cidr]
    }
  }

  egress {
    #checkov:skip=CKV_AWS_382:The CE is a network appliance whose overlay and application data-plane destinations are tenant-defined; ingress remains explicitly constrained.
    description = "Allow all outbound traffic"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, {
    Name = "${local.aws_resource_prefix}-aws-ce-sg"
  })
}

# Dedicated workload VPC. The client is managed only through SSM and its
# security group deliberately declares no ingress rules.
resource "aws_vpc" "workload" {
  #checkov:skip=CKV2_AWS_11:Short-lived protected-lab workload VPC.
  #checkov:skip=CKV2_AWS_12:Default security group is not used by the client.
  count                = var.enable_aws ? 1 : 0
  cidr_block           = var.aws_workload_vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-vpc" })
}

resource "aws_internet_gateway" "workload" {
  count  = var.enable_aws ? 1 : 0
  vpc_id = aws_vpc.workload[0].id
  tags   = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-igw" })
}

resource "aws_subnet" "workload" {
  count                   = var.enable_aws ? 1 : 0
  vpc_id                  = aws_vpc.workload[0].id
  cidr_block              = cidrsubnet(var.aws_workload_vpc_cidr, 8, 1)
  availability_zone       = try(data.aws_availability_zones.available[0].names[0], "${var.aws_location}a")
  map_public_ip_on_launch = false
  tags                    = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-public" })
}

resource "aws_route_table" "workload" {
  count  = var.enable_aws ? 1 : 0
  vpc_id = aws_vpc.workload[0].id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.workload[0].id
  }

  dynamic "route" {
    for_each = var.enable_aws_tgw_connect ? toset([for site in values(local.aws_sites) : site.listener_ip]) : toset([])
    content {
      cidr_block         = "${route.value}/32"
      transit_gateway_id = module.aws_tgw_connect[0].transit_gateway_id
    }
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-rt" })
}

resource "aws_route_table_association" "workload" {
  count          = var.enable_aws ? 1 : 0
  subnet_id      = aws_subnet.workload[0].id
  route_table_id = aws_route_table.workload[0].id
}

resource "aws_ec2_transit_gateway_vpc_attachment" "workload" {
  count                                           = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  subnet_ids                                      = [aws_subnet.workload[0].id]
  transit_gateway_id                              = module.aws_tgw_connect[0].transit_gateway_id
  transit_gateway_default_route_table_association = true
  transit_gateway_default_route_table_propagation = false
  vpc_id                                          = aws_vpc.workload[0].id
  tags                                            = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-tgw" })
}

resource "aws_ec2_transit_gateway_route_table_propagation" "workload" {
  count                          = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.workload[0].id
  transit_gateway_route_table_id = module.aws_tgw_connect[0].route_table_id
}

resource "aws_security_group" "workload" {
  #checkov:skip=CKV2_AWS_5:Attached directly to the workload instance through vpc_security_group_ids; Checkov does not follow the counted expression.
  count       = var.enable_aws ? 1 : 0
  name        = "${local.aws_resource_prefix}-aws-workload-ssm"
  description = "Egress-only SSM workload client; no ingress rules"
  vpc_id      = aws_vpc.workload[0].id

  egress {
    description = "HTTP showcase traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "HTTPS for SSM and showcase traffic"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "UDP DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = ["${cidrhost(var.aws_workload_vpc_cidr, 2)}/32"]
  }

  egress {
    description = "TCP DNS to the VPC resolver"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = ["${cidrhost(var.aws_workload_vpc_cidr, 2)}/32"]
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-workload-ssm" })
}

resource "aws_security_group" "smsv2_nlb" {
  #checkov:skip=CKV2_AWS_5:Attached directly to the internal SMSv2 network load balancer.
  count       = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  name        = "${local.aws_resource_prefix}-aws-smsv2-nlb"
  description = "Workload access to the SMSv2 site-local listeners"
  vpc_id      = aws_vpc.workload[0].id

  ingress {
    description = "HTTP from the workload VPC"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.aws_workload_vpc_cidr]
  }

  egress {
    description = "HTTP health checks and traffic to SMSv2 SLI listeners"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.aws_vpc_cidr]
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-smsv2-nlb" })
}

resource "aws_lb" "smsv2" {
  #checkov:skip=CKV2_AWS_20:Internal TCP NLB; HTTP redirects are an ALB listener capability.
  #checkov:skip=CKV_AWS_91:Ephemeral private development NLB; protected evidence captures health and traffic.
  #checkov:skip=CKV_AWS_150:Ephemeral development topology; deletion protection would block authorized teardown.
  count                            = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  name                             = "${local.aws_resource_prefix}-aws-nlb"
  internal                         = true
  load_balancer_type               = "network"
  security_groups                  = [aws_security_group.smsv2_nlb[0].id]
  enable_cross_zone_load_balancing = true

  subnet_mapping {
    subnet_id            = aws_subnet.workload[0].id
    private_ipv4_address = var.aws_vip
  }

  lifecycle {
    precondition {
      condition     = var.aws_vip == cidrhost(aws_subnet.workload[0].cidr_block, 10)
      error_message = "aws_vip must be host 10 of the workload subnet reserved for the internal SMSv2 NLB."
    }
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-smsv2" })
}

resource "aws_lb_target_group" "smsv2" {
  count       = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  name        = "${local.aws_resource_prefix}-aws-nlb"
  port        = 80
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = aws_vpc.workload[0].id

  health_check {
    enabled             = true
    healthy_threshold   = 2
    interval            = 10
    port                = "traffic-port"
    protocol            = "TCP"
    unhealthy_threshold = 2
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-smsv2" })
}

resource "aws_lb_target_group_attachment" "smsv2" {
  for_each = var.enable_aws && var.enable_aws_tgw_connect ? local.aws_sites : {}

  target_group_arn  = aws_lb_target_group.smsv2[0].arn
  target_id         = each.value.listener_ip
  port              = 80
  availability_zone = "all"
}

resource "aws_lb_listener" "smsv2" {
  count             = var.enable_aws && var.enable_aws_tgw_connect ? 1 : 0
  load_balancer_arn = aws_lb.smsv2[0].arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.smsv2[0].arn
  }
}

resource "aws_iam_role" "workload" {
  count = var.enable_aws ? 1 : 0
  name  = "${local.aws_resource_prefix}-aws-workload-ssm"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "workload_ssm" {
  count      = var.enable_aws ? 1 : 0
  role       = aws_iam_role.workload[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "workload" {
  count = var.enable_aws ? 1 : 0
  name  = "${local.aws_resource_prefix}-aws-workload-ssm"
  role  = aws_iam_role.workload[0].name
  tags  = local.tags
}

resource "aws_instance" "workload" {
  #checkov:skip=CKV_AWS_88:The ingress-free UAT client needs an explicit public IP for SSM and Internet origin checks without a NAT gateway.
  count                       = var.enable_aws ? 1 : 0
  ami                         = var.aws_workload_ami_id
  instance_type               = "t3.micro"
  subnet_id                   = aws_subnet.workload[0].id
  ebs_optimized               = true
  vpc_security_group_ids      = [aws_security_group.workload[0].id]
  iam_instance_profile        = aws_iam_instance_profile.workload[0].name
  associate_public_ip_address = true
  monitoring                  = true

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    encrypted = true
  }

  lifecycle {
    precondition {
      condition     = var.aws_workload_ami_id != null
      error_message = "AWS workload deployment requires an explicit approved aws_workload_ami_id; dynamic AMI selection is not allowed."
    }
  }

  tags = merge(local.tags, { Name = "${local.aws_resource_prefix}-aws-ssm-client" })
}
