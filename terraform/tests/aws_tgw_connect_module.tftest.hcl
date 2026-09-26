# The module owns only AWS TGW transport. F5 runtime identity and BGP state are
# intentionally absent and are composed by the root module.
mock_provider "aws" {}

run "plans_two_role_connect_attachments_and_default_associations" {
  command = plan

  module {
    source = "./modules/aws-tgw-connect"
  }

  variables {
    vpc_id                     = "vpc-plan-test"
    amazon_side_asn            = 64520
    transit_gateway_cidr_block = "100.64.0.0/24"
    transport_subnet_ids       = ["subnet-plan-a", "subnet-plan-b", "subnet-plan-c"]
    name_prefix                = "mcn-plan-test"
    ownership_tags             = { "mcn-generation" = "test-generation", "mcn-managed-by" = "terraform" }
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_connect.role) == 2
    error_message = "The module must create exactly the SLO and SLI Connect attachments."
  }

  assert {
    condition     = toset(keys(aws_ec2_transit_gateway_connect.role)) == toset(["slo", "sli"])
    error_message = "Connect attachments must be keyed strictly by the SLO and SLI roles."
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_vpc_attachment.transport.subnet_ids) == 3
    error_message = "The transport attachment must use exactly three availability-zone subnets."
  }

  assert {
    condition     = length(aws_ec2_transit_gateway_route_table_propagation.connect) == 2 && alltrue([for attachment in values(aws_ec2_transit_gateway_connect.role) : attachment.transit_gateway_default_route_table_association == true])
    error_message = "Each role attachment must use automatic default association and explicit propagation."
  }

  assert {
    condition     = aws_ec2_transit_gateway.this.default_route_table_association == "enable" && aws_ec2_transit_gateway.this.default_route_table_propagation == "disable" && aws_ec2_transit_gateway_vpc_attachment.transport.transit_gateway_default_route_table_association == true
    error_message = "The TGW and transport attachment must use automatic default association while retaining explicit propagation."
  }
}

run "rejects_duplicate_or_incomplete_transport_subnets" {
  command = plan

  module {
    source = "./modules/aws-tgw-connect"
  }

  variables {
    vpc_id                     = "vpc-plan-test"
    amazon_side_asn            = 64520
    transit_gateway_cidr_block = "100.64.0.0/24"
    transport_subnet_ids       = ["subnet-plan-a", "subnet-plan-a", "subnet-plan-b"]
    name_prefix                = "mcn-plan-test"
    ownership_tags             = { "mcn-generation" = "test-generation", "mcn-managed-by" = "terraform" }
  }

  expect_failures = [var.transport_subnet_ids]
}

run "rejects_invalid_amazon_side_asn" {
  command = plan

  module {
    source = "./modules/aws-tgw-connect"
  }

  variables {
    vpc_id                     = "vpc-plan-test"
    amazon_side_asn            = 0
    transit_gateway_cidr_block = "100.64.0.0/24"
    transport_subnet_ids       = ["subnet-plan-a", "subnet-plan-b", "subnet-plan-c"]
    name_prefix                = "mcn-plan-test"
    ownership_tags             = { "mcn-generation" = "test-generation", "mcn-managed-by" = "terraform" }
  }

  expect_failures = [var.amazon_side_asn]
}

run "rejects_invalid_tgw_cidr" {
  command = plan

  module {
    source = "./modules/aws-tgw-connect"
  }

  variables {
    vpc_id                     = "vpc-plan-test"
    amazon_side_asn            = 64520
    transit_gateway_cidr_block = "not-a-cidr"
    transport_subnet_ids       = ["subnet-plan-a", "subnet-plan-b", "subnet-plan-c"]
    name_prefix                = "mcn-plan-test"
    ownership_tags             = { "mcn-generation" = "test-generation", "mcn-managed-by" = "terraform" }
  }

  expect_failures = [var.transit_gateway_cidr_block]
}
