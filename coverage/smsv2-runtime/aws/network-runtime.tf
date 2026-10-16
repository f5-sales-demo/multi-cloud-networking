resource "aws_security_group" "origin" {
  # checkov:skip=CKV_AWS_382: Controlled origin/jump guest needs bootstrap repositories and private lab access; this fixture-only egress allowance ends at verified destruction.
  name        = "${var.task_id}-origin"
  description = "Permit controlled origin flows from the CE and task VPC."
  vpc_id      = aws_vpc.fixture.id
  ingress {
    description = "Permit the task CE acceptance traffic or operator SSH"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [aws_vpc.fixture.cidr_block]
  }
  ingress {
    description = "Permit the task CE acceptance traffic or operator SSH"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["${aws_eip.ce.public_ip}/32"]
  }
  ingress {
    description = "Permit the task CE acceptance traffic or operator SSH"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["${aws_eip.ce.public_ip}/32"]
  }
  ingress {
    description = "Permit the task CE acceptance traffic or operator SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.operator_cidr]
  }
  egress {
    description = "Temporary origin bootstrap and private jump access"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = local.tags
}

resource "aws_iam_role" "ce" {
  name = "${var.task_id}-ce"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
  tags = local.tags
}
resource "aws_iam_role_policy" "ce" {
  name = "${var.task_id}-ce-read"
  role = aws_iam_role.ce.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = [
        "ec2:DescribeInstances", "ec2:DescribeRouteTables",
        "ec2:DescribeSecurityGroups", "ec2:DescribeSubnets", "ec2:DescribeVpcs",
      ]
      Effect   = "Allow"
      Resource = "*"
    }]
  })
}
resource "aws_iam_instance_profile" "ce" {
  name = "${var.task_id}-ce"
  role = aws_iam_role.ce.name
  tags = local.tags
}
